import Foundation
import Darwin
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct RemoteDownloaderTests {
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
        await #expect(throws: expected) { try await downloader.download(file, token: "token", access: .unrestricted) }
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
        await #expect(throws: RemoteDownloadError.transport(404)) { try await downloader.download(file, token: "token", access: .unrestricted) }
        #expect(Self.leakedDownloadTemporaries(since: before, body: DownloadRejectedProtocol.body).isEmpty)
    }

    @Test func stopsABodyLargerThanReportedBeforeItIsFullyWritten() async throws {
        // No Content-Length, so only the byte count during the transfer can catch the overrun.
        // Chunks smaller than the 1 000-byte limit, so bytes (starting with the marker) are
        // written to the partial file before the overrun: the leak check below then proves the
        // partial file is removed, which a first chunk already over the limit never exercised.
        StreamingProtocol.reset(chunks: 400, chunkSize: 256)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        let before = Self.downloadTemporaryFiles()
        await #expect(throws: RemoteDownloadError.invalidResponse) {
            try await downloader.download(Self.file(size: 1_000), token: "token", access: .unrestricted)
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
        #expect(Self.downloadTemporaries(since: before, startingWith: StreamingProtocol.marker).isEmpty)
    }

    @Test func acceptsABodyOfExactlyTheReportedSizeWithoutContentLength() async throws {
        StreamingProtocol.reset(chunks: 4, chunkSize: 256)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        let downloaded = try await downloader.download(Self.file(size: 1_024), token: "token", access: .unrestricted)
        defer { try? FileManager.default.removeItem(at: downloaded.temporaryURL) }
        #expect(downloaded.expectedSize == 1_024)
        // The leak checks look for this prefix: prove they would see a body left behind.
        #expect(downloaded.temporaryURL.lastPathComponent.hasPrefix(RemoteDownloader.temporaryFilePrefix))
        #expect(try Data(contentsOf: downloaded.temporaryURL).count == 1_024)
    }

    /// Proves nothing is left behind; the body may reach disk before the rejection removes it.
    @Test func aRedirectedResponseIsRejectedAndLeavesNothingBehind() async throws {
        let before = Self.downloadTemporaryFiles()
        let downloader = RemoteDownloader(session: Self.session(RedirectingProtocol.self))
        await #expect(throws: RemoteDownloadError.unexpectedRedirect) {
            try await downloader.download(Self.file(size: Int64(RedirectingProtocol.body.count)), token: "token", access: .unrestricted)
        }
        #expect(Self.leakedDownloadTemporaries(since: before, body: RedirectingProtocol.body).isEmpty)
    }

    @Test func anHTTPRedirectIsRefusedBeforeTheSecondRequest() async throws {
        let server = try LocalRedirectServer()
        defer { server.stop() }
        let policy = WeBeepServerPolicy(endpoint: server.url, siteURL: server.url, scheme: "http", host: "127.0.0.1", port: server.port)
        let downloader = RemoteDownloader(policy: policy)
        let file = RemoteFileCandidate(id: "file", courseID: 1, sectionID: 1, moduleID: 1, sectionName: "", moduleName: "", filename: "file.txt", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/file", downloadURL: server.url, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true)
        await #expect(throws: RemoteDownloadError.transport(302)) {
            try await downloader.download(file, token: "token", access: .unrestricted)
        }
        #expect(server.requestCount == 1)
    }

    /// The server announces fewer bytes than WeBeep reported for the file. The body is smaller
    /// than the expected size, so only the Content-Length check can reject it (with a larger body,
    /// the overrun check would reject it too and hide a missing Content-Length check).
    @Test func aMismatchedContentLengthIsRejectedAndLeavesNothingBehind() async throws {
        let before = Self.downloadTemporaryFiles()
        let downloader = RemoteDownloader(session: Self.session(WrongLengthProtocol.self))
        await #expect(throws: RemoteDownloadError.invalidResponse) {
            try await downloader.download(Self.file(size: Int64(WrongLengthProtocol.body.count + 10)), token: "token", access: .unrestricted)
        }
        #expect(Self.leakedDownloadTemporaries(since: before, body: WrongLengthProtocol.body).isEmpty)
    }

    @Test func aServerErrorKeepsItsStatusWhateverTheBodySize() async throws {
        // Error pages are larger than most files: the size cap must not hide a 401/500.
        let downloader = RemoteDownloader(session: Self.session(DownloadRejectedProtocol.self))
        await #expect(throws: RemoteDownloadError.transport(404)) {
            try await downloader.download(Self.file(size: 1), token: "token", access: .unrestricted)
        }
    }

    @Test func cancellingTheSyncIsStillACancellationNotARejectedFile() async throws {
        // Chunks at least as long as the marker, so the partial file starts with it.
        StreamingProtocol.reset(chunks: 10_000, chunkSize: 64)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        // Taken before the transfer starts, so the partial body it writes counts as a leak.
        let before = Self.downloadTemporaryFiles()
        let task = Task { try await downloader.download(Self.file(size: 640_000), token: "token", access: .unrestricted) }
        // Cancel only once the downloader has really written a partial file. Without a
        // Content-Type, URLSession held back the first 512 bytes to guess one, so a cancel after a
        // few chunks never reached the cleanup this test is about; `StreamingProtocol` now sends
        // a Content-Type, and waiting for the file keeps the test independent of that buffering.
        await Self.waitUntil { !Self.downloadTemporaries(since: before, startingWith: StreamingProtocol.marker).isEmpty }
        #expect(!Self.downloadTemporaries(since: before, startingWith: StreamingProtocol.marker).isEmpty, "the partial file must exist before cancelling")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Self.downloadTemporaries(since: before, startingWith: StreamingProtocol.marker).isEmpty)
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
            try await downloader.download(Self.file(size: 11), token: "token", access: .unrestricted)
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
        return Set(entries.filter { $0.hasPrefix(RemoteDownloader.temporaryFilePrefix) || $0.hasPrefix("CFNetworkDownload") })
    }
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
        queue.async { self.send(index: 0, count: count, size: size) }
    }
    private func send(index: Int, count: Int, size: Int) {
        guard !isStopped else { return }
        guard index < count else { client?.urlProtocolDidFinishLoading(self); return }
        var chunk = Data(count: size)
        if index == 0 { chunk.replaceSubrange(0..<min(size, Self.marker.count), with: Self.marker.prefix(size)) }
        client?.urlProtocol(self, didLoad: chunk)
        Self.lock.withLock { Self.delivered += 1 }
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { self.send(index: index + 1, count: count, size: size) }
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
        let listeningFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listeningFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
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

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }

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
