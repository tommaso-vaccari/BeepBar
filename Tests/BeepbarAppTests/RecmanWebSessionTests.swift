import Foundation
import Testing
import WebKit
import BeepbarCore
@testable import BeepbarApp

/// The Polimi session's way through WebKit: saved by `RecmanSessionCodec`, put back into a fresh
/// browser by `RecmanWebSession.open(cookies:)`, read again by `cookies()`. If any attribute is
/// lost on the way, the next launch sends a session Polimi no longer accepts (the user is asked
/// to sign in every time) or sends it where it doesn't belong.
@MainActor
struct RecmanWebSessionTests {
    private let now = Date()

    private func cookie(_ name: String, domain: String, path: String = "/", expires: Date? = nil, httpOnly: Bool = false) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v-\(name)", .domain: domain, .path: path, .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    /// Saved, restored into WebKit, read back and saved again: every attribute that decides
    /// where a cookie goes and how long it lives survives both trips.
    @Test func aSavedSessionComesBackFromWebKitUnchanged() async throws {
        let original = [
            cookie("SSO_LOGIN", domain: "aunicalogin.polimi.it", httpOnly: true),
            cookie("RESTA_CONNESSO", domain: ".polimi.it", expires: now.addingTimeInterval(86_400)),
            cookie("__Host-shib_idp_session", domain: "shibidp.polimi.it", httpOnly: true),
            cookie("JSESSIONID", domain: "onlineservices.polimi.it", path: "/recman_frontend"),
        ]
        let snapshot = try RecmanSessionCodec.decode(RecmanSessionCodec.encode(original, ownerUserID: 7, now: now), now: now)
        let session = RecmanWebSession()
        await session.open(cookies: snapshot.cookies)
        defer { session.close() }
        let restored = try RecmanSessionCodec.decode(RecmanSessionCodec.encode(await session.cookies(), ownerUserID: 7, now: now), now: now)

        func attributes(_ cookies: [HTTPCookie]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: cookies.map { cookie in
                let expiry = cookie.expiresDate.map { String(Int($0.timeIntervalSince1970)) } ?? "session"
                return (cookie.name, "\(cookie.value) \(cookie.domain) \(cookie.path) secure:\(cookie.isSecure) httpOnly:\(cookie.isHTTPOnly) \(expiry)")
            })
        }
        #expect(attributes(restored.cookies) == attributes(snapshot.cookies))
        #expect(restored.cookies.count == 4)
        // Host-only cookies must stay host-only: a leading dot would make WebKit refuse the
        // `__Host-` cookie, and would send the others to every polimi.it site.
        #expect(restored.cookies.first { $0.name == "__Host-shib_idp_session" }?.domain == "shibidp.polimi.it")
    }

    /// Opening starts from an empty browser and closing drops it: turning the feature off, or
    /// another account signing in, leaves no Polimi session behind in memory.
    @Test func openStartsEmptyAndCloseForgetsEverything() async throws {
        let session = RecmanWebSession()
        #expect(session.isOpen == false)
        #expect(await session.cookies().isEmpty)

        await session.open(cookies: [cookie("FIRST", domain: "aunicalogin.polimi.it")])
        #expect(session.isOpen)
        #expect(await session.cookies().map(\.name) == ["FIRST"])

        await session.open(cookies: [cookie("SECOND", domain: "aunicalogin.polimi.it")])
        #expect(await session.cookies().map(\.name) == ["SECOND"])

        session.close()
        #expect(session.isOpen == false)
        #expect(await session.cookies().isEmpty)
        await session.open(cookies: [])
        #expect(await session.cookies().isEmpty)
        session.close()
    }

    /// Only host and path reach the trace: Polimi's query strings carry sign-on tickets.
    @Test func tracesNeverCarryTheQuery() {
        let url = URL(string: "https://onlineservices.polimi.it/recman_frontend/?ticket=ST-secret#frag")!
        #expect(RecmanWebSession.redacted(url) == "https://onlineservices.polimi.it/recman_frontend/")
        #expect(RecmanWebSession.redacted(nil) == "(none)")
        // Java and Shibboleth pages put the session id in the path.
        let pathSession = URL(string: "https://aunicalogin.polimi.it/aunicalogin/aunicalogin.jsp;jsessionid=SECRET?x=1")!
        #expect(RecmanWebSession.redacted(pathSession) == "https://aunicalogin.polimi.it/aunicalogin/aunicalogin.jsp")
        let middle = URL(string: "https://shibidp.polimi.it/idp/profile;jsessionid=SECRET/SAML2/Redirect/SSO")!
        #expect(RecmanWebSession.redacted(middle) == "https://shibidp.polimi.it/idp/profile/SAML2/Redirect/SSO")
    }
}
