import Foundation
import Testing
@testable import BeepbarCore

/// `VoiceLeveler`: the gain that brings a lecture's speech to a fixed level whatever it was
/// recorded at, with a gain curve that does not depend on where a render's clip starts and ends.
/// Synthetic signals only: noise bursts with short digital-silence gaps, which is what Apple's
/// voice isolation hands the leveler (a voice with silent pauses).
struct VoiceLevelerTests {
    static let rate = VoiceLeveler.rate
    static func seconds(_ s: Double) -> Int { Int((s * Double(rate)).rounded()) }

    /// Deterministic uniform noise in -1...1.
    struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
        }
    }

    /// `length` samples of "speech": bursts of noise at `dB` dBFS RMS, 1 s on and 0.3 s of digital
    /// silence, repeating. The leveler's 400 ms frames inside a burst measure `dB` (within a
    /// fraction of a dB), so the expected gain is `target − dB`.
    static func speech(seconds length: Double, dB: Double, silent: Bool = false) -> [Float] {
        var noise = Noise()
        let amplitude = Float(pow(10, dB / 20) * 3.0.squareRoot())
        let period = seconds(1.3), burst = seconds(1.0)
        return (0..<seconds(length)).map { i in
            let x = noise.next()
            return silent || i % period >= burst ? 0 : x * amplitude
        }
    }

    /// Several parts one after the other: (seconds, dBFS), dBFS nil for digital silence.
    static func lecture(_ parts: [(Double, Double?)]) -> [Float] {
        parts.flatMap { speech(seconds: $0.0, dB: $0.1 ?? -120, silent: $0.1 == nil) }
    }

    /// The 400 ms RMS levels in dBFS of `samples`, one per `hop` samples.
    static func levels(_ samples: [Float], hop: Int = 4800) -> [Double] {
        let frame = VoiceLeveler.frameLength
        return stride(from: 0, through: samples.count - frame, by: hop).map { lo in
            var energy = 0.0
            for i in lo..<(lo + frame) { energy += Double(samples[i]) * Double(samples[i]) }
            return 10 * log10(energy / Double(frame) + 1e-20)
        }
    }

    // MARK: Level

    /// A −60 dBFS lecture is lifted to about the target (+40 dB, the case the old chain could not
    /// do), a normal −22 dBFS one is left within 3 dB, and the gain stops at +48 and −6. Guards
    /// against a leveler that is relative to nothing (no lift of quiet lectures), one that
    /// changes a lecture that is fine, and one without the clamps (a −80 dBFS lecture lifted by
    /// 60 dB would amplify its noise floor).
    @Test func speechIsBroughtToTheTargetAndTheGainIsClamped() {
        let leveler = VoiceLeveler()
        func gain(_ dB: Double) -> Double {
            let clip = VoiceLeveler.Clip(samples: Self.speech(seconds: 40, dB: dB), start: 0)
            return leveler.gains(for: 3...3, detector: clip, known: [:])[3]!
        }
        #expect(abs(gain(-60) - 40) < 2)
        #expect(abs(gain(-22) - 2) < 2)
        #expect(gain(-80) == 48)
        #expect(gain(-5) == -6)
        // Applied: the output's speech sits at the target.
        let quiet = VoiceLeveler.Clip(samples: Self.speech(seconds: 40, dB: -60), start: 0)
        let out = leveler.level(quiet, gains: leveler.gains(for: leveler.keypoints(covering: 0..<quiet.samples.count), detector: quiet, known: [:]))
        let top = AudioLevels.percentile(Self.levels(out).filter { $0 > -95 }, 0.9)
        #expect(abs(top - (-20)) < 2, "speech levelled to \(top) dBFS")
    }

    /// A pause is not lifted: a keypoint whose window is silent takes the previous keypoint's
    /// gain, and every one after it does too. Guards against raising silence (and the noise in
    /// it) by +48 dB, and against a gain that jumps in a break and again when speech resumes.
    @Test func aSilentWindowHoldsThePreviousGain() {
        let leveler = VoiceLeveler()
        let clip = VoiceLeveler.Clip(samples: Self.lecture([(25, -40), (35, nil)]), start: 0)
        let gains = leveler.gains(for: 0...5, detector: clip, known: [:])
        #expect(abs(gains[3]! - 20) < 2, "keypoint 3's window is mostly speech")
        #expect(gains[4] == gains[3], "keypoint 4's window (28–40 s) is silent: it holds")
        #expect(gains[5] == gains[3])
        #expect(Set(gains.keys) == Set(0...5), "only the requested keypoints come back")
    }

    /// A window is a pause when fewer than 15% of its frames are voiced, not only when none is: a
    /// cough or a word in 12 s of silence does not set the gain. 1.6 s of speech in the window
    /// (4 frames of 30) holds the previous gain; 4 s (about 10) is measured. Guards against a
    /// hold that waits for exact silence, which lifted a stray noise by up to 48 dB.
    @Test func aWindowWithTooFewVoicedFramesHolds() {
        let leveler = VoiceLeveler()
        let few = VoiceLeveler.Clip(samples: Self.lecture([(18, -50), (1.6, -30), (10.4, nil)]), start: 0)
        let gainsFew = leveler.gains(for: 2...3, detector: few, known: [:])
        #expect(gainsFew[3] == gainsFew[2], "4 voiced frames of 30 hold")
        let enough = VoiceLeveler.Clip(samples: Self.lecture([(18, -50), (4, -30), (8, nil)]), start: 0)
        let gainsEnough = leveler.gains(for: 2...3, detector: enough, known: [:])
        #expect(abs(gainsEnough[3]! - 10) < 2, "about 10 voiced frames of 30 are measured: \(gainsEnough[3]!)")
    }

    /// A keypoint in `known` is returned as it is, whatever the audio says, and the others are
    /// still measured. This is what makes two segments that share a keypoint agree at their
    /// seam. Guards against recomputing a keypoint (a seam that steps by the difference between
    /// two views of the audio).
    @Test func aKnownKeypointIsNeverRecomputed() {
        let leveler = VoiceLeveler()
        let clip = VoiceLeveler.Clip(samples: Self.speech(seconds: 40, dB: -40), start: 0)
        let gains = leveler.gains(for: 2...3, detector: clip, known: [2: 7.5])
        #expect(gains[2] == 7.5, "the audio says +20")
        #expect(abs(gains[3]! - 20) < 2)
        // A known keypoint also anchors a hold chain: silence after it takes its value.
        let silent = VoiceLeveler.Clip(samples: Self.speech(seconds: 40, dB: -40, silent: true), start: 0)
        #expect(leveler.gains(for: 3...3, detector: silent, known: [2: 7.5])[3] == 7.5)
    }

    // MARK: Windows a clip cannot see in full

    /// After a seek the clip starts less than a window before a keypoint. With at least 8 frames
    /// the keypoint is measured on what exists; with fewer it looks forward from the clip's first
    /// sample. The audio is made so the two answers differ (quiet before the keypoint, loud after),
    /// and the clip's start is off the keypoint grid. Guards against a gain measured on too few
    /// frames, against a hold or neutral gain where audio exists, and against a forward window
    /// that is not anchored at the clip's own first sample.
    @Test func aPartialWindowIsMeasuredOnWhatExistsAndTooLittleLooksForward() {
        let leveler = VoiceLeveler()
        // −50 dBFS up to 20 s, −30 dBFS after it.
        let whole = Self.lecture([(20, -50), (30, -30)])
        func gain(from startSeconds: Double) -> Double? {
            let start = Self.seconds(startSeconds)
            let clip = VoiceLeveler.Clip(samples: Array(whole[start...]), start: start)
            return leveler.gains(for: 2...2, detector: clip, known: [:])[2]
        }
        // 8 frames (3.2 s) before keypoint 2 exist: measured on them, −50 → +30.
        #expect(abs(gain(from: 16.8)! - 30) < 2)
        // 7 frames: forward from the first sample (17.2 s, off the grid): 7 quiet frames and 23
        // loud ones, whose 90th percentile is the loud level: +10.
        #expect(abs(gain(from: 17.2)! - 10) < 2)
    }

    /// The keypoint at the lecture's start has no audio before it: it looks forward from the
    /// clip's first sample, so the gain is right from the first sample. Guards against the first
    /// seconds of every lecture being left at neutral gain (a −60 dBFS lecture inaudible at its
    /// start).
    @Test func theFirstKeypointLooksForward() {
        let leveler = VoiceLeveler()
        let clip = VoiceLeveler.Clip(samples: Self.speech(seconds: 20, dB: -60), start: 0)
        #expect(abs(leveler.gains(for: 0...0, detector: clip, known: [:])[0]! - 40) < 2)
    }

    /// A keypoint that cannot be anchored backwards (the clip starts in silence, nothing is
    /// known) takes the first keypoint ahead that measures a gain; failing that the nearest
    /// known one; failing that `neutral`. Guards against a silent start left at 0 dB (then a
    /// jump of 20+ dB at the first word), against lifting silence, and against a made-up value.
    @Test func anUnanchoredHoldTakesTheFirstMeasurableKeypointAhead() {
        var leveler = VoiceLeveler()
        // 30 s of silence, then speech at −40 dBFS: keypoints 0...3 hold (their windows are
        // silent); keypoint 4's window (28–40 s) is mostly speech.
        let clip = VoiceLeveler.Clip(samples: Self.lecture([(30, nil), (60, -40)]), start: 0)
        let gains = leveler.gains(for: 0...4, detector: clip, known: [:])
        #expect(abs(gains[4]! - 20) < 2)
        for k in 0...3 { #expect(gains[k] == gains[4], "keypoint \(k)") }

        let silent = VoiceLeveler.Clip(samples: Self.speech(seconds: 60, dB: -40, silent: true), start: 0)
        #expect(leveler.gains(for: 0...1, detector: silent, known: [20: 12, 90: -3]) == [0: 12, 1: 12], "nearest known by index")
        leveler.neutral = 3
        #expect(leveler.gains(for: 0...1, detector: silent, known: [:]) == [0: 3, 1: 3], "nothing to go on: neutral")
    }

    /// A clip far into the lecture (keypoint 540) that opens with 15 s of silence: the keypoints in
    /// that silence take the first keypoint ahead that measures (speech at −40 dBFS, +20), not
    /// the stale `known` gain of the lecture's first minute (+40), and the work is bounded (the
    /// forward bootstrap reaches at most one spacing before the clip, so the hold chain stops at
    /// keypoint 538 instead of walking back 540 keypoints through the same forward window). With the
    /// keypoint right before them known, the hold still takes it. Guards against a hold chain
    /// that ends on a gain from minutes ago, and against unbounded work on the actor after a seek.
    @Test func aSilentStartFarIntoTheLectureDoesNotReachBackToAStaleGain() {
        let leveler = VoiceLeveler()
        let start = 5400 * Self.rate
        let clip = VoiceLeveler.Clip(samples: Self.lecture([(15, nil), (40, -40)]), start: start)
        let gains = leveler.gains(for: 540...541, detector: clip, known: [0: 40])
        #expect(abs(gains[540]! - 20) < 2, "\(gains[540]!)")
        #expect(gains[541] == gains[540])
        // A known keypoint immediately before still anchors the chain (539 is one spacing before
        // the clip, within the bootstrap's reach; its own value is the known one).
        #expect(leveler.gains(for: 540...541, detector: clip, known: [0: 40, 539: 7.5]) == [540: 7.5, 541: 7.5])
    }

    /// Provisional keypoints (`resolve`): a provisional `neutral` requested again comes back
    /// unchanged and is still marked; it does not anchor a later keypoint in silence when a
    /// voice follows in the clip (that one takes the voice's gain, not the 0 dB); with no voice
    /// ahead and no firm known value the result is `neutral` and is marked provisional; a firm
    /// known value anchors as before. Guards against a lecture that opens with a long silence
    /// held at 0 dB through the silence before its first words (the gain then climbed to the
    /// voice's during them), and against a provisional value being recomputed (a step at a seam).
    @Test func aProvisionalKeypointAnchorsNothing() {
        let leveler = VoiceLeveler()
        // Silence, then speech at −40 dBFS (+20 dB) from 40 s: keypoint 5's window (38–50 s) has
        // 10 s of voice, so keypoints 1...4 are silent holds and 5 measures.
        let clip = VoiceLeveler.Clip(samples: Self.lecture([(40, nil), (30, -40)]), start: 0)
        let known: [Int: Double] = [0: 0]

        let again = leveler.resolve(for: 0...0, detector: clip, known: known, provisional: [0])
        #expect(again.gains == [0: 0] && again.provisional == [0], "a provisional value requested again")

        let provisionalAnchor = leveler.resolve(for: 1...2, detector: clip, known: known, provisional: [0])
        #expect(abs(provisionalAnchor.gains[1]! - 20) < 2 && abs(provisionalAnchor.gains[2]! - 20) < 2, "\(provisionalAnchor.gains)")
        #expect(provisionalAnchor.provisional.isEmpty)
        // The same memory, firm: it anchors, as it always did.
        let firm = leveler.resolve(for: 1...2, detector: clip, known: known, provisional: [])
        #expect(firm.gains == [1: 0, 2: 0] && firm.provisional.isEmpty)
        #expect(leveler.gains(for: 1...2, detector: clip, known: known) == firm.gains, "`gains` is `resolve` without provisional keypoints")

        // No voice anywhere ahead, only a provisional value known: neutral again, provisional.
        let silent = VoiceLeveler.Clip(samples: Self.speech(seconds: 60, dB: -40, silent: true), start: 0)
        let none = leveler.resolve(for: 1...2, detector: silent, known: [0: 0], provisional: [0])
        #expect(none.gains == [1: 0, 2: 0] && none.provisional == [1, 2], "\(none)")
        // A firm known value elsewhere is what the unanchored rule takes, and it is not provisional.
        let elsewhere = leveler.resolve(for: 1...1, detector: silent, known: [0: 0, 30: 9], provisional: [0])
        #expect(elsewhere.gains == [1: 9] && elsewhere.provisional.isEmpty, "\(elsewhere)")
    }

    // MARK: Applying

    /// A jump from −60 to −15 dBFS under a +40 dB keypoint gain (the gain was right for the
    /// quiet part) must not be amplified: the 400 ms RMS of the output never goes above
    /// target + headroom (−14 dBFS) by more than a couple of dB, which the limiter downstream can
    /// take. Without the ceiling it would be +25 dBFS. Also from a clip whose first sample is
    /// already loud, and one that starts off the 10 ms block grid: the ceiling does not wait to
    /// see enough audio. Guards against a ceiling that is off at the clip's edge, the case of
    /// every segment after a seek.
    @Test func theCeilingStopsALoudJumpUnderAHighGain() {
        let leveler = VoiceLeveler()
        let whole = Self.lecture([(10, -60), (10, -15)])
        let gains = [0: 40.0, 1: 40, 2: 40]
        func worst(_ start: Int) -> Double {
            let clip = VoiceLeveler.Clip(samples: Array(whole[start...]), start: start)
            let out = leveler.level(clip, gains: gains)
            // From the first loud 400 ms (the quiet part is far below the limit anyway).
            let loudFrom = max(0, Self.seconds(10) - start - Self.seconds(0.5))
            return Self.levels(Array(out[loudFrom...]), hop: 2400).max()!
        }
        let limit = leveler.target + leveler.ceilingHeadroom
        #expect(worst(0) < limit + 2, "the jump at 10 s")
        #expect(worst(Self.seconds(12)) < limit + 2, "a clip that starts loud")
        #expect(worst(Self.seconds(12) + 100) < limit + 2, "a clip that starts between two 10 ms blocks")
    }

    /// Outside the keypoints it was given, `level` holds the nearest one's gain (the pre- and
    /// post-roll of a clip lie outside its segment's own keypoints), linear in dB between two,
    /// and with none at all leaves the audio as it is. Guards against a gain that falls to 0 dB
    /// or to the wrong keypoint at a clip's edges, which would make a step at every seam.
    @Test func levelHoldsTheEdgeGainAndInterpolatesBetweenKeypoints() {
        let leveler = VoiceLeveler()
        // Quiet and steady, so the ceiling (about the loudness) never acts.
        var noise = Noise()
        let input = (0..<Self.seconds(50)).map { _ in noise.next() * 0.0005 + 0.0003 }
        let clip = VoiceLeveler.Clip(samples: input, start: 0)
        let out = leveler.level(clip, gains: [2: 10, 3: 20])
        func db(at seconds: Double) -> Double {
            let i = Self.seconds(seconds)
            return 20 * log10(Double(out[i] / input[i]))
        }
        #expect(abs(db(at: 5) - 10) < 0.01, "before keypoint 2: its value")
        #expect(abs(db(at: 20) - 10) < 0.01)
        #expect(abs(db(at: 25) - 15) < 0.01, "between 2 and 3: halfway")
        #expect(abs(db(at: 40) - 20) < 0.01, "after keypoint 3: its value")
        #expect(leveler.level(clip, gains: [:]) == input, "no keypoints: neutral")
        #expect(leveler.level(VoiceLeveler.Clip(samples: [], start: 0), gains: [:]).isEmpty)
    }

    /// A clip cut anywhere gives the same samples as the whole where it has its lead: the
    /// ceiling and the gain depend on the lecture's clock and on 1.2 s around, not on where the
    /// clip begins. Guards against a clip-relative position (a block grid or keypoint position
    /// counted from the clip's first sample), the property all segment seams rely on.
    @Test func aClipCutElsewhereRendersTheSameSamples() {
        let leveler = VoiceLeveler()
        let whole = Self.lecture([(15, -45), (15, -20), (20, -50)])
        let gains: [Int: Double] = [0: 25, 1: 25, 2: 30, 3: 5, 4: 35, 5: 30]
        let reference = leveler.level(VoiceLeveler.Clip(samples: whole, start: 0), gains: gains)
        let start = Self.seconds(17.3) + 7
        let cut = leveler.level(VoiceLeveler.Clip(samples: Array(whole[start..<Self.seconds(45)]), start: start), gains: gains)
        var worst = 0.0
        for i in Self.seconds(2)..<(cut.count - Self.seconds(2)) where abs(reference[start + i]) > 1e-9 {
            worst = max(worst, abs(Double(cut[i] / reference[start + i]) - 1))
        }
        #expect(worst < 1e-5, "largest relative difference \(worst)")
    }

    // MARK: Keypoints

    /// The keypoints a span needs: from the one at or before its first sample to the one at or
    /// after its end, so a span on the grid and one off it. Guards against a missing closing
    /// keypoint (the last samples of every segment would be uninterpolated).
    @Test func keypointsCoverASpanFromBothSides() {
        let leveler = VoiceLeveler()
        let step = Self.seconds(10)
        #expect(leveler.keypoints(covering: 0..<step) == 0...1)
        #expect(leveler.keypoints(covering: step..<(2 * step)) == 1...2)
        #expect(leveler.keypoints(covering: (step + 1)..<(2 * step + 1)) == 1...3)
        #expect(leveler.keypoints(covering: Self.seconds(5)..<Self.seconds(7)) == 0...1)
        #expect(leveler.keypoints(covering: 0..<1) == 0...1)
        #expect(leveler.keypoints(covering: Self.seconds(29.7)..<Self.seconds(59.7)) == 2...6)
    }

    // Speed is not tested here (a time limit is empty in a debug build and flaky under load):
    // `LiveAudioMeasurements.aMinuteOfLevellingTakesMilliseconds` measures it on demand.
}

/// Percentile with the definition the leveler uses, for the tests.
private enum AudioLevels {
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
}
