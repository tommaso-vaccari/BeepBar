import Foundation
import Testing
import BeepbarCore

/// Production `VoiceLeveler` against the prototype (`KeypointLeveler`, the reference the design was
/// measured with), the way the live pipeline uses it: a lecture cut into segments, each leveled
/// from a clip of its own surroundings with a keypoint memo carried from segment to segment.
struct VoiceLevelerReferenceTests {
    static let rate = 48_000
    static func seconds(_ s: Double) -> Int { Int((s * Double(rate)).rounded()) }

    /// A lecture of noise bursts (1 s on, 0.3 s digital silence) in parts of (seconds, dBFS, nil
    /// for silence). Starts with speech, changes level by 25 dB and has a pause of 15 s, which
    /// is longer than the leveler's 12 s window: every kind of keypoint (measured, held through a
    /// pause) occurs.
    static func lecture(_ parts: [(Double, Double?)]) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var result: [Float] = []
        for (length, dB) in parts {
            let amplitude = Float(pow(10, (dB ?? -120) / 20) * 3.0.squareRoot())
            let period = seconds(1.3), burst = seconds(1.0)
            for i in 0..<seconds(length) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                let x = Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
                result.append(dB == nil || i % period >= burst ? 0 : x * amplitude)
            }
        }
        return result
    }

    static let parts: [(Double, Double?)] = [(40, -50), (15, nil), (60, -25), (55, -45)]
    static let whole = lecture(parts)
    /// The prototype's output on `whole`, made once for the arguments of the test that uses it.
    static let wholeReference = KeypointLeveler().curve(over: KeypointLeveler.Audio(whole, bootstrap: true)).apply(to: 0..<whole.count)

    /// One segment the way `LiveAudioPipeline.produceIsolated` makes it: a clip of the last 22 s
    /// of the previous segment (when it exists), the segment, and the first `levelTail` (20.5 s) of the next;
    /// the keypoints it covers resolved with `memo`, merged into it (existing entries win), and
    /// the segment's own samples kept.
    static func render(_ signal: [Float], from start: Int, to end: Int, memo: inout [Int: Double], withPrevious: Bool, leveler: VoiceLeveler = VoiceLeveler()) -> [Float] {
        let clipStart = withPrevious ? max(0, start - AudioEnhancement.levelLead) : start
        let clipEnd = min(signal.count, end + AudioEnhancement.levelTail)
        let clip = VoiceLeveler.Clip(samples: Array(signal[clipStart..<clipEnd]), start: clipStart)
        let resolved = leveler.gains(for: leveler.keypoints(covering: start..<end), detector: clip, known: memo)
        for (k, gain) in resolved where memo[k] == nil { memo[k] = gain }
        var handed = resolved
        for (k, gain) in memo where handed[k] == nil {
            let t = Int((Double(k) * leveler.spacing * Double(VoiceLeveler.rate)).rounded())
            if t >= clip.start && t <= clip.end { handed[k] = gain }
        }
        let out = leveler.level(clip, gains: handed)
        return Array(out[(start - clipStart)..<(end - clipStart)])
    }

    /// `render` with the session's provisional set (`VoiceLeveler.resolve`), as `produceIsolated`
    /// uses it: a provisional `neutral` stays in the memo, never recomputed, and anchors nothing.
    static func renderKeepingProvisional(_ signal: [Float], from start: Int, to end: Int, memo: inout [Int: Double], provisional: inout Set<Int>, withPrevious: Bool) -> [Float] {
        let leveler = VoiceLeveler()
        let clipStart = withPrevious ? max(0, start - AudioEnhancement.levelLead) : start
        let clipEnd = min(signal.count, end + AudioEnhancement.levelTail)
        let clip = VoiceLeveler.Clip(samples: Array(signal[clipStart..<clipEnd]), start: clipStart)
        let resolution = leveler.resolve(for: leveler.keypoints(covering: start..<end), detector: clip, known: memo, provisional: provisional)
        for (k, gain) in resolution.gains where memo[k] == nil {
            memo[k] = gain
            if resolution.provisional.contains(k) { provisional.insert(k) }
        }
        var handed = resolution.gains
        for (k, gain) in memo where handed[k] == nil {
            let t = Int((Double(k) * leveler.spacing * Double(VoiceLeveler.rate)).rounded())
            if t >= clip.start && t <= clip.end { handed[k] = gain }
        }
        let out = leveler.level(clip, gains: handed)
        return Array(out[(start - clipStart)..<(end - clipStart)])
    }

    /// A lecture recorded before it began: a long silence, then a voice at −60 dBFS. Rendered in
    /// 30 s segments with the session's memo (including provisional keypoints), the gain applied
    /// 1.8 s after the voice starts (inside its second burst) is the whole render's, +40 dB,
    /// within 1 dB; the gain at every nonsilent sample is the whole render's within 1 dB; a
    /// keypoint, once used, is never changed by a later segment; and at each segment boundary
    /// that falls inside the voice the gain just before and just after differ by less than
    /// 0.3 dB (`onset` 119 puts the 120 s boundary there). `first` is the first segment's length,
    /// the others being 30 s: 30.010667 puts every boundary a little past the 10 s keypoint grid,
    /// as Webex's do (the last keypoint a segment asks for is then a whole `spacing` past its
    /// end, and the one after it, which "unanchored" looks at, has almost none of its window in
    /// the clip unless `levelTail` leaves room for it: 130.5 s is the onset that fell there).
    /// Guards against a first segment's
    /// provisional 0 dB being held through the silence that follows, so that the first words of a
    /// quiet lecture come out up to 40 dB too low and the gain climbs during them (before the
    /// correction: about +7 dB at that instant), and against fixing that by recomputing a
    /// keypoint, which would put a step at a seam.
    @Test(arguments: [(120.0, 30.0), (119.0, 30.0), (130.5, 30.010667), (134.0, 30.010667), (137.0, 30.010667)])
    func aLongSilenceBeforeTheVoiceLevelsFromTheFirstWords(onset: Double, first: Double) {
        // The silence is zeros, not generated noise at −120 dB: a minute of samples through the
        // generator costs seconds in a debug build and the silence's values are all zero anyway.
        let lecture = [Float](repeating: 0, count: Self.seconds(onset)) + Self.lecture([(180 - onset, -60)])
        let whole = lecture
        var wholeMemo: [Int: Double] = [:]
        let reference = Self.render(whole, from: 0, to: whole.count, memo: &wholeMemo, withPrevious: false)

        var produced: [Float] = []
        var memo: [Int: Double] = [:]
        var provisional: Set<Int> = []
        var start = 0
        var boundaries: [Int] = []
        while start < whole.count {
            let end = min(whole.count, boundaries.isEmpty ? Self.seconds(first) : start + Self.seconds(30))
            boundaries.append(end)
            let before = memo
            produced += Self.renderKeepingProvisional(whole, from: start, to: end, memo: &memo, provisional: &provisional, withPrevious: start > 0)
            for (k, gain) in before { #expect(memo[k] == gain, "keypoint \(k) changed after it was used") }
            start = end
        }
        #expect(produced.count == whole.count)

        func gain(_ out: [Float], _ at: Int) -> Double { 20 * log10(Double(out[at] / whole[at])) }
        /// The nearest sample with a signal, searching in `direction`.
        func nearest(_ from: Int, _ direction: Int) -> Int {
            var i = from
            while whole[i] == 0 { i += direction }
            return i
        }
        let probe = nearest(Self.seconds(onset + 1.8), 1)
        #expect(abs(gain(reference, probe) - 40) < 1, "the whole render: \(gain(reference, probe)) dB")
        #expect(abs(gain(produced, probe) - gain(reference, probe)) < 1, "\(gain(produced, probe)) dB in segments, \(gain(reference, probe)) dB whole")

        var worst = 0.0
        for i in stride(from: Self.seconds(onset), to: whole.count, by: 97) where whole[i] != 0 {
            worst = max(worst, abs(gain(produced, i) - gain(reference, i)))
        }
        #expect(worst < 1, "largest difference from the whole render \(worst) dB")

        var checkedSeams = 0
        for seam in boundaries.dropLast() where seam > Self.seconds(onset) {
            let a = nearest(seam - 1, -1), b = nearest(seam, 1)
            #expect(abs(gain(produced, a) - gain(produced, b)) < 0.3, "step at \(seam / Self.rate) s")
            checkedSeams += 1
        }
        #expect(checkedSeams >= 1)
    }

    /// Forward play equals the whole lecture: cut into segments (30 s, and 29.7 s so their
    /// boundaries are off the 10 s keypoint grid), each rendered in order from its own clip with
    /// the carried memo, the output has the prototype's gain on every sample within 0.01 dB
    /// (the last 10 s, whose closing keypoint the prototype does not know, left out). Guards
    /// against a seam where the gain steps, a clip too short for the window (a segment's
    /// gain differing from the lecture's), a memo that is lost or ignored, a hold chain that
    /// does not reach back across a pause, and the ceiling differing at a clip's edges.
    @Test(arguments: [30.0, 29.7]) func forwardPlayEqualsTheWholeLecture(segment: Double) {
        let whole = Self.whole
        #expect(whole.count >= Self.seconds(150))
        let reference = Self.wholeReference

        var produced: [Float] = []
        var memo: [Int: Double] = [:]
        var start = 0
        let length = Self.seconds(segment)
        while start < whole.count {
            let end = min(whole.count, start + length)
            produced += Self.render(whole, from: start, to: end, memo: &memo, withPrevious: start > 0)
            start = end
        }
        #expect(produced.count == whole.count)
        var worst = 0.0, checked = 0
        for i in 0..<(whole.count - Self.seconds(10)) where abs(reference[i]) > 1e-6 {
            checked += 1
            worst = max(worst, abs(20 * log10(Double(produced[i] / reference[i]))))
        }
        #expect(checked > Self.seconds(60), "the comparison must cover speech, not silence")
        #expect(worst < 0.01, "largest gain difference \(worst) dB")
    }

    /// A seek: segment 3 rendered first with no memory and no previous segment, then segment 2
    /// with what segment 3 used. The gain applied to the last sample of 2 and to the first of 3
    /// differs by less than 0.05 dB (the keypoint on their seam is the memo's), and rendering
    /// segment 3 again, now with its previous segment and the memo, gives exactly the samples it
    /// gave the first time. Guards against a seam that steps after a seek (the first thing a
    /// student does with a lecture is to jump to a point in it) and against a memo that is
    /// recomputed from the audio a later render sees.
    @Test func aSeekLeavesNoStepAtTheSeamAndTheMemoSticks() {
        let whole = Self.whole
        let segment = Self.seconds(30)
        var memo: [Int: Double] = [:]
        let third = Self.render(whole, from: 3 * segment, to: 4 * segment, memo: &memo, withPrevious: false)
        let usedBefore = memo
        #expect(!usedBefore.isEmpty)
        let second = Self.render(whole, from: 2 * segment, to: 3 * segment, memo: &memo, withPrevious: true)
        for (k, gain) in usedBefore { #expect(memo[k] == gain, "keypoint \(k) was recomputed") }

        func applied(_ out: [Float], _ at: Int, _ offset: Int) -> Double {
            // The nearest sample that is not silence, in the direction of the seam's other side.
            var i = at
            while out[i] == 0 { i += offset }
            return 20 * log10(Double(out[i] / whole[(offset > 0 ? 3 * segment : 2 * segment) + i]))
        }
        let before = applied(second, second.count - 1, -1), after = applied(third, 0, 1)
        #expect(abs(before - after) < 0.05, "gain \(before) dB before the seam, \(after) dB after")

        let again = Self.render(whole, from: 3 * segment, to: 4 * segment, memo: &memo, withPrevious: true)
        #expect(again == third, "the same keypoints, the same samples")
    }
}
