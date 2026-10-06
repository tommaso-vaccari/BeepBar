import AppKit
import WebKit

// The live check of the Recordings feature against Polimi's real sign-on and archive, run by a
// person with their own Polimi account (see scripts/recman-probe.sh). It drives the very
// `RecmanWebSession` the app uses, compiled together with Core's Recordings folder, so what it
// shows is what BeepBar would do. Unit tests can't cover this part: it depends on Polimi's pages.
//
// What it prints is meant to be pasted into a conversation or an issue: addresses are reduced to
// host and path (no query strings: they carry sign-on tickets), cookies are listed by name and
// domain only, and recordings are counted, never listed.
//
//   cold <state> [code year]   sign in by hand, save the session in <state>, then list a course
//   warm <state> [code year]   restore the session from <state> in a new process and get back in
//                              without the user, as BeepBar does after a relaunch

@MainActor func say(_ line: String) {
    print(line)
    fflush(stdout)
}

@MainActor func elapsed(since start: ContinuousClock.Instant) -> String {
    let duration = ContinuousClock.now - start
    return String(format: "%.1f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
}

/// Counts what a page shows around the results, so the probe can confirm (or correct) what
/// `RecmanScripts.resultsPage` assumes about the total, the pager and the empty state. Short
/// snippets only.
let diagnostics = #"""
(() => {
  const clean = t => (t || '').trim().replace(/\s+/g, ' ');
  const text = document.body ? document.body.innerText : '';
  const around = re => { const m = text.match(re); return m ? clean(text.slice(Math.max(0, m.index - 30), m.index + 40)) : null; };
  const pager = Array.from(document.querySelectorAll('a, button, input[type=submit], input[type=button]'))
    .map(e => clean(e.innerText || e.value))
    .filter(t => /^(prossima|precedente|successiva|avanti|indietro|prima|ultima|[0-9]{1,3}|>|>>|<|<<|«|»|‹|›)$/i.test(t));
  const rows = Array.from(document.querySelectorAll('tr')).filter(r => !r.querySelector('tr'));
  const aa = document.querySelector('select[name="aa"]');
  const course = document.querySelector('input[name="contesto"]');
  return JSON.stringify({
    totalText: around(/totale/i),
    pageText: around(/pag\.?\s*[0-9]+\s*(\/|di)\s*[0-9]+/i),
    emptyText: around(/nessun|non (sono|è) stat|non ci sono/i),
    pagerControls: pager.slice(0, 20),
    innermostRows: rows.length,
    rowsWithPreview: rows.filter(r => Array.from(r.querySelectorAll('a[href]')).some(a => a.href.includes('evn_preview_link'))).length,
    rowsWithDate: rows.filter(r => Array.from(r.cells).some(c => /\b\d{2}\/\d{2}\/\d{4}\b/.test(c.innerText))).length,
    cellsPerPreviewRow: Array.from(new Set(rows.filter(r => Array.from(r.querySelectorAll('a[href]')).some(a => a.href.includes('evn_preview_link'))).map(r => r.cells.length))),
    formHolds: { aa: aa ? aa.value : null, contesto: course ? course.value : null },
    yearsOffered: aa ? Array.from(aa.options).map(o => o.value) : null
  });
})()
"""#

@MainActor func describePage(_ session: RecmanWebSession, _ label: String) async {
    guard let webView = session.webView else { return say("  [\(label)] no page") }
    say("  [\(label)] at \(RecmanWebSession.redacted(webView.url))")
    say("  [\(label)] \(await RecmanWebSession.run(diagnostics, in: webView) ?? "(diagnostics failed)")")
}

@MainActor func describeCookies(_ cookies: [HTTPCookie]) {
    for cookie in cookies.sorted(by: { ($0.domain, $0.name) < ($1.domain, $1.name) }) {
        let lifetime = cookie.expiresDate.map { "expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "session"
        say("    \(cookie.name) @ \(cookie.domain)\(cookie.path) \(lifetime) secure:\(cookie.isSecure) httpOnly:\(cookie.isHTTPOnly)")
    }
}

/// The session file, written as BeepBar writes its own: 0600 in a 0700 folder, replaced whole.
@MainActor func save(_ session: RecmanWebSession, to file: URL) async throws {
    let cookies = await session.cookies()
    let data = try RecmanSessionCodec.encode(cookies, ownerUserID: 0)
    let kept = try RecmanSessionCodec.decode(data).cookies
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".session-\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    if rename(temporary.path, file.path) != 0 { throw CocoaError(.fileWriteUnknown) }
    say("saved \(kept.count) of \(cookies.count) cookies (Polimi only, unexpired):")
    describeCookies(kept)
}

@MainActor func list(_ session: RecmanWebSession, code: String, year: Int) async {
    guard let key = RecmanCourseKey(courseCode: code, academicYear: year) else { return say("not a course code and year: \(code) \(year)") }
    say("listing \(code) \(key.academicYearLabel)…")
    let start = ContinuousClock.now
    do {
        let recordings = try await session.recordings(for: key)
        say("RESULT list OK \(recordings.count) recordings in \(elapsed(since: start))")
        await describePage(session, "last results page")
        if let newest = recordings.first {
            let playStart = ContinuousClock.now
            do {
                let player = try await session.playbackURL(for: newest)
                // The player's address carries the recording's id: only its shape is printed.
                let shape = player.path.contains("/recording/playback/") ? "recordingservice …/recording/playback/<id>" : "ldr.php?RCID=<id>"
                say("RESULT play OK newest recording's player is \(player.host ?? "?") \(shape) (\(elapsed(since: playStart)))")
            } catch {
                say("RESULT play FAILED \(error) (\(elapsed(since: playStart)))")
                await describePage(session, "preview")
            }
        }
    } catch {
        say("RESULT list FAILED \(error) after \(elapsed(since: start))")
        await describePage(session, "where it stopped")
    }
    // The empty state is the part of the layout BeepBar knows least: show what a search with no
    // results looks like.
    say("searching a course code with no recordings, to see the empty state…")
    do {
        let none = try await session.recordings(for: RecmanCourseKey(courseCode: "000000", academicYear: year)!)
        say("RESULT empty OK \(none.count) recordings")
    } catch {
        say("RESULT empty FAILED \(error)")
    }
    await describePage(session, "empty search")
}

@MainActor func run() async -> Int32 {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3, ["cold", "warm"].contains(arguments[1]) else {
        say("usage: RecmanProbe cold|warm <state folder> [course code] [academic year]")
        return 2
    }
    let mode = arguments[1]
    let file = URL(fileURLWithPath: arguments[2]).appendingPathComponent("session.plist")
    let course = arguments.count >= 5 ? (arguments[3], Int(arguments[4]) ?? 0) : nil
    let session = RecmanWebSession()
    session.traceHandler = { say("  · \($0)") }
    defer { session.close() }

    if mode == "cold" {
        await session.open(cookies: [])
        say("Sign in to Polimi in the window that opens (it only opens if Polimi asks for you).")
        let start = ContinuousClock.now
        do {
            try await session.signIn()
        } catch {
            say("RESULT cold FAILED \(error) after \(elapsed(since: start))")
            await describePage(session, "where it stopped")
            return 1
        }
        say("RESULT cold OK reached the archive in \(elapsed(since: start))")
        await describePage(session, "archive")
        do { try await save(session, to: file) } catch { say("could not save the session: \(error)"); return 1 }
    } else {
        guard let data = FileManager.default.contents(atPath: file.path) else {
            say("no saved session: run cold first")
            return 1
        }
        let snapshot: RecmanSessionCodec.Snapshot
        do { snapshot = try RecmanSessionCodec.decode(data) } catch { say("RESULT warm FAILED unreadable session file: \(error)"); return 1 }
        say("restoring \(snapshot.cookies.count) cookies:")
        describeCookies(snapshot.cookies)
        await session.open(cookies: snapshot.cookies)
        let start = ContinuousClock.now
        do {
            try await session.reachArchive()
        } catch {
            say("RESULT warm FAILED \(error) after \(elapsed(since: start))")
            await describePage(session, "where it stopped")
            return 1
        }
        say("RESULT warm OK back in the archive without the user in \(elapsed(since: start))")
        do { try await save(session, to: file) } catch { say("could not save the session: \(error)") }
    }
    if let course { await list(session, code: course.0, year: course.1) }
    return 0
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
    let status = await run()
    exit(status)
}
application.run()
