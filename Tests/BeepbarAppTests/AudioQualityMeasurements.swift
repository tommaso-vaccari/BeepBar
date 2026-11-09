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
/// - `BEEPBAR_AUDIO_ONLY=name,name`: run only those candidates (plus `current`), to iterate.
/// - `BEEPBAR_AUDIO_AB_OUT=<dir>`: also write A/B renders there (`abRenders`).
/// - `BEEPBAR_AUDIO_EXCERPT=<file>`: with `BEEPBAR_AUDIO_AB_OUT`, render the same set from the
///   first audio track (at most 180 s) of that local file. It is private data: it is read only
///   here, never copied into the repository, and its name and contents are never printed.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BEEPBAR_MEASURE_AUDIO_QUALITY"] == "1" && AudioEnhancement.locateFFmpeg() != nil
                             && AudioTestSignals.canSpeak, "on demand: BEEPBAR_MEASURE_AUDIO_QUALITY=1"))
struct AudioQualityMeasurements {
    // MARK: Candidates

    /// A filter chain under test: what follows the voice-isolation step in `isolatedEncodeArguments`.
    struct Candidate: Sendable {
        let name: String
        let chain: String
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
        func leveler(g: Int, m: Int) -> String { "dynaudnorm=f=250:g=\(g):p=0.5:m=\(m):b=1" }
        func expander(_ threshold: String, ratio: String = "1.5", range: String = "0.35") -> String {
            "agate=threshold=\(threshold):ratio=\(ratio):range=\(range):attack=10:release=400:knee=6:detection=rms"
        }
        func chain(_ parts: String...) -> String { ([prefix] + parts + [limiter]).joined(separator: ",") }
        let all = [
            Candidate(name: "current", chain: AudioEnhancement.isolatedChain),
            Candidate(name: "isolation-only", chain: "anull"),
            Candidate(name: "C1-weak", chain: chain(leveler(g: 51, m: 50), expander("0.011"))),
            Candidate(name: "C1", chain: chain(leveler(g: 51, m: 50), expander("0.02"))),
            Candidate(name: "C1-mid", chain: chain(leveler(g: 51, m: 50), expander("0.03", ratio: "2.5"))),
            Candidate(name: "C1-strong", chain: chain(leveler(g: 51, m: 50), expander("0.05", ratio: "2", range: "0.25"))),
            Candidate(name: "C1-g31", chain: chain(leveler(g: 31, m: 50), expander("0.02"))),
            Candidate(name: "C1-g71", chain: chain(leveler(g: 71, m: 50), expander("0.02"))),
            Candidate(name: "C2", chain: chain(leveler(g: 51, m: 50))),
            Candidate(name: "C3", chain: chain("speechnorm=e=12:r=0.0001:l=1", expander("0.02"))),
            Candidate(name: "C3-t", chain: chain("speechnorm=e=12:r=0.0001:l=1:t=0.002", expander("0.02"))),
        ]
        guard let only = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_ONLY"] else { return all }
        let names = Set(only.split(separator: ",").map(String.init))
        return all.filter { $0.name == "current" || $0.name == "isolation-only" || names.contains($0.name) }
    }()

    // MARK: Synthetic classroom

    /// One scene: a teacher with known speech and pause regions, students, steady noise. Stems
    /// are scaled so a stem's RMS is the teacher's speech RMS (−22 dBFS at gain 0), so every
    /// level below is "dB relative to the teacher".
    struct Classroom {
        let teacher: [Float]
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
        return Classroom(teacher: teacher, students: scaled(Array(students.prefix(total))), noise: scaled(try AudioTestSignals.samples(noiseURL)), speech: speech, pauses: pauses)
    }

    private static func loop(say: URL, _ voice: [String], text: String, name: String, seconds: Int, folder: URL, ffmpeg: URL) throws -> [Float] {
        let spoken = folder.appendingPathComponent("\(name).aiff"), wav = folder.appendingPathComponent("\(name).wav")
        try AudioTestSignals.run(say, voice + ["-o", spoken.path, text], in: folder)
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-stream_loop", "-1", "-i", spoken.path, "-t", "\(seconds)",
                                          "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", wav.path], in: folder)
        return try AudioTestSignals.samples(wav)
    }

    enum MeasurementError: Error { case sentenceTooLong(Int), isolationUnavailable }

    /// One point of the matrix. Levels are dB relative to the teacher at the cell's `gain`:
    /// the scene scales as a whole, so only the absolute level changes between cells with the
    /// same `students` and `noise`. `moving` instead keeps the background where it is and steps
    /// only the teacher, 0 → −20 → 0 dB every 15 s, as when she walks away from the microphone.
    struct Cell: Sendable {
        let gain: Double
        let students: Double?
        let noise: Double
        var moving = false

        var label: String {
            moving ? "moving s-20 n-35" : "g\(Int(gain)) s\(students.map { "\(Int($0))" } ?? "none") n\(Int(noise))"
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
        return (0..<count).map { i in
            let background = students * room.students[i] + noise * room.noise[i]
            if cell.moving { return Float(pow(10, movingGain(at: i) / 20)) * room.teacher[i] + background }
            return gain * (room.teacher[i] + background)
        }
    }

    /// The regions of the classroom that end within `seconds`.
    static func regions(_ all: [Range<Int>], seconds: Int) -> [Range<Int>] { all.filter { $0.upperBound <= seconds * AudioTestSignals.sampleRate } }

    /// The matrix: teacher gain × students × noise, 24 cells, plus the moving teacher.
    static let cells: [Cell] = {
        var cells: [Cell] = []
        // `BEEPBAR_AUDIO_QUICK=1`: only students −20 and noise −35, to iterate on a chain.
        let quick = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_QUICK"] == "1"
        for noise in quick ? [-35.0] : [-35.0, -50.0] { for students in quick ? [-20.0] : [nil, -20.0, -30.0] { for gain in [0.0, -10, -20, -30] {
            cells.append(Cell(gain: gain, students: students, noise: noise))
        } } }
        return cells + [Cell(gain: 0, students: -20, noise: -35, moving: true)]
    }()

    // MARK: Processing path

    /// What comes before the chain.
    struct Front: Sendable, Hashable {
        let name: String
        /// Percent of isolated voice, or nil for no isolation.
        let wet: Double?
        static let none = Front(name: "raw", wet: nil)
        static let isolated = Front(name: "iso100", wet: 100)
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
            if !FileManager.default.fileExists(atPath: wav.path) { try AudioTestSignals.writeWAV(mix, to: wav) }
            guard var isolator = AppleVoiceIsolator.preferred() else { throw MeasurementError.isolationUnavailable }
            isolator.wetDryMix = wet
            try await isolator.isolate(wav, from: 0, count: nil, to: raw)
            return raw
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

    /// The fronts to run: no isolation and 100% when there is the unit, and 85% when asked
    /// (`wetDryAlignment` says whether that is meaningful).
    private static var fronts: [Front] {
        var fronts: [Front] = [.none]
        if AppleVoiceIsolator.preferred() != nil { fronts.append(.isolated) }
        if AppleVoiceIsolator.preferred() != nil, ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_WETDRY"] == "1" { fronts.append(.wetDry) }
        return fronts
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

    /// Everything one (candidate, front) accumulates over the matrix.
    struct Tally {
        var spreads: [Double] = []
        var movingNearFar = Double.nan
        var gapChanges: [Double] = []
        var softMeans: [Double] = [], softP5s: [Double] = [], pumps: [Double] = [], endings: [Double] = []
        var loudness: [Double] = []
        var peaks: [Double] = []
        var delays: [Int] = []
    }

    // MARK: Tests

    /// Runs the whole matrix and prints, per (candidate, front), one row per cell, the leveling,
    /// soft-speech and pumping measurements, and a summary. Proves nothing by itself: the
    /// numbers are what a chain is chosen on. What each column guards against:
    /// - `speech out`: the teacher's level out; its spread across `g0…g-30` (same students and
    ///   noise) is the leveling, ideally small (the unleveled spread is 30 dB);
    /// - `gap Δ`: (speech − pause level) out minus in; negative means the background was raised
    ///   relative to the teacher, which is "noise remains";
    /// - `soft loss`: how much more word endings and soft consonants lose than loud speech;
    /// - `pump`: how much the chain's gain moves within speech;
    /// - `peak`: the highest sample, which must stay at or under −1.9 dBFS (no clipping).
    @Test func matrix() async throws {
        let path = try Path()
        defer { path.remove() }
        let room = Self.classroom
        let rate = AudioTestSignals.sampleRate
        let seconds = 60
        let speech = Self.regions(room.speech, seconds: seconds), pauses = Self.regions(room.pauses, seconds: seconds)
        var tallies: [String: Tally] = [:]
        func key(_ c: Candidate, _ front: Front) -> String { "\(c.name) | \(front.name)" }

        // Spread of the teacher's out level over the four gains, per (students, noise).
        var levels: [String: [String: [Double: Double]]] = [:]
        print("QUALITY ROWS  candidate | front | cell: speech out (dB) | gap in -> out (dB) | gap Δ | peak (dBFS)")
        for front in Self.fronts {
            for cell in Self.cells {
                let input = Self.mix(cell, seconds: seconds)
                let raw = try await path.prepare(input, front: front, name: "cell")
                try? FileManager.default.removeItem(at: path.folder.appendingPathComponent("cell.wav"))
                let gapIn = AudioTestSignals.level(input, over: speech) - AudioTestSignals.level(input, over: pauses)
                let candidates = Self.all.filter { !($0.name == "isolation-only" && front.wet == nil) }
                let outputs = try Self.concurrentMap(candidates) { try path.filter(raw, chain: $0.chain) }
                for (candidate, out) in zip(candidates, outputs) {
                    let speechOut = AudioTestSignals.level(out, over: speech)
                    let gapOut = speechOut - AudioTestSignals.level(out, over: pauses)
                    let k = key(candidate, front)
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
                    } else {
                        levels[k, default: [:]]["s\(cell.students.map { "\(Int($0))" } ?? "none") n\(Int(cell.noise))", default: [:]][cell.gain] = speechOut
                    }
                    print("ROW \(Self.pad(candidate.name, 22)) | \(front.name) | \(Self.pad(cell.label, 17)) | \(Self.f(speechOut)) | \(Self.f(gapIn)) -> \(Self.f(gapOut)) | \(Self.f(gapOut - gapIn)) | \(Self.f(AudioTestSignals.peak(out)))")
                }
            }
        }
        for (k, groups) in levels {
            for byGain in groups.values { tallies[k, default: Tally()].spreads.append((byGain.values.max() ?? 0) - (byGain.values.min() ?? 0)) }
        }

        // Soft-speech loss and pumping on the teacher alone (no students, noise −50).
        print("SOFT ROWS  candidate | front | teacher gain: soft-frame loss mean / p5 (dB) | pumping std (dB) | frames soft/loud | delay (samples)")
        for front in Self.fronts {
            for gain in [0.0, -10, -20, -30] {
                let input = Self.mix(Cell(gain: gain, students: nil, noise: -50), seconds: seconds)
                let raw = try await path.prepare(input, front: front, name: "solo")
                try? FileManager.default.removeItem(at: path.folder.appendingPathComponent("solo.wav"))
                let candidates = Self.all.filter { !($0.name == "isolation-only" && front.wet == nil) }
                let measured = try Self.concurrentMap(candidates) { candidate -> (SoftSpeech, Double) in
                    let out = try path.filter(raw, chain: candidate.chain)
                    return (Self.softSpeech(input: input, output: out, speech: speech), AudioTestSignals.peak(out))
                }
                for (candidate, (m, peak)) in zip(candidates, measured) {
                    let k = key(candidate, front)
                    tallies[k, default: Tally()].softMeans.append(m.softMean)
                    tallies[k, default: Tally()].softP5s.append(m.softP5)
                    tallies[k, default: Tally()].endings.append(m.endingMean)
                    tallies[k, default: Tally()].pumps.append(m.pumping)
                    tallies[k, default: Tally()].delays.append(m.delay)
                    tallies[k, default: Tally()].peaks.append(peak)
                    print("SOFT \(Self.pad(candidate.name, 22)) | \(front.name) | g\(Int(gain)) | \(Self.f(m.softMean)) / \(Self.f(m.softP5)) | ending \(Self.f(m.endingMean)) | \(Self.f(m.pumping)) | \(m.softFrames)/\(m.loudFrames) | \(m.delay)")
                }
            }
        }

        print("""
        QUALITY SUMMARY (60 s cells; spread = max−min of teacher out level over gains 0…−30, input 30 dB;
        near−far = moving teacher out level difference, input 20 dB; gap Δ min/median over 24+1 cells;
        soft = mean / worst p5 over the four gains; ending = worst mean loss in the last 300 ms of sentences; pump = worst std; loudness = median speech RMS dBFS)
        """)
        print("candidate | front | spread worst/median | near−far | gap Δ min/median | soft mean / worst p5 | ending worst | pump worst | loudness | max peak | delay")
        for front in Self.fronts {
            for candidate in Self.all where !(candidate.name == "isolation-only" && front.wet == nil) {
                let k = key(candidate, front), t = tallies[k] ?? Tally()
                print("SUM \(Self.pad(candidate.name, 22)) | \(front.name) | \(Self.f(t.spreads.max() ?? .nan)) / \(Self.f(AudioTestSignals.percentile(t.spreads, 0.5))) | \(Self.f(t.movingNearFar)) | \(Self.f(t.gapChanges.min() ?? .nan)) / \(Self.f(AudioTestSignals.percentile(t.gapChanges, 0.5))) | \(Self.f(AudioTestSignals.mean(t.softMeans))) / \(Self.f(t.softP5s.min() ?? .nan)) | \(Self.f(t.endings.min() ?? .nan)) | \(Self.f(t.pumps.max() ?? .nan)) | \(Self.f(AudioTestSignals.percentile(t.loudness, 0.5))) | \(Self.f(t.peaks.max() ?? .nan)) | \(t.delays.min() ?? 0)…\(t.delays.max() ?? 0)")
                // A chain that clips would hide its damage in the other columns.
                #expect((t.peaks.max() ?? -100) <= -1.9 || candidate.name == "isolation-only", "\(k): peak \(t.peaks.max() ?? 0) dBFS")
            }
        }
    }

    /// Whether the unit's dry path is delay-aligned with its wet path, which a wet/dry mix needs:
    /// `AppleVoiceIsolator` drops `model.delay` samples from the start, so if the dry signal is
    /// not delayed by the same amount, mixing the two gives comb filtering. Renders clean
    /// speech at 100% and at 0% wet, lines each up with the input, and prints the shifts (in
    /// samples, positive = later than the input after the compensation). Passes whatever it finds:
    /// the finding decides whether `iso85` is worth running (`BEEPBAR_AUDIO_WETDRY=1`).
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
    /// is filtered with only its neighbours (30 s before and after) as context and then trimmed,
    /// so a chain whose memory is longer than that behaves differently at a join than it would
    /// over the whole lecture. Filters a 90 s scene whole and in three 30 s pieces with ±30 s of
    /// context, trimmed and joined, and prints the level difference (|pieces − whole| in dB, 100 ms
    /// frames, frames above −70 dBFS) within 1 s of each join (30 s and 60 s) and, for
    /// comparison, within 1 s of the middle of the first and last piece (22 s and 82 s), where a chain with
    /// enough context should show nothing. Guards against choosing a leveler that is fine over a
    /// whole file and steps at every segment boundary in the player.
    @Test func joins() async throws {
        let path = try Path()
        defer { path.remove() }
        let rate = AudioTestSignals.sampleRate
        let frame = rate / 10
        let seconds = 90
        for cell in [Cell(gain: 0, students: -20, noise: -35, moving: true), Cell(gain: -20, students: -20, noise: -35)] {
            let mix = Self.mix(cell, seconds: seconds)
            for front in Self.fronts where front != .wetDry {
                let raw = try await path.prepare(mix, front: front, name: "join")
                let bytes = try Data(contentsOf: raw)
                let input = try AudioTestSignals.rawSamples(raw)
                let lines = try Self.concurrentMap(Self.all.filter { $0.name != "isolation-only" }) { candidate -> String in
                    let whole = try path.filter(raw, chain: candidate.chain)
                    let delay = AudioTestSignals.delay(of: Array(whole[(20 * rate)..<(26 * rate)]), against: Array(input[(20 * rate)..<(26 * rate)]), limit: 2400)
                    var stitched: [Float] = []
                    for piece in 0..<3 {
                        let from = max(0, (30 * piece - 30) * rate), to = min(seconds * rate, (30 * piece + 60) * rate)
                        let part = path.folder.appendingPathComponent("piece-\(candidate.name)-\(piece).raw")
                        try bytes[(from * 2)..<(to * 2)].write(to: part)
                        let out = try path.filter(part, chain: candidate.chain)
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
                    let joins = differences(around: 30) + differences(around: 60), interior = differences(around: 22) + differences(around: 82)
                    return "JOIN \(Self.pad(cell.label, 17)) | \(front.name) | \(Self.pad(candidate.name, 22)) | at joins median \(Self.f(AudioTestSignals.percentile(joins, 0.5), 2)) max \(Self.f(joins.max() ?? .nan, 2)) dB | interior median \(Self.f(AudioTestSignals.percentile(interior, 0.5), 2)) max \(Self.f(interior.max() ?? .nan, 2)) dB | delay \(delay)"
                }
                lines.forEach { print($0) }
            }
        }
    }

    /// Renders for listening, when `BEEPBAR_AUDIO_AB_OUT` names a folder: for three scenes (a
    /// near teacher with students at −20 dB, a far one −20 dB with the same students, the
    /// moving teacher) the original and every candidate through the real path (isolation at 100%
    /// where the Mac has it), as `<scene>__original.wav`, `<scene>__<candidate>.wav`. With
    /// `BEEPBAR_AUDIO_EXCERPT` also the same set from that file's first audio track (180 s at
    /// most) as `excerpt__*.wav`: a private recording, so it is read in a temporary folder, never
    /// copied anywhere else, and neither its name nor its contents are printed. Proves nothing:
    /// the ear decides what the numbers cannot. Does nothing without the folder variable.
    @Test func abRenders() async throws {
        guard let directory = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_AB_OUT"], !directory.isEmpty else { return }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let path = try Path()
        defer { path.remove() }
        let front: Front = AppleVoiceIsolator.preferred() != nil ? .isolated : .none
        func render(_ name: String, _ mix: [Float]) async throws {
            try AudioTestSignals.writeWAV(mix, to: out.appendingPathComponent("\(name)__original.wav"))
            let raw = try await path.prepare(mix, front: front, name: name)
            for candidate in Self.all {
                let samples = try path.filter(raw, chain: candidate.chain)
                try AudioTestSignals.writeWAV(samples, to: out.appendingPathComponent("\(name)__\(candidate.name).wav"))
            }
            print("AB wrote \(name)")
        }
        try await render("near_students20", Self.mix(Cell(gain: 0, students: -20, noise: -35), seconds: 60))
        try await render("far_students20", Self.mix(Cell(gain: -20, students: -20, noise: -35), seconds: 60))
        try await render("moving_teacher", Self.mix(Cell(gain: 0, students: -20, noise: -35, moving: true), seconds: 60))

        if let excerpt = ProcessInfo.processInfo.environment["BEEPBAR_AUDIO_EXCERPT"], !excerpt.isEmpty {
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
            #expect(process.terminationStatus == 0, "the excerpt could not be read as audio")
            if process.terminationStatus == 0 { try await render("excerpt", try AudioTestSignals.samples(wav)) }
        }
    }
}
