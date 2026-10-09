import AppKit
import Foundation
import OSLog
import BeepbarCore

/// Why the Recordings page can't show something, in words for the user. The message is resolved
/// when shown, so a language switch changes it.
enum RecordingsProblem: Equatable {
    case unavailable
    case unrecognized
    case incomplete
    case yearUnavailable
    case playbackUnavailable

    init(_ error: Error) {
        switch error as? RecmanBrowserError {
        case .unavailable: self = .unavailable
        case .incomplete: self = .incomplete
        case .yearUnavailable: self = .yearUnavailable
        case .playbackUnavailable: self = .playbackUnavailable
        case .unrecognized, .needsSignIn, nil: self = .unrecognized
        }
    }

    var message: String {
        switch self {
        case .unavailable: tr("Il Politecnico non risponde. Controlla la connessione e riprova.", "Polimi isn't responding. Check your connection and try again.")
        case .unrecognized: tr("L'archivio delle registrazioni è diverso dal solito e BeepBar non riesce a leggerlo.", "The recordings archive looks different from usual and BeepBar can't read it.")
        case .incomplete: tr("L'elenco è arrivato incompleto. Riprova tra poco.", "The list came back incomplete. Try again shortly.")
        case .yearUnavailable: tr("L'archivio non ha ancora le registrazioni di quest'anno accademico.", "The archive doesn't have this academic year's recordings yet.")
        case .playbackUnavailable: tr("Non è stato possibile aprire questa registrazione.", "Couldn't open this recording.")
        }
    }
}

/// Whether the Recordings page can reach Polimi's archive.
enum RecordingsAccess: Equatable {
    /// The switch in Settings is off.
    case off
    /// On, and the saved Polimi session is assumed alive until a request says otherwise.
    case ready
    /// The Polimi sign-in is running; its window is on screen if Polimi asked for the user.
    case signingIn
    /// The Polimi session is gone (it lasts about ten days) or the last sign-in didn't finish.
    case needsSignIn(RecordingsProblem?)
}

/// One course's recordings as the page shows them. Earlier results stay while a refresh runs or
/// after it fails, so the page never goes blank because Polimi is slow.
struct RecordingsListing: Equatable {
    var recordings: [RecmanRecording]?
    var isLoading = false
    var problem: RecordingsProblem?
    var updatedAt: Date?
}

/// The Recordings feature: the switch in Settings, the Polimi session, and the recordings of the
/// synced courses, read from Polimi's archive by `RecmanBrowsing`.
///
/// Promises this class keeps, each guarded by `RecordingsControllerTests`:
/// - **On by default for Polimi, and gone when off.** Turning it off, disconnecting the WeBeep account or
///   switching university (`turnOff()`) closes the browser and deletes the saved session and
///   its notification settings. Personal study choices remain account-scoped. Another WeBeep account never inherits a Polimi session:
///   the saved one names its owner and is dropped when the known account differs.
/// - **Quiet at rest.** Nothing runs and no file is read until the Recordings page is shown or a
///   sign-in starts; the browser is closed as soon as the page is gone, unless a sign-in is on
///   screen. Nothing here takes part in quitting or in `expireCredential()`.
/// - **Nothing new writes nothing.** The session file is rewritten only when its cookies changed,
///   and the seen-recordings lists only when a recording is first seen or opened.
/// - **One request at a time, and never a stale one.** A single worker drains a queue (opening a
///   recording first, then the selected course, then the others for their badges). Turning off,
///   signing in and closing the page bump `generation`; a task from an older generation never
///   touches state again, so a late answer can't revive a turned-off feature or a closed page.
///
/// "New" recordings: the first listing of a course marks everything in it as seen (its
/// baseline), so only recordings published afterwards get the dot, until opened or marked seen.
@MainActor final class RecordingsController: ObservableObject {
    static let enabledKey = "io.github.tvaccari.beepbar.recordings-enabled.v1"
    static let acknowledgedKey = "io.github.tvaccari.beepbar.recordings-acknowledged.v1"
    static let baselinedKey = "io.github.tvaccari.beepbar.recordings-baselined.v1"
    /// Oldest ids are forgotten first; a semester of every course stays well below this.
    static let acknowledgedLimit = 5_000
    /// A course shown again within this time isn't asked for again unless the user refreshes.
    static let freshness: TimeInterval = 300

    enum OpenAction: Equatable { case play, copyLink }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var access: RecordingsAccess
    @Published private(set) var listings: [RecmanCourseKey: RecordingsListing] = [:]
    /// The recording whose player is being looked up, for its row's spinner.
    @Published private(set) var openingRecordingID: String?
    /// Why the last attempt to open a recording failed, until the next one.
    @Published private(set) var openingProblem: RecordingsProblem?
    @Published private(set) var acknowledged: Set<String>
    private var acknowledgedOrder: [String]
    private var baselined: Set<String>

    private let makeBrowser: @MainActor () -> RecmanBrowsing
    private let store: RecordingsSessionStore
    private let defaults: UserDefaults
    private let ownerUserID: @MainActor () -> Int?
    private let isAvailable: @MainActor () -> Bool
    private let openURL: @MainActor (URL) -> Void
    private let copy: @MainActor (URL) -> Void
    private let now: () -> Date
    private let log = Logger(subsystem: "io.github.tvaccari.beepbar", category: "recordings")

    private var browser: RecmanBrowsing?
    /// The WeBeep account the cookies in the browser belong to: read from the saved session, or
    /// the account connected when the user signed in. The session is saved under this id only.
    private var sessionOwner: Int?
    /// What the session file holds, so an unchanged session isn't written again.
    private var savedFingerprint: [String]?
    /// Webex players already found, so opening a recording again is instant.
    private var playbackURLs: [String: URL] = [:]

    private enum Job: Equatable {
        case list(RecmanCourseKey)
        case open(RecmanRecording, OpenAction, Int)
    }
    /// Every click, including a cached player, replaces older Play/Copy effects and errors.
    private var openingRequest = 0
    private var queue: [Job] = []
    private var runningKey: RecmanCourseKey?
    private var worker: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var generation = 0
    private var visiblePages = 0
    private var hasCheckedInitialSession = false
    /// The courses the page last asked for, reloaded after a sign-in.
    private var pageKeys: [RecmanCourseKey] = []
    private var selectedKey: RecmanCourseKey?

    init(
        makeBrowser: @escaping @MainActor () -> RecmanBrowsing = { RecmanWebSession() },
        store: RecordingsSessionStore = .standard,
        defaults: UserDefaults,
        ownerUserID: @escaping @MainActor () -> Int?,
        isAvailable: @escaping @MainActor () -> Bool,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        copy: @escaping @MainActor (URL) -> Void = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.makeBrowser = makeBrowser
        self.store = store
        self.defaults = defaults
        self.ownerUserID = ownerUserID
        self.isAvailable = isAvailable
        self.openURL = openURL
        self.copy = copy
        self.now = now
        // A switch left on for another university (only reachable through an old settings file)
        // counts as off: the feature exists only for Polimi.
        let enabled = (defaults.object(forKey: Self.enabledKey) as? Bool ?? true) && isAvailable()
        isEnabled = enabled
        access = enabled ? .ready : .off
        acknowledgedOrder = enabled ? defaults.stringArray(forKey: Self.acknowledgedKey) ?? [] : []
        acknowledged = Set(acknowledgedOrder)
        baselined = enabled ? Set(defaults.stringArray(forKey: Self.baselinedKey) ?? []) : []
    }

    // MARK: Personal study state

    @Published private(set) var study = RecordingsStudyState()
    @Published private(set) var studyProblem: BilingualText?
    private var studyOwner: Int?
    private var studyLoaded = false
    private var studyUnreadable = false
    nonisolated static func studyKey(owner: Int) -> String { "io.github.tvaccari.beepbar.recordings-study.v1.\(owner)" }

    /// Account isolation applies even when there is no saved Polimi session to invalidate.
    private func loadStudy() {
        let owner = isEnabled ? ownerUserID() : nil
        guard !studyLoaded || studyOwner != owner else { return }
        studyLoaded = true
        studyOwner = owner
        study = RecordingsStudyState()
        studyProblem = nil
        studyUnreadable = false
        guard let owner, let data = defaults.data(forKey: Self.studyKey(owner: owner)) else { return }
        do { study = try PropertyListDecoder().decode(RecordingsStudyState.self, from: data) }
        catch {
            studyUnreadable = true
            studyProblem = BilingualText("La watchlist salvata non è leggibile. I dati originali sono stati conservati.", "The saved watchlist couldn't be read. The original data has been preserved.")
        }
    }

    /// Never overwrite unreadable saved choices or write personal data before the account is known.
    private func updateStudy(_ change: (inout RecordingsStudyState) -> Void) {
        loadStudy()
        guard isEnabled, let owner = studyOwner, owner == ownerUserID(), !studyUnreadable else { return }
        var updated = study
        change(&updated)
        guard updated != study else { return }
        do {
            let data = try PropertyListEncoder().encode(updated)
            defaults.set(data, forKey: Self.studyKey(owner: owner))
            study = updated
        } catch {
            studyProblem = BilingualText("Non è stato possibile salvare la watchlist. Riprova.", "Couldn't save the watchlist. Try again.")
        }
    }

    var canEditStudy: Bool { isEnabled && studyOwner != nil && !studyUnreadable }

    func toggleWatchlist(_ recording: RecmanRecording, courseName: String) {
        updateStudy { state in
            if state.contains(recording) { state.bookmarks.removeAll { $0.id == RecordingsStudyState.identity(recording) } }
            else { state.bookmarks.append(.init(recording: recording, courseName: courseName)) }
        }
    }

    func selectDestination(_ destination: RecordingsDestination) {
        loadStudy()
        if !canEditStudy { study.destination = destination }
        else { updateStudy { $0.destination = destination } }
    }

    // MARK: Switch

    /// Whether the switch can be turned on: Polimi only, and once the WeBeep account is known,
    /// since the saved session is bound to it.
    var canTurnOn: Bool { isAvailable() && ownerUserID() != nil }

    /// What the switch in Settings does. Turning on starts the Polimi sign-in right away: its
    /// window appears only if Polimi asks for the user.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !isEnabled, canTurnOn else { return }
            isEnabled = true
            access = .ready
            defaults.set(true, forKey: Self.enabledKey)
            log.notice("Recordings turned on")
            signIn()
        } else {
            turnOff()
            defaults.set(false, forKey: Self.enabledKey)
        }
    }

    /// Browser closed and session forgotten; account-scoped study choices survive disabling the feature.
    /// Also called when the WeBeep account is disconnected or the university changes, whether or
    /// not the feature was on, so no session outlives the account it was made for.
    func turnOff() {
        invalidate()
        closeBrowser()
        isEnabled = false
        access = .off
        listings = [:]
        openingProblem = nil
        playbackURLs = [:]
        pageKeys = []
        selectedKey = nil
        forgetSeen()
        studyLoaded = false
        loadStudy()
        defaults.removeObject(forKey: Self.enabledKey)
        discardSessionFile()
    }

    // MARK: Sign-in

    /// The Polimi sign-in, from the switch or from "Accedi con Polimi". The saved session goes in
    /// first: when it is still alive, Polimi lets the browser through without a window.
    func signIn() {
        guard isEnabled, access != .signingIn else { return }
        hasCheckedInitialSession = true
        invalidate()
        access = .signingIn
        let generation = self.generation
        signInTask = Task { [weak self] in await self?.runSignIn(generation) }
    }

    private func runSignIn(_ generation: Int) async {
        let browser = currentBrowser()
        await browser.open(cookies: savedCookies())
        guard generation == self.generation else { return }
        do {
            try await browser.signIn()
        } catch {
            guard generation == self.generation else { return }
            signInTask = nil
            // Closing the window is the user's way to give up: no message for that.
            access = .needsSignIn(error is CancellationError ? nil : RecordingsProblem(error))
            log.notice("Polimi sign-in ended without the archive cancelled=\(error is CancellationError, privacy: .public)")
            if visiblePages == 0 { closeBrowser() }
            return
        }
        guard generation == self.generation else { return }
        signInTask = nil
        // The person who just signed in is whoever is connected to WeBeep now; a saved session's
        // owner only stands in while the account isn't known yet (offline launch).
        sessionOwner = ownerUserID() ?? sessionOwner
        access = .ready
        log.notice("Polimi sign-in reached the archive")
        await saveSession(generation)
        guard generation == self.generation else { return }
        if visiblePages > 0 {
            enqueue(pageKeys, selected: selectedKey, force: true)
        } else {
            closeBrowser()
        }
    }

    /// Called when the WeBeep account becomes known or changes. A session made for another
    /// account is dropped together with what that account had seen.
    func webBeepAccountChanged(to userID: Int) {
        loadStudy()
        guard let sessionOwner, sessionOwner != userID else { return }
        log.notice("Polimi session belongs to another WeBeep account: dropped")
        invalidate()
        closeBrowser()
        listings = [:]
        playbackURLs = [:]
        forgetSeen()
        discardSessionFile()
        if isEnabled { access = .needsSignIn(nil) }
    }

    // MARK: Page

    func pageAppeared() {
        loadStudy()
        visiblePages += 1
        // Keep launch and disabled recordings quiet; check only the first visit, before refresh
        // can open WebKit. Later visits must preserve a session established by explicit sign-in.
        guard isEnabled, access == .ready, !hasCheckedInitialSession else { return }
        hasCheckedInitialSession = true
        if savedCookies().isEmpty { access = .needsSignIn(nil) }
    }

    /// Deferred by one main-actor turn: a language switch rebuilds the page, which disappears and
    /// appears again at once, and that must not drop the browser and its live session.
    func pageDisappeared() {
        visiblePages = max(0, visiblePages - 1)
        Task { @MainActor [weak self] in
            guard let self, self.visiblePages == 0 else { return }
            self.suspend()
        }
    }

    /// The configuration window closed: whatever SwiftUI reports later, no page is visible.
    func windowClosed() {
        visiblePages = 0
        suspend()
    }

    /// Back to quiet: requests stop and the browser goes, while the lists stay in memory so the
    /// page shows them at once next time. A sign-in on screen is left alone: the user may be
    /// typing in it with BeepBar's window closed.
    private func suspend() {
        guard access != .signingIn else { return }
        invalidate()
        closeBrowser()
    }

    /// Brings the page's courses up to date: `selected` first, then the others, which only feed
    /// their badges. A course loaded in the last few minutes is skipped unless `force` (the
    /// refresh button), so moving around the page doesn't keep asking Polimi.
    func refresh(_ keys: [RecmanCourseKey], selected: RecmanCourseKey?, force: Bool = false) {
        guard isEnabled, visiblePages > 0 else { return }
        pageKeys = keys
        selectedKey = selected
        guard access == .ready else { return }
        enqueue(keys, selected: selected, force: force)
    }

    func listing(for key: RecmanCourseKey) -> RecordingsListing? {
        listings[key]
    }

    // MARK: Opening

    /// Opens the recording's Webex player in the default browser.
    func play(_ recording: RecmanRecording) { open(recording, .play) }

    /// Copies the link of the recording's Webex player.
    func copyLink(_ recording: RecmanRecording) { open(recording, .copyLink) }

    private func open(_ recording: RecmanRecording, _ action: OpenAction) {
        guard isEnabled, access == .ready else { return }
        openingRequest += 1
        openingProblem = nil
        openingRecordingID = recording.id
        // The cached path must replace pending openings too, or a slow lookup can later
        // overwrite the clipboard with the link chosen before the cached one.
        queue.removeAll { if case .open = $0 { true } else { false } }
        if let url = playbackURLs[recording.id] {
            finishOpening(recording, url: url, action: action)
            return
        }
        // Only the latest click counts, and it goes before any list still waiting.
        queue.insert(.open(recording, action, openingRequest), at: 0)
        startWorker()
    }

    private func finishOpening(_ recording: RecmanRecording, url: URL, action: OpenAction) {
        if openingRecordingID == recording.id { openingRecordingID = nil }
        acknowledge([recording.id])
        switch action {
        case .play: openURL(url)
        case .copyLink: copy(url)
        }
    }

    // MARK: New recordings

    func isNew(_ recording: RecmanRecording) -> Bool {
        baselined.contains(Self.baselineID(courseCode: recording.courseCode, academicYear: recording.academicYear)) && !acknowledged.contains(recording.id)
    }

    func newCount(for key: RecmanCourseKey) -> Int {
        listings[key]?.recordings?.filter(isNew).count ?? 0
    }

    /// "Segna come viste": the course's dots go away without opening every recording.
    func markSeen(_ key: RecmanCourseKey) {
        acknowledge(listings[key]?.recordings?.map(\.id) ?? [])
    }

    nonisolated static func baselineID(courseCode: String, academicYear: Int) -> String {
        "\(courseCode)-\(academicYear)"
    }

    private func acknowledge(_ ids: [String]) {
        let added = ids.filter { !acknowledged.contains($0) }
        guard !added.isEmpty else { return }
        acknowledgedOrder.append(contentsOf: added)
        if acknowledgedOrder.count > Self.acknowledgedLimit {
            acknowledgedOrder.removeFirst(acknowledgedOrder.count - Self.acknowledgedLimit)
        }
        acknowledged = Set(acknowledgedOrder)
        defaults.set(acknowledgedOrder, forKey: Self.acknowledgedKey)
    }

    private func forgetSeen() {
        acknowledgedOrder = []
        acknowledged = []
        baselined = []
        defaults.removeObject(forKey: Self.acknowledgedKey)
        defaults.removeObject(forKey: Self.baselinedKey)
    }

    // MARK: Worker

    private func needsLoad(_ key: RecmanCourseKey, force: Bool) -> Bool {
        if key == runningKey { return false }
        if force || queue.contains(.list(key)) { return true }
        guard let updatedAt = listings[key]?.updatedAt else { return true }
        return now().timeIntervalSince(updatedAt) > Self.freshness
    }

    private func enqueue(_ keys: [RecmanCourseKey], selected: RecmanCourseKey?, force: Bool) {
        var ordered: [RecmanCourseKey] = []
        for key in [selected].compactMap({ $0 }).filter({ keys.contains($0) }) + keys where !ordered.contains(key) { ordered.append(key) }
        let wanted = ordered.filter { needsLoad($0, force: force) }
        let opens = queue.filter { if case .open = $0 { true } else { false } }
        // The page's current keys replace queued listings. Keep explicit openings and the
        // in-flight listing, but stop showing spinners for work that will no longer run.
        for job in queue {
            if case .list(let key) = job, !wanted.contains(key), key != runningKey {
                listings[key]?.isLoading = false
            }
        }
        queue = opens + wanted.map(Job.list)
        for key in wanted {
            // A new attempt replaces the last one's failure: its banner next to the spinner read
            // as the new attempt having failed already.
            listings[key, default: RecordingsListing()].isLoading = true
            listings[key]?.problem = nil
        }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, access == .ready, !queue.isEmpty else { return }
        let generation = self.generation
        worker = Task { [weak self] in await self?.drain(generation) }
    }

    private enum Outcome { case next, stop, stopWithoutSaving }

    private func drain(_ generation: Int) async {
        let browser = currentBrowser()
        if !browser.isOpen { await browser.open(cookies: savedCookies()) }
        guard generation == self.generation else { return }
        var succeeded = false
        var saves = true
        while generation == self.generation, !queue.isEmpty {
            let job = queue.removeFirst()
            do {
                switch job {
                case .list(let key):
                    runningKey = key
                    let recordings = try await browser.recordings(for: key)
                    guard generation == self.generation else { return }
                    runningKey = nil
                    record(recordings, for: key)
                case .open(let recording, let action, let request):
                    let url: URL
                    if let cached = playbackURLs[recording.id] {
                        url = cached
                    } else {
                        url = try await browser.playbackURL(for: recording)
                    }
                    guard generation == self.generation else { return }
                    playbackURLs[recording.id] = url
                    if request == openingRequest { finishOpening(recording, url: url, action: action) }
                }
                succeeded = true
            } catch {
                guard generation == self.generation else { return }
                if case .open(_, _, let request) = job, request != openingRequest { continue }
                runningKey = nil
                let outcome = handle(error, of: job)
                if outcome == .next { continue }
                saves = outcome == .stop
                break
            }
        }
        guard generation == self.generation else { return }
        if succeeded, saves { await saveSession(generation) }
        guard generation == self.generation else { return }
        worker = nil
        // Courses asked for while the session was being saved.
        startWorker()
    }

    private func record(_ recordings: [RecmanRecording], for key: RecmanCourseKey) {
        var listing = listings[key] ?? RecordingsListing()
        listing.recordings = recordings
        listing.isLoading = queue.contains(.list(key))
        listing.problem = nil
        listing.updatedAt = now()
        listings[key] = listing
        updateStudy { $0.reconcile(recordings, for: key) }
        let baseline = Self.baselineID(courseCode: key.courseCode, academicYear: key.academicYear)
        if !baselined.contains(baseline) {
            baselined.insert(baseline)
            defaults.set(baselined.sorted(), forKey: Self.baselinedKey)
            acknowledge(recordings.map(\.id))
        }
    }

    private func handle(_ error: Error, of job: Job) -> Outcome {
        if case RecmanBrowserError.needsSignIn = error {
            log.notice("Polimi session lapsed")
            access = .needsSignIn(nil)
            clearQueue()
            closeBrowser()
            return .stopWithoutSaving
        }
        // Only another operation on the browser interrupts one, and only a sign-in starts one
        // while the worker runs, after bumping the generation. Nothing to tell the user.
        if error is CancellationError {
            clearQueue()
            return .stopWithoutSaving
        }
        let problem = RecordingsProblem(error)
        log.error("Recordings request failed problem=\(String(describing: problem), privacy: .public)")
        switch job {
        case .list(let key):
            listings[key, default: RecordingsListing()].problem = problem
            listings[key]?.isLoading = queue.contains(.list(key))
        case .open(let recording, _, _):
            if openingRecordingID == recording.id { openingRecordingID = nil }
            openingProblem = problem
        }
        // Offline or Polimi down: every other request would wait for the same timeout.
        guard problem == .unavailable else { return .next }
        for job in queue {
            switch job {
            case .list(let key): listings[key]?.problem = problem
            // A Play or Copy still waiting is dropped with the rest: it says why instead of the
            // click doing nothing.
            case .open: openingProblem = problem
            }
        }
        clearQueue()
        return .stop
    }

    private func clearQueue() {
        queue.removeAll()
        runningKey = nil
        openingRecordingID = nil
        for key in listings.keys where listings[key]?.isLoading == true {
            listings[key]?.isLoading = false
        }
    }

    /// Stops the worker and any sign-in for good: they belong to an older generation from now on.
    private func invalidate() {
        generation += 1
        worker?.cancel()
        worker = nil
        signInTask?.cancel()
        signInTask = nil
        clearQueue()
    }

    // MARK: Browser and session file

    private func currentBrowser() -> RecmanBrowsing {
        if let browser { return browser }
        let browser = makeBrowser()
        self.browser = browser
        return browser
    }

    private func closeBrowser() {
        browser?.close()
        browser = nil
    }

    /// The saved session's cookies, checked against the WeBeep account. A file that can't be
    /// decoded, or that belongs to another known account, is deleted; one that can't be read
    /// right now (a disk error) is kept for the next try.
    private func savedCookies() -> [HTTPCookie] {
        let data: Data?
        do {
            data = try store.load()
        } catch {
            log.error("Couldn't read the saved Polimi session")
            return []
        }
        guard let data else { return [] }
        let snapshot: RecmanSessionCodec.Snapshot
        do {
            snapshot = try RecmanSessionCodec.decode(data, now: now())
        } catch {
            log.notice("Saved Polimi session unreadable: dropped")
            discardSessionFile()
            return []
        }
        if let current = ownerUserID(), current != snapshot.ownerUserID {
            log.notice("Saved Polimi session belongs to another WeBeep account: dropped")
            listings = [:]
            playbackURLs = [:]
            forgetSeen()
            discardSessionFile()
            return []
        }
        sessionOwner = snapshot.ownerUserID
        savedFingerprint = Self.fingerprint(snapshot.cookies)
        return snapshot.cookies
    }

    /// Saves the browser's session after a success, under the account it belongs to, unless it
    /// is what the file already holds.
    private func saveSession(_ generation: Int) async {
        guard let browser else { return }
        let cookies = await browser.cookies()
        // The feature may have been turned off, or the page closed, while WebKit answered.
        guard generation == self.generation, isEnabled else { return }
        guard let owner = sessionOwner else {
            log.notice("Polimi session not saved: WeBeep account unknown")
            return
        }
        if let current = ownerUserID(), current != owner {
            webBeepAccountChanged(to: current)
            return
        }
        let fingerprint = Self.fingerprint(cookies.filter { RecmanSessionCodec.keeps($0, now: now()) })
        guard fingerprint != savedFingerprint else { return }
        do {
            try store.save(RecmanSessionCodec.encode(cookies, ownerUserID: owner, now: now()))
            savedFingerprint = fingerprint
        } catch {
            log.error("Couldn't save the Polimi session errorType=\(String(reflecting: type(of: error)), privacy: .public)")
        }
    }

    private func discardSessionFile() {
        sessionOwner = nil
        savedFingerprint = nil
        do {
            try store.delete()
        } catch {
            log.error("Couldn't delete the saved Polimi session errorType=\(String(reflecting: type(of: error)), privacy: .public)")
        }
    }

    /// What decides whether the file needs rewriting: every cookie attribute that is saved.
    nonisolated static func fingerprint(_ cookies: [HTTPCookie]) -> [String] {
        cookies.map { cookie in
            let expiry = cookie.expiresDate.map { String($0.timeIntervalSince1970) } ?? "session"
            return [cookie.name, cookie.domain, cookie.path, cookie.value, expiry, String(cookie.isSecure), String(cookie.isHTTPOnly)].joined(separator: "\u{1F}")
        }.sorted()
    }
}
