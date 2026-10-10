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


/// A page script that never answers no longer holds an operation hostage (#112). Before, the
/// session waited for WebKit's callback alone: a Promise that never settled kept a search or a
/// playback request suspended, and `close()`, a newer operation or the controller cancelling its
/// worker could not end it.
///
/// Each test opens an isolated session on its blank page (a non-persistent store, no network, no
/// Polimi session) and runs scripts through `runScript`, which starts an operation exactly as the
/// archive operations do. `callAsyncJavaScript` (the form with arguments) waits for a returned
/// Promise, which is how a script is made to never answer.
@MainActor
struct RecmanWebSessionScriptTests {
    /// A Promise that never settles. WebKit never answers it on its own within `interruptBound`
    /// (`aStalledScriptStaysPendingWithoutAnInterruption` checks that premise).
    private static let stalled = "return new Promise(() => {})"

    /// How soon an interruption must end a stalled script. Interrupted calls end in milliseconds;
    /// without the interruption WebKit has been seen to give up on a stalled Promise by itself
    /// only after about 6 s, so a looser bound could let a removed interruption go unnoticed.
    private static let interruptBound: Duration = .seconds(1)

    private func openSession(scriptTimeout: Duration) async -> RecmanWebSession {
        let session = RecmanWebSession()
        session.scriptTimeout = scriptTimeout
        await session.open(cookies: [])
        return session
    }

    private func start(_ script: String, in session: RecmanWebSession) -> Task<String, Error> {
        Task { try await session.runScript(script, arguments: [:]) }
    }

    /// Returns once `session` is waiting for a script's answer, so an interruption hits a call in
    /// flight rather than one that has not started.
    private func untilPending(_ session: RecmanWebSession) async throws {
        for _ in 0..<300 where !session.hasPendingScript {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.hasPendingScript, "the script never started")
    }

    private func outcome(_ task: Task<String, Error>) async -> String {
        switch await task.result {
        case .success(let answer): "answered \(answer)"
        case .failure(is CancellationError): "cancelled"
        case .failure(let error): "\(error)"
        }
    }

    /// The premise the interruption tests stand on: left alone, a stalled script is still waiting
    /// for WebKit after `interruptBound`. If a WebKit release started answering it sooner, this
    /// fails, rather than the interruption tests passing with their interruption removed.
    @Test(.timeLimit(.minutes(1))) func aStalledScriptStaysPendingWithoutAnInterruption() async throws {
        let session = await openSession(scriptTimeout: .seconds(20))
        defer { session.close() }
        let task = start(Self.stalled, in: session)
        try await untilPending(session)
        try await Task.sleep(for: Self.interruptBound + .milliseconds(500))
        #expect(session.hasPendingScript)
        task.cancel()
        _ = await task.result
    }

    /// The bounded wait changes nothing for scripts that answer: a string comes back from both
    /// WebKit forms, and anything else is still `unrecognized`.
    @Test func scriptsThatAnswerStillAnswer() async throws {
        let session = await openSession(scriptTimeout: .seconds(10))
        defer { session.close() }
        #expect(try await session.runScript("return 'ok'", arguments: [:]) == "ok")
        #expect(try await session.runScript("'plain'") == "plain")
        #expect(try await session.runScript("return Promise.resolve('later')", arguments: [:]) == "later")
        await #expect(throws: RecmanBrowserError.unrecognized) { try await session.runScript("return 42", arguments: [:]) }
        #expect(!session.hasPendingScript)
    }

    /// A script that never answers ends at `scriptTimeout` as `unavailable`, the error a page load
    /// that never finishes gives, so the controller stops instead of waiting forever.
    @Test(.timeLimit(.minutes(1))) func aScriptThatNeverAnswersEndsAtTheTimeout() async throws {
        let session = await openSession(scriptTimeout: .milliseconds(300))
        defer { session.close() }
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: RecmanBrowserError.unavailable) { try await session.runScript(Self.stalled, arguments: [:]) }
        let elapsed = clock.now - started
        #expect(elapsed >= .milliseconds(300))
        #expect(elapsed < .seconds(5))
        #expect(!session.hasPendingScript)
    }

    /// `close()` (Recordings turned off, sign-out, another account) ends a script in flight at
    /// once, well before the timeout.
    @Test(.timeLimit(.minutes(1))) func closingEndsAScriptInFlight() async throws {
        let session = await openSession(scriptTimeout: .seconds(20))
        let task = start(Self.stalled, in: session)
        try await untilPending(session)
        let clock = ContinuousClock()
        let started = clock.now
        session.close()
        #expect(await outcome(task) == "cancelled")
        #expect(clock.now - started < Self.interruptBound)
        #expect(!session.hasPendingScript)
    }

    /// A newer operation (another course, a playback request) ends the previous operation's script
    /// and gets its own answer, not the old one.
    @Test(.timeLimit(.minutes(1))) func aNewOperationEndsThePreviousScript() async throws {
        let session = await openSession(scriptTimeout: .seconds(20))
        defer { session.close() }
        let first = start(Self.stalled, in: session)
        try await untilPending(session)
        let clock = ContinuousClock()
        let started = clock.now
        let second = start("return 'second'", in: session)
        #expect(await outcome(first) == "cancelled")
        #expect(clock.now - started < Self.interruptBound)
        #expect(await outcome(second) == "answered second")
        #expect(!session.hasPendingScript)
    }

    /// Cancelling the task that awaits the script (the controller's `worker?.cancel()`) ends it
    /// at once, and the session keeps working for the next operation.
    @Test(.timeLimit(.minutes(1))) func cancellingTheAwaitingTaskEndsTheScript() async throws {
        let session = await openSession(scriptTimeout: .seconds(20))
        defer { session.close() }
        let task = start(Self.stalled, in: session)
        try await untilPending(session)
        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        #expect(await outcome(task) == "cancelled")
        #expect(clock.now - started < Self.interruptBound)
        #expect(!session.hasPendingScript)
        #expect(try await session.runScript("return 'next'", arguments: [:]) == "next")
    }

    /// An answer WebKit delivers after the call ended (here, after the timeout) is dropped: the
    /// ended call keeps its timeout and records the answer as late, and the next operation gets
    /// its own answer.
    @Test(.timeLimit(.minutes(1))) func anAnswerAfterTheCallEndedIsDropped() async throws {
        let session = await openSession(scriptTimeout: .milliseconds(100))
        defer { session.close() }
        let late = "return new Promise(resolve => setTimeout(() => resolve('late'), 400))"
        await #expect(throws: RecmanBrowserError.unavailable) { try await session.runScript(late, arguments: [:]) }
        let ended = try #require(session.lastScriptCall)
        for _ in 0..<300 where ended.lateSignals.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ended.outcome == .timedOut)
        #expect(ended.lateSignals == [.answered("late")])
        session.scriptTimeout = .seconds(10)
        let next = start("return 'next'", in: session)
        #expect(await outcome(next) == "answered next")
    }

    /// `close()` lets the web view go even while WebKit still holds the callback of a Promise that
    /// never settles: the callback captures the pending call, not the session or its web view.
    @Test(.timeLimit(.minutes(1))) func closingReleasesTheWebViewDespiteAStalledScript() async throws {
        let session = await openSession(scriptTimeout: .seconds(20))
        weak var webView = session.webView
        #expect(webView != nil)
        let task = start(Self.stalled, in: session)
        try await untilPending(session)
        session.close()
        #expect(await outcome(task) == "cancelled")
        for _ in 0..<300 where webView != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(webView == nil)
    }

    /// A page probe that answered is a page with those facts, an unreadable answer a page with
    /// none; one that timed out or was interrupted is fed to the entry as nothing at all.
    @Test func aProbeThatGaveNoAnswerSaysNothingAboutThePage() {
        let url = URL(string: "https://aunicalogin.polimi.it/aunicalogin/aunicalogin.jsp")
        var facts = PolimiPageFacts()
        facts.asksForCredentials = true
        #expect(RecmanWebSession.entryEvent(afterProbe: .success(facts), load: 3, url: url) == .loadFinished(id: 3, url: url, facts: facts))
        #expect(RecmanWebSession.entryEvent(afterProbe: .failure(RecmanBrowserError.unrecognized), load: 3, url: url) == .loadFinished(id: 3, url: url, facts: PolimiPageFacts()))
        #expect(RecmanWebSession.entryEvent(afterProbe: .failure(RecmanBrowserError.unavailable), load: 3, url: url) == nil)
        #expect(RecmanWebSession.entryEvent(afterProbe: .failure(CancellationError()), load: 3, url: url) == nil)
    }

    /// A background entry whose probe of the login page stalls ends as "Polimi isn't responding"
    /// at the deadline, as before scripts were bounded, not as "sign in again": treating the
    /// timeout as a page with no facts would make the login page look like a dead end (#112 review).
    @Test func aStalledProbeOnTheLoginPageEndsAtTheDeadline() {
        let url = URL(string: "https://aunicalogin.polimi.it/aunicalogin/aunicalogin.jsp")
        var navigator = RecmanEntryNavigator(mode: .background)
        #expect(navigator.handle(.loadStarted(id: 1)).isEmpty)
        if let event = RecmanWebSession.entryEvent(afterProbe: .failure(RecmanBrowserError.unavailable), load: 1, url: url) {
            for command in navigator.handle(event) {
                if case .schedulePatience(let id, _) = command { _ = navigator.handle(.patienceElapsed(id: id)) }
            }
        }
        #expect(!navigator.isFinished)
        #expect(navigator.handle(.deadlineElapsed) == [.finish(.timedOut)])
    }
}
