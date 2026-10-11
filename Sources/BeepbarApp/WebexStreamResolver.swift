import Foundation
#if canImport(BeepbarCore)
// `scripts/recman-probe.sh` compiles this file together with Core's Recordings folder into one
// module, where there is no BeepbarCore to import.
import BeepbarCore
#endif

/// A recording's stream, ready for the native player (#148). The URL is a Webex HLS playlist that
/// plays without cookies; title and duration are what Webex says about the recording, for the
/// window before the stream loads. None of them may be logged.
struct RecordingStream: Equatable, Sendable {
    let url: URL
    let title: String?
    let duration: TimeInterval?
}

/// One HTTP answer, as far as native playback reads it.
struct WebexHTTPResponse: Sendable, Equatable {
    let status: Int
    /// The `Location` header, for the player link's redirect.
    let location: String?
    let body: Data
}

/// Sends one request to Webex and returns its answer without following redirects. Tests replace
/// the network with a stub `URLProtocol` through `WebexURLSessionTransport(protocolClasses:)`.
protocol WebexHTTPTransport: Sendable {
    /// Throws `WebexTransportError.tooLarge` past `limit` bytes of body, `URLError` for network
    /// failures and `CancellationError` (or `URLError.cancelled`) when the awaiting task is
    /// cancelled.
    func send(_ request: URLRequest, limit: Int) async throws -> WebexHTTPResponse
}

enum WebexTransportError: Error, Equatable {
    case tooLarge
    case notHTTP
}

/// The real transport: a fresh ephemeral `URLSession` per request that never stores or adds a
/// cookie, never caches, never follows a redirect, and stops reading at the caller's limit.
///
/// - Cookies: `httpShouldSetCookies` off and no cookie storage, so the only cookies sent are the
///   ones the request's own Cookie header carries (`WebexStreamAPI.request`), and whatever Webex
///   sets in its answers is dropped. The Recman web view's store stays the only place that holds
///   the Webex session.
/// - Redirects: `ldr.php`'s 302 is the answer BeepBar reads (its `Location` names the playback
///   page). Following it would load the player page; following an API redirect would send the
///   ticket to wherever it points.
/// - A session per request: nothing outlives a Play, and the session is invalidated before
///   returning, so it holds no task, delegate or socket at rest.
final class WebexURLSessionTransport: WebexHTTPTransport, @unchecked Sendable {
    /// Only set in `init`; `URLSessionConfiguration` is copied by every session made from it.
    private let configuration: URLSessionConfiguration

    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        self.configuration = configuration
    }

    func send(_ request: URLRequest, limit: Int) async throws -> WebexHTTPResponse {
        let refuse = RefuseRedirects()
        let session = URLSession(configuration: configuration, delegate: refuse, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: refuse)
        guard let http = response as? HTTPURLResponse else { throw WebexTransportError.notHTTP }
        if http.expectedContentLength > Int64(limit) { throw WebexTransportError.tooLarge }
        // Counted as received, after decompression: a missing or false Content-Length never lets
        // more than `limit` bytes into memory.
        var body = Data()
        for try await byte in bytes {
            guard body.count < limit else { throw WebexTransportError.tooLarge }
            body.append(byte)
        }
        return WebexHTTPResponse(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"), body: body)
    }

    /// Answers every redirect with "don't follow": the task then completes with the redirect
    /// response itself.
    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}

/// What the resolver needs from the Recman web view, bound to one operation of
/// `RecmanWebSession` (tests pass their own).
@MainActor struct WebexSignInDriver {
    /// Every cookie of the Recman store; the resolver picks the Webex ones.
    var cookies: @MainActor () async -> [HTTPCookie]
    /// Deletes the store's Webex `ticket`, which the API just refused, so the sign-in can't count
    /// the stale one as done.
    var forgetTicket: @MainActor () async -> Void
    /// Signs in through the login URL; returns once a ticket is in the store.
    var signIn: @MainActor (URL) async throws -> Void
    /// Throws `CancellationError` once a newer operation, `close()` or a cancelled task took over.
    var ensureCurrent: @MainActor () throws -> Void
}

/// From a recording's Webex player link to its stream, per docs/recordings-native-playback.md:
///
/// 1. The player link's playback page: taken from the link itself, or from the `Location` of a
///    cookie-less, no-follow GET of `ldr.php` (`WebexPlayerLink`).
/// 2. The stream API with the Webex cookies of the Recman store (`WebexStreamAPI`).
/// 3. Signed out: a Webex sign-in in the Recman web view, hinted with the user's Polimi email,
///    then step 2 once more. Never more than one sign-in per call, so a Webex that keeps
///    refusing ends in the browser instead of a loop.
///
/// Errors, as the Recordings page reads them:
/// - `playbackUnavailable`: anything Webex answered that BeepBar doesn't recognize, or that a
///   sign-in can't fix (prevented playback, a password). The page opens the player in the
///   browser, as before #148.
/// - `needsEmail`: signed out of Webex and no confirmed Polimi email to sign in with.
/// - `unavailable`: the network failed.
/// - `CancellationError`: interrupted. Whatever the sign-in throws passes through
///   (`needsSignIn`, cancellation when the user closes the window).
///
/// The uuid, the stream address, cookies and the email never reach the trace.
@MainActor struct WebexStreamResolver {
    let transport: WebexHTTPTransport
    var trace: @MainActor (String) -> Void = { _ in }

    func stream(player: URL, email: PolimiEmail?, driver: WebexSignInDriver) async throws -> RecordingStream {
        let page = try await playbackPage(for: player, driver: driver)
        switch try await ask(page, driver: driver) {
        case .stream(let stream): return stream
        case .unavailable: throw RecmanBrowserError.playbackUnavailable
        case .signedOut: break
        }
        guard let email else {
            trace("signed out of Webex, and no Polimi email to sign in with")
            throw RecmanBrowserError.needsEmail
        }
        trace("signed out of Webex: signing in")
        await driver.forgetTicket()
        try driver.ensureCurrent()
        try await driver.signIn(WebexSignIn.loginURL(playbackPage: page, email: email))
        try driver.ensureCurrent()
        switch try await ask(page, driver: driver) {
        case .stream(let stream): return stream
        case .signedOut:
            // Signed in, yet refused again: retrying would loop, and the browser may still work.
            trace("still signed out after signing in")
            throw RecmanBrowserError.playbackUnavailable
        case .unavailable: throw RecmanBrowserError.playbackUnavailable
        }
    }

    private enum Answer { case stream(RecordingStream), signedOut, unavailable }

    private func playbackPage(for player: URL, driver: WebexSignInDriver) async throws -> WebexPlaybackPage {
        if let page = WebexPlayerLink.playbackPage(fromPlayerURL: player) { return page }
        guard WebexPlayerLink.isLoader(player) else { throw RecmanBrowserError.playbackUnavailable }
        let response = try await send(WebexPlayerLink.loaderRequest(player), driver: driver)
        guard WebexPlayerLink.isRedirect(response.status), let location = response.location,
              let page = WebexPlayerLink.playbackPage(fromRedirectLocation: location, relativeTo: player) else {
            // A 200 here is Webex's HTML player page: an unknown layout, not a way to the stream.
            trace("player link answered \(response.status) without a playback page")
            throw RecmanBrowserError.playbackUnavailable
        }
        return page
    }

    private func ask(_ page: WebexPlaybackPage, driver: WebexSignInDriver) async throws -> Answer {
        let cookies = await driver.cookies()
        try driver.ensureCurrent()
        let response = try await send(WebexStreamAPI.request(for: page, cookies: cookies), driver: driver)
        switch WebexStreamAPI.decode(status: response.status, data: response.body) {
        case .stream(let hls, let title, let duration):
            trace("stream API answered \(response.status) with a stream")
            return .stream(RecordingStream(url: hls, title: title, duration: duration))
        case .signedOut:
            trace("stream API answered \(response.status): signed out")
            return .signedOut
        case .unavailable(let reason):
            trace("stream API answered \(response.status): \(reason)")
            return .unavailable
        }
    }

    private func send(_ request: URLRequest, driver: WebexSignInDriver) async throws -> WebexHTTPResponse {
        let response: WebexHTTPResponse
        do {
            response = try await transport.send(request, limit: WebexStreamAPI.responseLimit)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch is URLError {
            try driver.ensureCurrent()
            throw RecmanBrowserError.unavailable
        } catch {
            try driver.ensureCurrent()
            throw RecmanBrowserError.playbackUnavailable
        }
        try driver.ensureCurrent()
        return response
    }
}
