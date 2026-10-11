import AppKit
import OSLog
import WebKit
#if canImport(BeepbarCore)
// `scripts/recman-probe.sh` compiles this file together with Core's Recordings folder into one
// module, where there is no BeepbarCore to import.
import BeepbarCore
#endif

/// Why an archive operation stopped, in terms the Recordings page can act on.
enum RecmanBrowserError: Error, Equatable {
    /// The Polimi session is gone: the user has to sign in again.
    case needsSignIn
    /// Offline, a page failed to load, or Polimi didn't answer in time.
    case unavailable
    /// Polimi or the archive didn't look as BeepBar expects: a changed page or an unknown way in.
    case unrecognized
    /// The archive's pages didn't add up to the whole list.
    case incomplete
    /// The archive doesn't list that academic year (yet).
    case yearUnavailable
    /// The recording's player couldn't be found, or Webex answered in a way native playback
    /// doesn't recognize: open the player in the browser instead.
    case playbackUnavailable
    /// Native playback (#148): signed out of Webex, and there is no confirmed Polimi email to
    /// sign in with. The Recordings page asks the user to confirm it, then tries again.
    case needsEmail
}

/// The Recman browser as the Recordings controller sees it. `RecmanWebSession` is the real one;
/// controller tests use a fake.
@MainActor protocol RecmanBrowsing: AnyObject {
    /// Whether `open(cookies:)` ran and `close()` hasn't since.
    var isOpen: Bool { get }
    /// Starts a fresh, empty browser holding `cookies` (the saved Polimi session, if any).
    func open(cookies: [HTTPCookie]) async
    /// The browser's cookies, for saving the Polimi session after a success.
    func cookies() async -> [HTTPCookie]
    /// Gets to the archive with the user's help: a sign-in window appears only if Polimi asks
    /// for the user. Throws `CancellationError` if the user closes it.
    func signIn() async throws
    /// Every recording of one course and year. Never asks the user: a lapsed Polimi session
    /// throws `needsSignIn`.
    func recordings(for key: RecmanCourseKey) async throws -> [RecmanRecording]
    /// The Webex player of a recording, to open in the default browser.
    func playbackURL(for recording: RecmanRecording) async throws -> URL
    /// The recording's stream for the native player (#148): the player link as `playbackURL`
    /// finds it, then Webex's stream API, signing in to Webex once with `email` if needed. Only
    /// for a Play the user asked for: the sign-in window may appear if Webex or Polimi needs the
    /// user. Throws `playbackUnavailable` when the browser should open the player instead.
    func stream(for recording: RecmanRecording, email: PolimiEmail?) async throws -> RecordingStream
    /// Stops whatever is running and discards the browser and its cookies.
    func close()
}

/// The hidden browser that reaches Polimi's lecture-recordings archive (Recman) and reads it.
///
/// Recman has no API and sits behind Polimi's single sign-on, so BeepBar walks the same pages a
/// person would, in a WKWebView that stays hidden unless Polimi needs the user (sign-in, 2FA).
/// How an entry is going is decided page by page by `RecmanEntryNavigator`; what a list of
/// result pages means is decided by `RecmanArchiveListing`. This class only carries events and
/// commands between WebKit and those two, so most of its behavior is tested in Core.
///
/// Lifetime, which keeps BeepBar quiet at rest:
/// - Everything here exists only between `open(cookies:)` and `close()`, which the Recordings
///   page calls when it appears and disappears. Nothing runs or stays in memory otherwise.
/// - The cookie store is non-persistent: WebKit writes nothing to disk, and nothing reaches
///   BeepBar's other web views. The Polimi session survives between uses only as the file the
///   controller saves from `cookies()` after a success (`RecmanSessionCodec`).
/// - Nothing here takes part in quitting. Saving the session at quit is what made "Esci" hang in
///   an earlier attempt at this feature: the session is saved after each success instead.
///
/// One operation runs at a time: starting one interrupts the previous (which throws
/// `CancellationError`), and every step checks it is still the current operation before touching
/// the page, so two operations never drive the web view at once. Interrupting reaches scripts
/// too: a page script still waiting for WebKit's callback ends with the operation (#112).
@MainActor final class RecmanWebSession: NSObject, RecmanBrowsing, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, WKHTTPCookieStoreObserver {
    /// How long a script-triggered page load (a search, "prossima", a preview) may take.
    static let loadTimeout: Duration = .seconds(30)

    /// How long one page script may take to answer. The scripts are synchronous reads and clicks,
    /// so a Promise still pending after this long means a stalled web process or a page the
    /// script was not written for; the operation then ends as `unavailable` instead of waiting
    /// for a callback that may never come (#112). A variable so tests can shorten it.
    var scriptTimeout: Duration = .seconds(10)

    /// Receives one line per step, with addresses reduced to host and path: Polimi's query
    /// strings carry login tickets, which must never be printed or logged. The probe prints
    /// these; the app leaves it nil and they go to the unified log at debug level.
    var traceHandler: ((String) -> Void)?

    private let log = Logger(subsystem: "io.github.tvaccari.beepbar", category: "recordings")
    private var store: WKWebsiteDataStore?
    /// Readable so `scripts/recman-probe` can inspect the live page; only this class drives it.
    private(set) var webView: WKWebView?
    private var window: NSWindow?

    /// Main-frame loads, numbered as `RecmanEntryNavigator` expects: a new number when a load
    /// starts and each time it is redirected, so the facts or a timer of an older page are stale.
    private var loadID = 0
    private var currentNavigation: WKNavigation?

    private var operationID = 0
    private var entry: Entry?
    private var loadWaiter: LoadWaiter?
    private var capturingPlayback = false
    private var capturedPlayback: URL?
    /// Script calls in flight, so `close()`, a new operation and a cancelled task can end them
    /// (#112). Normally one at a time; a list rather than a single slot, so a call could never
    /// interrupt another one by taking its place.
    private var pendingScripts: [BoundedScriptCall<String?>] = []
    /// The most recent script call, kept after it ends so `RecmanWebSessionTests` can see what
    /// WebKit delivered late. Holds only that call's outcome, never the page or the web view.
    private(set) var lastScriptCall: BoundedScriptCall<String?>?

    /// Native playback's HTTP side (#148): the player link's hop and the stream API. Replaced by
    /// tests with a stub `URLProtocol` transport; never the network in a test.
    var webexTransport: WebexHTTPTransport = WebexURLSessionTransport()
    /// The Webex sign-in in progress, if any (see `signInToWebex`).
    private var webexLogin: WebexLogin?
    /// The stream operation's work, so a newer operation or `close()` stops its HTTP requests
    /// at once instead of letting them run to their timeout.
    private var streamWork: Task<RecordingStream, Error>?
    /// How long the hidden Webex sign-in may sit on one page with nothing happening (no load, no
    /// redirect) before it counts as needing the user. The live chain moves every few hundred
    /// milliseconds; a placeholder email stalled forever on a blank idbroker page, which this
    /// turns into the sign-in window instead of a silent wait. A variable so tests can shorten it.
    var webexStallTimeout: Duration = RecmanWebSession.loadTimeout
    /// The most the hidden part of a Webex sign-in may take in total, even while pages keep
    /// moving (a redirect loop never stalls). A silent sign-in took ~7 s live.
    var webexHiddenDeadline: Duration = .seconds(60)
    /// How long the ticket may take to show up once Webex sends the sign-in back to the playback
    /// page. A variable so tests can shorten it.
    var webexPlaybackGrace: Duration = .seconds(5)
    /// Where the web view goes after a Webex sign-in, so no Webex page keeps running.
    static let blankPage = URL(string: "about:blank")!
    /// Starts the Webex sign-in's first load. Tests load a local fixture at the login address
    /// instead, so nothing reaches Webex.
    var startWebexLogin: @MainActor (WKWebView, URL) -> Void = { webView, url in webView.load(URLRequest(url: url)) }
    /// Puts the sign-in window on screen. Tests replace it so a run never takes the focus.
    var presentSignInWindow: @MainActor (NSWindow) -> Void = { window in
        window.center()
        // As in `LoginWindowController.showWindow`: a menu-bar app has to activate itself, or
        // the window shows without keyboard focus and the sign-in fields reject typing.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
    /// Main-frame loads of a Webex playback page cancelled during a sign-in; for tests, which
    /// prove the player page is never loaded.
    private(set) var cancelledPlaybackPages = 0

    var isOpen: Bool { store != nil }

    // MARK: Operations

    func open(cookies: [HTTPCookie]) async {
        close()
        let store = WKWebsiteDataStore.nonPersistent()
        self.store = store
        // The web view exists before the cookies go in: cookies set on a non-persistent store
        // that no web view uses yet have been known not to reach its first requests.
        _ = browser()
        for cookie in cookies {
            await store.httpCookieStore.setCookie(cookie)
        }
        trace("opened with \(cookies.count) cookies")
    }

    func cookies() async -> [HTTPCookie] {
        guard let store else { return [] }
        return await store.httpCookieStore.allCookies()
    }

    func signIn() async throws {
        let operation = beginOperation()
        switch await enter(.interactive, operation: operation) {
        case .archive: return
        case .cancelled: throw CancellationError()
        case .failed: throw RecmanBrowserError.unavailable
        // Interactive entries hand dead ends to the user instead of ending on them.
        case .needsUser, .unrecognized, .timedOut: throw RecmanBrowserError.unrecognized
        }
    }

    /// Reaches the archive without the user (the saved session must still be alive), or throws
    /// as `recordings(for:)` would. `scripts/recman-probe` uses it to time a warm entry alone.
    func reachArchive() async throws {
        let operation = beginOperation()
        try await enterInBackground(operation: operation)
    }

    func recordings(for key: RecmanCourseKey) async throws -> [RecmanRecording] {
        let operation = beginOperation()
        // A second attempt starts over from a fresh entry: the Recman session can lapse between
        // two uses even when the single sign-on is still alive, and the archive then answers a
        // search with its start page or a sign-in redirect.
        for attempt in 1...2 {
            if attempt == 2 {
                trace("search left the archive: starting over")
                try await enterInBackground(operation: operation)
            } else if try await !isOnArchive(operation: operation) {
                try await enterInBackground(operation: operation)
            }
            do {
                return try await search(key, operation: operation)
            } catch is LeftTheSearch where attempt == 1 {
                continue
            } catch is LeftTheSearch {
                throw RecmanBrowserError.unrecognized
            }
        }
        throw RecmanBrowserError.unrecognized
    }

    func playbackURL(for recording: RecmanRecording) async throws -> URL {
        let operation = beginOperation()
        guard RecmanURLPolicy.previewTransferID(recording.previewURL) == recording.id else { throw RecmanBrowserError.playbackUnavailable }
        // The preview link works only inside a live Recman session.
        if try await !isOnArchive(operation: operation) {
            try await enterInBackground(operation: operation)
        }
        capturingPlayback = true
        capturedPlayback = nil
        defer { capturingPlayback = false }
        let waiter = startWaiting()
        defer { stopWaiting(waiter) }
        browser().load(URLRequest(url: recording.previewURL))
        do {
            try await wait(for: waiter, operation: operation)
        } catch RecmanBrowserError.unrecognized {
            // The preview went somewhere the policy refused: not a player BeepBar can open.
            throw RecmanBrowserError.playbackUnavailable
        }
        if let capturedPlayback { return capturedPlayback }
        if let link = URL(string: try await evaluate(RecmanScripts.playbackLink, operation: operation)), let player = RecmanURLPolicy.playbackURL(link) {
            return player
        }
        if PolimiPage.classify(webView?.url, facts: try await pageFacts(operation: operation)) == .needsUser {
            throw RecmanBrowserError.needsSignIn
        }
        throw RecmanBrowserError.playbackUnavailable
    }

    /// Only for a Play the user asked for (#148 package F must never call it in the background):
    /// a sign-in it starts may put the sign-in window on screen.
    func stream(for recording: RecmanRecording, email: PolimiEmail?) async throws -> RecordingStream {
        let player: URL
        do {
            player = try await playbackURL(for: recording)
        } catch {
            diagnose("stream: step=archive-player-link failed error=\(PlaybackDiagnostics.errorName(error))")
            throw error
        }
        diagnose("stream: step=archive-player-link found form=\(WebexPlayerLink.isLoader(player) ? "loader" : "other")")
        return try await stream(player: player, email: email)
    }

    /// The stream of the player link `player`, as an operation of its own: the second half of
    /// `stream(for:email:)`, separate so `RecmanWebSessionTests` can start from a player link
    /// without Polimi's archive.
    func stream(player: URL, email: PolimiEmail?) async throws -> RecordingStream {
        let operation = beginOperation()
        let resolver = WebexStreamResolver(
            transport: webexTransport,
            trace: { [weak self] in self?.trace($0) },
            diagnose: { [weak self] in self?.diagnose($0) })
        let driver = WebexSignInDriver(
            cookies: { [weak self] in await self?.cookies() ?? [] },
            forgetTicket: { [weak self] in await self?.forgetWebexTicket() },
            // A Play is always the user's own request, so the sign-in may show its window.
            signIn: { [weak self] url in
                guard let self else { throw CancellationError() }
                try await self.signInToWebex(loginURL: url, interactive: true, operation: operation)
            },
            ensureCurrent: { [weak self] in
                guard let self else { throw CancellationError() }
                try self.ensureCurrent(operation)
            })
        let work = Task { try await resolver.stream(player: player, email: email, driver: driver) }
        streamWork = work
        defer { if streamWork == work { streamWork = nil } }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: Signing in to Webex

    /// A Webex sign-in in progress (#148): whether the user has the window, and whoever awaits
    /// the outcome. It ends exactly once; later events find it finished and do nothing.
    @MainActor private final class WebexLogin {
        let loginURL: URL
        let interactive: Bool
        /// The sign-in window is up and the user is driving: no more timers, any https page.
        var windowShown = false
        /// Webex sent the web view back to the playback page (cancelled): the chain is over.
        var reachedPlayback = false
        var stall: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var playbackGrace: Task<Void, Never>?
        private(set) var result: Result<Void, Error>?
        /// Why it ended, as a stable word for the Play diagnostics (`signInToWebex` logs it):
        /// which of the many ways out of a sign-in sent a Play to the browser.
        private(set) var endReason: String?
        /// The hosts of the main-frame hops so far (`WebexSignInNavigation.diagnosticHost`, never
        /// an address), consecutive repeats folded and at most `maxTrail`: the diagnostics show
        /// how far along the measured chain (webappng → idbroker → Polimi → back) the sign-in got.
        private(set) var trail: [String] = []
        static let maxTrail = 24
        private var continuation: CheckedContinuation<Void, Error>?

        func noteHop(_ host: String) {
            guard trail.last != host, trail.count < Self.maxTrail else { return }
            trail.append(host)
        }

        init(loginURL: URL, interactive: Bool) {
            self.loginURL = loginURL
            self.interactive = interactive
        }

        var isFinished: Bool { result != nil }

        /// `reason`: a privacy-safe word or two (never an address), see `endReason`.
        func finish(_ result: Result<Void, Error>, reason: String) {
            guard self.result == nil else { return }
            self.result = result
            endReason = reason
            stall?.cancel()
            deadline?.cancel()
            playbackGrace?.cancel()
            continuation?.resume(with: result)
            continuation = nil
        }

        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    /// Deletes the store's Webex `ticket`: the stream API just refused it, and leaving it there
    /// would make the next sign-in look done before it started.
    func forgetWebexTicket() async {
        guard let store else { return }
        for cookie in await store.httpCookieStore.allCookies() where WebexSignIn.isTicket(cookie) {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }

    /// Signs in to Webex in the hidden web view through `loginURL` (`WebexSignIn.loginURL`, which
    /// carries the email hint), and returns once a Webex `ticket` is in the store.
    ///
    /// The store already holds the Polimi single sign-on, so the live chain (webappng login →
    /// idbroker → shibidp/aunicalogin → back) needs nobody. While hidden, only that chain's hosts
    /// load (`WebexSignInNavigation`), and the final hop to the playback page is cancelled in
    /// every case: the player page would pull Webex's whole web app and play audio hidden.
    ///
    /// Done is decided on the cookie store, checked on every load, redirect and cookie change,
    /// never on a polling timer. The user is needed when a page asks for credentials, when the
    /// chain sits still for `webexStallTimeout`, or when it is still hidden after
    /// `webexHiddenDeadline`: an `interactive` sign-in then shows the window (as `signIn()` does)
    /// and waits for the user without a deadline; otherwise it throws `needsSignIn`. A host off
    /// the chain while hidden throws `playbackUnavailable` (browser fallback), a failed load
    /// `unavailable`, and closing the window, `close()`, a newer operation or cancelling the
    /// awaiting task `CancellationError`. Back at the playback page without a ticket after
    /// `webexPlaybackGrace`, it throws `playbackUnavailable` whoever is driving. Whatever the
    /// outcome, the web view then goes to `about:blank`.
    private func signInToWebex(loginURL: URL, interactive: Bool, operation: Int) async throws {
        try ensureCurrent(operation)
        guard let store else { throw CancellationError() }
        let login = WebexLogin(loginURL: loginURL, interactive: interactive)
        webexLogin = login
        store.httpCookieStore.add(self)
        defer {
            store.httpCookieStore.remove(self)
            if webexLogin === login { webexLogin = nil }
            // Whatever happened, no Webex page keeps running in the hidden web view: a signed-in
            // webappng page (or a player reached through in-page routing, which the navigation
            // policy can't see) would keep its scripts, timers and connections alive until the
            // next operation (#148 review). Only while this operation is still the current one:
            // a newer operation already drives the page, and a blank load would cancel its own.
            if operation == operationID {
                webView?.stopLoading()
                webView?.load(URLRequest(url: Self.blankPage))
            }
            window?.orderOut(nil)
        }
        trace("signing in to Webex at \(Self.redacted(loginURL))")
        let deadline = webexHiddenDeadline
        login.deadline = Task { [weak self] in
            do { try await Task.sleep(for: deadline) } catch { return }
            self?.trace("Webex sign-in still hidden at its deadline")
            self?.webexLoginNeedsUser(login, cause: "deadline", restartWithoutHint: true)
        }
        restartStall(login)
        let webView = browser()
        webView.stopLoading()
        startWebexLogin(webView, loginURL)
        do {
            try await withTaskCancellationHandler {
                try await login.wait()
            } onCancel: {
                Task { @MainActor in login.finish(.failure(CancellationError()), reason: "task-cancelled") }
            }
        } catch {
            // Which way out it was, and whether the user had the window: a Play that ended in the
            // browser from here says whether Webex never set the ticket, left the measured chain
            // or stalled (#148, package F diagnostics).
            diagnose("stream: step=sign-in ended result=\(login.endReason ?? "unknown") window=\(login.windowShown ? "shown" : "hidden") error=\(PlaybackDiagnostics.errorName(error)) trail=\(login.trail.joined(separator: ">"))")
            throw error
        }
        diagnose("stream: step=sign-in ended result=\(login.endReason ?? "unknown") window=\(login.windowShown ? "shown" : "hidden") trail=\(login.trail.joined(separator: ">"))")
        try ensureCurrent(operation)
    }

    /// Runs `signInToWebex` as an operation of its own, exactly as `stream(for:email:)` does after
    /// finding the player link. For `RecmanWebSessionTests`, which drive it against local pages.
    func runWebexSignIn(loginURL: URL, interactive: Bool) async throws {
        let operation = beginOperation()
        try await signInToWebex(loginURL: loginURL, interactive: interactive, operation: operation)
    }

    /// Restarts the "nothing is happening" timer of a hidden sign-in.
    private func restartStall(_ login: WebexLogin) {
        guard !login.windowShown, !login.isFinished else { return }
        login.stall?.cancel()
        let timeout = webexStallTimeout
        login.stall = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.trace("Webex sign-in stalled")
            self?.webexLoginNeedsUser(login, cause: "stall", restartWithoutHint: true)
        }
    }

    /// The hidden sign-in can't go on alone.
    ///
    /// With `restartWithoutHint` (a stall or the deadline) on a Webex page, the window opens on
    /// Webex's login again
    /// without the email hint: the page it stalled on (live, a blank idbroker page after a hint
    /// that didn't match the asserted identity) gives the user nothing to act on, while the
    /// unhinted login starts at Webex's own email page. A page that asks for credentials is
    /// already actionable and stays as it is.
    /// `cause` ("stall", "deadline", "credentials") goes to the Play diagnostics, with the host of
    /// the page the hidden sign-in was on, never its address.
    private func webexLoginNeedsUser(_ login: WebexLogin, cause: String, restartWithoutHint: Bool = false) {
        guard webexLogin === login, !login.isFinished, !login.windowShown else { return }
        if login.reachedPlayback {
            // Webex considers the sign-in over, yet no ticket arrived: an unknown change, not
            // something the user could fix in the window.
            login.finish(.failure(RecmanBrowserError.playbackUnavailable), reason: "back-at-playback-without-ticket after=\(cause)")
            return
        }
        guard login.interactive else {
            login.finish(.failure(RecmanBrowserError.needsSignIn), reason: "needs-user cause=\(cause)")
            return
        }
        diagnose("stream: step=sign-in needs-user cause=\(cause) page=\(WebexSignInNavigation.diagnosticHost(webView?.url))")
        trace("Webex sign-in needs the user: showing the sign-in window")
        login.windowShown = true
        login.stall?.cancel()
        login.deadline?.cancel()
        showWindow()
        // Only from a Webex page: a stall on Polimi's side (a 2FA push waiting for approval on
        // the phone, say) is the user's to finish where it is, and reloading would throw it away.
        if restartWithoutHint, let webView, WebexSignIn.isWebexLoginPage(webView.url) {
            webView.stopLoading()
            startWebexLogin(webView, WebexSignIn.withoutEmailHint(login.loginURL))
        }
    }

    /// Ends the sign-in if the store now holds a Webex ticket.
    private func checkWebexTicket(_ login: WebexLogin) {
        guard let store, !login.isFinished else { return }
        Task { [weak self] in
            let cookies = await store.httpCookieStore.allCookies()
            guard let self, self.webexLogin === login, WebexSignIn.isSignedIn(cookies: cookies) else { return }
            self.trace("signed in to Webex")
            // Whether the ticket was already there when Webex sent the web view back to the
            // playback page (whose load is always cancelled), or arrived before that hop.
            login.finish(.success(()), reason: login.reachedPlayback ? "ticket at-playback-page" : "ticket")
        }
    }

    /// A page of the sign-in finished loading: maybe the ticket is there, maybe the page needs
    /// the user (a password or one-time-code field, read by the same probe as Polimi's pages).
    private func webexPageFinished(_ login: WebexLogin, url: URL?) {
        checkWebexTicket(login)
        restartStall(login)
        guard !login.windowShown else { return }
        let operation = operationID
        Task { [weak self] in
            guard let self else { return }
            let facts = try? await self.pageFacts(operation: operation)
            guard self.webexLogin === login, !login.isFinished else { return }
            self.trace("loaded \(Self.redacted(url)) — asks credentials \(facts?.asksForCredentials ?? false)")
            if facts?.asksForCredentials == true { self.webexLoginNeedsUser(login, cause: "credentials") }
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        if let login = webexLogin { checkWebexTicket(login) }
    }

    func close() {
        interruptPending()
        operationID += 1
        if let window {
            window.delegate = nil
            window.close()
        }
        window = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        webView = nil
        currentNavigation = nil
        store = nil
    }

    // MARK: Entering the archive

    /// An entry in progress: the navigator's state, its timers and whoever awaits its outcome.
    @MainActor private final class Entry {
        var navigator: RecmanEntryNavigator
        var timers: [Task<Void, Never>] = []
        var outcome: RecmanEntryNavigator.Outcome?
        var continuation: CheckedContinuation<RecmanEntryNavigator.Outcome, Never>?

        init(mode: RecmanEntryNavigator.Mode) {
            navigator = RecmanEntryNavigator(mode: mode)
        }
    }

    private func enter(_ mode: RecmanEntryNavigator.Mode, operation: Int) async -> RecmanEntryNavigator.Outcome {
        guard operation == operationID else { return .cancelled }
        let entry = Entry(mode: mode)
        self.entry = entry
        trace("entering (\(mode == .background ? "background" : "interactive"))")
        entry.timers.append(Task { [weak self] in
            do { try await Task.sleep(for: RecmanEntryNavigator.deadline) } catch { return }
            self?.feed(.deadlineElapsed, to: entry)
        })
        let webView = browser()
        webView.stopLoading()
        webView.load(URLRequest(url: PolimiPage.entryURL))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let outcome = entry.outcome {
                    continuation.resume(returning: outcome)
                } else {
                    entry.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.feed(.cancelled, to: entry) }
        }
    }

    private func enterInBackground(operation: Int) async throws {
        let outcome = await enter(.background, operation: operation)
        try ensureCurrent(operation)
        switch outcome {
        case .archive: return
        case .needsUser: throw RecmanBrowserError.needsSignIn
        case .unrecognized: throw RecmanBrowserError.unrecognized
        case .timedOut, .failed: throw RecmanBrowserError.unavailable
        case .cancelled: throw CancellationError()
        }
    }

    /// Hands `event` to the entry's navigator and carries out what it decides. Events for an
    /// entry that already ended (a late timer, a page probe that came back after `close()`) are
    /// dropped here.
    private func feed(_ event: RecmanEntryNavigator.Event, to entry: Entry) {
        guard self.entry === entry else { return }
        for command in entry.navigator.handle(event) {
            switch command {
            case .schedulePatience(let id, let delay):
                entry.timers.append(Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    self?.feed(.patienceElapsed(id: id), to: entry)
                })
            case .showWindow:
                trace("showing the sign-in window")
                showWindow()
            case .finish(let outcome):
                trace("entry ended: \(outcome)")
                entry.timers.forEach { $0.cancel() }
                entry.timers = []
                self.entry = nil
                if outcome != .archive { webView?.stopLoading() }
                window?.orderOut(nil)
                entry.outcome = outcome
                entry.continuation?.resume(returning: outcome)
                entry.continuation = nil
            }
        }
    }

    // MARK: Reading the archive

    /// The page after a search or "prossima" is no longer this search's results: the Recman
    /// session lapsed. `recordings(for:)` starts over once.
    private struct LeftTheSearch: Error {}

    private func search(_ key: RecmanCourseKey, operation: Int) async throws -> [RecmanRecording] {
        switch try await submit(RecmanScripts.clearColumnFilters, operation: operation) {
        case "clean": break
        case "submitted": guard try await isOnArchive(operation: operation) else { throw LeftTheSearch() }
        default: throw RecmanBrowserError.unrecognized
        }
        switch try await submit(RecmanScripts.search, arguments: ["code": key.courseCode, "year": String(key.academicYear)], operation: operation) {
        case "submitted": break
        case "missingYear": throw RecmanBrowserError.yearUnavailable
        default: throw RecmanBrowserError.unrecognized
        }
        // Before the listing starts, since changing the page size goes back to page one.
        switch try await submit(RecmanScripts.hundredPerPage, operation: operation) {
        case "submitted", "unchanged": break
        default: throw RecmanBrowserError.unrecognized
        }
        var listing = RecmanArchiveListing(key: key)
        while true {
            guard try await isOnArchive(operation: operation) else { throw LeftTheSearch() }
            let page: RecmanResultsPage
            do {
                page = try RecmanResultsPage.decode(try await evaluate(RecmanScripts.resultsPage, operation: operation))
            } catch is RecmanRecordingParser.ParseError {
                throw RecmanBrowserError.unrecognized
            }
            trace("results page: \(page.recordings.count) rows, total \(page.declaredTotal.map(String.init) ?? "none"), next \(page.hasNext), says empty \(page.saysEmpty), search matches \(page.searchedCode == key.courseCode && page.searchedYear == String(key.academicYear))")
            let more: Bool
            do {
                more = try listing.add(page)
            } catch RecmanArchiveListing.ListingError.notThisSearch {
                throw LeftTheSearch()
            } catch RecmanArchiveListing.ListingError.incompatiblePage {
                throw RecmanBrowserError.unrecognized
            } catch {
                throw RecmanBrowserError.incomplete
            }
            guard more else { return listing.recordings }
            guard try await submit(RecmanScripts.nextPage, operation: operation) == "submitted" else { throw RecmanBrowserError.incomplete }
        }
    }

    private func isOnArchive(operation: Int) async throws -> Bool {
        guard let webView, !webView.isLoading else { return false }
        return PolimiPage.classify(webView.url, facts: try await pageFacts(operation: operation)) == .archive
    }

    /// What a finished load tells the entry's navigator, given how its page probe ended.
    ///
    /// A probe that answered, even with something unreadable, is a page with those facts (an
    /// unreadable one has none). A probe that timed out or was interrupted says nothing about the
    /// page, so nothing is fed: the entry then ends as it did before page scripts were bounded,
    /// at `RecmanEntryNavigator.deadline` for a background entry ("Polimi isn't responding") or
    /// with the window for an interactive one. Feeding empty facts instead would classify a
    /// stalled login page as "sign in again", or the archive as "looks different" (#112 review).
    nonisolated static func entryEvent(afterProbe probe: Result<PolimiPageFacts, Error>, load id: Int, url: URL?) -> RecmanEntryNavigator.Event? {
        switch probe {
        case .success(let facts): .loadFinished(id: id, url: url, facts: facts)
        case .failure(RecmanBrowserError.unrecognized): .loadFinished(id: id, url: url, facts: PolimiPageFacts())
        case .failure: nil
        }
    }

    private func pageFacts(operation: Int) async throws -> PolimiPageFacts {
        PolimiPageFacts.decode(try await evaluate(RecmanScripts.pageFacts, operation: operation)) ?? PolimiPageFacts()
    }

    // MARK: Driving the page

    /// A page load something is waiting for: the first main-frame load to finish after
    /// `after`. It can finish before anyone awaits it (WebKit may report the load before the
    /// script that started it returns), so the result is kept until `wait()`.
    @MainActor private final class LoadWaiter {
        let after: Int
        private var result: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?

        init(after: Int) {
            self.after = after
        }

        func resolve(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }

        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    private func startWaiting() -> LoadWaiter {
        let waiter = LoadWaiter(after: loadID)
        loadWaiter?.resolve(.failure(CancellationError()))
        loadWaiter = waiter
        return waiter
    }

    private func stopWaiting(_ waiter: LoadWaiter) {
        if loadWaiter === waiter { loadWaiter = nil }
    }

    private func wait(for waiter: LoadWaiter, operation: Int) async throws {
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: Self.loadTimeout) } catch { return }
            self?.trace("page load timed out")
            waiter.resolve(.failure(RecmanBrowserError.unavailable))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            Task { @MainActor in waiter.resolve(.failure(CancellationError())) }
        }
        try ensureCurrent(operation)
    }

    /// Runs a script that may press one of the page's controls. When it answers "submitted",
    /// waits for the page that control loads. Returns the script's answer.
    private func submit(_ script: String, arguments: [String: Any]? = nil, operation: Int) async throws -> String {
        let waiter = startWaiting()
        defer { stopWaiting(waiter) }
        let status = try await evaluate(script, arguments: arguments, operation: operation)
        guard status == "submitted" else { return status }
        try await wait(for: waiter, operation: operation)
        return status
    }

    /// Runs one of `RecmanScripts` in the isolated content world. Every script answers with a
    /// string; anything else (an exception, no page) is `unrecognized`. With `arguments`, `script`
    /// is a function body for `callAsyncJavaScript`.
    ///
    /// The call ends exactly once, with the first of WebKit's answer, an interruption (`close()`,
    /// a newer operation, the awaiting task cancelled) or `scriptTimeout`. Before #112 it waited
    /// for the callback alone: a Promise that never settled kept the operation suspended for as
    /// long as WebKit held the callback, and nothing in the session could end it. An answer that
    /// comes after the call ended reaches a settled `BoundedScriptCall` and is dropped there,
    /// never handed to the next operation.
    private func evaluate(_ script: String, arguments: [String: Any]? = nil, operation: Int) async throws -> String {
        try ensureCurrent(operation)
        guard let webView else { throw CancellationError() }
        let call = BoundedScriptCall<String?>()
        pendingScripts.append(call)
        lastScriptCall = call
        defer { pendingScripts.removeAll { $0 === call } }
        // The completion captures `call` and nothing else: a callback WebKit keeps for a Promise
        // that never settles must not keep this session or its web view alive after `close()`.
        Self.start(script, arguments: arguments, in: webView) { call.answer($0) }
        let outcome = await call.wait(timeout: scriptTimeout)
        try ensureCurrent(operation)
        switch outcome {
        case .answered(let answer?): return answer
        case .answered(nil): throw RecmanBrowserError.unrecognized
        case .interrupted: throw CancellationError()
        case .timedOut:
            trace("script timed out")
            // As a page load that never finishes: the archive isn't answering, and the controller
            // then stops the other requests instead of letting each wait for the same timeout.
            throw RecmanBrowserError.unavailable
        }
    }

    /// Runs `script` as an operation of its own, exactly as the archive operations run theirs.
    /// For `RecmanWebSessionTests`, which drive the script lifecycle against a local page (#112).
    func runScript(_ script: String, arguments: [String: Any]? = nil) async throws -> String {
        let operation = beginOperation()
        return try await evaluate(script, arguments: arguments, operation: operation)
    }

    /// Whether a script call is waiting for WebKit; for `RecmanWebSessionTests`.
    var hasPendingScript: Bool { !pendingScripts.isEmpty }

    /// The string `script` answers in `webView`, or nil if it threw or answered something else.
    /// Shared with `RecmanScriptsTests` and the probe, so the fixtures run the scripts exactly as
    /// the session does. Unbounded on purpose: it waits for WebKit's callback, which the fixtures
    /// always get; the session itself goes through `evaluate`.
    static func run(_ script: String, arguments: [String: Any]? = nil, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            start(script, arguments: arguments, in: webView) { continuation.resume(returning: $0) }
        }
    }

    /// Starts `script` and hands its answer to `completion` when WebKit calls back; WebKit decides
    /// when, or whether, that is. The completion-handler forms are used because the async
    /// `evaluateJavaScript` traps when a script returns nothing.
    private static func start(_ script: String, arguments: [String: Any]?, in webView: WKWebView, completion: @escaping @MainActor (String?) -> Void) {
        let finish: @MainActor (Result<Any, Error>) -> Void = { result in
            completion((try? result.get()) as? String)
        }
        if let arguments {
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient, completionHandler: finish)
        } else {
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient, completionHandler: finish)
        }
    }

    private func beginOperation() -> Int {
        interruptPending()
        operationID += 1
        return operationID
    }

    private func ensureCurrent(_ operation: Int) throws {
        try Task.checkCancellation()
        guard operation == operationID else { throw CancellationError() }
    }

    /// Ends whatever the previous operation was waiting for, so it throws instead of driving the
    /// page alongside the next one.
    private func interruptPending() {
        if let entry { feed(.cancelled, to: entry) }
        webexLogin?.finish(.failure(CancellationError()), reason: "superseded")
        streamWork?.cancel()
        loadWaiter?.resolve(.failure(CancellationError()))
        loadWaiter = nil
        capturingPlayback = false
        // Emptied before interrupting: each resumed `evaluate` removes its own call from the list.
        let scripts = pendingScripts
        pendingScripts = []
        scripts.forEach { $0.interrupt() }
    }

    private func playbackFound(_ url: URL) {
        trace("player found")  // its address carries the recording id
        capturedPlayback = url
        capturingPlayback = false
        webView?.stopLoading()
        loadWaiter?.resolve(.success(()))
    }

    // MARK: Browser and window

    /// The web view and its (hidden) window, created by `open(cookies:)`.
    private func browser() -> WKWebView {
        if let webView { return webView }
        let store = store ?? .nonPersistent()
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        // The web view is hidden for most of its life. Without this WebKit throttles hidden
        // pages, and Polimi's self-submitting single sign-on pages would crawl or stall.
        configuration.preferences.inactiveSchedulingPolicy = .none
        let webView = RecmanSignInWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 680), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = tr("Accesso Polimi per le registrazioni", "Polimi sign-in for recordings")
        window.contentView = webView
        window.delegate = self
        self.webView = webView
        self.window = window
        return webView
    }

    private func showWindow() {
        guard let window else { return }
        presentSignInWindow(window)
    }

    func windowWillClose(_ notification: Notification) {
        if let entry { feed(.windowClosed, to: entry) }
        webexLogin?.finish(.failure(CancellationError()), reason: "window-closed")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        loadID += 1
        currentNavigation = navigation
        if let entry { feed(.loadStarted(id: loadID), to: entry) }
        if let webexLogin { restartStall(webexLogin) }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, navigation === currentNavigation else { return }
        loadID += 1
        if let entry { feed(.loadStarted(id: loadID), to: entry) }
        if let webexLogin {
            restartStall(webexLogin)
            checkWebexTicket(webexLogin)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === currentNavigation else { return }
        let id = loadID
        let url = webView.url
        if let waiter = loadWaiter, id > waiter.after {
            loadWaiter = nil
            waiter.resolve(.success(()))
        }
        if let webexLogin {
            webexPageFinished(webexLogin, url: url)
            return
        }
        guard let entry else {
            trace("loaded \(Self.redacted(url))")
            return
        }
        let operation = operationID
        Task { [weak self] in
            guard let self else { return }
            let probe: Result<PolimiPageFacts, Error>
            do { probe = .success(try await self.pageFacts(operation: operation)) } catch { probe = .failure(error) }
            guard let event = Self.entryEvent(afterProbe: probe, load: id, url: url) else {
                self.trace("loaded \(Self.redacted(url)) — page probe gave no answer")
                return
            }
            if case .loadFinished(_, _, let facts) = event {
                self.trace("loaded \(Self.redacted(url)) — \(PolimiPage.classify(url, facts: facts)), archive form \(facts.hasArchiveForm), redirect form \(facts.hasAutomaticRedirectForm), asks credentials \(facts.asksForCredentials)")
            }
            self.feed(event, to: entry)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(webView, navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(webView, navigation, error)
    }

    /// Only network failures count. A load cancelled because a newer one took over, or because
    /// the policy below refused it, also arrives here, as a cancellation or as a WebKit error;
    /// treating those as failures would end entries that are about to succeed (the bug
    /// `LoginWindowController.retryAutomaticallyOrGiveUp` documents).
    private func loadFailed(_ webView: WKWebView, _ navigation: WKNavigation?, _ error: Error) {
        guard webView === self.webView, navigation === currentNavigation else { return }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled else { return }
        trace("load failed: \(error.domain) \(error.code)")
        loadWaiter?.resolve(.failure(RecmanBrowserError.unavailable))
        loadWaiter = nil
        if let entry { feed(.loadFailed(id: loadID), to: entry) }
        // With the window up a failed load is the user's to retry, as in a browser.
        if let webexLogin, !webexLogin.windowShown {
            webexLogin.finish(.failure(RecmanBrowserError.unavailable), reason: "load-failed code=\(error.code)")
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        trace("web content process ended")
        loadWaiter?.resolve(.failure(RecmanBrowserError.unavailable))
        loadWaiter = nil
        if let webexLogin {
            if webexLogin.windowShown {
                // The user is looking at a blank window: start the login again for them.
                startWebexLogin(webView, WebexSignIn.withoutEmailHint(webexLogin.loginURL))
            } else {
                webexLogin.finish(.failure(RecmanBrowserError.unavailable), reason: "web-process-ended")
            }
            return
        }
        guard let entry else { return }
        if entry.navigator.isWaitingForUser {
            // The user is looking at a blank window: start the way in again for them.
            webView.load(URLRequest(url: PolimiPage.entryURL))
        } else {
            feed(.loadFailed(id: loadID), to: entry)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, let url = action.request.url else { decisionHandler(.cancel); return }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if let login = webexLogin {
            decideDuringWebexLogin(login, url: url, mainFrame: mainFrame, decisionHandler: decisionHandler)
            return
        }
        if capturingPlayback, let player = RecmanURLPolicy.playbackURL(url) {
            decisionHandler(.cancel)
            playbackFound(player)
            return
        }
        // During a sign-in the user asked for, Polimi may send them to another site (SPID, CIE, a
        // 2FA provider) before the window is up: letting that load lands the entry on a page it
        // doesn't recognize, which shows the window there. Refusing it would show the page before.
        if RecmanNavigationPolicy.allows(url, mainFrame: mainFrame, userDriven: entry?.navigator.mode == .interactive) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        guard mainFrame else { return }
        trace("refused \(Self.redacted(url))")
        refused(url)
    }

    /// The navigation policy while signing in to Webex (`WebexSignInNavigation`). The playback
    /// page is cancelled whoever is driving: it means the chain is over, so the ticket is
    /// checked. A refused page while hidden ends the sign-in (an unknown chain, browser fallback).
    private func decideDuringWebexLogin(_ login: WebexLogin, url: URL, mainFrame: Bool, decisionHandler: @MainActor (WKNavigationActionPolicy) -> Void) {
        let decision = WebexSignInNavigation.decide(url, mainFrame: mainFrame, userDriven: login.windowShown)
        if mainFrame { login.noteHop(WebexSignInNavigation.diagnosticHost(url) + (decision == .playbackPage ? "(playback)" : decision == .refuse ? "(refused)" : "")) }
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .playbackPage:
            decisionHandler(.cancel)
            cancelledPlaybackPages += 1
            trace("Webex went back to the playback page: not loaded")
            login.reachedPlayback = true
            checkWebexTicket(login)
            // Webex considers the sign-in done. The ticket normally arrives with this hop; if it
            // doesn't within a moment, the operation ends in the browser rather than waiting for
            // a stall or, with the window up, for the user to close a window that can't help.
            if login.playbackGrace == nil, !login.isFinished {
                let grace = webexPlaybackGrace
                login.playbackGrace = Task { [weak self] in
                    do { try await Task.sleep(for: grace) } catch { return }
                    guard let self, self.webexLogin === login, !login.isFinished else { return }
                    self.trace("back at the playback page without a Webex ticket")
                    login.finish(.failure(RecmanBrowserError.playbackUnavailable), reason: "back-at-playback-without-ticket")
                }
            }
        case .refuse:
            decisionHandler(.cancel)
            guard mainFrame else { return }
            trace("refused \(Self.redacted(url))")
            if !login.windowShown {
                login.finish(.failure(RecmanBrowserError.playbackUnavailable), reason: "refused-host host=\(WebexSignInNavigation.diagnosticHost(url))")
            }
        }
    }

    /// A main-frame load the policy refused. Whatever was waiting for the next page won't get
    /// one, so it ends now instead of at its timeout; an entry treats it as a page it doesn't
    /// recognize, which ends a background entry and hands an interactive one to the user.
    private func refused(_ url: URL) {
        loadWaiter?.resolve(.failure(RecmanBrowserError.unrecognized))
        loadWaiter = nil
        guard let entry else { return }
        loadID += 1
        feed(.loadStarted(id: loadID), to: entry)
        feed(.loadFinished(id: loadID, url: url, facts: PolimiPageFacts()), to: entry)
    }

    // MARK: WKUIDelegate

    /// Links meant for a new window open in this one, where the policy above still applies;
    /// a Webex player is captured instead while a recording is being opened.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, let url = action.request.url else { return nil }
        if capturingPlayback, let player = RecmanURLPolicy.playbackURL(url) {
            playbackFound(player)
        } else if action.targetFrame == nil {
            webView.load(action.request)
        }
        return nil
    }

    // MARK: Tracing

    private func trace(_ line: String) {
        log.debug("\(line, privacy: .public)")
        traceHandler?(line)
    }

    /// One step of a Play (#148, package F diagnostics), at notice level in the `playback`
    /// category, so it is in the unified log without debug logging turned on and a Play that
    /// ended in the browser says which step sent it there. Only lines built from step names,
    /// statuses and the privacy-safe names of `PlaybackDiagnostics` and Core's `diagnostic…`
    /// helpers reach it: never an address, a uuid, a cookie, a title or the email. Called only
    /// on a Play's path, so nothing is logged at rest.
    private func diagnose(_ line: String) {
        PlaybackDiagnostics.log.notice("\(line, privacy: .public)")
        traceHandler?(line)
    }

    /// Host and path only: Polimi's query strings carry single sign-on tickets, and Java and
    /// Shibboleth pages can put the session id in the path itself (`;jsessionid=…`), so each
    /// path segment is cut at its first `;` too. Webex puts the recording's uuid in the path of
    /// its playback page (#148): 32-hex runs are masked, so a trace never says what was watched.
    static func redacted(_ url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "(none)" }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }
            .joined(separator: "/")
            .replacingOccurrences(of: "[0-9A-Fa-f]{32}", with: "<id>", options: .regularExpression)
        return "\(components.scheme ?? "?")://\(components.host ?? "?")\(path)"
    }
}

/// The Recman browser's web view, which handles the editing shortcuts itself.
///
/// In a Mac app ⌘V, ⌘C and the rest reach a text field through the main menu's Edit items, and
/// whether a menu-bar process has that menu depends on how it was set up. Without it the
/// shortcuts do nothing and a copied password can't be pasted into Polimi's sign-in (first seen
/// in the live check of 2026-10-06). Handling them here works whatever the main menu holds, and
/// never touches it or the status item.
final class RecmanSignInWebView: WKWebView {
    /// The editing action a key equivalent stands for, or nil for every other key.
    static func editingAction(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.editingAction(for: event) {
            // The web view takes cut, copy, paste and select-all itself; undo and redo belong to
            // its window, so they go up the responder chain.
            if NSApplication.shared.sendAction(action, to: responds(to: action) ? self : nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
