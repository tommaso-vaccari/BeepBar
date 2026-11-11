import Foundation

/// Candidate "G", the keypoint leveler: a gain that follows the lecture's own speech level over
/// tens of seconds, in pure functions of the PCM (so it can move out of the test target when a
/// design is chosen). Prototype for measurement only: nothing in production uses it.
///
/// Why it exists: the dynaudnorm/speechnorm family needs an absolute threshold or a bounded
/// gain, and real lectures are recorded 20 to 62 dB apart (some are −60 dBFS) and sometimes
/// change by 20 to 35 dB inside one lecture. This one measures, then applies, a gain of up to
/// +48 dB, and leaves a normal lecture at about the level it has.
///
/// How it works: a *keypoint* every `spacing` seconds on the lecture's clock (keypoint `k` is
/// at `k × spacing`). Keypoint `k`'s gain is computed only from the `window` seconds of audio
/// before it: the `percentile` of the 400 ms RMS frames above `silenceFloor` (the audio is
/// Apple-isolated, so pauses are digital silence and "above the floor" is speech detection for
/// free), brought to `target` dBFS and clamped to `minGain...maxGain`. When fewer than
/// `minVoiced` of the window's frames are voiced, the keypoint *holds* the previous keypoint's
/// gain (a break or a silent stretch must not be lifted). The gain between two keypoints is
/// interpolated linearly in dB and applied sample by sample.
///
/// Determinism (why a piece rendered alone can equal the whole lecture): a keypoint depends on
/// audio before it only. A sample between keypoints `k` and `k + 1` needs keypoint `k + 1`, so a
/// piece needs up to `spacing` seconds of audio after itself (its *tail*), and, before itself,
/// `window` seconds before its first keypoint plus, for a hold, `spacing` per keypoint held
/// (`maxHold`): `lead = window + spacing × maxHold` for a piece that starts on a keypoint. An unbounded hold chains back for as long as
/// the silence lasts, which no bounded lead can match, so a bound (`maxHold`) trades quality
/// after a long silence (neutral gain until a voiced window) for a bounded lead. What a piece
/// cannot see is *unknown* and falls back to `neutral`, never to a guess.
struct KeypointLeveler: Sendable {
    static let rate = 48_000
    /// 400 ms, the frame the level is measured on.
    static let frameLength = 19_200
    /// The ceiling's block: its level is evaluated every 10 ms, over 40 blocks (400 ms) around it.
    static let block = 480
    static let blocksAround = 20

    var spacing = 10.0
    var window = 12.0
    var percentile = 0.90
    var target = -20.0
    var silenceFloor = -95.0
    var minGain = -6.0
    var maxGain = 48.0
    var minVoiced = 0.15
    /// Most consecutive keypoints that may hold; past it the gain is `neutral`. nil: no bound.
    var maxHold: Int?
    var neutral = 0.0
    /// The local ceiling's headroom over `target`, in dB; nil turns the ceiling off. At every
    /// instant the applied gain is at most `target + ceilingHeadroom − local level`, so a jump
    /// up of the input (a teacher who steps closer, a quiet lecture that gets loud) is not
    /// amplified by a gain that was right for the quiet part, which would drive the limiter
    /// tens of dB into reduction.
    var ceilingHeadroom: Double? = 6
    /// The local level is a 400 ms RMS centred on the instant, every 10 ms, held for the next
    /// `ceilingHold` seconds (a finite-memory release, so a piece with a lead of that much sees
    /// exactly what the whole lecture does; an IIR smoother's memory never quite ends).
    var ceilingHold = 1.0

    /// What one keypoint's window says.
    enum Measure: Equatable { case gain(Double), hold, unknown }

    /// The audio a render can see: `samples` indexed by the lecture's clock (sample 0 is the
    /// lecture's start), of which only `visible` exists for this render; everything else is
    /// unknown to it, as it is to a piece rendered alone. `end` is the lecture's length when the
    /// render knows it (a keypoint past it is not evaluated).
    struct Audio {
        var samples: [Float]
        var visible: Range<Int>
        var end: Int?
        init(_ samples: [Float], visible: Range<Int>? = nil, end: Int? = nil) {
            self.samples = samples
            self.visible = visible ?? 0..<samples.count
            self.end = end
        }
    }

    /// The gain curve over one `Audio`, evaluated on demand and cached.
    final class Curve {
        let leveler: KeypointLeveler
        let audio: Audio
        private var measures: [Int: Measure] = [:]
        private var values: [Int: Double] = [:]

        init(_ leveler: KeypointLeveler, over audio: Audio) {
            self.leveler = leveler
            self.audio = audio
        }

        private func time(of k: Int) -> Int { Int((Double(k) * leveler.spacing * Double(KeypointLeveler.rate)).rounded()) }

        func measure(_ k: Int) -> Measure {
            if let cached = measures[k] { return cached }
            let result = compute(k)
            measures[k] = result
            return result
        }

        private func compute(_ k: Int) -> Measure {
            let t = time(of: k)
            let frames = Int(leveler.window * Double(KeypointLeveler.rate)) / KeypointLeveler.frameLength
            var levels: [Double] = []
            var existing = 0
            for i in 0..<frames {
                let hi = t - i * KeypointLeveler.frameLength, lo = hi - KeypointLeveler.frameLength
                if lo < 0 { break }
                existing += 1
                guard lo >= audio.visible.lowerBound, hi <= audio.visible.upperBound else { return .unknown }
                var energy = 0.0
                audio.samples.withUnsafeBufferPointer { p in
                    for j in lo..<hi { energy += Double(p[j]) * Double(p[j]) }
                }
                levels.append(max(-120, 10 * log10(energy / Double(KeypointLeveler.frameLength) + 1e-20)))
            }
            let voiced = levels.filter { $0 > leveler.silenceFloor }
            guard existing > 0, Double(voiced.count) / Double(existing) >= leveler.minVoiced else { return .hold }
            let level = AudioTestSignals.percentile(voiced, leveler.percentile)
            return .gain(max(leveler.minGain, min(leveler.maxGain, leveler.target - level)))
        }

        /// Keypoint `k`'s gain in dB: its own measurement, or, when it holds, the gain of the
        /// nearest earlier keypoint that measured, if at most `maxHold` keypoints (itself
        /// included) held; `neutral` when the chain is too long, reaches what this render cannot
        /// see, or reaches the lecture's start.
        func keypoint(_ k: Int) -> Double {
            if let cached = values[k] { return cached }
            var j = k, held = 0
            var value = leveler.neutral
            while true {
                switch measure(j) {
                case .gain(let g):
                    if let bound = leveler.maxHold, held > bound { value = leveler.neutral } else { value = g }
                case .unknown:
                    value = leveler.neutral
                case .hold:
                    held += 1
                    if j == 0 || (leveler.maxHold.map { held > $0 } ?? false) { value = leveler.neutral } else { j -= 1; continue }
                }
                break
            }
            values[k] = value
            return value
        }

        /// The gain in dB at keypoint `k` and at the next one, as the sample positions between
        /// them need them. Past the lecture's known end the last gain is held.
        private func segment(_ k: Int) -> (t0: Int, t1: Int, g0: Double, g1: Double) {
            let t1 = time(of: k + 1)
            let g0 = keypoint(k)
            let g1 = (audio.end.map { t1 > $0 } ?? false) ? g0 : keypoint(k + 1)
            return (time(of: k), t1, g0, g1)
        }

        /// The gain in dB at sample `tau` of the lecture's clock: linear in dB between keypoints.
        func gainDB(at tau: Int) -> Double {
            let k = Int((Double(tau) / (leveler.spacing * Double(KeypointLeveler.rate))).rounded(.down))
            let s = segment(k)
            return s.g0 + (s.g1 - s.g0) * Double(tau - s.t0) / Double(s.t1 - s.t0)
        }

        /// `audio.samples[range]` with the applied gain (keypoint gain under the ceiling; float: no
        /// clipping here, the limiter downstream is the only place peaks are cut). Works in 10 ms
        /// blocks, inside which both gains are linear in dB.
        func apply(to range: Range<Int>) -> [Float] {
            var out = [Float](repeating: 0, count: range.count)
            let step = leveler.spacing * Double(KeypointLeveler.rate)
            var tau = range.lowerBound
            while tau < range.upperBound {
                let s = segment(Int((Double(tau) / step).rounded(.down)))
                let m = tau / KeypointLeveler.block
                let stop = min(range.upperBound, s.t1, (m + 1) * KeypointLeveler.block)
                let slope = (s.g1 - s.g0) / Double(s.t1 - s.t0)
                let a = ceiling(m), b = ceiling(m + 1)
                let ceilingOff = a >= 1000 || b >= 1000
                let cSlope = ceilingOff ? 0 : (b - a) / Double(KeypointLeveler.block)
                for i in tau..<stop {
                    let key = s.g0 + slope * Double(i - s.t0)
                    let cap = ceilingOff ? 1000 : a + cSlope * Double(i - m * KeypointLeveler.block)
                    out[i - range.lowerBound] = audio.samples[i] * Float(exp(min(key, cap) * 0.1151292546497023))
                }
                tau = stop
            }
            return out
        }

        // MARK: Local ceiling

        private var blockEnergies: [Int: Double] = [:]
        private var blockLevels: [Int: Double?] = [:]
        private var ceilings: [Int: Double] = [:]

        /// A 10 ms block as this render knows it: `absent` when it does not exist in the lecture
        /// (before the start, past the known end), `unknown` when it exists but this render
        /// cannot see it (outside a piece's lead and tail), else its energy (sum of squares).
        private enum Block { case absent, unknown, energy(Double) }

        private func block(_ b: Int) -> Block {
            let lo = b * KeypointLeveler.block, hi = lo + KeypointLeveler.block
            if lo < 0 || (audio.end.map { hi > $0 } ?? false) { return .absent }
            if lo < audio.visible.lowerBound || hi > audio.visible.upperBound { return .unknown }
            if let cached = blockEnergies[b] { return .energy(cached) }
            var energy = 0.0
            audio.samples.withUnsafeBufferPointer { p in for j in lo..<hi { energy += Double(p[j]) * Double(p[j]) } }
            blockEnergies[b] = energy
            return .energy(energy)
        }

        /// The 400 ms RMS level in dB centred on block boundary `m` (the instant `m × 10 ms`),
        /// over the blocks that exist; nil when one of them is unknown to this render.
        func localLevel(_ m: Int) -> Double? {
            if let cached = blockLevels[m] { return cached }
            var sum = 0.0, count = 0
            var result: Double?
            var known = true
            for b in (m - KeypointLeveler.blocksAround)..<(m + KeypointLeveler.blocksAround) {
                switch block(b) {
                case .absent: continue
                case .unknown: known = false
                case .energy(let e): sum += e; count += 1
                }
                if !known { break }
            }
            if known { result = max(-120, 10 * log10(sum / Double(max(count, 1) * KeypointLeveler.block) + 1e-20)) }
            blockLevels[m] = .some(result)
            return result
        }

        /// The held local level at instant `m × 10 ms`: the highest `localLevel` of the last
        /// `ceilingHold` seconds, nil when any of them is unknown.
        func heldLevel(_ m: Int) -> Double? {
            var top = -120.0
            for j in 0..<Int(leveler.ceilingHold * 100) {
                if m - j < -KeypointLeveler.blocksAround { break }
                guard let level = localLevel(m - j) else { return nil }
                top = max(top, level)
            }
            return top
        }

        /// The ceiling on the gain at instant `m × 10 ms`, dB; very large when it does not
        /// apply (off, silent, or this render cannot see enough to say).
        func ceiling(_ m: Int) -> Double {
            guard let headroom = leveler.ceilingHeadroom else { return 1000 }
            if let cached = ceilings[m] { return cached }
            let value = heldLevel(m).map { leveler.target + headroom - $0 } ?? 1000
            ceilings[m] = value
            return value
        }

        /// The gain actually applied at sample `tau`, dB: the keypoint gain under the ceiling,
        /// the ceiling interpolated linearly in dB between its 10 ms instants.
        func appliedGainDB(at tau: Int) -> Double {
            let m = tau / KeypointLeveler.block
            let a = ceiling(m), b = ceiling(m + 1)
            if a >= 1000 || b >= 1000 { return gainDB(at: tau) }
            return min(gainDB(at: tau), a + (b - a) * Double(tau - m * KeypointLeveler.block) / Double(KeypointLeveler.block))
        }

        /// Of the 10 ms instants in `range` that are not silent (local level above `silenceFloor`),
        /// the share where the ceiling is the lower of the two gains: how often it acts.
        func ceilingActivity(over range: Range<Int>) -> Double {
            var active = 0, voiced = 0
            for m in stride(from: range.lowerBound / KeypointLeveler.block, to: range.upperBound / KeypointLeveler.block, by: 1) {
                guard let level = localLevel(m), level > leveler.silenceFloor else { continue }
                voiced += 1
                if ceiling(m) < gainDB(at: m * KeypointLeveler.block) - 0.01 { active += 1 }
            }
            return Double(active) / Double(max(voiced, 1))
        }

        /// Keypoints `0...last` summarized: the gains' min, median, max, how many held, and the
        /// largest change between consecutive keypoints, in dB.
        func summary(through last: Int) -> (min: Double, median: Double, max: Double, holds: Int, largestStep: Double, count: Int) {
            let gains = (0...last).map(keypoint)
            let holds = (0...last).filter { measure($0) == .hold }.count
            let step = zip(gains, gains.dropFirst()).map { abs($1 - $0) }.max() ?? 0
            return (gains.min() ?? 0, AudioTestSignals.percentile(gains, 0.5), gains.max() ?? 0, holds, step, gains.count)
        }
    }

    func curve(over audio: Audio) -> Curve { Curve(self, over: audio) }

    /// The lead a piece needs before itself, in seconds, for its gain curve to equal the whole
    /// lecture's, when the piece starts on a keypoint: the window of the oldest keypoint a hold
    /// may reach (`maxHold` keypoints back) is the furthest audio read. A piece that starts
    /// between keypoints needs up to one `spacing` more. nil: unbounded.
    var requiredLead: Double? { maxHold.map { window + spacing * Double($0) } }
}
