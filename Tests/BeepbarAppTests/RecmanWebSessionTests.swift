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

    /// A lesson added by its Webex link is its own player link: answered without a web view or an
    /// archive session (the browser is never even opened), and one whose stored link fails the
    /// policy is refused instead of followed. Without the manual branch, the transfer-id check
    /// refuses every manual lesson and Play can never reach Webex.
    @Test func aManualLessonIsItsOwnPlayerLink() async throws {
        let session = RecmanWebSession()
        let link = URL(string: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/0123456789abcdef0123456789abcdef")!
        let lesson = ManualWebexLesson(title: "", courseName: "", link: link, addedAt: now)
        #expect(try await session.playbackURL(for: lesson.recording) == link)
        #expect(session.isOpen == false)
        let tampered = ManualWebexLesson(title: "", courseName: "", link: URL(string: "https://evil.example/ldr.php?RCID=a")!, addedAt: now)
        await #expect(throws: RecmanBrowserError.playbackUnavailable) { try await session.playbackURL(for: tampered.recording) }
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

    /// A web view that has no page yet (right after `open(cookies:)`) or is still loading skips
    /// the archive probe; any page with an address is probed. Guards #174: probing the URL-less
    /// web view ran a script whose answer could not matter, and a cold web process missing the
    /// script deadline (as CI saw for that same fresh session) could end the first Recordings
    /// operation as `unavailable` before it tried to enter. The session's own check is covered
    /// by `aFreshSessionSkipsTheArchiveProbe` and `aLoadedPageIsStillProbedForTheArchive`.
    @Test func theArchiveProbeRunsOnlyOnALoadedPage() throws {
        let archive = try #require(URL(string: "https://\(RecmanURLPolicy.archiveHost)\(RecmanURLPolicy.archivePath)"))
        #expect(!RecmanWebSession.archiveProbeCanAnswer(url: nil, isLoading: false))
        #expect(!RecmanWebSession.archiveProbeCanAnswer(url: nil, isLoading: true))
        #expect(!RecmanWebSession.archiveProbeCanAnswer(url: archive, isLoading: true))
        #expect(RecmanWebSession.archiveProbeCanAnswer(url: archive, isLoading: false))
        // Pages that are not the archive are still probed, so a stalled one keeps ending as
        // `unavailable` inside a search.
        #expect(RecmanWebSession.archiveProbeCanAnswer(url: RecmanWebSession.blankPage, isLoading: false))
        // The skip changes no outcome: a missing address is never the archive.
        #expect(PolimiPage.classify(archive, facts: PolimiPageFacts(hasArchiveForm: true)) == .archive)
        #expect(PolimiPage.classify(nil, facts: PolimiPageFacts(hasArchiveForm: true)) != .archive)
    }

    /// The session's real archive check, right after `open(cookies:)`, answers "not the archive"
    /// without running a script. Fails if `isOnArchive` stops using `archiveProbeCanAnswer`
    /// (#174): the first Recordings operation would again start with a bounded script on an
    /// empty web view. Nothing loads, so nothing reaches polimi.it.
    @Test func aFreshSessionSkipsTheArchiveProbe() async throws {
        let session = RecmanWebSession()
        await session.open(cookies: [])
        defer { session.close() }
        let webView = try #require(session.webView)
        #expect(webView.url == nil)
        #expect(try await session.probeArchive() == false)
        #expect(session.lastScriptCall == nil)
    }

    @Test func tracesNeverCarryTheQuery() {
        for address in [
            "https://user:password@onlineservices.polimi.it/recman_frontend/?ticket=ST-secret#frag",
            "https://onlineservices.polimi.it/aunicalogin.jsp;jsessionid=SECRET",
            "https://onlineservices.polimi.it/mario.rossi@polimi.it/12345678-1234-1234-1234-123456789abc",
            "https://onlineservices.polimi.it/arbitrary-private-course-title/0123456789abcdef0123456789abcdef",
        ] {
            #expect(RecmanWebSession.redacted(URL(string: address)) == "https://onlineservices.polimi.it")
        }
        #expect(RecmanWebSession.redacted(nil) == "(none)")
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
/// Each test loads a local document in an isolated session (a non-persistent store, no network, no
/// Polimi session) and runs scripts through `runScript`, which starts an operation exactly as the
/// archive operations do. `callAsyncJavaScript` (the form with arguments) waits for a returned
/// Promise, which is how a script is made to never answer.
@MainActor
struct RecmanWebSessionScriptTests {
    /// A Promise that never settles, kept reachable from the page's global object. Without that
    /// reference WebKit answers nil by itself as soon as its garbage collector finds the Promise
    /// unreachable: about 6 s on an idle machine, at any moment under load, which made
    /// `aNewOperationEndsThePreviousScript` read `.answered(nil)` in a loaded gate run (#243).
    /// Referenced, it was seen still waiting after 20 s, so only the session can end the call.
    /// The interruption tests still check how the call ended (`.interrupted`): a call that
    /// WebKit ended reads `.answered(nil)`, whatever the timing.
    private static let stalled = "globalThis.beepbarStalled = new Promise(() => {}); return globalThis.beepbarStalled"

    /// A generous finite script timeout bounds a broken interruption:
    /// the distinct `.interrupted` outcome identifies the interruption, so no elapsed-time bound is needed (the old 15 s bound was flaky under a
    /// loaded suite: #243). `call.outcome == .interrupted` says how the call ended.
    private static let fallbackTimeout: Duration = .seconds(90)

    private func openSession(scriptTimeout: Duration) async throws -> RecmanWebSession {
        let session = RecmanWebSession()
        session.scriptTimeout = scriptTimeout
        await session.open(cookies: [])
        do {
            let webView = try #require(session.webView)
            let loaded = ScriptPageLoad()
            let delegate = webView.navigationDelegate
            webView.navigationDelegate = loaded
            defer { webView.navigationDelegate = delegate }
            // Process/document startup is fixture setup, not part of the script's deadline.
            webView.loadHTMLString("<html><body id='script-fixture'></body></html>", baseURL: nil)
            try await loaded.wait()
            return session
        } catch {
            session.close()
            throw error
        }
    }

    /// Temporary navigation delegate used only while `openSession` loads the fixture document.
    /// It reports the first finished or failed load, so a missing or broken document fails setup
    /// within 30 s instead of letting a script start on a web view that has none.
    @MainActor private final class ScriptPageLoad: NSObject, WKNavigationDelegate {
        private var result: Result<Void, Error>?

        func wait() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while result == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(result, "local script fixture did not finish loading").get()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            result = .success(())
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            result = .failure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            result = .failure(error)
        }
    }

    /// Cold WebContent startup belongs to setup, not to a script's deadline: a CI run once had
    /// `scriptsThatAnswerStillAnswer` end as `unavailable` because the first script also paid for
    /// starting WebKit. Fails if the fixture stops loading its document, runs a session script
    /// during setup, or leaves its own navigation delegate in place of the session's.
    @Test func theLocalDocumentIsReadyBeforeTheScriptDeadlineStarts() async throws {
        let session = try await openSession(scriptTimeout: .seconds(10))
        defer { session.close() }
        #expect(session.lastScriptCall == nil)
        #expect(session.webView?.navigationDelegate === session)
        #expect(try await session.runScript("document.readyState + ':' + document.body.id") == "complete:script-fixture")
    }

    /// A page with an address (the local fixture, `about:blank`) is still probed: the check runs
    /// the page-facts script and answers "not the archive". Fails if the #174 skip widens to pages
    /// that have loaded, which would change how a stalled page inside a search ends.
    @Test func aLoadedPageIsStillProbedForTheArchive() async throws {
        let session = try await openSession(scriptTimeout: .seconds(10))
        defer { session.close() }
        #expect(session.webView?.url != nil)
        #expect(try await session.probeArchive() == false)
        #expect(session.lastScriptCall != nil)
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

    /// The call `session` is waiting on, once it is waiting.
    private func pendingCall(_ session: RecmanWebSession) async throws -> BoundedScriptCall<String?> {
        try await untilPending(session)
        return try #require(session.lastScriptCall)
    }

    private func outcome(_ task: Task<String, Error>) async -> String {
        switch await task.result {
        case .success(let answer): "answered \(answer)"
        case .failure(is CancellationError): "cancelled"
        case .failure(let error): "\(error)"
        }
    }

    /// The bounded wait changes nothing for scripts that answer: a string comes back from both
    /// WebKit forms, and anything else is still `unrecognized`.
    @Test func scriptsThatAnswerStillAnswer() async throws {
        let session = try await openSession(scriptTimeout: .seconds(10))
        defer { session.close() }
        #expect(try await session.runScript("return 'ok'", arguments: [:]) == "ok")
        #expect(try await session.runScript("'plain'") == "plain")
        #expect(try await session.runScript("return Promise.resolve('later')", arguments: [:]) == "later")
        await #expect(throws: RecmanBrowserError.unrecognized) { try await session.runScript("return 42", arguments: [:]) }
        #expect(!session.hasPendingScript)
    }

    /// A script that never answers ends at `scriptTimeout` as `unavailable`, the error a page load
    /// that never finishes gives, so the controller stops instead of waiting forever. The lower
    /// bound (it did not end early) is deterministic; the "not forever" half is the time limit.
    @Test(.timeLimit(.minutes(2))) func aScriptThatNeverAnswersEndsAtTheTimeout() async throws {
        let session = try await openSession(scriptTimeout: .milliseconds(300))
        defer { session.close() }
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { try await session.runScript(Self.stalled, arguments: [:]) }
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            task.cancel()
            return true
        }
        await #expect(throws: RecmanBrowserError.unavailable) { try await task.value }
        let elapsed = clock.now - started
        watchdog.cancel()
        #expect(await watchdog.value == false, "script timeout did not fire")
        #expect(session.lastScriptCall?.outcome == .timedOut)
        #expect(elapsed >= .milliseconds(300))
        // No upper bound: the failure guarded against is a wait that never ends, which the
        // watchdog bounds (a 15 s bound failed on loaded runners: #243). The outcome
        // and the lower bound together say the timeout ended it.
        #expect(!session.hasPendingScript)
    }

    /// `close()` (Recordings turned off, sign-out, another account) ends a script in flight. The
    /// script timeout is finite; `close()` must end it (`.interrupted`, not
    /// `.timedOut`); a close that left it waiting eventually reports `.timedOut`.
    @Test(.timeLimit(.minutes(2))) func closingEndsAScriptInFlight() async throws {
        let session = try await openSession(scriptTimeout: Self.fallbackTimeout)
        let task = start(Self.stalled, in: session)
        let call = try await pendingCall(session)
        session.close()
        #expect(await outcome(task) == "cancelled")
        #expect(call.outcome == .interrupted)
        #expect(!session.hasPendingScript)
    }

    /// A newer operation (another course, a playback request) ends the previous operation's script
    /// and gets its own answer, not the old one. The interruption outcome identifies the newer operation as the cause.
    @Test(.timeLimit(.minutes(2))) func aNewOperationEndsThePreviousScript() async throws {
        let session = try await openSession(scriptTimeout: Self.fallbackTimeout)
        defer { session.close() }
        let first = start(Self.stalled, in: session)
        let call = try await pendingCall(session)
        let second = start("return 'second'", in: session)
        #expect(await outcome(first) == "cancelled")
        #expect(call.outcome == .interrupted)
        #expect(await outcome(second) == "answered second")
        #expect(!session.hasPendingScript)
    }

    /// Cancelling the task that awaits the script (the controller's `worker?.cancel()`) ends it
    /// and the session keeps working for the next operation. The interruption outcome identifies cancellation as the cause.
    @Test(.timeLimit(.minutes(2))) func cancellingTheAwaitingTaskEndsTheScript() async throws {
        let session = try await openSession(scriptTimeout: Self.fallbackTimeout)
        defer { session.close() }
        let task = start(Self.stalled, in: session)
        let call = try await pendingCall(session)
        task.cancel()
        #expect(await outcome(task) == "cancelled")
        #expect(call.outcome == .interrupted)
        #expect(!session.hasPendingScript)
        #expect(try await session.runScript("return 'next'", arguments: [:]) == "next")
    }

    /// An answer WebKit delivers after the call ended (here, after the timeout) is dropped: the
    /// ended call keeps its timeout and records the answer as late, and the next operation gets
    /// its own answer.
    @Test(.timeLimit(.minutes(2))) func anAnswerAfterTheCallEndedIsDropped() async throws {
        let session = try await openSession(scriptTimeout: .milliseconds(100))
        defer { session.close() }
        let late = "return new Promise(resolve => { if (globalThis.releaseLate) resolve('late'); else globalThis.resolveLate = resolve; })"
        let task = Task { try await session.runScript(late, arguments: [:]) }
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            task.cancel()
            return true
        }
        await #expect(throws: RecmanBrowserError.unavailable) { try await task.value }
        watchdog.cancel()
        #expect(await watchdog.value == false, "script timeout did not fire")
        let ended = try #require(session.lastScriptCall)
        try #require(ended.outcome == .timedOut)
        let webView = try #require(session.webView)
        webView.evaluateJavaScript("globalThis.releaseLate = true; if (globalThis.resolveLate) globalThis.resolveLate('late')", in: nil, in: .defaultClient, completionHandler: nil)
        let deadline = ContinuousClock.now + .seconds(45)
        while ended.lateSignals.isEmpty && ContinuousClock.now < deadline {
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
    /// The interruption outcome identifies `close()` as the cause.
    @Test(.timeLimit(.minutes(2))) func closingReleasesTheWebViewDespiteAStalledScript() async throws {
        let session = try await openSession(scriptTimeout: Self.fallbackTimeout)
        weak var webView = session.webView
        #expect(webView != nil)
        let task = start(Self.stalled, in: session)
        let call = try await pendingCall(session)
        session.close()
        #expect(await outcome(task) == "cancelled")
        #expect(call.outcome == .interrupted)
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
