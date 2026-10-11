import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BeepbarCore

/// The pure half of native playback (#148): from Recman's player link to the HLS stream, and the
/// Webex sign-in around it. Fixtures are shaped exactly as the live probes saw them
/// (docs/recordings-native-playback.md), with synthetic ids, tokens and addresses.
///
/// What they guard against: following a link or a stream address off Webex, sending Polimi's or a
/// lookalike's cookies to Webex, treating Webex's misleading `requireLogin` as the sign-in state,
/// an email that rewrites the login URL, and a playback page slipping through the sign-in (it
/// would load Webex's whole web player in the hidden web view).
struct WebexStreamTests {
    private static let uuid = "0123456789abcdef0123456789abcdef"
    private static let page = "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)"
    private static let loader = URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc123DEF")!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = true, expires: Date? = nil, value: String? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value ?? "v-\(name)", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private func playbackPage() throws -> WebexPlaybackPage {
        let url = try #require(URL(string: Self.page))
        return try #require(WebexPlayerLink.playbackPage(fromPlayerURL: url))
    }

    // MARK: Player link → uuid

    /// The 302 Location of `ldr.php`, absolute or relative to the player link, yields the uuid;
    /// any other host, form of id or path tricks yield nothing, so the browser fallback applies.
    @Test func theRedirectLocationNamesThePlaybackPageOnlyInWebexsExactForm() throws {
        let absolute = WebexPlayerLink.playbackPage(fromRedirectLocation: Self.page, relativeTo: Self.loader)
        #expect(absolute?.uuid == Self.uuid)
        #expect(absolute?.url.absoluteString == Self.page)
        let relative = WebexPlayerLink.playbackPage(fromRedirectLocation: "/recordingservice/sites/politecnicomilano/recording/playback/\(Self.uuid)", relativeTo: Self.loader)
        #expect(relative?.uuid == Self.uuid)
        #expect(relative?.url.host == "politecnicomilano.webex.com")
        // A trailing slash and a query are still the same page.
        #expect(WebexPlayerLink.playbackPage(fromRedirectLocation: Self.page + "/?siteurl=politecnicomilano", relativeTo: Self.loader)?.uuid == Self.uuid)

        let refused = [
            "",
            "https://evil.example/recordingservice/sites/politecnicomilano/recording/playback/\(Self.uuid)",
            "//evil.example/recording/playback/\(Self.uuid)",
            "https://politecnicomilano.webex.com.evil.example/recording/playback/\(Self.uuid)",
            "https://other.webex.com/recordingservice/sites/x/recording/playback/\(Self.uuid)",
            "http://politecnicomilano.webex.com/recording/playback/\(Self.uuid)",
            "https://politecnicomilano.webex.com:8443/recording/playback/\(Self.uuid)",
            "https://user:pw@politecnicomilano.webex.com/recording/playback/\(Self.uuid)",
            // Uppercase, dashed and short ids: not the form Webex uses.
            "https://politecnicomilano.webex.com/recording/playback/\(Self.uuid.uppercased())",
            "https://politecnicomilano.webex.com/recording/playback/01234567-89ab-cdef-0123-456789abcdef",
            "https://politecnicomilano.webex.com/recording/playback/0123456789abcdef",
            "https://politecnicomilano.webex.com/recording/playback/\(Self.uuid)00",
            // The uuid only in the query, the fragment, or an encoded path.
            "https://politecnicomilano.webex.com/login?return=/recording/playback/\(Self.uuid)",
            "https://politecnicomilano.webex.com/login#/recording/playback/\(Self.uuid)",
            "https://politecnicomilano.webex.com/x%2Frecording%2Fplayback%2F\(Self.uuid)",
            "https://politecnicomilano.webex.com/a/../recording/playback/\(Self.uuid)",
            // Something after the id, or the stream API itself.
            "https://politecnicomilano.webex.com/recording/playback/\(Self.uuid)/extra",
            "https://politecnicomilano.webex.com/webappng/api/v1/recordings/\(Self.uuid)/stream",
        ]
        for location in refused {
            #expect(WebexPlayerLink.playbackPage(fromRedirectLocation: location, relativeTo: Self.loader) == nil, "\(location)")
        }
    }

    /// A player link that already is the playback page needs no hop; the ldr.php link does.
    @Test func aPlaybackLinkNeedsNoHopAndOnlyLdrIsALoader() throws {
        let page = try #require(URL(string: Self.page))
        #expect(WebexPlayerLink.playbackPage(fromPlayerURL: page)?.uuid == Self.uuid)
        #expect(WebexPlayerLink.isLoader(page) == false)
        #expect(WebexPlayerLink.playbackPage(fromPlayerURL: Self.loader) == nil)
        #expect(WebexPlayerLink.isLoader(Self.loader))
        #expect(WebexPlayerLink.isLoader(URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a1")!))
        #expect(WebexPlayerLink.isLoader(URL(string: "https://evil.example/ldr.php?RCID=a1")!) == false)
        #expect(WebexPlayerLink.isLoader(URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a1&RCID=b2")!) == false)
    }

    /// The hop is cookie-less and asks with `Accept: */*`: with a text/html-only Accept Webex
    /// answers 200 without the uuid (Phase 0b).
    @Test func theLoaderRequestAcceptsAnythingAndCarriesNoCookies() {
        let request = WebexPlayerLink.loaderRequest(Self.loader)
        #expect(request.url == Self.loader)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect([301, 302, 303, 307, 308].allSatisfy(WebexPlayerLink.isRedirect))
        #expect([200, 204, 304, 403].allSatisfy { !WebexPlayerLink.isRedirect($0) })
    }

    /// Printing a page never shows the uuid or its address.
    @Test func aPlaybackPagePrintsRedacted() throws {
        let page = try playbackPage()
        for text in ["\(page)", String(reflecting: page), { var s = ""; dump(page, to: &s); return s }()] {
            #expect(!text.contains(Self.uuid), "\(text)")
        }
    }

    // MARK: Stream API request

    /// Only the Webex cookies a browser would send reach the API: Polimi's single sign-on,
    /// lookalike domains, other Webex hosts' host-only cookies, a narrower path, and expired
    /// cookies stay out.
    @Test func theAPIRequestCarriesExactlyTheWebexCookiesABrowserWouldSend() throws {
        let request = WebexStreamAPI.request(for: try playbackPage(), cookies: [
            cookie("ticket", domain: ".webex.com"),
            cookie("site", domain: "politecnicomilano.webex.com"),
            cookie("webappng", domain: "politecnicomilano.webex.com", path: "/webappng"),
            cookie("narrower", domain: "politecnicomilano.webex.com", path: "/webappng/api/v2"),
            cookie("prefix", domain: "politecnicomilano.webex.com", path: "/webapp"),
            cookie("idb", domain: "idbroker-eu.webex.com"),
            cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it"),
            cookie("polimi", domain: ".polimi.it"),
            cookie("lookalike", domain: ".evilwebex.com"),
            cookie("suffix", domain: ".webex.com.evil.example"),
            cookie("expired", domain: ".webex.com", expires: now.addingTimeInterval(-1)),
        ], now: now)
        #expect(request.url?.absoluteString == "https://politecnicomilano.webex.com/webappng/api/v1/recordings/\(Self.uuid)/stream?siteurl=politecnicomilano")
        #expect(request.httpMethod == "GET")
        #expect(request.httpShouldHandleCookies == false)
        let sent = (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).split(separator: "=").first.map(String.init) ?? "" }
        #expect(Set(sent) == ["ticket", "site", "webappng"])
    }

    /// No Webex cookie, no Cookie header at all.
    @Test func withoutWebexCookiesTheAPIRequestHasNoCookieHeader() throws {
        let request = WebexStreamAPI.request(for: try playbackPage(), cookies: [cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it")], now: now)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    /// RFC 6265 path matching: a prefix only at a `/` boundary.
    @Test func cookiePathsMatchOnSegmentBoundaries() {
        #expect(WebexCookies.pathMatches("/webappng/api", cookiePath: "/"))
        #expect(WebexCookies.pathMatches("/webappng/api", cookiePath: "/webappng"))
        #expect(WebexCookies.pathMatches("/webappng/api", cookiePath: "/webappng/"))
        #expect(WebexCookies.pathMatches("/webappng", cookiePath: "/webappng"))
        #expect(!WebexCookies.pathMatches("/webappng/api", cookiePath: "/webapp"))
        #expect(!WebexCookies.pathMatches("/webappng", cookiePath: "/webappng/api"))
        // A secure cookie never goes over http.
        let insecure = URL(string: "http://politecnicomilano.webex.com/x")!
        #expect(WebexCookies.sent(to: insecure, from: [cookie("ticket", domain: ".webex.com")], now: now).isEmpty)
        #expect(WebexCookies.sent(to: insecure, from: [cookie("plain", domain: ".webex.com", secure: false)], now: now).count == 1)
        // Nothing is ever selected for a host that isn't Webex.
        #expect(WebexCookies.sent(to: URL(string: "https://evil.example/")!, from: [cookie("ticket", domain: "evil.example")], now: now).isEmpty)
    }

    // MARK: Stream API answer

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// The signed-in 200 as the probe saw it (keys and types; synthetic values).
    private func signedIn(hls: Any? = "https://nfg1wss.webex.com/nbr/MultiThumbnail/hls.m3u8?trackingID=t-1", extra: [String: Any] = [:]) -> [String: Any] {
        var info: [String: Any] = ["mp4URL": "https://nfg1wss.webex.com/nbr/x.mp4", "dashURL": "https://nfg1wss.webex.com/nbr/x.mpd", "audioURL": "https://nfg1wss.webex.com/nbr/x.m4a", "playerCoverURL": "https://nfg1wss.webex.com/c.jpg"]
        if let hls { info["hlsURL"] = hls }
        var body: [String: Any] = [
            "requireLogin": 1, "canPlayback": true, "preventPlayback": false, "passwordProtected": false, "needPassword": false, "preventDownload": false,
            "downloadRecordingInfo": ["downloadInfo": info], "mp4StreamOption": [String: Any](), "duration": 8160, "recordName": "  Lezione sintetica  ",
            "chapterLayout": [Any](), "transcriptStatus": "none", "showAISummary": false,
        ]
        extra.forEach { body[$0.key] = $0.value }
        return body
    }

    /// The signed-out 403 as the probe saw it.
    private var signedOut: [String: Any] {
        ["requireLogin": 0, "canPlayback": false, "preventPlayback": false, "passwordProtected": false, "needPassword": false, "preventDownload": false]
    }

    @Test func aSignedIn200GivesTheStreamWithItsTitleAndLength() throws {
        let answer = WebexStreamAPI.decode(status: 200, data: try json(signedIn()))
        #expect(answer == .stream(hls: URL(string: "https://nfg1wss.webex.com/nbr/MultiThumbnail/hls.m3u8?trackingID=t-1")!, title: "Lezione sintetica", duration: 8160))
    }

    /// Only a 403 is signed out. A 200 without an hlsURL is a recording without HLS: signing in
    /// can't fix it (live, a `ticket` alone always got the 200), so it goes to the browser
    /// instead of costing a hidden sign-in on every Play.
    @Test func onlyA403IsSignedOutAndA200WithoutTheStreamIsUnavailable() throws {
        #expect(WebexStreamAPI.decode(status: 403, data: try json(signedOut)) == .signedOut)
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(hls: nil))) == .unavailable(.noStream))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(hls: ""))) == .unavailable(.noStream))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(hls: 42))) == .unavailable(.noStream))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(["something": "else"])) == .unavailable(.noStream))
    }

    /// `requireLogin` reads 1 on success and 0 on the 403: whatever it says, the status and the
    /// hlsURL decide.
    @Test func requireLoginNeverDecides() throws {
        for value in [0, 1] {
            #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["requireLogin": value]))).isStream, "requireLogin \(value) on 200")
            var forbidden = signedOut
            forbidden["requireLogin"] = value
            #expect(WebexStreamAPI.decode(status: 403, data: try json(forbidden)) == .signedOut, "requireLogin \(value) on 403")
        }
    }

    /// Prevented playback or a password: signing in can't fix it, so the browser takes over.
    @Test func preventedOrPasswordProtectedRecordingsAreUnavailable() throws {
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["preventPlayback": true]))) == .unavailable(.playbackPrevented))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["preventPlayback": 1]))) == .unavailable(.playbackPrevented))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["canPlayback": false]))) == .unavailable(.playbackPrevented))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["needPassword": true]))) == .unavailable(.passwordRequired))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["passwordProtected": "true"]))) == .unavailable(.passwordRequired))
        // Unknown flag values decide nothing.
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["preventPlayback": "maybe", "canPlayback": 7]))).isStream)
    }

    /// Any other status, a body that isn't a JSON object, or an oversized body is unavailable.
    @Test func unexpectedAnswersAreUnavailable() throws {
        #expect(WebexStreamAPI.decode(status: 500, data: try json(signedIn())) == .unavailable(.unexpectedStatus(500)))
        #expect(WebexStreamAPI.decode(status: 302, data: Data()) == .unavailable(.unexpectedStatus(302)))
        #expect(WebexStreamAPI.decode(status: 401, data: try json(signedOut)) == .unavailable(.unexpectedStatus(401)))
        #expect(WebexStreamAPI.decode(status: 200, data: Data("<html>".utf8)) == .unavailable(.malformed))
        #expect(WebexStreamAPI.decode(status: 200, data: Data("[1,2]".utf8)) == .unavailable(.malformed))
        #expect(WebexStreamAPI.decode(status: 403, data: Data("<html>Forbidden</html>".utf8)) == .unavailable(.malformed))
        var huge = try json(signedIn())
        huge.append(Data(repeating: 0x20, count: WebexStreamAPI.responseLimit))
        #expect(WebexStreamAPI.decode(status: 200, data: huge) == .unavailable(.tooLarge))
    }

    /// A stream address the policy refuses never reaches the player.
    @Test func aStreamOffWebexIsUnavailable() throws {
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(hls: "https://evil.example/hls.m3u8"))) == .unavailable(.disallowedStream))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(hls: "http://nfg1wss.webex.com/hls.m3u8"))) == .unavailable(.disallowedStream))
    }

    /// Title and length are hints: absent, blank, boolean or nonsense values become nil.
    @Test func titleAndLengthAreOptionalHints() throws {
        let hls = URL(string: "https://nfg1wss.webex.com/nbr/MultiThumbnail/hls.m3u8?trackingID=t-1")!
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["recordName": "   ", "duration": true]))) == .stream(hls: hls, title: nil, duration: nil))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["recordName": 3, "duration": -5]))) == .stream(hls: hls, title: nil, duration: nil))
        #expect(WebexStreamAPI.decode(status: 200, data: try json(signedIn(extra: ["duration": "8160"]))) == .stream(hls: hls, title: "Lezione sintetica", duration: nil))
    }

    // MARK: Stream policy

    @Test func onlyWebexHLSPlaylistsAreAllowed() {
        let allowed = [
            "https://nfg1wss.webex.com/nbr/MultiThumbnail/hls.m3u8?trackingID=t-1",
            "https://NFG1WSS.WEBEX.COM/nbr/a/HLS.M3U8",
            "https://other-1.webex.com/x.m3u8",
            "https://nfg1wss.webex.com:443/x.m3u8",
        ]
        let refused = [
            "http://nfg1wss.webex.com/x.m3u8",
            "https://webex.com/x.m3u8",
            "https://evilwebex.com/x.m3u8",
            "https://nfg1wss.webex.com.evil.example/x.m3u8",
            "https://webex.com.evil.example/x.m3u8",
            "https://nfg1wss.webex.com./x.m3u8",
            "https://user@nfg1wss.webex.com/x.m3u8",
            "https://u:p@nfg1wss.webex.com/x.m3u8",
            "https://nfg1wss.webex.com:8443/x.m3u8",
            "https://nfg1wss.webex.com/x.mp4",
            "https://nfg1wss.webex.com/x.m3u8.mp4",
            "https://nfg1wss.webex.com/x?file=a.m3u8",
            "https://nfg1wss.webex.com/x#a.m3u8",
            "file:///tmp/x.m3u8",
        ]
        for url in allowed { #expect(WebexStreamPolicy.isAllowedStream(URL(string: url)!), "\(url)") }
        for url in refused { #expect(!WebexStreamPolicy.isAllowedStream(URL(string: url)!), "\(url)") }
    }

    // MARK: Sign-in

    /// The email and the return page go in as query values only: a `+`, `&` or `=` in them can
    /// never add or change a parameter.
    @Test func theLoginURLCarriesTheEmailAsAQueryValue() throws {
        let email = try #require(PolimiEmail("mario.rossi+x@mail.polimi.it"))
        let url = WebexSignIn.loginURL(playbackPage: try playbackPage(), email: email)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "politecnicomilano.webex.com")
        #expect(components.path == "/webappng/sites/politecnicomilano/login")
        let items = components.queryItems ?? []
        #expect(items.map(\.name) == ["siteurl", "login_return_url", "email"])
        #expect(items.first { $0.name == "siteurl" }?.value == "politecnicomilano")
        #expect(items.first { $0.name == "login_return_url" }?.value == Self.page)
        #expect(items.first { $0.name == "email" }?.value == "mario.rossi+x@mail.polimi.it")
        // `+` encoded, so no server reads it as a space; `@` and `/` encoded too.
        #expect(components.percentEncodedQuery?.contains("mario.rossi%2Bx%40mail.polimi.it") == true)
        #expect(WebexSignIn.encoded("a&b=c#d e+f") == "a%26b%3Dc%23d%20e%2Bf")
    }

    /// Signed in means a live, non-empty `ticket` on the `webex.com` domain, nowhere else.
    @Test func signedInMeansATicketOnWebexDotCom() {
        #expect(WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: ".webex.com")], now: now))
        #expect(WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: ".WEBEX.com", expires: now.addingTimeInterval(60))], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: "politecnicomilano.webex.com")], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: "idbroker-eu.webex.com")], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: ".evilwebex.com")], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: ".webex.com.evil.example")], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: ".polimi.it")], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("Ticket", domain: ".webex.com")], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("accessToken", domain: ".webex.com")], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: ".webex.com", expires: now.addingTimeInterval(-1))], now: now))
        #expect(!WebexSignIn.isSignedIn(cookies: [cookie("ticket", domain: ".webex.com", value: "")], now: now))
    }

    // MARK: Sign-in navigation

    /// Alone, only the measured chain loads; the playback page is cancelled in every mode, from
    /// whichever path form Webex uses.
    @Test func theSignInLoadsOnlyTheChainAndNeverThePlaybackPage() {
        func decide(_ url: String, mainFrame: Bool = true, userDriven: Bool = false) -> WebexSignInNavigation.Decision {
            WebexSignInNavigation.decide(URL(string: url)!, mainFrame: mainFrame, userDriven: userDriven)
        }
        let chain = [
            "https://politecnicomilano.webex.com/webappng/sites/politecnicomilano/login?siteurl=politecnicomilano",
            "https://idbroker-eu.webex.com/idb/saml2/jsp/doSSO.jsp",
            "https://idbroker.webex.com/idb/globalLogin",
            "https://idbroker-b-us.webex.com/idb/Consumer/metaAlias/x/sp",
            "https://shibidp.polimi.it/idp/profile/SAML2/POST/SSO",
            "https://aunicalogin.polimi.it/aunicalogin/aunicalogin.jsp",
            "about:blank",
        ]
        for url in chain { #expect(decide(url) == .allow, "\(url)") }
        let playback = [
            Self.page,
            "https://politecnicomilano.webex.com/webappng/sites/politecnicomilano/recording/\(Self.uuid)/playback",
            "https://politecnicomilano.webex.com/webappng/sites/politecnicomilano/recording/playback/\(Self.uuid)?from=login",
            "https://POLITECNICOMILANO.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(Self.uuid.uppercased())",
        ]
        for url in playback {
            #expect(decide(url) == .playbackPage, "\(url)")
            #expect(decide(url, userDriven: true) == .playbackPage, "user driven \(url)")
        }
        let refused = [
            "https://www.webex.com/",
            "https://evil.example/",
            "https://idbroker.webex.com.evil.example/",
            "https://evilidbroker.webex.com/",
            "https://politecnicomilano.webex.com:8443/x",
            "http://politecnicomilano.webex.com/x",
            "https://user@politecnicomilano.webex.com/x",
            "https://evilpolimi.it/",
            "javascript:alert(1)",
        ]
        for url in refused { #expect(decide(url) == .refuse, "\(url)") }
        // The stream API is not a page and doesn't count as one.
        #expect(decide("https://politecnicomilano.webex.com/webappng/api/v1/recordings/\(Self.uuid)/stream") == .allow)
        // Embedded frames load as in the Recman browser; with the window up, the user may go
        // anywhere https, but never over http or with credentials in the URL.
        #expect(decide("https://evil.example/frame", mainFrame: false) == .allow)
        #expect(decide("https://spid.example/", userDriven: true) == .allow)
        #expect(decide("http://spid.example/", userDriven: true) == .refuse)
        #expect(decide("https://u:p@spid.example/", userDriven: true) == .refuse)
    }
}

private extension WebexStreamAnswer {
    var isStream: Bool { if case .stream = self { true } else { false } }
}
