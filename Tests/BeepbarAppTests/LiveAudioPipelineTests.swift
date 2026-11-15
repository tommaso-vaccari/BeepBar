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
/// With `originalTone` the decode writes what a real one does, a mono 48 kHz float WAV of a
/// 440 Hz sine of that amplitude, as long as the `atrim` of its arguments says; and every encode
/// records its arguments and the bytes of the levelled file it was given, which is deleted once
/// the encode returns.
private final class FakeFFmpeg: LiveAudioProcessRunning, @unchecked Sendable {
    let gates = Gates()
    private let lock = NSLock()
    private var failing: Set<String>
    private var missing: [String] = []
    private var finished: [String] = []
    private var encoded: [String: Encode] = [:]
    private let originalTone: Float?
    /// With `decodeLimit` a decode writes at most that many samples: a WAV shorter than the
    /// span the isolated piece covers, as the last fragment's can be.
    private let decodeLimit: Int?
    init(failOnce: Set<String> = [], originalTone: Float? = nil, decodeLimit: Int? = nil) { failing = failOnce; self.originalTone = originalTone; self.decodeLimit = decodeLimit }
    /// One encode: its arguments, the bytes of the raw float input it read and the sample
    /// position the filter puts that input at.
    struct Encode { let arguments: [String]; let levelled: Data?; let firstSample: Int }
    /// The last encode that wrote each output (`out3.ts`).
    func encode(_ name: String) -> Encode? { lock.withLock { encoded[name] } }
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
            let raw = zip(arguments, arguments.dropFirst()).first { $0.0 == "-i" && $0.1.hasSuffix(".raw") }?.1
            let filter = arguments.first { $0.hasPrefix("asetpts=(N+") } ?? ""
            let first = filter.firstMatch(of: /asetpts=\(N\+(\d+)\)/).flatMap { Int($0.1) } ?? 0
            let levelled = raw.flatMap { FileManager.default.contents(atPath: $0) }
            lock.withLock { encoded[name] = Encode(arguments: arguments, levelled: levelled, firstSample: first) }
            try Data([0x47]).write(to: output)
        } else if let amplitude = originalTone, let trim = arguments.first(where: { $0.contains("atrim=start_sample=") }) {
            // The decode: as long as the trim keeps (a fragment and its lead-in when it has no end).
            let numbers = trim.matches(of: /_sample=(\d+)/).compactMap { Int($0.1) }
            let length = min(decodeLimit ?? .max, numbers.count > 1 ? numbers[1] - numbers[0] : (numbers[0] > 0 ? 34 : 30) * 48000)
            try AudioTestTones.floatWAV(tone(amplitude, hz: 440, count: length)).write(to: output)
        } else {
            try Data(count: 64).write(to: output)
        }
    }
}

/// Sine waves for the fakes: whole-second tiles, so a long one is cheap to make. Copied a
/// second at a time with `update(from:)`: an element-by-element `map` over a minute of samples
/// is what made the pipeline tests cost tens of CPU seconds in debug builds.
private func tone(_ amplitude: Float, hz: Int, count: Int) -> [Float] {
    let second = (0..<48000).map { amplitude * Float(sin(2 * Double.pi * Double(hz) * Double($0) / 48000)) }
    return tiled(second, count: count)
}

/// The same tone as 16-bit samples (what the isolator writes), by tiles of a second.
private func tone16(_ amplitude: Float, hz: Int, count: Int) -> [Int16] {
    let second = (0..<48000).map { Int16(((amplitude * Float(sin(2 * Double.pi * Double(hz) * Double($0) / 48000))) * 32767).rounded()) }
    return tiled(second, count: count)
}

private func tiled<T>(_ tile: [T], count: Int) -> [T] {
    guard count > 0, let first = tile.first else { return [] }
    var out = [T](repeating: first, count: count)
    out.withUnsafeMutableBufferPointer { destination in
        tile.withUnsafeBufferPointer { source in
            var at = 0
            while at < count {
                let n = min(source.count, count - at)
                (destination.baseAddress! + at).update(from: source.baseAddress!, count: n)
                at += n
            }
        }
    }
    return out
}

private enum AudioTestTones {
    /// A mono 48 kHz 32-bit float WAV (IEEE float, format 3), as ffmpeg's decode writes.
    static func floatWAV(_ samples: [Float]) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        let bytes = samples.count * 4
        var d = Data("RIFF".utf8)
        d += le(UInt32(36 + bytes)) + Data("WAVEfmt ".utf8) + le(UInt32(16)) + le(UInt16(3)) + le(UInt16(1))
        d += le(UInt32(48000)) + le(UInt32(48000 * 4)) + le(UInt16(4)) + le(UInt16(32)) + Data("data".utf8) + le(UInt32(bytes))
        samples.withUnsafeBufferPointer { d += Data(buffer: $0) }
        return d
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
    private let amplitude: (@Sendable (Int) -> Float)?
    private var failingAfterWriting: Set<String>
    /// With `amplitude`, the isolated voice is a 880 Hz sine of the amplitude it gives for the
    /// fragment (the decoded file's name says which), instead of zeros.
    /// `failAfterWriting` fails the first call for those decoded files after the output is written, as a
    /// real isolator does when it dies or is cancelled mid-write; `gates` also hold `"written-<name>"`,
    /// the moment after the output is on disk.
    init(failOnce: Set<String> = [], failAfterWriting: Set<String> = [], amplitude: (@Sendable (Int) -> Float)? = nil) {
        failing = failOnce; failingAfterWriting = failAfterWriting; self.amplitude = amplitude
    }
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
        let length = count ?? 30 * 48000
        if let amplitude, let fragment = name.firstMatch(of: /decoded(\d+)/).flatMap({ Int($0.1) }) {
            let samples = tone16(amplitude(fragment), hz: 880, count: length)
            try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: output)
        } else {
            try Data(count: 2 * length).write(to: output)
        }
        if lock.withLock({ failingAfterWriting.remove(name) != nil }) { throw Failure() }
        try await gates.pass("written-" + name)
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

    private func pipeline(_ webex: SyntheticWebex, _ ffmpeg: FakeFFmpeg, _ isolator: FakeIsolator, kind: AudioEnhancementKind = .isolated, reports: Reports = Reports()) -> LiveAudioPipeline {
        LiveAudioPipeline(stream: Self.address, ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), folder: parent.appendingPathComponent("session"),
                          parent: parent, fetcher: webex, runner: ffmpeg, isolator: isolator, kind: kind, report: { reports.add($0) })
    }

    /// The raw files of the session folder whose name starts with `prefix`, run numbers removed.
    private func rawFiles(_ prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("session").path)) ?? []).filter { $0.hasSuffix(".raw") && $0.hasPrefix(prefix) }
    }
    private func size(_ name: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: parent.appendingPathComponent("session").appendingPathComponent(name).path)[.size] as? Int) ?? 0
    }

    private static func rms(_ data: Data, _ range: Range<Int>) -> Double {
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (range.reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / Double(range.count)).squareRoot()
    }

    private var pieceFiles: Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent("session").path)) ?? []).filter { $0.hasSuffix(".raw") && $0.hasPrefix("piece") }.map(stem))
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

    /// An isolation that ends after its isolator wrote the piece but before the piece is stored
    /// (cancelled by a seek away, or the isolator dying mid-write) leaves neither the piece nor an
    /// original on disk, in both kinds. Guards against a leak of 2.9 MB (5.8 MB more in
    /// `.levelled`) per abandoned isolation until the player closes.
    @Test(arguments: [AudioEnhancementKind.isolated, .levelled])
    func anIsolationEndedBeforeItsPieceIsStoredLeavesNoFile(kind: AudioEnhancementKind) async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        // Cancelled after the isolator wrote the file.
        let ffmpeg = FakeFFmpeg(originalTone: 0.01)
        let isolator = FakeIsolator(failAfterWriting: ["decoded0t.wav"], amplitude: { _ in 0.1 })
        let pipeline = pipeline(SyntheticWebex(fragments: 40), ffmpeg, isolator, kind: kind)
        // The isolator dying mid-write: segment 0 fails, and the piece it started is gone.
        await #expect(throws: (any Error).self) { _ = try await pipeline.segment(0) }
        #expect(!rawFiles("piece").contains { stem($0) == "piece0t.raw" }, "left by a failed isolator: \(rawFiles("piece"))")
        #expect(!rawFiles("original").contains { stem($0) == "original0t.raw" })
        _ = try await pipeline.segment(0)
        isolator.gates.hold("written-decoded6t.wav")
        let six = Task { try await pipeline.segment(6) }
        try await eventually("piece 6 written and held") { isolator.gates.isWaiting("written-decoded6t.wav") }
        #expect(rawFiles("piece").contains { stem($0) == "piece6t.raw" }, "the isolator's output is on disk while it waits")
        #expect(try await pipeline.segment(20).first == 0x47)
        try await eventually("piece 6's isolation ended") { !isolator.gates.isWaiting("written-decoded6t.wav") }
        await #expect(throws: (any Error).self) { _ = try await six.value }
        #expect(!rawFiles("piece").contains { stem($0) == "piece6t.raw" }, "left by a cancelled isolation: \(rawFiles("piece"))")
        #expect(!rawFiles("original").contains { stem($0) == "original6t.raw" })
        isolator.gates.release("written-decoded6t.wav")
        await pipeline.stop()
    }

    /// An isolation ended while the original's copy is under way (a seek away, in `.levelled`)
    /// leaves no `original` file: the half-written copy is deleted. The copy is stopped at its
    /// first block boundary by the pipeline's test checkpoint (`originalCheckpoint`), which
    /// waits there until its task is cancelled, so the order is forced, not raced: copy stopped
    /// midway (the test asserts the file is there and holds exactly one block), then the seek
    /// to segment 20 cancels isolation 6 inside the copy, then the cleanup runs. It no longer
    /// depends on how long the copy takes (it failed when the copy was made a block move that
    /// ended before the seek arrived: issue #243). The two failure points the test above covers
    /// both precede the copy, so only this one can fail when the cleanup is removed. Guards
    /// against 5.8 MB per 30 s of audio, up to the whole lecture, left in the temporary folder
    /// by every seek that arrives while an original is being written.
    @Test(.timeLimit(.minutes(1))) func anIsolationEndedWhileTheOriginalIsCopiedLeavesNoOriginal() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg(originalTone: 0.01)
        let isolator = FakeIsolator(amplitude: { _ in 0.1 })
        let pipeline = pipeline(SyntheticWebex(fragments: 40), ffmpeg, isolator, kind: .levelled)
        // Stops the copy of piece 6's original after its first block, until its task is
        // cancelled: the wait ends only that way, so the seek below is what ends it. Other
        // pieces' copies (the prefetched neighbours, segment 20's) are not held.
        let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { stopped.continuation.finish() }
        await pipeline.setOriginalCheckpointForTesting { output, blocks in
            guard blocks == 1, stem(output.lastPathComponent) == "original6t.raw" else { return }
            stopped.continuation.yield(())
            try await Task.sleep(for: .seconds(90))
            Issue.record("the seek did not cancel the copy")
            throw CancellationError()
        }
        _ = try await pipeline.segment(0)
        let six = Task { try await pipeline.segment(6) }
        let reached = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stopped.stream { return true }; return false }
            group.addTask { do { try await Task.sleep(for: .seconds(45)) } catch { return false }; return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard reached else {
            Issue.record("original copy did not reach its checkpoint")
            six.cancel()
            await pipeline.stop()
            return
        }
        // A throw from here on must still stop the pipeline before the `defer` above removes the
        // folder: the held copy would otherwise keep writing into a deleted directory.
        do {
            // The copy is under way and cut short: the file is there with exactly the one block.
            let original = try #require(rawFiles("original").first { stem($0) == "original6t.raw" }, "the copy stopped before its file existed")
            #expect(size(original) == 65_536 * 4, "the copy was not stopped after its first block")
            #expect(rawFiles("piece").contains { stem($0) == "piece6t.raw" })
            #expect(try await pipeline.segment(20).first == 0x47)
            await #expect(throws: (any Error).self) { _ = try await six.value }
            // `six` may throw before the cancelled isolation has finished unwinding, so the cleanup
            // is waited for (an external event: it has no signal of its own).
            try await eventually("the half-written original and its piece deleted") {
                !rawFiles("original").contains { stem($0) == "original6t.raw" } && !rawFiles("piece").contains { stem($0) == "piece6t.raw" }
            }
        } catch {
            six.cancel()
            await pipeline.stop()
            _ = try? await six.value
            throw error
        }
        await pipeline.stop()
    }

    /// A decoded WAV shorter than the piece (the last fragment's can be) gives an original of
    /// exactly the piece's length: the samples there are, then silence. `AVAudioFile.read`
    /// throws `eofErr` at the end of the file instead of returning no frames, so asking for
    /// more than is left used to fail the segment and, in `.levelled`, turn the lecture's
    /// enhanced audio off. Guards against that, and against the original being shorter than the
    /// piece (the gain and the audio drifting apart).
    @Test func aDecodeShorterThanThePieceIsPaddedWithSilence() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let shortBy = 40_000
        let pipeline = pipeline(SyntheticWebex(fragments: 4), FakeFFmpeg(originalTone: 0.1, decodeLimit: shortBy), FakeIsolator(amplitude: { _ in 0.1 }), kind: .levelled)
        _ = try await pipeline.segment(0)
        let name = try #require(rawFiles("original").first { stem($0) == "original0t.raw" })
        let data = try #require(FileManager.default.contents(atPath: parent.appendingPathComponent("session").appendingPathComponent(name).path))
        let pieceSamples = size(try #require(rawFiles("piece").first { stem($0) == "piece0t.raw" })) / 2
        #expect(pieceSamples > shortBy)
        #expect(data.count == pieceSamples * 4, "\(data.count) bytes for \(pieceSamples) samples")
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(Self.rms(data, 0..<shortBy) > 0.05, "the decoded samples are there")
        #expect(samples[shortBy...].allSatisfy { $0 == 0 }, "then silence")
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
    ///
    /// In `.levelled` each kept piece's original is kept with it and goes with it, one to one:
    /// guards against an eviction that retires the piece file and leaves the original (5.8 MB a
    /// piece, kept until the player closes).
    @Test(arguments: [AudioEnhancementKind.isolated, .levelled])
    func atMostKeptPiecesStayOnDisk(kind: AudioEnhancementKind) async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let count = LiveAudioPipeline.keptPieces + 2
        let levelled = kind == .levelled
        // One second of decoded audio (the original is then padded with silence): the files are
        // what is counted, and 46 segments of a full-size tone would starve the other suites.
        let ffmpeg = FakeFFmpeg(originalTone: levelled ? 0.01 : nil, decodeLimit: 48_000)
        var amplitude: (@Sendable (Int) -> Float)?
        if levelled { amplitude = { _ in 0.1 } }
        let pipeline = pipeline(SyntheticWebex(fragments: count), ffmpeg, FakeIsolator(amplitude: amplitude), kind: kind)
        for index in 0..<count {
            let served = try await pipeline.segment(index)
            #expect(served.first == 0x47, "segment \(index)")
        }
        try await eventually("only the kept pieces left") { pieceFiles.count == LiveAudioPipeline.keptPieces }
        #expect(pieceFiles.contains { $0.hasPrefix("piece\(count - 1)") })
        #expect(!pieceFiles.contains { $0.hasPrefix("piece0") })
        if levelled {
            try await eventually("the originals of the kept pieces only") {
                let originals: Set<String> = Set(rawFiles("original").map { stem($0) })
                let expected: Set<String> = Set(pieceFiles.map { "original" + String($0.dropFirst("piece".count)) })
                return originals.count == LiveAudioPipeline.keptPieces && originals == expected
            }
        } else {
            #expect(rawFiles("original").isEmpty)
        }
        await pipeline.stop()
    }

    // MARK: Levelling

    /// In `.isolated` the segment is encoded from one raw float file and no piece has an original
    /// file next to it; the encode is `levelledEncodeArguments` (the chain and the clock offset in
    /// one filter). Guards against the original being written when nothing will use it (115 MB
    /// more on disk for nothing) and against the encode reading anything but the levelled file.
    @Test func isolatedKindEncodesOneLevelledInputAndKeepsNoOriginal() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg()
        let pipeline = pipeline(SyntheticWebex(fragments: 4), ffmpeg, FakeIsolator())
        _ = try await pipeline.segment(1)
        let encode = try #require(ffmpeg.encode("out1.ts"))
        let first = encode.firstSample
        #expect(encode.arguments.filter { $0 == "-i" }.count == 2, "the video and one levelled input")
        let levelledIndex = try #require(encode.arguments.lastIndex(of: "-i"))
        #expect(encode.arguments[levelledIndex + 1].contains("levelled1"))
        #expect(encode.arguments.contains("f32le"))
        let filter = try #require(encode.arguments.first { $0.hasPrefix("asetpts=") })
        #expect(filter.contains(AudioEnhancement.levelledChain))
        #expect(first > 0 && filter.hasPrefix("asetpts=(N+\(first))/SR/TB,"))
        #expect(rawFiles("original").isEmpty, "no original in the isolated kind: \(rawFiles("original"))")
        await pipeline.stop()
    }

    /// In `.levelled` every piece has an original next to it with the same number of samples
    /// (float, so twice the bytes of the 16-bit piece), the segment's levelled input is the
    /// ORIGINAL audio (440 Hz) with a gain, not the isolated voice (880 Hz), and the levelled
    /// file is gone once the encode has returned. Guards against the piece and the original
    /// drifting apart (a gain applied a few ms off), against levelling the isolated voice in the
    /// mode that is meant to keep the original, and against a temporary file left per segment.
    @Test func levelledKindAppliesTheGainToTheOriginal() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg(originalTone: 0.01)
        let pipeline = pipeline(SyntheticWebex(fragments: 5), ffmpeg, FakeIsolator(amplitude: { _ in 0.1 }), kind: .levelled)
        _ = try await pipeline.segment(1)
        // The pieces the pipeline keeps (it may still be making the next one in the background,
        // so the folder's listing is not a stable thing to read).
        var checked = 0
        let folder = parent.appendingPathComponent("session")
        for k in 0..<4 {
            guard let flags = await pipeline.keptPiece(k) else { continue }
            checked += 1
            let suffix = "\(k)" + (flags.hasLead ? "l" : "") + (flags.hasTail ? "t" : "")
            let pieceFile = try #require(rawFiles("piece").first { stem($0) == "piece\(suffix).raw" }, "piece \(suffix) is not on disk")
            let originalFile = try #require(rawFiles("original").first { stem($0) == "original\(suffix).raw" }, "piece \(suffix) has no original")
            let piece = (file: folder.appendingPathComponent(pieceFile), original: folder.appendingPathComponent(originalFile))
            func bytes(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
            #expect(bytes(piece.original) == 2 * bytes(piece.file), "piece \(suffix): \(bytes(piece.file)) bytes, original: \(bytes(piece.original))")
            // The original is the decoded tone with no gap: `AVAudioFile.read` returns a few frames
            // short of what it is asked, and a copy that took that for the end left 11 silent samples
            // in every 65 536 (the sine of the fake has a lone exact zero at most every second).
            let values = try Data(contentsOf: piece.original).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var run = 0, longest = 0
            for value in values { run = value == 0 ? run + 1 : 0; longest = max(longest, run) }
            #expect(longest < 3, "piece \(suffix): \(longest) samples of silence in a row")
        }
        #expect(checked >= 2, "the segment's piece and the next one are kept")
        // Only this segment's own: the pipeline may already be making the next one in the background.
        #expect(!rawFiles("levelled").contains { stem($0) == "levelled1.raw" }, "temporary file left: \(rawFiles("levelled"))")
        let data = try #require(ffmpeg.encode("out1.ts")?.levelled)
        // 100 ms in the middle of the segment, in a clip that starts at the previous fragment's end - 22 s at most.
        let middle = data.count / 4 / 2
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let crossings = (middle..<middle + 4800).filter { samples[$0 - 1] < 0 && samples[$0] >= 0 }.count
        #expect((40...48).contains(crossings), "\(crossings) rising zero crossings in 100 ms: 440 Hz is 44, 880 Hz is 88")
        await pipeline.stop()
    }

    /// The gain of a keypoint, once used by a segment, stays: with the isolated voice 20 dB
    /// louder in fragment 3 than in fragment 2, segment 3 made first (a seek) and segment 2
    /// afterwards, the gain applied to the original is the same 25 ms (11 cycles of the tone, the
    /// gain still ramps by 2 dB a second before the boundary) before and after their
    /// shared boundary (90 s, itself a keypoint). Without the memo segment 2 measures that
    /// keypoint again from its own, quieter fragment and the level steps by about 20 dB at the
    /// join: a jump every time a student seeks and steps back.
    @Test func aSeekLeavesNoStepInTheGainAtTheBoundary() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg(originalTone: 0.002)
        let isolator = FakeIsolator(amplitude: { $0 == 3 || $0 == 4 ? 0.02 : 0.002 })
        let pipeline = pipeline(SyntheticWebex(fragments: 6), ffmpeg, isolator, kind: .levelled)
        _ = try await pipeline.segment(3)
        _ = try await pipeline.segment(2)
        let two = try #require(ffmpeg.encode("out2.ts")), three = try #require(ffmpeg.encode("out3.ts"))
        let seam = 90 * 48000
        let before = Self.rms(try #require(two.levelled), (seam - 1200 - two.firstSample)..<(seam - two.firstSample))
        let after = Self.rms(try #require(three.levelled), (seam - three.firstSample)..<(seam + 1200 - three.firstSample))
        let difference = abs(20 * log10(before / after))
        #expect(difference < 0.05, "\(difference) dB between the two sides of the boundary")
        await pipeline.stop()
    }

    /// A lecture whose first four fragments (2 minutes) are silent for the isolator and whose voice,
    /// quiet, starts at the fifth: the segment with the voice is levelled for it from the first
    /// second (the original at −57 dBFS comes out near −20, +37 dB), and there is no step at its
    /// boundary with the silent segment before it. Guards against the first segment's provisional
    /// 0 dB held through the silence after it, so that the voice's segment starts near 0 dB and
    /// climbs during the first words (before the correction: about +4 dB at that point), and
    /// against a provisional value that changes when the next segment sees the voice.
    @Test func aLongSilenceBeforeTheVoiceLevelsTheFirstSegmentWithVoice() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg(originalTone: 0.002)
        let isolator = FakeIsolator(amplitude: { $0 >= 4 ? 0.002 : 0 })
        let pipeline = pipeline(SyntheticWebex(fragments: 6), ffmpeg, isolator, kind: .levelled)
        for index in 0...4 { _ = try await pipeline.segment(index) }
        let three = try #require(ffmpeg.encode("out3.ts")), four = try #require(ffmpeg.encode("out4.ts"))
        let originalRMS = 0.002 / 2.0.squareRoot()
        func gain(_ encode: FakeFFmpeg.Encode, at second: Double) throws -> Double {
            let sample = Int(second * 48000)
            let rms = Self.rms(try #require(encode.levelled), (sample - 2400 - encode.firstSample)..<(sample + 2400 - encode.firstSample))
            return 20 * log10(rms / originalRMS)
        }
        let seam = 120.0
        let before = try gain(three, at: seam - 0.1), after = try gain(four, at: seam + 0.1)
        #expect(abs(before - after) < 0.3, "\(before) dB before the boundary, \(after) dB after")
        let first = try gain(four, at: seam + 1.0)
        #expect(abs(first - 37) < 1.5, "\(first) dB one second into the voice, expected about +37")
        await pipeline.stop()
    }

    /// A piece replaced (or covered) is deleted with its original; nothing of it is left. Guards
    /// against originals left behind when their piece goes (350 MB for 40 pieces in `.levelled`).
    @Test func aCoveredPieceTakesItsOriginalWithIt() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg(originalTone: 0.01)
        let pipeline = pipeline(SyntheticWebex(fragments: 7), ffmpeg, FakeIsolator(amplitude: { _ in 0.1 }), kind: .levelled)
        _ = try await pipeline.segment(0)
        ffmpeg.gates.hold("decoded6.wav")
        let six = Task { try? await pipeline.segment(6) }
        try await eventually("piece 6 decoding") { ffmpeg.gates.isWaiting("decoded6.wav") }
        _ = try await pipeline.segment(5)
        try await eventually("piece 6 with a lead-in kept") { await pipeline.keptPiece(6).map { $0.hasLead && $0.hasTail } == true }
        ffmpeg.gates.release("decoded6.wav")
        _ = await six.value
        try await eventually("the covered piece and its original deleted") { !pieceFiles.contains("piece6.raw") && !rawFiles("original").contains { stem($0) == "original6.raw" } }
        #expect(rawFiles("original").contains { stem($0) == "original6l.raw" })
        // The files on disk are exactly the pieces and their originals, one for one: no original
        // outlives its piece, and no piece (an isolation cancelled before its piece was stored
        // leaves none, `ff72404`) outlives its original.
        try await eventually("originals and pieces match one for one") {
            Set(rawFiles("original").map { stem($0).replacingOccurrences(of: "original", with: "") })
                == Set(rawFiles("piece").map { stem($0).replacingOccurrences(of: "piece", with: "") })
        }
        await pipeline.stop()
    }

    /// The levelled file is deleted also when the encode fails. Guards against a raw file of
    /// minutes of float audio left per failed segment.
    @Test func aFailedEncodeLeavesNoLevelledFile() async throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let ffmpeg = FakeFFmpeg(failOnce: ["out0.ts"], originalTone: 0.01)
        let pipeline = pipeline(SyntheticWebex(fragments: 3), ffmpeg, FakeIsolator(amplitude: { _ in 0.1 }), kind: .levelled)
        await #expect(throws: (any Error).self) { try await pipeline.segment(0) }
        #expect(ffmpeg.failedAll)
        // The failed segment's own file (the pipeline may be making another one in the background).
        #expect(!rawFiles("levelled").contains { stem($0) == "levelled0.raw" }, "left behind: \(rawFiles("levelled"))")
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
