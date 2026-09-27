import Foundation
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
        StreamingProtocol.reset(chunks: 400, chunkSize: 64 * 1024)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        let before = Self.downloadTemporaryFiles()
        await #expect(throws: RemoteDownloadError.invalidResponse) {
            try await downloader.download(Self.file(size: 1_000), token: "token", access: .unrestricted)
        }
        #expect(StreamingProtocol.deliveredChunks < 400)
        #expect(StreamingProtocol.wasStopped)
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

    @Test func aRedirectedResponseIsRejectedBeforeAnythingIsWritten() async throws {
        let before = Self.downloadTemporaryFiles()
        let downloader = RemoteDownloader(session: Self.session(RedirectingProtocol.self))
        await #expect(throws: RemoteDownloadError.unexpectedRedirect) {
            try await downloader.download(Self.file(size: Int64(RedirectingProtocol.body.count)), token: "token", access: .unrestricted)
        }
        #expect(Self.leakedDownloadTemporaries(since: before, body: RedirectingProtocol.body).isEmpty)
    }

    @Test func aMismatchedContentLengthIsRejectedBeforeAnythingIsWritten() async throws {
        let before = Self.downloadTemporaryFiles()
        let downloader = RemoteDownloader(session: Self.session(WrongLengthProtocol.self))
        await #expect(throws: RemoteDownloadError.invalidResponse) {
            try await downloader.download(Self.file(size: 3), token: "token", access: .unrestricted)
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
        StreamingProtocol.reset(chunks: 10_000, chunkSize: 16)
        let downloader = RemoteDownloader(session: Self.session(StreamingProtocol.self))
        let task = Task { try await downloader.download(Self.file(size: 160_000), token: "token", access: .unrestricted) }
        while StreamingProtocol.deliveredChunks < 5 { await Task.yield() }
        task.cancel()
        let before = Self.downloadTemporaryFiles()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Self.downloadTemporaries(since: before, startingWith: StreamingProtocol.marker).isEmpty)
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
/// the loading system stops it: lets a test see whether a transfer was cut short.
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
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
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
