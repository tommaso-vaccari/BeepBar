import AppKit
import AVFoundation
import BeepbarCore
import Darwin
import OSLog
import os

// Enhanced audio while the lecture plays (`AudioEnhancement`): a local HTTP server that AVPlayer
// plays instead of Webex, and the pipeline behind it that fetches each 30-second segment's bytes,
// filters its audio (Apple's voice isolation between two ffmpeg runs, or ffmpeg alone where the
// Mac lacks it) and serves it as MPEG-TS.
//
// Bounds (principles 3 and 6): one session at a time, alive only while enhanced audio is on for
// the lecture on screen; at most `LoopbackHTTPServer.maximumConnections` connections; segments
// cached only around the one playing (`AudioEnhancement.keptSegments`), a few megabytes each;
// every fetch capped at the segment's own length; every ffmpeg run capped in time.
// Privacy: the server listens on 127.0.0.1 only, and answers only paths carrying the session's
// random token; neither the token nor any Webex address is ever logged.

/// One lecture filtered while it plays: the server and its pipeline, stopped together.
@MainActor final class LiveAudioSession: LiveAudioStreaming {
    let playlistURL: URL
    private let server: LoopbackHTTPServer
    private let pipeline: LiveAudioPipeline
    private var stopped = false

    /// `onFailure`: each failure of a request, and nil when one succeeds after it.
    init(stream: URL, ffmpeg: URL, onFailure: @escaping @MainActor (LiveAudioFailure?) -> Void,
         fetcher: LiveAudioFetching = URLSessionLiveAudioFetcher(), runner: LiveAudioProcessRunning = FFmpegRunner(),
         isolator: LiveAudioVoiceIsolating? = AppleVoiceIsolator.preferred(),
         kind: AudioEnhancementKind = .isolated,
         parent: URL = LiveAudioSession.defaultParent) throws {
        let token = Self.makeToken()
        // A name of its own, not the token: the folder's path is in every ffmpeg's arguments,
        // which other processes can read, and the token is what opens the server.
        let folder = parent.appendingPathComponent(Self.makeToken(), isDirectory: true)
        let pipeline = LiveAudioPipeline(stream: stream, ffmpeg: ffmpeg, folder: folder, parent: parent, fetcher: fetcher, runner: runner,
                                         isolator: isolator, kind: kind, report: { failure in await MainActor.run { onFailure(failure) } })
        let prefix = "/\(token)/"
        server = try LoopbackHTTPServer { path in
            guard path.hasPrefix(prefix) else { return .notFound }
            let name = String(path.dropFirst(prefix.count))
            do {
                if name == AudioEnhancement.playlistName {
                    return .init(status: 200, contentType: "application/vnd.apple.mpegurl", body: try await pipeline.playlist())
                }
                guard let index = AudioEnhancement.segmentIndex(name) else { return .notFound }
                return .init(status: 200, contentType: "video/mp2t", body: try await pipeline.segment(index))
            } catch LiveAudioPipeline.PipelineError.notFound {
                return .notFound
            } catch {
                return .init(status: 502, contentType: "text/plain", body: Data())
            }
        }
        self.pipeline = pipeline
        playlistURL = URL(string: "http://127.0.0.1:\(server.port)\(prefix)\(AudioEnhancement.playlistName)")!
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        server.stop()
        let pipeline = pipeline
        Task.detached { await pipeline.stop() }
    }

    /// Where sessions keep their fragments, one folder each; a new session clears the others'
    /// leftovers here. Tests pass their own: the app isn't sandboxed, so a test run would
    /// otherwise share this folder with the installed app and delete a lecture it is playing.
    nonisolated static var defaultParent: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-LiveAudio", isDirectory: true)
    }

    /// 128 random bits, hex: the secret part of every path.
    nonisolated static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }
}

// MARK: - Fetching

/// Reads bytes of the lecture from Webex: the playlist, or one byte range of its file.
protocol LiveAudioFetching: Sendable {
    /// The whole resource (the playlist) when `range` is nil, else exactly that range. Throws
    /// `LiveAudioFetchError` for an answer that isn't that.
    func fetch(_ url: URL, range: AudioEnhancement.ByteRangeLecture.Span?) async throws -> (data: Data, url: URL)
    /// Cancels what is in flight and releases the fetcher: the session ended.
    func close()
}

enum LiveAudioFetchError: Error, Equatable {
    /// Webex refused the address (expired or gone).
    case refused(Int)
    /// Webex answered 5xx or 429: a passing trouble on its side, not the filter's.
    case unavailableNow(Int)
    /// Any other answer: an unexpected status, a range not honoured, too much data.
    case unexpected
}

/// The real fetcher: an ephemeral session (no cookies or cache written), 30 s per request.
struct URLSessionLiveAudioFetcher: LiveAudioFetching {
    /// A playlist is ~40 KB for 2.5 hours; anything above this is not one.
    static let playlistLimit: Int64 = 4 * 1024 * 1024
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }

    func close() { session.invalidateAndCancel() }

    func fetch(_ url: URL, range: AudioEnhancement.ByteRangeLecture.Span?) async throws -> (data: Data, url: URL) {
        guard url.scheme == "https" else { throw LiveAudioFetchError.unexpected }
        var request = URLRequest(url: url)
        if let range { request.setValue(range.rangeHeader, forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveAudioFetchError.unexpected }
        if [401, 403, 404, 410].contains(http.statusCode) { throw LiveAudioFetchError.refused(http.statusCode) }
        if http.statusCode == 429 || (500...599).contains(http.statusCode) { throw LiveAudioFetchError.unavailableNow(http.statusCode) }
        let limit: Int64
        if let range {
            // A 200 would be the whole 1 GB file: refused before reading any of it.
            guard http.statusCode == 206,
                  let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                  contentRange.hasPrefix("bytes \(range.offset)-\(range.offset + range.length - 1)/") else { throw LiveAudioFetchError.unexpected }
            limit = range.length
        } else {
            guard http.statusCode == 200 else { throw LiveAudioFetchError.unexpected }
            limit = Self.playlistLimit
        }
        if response.expectedContentLength > limit { throw LiveAudioFetchError.unexpected }
        var data = Data()
        data.reserveCapacity(Int(min(limit, 8 * 1024 * 1024)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw LiveAudioFetchError.unexpected }
        }
        if let range, data.count != range.length { throw LiveAudioFetchError.unexpected }
        return (data, response.url ?? url)
    }
}

// MARK: - Running ffmpeg

protocol LiveAudioProcessRunning: Sendable {
    /// Runs `executable` to completion; throws when it exits otherwise than with status 0, and
    /// `CancellationError` when the calling task is cancelled (the process is then killed).
    func run(_ executable: URL, _ arguments: [String]) async throws
}

struct FFmpegExitError: Error {}

/// The real runner: a child process with no stdin, and stdout and stderr discarded (stderr can
/// repeat file paths; only the exit status matters). Killed on cancellation, after
/// `timeLimit`, and when BeepBar quits (`LiveAudioProcesses`).
struct FFmpegRunner: LiveAudioProcessRunning {
    /// A segment takes 0.3–0.7 s on an Apple M5; a minute means ffmpeg is stuck.
    var timeLimit: TimeInterval = 60

    func run(_ executable: URL, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let control = ProcessControl()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    control.finished(finished.processIdentifier)
                    continuation.resume(returning: finished.terminationReason == .exit ? finished.terminationStatus : -1)
                }
                do {
                    try control.launch(process)
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                let limit = timeLimit
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) { control.kill() }
            }
        } onCancel: {
            control.cancel()
        }
        try Task.checkCancellation()
        guard status == 0 else { throw FFmpegExitError() }
    }

    /// Who may signal the process, and when: never before it runs, never after it exited (its
    /// pid could belong to another process by then). Everything under one lock.
    private final class ProcessControl: @unchecked Sendable {
        private struct State {
            var pid: pid_t?
            var cancelled = false
            var exited = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func launch(_ process: Process) throws {
            try state.withLockUnchecked { state in
                if state.cancelled { throw CancellationError() }
                try process.run()
                state.pid = process.processIdentifier
                LiveAudioProcesses.insert(process.processIdentifier)
            }
        }

        func finished(_ pid: pid_t) {
            state.withLock { state in
                state.exited = true
                LiveAudioProcesses.remove(pid)
            }
        }

        func cancel() {
            state.withLock { state in
                state.cancelled = true
                if let pid = state.pid, !state.exited { Darwin.kill(pid, SIGTERM) }
            }
        }

        func kill() {
            state.withLock { state in
                if let pid = state.pid, !state.exited { Darwin.kill(pid, SIGTERM) }
            }
        }
    }
}

/// Every ffmpeg the live sessions are running, so quitting BeepBar ends them: a child process
/// would outlive it. One `willTerminateNotification` observer, installed with the first
/// process, sends each SIGTERM synchronously on the posting thread (queue nil): a syscall per
/// process, no file or main-actor work, nothing added to `applicationShouldTerminate` or to
/// `prepareForMenuQuit` (the hard rules on quitting).
enum LiveAudioProcesses {
    private struct State {
        var pids: Set<pid_t> = []
        var observing = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func insert(_ pid: pid_t) {
        let install = state.withLock { state -> Bool in
            state.pids.insert(pid)
            defer { state.observing = true }
            return !state.observing
        }
        guard install else { return }
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            LiveAudioProcesses.killAll()
        }
    }

    static func remove(_ pid: pid_t) {
        state.withLock { _ = $0.pids.remove(pid) }
    }

    static func killAll() {
        state.withLock { state in
            for pid in state.pids { kill(pid, SIGTERM) }
        }
    }

    static var running: Int { state.withLock { $0.pids.count } }
}

// MARK: - Pipeline

/// Makes the segments of one lecture, on request, from its Webex file.
///
/// For segment `i` it fetches that segment's bytes and the next one's (and keeps the previous
/// one when it was just played), measures where each one's audio starts (`probeArguments`),
/// then makes the segment. Without `isolator`, ffmpeg runs once (`segmentArguments`, whatever
/// the `kind`). With it, the segment is made from isolated pieces (`IsolatedPiece`): each
/// fragment's audio is isolated once, with up to 4 s of the previous fragment before it and
/// 0.5 s of the next after it (`AudioEnhancement.isolationLead`), which makes the pieces join
/// sample-identically to the whole lecture isolated in one go. In `.levelled` the piece also
/// keeps the fragment's original decoded audio (`original`), as float.
///
/// The segment is then levelled (`VoiceLeveler`) and encoded: the last `levelLead` samples of
/// the previous piece, the whole current one and the first `levelTail` of the next make a clip;
/// the gain is *detected* on the isolated voice and *applied* to the isolated voice (`.isolated`)
/// or to the original audio (`.levelled`); the levelled float samples go to a file that
/// ffmpeg encodes with `levelledChain` (`levelledEncodeArguments`). The gains are keypoints
/// every 10 s on the lecture's clock, and `keypointGains` keeps each one the first time a
/// segment uses it: a segment made after a seek, or again, renders the same curve on both
/// sides of its seams as the lecture played from the start would. Before pieces, each segment
/// isolated 60–90 s of audio, so every stretch went through isolation 2–3 times (~850 ms a
/// segment, measured on 2026-11-09 with Webex's 30-second segments).
///
/// Pieces stay on disk, up to `keptPieces`, after the segments around the position are
/// dropped: going back to a part already heard makes the segment again without isolating it.
/// The segment asked for (`urgent`) never waits for a fragment beyond the next: its next piece
/// may then lack its 0.5 s after, which only matters near that piece's end, and that piece is
/// isolated again, complete, when its own segment is made.
///
/// A request also starts the following segment, so it is usually ready before AVPlayer asks.
/// A request far from the last one is a seek: work for the position left behind is cancelled
/// (`keptSegments`).
///
/// Failure: every real failure is reported (`report`, classified by `failure(for:)`) before the
/// request answers with an error, so the controller knows why the player failed when it hears
/// of it. Cancellations are never failures. Work that failed is forgotten (`outputs`,
/// `fragments`, `starts`, `isolating`, `lectureTask`), so AVPlayer's next request tries again
/// instead of getting the same error for the rest of the lecture.
actor LiveAudioPipeline {
    enum PipelineError: Error { case notFound, stopped }

    private let stream: URL
    private let ffmpeg: URL
    private let folder: URL
    private let parent: URL
    private let fetcher: LiveAudioFetching
    private let runner: LiveAudioProcessRunning
    private let isolator: LiveAudioVoiceIsolating?
    private let kind: AudioEnhancementKind
    private let leveler = VoiceLeveler()
    /// A failure, or nil when a request succeeds after one was reported (`reporting`).
    private let report: @Sendable (LiveAudioFailure?) async -> Void

    private var lectureTask: Task<(AudioEnhancement.ByteRangeLecture, URL), Error>?
    private var fragments: [Int: Task<URL, Error>] = [:]
    private var starts: [Int: Task<Double, Error>] = [:]
    private var outputs: [Int: Task<Data, Error>] = [:]
    /// Every isolation underway, by serial, with its fragment and what it was given; and
    /// finished pieces, least recently used first in `piecesUsed`. By serial rather than by
    /// fragment: one asked with other surroundings runs beside the first instead of replacing
    /// its entry, and a replaced entry was work nothing could cancel (`stop`, a seek) or protect
    /// (its lead-in and tail fragments, `keep`), found in review.
    private var isolating: [Int: (k: Int, task: Task<IsolatedPiece, Error>, hasLead: Bool, hasTail: Bool)] = [:]
    private var isolations = 0
    /// Numbers every file a run writes (`runFile`), so a cancelled run still ending never
    /// deletes or overwrites the file of the run that replaced it under the same name.
    private var runs = 0
    /// The segment of the request that arrived last: where the player is. A request whose work
    /// a seek cancelled retries only while its segment is still near it (`segment`).
    private var latestRequest = 0
    private var pieces: [Int: IsolatedPiece] = [:]
    private var piecesUsed: [Int] = []
    /// Pieces replaced or dropped while a segment is being made: deleted once none is
    /// (`retire`). A segment holds the pieces it awaited from the moment they finish, across
    /// several awaits, until its encode ends; deleting one meanwhile made the segment fail
    /// (an encode's ffmpeg reading a deleted piece, seen in testing; and a seek forward then a
    /// step back, found in review). So the count covers the whole of `produceIsolated`.
    private var producing = 0
    private var retired: [URL] = []
    private var stopped = false
    /// The kind of the last failure logged, so a run of the same failure logs once; nil
    /// again once a request succeeds, which is then reported (`reporting`).
    private var lastLogged: LiveAudioFailure?
    /// The session's sticky keypoint memo (`VoiceLeveler`): keypoint index to gain in dB. Invariant:
    /// a keypoint's gain, once used by a segment, never changes for the session, so two segments
    /// that share a keypoint render the same curve on both sides of their seam, whatever audio
    /// each saw and in whatever order they were made (a seek makes segment 3 before 2). Read and
    /// merged in `produceIsolated` with no `await` between, so concurrent segments cannot
    /// interleave. It dies with the session (`stop`). A value that is a provisional `neutral`
    /// (`VoiceLeveler.Resolution`) is kept the same way, and so never changes either, but it is
    /// listed in `provisionalKeypoints` and anchors no other keypoint: the climb to a voice that
    /// follows a long opening silence happens in the silence.
    private var keypointGains: [Int: Double] = [:]
    /// The keypoints of `keypointGains` that are provisional; written and cleared with it.
    private var provisionalKeypoints: Set<Int> = []

    init(stream: URL, ffmpeg: URL, folder: URL, parent: URL, fetcher: LiveAudioFetching, runner: LiveAudioProcessRunning,
         isolator: LiveAudioVoiceIsolating? = nil, kind: AudioEnhancementKind = .isolated,
         report: @escaping @Sendable (LiveAudioFailure?) async -> Void) {
        self.stream = stream
        self.ffmpeg = ffmpeg
        self.folder = folder
        self.parent = parent
        self.fetcher = fetcher
        self.runner = runner
        self.isolator = isolator
        self.kind = kind
        self.report = report
    }

    func playlist() async throws -> Data {
        try await reporting {
            let (lecture, _) = try await self.lecture()
            return Data(AudioEnhancement.proxyPlaylist(lecture).utf8)
        }
    }

    func segment(_ index: Int) async throws -> Data {
        // On arrival, before any await: a request that waited on the playlist must not take
        // the place of one that arrived after it.
        latestRequest = index
        return try await reporting {
            let (lecture, _) = try await self.lecture()
            guard lecture.segments.indices.contains(index) else { throw PipelineError.notFound }
            self.keep(around: index)
            // Retried when the work it waited on was cancelled by an earlier request's seek
            // logic rather than by this request, and once when it failed but was started before
            // this request (made ahead, or for an earlier request): its error may be a Wi-Fi drop
            // long over, which would answer AVPlayer with a stale 502 (found in review).
            // A cancellation is retried only while this segment is still near the latest
            // request: otherwise the player has seeked away and dropped this request (the local
            // server can't tell, it never sees the connection close), and retrying rebuilt the
            // segment, the next one and their isolations after every seek, competing with the
            // segment the student waits for (found in testing).
            var retriedEarlierWork = false
            for _ in 0..<3 {
                let earlier = self.outputs[index] != nil
                let task = self.output(index, count: lecture.segments.count, urgent: true)
                if index + 1 < lecture.segments.count { _ = self.output(index + 1, count: lecture.segments.count, urgent: false) }
                do {
                    return try await task.value
                } catch let error where Self.isCancellation(error) {
                    try self.checkRunning()
                    if self.outputs[index] == task { self.outputs[index] = nil }
                    // The cancellation itself, which `reporting` doesn't report.
                    guard AudioEnhancement.keptSegments(around: self.latestRequest).contains(index) else { throw error }
                } catch {
                    // Not kept: AVPlayer asks again, and that request makes the segment anew.
                    if self.outputs[index] == task { self.outputs[index] = nil }
                    guard earlier, !retriedEarlierWork else { throw error }
                    retriedEarlierWork = true
                }
            }
            throw CancellationError()
        }
    }

    /// Ends everything and deletes the session's files.
    func stop() {
        stopped = true
        lectureTask?.cancel()
        for task in fragments.values { task.cancel() }
        for task in starts.values { task.cancel() }
        for task in outputs.values { task.cancel() }
        for entry in isolating.values { entry.task.cancel() }
        fragments = [:]
        starts = [:]
        outputs = [:]
        isolating = [:]
        pieces = [:]
        keypointGains = [:]
        provisionalKeypoints = []
        fetcher.close()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Steps

    /// The lecture's layout and its init section's file, fetched once (again after a failure).
    private func lecture() async throws -> (AudioEnhancement.ByteRangeLecture, URL) {
        try checkRunning()
        let task: Task<(AudioEnhancement.ByteRangeLecture, URL), Error>
        if let lectureTask {
            task = lectureTask
        } else {
            task = Task { () throws -> (AudioEnhancement.ByteRangeLecture, URL) in
                let (data, url) = try await self.fetcher.fetch(self.stream, range: nil)
                guard let text = String(data: data, encoding: .utf8),
                      let lecture = AudioEnhancement.byteRangeLecture(playlist: text, at: url) else { throw LiveAudioFetchError.unexpected }
                try self.prepareFolder()
                let (bytes, _) = try await self.fetcher.fetch(lecture.file, range: lecture.initSection)
                let file = self.folder.appendingPathComponent("init.mp4")
                try bytes.write(to: file)
                return (lecture, file)
            }
            lectureTask = task
        }
        do {
            return try await task.value
        } catch {
            if lectureTask == task { lectureTask = nil }
            throw error
        }
    }

    /// A fresh, private folder for this session; earlier sessions' leftovers (a crash) go.
    private func prepareFolder() throws {
        let manager = FileManager.default
        if let leftovers = try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            for url in leftovers where url.lastPathComponent != folder.lastPathComponent { try? manager.removeItem(at: url) }
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A path with `|` would split ffmpeg's `concat:` input.
        if folder.path.contains("|") { throw LiveAudioFetchError.unexpected }
    }

    /// `urgent`: the segment AVPlayer asked for, rather than the one made ahead of it.
    private func output(_ index: Int, count: Int, urgent: Bool) -> Task<Data, Error> {
        if let existing = outputs[index] { return existing }
        // The previous segment counts when it is fetched or being made: then its bytes are (or
        // will be) here anyway.
        let hasPrevious = fragments[index - 1] != nil || outputs[index - 1] != nil
        let task = Task { try await self.produce(index, count: count, hasPrevious: hasPrevious, urgent: urgent) }
        outputs[index] = task
        return task
    }

    private func produce(_ index: Int, count: Int, hasPrevious: Bool, urgent: Bool) async throws -> Data {
        let (lecture, initFile) = try await lecture()
        if isolator != nil { return try await produceIsolated(index, count: count, urgent: urgent, in: lecture, initFile: initFile) }
        let context = AudioEnhancement.audioContext(for: index, count: count, hasPrevious: hasPrevious)
        // All fetches start before any is awaited, so they run side by side.
        for k in context { _ = fragment(k, in: lecture) }
        var files: [Int: URL] = [:]
        for k in context { files[k] = try await fragmentFile(k, in: lecture) }
        let (start, end) = try await span(index, count: count, in: lecture, initFile: initFile)
        let output = runFile("out\(index)", "ts")
        let video = AudioEnhancement.concatInput([initFile.path, files[index]!.path])
        let audio = AudioEnhancement.concatInput([initFile.path] + context.map { files[$0]!.path })
        try await runner.run(ffmpeg, AudioEnhancement.segmentArguments(video: video, audio: audio, start: start, end: end, output: output.path))
        return try finish(output)
    }

    /// A segment from isolated pieces: its own (complete), the next one's (complete unless
    /// `urgent`), the previous one's when it is on disk already; never isolation of its own.
    private func produceIsolated(_ index: Int, count: Int, urgent: Bool, in lecture: AudioEnhancement.ByteRangeLecture, initFile: URL) async throws -> Data {
        // Before any await: from here until the encode ends, no piece is deleted (`retire`).
        producing += 1
        defer { producing -= 1; retire() }
        // This fragment is fetched now, so the next piece gets its lead-in from it (`piece`).
        _ = fragment(index, in: lecture)
        // Both isolations start before either is awaited, so they run side by side.
        let own = piece(index, count: count, tail: true, in: lecture, initFile: initFile)
        let next = index + 1 < count ? piece(index + 1, count: count, tail: !urgent, in: lecture, initFile: initFile) : nil
        let made = try await own.value
        let madeNext = try await next?.value
        let (start, end) = try await span(index, count: count, in: lecture, initFile: initFile)
        let output = runFile("out\(index)", "ts")
        let video = AudioEnhancement.concatInput([initFile.path, try await fragmentFile(index, in: lecture).path])
        // A piece made with at least as much around it may have replaced the one awaited
        // meanwhile (`store`): the better one is used. Either stays on disk until this segment
        // is made (`producing`).
        let current = kept(made)
        let following = madeNext.map(kept)
        // The previous piece ends where this one starts unless a sample or so of rounding
        // (`isolate`); one further off would move this segment's voice, so it is left out.
        let previous = pieces[index - 1].flatMap { abs($0.end - current.start) <= 2 ? $0 : nil }
        let used = [previous, current, following].compactMap { $0 }
        // Only `stop` removes a piece under a segment being made: its folder is gone.
        guard used.allSatisfy({ FileManager.default.fileExists(atPath: $0.file.path) && ($0.original.map { FileManager.default.fileExists(atPath: $0.path) } ?? true) })
        else { throw PipelineError.stopped }
        for piece in used { touch(piece.index) }
        // Detector (the isolated voice) and signal (what is heard) clips, read off the actor. In
        // `.isolated` they are the same samples, not copied.
        let (detector, heard) = try await Self.loadClips(previous: previous, current: current, following: following, levelled: kind == .levelled)
        try Task.checkCancellation()
        let signal = heard ?? detector
        // No `await` from here to the end of the merge: the memo is read and written in one
        // turn, so a segment made at the same time cannot decide a shared keypoint differently.
        let wanted = leveler.keypoints(covering: AudioEnhancement.samplePosition(start)..<AudioEnhancement.samplePosition(end))
        let resolution = leveler.resolve(for: wanted, detector: detector, known: keypointGains, provisional: provisionalKeypoints)
        let resolved = resolution.gains
        for (k, gain) in resolved where keypointGains[k] == nil {
            keypointGains[k] = gain
            if resolution.provisional.contains(k) { provisionalKeypoints.insert(k) }
        }
        // What `level` is handed: the keypoints this segment resolved, and every one already
        // used inside the clip, so its pre-roll gets the gains it was rendered with.
        var handed = resolved
        let step = Double(VoiceLeveler.rate) * leveler.spacing
        for (k, gain) in keypointGains where handed[k] == nil {
            let t = Int((Double(k) * step).rounded())
            if t >= detector.start && t <= detector.end { handed[k] = gain }
        }
        let levelled = runFile("levelled\(index)", "raw")
        defer { try? FileManager.default.removeItem(at: levelled) }
        try await Self.writeLevelled(leveler: leveler, signal: signal, gains: handed, to: levelled)
        try Task.checkCancellation()
        try await runner.run(ffmpeg, AudioEnhancement.levelledEncodeArguments(video: video, levelled: levelled.path, firstSample: detector.start,
                                                                              start: start, end: end, output: output.path))
        return try finish(output)
    }

    /// The piece to use in place of `made`: the one `pieces` keeps for that fragment when it
    /// has everything `made` has (`covers`), else `made`.
    private func kept(_ made: IsolatedPiece) -> IsolatedPiece {
        guard let kept = pieces[made.index], kept.covers(made) else { return made }
        return kept
    }

    /// Where segment `index`'s audio starts and ends on the lecture's clock.
    private func span(_ index: Int, count: Int, in lecture: AudioEnhancement.ByteRangeLecture, initFile: URL) async throws -> (Double, Double) {
        let start = try await audioStart(index, in: lecture, initFile: initFile)
        let nextStart = index + 1 < count ? try await audioStart(index + 1, in: lecture, initFile: initFile) : nil
        return (start, AudioEnhancement.audioEnd(index: index, start: start, nextStart: nextStart, lecture: lecture))
    }

    /// A file in the session's folder for one run: `name-<run>.ext`. Names stay readable in a
    /// failure (`out6`, `decoded6l`, `piece6t`), the number keeps runs apart.
    private func runFile(_ name: String, _ ext: String) -> URL {
        runs += 1
        return folder.appendingPathComponent("\(name)-\(runs).\(ext)")
    }

    private func finish(_ output: URL) throws -> Data {
        try Task.checkCancellation()
        let data = try Data(contentsOf: output)
        try? FileManager.default.removeItem(at: output)
        return data
    }

    // MARK: Isolated pieces

    /// Fragment `k`'s isolated voice, on disk: raw 16-bit mono 48 kHz samples from `start` on
    /// the lecture's clock to `end`, the next fragment's start (or the lecture's end).
    /// `hasLead`: isolated with the previous fragment's last 4 s before it; `hasTail`: with the
    /// next fragment's first 0.5 s after it (or none exists). Without either, the piece differs
    /// from the whole lecture's isolation near that edge (`AudioEnhancement.isolationLead`).
    /// `original`: in `.levelled`, the same span `[start, end)` of the fragment's decoded audio,
    /// before isolation, as raw 32-bit float mono 48 kHz with exactly as many samples as `file`
    /// (float on purpose: a lecture at −60 dBFS keeps about 7 bits in 16-bit); nil otherwise.
    /// Everything that deletes `file` deletes `original` (`retire`).
    struct IsolatedPiece: Sendable {
        let index: Int
        let file: URL
        let original: URL?
        let start: Int
        let end: Int
        let hasLead: Bool
        let hasTail: Bool

        /// Whether this piece has everything `other` has around it: then it can stand in for
        /// `other`. The one relation `store` and `kept` share; when they disagreed, `store`
        /// deleted a piece `kept` then chose (a seek forward then a step back failed the
        /// segment for good, found in review).
        func covers(_ other: IsolatedPiece) -> Bool { (hasLead || !other.hasLead) && (hasTail || !other.hasTail) }
    }

    /// How many pieces stay on disk: 20 minutes of Webex's 30-second fragments, about 115 MB
    /// isolated (2.9 MB each) and about 350 MB in `.levelled` (2.9 MB plus 5.8 MB of original
    /// audio each), in the session's folder, which goes when the player closes.
    static let keptPieces = 40

    /// Fragment `k`'s piece: on disk, underway, or started now. With a lead-in whenever the
    /// previous fragment is fetched or being fetched already (a seek doesn't fetch it just for
    /// this), and with what follows it when `tail` asks (fetching the next fragment). A piece
    /// made with less than is now wanted isn't used: it is isolated again.
    private func piece(_ k: Int, count: Int, tail: Bool, in lecture: AudioEnhancement.ByteRangeLecture, initFile: URL) -> Task<IsolatedPiece, Error> {
        let lead = k > 0 && fragments[k - 1] != nil
        let tail = tail && k + 1 < count
        func serves(_ hasLead: Bool, _ hasTail: Bool) -> Bool { (hasLead || !lead) && (hasTail || !tail) }
        if let done = pieces[k], serves(done.hasLead, done.hasTail) { return Task { done } }
        if let underway = isolating.values.first(where: { $0.k == k && serves($0.hasLead, $0.hasTail) }) { return underway.task }
        isolations += 1
        let serial = isolations
        let task = Task { () throws -> IsolatedPiece in
            do {
                return try await self.isolate(k, count: count, lead: lead, tail: tail, serial: serial, in: lecture, initFile: initFile)
            } catch {
                // Not kept underway: the next request for this piece isolates it anew.
                self.isolating[serial] = nil
                throw error
            }
        }
        isolating[serial] = (k, task, lead, tail)
        return task
    }

    private func isolate(_ k: Int, count: Int, lead: Bool, tail: Bool, serial: Int, in lecture: AudioEnhancement.ByteRangeLecture, initFile: URL) async throws -> IsolatedPiece {
        guard let isolator else { throw PipelineError.stopped }
        let first = lead ? k - 1 : k
        let last = tail ? k + 1 : k
        for j in first...last { _ = fragment(j, in: lecture) }
        var files: [URL] = []
        for j in first...last { files.append(try await fragmentFile(j, in: lecture)) }
        // The decoded audio starts where its first fragment's does; the WAV keeps no
        // timestamps, so these positions are what put the isolated voice back on the clock.
        let firstSample = AudioEnhancement.samplePosition(try await audioStart(first, in: lecture, initFile: initFile))
        let start = AudioEnhancement.samplePosition(try await audioStart(k, in: lecture, initFile: initFile))
        let from = max(firstSample, start - (lead ? AudioEnhancement.isolationLead : 0))
        // With a tail the piece ends exactly where the next fragment starts. Without, at the end
        // of this fragment's own audio: the same sample, give or take one of resampling, and
        // the next fragment isn't fetched just to know it.
        let next = tail ? AudioEnhancement.samplePosition(try await audioStart(k + 1, in: lecture, initFile: initFile)) : nil
        let flags = (lead ? "l" : "") + (tail ? "t" : "")
        let decoded = runFile("decoded\(k)\(flags)", "wav")
        let file = runFile("piece\(k)\(flags)", "raw")
        defer { try? FileManager.default.removeItem(at: decoded) }
        try await runner.run(ffmpeg, AudioEnhancement.isolationDecodeArguments(audio: AudioEnhancement.concatInput([initFile.path] + files.map(\.path)),
                                                                               firstSample: firstSample, from: from,
                                                                               to: next.map { $0 + AudioEnhancement.isolationTail }, output: decoded.path))
        try Task.checkCancellation()
        // From here until `store` takes the piece over, a throw (the isolator failing or cancelled
        // mid-write, a cancellation right after it, a failing `writeOriginal`) must not leave the
        // file behind: nothing else knows about it. Safe by construction: `runFile` names are
        // unique per run, so this can only ever delete this run's own file, never another's.
        var stored = false
        defer { if !stored { try? FileManager.default.removeItem(at: file) } }
        try await isolator.isolate(decoded, from: start - from, count: next.map { $0 - start }, to: file)
        try Task.checkCancellation()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        // The fragment's own span of the decoded audio, as float, before the WAV goes. As many
        // samples as the isolated piece, padded or cut, so the two files line up by position.
        var original: URL?
        if kind == .levelled {
            let url = runFile("original\(k)\(flags)", "raw")
            do {
                try await Self.writeOriginal(from: decoded, offset: start - from, count: bytes / 2, to: url)
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            original = url
        }
        let piece = IsolatedPiece(index: k, file: file, original: original, start: start, end: start + bytes / 2, hasLead: lead, hasTail: tail || k + 1 == count)
        isolating[serial] = nil
        stored = true
        store(piece)
        return piece
    }

    /// Keeps `piece` unless the one on disk has everything it has (`covers`), which callers
    /// then use instead (`kept`); drops the least recently used pieces beyond `keptPieces`.
    /// Pieces made with different surroundings, neither covering the other, keep the newest.
    private func store(_ piece: IsolatedPiece) {
        if stopped { return }
        if let kept = pieces[piece.index], kept.covers(piece) {
            retire(piece)
            touch(piece.index)
            return
        }
        if let replaced = pieces[piece.index], replaced.file != piece.file { retire(replaced) }
        pieces[piece.index] = piece
        touch(piece.index)
        while pieces.count > Self.keptPieces, let oldest = piecesUsed.first {
            piecesUsed.removeFirst()
            if let dropped = pieces.removeValue(forKey: oldest) { retire(dropped) }
        }
    }

    /// Sets `piece`'s files aside (`retire()`): both of them, or the original audio would stay
    /// on disk, 5.8 MB a piece, until the player closes.
    private func retire(_ piece: IsolatedPiece) {
        retired.append(piece.file)
        if let original = piece.original { retired.append(original) }
        retire()
    }

    /// Deletes the files set aside, as soon as no segment is being made.
    private func retire() {
        guard producing == 0 else { return }
        for file in retired { try? FileManager.default.removeItem(at: file) }
        retired = []
    }

    // MARK: Levelling helpers

    /// The detector clip (the isolated voice) and, in `.levelled`, the signal clip (the original
    /// audio) for one segment: the last `levelLead` samples of `previous`, all of `current` and
    /// the first `levelTail` of `following`, as floats, positioned on the lecture's clock from
    /// `current`'s start (the previous piece ends within a sample or two of it, `produceIsolated`).
    /// Nonisolated and async: the reading and converting of a minute of audio runs on the
    /// shared pool, not on the actor that serves seeks.
    private nonisolated static func loadClips(previous: IsolatedPiece?, current: IsolatedPiece, following: IsolatedPiece?,
                                              levelled: Bool) async throws -> (detector: VoiceLeveler.Clip, signal: VoiceLeveler.Clip?) {
        let before = previous.map { min(AudioEnhancement.levelLead, $0.end - $0.start) } ?? 0
        let after = following.map { min(AudioEnhancement.levelTail, $0.end - $0.start) } ?? 0
        var parts: [(piece: IsolatedPiece, skip: Int, take: Int)] = []
        if let previous { parts.append((previous, previous.end - previous.start - before, before)) }
        parts.append((current, 0, current.end - current.start))
        if let following { parts.append((following, 0, after)) }
        func read(_ file: (IsolatedPiece) -> URL?, float: Bool) throws -> VoiceLeveler.Clip {
            var samples: [Float] = []
            samples.reserveCapacity(before + (current.end - current.start) + after)
            for part in parts {
                try Task.checkCancellation()
                guard let url = file(part.piece) else { throw PipelineError.stopped }
                samples += try readRaw(url, float: float, skip: part.skip, take: part.take)
            }
            return VoiceLeveler.Clip(samples: samples, start: current.start - before)
        }
        let detector = try read({ $0.file }, float: false)
        guard levelled else { return (detector, nil) }
        return (detector, try read({ $0.original }, float: true))
    }

    /// `take` samples of a raw mono file after `skip` samples, as floats: 16-bit (÷ 32768) or
    /// 32-bit float. A file shorter than asked is padded with silence, so positions never shift.
    private nonisolated static func readRaw(_ url: URL, float: Bool, skip: Int, take: Int) throws -> [Float] {
        let width = float ? 4 : 2
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(skip * width))
        let data = try handle.read(upToCount: take * width) ?? Data()
        var samples = [Float](repeating: 0, count: take)
        let available = min(take, data.count / width)
        // `while` loops on purpose: a segment converts millions of samples here and a `for` over a
        // range costs ten times as much in a debug build, where the pipeline tests run.
        data.withUnsafeBytes { raw in
            samples.withUnsafeMutableBufferPointer { out in
                var i = 0
                if float {
                    while i < available { out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: Float.self); i += 1 }
                } else {
                    while i < available { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768; i += 1 }
                }
            }
        }
        return samples
    }

    /// Writes `count` samples of the decoded WAV from sample `offset` as raw float mono (what
    /// `original` is), padding with silence or cutting so it has exactly `count`. In blocks:
    /// memory does not depend on the fragment's length. Throws `CancellationError`.
    private nonisolated static func writeOriginal(from decoded: URL, offset: Int, count: Int, to output: URL) async throws {
        let source = try AVAudioFile(forReading: decoded)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw LiveAudioFetchError.unexpected }
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        let block = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(block)) else { throw LiveAudioFetchError.unexpected }
        var done = 0
        while done < count {
            try Task.checkCancellation()
            let wanted = min(block, count - done)
            let position = offset + done
            var samples = [Float](repeating: 0, count: wanted)
            // `read` may return fewer frames than asked without being at the end (AVAudioFile gives
            // 65 525 of 65 536 on a float WAV, 11 samples short every block): read on until the
            // block is full or the file ends, or each block would carry a gap of silence in the
            // original that the gain then multiplies, a click every 1.4 s of a fragment's audio.
            if position >= 0, position < Int(source.length) {
                source.framePosition = AVAudioFramePosition(position)
                var got = 0
                while got < wanted {
                    try Task.checkCancellation()
                    // `read` at the end of the file throws (eofErr, -39) instead of returning no
                    // frames, so never ask for more than is left: a decode shorter than
                    // `offset + count` (the last fragment) is padded with silence, not failed.
                    let left = Int(source.length - source.framePosition)
                    guard left > 0 else { break }
                    try source.read(into: buffer, frameCount: AVAudioFrameCount(min(wanted - got, left)))
                    let frames = Int(buffer.frameLength)
                    guard frames > 0 else { break }
                    if let channel = buffer.floatChannelData?[0] {
                        for i in 0..<frames { samples[got + i] = channel[i] }
                    }
                    got += frames
                }
            }
            try destination.write(contentsOf: samples.withUnsafeBytes { Data($0) })
            done += wanted
        }
    }

    /// `leveler.level` over `signal` with `gains`, written as raw float to `output`. Nonisolated
    /// and async: a minute of audio is a few million samples, never on the actor.
    private nonisolated static func writeLevelled(leveler: VoiceLeveler, signal: VoiceLeveler.Clip, gains: [Int: Double], to output: URL) async throws {
        let levelled = leveler.level(signal, gains: gains)
        try Task.checkCancellation()
        try levelled.withUnsafeBytes { try Data($0).write(to: output) }
    }

    /// What fragment `k`'s kept piece was made with, nil when none is kept: for tests, which
    /// can't tell from the files when `store` has run.
    func keptPiece(_ k: Int) -> (hasLead: Bool, hasTail: Bool)? { pieces[k].map { ($0.hasLead, $0.hasTail) } }
    /// `latestRequest`, for tests, which can't tell otherwise when a request has arrived.
    func lastRequested() -> Int { latestRequest }

    private func touch(_ k: Int) {
        piecesUsed.removeAll { $0 == k }
        if pieces[k] != nil { piecesUsed.append(k) }
    }

    private func fragment(_ k: Int, in lecture: AudioEnhancement.ByteRangeLecture) -> Task<URL, Error> {
        if let existing = fragments[k] { return existing }
        let span = lecture.segments[k].span
        let file = folder.appendingPathComponent("frag\(k).m4s")
        let task = Task { () throws -> URL in
            let (data, _) = try await self.fetcher.fetch(lecture.file, range: span)
            try Task.checkCancellation()
            // Atomic: a cancelled fetch ending late may write the same fragment again under a
            // run reading it, which then keeps the file it opened.
            try data.write(to: file, options: .atomic)
            return file
        }
        fragments[k] = task
        return task
    }

    /// Where fragment `k`'s audio starts, probed once (again after a failure).
    private func audioStart(_ k: Int, in lecture: AudioEnhancement.ByteRangeLecture, initFile: URL) async throws -> Double {
        let task: Task<Double, Error>
        if let existing = starts[k] {
            task = existing
        } else {
            let probe = runFile("probe\(k)", "txt")
            task = Task { () throws -> Double in
                let file = try await self.fragmentFile(k, in: lecture)
                try await self.runner.run(self.ffmpeg, AudioEnhancement.probeArguments(input: AudioEnhancement.concatInput([initFile.path, file.path]), output: probe.path))
                defer { try? FileManager.default.removeItem(at: probe) }
                guard let text = try? String(contentsOf: probe, encoding: .utf8),
                      let seconds = AudioEnhancement.firstPacketSeconds(framecrc: text) else { throw FFmpegExitError() }
                return seconds
            }
            starts[k] = task
        }
        do {
            return try await task.value
        } catch {
            if starts[k] == task { starts[k] = nil }
            throw error
        }
    }

    /// A fragment's file, fetching it again once if its earlier fetch was cancelled by a seek.
    private func fragmentFile(_ k: Int, in lecture: AudioEnhancement.ByteRangeLecture) async throws -> URL {
        for _ in 0..<2 {
            let task = fragment(k, in: lecture)
            do {
                return try await task.value
            } catch let error where Self.isCancellation(error) {
                try Task.checkCancellation()
                try checkRunning()
                if fragments[k] == task { fragments[k] = nil }
            } catch {
                // Not kept: the next request fetches it again.
                if fragments[k] == task { fragments[k] = nil }
                throw error
            }
        }
        throw CancellationError()
    }

    /// Cancels and forgets work outside the segments around `index`.
    private func keep(around index: Int) {
        let kept = AudioEnhancement.keptSegments(around: index)
        // One more fragment ahead than outputs: the last kept output reads the one after it.
        let around = kept.lowerBound...(kept.upperBound + 1)
        for (k, task) in outputs where !kept.contains(k) { task.cancel(); outputs[k] = nil }
        // Finished pieces stay (`keptPieces`); isolations for the position left behind stop.
        for (serial, entry) in isolating where !around.contains(entry.k) { entry.task.cancel(); isolating[serial] = nil }
        // The work that stays also reads its neighbours: a segment its previous fragment
        // (without pieces, `audioContext`) and its next, an isolation its lead and tail.
        // Deleting one of those under it failed its ffmpeg, which looked like the filter
        // failing and turned enhanced audio off (found in review).
        var keptFragments = Set(around)
        for k in outputs.keys { keptFragments.formUnion([k - 1, k + 1]) }
        for entry in isolating.values {
            if entry.hasLead { keptFragments.insert(entry.k - 1) }
            if entry.hasTail { keptFragments.insert(entry.k + 1) }
        }
        for (k, task) in starts where !keptFragments.contains(k) { task.cancel(); starts[k] = nil }
        for (k, task) in fragments where !keptFragments.contains(k) {
            task.cancel()
            fragments[k] = nil
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("frag\(k).m4s"))
        }
    }

    private func checkRunning() throws {
        if stopped { throw PipelineError.stopped }
    }

    /// Runs `body`, reporting a real failure before rethrowing it. Each one is reported (the
    /// controller keeps what decides, `AudioEnhancer.reportedFailure`); a run of the same kind
    /// is logged once. The first success after a failure reports nil: the failure has passed,
    /// and a later one the pipeline never saw must not be read as it (a healed Wi-Fi drop made
    /// a later fault of the filter look like a network error, found in review). Only then, so a
    /// lecture playing normally costs no main-actor hop per segment.
    private func reporting<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            if lastLogged != nil {
                lastLogged = nil
                await report(nil)
            }
            return value
        } catch {
            if stopped || Self.isCancellation(error) { throw error }
            if case PipelineError.notFound = error { throw error }
            let failure = Self.failure(for: error)
            if failure != lastLogged {
                lastLogged = failure
                Logger(subsystem: "io.github.tvaccari.beepbar", category: "AudioEnhancer")
                    .error("Enhanced audio failed kind=\(String(describing: failure), privacy: .public)")
            }
            await report(failure)
            throw error
        }
    }

    /// What a failure means for the lecture: Webex refusing its address (expired), Webex or
    /// the connection failing for now (a `URLError`, a 5xx or 429), or the filter's own
    /// failure (anything else: the layout, ffmpeg, the disk). Only the last turns enhanced
    /// audio off; the others go to the usual recovery, as without the filter.
    nonisolated static func failure(for error: Error) -> LiveAudioFailure {
        switch error {
        case LiveAudioFetchError.refused: return .streamRefused
        case LiveAudioFetchError.unavailableNow: return .network
        case is URLError: return .network
        default: return .unavailable
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }
}

// MARK: - Server

/// A minimal HTTP/1.1 server on 127.0.0.1 and a port the system picks, for AVPlayer only: GET
/// and HEAD, a single `Range` answered from the finished body, `Connection: close`.
///
/// BSD sockets rather than `NWListener`, because the port is known as soon as `init` returns:
/// the player gets its address in the same main-actor turn the switch was pressed, with no
/// wait for a listener to become ready.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        static let notFound = Response(status: 404, contentType: "text/plain", body: Data())
    }
    typealias Handler = @Sendable (_ path: String) async -> Response

    /// AVPlayer opens a handful; more means something else is knocking.
    static let maximumConnections = 8
    /// A request line and headers; AVPlayer's are well under 2 KB.
    static let maximumRequestBytes = 16 * 1024

    let port: UInt16
    private let listener: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "io.github.tvaccari.beepbar.live-audio", attributes: .concurrent)
    private let handler: Handler
    private struct State {
        var connections: Set<Int32> = []
        var stopped = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && listen(fd, 16) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        port = UInt16(bigEndian: address.sin_port)
        listener = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { stop() }

    /// Stops listening and ends every open connection. Idempotent.
    func stop() {
        let stopping = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.stopped = true
            // Unblocks their reads and writes; each connection closes its own descriptor. Under
            // the lock `finish` closes them under: a descriptor read here and shut down after
            // releasing it could by then be closed and reused by another socket of the app.
            for fd in state.connections { shutdown(fd, SHUT_RDWR) }
            return true
        }
        guard stopping else { return }
        source.cancel()
    }

    private func acceptPending() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // On macOS an accepted socket inherits the listener's O_NONBLOCK: without clearing it
            // the first `recv` fails with EAGAIN and every request is dropped unanswered. The
            // connection is served blocking, bounded by the timeouts below.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var receive = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))
            var send = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
            let admitted = state.withLock { state -> Bool in
                guard !state.stopped, state.connections.count < Self.maximumConnections else { return false }
                state.connections.insert(fd)
                return true
            }
            guard admitted else {
                close(fd)
                continue
            }
            queue.async { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        guard let request = readRequest(fd) else { return finish(fd) }
        let handler = handler
        Task.detached { [weak self] in
            let response: Response = request.method == "GET" || request.method == "HEAD" ? await handler(request.path) : Response(status: 405, contentType: "text/plain", body: Data())
            self?.queue.async { [weak self] in
                guard let self else {
                    close(fd)
                    return
                }
                self.write(response, for: request, to: fd)
                self.finish(fd)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let range: String?
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let end = Data("\r\n\r\n".utf8)
        while data.range(of: end) == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            if data.count > Self.maximumRequestBytes { return nil }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3 else { return nil }
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
        return Request(method: String(parts[0]), path: path, range: range)
    }

    private func write(_ response: Response, for request: Request, to fd: Int32) {
        var status = response.status
        var body = response.body
        var extra = ""
        if status == 200, let range = request.range, let slice = Self.byteRange(range, length: body.count) {
            status = 206
            extra = "Content-Range: bytes \(slice.lowerBound)-\(slice.upperBound)/\(body.count)\r\n"
            body = body.subdata(in: slice.lowerBound..<(slice.upperBound + 1))
        }
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(body.count)\r\n\(extra)Accept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        guard send(Data(head.utf8), to: fd), request.method != "HEAD" else { return }
        _ = send(body, to: fd)
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n` against `length`, as a closed range of offsets, or
    /// nil (anything else is answered with the whole body).
    static func byteRange(_ header: String, length: Int) -> ClosedRange<Int>? {
        guard length > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty {
            guard let suffix = Int(spec[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)...(length - 1)
        }
        guard let start = Int(spec[0]), start >= 0, start < length else { return nil }
        let end = spec[1].isEmpty ? length - 1 : Int(spec[1]).map { min($0, length - 1) }
        guard let end, end >= start else { return nil }
        return start...end
    }

    private func send(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base + sent, raw.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private func finish(_ fd: Int32) {
        state.withLock { state in
            state.connections.remove(fd)
            close(fd)
        }
    }
}
