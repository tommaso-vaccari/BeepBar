import Foundation
import Darwin
import Testing
@testable import BeepbarCore

/// Synthetic progressive responses prove reception stops, rather than merely rejecting the decoder input.
@Suite(.serialized) struct MetadataResponseTests {
    @Test(arguments: [nil, "1", "1048576", "invalid", "99999999999999999999999999999"] as [String?])
    func stopsOversizedResponseWhileReceiving(_ length: String?) async throws {
        let fixture = MetadataFixture(total: 16 * 1_048_576, length: length, cancellationBoundary: 1_048_576 + MetadataFixture.chunkSize)
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
        let fixture = MetadataFixture(total: 16 * 1_048_576, length: "16777216", cancellationBoundary: MetadataFixture.chunkSize)
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
        let fixture = MetadataFixture(total: 16 * 1_048_576, length: "16777216", status: status, type: type, cancellationBoundary: MetadataFixture.chunkSize)
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

    /// Force the exact handoff order from #127: cancellation's terminal delegate callback
    /// arrives before a consumer is installed. The watchdog only releases a broken receiver.
    @Test func terminalCancellationBeforeContinuationInstallationIsRetained() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://synthetic.invalid/metadata")!)
        let receiver = BoundedMetadataResponse(limit: 1024)
        let completion = DispatchGroup()
        completion.enter()
        receiver.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        let consumer = Task {
            defer { completion.leave() }
            return try await receiver.receive { Issue.record("An already completed transport must not start") }
        }
        let finished = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: completion.wait(timeout: .now() + 2) == .success)
            }
        }
        #expect(finished, "Terminal cancellation was lost before continuation installation")
        // A broken bridge discards the first callback. Replay only after the failed watchdog
        // to release its checked continuation; ordering above comes from direct callback delivery.
        if !finished { receiver.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled)) }
        await #expect(throws: URLError(.cancelled)) { try await consumer.value }
    }

    /// Success/error callbacks can precede installation, and a later duplicate cannot replace
    /// the first terminal result or resume the consumer twice. No live endpoint is contacted.
    @Test(arguments: [false, true]) func terminalResultWinsOnceBeforeAndAfterInstallation(_ early: Bool) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://synthetic.invalid/metadata")!)
        let receiver = BoundedMetadataResponse(limit: 1024)
        let payload = Data("[]".utf8)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let deliver: @Sendable () -> Void = {
            receiver.urlSession(session, dataTask: task, didReceive: response) { disposition in
                #expect(disposition == .allow)
            }
            receiver.urlSession(session, dataTask: task, didReceive: payload)
            receiver.urlSession(session, task: task, didCompleteWithError: nil)
            receiver.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        }
        if early { deliver() }
        let received = try await receiver.receive {
            #expect(!early, "Transport completed before installation must not start")
            if !early { deliver() }
        }
        #expect(received == payload)
        receiver.urlSession(session, task: task, didCompleteWithError: URLError(.timedOut))
    }

    /// Two concurrent terminal callbacks may race with installation; only one result survives.
    /// Repetition covers both winners without making either scheduling order an expectation.
    @Test func concurrentSuccessAndCancellationCompleteOnce() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for _ in 0..<30 {
            let task = session.dataTask(with: URL(string: "https://synthetic.invalid/metadata")!)
            let receiver = BoundedMetadataResponse(limit: 1024)
            let payload = Data("[]".utf8)
            let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            receiver.urlSession(session, dataTask: task, didReceive: response) { _ in }
            receiver.urlSession(session, dataTask: task, didReceive: payload)
            let group = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            for failure in [nil, URLError(.cancelled)] as [URLError?] {
                group.enter()
                DispatchQueue.global().async {
                    start.wait()
                    receiver.urlSession(session, task: task, didCompleteWithError: failure)
                    group.leave()
                }
            }
            start.signal(); start.signal()
            do { #expect(try await receiver.receive {} == payload) }
            catch { #expect((error as? URLError)?.code == .cancelled) }
            await withCheckedContinuation { continuation in
                group.notify(queue: .global()) { continuation.resume() }
            }
        }
    }

    /// Opt-in probe runs in a fresh Release test process for each advertised body size/ref.
    @Test func memoryProbe() async throws {
        guard let raw = ProcessInfo.processInfo.environment["BEEPBAR_METADATA_PROBE_MIB"], let mib = Int(raw), mib > 1 else { return }
        let fixture = MetadataFixture(total: mib * 1_048_576, cancellationBoundary: 1_048_576 + MetadataFixture.chunkSize)
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
    let cancellationBoundary: Int?
    let lock = NSLock()
    private var count = 0
    private var cancelled = false
    var sent: Int { lock.withLock { count } }
    var stopped: Bool { lock.withLock { cancelled } }

    init(total: Int, prefix: String = MetadataFixture.siteInfo, length: String? = nil, status: Int = 200, type: String = "application/json", failure: URLError.Code? = nil, cancellationBoundary: Int? = nil) {
        self.total = total; self.prefix = prefix; self.length = length
        self.status = status; self.type = type; self.failure = failure
        self.cancellationBoundary = cancellationBoundary
        stoppedEvent.enter()
    }
    func session() -> URLSession {
        MetadataProtocol.fixture = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetadataProtocol.self]
        return URLSession(configuration: config)
    }
    private let stoppedEvent = DispatchGroup()
    /// Completion can precede URLProtocol.stopLoading. The signal is the handoff; timeout is only a watchdog.
    func waitForStop() async {
        guard !stopped else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.stoppedEvent.wait(timeout: .now() + 1)
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
        if firstStop { stoppedEvent.leave() }
    }
    /// Hold the fixture's transport window after the decisive chunk. A broken receiver is allowed
    /// to continue after the watchdog, so the base still receives the entire body and fails red.
    func waitAtCancellationBoundary() {
        if sent == cancellationBoundary { _ = stoppedEvent.wait(timeout: .now() + 2) }
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
                fixture.waitAtCancellationBoundary()
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !fixture.stopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { active?.stop() }
}
