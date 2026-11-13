import Darwin
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// On-demand measurement of enhanced audio, never part of the regular `swift test`: run with
/// `BEEPBAR_MEASURE_AUDIO=1 swift test --filter LiveAudioMeasurements`. A synthetic lecture laid
/// out as Webex's (one fragmented MP4, 30-second segments, 720p picture, 44.1 kHz stereo voice)
/// read from disk, so network time is left out: what it reports is the local work. Prints the
/// wait for each segment as the player would ask for it, the time spent in each step, the CPU
/// of BeepBar and of ffmpeg, and checks that stopping leaves no process and no file behind.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BEEPBAR_MEASURE_AUDIO"] == "1" && AudioEnhancement.locateFFmpeg() != nil
                             && AudioTestSignals.canSpeak, "on demand: BEEPBAR_MEASURE_AUDIO=1"))
struct LiveAudioMeasurements {
    private static let address = URL(string: "https://media.example.test/rec/out.m3u8")!
    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-audio-measure", isDirectory: true)

    /// Six minutes, twelve segments; made once and reused by both variants.
    private static func lecture() throws -> URL {
        let playlist = folder.appendingPathComponent("out.m3u8")
        if FileManager.default.fileExists(atPath: playlist.path) { return folder }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ffmpeg = try #require(AudioEnhancement.locateFFmpeg())
        let speech = try AudioTestSignals.speech(seconds: 360, in: folder, ffmpeg: ffmpeg)
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y",
                                          "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25", "-i", speech.path, "-t", "360",
                                          "-c:v", "libx264", "-preset", "veryfast", "-b:v", "1500k", "-g", "50",
                                          "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "128k", "-output_ts_offset", "1",
                                          "-f", "hls", "-hls_time", "30", "-hls_segment_type", "fmp4", "-hls_flags", "single_file",
                                          "-hls_playlist_type", "vod", "out.m3u8"], in: folder)
        return folder
    }

    /// One run per variant: the isolated kind with Apple's voice isolation, the levelled kind
    /// (which also isolates, then levels), and ffmpeg alone (`isolation: false`, no isolator).
    /// The segments asked for, in order: by default the short sequence the documented timings
    /// were measured with; with `BEEPBAR_MEASURE_AUDIO_SEGMENTS=all`, the twelve of the whole
    /// synthetic lecture, to see whether memory stops growing after the first segments.
    private static var requests: [Int] {
        ProcessInfo.processInfo.environment["BEEPBAR_MEASURE_AUDIO_SEGMENTS"] == "all" ? Array(0...11) : [0, 1, 2, 8, 1]
    }

    @Test(arguments: [(true, AudioEnhancementKind.isolated), (true, .levelled), (false, .isolated)])
    func measure(isolation: Bool, kind: AudioEnhancementKind) async throws {
        let lecture = try Self.lecture()
        let ffmpeg = try #require(AudioEnhancement.locateFFmpeg())
        let steps = Steps()
        let isolator: LiveAudioVoiceIsolating? = isolation ? TimedIsolator(inner: try #require(AppleVoiceIsolator.preferred()), steps: steps) : nil
        let sessions = Self.folder.appendingPathComponent("sessions-\(isolation)-\(kind.rawValue)")
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: ffmpeg, onFailure: { _ in },
                                           fetcher: DiskLecture(folder: lecture), runner: TimedRunner(steps: steps),
                                           isolator: isolator, kind: kind, parent: sessions)
        let cpuBefore = (Self.cpu(RUSAGE_SELF), Self.cpu(RUSAGE_CHILDREN))
        let memoryBefore = Self.footprint()
        var peak = memoryBefore
        _ = try await URLSession.shared.data(from: session.playlistURL)
        var waits: [String] = []
        // As the player asks: the first three in order, a seek ahead, a seek back to heard audio.
        for index in Self.requests {
            let clock = ContinuousClock.now
            let (data, response) = try await URLSession.shared.data(from: session.playlistURL.deletingLastPathComponent()
                .appendingPathComponent(AudioEnhancement.segmentName(index)))
            try #require((response as? HTTPURLResponse)?.statusCode == 200 && !data.isEmpty)
            let wait = ContinuousClock.now - clock
            let footprint = Self.footprint()
            waits.append("seg\(index) \(Self.ms(wait)) \(footprint / 1_048_576) MB")
            peak = max(peak, footprint)
            // The player plays a while before asking for the next one: lets prefetch finish.
            try await Task.sleep(for: .seconds(3))
        }
        let cpu = (Self.cpu(RUSAGE_SELF) - cpuBefore.0, Self.cpu(RUSAGE_CHILDREN) - cpuBefore.1)
        session.stop()
        try await Task.sleep(for: .seconds(1))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        print("""
        MEASURE isolation=\(isolation) kind=\(kind.rawValue)
          waits: \(waits.joined(separator: ", "))
          steps: \(steps.summary)
          cpu: beepbar \(String(format: "%.2f", cpu.0)) s, ffmpeg \(String(format: "%.2f", cpu.1)) s
          memory: footprint \(memoryBefore / 1_048_576) MB before, peak \(peak / 1_048_576) MB, after stop \(Self.footprint() / 1_048_576) MB
          after stop: \(leftovers.count) files left, \(Self.children()) child processes running
        """)
        #expect(leftovers.isEmpty)
    }

    /// The cost of `VoiceLeveler` on a 62 s clip (a 30 s segment with its lead and tail), which
    /// every segment waits for: `gains` (the keypoints, run on the pipeline actor, so it blocks
    /// the seeks it serves) and `level` (the samples, off the actor), five repetitions each,
    /// median and max in ms. A time limit in the gate would be empty in a debug build and flaky
    /// under load, so it is measured here. Prints; asserts nothing about time.
    @Test func aMinuteOfLevellingTakesMilliseconds() {
        let leveler = VoiceLeveler()
        let clip = VoiceLeveler.Clip(samples: VoiceLevelerReferenceTests.lecture([(62, -40)]), start: 0)
        var gainTimes: [Double] = [], levelTimes: [Double] = []
        for _ in 0..<5 {
            let clock = ContinuousClock()
            var gains: [Int: Double] = [:]
            let a = clock.measure { gains = leveler.gains(for: 0...7, detector: clip, known: [:]) }
            let b = clock.measure { _ = leveler.level(clip, gains: gains) }
            gainTimes.append(Self.seconds(a) * 1000)
            levelTimes.append(Self.seconds(b) * 1000)
        }
        func summary(_ values: [Double]) -> String { "median \(String(format: "%.1f", values.sorted()[2])) ms, max \(String(format: "%.1f", values.max()!)) ms" }
        print("LEVELLING 62 s clip, 5 runs: gains \(summary(gainTimes)); level \(summary(levelTimes))")
        #expect(!gainTimes.isEmpty)
    }

    private static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    /// This process's children (ffmpeg, here) still running.
    private static func children() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(getpid())"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        // pgrep's own process is a child too while it runs, but it has exited by now.
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
    }

    private static func ms(_ duration: Duration) -> String {
        "\(Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000)) ms"
    }

    private static func cpu(_ who: Int32) -> Double {
        var usage = rusage()
        getrusage(who, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

/// Time spent in each step, by kind, and how many times it ran.
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var totals: [String: (count: Int, seconds: Double)] = [:]
    func add(_ kind: String, _ seconds: Double) {
        lock.withLock { totals[kind, default: (0, 0)].count += 1; totals[kind, default: (0, 0)].seconds += seconds }
    }
    var summary: String {
        lock.withLock {
            totals.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value.count) \(Int($0.value.seconds * 1000)) ms" }.joined(separator: ", ")
        }
    }
}

private struct TimedRunner: LiveAudioProcessRunning {
    let inner = FFmpegRunner()
    let steps: Steps
    func run(_ executable: URL, _ arguments: [String]) async throws {
        let kind = arguments.contains("framecrc") ? "probe" : arguments.contains("wav") ? "decode" : "encode"
        let start = Date()
        defer { steps.add(kind, Date().timeIntervalSince(start)) }
        try await inner.run(executable, arguments)
    }
}

private struct TimedIsolator: LiveAudioVoiceIsolating {
    let inner: LiveAudioVoiceIsolating
    let steps: Steps
    func isolate(_ input: URL, from first: Int, count: Int?, to output: URL) async throws {
        let start = Date()
        defer { steps.add("isolate", Date().timeIntervalSince(start)) }
        try await inner.isolate(input, from: first, count: count, to: output)
    }
}

/// The synthetic lecture from disk, as Webex serves it: the playlist whole, the file by range.
private struct DiskLecture: LiveAudioFetching {
    let folder: URL
    func fetch(_ url: URL, range: AudioEnhancement.ByteRangeLecture.Span?) async throws -> (data: Data, url: URL) {
        guard let range else { return (try Data(contentsOf: folder.appendingPathComponent("out.m3u8")), url) }
        let handle = try FileHandle(forReadingFrom: folder.appendingPathComponent("out.m4s"))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.offset))
        return (try handle.read(upToCount: Int(range.length)) ?? Data(), url)
    }
    func close() {}
}
