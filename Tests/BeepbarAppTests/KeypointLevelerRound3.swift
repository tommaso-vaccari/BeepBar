import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

private let rate = AudioTestSignals.sampleRate
private func f(_ x: Double, _ digits: Int = 1) -> String { AudioQualityMeasurements.f(x, digits) }

/// Round 3 of the keypoint leveler measurements (same on-demand gate and variables as
/// `KeypointLevelerMeasurements`, local recordings only, never printed by name):
/// - `cleanup`: hiss cleanup placed after the leveler and before the compressor, measured on the
///   residue between words and in pauses, on speech level and on word endings;
/// - `limiterLoad`: compressor variants, with the limiter's reduction as a distribution;
/// - `pieces`: a gain curve per 30 s piece with history from the previous piece, or bootstrapped
///   without any, against the whole-file curve, and the step at a seam;
/// - `fallback`: the ffmpeg-only chain (no Swift leveler);
/// - `listening`: the A/B set `<n>-<label>__original-loud|current|new-r2|new-r3.wav`.
extension KeypointLevelerMeasurements {
    // MARK: Cleanup variants

    /// The cleanup placed between the leveler and the compressor, by name. `nf` is the noise
    /// floor `afftdn` is told, from the residue measured on the leveled audio of that excerpt.
    static func cleanupChain(_ name: String, nf: Double) -> String? {
        func spectral(_ nr: Int) -> String { String(format: "afftdn=nr=%d:nf=%.0f:tn=1", nr, nf) }
        func expander(_ range: String) -> String { "agate=threshold=0.0126:ratio=2:range=\(range):attack=5:release=400:knee=8:detection=rms" }
        switch name {
        case "none": return nil
        case "H1-nr8": return spectral(8)
        case "H1-nr12": return spectral(12)
        case "H1-nr18": return spectral(18)
        case "H2": return expander("0.25")
        case "H2-r04": return expander("0.4")
        case "H3": return spectral(12) + "," + expander("0.4")
        // Round 3b: the specified variants hardly moved the residue, so these probe why. `F`: the
        // spectral cleanup with a fixed floor (no tracking) and a deeper reduction; `L`: the
        // expander with its threshold just above the measured residue (nf + 8 dB) and a deeper range.
        case "F-nr20": return String(format: "afftdn=nr=20:nf=%.0f:tn=0", nf)
        case "F-nr35": return String(format: "afftdn=nr=35:nf=%.0f:tn=0", nf)
        case "L-r01": return String(format: "agate=threshold=%.5f:ratio=4:range=0.1:attack=5:release=250:knee=4:detection=rms", pow(10, (nf + 8) / 20))
        case "L-r003": return String(format: "agate=threshold=%.5f:ratio=6:range=0.03:attack=5:release=250:knee=4:detection=rms", pow(10, (nf + 8) / 20))
        case "FL": return String(format: "afftdn=nr=20:nf=%.0f:tn=0,", nf) + String(format: "agate=threshold=%.5f:ratio=4:range=0.1:attack=5:release=250:knee=4:detection=rms", pow(10, (nf + 8) / 20))
        default: return nil
        }
    }

    static let cleanupNames = ["none", "H1-nr8", "H1-nr12", "H1-nr18", "H2", "H2-r04", "H3", "F-nr20", "F-nr35", "L-r01", "L-r003", "FL"]

    /// Compressors after the leveler for `limiterLoad`: the round-2 one and the faster ones.
    static let compressors3: [(String, Compressor)] = [
        ("K7", chosen),
        ("K9", Compressor(threshold: 0.08, ratio: 3, makeup: 3.8, attack: 2)),
        ("K10", Compressor(threshold: 0.063, ratio: 4, makeup: 3.5, attack: 1)),
        ("K11", Compressor(threshold: 0.08, ratio: 3, makeup: 3.8, attack: 1, release: 100, knee: 6)),
        ("K12", Compressor(threshold: 0.05, ratio: 5, makeup: 4.5, attack: 1, release: 150, knee: 6)),
        ("K13", Compressor(threshold: 0.08, ratio: 3, makeup: 3.8, attack: 25)),
        ("K14", Compressor(threshold: 0.08, ratio: 3, makeup: 3.0, attack: 25)),
        // Ratio 2 rows aimed at lifting low-level material less: their makeup is a placeholder,
        // `limiterLoad` calibrates it per excerpt so the integrated level matches K7's (±0.5 LU).
        ("R2-a10", Compressor(threshold: 0.08, ratio: 2, makeup: 3.8, attack: 10)),
        ("R2-a25", Compressor(threshold: 0.08, ratio: 2, makeup: 3.8, attack: 25)),
        // K11 and K9 with the makeup raised to reach K7's loudness (fixed makeup: the "R2" calibration does not apply).
        ("K15", Compressor(threshold: 0.08, ratio: 3, makeup: 4.26, attack: 1, release: 100, knee: 6)),   // K11 +1.0 dB
        ("K16", Compressor(threshold: 0.08, ratio: 3, makeup: 4.26, attack: 2)),                           // K9 +1.0 dB
        ("K17", Compressor(threshold: 0.08, ratio: 3, makeup: 4.52, attack: 1, release: 100, knee: 6)),   // K11 +1.5 dB
    ]

    /// The share of 50 ms frames of `x` between −50 and −30 dBFS, in percent: how much low-level
    /// material the chain left in (or lifted into) that band.
    static func lowBandShare(_ x: [Float]) -> Double {
        let levels = AudioTestSignals.frameLevels(x, frame: rate / 20, in: 0..<x.count)
        guard !levels.isEmpty else { return 0 }
        return 100 * Double(levels.filter { $0 >= -50 && $0 < -30 }.count) / Double(levels.count)
    }

    // MARK: Residue metric

    /// Where the residue between words and the pauses are, from the isolator's own output
    /// (`isolated`), read in `output`, in 20 ms frames:
    /// - speech frames: isolated level within 30 dB of the isolated 90th percentile of its active
    ///   frames (active: above −100 dBFS, the rest is the isolator's digital silence);
    /// - voiced regions: speech frames joined across gaps of at most 300 ms;
    /// - `p10`: the 10th percentile of `output`'s frames inside voiced regions (the coordinator's
    ///   "between-word" level; digital silence inside a region reads as −120);
    /// - `between`: the median of `output`'s active non-speech frames inside voiced regions;
    /// - `pause`: the RMS level of `output` over the active frames outside the regions (pauses
    ///   longer than 300 ms that are not digital silence), and `pauseSilent` the share of the
    ///   pause frames that are digital silence;
    /// - `speech`: `output`'s 400 ms 90th percentile.
    struct Residue {
        var speech = Double.nan, p10 = Double.nan, between = Double.nan, pause = Double.nan, pauseSilent = Double.nan
    }

    static func residue(isolated: [Float], output: [Float]) -> Residue {
        let small = rate / 50
        let count = min(isolated.count, output.count)
        let a = AudioTestSignals.frameLevels(Array(isolated[0..<count]), frame: small, in: 0..<count)
        let b = AudioTestSignals.frameLevels(Array(output[0..<count]), frame: small, in: 0..<count)
        let top = AudioTestSignals.percentile(a.filter { $0 > -100 }, 0.9)
        let speech = a.map { $0 > -100 && $0 >= top - 30 }
        var inRegion = [Bool](repeating: false, count: a.count)
        var last: Int?
        for i in a.indices where speech[i] {
            if let l = last, i - l <= 15 { for j in l...i { inRegion[j] = true } } else { inRegion[i] = true }
            last = i
        }
        var r = Residue()
        r.speech = AudioTestSignals.percentile(frames(Array(output[0..<count])), 0.9)
        r.p10 = AudioTestSignals.percentile(a.indices.filter { inRegion[$0] }.map { b[$0] }, 0.1)
        r.between = AudioTestSignals.percentile(a.indices.filter { inRegion[$0] && !speech[$0] && a[$0] > -100 }.map { b[$0] }, 0.5)
        let pauseActive = a.indices.filter { !inRegion[$0] && a[$0] > -100 }
        let pauseAll = a.indices.filter { !inRegion[$0] }
        if !pauseActive.isEmpty {
            r.pause = 10 * log10(pauseActive.map { pow(10, b[$0] / 10) }.reduce(0, +) / Double(pauseActive.count) + 1e-20)
        }
        r.pauseSilent = Double(pauseAll.count - pauseActive.count) / Double(max(pauseAll.count, 1))
        return r
    }

    /// The ending metric of `output` against `reference` as numbers: median and worst 10%, and
    /// how many endings were found.
    static func endings(_ reference: [Float], _ output: [Float], path: Path) throws -> (median: Double, worst: Double, count: Int) {
        let line = try Measurements.excerptMetrics("", input: reference, output: output, path: path)
        let pattern = try NSRegularExpression(pattern: #"median (-?[0-9.]+) worst10% (-?[0-9.]+) over ([0-9]+) ends"#)
        guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let a = Range(m.range(at: 1), in: line), let b = Range(m.range(at: 2), in: line), let c = Range(m.range(at: 3), in: line)
        else { return (.nan, .nan, 0) }
        return (Double(line[a]) ?? .nan, Double(line[b]) ?? .nan, Int(line[c]) ?? 0)
    }

    /// The leveler's output over the isolated audio, the reference "isolation + leveler only".
    static func leveled(_ isolated: [Float], _ leveler: KeypointLeveler = KeypointLeveler()) -> [Float] {
        leveler.curve(over: .init(isolated)).apply(to: 0..<isolated.count)
    }

    /// The noise floor to tell `afftdn`: the median residue of the leveled audio, rounded, within
    /// the filter's range (−80 to −20 dB); −45 when there is no residue to measure.
    static func noiseFloor(isolated: [Float], leveled: [Float]) -> Double {
        let r = residue(isolated: isolated, output: leveled).between
        return r.isNaN ? -45 : max(-80, min(-20, r.rounded()))
    }

    /// The limiter's reduction as a distribution, over 10 ms frames whose unlimited peak is above
    /// −60 dBFS: median, 99th percentile and maximum, dB (0 where it did not act).
    static func limiterReduction(_ r: Rendering) -> (p50: Double, p99: Double, max: Double) {
        let frame = rate / 100
        var values: [Double] = []
        var i = 0
        let count = min(r.output.count, r.unlimited.count)
        while i + frame <= count {
            let before = r.unlimited[i..<(i + frame)].reduce(0) { max($0, abs($1)) }
            if before > 0.001 {
                let after = r.output[i..<(i + frame)].reduce(0) { max($0, abs($1)) }
                values.append(before > 0.8 ? 20 * log10(Double(before) / Double(max(after, 1e-9))) : 0)
            }
            i += frame
        }
        return (AudioTestSignals.percentile(values, 0.5), AudioTestSignals.percentile(values, 0.99), values.max() ?? 0)
    }

    /// `leveled` through `cleanup`, the equalizers, `compressor` and the limiter, and the same
    /// without the limiter.
    static func finish(_ leveled: [Float], cleanup: String?, compressor: Compressor, path: Path) throws -> Rendering {
        let chain = ([cleanup, Measurements.prefix, compressor.chain].compactMap { $0 }).joined(separator: ",")
        return Rendering(output: try run(leveled, chain: chain + "," + Measurements.limiter, in: path), unlimited: try run(leveled, chain: chain, in: path))
    }

    // MARK: A: cleanup

    /// For each excerpt and cleanup (`cleanupNames`): speech level out, residue between words
    /// (p10 and median) and in pauses, the speech-to-residue distances, integrated loudness and
    /// range, and the ending metric against "isolation + leveler only". The acceptance asked for:
    /// residue at least 40 dB under the speech on the quiet excerpts, endings no more than 3 dB
    /// worse than the leveler alone (`dEnd`, against the `none` row, which isolates the cleanup's
    /// own cost from the compressor's), speech level within 1 dB on the normal ones (`dSpeech`).
    @Test func cleanup() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        for (i, file) in files.enumerated() {
            let n = i + 1
            let isolated = try await Self.material(n, file, path: path).isolated
            let leveled = Self.leveled(isolated)
            let nf = Self.noiseFloor(isolated: isolated, leveled: leveled)
            let results = try Self.parallel(Self.cleanupNames.count) { k -> (Rendering, Residue, (median: Double, worst: Double, count: Int), (lufs: Double, lra: Double)) in
                let r = try Self.finish(leveled, cleanup: Self.cleanupChain(Self.cleanupNames[k], nf: nf), compressor: Self.chosen, path: path)
                return (r, Self.residue(isolated: isolated, output: r.output), try Self.endings(leveled, r.output, path: path), try Measurements.loudness(r.output, in: path))
            }
            let base = results[0]
            let only = Self.residue(isolated: isolated, output: leveled)
            print("CLEAN \(n) | nf used \(f(nf, 0)) dBFS | leveler only: speech \(f(only.speech)), between-word median \(f(only.between)), pause \(f(only.pause))")
            for (name, r) in zip(Self.cleanupNames, results) {
                print("CLEAN \(n) | \(name) | speech \(f(r.1.speech)) (\(f(r.1.speech - base.1.speech)) vs none) | between-word p10 \(f(r.1.p10)), median \(f(r.1.between)) => \(f(r.1.speech - r.1.between)) dB under | pause \(f(r.1.pause)) => \(f(r.1.speech - r.1.pause)) dB under, \(f(r.1.pauseSilent * 100, 0))% of pause frames silent | \(f(r.3.lufs)) LUFS / \(f(r.3.lra)) LU | endings vs leveler-only median \(f(r.2.median)) worst10% \(f(r.2.worst)) over \(r.2.count) (dEnd \(f(r.2.median - base.2.median)) / \(f(r.2.worst - base.2.worst)))")
            }
        }
    }

    // MARK: B: limiter load

    /// `compressors3` after G with the cleanup named by `BEEPBAR_AUDIO_LEVELER_CLEANUP` (default
    /// `none`): the limiter's reduction p50/p99/max, loudness and range. Asked for: p99 at most
    /// 3 dB with the loudness still in −18..−16 LUFS.
    @Test func limiterLoad() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let cleanup = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_LEVELER_CLEANUP"] ?? "none"
        let path = try Path()
        defer { path.remove() }
        for (i, file) in files.enumerated() {
            let n = i + 1
            let isolated = try await Self.material(n, file, path: path).isolated
            let leveled = Self.leveled(isolated)
            let nf = Self.noiseFloor(isolated: isolated, leveled: leveled)
            let reference = try Measurements.loudness(try Self.finish(leveled, cleanup: nil, compressor: Self.chosen, path: path).output, in: path).lufs
            let rows = try Self.parallel(Self.compressors3.count) { k -> String in
                var compressor = Self.compressors3[k].1
                if Self.compressors3[k].0.hasPrefix("R2") {
                    // Secant steps on the makeup (linear gain) until within 0.2 LU of K7's level.
                    for _ in 0..<4 {
                        let lufs = try Measurements.loudness(try Self.finish(leveled, cleanup: nil, compressor: compressor, path: path).output, in: path).lufs
                        if abs(lufs - reference) < 0.2 { break }
                        compressor.makeup *= pow(10, (reference - lufs) / 20)
                    }
                }
                let r = try Self.finish(leveled, cleanup: Self.cleanupChain(cleanup, nf: nf), compressor: compressor, path: path)
                let loud = try Measurements.loudness(r.output, in: path)
                let l = Self.limiterReduction(r)
                return "LOAD \(n) | \(cleanup) + \(Self.compressors3[k].0) (makeup \(f(compressor.makeup, 2))) | limiter p50 \(f(l.p50)) p99 \(f(l.p99)) max \(f(l.max)) dB | \(f(loud.lufs)) LUFS / \(f(loud.lra)) LU | frames -50..-30 dBFS \(f(Self.lowBandShare(r.output)))%"
            }
            rows.forEach { print($0) }
        }
    }

    // MARK: C: pieces

    /// The gain of a bootstrapped piece for its first `ramp` samples, eased from `previous`, the
    /// final gain of the piece before it, to the piece's own curve (`own`) so the seam has no
    /// step: `i` is the sample's index in the piece.
    static func rampedGain(own: Double, previous: Double, index i: Int, ramp: Int) -> Double {
        guard i < ramp else { return own }
        let w = Double(i) / Double(ramp)
        return previous * (1 - w) + own * w
    }

    /// A piece `[start, start + 30 s)` of `samples` (indexed by the lecture's clock) as the player
    /// would render it: `history` seconds of the previous piece's isolated audio before it
    /// (`history` 0: no history, bootstrapped).
    static func pieceCurve(_ leveler: KeypointLeveler, samples: [Float], start: Int, history: Double) -> KeypointLeveler.Curve {
        let lower = max(0, start - Int(history * Double(rate)))
        return leveler.curve(over: .init(samples, visible: lower..<min(samples.count, start + 30 * rate), end: samples.count, bootstrap: history == 0))
    }

    static func gainErrors(_ a: KeypointLeveler.Curve, _ b: KeypointLeveler.Curve, over range: Range<Int>) -> (mean: Double, p95: Double, max: Double) {
        let errors = stride(from: range.lowerBound, to: range.upperBound, by: rate / 100).map { abs(a.gainDB(at: $0) - b.gainDB(at: $0)) }
        return (AudioTestSignals.mean(errors), AudioTestSignals.percentile(errors, 0.95), errors.max() ?? 0)
    }

    /// (1) A piece's keypoint gain against the whole-file render's, over the 30 s of the piece, at
    /// offsets 30, 90 and 150 s of each excerpt: bootstrapped (no history) and with 12 s and 30 s
    /// of history (the previous piece's isolated audio), for the unbounded hold and for
    /// `maxHold` 0 and 1 (`requiredLead` 12 s and 22 s). (2) The step at the seam when a
    /// bootstrapped piece N is reached from a freshly rendered, bootstrapped piece N−1 (backward
    /// seek): |first gain of N − last gain of N−1| over every seam at 30...150 s, max and p95;
    /// and the same with the first 2 s of N eased from N−1's last gain: the largest deviation
    /// from the whole-file gain there and the steepest slope.
    @Test func pieces() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        var steps: [Double] = [], rampDeviations: [Double] = [], plainDeviations: [Double] = [], slopes: [Double] = []
        for (i, file) in files.enumerated() {
            let n = i + 1
            let samples = try await Self.material(n, file, path: path).isolated
            let whole = KeypointLeveler().curve(over: .init(samples, end: samples.count))
            for offset in [30, 90, 150] {
                let start = offset * rate
                var row = "PIECE \(n) | piece at \(offset) s"
                let boot = Self.pieceCurve(KeypointLeveler(), samples: samples, start: start, history: 0)
                let e = Self.gainErrors(boot, whole, over: start..<(start + 30 * rate))
                let head = Self.gainErrors(boot, whole, over: start..<(start + 10 * rate))
                row += " | bootstrap over 30 s mean \(f(e.mean, 2)) p95 \(f(e.p95, 2)) max \(f(e.max, 2)) dB (first 10 s max \(f(head.max, 2)))"
                for (bound, history) in [(nil, 12.0), (nil, 30.0), (0, 12.0), (1, 30.0)] as [(Int?, Double)] {
                    var leveler = KeypointLeveler()
                    leveler.maxHold = bound
                    let wholeBound = leveler.curve(over: .init(samples, end: samples.count))
                    let piece = Self.pieceCurve(leveler, samples: samples, start: start, history: history)
                    row += " | history \(f(history, 0)) s, maxHold \(bound.map(String.init) ?? "none"): max \(f(Self.gainErrors(piece, wholeBound, over: start..<(start + 30 * rate)).max, 2))"
                }
                print(row)
            }
            for seam in [30, 60, 90, 120, 150] {
                let s = seam * rate
                let previous = Self.pieceCurve(KeypointLeveler(), samples: samples, start: s - 30 * rate, history: 0)
                let next = Self.pieceCurve(KeypointLeveler(), samples: samples, start: s, history: 0)
                let last = previous.gainDB(at: s - 1)
                steps.append(abs(next.gainDB(at: s) - last))
                let ramp = 2 * rate
                var worst = 0.0, plain = 0.0, slope = 0.0, before = last
                for k in stride(from: 0, to: ramp, by: rate / 100) {
                    let eased = Self.rampedGain(own: next.gainDB(at: s + k), previous: last, index: k, ramp: ramp)
                    let truth = whole.gainDB(at: s + k)
                    worst = max(worst, abs(eased - truth))
                    plain = max(plain, abs(next.gainDB(at: s + k) - truth))
                    slope = max(slope, abs(eased - before) * 100)
                    before = eased
                }
                rampDeviations.append(worst)
                plainDeviations.append(plain)
                slopes.append(slope)
                print("SEAM3 \(n) | seam at \(seam) s | step \(f(steps.last!, 2)) dB | first 2 s deviation from whole-file: plain \(f(plain, 2)) eased \(f(worst, 2)) dB, steepest eased slope \(f(slope, 2)) dB/s")
            }
        }
        print("SEAM3 all | \(steps.count) seams | step max \(f(steps.max() ?? 0, 2)) p95 \(f(AudioTestSignals.percentile(steps, 0.95), 2)) median \(f(AudioTestSignals.percentile(steps, 0.5), 2)) dB | first 2 s deviation: plain max \(f(plainDeviations.max() ?? 0, 2)) p95 \(f(AudioTestSignals.percentile(plainDeviations, 0.95), 2)), eased max \(f(rampDeviations.max() ?? 0, 2)) p95 \(f(AudioTestSignals.percentile(rampDeviations, 0.95), 2)) | steepest eased slope max \(f(slopes.max() ?? 0, 2)) dB/s")
    }

    /// Forward play after a seek: piece N is bootstrapped (no history), piece N+1 follows with 12 s
    /// of history taken from N's isolated audio. The step at the seam |last gain of N − first gain of
    /// N+1| must be about 0 because N's last keypoint (at the seam, from its own last 12 s) is the
    /// one N+1 starts from. Over every excerpt at the seams 30, 90 and 150 s (18 positions); also
    /// the first 2 s of N+1 against the whole-file curve (exact history, so 0).
    @Test func forwardSeams() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        var steps: [Double] = []
        for (i, file) in files.enumerated() {
            let n = i + 1
            let samples = try await Self.material(n, file, path: path).isolated
            let whole = KeypointLeveler().curve(over: .init(samples, end: samples.count))
            for seam in [30, 90, 150] {
                let s = seam * rate
                let previous = Self.pieceCurve(KeypointLeveler(), samples: samples, start: s - 30 * rate, history: 0)
                let next = Self.pieceCurve(KeypointLeveler(), samples: samples, start: s, history: 12)
                let step = abs(next.gainDB(at: s) - previous.gainDB(at: s - 1))
                steps.append(step)
                let drift = Self.gainErrors(next, whole, over: s..<(s + 2 * rate)).max
                print("FWD \(n) | seam at \(seam) s | step \(f(step, 3)) dB | N+1 first 2 s vs whole-file \(f(drift, 3)) dB")
            }
        }
        print("FWD all | \(steps.count) positions | step max \(f(steps.max() ?? 0, 3)) p95 \(f(AudioTestSignals.percentile(steps, 0.95), 3)) dB")
    }

    // MARK: D: ffmpeg-only fallback

    /// The chains without a Swift leveler, per excerpt: `current` (production), family D
    /// (`D1-t0`, `D1-m10`: `dynaudnorm` and `acompressor` in place of `speechnorm` and `agate`,
    /// through the isolated raw file as the production pieces are read), and G's round-2 render
    /// for the distance. Without Apple isolation (the path `segmentArguments` takes): the
    /// production `filterChain`, and family D after the same front-end filters, both on the
    /// original audio. Prints `FALL` lines (`report`) and the residue figures.
    @Test func fallback() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        let front = "highpass=f=90,lowpass=f=10000,afftdn=nr=15:nf=-50:tn=1,equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1.4:g=3"
        let dynamic = "dynaudnorm=f=250:g=51:p=0.5:m=10:b=1,acompressor=threshold=0.125:ratio=3:attack=10:release=200:knee=4:makeup=1.5"
        // Family D3: the same dynamic stage with a louder compressor (K11 + 1 dB makeup) and a higher gain cap `m`.
        let dynamicM40 = "dynaudnorm=f=250:g=51:p=0.9:m=40:b=1,acompressor=threshold=0.08:ratio=3:attack=1:release=100:knee=6:makeup=4.26"
        let dynamicM100 = "dynaudnorm=f=250:g=51:p=0.9:m=100:b=1,acompressor=threshold=0.08:ratio=3:attack=1:release=100:knee=6:makeup=4.26"
        for (i, file) in files.enumerated() {
            let n = i + 1
            let material = try await Self.material(n, file, path: path)
            let raw = path.folder.appendingPathComponent("src-\(n)-iso100.raw")
            if !FileManager.default.fileExists(atPath: raw.path) { try AudioTestSignals.writeRaw16(material.isolated, to: raw) }
            let d1 = try #require(Measurements.all.first { $0.name == "D1-t0" })
            let d2 = try #require(Measurements.all.first { $0.name == "D1-m10" })
            let names = ["current", "D1-t0", "D1-m10", "G (round 2)", "no isolation: filterChain", "no isolation: front + D", "D3-m40", "D3-m100", "no isolation: front + D3-m40", "no isolation: front + D3-m100"]
            let renderings = try Self.parallel(names.count) { k -> Rendering in
                switch k {
                case 0: return try Self.render(chain: AudioEnhancement.isolatedChain, pregain: nil, raw: raw, path: path)
                case 1: return try Self.render(chain: d1.chain, pregain: nil, raw: raw, path: path)
                case 2: return try Self.render(chain: d2.chain, pregain: nil, raw: raw, path: path)
                case 3: return try Self.render(Self.variants[0], isolated: material.isolated, path: path)
                case 4:
                    let out = try Self.run(material.input, chain: AudioEnhancement.filterChain, in: path)
                    return Rendering(output: out, unlimited: out)
                case 6, 7:
                    let chain = [Measurements.prefix, k == 6 ? dynamicM40 : dynamicM100, Measurements.limiter].joined(separator: ",")
                    return try Self.render(chain: chain, pregain: nil, raw: raw, path: path)
                default:
                    let chain = front + "," + (k == 5 ? dynamic : k == 8 ? dynamicM40 : dynamicM100)
                    return Rendering(output: try Self.run(material.input, chain: chain + "," + Measurements.limiter, in: path), unlimited: try Self.run(material.input, chain: chain, in: path))
                }
            }
            for (name, r) in zip(names, renderings) {
                let loud = try Measurements.loudness(r.output, in: path)
                let res = Self.residue(isolated: material.isolated, output: r.output)
                let end = try Self.endings(material.input, r.output, path: path)
                print("FALL \(n) | \(name) | \(f(loud.lufs)) LUFS / \(f(loud.lra)) LU | speech \(f(Self.speechLevel(material.input))) -> \(f(res.speech)) | between-word median \(f(res.between)) pause \(f(res.pause)) | endings median \(f(end.median)) worst10% \(f(end.worst)) over \(end.count) | peak \(f(AudioTestSignals.peak(r.output))) dBFS")
            }
        }
    }

    // MARK: E: listening set

    /// `<n>-<label>__original-loud|current|new-r2|new-r3.wav` in `BEEPBAR_AUDIO_AB_OUT`: `new-r2`
    /// is round 2's G (compressor K7, no cleanup), `new-r3` is G with the cleanup named by
    /// `BEEPBAR_AUDIO_LEVELER_CLEANUP` and the compressor named by `BEEPBAR_AUDIO_LEVELER_COMPRESSOR`
    /// (a `compressors3` name); `original-loud` is a static gain to `new-r3`'s loudness.
    @Test func listening() async throws {
        let files = Self.excerptFiles
        let env = ProcessInfo.processInfo.environment
        guard !files.isEmpty, let out = env["BEEPBAR_AUDIO_AB_OUT"].flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let labels = (env["BEEPBAR_AUDIO_LEVELER_LABELS"] ?? "").split(separator: ",").map(String.init)
        let cleanup = env["BEEPBAR_AUDIO_LEVELER_CLEANUP"] ?? "none"
        let compressor = try #require(Self.compressors3.first { $0.0 == (env["BEEPBAR_AUDIO_LEVELER_COMPRESSOR"] ?? "K7") }).1
        let path = try Path()
        defer { path.remove() }
        for (i, file) in files.enumerated() {
            let n = i + 1
            let label = i < labels.count ? labels[i] : "excerpt"
            let material = try await Self.material(n, file, path: path)
            let raw = path.folder.appendingPathComponent("src-\(n)-iso100.raw")
            if !FileManager.default.fileExists(atPath: raw.path) { try AudioTestSignals.writeRaw16(material.isolated, to: raw) }
            let current = try Self.render(chain: AudioEnhancement.isolatedChain, pregain: nil, raw: raw, path: path)
            let r2 = try Self.render(Self.variants[0], isolated: material.isolated, path: path)
            let leveled = Self.leveled(material.isolated)
            let nf = Self.noiseFloor(isolated: material.isolated, leveled: leveled)
            let r3 = try Self.finish(leveled, cleanup: Self.cleanupChain(cleanup, nf: nf), compressor: compressor, path: path)
            func write(_ suffix: String, _ samples: [Float]) throws {
                try AudioTestSignals.writeWAV16(samples, to: out.appendingPathComponent("\(n)-\(label)__\(suffix).wav"))
            }
            try write("current", current.output)
            try write("new-r2", r2.output)
            try write("new-r3", r3.output)
            let target = try Measurements.loudness(r3.output, in: path).lufs
            var dB = target - (try Measurements.loudness(material.input, in: path)).lufs
            var loud = try Self.run(material.input, chain: String(format: "volume=%.2fdB,", dB) + Measurements.limiter, in: path)
            dB += target - (try Measurements.loudness(loud, in: path)).lufs
            loud = try Self.run(material.input, chain: String(format: "volume=%.2fdB,", dB) + Measurements.limiter, in: path)
            try write("original-loud", loud)
            print("LISTEN \(n) | nf \(f(nf, 0)) | new-r3 \(f(target)) LUFS, new-r2 \(f(try Measurements.loudness(r2.output, in: path).lufs)), current \(f(try Measurements.loudness(current.output, in: path).lufs)), original-loud \(f(try Measurements.loudness(loud, in: path).lufs))")
        }
    }
}
