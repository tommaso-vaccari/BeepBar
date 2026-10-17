import Foundation
import os
@testable import BeepbarApp

/// A local Webex for native-playback tests (#148): answers each request from the test's handler
/// and records what was sent. Requests stay in this process; nothing reaches Webex.
///
/// One handler for the whole process: only `WebexStreamResolverTests` uses it, and that suite is
/// `.serialized`, each test calling `reset` first.
final class WebexStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        /// A plain answer.
        case answer(status: Int, headers: [String: String] = [:], body: Data = Data())
        /// A redirect, delivered the way URLSession's own HTTP loader does: the session's
        /// delegate decides whether it is followed. Refused, the redirect response itself is
        /// the answer (with `body`).
        case redirect(status: Int, location: String, body: Data = Data())
        case failure(URLError.Code)
        /// Never answers, until the task is cancelled.
        case hang
    }

    struct Recorded: Sendable, Equatable {
        let url: URL
        let method: String
        let headers: [String: String]
    }

    private struct State {
        var handler: @Sendable (URLRequest) -> Reply = { _ in .answer(status: 404) }
        var requests: [Recorded] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        state.withLock { $0 = State(handler: handler) }
    }

    static var requests: [Recorded] { state.withLock { $0.requests } }

    static func makeTransport() -> WebexURLSessionTransport {
        WebexURLSessionTransport(protocolClasses: [WebexStubProtocol.self])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let url = request.url!
        let handler = Self.state.withLock { state -> @Sendable (URLRequest) -> Reply in
            state.requests.append(Recorded(url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:]))
            return state.handler
        }
        switch handler(request) {
        case .answer(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let location, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            let target = URL(string: location, relativeTo: url)!.absoluteURL
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // Refused, the session takes the redirect response as the answer; followed, it has
            // already stopped this load and ignores the rest.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}
