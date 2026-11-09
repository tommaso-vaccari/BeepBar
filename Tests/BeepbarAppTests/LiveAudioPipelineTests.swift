import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// Waits, a step at a time, for something another task does; fails the test after ~5 s.
private func eventually(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("never happened: \(what)")
    throw CancellationError()
}

/// Lets a test hold one named step until it says so, and see that it is being held.
private final class Gates: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var waiting: Set<String> = []
    func hold(_ name: String) { lock.withLock { _ = held.insert(name) } }
    func release(_ name: String) { lock.withLock { _ = held.remove(name) } }
    func isWaiting(_ name: String) -> Bool { lock.withLock { waiting.contains(name) } }
    func pass(_ name: String) async throws {
        while lock.withLock({ held.contains(name) }) {
            lock.withLock { _ = waiting.insert(name) }
            try await Task.sleep(for: .milliseconds(5))
        }
        lock.withLock { _ = waiting.remove(name) }
    }
}

/// Webex as the pipeline sees it, with no network: a byte-range playlist of `fragments`
/// 30-second fragments of one file, and zeros for every range. `failOnce` makes the first
/// fetch of those offsets fail as a Wi-Fi drop does.
private final class SyntheticWebex: LiveAudioFetching, @unchecked Sendable {
    static let fragmentBytes: Int64 = 1000
    let fragments: Int
    private let lock = NSLock()
    private var failing: Set<Int64>
    private var playlistFailures: Int
    init(fragments: Int, failOnce: Set<Int64> = [], failPlaylistOnce: Bool = false) {
        self.fragments = fragments
        failing = failOnce
        playlistFailures = failPlaylistOnce ? 1 : 0
    }
    var playlist: String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:30", "#EXT-X-PLAYLIST-TYPE:VOD",
                     "#EXT-X-MAP:URI=\"out.m4s\",BYTERANGE=\"100@0\""]
        for k in 0..<fragments {
            lines += ["#EXTINF:30.0,", "#EXT-X-BYTERANGE:\(Self.fragmentBytes)@\(100 + Int64(k) * Self.fragmentBytes)", "out.m4s"]
        }
        return (lines + ["#EXT-X-ENDLIST"]).joined(separator: "\n")
    }
    static func offset(of fragment: Int) -> Int64 { 100 + Int64(fragment) * fragmentBytes }
    func fetch(_ url: URL, range: AudioEnhancement.ByteRangeLecture.Span?) async throws -> (data: Data, url: URL) {
        guard let range else {
            if lock.withLock({ defer { playlistFailures = max(0, playlistFailures - 1) }; return playlistFailures > 0 }) {
                throw URLError(.notConnectedToInternet)
            }
            return (Data(playlist.utf8), url)
        }
        if lock.withLock({ failing.remove(range.offset) != nil }) { throw URLError(.notConnectedToInternet) }
        return (Data(count: Int(range.length)), url)
    }
    func close() {}
}

/// ffmpeg as the pipeline drives it, without ffmpeg: each run checks that every file it
/// would read is there, as ffmpeg fails on a missing one, then writes its output. A probe
/// answers that fragment `k`'s audio starts at `30 k` s; a decode writes a stand-in WAV; an
/// encode writes an MPEG-TS byte. `failOnce` fails the first run writing one of those names.
private final class FakeFFmpeg: LiveAudioProcessRunning, @unchecked Sendable {
    let gates = Gates()
    private let lock = NSLock()
    private var failing: Set<String>
    private var missing: [String] = []
    private var finished: [String] = []
    init(failOnce: Set<String> = []) { failing = failOnce }
    /// Runs that found a file they read deleted: each one a segment or piece lost.
    var missingInputs: [String] { lock.withLock { missing } }
    func hasFinished(_ name: String) -> Bool { lock.withLock { finished.contains(name) } }

    func run(_ executable: URL, _ arguments: [String]) async throws {
        guard let y = arguments.lastIndex(of: "-y"), y + 1 < arguments.count else { throw FFmpegExitError() }
        let output = URL(fileURLWithPath: arguments[y + 1])
        let name = output.lastPathComponent
        try await gates.pass(name)
        try Task.checkCancellation()
        defer { lock.withLock { finished.append(name) } }
        let inputs = arguments.enumerated().filter { $0.offset > 0 && arguments[$0.offset - 1] == "-i" }.map(\.element)
        let files = inputs.flatMap { $0.hasPrefix("concat:") ? $0.dropFirst("concat:".count).split(separator: "|").map(String.init) : [$0] }
        let gone = files.filter { !FileManager.default.fileExists(atPath: $0) }
        if !gone.isEmpty {
            lock.withLock { missing.append(name) }
            throw FFmpegExitError()
        }
        if lock.withLock({ failing.remove(name) != nil }) { throw FFmpegExitError() }
        if arguments.contains("framecrc") {
            let fragment = files.last.flatMap { Int(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.dropFirst("frag".count)) } ?? 0
            let pts = fragment * 30 * 48000
            try "#tb 0: 1/48000\n0, \(pts), \(pts), 1024, 10, 0x00000000\n".write(to: output, atomically: true, encoding: .utf8)
        } else if arguments.contains("mpegts") {
            try Data([0x47]).write(to: output)
        } else {
            try Data(count: 64).write(to: output)
        }
    }
}

/// Voice isolation as the pipeline uses it: writes the samples asked for (zeros), so a piece
/// spans exactly its fragment; records the decoded file each call was given (which names the
/// fragment and its surroundings: `decoded6l.wav` is fragment 6 with a lead-in, no tail).
private final class FakeIsolator: LiveAudioVoiceIsolating, @unchecked Sendable {
    let gates = Gates()
    private let lock = NSLock()
    private var made: [String] = []
    private var failing: Set<String>
    init(failOnce: Set<String> = []) { failing = failOnce }
    var calls: [String] { lock.withLock { made } }
    struct Failure: Error {}
    func isolate(_ input: URL, from first: Int, count: Int?, to output: URL) async throws {
        let name = input.lastPathComponent
        lock.withLock { made.append(name) }
        try await gates.pass(name)
        if lock.withLock({ failing.remove(name) != nil }) { throw Failure() }
        try Data(count: 2 * (count ?? 30 * 48000)).write(to: output)
    }
}

/// The live pipeline's bookkeeping (which fragments, pieces and segments are made, kept,
/// reused and deleted) with stand-ins for Webex, ffmpeg and isolation: no network, no ffmpeg,
/// so it runs on every Mac and in the gate, unlike `LiveAudioSessionTests`. Each test works in
/// its own throwaway folder.
struct LiveAudioPipelineTests {
    private let parent = FileManager.default.temporaryDirectory.appendingPathComponent("live-pipeline-\(UUID().uuidString)", isDirectory: true)
    private static let address = URL(string: "https://media.example.test/rec/out.m3u8")!

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [LiveAudioFailure] = []
        var all: [LiveAudioFailure] { lock.withLock { seen } }
        func add(_ failure: LiveAudioFailure) { lock.withLock { seen.append(failure) } }
    }

    private func pipeline(_ webex: SyntheticWebex, _ ffmpeg: FakeFFmpeg, _ isolator: FakeIsolator, reports: Reports = Reports()) -> LiveAudioPipeline {
        LiveAudioPipeline(stream: Self.address, ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), folder: parent.appendingPathComponent("session"),
                          parent: parent, fetcher: webex, runner: ffmpeg, isolator: isolator, report: { reports.add($0) })
    }

    private var pieceFiles: Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("session").path)) ?? []).filter { $0.hasSuffix(".raw") })
    }

    /// A seek forward, then a step back into the segment before: every segment is served, the
    /// piece made for the step back (with a lead-in, no tail) is kept rather than deleted, and
    /// asked for again it isn't isolated again. Before the fix `store` deleted that piece while
    /// `kept` chose it: the segment failed with a 502 for good and enhanced audio switched off
    /// "because it didn't work" (found in review: ⌘← after a seek).
    @Test func aSeekForwardThenAStepBackServesEverySegment() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg()
        let isolator = FakeIsolator()
        let reports = Reports()
        let pipeline = pipeline(SyntheticWebex(fragments: 8), ffmpeg, isolator, reports: reports)
        for index in [0, 6, 7, 5] { #expect(try await pipeline.segment(index).first == 0x47, "segment \(index)") }
        #expect(isolator.calls.filter { $0 == "decoded6l.wav" }.count == 1)
        // Away and back: segment 5 is made again from the pieces kept.
        _ = try await pipeline.segment(0)
        _ = try await pipeline.segment(5)
        #expect(isolator.calls.filter { $0 == "decoded6l.wav" }.count == 1, "isolated again: \(isolator.calls)")
        #expect(reports.all.isEmpty)
        #expect(ffmpeg.missingInputs.isEmpty)
        await pipeline.stop()
    }

    /// A piece replaced by one made with different surroundings while a segment still waits to
    /// use it stays on disk until that segment is made, and goes afterwards. Here segment 6
    /// waits for its next piece holding piece 6 (no lead-in, with its tail) when the step back
    /// to segment 5 makes piece 6 with a lead-in, no tail, which replaces it. Guards against
    /// deleting it at once (the segment's encode then found it gone, a 502 that never healed)
    /// and against replaced pieces left behind.
    @Test func aReplacedPieceStaysUntilTheSegmentUsingItIsMade() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg()
        let isolator = FakeIsolator()
        let pipeline = pipeline(SyntheticWebex(fragments: 8), ffmpeg, isolator)
        _ = try await pipeline.segment(0)
        isolator.gates.hold("decoded6t.wav")
        isolator.gates.hold("decoded7l.wav")
        isolator.gates.hold("decoded6l.wav")
        let six = Task { try await pipeline.segment(6) }
        try await eventually("piece 6 isolating") { isolator.gates.isWaiting("decoded6t.wav") && isolator.gates.isWaiting("decoded7l.wav") }
        let five = Task { try await pipeline.segment(5) }
        try await eventually("piece 6 with a lead-in isolating") { isolator.gates.isWaiting("decoded6l.wav") }
        isolator.gates.release("decoded6t.wav")
        try await eventually("piece 6 stored") { pieceFiles.contains("piece6t.raw") }
        isolator.gates.release("decoded6l.wav")
        #expect(try await five.value.first == 0x47, "segment 5")
        isolator.gates.release("decoded7l.wav")
        #expect(try await six.value.first == 0x47, "segment 6")
        #expect(ffmpeg.missingInputs.isEmpty)
        #expect(!pieceFiles.contains("piece6t.raw"), "the replaced piece was left behind")
        #expect(pieceFiles.contains("piece6l.raw"))
        await pipeline.stop()
    }

    /// A step that fails once (the playlist or a fragment over a Wi-Fi drop, a probe, the
    /// isolation, the encode) fails that request only: AVPlayer's next request makes the
    /// segment again and gets it. A network error is reported as `.network`, anything else as
    /// `.unavailable`. Guards against a failed step kept as the answer for the rest of the
    /// lecture: every retry got the same 502, the player gave up, and enhanced audio was
    /// turned off (found in review).
    @Test(arguments: ["playlist", "fragment", "probe", "isolation", "encode"])
    func aStepFailingOnceIsTriedAgain(step: String) async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let webex = SyntheticWebex(fragments: 4, failOnce: step == "fragment" ? [SyntheticWebex.offset(of: 1)] : [], failPlaylistOnce: step == "playlist")
        let ffmpeg = FakeFFmpeg(failOnce: step == "probe" ? ["probe1.txt"] : step == "encode" ? ["out1.ts"] : [])
        let isolator = FakeIsolator(failOnce: step == "isolation" ? ["decoded1lt.wav"] : [])
        let reports = Reports()
        let pipeline = pipeline(webex, ffmpeg, isolator, reports: reports)
        if step != "playlist" { _ = try await pipeline.segment(0) }
        await #expect(throws: (any Error).self) { _ = try await pipeline.segment(1) }
        #expect(try await pipeline.segment(1).first == 0x47, "the retry failed too")
        #expect(reports.all == [step == "playlist" || step == "fragment" ? .network : .unavailable])
        await pipeline.stop()
    }

    /// A seek keeps the fragments that work still underway reads: here an isolation of the
    /// first fragment kept, which reads the one before it as its lead-in. Guards against that
    /// fragment deleted under it, which failed the isolation's ffmpeg and was reported as the
    /// filter failing (found in review).
    @Test func aSeekKeepsTheFragmentsWorkUnderwayReads() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg()
        let isolator = FakeIsolator()
        let pipeline = pipeline(SyntheticWebex(fragments: 10), ffmpeg, isolator)
        // Segment 0 makes segment 1 ahead, whose next piece is fragment 2's, with its lead-in
        // (fragment 1) and tail (fragment 3).
        ffmpeg.gates.hold("decoded2lt.wav")
        _ = try await pipeline.segment(0)
        try await eventually("fragment 2 decoding") { ffmpeg.gates.isWaiting("decoded2lt.wav") }
        // Segments 2–6 are kept around 4: fragment 2's isolation stays, fragment 1 is outside.
        _ = try await pipeline.segment(4)
        ffmpeg.gates.release("decoded2lt.wav")
        try await eventually("fragment 2 decoded") { ffmpeg.hasFinished("decoded2lt.wav") }
        #expect(ffmpeg.missingInputs.isEmpty, "deleted under a run: \(ffmpeg.missingInputs)")
        await pipeline.stop()
    }

    /// How a failure is read: Webex refusing the address is an expiry, a connection error or
    /// Webex's 5xx/429 is passing, anything else is the filter's own. Guards against a Wi-Fi
    /// drop turning enhanced audio off for the lecture.
    @Test func failuresAreClassified() {
        #expect(LiveAudioPipeline.failure(for: LiveAudioFetchError.refused(403)) == .streamRefused)
        #expect(LiveAudioPipeline.failure(for: LiveAudioFetchError.unavailableNow(503)) == .network)
        #expect(LiveAudioPipeline.failure(for: URLError(.timedOut)) == .network)
        #expect(LiveAudioPipeline.failure(for: LiveAudioFetchError.unexpected) == .unavailable)
        #expect(LiveAudioPipeline.failure(for: FFmpegExitError()) == .unavailable)
    }
}
