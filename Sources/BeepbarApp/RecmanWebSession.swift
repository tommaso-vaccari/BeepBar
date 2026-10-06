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
    /// The recording's player couldn't be found.
    case playbackUnavailable
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
/// the page, so two operations never drive the web view at once.
@MainActor final class RecmanWebSession: NSObject, RecmanBrowsing, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// How long a script-triggered page load (a search, "prossima", a preview) may take.
    static let loadTimeout: Duration = .seconds(30)

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
    private func evaluate(_ script: String, arguments: [String: Any]? = nil, operation: Int) async throws -> String {
        try ensureCurrent(operation)
        guard let webView else { throw CancellationError() }
        let answer = await Self.run(script, arguments: arguments, in: webView)
        try ensureCurrent(operation)
        guard let answer else { throw RecmanBrowserError.unrecognized }
        return answer
    }

    /// The string `script` answers in `webView`, or nil if it threw or answered something else.
    /// Shared with `RecmanScriptsTests`, so the fixtures run the scripts exactly as the session
    /// does. The completion-handler forms are used because the async `evaluateJavaScript` traps
    /// when a script returns nothing.
    static func run(_ script: String, arguments: [String: Any]? = nil, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            let finish: @MainActor (Result<Any, Error>) -> Void = { result in
                continuation.resume(returning: (try? result.get()) as? String)
            }
            if let arguments {
                webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient, completionHandler: finish)
            } else {
                webView.evaluateJavaScript(script, in: nil, in: .defaultClient, completionHandler: finish)
            }
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
        loadWaiter?.resolve(.failure(CancellationError()))
        loadWaiter = nil
        capturingPlayback = false
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
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 680), configuration: configuration)
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
        window.center()
        // As in `LoginWindowController.showWindow`: a menu-bar app has to activate itself, or
        // the window shows without keyboard focus and the sign-in fields reject typing.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let entry { feed(.windowClosed, to: entry) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        loadID += 1
        currentNavigation = navigation
        if let entry { feed(.loadStarted(id: loadID), to: entry) }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, navigation === currentNavigation else { return }
        loadID += 1
        if let entry { feed(.loadStarted(id: loadID), to: entry) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === currentNavigation else { return }
        let id = loadID
        let url = webView.url
        if let waiter = loadWaiter, id > waiter.after {
            loadWaiter = nil
            waiter.resolve(.success(()))
        }
        guard let entry else {
            trace("loaded \(Self.redacted(url))")
            return
        }
        let operation = operationID
        Task { [weak self] in
            guard let self else { return }
            let facts = (try? await self.pageFacts(operation: operation)) ?? PolimiPageFacts()
            self.trace("loaded \(Self.redacted(url)) — \(PolimiPage.classify(url, facts: facts)), archive form \(facts.hasArchiveForm), redirect form \(facts.hasAutomaticRedirectForm), asks credentials \(facts.asksForCredentials)")
            self.feed(.loadFinished(id: id, url: url, facts: facts), to: entry)
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
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        trace("web content process ended")
        loadWaiter?.resolve(.failure(RecmanBrowserError.unavailable))
        loadWaiter = nil
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

    /// Host and path only: Polimi's query strings carry single sign-on tickets, and Java and
    /// Shibboleth pages can put the session id in the path itself (`;jsessionid=…`), so each
    /// path segment is cut at its first `;` too.
    static func redacted(_ url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "(none)" }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }
            .joined(separator: "/")
        return "\(components.scheme ?? "?")://\(components.host ?? "?")\(path)"
    }
}
