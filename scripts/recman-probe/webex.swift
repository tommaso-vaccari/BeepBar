import AppKit
import AVFoundation
import WebKit

// The `play` investigation of the native-playback feature: what happens after BeepBar has found a
// recording's Webex player. It opens that player in a visible window sharing the Recman browser's
// cookies (so Polimi's single sign-on is already there), and reports:
//
// - every main-frame page it goes through, and the visible input fields each one shows (type,
//   name, id, autocomplete: never a value), to see where Webex asks for the email;
// - the requests the page makes with their JSON responses reduced to keys and value types, to
//   find the API that hands out the stream;
// - the stream addresses it finds, kept in memory only and printed reduced to host and path;
// - whether AVPlayer plays each of them, first without any cookie, then with the store's cookies.
//
// Nothing here is product code: it answers the questions in docs/recordings-native-playback.md.
// The output carries no query strings, tokens, cookie values, ids or titles.

/// Host and path with long id-like segments masked, plus the names (never the values) of the
/// query parameters.
func streamShape(_ url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "(unparsable)" }
    let path = components.path.replacingOccurrences(of: #"[A-Za-z0-9_\-]{16,}"#, with: "<id>", options: .regularExpression)
    let names = (components.queryItems ?? []).map(\.name)
    return "\(components.scheme ?? "?")://\(components.host ?? "?")\(path)" + (names.isEmpty ? "" : " ?\(names.joined(separator: ","))")
}

/// Wraps the page's `fetch` and `XMLHttpRequest` to report each request, and every string in a
/// JSON answer that looks like a stream. Runs in the page's own world, which is what it wraps.
let webexObserver = #"""
(() => {
  const post = m => { try { window.webkit.messageHandlers.probe.postMessage(m); } catch (e) {} };
  const red = u => { try { const x = new URL(u, location.href); return x.protocol + '//' + x.host + x.pathname.replace(/[A-Za-z0-9_-]{16,}/g, '<id>') + (x.search ? ' ?' + Array.from(x.searchParams.keys()).join(',') : ''); } catch (e) { return '(unparsable)'; } };
  const shape = (v, d) => {
    if (d > 6) return '…';
    if (Array.isArray(v)) return v.length ? [shape(v[0], d + 1), 'len ' + v.length] : [];
    if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v).slice(0, 80)) o[k] = shape(v[k], d + 1); return o; }
    if (typeof v === 'string') return /^https?:/.test(v) ? 'url ' + red(v) : 'string(' + v.length + ')';
    return typeof v;
  };
  const candidates = (v, path, d) => {
    if (d > 10 || v == null) return;
    if (typeof v === 'string') { if (/^https?:/.test(v) && /(m3u8|\.mp4|html5-pipeline|playlist|hls)/i.test(v)) post({ kind: 'candidate', source: path, value: v }); return; }
    if (typeof v === 'object') for (const k of Object.keys(v)) candidates(v[k], path + '.' + k, d + 1);
  };
  const skip = u => /\.(js|css|png|jpe?g|gif|svg|woff2?|ttf|ico|map)(\?|$)/i.test(u);
  const report = (method, url, status, type, body) => {
    if (skip(url)) return;
    const m = { kind: 'request', method: method, url: red(url), status: status, type: type || '' };
    if (body && /json/i.test(type || '')) {
      try { const j = JSON.parse(body); if (/\/webappng\/api\/v1\/recordings\//.test(url)) m.shape = JSON.stringify(shape(j, 0)); candidates(j, red(url), 0); } catch (e) {}
    }
    if (/m3u8|mpegurl/i.test(url + ' ' + (type || ''))) { try { post({ kind: 'candidate', source: 'request', value: new URL(url, location.href).href }); } catch (e) {} }
    post(m);
  };
  const originalFetch = window.fetch;
  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
    const method = (init && init.method) || (input && input.method) || 'GET';
    const response = await originalFetch.apply(this, arguments);
    try {
      const type = response.headers.get('content-type') || '';
      report(method, url, response.status, type, /json/i.test(type) ? await response.clone().text() : null);
    } catch (e) {}
    return response;
  };
  const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) { this.__probe = { method: method, url: String(url) }; return open.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener('loadend', () => {
      try {
        const type = this.getResponseHeader('content-type') || '';
        let body = null;
        if ((this.responseType === '' || this.responseType === 'text') && /json/i.test(type)) body = this.responseText;
        else if (this.responseType === 'json' && this.response) body = JSON.stringify(this.response);
        report(this.__probe.method, this.__probe.url, this.status, type, body);
      } catch (e) {}
    });
    return send.apply(this, arguments);
  };
})();
"""#

/// The visible inputs of a page, by kind only, and whether the page has a video.
let webexPageFacts = #"""
(() => {
  const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const inputs = Array.from(document.querySelectorAll('input, button[type=submit]')).filter(visible)
    .map(i => ({ tag: i.tagName.toLowerCase(), type: i.type || '', name: i.name || '', id: i.id || '', autocomplete: i.autocomplete || '' }));
  const videos = Array.from(document.querySelectorAll('video')).map(v => ({ source: v.currentSrc ? (v.currentSrc.startsWith('blob:') ? 'blob' : 'url') : 'none', ready: v.readyState, paused: v.paused, duration: isFinite(v.duration) ? Math.round(v.duration) : null }));
  const frames = Array.from(document.querySelectorAll('iframe')).map(f => { try { const u = new URL(f.src); return u.host + u.pathname.replace(/[A-Za-z0-9_-]{16,}/g, '<id>'); } catch (e) { return '(none)'; } });
  return JSON.stringify({ inputs: inputs, videos: videos, frames: frames });
})()
"""#

/// The address of a playing video that is not a `blob:` (native HLS or a plain file), or "".
let webexVideoSource = #"""
(() => { const v = Array.from(document.querySelectorAll('video')).find(v => v.currentSrc && !v.currentSrc.startsWith('blob:')); return v ? v.currentSrc : ''; })()
"""#

@MainActor final class WebexProbe: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private let store: WKWebsiteDataStore
    private var webView: WKWebView?
    private var window: NSWindow?
    private var windowClosed = false
    private var candidates: [(source: String, url: URL)] = []
    private var pages = 0
    /// Telemetry and Webex-app service calls, counted instead of printed.
    private var quietRequests = 0
    /// The playback page's address, whose path carries the recording's uuid.
    private(set) var playbackPage: URL?

    init(store: WKWebsiteDataStore) {
        self.store = store
    }

    /// Opens `player`, reports until the user closes the window or `limit` runs out, then tests
    /// every stream found.
    func run(player: URL, limit: Duration) async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.inactiveSchedulingPolicy = .none
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: webexObserver, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        content.add(self, contentWorld: .page, name: "probe")
        let webView = RecmanSignInWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Webex probe: if Webex asks for your email, type it; close the window when the video plays"
        window.contentView = webView
        window.delegate = self
        self.webView = webView
        self.window = window
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        say("opening the player \(streamShape(player))")
        let start = ContinuousClock.now
        webView.load(URLRequest(url: player))
        var lastVideo = ""
        while !windowClosed, ContinuousClock.now - start < limit {
            try? await Task.sleep(for: .seconds(2))
            if let source = try? await webView.evaluateJavaScript(webexVideoSource, in: nil, contentWorld: .defaultClient) as? String,
               !source.isEmpty, source != lastVideo, let url = URL(string: source) {
                lastVideo = source
                found(url, source: "video element")
            }
        }
        say("(\(quietRequests) telemetry and Webex-app service requests not printed)")
        say(windowClosed ? "window closed after \(elapsed(since: start))" : "time limit reached (\(elapsed(since: start)))")
        if let facts = try? await webView.evaluateJavaScript(webexPageFacts, in: nil, contentWorld: .defaultClient) as? String {
            say("  [last page] at \(webView.url.map(streamShape) ?? "(none)") \(facts)")
        }
        content.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        window.delegate = nil
        window.close()
        self.webView = nil
        self.window = nil

        if candidates.isEmpty {
            say("RESULT stream NONE found: no JSON field, request or video element looked like a stream")
        }
        let cookies = await store.httpCookieStore.allCookies()
        for (index, candidate) in candidates.prefix(4).enumerated() {
            say("stream \(index + 1) from \(candidate.source): \(streamShape(candidate.url))")
            await fetchHead(candidate.url)
            let bare = await plays(candidate.url, cookies: nil)
            say("RESULT stream \(index + 1) AVPlayer without cookies: \(bare)")
            if !bare.hasPrefix("PLAYS") {
                let host = candidate.url.host ?? ""
                let matching = cookies.filter { host == $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) || host.hasSuffix($0.domain.hasPrefix(".") ? $0.domain : "." + $0.domain) }
                say("RESULT stream \(index + 1) AVPlayer with \(matching.count) cookies for its host: \(await plays(candidate.url, cookies: matching))")
            }
        }
    }

    /// The first bytes, fetched with no cookies at all: status, type and what kind of file it is.
    private func fetchHead(_ url: URL) async {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let text = String(decoding: data, as: UTF8.self)
            var kind = "\(data.count) bytes"
            if text.hasPrefix("#EXTM3U") {
                let lines = text.split(whereSeparator: \.isNewline)
                kind = "HLS playlist: \(lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF") }.count) variants, \(lines.filter { $0.hasPrefix("#EXTINF") }.count) segments in the first 4 KB, keys \(lines.contains { $0.hasPrefix("#EXT-X-KEY") })"
                // Where the next level lives (relative, same host, other host), not its address.
                if let next = lines.first(where: { !$0.hasPrefix("#") }) {
                    let target = URL(string: String(next), relativeTo: url)?.absoluteURL
                    kind += ", next level \(next.hasPrefix("http") ? "absolute" : "relative") on \(target?.host == url.host ? "same host" : "host \(target?.host ?? "?")")\(target.map { " query names \((URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name))" } ?? "")"
                }
            } else if data.count > 8, String(decoding: data[4..<8], as: UTF8.self) == "ftyp" {
                kind = "MP4 file"
            }
            say("  no-cookie GET: HTTP \(http?.statusCode ?? 0) \(http?.value(forHTTPHeaderField: "Content-Type") ?? "?") — \(kind)")
        } catch {
            say("  no-cookie GET failed: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    /// Whether AVPlayer actually advances through `url` (muted), within 25 seconds.
    private func plays(_ url: URL, cookies: [HTTPCookie]?) async -> String {
        let asset = cookies.map { AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: $0]) } ?? AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(25) {
            try? await Task.sleep(for: .milliseconds(500))
            if item.status == .failed {
                let error = item.error as NSError?
                return "FAILED \(error?.domain ?? "?") \(error?.code ?? 0) after \(elapsed(since: start))"
            }
            if item.currentTime().seconds > 2 {
                let duration = item.duration.seconds
                return "PLAYS after \(elapsed(since: start)), duration \(duration.isFinite ? "\(Int(duration / 60)) min" : "unknown"), \(item.presentationSize.width)x\(item.presentationSize.height)"
            }
        }
        return "STALLED (status \(item.status.rawValue), at \(item.currentTime().seconds) s) after 25 s"
    }

    private func found(_ url: URL, source: String) {
        guard url.scheme == "https", !candidates.contains(where: { $0.url == url }) else { return }
        candidates.append((source, url))
        say("  candidate stream from \(source): \(streamShape(url))")
    }

    // MARK: Delegates

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "request":
            if let url = body["url"] as? String, ["tsa-f.webex.com", "tsa.webex.com", "amplitude.com", "wbx2.com", "/metric"].contains(where: url.contains) {
                quietRequests += 1
                return
            }
            let shape = (body["shape"] as? String).map { " " + $0 } ?? ""
            say("  · request \(body["method"] ?? "?") \(body["url"] ?? "?") → \(body["status"] ?? "?") \(body["type"] ?? "")\(shape)")
        case "candidate":
            if let value = body["value"] as? String, let url = URL(string: value) { found(url, source: (body["source"] as? String) ?? "?") }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame ?? true, let url = action.request.url {
            if webexRecordingUUID(url) != nil, playbackPage == nil { playbackPage = url }
            say("  → \(streamShape(url))")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pages += 1
        let page = pages
        let url = webView.url
        Task {
            let facts = (try? await webView.evaluateJavaScript(webexPageFacts, in: nil, contentWorld: .defaultClient) as? String) ?? "(no facts)"
            say("  [page \(page)] \(url.map(streamShape) ?? "(none)") \(facts)")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        say("  load failed: \((error as NSError).domain) \((error as NSError).code)")
    }

    /// Pop-ups open in the same window, as the app would have to.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        windowClosed = true
    }
}

/// The Webex cookies the probe keeps between runs, to see whether a second play still asks for
/// the email. A separate file because the app's session codec keeps only Polimi cookies.
@MainActor func loadWebexCookies(from file: URL) -> [HTTPCookie] {
    guard let data = FileManager.default.contents(atPath: file.path),
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
    return values.compactMap { HTTPCookie(properties: Dictionary(uniqueKeysWithValues: $0.map { (HTTPCookiePropertyKey($0.key), $0.value) })) }
        .filter { $0.expiresDate.map { $0 > Date() } ?? true }
}

@MainActor func saveWebexCookies(_ cookies: [HTTPCookie], to file: URL) {
    let kept = cookies.filter { !PolimiPage.isPolimiHost($0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
    let values = kept.compactMap { $0.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) } }
    guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return }
    FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    say("kept \(kept.count) non-Polimi cookies for the next play run:")
    describeCookies(kept)
}

// MARK: The direct way, without the player page

/// The 32-hex recording uuid of a Webex playback page, from either form of its path.
func webexRecordingUUID(_ url: URL) -> String? {
    guard url.host?.lowercased() == "politecnicomilano.webex.com" else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard let index = parts.firstIndex(of: "recording") else { return nil }
    return parts[(index + 1)...].first { $0.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }
}

/// Cookies of `cookies` that a browser would send to `url`.
func cookies(_ cookies: [HTTPCookie], for url: URL) -> [HTTPCookie] {
    guard let host = url.host?.lowercased() else { return [] }
    return cookies.filter { cookie in
        let domain = cookie.domain.lowercased()
        let matches = domain.hasPrefix(".") ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
        return matches && url.path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https")
    }
}

/// One GET from Swift with exactly `sent` as cookies, no redirects followed unless `follow`.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    let follow: Bool
    init(follow: Bool) { self.follow = follow }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        follow ? request : nil
    }
}

func get(_ url: URL, cookies sent: [HTTPCookie], follow: Bool) async throws -> (Data, HTTPURLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    let session = URLSession(configuration: configuration, delegate: NoRedirect(follow: follow), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url, timeoutInterval: 20)
    for (name, value) in HTTPCookie.requestHeaderFields(with: sent) { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue("application/json, text/html", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    return (data, response as! HTTPURLResponse)
}

/// Tries to reach the stream without loading Webex's player page: the player link answered
/// from Swift, then the stream API with the store's cookies. Returns the HLS address when that
/// works, so the window is only needed when it doesn't.
@MainActor func direct(player: URL, store: WKWebsiteDataStore) async -> URL? {
    let all = await store.httpCookieStore.allCookies()
    say("direct: \(all.filter { $0.domain.lowercased().contains("webex.com") }.count) Webex cookies in the store")
    var uuid: String?
    do {
        let (_, response) = try await get(player, cookies: [], follow: false)
        let location = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: player)?.absoluteURL }
        say("direct: player link without cookies → HTTP \(response.statusCode)\(location.map { " Location \(streamShape($0))" } ?? " (no redirect: the hop is done by the page)")")
        uuid = location.flatMap(webexRecordingUUID)
        if uuid == nil {
            let (data, followed) = try await get(player, cookies: [], follow: true)
            let final = followed.url.flatMap(webexRecordingUUID)
            let inBody = String(decoding: data.prefix(200_000), as: UTF8.self).range(of: "recording/(?:playback/)?[0-9a-f]{32}", options: .regularExpression) != nil
            say("direct: followed → HTTP \(followed.statusCode) at \(followed.url.map(streamShape) ?? "?"), uuid in final URL \(final != nil), in body \(inBody)")
            uuid = final
        }
    } catch {
        say("direct: player link failed \((error as NSError).domain) \((error as NSError).code)")
    }
    guard let uuid else { say("RESULT direct NO-UUID: the recording id needs the web view"); return nil }
    var components = URLComponents(string: "https://politecnicomilano.webex.com/webappng/api/v1/recordings/\(uuid)/stream")!
    components.queryItems = [URLQueryItem(name: "siteurl", value: "politecnicomilano")]
    let api = components.url!
    for (label, sent) in [("without cookies", [HTTPCookie]()), ("with the store's cookies", cookies(all, for: api))] {
        do {
            let (data, response) = try await get(api, cookies: sent, follow: false)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let flags = ["requireLogin", "canPlayback", "preventPlayback", "passwordProtected", "needPassword", "preventDownload"]
                .map { "\($0)=\(json?[$0].map { "\($0)" } ?? "-")" }.joined(separator: " ")
            let hls = ((json?["downloadRecordingInfo"] as? [String: Any])?["downloadInfo"] as? [String: Any])?["hlsURL"] as? String
            say("RESULT direct API \(label) (\(sent.count) sent) → HTTP \(response.statusCode) \(flags) hlsURL \(hls.flatMap(URL.init(string:)).map(streamShape) ?? "absent")")
            if response.statusCode == 200, let hls, let url = URL(string: hls) { return url }
        } catch {
            say("RESULT direct API \(label) failed \((error as NSError).domain) \((error as NSError).code)")
        }
    }
    return nil
}
