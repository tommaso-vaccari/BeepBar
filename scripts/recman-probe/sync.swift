import AppKit
import CryptoKit
import Darwin
import Foundation

// The `sync` mode (performance plan, "Cost model and proof"): ONE background-style refresh exactly
// as the app does at a sync, measured. `RecordingsController.drain` opens the web session with the
// saved cookies and calls `recordings(for:)` for each queued course, one after the other; the
// first call enters the archive in the background (`enterInBackground`: single sign-on, never a
// window), the next ones find the web view already in the archive. This mode does the same through
// the very same `RecmanWebSession`, and reports numbers only.
//
// What it prints, and nothing else: milliseconds, counts, megabytes, yes/no. No address (not even
// a redacted one), no title, no cookie name or value, no course code (courses are numbered), no
// ticket. The web session's trace lines are read to be counted and are never printed. The saved
// session is read, never rewritten, so a run can be repeated and `sync` cannot change what the
// app would find.
//
// Not observable from here, and printed as n/a rather than guessed: bytes received and sub-resource
// requests (WKWebView exposes neither without a content-blocking or scheme-handler hook that would
// change what is measured). Page loads are the main-frame loads that finished.

/// What one run measured. Plain values: `dry-run` fills it with sample numbers, a live run with
/// measurements, and `renderSyncReport` turns either into the lines that are printed.
struct SyncReport: Sendable {
    struct Entry: Sendable {
        var elapsedMilliseconds: Int
        var pageLoads: Int
        var loadFailures: Int
        /// More than one means the archive was entered again mid-run (the session lapsed).
        var entries: Int
        /// The navigator's outcome name (archive, needsUser, ...), a fixed vocabulary.
        var outcome: String
    }
    struct Course: Sendable {
        /// Listing time without the entry's, so the two add up to the run.
        var elapsedMilliseconds: Int
        var pageLoads: Int
        var resultPages: Int
        var recordings: Int
        var complete: Bool
        var enteredInside: Bool
        var state: String
    }
    struct Memory: Sendable {
        var processes: Int
        var megabytes: Double
    }
    struct Cookies: Sendable {
        var before: Int
        var after: Int
        var fingerprintChanged: Bool
        var added: Int
        var removed: Int
        var valueChanged: Int
        var expiryChanged: Int
    }
    var dryRun: Bool
    var courseCount: Int
    var entry: Entry?
    var courses: [Course]
    var totalMilliseconds: Int
    var memoryBefore: Memory
    var memoryPeak: Memory
    var memoryAfter: Memory
    var cookies: Cookies?
    var needsSignIn: Bool
    var windowWouldHaveShown: Bool
    /// `ok`, `needs-sign-in`, `no-saved-session`, or `failed (<kind>)`.
    var exitState: String
}

/// The printed lines. Pure, so the dry run proves the format. Every line goes through the guard
/// below: if a future edit ever interpolated something address-, mail- or ticket-shaped, the line
/// is withheld instead of printed.
func renderSyncReport(_ report: SyncReport) -> [String] {
    func ms(_ value: Int) -> String { "\(value) ms" }
    func mb(_ memory: SyncReport.Memory) -> String { String(format: "%d processes, %.1f MB", memory.processes, memory.megabytes) }
    func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
    var lines: [String] = []
    if report.dryRun { lines.append("DRY RUN: sample numbers, no network, no web view, no saved session read") }
    lines.append("sync: \(report.courseCount) course\(report.courseCount == 1 ? "" : "s"), background entry only, read-only")
    if let entry = report.entry {
        lines.append("ENTRY    elapsed \(ms(entry.elapsedMilliseconds)) · page loads \(entry.pageLoads) · load failures \(entry.loadFailures) · requests n/a · bytes n/a · entries \(entry.entries) · outcome \(entry.outcome)")
    } else {
        lines.append("ENTRY    not reached")
    }
    for (index, course) in report.courses.enumerated() {
        lines.append("COURSE \(index + 1) elapsed \(ms(course.elapsedMilliseconds)) (listing, entry excluded) · page loads \(course.pageLoads) · results pages \(course.resultPages) · requests n/a · bytes n/a · recordings \(course.recordings) · complete \(yesNo(course.complete)) · entered inside \(yesNo(course.enteredInside)) · \(course.state)")
    }
    if report.courses.count < report.courseCount {
        lines.append("COURSE \(report.courses.count + 1)-\(report.courseCount) not run")
    }
    lines.append("TOTAL    elapsed \(ms(report.totalMilliseconds)) (web session opened to last listing)")
    lines.append("MEMORY   WebKit helper processes (WebContent, Networking, GPU) resident size")
    lines.append("         before \(mb(report.memoryBefore))")
    lines.append("         peak   \(mb(report.memoryPeak)) (sampled every 250 ms)")
    lines.append("         after  \(mb(report.memoryAfter)) (web view closed, 2 s settle)")
    if let cookies = report.cookies {
        lines.append("COOKIES  session cookie fingerprint changed \(yesNo(cookies.fingerprintChanged)) (would a sync rewrite the session file)")
        lines.append("         cookies before \(cookies.before), after \(cookies.after) · added \(cookies.added) · removed \(cookies.removed) · value changed \(cookies.valueChanged) · expiry changed \(cookies.expiryChanged)")
    } else {
        lines.append("COOKIES  not compared")
    }
    lines.append("SIGN-IN  needed \(yesNo(report.needsSignIn)) · sign-in window would have shown \(yesNo(report.windowWouldHaveShown)) (none is ever shown by this mode)")
    lines.append("EXIT \(report.exitState)")
    return lines.map(guarded)
}

/// Last line of defence for the "numbers only" promise: nothing shaped like an address, a mail
/// address or a ticket may leave the process.
func guarded(_ line: String) -> String {
    let lowered = line.lowercased()
    for forbidden in ["://", "http", "www.", "@", "ticket", "token", "set-cookie", "session="] where lowered.contains(forbidden) {
        return "(line withheld: it looked like it carried an identifier)"
    }
    return line
}

// MARK: Arguments

struct SyncArguments {
    var dryRun = false
    var courses: [(code: String, year: Int)] = []
}

let syncUsage = """
usage: scripts/recman-probe.sh sync <course code> <academic year> [<course code> <academic year> ...] [--dry-run]
  one background-style refresh from the saved probe session (cold or warm first), sequential listings
  course code: 6 digits · academic year: the starting year, 4 digits (2026 for 2026/27)
  --dry-run  argument parsing and output formatting only: no network, no web view, no session read
  --help     this text
"""

/// nil means "show the usage and exit 2". Flags may sit anywhere; the rest must be code/year pairs.
func parseSyncArguments(_ arguments: [String]) -> SyncArguments? {
    var parsed = SyncArguments()
    var positional: [String] = []
    for argument in arguments {
        if argument == "--dry-run" { parsed.dryRun = true } else if argument.hasPrefix("--") { return nil } else { positional.append(argument) }
    }
    guard !positional.isEmpty, positional.count % 2 == 0 else { return nil }
    for index in stride(from: 0, to: positional.count, by: 2) {
        let code = positional[index]
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }), positional[index + 1].count == 4, let year = Int(positional[index + 1]),
              RecmanCourseKey(courseCode: code, academicYear: year) != nil else { return nil }
        parsed.courses.append((code, year))
    }
    return parsed
}

// MARK: Process memory

/// Resident size of the WebKit helper processes that belong to this probe. They are XPC services,
/// launched by launchd, not children of the probe. Measured on this machine: their "responsible
/// process" is whatever launched the probe (the terminal), not the probe itself, so ownership is
/// "appeared after `baseline` was taken and has the same responsible process as the probe". Helper
/// processes that already existed before the run (another app's, or a shared one) are never
/// counted; a different app starting WebKit during the run from the same terminal would be, which
/// is why the probe should be run with no other WebKit app being launched. Only counts and bytes
/// leave this type.
final class WebKitMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var baseline: Set<pid_t> = []
    private var peak = SyncReport.Memory(processes: 0, megabytes: 0)
    private let responsible: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func webKitProcesses() -> [(pid: pid_t, bytes: UInt64)] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var found: [(pid: pid_t, bytes: UInt64)] = []
        for pid in pids.prefix(count) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            guard length > 0, String(decoding: path.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("com.apple.WebKit.") else { continue }
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
            found.append((pid, info.pti_resident_size))
        }
        return found
    }

    /// Call before the web session exists.
    func markBaseline() {
        let pids = Set(Self.webKitProcesses().map(\.pid))
        lock.lock(); defer { lock.unlock() }
        baseline = pids
    }

    func sample() -> SyncReport.Memory {
        let me = getpid()
        lock.lock()
        let known = baseline
        lock.unlock()
        let myOwner = responsible?(me)
        let ours = Self.webKitProcesses().filter { process in
            // Started after the baseline AND, where the system can say, answering to the same
            // responsible process as the probe (the launching terminal, when run from a shell).
            guard !known.contains(process.pid) else { return false }
            if let responsible, let myOwner { return responsible(process.pid) == myOwner }
            return true
        }
        let memory = SyncReport.Memory(processes: ours.count, megabytes: Double(ours.reduce(0) { $0 + $1.bytes }) / 1_048_576)
        lock.lock(); defer { lock.unlock() }
        if memory.megabytes > peak.megabytes { peak = memory }
        return memory
    }

    var peakSoFar: SyncReport.Memory { lock.lock(); defer { lock.unlock() }; return peak }
}

// MARK: Trace counting

/// Counts what the web session's trace lines say, without keeping or printing them. Lines are
/// recognised by their fixed prefixes (`RecmanWebSession.trace` call sites); a prefix that changes
/// makes a count read 0, which is visible in the report, never a leak.
@MainActor final class SyncTally {
    private(set) var inEntry = false
    private var entryStarted: ContinuousClock.Instant?
    private(set) var entryTime: Duration = .zero
    private(set) var entries = 0
    private(set) var entryLoads = 0
    private(set) var loadFailures = 0
    private(set) var outcome = "none"
    private(set) var windowRequested = false
    private var courseLoads = 0
    private var coursePages = 0
    private var courseEntryTime: Duration = .zero
    private var courseEntered = false

    func note(_ line: String) {
        if line.hasPrefix("entering (") {
            inEntry = true; entries += 1; entryStarted = .now; courseEntered = true
        } else if line.hasPrefix("entry ended: ") {
            if let started = entryStarted {
                let spent = ContinuousClock.now - started
                entryTime += spent; courseEntryTime += spent
            }
            inEntry = false; entryStarted = nil
            // The outcome is an enum case name; anything else is not copied.
            let name = String(line.dropFirst("entry ended: ".count))
            outcome = ["archive", "needsUser", "unrecognized", "timedOut", "failed", "cancelled"].contains(name) ? name : "other"
        } else if line.hasPrefix("loaded ") {
            if inEntry { entryLoads += 1 } else { courseLoads += 1 }
        } else if line.hasPrefix("load failed") {
            loadFailures += 1
        } else if line.hasPrefix("results page:") {
            coursePages += 1
        } else if line.hasPrefix("showing the sign-in window") {
            windowRequested = true
        }
    }

    /// Closes the books on one course's listing.
    func finishCourse(total: Duration) -> (listing: Duration, loads: Int, pages: Int, enteredInside: Bool) {
        defer { courseLoads = 0; coursePages = 0; courseEntryTime = .zero; courseEntered = false }
        return (max(.zero, total - courseEntryTime), courseLoads, coursePages, courseEntered)
    }
}

func milliseconds(_ duration: Duration) -> Int {
    Int((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded())
}

// MARK: Cookies

enum CookieComparison {
    /// Compares by hashes only; neither a value nor a name is ever printed. `fingerprintChanged`
    /// is the vault's own rule (`RecmanSessionCodec.fingerprint`): yes means a sync would rewrite
    /// the session file.
    static func compare(before: [HTTPCookie], after: [HTTPCookie]) -> SyncReport.Cookies {
        func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        func index(_ cookies: [HTTPCookie]) -> [String: (value: String, expiry: String)] {
            Dictionary(cookies.map { ("\($0.name)|\($0.domain)|\($0.path)", (digest($0.value), $0.expiresDate.map { String($0.timeIntervalSince1970) } ?? "session")) }, uniquingKeysWith: { $1 })
        }
        let old = index(before), new = index(after)
        func fingerprint(_ cookies: [HTTPCookie]) -> String { digest(RecmanSessionCodec.fingerprint(cookies).joined(separator: "\n")) }
        return SyncReport.Cookies(
            before: before.count, after: after.count,
            fingerprintChanged: fingerprint(before) != fingerprint(after),
            added: new.keys.filter { old[$0] == nil }.count,
            removed: old.keys.filter { new[$0] == nil }.count,
            valueChanged: new.filter { old[$0.key] != nil && old[$0.key]!.value != $0.value.value }.count,
            expiryChanged: new.filter { old[$0.key] != nil && old[$0.key]!.expiry != $0.value.expiry }.count)
    }
}

// MARK: The run

/// Fixed vocabulary for a failure, never the error's own text.
func syncFailureKind(_ error: Error) -> String {
    switch error {
    case RecmanBrowserError.needsSignIn: return "needs-sign-in"
    case RecmanBrowserError.unavailable: return "failed (unavailable)"
    case RecmanBrowserError.unrecognized: return "failed (unrecognized)"
    case RecmanBrowserError.incomplete: return "failed (incomplete)"
    case RecmanBrowserError.yearUnavailable: return "failed (year unavailable)"
    case is CancellationError: return "failed (cancelled)"
    default: return "failed (other)"
    }
}

@MainActor func syncDryRun(_ parsed: SyncArguments) -> Int32 {
    let sample = parsed.courses.enumerated().map { index, _ in
        SyncReport.Course(elapsedMilliseconds: 900 + index * 150, pageLoads: 4, resultPages: 1, recordings: 12 + index, complete: true, enteredInside: index == 0, state: "ok")
    }
    let report = SyncReport(
        dryRun: true, courseCount: parsed.courses.count,
        entry: .init(elapsedMilliseconds: 2100, pageLoads: 5, loadFailures: 0, entries: 1, outcome: "archive"),
        courses: sample, totalMilliseconds: 2100 + sample.reduce(0) { $0 + $1.elapsedMilliseconds },
        memoryBefore: .init(processes: 0, megabytes: 0), memoryPeak: .init(processes: 3, megabytes: 187.4), memoryAfter: .init(processes: 0, megabytes: 0),
        cookies: .init(before: 9, after: 9, fingerprintChanged: false, added: 0, removed: 0, valueChanged: 0, expiryChanged: 0),
        needsSignIn: false, windowWouldHaveShown: false, exitState: "ok")
    renderSyncReport(report).forEach(say)
    return 0
}

/// The live measurement. Needs the owner's explicit go: it contacts Polimi with the saved session.
@MainActor func syncMode(state: URL, arguments: [String]) async -> Int32 {
    guard let parsed = parseSyncArguments(arguments) else {
        say(syncUsage)
        return 2
    }
    if parsed.dryRun { return syncDryRun(parsed) }
    let file = state.appendingPathComponent("session.plist")
    guard let data = FileManager.default.contents(atPath: file.path) else {
        say("no saved session: run cold first")
        say("EXIT no-saved-session")
        return 1
    }
    let snapshot: RecmanSessionCodec.Snapshot
    do { snapshot = try RecmanSessionCodec.decode(data) } catch {
        say("unreadable saved session: run cold first")
        say("EXIT no-saved-session")
        return 1
    }

    let memory = WebKitMemory()
    memory.markBaseline()
    let before = memory.sample()
    let tally = SyncTally()
    let sampler = Task { @MainActor in
        while !Task.isCancelled {
            _ = memory.sample()
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
    let session = RecmanWebSession()
    session.traceHandler = { tally.note($0) }
    // A background entry never asks for a window; if it ever did, nothing would be shown.
    session.presentSignInWindow = { _ in }

    let start = ContinuousClock.now
    await session.open(cookies: snapshot.cookies)
    var courses: [SyncReport.Course] = []
    var exitState = "ok"
    var needsSignIn = false
    for course in parsed.courses {
        guard let key = RecmanCourseKey(courseCode: course.code, academicYear: course.year) else { break }
        let courseStart = ContinuousClock.now
        do {
            let recordings = try await session.recordings(for: key)
            let books = tally.finishCourse(total: ContinuousClock.now - courseStart)
            courses.append(.init(elapsedMilliseconds: milliseconds(books.listing), pageLoads: books.loads, resultPages: books.pages, recordings: recordings.count, complete: true, enteredInside: books.enteredInside, state: "ok"))
        } catch {
            let books = tally.finishCourse(total: ContinuousClock.now - courseStart)
            exitState = syncFailureKind(error)
            needsSignIn = exitState == "needs-sign-in"
            courses.append(.init(elapsedMilliseconds: milliseconds(books.listing), pageLoads: books.loads, resultPages: books.pages, recordings: 0, complete: false, enteredInside: books.enteredInside, state: exitState))
            break
        }
    }
    let total = ContinuousClock.now - start
    let afterCookies = await session.cookies().filter { RecmanSessionCodec.keeps($0, now: Date()) }
    _ = memory.sample()
    session.close()
    try? await Task.sleep(for: .seconds(2))
    let after = memory.sample()
    sampler.cancel()

    let entry: SyncReport.Entry? = tally.entries > 0
        ? .init(elapsedMilliseconds: milliseconds(tally.entryTime), pageLoads: tally.entryLoads, loadFailures: tally.loadFailures, entries: tally.entries, outcome: tally.outcome)
        : nil
    let report = SyncReport(
        dryRun: false, courseCount: parsed.courses.count, entry: entry, courses: courses, totalMilliseconds: milliseconds(total),
        memoryBefore: before, memoryPeak: memory.peakSoFar, memoryAfter: after,
        cookies: CookieComparison.compare(before: snapshot.cookies, after: afterCookies),
        needsSignIn: needsSignIn, windowWouldHaveShown: tally.windowRequested, exitState: exitState)
    renderSyncReport(report).forEach(say)
    return exitState == "ok" ? 0 : 1
}
