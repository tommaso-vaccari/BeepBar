import AppKit
import WebKit

// The `webeep` mode (issue #234): do the Polimi single sign-on cookies left in the web store by
// the app's WeBeep sign-in suffice to enter the Recman archive, with no new sign-in and no new
// two-factor step? It reproduces the WeBeep sign-in in a window, takes the cookies that remain
// in that window's store, restores the ones Recordings keeps into a fresh store (as
// `RecmanWebSession.open` does) and tries the archive entry the `warm` mode uses, with no window.
//
// Output rules are the probe's: the WeBeep token is never printed or stored (only "received"),
// cookies are counted and their domains named, never their names or values, and addresses are
// reduced to host and path.

/// How the WeBeep sign-in window ended.
enum WeBeepLoginOutcome {
    case tokenReceived
    case windowClosed
    case timedOut
}

/// The WeBeep sign-in window, a minimal copy of the app's `LoginWindowController`
/// (Sources/BeepbarApp/WeBeepAuthenticationController.swift, around lines 4223-4400): same
/// non-persistent store, same login URL, same hand-off into `launch.php` once the site lands on
/// `/my`, same interception of `moodlemobile://token=`. That file can't be compiled into the
/// probe, so the URLs (`MoodleSite.polimi`: loginURL, mobileLaunchURL, isAuthenticatedLandingURL)
/// are repeated here: if the app's sign-in flow changes, update this copy too.
///
/// One deliberate difference: the web view is `RecmanSignInWebView` (the Recordings sign-in
/// window's), which handles the editing shortcuts itself, because the probe is a menu-less
/// process in which ⌘V did not paste a password. It changes keyboard handling only; the cookies
/// WebKit stores are unaffected. The app's automatic reload on network failures is left out.
@MainActor final class WeBeepLoginProbe: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private enum Phase { case signingIn, launchingMobile, finished }

    private static let host = "webeep.polimi.it"
    private static let loginURL = URL(string: "https://webeep.polimi.it/auth/shibboleth/index.php")!
    private static var mobileLaunchURL: URL {
        var components = URLComponents(string: "https://webeep.polimi.it/admin/tool/mobile/launch.php")!
        components.queryItems = [URLQueryItem(name: "service", value: "moodle_mobile_app"), URLQueryItem(name: "passport", value: UUID().uuidString)]
        return components.url!
    }

    private let store = WKWebsiteDataStore.nonPersistent()
    private let webView: RecmanSignInWebView
    private let window: NSWindow
    private var phase = Phase.signingIn
    private var outcome: WeBeepLoginOutcome?
    private var continuation: CheckedContinuation<WeBeepLoginOutcome, Never>?
    private var timer: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = RecmanSignInWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 680), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "RecmanProbe: WeBeep sign-in"
        window.contentView = webView
        super.init()
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Shows the window and waits for the token, the window being closed, or `limit`.
    func run(limit: Duration) async -> WeBeepLoginOutcome {
        window.center()
        // As in the app: an accessory process must activate itself or the window shows without
        // keyboard focus.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: Self.loginURL))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            self?.finish(.timedOut)
        }
        return await withCheckedContinuation { continuation in
            if let outcome { continuation.resume(returning: outcome) } else { self.continuation = continuation }
        }
    }

    /// Every cookie in the window's store, read before `close()`.
    func cookies() async -> [HTTPCookie] { await store.httpCookieStore.allCookies() }

    func close() {
        timer?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        window.delegate = nil
        window.close()
    }

    private func finish(_ result: WeBeepLoginOutcome) {
        guard phase != .finished else { return }
        phase = .finished
        timer?.cancel()
        outcome = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    /// `nonisolated` + hop, as in the app (#241, #30).
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.finish(.windowClosed) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "moodlemobile" {
            decisionHandler(.cancel)
            // The address carries the token: only the fact is kept, never the address.
            if phase == .launchingMobile, url.absoluteString.hasPrefix("moodlemobile://token=") {
                webView.stopLoading()
                finish(.tokenReceived)
            }
            return
        }
        guard url.scheme == "https" else { decisionHandler(.cancel); return }
        if phase == .signingIn, url.host?.lowercased() == Self.host, url.path == "/my" || url.path == "/my/" {
            phase = .launchingMobile
            decisionHandler(.cancel)
            webView.load(URLRequest(url: Self.mobileLaunchURL))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url, url.scheme == "https" else { return nil }
        webView.load(action.request)
        return nil
    }
}

/// A minimal main menu with an Edit menu. The probe's process is menu-less (LSUIElement), and in
/// an earlier run ⌘V did not paste into the sign-in window; the standard items give the shortcuts
/// their usual route. Installed for `webeep` only, so the other modes keep what they check.
@MainActor func installEditMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit RecmanProbe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
}

/// Host and path only: the query and any `;jsessionid`-style path parameter can carry a ticket.
func hostAndPath(_ url: URL?) -> String {
    guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "(none)" }
    let path = components.path.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    return "\(components.host ?? "?")\(path)"
}

/// `webeep <state> [code year]`. Contacts Polimi; run it only by hand, with your own account.
/// `RECMAN_PROBE_NO_EDIT_MENU=1` leaves the Edit menu out, so the window gets its shortcuts the way
/// the app's sign-in window does (the app installs no Edit menu): ⌘V working then shows that the
/// web view alone handles paste (#234).
@MainActor func webeepMode(state: URL, course: (code: String, year: Int)?) async -> Int32 {
    if ProcessInfo.processInfo.environment["RECMAN_PROBE_NO_EDIT_MENU"] != "1" { installEditMenu() }
    let seconds = Int(ProcessInfo.processInfo.environment["RECMAN_PROBE_WINDOW_SECONDS"] ?? "") ?? 300
    say("Sign in to WeBeep in the window that opens, as in the app (up to \(seconds) s).")
    let login = WeBeepLoginProbe()
    let outcome = await login.run(limit: .seconds(seconds))
    switch outcome {
    case .tokenReceived: say("WeBeep token received (not shown, not saved)")
    case .windowClosed: say("RESULT webeep ABORTED the window was closed before the WeBeep sign-in finished"); return 1
    case .timedOut: login.close(); say("RESULT webeep TIMED OUT no WeBeep token within \(seconds) s"); return 1
    }
    // Cookies are read while the store is still referenced by the window, then the window goes.
    let all = await login.cookies()
    login.close()
    let now = Date()
    let kept = all.filter { RecmanSessionCodec.keeps($0, now: now) }
    say("cookies in the WeBeep window's store: \(all.count) total, \(kept.count) kept by the Recordings filter (Polimi, unexpired)")
    let domains = Dictionary(grouping: kept, by: { $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    for domain in domains.keys.sorted() { say("  kept domain \(domain): \(domains[domain]!.count)") }

    let session = RecmanWebSession()
    session.traceHandler = { say("  · \($0)") }
    defer { session.close() }
    await session.open(cookies: kept)
    say("trying the archive from a fresh store holding only those cookies, with no window…")
    let start = ContinuousClock.now
    do {
        try await session.reachArchive()
    } catch {
        let stop = hostAndPath(session.webView?.url)
        if let error = error as? RecmanBrowserError, error == .needsSignIn {
            say("RESULT webeep NEEDS SIGN-IN stopped at \(stop) after \(elapsed(since: start))")
        } else {
            // Not a verdict on the cookies: Polimi didn't answer or the pages weren't recognised.
            say("RESULT webeep INCONCLUSIVE \(error) stopped at \(stop) after \(elapsed(since: start))")
        }
        return 1
    }
    say("RESULT webeep ENTERED archive at \(hostAndPath(session.webView?.url)) after \(elapsed(since: start))")
    let file = state.appendingPathComponent("session.plist")
    do { try await save(session, to: file, describe: false) } catch { say("could not save the session: \(error)") }
    if let course, let key = RecmanCourseKey(courseCode: course.code, academicYear: course.year) {
        do {
            let recordings = try await session.recordings(for: key)
            say("RESULT list OK \(recordings.count) recordings for \(course.code) \(key.academicYearLabel)")
        } catch {
            say("RESULT list FAILED \(error)")
        }
    }
    return 0
}
