import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// From a recording's player link to its stream (#148), over the real `WebexURLSessionTransport`
/// with a local Webex (`WebexStubProtocol`) and a scripted Recman store and sign-in.
///
/// What it guards against: following Webex's redirects (to the player page, or the ticket to
/// another host), sending Polimi's cookies or any cookie to the player link, a sign-in loop when
/// Webex keeps refusing, signing in without an email or when signing in can't help, a stale
/// ticket counting as a finished sign-in, unbounded answers, and a cancelled Play that keeps
/// talking to Webex.
///
/// Serialized: `WebexStubProtocol` has one handler for the process.
@MainActor @Suite(.serialized)
struct WebexStreamResolverTests {
    nonisolated static let uuid = "0123456789abcdef0123456789abcdef"
    nonisolated static let player = URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc123")!
    nonisolated static let page = "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)"
    nonisolated static let api = "https://politecnicomilano.webex.com/webappng/api/v1/recordings/\(uuid)/stream?siteurl=politecnicomilano"
    nonisolated static let hls = "https://nfg1wss.webex.com/nbr/MultiThumbnail/hls.m3u8?trackingID=t-1"
    let email = PolimiEmail("mario.rossi@mail.polimi.it")!

    static func cookie(_ name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"])!
    }

    static let polimi = cookie("SSO_LOGIN", value: "polimi-secret", domain: "aunicalogin.polimi.it")
    static let idbroker = cookie("amlbcookie", value: "idb", domain: "idbroker-eu.webex.com")

    /// The Recman store and sign-in, as the resolver sees them.
    @MainActor final class FakeBrowser {
        var cookies: [HTTPCookie]
        /// What a sign-in leaves in the store.
        var cookiesAfterSignIn: [HTTPCookie]?
        var signInError: Error?
        /// Set to false to act as a newer operation taking over.
        var isCurrent = true
        var supersedeDuringSignIn = false
        private(set) var events: [String] = []
        private(set) var signIns: [URL] = []

        init(cookies: [HTTPCookie]) { self.cookies = cookies }

        var driver: WebexSignInDriver {
            WebexSignInDriver(
                cookies: { self.cookies },
                forgetTicket: {
                    self.events.append("forget")
                    self.cookies.removeAll(where: WebexSignIn.isTicket)
                },
                signIn: { url in
                    self.events.append("signIn")
                    self.signIns.append(url)
                    if self.supersedeDuringSignIn { self.isCurrent = false }
                    if let error = self.signInError { throw error }
                    if let after = self.cookiesAfterSignIn { self.cookies = after }
                },
                ensureCurrent: {
                    try Task.checkCancellation()
                    guard self.isCurrent else { throw CancellationError() }
                })
        }
    }

    private func resolver() -> WebexStreamResolver {
        WebexStreamResolver(transport: WebexStubProtocol.makeTransport())
    }

    private func signedInBody(extra: [String: Any] = [:]) -> Data {
        var body: [String: Any] = ["requireLogin": 1, "canPlayback": true, "preventPlayback": false, "needPassword": false, "passwordProtected": false,
                                   "downloadRecordingInfo": ["downloadInfo": ["hlsURL": Self.hls, "mp4URL": "https://nfg1wss.webex.com/x.mp4"]],
                                   "duration": 8160, "recordName": "Lezione sintetica"]
        extra.forEach { body[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    nonisolated private static let signedOutBody = try! JSONSerialization.data(withJSONObject: ["requireLogin": 0, "canPlayback": false, "preventPlayback": false])

    /// Webex as measured: ldr.php redirects to the playback page; the API answers 200 to
    /// `ticket=fresh` and 403 to anything else; the playback page itself answers 200 (so a
    /// followed redirect would show up as a request for it).
    private func liveWebex(ldr: WebexStubProtocol.Reply? = nil, api: WebexStubProtocol.Reply? = nil) {
        let signedIn = signedInBody()
        WebexStubProtocol.reset { request in
            let url = request.url!.absoluteString
            if url.hasPrefix(Self.player.absoluteString) { return ldr ?? .redirect(status: 302, location: Self.page) }
            if url == Self.api {
                if let api { return api }
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                return cookie.contains("ticket=fresh") ? .answer(status: 200, headers: ["Content-Type": "application/json"], body: signedIn)
                    : .answer(status: 403, headers: ["Content-Type": "application/json"], body: Self.signedOutBody)
            }
            return .answer(status: 200, body: Data("<html>player</html>".utf8))
        }
    }

    private var requestedURLs: [String] { WebexStubProtocol.requests.map(\.url.absoluteString) }

    private func outcome(_ work: () async throws -> RecordingStream) async -> String {
        do { return "stream \(try await work().url.absoluteString)" }
        catch is CancellationError { return "cancelled" }
        catch { return "\(error)" }
    }

    // MARK: Happy paths

    /// Two requests: the cookie-less hop with `Accept: */*`, then the API with only the Webex
    /// cookies a browser would send. No sign-in, no request for the player page.
    @Test func aLiveTicketGetsTheStreamInTwoRequests() async throws {
        liveWebex()
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "fresh", domain: ".webex.com"), Self.polimi, Self.idbroker])
        let stream = try await resolver().stream(player: Self.player, email: email, driver: browser.driver)
        #expect(stream == RecordingStream(url: URL(string: Self.hls)!, title: "Lezione sintetica", duration: 8160))
        #expect(requestedURLs == [Self.player.absoluteString, Self.api])
        let (hop, api) = (WebexStubProtocol.requests[0], WebexStubProtocol.requests[1])
        #expect(hop.headers["Cookie"] == nil)
        #expect(hop.headers["Accept"] == "*/*")
        #expect(api.headers["Cookie"] == "ticket=fresh")
        #expect(browser.events.isEmpty)
    }

    /// A player link that already is the playback page skips the hop.
    @Test func aPlaybackPageLinkGoesStraightToTheAPI() async throws {
        liveWebex()
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "fresh", domain: ".webex.com")])
        _ = try await resolver().stream(player: URL(string: Self.page)!, email: email, driver: browser.driver)
        #expect(requestedURLs == [Self.api])
    }

    // MARK: Signing in

    /// Signed out: the stale ticket goes first, then one hinted sign-in, then the API once more
    /// with the new ticket.
    @Test func signedOutSignsInOnceWithTheEmailAndRetries() async throws {
        liveWebex()
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "stale", domain: ".webex.com"), Self.polimi])
        browser.cookiesAfterSignIn = [Self.cookie("ticket", value: "fresh", domain: ".webex.com"), Self.polimi]
        let stream = try await resolver().stream(player: Self.player, email: email, driver: browser.driver)
        #expect(stream.url.absoluteString == Self.hls)
        #expect(browser.events == ["forget", "signIn"])
        let page = try #require(WebexPlayerLink.playbackPage(fromPlayerURL: URL(string: Self.page)!))
        #expect(browser.signIns == [WebexSignIn.loginURL(playbackPage: page, email: email)])
        #expect(requestedURLs == [Self.player.absoluteString, Self.api, Self.api])
        #expect(WebexStubProtocol.requests[1].headers["Cookie"] == "ticket=stale")
        #expect(WebexStubProtocol.requests[2].headers["Cookie"] == "ticket=fresh")
    }

    /// Still refused after signing in: the browser takes over; no second sign-in, no third ask.
    @Test func refusedAgainAfterSigningInEndsInTheBrowser() async throws {
        liveWebex()
        let browser = FakeBrowser(cookies: [])
        browser.cookiesAfterSignIn = [Self.cookie("ticket", value: "still-refused", domain: ".webex.com")]
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "playbackUnavailable")
        #expect(browser.signIns.count == 1)
        #expect(requestedURLs == [Self.player.absoluteString, Self.api, Self.api])
    }

    /// A 200 without the stream is a recording without HLS, not a lapsed session: the browser
    /// takes over at once, the ticket stays and no sign-in runs.
    @Test func a200WithoutTheStreamEndsInTheBrowserWithoutSigningIn() async throws {
        let empty = try JSONSerialization.data(withJSONObject: ["requireLogin": 1, "downloadRecordingInfo": ["downloadInfo": [String: Any]()]])
        liveWebex(api: .answer(status: 200, body: empty))
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "fresh", domain: ".webex.com")])
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "playbackUnavailable")
        #expect(browser.events.isEmpty)
        #expect(browser.cookies.contains(where: WebexSignIn.isTicket))
        #expect(requestedURLs == [Self.player.absoluteString, Self.api])
    }

    /// No email to hint: nothing is attempted; the page asks the user for it.
    @Test func signedOutWithoutAnEmailNeedsTheEmail() async throws {
        liveWebex()
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "stale", domain: ".webex.com")])
        #expect(await outcome { try await resolver().stream(player: Self.player, email: nil, driver: browser.driver) } == "needsEmail")
        #expect(browser.events.isEmpty)
        #expect(requestedURLs == [Self.player.absoluteString, Self.api])
    }

    /// What the sign-in throws (the user is needed but can't be asked, a failed load) passes
    /// through, and the API isn't asked again.
    @Test func aFailedSignInPassesThrough() async throws {
        liveWebex()
        let browser = FakeBrowser(cookies: [])
        browser.signInError = RecmanBrowserError.needsSignIn
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "needsSignIn")
        #expect(requestedURLs == [Self.player.absoluteString, Self.api])
    }

    // MARK: Browser fallback

    /// ldr.php answering 200 (its HTML page) is an unknown layout: no API call, no sign-in.
    @Test func aPlayerLinkThatDoesNotRedirectEndsInTheBrowser() async throws {
        liveWebex(ldr: .answer(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html></html>".utf8)))
        let browser = FakeBrowser(cookies: [])
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "playbackUnavailable")
        #expect(requestedURLs == [Self.player.absoluteString])
        #expect(browser.events.isEmpty)
    }

    /// A redirect anywhere but a Polimi playback page is neither followed nor used.
    @Test func aRedirectOffWebexIsNotFollowed() async throws {
        liveWebex(ldr: .redirect(status: 302, location: "https://evil.example/recording/playback/\(Self.uuid)"))
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "fresh", domain: ".webex.com")])
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "playbackUnavailable")
        #expect(requestedURLs == [Self.player.absoluteString])
    }

    /// An API redirect (to a login page, say) is not followed: the ticket stays with Webex's API.
    @Test func anAPIRedirectIsNotFollowed() async throws {
        liveWebex(api: .redirect(status: 302, location: "https://evil.example/login"))
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "fresh", domain: ".webex.com")])
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "playbackUnavailable")
        #expect(requestedURLs == [Self.player.absoluteString, Self.api])
        #expect(browser.signIns.isEmpty)
    }

    /// Prevented playback can't be fixed by signing in.
    @Test func preventedPlaybackEndsInTheBrowserWithoutSigningIn() async throws {
        liveWebex(api: .answer(status: 200, body: signedInBody(extra: ["preventPlayback": true])))
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "fresh", domain: ".webex.com")])
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "playbackUnavailable")
        #expect(browser.signIns.isEmpty)
    }

    /// An answer past the limit is cut off, whatever its headers say, and ends in the browser.
    @Test func anOversizedAnswerIsCutOff() async throws {
        liveWebex(api: .answer(status: 200, body: Data(repeating: 0x20, count: WebexStreamAPI.responseLimit + 1)))
        let browser = FakeBrowser(cookies: [Self.cookie("ticket", value: "fresh", domain: ".webex.com")])
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "playbackUnavailable")
        #expect(browser.signIns.isEmpty)
    }

    /// Offline is "Polimi isn't responding", not the browser.
    @Test func aNetworkFailureIsUnavailable() async throws {
        liveWebex(ldr: .failure(.notConnectedToInternet))
        let browser = FakeBrowser(cookies: [])
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "unavailable")
    }

    // MARK: Cancellation

    /// Cancelling the Play while the API hangs ends it at once, and nothing follows.
    @Test(.timeLimit(.minutes(1))) func cancellingMidRequestEndsAtOnce() async throws {
        liveWebex(api: .hang)
        let browser = FakeBrowser(cookies: [])
        let resolver = resolver()
        let email = self.email
        let task = Task { try await resolver.stream(player: Self.player, email: email, driver: browser.driver) }
        for _ in 0..<500 where WebexStubProtocol.requests.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(WebexStubProtocol.requests.count == 2)
        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        #expect(await outcome { try await task.value } == "cancelled")
        #expect(clock.now - started < .seconds(5))
        #expect(browser.events.isEmpty)
        #expect(requestedURLs == [Self.player.absoluteString, Self.api])
    }

    /// A newer operation taking over during the sign-in stops the Play before the second ask.
    @Test func aNewerOperationStopsThePlayAfterTheSignIn() async throws {
        liveWebex()
        let browser = FakeBrowser(cookies: [])
        browser.cookiesAfterSignIn = [Self.cookie("ticket", value: "fresh", domain: ".webex.com")]
        browser.supersedeDuringSignIn = true
        #expect(await outcome { try await resolver().stream(player: Self.player, email: email, driver: browser.driver) } == "cancelled")
        #expect(requestedURLs == [Self.player.absoluteString, Self.api])
    }

    // MARK: Transport

    /// The transport stores no cookie Webex sets: the next request carries none.
    @Test func theTransportKeepsNoCookies() async throws {
        WebexStubProtocol.reset { _ in .answer(status: 200, headers: ["Set-Cookie": "ticket=leak; Domain=.webex.com; Path=/; Secure"]) }
        let transport = WebexStubProtocol.makeTransport()
        _ = try await transport.send(URLRequest(url: URL(string: Self.api)!), limit: 1024)
        _ = try await transport.send(URLRequest(url: URL(string: Self.api)!), limit: 1024)
        #expect(WebexStubProtocol.requests.map { $0.headers["Cookie"] } == [nil, nil])
    }

    /// A Content-Length past the limit is refused before reading.
    @Test func theTransportRefusesADeclaredOversizedBody() async throws {
        WebexStubProtocol.reset { _ in .answer(status: 200, headers: ["Content-Length": "4096"], body: Data(repeating: 0x20, count: 4096)) }
        await #expect(throws: WebexTransportError.tooLarge) {
            _ = try await WebexStubProtocol.makeTransport().send(URLRequest(url: URL(string: Self.api)!), limit: 1024)
        }
        WebexStubProtocol.reset { _ in .answer(status: 200, body: Data(repeating: 0x20, count: 1024)) }
        let exact = try await WebexStubProtocol.makeTransport().send(URLRequest(url: URL(string: Self.api)!), limit: 1024)
        #expect(exact.body.count == 1024)
    }
}
