import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BeepbarCore

/// The Polimi session file. What it guards: a sign-in that doesn't survive a relaunch (the user
/// would be asked every time), a session that outlives its account, anything but Polimi's and
/// Webex's own live cookies being written to disk, and (v2, issue #148) users of a v1 file being
/// signed out by the format change.
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
            cookie("lookalike", domain: "evilpolimi.it"),
            cookie("other", domain: "example.com"),
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
#if canImport(Darwin)
        // swift-corelibs-foundation drops the Secure attribute when it rebuilds a cookie from properties.
        #expect(restored["SSO_LOGIN"]?.isSecure == true)
#endif
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

    // MARK: - v2 (issue #148)

    /// The bytes a v1 BeepBar wrote, built exactly as its encoder did (version 1, no email key),
    /// so these tests don't depend on the current encoder.
    private func v1File(owner: Int, cookies: [HTTPCookie], extra: [String: Any] = [:]) throws -> Data {
        let values: [[String: Any]] = cookies.compactMap { cookie in
            cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        var plist: [String: Any] = ["version": 1, "owner": owner, "cookies": values]
        plist.merge(extra) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    private func plist(_ data: Data) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The confirmed email survives a save and a read, and the file says it is v2. Guards against
    /// an encoder that drops the email (the user would be asked to confirm it after every launch).
    @Test func v2RoundTripKeepsTheEmail() throws {
        let data = try RecmanSessionCodec.encode([cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it")], ownerUserID: 7, email: "mario.rossi@mail.polimi.it", now: now)
        #expect(try plist(data)["version"] as? Int == 2)
        let snapshot = try RecmanSessionCodec.decode(data, now: now)
        #expect(snapshot.email == "mario.rossi@mail.polimi.it")
        #expect(snapshot.ownerUserID == 7)
        #expect(snapshot.cookies.map(\.name) == ["SSO_LOGIN"])
    }

    /// Without an email (the default, as for callers that predate it) the key is absent rather
    /// than an empty string, and reads back as nil.
    @Test func v2RoundTripWithoutEmail() throws {
        let data = try RecmanSessionCodec.encode([cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it")], ownerUserID: 7, now: now)
        #expect(try plist(data)["email"] == nil)
        #expect(try RecmanSessionCodec.decode(data, now: now).email == nil)
    }

    /// A user updating from a v1 release keeps their Polimi session with no action: the v1 file
    /// decodes with no email, and an email key a v1 file can't legitimately hold is ignored.
    /// Guards against dropping v1 support, which would sign every existing user out.
    @Test func v1FileDecodesWithoutEmail() throws {
        let data = try v1File(owner: 4242, cookies: [
            cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it"),
            cookie("JSESSIONID", domain: "onlineservices.polimi.it", path: "/recman_frontend"),
        ], extra: ["email": "ignored@polimi.it"])
        let snapshot = try RecmanSessionCodec.decode(data, now: now)
        #expect(snapshot.ownerUserID == 4242)
        #expect(snapshot.email == nil)
        #expect(Set(snapshot.cookies.map(\.name)) == ["SSO_LOGIN", "JSESSIONID"])
    }

    /// The migration path: a v1 file, decoded and saved again, becomes a v2 file holding the
    /// same session (and the email once there is one).
    @Test func v1FileIsRewrittenAsV2OnNextSave() throws {
        let old = try RecmanSessionCodec.decode(try v1File(owner: 9, cookies: [cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it")]), now: now)
        let data = try RecmanSessionCodec.encode(old.cookies, ownerUserID: old.ownerUserID, email: "a.b@polimi.it", now: now)
        let raw = try plist(data)
        #expect(raw["version"] as? Int == 2)
        #expect(raw["email"] as? String == "a.b@polimi.it")
        let snapshot = try RecmanSessionCodec.decode(data, now: now)
        #expect(snapshot.ownerUserID == 9)
        #expect(snapshot.cookies.map(\.name) == ["SSO_LOGIN"])
    }

    /// The Webex login is kept, so playback doesn't sign in to Webex after each relaunch; Webex
    /// lookalikes, expired Webex cookies and unrelated sites never reach the file.
    @Test func keepsLiveWebexCookiesButNotLookalikes() throws {
        let cookies = [
            cookie("apex", domain: "webex.com"),
            cookie("dotted", domain: ".webex.com", expires: now.addingTimeInterval(3_600)),
            cookie("site", domain: "polimi.webex.com"),
            cookie("deep", domain: "idbroker.eu.webex.com"),
            cookie("upper", domain: "Polimi.WebEx.com"),
            cookie("expired", domain: "polimi.webex.com", expires: now.addingTimeInterval(-1)),
            cookie("prefix", domain: "evilwebex.com"),
            cookie("suffix", domain: "webex.com.evil.com"),
            cookie("tld", domain: "webex.co"),
            cookie("cisco", domain: "cisco.com"),
        ]
        let data = try RecmanSessionCodec.encode(cookies, ownerUserID: 1, now: now)
        // Checked on the raw file too: what is filtered must never be written, not only hidden on read.
        #expect((try plist(data)["cookies"] as? [[String: Any]])?.count == 5)
        #expect(Set(try RecmanSessionCodec.decode(data, now: now).cookies.map(\.name)) == ["apex", "dotted", "site", "deep", "upper"])
    }

    /// The host predicate on its own, with the label boundary checked on both sides.
    @Test func webexHostMatchesOnALabelBoundary() {
        for host in ["webex.com", "x.webex.com", "polimi.webex.com", "a.b.webex.com", "WEBEX.COM"] {
            #expect(RecmanSessionCodec.isWebexHost(host), "\(host)")
        }
        for host in ["evilwebex.com", "webex.com.evil.com", "webex.co", "webexcom", "xwebex.com", "", "com", "polimi.it"] {
            #expect(!RecmanSessionCodec.isWebexHost(host), "\(host)")
        }
    }

    /// Versions other than 1 and 2 are refused rather than guessed at, so a downgrade never
    /// half-uses a session it doesn't understand.
    @Test func versionsOtherThanV1AndV2AreUnsupported() throws {
        #expect(RecmanSessionCodec.currentVersion == 2)
        for version in [0, 3, 99] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["version": version, "owner": 1, "cookies": [Any]()], format: .binary, options: 0)
            #expect(throws: RecmanSessionCodec.DecodeError.unsupportedVersion) { try RecmanSessionCodec.decode(data) }
        }
    }

    /// A v2 email of the wrong type marks a corrupt file: refused as unreadable, never a crash,
    /// never read as "no email" while trusting the rest.
    @Test func wrongTypedEmailIsUnreadable() throws {
        let values: [Any] = [42, ["a@polimi.it"], Data("a@polimi.it".utf8), true]
        for value in values {
            let data = try PropertyListSerialization.data(fromPropertyList: ["version": 2, "owner": 1, "cookies": [Any](), "email": value], format: .binary, options: 0)
            #expect(throws: RecmanSessionCodec.DecodeError.unreadable) { try RecmanSessionCodec.decode(data) }
        }
    }
}
