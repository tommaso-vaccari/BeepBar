import AppKit
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

    init(stream: URL, ffmpeg: URL, onFailure: @escaping @MainActor (LiveAudioFailure) -> Void,
         fetcher: LiveAudioFetching = URLSessionLiveAudioFetcher(), runner: LiveAudioProcessRunning = FFmpegRunner(),
         isolator: LiveAudioVoiceIsolating? = AppleVoiceIsolator.preferred(),
         parent: URL = LiveAudioSession.defaultParent) throws {
        let token = Self.makeToken()
        let folder = parent.appendingPathComponent(token, isDirectory: true)
        let pipeline = LiveAudioPipeline(stream: stream, ffmpeg: ffmpeg, folder: folder, parent: parent, fetcher: fetcher, runner: runner,
                                         isolator: isolator, report: { failure in await MainActor.run { onFailure(failure) } })
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
    /// A segment takes 0.3–0.7 s on an M2; a minute means ffmpeg is stuck.
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
/// then makes the segment: with `isolator`, ffmpeg decodes the audio context to a WAV
/// (`isolationDecodeArguments`), the isolator cleans it, and ffmpeg encodes the segment from it
/// (`isolatedEncodeArguments`); without, ffmpeg runs once (`segmentArguments`). A request also starts the following segment, so
/// it is usually ready before AVPlayer asks. A request far from the last one is a seek: work
/// for the position left behind is cancelled (`keptSegments`).
///
/// Failure: the first real failure is reported (`report`) before the request answers with an
/// error, so the controller knows why the player failed when it hears of it. Cancellations are
/// never failures.
actor LiveAudioPipeline {
    enum PipelineError: Error { case notFound, stopped }

    private let stream: URL
    private let ffmpeg: URL
    private let folder: URL
    private let parent: URL
    private let fetcher: LiveAudioFetching
    private let runner: LiveAudioProcessRunning
    private let isolator: LiveAudioVoiceIsolating?
    private let report: @Sendable (LiveAudioFailure) async -> Void

    private var lectureTask: Task<(AudioEnhancement.ByteRangeLecture, URL), Error>?
    private var fragments: [Int: Task<URL, Error>] = [:]
    private var starts: [Int: Task<Double, Error>] = [:]
    private var outputs: [Int: Task<Data, Error>] = [:]
    private var stopped = false
    private var reported = false

    init(stream: URL, ffmpeg: URL, folder: URL, parent: URL, fetcher: LiveAudioFetching, runner: LiveAudioProcessRunning,
         isolator: LiveAudioVoiceIsolating? = nil, report: @escaping @Sendable (LiveAudioFailure) async -> Void) {
        self.stream = stream
        self.ffmpeg = ffmpeg
        self.folder = folder
        self.parent = parent
        self.fetcher = fetcher
        self.runner = runner
        self.isolator = isolator
        self.report = report
    }

    func playlist() async throws -> Data {
        try await reporting {
            let (lecture, _) = try await self.lecture()
            return Data(AudioEnhancement.proxyPlaylist(lecture).utf8)
        }
    }

    func segment(_ index: Int) async throws -> Data {
        try await reporting {
            let (lecture, _) = try await self.lecture()
            guard lecture.segments.indices.contains(index) else { throw PipelineError.notFound }
            self.keep(around: index)
            // Retried once when the work it waited on was cancelled by an earlier request's seek
            // logic rather than by this request.
            for _ in 0..<2 {
                let task = self.output(index, count: lecture.segments.count)
                if index + 1 < lecture.segments.count { _ = self.output(index + 1, count: lecture.segments.count) }
                do {
                    return try await task.value
                } catch let error where Self.isCancellation(error) {
                    try self.checkRunning()
                    if self.outputs[index] == task { self.outputs[index] = nil }
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
        fragments = [:]
        starts = [:]
        outputs = [:]
        fetcher.close()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Steps

    /// The lecture's layout and its init section's file, fetched once.
    private func lecture() async throws -> (AudioEnhancement.ByteRangeLecture, URL) {
        try checkRunning()
        if let lectureTask { return try await lectureTask.value }
        let task = Task { () throws -> (AudioEnhancement.ByteRangeLecture, URL) in
            let (data, url) = try await self.fetcher.fetch(self.stream, range: nil)
            guard let text = String(data: data, encoding: .utf8),
                  let lecture = AudioEnhancement.byteRangeLecture(playlist: text, at: url) else { throw LiveAudioFetchError.unexpected }
            try await self.prepareFolder()
            let (bytes, _) = try await self.fetcher.fetch(lecture.file, range: lecture.initSection)
            let file = self.folder.appendingPathComponent("init.mp4")
            try bytes.write(to: file)
            return (lecture, file)
        }
        lectureTask = task
        return try await task.value
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

    private func output(_ index: Int, count: Int) -> Task<Data, Error> {
        if let existing = outputs[index] { return existing }
        // The previous segment counts when it is fetched or being made: then its bytes are (or
        // will be) here anyway.
        let hasPrevious = fragments[index - 1] != nil || outputs[index - 1] != nil
        let task = Task { try await self.produce(index, count: count, hasPrevious: hasPrevious) }
        outputs[index] = task
        return task
    }

    private func produce(_ index: Int, count: Int, hasPrevious: Bool) async throws -> Data {
        let (lecture, initFile) = try await lecture()
        let context = AudioEnhancement.audioContext(for: index, count: count, hasPrevious: hasPrevious)
        // All fetches start before any is awaited, so they run side by side.
        for k in context { _ = fragment(k, in: lecture) }
        var files: [Int: URL] = [:]
        for k in context { files[k] = try await fragmentFile(k, in: lecture) }
        let start = try await audioStart(index, in: lecture, initFile: initFile)
        let nextStart = index + 1 < count ? try await audioStart(index + 1, in: lecture, initFile: initFile) : nil
        let end = AudioEnhancement.audioEnd(index: index, start: start, nextStart: nextStart, lecture: lecture)
        let output = folder.appendingPathComponent("out\(index).ts")
        let video = AudioEnhancement.concatInput([initFile.path, files[index]!.path])
        let audio = AudioEnhancement.concatInput([initFile.path] + context.map { files[$0]!.path })
        if let isolator {
            // The context's audio starts where its first fragment's does; the WAVs keep no
            // timestamps, so that sample is what puts the isolated audio back on the clock.
            let firstSample = AudioEnhancement.samplePosition(try await audioStart(context.lowerBound, in: lecture, initFile: initFile))
            let decoded = folder.appendingPathComponent("decoded\(index).wav")
            let isolated = folder.appendingPathComponent("isolated\(index).wav")
            defer {
                try? FileManager.default.removeItem(at: decoded)
                try? FileManager.default.removeItem(at: isolated)
            }
            try await runner.run(ffmpeg, AudioEnhancement.isolationDecodeArguments(audio: audio, firstSample: firstSample, output: decoded.path))
            try Task.checkCancellation()
            try await isolator.isolate(decoded, to: isolated)
            try? FileManager.default.removeItem(at: decoded)
            try Task.checkCancellation()
            try await runner.run(ffmpeg, AudioEnhancement.isolatedEncodeArguments(video: video, isolated: isolated.path, firstSample: firstSample,
                                                                                  start: start, end: end, output: output.path))
        } else {
            try await runner.run(ffmpeg, AudioEnhancement.segmentArguments(video: video, audio: audio, start: start, end: end, output: output.path))
        }
        try Task.checkCancellation()
        let data = try Data(contentsOf: output)
        try? FileManager.default.removeItem(at: output)
        return data
    }

    private func fragment(_ k: Int, in lecture: AudioEnhancement.ByteRangeLecture) -> Task<URL, Error> {
        if let existing = fragments[k] { return existing }
        let span = lecture.segments[k].span
        let file = folder.appendingPathComponent("frag\(k).m4s")
        let task = Task { () throws -> URL in
            let (data, _) = try await self.fetcher.fetch(lecture.file, range: span)
            try Task.checkCancellation()
            try data.write(to: file)
            return file
        }
        fragments[k] = task
        return task
    }

    private func audioStart(_ k: Int, in lecture: AudioEnhancement.ByteRangeLecture, initFile: URL) async throws -> Double {
        if starts[k] == nil {
            let probe = folder.appendingPathComponent("probe\(k).txt")
            starts[k] = Task { () throws -> Double in
                let file = try await self.fragmentFile(k, in: lecture)
                try await self.runner.run(self.ffmpeg, AudioEnhancement.probeArguments(input: AudioEnhancement.concatInput([initFile.path, file.path]), output: probe.path))
                defer { try? FileManager.default.removeItem(at: probe) }
                guard let text = try? String(contentsOf: probe, encoding: .utf8),
                      let seconds = AudioEnhancement.firstPacketSeconds(framecrc: text) else { throw FFmpegExitError() }
                return seconds
            }
        }
        return try await starts[k]!.value
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
            }
        }
        throw CancellationError()
    }

    /// Cancels and forgets work outside the segments around `index`.
    private func keep(around index: Int) {
        let kept = AudioEnhancement.keptSegments(around: index)
        // One more fragment ahead than outputs: the last kept output reads the one after it.
        let keptFragments = kept.lowerBound...(kept.upperBound + 1)
        for (k, task) in outputs where !kept.contains(k) { task.cancel(); outputs[k] = nil }
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

    /// Runs `body`, reporting its first real failure before rethrowing it.
    private func reporting<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if stopped || Self.isCancellation(error) { throw error }
            if case PipelineError.notFound = error { throw error }
            if !reported {
                reported = true
                let failure: LiveAudioFailure
                if case LiveAudioFetchError.refused = error { failure = .streamRefused } else { failure = .unavailable }
                Logger(subsystem: "io.github.tvaccari.beepbar", category: "AudioEnhancer")
                    .error("Enhanced audio failed kind=\(failure == .streamRefused ? "refused" : "unavailable", privacy: .public)")
                await report(failure)
            }
            throw error
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
        let open = state.withLock { state -> Set<Int32>? in
            guard !state.stopped else { return nil }
            state.stopped = true
            return state.connections
        }
        guard let open else { return }
        source.cancel()
        // Unblocks their reads and writes; each connection closes its own descriptor.
        state.withLock { _ in for fd in open { shutdown(fd, SHUT_RDWR) } }
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
