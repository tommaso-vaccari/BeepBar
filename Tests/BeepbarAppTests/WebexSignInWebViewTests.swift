import Foundation
import Network
import Testing
import WebKit
import BeepbarCore
@testable import BeepbarApp

/// The hidden Webex sign-in of native playback (#148), in a real WKWebView with local pages.
///
/// Each test opens an isolated `RecmanWebSession` whose first sign-in load is a local fixture
/// served at the real login address (`startWebexLogin`), so the navigation policy sees Webex's
/// hosts without anything leaving the Mac. As a backstop the store's traffic goes to a proxy on
/// a closed local port: a load a regression lets through fails instead of reaching Webex. The
/// sign-in window is never put on screen (`presentSignInWindow` only counts), so a test run never
/// takes the focus.
///
/// What it guards against: loading Webex's player page in the hidden web view, a sign-in that
/// never ends (a stalled page, a page that needs the user), going off the measured chain while
/// hidden, a stale ticket counting as a finished sign-in, and a sign-in that survives `close()`
/// or a cancelled Play.
@MainActor
struct WebexSignInWebViewTests {
    nonisolated static let uuid = "0123456789abcdef0123456789abcdef"
    nonisolated static let page = "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)"
    nonisolated static let loginURL = URL(string: "https://politecnicomilano.webex.com/webappng/sites/politecnicomilano/login?siteurl=politecnicomilano&email=x%40mail.polimi.it")!

    /// The session's trace and Play-diagnostics lines, collected from whatever context
    /// `traceHandler` is called in.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
        /// The Play diagnostics only (`RecmanWebSession.diagnose`), not the debug trace.
        var diagnostics: [String] { all.filter { $0.hasPrefix("stream: ") } }
    }

    @MainActor final class Harness {
        let session = RecmanWebSession()
        let lines = Lines()
        var windowsShown = 0
        /// Every address the sign-in started (or restarted) its login at.
        var started: [URL] = []

        func open(fixture: String, stall: Duration = .seconds(20), deadline: Duration = .seconds(60), grace: Duration = .milliseconds(300)) async throws {
            try await open(fixtureFor: { _ in fixture }, stall: stall, deadline: deadline, grace: grace)
        }

        /// `fixtureFor` picks the page by the login address it is served at, so a restart
        /// without the email hint can show a different page.
        /// `servedAt`, when set, is where the first page appears to be instead of the login
        /// address (a Polimi page the chain stalled on, say).
        func open(fixtureFor: @escaping (URL) -> String, servedAt: URL? = nil, stall: Duration = .seconds(20), deadline: Duration = .seconds(60), grace: Duration = .milliseconds(300)) async throws {
            session.webexStallTimeout = stall
            session.webexHiddenDeadline = deadline
            session.webexPlaybackGrace = grace
            let lines = lines
            session.traceHandler = { lines.append($0) }
            session.presentSignInWindow = { [weak self] _ in self?.windowsShown += 1 }
            session.startWebexLogin = { [weak self] webView, url in
                let first = self?.started.isEmpty ?? true
                self?.started.append(url)
                webView.loadHTMLString(fixtureFor(url), baseURL: first ? (servedAt ?? url) : url)
            }
            await session.open(cookies: [])
            let store = try #require(session.webView?.configuration.websiteDataStore)
            store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 9))]
        }

        var store: WKHTTPCookieStore { session.webView!.configuration.websiteDataStore.httpCookieStore }

        func start(interactive: Bool = true) -> Task<Void, Error> {
            let session = session
            return Task { try await session.runWebexSignIn(loginURL: WebexSignInWebViewTests.loginURL, interactive: interactive) }
        }

        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<500 where !condition() {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition())
        }

        /// Waits for the web view to settle on the blank page every sign-in ends on.
        func untilBlank() async throws {
            try await until { session.webView?.url?.absoluteString == "about:blank" && session.webView?.isLoading == false }
        }
    }

    static func ticket(_ value: String = "fresh") -> HTTPCookie {
        HTTPCookie(properties: [.name: "ticket", .value: value, .domain: ".webex.com", .path: "/", .secure: "TRUE"])!
    }

    /// How `task` ended. A sign-in still running after `bound` is cancelled, so a regression
    /// that leaves it waiting (for a ticket it never notices, say) fails as "cancelled" instead of
    /// hanging the suite: the time limit alone can't end an unstructured task. The bound is wide
    /// because CI's full parallel suite slows every main-actor step several times over.
    private func outcome(_ task: Task<Void, Error>, within bound: Duration = .seconds(20)) async -> String {
        let watchdog = Task {
            try await Task.sleep(for: bound)
            task.cancel()
        }
        defer { watchdog.cancel() }
        return switch await task.result {
        case .success: "signed in"
        case .failure(is CancellationError): "cancelled"
        case .failure(let error): "\(error)"
        }
    }

    /// Webex sends the web view back to the playback page: the load is cancelled (the player
    /// page never loads) and the ticket that arrives with it ends the sign-in, hidden.
    @Test(.timeLimit(.minutes(1))) func thePlaybackPageIsCancelledAndTheTicketEndsTheSignIn() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        // A long grace: the ticket is set only after the test sees the cancelled page, and on a
        // loaded CI runner that took longer than the default 300 ms grace, which then ended the
        // sign-in as "back at the playback page without a ticket" first.
        try await harness.open(fixture: "<script>setTimeout(() => { location.href = '\(Self.page)' }, 50)</script>", grace: .seconds(30))
        let task = harness.start()
        try await harness.until { harness.session.cancelledPlaybackPages == 1 }
        #expect(harness.session.webView?.url?.absoluteString != Self.page)
        await harness.store.setCookie(Self.ticket())
        #expect(await outcome(task) == "signed in")
        #expect(harness.windowsShown == 0)
        #expect(harness.session.webView?.url?.path.contains("/recording/") != true)
        // No Webex page keeps running once signed in.
        try await harness.untilBlank()
        // The diagnostics say the ticket came with the hop back to the playback page.
        let ended = try #require(harness.lines.diagnostics.last)
        #expect(ended.hasPrefix("stream: step=sign-in ended result=ticket at-playback-page window=hidden"), "\(ended)")
        #expect(ended.contains("politecnicomilano.webex.com(playback)"), "\(ended)")
    }

    /// A ticket set in the middle of the chain is seen through the cookie store's own change
    /// notification, without waiting for a page to finish.
    ///
    /// The ticket is set only once the page has finished and its probe ran (its "loaded" trace
    /// line, #223): from then on no page event is left to find it, so only the cookie-store
    /// observer can end the sign-in. A fixed sleep let a loaded runner set the ticket before the
    /// page finished, and `webexPageFinished` found it instead (a vacuous pass). Mutation: empty
    /// `cookiesDidChange` and the sign-in never ends (cancelled after `outcome`'s bound).
    @Test(.timeLimit(.minutes(1))) func aTicketMidChainEndsTheSignIn() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<p>idbroker</p>")
        let task = harness.start()
        try await harness.until { harness.lines.all.contains { $0.hasPrefix("loaded ") && $0.contains("asks credentials false") } }
        await harness.store.setCookie(Self.ticket())
        #expect(await outcome(task) == "signed in")
    }

    /// A page asking for a password needs the user: the window comes up at once (well before the
    /// stall timeout), and closing it cancels the sign-in.
    @Test(.timeLimit(.minutes(1))) func aPasswordPageShowsTheWindowAndClosingItCancels() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<form><input type='password' name='pw'></form>", stall: .seconds(30))
        let task = harness.start()
        try await harness.until { harness.windowsShown == 1 }
        harness.session.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(await outcome(task) == "cancelled")
    }

    /// The same page in a sign-in nobody asked for ends as "sign in again", with no window.
    @Test(.timeLimit(.minutes(1))) func aPasswordPageWithoutTheUserNeedsSignIn() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<form><input type='password' name='pw'></form>", stall: .seconds(30))
        #expect(await outcome(harness.start(interactive: false)) == "needsSignIn")
        #expect(harness.windowsShown == 0)
    }

    /// A page where nothing happens (the blank idbroker page a placeholder email stalled on)
    /// becomes the window after the stall timeout, never a silent wait; once the user has the
    /// window, the ticket still ends the sign-in.
    @Test(.timeLimit(.minutes(1))) func aStalledChainHandsOverToTheUser() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<p></p>", stall: .milliseconds(300))
        let task = harness.start()
        try await harness.until { harness.windowsShown == 1 }
        await harness.store.setCookie(Self.ticket())
        #expect(await outcome(task) == "signed in")
    }

    /// The hidden deadline bounds a chain that keeps moving without ending.
    @Test(.timeLimit(.minutes(1))) func aChainThatNeverEndsHitsTheDeadline() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<p></p>", stall: .seconds(30), deadline: .milliseconds(300))
        #expect(await outcome(harness.start(interactive: false)) == "needsSignIn")
    }

    /// Back at the playback page without a ticket: Webex changed, and the browser takes over
    /// rather than the window.
    @Test(.timeLimit(.minutes(1))) func thePlaybackPageWithoutATicketEndsInTheBrowser() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        // A long stall timeout: with both timers at 300 ms, a loaded CI runner let the stall fire
        // first and bring up the window, which is not the path this test is about.
        try await harness.open(fixture: "<script>location.href = '\(Self.page)'</script>", stall: .seconds(30))
        #expect(await outcome(harness.start()) == "playbackUnavailable")
        #expect(harness.windowsShown == 0)
        #expect(harness.session.cancelledPlaybackPages == 1)
        // Package F diagnostics: this way to the browser is named as such, so a user's log tells
        // it apart from a refused host or a failed load. Mutation: pass "" as the `reason:` of
        // both `finish` calls that end at the playback page (the grace timer's and
        // `webexLoginNeedsUser`'s; either may fire first here) and the first expectation fails.
        let ended = try #require(harness.lines.diagnostics.last)
        #expect(ended.contains("result=back-at-playback-without-ticket"), "\(ended)")
        #expect(ended.contains("error=playbackUnavailable"), "\(ended)")
        #expect(!ended.contains(Self.uuid) && !ended.contains("recording/"), "no address in the log: \(ended)")
    }

    /// Hidden, a host off the measured chain is refused and ends the sign-in (browser fallback).
    @Test(.timeLimit(.minutes(1))) func aHostOffTheChainEndsTheSignIn() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<script>location.href = 'https://evil.example/collect'</script>")
        #expect(await outcome(harness.start()) == "playbackUnavailable")
        #expect(harness.windowsShown == 0)
        // A failed sign-in leaves no Webex page running either.
        try await harness.untilBlank()
        // Package F diagnostics: the refused hop is named by kind of host, never by address,
        // and nothing of the login URL (which carries the email hint) reaches any line.
        let ended = try #require(harness.lines.diagnostics.last)
        #expect(ended.contains("result=refused-host host=other-host"), "\(ended)")
        #expect(ended.contains("other-host(refused)"), "\(ended)")
        for line in harness.lines.diagnostics {
            #expect(!line.contains("evil.example") && !line.contains("collect") && !line.contains("%40") && !line.contains("@"), "\(line)")
        }
    }

    /// `close()` and a cancelled Play both end a sign-in in flight at once. Each waits until the
    /// sign-in has started its login page (`started`), not for a fixed time (#223), so the close
    /// or cancel really lands on a running sign-in.
    @Test(.timeLimit(.minutes(1))) func closingOrCancellingEndsTheSignIn() async throws {
        let first = Harness()
        try await first.open(fixture: "<p></p>")
        let closed = first.start()
        try await first.until { first.started.count == 1 }
        first.session.close()
        #expect(await outcome(closed) == "cancelled")

        let second = Harness()
        defer { second.session.close() }
        try await second.open(fixture: "<p></p>")
        let cancelled = second.start()
        try await second.until { second.started.count == 1 }
        cancelled.cancel()
        #expect(await outcome(cancelled) == "cancelled")
        try await second.untilBlank()
        // The session still works for the next operation.
        #expect(try await second.session.runScript("return 'next'", arguments: [:]) == "next")
    }

    /// A stall hands over to the user on Webex's own login, without the email hint, since the
    /// page it stalled on gives them nothing to act on; with the window up, getting back to the
    /// playback page without a ticket ends the Play in the browser instead of waiting for the
    /// user to close a window that can't help.
    @Test(.timeLimit(.minutes(1))) func aStallRestartsWithoutTheHintAndThePlaybackPageEndsIt() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixtureFor: { url in
            url.query?.contains("email=") == true ? "<p></p>" : "<script>setTimeout(() => { location.href = '\(Self.page)' }, 300)</script>"
        }, stall: .milliseconds(300))
        let task = harness.start()
        try await harness.until { harness.windowsShown == 1 }
        #expect(await outcome(task) == "playbackUnavailable")
        #expect(harness.started.count == 2)
        #expect(harness.started.first?.query?.contains("email=") == true)
        #expect(harness.started.last == WebexSignIn.withoutEmailHint(Self.loginURL))
        #expect(harness.started.last?.query?.contains("email") == false)
        #expect(harness.session.cancelledPlaybackPages == 1)
        try await harness.untilBlank()
    }

    /// A stall on Polimi's side (a 2FA push waiting on the phone) hands over to the user on that
    /// very page: reloading Webex's login there would throw the user's progress away.
    @Test(.timeLimit(.minutes(1))) func aStallOnAPolimiPageKeepsThatPage() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        let polimi = URL(string: "https://aunicalogin.polimi.it/aunicalogin/push.jsp")!
        try await harness.open(fixtureFor: { _ in "<p>Approva la notifica</p>" }, servedAt: polimi, stall: .milliseconds(200))
        let task = harness.start()
        try await harness.until { harness.windowsShown == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.started.count == 1)
        #expect(harness.session.webView?.url == polimi)
        await harness.store.setCookie(Self.ticket())
        #expect(await outcome(task) == "signed in")
    }

    /// A newer operation started while a sign-in runs keeps its page: the ended sign-in must not
    /// blank the page under it (its script would come back unrecognized, or its load wait time
    /// out).
    @Test(.timeLimit(.minutes(1))) func aNewerOperationKeepsItsPageWhenTheSignInEnds() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<p>idbroker</p>")
        let task = harness.start()
        try await harness.until { harness.started.count == 1 && harness.session.webView?.isLoading == false }
        try await Task.sleep(for: .milliseconds(100))
        let href = try await harness.session.runScript("await new Promise(r => setTimeout(r, 300)); return location.href", arguments: [:])
        #expect(href == Self.loginURL.absoluteString)
        #expect(await outcome(task) == "cancelled")
        #expect(harness.session.webView?.url?.absoluteString != "about:blank")
    }

    /// A page that fails to load ends a hidden sign-in as "not responding"; with the window up
    /// it is the user's to retry, and the sign-in goes on.
    @Test(.timeLimit(.minutes(1))) func aFailedLoadEndsAHiddenSignInButNotTheUsers() async throws {
        let unreachable = "<script>setTimeout(() => { location.href = 'https://no-such-host.polimi.it/x' }, 50)</script>"
        let hidden = Harness()
        defer { hidden.session.close() }
        try await hidden.open(fixture: unreachable)
        #expect(await outcome(hidden.start()) == "unavailable")

        let shown = Harness()
        defer { shown.session.close() }
        try await shown.open(fixtureFor: { url in url.query?.contains("email=") == true ? "<p></p>" : unreachable }, stall: .milliseconds(200))
        let task = shown.start()
        try await shown.until { shown.windowsShown == 1 }
        try await Task.sleep(for: .seconds(2))
        await shown.store.setCookie(Self.ticket())
        #expect(await outcome(task) == "signed in")
    }

    /// The web content process ending stops a hidden sign-in; with the window up the login
    /// starts again for the user (unhinted), as the Recman entry does.
    @Test(.timeLimit(.minutes(1))) func aCrashedPageStopsAHiddenSignInOrRestartsTheUsers() async throws {
        let hidden = Harness()
        defer { hidden.session.close() }
        try await hidden.open(fixture: "<p></p>")
        let hiddenTask = hidden.start()
        try await hidden.until { hidden.started.count == 1 }
        hidden.session.webViewWebContentProcessDidTerminate(hidden.session.webView!)
        #expect(await outcome(hiddenTask) == "unavailable")

        let shown = Harness()
        defer { shown.session.close() }
        try await shown.open(fixture: "<form><input type='password'></form>")
        let task = shown.start()
        try await shown.until { shown.windowsShown == 1 }
        shown.session.webViewWebContentProcessDidTerminate(shown.session.webView!)
        #expect(shown.started.count == 2)
        #expect(shown.started.last == WebexSignIn.withoutEmailHint(Self.loginURL))
        await shown.store.setCookie(Self.ticket())
        #expect(await outcome(task) == "signed in")
    }

    /// A transport that never answers, until cancelled.
    final class HangingTransport: WebexHTTPTransport {
        func send(_ request: URLRequest, limit: Int) async throws -> WebexHTTPResponse {
            try await Task.sleep(for: .seconds(120))
            throw URLError(.timedOut)
        }
    }

    /// `close()` and a newer operation end a Play waiting on Webex at once: the request is
    /// cancelled, not left to its timeout.
    @Test(.timeLimit(.minutes(1))) func closingOrANewOperationEndsAStreamWaitingOnWebex() async throws {
        for interruption in ["close", "newer operation"] {
            let session = RecmanWebSession()
            session.webexTransport = HangingTransport()
            await session.open(cookies: [])
            defer { session.close() }
            let task = Task { try await session.stream(player: URL(string: Self.page)!, email: nil) }
            // If the wiring broke, the Play would wait out the transport: the watchdog cancels it
            // after 20 s so the suite doesn't hang, and says it did, which fails the test. A
            // wall-clock bound alone was flaky: CI's loaded runner took 5.6 s for a working close.
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(20)) } catch { return false }
                task.cancel()
                return true
            }
            try await Task.sleep(for: .milliseconds(200))
            let clock = ContinuousClock()
            let started = clock.now
            if interruption == "close" {
                session.close()
            } else {
                _ = try? await session.runScript("'next'")
            }
            let result: String
            do { _ = try await task.value; result = "stream" } catch is CancellationError { result = "cancelled" } catch { result = "\(error)" }
            watchdog.cancel()
            #expect(result == "cancelled", "\(interruption)")
            #expect(await watchdog.value == false, "\(interruption)")
            #expect(clock.now - started < .seconds(15), "\(interruption)")
        }
    }

    /// Forgetting the ticket removes Webex's ticket and nothing else, so a stale ticket can't
    /// make the next sign-in look done before it starts.
    @Test func forgettingTheTicketKeepsEverythingElse() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<p></p>")
        let other = HTTPCookie(properties: [.name: "ticket", .value: "p", .domain: "aunicalogin.polimi.it", .path: "/", .secure: "TRUE"])!
        let access = HTTPCookie(properties: [.name: "accessToken", .value: "a", .domain: ".webex.com", .path: "/", .secure: "TRUE"])!
        for cookie in [Self.ticket("stale"), other, access] { await harness.store.setCookie(cookie) }
        await harness.session.forgetWebexTicket()
        let left = await harness.store.allCookies().map { "\($0.name)@\($0.domain)" }.sorted()
        #expect(left == ["accessToken@.webex.com", "ticket@aunicalogin.polimi.it"])
    }

    /// A Play on a recording whose preview link doesn't name it never starts: nothing loads.
    @Test func aMismatchedRecordingIsUnavailable() async throws {
        let session = RecmanWebSession()
        await session.open(cookies: [])
        defer { session.close() }
        let recording = RecmanRecording(id: "A1", courseCode: "058167", academicYear: 2026, title: "t", recordedAt: Date(), kind: "Lezione", duration: "90 min", size: nil,
                                        previewURL: URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=&transfer_id=B2")!)
        await #expect(throws: RecmanBrowserError.playbackUnavailable) { try await session.stream(for: recording, email: nil) }
    }

    /// Traces mask the recording's uuid in a playback page's path.
    @Test func tracesMaskTheRecordingID() {
        #expect(RecmanWebSession.redacted(URL(string: Self.page)) == "https://politecnicomilano.webex.com")
    }
}
