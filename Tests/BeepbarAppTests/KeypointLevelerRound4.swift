import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

private let rate = AudioTestSignals.sampleRate
private func f(_ x: Double, _ digits: Int = 1) -> String { AudioQualityMeasurements.f(x, digits) }

/// Round 4 of the keypoint leveler measurements (same on-demand gate and variables as
/// `KeypointLevelerMeasurements`; local recordings only, never printed by name, excerpts appear
/// only as their index). Question: can "Voce livellata" (no Apple isolation in what is heard)
/// follow the isolated audio's level without lifting room noise?
///
/// S ("sidechain"): the isolated audio is only a *detector*. Its keypoint gain (the same
/// `KeypointLeveler` curve G uses) is applied to the ORIGINAL audio, under a local ceiling
/// computed on the audio actually amplified (the original), then a front end, K17 and the limiter.
/// - `sidechain`: S's four fronts against G+K17 and the shipped no-isolation chain, per excerpt;
/// - `longPause`: a composite with 180 s of room noise in the middle, to see what each chain does
///   to a pause of minutes (a gain must hold across it, not climb);
/// - `listening4`: the A/B set `<n>-<label>__original-loud|new-isolated|new-levelled.wav`.
extension KeypointLevelerMeasurements {
    // MARK: S: sidechain gain

    /// The two pieces of the sidechain gain: keypoint gains from the isolated audio, and the local
    /// ceiling from the audio that is amplified. Not thread-safe (the curves cache): one per task.
    final class SidechainGain {
        let detector: KeypointLeveler.Curve
        let ceilingCurve: KeypointLeveler.Curve
        init(isolated: [Float], amplified: [Float], leveler: KeypointLeveler = KeypointLeveler()) {
            detector = leveler.curve(over: .init(isolated))
            ceilingCurve = leveler.curve(over: .init(amplified))
        }

        /// The keypoint gain (dB) at sample `tau`, before the ceiling.
        func keypointDB(at tau: Int) -> Double { detector.gainDB(at: tau) }

        /// The applied gain (dB) at sample `tau`: keypoint gain under the ceiling interpolated
        /// linearly in dB between 10 ms instants, as `Curve.apply` does.
        func appliedDB(at tau: Int) -> Double {
            let m = tau / KeypointLeveler.block
            let a = ceilingCurve.ceiling(m), b = ceilingCurve.ceiling(m + 1)
            if a >= 1000 || b >= 1000 { return keypointDB(at: tau) }
            return min(keypointDB(at: tau), a + (b - a) * Double(tau - m * KeypointLeveler.block) / Double(KeypointLeveler.block))
        }

        /// `x` times the applied gain. Works in 10 ms blocks: spacing × rate is a multiple of the
        /// block, so a block never straddles two keypoints and the keypoint gain is linear in dB
        /// inside it (same structure as `Curve.apply`, which this must agree with).
        func apply(to x: [Float]) -> [Float] {
            var out = x
            let block = KeypointLeveler.block
            var g0 = keypointDB(at: 0), c0 = ceilingCurve.ceiling(0)
            for m in 0..<((x.count + block - 1) / block) {
                let lo = m * block, hi = min(lo + block, x.count)
                let g1 = keypointDB(at: (m + 1) * block), c1 = ceilingCurve.ceiling(m + 1)
                let off = c0 >= 1000 || c1 >= 1000
                for i in lo..<hi {
                    let w = Double(i - lo) / Double(block)
                    let key = g0 + (g1 - g0) * w
                    let cap = off ? 1000 : c0 + (c1 - c0) * w
                    out[i] = x[i] * Float(exp(min(key, cap) * 0.1151292546497023))
                }
                g0 = g1
                c0 = c1
            }
            return out
        }
    }

    static let frontA = "highpass=f=90,lowpass=f=10000,afftdn=nr=15:nf=-50:tn=1,equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1.4:g=3"
    static let frontC = "highpass=f=90,lowpass=f=10000,afftdn=nr=12:nf=-40:tn=1,equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1.4:g=3"
    static let preCleanD = "highpass=f=90,lowpass=f=10000,afftdn=nr=15:nf=-50:tn=1"
    static let equalizersOnly = "equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1.4:g=3"
    /// The shipped "front + D3-m100" stage (as in `fallback`).
    static let dynamicM100Stage = "dynaudnorm=f=250:g=51:p=0.9:m=100:b=1,acompressor=threshold=0.08:ratio=3:attack=1:release=100:knee=6:makeup=4.26"
    static var k17: Compressor { compressors3.first { $0.0 == "K17" }!.1 }

    /// The sidechain rows: name, the front the S gain is followed by, and whether afftdn runs on
    /// the original BEFORE the gain (S-d: the gain and its ceiling then see the cleaned audio).
    static let sidechainFronts: [(name: String, front: String, cleanBefore: Bool)] = [
        ("S-a", frontA, false),
        ("S-b", Measurements.prefix, false),
        ("S-c", frontC, false),
        ("S-d", equalizersOnly, true),
    ]

    /// The audio the S gain is applied to, per front group: the original, and (S-d) the original
    /// after `preCleanD`. Computed serially: the curves cache and are not thread-safe.
    struct SidechainAudio {
        let original: [Float]     // input × gain (S-a, S-b, S-c)
        let cleaned: [Float]      // preCleanD(input) × gain (S-d)
    }

    static func sidechainAudio(input: [Float], isolated: [Float], path: Path) throws -> SidechainAudio {
        let original = SidechainGain(isolated: isolated, amplified: input).apply(to: input)
        var pre = try run(input, chain: preCleanD, in: path)
        if pre.count > input.count { pre.removeLast(pre.count - input.count) }
        if pre.count < input.count { pre += [Float](repeating: 0, count: input.count - pre.count) }
        let cleaned = SidechainGain(isolated: isolated, amplified: pre).apply(to: pre)
        return SidechainAudio(original: original, cleaned: cleaned)
    }

    /// One S row, rendered: `front`, K17, limiter (and the same without the limiter).
    static func renderSidechain(_ row: (name: String, front: String, cleanBefore: Bool), audio: SidechainAudio, path: Path) throws -> Rendering {
        let chain = row.front + "," + k17.chain
        let source = row.cleanBefore ? audio.cleaned : audio.original
        return Rendering(output: try run(source, chain: chain + "," + Measurements.limiter, in: path), unlimited: try run(source, chain: chain, in: path))
    }

    /// The sample ranges (50 ms frames) of true pauses: the isolated audio below −90 dBFS for at
    /// least 300 ms (six frames) in a row.
    static func truePauses(isolated: [Float]) -> [Range<Int>] {
        let frame = rate / 20
        let levels = AudioTestSignals.frameLevels(isolated, frame: frame, in: 0..<isolated.count)
        var ranges: [Range<Int>] = []
        var start: Int?
        for i in 0...levels.count {
            let quiet = i < levels.count && levels[i] < -90
            if quiet { if start == nil { start = i } } else if let s = start {
                if i - s >= 6 { for j in s..<i { ranges.append(j * frame..<(j + 1) * frame) } }
                start = nil
            }
        }
        return ranges
    }

    // MARK: A: sidechain

    /// Per excerpt, the rows `G isolated K17` (reference), `no isolation: front + D3-m100`, and
    /// S-a...S-d. Columns as `fallback` and `limiterLoad`, plus `pause noise`: the RMS (dBFS) of
    /// the output over the true pauses (isolated audio below −90 dBFS for 300 ms), and the same
    /// figure for the original input, so the lift is visible.
    @Test func sidechain() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        for (i, file) in files.enumerated() {
            let n = i + 1
            let material = try await Self.material(n, file, path: path)
            let leveled = Self.leveled(material.isolated)
            let audio = try Self.sidechainAudio(input: material.input, isolated: material.isolated, path: path)
            let pauses = Self.truePauses(isolated: material.isolated)
            let names = ["G isolated K17", "no isolation: front + D3-m100"] + Self.sidechainFronts.map(\.name)
            let renderings = try Self.parallel(names.count) { k -> Rendering in
                switch k {
                case 0: return try Self.finish(leveled, cleanup: nil, compressor: Self.k17, path: path)
                case 1:
                    let chain = Self.frontA + "," + Self.dynamicM100Stage
                    return Rendering(output: try Self.run(material.input, chain: chain + "," + Measurements.limiter, in: path), unlimited: try Self.run(material.input, chain: chain, in: path))
                default: return try Self.renderSidechain(Self.sidechainFronts[k - 2], audio: audio, path: path)
                }
            }
            let inputPause = AudioTestSignals.level(material.input, over: pauses)
            for (name, r) in zip(names, renderings) {
                let loud = try Measurements.loudness(r.output, in: path)
                let res = Self.residue(isolated: material.isolated, output: r.output)
                let end = try Self.endings(material.input, r.output, path: path)
                let l = Self.limiterReduction(r)
                let pauseNoise = pauses.isEmpty ? Double.nan : AudioTestSignals.level(r.output, over: pauses)
                print("SIDE \(n) | \(name) | \(f(loud.lufs)) LUFS / \(f(loud.lra)) LU | speech \(f(Self.speechLevel(material.input))) -> \(f(res.speech)) | between-word median \(f(res.between)) pause \(f(res.pause)) | endings median \(f(end.median)) worst10% \(f(end.worst)) over \(end.count) | limiter p50 \(f(l.p50)) p99 \(f(l.p99)) max \(f(l.max)) dB | pause noise \(f(pauseNoise)) dBFS (input \(f(pauses.isEmpty ? .nan : inputPause)), \(f(Double(pauses.count) * 0.05)) s of true pauses) | peak \(f(AudioTestSignals.peak(r.output))) dBFS")
            }
        }
    }

    // MARK: B: long pause

    /// The longest run of 10 ms frames of `isolated` below −90 dBFS, as a sample range.
    static func longestQuiet(isolated: [Float]) -> Range<Int> {
        let frame = rate / 100
        let levels = AudioTestSignals.frameLevels(isolated, frame: frame, in: 0..<isolated.count)
        var best = 0..<0
        var start: Int?
        for i in 0...levels.count {
            let quiet = i < levels.count && levels[i] < -90
            if quiet { if start == nil { start = i } } else if let s = start {
                if i - s > best.count / frame { best = s * frame..<i * frame }
                start = nil
            }
        }
        return best
    }

    /// `piece` tiled to `length` samples, each copy joined to the next by a 20 ms equal-power
    /// crossfade (cos/sin, so uncorrelated noise keeps its level).
    static func tile(_ piece: [Float], to length: Int) -> [Float] {
        let fade = rate / 50
        var out = [Float](repeating: 0, count: length)
        var pos = 0
        var first = true
        while pos < length {
            for j in 0..<piece.count where pos + j < length {
                var gain = Float(1)
                if !first && j < fade { gain = Float(sin(Double(j) / Double(fade) * .pi / 2)) }
                else if j >= piece.count - fade { gain = Float(cos(Double(j - (piece.count - fade)) / Double(fade) * .pi / 2)) }
                out[pos + j] += piece[j] * gain
            }
            pos += piece.count - fade
            first = false
        }
        return out
    }

    /// Excerpts 1, 2 and 5: a composite of the excerpt's seconds 0–60, 180 s of its own room noise
    /// (its longest stretch where the isolated audio is under −90 dBFS, tiled), and seconds
    /// 60–120; isolated as new audio. Chains: production `filterChain`, `front + D3-m100`, S-a,
    /// S-b and the S rows named by `BEEPBAR_AUDIO_LEVELER_SIDECHAIN_EXTRA` (comma list). Reports
    /// the output RMS over the pause in five windows, the original's pause RMS, the p90 of 400 ms
    /// speech frames in the 10 s after the pause and over the last 30 s, the limiter's maximum
    /// reduction in those 10 s, and for S the keypoint (and applied) gain at the pause's start,
    /// middle and end, which should hold.
    @Test func longPause() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let extra = (ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_LEVELER_SIDECHAIN_EXTRA"] ?? "").split(separator: ",").map(String.init)
        let path = try Path()
        defer { path.remove() }
        for n in [1, 2, 5] where n <= files.count {
            let material = try await Self.material(n, files[n - 1], path: path)
            let quiet = Self.longestQuiet(isolated: material.isolated)
            print("PAUSE \(n) | room noise stretch \(f(Double(quiet.count) / Double(rate), 2)) s")
            guard quiet.count >= rate / 2 else { print("PAUSE \(n) | shorter than 0.5 s, skipped"); continue }
            guard material.input.count >= 120 * rate else { print("PAUSE \(n) | excerpt shorter than 120 s, skipped"); continue }
            let noise = Self.tile(Array(material.input[quiet]), to: 180 * rate)
            let composite = Array(material.input[0..<60 * rate]) + noise + Array(material.input[60 * rate..<120 * rate])
            let raw = try await path.prepare(composite, front: .isolated, name: "comp-\(n)")
            let isolated = try AudioTestSignals.rawSamples(raw)
            let pauseStart = 60 * rate, pauseEnd = 240 * rate
            let pauseOriginal = AudioTestSignals.level(composite, over: [pauseStart..<pauseEnd])
            let audio = try Self.sidechainAudio(input: composite, isolated: isolated, path: path)
            let gain = SidechainGain(isolated: isolated, amplified: composite)
            let rows = ([("production filterChain", nil), ("front + D3-m100", nil)] as [(String, String?)])
                + Self.sidechainFronts.filter { $0.name == "S-a" || $0.name == "S-b" || extra.contains($0.name) }.map { ($0.name, Optional($0.name)) }
            let renderings = try Self.parallel(rows.count) { k -> Rendering in
                switch k {
                case 0:
                    let out = try Self.run(composite, chain: AudioEnhancement.filterChain, in: path)
                    return Rendering(output: out, unlimited: out)
                case 1:
                    let chain = Self.frontA + "," + Self.dynamicM100Stage
                    return Rendering(output: try Self.run(composite, chain: chain + "," + Measurements.limiter, in: path), unlimited: try Self.run(composite, chain: chain, in: path))
                default:
                    let row = Self.sidechainFronts.first { $0.name == rows[k].1 }!
                    return try Self.renderSidechain(row, audio: audio, path: path)
                }
            }
            for ((name, _), r) in zip(rows, renderings) {
                let windows = [0, 25, 55, 115, 175].map { s -> String in
                    "\(s)-\(s + 5) s \(f(AudioTestSignals.level(r.output, over: [(pauseStart + s * rate)..<(pauseStart + (s + 5) * rate)])))"
                }.joined(separator: ", ")
                let after = pauseEnd..<(pauseEnd + 10 * rate)
                let afterSpeech = Self.speechLevel(Array(r.output[after]))
                let lastSpeech = Self.speechLevel(Array(r.output[(composite.count - 30 * rate)..<composite.count]))
                let limiter = name == "production filterChain" ? "n/a (limiter is inside the chain)"
                    : f(Self.limiterReduction(Rendering(output: Array(r.output[after]), unlimited: Array(r.unlimited[after]))).max)
                var gains = ""
                if name.hasPrefix("S-") {
                    let points = [pauseStart, (pauseStart + pauseEnd) / 2, pauseEnd - 1]
                    gains = " | keypoint gain start/middle/end " + points.map { f(gain.keypointDB(at: $0)) }.joined(separator: "/")
                        + " dB, applied " + points.map { f(gain.appliedDB(at: $0)) }.joined(separator: "/") + " dB"
                }
                print("PAUSE \(n) | \(name) | pause RMS dBFS: \(windows) (original pause \(f(pauseOriginal))) | speech p90 after pause \(f(afterSpeech)), last 30 s \(f(lastSpeech)) (original last 30 s \(f(Self.speechLevel(Array(composite[(composite.count - 30 * rate)..<composite.count]))))) | limiter max in 10 s after \(limiter) dB\(gains)")
            }
        }
    }

    // MARK: C: listening

    /// `<n>-<label>__original-loud|new-isolated|new-levelled.wav` in `BEEPBAR_AUDIO_AB_OUT` for
    /// excerpts 1, 2, 5 and 6: `new-isolated` is G + K17, `new-levelled` is S with the front named
    /// by `BEEPBAR_AUDIO_LEVELER_SIDECHAIN` (default `S-a`), `original-loud` a static gain to
    /// `new-levelled`'s loudness (as in round 3).
    @Test func listening4() async throws {
        let files = Self.excerptFiles
        let env = ProcessInfo.processInfo.environment
        guard !files.isEmpty, let out = env["BEEPBAR_AUDIO_AB_OUT"].flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let labels = (env["BEEPBAR_AUDIO_LEVELER_LABELS"] ?? "").split(separator: ",").map(String.init)
        let frontName = env["BEEPBAR_AUDIO_LEVELER_SIDECHAIN"] ?? "S-a"
        let row = try #require(Self.sidechainFronts.first { $0.name == frontName })
        let path = try Path()
        defer { path.remove() }
        for n in [1, 2, 5, 6] where n <= files.count {
            let label = n - 1 < labels.count ? labels[n - 1] : "excerpt"
            let material = try await Self.material(n, files[n - 1], path: path)
            let isolatedRender = try Self.finish(Self.leveled(material.isolated), cleanup: nil, compressor: Self.k17, path: path)
            let audio = try Self.sidechainAudio(input: material.input, isolated: material.isolated, path: path)
            let levelled = try Self.renderSidechain(row, audio: audio, path: path)
            func write(_ suffix: String, _ samples: [Float]) throws {
                try AudioTestSignals.writeWAV16(samples, to: out.appendingPathComponent("\(n)-\(label)__\(suffix).wav"))
            }
            try write("new-isolated", isolatedRender.output)
            try write("new-levelled", levelled.output)
            let target = try Measurements.loudness(levelled.output, in: path).lufs
            var dB = target - (try Measurements.loudness(material.input, in: path)).lufs
            var loud = try Self.run(material.input, chain: String(format: "volume=%.2fdB,", dB) + Measurements.limiter, in: path)
            dB += target - (try Measurements.loudness(loud, in: path)).lufs
            loud = try Self.run(material.input, chain: String(format: "volume=%.2fdB,", dB) + Measurements.limiter, in: path)
            try write("original-loud", loud)
            print("LISTEN4 \(n) | \(frontName) | new-levelled \(f(target)) LUFS, new-isolated \(f(try Measurements.loudness(isolatedRender.output, in: path).lufs)), original-loud \(f(try Measurements.loudness(loud, in: path).lufs))")
        }
    }
}
