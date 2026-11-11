import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// On-demand measurement of how well "Audio migliorato" keeps a teacher's voice at any distance
/// from the microphone, never part of the regular `swift test`:
/// `BEEPBAR_MEASURE_AUDIO_QUALITY=1 swift test --filter AudioQualityMeasurements`
/// (`docs/benchmarks.md`, "Enhanced audio quality"). Synthetic audio only, made on the spot.
///
/// Why it exists: `AudioEnhancement.isolatedChain` ends in `speechnorm` and an `agate` whose
/// threshold is a fixed absolute level, so what a student hears depends on how loud the teacher
/// was recorded: a close teacher leaves the background voices raised, a distant one has word
/// endings and soft consonants cut. The suite builds a classroom from separate stems with known
/// speech and pause regions, scales the whole scene (and, in one case, only the teacher) and
/// reports, per processing path, what each filter chain does to level, pauses and soft speech.
///
/// A processing path is `front` then `chain`: `front` is Apple's voice isolation (100% or a
/// wet/dry mix) or nothing (so the chain's own effect is separate from the unit's), `chain` is
/// the ffmpeg filter the candidate defines, fed the unit's raw 16-bit output the way
/// `isolatedEncodeArguments` feeds it, but written as float WAV (no video, no AAC).
///
/// Environment:
/// - `BEEPBAR_AUDIO_ONLY=name,name`: run only those candidates (plus `current` and `isolation-only`), to iterate.
/// - `BEEPBAR_AUDIO_QUICK=1`: only students −20 in the matrix.
/// - `BEEPBAR_AUDIO_AB_OUT=<dir>`: also write A/B renders there (`abRenders`).
/// - `BEEPBAR_AUDIO_EXCERPT=<file>[,<file>]`: with `BEEPBAR_AUDIO_AB_OUT`, render the same set from
///   the first audio track (at most 180 s) of each local file, and `BEEPBAR_AUDIO_EXCERPT_ONLY=1`
///   skips the synthetic scenes. They are private data: read only here, never copied into the
///   repository, and their names and contents are never printed.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BEEPBAR_MEASURE_AUDIO_QUALITY"] == "1" && AudioEnhancement.locateFFmpeg() != nil
                             && AudioTestSignals.canSpeak, "on demand: BEEPBAR_MEASURE_AUDIO_QUALITY=1"))
struct AudioQualityMeasurements {
    // MARK: Candidates

    /// A filter chain under test: what follows the voice-isolation step in `isolatedEncodeArguments`.
    struct Candidate: Sendable {
        let name: String
        let chain: String
        /// A static gain computed from the isolated audio and applied before `chain` (family E).
        var pregain: PreGain?
    }

    /// Where a static pre-gain is measured: it brings the 95th percentile of 400 ms RMS frames of
    /// the audio it reads to `PreGain.target` dBFS.
    /// - `lecture`: the whole lecture, known before the first piece plays: an upper bound on what
    ///   production could do (it can't decode and isolate everything up front);
    /// - `first(seconds)`: only the first seconds of the lecture, measured once and held for every piece;
    /// - `piece`: each piece's own audio, so the gain can change at every join.
    enum PreGain: Sendable {
        case lecture, first(Int), piece
        static let target = -22.0
        static let ceiling = 50.0
    }

    /// What `AudioEnhancement.isolatedChain` begins with, kept by every candidate: rumble and
    /// hiss filters and the two speech equalizers.
    private static let prefix = "highpass=f=90,lowpass=f=10000,equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1.4:g=3"
    /// Where every chain ends: a limiter that keeps peaks at −1.9 dBFS and adds no delay.
    private static let limiter = "alimiter=limit=0.8:level=disabled:latency=1"

    /// The candidates. `current` is production, verbatim; the rest are strings defined here, never
    /// in production code, until one is chosen.
    ///
    /// `leveler` (`dynaudnorm`) works in 250 ms frames and smooths its gain over `g` of them (a
    /// Gaussian window, so `g=51` averages about 12 s): slow enough to ride the teacher's distance
    /// rather than each syllable, which is what `speechnorm` does and what raised the room's
    /// voices in pauses. `t` is the input peak below which a frame is left out of the level
    /// estimate, so pauses are not normalized on their own. After it speech sits at a known level,
    /// so the gentle downward expander's fixed threshold (`agate` with ratio 1.5, range 0.35: at
    /// most 9 dB down, against 18 for the production gate) is relative to the teacher.
    static let all: [Candidate] = {
        func leveler(g: Int, m: Int, t: String? = nil) -> String { "dynaudnorm=f=250:g=\(g):p=0.5:m=\(m):b=1" + (t.map { ":t=\($0)" } ?? "") }
        func expander(_ threshold: String, ratio: String = "1.5", range: String = "0.35") -> String {
            "agate=threshold=\(threshold):ratio=\(ratio):range=\(range):attack=10:release=400:knee=6:detection=rms"
        }
        /// Peaks above −18 dBFS squeezed 3:1, then +3.5 dB.
        let compressor = "acompressor=threshold=0.125:ratio=3:attack=10:release=200:knee=4:makeup=1.5"
        func chain(_ parts: String...) -> String { ([prefix] + parts + [limiter]).joined(separator: ",") }
        let all = [
            Candidate(name: "current", chain: AudioEnhancement.isolatedChain),
            Candidate(name: "isolation-only", chain: "anull"),
            Candidate(name: "C1", chain: chain(leveler(g: 51, m: 50), expander("0.02"))),
            Candidate(name: "C2", chain: chain(leveler(g: 51, m: 50))),
            // D: no gate. After isolation the steady noise is gone, so a gate buys little and is
            // what chops soft speech. `t=0.003` leaves frames whose peak is under −50 dBFS out of
            // the level estimate; `m` caps the gain a long pause can be raised by (m=50 allowed
            // +34 dB, the "noise remains" failure).
            Candidate(name: "D1-m6", chain: chain(leveler(g: 51, m: 6, t: "0.003"), compressor)),
            Candidate(name: "D1-m10", chain: chain(leveler(g: 51, m: 10, t: "0.003"), compressor)),
            Candidate(name: "D1-m16", chain: chain(leveler(g: 51, m: 16, t: "0.003"), compressor)),
            // D2: D1 and a very gentle expander (at most 6 dB down).
            Candidate(name: "D2", chain: chain(leveler(g: 51, m: 10, t: "0.003"), compressor, expander("0.02", ratio: "1.5", range: "0.5"))),
            // E: for a teacher recorded 25 to 45 dB under a normal level (real excerpts: −41 and
            // −51 LUFS). E1: one pass, the leveler alone with a large maximum gain and a low input
            // threshold (−54 dBFS) so the −90 dBFS floor is left alone. E2: a static pre-gain
            // brings speech to a fixed level first, then D1 unchanged.
            Candidate(name: "E1", chain: chain(leveler(g: 51, m: 80, t: "0.002"), compressor)),
            // The `t` variants: the ending metric showed that the input threshold, which leaves
            // quiet frames at unity gain, is what cuts the last 120 ms of a sentence (the tail
            // falls under −50 dBFS and the gain jumps back), so the threshold is tried lower or off.
            Candidate(name: "D1-t0", chain: chain(leveler(g: 51, m: 10), compressor)),
            Candidate(name: "D1-t0003", chain: chain(leveler(g: 51, m: 10, t: "0.0003"), compressor)),
            Candidate(name: "E1-t0003", chain: chain(leveler(g: 51, m: 80, t: "0.0003"), compressor)),
            Candidate(name: "E2-t0", chain: chain(leveler(g: 51, m: 10), compressor), pregain: .lecture),
            Candidate(name: "E2", chain: chain(leveler(g: 51, m: 10, t: "0.003"), compressor), pregain: .lecture),
            Candidate(name: "E2-first20", chain: chain(leveler(g: 51, m: 10, t: "0.003"), compressor), pregain: .first(20)),
            Candidate(name: "E2-piece", chain: chain(leveler(g: 51, m: 10, t: "0.003"), compressor), pregain: .piece),
        ]
        guard let only = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_ONLY"] else { return all }
        let names = Set(only.split(separator: ",").map(String.init))
        return all.filter { $0.name == "current" || $0.name == "isolation-only" || names.contains($0.name) }
    }()

    /// The candidates run behind a wet/dry front (90%, 85%): the D and E families, with `current` and
    /// `isolation-only` as the references the ending metric needs.
    static func runs(on front: Front) -> [Candidate] {
        all.filter { candidate in
            if candidate.name == "isolation-only" { return front.wet != nil }
            return front.wet == nil || front.wet == 100 || candidate.name.hasPrefix("D") || candidate.name.hasPrefix("E") || candidate.name == "current"
        }
    }

    // MARK: Synthetic classroom

    /// One scene: a teacher with known speech and pause regions, students, steady noise. Stems
    /// are scaled so a stem's RMS is the teacher's speech RMS (−22 dBFS at gain 0), so every
    /// level below is "dB relative to the teacher".
    struct Classroom {
        let teacher: [Float]
        /// The same sentences through a reverberant room (`farTeacher`), 10 dB quieter than `teacher`.
        let far: [Float]
        let students: [Float]
        let noise: [Float]
        /// Where the teacher speaks, each region one sentence trimmed of its silent edges.
        let speech: [Range<Int>]
        /// Where she doesn't: at least 4 s, trimmed 0.5 s each side so a release time or the
        /// unit's tail doesn't count as pause.
        let pauses: [Range<Int>]
    }

    /// 90 s: nine sentences, one every 10 s, each followed by a pause of 5 s or more.
    static let classroom: Classroom = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-quality-stems-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do { return try makeClassroom(in: folder) } catch { fatalError("synthetic classroom: \(error)") }
    }()

    private static let sentences = [
        "Today we study the conditioning of a linear system.",
        "When the matrix is nearly singular, a small change moves the solution.",
        "The determinant alone does not measure how close we are to singular.",
        "Remember that the condition number multiplies the relative error.",
        "Let us compute it together for this two by two example.",
        "Notice how the second row almost repeats the first one.",
        "That is why the solution changed so much with a tiny perturbation.",
        "In practice we scale the rows before solving the system.",
        "For next week, please finish the exercises on the sheet.",
    ]

    private static func makeClassroom(in folder: URL) throws -> Classroom {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ffmpeg = try #require(AudioEnhancement.locateFFmpeg())
        let rate = AudioTestSignals.sampleRate
        let say = URL(fileURLWithPath: "/usr/bin/say")
        let total = 90 * rate
        var teacher = [Float](repeating: 0, count: total)
        var speech: [Range<Int>] = []
        for (k, text) in sentences.enumerated() {
            let spoken = folder.appendingPathComponent("t\(k).aiff"), wav = folder.appendingPathComponent("t\(k).wav")
            try AudioTestSignals.run(say, ["-o", spoken.path, text], in: folder)
            try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-i", spoken.path, "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", wav.path], in: folder)
            let voice = try AudioTestSignals.samples(wav)
            // Trim the synthesizer's silent edges so the region is the voice.
            let floor = 0.01 * (voice.map { abs($0) }.max() ?? 1)
            let first = voice.firstIndex { abs($0) > floor } ?? 0, last = voice.lastIndex { abs($0) > floor } ?? voice.count - 1
            let start = k * 10 * rate + rate / 5
            guard last - first < Int(4.8 * Double(rate)) else { throw MeasurementError.sentenceTooLong(k) }
            for (i, s) in voice[first...last].enumerated() { teacher[start + i] = s }
            speech.append(start..<(start + last - first + 1))
        }
        var pauses: [Range<Int>] = []
        for (k, region) in speech.enumerated() {
            let next = k + 1 < speech.count ? speech[k + 1].lowerBound : total
            let pause = (region.upperBound + rate / 2)..<(next - rate / 2)
            if pause.count >= 4 * rate { pauses.append(pause) }
        }
        let teacherRMS = AudioTestSignals.level(teacher, over: speech)
        teacher = teacher.map { $0 * Float(pow(10, (-22 - teacherRMS) / 20)) }

        let studentsText = "Excuse me, could you repeat the last step? I did not understand why we divide by the second pivot. Also, is the exam going to include the proofs, or only the exercises like these? Thank you, and sorry for interrupting. My neighbour also has a question about the homework, but he is too shy to ask."
        let students = try loop(say: say, ["-v", "Daniel"], text: studentsText, name: "students", seconds: 90, folder: folder, ffmpeg: ffmpeg)
        let noiseURL = folder.appendingPathComponent("noise.wav")
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y",
                                          "-f", "lavfi", "-i", "anoisesrc=c=pink:a=0.04:r=48000:d=90:seed=7",
                                          "-f", "lavfi", "-i", "sine=f=100:r=48000:d=90",
                                          "-filter_complex", "[1]volume=0.02[h];[0][h]amix=inputs=2:normalize=0",
                                          "-ac", "1", "-c:a", "pcm_f32le", noiseURL.path], in: folder)
        let reference = AudioTestSignals.level(teacher, over: speech)
        func scaled(_ x: [Float]) -> [Float] {
            let gain = Float(pow(10, (reference - AudioTestSignals.level(x[...])) / 20))
            return x.map { $0 * gain }
        }
        let far = try farTeacher(teacher, speech: speech, folder: folder, ffmpeg: ffmpeg, level: reference - 10)
        return Classroom(teacher: teacher, far: far, students: scaled(Array(students.prefix(total))), noise: scaled(try AudioTestSignals.samples(noiseURL)), speech: speech, pauses: pauses)
    }

    /// `teacher` as heard from the back of a lecture hall: convolved (ffmpeg `afir`) with a
    /// synthetic impulse response, the direct sound followed by a noise tail decaying
    /// exponentially (RT60 0.8 s, tail energy half the direct sound's), then a gentle 6 dB/octave
    /// roll-off above 5 kHz, scaled so the speech regions' RMS is `level` dBFS. Not `aecho`: a
    /// handful of discrete echoes does not smear word endings the way a diffuse tail does.
    private static func farTeacher(_ teacher: [Float], speech: [Range<Int>], folder: URL, ffmpeg: URL, level: Double) throws -> [Float] {
        let rate = AudioTestSignals.sampleRate
        var generator = SeededGenerator(state: 0x9E3779B97F4A7C15)
        let rt60 = 0.8
        var ir = [Float](repeating: 0, count: rate)
        // Σ envelope² over the tail, so the tail's energy is exactly half the direct sound's.
        let amplitude = (0.5 / (Double(rate) * rt60 / (2 * log(1000.0)))).squareRoot()
        for i in 1..<ir.count {
            let envelope = exp(-log(1000.0) * Double(i) / (rt60 * Double(rate)))
            // Three uniforms summed, ×2: unit variance and near enough to Gaussian for a diffuse tail.
            ir[i] = Float(amplitude * envelope * (generator.unit() + generator.unit() + generator.unit()) * 2)
        }
        ir[0] = 1
        let near = folder.appendingPathComponent("far-near.wav"), impulse = folder.appendingPathComponent("far-ir.wav"), out = folder.appendingPathComponent("far-out.wav")
        try AudioTestSignals.writeWAV(teacher, to: near)
        try AudioTestSignals.writeWAV(ir, to: impulse)
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-i", near.path, "-i", impulse.path,
                                          "-filter_complex", "[0][1]afir=gtype=none:irnorm=0:irgain=1,lowpass=f=5000:p=1",
                                          "-ac", "1", "-c:a", "pcm_f32le", out.path], in: folder)
        var far = try AudioTestSignals.samples(out)
        // afir adds no delay of its own, but the correlation peak of reverberant speech sits a
        // couple of milliseconds late (131 samples measured); a lag of tens of milliseconds
        // would be a misalignment of every region, so refuse that rather than carry on.
        let lag = AudioTestSignals.delay(of: Array(far[0..<(20 * rate)]), against: Array(teacher[0..<(20 * rate)]), limit: 2400)
        guard abs(lag) <= 480 else { throw MeasurementError.farTeacherMisaligned(lag) }
        far = Array(far.prefix(teacher.count)) + [Float](repeating: 0, count: max(0, teacher.count - far.count))
        let gain = Float(pow(10, (level - AudioTestSignals.level(far, over: speech)) / 20))
        return far.map { $0 * gain }
    }

    /// A small deterministic generator so the synthetic room is the same on every run.
    struct SeededGenerator {
        var state: UInt64
        /// Uniform in −0.5..<0.5.
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
    }

    private static func loop(say: URL, _ voice: [String], text: String, name: String, seconds: Int, folder: URL, ffmpeg: URL) throws -> [Float] {
        let spoken = folder.appendingPathComponent("\(name).aiff"), wav = folder.appendingPathComponent("\(name).wav")
        try AudioTestSignals.run(say, voice + ["-o", spoken.path, text], in: folder)
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-stream_loop", "-1", "-i", spoken.path, "-t", "\(seconds)",
                                          "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", wav.path], in: folder)
        return try AudioTestSignals.samples(wav)
    }

    enum MeasurementError: Error { case sentenceTooLong(Int), isolationUnavailable, farTeacherMisaligned(Int) }

    /// One point of the matrix. Levels are dB relative to the teacher at the cell's `gain`:
    /// the scene scales as a whole, so only the absolute level changes between cells with the
    /// same `students` and `noise`. `moving` instead keeps the background where it is and steps
    /// only the teacher, 0 → −20 → 0 dB every 15 s, as when she walks away from the microphone.
    struct Cell: Sendable {
        let gain: Double
        let students: Double?
        let noise: Double
        var moving = false
        /// Which teacher stem: close to the microphone, or the reverberant `far` one.
        var far = false

        var label: String {
            let room = far ? "far " : "near "
            return room + (moving ? "moving s-20 n-35" : "g\(Int(gain)) s\(students.map { "\(Int($0))" } ?? "none") n\(Int(noise))")
        }
    }

    /// The teacher's gain in dB at sample `i` of a moving cell.
    static func movingGain(at i: Int) -> Double { (i / (15 * AudioTestSignals.sampleRate)) % 2 == 0 ? 0 : -20 }

    /// The scene of `cell`, `seconds` long, mixed in float.
    static func mix(_ cell: Cell, seconds: Int) -> [Float] {
        let room = classroom
        let count = seconds * AudioTestSignals.sampleRate
        let students = cell.students.map { Float(pow(10, $0 / 20)) } ?? 0
        let noise = Float(pow(10, cell.noise / 20))
        let gain = Float(pow(10, cell.gain / 20))
        let teacher = cell.far ? room.far : room.teacher
        return (0..<count).map { i in
            let background = students * room.students[i] + noise * room.noise[i]
            if cell.moving { return Float(pow(10, movingGain(at: i) / 20)) * teacher[i] + background }
            return gain * (teacher[i] + background)
        }
    }

    /// The regions of the classroom that end within `seconds`.
    static func regions(_ all: [Range<Int>], seconds: Int) -> [Range<Int>] { all.filter { $0.upperBound <= seconds * AudioTestSignals.sampleRate } }

    /// The matrix, per teacher stem (near, far): teacher gain 0 and −20 dB × students none, −20,
    /// −30 dB, noise −35 dB, students −20 also at −30 and −40 dB (real excerpts sit 25 to 45 dB
    /// under a normal recording), plus the moving teacher. `BEEPBAR_AUDIO_QUICK=1`: only students −20.
    static let cells: [Cell] = {
        let quick = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_QUICK"] == "1"
        var cells: [Cell] = []
        for far in [false, true] {
            for students in quick ? [-20.0] : [nil, -20.0, -30.0] { for gain in students == -20 ? [0.0, -20, -30, -40] : [0.0, -20] {
                cells.append(Cell(gain: gain, students: students, noise: -35, far: far))
            } }
            cells.append(Cell(gain: 0, students: -20, noise: -35, moving: true, far: far))
        }
        return cells
    }()

    // MARK: Processing path

    /// What comes before the chain.
    struct Front: Sendable, Hashable {
        let name: String
        /// Percent of isolated voice, or nil for no isolation.
        let wet: Double?
        static let none = Front(name: "raw", wet: nil)
        static let isolated = Front(name: "iso100", wet: 100)
        static let wet90 = Front(name: "iso90", wet: 90)
        static let wetDry = Front(name: "iso85", wet: 85)
    }

    /// Runs the path in a folder of its own, removed with it.
    struct Path {
        let ffmpeg: URL
        let folder: URL
        init() throws {
            ffmpeg = try #require(AudioEnhancement.locateFFmpeg())
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-quality-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }

        /// The raw 16-bit file the chain reads: the isolator's output for `front`, or the mix
        /// quantized the same way when there is no isolation.
        func prepare(_ mix: [Float], front: Front, name: String) async throws -> URL {
            let raw = folder.appendingPathComponent("\(name)-\(front.name).raw")
            guard let wet = front.wet else { try AudioTestSignals.writeRaw16(mix, to: raw); return raw }
            let wav = folder.appendingPathComponent("\(name).wav")
            // Always rewritten: this file is shared by every scene of a test, and reusing a
            // previous scene's would isolate the wrong audio (the second `joins` scene did).
            try AudioTestSignals.writeWAV(mix, to: wav)
            guard var isolator = AppleVoiceIsolator.preferred() else { throw MeasurementError.isolationUnavailable }
            isolator.wetDryMix = wet
            try await isolator.isolate(wav, from: 0, count: nil, to: raw)
            return raw
        }

        /// The static gain, in dB, `how` gives for `source` (the raw 16-bit file it measures):
        /// the 95th percentile of 400 ms RMS frames brought to `PreGain.target`, at most
        /// `PreGain.ceiling` up, and 0 when the audio is silent.
        static func gain(_ how: PreGain, measuring source: URL) throws -> Double {
            var samples = try AudioTestSignals.rawSamples(source)
            if case .first(let seconds) = how { samples = Array(samples.prefix(seconds * AudioTestSignals.sampleRate)) }
            let frame = AudioTestSignals.sampleRate * 4 / 10
            let levels = AudioTestSignals.frameLevels(samples, frame: frame, in: 0..<samples.count)
            guard !levels.isEmpty else { return 0 }
            let top = AudioTestSignals.percentile(levels, 0.95)
            return top < -80 ? 0 : max(0, min(PreGain.ceiling, PreGain.target - top))
        }

        /// `candidate` over `raw`; a pre-gain is measured on `gainFrom` (the whole lecture's
        /// file when `raw` is one piece of it) unless it is per piece.
        func filter(_ raw: URL, candidate: Candidate, gainFrom: URL? = nil) throws -> [Float] {
            guard let how = candidate.pregain else { return try filter(raw, chain: candidate.chain) }
            var source = gainFrom ?? raw
            if case .piece = how { source = raw }
            let dB = try Self.gain(how, measuring: source)
            return try filter(raw, chain: String(format: "volume=%.2fdB,", dB) + candidate.chain)
        }

        /// ffmpeg with `chain` over `raw`, as `isolatedEncodeArguments` reads it, to a float WAV.
        func filter(_ raw: URL, chain: String) throws -> [Float] {
            let out = folder.appendingPathComponent("out-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: out) }
            try AudioTestSignals.run(ffmpeg, ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
                                              "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", raw.path,
                                              "-af", "asetpts=N/SR/TB," + chain, "-c:a", "pcm_f32le", "-f", "wav", "-y", out.path], in: folder)
            return try AudioTestSignals.samples(out)
        }
    }

    /// The fronts to run: no isolation, and with the unit 100%, 90% and 85% wet. The wet/dry
    /// mix is a main hypothesis (the unit may swallow word endings of far, reverberant speech
    /// and a little dry signal restores them); it is only meaningful because `wetDryAlignment`
    /// finds the dry path delay-aligned.
    private static var fronts: [Front] {
        guard AppleVoiceIsolator.preferred() != nil else { return [.none] }
        return [.none, .isolated, .wet90, .wetDry]
    }

    final class ConcurrentResults<T>: @unchecked Sendable {
        let lock = NSLock()
        var values: [T?]
        var failure: Error?
        init(_ count: Int) { values = Array(repeating: nil, count: count) }
    }

    /// `body` over `items` on all cores, results in order: each candidate is an independent
    /// ffmpeg run, so a matrix of hundreds takes minutes, not the better part of an hour.
    static func concurrentMap<T: Sendable>(_ items: [Candidate], _ body: @Sendable (Candidate) throws -> T) throws -> [T] {
        let results = ConcurrentResults<T>(items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            do {
                let value = try body(items[i])
                results.lock.withLock { results.values[i] = value }
            } catch {
                results.lock.withLock { results.failure = error }
            }
        }
        if let failure = results.failure { throw failure }
        return results.values.map { $0! }
    }

    // MARK: Metrics

    private static func f(_ x: Double, _ digits: Int = 1) -> String { x.isNaN ? "n/a" : String(format: "%.\(digits)f", x) }
    private static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

    /// Frame-by-frame gain of `out` over `input` (dB) on the frames of `speech` that fit whole.
    /// `out` is first lined up with `input` by cross-correlation (the delay is returned too).
    struct SoftSpeech {
        var delay = 0
        var softMean = Double.nan, softP5 = Double.nan, pumping = Double.nan
        /// Mean loss over the last 300 ms of each sentence, where audible (within 40 dB of the loud speech).
        var endingMean = Double.nan
        var softFrames = 0, loudFrames = 0
    }

    /// The "cuts voice and word endings" metric, and pumping, for a teacher-only scene.
    ///
    /// 20 ms frames inside speech regions; "loud" frames are within 12 dB of the 95th percentile
    /// of speech frame levels, "soft" ones 12 to 30 dB below it (word endings, soft consonants).
    /// Per-frame gain is out minus in; loss is a soft frame's gain minus the median gain of the
    /// loud frames, so a chain that only makes everything louder or quieter scores 0 and one that
    /// removes soft speech more than loud speech scores negative. Pumping is the standard
    /// deviation of the loud frames' gain: a steady chain scores near 0.
    static func softSpeech(input: [Float], output: [Float], speech: [Range<Int>]) -> SoftSpeech {
        let rate = AudioTestSignals.sampleRate
        var result = SoftSpeech()
        let window = 0..<min(input.count, output.count, 6 * rate)
        result.delay = AudioTestSignals.delay(of: Array(output[window]), against: Array(input[window]), limit: 2400)
        let shift = result.delay
        let frame = rate / 50
        var inLevels: [Double] = [], gains: [Double] = [], endings: [Bool] = []
        for region in speech {
            for start in stride(from: region.lowerBound, to: region.upperBound - frame + 1, by: frame) where start + shift >= 0 && start + shift + frame <= output.count {
                let a = AudioTestSignals.level(input[start..<(start + frame)])
                let b = AudioTestSignals.level(output[(start + shift)..<(start + shift + frame)])
                inLevels.append(a)
                gains.append(max(b, -120) - max(a, -120))
                endings.append(start + frame > region.upperBound - 15 * frame)
            }
        }
        guard !inLevels.isEmpty else { return result }
        let top = AudioTestSignals.percentile(inLevels, 0.95)
        let loud = zip(inLevels, gains).filter { $0.0 >= top - 12 }.map(\.1)
        let soft = zip(inLevels, gains).filter { $0.0 < top - 12 && $0.0 >= top - 30 }.map(\.1)
        let reference = AudioTestSignals.percentile(loud, 0.5)
        let losses = soft.map { $0 - reference }
        result.softMean = AudioTestSignals.mean(losses)
        result.softP5 = AudioTestSignals.percentile(losses, 0.05)
        result.pumping = AudioTestSignals.standardDeviation(loud)
        let ending = zip(zip(inLevels, gains), endings).filter { $0.1 && $0.0.0 >= top - 40 }.map { $0.0.1 - reference }
        result.endingMean = AudioTestSignals.mean(ending)
        result.softFrames = soft.count
        result.loudFrames = loud.count
        return result
    }

    /// Everything one (candidate, front, stem) accumulates over the matrix.
    struct Tally {
        var spreads: [Double] = []
        var movingNearFar = Double.nan
        var gapChanges: [Double] = []
        var softMeans: [Double] = [], softP5s: [Double] = [], pumps: [Double] = [], endings: [Double] = []
        var loudness: [Double] = []
        var peaks: [Double] = []
        var delays: [Int] = []
        var lufs = Double.nan, lra = Double.nan
    }

    /// Integrated loudness (LUFS) and loudness range (LU) of `samples`, by ffmpeg's `ebur128`:
    /// the targets to judge a chain by are about −16 to −18 LUFS and a range of at most about 6 LU.
    static func loudness(_ samples: [Float], in path: Path) throws -> (lufs: Double, lra: Double) {
        let wav = path.folder.appendingPathComponent("loud-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try AudioTestSignals.writeWAV(samples, to: wav)
        let process = Process()
        process.executableURL = path.ffmpeg
        process.arguments = ["-hide_banner", "-nostdin", "-nostats", "-i", wav.path, "-af", "ebur128", "-f", "null", "-"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // The summary at the end of the report: "    I:         -17.6 LUFS" and "    LRA:         3.2 LU".
        let summary = text.components(separatedBy: "Summary:").last ?? ""
        func value(_ label: String) -> Double {
            for line in summary.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(label + " "), let number = trimmed.dropFirst(label.count).split(separator: " ").first.flatMap({ Double($0) }) { return number }
            }
            return .nan
        }
        return (value("I:"), value("LRA:"))
    }

    // MARK: Tests

    /// Runs the whole matrix, near and far teacher, and prints, per (candidate, front, stem),
    /// one row per cell, the soft-speech and pumping measurements, the loudness of the moving
    /// scene, and a summary. Proves nothing by itself: the numbers are what a chain is chosen
    /// on. What each column guards against:
    /// - `speech out`: the teacher's level out; its spread between gain 0 and −20 (same students
    ///   and noise) is the leveling, ideally at most 3 dB (the unleveled spread is 20 dB);
    /// - `gap Δ`: (speech − pause level) out minus in; negative means the background was raised
    ///   relative to the teacher, which is "noise remains";
    /// - `soft loss`: how much more soft consonants lose than loud speech;
    /// - `pump`: how much the chain's gain moves within speech;
    /// - `LUFS`/`LRA`: the moving scene's integrated loudness and range;
    /// - `peak`: the highest sample, which must stay at or under −1.9 dBFS (no clipping).
    @Test func matrix() async throws {
        let path = try Path()
        defer { path.remove() }
        let room = Self.classroom
        let rate = AudioTestSignals.sampleRate
        let seconds = 60
        let speech = Self.regions(room.speech, seconds: seconds), pauses = Self.regions(room.pauses, seconds: seconds)
        var tallies: [String: Tally] = [:]
        func key(_ c: Candidate, _ front: Front, far: Bool) -> String { "\(c.name) | \(front.name) | \(far ? "far" : "near")" }

        var levels: [String: [String: [Double: Double]]] = [:]
        print("QUALITY ROWS  candidate | front | cell: speech out (dB) | gap in -> out (dB) | gap Δ | peak (dBFS) | LUFS / LRA (moving cell)")
        for front in Self.fronts {
            for cell in Self.cells {
                let input = Self.mix(cell, seconds: seconds)
                let raw = try await path.prepare(input, front: front, name: "cell")
                try? FileManager.default.removeItem(at: path.folder.appendingPathComponent("cell.wav"))
                let gapIn = AudioTestSignals.level(input, over: speech) - AudioTestSignals.level(input, over: pauses)
                let candidates = Self.runs(on: front)
                let outputs = try Self.concurrentMap(candidates) { try path.filter(raw, candidate: $0) }
                for (candidate, out) in zip(candidates, outputs) {
                    let speechOut = AudioTestSignals.level(out, over: speech)
                    let gapOut = speechOut - AudioTestSignals.level(out, over: pauses)
                    let k = key(candidate, front, far: cell.far)
                    var loud = ""
                    // The moving cell's gap is not comparable: a leveler is meant to raise the far
                    // stretches (and the students with them), which its `ROW` still shows.
                    if !cell.moving { tallies[k, default: Tally()].gapChanges.append(gapOut - gapIn) }
                    tallies[k, default: Tally()].loudness.append(speechOut)
                    tallies[k, default: Tally()].peaks.append(AudioTestSignals.peak(out))
                    if cell.moving {
                        // Near stretches are 0–15 s and 30–45 s, far ones 15–30 s and 45–60 s; a
                        // sentence that straddles a step belongs to neither.
                        func inside(_ lo: Int, _ hi: Int) -> [Range<Int>] { speech.filter { $0.lowerBound >= lo * rate && $0.upperBound <= hi * rate } }
                        let near = inside(0, 15) + inside(30, 45), far = inside(15, 30) + inside(45, 60)
                        tallies[k, default: Tally()].movingNearFar = AudioTestSignals.level(out, over: near) - AudioTestSignals.level(out, over: far)
                        let measured = try Self.loudness(out, in: path)
                        tallies[k, default: Tally()].lufs = measured.lufs
                        tallies[k, default: Tally()].lra = measured.lra
                        loud = " | \(Self.f(measured.lufs)) LUFS / \(Self.f(measured.lra)) LU"
                    } else {
                        levels[k, default: [:]]["s\(cell.students.map { "\(Int($0))" } ?? "none") n\(Int(cell.noise))", default: [:]][cell.gain] = speechOut
                    }
                    print("ROW \(Self.pad(candidate.name, 14)) | \(front.name) | \(Self.pad(cell.label, 22)) | \(Self.f(speechOut)) | \(Self.f(gapIn)) -> \(Self.f(gapOut)) | \(Self.f(gapOut - gapIn)) | \(Self.f(AudioTestSignals.peak(out)))\(loud)")
                }
            }
        }
        for (k, groups) in levels {
            for byGain in groups.values { tallies[k, default: Tally()].spreads.append((byGain.values.max() ?? 0) - (byGain.values.min() ?? 0)) }
        }

        // Soft-speech loss and pumping on the teacher alone (no students, noise −50).
        print("SOFT ROWS  candidate | front | stem | teacher gain: soft-frame loss mean / p5 (dB) | ending (last 300 ms) | pumping std (dB) | frames soft/loud | shift (samples)")
        for front in Self.fronts {
            for far in [false, true] {
                for gain in [0.0, -20, -30, -40] {
                    let input = Self.mix(Cell(gain: gain, students: nil, noise: -50, far: far), seconds: seconds)
                    let raw = try await path.prepare(input, front: front, name: "solo")
                    try? FileManager.default.removeItem(at: path.folder.appendingPathComponent("solo.wav"))
                    let candidates = Self.runs(on: front)
                    let measured = try Self.concurrentMap(candidates) { candidate -> (SoftSpeech, Double) in
                        let out = try path.filter(raw, candidate: candidate)
                        return (Self.softSpeech(input: input, output: out, speech: speech), AudioTestSignals.peak(out))
                    }
                    for (candidate, (m, peak)) in zip(candidates, measured) {
                        let k = key(candidate, front, far: far)
                        tallies[k, default: Tally()].softMeans.append(m.softMean)
                        tallies[k, default: Tally()].softP5s.append(m.softP5)
                        tallies[k, default: Tally()].endings.append(m.endingMean)
                        tallies[k, default: Tally()].pumps.append(m.pumping)
                        tallies[k, default: Tally()].delays.append(m.delay)
                        tallies[k, default: Tally()].peaks.append(peak)
                        print("SOFT \(Self.pad(candidate.name, 14)) | \(front.name) | \(far ? "far" : "near") | g\(Int(gain)) | \(Self.f(m.softMean)) / \(Self.f(m.softP5)) | ending \(Self.f(m.endingMean)) | \(Self.f(m.pumping)) | \(m.softFrames)/\(m.loudFrames) | \(m.delay)")
                    }
                }
            }
        }

        print("""
        QUALITY SUMMARY (60 s cells; spread = max−min of teacher out level between the teacher gains, 20 dB (40 for students −20), worst over students/noise;
        near−far = moving teacher out level difference, input 20 dB; gap Δ min/median over the cells;
        soft = mean / worst p5 over the gains; ending = worst mean loss in the last 300 ms of sentences; pump = worst std;
        loudness = median speech RMS dBFS; LUFS/LRA of the moving scene)
        """)
        print("candidate | front | stem | spread worst/median | near−far | gap Δ min/median | soft mean / worst p5 | ending worst | pump worst | loudness | LUFS / LRA | max peak | shift")
        for front in Self.fronts {
            for far in [false, true] {
                for candidate in Self.runs(on: front) {
                    let k = key(candidate, front, far: far), t = tallies[k] ?? Tally()
                    print("SUM \(Self.pad(candidate.name, 14)) | \(front.name) | \(far ? "far" : "near") | \(Self.f(t.spreads.max() ?? .nan)) / \(Self.f(AudioTestSignals.percentile(t.spreads, 0.5))) | \(Self.f(t.movingNearFar)) | \(Self.f(t.gapChanges.min() ?? .nan)) / \(Self.f(AudioTestSignals.percentile(t.gapChanges, 0.5))) | \(Self.f(AudioTestSignals.mean(t.softMeans))) / \(Self.f(t.softP5s.min() ?? .nan)) | \(Self.f(t.endings.min() ?? .nan)) | \(Self.f(t.pumps.max() ?? .nan)) | \(Self.f(AudioTestSignals.percentile(t.loudness, 0.5))) | \(Self.f(t.lufs)) / \(Self.f(t.lra)) | \(Self.f(t.peaks.max() ?? .nan)) | \(t.delays.min() ?? 0)…\(t.delays.max() ?? 0)")
                    // A chain that clips would hide its damage in the other columns.
                    #expect((t.peaks.max() ?? -100) <= -1.9 || candidate.name == "isolation-only", "\(k): peak \(t.peaks.max() ?? 0) dBFS")
                }
            }
        }
    }

    /// Whether the isolator, or the chain after it, eats word endings. For each speech region:
    /// the level change (output minus input, dB) of its last 120 ms, minus the level change of
    /// the rest of the region, so a pure gain cancels and only a tail that is treated worse than
    /// the body shows (negative). Teacher alone (noise −50), 90 s so there are nine regions,
    /// for the near and the far stem, at teacher gain 0, −20, −30 and −40, behind every front: `raw` is the
    /// chain alone, `iso100` and the wet/dry fronts include the unit, and `isolation-only` is the
    /// unit alone, so the column tells which of the two removes the endings. Prints the median
    /// and the worst 10% (the 10th percentile) over the regions and gains.
    @Test func endings() async throws {
        let path = try Path()
        defer { path.remove() }
        let room = Self.classroom
        let rate = AudioTestSignals.sampleRate
        let tail = rate * 120 / 1000
        print("END candidate | front | stem | median / worst 10% of (tail change − body change), dB | regions")
        for front in Self.fronts {
            for far in [false, true] {
                var values: [String: [Double]] = [:]
                for gain in [0.0, -20, -30, -40] {
                    let input = Self.mix(Cell(gain: gain, students: nil, noise: -50, far: far), seconds: 90)
                    let raw = try await path.prepare(input, front: front, name: "end")
                    try? FileManager.default.removeItem(at: path.folder.appendingPathComponent("end.wav"))
                    let candidates = Self.runs(on: front)
                    let outputs = try Self.concurrentMap(candidates) { try path.filter(raw, candidate: $0) }
                    for (candidate, out) in zip(candidates, outputs) {
                        for region in room.speech where region.upperBound <= 90 * rate && region.count > 2 * tail {
                            let body = region.lowerBound..<(region.upperBound - tail), end = (region.upperBound - tail)..<region.upperBound
                            func change(_ r: Range<Int>) -> Double { AudioTestSignals.level(out, over: [r]) - AudioTestSignals.level(input, over: [r]) }
                            values[candidate.name, default: []].append(change(end) - change(body))
                        }
                    }
                }
                for candidate in Self.runs(on: front) {
                    let v = values[candidate.name] ?? []
                    print("END \(Self.pad(candidate.name, 14)) | \(front.name) | \(far ? "far" : "near") | \(Self.f(AudioTestSignals.percentile(v, 0.5))) / \(Self.f(AudioTestSignals.percentile(v, 0.1))) | \(v.count)")
                }
            }
        }
    }

    /// The risk of a leveler that the matrix's 5 s pauses cannot show: a teacher who stops for
    /// half a minute (writing on the board, an exercise) while students talk. A leveler with a
    /// window of seconds and no input threshold can raise the students toward the teacher's
    /// level, and isolation keeps their voices. Sentences 3 to 5 (20 to 50 s) are removed from
    /// the teacher, leaving a pause of about 35 s; prints, for each candidate, the students' level
    /// in 26–49 s relative to the teacher's speech level, in and out ("speech − pause"), and the
    /// difference (negative: the pause came closer to the teacher). The two cases are different
    /// findings: with no students (steady noise only) a raised pause is raised hiss, a defect;
    /// with students it may be a student's question, a product decision. The numbers to compare
    /// are `Δ` of `isolation-only` (what the unit alone does, near 0) and of the candidates.
    /// The pause's absolute level, in and out, is printed too: −120 means digital silence, a
    /// finding in itself (the unit gated the noise) and not a gap.
    @Test func longPause() async throws {
        let path = try Path()
        defer { path.remove() }
        let room = Self.classroom
        let rate = AudioTestSignals.sampleRate
        let seconds = 60
        let speech = Self.regions(room.speech, seconds: seconds).filter { $0.lowerBound < 20 * rate || $0.lowerBound >= 50 * rate }
        let pause = (26 * rate)..<(49 * rate)
        for gain in [0.0, -20.0] {
            for students in [nil, -20.0, -30.0] {
                let g = Float(pow(10, gain / 20)), s = students.map { Float(pow(10, $0 / 20)) } ?? 0, n = Float(pow(10, -35.0 / 20))
                let mix: [Float] = (0..<(seconds * rate)).map { i in
                    let teacher: Float = (i >= 19 * rate && i < 50 * rate) ? 0 : room.teacher[i]
                    return g * (teacher + s * room.students[i] + n * room.noise[i])
                }
                let inGap = AudioTestSignals.level(mix, over: speech) - AudioTestSignals.level(mix, over: [pause])
                for front in Self.fronts {
                    let raw = try await path.prepare(mix, front: front, name: "long")
                    try? FileManager.default.removeItem(at: path.folder.appendingPathComponent("long.wav"))
                    let candidates = Self.runs(on: front)
                    let outputs = try Self.concurrentMap(candidates) { try path.filter(raw, candidate: $0) }
                    for (candidate, out) in zip(candidates, outputs) {
                        let outGap = AudioTestSignals.level(out, over: speech) - AudioTestSignals.level(out, over: [pause])
                        print("LONG \(Self.pad(candidate.name, 22)) | \(front.name) | g\(Int(gain)) \(students.map { "students \(Int($0))" } ?? "noise only") | speech − pause in \(Self.f(inGap)) out \(Self.f(outGap)) | Δ \(Self.f(outGap - inGap)) | pause \(Self.f(AudioTestSignals.level(mix, over: [pause]))) → \(Self.f(AudioTestSignals.level(out, over: [pause]))) dBFS")
                    }
                }
            }
        }
    }

    /// Whether the unit's dry path is delay-aligned with its wet path, which a wet/dry mix needs:
    /// `AppleVoiceIsolator` drops `model.delay` samples from the start, so if the dry signal is
    /// not delayed by the same amount, mixing the two gives comb filtering. Renders clean
    /// speech at 100% and at 0% wet, lines each up with the input, and prints the shifts (in
    /// samples, positive = later than the input after the compensation). Passes whatever it finds:
    /// the finding decides whether `iso90` and `iso85` mean anything: with a misaligned dry path they
    /// would be comb filters.
    @Test func wetDryAlignment() async throws {
        try #require(AppleVoiceIsolator.preferred() != nil, "needs voice isolation")
        let path = try Path()
        defer { path.remove() }
        let room = Self.classroom
        let input = Array(room.teacher[0..<(25 * AudioTestSignals.sampleRate)])
        let wav = path.folder.appendingPathComponent("clean.wav")
        try AudioTestSignals.writeWAV(input, to: wav)
        var models: [AppleVoiceIsolator.Model] = [.standard]
        if #available(macOS 15, *) { models.append(.highQuality) }
        for model in models {
            for wet in [100.0, 50.0, 0.0] {
                let raw = path.folder.appendingPathComponent("w\(Int(wet))-\(model).raw")
                try await AppleVoiceIsolator(model: model, wetDryMix: wet).isolate(wav, from: 0, count: nil, to: raw)
                let out = try AudioTestSignals.rawSamples(raw)
                let delay = AudioTestSignals.delay(of: Array(out[0..<(8 * AudioTestSignals.sampleRate)]), against: Array(input[0..<(8 * AudioTestSignals.sampleRate)]), limit: 9600)
                // A comb shows as a notch pattern; the level change against the input says how much was removed.
                print("WETDRY model=\(model) wet=\(Int(wet))% shift=\(delay) samples, level change \(Self.f(AudioTestSignals.level(out[...]) - AudioTestSignals.level(input[...]))) dB")
            }
        }
    }

    /// Seamless joins (the header of `AudioEnhancement.swift`): in production each 30 s segment
    /// (Webex's length: `docs/benchmarks.md`, and the 2–4 MB limit in `AudioEnhancement`) is filtered with its neighbours as context
    /// and then trimmed (`AudioEnhancement.audioContext`: the next segment always, the previous
    /// one only when it is already on disk, so none after a seek), so a chain whose memory is
    /// longer than that behaves differently at a join than it would over the whole lecture.
    /// Filters a 90 s scene whole and in three 30 s pieces, trimmed and joined, with
    /// context before it (30 s as production has when the previous segment is on disk, and 12, 6
    /// and 0 s: none is what a segment after a seek gets) and the 30 s after it, and prints, for
    /// 100 ms frames above −70 dBFS within 1 s of each join (30 s and 60 s) and, for comparison,
    /// of the middle of the first and last piece (22 s and 82 s), the level difference between
    /// pieces and whole (dB), plus two seam artifacts: `step` is the largest level change between
    /// consecutive 20 ms frames across a join that the whole file does not have (an audible level
    /// step), and `click` the largest sample-to-sample jump within 5 ms of a join relative to the
    /// whole file's, in dB (a discontinuity). Guards against choosing a leveler that is fine over
    /// a whole file and steps at every segment boundary in the player.
    @Test func joins() async throws {
        let path = try Path()
        defer { path.remove() }
        let rate = AudioTestSignals.sampleRate
        let frame = rate / 10
        let seconds = 90
        for cell in [Cell(gain: 0, students: -20, noise: -35, moving: true), Cell(gain: -20, students: -20, noise: -35)] {
            let mix = Self.mix(cell, seconds: seconds)
            for front in Self.fronts where front.wet == nil || front.wet == 100 {
                let raw = try await path.prepare(mix, front: front, name: "join")
                let bytes = try Data(contentsOf: raw)
                let input = try AudioTestSignals.rawSamples(raw)
                for lead in [30, 12, 6, 0] {
                    let lines = try Self.concurrentMap(Self.all.filter { $0.name != "isolation-only" }) { candidate -> String in
                        let whole = try path.filter(raw, candidate: candidate)
                        let delay = AudioTestSignals.delay(of: Array(whole[(20 * rate)..<(26 * rate)]), against: Array(input[(20 * rate)..<(26 * rate)]), limit: 2400)
                        var stitched: [Float] = []
                        for piece in 0..<3 {
                            let from = max(0, (30 * piece - lead) * rate), to = min(seconds * rate, (30 * piece + 60) * rate)
                            let part = path.folder.appendingPathComponent("piece-\(candidate.name)-\(piece)-\(lead).raw")
                            try bytes[(from * 2)..<(to * 2)].write(to: part)
                            let out = try path.filter(part, candidate: candidate, gainFrom: raw)
                            let lower = 30 * piece * rate - from + delay
                            for i in lower..<(lower + 30 * rate) { stitched.append(i >= 0 && i < out.count ? out[i] : 0) }
                        }
                        func differences(around second: Int) -> [Double] {
                            stride(from: (second - 1) * rate, to: (second + 1) * rate, by: frame).compactMap { start in
                                guard start + delay >= 0, start + delay + frame <= whole.count else { return nil }
                                let a = AudioTestSignals.level(stitched[start..<(start + frame)]), b = AudioTestSignals.level(whole[(start + delay)..<(start + delay + frame)])
                                return max(a, b) > -70 ? abs(a - b) : nil
                            }
                        }
                        // The first 5 s of a piece after a join: what a seek lands in, since the leveler
                        // has just started; compared with the whole-file render.
                        func warmup(from second: Int) -> [Double] {
                            stride(from: second * rate, to: (second + 5) * rate, by: frame).compactMap { start in
                                guard start + delay >= 0, start + delay + frame <= whole.count else { return nil }
                                let a = AudioTestSignals.level(stitched[start..<(start + frame)]), b = AudioTestSignals.level(whole[(start + delay)..<(start + delay + frame)])
                                return max(a, b) > -70 ? abs(a - b) : nil
                            }
                        }
                        let first5 = warmup(from: 30) + warmup(from: 60)
                        let joins = differences(around: 30) + differences(around: 60), interior = differences(around: 22) + differences(around: 82)
                        // Seam artifacts, at the joins only.
                        var step = 0.0, click = -Double.infinity
                        let small = rate / 50
                        for seam in [30 * rate, 60 * rate] {
                            func jumps(_ x: ArraySlice<Float>) -> [Double] { // frame-to-frame level change in dB
                                var last: Double?
                                var result: [Double] = []
                                for start in stride(from: x.startIndex, to: x.endIndex - small + 1, by: small) {
                                    let l = AudioTestSignals.level(x[start..<(start + small)])
                                    if let last, max(l, last) > -70 { result.append(l - last) } else { result.append(0) }
                                    last = l
                                }
                                return result
                            }
                            let range = (seam - rate / 2)..<(seam + rate / 2)
                            let a = jumps(stitched[range]), b = jumps(whole[(range.lowerBound + delay)..<(range.upperBound + delay)])
                            step = max(step, zip(a, b).map { abs($0 - $1) }.max() ?? 0)
                            func maxJump(_ x: ArraySlice<Float>) -> Double { 20 * log10(Double(zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0) + 1e-9) }
                            let near = (seam - rate / 200)..<(seam + rate / 200)
                            click = max(click, maxJump(stitched[near]) - maxJump(whole[(near.lowerBound + delay)..<(near.upperBound + delay)]))
                        }
                        return "JOIN \(Self.pad(cell.label, 22)) | \(front.name) | lead \(lead) s | \(Self.pad(candidate.name, 14)) | at joins median \(Self.f(AudioTestSignals.percentile(joins, 0.5), 2)) max \(Self.f(joins.max() ?? .nan, 2)) dB | interior median \(Self.f(AudioTestSignals.percentile(interior, 0.5), 2)) max \(Self.f(interior.max() ?? .nan, 2)) dB | step \(Self.f(step, 2)) dB | click \(Self.f(click, 2)) dB | first 5 s after join median \(Self.f(AudioTestSignals.percentile(first5, 0.5), 2)) max \(Self.f(first5.max() ?? .nan, 2)) dB"
                    }
                    lines.forEach { print($0) }
                }
            }
        }
    }

    /// What a rendering of a real recording shows without a clean reference: integrated
    /// loudness and range, peak and clipped samples (|x| ≥ 0.999), how far the quietest and the
    /// loudest tenths of 100 ms frames moved (`floor`, `speech`: a 35 to 45 dB lift of a quiet
    /// recording exposes the floor), the standard deviation of the gain in the quietest 30% of
    /// frames (`pump`: noise pumping), and `ending`, an approximation of the word-ending
    /// metric: speech ends are found in the input itself (a 20 ms frame within 18 dB of the 90th
    /// percentile followed by 200 ms more than 18 dB under it), and the last 120 ms before each
    /// end is compared, output minus input, with the 500 ms before that, so pure gain cancels.
    /// It is approximate because the input still holds the noise and the reverberation a clean
    /// reference would not, and the ends are only where the level drops.
    static func excerptMetrics(_ label: String, input: [Float], output: [Float], path: Path) throws -> String {
        let rate = AudioTestSignals.sampleRate
        let count = min(input.count, output.count)
        let frame = rate / 10
        let a = AudioTestSignals.frameLevels(Array(input[0..<count]), frame: frame, in: 0..<count)
        let b = AudioTestSignals.frameLevels(Array(output[0..<count]), frame: frame, in: 0..<count)
        let gains = zip(a, b).map { $1 - $0 }
        let quiet = AudioTestSignals.percentile(a, 0.3)
        let quietGains = zip(a, gains).filter { $0.0 <= quiet }.map(\.1)
        let floorLift = AudioTestSignals.percentile(b, 0.1) - AudioTestSignals.percentile(a, 0.1)
        let speechLift = AudioTestSignals.percentile(b, 0.9) - AudioTestSignals.percentile(a, 0.9)
        let loud = try loudness(Array(output[0..<count]), in: path)
        let clipped = output[0..<count].reduce(0) { $0 + (abs($1) >= 0.999 ? 1 : 0) }

        let small = rate / 50
        let levels = AudioTestSignals.frameLevels(Array(input[0..<count]), frame: small, in: 0..<count)
        let top = AudioTestSignals.percentile(levels, 0.9)
        var ends: [Int] = [], values: [Double] = []
        var i = 31
        while i + 10 < levels.count {
            if levels[i - 1] >= top - 18, levels[i..<(i + 10)].allSatisfy({ $0 < top - 18 }) {
                ends.append(i)
                func change(_ lo: Int, _ hi: Int) -> Double {
                    AudioTestSignals.level(output[(lo * small)..<(hi * small)]) - AudioTestSignals.level(input[(lo * small)..<(hi * small)])
                }
                values.append(change(i - 6, i) - change(i - 31, i - 6))
                i += 50
            } else { i += 1 }
        }
        return "EXC \(label) | \(Self.f(loud.lufs)) LUFS / \(Self.f(loud.lra)) LU | peak \(Self.f(AudioTestSignals.peak(Array(output[0..<count])))) dBFS clipped \(clipped) | lift floor \(Self.f(floorLift)) speech \(Self.f(speechLift)) dB | pump (quiet frames gain std) \(Self.f(AudioTestSignals.standardDeviation(quietGains))) dB | ending (approx.) median \(Self.f(AudioTestSignals.percentile(values, 0.5))) worst10% \(Self.f(AudioTestSignals.percentile(values, 0.1))) over \(ends.count) ends"
    }

    /// Renders for listening, when `BEEPBAR_AUDIO_AB_OUT` names a folder: for four scenes (a
    /// near teacher with students at −20 dB, a far one −20 dB with the same students, the
    /// moving teacher, the reverberant teacher) the original and every candidate through the
    /// real path (isolation at 100% where the Mac has it), as `<scene>__original.wav`,
    /// `<scene>__<candidate>.wav`, 16-bit WAV (a float one of a long scene is 35 MB).
    ///
    /// `BEEPBAR_AUDIO_EXCERPT=<file>[,<file>]` also renders each file's first audio track (180 s at
    /// most) as `excerpt<n>__<front>__<candidate>.wav` (n from 1, in the order given; fronts
    /// `raw`, `iso100`, `iso85`) and prints `EXC` lines (`excerptMetrics`). Real recordings are
    /// private: they are read in a temporary folder, never copied anywhere else, and neither
    /// the names nor the contents are printed; only an index. Proves nothing: the ear decides
    /// what the numbers cannot. Does nothing without the folder variable.
    @Test func abRenders() async throws {
        guard let directory = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_AB_OUT"], !directory.isEmpty else { return }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let path = try Path()
        defer { path.remove() }
        let front: Front = AppleVoiceIsolator.preferred() != nil ? .isolated : .none
        func render(_ name: String, _ mix: [Float], fronts: [Front], measure: Bool = false) async throws {
            try AudioTestSignals.writeWAV16(mix, to: out.appendingPathComponent("\(name)__original.wav"))
            if measure { print(try Self.excerptMetrics("\(name) | original", input: mix, output: mix, path: path)) }
            for front in fronts {
                let raw = try await path.prepare(mix, front: front, name: name)
                try? FileManager.default.removeItem(at: path.folder.appendingPathComponent("\(name).wav"))
                for candidate in Self.runs(on: front) {
                    let samples = try path.filter(raw, candidate: candidate)
                    let file = fronts.count > 1 ? "\(name)__\(front.name)__\(candidate.name).wav" : "\(name)__\(candidate.name).wav"
                    try AudioTestSignals.writeWAV16(samples, to: out.appendingPathComponent(file))
                    if measure { print(try Self.excerptMetrics("\(name) | \(front.name) | \(candidate.name)", input: mix, output: samples, path: path)) }
                }
            }
            print("AB wrote \(name)")
        }
        let synthetic = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_EXCERPT_ONLY"] == "1" ? [] : [
            ("near_students20", Cell(gain: 0, students: -20, noise: -35)),
            ("far_students20", Cell(gain: -20, students: -20, noise: -35)),
            ("quiet_students20_g-40", Cell(gain: -40, students: -20, noise: -35)),
            ("moving_teacher", Cell(gain: 0, students: -20, noise: -35, moving: true)),
            ("reverb_far_g0", Cell(gain: 0, students: -20, noise: -35, far: true)),
        ]
        for (name, cell) in synthetic { try await render(name, Self.mix(cell, seconds: 60), fronts: [front]) }

        let excerpts = (ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_EXCERPT"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        for (n, excerpt) in excerpts.enumerated() {
            let wav = path.folder.appendingPathComponent("excerpt-source.wav")
            // Not `AudioTestSignals.run`: its failure message carries ffmpeg's, which names the file.
            let process = Process()
            process.executableURL = path.ffmpeg
            process.arguments = ["-nostdin", "-loglevel", "quiet", "-y", "-i", excerpt, "-map", "0:a:0", "-t", "180", "-vn",
                                 "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", wav.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "excerpt \(n + 1) could not be read as audio")
            if process.terminationStatus == 0 {
                let fronts: [Front] = AppleVoiceIsolator.preferred() != nil ? [.none, .isolated, .wetDry] : [.none]
                try await render("excerpt\(n + 1)", try AudioTestSignals.samples(wav), fronts: fronts, measure: true)
            }
        }
    }
}
