import AppKit
import AVFoundation
import WebKit

// The `lab` investigation (issue #148, Phase 0b): unattended, never shows a window and never
// types. It answers three questions with the saved Polimi and Webex cookies:
//
// 1. Can the recording uuid be read from the `ldr.php` player link without a web view, and if
//    not, how cheaply can a hidden web view hand it over?
// 2. Which cookies and headers does the stream API need from plain URLSession, and does its
//    hlsURL keep playing some minutes later?
// 3. With which cookies does a later Webex login skip the email page, and does the login accept
//    an email hint?
//
// Same privacy rules as the rest of the probe: addresses reduced to host, masked path and query
// names; cookies by name and domain; inputs by kind and a filled/empty flag, never a value.

/// Visible inputs by kind, whether each holds a value (never the value), and the forms' targets.
let labPageFacts = #"""
(() => {
  const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const red = u => { try { const x = new URL(u, location.href); return x.host + x.pathname.replace(/[A-Za-z0-9_-]{16,}/g, '<id>'); } catch (e) { return '(none)'; } };
  const inputs = Array.from(document.querySelectorAll('input, button[type=submit]')).filter(visible)
    .map(i => ({ type: i.type || '', name: i.name || '', id: i.id || '', filled: !!(i.value && i.type !== 'submit' && i.type !== 'button'), readOnly: !!i.readOnly }));
  const forms = Array.from(document.forms).map(f => red(f.action));
  return JSON.stringify({ inputs: inputs, forms: forms });
})()
"""#

/// One GET from Swift with exactly `sent` as cookies and `headers`.
func labGet(_ url: URL, cookies sent: [HTTPCookie], headers: [String: String] = [:], follow: Bool) async throws -> (Data, HTTPURLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    let session = URLSession(configuration: configuration, delegate: NoRedirect(follow: follow), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url, timeoutInterval: 20)
    for (name, value) in HTTPCookie.requestHeaderFields(with: sent) { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await session.data(for: request)
    return (data, response as! HTTPURLResponse)
}

/// What a body carries that could lead to the recording, without printing it.
func bodyHints(_ data: Data) -> String {
    let text = String(decoding: data.prefix(400_000), as: UTF8.self)
    func count(_ pattern: String) -> Int {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }
    // Path-like strings in the page (scripts, API calls), masked, to see what it would call.
    var paths: [String] = []
    if let regex = try? NSRegularExpression(pattern: #"["'](/[A-Za-z0-9_\-./]{4,120})["'?]"#) {
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let path = String(text[range]).replacingOccurrences(of: #"[A-Za-z0-9_\-]{16,}"#, with: "<id>", options: .regularExpression)
                .replacingOccurrences(of: #"[0-9]{5,}"#, with: "<n>", options: .regularExpression)
            if !paths.contains(path) { paths.append(path) }
        }
    }
    return "\(data.count) bytes, hex32 \(count("[0-9a-f]{32}")), 'recording/playback' \(count("recording/playback")), 'recordingservice' \(count("recordingservice")), location.* \(count(#"location\.(href|replace|assign)|window\.location"#)), meta refresh \(count(#"http-equiv=[\"']?refresh"#)), forms \(count("<form")), scripts \(count("<script")), paths \(paths.prefix(25))"
}

/// A hidden web view with its own store that records the main-frame trail and stops on demand.
@MainActor final class LabBrowser: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let label: String
    let webView: WKWebView
    var stopAtUUID = false
    /// Hosts whose main-frame navigation is cancelled and ends the run (recorded, never loaded).
    var cancelHosts: [String] = []
    var printRequests = true
    private(set) var uuidURL: URL?
    private(set) var trail: [URL] = []
    private(set) var cancelledAt: String?
    private(set) var streamStatuses: [Int] = []
    private(set) var emailPage: (filled: Bool, readOnly: Bool)?
    private(set) var passwordPage = false
    private(set) var lastFacts = ""
    private var pages = 0
    private var done = false

    init(label: String, store: WKWebsiteDataStore) {
        self.label = label
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.addUserScript(WKUserScript(source: webexObserver, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, contentWorld: .page, name: "probe")
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Loads `url` and waits until a stop, the email page, a password page, a 200 from the stream
    /// API, or `limit`.
    func run(_ url: URL, limit: Duration) async -> String {
        let start = ContinuousClock.now
        webView.load(URLRequest(url: url))
        var outcome = "timeout"
        while ContinuousClock.now - start < limit {
            try? await Task.sleep(for: .milliseconds(250))
            if uuidURL != nil, stopAtUUID { outcome = "uuid in main-frame URL, navigation cancelled"; break }
            if let cancelledAt { outcome = "cancelled at \(cancelledAt)"; break }
            if let emailPage { outcome = "EMAIL PAGE shown (IDToken1/email field), prefilled \(emailPage.filled), readOnly \(emailPage.readOnly)"; break }
            if passwordPage { outcome = "PASSWORD PAGE shown"; break }
            if streamStatuses.contains(200) { outcome = "signed in: stream API 200 in page"; break }
        }
        let summary = "\(outcome) after \(elapsed(since: start)), \(trail.count) main-frame navigations, \(pages) pages finished, stream API statuses \(streamStatuses)"
        done = true
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        return summary
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !done, let body = message.body as? [String: Any], body["kind"] as? String == "request", let url = body["url"] as? String else { return }
        if url.contains("/webappng/api/v1/recordings/"), url.contains("/stream"), let status = body["status"] as? Int { streamStatuses.append(status) }
        if ["tsa-f.webex.com", "tsa.webex.com", "amplitude.com", "wbx2.com", "/metric"].contains(where: url.contains) { return }
        if printRequests { say("    [\(label)] request \(body["method"] ?? "?") \(url) → \(body["status"] ?? "?")") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !done else { decisionHandler(.cancel); return }
        guard action.targetFrame?.isMainFrame ?? true, let url = action.request.url else { decisionHandler(.allow); return }
        trail.append(url)
        say("    [\(label)] → \(streamShape(url)) (type \(action.navigationType.rawValue))")
        if webexRecordingUUID(url) != nil, uuidURL == nil {
            uuidURL = url
            if stopAtUUID { decisionHandler(.cancel); return }
        }
        if let host = url.host?.lowercased(), cancelHosts.contains(host) {
            cancelledAt = host
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        say("    [\(label)] (server redirect to \(webView.url.map(streamShape) ?? "?"))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pages += 1
        let url = webView.url
        Task {
            guard !self.done, let facts = try? await webView.evaluateJavaScript(labPageFacts, in: nil, contentWorld: .defaultClient) as? String else { return }
            self.lastFacts = facts
            say("    [\(self.label)] page \(url.map(streamShape) ?? "(none)") \(facts)")
            if let data = facts.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let inputs = json["inputs"] as? [[String: Any]] {
                if let email = inputs.first(where: { ($0["name"] as? String) == "IDToken1" || ($0["id"] as? String) == "IDToken1" || ($0["type"] as? String) == "email" }) {
                    self.emailPage = ((email["filled"] as? Bool) ?? false, (email["readOnly"] as? Bool) ?? false)
                }
                if inputs.contains(where: { ($0["type"] as? String) == "password" }) { self.passwordPage = true }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        if error.code != NSURLErrorCancelled, error.code != 102 { say("    [\(label)] load failed \(error.domain) \(error.code)") }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, !done { webView.load(action.request) }
        return nil
    }
}

/// A fresh, non-persistent store holding exactly `cookies`.
@MainActor func labStore(_ cookies: [HTTPCookie]) async -> WKWebsiteDataStore {
    let store = WKWebsiteDataStore.nonPersistent()
    for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }
    return store
}

func names(_ cookies: [HTTPCookie]) -> String {
    cookies.map { "\($0.name)@\($0.domain)" }.sorted().joined(separator: ",")
}

/// Status of the stream API for one cookie set and header set, as one line; the hlsURL in memory.
@MainActor func streamAPI(_ api: URL, _ label: String, cookies sent: [HTTPCookie], headers: [String: String] = [:]) async -> URL? {
    do {
        let (data, response) = try await labGet(api, cookies: sent, headers: headers, follow: false)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let hls = ((json?["downloadRecordingInfo"] as? [String: Any])?["downloadInfo"] as? [String: Any])?["hlsURL"] as? String
        let setCookies = HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields as? [String: String] ?? [:], for: api).map(\.name)
        let keys = json.map { Array($0.keys).sorted().prefix(12).joined(separator: ",") } ?? "(not JSON)"
        say("  API [\(label)] → HTTP \(response.statusCode) requireLogin=\(json?["requireLogin"].map { "\($0)" } ?? "-") hls \(hls != nil) set-cookie \(setCookies) keys \(keys)")
        return response.statusCode == 200 ? hls.flatMap(URL.init(string:)) : nil
    } catch {
        say("  API [\(label)] failed \((error as NSError).domain) \((error as NSError).code)")
        return nil
    }
}

@MainActor func lab(state: URL, code: String, year: Int, index: Int) async -> Int32 {
    guard let key = RecmanCourseKey(courseCode: code, academicYear: year) else { say("not a course code and year"); return 2 }
    let waitMinutes = Int(ProcessInfo.processInfo.environment["RECMAN_PROBE_LAB_WAIT_MINUTES"] ?? "") ?? 10
    let file = state.appendingPathComponent("session.plist")
    guard let data = FileManager.default.contents(atPath: file.path), let snapshot = try? RecmanSessionCodec.decode(data) else { say("no readable saved session"); return 1 }
    let webexFile = state.appendingPathComponent("webex-cookies.plist")
    let webexCookies = loadWebexCookies(from: webexFile)
    say("restoring \(snapshot.cookies.count) Polimi cookies and \(webexCookies.count) Webex cookies")
    describeCookies(webexCookies)
    let session = RecmanWebSession()
    defer { session.close() }
    await session.open(cookies: snapshot.cookies + webexCookies)
    let player: URL
    do {
        try await session.reachArchive()
        let recordings = try await session.recordings(for: key)
        guard recordings.indices.contains(index - 1) else { say("only \(recordings.count) recordings"); return 1 }
        player = try await session.playbackURL(for: recordings[index - 1])
        try await save(session, to: file)
    } catch {
        say("RESULT lab FAILED before the player: \(error)")
        return 1
    }
    guard let store = session.webView?.configuration.websiteDataStore else { return 1 }
    let all = await store.httpCookieStore.allCookies()
    let polimi = all.filter { PolimiPage.isPolimiHost($0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
    let webex = all.filter { $0.domain.lowercased().contains("webex.com") }
    say("player link: \(streamShape(player)); store has \(polimi.count) Polimi and \(webex.count) Webex cookies")

    // MARK: Q1 — the uuid without a web view
    say("== Q1: player link from Swift")
    for (label, sent) in [("no cookies", [HTTPCookie]()), ("Webex cookies", cookies(webex, for: player))] {
        do {
            let (body, response) = try await labGet(player, cookies: sent, headers: ["Accept": "text/html,application/xhtml+xml"], follow: false)
            let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: player)?.absoluteURL }
            let setCookies = HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields as? [String: String] ?? [:], for: player).map(\.name)
            say("  ldr [\(label), \(sent.count) sent, no follow] → HTTP \(response.statusCode) \(response.value(forHTTPHeaderField: "Content-Type") ?? "?") Location \(location.map(streamShape) ?? "none") uuid-in-Location \(location.flatMap(webexRecordingUUID) != nil) set-cookie \(setCookies)")
            say("    body: \(bodyHints(body))")
            let (followedBody, followed) = try await labGet(player, cookies: sent, headers: ["Accept": "text/html,application/xhtml+xml"], follow: true)
            say("  ldr [\(label), followed] → HTTP \(followed.statusCode) at \(followed.url.map(streamShape) ?? "?") uuid-in-URL \(followed.url.flatMap(webexRecordingUUID) != nil)")
            say("    body: \(bodyHints(followedBody))")
        } catch {
            say("  ldr [\(label)] failed \((error as NSError).domain) \((error as NSError).code)")
        }
    }
    say("== Q1: hidden web view on the session's store, cancelled at the first URL with the uuid")
    let finder = LabBrowser(label: "uuid", store: store)
    finder.stopAtUUID = true
    say("  \(await finder.run(player, limit: .seconds(40)))")
    guard let playback = finder.uuidURL, let uuid = webexRecordingUUID(playback) else { say("RESULT lab NO-UUID"); return 1 }

    // MARK: Q2 — the stream API from URLSession
    say("== Q2: stream API from URLSession")
    var components = URLComponents(string: "https://politecnicomilano.webex.com/webappng/api/v1/recordings/\(uuid)/stream")!
    components.queryItems = [URLQueryItem(name: "siteurl", value: "politecnicomilano")]
    let api = components.url!
    let matching = cookies(all, for: api)
    say("  cookies a browser would send to the API: \(names(matching))")
    _ = await streamAPI(api, "none", cookies: [])
    var hls = await streamAPI(api, "all matching", cookies: matching)
    _ = await streamAPI(api, "only .webex.com", cookies: matching.filter { $0.domain.hasPrefix(".") })
    _ = await streamAPI(api, "only politecnicomilano.webex.com", cookies: matching.filter { !$0.domain.hasPrefix(".") })
    for cookie in matching {
        _ = await streamAPI(api, "without \(cookie.name)", cookies: matching.filter { $0 !== cookie })
    }
    for cookie in matching {
        _ = await streamAPI(api, "only \(cookie.name)", cookies: [cookie])
    }
    if hls == nil {
        let referer = ["Referer": playback.absoluteString, "Origin": "https://politecnicomilano.webex.com"]
        hls = await streamAPI(api, "all + Referer/Origin", cookies: matching, headers: referer)
        if let csrf = matching.first(where: { $0.name == "_csrf_" })?.value {
            for header in ["X-CSRF-Token", "csrfToken", "X-XSRF-TOKEN"] {
                if hls == nil { hls = await streamAPI(api, "all + Referer + \(header)", cookies: matching, headers: referer.merging([header: csrf]) { $1 }) }
            }
        }
        if let token = matching.first(where: { $0.name == "accessToken" })?.value {
            if hls == nil { hls = await streamAPI(api, "Authorization Bearer accessToken only", cookies: [], headers: ["Authorization": "Bearer \(token)"]) }
        }
    }
    let tester = WebexProbe(store: store)
    if let hls {
        say("  hlsURL \(streamShape(hls))")
        await tester.fetchHead(hls)
        say("RESULT hls now, AVPlayer without cookies: \(await tester.plays(hls, cookies: nil))")
    } else {
        say("RESULT Q2 no 200 from URLSession")
    }

    // MARK: Q3 — what a later login needs
    say("== Q3: later login with cookie subsets (fresh stores, hidden, nothing typed)")
    let persistentWebex = webex.filter { $0.expiresDate != nil }
    let idbroker = webex.filter { $0.domain.lowercased().contains("idbroker") || $0.path.hasPrefix("/idb") }
    let subsets: [(String, [HTTPCookie])] = [
        ("A polimi + all webex", polimi + webex),
        ("B polimi + persistent webex (\(names(persistentWebex)))", polimi + persistentWebex),
        ("C polimi only", polimi),
        ("D polimi + persistent + idbroker session (\(names(idbroker)))", polimi + Array(Set(persistentWebex + idbroker))),
        ("E persistent webex only, no polimi", persistentWebex),
    ]
    var idbrokerURL: URL?
    var webappLoginURL: URL?
    for (label, subset) in subsets {
        say("  -- \(label)")
        let browser = LabBrowser(label: String(label.prefix(1)), store: await labStore(subset))
        browser.printRequests = false
        say("  RESULT \(label.prefix(1)): \(await browser.run(playback, limit: .seconds(60)))")
        idbrokerURL = idbrokerURL ?? browser.trail.first { $0.host?.contains("idbroker") == true }
        webappLoginURL = webappLoginURL ?? browser.trail.first { $0.host == "politecnicomilano.webex.com" && $0.path.lowercased().contains("login") }
    }
    say("== Q3: email hints with a placeholder address (never the user's), stopped before Polimi's IdP")
    let placeholder = "probe@mail.polimi.it"
    var hinted: [(String, URL)] = []
    for (base, name) in [(idbrokerURL, "idbroker"), (webappLoginURL, "webappng login")] {
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { say("  no \(name) URL captured"); continue }
        for parameter in ["email", "login_hint"] {
            var items = (components.queryItems ?? []).filter { $0.name != parameter }
            items.append(URLQueryItem(name: parameter, value: placeholder))
            components.queryItems = items
            if let url = components.url { hinted.append(("\(name) + \(parameter)", url)) }
        }
    }
    for (label, url) in hinted {
        let browser = LabBrowser(label: label, store: await labStore(polimi))
        browser.printRequests = false
        browser.cancelHosts = ["shibidp.polimi.it", "aunicalogin.polimi.it"]
        say("  RESULT hint \(label): \(await browser.run(url, limit: .seconds(45)))")
    }

    // MARK: Q2 later — does the hlsURL and the API session survive
    if waitMinutes > 0 {
        say("== waiting \(waitMinutes) min to re-test the same hlsURL and the API")
        try? await Task.sleep(for: .seconds(waitMinutes * 60))
        if let hls {
            await tester.fetchHead(hls)
            say("RESULT hls after \(waitMinutes) min, AVPlayer without cookies: \(await tester.plays(hls, cookies: nil))")
        }
        let later = cookies(await store.httpCookieStore.allCookies(), for: api)
        _ = await streamAPI(api, "all matching, \(waitMinutes) min later", cookies: later)
    }
    saveWebexCookies(await store.httpCookieStore.allCookies(), to: webexFile)
    return 0
}

// MARK: Part 2 (RECMAN_PROBE_LAB_PART=2): follow-ups to part 1

/// Whether the ldr page's HTML holds `uuid`, and the identifier-like names just before it.
func uuidInBody(_ data: Data, uuid: String) -> String {
    let text = String(decoding: data, as: UTF8.self)
    let dashed = [8, 4, 4, 4, 12].reduce(into: (parts: [String](), rest: Substring(uuid))) { acc, n in acc.parts.append(String(acc.rest.prefix(n))); acc.rest = acc.rest.dropFirst(n) }.parts.joined(separator: "-")
    var notes: [String] = []
    for (form, needle) in [("plain", uuid), ("upper", uuid.uppercased()), ("dashed", dashed)] {
        var count = 0
        var contexts: [String] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, options: [], range: search) {
            count += 1
            let lower: String.Index = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let before = String(text[lower..<range.lowerBound])
            let names = (try? NSRegularExpression(pattern: "[A-Za-z_]{3,30}"))?.matches(in: before, range: NSRange(before.startIndex..., in: before))
                .compactMap { Range($0.range, in: before).map { String(before[$0]) } }.suffix(3) ?? []
            contexts.append(names.joined(separator: "."))
            search = range.upperBound..<text.endIndex
        }
        notes.append("\(form) \(count)\(contexts.isEmpty ? "" : " after \(contexts.prefix(4))")")
    }
    return notes.joined(separator: ", ")
}

@MainActor func labTwo(state: URL, code: String, year: Int, index: Int) async -> Int32 {
    guard let key = RecmanCourseKey(courseCode: code, academicYear: year) else { return 2 }
    let file = state.appendingPathComponent("session.plist")
    guard let data = FileManager.default.contents(atPath: file.path), let snapshot = try? RecmanSessionCodec.decode(data) else { say("no readable saved session"); return 1 }
    let webexFile = state.appendingPathComponent("webex-cookies.plist")
    let webexCookies = loadWebexCookies(from: webexFile)
    say("restoring \(snapshot.cookies.count) Polimi cookies and \(webexCookies.count) Webex cookies")
    let session = RecmanWebSession()
    defer { session.close() }
    await session.open(cookies: snapshot.cookies + webexCookies)
    let player: URL
    do {
        try await session.reachArchive()
        let recordings = try await session.recordings(for: key)
        guard recordings.indices.contains(index - 1) else { return 1 }
        player = try await session.playbackURL(for: recordings[index - 1])
        try await save(session, to: file)
    } catch {
        say("RESULT lab2 FAILED before the player: \(error)")
        return 1
    }
    guard let store = session.webView?.configuration.websiteDataStore else { return 1 }
    let all = await store.httpCookieStore.allCookies()
    let polimi = all.filter { PolimiPage.isPolimiHost($0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
    let webex = all.filter { $0.domain.lowercased().contains("webex.com") }

    say("== Q1b: is the uuid in the ldr page's HTML?")
    let finder = LabBrowser(label: "uuid", store: store)
    finder.stopAtUUID = true
    finder.printRequests = false
    say("  \(await finder.run(player, limit: .seconds(40)))")
    guard let playback = finder.uuidURL, let uuid = webexRecordingUUID(playback) else { say("RESULT lab2 NO-UUID"); return 1 }
    for (label, sent) in [("no cookies", [HTTPCookie]()), ("Webex cookies", cookies(webex, for: player))] {
        let start = ContinuousClock.now
        if let (body, response) = try? await labGet(player, cookies: sent, headers: ["Accept": "text/html"], follow: false) {
            say("  ldr [\(label)] HTTP \(response.statusCode) in \(elapsed(since: start)): uuid in body \(uuidInBody(body, uuid: uuid))")
        }
    }

    var components = URLComponents(string: "https://politecnicomilano.webex.com/webappng/api/v1/recordings/\(uuid)/stream")!
    components.queryItems = [URLQueryItem(name: "siteurl", value: "politecnicomilano")]
    let api = components.url!
    _ = await streamAPI(api, "saved store, only ticket", cookies: cookies(all, for: api).filter { $0.name == "ticket" })

    let persistentWebex = webex.filter { $0.expiresDate != nil }
    let idbroker = webex.filter { $0.domain.lowercased().contains("idbroker") || $0.path.hasPrefix("/idb") }

    say("== Q3b: D again (Polimi + idbroker session), then URLSession with the cookies it ends with")
    let storeD = await labStore(polimi + Array(Set(persistentWebex + idbroker)))
    let browserD = LabBrowser(label: "D", store: storeD)
    browserD.printRequests = true
    say("  RESULT D: \(await browserD.run(playback, limit: .seconds(45)))")
    let afterD = await storeD.httpCookieStore.allCookies()
    say("  D gained: \(names(afterD.filter { c in !(polimi + persistentWebex + idbroker).contains { $0.name == c.name && $0.domain == c.domain } }))")
    _ = await streamAPI(api, "D's cookies", cookies: cookies(afterD, for: api))

    say("== Q3c: capture the webappng login URL (Polimi only, stopped at idbroker)")
    let capture = LabBrowser(label: "C", store: await labStore(polimi))
    capture.printRequests = false
    capture.cancelHosts = ["idbroker-eu.webex.com"]
    say("  \(await capture.run(playback, limit: .seconds(40)))")
    guard let login = capture.trail.first(where: { $0.host == "politecnicomilano.webex.com" && $0.path.lowercased().contains("login") }),
          let base = URLComponents(url: login, resolvingAgainstBaseURL: false) else { say("no login URL"); return 1 }
    func hinted(_ items: [URLQueryItem]) -> URL {
        var c = base
        c.queryItems = (base.queryItems ?? []) + items
        return c.url!
    }
    let placeholder = "probe@mail.polimi.it"
    for (label, url) in [("login_hint only", hinted([URLQueryItem(name: "login_hint", value: placeholder)])),
                         ("email=other domain", hinted([URLQueryItem(name: "email", value: "probe@example.com")]))] {
        let browser = LabBrowser(label: label, store: await labStore(polimi))
        browser.printRequests = false
        browser.cancelHosts = ["shibidp.polimi.it", "aunicalogin.polimi.it"]
        say("  RESULT hint \(label): \(await browser.run(url, limit: .seconds(30)))")
    }
    say("== Q3d: email hint with a placeholder, Polimi only, allowed to finish (nothing typed)")
    let storeH = await labStore(polimi)
    let full = LabBrowser(label: "H", store: storeH)
    full.printRequests = false
    say("  RESULT full hinted login: \(await full.run(hinted([URLQueryItem(name: "email", value: placeholder)]), limit: .seconds(60)))")
    let afterH = await storeH.httpCookieStore.allCookies()
    say("  H webex cookies: \(names(afterH.filter { $0.domain.contains("webex.com") }))")
    _ = await streamAPI(api, "H's cookies", cookies: cookies(afterH, for: api))
    return 0
}

// MARK: Part 3 (RECMAN_PROBE_LAB_PART=3): does the ldr hop depend on the User-Agent?

@MainActor func labThree(state: URL, code: String, year: Int, index: Int) async -> Int32 {
    guard let key = RecmanCourseKey(courseCode: code, academicYear: year) else { return 2 }
    let file = state.appendingPathComponent("session.plist")
    guard let data = FileManager.default.contents(atPath: file.path), let snapshot = try? RecmanSessionCodec.decode(data) else { return 1 }
    let webexCookies = loadWebexCookies(from: state.appendingPathComponent("webex-cookies.plist"))
    let session = RecmanWebSession()
    defer { session.close() }
    await session.open(cookies: snapshot.cookies + webexCookies)
    let player: URL
    do {
        try await session.reachArchive()
        let recordings = try await session.recordings(for: key)
        guard recordings.indices.contains(index - 1) else { return 1 }
        player = try await session.playbackURL(for: recordings[index - 1])
        try await save(session, to: file)
    } catch { say("RESULT lab3 FAILED before the player: \(error)"); return 1 }
    guard let webView = session.webView, let store = webView.configuration.websiteDataStore as WKWebsiteDataStore? else { return 1 }
    let webex = await store.httpCookieStore.allCookies().filter { $0.domain.contains("webex.com") }
    let webKitUA = (try? await webView.evaluateJavaScript("navigator.userAgent") as? String) ?? ""
    let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    // Part 3b: the smallest User-Agent that gets the redirect, and whether it names the same
    // recording as the web view's hop.
    let finder = LabBrowser(label: "uuid", store: store)
    finder.stopAtUUID = true
    finder.printRequests = false
    _ = await finder.run(player, limit: .seconds(30))
    let viewUUID = finder.uuidURL.flatMap(webexRecordingUUID)
    // Part 3c: runs 1-2 got a 200 page with Accept "text/html…", part 3b a 302 with every
    // User-Agent: vary Accept alone (default User-Agent), in both orders, then follow.
    let accepts = ["text/html", "text/html,application/xhtml+xml", "*/*", "application/json, text/plain, */*",
                   "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "text/html", "*/*"]
    for accept in accepts {
        if let (body, response) = try? await labGet(player, cookies: [], headers: ["Accept": accept], follow: false) {
            let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: player)?.absoluteURL }
            let uuid = location.flatMap(webexRecordingUUID)
            say("  ldr [Accept \(accept)] → HTTP \(response.statusCode) uuid-in-Location \(uuid != nil) same-as-web-view \(uuid != nil && uuid == viewUUID) body \(body.count) bytes")
        }
    }
    if let (_, followed) = try? await labGet(player, cookies: [], headers: ["Accept": "*/*"], follow: true) {
        let uuid = followed.url.flatMap(webexRecordingUUID)
        say("  ldr [Accept */*, followed] → HTTP \(followed.statusCode) uuid-in-final-URL \(uuid != nil) same \(uuid == viewUUID)")
    }
    for (uaLabel, ua) in [("WKWebView UA", webKitUA), ("Safari UA", safariUA)] where ProcessInfo.processInfo.environment["RECMAN_PROBE_LAB_3A"] != nil {
        for (label, sent) in [("no cookies", [HTTPCookie]()), ("Webex cookies", cookies(webex, for: player))] {
            let headers = ["User-Agent": ua, "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "Accept-Language": "it-IT,it;q=0.9"]
            if let (body, response) = try? await labGet(player, cookies: sent, headers: headers, follow: false) {
                let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: player)?.absoluteURL }
                say("  ldr [\(uaLabel), \(label)] → HTTP \(response.statusCode) Location \(location.map(streamShape) ?? "none") uuid-in-Location \(location.flatMap(webexRecordingUUID) != nil) body \(body.count) bytes")
            }
        }
    }
    // Which script does the hop: list the external scripts and inline-script sizes, masked.
    if let (body, _) = try? await labGet(player, cookies: [], headers: ["User-Agent": webKitUA], follow: false) {
        let text = String(decoding: body, as: UTF8.self)
        let scriptRegex = try! NSRegularExpression(pattern: #"<script[^>]*src=["']([^"']+)["']"#)
        var srcs: [String] = []
        for match in scriptRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let src = String(text[range].split(separator: "?").first ?? "")
            srcs.append(src.replacingOccurrences(of: #"[A-Za-z0-9_\-]{16,}"#, with: "<id>", options: .regularExpression))
        }
        say("  ldr scripts: \(srcs)")
        for word in ["RCID", "recordId", "recordingId", "uuid", "playback", "ajax", "fetch(", "XMLHttpRequest", "$.get", "$.post", "submit()", "redirect", "href"] {
            let n = text.components(separatedBy: word).count - 1
            if n > 0 { say("  ldr body mentions \(word): \(n)") }
        }
    }
    return 0
}
