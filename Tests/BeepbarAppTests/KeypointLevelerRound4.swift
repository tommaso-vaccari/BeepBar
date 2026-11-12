import AVFoundation
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

    // MARK: D: whole-lecture profile of the keypoint gain in pauses

    /// The detector variants of `lectureProfile`, on 400 ms frame levels (the keypoints' own
    /// frames: spacing 10 s is 25 frames, so the frame grid is the keypoints' grid). Everything
    /// else is `KeypointLeveler()`'s: window 12 s (30 frames), 90th percentile, target -20,
    /// clamp -6...48, 15% voiced minimum, unbounded hold, bootstrap at the lecture's start.
    /// - `ratio` (R): a frame counts as voiced only if isolated > -95 dBFS and isolated >= original - 10 dB
    ///   (the isolator kept most of the frame's energy);
    /// - `evidence` (E): a keypoint whose measured gain exceeds the previous resolved keypoint's by
    ///   more than 6 dB needs 40% voiced frames in its window, else it holds.
    struct Detector {
        let name: String
        var ratio = false
        var evidence = false
    }

    static let detectors = [Detector(name: "BASE"), Detector(name: "R", ratio: true), Detector(name: "E", evidence: true), Detector(name: "RE", ratio: true, evidence: true)]

    /// What one keypoint's window said under a detector.
    struct KeypointRead {
        var existing = 0
        var voiced: [Int] = []        // frame indices that count as voiced
        var share: Double { existing == 0 ? 0 : Double(voiced.count) / Double(existing) }
        var measured: Double?         // the gain it measures (clamped), nil: fewer than 15% voiced
    }

    /// Keypoint `k`'s window, as `KeypointLeveler.Curve.compute` reads it with `bootstrap` on:
    /// frames `25k - 30 ..< 25k` (those at or after frame 0), and for `k == 0` the 30 frames after it.
    static func read(_ k: Int, iso: [Double], orig: [Double], detector: Detector) -> KeypointRead {
        let hi = k == 0 ? 30 : 25 * k
        let lo = max(0, hi - 30)
        var r = KeypointRead()
        for f in lo..<min(hi, iso.count) {
            r.existing += 1
            if iso[f] > -95 && (!detector.ratio || iso[f] >= orig[f] - 10) { r.voiced.append(f) }
        }
        if r.existing > 0, r.share >= 0.15 {
            let level = AudioTestSignals.percentile(r.voiced.map { iso[$0] }, 0.9)
            r.measured = max(-6, min(48, -20 - level))
        }
        return r
    }

    /// The resolved keypoint gains 0...`last` of a detector, in ascending order (a hold takes the
    /// previous resolved gain; keypoint 0 holding is neutral, 0 dB), and which ones measured.
    static func resolve(last: Int, iso: [Double], orig: [Double], detector: Detector) -> (gains: [Double], measured: [Bool], reads: [KeypointRead]) {
        var gains: [Double] = [], measured: [Bool] = [], reads: [KeypointRead] = []
        for k in 0...last {
            let r = read(k, iso: iso, orig: orig, detector: detector)
            var value = r.measured
            if detector.evidence, let g = value, let previous = gains.last, g > previous + 6, r.share < 0.4 { value = nil }
            gains.append(value ?? gains.last ?? 0)
            measured.append(value != nil)
            reads.append(r)
        }
        return (gains, measured, reads)
    }

    /// The gain (dB) at frame `f`'s centre: linear in dB between keypoints, the last one held past
    /// the lecture's end (the `Curve`'s `end` rule).
    static func frameGain(_ f: Int, gains: [Double]) -> Double {
        let t = (Double(f) + 0.5) / 25
        let k = Int(t.rounded(.down))
        guard k + 1 < gains.count else { return gains[min(k, gains.count - 1)] }
        return gains[k] + (gains[k + 1] - gains[k]) * (t - Double(k))
    }

    /// 400 ms frame levels of `x` (whole frames only), as `Curve` computes them.
    static func level400(_ energy: Double) -> Double { max(-120, 10 * log10(energy / Double(KeypointLeveler.frameLength) + 1e-20)) }

    static func levels400(_ x: [Float]) -> [Double] {
        stride(from: 0, to: x.count - KeypointLeveler.frameLength + 1, by: KeypointLeveler.frameLength).map { lo in
            var e = 0.0
            for j in lo..<(lo + KeypointLeveler.frameLength) { e += Double(x[j]) * Double(x[j]) }
            return level400(e)
        }
    }

    /// The same, streamed from a float audio file (a lecture never sits in memory whole).
    static func levels400(streaming url: URL) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536))
        var out: [Double] = []
        var energy = 0.0, count = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            let p = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                energy += Double(p[i]) * Double(p[i])
                count += 1
                if count == KeypointLeveler.frameLength { out.append(level400(energy)); energy = 0; count = 0 }
            }
        }
        return out
    }

    /// The same, streamed from raw 16-bit little-endian mono (the isolator's output).
    static func levels400(streamingRaw url: URL) throws -> [Double] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var out: [Double] = []
        var energy = 0.0, count = 0
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            data.withUnsafeBytes { bytes in
                for i in stride(from: 0, to: data.count - 1, by: 2) {
                    let s = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32767
                    energy += s * s
                    count += 1
                    if count == KeypointLeveler.frameLength { out.append(level400(energy)); energy = 0; count = 0 }
                }
            }
        }
        return out
    }

    static func stats(_ x: [Double], _ ps: [Double]) -> String { x.isEmpty ? "n/a" : ps.map { f(AudioTestSignals.percentile(x, $0)) }.joined(separator: "/") }
    static func seconds(_ n: Int) -> String { f(Double(n) * 0.4, 0) }
    static func mmss(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    /// Prints the `PROF` and `KEY` rows of one lecture from its frame levels.
    static func profile(lecture: Int, iso: [Double], orig: [Double]) {
        let frames = min(iso.count, orig.count)
        let iso = Array(iso[0..<frames]), orig = Array(orig[0..<frames])
        let last = frames / 25
        let ceiling = KeypointLeveler().target + (KeypointLeveler().ceilingHeadroom ?? 6)
        let results = detectors.map { resolve(last: last, iso: iso, orig: orig, detector: $0) }
        let baseVoiced = (0..<frames).map { iso[$0] > -95 }
        // Speech spans: the 10 s between keypoints k and k+1 with at least 30% BASE-voiced frames.
        var spans: [Range<Int>] = []
        var inSpan = [Bool](repeating: false, count: frames)
        for k in 0..<(frames / 25) {
            let r = (25 * k)..<(25 * k + 25)
            if Double(r.filter { baseVoiced[$0] }.count) >= 0.3 * 25 { spans.append(r); for f in r { inSpan[f] = true } }
        }
        let pause = (0..<frames).filter { iso[$0] < -95 }
        let pauseNoisy = pause.filter { orig[$0] > -110 }
        print("PROF \(lecture) | frames | \(f(Double(frames) * 0.4 / 60)) min | pause frames \(f(Double(pause.count) * 0.4 / 60)) min, of which original not digital silence \(f(Double(pauseNoisy.count) * 0.4 / 60)) min | speech spans \(spans.count) (\(seconds(spans.count * 25)) s) | original over pause frames p50/p90 \(stats(pause.map { orig[$0] }, [0.5, 0.9])), over the not-silent ones \(stats(pauseNoisy.map { orig[$0] }, [0.5, 0.9]))")
        for (d, res) in zip(detectors, results) {
            let g = res.gains
            let measuredCount = res.measured.filter { $0 }.count
            func out(_ f: Int) -> Double { orig[f] + min(frameGain(f, gains: g), ceiling - orig[f]) }
            let levelled = pause.map(out)
            let levelledNoisy = pauseNoisy.map(out)
            let spanValues = spans.map { r in AudioTestSignals.percentile(r.filter { baseVoiced[$0] }.map(out), 0.9) }
            let tooQuiet = spanValues.filter { $0 < -30 }.count
            let isolatedPause = (0..<frames).filter { iso[$0] >= -95 && iso[$0] < -60 && !inSpan[$0] }
            let isolatedOut = isolatedPause.map { iso[$0] + frameGain($0, gains: g) }
            print("PROF \(lecture) | \(d.name) | keypoints \(g.count) (\(measuredCount) measured, \(g.count - measuredCount) held) gain p5/p50/p95/min/max \(stats(g, [0.05, 0.5, 0.95, 0, 1])) dB"
                + " | LEVELLED ORIGINAL in pause frames: out p50/p90/p99/max \(stats(levelled, [0.5, 0.9, 0.99, 1])) dBFS, \(f(Double(pause.count) * 0.4 / 60)) min, above -35: \(seconds(levelled.filter { $0 > -35 }.count)) s, above -26: \(seconds(levelled.filter { $0 > -26 }.count)) s; where the original is not digital silence: p50/p90/p99/max \(stats(levelledNoisy, [0.5, 0.9, 0.99, 1])), above -35: \(seconds(levelledNoisy.filter { $0 > -35 }.count)) s, above -26: \(seconds(levelledNoisy.filter { $0 > -26 }.count)) s"
                + " | SPEECH span p90 across \(spans.count) spans p5/p50/p95 \(stats(spanValues, [0.05, 0.5, 0.95])) dBFS, below -30: \(tooQuiet) spans (\(tooQuiet * 10) s)"
                + " | ISOLATED in non-speech frames (-95..-60): \(isolatedPause.count) frames, out p50/p90/p99/max \(stats(isolatedOut, [0.5, 0.9, 0.99, 1])) dBFS, above -35: \(seconds(isolatedOut.filter { $0 > -35 }.count)) s")
        }
        // KEY rows (BASE): keypoints 10 dB or more away from the median of the 30 nearest measured
        // keypoints on each side (excluding itself), the 60 largest deviations in time order.
        let base = results[0], rVariant = detectors[1], eResult = results[2]
        let measuredIndices = (0...last).filter { base.measured[$0] }
        var rows: [(k: Int, deviation: Double, text: String)] = []
        for k in 0...last {
            let before = measuredIndices.filter { $0 < k }.suffix(30), after = measuredIndices.filter { $0 > k }.prefix(30)
            let neighbours = (before + after).map { base.gains[$0] }
            guard !neighbours.isEmpty else { continue }
            let median = AudioTestSignals.percentile(neighbours, 0.5)
            let deviation = base.gains[k] - median
            guard abs(deviation) >= 10 else { continue }
            let read = base.reads[k]
            let isoVoiced = read.voiced.map { iso[$0] }, origVoiced = read.voiced.map { orig[$0] }
            let passing = read.voiced.isEmpty ? Double.nan : Double(read.voiced.filter { iso[$0] >= orig[$0] - 10 }.count) / Double(read.voiced.count)
            let rRead = Self.read(k, iso: iso, orig: orig, detector: rVariant)
            let rGain = rRead.measured.map { f($0) } ?? "hold"
            // E's rule on this keypoint alone, against E's own resolved previous gain.
            var eGain = base.reads[k].measured.map { f($0) } ?? "hold"
            if let g = base.reads[k].measured, k > 0, g > eResult.gains[k - 1] + 6, read.share < 0.4 { eGain = "hold" }
            let w = max(0, (k == 0 ? 30 : 25 * k) - 30)..<min(frames, k == 0 ? 30 : 25 * k)
            let silent = Double(w.filter { orig[$0] < -110 }.count) / Double(max(w.count, 1))
            rows.append((k, abs(deviation), "KEY \(lecture) | \(mmss(k * 10)) | \(base.measured[k] ? "measured" : "held") gain \(f(base.gains[k])) dB vs median \(f(median)) | voiced \(f(read.share * 100, 0))% | isolated p90 \(stats(isoVoiced, [0.9])) original p90 \(stats(origVoiced, [0.9])) | frames passing R's ratio \(f(passing * 100, 0))% | R \(rGain) | E \(eGain) | original frames below -110 dBFS in window \(f(silent * 100, 0))%\(silent > 0.5 ? " (mostly digital silence)" : "")"))
        }
        print("KEY \(lecture) | \(rows.count) keypoints are 10 dB or more from the neighbouring median; showing \(min(rows.count, 60)) (largest deviations, in time order)")
        for row in rows.sorted(by: { $0.deviation > $1.deviation }).prefix(60).sorted(by: { $0.k < $1.k }) { print(row.text) }
    }

    /// For each lecture in `BEEPBAR_AUDIO_LEVELER_LECTURES` (comma-separated; printed as lecture 1,
    /// 2, 3 only): the keypoint gain under four detector variants, and what it does to pauses and
    /// to speech, at 400 ms frame level (see `Detector`, `profile`). One lecture at a time; only
    /// frame levels are kept (the audio is streamed), so memory stays small. First, as a check that
    /// the frame-based BASE equals `KeypointLeveler.Curve`'s keypoints, it compares the two on the
    /// first excerpt when excerpts are configured (`PROF check`).
    @Test func lectureProfile() async throws {
        let lectures = (ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_LEVELER_LECTURES"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !lectures.isEmpty else { return }
        if let file = Self.excerptFiles.first {
            let path = try Path()
            defer { path.remove() }
            let m = try await Self.material(1, file, path: path)
            let iso = Self.levels400(m.isolated), orig = Self.levels400(m.input)
            let curve = KeypointLeveler().curve(over: .init(m.isolated, end: m.isolated.count, bootstrap: true))
            let last = m.isolated.count / (10 * rate)
            let mine = Self.resolve(last: last, iso: iso, orig: orig, detector: Self.detectors[0]).gains
            let worst = (0...last).map { abs(mine[$0] - curve.keypoint($0)) }.max() ?? 0
            print("PROF check | frame-based BASE against KeypointLeveler.Curve on excerpt 1: \(last + 1) keypoints, largest difference \(f(worst, 4)) dB")
        }
        for (i, lecture) in lectures.enumerated() {
            try await autoreleasepool_async {
                let path = try Path()
                defer { path.remove() }
                let wav = path.folder.appendingPathComponent("lecture.wav")
                let raw = path.folder.appendingPathComponent("lecture.raw")
                let process = Process()
                process.executableURL = path.ffmpeg
                process.arguments = ["-nostdin", "-loglevel", "quiet", "-y", "-i", lecture, "-map", "0:a:0", "-vn", "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", wav.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                try #require(process.terminationStatus == 0, "lecture \(i + 1) could not be read as audio")
                let orig = try Self.levels400(streaming: wav)
                var isolator = try #require(AppleVoiceIsolator.preferred())
                isolator.wetDryMix = 100
                try await isolator.isolate(wav, from: 0, count: nil, to: raw)
                try? FileManager.default.removeItem(at: wav)
                let iso = try Self.levels400(streamingRaw: raw)
                try? FileManager.default.removeItem(at: raw)
                Self.profile(lecture: i + 1, iso: iso, orig: orig)
            }
        }
    }
}

/// Runs `body` (kept as a function so each lecture's temporaries are released before the next).
private func autoreleasepool_async(_ body: () async throws -> Void) async throws { try await body() }
