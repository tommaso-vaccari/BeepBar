import Foundation
import Testing
@testable import BeepbarCore

/// The Polimi session file. What it guards: a sign-in that doesn't survive a relaunch (the user
/// would be asked every time), a session that outlives its account, and anything but Polimi's own
/// live cookies being written to disk.
struct RecmanSessionCodecTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func cookie(_ name: String, domain: String, path: String = "/", expires: Date? = nil, secure: Bool = true) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v-\(name)", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    /// The single sign-on session cookies (no expiry) are exactly what must come back; expired
    /// cookies and other sites' cookies never reach the file.
    @Test func keepsLivePolimiCookiesAndOnlyThose() throws {
        let cookies = [
            cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it"),
            cookie("RESTA_CONNESSO", domain: ".polimi.it", expires: now.addingTimeInterval(86_400)),
            cookie("__Host-shib_idp_session", domain: "shibidp.polimi.it"),
            cookie("JSESSIONID", domain: "onlineservices.polimi.it", path: "/recman_frontend"),
            cookie("OLD", domain: "aunicalogin.polimi.it", expires: now.addingTimeInterval(-1)),
            cookie("webex", domain: ".webex.com"),
            cookie("lookalike", domain: "evilpolimi.it"),
        ]
        let data = try RecmanSessionCodec.encode(cookies, ownerUserID: 4242, now: now)
        let snapshot = try RecmanSessionCodec.decode(data, now: now)
        #expect(snapshot.ownerUserID == 4242)
        #expect(Set(snapshot.cookies.map(\.name)) == ["SSO_LOGIN", "RESTA_CONNESSO", "__Host-shib_idp_session", "JSESSIONID"])
        let restored = Dictionary(uniqueKeysWithValues: snapshot.cookies.map { ($0.name, $0) })
        // Host-only stays host-only (no leading dot), so `__Host-` cookies stay valid.
        #expect(restored["__Host-shib_idp_session"]?.domain == "shibidp.polimi.it")
        #expect(restored["RESTA_CONNESSO"]?.domain == ".polimi.it")
        #expect(restored["JSESSIONID"]?.path == "/recman_frontend")
        #expect(restored["SSO_LOGIN"]?.isSecure == true)
        #expect(restored["SSO_LOGIN"]?.expiresDate == nil)
        #expect(restored["SSO_LOGIN"]?.value == "v-SSO_LOGIN")
    }

    /// A cookie that expires while the file sits on disk is dropped when it is read back.
    @Test func cookiesThatExpiredSinceSavingAreDropped() throws {
        let data = try RecmanSessionCodec.encode([cookie("SHORT", domain: "aunicalogin.polimi.it", expires: now.addingTimeInterval(60)), cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it")], ownerUserID: 1, now: now)
        let later = try RecmanSessionCodec.decode(data, now: now.addingTimeInterval(120))
        #expect(later.cookies.map(\.name) == ["SSO_LOGIN"])
    }

    /// A file BeepBar can't read, or from a future format, is refused rather than half-used: the
    /// user signs in to Polimi again instead of BeepBar sending a partial session.
    @Test func unreadableOrNewerFilesAreRefused() throws {
        #expect(throws: RecmanSessionCodec.DecodeError.unreadable) { try RecmanSessionCodec.decode(Data("not a plist".utf8)) }
        let newer = try PropertyListSerialization.data(fromPropertyList: ["version": RecmanSessionCodec.currentVersion + 1, "owner": 1, "cookies": []], format: .binary, options: 0)
        #expect(throws: RecmanSessionCodec.DecodeError.unsupportedVersion) { try RecmanSessionCodec.decode(newer) }
        let ownerless = try PropertyListSerialization.data(fromPropertyList: ["version": RecmanSessionCodec.currentVersion, "cookies": []], format: .binary, options: 0)
        #expect(throws: RecmanSessionCodec.DecodeError.unreadable) { try RecmanSessionCodec.decode(ownerless) }
    }
}
