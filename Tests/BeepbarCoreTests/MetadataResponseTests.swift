import Foundation
import Darwin
import Testing
@testable import BeepbarCore

/// Synthetic progressive responses prove reception stops, rather than merely rejecting the decoder input.
@Suite(.serialized) struct MetadataResponseTests {
    @Test(arguments: [nil, "1", "1048576", "invalid", "99999999999999999999999999999"] as [String?])
    func stopsOversizedResponseWhileReceiving(_ length: String?) async throws {
        let fixture = MetadataFixture(total: 16 * 1_048_576, length: length)
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: WeBeepAPIError.responseTooLarge) {
            try await WeBeepAPIClient(session: session).validateToken("synthetic-token")
        }
        await fixture.waitForStop()
        #expect(fixture.sent <= 1_048_576 + 4 * MetadataFixture.chunkSize)
        #expect(fixture.stopped)
    }

    /// All three callers retain their inclusive 1/2/4 MiB limit, even without a length header.
    @Test(arguments: [1, 2, 4]) func acceptsExactLimitAndRejectsOneByteMore(_ mib: Int) async throws {
        let limit = mib * 1_048_576
        for extra in [0, 1] {
            let fixture = MetadataFixture(total: limit + extra, prefix: mib == 1 ? MetadataFixture.siteInfo : "[]")
            let session = fixture.session()
            defer { session.invalidateAndCancel() }
            let operation: @Sendable () async throws -> Void = {
                let client = WeBeepAPIClient(session: session)
                if mib == 1 { _ = try await client.validateToken("token") }
                else if mib == 2 { _ = try await client.fetchCourses(userID: 7, token: "token") }
                else { _ = try await client.fetchContents(courseID: 9, token: "token") }
            }
            if extra == 0 { try await operation() }
            else { await #expect(throws: WeBeepAPIError.responseTooLarge) { try await operation() } }
        }
    }

    @Test func rejectsExcessiveLengthBeforeReceivingBody() async {
        let fixture = MetadataFixture(total: 16 * 1_048_576, length: "16777216")
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: WeBeepAPIError.responseTooLarge) {
            try await WeBeepAPIClient(session: session).validateToken("token")
        }
        #expect(fixture.sent <= 4 * MetadataFixture.chunkSize)
    }

    /// A rejected status/type must retain its recovery classification, even with an oversized body.
    @Test(arguments: [(503, "application/json", WeBeepAPIError.transport(503)),
                      (200, "text/html", .invalidResponse)])
    func preservesResponseErrors(_ status: Int, _ type: String, _ error: WeBeepAPIError) async {
        let fixture = MetadataFixture(total: 16 * 1_048_576, length: "16777216", status: status, type: type)
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: error) { try await WeBeepAPIClient(session: session).validateToken("token") }
        #expect(fixture.sent <= 4 * MetadataFixture.chunkSize)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cancelled])
    func preservesTransportErrors(_ code: URLError.Code) async {
        let fixture = MetadataFixture(total: 0, failure: code)
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        if code == .cancelled {
            await #expect(throws: CancellationError.self) { try await WeBeepAPIClient(session: session).validateToken("token") }
        } else {
            await #expect(throws: WeBeepAPIError.network(NetworkFailure(code))) {
                try await WeBeepAPIClient(session: session).validateToken("token")
            }
        }
    }

    @Test func cancellationStopsReceptionAndAlreadyCancelledTaskDoesNotStart() async throws {
        let fixture = MetadataFixture(total: 16 * 1_048_576)
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let task = Task { try await WeBeepAPIClient(session: session).validateToken("token") }
        while fixture.sent == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await fixture.waitForStop()
        #expect(fixture.stopped)
        #expect(fixture.sent < fixture.total)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WeBeepAPIClient(session: session).validateToken("token")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    /// Opt-in probe runs in a fresh Release test process for each advertised body size/ref.
    @Test func memoryProbe() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BEEPBAR_METADATA_PROBE_MIB"], let mib = Int(raw), mib > 1 else { return }
        let fixture = MetadataFixture(total: mib * 1_048_576)
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: WeBeepAPIError.responseTooLarge) { try await WeBeepAPIClient(session: session).validateToken("token") }
        await fixture.waitForStop()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("METADATA_PROBE advertised=\(fixture.total) sent=\(fixture.sent) peak_rss_bytes=\(usage.ru_maxrss)")
    }
}

/// Lazily produces fixed chunks on one background queue; it never allocates the advertised body.
private final class MetadataFixture: @unchecked Sendable {
    static let chunkSize = 16_384
    static let siteInfo = #"{"userid":7,"siteurl":"https://webeep.polimi.it"}"#
    let total: Int
    let prefix: String
    let length: String?
    let status: Int
    let type: String
    let failure: URLError.Code?
    let lock = NSLock()
    private var count = 0
    private var cancelled = false
    var sent: Int { lock.withLock { count } }
    var stopped: Bool { lock.withLock { cancelled } }

    init(total: Int, prefix: String = MetadataFixture.siteInfo, length: String? = nil, status: Int = 200, type: String = "application/json", failure: URLError.Code? = nil) {
        self.total = total; self.prefix = prefix; self.length = length
        self.status = status; self.type = type; self.failure = failure
    }
    func session() -> URLSession {
        MetadataProtocol.fixture = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetadataProtocol.self]
        return URLSession(configuration: config)
    }
    private let stoppedSignal = DispatchSemaphore(value: 0)
    /// Completion can precede URLProtocol.stopLoading. The signal is the handoff; timeout is only a watchdog.
    func waitForStop() async {
        guard !stopped else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.stoppedSignal.wait(timeout: .now() + 1)
                continuation.resume()
            }
        }
    }
    func stop() {
        let firstStop = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        if firstStop { stoppedSignal.signal() }
    }
    func next() -> Data? {
        lock.withLock {
            guard !cancelled, count < total else { return nil }
            let size = min(Self.chunkSize, total - count)
            var data = Data(repeating: 32, count: size)
            if count == 0 { data.replaceSubrange(0..<min(prefix.utf8.count, size), with: prefix.utf8.prefix(size)) }
            count += size
            return data
        }
    }
}

private final class MetadataProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: MetadataFixture!
    private var active: MetadataFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.fixture!
        active = fixture
        DispatchQueue.global().async { [self] in
            if let failure = fixture.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
            var headers = ["Content-Type": fixture.type]
            if let length = fixture.length { headers["Content-Length"] = length }
            let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            while let chunk = fixture.next() {
                client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !fixture.stopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { active?.stop() }
}
