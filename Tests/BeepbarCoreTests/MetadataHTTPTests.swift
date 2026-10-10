// This socket fixture verifies Apple's CFNetwork behavior, including authentication and
// transparent gzip. Linux Core checks cover the transport-independent completion protocol.
#if canImport(Darwin)
import Foundation
import Darwin
import Testing
@testable import BeepbarCore

/// Loopback HTTP exercises CFNetwork behavior that a URLProtocol cannot simulate, without real accounts.
@Suite(.serialized) struct MetadataHTTPTests {
    @Test func countsDecompressedBytesRatherThanCompressedLength() async throws {
        // gzip of valid site info padded to 1 MiB + 1; compressed length is much smaller than the cap.
        let compressed = Data(base64Encoded: "H4sIAAAAAAAC/+3BQQrCMBAAwK/InqU9CnlOccGFiqFJ8SD+3btvmJlPnCOPuke7XWPUzPPYo8Vjzj7aur5zy+xLf+31rKVmfC8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAH9+Sw1N8gEAEAA=")!
        let server = try MetadataHTTPServer(status: "200 OK", headers: ["Content-Type": "application/json", "Content-Encoding": "gzip"], body: compressed)
        defer { server.stop() }
        await #expect(throws: WeBeepAPIError.responseTooLarge) {
            try await WeBeepAPIClient(policy: server.policy).validateToken("synthetic-token")
        }
        #expect(compressed.count < 1_048_576)
    }

    @Test func standardSessionStillRefusesRedirects() async throws {
        let server = try MetadataHTTPServer(status: "302 Found", headers: ["Location": "http://127.0.0.1:1/never-follow"])
        defer { server.stop() }
        await #expect(throws: WeBeepAPIError.transport(302)) {
            try await WeBeepAPIClient(policy: server.policy).validateToken("synthetic-token")
        }
    }

    @Test func authenticationChallengesStillReachInjectedSessionDelegate() async throws {
        let server = try MetadataHTTPServer(status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"synthetic\"", "Content-Type": "application/json"])
        defer { server.stop() }
        let delegate = MetadataAuthDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        await #expect(throws: CancellationError.self) {
            try await WeBeepAPIClient(policy: server.policy, session: session).validateToken("synthetic-token")
        }
        #expect(delegate.challenges == 1)
    }
}

private final class MetadataAuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var challenges: Int { lock.withLock { count } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.withLock { count += 1 }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

/// A single isolated socket returns one synthetic response and closes; no persistent server/process.
private final class MetadataHTTPServer: @unchecked Sendable {
    let policy: WeBeepServerPolicy
    private let fd: Int32
    private let finished = DispatchSemaphore(value: 0)

    init(status: String, headers: [String: String], body: Data = Data()) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw CocoaError(.fileReadUnknown) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard named == 0 else { close(fd); throw CocoaError(.fileReadUnknown) }
        let port = Int(UInt16(bigEndian: address.sin_port))
        policy = WeBeepServerPolicy(endpoint: URL(string: "http://127.0.0.1:\(port)/metadata")!, siteURL: WeBeepServerPolicy.production.siteURL, scheme: "http", host: "127.0.0.1", port: port)
        self.fd = fd
        let header = "HTTP/1.1 \(status)\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = Data(header.utf8) + body
        DispatchQueue.global().async { [self] in
            defer { finished.signal() }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &buffer, buffer.count, 0)
            response.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let sent = send(client, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    guard sent > 0 else { return }
                    offset += sent
                }
            }
        }
    }
    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
        _ = finished.wait(timeout: .now() + 2)
    }
}

#endif
