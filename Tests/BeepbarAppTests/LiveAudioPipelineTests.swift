import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// Waits, a step at a time, for something another task does; fails the test after ~5 s.
private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("never happened: \(what)")
    throw CancellationError()
}

/// The name a file of one run has without its run number (`runFile`): `decoded6l-12.wav` is
/// `decoded6l.wav`, the name tests hold, fail and look for.
private func stem(_ name: String) -> String {
    name.replacingOccurrences(of: #"-[0-9]+(?=\.[a-z0-9]+$)"#, with: "", options: .regularExpression)
}

/// Lets a test hold one named step until it says so, see how many runs it holds, and let
/// them through one at a time in arrival order. A held run that is cancelled leaves at once,
/// unless held `throughCancellation`: then it waits on, as a real ffmpeg process does until
/// it is terminated, and ends as `FFmpegRunner` ends it.
private final class Gates: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<String> = []
    private var stubborn: Set<String> = []
    private var waiting: [String: Int] = [:]
    private var arrivals: [String: Int] = [:]
    private var letThrough: [String: Int] = [:]
    func hold(_ name: String, throughCancellation: Bool = false) {
        lock.withLock { held.insert(name); if throughCancellation { stubborn.insert(name) } }
    }
    func release(_ name: String) { lock.withLock { _ = held.remove(name) } }
    /// Lets the earliest run still held at `name` through.
    func releaseOne(_ name: String) { lock.withLock { letThrough[name, default: 0] += 1 } }
    func waiters(_ name: String) -> Int { lock.withLock { waiting[name, default: 0] } }
    func isWaiting(_ name: String) -> Bool { waiters(name) > 0 }
    func pass(_ name: String) async throws {
        let ticket = lock.withLock { defer { arrivals[name, default: 0] += 1 }; return arrivals[name, default: 0] }
        var counted = false
        defer { if counted { lock.withLock { waiting[name, default: 1] -= 1 } } }
        while lock.withLock({ held.contains(name) && ticket >= letThrough[name, default: 0] }) {
            if !counted { counted = true; lock.withLock { waiting[name, default: 0] += 1 } }
            if lock.withLock({ stubborn.contains(name) }) {
                await Task.detached { try? await Task.sleep(for: .milliseconds(5)) }.value
            } else {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
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
    /// Holds the playlist fetch when a test asks (`"playlist"`).
    let gates = Gates()
    /// Whether every failure asked for has happened.
    var failedAll: Bool { lock.withLock { failing.isEmpty && playlistFailures == 0 } }
    func fetch(_ url: URL, range: AudioEnhancement.ByteRangeLecture.Span?) async throws -> (data: Data, url: URL) {
        guard let range else {
            try await gates.pass("playlist")
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
/// would read is there, as ffmpeg fails on a missing one (a cancelled run's failure is a
/// cancellation, as `FFmpegRunner` reports it), then writes its output. A probe
/// answers that fragment `k`'s audio starts at `30 k` s; a decode writes a stand-in WAV; an
/// encode writes an MPEG-TS byte. `failOnce` fails the first run writing one of those names.
private final class FakeFFmpeg: LiveAudioProcessRunning, @unchecked Sendable {
    let gates = Gates()
    private let lock = NSLock()
    private var failing: Set<String>
    private var missing: [String] = []
    private var finished: [String] = []
    init(failOnce: Set<String> = []) { failing = failOnce }
    /// Runs that found a file they read deleted, and those files: each one a segment or piece lost.
    var missingInputs: [String] { lock.withLock { missing } }
    var failedAll: Bool { lock.withLock { failing.isEmpty } }
    func hasFinished(_ name: String) -> Bool { lock.withLock { finished.contains(name) } }

    func run(_ executable: URL, _ arguments: [String]) async throws {
        guard let y = arguments.lastIndex(of: "-y"), y + 1 < arguments.count else { throw FFmpegExitError() }
        let output = URL(fileURLWithPath: arguments[y + 1])
        let name = stem(output.lastPathComponent)
        try await gates.pass(name)
        try Task.checkCancellation()
        defer { lock.withLock { finished.append(name) } }
        let inputs = arguments.enumerated().filter { $0.offset > 0 && arguments[$0.offset - 1] == "-i" }.map(\.element)
        let files = inputs.flatMap { $0.hasPrefix("concat:") ? $0.dropFirst("concat:".count).split(separator: "|").map(String.init) : [$0] }
        let gone = files.filter { !FileManager.default.fileExists(atPath: $0) }
        if !gone.isEmpty {
            try Task.checkCancellation()
            let names = gone.map { stem(URL(fileURLWithPath: $0).lastPathComponent) }
            lock.withLock { missing.append("\(name) ← \(names.joined(separator: ", "))") }
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
    private var given: [URL] = []
    private var missing: [String] = []
    private var failing: Set<String>
    init(failOnce: Set<String> = []) { failing = failOnce }
    var calls: [String] { lock.withLock { made } }
    /// The decoded file each call was given, with its run number.
    var inputs: [URL] { lock.withLock { given } }
    /// Calls whose decoded file was deleted under them: a piece lost.
    var missingInputs: [String] { lock.withLock { missing } }
    var failedAll: Bool { lock.withLock { failing.isEmpty } }
    struct Failure: Error {}
    func isolate(_ input: URL, from first: Int, count: Int?, to output: URL) async throws {
        let name = stem(input.lastPathComponent)
        lock.withLock { made.append(name); given.append(input) }
        try await gates.pass(name)
        guard FileManager.default.fileExists(atPath: input.path) else {
            lock.withLock { missing.append(name) }
            throw Failure()
        }
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
        private var seen: [LiveAudioFailure?] = []
        var all: [LiveAudioFailure?] { lock.withLock { seen } }
        func add(_ failure: LiveAudioFailure?) { lock.withLock { seen.append(failure) } }
    }

    private func pipeline(_ webex: SyntheticWebex, _ ffmpeg: FakeFFmpeg, _ isolator: FakeIsolator, reports: Reports = Reports()) -> LiveAudioPipeline {
        LiveAudioPipeline(stream: Self.address, ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), folder: parent.appendingPathComponent("session"),
                          parent: parent, fetcher: webex, runner: ffmpeg, isolator: isolator, report: { reports.add($0) })
    }

    private var pieceFiles: Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("session").path)) ?? []).filter { $0.hasSuffix(".raw") }.map(stem))
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
        #expect(ffmpeg.missingInputs.isEmpty, "deleted under a run: \(ffmpeg.missingInputs)")
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
        try await eventually("piece 6 stored") { await pipeline.keptPiece(6).map { !$0.hasLead && $0.hasTail } == true }
        isolator.gates.release("decoded6l.wav")
        #expect(try await five.value.first == 0x47, "segment 5")
        isolator.gates.release("decoded7l.wav")
        #expect(try await six.value.first == 0x47, "segment 6")
        #expect(ffmpeg.missingInputs.isEmpty, "deleted under a run: \(ffmpeg.missingInputs)")
        // Deleted once no segment is being made, the one made ahead of segment 6 included.
        try await eventually("the replaced piece deleted") { !pieceFiles.contains("piece6t.raw") }
        #expect(pieceFiles.contains("piece6l.raw"))
        await pipeline.stop()
    }

    /// A step of the segment asked for that fails once (the playlist or a fragment over a
    /// Wi-Fi drop, a probe, the isolation, the encode) fails that request only, reported as
    /// `.network` for a network error and `.unavailable` otherwise; AVPlayer's next request
    /// makes the segment again, gets it, and reports that the failure passed (nil). Guards
    /// against a failed step kept as the answer for the rest of the lecture: every retry got
    /// the same 502, the player gave up, and enhanced audio was turned off (found in review).
    @Test(arguments: ["playlist", "fragment", "probe", "isolation", "encode"])
    func aStepFailingOnceIsTriedAgain(step: String) async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        // Steps of segment 0's own: whichever task runs them first, segment 0 waits on it.
        let webex = SyntheticWebex(fragments: 4, failOnce: step == "fragment" ? [SyntheticWebex.offset(of: 0)] : [], failPlaylistOnce: step == "playlist")
        let ffmpeg = FakeFFmpeg(failOnce: step == "probe" ? ["probe0.txt"] : step == "encode" ? ["out0.ts"] : [])
        let isolator = FakeIsolator(failOnce: step == "isolation" ? ["decoded0t.wav"] : [])
        let reports = Reports()
        let pipeline = pipeline(webex, ffmpeg, isolator, reports: reports)
        await #expect(throws: (any Error).self) { _ = try await pipeline.segment(0) }
        #expect(try await pipeline.segment(0).first == 0x47, "the retry failed too")
        #expect(reports.all == [step == "playlist" || step == "fragment" ? .network : .unavailable, nil])
        await pipeline.stop()
    }

    /// A step of the segment made ahead that fails once (here segment 1's, made while segment
    /// 0 is served) never reaches AVPlayer: its request makes that segment again instead of
    /// answering with the old error, and nothing is reported. Guards against a Wi-Fi drop long
    /// over answered as a 502 and reported as a failure when the segment is asked for (found
    /// in review).
    @Test(arguments: ["fragment", "probe", "isolation", "encode"])
    func aStepFailingAheadIsMadeAgainForItsRequest(step: String) async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        // Steps segment 1 needs and segment 0 doesn't: fragment 2, its start, piece 1 with its
        // tail, segment 1's encode.
        let webex = SyntheticWebex(fragments: 4, failOnce: step == "fragment" ? [SyntheticWebex.offset(of: 2)] : [])
        let ffmpeg = FakeFFmpeg(failOnce: step == "probe" ? ["probe2.txt"] : step == "encode" ? ["out1.ts"] : [])
        let isolator = FakeIsolator(failOnce: step == "isolation" ? ["decoded1lt.wav"] : [])
        let reports = Reports()
        let pipeline = pipeline(webex, ffmpeg, isolator, reports: reports)
        #expect(try await pipeline.segment(0).first == 0x47)
        #expect(try await pipeline.segment(1).first == 0x47)
        #expect(webex.failedAll && ffmpeg.failedAll && isolator.failedAll, "the step never failed")
        #expect(reports.all.isEmpty)
        await pipeline.stop()
    }

    /// Stopping ends every isolation underway, also one that another for the same fragment
    /// (asked with other surroundings) started beside. Guards against that first one running
    /// on unseen, with its ffmpeg, after the player closed, and its fragments deleted under it
    /// by a seek (it was replaced in the bookkeeping, found in review).
    @Test func stopEndsEveryIsolationUnderway() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg()
        let isolator = FakeIsolator()
        let pipeline = pipeline(SyntheticWebex(fragments: 8), ffmpeg, isolator)
        _ = try await pipeline.segment(0)
        ffmpeg.gates.hold("decoded6t.wav")
        ffmpeg.gates.hold("decoded6l.wav")
        let six = Task { try? await pipeline.segment(6) }
        try await eventually("piece 6 decoding") { ffmpeg.gates.isWaiting("decoded6t.wav") }
        let five = Task { try? await pipeline.segment(5) }
        try await eventually("piece 6 with a lead-in decoding") { ffmpeg.gates.isWaiting("decoded6l.wav") }
        await pipeline.stop()
        ffmpeg.gates.release("decoded6t.wav")
        ffmpeg.gates.release("decoded6l.wav")
        // Each segment waits for its piece's isolation to end.
        _ = await six.value
        _ = await five.value
        #expect(!ffmpeg.hasFinished("decoded6t.wav"), "an isolation outlived stop")
        #expect(!ffmpeg.hasFinished("decoded6l.wav"))
    }

    /// A seek away ends the isolation of a piece no longer near, and the request left behind
    /// (which the local server can't cancel: it never sees AVPlayer drop the connection) doesn't
    /// start it again. Guards against isolations of every part skipped running on, each with
    /// its ffmpeg and the voice model, after the student jumped ahead (`keep`), and against the
    /// abandoned request rebuilding its segment after every seek (found in testing).
    @Test func aSeekAwayEndsAnIsolationNoLongerNeeded() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg()
        let isolator = FakeIsolator()
        let pipeline = pipeline(SyntheticWebex(fragments: 40), ffmpeg, isolator)
        _ = try await pipeline.segment(0)
        isolator.gates.hold("decoded6t.wav")
        let six = Task { try await pipeline.segment(6) }
        try await eventually("piece 6 isolating") { isolator.gates.isWaiting("decoded6t.wav") }
        #expect(try await pipeline.segment(20).first == 0x47)
        try await eventually("piece 6's isolation ended") { !isolator.gates.isWaiting("decoded6t.wav") }
        await #expect(throws: (any Error).self) { _ = try await six.value }
        #expect(isolator.calls.filter { $0 == "decoded6t.wav" }.count == 1, "piece 6 was isolated again")
        #expect(!ffmpeg.hasFinished("out6.ts"))
        isolator.gates.release("decoded6t.wav")
        await pipeline.stop()
    }

    /// A request that arrived first but waited on the playlist, far from the next one, seeks
    /// late: it cancels the work of the request that arrived after it, which is where the
    /// player now is and so is made again. Guards against the latest request answered with a
    /// 502 because an older one's seek logic ran after it (the case the retry exists for), and
    /// against taking the order requests resumed in for the order they arrived in.
    @Test func theLatestRequestOutlivesAnEarlierOnesLateSeek() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let webex = SyntheticWebex(fragments: 40)
        let pipeline = pipeline(webex, FakeFFmpeg(), FakeIsolator())
        webex.gates.hold("playlist")
        let far = Task { try await pipeline.segment(30) }
        try await eventually("the playlist asked") { webex.gates.isWaiting("playlist") }
        let near = Task { try await pipeline.segment(6) }
        try await eventually("the near request arrived") { await pipeline.lastRequested() == 6 }
        webex.gates.release("playlist")
        #expect(try await near.value.first == 0x47, "the latest request failed")
        _ = try? await far.value
        await pipeline.stop()
    }

    /// An isolation ended by a seek whose process is still exiting (ffmpeg takes a moment to
    /// stop) doesn't touch the files of the isolation of the same piece started after it. Guards
    /// against the old run deleting the new run's decoded audio, which then had no input and lost
    /// the piece (runs once shared a file name; found under load).
    @Test func anEndedRunDoesNotDeleteTheFilesOfTheNext() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let isolator = FakeIsolator()
        let pipeline = pipeline(SyntheticWebex(fragments: 40), FakeFFmpeg(), isolator)
        _ = try await pipeline.segment(0)
        isolator.gates.hold("decoded6t.wav", throughCancellation: true)
        let first = Task { try? await pipeline.segment(6) }
        try await eventually("the first isolation held") { isolator.gates.waiters("decoded6t.wav") == 1 }
        _ = try await pipeline.segment(20)
        let second = Task { try await pipeline.segment(6) }
        try await eventually("the second isolation held") { isolator.gates.waiters("decoded6t.wav") == 2 }
        // The ended run finishes and cleans up; then the new one reads its decoded audio.
        let ended = try #require(isolator.inputs.first { stem($0.lastPathComponent) == "decoded6t.wav" })
        isolator.gates.releaseOne("decoded6t.wav")
        try await eventually("the ended run cleaned up") { !FileManager.default.fileExists(atPath: ended.path) }
        isolator.gates.release("decoded6t.wav")
        #expect(try await second.value.first == 0x47)
        #expect(isolator.missingInputs.isEmpty, "a run lost its input: \(isolator.missingInputs)")
        _ = await first.value
        await pipeline.stop()
    }

    /// An isolation that ends after one covering more of the same fragment was kept (asked with
    /// a lead-in meanwhile) deletes its own piece instead of leaving it on disk. Guards against
    /// stray pieces filling the temporary folder beyond `keptPieces`.
    @Test func aPieceAlreadyCoveredIsDeleted() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        // Fragment 6 is the last: every piece of it reaches the end, with or without a lead-in.
        let ffmpeg = FakeFFmpeg()
        let pipeline = pipeline(SyntheticWebex(fragments: 7), ffmpeg, FakeIsolator())
        _ = try await pipeline.segment(0)
        ffmpeg.gates.hold("decoded6.wav")
        let six = Task { try? await pipeline.segment(6) }
        try await eventually("piece 6 decoding") { ffmpeg.gates.isWaiting("decoded6.wav") }
        _ = try await pipeline.segment(5)
        try await eventually("piece 6 with a lead-in kept") { await pipeline.keptPiece(6).map { $0.hasLead && $0.hasTail } == true }
        ffmpeg.gates.release("decoded6.wav")
        _ = await six.value
        try await eventually("the covered piece deleted") { !pieceFiles.contains("piece6.raw") }
        #expect(pieceFiles.contains("piece6l.raw"))
        await pipeline.stop()
    }

    /// Played straight through, a lecture keeps at most `keptPieces` pieces on disk, the most
    /// recent ones. Guards against a lecture filling the temporary folder (2.9 MB a piece).
    @Test func atMostKeptPiecesStayOnDisk() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let count = LiveAudioPipeline.keptPieces + 6
        let pipeline = pipeline(SyntheticWebex(fragments: count), FakeFFmpeg(), FakeIsolator())
        for index in 0..<count { #expect(try await pipeline.segment(index).first == 0x47, "segment \(index)") }
        try await eventually("only the kept pieces left") { pieceFiles.count == LiveAudioPipeline.keptPieces }
        #expect(pieceFiles.contains { $0.hasPrefix("piece\(count - 1)") })
        #expect(!pieceFiles.contains { $0.hasPrefix("piece0") })
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
