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

    @MainActor final class Harness {
        let session = RecmanWebSession()
        var windowsShown = 0

        func open(fixture: String, stall: Duration = .seconds(20), deadline: Duration = .seconds(60)) async throws {
            session.webexStallTimeout = stall
            session.webexHiddenDeadline = deadline
            session.presentSignInWindow = { [weak self] _ in self?.windowsShown += 1 }
            session.startWebexLogin = { webView, url in webView.loadHTMLString(fixture, baseURL: url) }
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
    }

    static func ticket(_ value: String = "fresh") -> HTTPCookie {
        HTTPCookie(properties: [.name: "ticket", .value: value, .domain: ".webex.com", .path: "/", .secure: "TRUE"])!
    }

    /// How `task` ended. A sign-in still running after `bound` is cancelled, so a regression
    /// that leaves it waiting (for a ticket it never notices, say) fails as "cancelled" instead of
    /// hanging the suite: the time limit alone can't end an unstructured task.
    private func outcome(_ task: Task<Void, Error>, within bound: Duration = .seconds(10)) async -> String {
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
        try await harness.open(fixture: "<script>setTimeout(() => { location.href = '\(Self.page)' }, 50)</script>")
        let task = harness.start()
        try await harness.until { harness.session.cancelledPlaybackPages == 1 }
        #expect(harness.session.webView?.url?.absoluteString != Self.page)
        await harness.store.setCookie(Self.ticket())
        #expect(await outcome(task) == "signed in")
        #expect(harness.windowsShown == 0)
        #expect(harness.session.webView?.url?.path.contains("/recording/") != true)
    }

    /// A ticket set in the middle of the chain is seen through the cookie store's own change
    /// notification, without waiting for a page to finish.
    @Test(.timeLimit(.minutes(1))) func aTicketMidChainEndsTheSignIn() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<p>idbroker</p>")
        let task = harness.start()
        try await Task.sleep(for: .milliseconds(200))
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
        try await harness.open(fixture: "<script>location.href = '\(Self.page)'</script>", stall: .milliseconds(300))
        #expect(await outcome(harness.start()) == "playbackUnavailable")
        #expect(harness.windowsShown == 0)
        #expect(harness.session.cancelledPlaybackPages == 1)
    }

    /// Hidden, a host off the measured chain is refused and ends the sign-in (browser fallback).
    @Test(.timeLimit(.minutes(1))) func aHostOffTheChainEndsTheSignIn() async throws {
        let harness = Harness()
        defer { harness.session.close() }
        try await harness.open(fixture: "<script>location.href = 'https://evil.example/collect'</script>")
        #expect(await outcome(harness.start()) == "playbackUnavailable")
        #expect(harness.windowsShown == 0)
    }

    /// `close()` and a cancelled Play both end a sign-in in flight at once.
    @Test(.timeLimit(.minutes(1))) func closingOrCancellingEndsTheSignIn() async throws {
        let first = Harness()
        try await first.open(fixture: "<p></p>")
        let closed = first.start()
        try await Task.sleep(for: .milliseconds(100))
        first.session.close()
        #expect(await outcome(closed) == "cancelled")

        let second = Harness()
        defer { second.session.close() }
        try await second.open(fixture: "<p></p>")
        let cancelled = second.start()
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        #expect(await outcome(cancelled) == "cancelled")
        // The session still works for the next operation.
        #expect(try await second.session.runScript("return 'next'", arguments: [:]) == "next")
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
        #expect(RecmanWebSession.redacted(URL(string: Self.page)) == "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/<id>")
    }
}
