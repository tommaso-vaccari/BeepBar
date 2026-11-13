import Foundation

/// The keypoint leveler: a gain that follows a lecture's own speech level over tens of seconds,
/// as pure functions of PCM samples (no I/O), so a lecture played in 30-second segments gets the
/// same gain curve it would get rendered whole.
///
/// Why it exists: lectures are recorded 20 to 62 dB apart (some at −60 dBFS) and the level
/// changes by 20 to 35 dB inside one lecture (a teacher stepping closer, a microphone turned
/// up). `speechnorm` plus `agate` after Apple's voice isolation cut the ends of words and could
/// not lift a −60 dBFS lecture. This one measures, then applies, a gain of up to +48 dB, and
/// leaves a lecture that is already at a normal level at about the level it has. What follows it
/// in the encode (EQ, a gentle compressor and the limiter) is `AudioEnhancement.levelledChain`.
///
/// How it works: a *keypoint* every `spacing` seconds on the lecture's clock (keypoint `k` is at
/// sample `round(k × spacing × rate)`, sample 0 being the lecture's start). Keypoint `k`'s gain
/// is computed from the `window` seconds of audio before it: the `percentile` of the 400 ms RMS
/// frames above `silenceFloor` (Apple's isolation leaves pauses digitally silent, so "above the
/// floor" is speech detection for free), brought to `target` dBFS and clamped to
/// `minGain...maxGain`. The gain between two keypoints is interpolated linearly in dB, and then
/// capped by a local ceiling (`level`).
///
/// A render sees only a `Clip` of the lecture, never all of it. So that clips cut anywhere give
/// one curve, every rule below picks a value from what the clip contains, and the caller keeps
/// the values it has used (`known`):
/// - **A known keypoint is never recomputed.** Two segments that share a keypoint then render
///   the same gain on both sides of their seam, by construction, even if a seek made the second
///   one see different audio than the first.
/// - A keypoint is measured on the frames that exist: those inside the clip and the lecture. A
///   window that is only partly there (after a seek, the clip starts less than `window` before
///   the keypoint) is measured on what is there when at least `minFrames` frames remain. With
///   fewer, the window looks *forward* from the clip's first sample instead (the audio the
///   render has is the audio after it), so the gain is right from the first sample and not
///   neutral. With fewer than `minFrames` there too, the keypoint is unmeasurable.
/// - A keypoint that is mostly silence (fewer than `minVoiced` of its frames voiced) *holds*:
///   it takes the previous keypoint's gain. A break must not be lifted into noise. The hold is
///   resolved recursively by the same rules (known first, then measured), for as long as the
///   previous keypoint exists and is known or measurable.
/// - When that chain ends at something neither known nor measurable (a clip that starts in
///   silence with no memory, or the lecture's start), it is *unanchored*: the keypoint takes the
///   first keypoint after it that measures a gain, up to one `spacing` past the clip's end
///   (silence in front of speech is then leveled for the speech after it, which is what the
///   listener will hear next); failing that the `known` gain nearest in index; failing that
///   `neutral` (0 dB: the audio as it is, never a guess).
public struct VoiceLeveler: Sendable {
    public static let rate = 48_000
    /// 400 ms, the frame the level is measured on.
    public static let frameLength = 19_200
    /// The ceiling's block: its level is evaluated every 10 ms, over 40 blocks (400 ms) around it.
    public static let block = 480
    public static let blocksAround = 20
    /// Fewest frames a window may have and still be measured.
    public static let minFrames = 8

    public var spacing = 10.0
    public var window = 12.0
    public var percentile = 0.90
    public var target = -20.0
    public var silenceFloor = -95.0
    public var minGain = -6.0
    public var maxGain = 48.0
    public var minVoiced = 0.15
    public var neutral = 0.0
    /// The local ceiling's headroom over `target`, in dB. At every instant the applied gain is at
    /// most `target + ceilingHeadroom − local level`, so a jump up of the input (a teacher who
    /// steps closer, a quiet lecture that gets loud) is not amplified by a gain that was right
    /// for the quiet part, which would drive the limiter tens of dB into reduction.
    public var ceilingHeadroom = 6.0
    /// The local level is a 400 ms RMS centred on the instant, every 10 ms, held for the next
    /// `ceilingHold` seconds (a finite-memory release, so a render with a lead of that much sees
    /// exactly what the whole lecture does; an IIR smoother's memory never quite ends).
    public var ceilingHold = 1.0

    public init() {}

    /// Mono float samples on the lecture's clock: `samples[0]` is at lecture sample `start`.
    public struct Clip: Sendable {
        public var samples: [Float]
        public var start: Int
        public init(samples: [Float], start: Int) {
            self.samples = samples
            self.start = start
        }
        /// One past the last sample's position.
        public var end: Int { start + samples.count }
    }

    /// Samples between keypoints.
    private var step: Double { spacing * Double(Self.rate) }
    /// Keypoint `k`'s position on the lecture's clock.
    private func time(of k: Int) -> Int { Int((Double(k) * step).rounded()) }
    private func keypoint(containing sample: Int) -> Int { Int((Double(sample) / step).rounded(.down)) }

    // MARK: Keypoints

    /// The keypoints a render of `span` needs: the one at or before its first sample to the one at
    /// or after its last, since a sample between two keypoints needs both.
    public func keypoints(covering span: Range<Int>) -> ClosedRange<Int> {
        let first = Int((Double(span.lowerBound) / step).rounded(.down))
        let last = Int((Double(span.upperBound) / step).rounded(.up))
        return first...max(first, last)
    }

    /// What one keypoint's window says.
    private enum Measure { case gain(Double), hold, unmeasurable }

    /// The gain in dB of each of `keypoints`, one value per keypoint, resolved by the rules in the
    /// type's documentation. `detector` is the audio the level is read from (for the isolated
    /// mode, the signal itself); `known` holds the keypoints already used, which are returned as
    /// they are. Keypoints measured on the way along a hold chain are not returned: the caller
    /// stores only what it asked for, and so only what it will have used.
    public func gains(for keypoints: ClosedRange<Int>, detector: Clip, known: [Int: Double]) -> [Int: Double] {
        var measures: [Int: Measure] = [:]
        func measure(_ k: Int) -> Measure {
            if let cached = measures[k] { return cached }
            let result = self.measure(k, in: detector)
            measures[k] = result
            return result
        }
        func usable(_ k: Int) -> Bool {
            if known[k] != nil { return true }
            if case .unmeasurable = measure(k) { return false }
            return true
        }
        // Where a keypoint's own value cannot be had: see "unanchored" in the type's docs.
        func unanchored(_ k: Int) -> Double {
            var j = k + 1
            while time(of: j) <= detector.end + Int(step.rounded()) {
                if case .gain(let g) = measure(j) { return g }
                j += 1
            }
            // The nearest index, the earlier one on a tie (a gain already in use that came
            // before this one is what the listener heard last).
            if let nearest = known.keys.min(by: { (abs($0 - k), $0) < (abs($1 - k), $1) }) { return known[nearest]! }
            return neutral
        }
        func value(_ k: Int) -> Double {
            var j = k
            while true {
                if let fixed = known[j] { return fixed }
                if case .gain(let g) = measure(j) { return g }
                // Hold or unmeasurable: the previous keypoint's value, when there is one to use.
                guard j > 0, usable(j - 1) else { return unanchored(k) }
                j -= 1
            }
        }
        var result: [Int: Double] = [:]
        for k in keypoints { result[k] = value(k) }
        return result
    }

    /// Keypoint `k`'s window on `clip`: the 30 frames ending at its position, or the 30 after the
    /// clip's first sample (see the type's docs). Frame `i` is `[t − (i+1)F, t − iF)`.
    private func measure(_ k: Int, in clip: Clip) -> Measure {
        let frame = Self.frameLength
        let frames = Int(window * Double(Self.rate)) / frame
        let t = time(of: k)
        let earliest = max(0, clip.start), latest = clip.end
        var starts: [Int] = []
        for i in 0..<frames {
            let hi = t - i * frame, lo = hi - frame
            if lo < earliest { break }
            if hi > latest { continue }
            starts.append(lo)
        }
        if starts.count < Self.minFrames {
            starts = []
            for j in 0..<frames {
                let lo = clip.start + j * frame
                if lo < 0 { continue }
                if lo + frame > latest { break }
                starts.append(lo)
            }
            if starts.count < Self.minFrames { return .unmeasurable }
        }
        var voiced: [Double] = []
        clip.samples.withUnsafeBufferPointer { p in
            for lo in starts {
                let energy = Self.energy(p, from: lo - clip.start, count: frame)
                let level = max(-120, 10 * log10(energy / Double(frame) + 1e-20))
                if level > silenceFloor { voiced.append(level) }
            }
        }
        guard Double(voiced.count) / Double(starts.count) >= minVoiced else { return .hold }
        return .gain(max(minGain, min(maxGain, target - Self.percentile(voiced, percentile))))
    }

    /// The sum of squares of `count` samples from `from`. A `while` loop on purpose: it visits
    /// every sample of a minute of audio, and a `for` over a range costs ten times as much in a
    /// debug build, which is what the tests run (see the pipeline tests).
    private static func energy(_ p: UnsafeBufferPointer<Float>, from: Int, count: Int) -> Double {
        var energy = 0.0
        var j = from
        let end = from + count
        while j < end {
            let x = Double(p[j])
            energy += x * x
            j += 1
        }
        return energy
    }

    /// Linear-interpolated percentile of `values`, `p` in 0...1 (the definition the prototype was
    /// measured with: position `p × (n − 1)` between the two nearest ranks).
    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    // MARK: Applying

    /// `signal` with the gain applied, as floats (no clipping here: the limiter downstream is the
    /// only place peaks are cut). The gain at a sample is linear in dB between the keypoints
    /// around it, from `gains`; a keypoint `gains` lacks takes the value of the nearest one it
    /// has, so the audio before and after the resolved range holds the edge value (a clip has
    /// pre- and post-roll that its segment's own keypoints do not reach). No keypoints at all:
    /// `neutral`.
    ///
    /// Then the local ceiling: the applied gain is at most `target + ceilingHeadroom − heldLevel`,
    /// `heldLevel` being the highest 400 ms RMS (centred, evaluated every 10 ms) of the last
    /// `ceilingHold` seconds, the ceiling interpolated linearly in dB inside each 10 ms block.
    /// It is computed on `signal` itself, and blocks that are not entirely inside the clip are
    /// simply absent from an RMS, so it works from the clip's first sample and never turns off.
    ///
    /// Efficient on purpose: block energies are computed once into arrays and the ceiling once
    /// per 10 ms, so a 62-second clip levels in a few dozen milliseconds in a release build.
    public func level(_ signal: Clip, gains: [Int: Double]) -> [Float] {
        let n = signal.samples.count
        guard n > 0 else { return [] }
        let block = Self.block
        let keys = gains.keys.sorted()
        func gain(at k: Int) -> Double {
            if let exact = gains[k] { return exact }
            guard !keys.isEmpty else { return neutral }
            // Nearest present keypoint, the earlier one on a tie.
            var lo = 0, hi = keys.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if keys[mid] < k { lo = mid + 1 } else { hi = mid }
            }
            if lo == 0 { return gains[keys[0]]! }
            if lo == keys.count { return gains[keys[lo - 1]]! }
            return gains[k - keys[lo - 1] <= keys[lo] - k ? keys[lo - 1] : keys[lo]]!
        }

        // Block energies of the blocks wholly inside the clip, index b - firstBlock.
        func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
        let firstBlock = max(0, -floorDiv(-signal.start, block)), endBlock = floorDiv(signal.end, block)
        var energies = [Double](repeating: 0, count: max(0, endBlock - firstBlock))
        signal.samples.withUnsafeBufferPointer { p in
            for b in firstBlock..<max(firstBlock, endBlock) {
                let from = b * block - signal.start
                energies[b - firstBlock] = Self.energy(p, from: from, count: block)
            }
        }
        func localLevel(_ m: Int) -> Double {
            let lo = max(m - Self.blocksAround, firstBlock), hi = min(m + Self.blocksAround, endBlock)
            var sum = 0.0
            if hi > lo { for b in lo..<hi { sum += energies[b - firstBlock] } }
            return max(-120, 10 * log10(sum / Double(max(hi - lo, 1) * block) + 1e-20))
        }
        // Held level and ceiling at every 10 ms instant the clip touches (the instant after its
        // last sample's block too: the ceiling is interpolated up to it).
        let held = Int(ceilingHold * 100)
        let firstInstant = floorDiv(signal.start, block), lastInstant = floorDiv(signal.end - 1, block) + 1
        let levels = (firstInstant - held + 1...lastInstant).map(localLevel)
        var ceilings = [Double](repeating: 0, count: lastInstant - firstInstant + 1)
        for m in firstInstant...lastInstant {
            var top = -120.0
            let at = m - (firstInstant - held + 1)
            var j = 0
            while j < held { top = max(top, levels[at - j]); j += 1 }
            ceilings[m - firstInstant] = target + ceilingHeadroom - top
        }

        var out = [Float](repeating: 0, count: n)
        let decibelsToNeper = 0.1151292546497023
        signal.samples.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                var tau = signal.start
                while tau < signal.end {
                    let k = keypoint(containing: tau)
                    let t0 = time(of: k), t1 = time(of: k + 1)
                    let g0 = gain(at: k), g1 = gain(at: k + 1)
                    let m = floorDiv(tau, block)
                    let stop = min(signal.end, t1, (m + 1) * block)
                    let slope = (g1 - g0) / Double(t1 - t0)
                    let a = ceilings[m - firstInstant], b = ceilings[m + 1 - firstInstant]
                    let ceilingSlope = (b - a) / Double(block)
                    // A `while` loop (`for` over a range costs ten times as much in a debug build).
                    var i = tau
                    while i < stop {
                        // Digital silence (what isolation leaves in pauses) stays silence: no gain
                        // to compute, and a pause is a large share of a lecture.
                        let x = input[i - signal.start]
                        if x != 0 {
                            let key = g0 + slope * Double(i - t0)
                            let cap = a + ceilingSlope * Double(i - m * block)
                            output[i - signal.start] = x * Float(exp(min(key, cap) * decibelsToNeper))
                        }
                        i += 1
                    }
                    tau = stop
                }
            }
        }
        return out
    }
}
