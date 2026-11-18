#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct RemoteDownloaderTests {
    private let fixture = try! DownloadFixture()
    /// Completion preceding continuation registration must be delivered exactly once.
    @Test func completionBeforeRegistrationIsNotLost() {
        var completion = DownloadCompletion()
        let received = CompletionProbe()
        let result: Result<String, Error> = .failure(URLError(.cancelled))
        completion.finish(result)?(result)
        if let parked = completion.register({ received.accept($0) }) { received.accept(parked) }
        #expect(received.calls == 1)
        #expect(received.wasCancelled)
    }

    /// Completion after registration must also be delivered exactly once.
    @Test func completionAfterRegistrationIsDelivered() {
        var completion = DownloadCompletion()
        let received = CompletionProbe()
        if let parked = completion.register({ received.accept($0) }) { received.accept(parked) }
        let result: Result<String, Error> = .success("digest")
        completion.finish(result)?(result)
        #expect(received.calls == 1)
        #expect(received.digest == "digest")
    }

    /// Cancellation at the stage handoff closes and removes it before any request starts.
    @Test func cancellationImmediatelyAfterOpeningStageCleansUp() async throws {
        StreamingProtocol.reset(chunks: 1, chunkSize: 1)
        let barrier = StageBarrier()
        let store = fixture.store
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self), writeStage: { write($0, $1, $2) }, afterStageOpened: { await barrier.pause() })
        let done = CompletionProbe()
        let task = Task {
            do {
                _ = try await downloader.download(Self.file(size: 1), token: "token", access: .unrestricted, into: store)
                done.accept(.success("unexpected success"))
            } catch { done.accept(.failure(error)) }
        }
        await Self.waitUntil { barrier.waiting }
        #expect(barrier.waiting)
        #expect(fixture.stageFiles.count == 1)
        task.cancel()
        barrier.release()
        await Self.waitUntil { done.calls > 0 }
        #expect(done.calls == 1)
        #expect(done.wasTaskCancelled)
        #expect(fixture.stageFiles.isEmpty)
        #expect(StreamingProtocol.deliveredChunks == 0)
    }

    /// A paused transfer exposes written bytes before it can finish, even without Content-Length.
    @Test func reportsBytesWhileTransferIsInFlight() async throws {
        StreamingProtocol.reset(chunks: 1_000, chunkSize: 256)
        let counter = DownloadWriteCounter()
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        let store = fixture.store
        let task = Task { try await downloader.download(Self.file(size: 256_000), token: "token", access: .unrestricted, into: store, onBytes: { counter.add(Int($0)) }) }
        await Self.waitUntil { StreamingProtocol.deliveredChunks >= 10 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(StreamingProtocol.deliveredChunks < 1_000)
        #expect(counter.total > 0)
        task.cancel()
        _ = try? await task.value
    }

    /// The batch publishes bytes before a gated body completes, then clears them when it ends.
    @Test func batchPublishesWhileBodyIsGated() async throws {
        GatedDownloadProtocol.reset()
        defer { GatedDownloadProtocol.release() }
        let db = try SyncDatabase(url: fixture.root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await db.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let runner = ManualSyncRun(rootID: rootID, database: db, fileStore: fixture.store, gate: RootOperationGate(), downloader: RemoteDownloader(session: Self.session(GatedDownloadProtocol.self)), networkAccess: .unrestricted)
        let item = PreparedSyncItem(remote: Self.file(size: 1_024), destination: try RelativePath("Course/file.txt"))
        let seen = SyncProgressProbe()
        let task = Task { try await runner.start(items: [item], token: "token", progress: { seen.append($0) }) }
        await Self.waitUntil { seen.values.contains { $0.transfer?.received == 256 } }
        #expect(seen.values.contains { $0.completed == 0 && $0.transfer?.received == 256 && $0.transfer?.total == 1_024 })
        #expect(!GatedDownloadProtocol.finished)
        GatedDownloadProtocol.release()
        let result = try await task.value
        #expect(result.completed == 1)
        #expect(result.added == 1)
        #expect(seen.values.last?.transfer == nil)
    }

    /// The received bytes are written once to a stage and the artifact names their SHA-256.
    @Test func downloadWritesOnePassIntoTheStage() async throws {
        let fixture = try DownloadFixture()
        StreamingProtocol.reset(chunks: 4, chunkSize: 256)
        let counter = DownloadWriteCounter()
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self), writeStage: { fd, bytes, count in
            let result = write(fd, bytes, count)
            if result > 0 { counter.add(result) }
            return result
        })
        let before = Self.downloadTemporaryFiles()
        let artifact = try await downloader.download(Self.file(size: 1_024), token: "token", access: .unrestricted, into: fixture.store)
        let bytes = try Data(contentsOf: fixture.root.appending(path: artifact.stagePath.value))
        #expect(bytes.count == 1_024)
        #expect(counter.total == 1_024)
        #expect(artifact.sha256 == fixture.digest(bytes))
        #expect(Self.downloadTemporaryFiles().subtracting(before).isEmpty)
    }

    /// Proves a completed download hands over a stage whose stored bytes hash to the reported
    /// digest, whose size is the reported one, and whose permission bits equal those of a stage made
    /// by `createStage()` (so the installed file is permissioned as before). Guards against hashing
    /// something other than what was saved, and against the download path changing file modes.
    @Test func completedDownloadMatchesItsDigestSizeAndStageMode() async throws {
        StreamingProtocol.reset(chunks: 200, chunkSize: 256)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        let artifact = try await downloader.download(Self.file(size: 51_200), token: "token", access: .unrestricted, into: fixture.store)
        let path = fixture.root.appending(path: artifact.stagePath.value)
        let bytes = try Data(contentsOf: path)
        #expect(bytes.count == 51_200)
        #expect(artifact.size == 51_200)
        #expect(artifact.sha256 == fixture.digest(bytes))
        let reference = try await fixture.store.createStage()
        let referenceMode = try FileManager.default.attributesOfItem(atPath: fixture.root.appending(path: reference.relativePath.value).path)[.posixPermissions] as? Int
        let downloadedMode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(downloadedMode != nil)
        #expect(downloadedMode == referenceMode)
    }

    /// Proves the hand-off rechecks the stage identity: if the path is replaced by a different
    /// file of the same size after the last byte is written, the download fails with
    /// `invalidStage` and the original is not handed over. `discard` refuses to unlink a file that
    /// is not the one the stage created, so the foreign replacement stays in staging for the
    /// recovery sweep (asserted below) instead of being deleted blindly. The swap runs inside the
    /// injected write, on the final write, so it is deterministic; the replacement is created
    /// before the original is renamed over, so the two inodes are necessarily distinct.
    @Test func replacedStageFailsHandOffAndLeavesTheForeignFileForTheSweep() async throws {
        StreamingProtocol.reset(chunks: 4, chunkSize: 256)
        let counter = DownloadWriteCounter()
        let staging = fixture.root.appending(path: ".beepbar/staging")
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self), writeStage: { fd, bytes, count in
            let result = write(fd, bytes, count)
            if result > 0 { counter.add(result) }
            if counter.total == 1_024 {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
                if let name = entries.first {
                    let replacement = staging.appending(path: "replacement.tmp")
                    try? Data(count: 1_024).write(to: replacement)
                    rename(replacement.path, staging.appending(path: name).path)
                }
            }
            return result
        })
        await #expect(throws: FileStoreError.invalidStage) {
            try await downloader.download(Self.file(size: 1_024), token: "token", access: .unrestricted, into: fixture.store)
        }
        // `discard` refuses to unlink a file that is not the one the stage created, so the foreign
        // replacement stays for the recovery sweep instead of being deleted blindly.
        #expect(fixture.stageFiles.count == 1)
        try await fixture.store.sweepUnreferencedStages(referencedPaths: [])
        #expect(fixture.stageFiles.isEmpty)
    }

    /// Proves the hand-off rechecks the stage size: the injected write truncates the stage through
    /// its own descriptor after the last byte, so the inode (identity) is unchanged and only the
    /// size check can notice. Expects `sizeMismatch` and the stage removed (it is still ours).
    /// Guards against handing over a file whose size no longer matches the digest's source.
    @Test func truncatedStageFailsHandOffOnSizeAndIsRemoved() async throws {
        StreamingProtocol.reset(chunks: 4, chunkSize: 256)
        let counter = DownloadWriteCounter()
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self), writeStage: { fd, bytes, count in
            let result = write(fd, bytes, count)
            if result > 0 { counter.add(result) }
            if counter.total == 1_024 { _ = ftruncate(fd, 512) }
            return result
        })
        await #expect(throws: FileStoreError.sizeMismatch) {
            try await downloader.download(Self.file(size: 1_024), token: "token", access: .unrestricted, into: fixture.store)
        }
        #expect(fixture.stageFiles.isEmpty)
    }

    /// A body shorter than the reported size (no Content-Length to catch it early) is rejected and
    /// its partial stage removed, instead of being handed over as if complete.
    @Test func shorterBodyThanReportedIsRejectedAndRemoved() async throws {
        StreamingProtocol.reset(chunks: 2, chunkSize: 256)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        await #expect(throws: RemoteDownloadError.invalidResponse) {
            try await downloader.download(Self.file(size: 1_024), token: "token", access: .unrestricted, into: fixture.store)
        }
        #expect(fixture.stageFiles.isEmpty)
    }

    /// A short syscall write must reject the transfer and discard its partial stage.
    @Test func shortWriteRejectsAndRemovesTheStage() async throws {
        StreamingProtocol.reset(chunks: 4, chunkSize: 256)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self), writeStage: { fd, bytes, count in
            write(fd, bytes, max(1, count / 2))
        })
        await #expect(throws: FileStoreError.ioFailure) {
            try await downloader.download(Self.file(size: 1_024), token: "token", access: .unrestricted, into: fixture.store)
        }
        #expect(fixture.stageFiles.isEmpty)
        await Self.waitUntil { StreamingProtocol.wasStopped }
    }

    /// A crash-left partial remains discoverable and is swept on recovery.
    @Test func crashLeftStageIsSwept() async throws {
        let (_, fd) = try await fixture.store.openDownloadStage()
        let bytes = Data("partial".utf8)
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        #expect(count == bytes.count)
        close(fd)
        #expect(fixture.stageFiles.count == 1)
        try await fixture.store.sweepUnreferencedStages(referencedPaths: [])
        #expect(fixture.stageFiles.isEmpty)
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, RemoteDownloadError.network(.offline)),
        (.timedOut, .network(.timedOut)),
        (.networkConnectionLost, .network(.connectionLost))
    ])
    func preservesNetworkFailure(_ code: URLError.Code, _ expected: RemoteDownloadError) async {
        DownloadFailureProtocol.code = code
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFailureProtocol.self]
        let downloader = RemoteDownloader(session: URLSession(configuration: configuration))
        let file = RemoteFileCandidate(
            id: "file", courseID: 1, sectionID: 1, moduleID: 1,
            sectionName: "", moduleName: "", filename: "file.txt", remoteFilePath: "/",
            canonicalPluginPath: "/pluginfile.php/file",
            downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/file")!,
            size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true
        )
        await #expect(throws: expected) { try await downloader.download(file, token: "token", access: .unrestricted, into: fixture.store) }
    }

    @Test func removesTemporaryFileWhenResponseIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadRejectedProtocol.self]
        let downloader = RemoteDownloader(session: URLSession(configuration: configuration))
        let file = RemoteFileCandidate(
            id: "file", courseID: 1, sectionID: 1, moduleID: 1,
            sectionName: "", moduleName: "", filename: "file.txt", remoteFilePath: "/",
            canonicalPluginPath: "/pluginfile.php/file",
            downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/file")!,
            size: 4, modifiedAt: nil, observedRevision: "1", isSupported: true
        )
        let before = Self.downloadTemporaryFiles()
        await #expect(throws: RemoteDownloadError.transport(404)) { try await downloader.download(file, token: "token", access: .unrestricted, into: fixture.store) }
        #expect(Self.leakedDownloadTemporaries(since: before, body: DownloadRejectedProtocol.body).isEmpty)
        #expect(fixture.stageFiles.isEmpty)
    }

    @Test func stopsABodyLargerThanReportedBeforeItIsFullyWritten() async throws {
        // No Content-Length, so only the byte count during the transfer can catch the overrun.
        // Chunks smaller than the 1 000-byte limit, so bytes (starting with the marker) are
        // written to the partial file before the overrun: the leak check below then proves the
        // partial file is removed, which a first chunk already over the limit never exercised.
        StreamingProtocol.reset(chunks: 400, chunkSize: 256)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        await #expect(throws: RemoteDownloadError.invalidResponse) {
            try await downloader.download(Self.file(size: 1_000), token: "token", access: .unrestricted, into: fixture.store)
        }
        // URLSession tears the transfer down (`stopLoading`) on its own queue a few ms after the
        // downloader cancels it. Asserting `wasStopped` right away is what failed 19 of 25 runs
        // under CPU load; waiting for it also leaves `deliveredChunks` final and nothing running
        // into the next test. `wasStopped` is only the wait condition, since `stopLoading` also
        // runs after a body that finished normally. The proof of an early stop is
        // `deliveredChunks < 400`: a transfer never cut off delivers all 400 chunks (under a
        // second) before the download even throws.
        await Self.waitUntil { StreamingProtocol.wasStopped }
        #expect(StreamingProtocol.deliveredChunks < 400)
        #expect(fixture.stageFiles.isEmpty)
    }

    @Test func acceptsABodyOfExactlyTheReportedSizeWithoutContentLength() async throws {
        StreamingProtocol.reset(chunks: 4, chunkSize: 256)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        let downloaded = try await downloader.download(Self.file(size: 1_024), token: "token", access: .unrestricted, into: fixture.store)
        #expect(downloaded.size == 1_024)
        #expect(try Data(contentsOf: fixture.root.appending(path: downloaded.stagePath.value)).count == 1_024)
    }

    /// Proves nothing is left behind; the body may reach disk before the rejection removes it.
    @Test func aRedirectedResponseIsRejectedAndLeavesNothingBehind() async throws {
        let before = Self.downloadTemporaryFiles()
        let downloader = RemoteDownloader(session: Self.session(RedirectingProtocol.self))
        await #expect(throws: RemoteDownloadError.unexpectedRedirect) {
            try await downloader.download(Self.file(size: Int64(RedirectingProtocol.body.count)), token: "token", access: .unrestricted, into: fixture.store)
        }
        #expect(Self.leakedDownloadTemporaries(since: before, body: RedirectingProtocol.body).isEmpty)
        #expect(fixture.stageFiles.isEmpty)
    }

    @Test func anHTTPRedirectIsRefusedBeforeTheSecondRequest() async throws {
        let server = try LocalRedirectServer()
        defer { server.stop() }
        let policy = WeBeepServerPolicy(endpoint: server.url, siteURL: server.url, scheme: "http", host: "127.0.0.1", port: server.port)
        let downloader = RemoteDownloader(policy: policy)
        let file = RemoteFileCandidate(id: "file", courseID: 1, sectionID: 1, moduleID: 1, sectionName: "", moduleName: "", filename: "file.txt", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/file", downloadURL: server.url, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true)
        await #expect(throws: RemoteDownloadError.transport(302)) {
            try await downloader.download(file, token: "token", access: .unrestricted, into: fixture.store)
        }
        #expect(server.requestCount == 1)
        #expect(fixture.stageFiles.isEmpty)
    }

    /// The server announces fewer bytes than WeBeep reported for the file. The body is smaller
    /// than the expected size, so only the Content-Length check can reject it (with a larger body,
    /// the overrun check would reject it too and hide a missing Content-Length check).
    @Test func aMismatchedContentLengthIsRejectedAndLeavesNothingBehind() async throws {
        let before = Self.downloadTemporaryFiles()
        let downloader = RemoteDownloader(session: Self.session(WrongLengthProtocol.self))
        await #expect(throws: RemoteDownloadError.invalidResponse) {
            try await downloader.download(Self.file(size: Int64(WrongLengthProtocol.body.count + 10)), token: "token", access: .unrestricted, into: fixture.store)
        }
        #expect(Self.leakedDownloadTemporaries(since: before, body: WrongLengthProtocol.body).isEmpty)
        #expect(fixture.stageFiles.isEmpty)
    }

    @Test func aServerErrorKeepsItsStatusWhateverTheBodySize() async throws {
        // Error pages are larger than most files: the size cap must not hide a 401/500.
        let downloader = RemoteDownloader(session: Self.session(DownloadRejectedProtocol.self))
        await #expect(throws: RemoteDownloadError.transport(404)) {
            try await downloader.download(Self.file(size: 1), token: "token", access: .unrestricted, into: fixture.store)
        }
    }

    @Test func cancellingTheSyncIsStillACancellationNotARejectedFile() async throws {
        // Chunks at least as long as the marker, so the partial file starts with it.
        StreamingProtocol.reset(chunks: 10_000, chunkSize: 64)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        let store = fixture.store
        let task = Task { try await downloader.download(Self.file(size: 640_000), token: "token", access: .unrestricted, into: store) }
        // Cancel only once the downloader has really written a partial file. Without a
        // Content-Type, URLSession held back the first 512 bytes to guess one, so a cancel after a
        // few chunks never reached the cleanup this test is about; `StreamingProtocol` now sends
        // a Content-Type, and waiting for the file keeps the test independent of that buffering.
        await Self.waitUntil { !fixture.stages(startingWith: StreamingProtocol.marker).isEmpty }
        #expect(!fixture.stages(startingWith: StreamingProtocol.marker).isEmpty, "the partial file must exist before cancelling")
        #expect(StreamingProtocol.deliveredChunks < 10_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.stageFiles.isEmpty)
        // Let the transfer finish tearing down, so it can't add to the next test's counters; a
        // timeout fails here rather than in whichever test runs next.
        await Self.waitUntil { StreamingProtocol.wasStopped }
        #expect(StreamingProtocol.wasStopped)
    }

    @Test func sizeLimitDefaultsToOneGigabyteAndKeepsACustomValue() {
        #expect(RemoteDownloader.defaultMaximumSize == 1_073_741_824)
        #expect(RemoteDownloader(session: .shared).maximumSize == RemoteDownloader.defaultMaximumSize)
        #expect(RemoteDownloader(session: .shared, maximumSize: 10).maximumSize == 10)
    }

    @Test func rejectsAFileReportedLargerThanTheLimitWithoutDownloading() async {
        StreamingProtocol.reset(chunks: 1, chunkSize: 1)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self), maximumSize: 10)
        await #expect(throws: RemoteDownloadError.tooLarge) {
            try await downloader.download(Self.file(size: 11), token: "token", access: .unrestricted, into: fixture.store)
        }
        #expect(StreamingProtocol.deliveredChunks == 0)
    }

    /// Polls `condition` for up to 5 s. Bounded so that a regression fails the test (through the
    /// assertions after it) instead of spinning forever: CI sets no job timeout.
    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private static func session(_ protocolClass: AnyClass) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }

    private static func file(size: Int64) -> RemoteFileCandidate {
        RemoteFileCandidate(
            id: "file", courseID: 1, sectionID: 1, moduleID: 1,
            sectionName: "", moduleName: "", filename: "file.txt", remoteFilePath: "/",
            canonicalPluginPath: "/pluginfile.php/file",
            downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/file")!,
            size: size, modifiedAt: nil, observedRevision: "1", isSupported: true
        )
    }

    private static func downloadTemporaries(since before: Set<String>, startingWith marker: Data) -> [String] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return downloadTemporaryFiles().subtracting(before).filter {
            (try? Data(contentsOf: directory.appending(path: $0)))?.starts(with: marker) == true
        }
    }

    // URLSession stages every download in the process temporary directory, which the rest of the
    // suite uses at the same time: only a file holding this test's body is our leak.
    private static func leakedDownloadTemporaries(since before: Set<String>, body: Data) -> [String] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return downloadTemporaryFiles().subtracting(before).filter {
            (try? Data(contentsOf: directory.appending(path: $0))) == body
        }
    }

    private static func downloadTemporaryFiles() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(entries.filter { $0.hasPrefix("Beepbar-download-") || $0.hasPrefix("CFNetworkDownload") })
    }
}

private final class SyncProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncProgress] = []
    func append(_ progress: SyncProgress) { lock.withLock { stored.append(progress) } }
    var values: [SyncProgress] { lock.withLock { stored } }
}

private final class GatedDownloadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: GatedDownloadProtocol?
    nonisolated(unsafe) private static var didFinish = false
    static var finished: Bool { lock.withLock { didFinish } }
    static func reset() { lock.withLock { current = nil; didFinish = false } }
    static func release() {
        let instance = lock.withLock { let instance = current; current = nil; return instance }
        guard let instance else { return }
        instance.client?.urlProtocol(instance, didLoad: Data(count: 768))
        instance.client?.urlProtocolDidFinishLoading(instance)
        lock.withLock { didFinish = true }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: 256))
        Self.lock.withLock { Self.current = self }
    }
    override func stopLoading() { Self.lock.withLock { if Self.current === self { Self.current = nil } } }
}

private final class DownloadRejectedProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("rejected-body-\(UUID().uuidString)".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DownloadFailureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var code = URLError.Code.notConnectedToInternet
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(Self.code)) }
    override func stopLoading() {}
}

/// Streams `chunks` pieces of body from a background queue, without a Content-Length, until
/// the loading system stops it: lets a test see whether a transfer was cut short. It sends a
/// Content-Type so URLSession delivers each chunk as it arrives instead of buffering the first
/// 512 bytes to guess one.
private final class StreamingProtocol: URLProtocol, @unchecked Sendable {
    static let marker = Data("streaming-body-\(UUID().uuidString)".utf8)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chunks = 0
    nonisolated(unsafe) private static var chunkSize = 0
    nonisolated(unsafe) private static var delivered = 0
    nonisolated(unsafe) private static var stopped = false
    private let queue = DispatchQueue(label: "StreamingProtocol")
    private var isStopped = false

    static func reset(chunks: Int, chunkSize: Int) {
        lock.withLock { Self.chunks = chunks; Self.chunkSize = chunkSize; delivered = 0; stopped = false }
    }
    static var deliveredChunks: Int { lock.withLock { delivered } }
    static var wasStopped: Bool { lock.withLock { stopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let (count, size) = Self.lock.withLock { (Self.chunks, Self.chunkSize) }
        // `URLProtocol` is not `Sendable` on Linux's Foundation, so the class's own `@unchecked
        // Sendable` does not reach the closure there; the instance is guarded by `queue` anyway.
        nonisolated(unsafe) let this = self
        queue.async { this.send(index: 0, count: count, size: size) }
    }
    private func send(index: Int, count: Int, size: Int) {
        guard !isStopped else { return }
        guard index < count else { client?.urlProtocolDidFinishLoading(self); return }
        var chunk = Data(count: size)
        if index == 0 { chunk.replaceSubrange(0..<min(size, Self.marker.count), with: Self.marker.prefix(size)) }
        client?.urlProtocol(self, didLoad: chunk)
        Self.lock.withLock { Self.delivered += 1 }
        nonisolated(unsafe) let this = self
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { this.send(index: index + 1, count: count, size: size) }
    }
    override func stopLoading() {
        queue.sync { isStopped = true }
        Self.lock.withLock { Self.stopped = true }
    }
}

private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("redirected-body-\(UUID().uuidString)".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let target = URL(string: "https://webeep.polimi.it/pluginfile.php/elsewhere")!
        let response = HTTPURLResponse(url: target, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class LocalRedirectServer: @unchecked Sendable {
    let port: Int
    let url: URL
    private let fd: Int32
    private let lock = NSLock()
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }

    init() throws {
#if canImport(Darwin)
        let listeningFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listeningFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
#else
        let listeningFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard listeningFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        var address = sockaddr_in(sin_family: sa_family_t(AF_INET), sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
#endif
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listeningFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listeningFD, 2) == 0 else { close(listeningFD); throw CocoaError(.fileReadUnknown) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listeningFD, $0, &size) } }
        guard named == 0 else { close(listeningFD); throw CocoaError(.fileReadUnknown) }
        port = Int(UInt16(bigEndian: address.sin_port))
        url = URL(string: "http://127.0.0.1:\(port)/pluginfile.php/file")!
        fd = listeningFD
        DispatchQueue.global().async { [self] in serve() }
    }

    func stop() { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }

    private func serve() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            let count = lock.withLock { requests += 1; return requests }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &buffer, buffer.count, 0)
            let response = count == 1
                ? "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/pluginfile.php/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx"
            _ = response.withCString { send(client, $0, strlen($0), 0) }
            close(client)
        }
    }
}

private final class WrongLengthProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("wrong-length-\(UUID().uuidString)".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(Self.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DownloadWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var total: Int { lock.withLock { value } }
    func add(_ amount: Int) { lock.withLock { value += amount } }
}

private final class DownloadFixture {
    let root: URL
    let store: FileStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try FileStore(root: root)
    }
    var stageFiles: [URL] {
        let directory = root.appending(path: ".beepbar/staging")
        return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
    func stages(startingWith prefix: Data) -> [URL] {
        stageFiles.filter {
            (try? Data(contentsOf: $0).starts(with: prefix)) == true
        }
    }
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    deinit { try? FileManager.default.removeItem(at: root) }
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, Error>] = []
    func accept(_ result: Result<String, Error>) { lock.withLock { results.append(result) } }
    var calls: Int { lock.withLock { results.count } }
    var digest: String? { lock.withLock { try? results.first?.get() } }
    var wasTaskCancelled: Bool { lock.withLock { guard case .failure(let error) = results.first else { return false }; return error is CancellationError } }
    var wasCancelled: Bool { lock.withLock { guard case .failure(let error) = results.first else { return false }; return (error as? URLError)?.code == .cancelled } }
}

private final class StageBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var waiting: Bool { lock.withLock { continuation != nil } }
    func pause() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                self.continuation = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
