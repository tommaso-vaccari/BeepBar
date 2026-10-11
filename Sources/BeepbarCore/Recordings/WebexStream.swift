import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Native recordings playback (#148): the pure half of going from a recording's Webex player link
// to the HLS stream AVPlayer plays, as measured live in docs/recordings-native-playback.md.
//
// 1. `WebexPlayerLink`: the `ldr.php` player link answers a cookie-less, no-follow GET with a
//    302 whose Location is the playback page; its path carries the recording's 32-hex uuid.
// 2. `WebexStreamAPI`: the web player's own JSON API, called with the Webex cookies a browser
//    would send. 200 with `hlsURL` is the stream; 403 is "signed out"; 200 without `hlsURL`
//    is a recording without HLS, for the browser.
// 3. `WebexStreamPolicy`: the only stream addresses BeepBar hands to the player.
// 4. `WebexSignIn` and `WebexSignInNavigation`: the Webex sign-in in the hidden Recman web view,
//    hinted with the user's Polimi email so idbroker skips its email page.
//
// Webex's web-player API is internal and can change without notice, so every function here
// answers "not recognized" for anything it was not written for, and the app then falls back to
// opening the player in the browser, as before #148.
//
// Deliberately Foundation-only: `scripts/recman-probe.sh` compiles this folder on its own.
// The uuid, the stream address, cookie values and the email are never logged: the types that hold
// them print redacted.

/// Polimi's Webex site, the only one these functions accept.
public enum WebexSite {
    public static let host = "politecnicomilano.webex.com"
    public static let name = "politecnicomilano"

    /// https on the default port, no credentials in the URL: the shape every Webex address
    /// BeepBar follows must have. Returns the components with a lowercased host.
    static func safeComponents(_ url: URL) -> URLComponents? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443, components.host?.isEmpty == false else { return nil }
        return components
    }

    /// `webex.com` subdomains only, matched on a label boundary: `nfg1wss.webex.com` is Webex,
    /// `evilwebex.com`, `webex.com.evil.com` and `webex.com.` (trailing dot) are not.
    static func isWebexSubdomain(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host.hasSuffix(".webex.com") else { return false }
        let label = host.dropLast(".webex.com".count)
        return !label.isEmpty && !label.hasPrefix(".") && !label.contains("..")
    }
}

/// A recording's playback page on Polimi's Webex site and the uuid its path carries.
///
/// The uuid is what the stream API is called with; the page is only ever used as the
/// `login_return_url` of a sign-in and is never loaded (it pulls Webex's whole web player).
/// Printing either would leak which recording the user watches, so `description` is redacted.
public struct WebexPlaybackPage: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// 32 lowercase hex characters, exactly as Webex wrote it.
    public let uuid: String
    /// The page itself, absolute.
    public let url: URL

    public var description: String { "WebexPlaybackPage(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// From the player link Recman gives to the recording's playback page, without a web view.
public enum WebexPlayerLink {
    /// The uuid form Webex uses: 32 lowercase hex characters. Uppercase, dashed (8-4-4-4-12) and
    /// shorter ids are refused rather than normalized: a different shape means Webex changed its
    /// URLs, and the browser fallback is safer than guessing.
    static let uuidPattern = "^[0-9a-f]{32}$"

    /// The page, when `url` already is a playback page
    /// (`https://politecnicomilano.webex.com/<…>/recording/playback/<uuid>`). Nil for an
    /// `ldr.php` link (which needs `loaderRequest`) and for anything else.
    public static func playbackPage(fromPlayerURL url: URL) -> WebexPlaybackPage? {
        guard let components = WebexSite.safeComponents(url), components.host?.lowercased() == WebexSite.host else { return nil }
        // The percent-encoded path, so an encoded "/" (`%2F`) can't assemble a playback path out
        // of a single segment.
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // "", …, "recording", "playback", uuid, and an optional trailing "".
        var trimmed = segments
        if trimmed.last == "" { trimmed.removeLast() }
        guard trimmed.count >= 4, trimmed.first == "", !trimmed.dropFirst().contains(""),
              trimmed[trimmed.count - 3] == "recording", trimmed[trimmed.count - 2] == "playback",
              let uuid = trimmed.last, uuid.range(of: uuidPattern, options: .regularExpression) != nil,
              trimmed.allSatisfy({ $0 != "." && $0 != ".." && $0.range(of: #"^[A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil }) else { return nil }
        return WebexPlaybackPage(uuid: uuid, url: url)
    }

    /// The playback page named by a redirect's `Location`, absolute or relative to `base` (the
    /// player link that answered). Nil when it leads anywhere else, including another host.
    public static func playbackPage(fromRedirectLocation location: String, relativeTo base: URL) -> WebexPlaybackPage? {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        return playbackPage(fromPlayerURL: url)
    }

    /// Whether `url` is the `ldr.php` form of the player link (as `RecmanURLPolicy.playbackURL`
    /// accepts it), the one form that needs `loaderRequest` to reach the playback page.
    public static func isLoader(_ url: URL) -> Bool {
        guard RecmanURLPolicy.playbackURL(url) != nil, let components = WebexSite.safeComponents(url) else { return false }
        return components.path == "/politecnicomilano/ldr.php" || components.path == "/ldr.php"
    }

    /// The GET that makes `ldr.php` answer with its redirect. `Accept: */*` is load-bearing:
    /// with a `text/html`-only Accept, Webex answers 200 with a page that doesn't carry the uuid
    /// (Phase 0b). No cookies: the hop doesn't need them, and Webex learns nothing about the
    /// user from it. The caller must not follow redirects.
    public static func loaderRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// Whether `status` is a redirect whose `Location` is worth reading.
    public static func isRedirect(_ status: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(status)
    }
}

/// The cookies a browser would send with a request, restricted to Webex's own.
public enum WebexCookies {
    /// Every unexpired `webex.com` cookie whose domain, path and Secure flag match `url`, as
    /// RFC 6265 would select them. Cookies of other sites (Polimi's single sign-on, trackers)
    /// never reach Webex, even when a lookalike domain would string-match.
    public static func sent(to url: URL, from cookies: [HTTPCookie], now: Date = Date()) -> [HTTPCookie] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), WebexSite.isWebexSubdomain(host) || host == "webex.com" else { return [] }
        let path = components.path.isEmpty ? "/" : components.path
        let secure = components.scheme?.lowercased() == "https"
        return cookies.filter { cookie in
            let rawDomain = cookie.domain.lowercased()
            let domain = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
            guard RecmanSessionCodec.isWebexHost(domain) else { return false }
            // A leading dot marks a domain cookie (sent to subdomains too); without it the cookie
            // is host-only.
            let domainMatches = rawDomain.hasPrefix(".") ? (host == domain || host.hasSuffix("." + domain)) : host == domain
            guard domainMatches, pathMatches(path, cookiePath: cookie.path) else { return false }
            if cookie.isSecure && !secure { return false }
            if let expiry = cookie.expiresDate, expiry <= now { return false }
            return true
        }
    }

    /// RFC 6265 §5.1.4: the cookie path is the request path or a prefix of it ending at a `/`.
    static func pathMatches(_ path: String, cookiePath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        guard path.hasPrefix(cookiePath) else { return false }
        return path.count == cookiePath.count || cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")
    }
}

/// What the stream API answered.
public enum WebexStreamAnswer: Sendable, Equatable {
    /// The HLS playlist (allowed by `WebexStreamPolicy`), with what the API says about the
    /// recording for the player's window. Never log any of them.
    case stream(hls: URL, title: String?, duration: TimeInterval?)
    /// No Webex session: sign in and ask again.
    case signedOut
    /// Something signing in can't fix: open the player in the browser instead.
    case unavailable(WebexStreamUnavailable)
}

public enum WebexStreamUnavailable: Sendable, Equatable {
    /// `preventPlayback`, or `canPlayback` false: the host disabled playback.
    case playbackPrevented
    /// `needPassword` / `passwordProtected`: only Webex's page can ask for it.
    case passwordRequired
    /// A status other than 200 and 403.
    case unexpectedStatus(Int)
    /// Not a JSON object.
    case malformed
    /// More than `WebexStreamAPI.responseLimit` bytes.
    case tooLarge
    /// A 200 without an `hlsURL`: no HLS stream for this recording.
    case noStream
    /// An `hlsURL` that `WebexStreamPolicy` refuses.
    case disallowedStream
}

/// The web player's stream API:
/// `GET https://politecnicomilano.webex.com/webappng/api/v1/recordings/<uuid>/stream?siteurl=politecnicomilano`.
public enum WebexStreamAPI {
    /// The answer is a few tens of KB of JSON; 1 MiB leaves room for growth while keeping a
    /// misbehaving server from filling memory. The transport stops reading past it.
    public static let responseLimit = 1 << 20

    public static func url(for page: WebexPlaybackPage) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = WebexSite.host
        // The uuid is 32 hex characters (checked by `WebexPlayerLink`), so it can't alter the path.
        components.percentEncodedPath = "/webappng/api/v1/recordings/\(page.uuid)/stream"
        components.percentEncodedQuery = "siteurl=\(WebexSite.name)"
        return components.url!
    }

    /// The request with exactly the Webex cookies a browser would send to the API (live probes:
    /// only `ticket` on `.webex.com` matters). The Cookie header is built here and
    /// `httpShouldHandleCookies` is off, so no cookie store adds or keeps anything. The caller
    /// must not follow redirects: a signed-out answer is a 403, never a hop to a login page.
    public static func request(for page: WebexPlaybackPage, cookies: [HTTPCookie], now: Date = Date()) -> URLRequest {
        let url = url(for: page)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let sent = WebexCookies.sent(to: url, from: cookies, now: now)
        if !sent.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: sent) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    /// Reads the API's answer.
    ///
    /// Decided on the HTTP status and on the presence of `hlsURL`, never on `requireLogin`: live,
    /// it read 1 on the signed-in 200 and 0 on the signed-out 403, the opposite of its name.
    /// - 403 with a JSON object: signed out. Its flags are not trusted, since a signed-out
    ///   answer may describe the recording differently; the retry after signing in decides.
    /// - 200 with a JSON object: playback prevented or a password needed → unavailable;
    ///   otherwise an `hlsURL` the policy accepts → stream, one it refuses → unavailable, none →
    ///   unavailable (`noStream`). Live, signed out was only ever a 403 and a `ticket` alone got a
    ///   200, so a 200 without the stream is this recording having no HLS (or a changed answer):
    ///   signing in can't fix it, and doing so would cost a hidden sign-in on every Play.
    /// - Anything else, or more than `responseLimit` bytes → unavailable.
    public static func decode(status: Int, data: Data) -> WebexStreamAnswer {
        guard data.count <= responseLimit else { return .unavailable(.tooLarge) }
        guard status == 200 || status == 403 else { return .unavailable(.unexpectedStatus(status)) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unavailable(.malformed) }
        if status == 403 { return .signedOut }
        if flag(json["preventPlayback"]) == true || flag(json["canPlayback"]) == false { return .unavailable(.playbackPrevented) }
        if flag(json["needPassword"]) == true || flag(json["passwordProtected"]) == true { return .unavailable(.passwordRequired) }
        let info = (json["downloadRecordingInfo"] as? [String: Any])?["downloadInfo"] as? [String: Any]
        guard let raw = info?["hlsURL"] as? String, !raw.isEmpty else { return .unavailable(.noStream) }
        guard let hls = URL(string: raw), WebexStreamPolicy.isAllowedStream(hls) else { return .unavailable(.disallowedStream) }
        let title = (json["recordName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .stream(hls: hls, title: title?.isEmpty == false ? title : nil, duration: duration(json["duration"]))
    }

    /// A JSON boolean, also when Webex writes it as 0/1 or "true"/"false". Nil when absent or
    /// anything else, so an unknown value never decides anything.
    static func flag(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            // JSONSerialization gives booleans and numbers alike as NSNumber; true and false
            // read 1 and 0, like Webex's integer flags.
            let double = number.doubleValue
            return double == 0 ? false : (double == 1 ? true : nil)
        case let string as String:
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The recording's length as Webex reports it, in seconds when it is a positive finite
    /// number. The unit is not confirmed live; the player reads the real length from the stream
    /// and this is only a hint for the window before it loads.
    static func duration(_ value: Any?) -> TimeInterval? {
        // A JSON boolean is an NSNumber too, of Objective-C type "c" (char): not a length.
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        let seconds = number.doubleValue
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}

/// The only streams BeepBar hands to AVPlayer.
public enum WebexStreamPolicy {
    /// https on the default port with no credentials, a `webex.com` subdomain on a label boundary
    /// (live: `nfg1wss.webex.com`), and a path ending in `.m3u8`. The address comes from a JSON
    /// answer, so a lookalike host, plain http or another kind of file is refused.
    public static func isAllowedStream(_ url: URL) -> Bool {
        guard let components = WebexSite.safeComponents(url), let host = components.host,
              WebexSite.isWebexSubdomain(host) else { return false }
        return components.percentEncodedPath.lowercased().hasSuffix(".m3u8")
    }
}

/// The Webex sign-in BeepBar runs in the hidden Recman web view, where Polimi's single sign-on
/// cookies already are.
public enum WebexSignIn {
    /// The webappng login page the playback page itself sends a signed-out visitor to (live
    /// chain: playback page → this, with `siteurl`, `viewFrom` and `login_return_url`).
    public static let loginPage = URL(string: "https://politecnicomilano.webex.com/webappng/sites/politecnicomilano/login")!

    /// The login URL, with `email` as the hint that makes idbroker skip its email page and post
    /// straight to Polimi's IdP (live, with a `mail.polimi.it` placeholder), and the playback
    /// page as where Webex returns once signed in. That last hop is cancelled by
    /// `WebexSignInNavigation`, so the player page is never loaded.
    ///
    /// Values are percent-encoded by hand with only RFC 3986 unreserved characters left as is,
    /// so `+`, `&`, `=` and `#` in a value can never add or change a parameter. `viewFrom` is
    /// left out: its live value was not recorded, and the probe's hinted run reached Polimi's IdP
    /// with the parameters below (to confirm live).
    public static func loginURL(playbackPage: WebexPlaybackPage, email: PolimiEmail) -> URL {
        var components = URLComponents(url: loginPage, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = [
            ("siteurl", WebexSite.name),
            ("login_return_url", playbackPage.url.absoluteString),
            ("email", email.value),
        ].map { "\($0.0)=\(encoded($0.1))" }.joined(separator: "&")
        return components.url!
    }

    /// `loginURL` without its `email` parameter: Webex's own login, starting at its email page.
    /// Used when the hinted sign-in stalled and the user takes over in the window.
    public static func withoutEmailHint(_ loginURL: URL) -> URL {
        guard var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false) else { return loginPage }
        let kept = (components.percentEncodedQuery ?? "").split(separator: "&").filter { !$0.hasPrefix("email=") && $0 != "email" }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return components.url ?? loginPage
    }

    /// Whether `url` is a page of Webex's own login (Polimi's Webex site or idbroker), over
    /// https: where a stalled sign-in may be restarted without the hint. Polimi's pages and any
    /// other host are not.
    public static func isWebexLoginPage(_ url: URL?) -> Bool {
        guard let url, let components = WebexSite.safeComponents(url), let host = components.host?.lowercased() else { return false }
        return host == WebexSite.host || WebexSignInNavigation.isIDBroker(host)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Whether `cookie` is Webex's session ticket: `ticket` on the `webex.com` domain (sent to
    /// every Webex subdomain). The only cookie the stream API needs (live).
    public static func isTicket(_ cookie: HTTPCookie) -> Bool {
        cookie.name == "ticket" && [".webex.com", "webex.com"].contains(cookie.domain.lowercased())
    }

    /// Whether the store holds an unexpired, non-empty ticket: the sign-in is done.
    public static func isSignedIn(cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        cookies.contains { isTicket($0) && !$0.value.isEmpty && ($0.expiresDate.map { $0 > now } ?? true) }
    }
}

/// Which loads the hidden web view lets through while it signs in to Webex.
public enum WebexSignInNavigation {
    public enum Decision: Sendable, Equatable {
        case allow
        /// The playback page Webex returns to once signed in: cancel it (never load the player)
        /// and check for the ticket.
        case playbackPage
        /// Not part of the sign-in: cancel it.
        case refuse
    }

    /// - Parameters:
    ///   - mainFrame: the page itself, rather than a frame embedded in it.
    ///   - userDriven: the sign-in window is on screen and the user is driving, so they may be
    ///     sent anywhere Polimi's login uses (SPID, CIE, a 2FA provider), as in a browser.
    ///
    /// Alone, only the hosts of the measured chain load: Polimi's Webex site, idbroker and
    /// Polimi's own login hosts. The playback page is cancelled in every mode.
    ///
    /// Embedded frames from any https host are allowed, as `RecmanNavigationPolicy` allows them:
    /// login pages embed captchas, 2FA widgets and identity-provider helpers from hosts no list
    /// can anticipate, and refusing one breaks the page around it. A frame can't move the page
    /// itself off the chain (that is a main-frame load, checked here), and the playback page is
    /// matched on the main frame because that is the load that would start Webex's player.
    public static func decide(_ url: URL, mainFrame: Bool, userDriven: Bool) -> Decision {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else { return .refuse }
        if scheme == "about" { return .allow }
        guard scheme == "https", components.user == nil, components.password == nil, let host = components.host?.lowercased() else { return .refuse }
        if mainFrame && isPlaybackPage(host: host, path: components.percentEncodedPath) { return .playbackPage }
        if !mainFrame || userDriven { return .allow }
        guard components.port == nil || components.port == 443 else { return .refuse }
        if host == WebexSite.host || isIDBroker(host) || PolimiPage.isPolimiHost(host) { return .allow }
        return .refuse
    }

    /// Any page of Polimi's Webex site whose path has a `recording` segment followed by a
    /// 32-hex id, whatever comes around them: broader than `WebexPlayerLink` on purpose, since
    /// here a false match only cancels a load, while a miss would load Webex's whole player.
    /// The stream API (`…/recordings/<uuid>/stream`) is not a page and doesn't match.
    static func isPlaybackPage(host: String, path: String) -> Bool {
        guard host == WebexSite.host else { return false }
        let segments = path.split(separator: "/").map { $0.lowercased() }
        guard let index = segments.firstIndex(of: "recording") else { return false }
        return segments[(index + 1)...].contains { $0.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }
    }

    /// `idbroker.webex.com` and its regional forms (`idbroker-eu.webex.com`, `idbroker-b-us…`).
    static func isIDBroker(_ host: String) -> Bool {
        host.range(of: #"^idbroker(-[a-z0-9]+)*\.webex\.com$"#, options: .regularExpression) != nil
    }
}
