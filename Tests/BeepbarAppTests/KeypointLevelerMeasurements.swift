import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

private let rate = AudioTestSignals.sampleRate
private func f(_ x: Double, _ digits: Int = 1) -> String { AudioQualityMeasurements.f(x, digits) }

/// On-demand measurement of the keypoint leveler (`KeypointLeveler`, candidate G) against the
/// production chain, on local recordings. Never part of the regular `swift test`:
/// `BEEPBAR_MEASURE_AUDIO_QUALITY=1 BEEPBAR_AUDIO_LEVELER_EXCERPTS=<file>,<file> swift test --filter KeypointLevelerMeasurements`
///
/// Real lectures are private: files are read in a temporary folder, never copied into the
/// repository, and only an index is printed, never a name or a path. Variables:
/// - `BEEPBAR_AUDIO_LEVELER_EXCERPTS`: comma-separated audio files (any length; the first 180 s of
///   the first track are used), numbered from 1 in the order given;
/// - `BEEPBAR_AUDIO_LEVELER_CACHE`: a folder where the isolated audio is kept between runs (the
///   isolation is the slow step); private audio, so it must be outside the repository;
/// - `BEEPBAR_AUDIO_LEVELER_LABELS`: comma-separated short names for the listening files;
/// - `BEEPBAR_AUDIO_LEVELER_BEST`: the variant written as `new` (default `G`);
/// - `BEEPBAR_AUDIO_AB_OUT`: folder for the listening files of `renders`;
/// - `BEEPBAR_AUDIO_LEVELER_LECTURE`: a whole lecture for `wholeLecture`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BEEPBAR_MEASURE_AUDIO_QUALITY"] == "1" && AudioEnhancement.locateFFmpeg() != nil
                             && AppleVoiceIsolator.preferred() != nil, "on demand: BEEPBAR_MEASURE_AUDIO_QUALITY=1"))
struct KeypointLevelerMeasurements {
    typealias Measurements = AudioQualityMeasurements
    typealias Path = AudioQualityMeasurements.Path

    // MARK: Variants

    /// `acompressor` after the leveler. The leveler puts speech at a known level, so the
    /// threshold is a fixed number of dB under it; makeup then brings the integrated loudness to
    /// the target.
    struct Compressor: Sendable {
        var threshold = 0.063
        var ratio = 3.0
        var makeup = 2.5
        var attack = 10.0
        var release = 200.0
        var knee = 4.0
        var chain: String { "acompressor=threshold=\(threshold):ratio=\(ratio):attack=\(attack):release=\(release):knee=\(knee):makeup=\(makeup)" }
    }

    /// One way of running G: the leveler, the compressor after it, and whether the production
    /// equalizers run before the leveler (only changes where the level is measured).
    struct Variant: Sendable {
        let name: String
        var leveler = KeypointLeveler()
        var compressor = Compressor()
        var eqFirst = false
        /// An `agate` after the leveler, before the equalizers (hiss mitigation).
        var expander: String?
    }

    /// A very gentle downward expander for residue between words, placed after the leveler where
    /// speech sits at the target, so its threshold is relative by construction: −50 dBFS is 30 dB
    /// under the target, 1.5:1 and at most 6 dB down, slow release.
    static let gentleExpander = "agate=threshold=0.00316:ratio=1.5:range=0.5:attack=10:release=1000:knee=6:detection=rms"

    /// D1's compressor, kept as the starting point of the tuning.
    static let compressors: [(String, Compressor)] = [
        ("K1-d1", Compressor(threshold: 0.125, ratio: 3, makeup: 1.5)),
        ("K7", Compressor(threshold: 0.08, ratio: 3, makeup: 3.8)),
        ("K9", Compressor(threshold: 0.08, ratio: 3, makeup: 3.8, attack: 2)),
        ("K10", Compressor(threshold: 0.063, ratio: 4, makeup: 3.5, attack: 1)),
        ("K11", Compressor(threshold: 0.08, ratio: 3, makeup: 3.8, attack: 1, release: 100, knee: 6)),
        ("K12", Compressor(threshold: 0.05, ratio: 5, makeup: 4.5, attack: 1, release: 150, knee: 6)),
    ]

    /// The compressor the variants use: chosen on the `tune` output, see `docs/benchmarks.md`.
    static let chosen = Compressor(threshold: 0.08, ratio: 3, makeup: 3.8)

    static let variants: [Variant] = {
        func v(_ name: String, _ edit: (inout KeypointLeveler) -> Void = { _ in }, eqFirst: Bool = false) -> Variant {
            var leveler = KeypointLeveler()
            edit(&leveler)
            return Variant(name: name, leveler: leveler, compressor: chosen, eqFirst: eqFirst)
        }
        return [
            v("G"),
            v("G-noceil") { $0.ceilingHeadroom = nil },
            v("G-h10") { $0.ceilingHeadroom = 10 },
            v("G-h14") { $0.ceilingHeadroom = 14 },
            v("G-s5") { $0.spacing = 5 },
            v("G-p95") { $0.percentile = 0.95 },
            v("G-t23") { $0.target = -23 },
            v("G-hold3") { $0.maxHold = 3 },
            v("G-eq1", eqFirst: true),
            Variant(name: "G-exp", compressor: chosen, expander: gentleExpander),
            Variant(name: "G-exp44", compressor: chosen, expander: "agate=threshold=0.0063:ratio=1.5:range=0.5:attack=10:release=1000:knee=6:detection=rms"),
        ]
    }()

    // MARK: Material

    static var excerptFiles: [String] {
        (ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_LEVELER_EXCERPTS"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// An excerpt as heard (48 kHz mono float) and after Apple's isolation at 100%.
    struct Material {
        let input: [Float]
        let isolated: [Float]
    }

    /// Decodes file `n` (first 180 s of the first track) and isolates it, reusing the cache.
    /// ffmpeg's own error text would name the file, so a failure only says the index.
    static func material(_ n: Int, _ file: String, path: Path) async throws -> Material {
        let wav = path.folder.appendingPathComponent("src-\(n).wav")
        let process = Process()
        process.executableURL = path.ffmpeg
        process.arguments = ["-nostdin", "-loglevel", "quiet", "-y", "-i", file, "-map", "0:a:0", "-t", "180", "-vn",
                             "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", wav.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "excerpt \(n) could not be read as audio")
        let input = try AudioTestSignals.samples(wav)
        let cache = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_LEVELER_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let cached = cache?.appendingPathComponent("iso-\(n)-\(input.count).raw")
        if let cached, FileManager.default.fileExists(atPath: cached.path) {
            return Material(input: input, isolated: try AudioTestSignals.rawSamples(cached))
        }
        let raw = try await path.prepare(input, front: .isolated, name: "src-\(n)")
        if let cache, let cached {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: raw, to: cached)
        }
        return Material(input: input, isolated: try AudioTestSignals.rawSamples(raw))
    }

    static func parallel<T: Sendable>(_ count: Int, _ body: @Sendable (Int) throws -> T) throws -> [T] {
        let results = Measurements.ConcurrentResults<T>(count)
        DispatchQueue.concurrentPerform(iterations: count) { i in
            do {
                let value = try body(i)
                results.lock.withLock { results.values[i] = value }
            } catch {
                results.lock.withLock { results.failure = error }
            }
        }
        if let failure = results.failure { throw failure }
        return results.values.map { $0! }
    }

    // MARK: Running a chain

    /// ffmpeg with `chain` over `samples` (float in, float out, same length).
    static func run(_ samples: [Float], chain: String, in path: Path) throws -> [Float] {
        let id = UUID().uuidString
        let source = path.folder.appendingPathComponent("lv-\(id).wav")
        let out = path.folder.appendingPathComponent("lo-\(id).wav")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: out) }
        try AudioTestSignals.writeWAV(samples, to: source)
        try AudioTestSignals.run(path.ffmpeg, ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-i", source.path,
                                               "-af", chain, "-c:a", "pcm_f32le", "-f", "wav", "-y", out.path], in: path.folder)
        return try AudioTestSignals.samples(out)
    }

    /// What one rendering gave: the audio, and the same chain without its final limiter (to say
    /// how much the limiter took off).
    struct Rendering {
        let output: [Float]
        let unlimited: [Float]
    }

    /// G: leveler in Swift over the isolated samples, then `prefix`, the compressor and the
    /// limiter in ffmpeg (`eqFirst`: the equalizers first, as the leveler's input).
    static func render(_ variant: Variant, isolated: [Float], path: Path) throws -> Rendering {
        let after = variant.compressor.chain
        var source = isolated
        var chain = ([variant.expander, Measurements.prefix, after].compactMap { $0 }).joined(separator: ",")
        if variant.eqFirst {
            source = try run(isolated, chain: Measurements.prefix, in: path)
            chain = ([variant.expander, after].compactMap { $0 }).joined(separator: ",")
        }
        let leveled = variant.leveler.curve(over: .init(source)).apply(to: 0..<source.count)
        return Rendering(output: try run(leveled, chain: chain + "," + Measurements.limiter, in: path),
                         unlimited: try run(leveled, chain: chain, in: path))
    }

    /// A chain from `AudioQualityMeasurements` over the isolated raw file; the unlimited copy
    /// is the same chain without the closing limiter.
    static func render(chain: String, pregain: Double?, raw: URL, path: Path) throws -> Rendering {
        let head = pregain.map { String(format: "volume=%.2fdB,", $0) } ?? ""
        let output = try path.filter(raw, chain: head + chain)
        let stripped = chain.replacingOccurrences(of: "," + Measurements.limiter, with: "")
        return Rendering(output: output, unlimited: stripped == chain ? output : try path.filter(raw, chain: head + stripped))
    }

    // MARK: Metrics

    /// 400 ms frame levels.
    static func frames(_ x: [Float], _ range: Range<Int>? = nil) -> [Double] {
        AudioTestSignals.frameLevels(x, frame: rate * 4 / 10, in: range ?? 0..<x.count)
    }

    /// The speech level of `x`: 90th percentile of its 400 ms frames.
    static func speechLevel(_ x: [Float]) -> Double { AudioTestSignals.percentile(frames(x), 0.9) }

    /// The 90th percentile of each 30 s segment: how steady the level is inside the excerpt.
    static func segmentLevels(_ x: [Float]) -> [Double] {
        let segment = 30 * rate
        return stride(from: 0, to: x.count - segment + 1, by: segment).map { AudioTestSignals.percentile(frames(x, $0..<($0 + segment)), 0.9) }
    }

    /// The most the limiter took off, and the share of 10 ms frames it took more than 0.5 dB off.
    static func limiterActivity(_ r: Rendering, over range: Range<Int>? = nil) -> (worst: Double, share: Double) {
        let frame = rate / 100
        var worst = 0.0, reduced = 0, total = 0
        var i = range?.lowerBound ?? 0
        let count = min(r.output.count, r.unlimited.count, range?.upperBound ?? Int.max)
        while i + frame <= count {
            let before = r.unlimited[i..<(i + frame)].reduce(0) { max($0, abs($1)) }
            let after = r.output[i..<(i + frame)].reduce(0) { max($0, abs($1)) }
            if before > 0.8 {
                let dB = 20 * log10(Double(before) / Double(max(after, 1e-9)))
                worst = max(worst, dB)
                if dB > 0.5 { reduced += 1 }
            }
            total += 1
            i += frame
        }
        return (worst, Double(reduced) / Double(max(total, 1)))
    }

    /// Where the speech level rises most: for every 400 ms boundary, the median level of the voiced
    /// frames of the next 5 s minus that of the previous 5 s; the largest rise and its sample.
    static func largestJump(_ x: [Float]) -> (rise: Double, at: Int)? {
        let levels = frames(x)
        let span = 12  // 12 frames of 400 ms is 4.8 s
        var best: (Double, Int)?
        for i in span..<max(span, levels.count - span) {
            let before = levels[(i - span)..<i].filter { $0 > -95 }, after = levels[i..<(i + span)].filter { $0 > -95 }
            guard before.count >= 4, after.count >= 4 else { continue }
            let rise = AudioTestSignals.percentile(Array(after), 0.5) - AudioTestSignals.percentile(Array(before), 0.5)
            if best == nil || rise > best!.0 { best = (rise, i * rate * 4 / 10) }
        }
        return best.map { (rise: $0.0, at: $0.1) }
    }

    /// Mean level (dB) of `x` over the 400 ms frames at `indices`.
    static func mean(_ x: [Float], at indices: [Int]) -> Double {
        let levels = frames(x)
        return AudioTestSignals.mean(indices.filter { $0 < levels.count }.map { levels[$0] })
    }

    /// The report line of one rendering. Columns:
    /// - LUFS/LRA: integrated loudness and range (targets about −18 to −16 LUFS, at most about 6 LU);
    /// - speech: 90th percentile of 400 ms frames, input → output, dBFS;
    /// - seg: the lowest and highest of the 30 s segments' speech levels in the output (their
    ///   difference is the leveling that is left; the input's is `seg in`);
    /// - pause: the mean level of the input's quietest 20% of frames, input → output (the
    ///   gain a pause gets: what "noise remains" is made of);
    /// - limiter: the most it took off, and the share of frames it touched by more than 0.5 dB.
    /// then `excerptMetrics`'s ending metric and clipping.
    static func report(_ n: Int, _ name: String, input: [Float], _ r: Rendering, path: Path) throws -> String {
        let count = min(input.count, r.output.count)
        let input = Array(input[0..<count]), output = Array(r.output[0..<count])
        let a = frames(input)
        let quietest = AudioTestSignals.percentile(a, 0.2)
        let pauses = a.indices.filter { a[$0] <= quietest }
        let loud = try Measurements.loudness(output, in: path)
        let seg = segmentLevels(output), segIn = segmentLevels(input)
        let limit = limiterActivity(Rendering(output: output, unlimited: Array(r.unlimited[0..<min(count, r.unlimited.count)])))
        var line = "LEV \(n) | \(name) | \(f(loud.lufs)) LUFS / \(f(loud.lra)) LU | speech \(f(speechLevel(input))) -> \(f(speechLevel(output))) | seg out \(f(seg.min() ?? .nan))..\(f(seg.max() ?? .nan)) (in \(f(segIn.min() ?? .nan))..\(f(segIn.max() ?? .nan)))"
        line += " | pause \(f(mean(input, at: pauses))) -> \(f(mean(output, at: pauses))) | limiter worst \(f(limit.worst)) dB, \(f(limit.share * 100, 2))% of frames"
        line += " | " + (try Measurements.excerptMetrics("", input: input, output: output, path: path)).components(separatedBy: "| peak").last.map { "peak" + $0 }!
        return line
    }

    // MARK: Tests

    /// Tunes the compressor after G: for each excerpt, the loudness and limiter activity of the
    /// base G with each compressor, to choose settings that land the integrated loudness at −18 to
    /// −16 LUFS on every excerpt without the limiter working hard.
    @Test func tune() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        for (i, file) in files.enumerated() {
            let material = try await Self.material(i + 1, file, path: path)
            let rows = try Self.parallel(Self.compressors.count) { k -> String in
                let variant = Variant(name: "G", compressor: Self.compressors[k].1)
                let r = try Self.render(variant, isolated: material.isolated, path: path)
                let loud = try Measurements.loudness(r.output, in: path)
                let limit = Self.limiterActivity(r)
                return "TUNE \(i + 1) | \(Self.compressors[k].0) | \(f(loud.lufs)) LUFS / \(f(loud.lra)) LU | limiter worst \(f(limit.worst)) dB, \(f(limit.share * 100, 2))%"
            }
            rows.forEach { print($0) }
        }
    }

    /// Runs every candidate on every excerpt: `current` (production), `isolation-only`, `E2-t0`
    /// (a static gain per excerpt, the upper bound of the old family) and the G variants, at
    /// 100% wet; prints `LEV` lines (`report`); with `BEEPBAR_AUDIO_AB_OUT` also writes, per
    /// excerpt, `<n>-<label>__original|current|new|original-loud.wav` (16-bit).
    /// `original-loud` is the original with one static gain (and the limiter) to the same
    /// integrated loudness as `new`, so a listener can tell what the chain adds over just
    /// turning it up. Proves nothing by itself: the numbers and the ear choose.
    @Test func renders() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let env = ProcessInfo.processInfo.environment
        let labels = (env["BEEPBAR_AUDIO_LEVELER_LABELS"] ?? "").split(separator: ",").map(String.init)
        let best = env["BEEPBAR_AUDIO_LEVELER_BEST"] ?? "G"
        let out = env["BEEPBAR_AUDIO_AB_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let path = try Path()
        defer { path.remove() }
        let e2 = try #require(Measurements.all.first { $0.name == "E2-t0" })
        for (i, file) in files.enumerated() {
            let n = i + 1
            let material = try await Self.material(n, file, path: path)
            let raw = path.folder.appendingPathComponent("src-\(n)-iso100.raw")
            if !FileManager.default.fileExists(atPath: raw.path) { try AudioTestSignals.writeRaw16(material.isolated, to: raw) }
            let gain = try Path.gain(.lecture, measuring: raw)
            print("LEV \(n) | E2-t0 static gain \(f(gain)) dB")
            let names = ["current", "isolation-only", "E2-t0"] + Self.variants.map(\.name)
            let renderings = try Self.parallel(names.count) { k -> Rendering in
                switch names[k] {
                case "current": return try Self.render(chain: AudioEnhancement.isolatedChain, pregain: nil, raw: raw, path: path)
                case "isolation-only": return try Self.render(chain: "anull", pregain: nil, raw: raw, path: path)
                case "E2-t0": return try Self.render(chain: e2.chain, pregain: gain, raw: raw, path: path)
                default: return try Self.render(Self.variants[k - 3], isolated: material.isolated, path: path)
                }
            }
            print("LEV \(n) | original | " + (try Measurements.loudness(material.input, in: path)).lufs.description + " LUFS")
            for (name, r) in zip(names, renderings) {
                print(try Self.report(n, name, input: material.input, r, path: path))
                print(Self.hiss(n, name, isolated: material.isolated, output: r.output))
            }
            for variant in Self.variants where variant.leveler.ceilingHeadroom != nil && variant.name.hasPrefix("G") && !variant.name.contains("exp") {
                let curve = variant.leveler.curve(over: .init(material.isolated, end: material.isolated.count))
                print("CEIL \(n) | \(variant.name) (headroom \(f(variant.leveler.ceilingHeadroom!, 0)) dB) acts on \(f(curve.ceilingActivity(over: 0..<material.isolated.count) * 100, 2))% of the non-silent 10 ms instants")
            }
            if let jump = Self.largestJump(material.isolated) {
                for (name, r) in zip(names, renderings) where name.hasPrefix("G") || name == "current" {
                    print("JUMP \(n) | \(name) | largest rise \(f(jump.rise)) dB at \(f(Double(jump.at) / Double(rate), 0)) s | limiter worst in the 12 s after \(f(Self.limiterActivity(r, over: jump.at..<min(r.output.count, jump.at + 12 * rate)).worst)) dB")
                }
            }
            guard let out else { continue }
            let label = i < labels.count ? labels[i] : "excerpt"
            func write(_ suffix: String, _ samples: [Float]) throws {
                try AudioTestSignals.writeWAV16(samples, to: out.appendingPathComponent("\(n)-\(label)__\(suffix).wav"))
            }
            let new = try #require(zip(names, renderings).first { $0.0 == best }?.1.output)
            try write("original", material.input)
            try write("current", renderings[0].output)
            try write("new", new)
            // One static gain to the integrated loudness of `new`, twice, as the limiter trims
            // what the first guess lets through.
            let target = try Measurements.loudness(new, in: path).lufs
            var dB = target - (try Measurements.loudness(material.input, in: path)).lufs
            var loud = try Self.run(material.input, chain: String(format: "volume=%.2fdB,", dB) + Measurements.limiter, in: path)
            dB += target - (try Measurements.loudness(loud, in: path)).lufs
            loud = try Self.run(material.input, chain: String(format: "volume=%.2fdB,", dB) + Measurements.limiter, in: path)
            try write("original-loud", loud)
            print("LEV \(n) | original-loud static gain \(f(dB)) dB -> \(f(try Measurements.loudness(loud, in: path).lufs)) LUFS (new \(f(target)))")
        }
    }


    // MARK: Hiss

    /// The residue between words, from the isolator's own output. `isolated` fixes which 20 ms
    /// frames are residue: active (above −100 dBFS: not the digital silence of a pause) and at
    /// least 30 dB under the isolated speech level (90th percentile of its active frames). The
    /// same frames are then read in `output`. Columns: residue frames' share of the active ones;
    /// their median level, absolute and relative to `output`'s speech level (90th percentile of
    /// its active frames); the share above −55 dBFS and the share within 35 dB of the speech
    /// (the owner's thresholds for audible hiss); and the level on the digital-silence frames.
    static func hiss(_ n: Int, _ name: String, isolated: [Float], output: [Float]) -> String {
        let small = rate / 50
        let count = min(isolated.count, output.count)
        let a = AudioTestSignals.frameLevels(Array(isolated[0..<count]), frame: small, in: 0..<count)
        let b = AudioTestSignals.frameLevels(Array(output[0..<count]), frame: small, in: 0..<count)
        let active = a.indices.filter { a[$0] > -100 }
        let isoSpeech = AudioTestSignals.percentile(active.map { a[$0] }, 0.9)
        let residue = active.filter { a[$0] <= isoSpeech - 30 }
        let outSpeech = AudioTestSignals.percentile(b.indices.filter { b[$0] > -100 }.map { b[$0] }, 0.9)
        let levels = residue.map { b[$0] }
        let silent = a.indices.filter { a[$0] <= -100 }.map { b[$0] }
        let share = { (test: (Double) -> Bool) in Double(levels.filter(test).count) / Double(max(levels.count, 1)) * 100 }
        return "HISS \(n) | \(name) | residue \(f(Double(residue.count) / Double(max(active.count, 1)) * 100, 0))% of active frames | median \(f(AudioTestSignals.percentile(levels, 0.5))) dBFS, \(f(AudioTestSignals.percentile(levels, 0.5) - outSpeech)) dB re speech (\(f(outSpeech))) | p90 \(f(AudioTestSignals.percentile(levels, 0.9))) | above -55 dBFS \(f(share { $0 > -55 }, 0))% | within 35 dB of speech \(f(share { $0 > outSpeech - 35 }, 0))% | silent frames \(f(Double(silent.count) / Double(max(a.count, 1)) * 100, 0))% at median \(f(AudioTestSignals.percentile(silent, 0.5)))"
    }

    // MARK: Isolator level invariance

    /// Is the isolator level-invariant? `BEEPBAR_AUDIO_LEVELER_INVARIANCE=<n>:<dB>,...` (n is the
    /// excerpt's number, dB the gain applied before isolation: +40 for a quiet lecture, −40 for a
    /// normal one). For each, `isolate(x)` is compared with `isolate(x × gain)` scaled back, as
    /// float, frame by frame (20 ms): the difference's level in dBFS and dB under the signal,
    /// separately for speech frames (isolated level within 25 dB of its 90th percentile) and
    /// other active frames; the residue level of each, and the word-ending metric of each against
    /// the other. Within about 1 dB of agreement the leveler can stay after isolation; a clear
    /// margin for the pre-lifted one would mean a coarse pre-gain before it.
    @Test func levelInvariance() async throws {
        let spec = (ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_LEVELER_INVARIANCE"] ?? "").split(separator: ",").compactMap { part -> (Int, Double)? in
            let pair = part.split(separator: ":")
            guard pair.count == 2, let n = Int(pair[0]), let dB = Double(pair[1]) else { return nil }
            return (n, dB)
        }
        let files = Self.excerptFiles
        guard !spec.isEmpty, !files.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        for (n, dB) in spec where n >= 1 && n <= files.count {
            let material = try await Self.material(n, files[n - 1], path: path)
            let factor = Float(pow(10, dB / 20))
            let scaled = material.input.map { $0 * factor }
            let raw = try await path.prepare(scaled, front: .isolated, name: "inv-\(n)")
            let lifted = try AudioTestSignals.rawSamples(raw).map { $0 / factor }
            let plain = material.isolated
            let count = min(plain.count, lifted.count)
            let small = rate / 50
            let a = AudioTestSignals.frameLevels(Array(plain[0..<count]), frame: small, in: 0..<count)
            let diff = (0..<count).map { lifted[$0] - plain[$0] }
            let d = AudioTestSignals.frameLevels(diff, frame: small, in: 0..<count)
            let active = a.indices.filter { a[$0] > -100 }
            let top = AudioTestSignals.percentile(active.map { a[$0] }, 0.9)
            let speech = active.filter { a[$0] >= top - 25 }, rest = active.filter { a[$0] < top - 25 }
            func power(_ x: [Double], _ idx: [Int]) -> Double { 10 * log10(idx.map { pow(10, x[$0] / 10) }.reduce(0, +) / Double(max(idx.count, 1)) + 1e-20) }
            let b = AudioTestSignals.frameLevels(Array(lifted[0..<count]), frame: small, in: 0..<count)
            var line = "INV \(n) | pre-gain \(f(dB, 0)) dB (peak \(f(AudioTestSignals.peak(scaled))) dBFS)"
            for (what, idx) in [("speech", speech), ("other active", rest)] {
                let signal = power(a, idx), error = power(d, idx)
                line += " | \(what) (\(idx.count) frames): plain \(f(signal)) dBFS, scaled-back \(f(power(b, idx))) dBFS, difference \(f(error)) dBFS = \(f(signal - error)) dB under"
            }
            print(line)
            print(try Measurements.excerptMetrics("INV \(n) | plain vs pre-gain (ending, output = pre-gain)", input: Array(plain[0..<count]), output: Array(lifted[0..<count]), path: path))
            print(try Measurements.excerptMetrics("INV \(n) | pre-gain vs plain (ending, output = plain)", input: Array(lifted[0..<count]), output: Array(plain[0..<count]), path: path))
        }
    }

    // MARK: Transients

    /// A burst of non-speech sound, `rms` dBFS, `kind` of: a door slam (broadband, 80 ms, fast
    /// decay), a desk knock (low-passed, 60 ms), a chair scrape (band-limited, 400 ms swell),
    /// keyboard clicks (six 3 ms ticks, 150 ms apart) or a cough (band-limited noise and a
    /// 180 Hz buzz, 250 ms, sharp attack). Deterministic.
    static func burst(_ kind: String, rms: Double, seed: UInt64) -> [Float] {
        var generator = Measurements.SeededGenerator(state: seed)
        func noise(_ n: Int) -> [Double] { (0..<n).map { _ in generator.unit() * 2 } }
        func onePole(_ x: [Double], cutoff: Double, highpass: Bool = false) -> [Double] {
            let alpha = 1 - exp(-2 * Double.pi * cutoff / Double(rate))
            var y = 0.0
            return x.map { v in y += alpha * (v - y); return highpass ? v - y : y }
        }
        let n80 = rate * 8 / 100
        var signal: [Double]
        switch kind {
        case "door": signal = noise(n80).enumerated().map { $1 * exp(-Double($0) / Double(rate) / 0.02) }
        case "knock": signal = onePole(onePole(noise(rate * 6 / 100), cutoff: 300), cutoff: 300).enumerated().map { $1 * exp(-Double($0) / Double(rate) / 0.015) }
        case "scrape":
            let n = rate * 4 / 10
            signal = onePole(onePole(noise(n), cutoff: 3000), cutoff: 800, highpass: true).enumerated().map { $1 * pow(sin(Double.pi * Double($0) / Double(n)), 2) }
        case "clicks":
            signal = [Double](repeating: 0, count: rate * 9 / 10)
            for c in 0..<6 { for j in 0..<(rate * 3 / 1000) { signal[c * rate * 15 / 100 + j] = generator.unit() * 2 * exp(-Double(j) / Double(rate) / 0.001) } }
        default:
            let n = rate / 4
            let hiss = onePole(onePole(noise(n), cutoff: 2500), cutoff: 500, highpass: true)
            signal = (0..<n).map { i in
                let t = Double(i) / Double(rate)
                let buzz = (1...8).reduce(0.0) { $0 + sin(2 * Double.pi * 180 * Double($1) * t) / Double($1) }
                return (hiss[i] * 2 + 0.3 * buzz) * (min(1, t / 0.01) * exp(-t / 0.09))
            }
        }
        let power = signal.reduce(0) { $0 + $1 * $1 } / Double(signal.count)
        let scale = pow(10, rms / 20) / max(power.squareRoot(), 1e-12)
        return signal.map { Float($0 * scale) }
    }

    /// What survives isolation of non-speech sounds and what the chain does to them. A 90 s
    /// classroom (near teacher, students −20, noise −35 dB re the teacher) at a normal level
    /// (`gain` 0) and a quiet one (−40) gets 18 bursts, alternating in the teacher's pauses and
    /// under her speech, five kinds, levels −10, −4, 0 and +6 dB re the teacher's speech. Prints
    /// per burst: the level it was added at, the level of what survives isolation (isolated scene
    /// minus the isolated scene without bursts, over the burst) and, after G's chain, the
    /// burst's peak. Then, for the whole scene: the limiter's worst reduction, samples at or over
    /// full scale, and the largest change of any keypoint's gain, and the ceiling's, with the bursts against
    /// without. And a scene of bursts alone, isolated: how many keypoints hold (a window of
    /// only bursts must), and the gain of those that do not.
    @Test func transients() async throws {
        let path = try Path()
        defer { path.remove() }
        let kinds = ["door", "knock", "scrape", "clicks", "cough"], levels = [-10.0, -4, 0, 6]
        let room = Measurements.classroom
        let seconds = 90
        let base = Measurements.mix(Measurements.Cell(gain: 0, students: -20, noise: -35), seconds: seconds)
        let slots = zip(room.pauses.filter { $0.upperBound <= seconds * rate }, room.speech.filter { $0.upperBound <= seconds * rate }).flatMap { [("pause", $0), ("speech", $1)] }
        var placed: [(kind: String, level: Double, where: String, range: Range<Int>, samples: [Float])] = []
        for (i, slot) in slots.prefix(18).enumerated() {
            let kind = kinds[i % kinds.count], level = levels[(i / 2) % levels.count]
            let samples = Self.burst(kind, rms: -22 + level, seed: UInt64(1000 + i))
            let start = slot.1.lowerBound + max(0, (slot.1.count - samples.count) / 2)
            placed.append((kind, level, slot.0, start..<(start + samples.count), samples))
        }
        var withBursts = base
        for b in placed { for (j, v) in b.samples.enumerated() where b.range.lowerBound + j < withBursts.count { withBursts[b.range.lowerBound + j] += v } }
        var aloneScene = (0..<base.count).map { _ in Float(0) }
        for b in placed { for (j, v) in b.samples.enumerated() where b.range.lowerBound + j < aloneScene.count { aloneScene[b.range.lowerBound + j] += v } }
        for gain in [0.0, -40.0] {
            let factor = Float(pow(10, gain / 20))
            func isolate(_ scene: [Float], _ name: String) async throws -> [Float] {
                let raw = try await path.prepare(scene.map { $0 * factor }, front: .isolated, name: name)
                return try AudioTestSignals.rawSamples(raw)
            }
            let isoBase = try await isolate(base, "t-base-\(Int(-gain))")
            let isoBursts = try await isolate(withBursts, "t-burst-\(Int(-gain))")
            let isoAlone = try await isolate(aloneScene, "t-alone-\(Int(-gain))")
            let variant = Self.variants[0]
            let rendering = try Self.render(variant, isolated: isoBursts, path: path)
            for b in placed {
                let window = b.range.lowerBound..<min(b.range.upperBound + rate / 20, isoBase.count)
                let survivor = window.map { isoBursts[$0] - isoBase[$0] }
                let nominal = AudioTestSignals.level(b.samples.map { $0 * factor }.map { $0 }, over: [0..<b.samples.count])
                let peakOut = rendering.output[window].reduce(0) { max($0, abs($1)) }
                print("TRANS gain \(f(gain, 0)) | \(b.kind) \(b.where) \(f(b.level, 0)) dB re teacher | added \(f(nominal)) dBFS | survives isolation \(f(AudioTestSignals.level(survivor, over: [0..<survivor.count]))) dBFS (\(f(AudioTestSignals.level(survivor, over: [0..<survivor.count]) - nominal)) dB) | peak after chain \(f(20 * log10(Double(peakOut) + 1e-9))) dBFS")
            }
            let clipped = rendering.output.filter { abs($0) >= 0.999 }.count
            let limit = Self.limiterActivity(rendering)
            let plain = variant.leveler.curve(over: .init(isoBase, end: isoBase.count)), burst = variant.leveler.curve(over: .init(isoBursts, end: isoBursts.count))
            let last = isoBase.count / (10 * rate)
            let keypoints = (1...last).map { abs(burst.keypoint($0) - plain.keypoint($0)) }
            let applied = stride(from: 0, to: min(isoBase.count, isoBursts.count), by: rate / 50).map { abs(burst.appliedGainDB(at: $0) - plain.appliedGainDB(at: $0)) }
            print("TRANS gain \(f(gain, 0)) | scene: limiter worst \(f(limit.worst)) dB, samples at full scale \(clipped), peak \(f(AudioTestSignals.peak(rendering.output))) dBFS | keypoint gain with vs without bursts: max \(f(keypoints.max() ?? 0, 2)) dB, median \(f(AudioTestSignals.percentile(keypoints, 0.5), 2)) dB | applied gain (with ceiling): max \(f(applied.max() ?? 0, 2)) dB")
            let alone = variant.leveler.curve(over: .init(isoAlone, end: isoAlone.count))
            let kinds = (1...(isoAlone.count / (10 * rate))).map { alone.measure($0) }
            let holds = kinds.filter { $0 == .hold }.count
            let gains = kinds.compactMap { m -> Double? in if case .gain(let g) = m { return g } else { return nil } }
            print("TRANS gain \(f(gain, 0)) | bursts alone: \(holds) of \(kinds.count) keypoints hold; the others measure gains \(gains.map { f($0) }.joined(separator: ", ")) dB; isolated bursts-only level p90 of 400 ms frames \(f(Self.speechLevel(isoAlone))) dBFS (added: \(f(Self.speechLevel(aloneScene.map { $0 * factor }))))")
        }
    }

    // MARK: Seams

    /// The largest difference, in dB, between the gain a piece rendered alone gets and the
    /// whole lecture's, over `piece` sampled every 20 ms. A piece sees `lead` seconds before
    /// itself and `tail` after.
    static func seamDifference(_ leveler: KeypointLeveler, whole: KeypointLeveler.Curve, samples: [Float], piece: Range<Int>, lead: Double, tail: Double) -> Double {
        let visible = max(0, piece.lowerBound - Int(lead * Double(rate)))..<min(samples.count, piece.upperBound + Int(tail * Double(rate)))
        let alone = leveler.curve(over: .init(samples, visible: visible))
        return stride(from: piece.lowerBound, to: piece.upperBound, by: rate / 50).map { abs(alone.appliedGainDB(at: $0) - whole.appliedGainDB(at: $0)) }.max() ?? 0
    }

    /// Whether a piece rendered alone gets the whole lecture's gain curve. Three tables, only
    /// differences in dB (0.00 is exact):
    /// - leads of 15 s, 4 s (today's production lead) and 0 s, tails of 0, 0.5 s (production) and
    ///   10 s, for 30 s pieces that start on a lecture's multiple of 30 s (as Webex fragments do),
    ///   and for a piece that starts between keypoints;
    /// - the same after a long digital silence, where the hold rule chains: for several bounds
    ///   `maxHold` and leads, which lead is exact (`requiredLead`) and that an unbounded hold has
    ///   none.
    /// A mutation guard: a leveler whose keypoint read audio after itself would show a nonzero
    /// difference at lead 15 and tail 0.
    @Test func seams() async throws {
        let files = Self.excerptFiles
        guard !files.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        for (i, file) in files.enumerated() {
            let n = i + 1
            let samples = try await Self.material(n, file, path: path).isolated
            for spacing in [10.0, 5.0] {
                var leveler = KeypointLeveler()
                leveler.spacing = spacing
                let whole = leveler.curve(over: .init(samples, end: samples.count))
                for (what, start) in [("aligned", 60), ("aligned", 90), ("aligned", 120), ("between keypoints", 65)] {
                    let piece = (start * rate)..<((start + 30) * rate)
                    var row = "SEAM \(n) | spacing \(f(spacing, 0)) | piece \(what) at \(start) s"
                    for lead in [15.0, 4.0, 0.0] {
                        row += " | lead \(f(lead, 0)):"
                        for tail in [0.0, 0.5, 10.0] {
                            row += " tail \(f(tail, 1)) \(f(Self.seamDifference(leveler, whole: whole, samples: samples, piece: piece, lead: lead, tail: tail), 2))"
                        }
                    }
                    print(row)
                }
            }
            guard i == 0 else { continue }
            // A long silence in the isolated audio: the hold rule chains back through it.
            for (silence, piece) in [(60..<120, 120), (30..<150, 150)] {
                var edited = samples
                for k in (silence.lowerBound * rate)..<(silence.upperBound * rate) { edited[k] = 0 }
                for bound in [nil, 0, 2, 5] as [Int?] {
                    var leveler = KeypointLeveler()
                    leveler.maxHold = bound
                    let whole = leveler.curve(over: .init(edited, end: edited.count))
                    var row = "HOLD \(n) | silence \(silence.lowerBound)-\(silence.upperBound) s, piece at \(piece) s | maxHold \(bound.map(String.init) ?? "none") (requiredLead \(leveler.requiredLead.map { f($0, 0) } ?? "unbounded"))"
                    for lead in [15.0, 32.0, 62.0, 100.0, Double(piece)] {
                        row += " | lead \(f(lead, 0)): \(f(Self.seamDifference(leveler, whole: whole, samples: edited, piece: (piece * rate)..<((piece + 30) * rate), lead: lead, tail: 0), 2))"
                    }
                    print(row)
                }
            }
        }
    }

    // MARK: Whole lecture

    /// G alone over a whole lecture (`BEEPBAR_AUDIO_LEVELER_LECTURE`): the gain curve summary,
    /// how the speech level of each 10 minutes changes, and the time the Swift part takes
    /// (decode and isolation are timed apart). The lecture is processed in 10-minute chunks so
    /// the output never sits in memory whole.
    @Test func wholeLecture() async throws {
        guard let lecture = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_LEVELER_LECTURE"], !lecture.isEmpty else { return }
        let path = try Path()
        defer { path.remove() }
        let wav = path.folder.appendingPathComponent("whole.wav")
        let raw = path.folder.appendingPathComponent("whole.raw")
        var clock = Date()
        func lap() -> String { defer { clock = Date() }; return f(Date().timeIntervalSince(clock), 1) }
        let process = Process()
        process.executableURL = path.ffmpeg
        process.arguments = ["-nostdin", "-loglevel", "quiet", "-y", "-i", lecture, "-map", "0:a:0", "-vn", "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", wav.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "the lecture could not be read as audio")
        print("WHOLE decode \(lap()) s")
        var isolator = try #require(AppleVoiceIsolator.preferred())
        isolator.wetDryMix = 100
        try await isolator.isolate(wav, from: 0, count: nil, to: raw)
        try? FileManager.default.removeItem(at: wav)
        print("WHOLE isolation \(lap()) s")
        let samples = try AudioTestSignals.rawSamples(raw)
        try? FileManager.default.removeItem(at: raw)
        print("WHOLE read \(lap()) s, \(f(Double(samples.count) / Double(rate) / 60, 1)) min")

        let leveler = KeypointLeveler()
        let curve = leveler.curve(over: .init(samples, end: samples.count))
        let last = samples.count / (10 * rate)
        let summary = curve.summary(through: last)
        print("WHOLE keypoints \(summary.count) | gain min \(f(summary.min)) median \(f(summary.median)) max \(f(summary.max)) dB | holds \(summary.holds) | largest change between consecutive keypoints \(f(summary.largestStep)) dB | curve \(lap()) s")
        let chunk = 600 * rate
        var applyTime = 0.0
        for (index, start) in stride(from: 0, to: samples.count, by: chunk).enumerated() {
            let range = start..<min(samples.count, start + chunk)
            let began = Date()
            let leveled = curve.apply(to: range)
            applyTime += Date().timeIntervalSince(began)
            let before = Self.frames(samples, range)
            let after = Self.frames(leveled)
            let voiced = after.filter { $0 > -95 }
            print("WHOLE minutes \(index * 10)-\(index * 10 + 10) | speech p90 in \(f(AudioTestSignals.percentile(before, 0.9))) out \(f(AudioTestSignals.percentile(after, 0.9))) | voiced frames \(f(Double(voiced.count) / Double(max(after.count, 1)) * 100, 0))% | gain \(f(curve.gainDB(at: range.lowerBound))) -> \(f(curve.gainDB(at: range.upperBound - 1))) dB")
        }
        print("WHOLE apply (Swift, all samples) \(f(applyTime, 1)) s")
    }
}
