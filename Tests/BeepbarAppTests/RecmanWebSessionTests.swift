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

    /// ⌘A, ⌘C, ⌘V, ⌘X and undo/redo work in the sign-in page with no Edit menu around: the web
    /// view handles them itself. Guards the first live sign-in, where a copied password couldn't
    /// be pasted because the process had no main menu to carry ⌘V.
    @Test func theSignInPageTakesEditingShortcutsWithoutAMenu() async throws {
        func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
        }
        #expect(RecmanSignInWebView.editingAction(for: key("v")) == #selector(NSText.paste(_:)))
        #expect(RecmanSignInWebView.editingAction(for: key("c")) == #selector(NSText.copy(_:)))
        #expect(RecmanSignInWebView.editingAction(for: key("x")) == #selector(NSText.cut(_:)))
        #expect(RecmanSignInWebView.editingAction(for: key("Z", [.command, .shift])) == Selector(("redo:")))
        // Only the plain shortcuts: ⌥⌘V, ⌘Q or a bare "v" keep their usual meaning.
        #expect(RecmanSignInWebView.editingAction(for: key("v", [.command, .option])) == nil)
        #expect(RecmanSignInWebView.editingAction(for: key("q")) == nil)
        #expect(RecmanSignInWebView.editingAction(for: key("v", [])) == nil)

        // On a real page: ⌘A selects what is typed in the focused field.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = RecmanSignInWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<input id='password' value='typed-secret'>", baseURL: URL(string: "https://aunicalogin.polimi.it/")!)
        await loaded.wait()
        _ = try await webView.evaluateJavaScript("(() => { const f = document.getElementById('password'); f.focus(); f.setSelectionRange(3, 3); return 'ok' })()")
        #expect(webView.performKeyEquivalent(with: key("a")))
        var selection = ""
        for _ in 0..<40 {
            selection = try await webView.evaluateJavaScript("(() => { const f = document.getElementById('password'); return f.selectionStart + '-' + f.selectionEnd })()") as? String ?? ""
            if selection == "0-12" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(selection == "0-12")
    }

    @MainActor private final class PageLoad: NSObject, WKNavigationDelegate {
        private var finished = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            if finished { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            waiter?.resume()
            waiter = nil
        }
    }
}

