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
    case historyUnavailable

    init(_ error: Error) {
        switch error as? RecmanBrowserError {
        case .unavailable: self = .unavailable
        case .incomplete: self = .incomplete
        case .yearUnavailable: self = .yearUnavailable
        // `needsEmail` comes only from `stream(for:email:)` (native playback, #148): the product
        // decision is the same sentence as for any recording that can't be opened, with no
        // Webex email page shown to the user. It reaches the page only when Webex needs a
        // sign-in and no Polimi email was confirmed in Settings.
        case .playbackUnavailable, .needsEmail: self = .playbackUnavailable
        case .unrecognized, .needsSignIn, nil: self = .unrecognized
        }
    }

    var message: String {
        switch self {
        case .unavailable: tr("Il Politecnico non risponde. Controlla la connessione e riprova.", "Polimi isn't responding. Check your connection and try again.")
        case .unrecognized: tr("L'archivio delle registrazioni è diverso dal solito e BeepBar non riesce a leggerlo.", "The recordings archive looks different from usual and BeepBar can't read it.")
        case .incomplete: tr("L'elenco è arrivato incompleto. Riprova tra poco.", "The list came back incomplete. Try again shortly.")
        case .yearUnavailable: tr("L'archivio non ha ancora le registrazioni di quest'anno accademico.", "The archive doesn't have this academic year's recordings yet.")
        case .historyUnavailable: tr("Non è stato possibile salvare lo stato delle registrazioni. Riprova.", "Couldn’t save recording history. Try again.")
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
    /// Membership snapshot paired with this exact successfully loaded list.
    var seenIDs: Set<String>?
    /// A successful acknowledgement cannot turn a failed list refresh into a fresh one.
    var historyReadFailed = false
}

/// The Recordings feature: the switch in Settings, the Polimi session, and the recordings of the
/// synced courses, read from Polimi's archive by `RecmanBrowsing`.
///
/// Promises this class keeps, each guarded by `RecordingsControllerTests`:
/// - **On by default for Polimi, and gone when off.** Turning it off, disconnecting the WeBeep account or
///   switching university (`turnOff()`) closes the browser and deletes the saved session and
///   its notification settings and history (an opaque reset namespace remains). Personal study choices
///   remain account-scoped. Another WeBeep account never inherits a Polimi session:
///   the saved one names its owner and is dropped when the known account differs.
/// - **Quiet at rest.** Nothing runs and no file is read until the Recordings page is shown or a
///   sign-in starts; the browser is closed as soon as the page is gone, unless a sign-in is on
///   screen. Nothing here takes part in quitting or in `expireCredential()`.
/// - **Nothing new writes nothing.** The session file is rewritten only when its cookies changed,
///   and the seen-recordings lists only when a recording is first seen or opened.
/// - **The session file never touches the main actor (#97).** It is read, written and deleted by
///   `RecmanSessionVault`, off the main actor and in call order; it is read once per opening cycle,
///   and a save that began before turn-off, logout or an account change is refused at commit
///   time, so a late save can't bring the deleted session back. The delete itself finishes
///   after turn-off, logout or an account change has returned: if the process ends first, the
///   file survives until the next discard, and the owner check on the next read still refuses
///   it to another account. Quitting never waits for it (see the quit rules in AGENTS.md).
/// - **One request at a time, and never a stale one.** A single worker drains a queue (opening a
///   recording first, then the selected course, then the others for their badges). Turning off,
///   signing in and closing the page bump `generation`; a task from an older generation never
///   touches state again, so a late answer can't revive a turned-off feature or a closed page.
///
/// "New" recordings: the first listing of a course marks everything in it as seen (its
/// baseline), so only recordings published afterwards get the dot, until opened or marked seen.
///
/// Native playback (#148). Play resolves the recording's stream through the same browser and
/// plays it in BeepBar's own window; anything it can't do falls back to the default browser, as
/// Play always did. What this class keeps, each guarded by `RecordingsNativePlaybackTests`:
/// - **Nothing before the first Play.** The player is created by the first Play that has a
///   stream; no timer, observer or write runs for it at rest, and it is not part of quitting.
/// - **The player belongs to the account.** Turning the feature off, disconnecting, switching
///   university and an account change close it (`closePlayerForIdentityChange`); closing the
///   Settings window does not: a lecture keeps playing with the window closed.
/// - **Where you stopped is written only when the player reports it** (pause, close, a newer
///   Play, a failure), never on a clock; a lecture watched to the end starts from the beginning
///   again and counts as seen. The positions are stored per account and deleted with the session.
/// - **The Polimi email stays in the session file** (`RecmanSessionVault`) and nowhere else, is
///   never logged, and is deleted with the file.
/// - **A failed lecture is recovered once.** A stream that dies mid-lecture is resolved again and
///   resumes where it stopped; after that, or if it never started, the browser opens.
@MainActor final class RecordingsController: ObservableObject {
    static let enabledKey = "io.github.tvaccari.beepbar.recordings-enabled.v1"
    static let acknowledgedKey = "io.github.tvaccari.beepbar.recordings-acknowledged.v1"
    static let baselinedKey = "io.github.tvaccari.beepbar.recordings-baselined.v1"
    /// Durable reset tombstone: a failed file removal can never reuse the old namespace.
    static let historyNamespaceKey = "io.github.tvaccari.beepbar.recordings-history-namespace.v2"
    /// Where the student stopped in each lecture (`RecordingResumePoints`), for one account.
    /// Removed with the session: turn-off, disconnect and account change.
    nonisolated static let resumePointsKey = "io.github.tvaccari.beepbar.recordings-resume.v1"
    /// The WeBeep account (numeric user id) whose student removed the Polimi email in Settings:
    /// the profile's address is then never taken again for that account, also after a relaunch
    /// (an empty session file can't tell "removed" from "never set"). Holds no address. Removed
    /// with the session's identity (turn-off, disconnect, account change) and when the student
    /// enters an address again.
    nonisolated static let emailDeclinedKey = "io.github.tvaccari.beepbar.recordings-email-declined.v1"
    /// A course shown again within this time isn't asked for again unless the user refreshes.
    static let freshness: TimeInterval = 300

    /// `play`: BeepBar's player, the browser only as a fallback (#148). `browser`: the Webex
    /// player in the default browser, on purpose (the rows' "Apri nel browser" menu item, which
    /// before the package F fix ran a native Play despite its name). `copyLink`: the clipboard.
    enum OpenAction: Equatable { case play, browser, copyLink }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var access: RecordingsAccess
    /// How many course listings stay in memory (#100), the page's own included. The page's courses
    /// are pinned and never evicted, even past the bound, so reopening one stays immediate; the
    /// others (courses deselected since, bookmarked courses of other years) fill what is left and
    /// go least recently updated first. Well above a semester's courses plus a watchlist's, so in
    /// normal use nothing a user goes back to is reloaded; the bound is for sessions that stay
    /// open for weeks.
    nonisolated static let listingCapacity = 64
    /// Webex players remembered for an instant second opening; a few hundred bytes each.
    nonisolated static let playbackURLCapacity = 512

    @Published private(set) var listings: BoundedCache<RecmanCourseKey, RecordingsListing>
    /// The recording whose player is being looked up, for its row's spinner.
    @Published private(set) var openingRecordingID: String?
    /// Why the last attempt to open a recording failed, until the next one.
    @Published private(set) var openingProblem: RecordingsProblem?
    private var seenHistory: RecordingsSeenHistory
    private let makeSeenHistory: @MainActor (UUID?) -> RecordingsSeenHistory
    private var historyResetTask: Task<Void, Never>?
    private var historyRevision: [RecmanCourseKey: Int] = [:]
    private var pendingAcknowledgements: [UUID: RecmanCourseKey] = [:]
    /// Coalesce repeated clicks while the same IDs are being committed; no duplicate task queue.
    private var pendingAcknowledgementIDs: [RecmanCourseKey: Set<String>] = [:]
    private var legacyOwner: Int?
    private var legacySeen: RecordingsSeenStore.Legacy

    // MARK: Native playback state (#148)

    private let makePlayer: @MainActor () -> RecordingPlaying
    /// The WeBeep profile's email address, or nil: any failure is "ask the user", never an error.
    private let fetchProfileEmail: @MainActor () async -> String?
    /// Created by the first Play that has a stream, never earlier.
    private var player: RecordingPlaying?
    /// The lectures whose reports are still accepted, by recording id. Filled before a `play` (the
    /// lecture it replaces reports inside that call) and cut down to the new lecture right after;
    /// emptied before the player is closed for an identity change, so the close's last report is
    /// refused instead of being written under the next account.
    private var nowPlaying: [String: RecmanRecording] = [:]
    /// The lecture last handed to the player, for recoveries that outlive a newer Play.
    private var currentLectureID: String?
    /// Lectures already given their one fresh stream since the student pressed Play.
    private var recoveredLectures: Set<String> = []
    private var resumePoints: RecordingResumePoints?
    /// A recovery ran with no Recordings page on screen: the browser it opened closes after it.
    private var closesBrowserWhenIdle = false
    /// A recovery job is executing (it has left the queue).
    private var runningRecovery = false

    /// The Polimi address in use for the Webex sign-in: the one the student typed, the one the
    /// session file holds, or (product decision 2026-10-11) the WeBeep profile's, taken as
    /// confirmed without a confirmation step (`learnEmail`). Lives in the session file.
    @Published private(set) var confirmedEmail: PolimiEmail? = nil
    /// Whether `confirmedEmail` was taken from the WeBeep profile in this session (the Settings
    /// field says so, and the Play diagnostics log `email=profile`). False once the student
    /// edits it, and for an address read from the session file.
    @Published private(set) var emailFromProfile = false
    /// Whether the saved session was read, so `confirmedEmail` says what the file holds.
    private var emailLoaded = false
    /// The student changed or removed the address in this launch: it wins over what a late read
    /// finds, and the profile is not asked again.
    private var emailEditedByUser = false
    /// Bumped whenever the session (and so the email) is discarded: a late profile answer or
    /// read from before it is dropped.
    private var emailEpoch = 0
    /// The profile was asked (or is being asked) in this epoch: a failed or empty answer is not
    /// asked again at every Settings appearance or Play.
    private var suggestionAttempted = false
    /// The one profile lookup of the current epoch, shared by the Settings field and Play so a
    /// Play that starts while the Settings row is already asking waits for the same answer
    /// instead of going on without an address.
    private var emailLookup: (epoch: Int, task: Task<Void, Never>)?
    /// The WeBeep account the in-memory address (or the profile lookup) belongs to. Needed because
    /// an address can exist before any Polimi session does (the Settings field or a Play read the
    /// profile, or the student typed one, while the Polimi sign-in never completed): then
    /// `sessionOwner` is nil, and without this an account change would keep the previous
    /// account's address and send it to Webex for the new one (PR #152 review, P0).
    private var emailAccount: Int?

    private let makeBrowser: @MainActor () -> RecmanBrowsing
    private let store: RecordingsSessionStore
    /// Every run-time read, write and delete of the session file goes through here.
    private let vault: RecmanSessionVault
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
    /// The saved session as read for the current opening cycle, shared by the first visit's check,
    /// the worker and a sign-in so the file is read once, not once per caller. Forgotten when the
    /// browser closes (the next opening reads again), when the file is discarded, after a save
    /// wrote new cookies, and after a read error (kept for the next try).
    private var sessionLoad: (id: Int, task: Task<[HTTPCookie], Never>)?
    /// Identifies each read, so a failed one clears the cache only if it is still the cached one.
    private var sessionLoads = 0
    /// The first visit's check of the saved session, while it is reading the file. Until it answers
    /// nothing opens the browser: without a reusable session the page asks for a sign-in instead,
    /// as when the check was synchronous. Sign-in, turn-off and an account change supersede it.
    private var initialSessionCheck: Int?
    /// Identifies each first-visit check, so a superseded one can't apply its answer.
    private var initialSessionChecks = 0
    /// Webex players already found, so opening a recording again is instant. Bounded (#100): it
    /// used to grow with every recording opened until the feature was turned off.
    private var playbackURLs: BoundedCache<String, URL>

    private enum Job: Equatable {
        case list(RecmanCourseKey)
        case open(RecmanRecording, OpenAction, Int)
        /// A lecture in the player went wrong (#148): not a click, so it changes no spinner.
        case recover(RecmanRecording, Recovery)
    }

    /// What to do about a lecture that failed in the player.
    enum Recovery: Equatable {
        /// Resolve the stream again and resume at this position: its address expired or the
        /// connection dropped.
        case freshStream(at: TimeInterval)
        /// Open the player link in the browser.
        case browser
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
        makeSeenHistory: (@MainActor (UUID?) -> RecordingsSeenHistory)? = nil,
        ownerUserID: @escaping @MainActor () -> Int?,
        isAvailable: @escaping @MainActor () -> Bool,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        copy: @escaping @MainActor (URL) -> Void = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        },
        now: @escaping () -> Date = Date.init,
        makePlayer: @escaping @MainActor () -> RecordingPlaying = { RecordingPlayerController() },
        fetchProfileEmail: @escaping @MainActor () async -> String? = { nil },
        listingCapacity: Int = RecordingsController.listingCapacity,
        playbackURLCapacity: Int = RecordingsController.playbackURLCapacity
    ) {
        self.makePlayer = makePlayer
        self.fetchProfileEmail = fetchProfileEmail
        listings = BoundedCache(capacity: listingCapacity)
        playbackURLs = BoundedCache(capacity: playbackURLCapacity)
        self.makeBrowser = makeBrowser
        self.store = store
        self.vault = RecmanSessionVault(storage: .init(load: { try store.load() }, save: { try store.save($0) }, delete: { try store.delete() }))
        let historyFactory = makeSeenHistory ?? { namespace in
            RecordingsSeenHistory(store: RecordingsSeenStore(directory: store.directory, namespace: namespace))
        }
        self.makeSeenHistory = historyFactory
        let savedNamespace = defaults.string(forKey: Self.historyNamespaceKey)
        let namespace = savedNamespace.flatMap(UUID.init(uuidString:))
        if savedNamespace != nil && namespace == nil {
            // An invalid tombstone must not fall back to the pre-reset canonical database.
            let replacement = UUID()
            defaults.set(replacement.uuidString, forKey: Self.historyNamespaceKey)
            self.seenHistory = historyFactory(replacement)
        } else {
            self.seenHistory = historyFactory(namespace)
        }
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
        legacySeen = .init(ids: enabled ? defaults.stringArray(forKey: Self.acknowledgedKey) ?? [] : [], baselines: enabled ? defaults.stringArray(forKey: Self.baselinedKey) ?? [] : [])
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

    /// Browser closed and session/history forgotten; a persisted opaque namespace prevents reuse
    /// if history cleanup fails. Account-scoped study choices survive disabling the feature.
    /// Also called when the WeBeep account is disconnected or the university changes, whether or
    /// not the feature was on, so no session outlives the account it was made for.
    func turnOff() {
        supersedeInitialSessionCheck()
        // The lecture on screen belongs to the account being forgotten. First, because closing it
        // reports where the student stopped, and that report must find nothing to write.
        closePlayerForIdentityChange()
        invalidate()
        closeBrowser()
        isEnabled = false
        access = .off
        listings.removeAll()
        listings.pin([])
        openingProblem = nil
        playbackURLs.removeAll()
        pageKeys = []
        selectedKey = nil
        forgetSeen()
        forgetResumePoints()
        forgetEmailOptOut()
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
        supersedeInitialSessionCheck()
        invalidate()
        access = .signingIn
        let generation = self.generation
        signInTask = Task { [weak self] in await self?.runSignIn(generation) }
    }

    private func runSignIn(_ generation: Int) async {
        let browser = currentBrowser()
        let cookies = await savedCookies()
        guard generation == self.generation else { return }
        await browser.open(cookies: cookies)
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
        // Before the session check: an address learned with no Polimi session yet belongs to the
        // account that was signed in then, not to this one.
        if let emailAccount, emailAccount != userID {
            log.notice("Polimi email belongs to another WeBeep account: dropped")
            resetEmail()
        }
        guard let sessionOwner, sessionOwner != userID else { return }
        log.notice("Polimi session belongs to another WeBeep account: dropped")
        supersedeInitialSessionCheck()
        closePlayerForIdentityChange()
        invalidate()
        closeBrowser()
        listings.removeAll()
        playbackURLs.removeAll()
        forgetSeen()
        forgetResumePoints()
        forgetEmailOptOut()
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
        initialSessionChecks += 1
        let check = initialSessionChecks
        initialSessionCheck = check
        // Not tied to `generation`: closing the page while the file is read must not lose the
        // answer, or the next visit would open the browser without a session to show.
        Task { [weak self] in
            guard let self else { return }
            let cookies = await self.savedCookies()
            guard self.initialSessionCheck == check else { return }
            self.initialSessionCheck = nil
            guard self.isEnabled, self.access == .ready else { return }
            if cookies.isEmpty {
                self.clearQueue()
                self.access = .needsSignIn(nil)
                return
            }
            // What the page asked for while the file was read. No `force` to carry over: this is
            // the first visit, so nothing has been listed yet and every key loads anyway.
            if self.visiblePages > 0 { self.enqueue(self.pageKeys, selected: self.selectedKey, force: false) }
            self.startWorker()
        }
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
    /// Deliberately leaves the player alone: a lecture keeps playing with this window closed
    /// (`suspend` stops only requests and the browser, and the stream needs neither).
    func windowClosed() {
        visiblePages = 0
        suspend()
    }

    /// Back to quiet: requests stop and the browser goes, while the lists stay in memory so the
    /// page shows them at once next time. A sign-in on screen is left alone: the user may be
    /// typing in it with BeepBar's window closed.
    ///
    /// A lecture recovery (queued or running) is the exception: the student is watching a lecture
    /// that stopped, and cancelling its fresh stream because a window closed would leave it
    /// paused and silent with its one retry spent. Only the course listings are dropped then; the
    /// browser closes when the recovery has drained (`closesBrowserWhenIdle`).
    private func suspend() {
        guard access != .signingIn else { return }
        if hasRecovery {
            dropQueuedListings()
            dropQueuedOpenings()
            closesBrowserWhenIdle = true
            return
        }
        invalidate()
        closeBrowser()
    }

    /// Whether a recovery is queued or running.
    private var hasRecovery: Bool {
        runningRecovery || queue.contains { if case .recover = $0 { true } else { false } }
    }

    /// Removes the listings still waiting (not the one in flight) and their spinners.
    private func dropQueuedListings() {
        for job in queue {
            if case .list(let key) = job, key != runningKey { listings[key]?.isLoading = false }
        }
        queue.removeAll { if case .list = $0 { true } else { false } }
    }

    /// Removes the clicks still waiting (Play, Open in browser, Copy link) and their spinner: with
    /// the window closed nobody is waiting for them, and a Play would otherwise start a lecture,
    /// a browser or a sign-in window after the recovery ahead of it (PR #152 review). The one in
    /// flight, if any, finishes, as it did before the recovery exception.
    private func dropQueuedOpenings() {
        for job in queue {
            if case .open(let recording, _, _) = job, openingRecordingID == recording.id { openingRecordingID = nil }
        }
        queue.removeAll { if case .open = $0 { true } else { false } }
    }

    /// Brings the page's courses up to date: `selected` first, then the others, which only feed
    /// their badges. A course loaded in the last few minutes is skipped unless `force` (the
    /// refresh button), so moving around the page doesn't keep asking Polimi.
    func refresh(_ keys: [RecmanCourseKey], selected: RecmanCourseKey?, force: Bool = false) {
        guard isEnabled, visiblePages > 0 else { return }
        pageKeys = keys
        selectedKey = selected
        // What the page shows is never evicted, so going back to one of its courses is immediate.
        // Compared first: `listings` is published, and an unchanged page must not redraw.
        let onPage = Set(keys + [selected].compactMap { $0 })
        if listings.pinnedKeys != onPage { listings.pin(onPage) }
        guard access == .ready else { return }
        // The initial check enqueues these keys itself once it knows a session exists.
        guard initialSessionCheck == nil else { return }
        enqueue(keys, selected: selected, force: force)
    }

    func listing(for key: RecmanCourseKey) -> RecordingsListing? {
        listings[key]
    }

    // MARK: Opening

    /// Plays the recording in BeepBar's own player; when that isn't possible, opens its Webex
    /// player in the default browser, as Play did before native playback.
    func play(_ recording: RecmanRecording) { open(recording, .play) }

    /// Opens the recording's Webex player in the default browser, without trying BeepBar's own
    /// player: the menu item that says so. Like Copy link, it is answered from the cached link
    /// when there is one.
    func openInBrowser(_ recording: RecmanRecording) { open(recording, .browser) }

    /// Copies the link of the recording's Webex player.
    func copyLink(_ recording: RecmanRecording) { open(recording, .copyLink) }

    private func open(_ recording: RecmanRecording, _ action: OpenAction) {
        guard isEnabled, access == .ready else { return }
        openingRequest += 1
        openingProblem = nil
        openingRecordingID = recording.id
        // The cached path must replace pending openings too, or a slow lookup can later
        // overwrite the clipboard with the link chosen before the cached one.
        // A new Play replaces a waiting recovery (the student moved on); Copy link doesn't: it
        // has nothing to do with the lecture that stopped.
        queue.removeAll { job in
            if case .open = job { return true }
            if case .recover = job { return action == .play }
            return false
        }
        // Only the link can be answered from memory (Copy link, Open in browser): a native Play
        // always asks for a fresh stream, since its address is short-lived and tied to a sign-in.
        if action != .play, let url = playbackURLs[recording.id] {
            finishOpening(recording, url: url, action: action)
            return
        }
        // Only the latest click counts, and it goes before any list still waiting.
        queue.insert(.open(recording, action, openingRequest), at: 0)
        startWorker()
    }

    private func finishOpening(_ recording: RecmanRecording, url: URL, action: OpenAction) {
        markOpened(recording)
        switch action {
        case .play, .browser: openURL(url)
        case .copyLink: copy(url)
        }
    }

    /// The row stops spinning and the recording stops being new.
    private func markOpened(_ recording: RecmanRecording) {
        if openingRecordingID == recording.id { openingRecordingID = nil }
        if let key = RecmanCourseKey(courseCode: recording.courseCode, academicYear: recording.academicYear) { scheduleAcknowledge([recording.id], for: key, opening: openingRequest) }
    }

    private static func isOpening(_ job: Job) -> Bool {
        switch job {
        case .open, .recover: true
        case .list: false
        }
    }

    // MARK: New recordings

    /// Pure memory lookup: a list is published only with its matching membership snapshot.
    /// No disk read, lazy migration or aggregate scan runs from SwiftUI row evaluation.
    func isNew(_ recording: RecmanRecording) -> Bool {
        guard let key = RecmanCourseKey(courseCode: recording.courseCode, academicYear: recording.academicYear),
              let seen = listings[key]?.seenIDs else { return false }
        return !seen.contains(recording.id)
    }

    func newCount(for key: RecmanCourseKey) -> Int {
        guard let listing = listings[key], let seen = listing.seenIDs else { return 0 }
        return listing.recordings?.reduce(0) { $0 + (seen.contains($1.id) ? 0 : 1) } ?? 0
    }

    /// Dots clear after the serialized worker commits their durable acknowledgement.
    func markSeen(_ key: RecmanCourseKey) {
        scheduleAcknowledge(listings[key]?.recordings?.map(\.id) ?? [], for: key)
    }

    nonisolated static func baselineID(courseCode: String, academicYear: Int) -> String {
        "\(courseCode)-\(academicYear)"
    }

    private func scheduleAcknowledge(_ ids: [String], for key: RecmanCourseKey, opening: Int? = nil) {
        guard let owner = sessionOwner ?? ownerUserID(), !ids.isEmpty else { return }
        let pending = pendingAcknowledgementIDs[key] ?? []
        let added = ids.filter { !(listings[key]?.seenIDs?.contains($0) ?? false) && !pending.contains($0) }
        guard !added.isEmpty else { return }
        let history = seenHistory
        let generation = self.generation
        let legacy = legacy(for: owner)
        let reset = historyResetTask
        let operation = UUID()
        pendingAcknowledgements[operation] = key
        pendingAcknowledgementIDs[key, default: []].formUnion(added)
        Task { [weak self] in
            guard let self else { return }
            defer {
                // A reset removes the operation token; its old completion must not subtract
                // IDs belonging to a later account's acknowledgement of the same course.
                if self.pendingAcknowledgements.removeValue(forKey: operation) != nil {
                    self.pendingAcknowledgementIDs[key]?.subtract(added)
                    if self.pendingAcknowledgementIDs[key]?.isEmpty == true { self.pendingAcknowledgementIDs.removeValue(forKey: key) }
                }
            }
            await reset?.value
            // Explicit user acknowledgements persist when the page closes, but never after
            // an account/reset boundary. Their fixed scoped IDs remain valid across page generations.
            guard self.isCurrentIdentity(history, owner: owner) else { return }
            do {
                try await history.acknowledge(owner: owner, key: key, ids: added, legacy: legacy)
                guard self.isCurrentIdentity(history, owner: owner) else { return }
                self.discardLegacyDefaults()
                self.historyRevision[key, default: 0] += 1
                // Explicit acknowledgement IDs belong to this account/course, so they remain
                // valid across page generations (close/reopen). Never publish old browser/list
                // results here: only merge the committed IDs into a current matching snapshot.
                // Opening before the first listing still does not establish a baseline.
                if self.listings[key]?.seenIDs != nil { self.listings[key]?.seenIDs?.formUnion(added) }
                if self.listings[key]?.historyReadFailed != true, self.listings[key]?.problem == .historyUnavailable { self.listings[key]?.problem = nil }
            } catch {
                guard self.isCurrentHistory(history, owner: owner, generation: generation) else { return }
                self.listings[key]?.problem = .historyUnavailable
                if let opening, opening == self.openingRequest { self.openingProblem = .historyUnavailable }
                self.log.error("Couldn't save recording history")
            }
        }
    }

    /// Validate both identity and lifecycle after every await, before publishing or scheduling
    /// another operation. The old actor is also invalidated at reset, so queued writes reject.
    private func isCurrentHistory(_ history: RecordingsSeenHistory, owner: Int, generation: Int) -> Bool {
        self.generation == generation && isCurrentIdentity(history, owner: owner)
    }

    private func isCurrentIdentity(_ history: RecordingsSeenHistory, owner: Int) -> Bool {
        isEnabled && seenHistory === history && (sessionOwner ?? ownerUserID()) == owner &&
            (ownerUserID() == nil || ownerUserID() == owner)
    }

    /// Import only history whose saved session verified this account. A failed session read
    /// preserves v1 for retry, but does not authorize attaching it to a later fresh sign-in.
    private func legacy(for owner: Int) -> RecordingsSeenStore.Legacy {
        legacyOwner == owner ? legacySeen : .init(ids: [], baselines: [])
    }

    /// v1 keys are removed only after the SQLite migration committed. Keeping legacySeen in
    /// memory until reset lets a failed first migration retry without losing surviving IDs.
    private func discardLegacyDefaults() {
        for key in [Self.acknowledgedKey, Self.baselinedKey] where defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
    }

    private func forgetSeen() {
        for key in listings.keys { listings[key]?.seenIDs = nil }
        historyRevision = [:]
        pendingAcknowledgements = [:]
        pendingAcknowledgementIDs = [:]
        legacySeen = .init(ids: [], baselines: [])
        legacyOwner = nil
        defaults.removeObject(forKey: Self.acknowledgedKey)
        defaults.removeObject(forKey: Self.baselinedKey)
        // Rotate the persisted namespace before asynchronous cleanup. Removal can fail, but
        // neither re-enable nor restart ever reads that previous namespace again (#106).
        let namespace = UUID()
        defaults.set(namespace.uuidString, forKey: Self.historyNamespaceKey)
        let previous = seenHistory
        previous.invalidate()
        let reset = historyResetTask
        seenHistory = makeSeenHistory(namespace)
        historyResetTask = Task { [log] in
            await reset?.value
            do { try await previous.invalidateAndDelete() }
            catch { log.error("Couldn't delete obsolete recording history; next use retries cleanup") }
        }
    }

    // MARK: Worker

    private func needsLoad(_ key: RecmanCourseKey, force: Bool) -> Bool {
        if key == runningKey { return false }
        if force || queue.contains(.list(key)) { return true }
        if listings[key]?.problem == .historyUnavailable { return true }
        guard let updatedAt = listings[key]?.updatedAt else { return true }
        return now().timeIntervalSince(updatedAt) > Self.freshness
    }

    private func enqueue(_ keys: [RecmanCourseKey], selected: RecmanCourseKey?, force: Bool) {
        var ordered: [RecmanCourseKey] = []
        for key in [selected].compactMap({ $0 }).filter({ keys.contains($0) }) + keys where !ordered.contains(key) { ordered.append(key) }
        let wanted = ordered.filter { needsLoad($0, force: force) }
        let opens = queue.filter(Self.isOpening)
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
        guard worker == nil, access == .ready, initialSessionCheck == nil, !queue.isEmpty else { return }
        let generation = self.generation
        worker = Task { [weak self] in await self?.drain(generation) }
    }

    private enum Outcome { case next, stop, stopWithoutSaving }

    private func drain(_ generation: Int) async {
        let browser = currentBrowser()
        if !browser.isOpen {
            let cookies = await savedCookies()
            guard generation == self.generation else { return }
            await browser.open(cookies: cookies)
        }
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
                    await record(recordings, for: key, generation: generation)
                    guard generation == self.generation else { return }
                    runningKey = nil
                case .open(let recording, .copyLink, let request):
                    let url = try await playerLink(for: recording, browser: browser)
                    guard generation == self.generation else { return }
                    playbackURLs[recording.id] = url
                    if request == openingRequest { finishOpening(recording, url: url, action: .copyLink) }
                case .open(let recording, .browser, let request):
                    let url = try await playerLink(for: recording, browser: browser)
                    guard generation == self.generation else { return }
                    playbackURLs[recording.id] = url
                    if request == openingRequest { finishOpening(recording, url: url, action: .browser) }
                case .open(let recording, .play, let request):
                    try await playNatively(recording, request: request, browser: browser, generation: generation)
                    guard generation == self.generation else { return }
                case .recover(let recording, let recovery):
                    runningRecovery = true
                    defer { runningRecovery = false }
                    try await recoverPlayback(recording, recovery, browser: browser, generation: generation)
                    guard generation == self.generation else { return }
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
        // A recovery ran for a lecture while no Recordings page was on screen: the browser it
        // needed has no reason to stay open (the stream doesn't use it).
        if closesBrowserWhenIdle, queue.isEmpty, visiblePages == 0, access != .signingIn {
            closesBrowserWhenIdle = false
            closeBrowser()
        }
        // Courses asked for while the session was being saved.
        startWorker()
    }

    // MARK: Native playback (#148)

    /// The Webex player link of a recording, from memory when it was found before.
    private func playerLink(for recording: RecmanRecording, browser: RecmanBrowsing, found: URL? = nil) async throws -> URL {
        if let found { return found }
        if let cached = playbackURLs[recording.id] { return cached }
        return try await browser.playbackURL(for: recording)
    }

    /// What actually failed in a stream lookup, and the player link it had found by then, if any
    /// (`RecmanStreamFailure`). Every decision and log line reads the cause, never the wrapper.
    nonisolated static func streamFailureCause(_ error: Error) -> (cause: Error, player: URL?) {
        if let failure = error as? RecmanStreamFailure { return (failure.underlying, failure.player) }
        return (error, nil)
    }

    /// What a failed stream lookup means for a Play. Pure, so it is tested without a browser.
    enum StreamFailureOutcome: Equatable {
        /// Open the player link in the browser, as Play did before native playback.
        case browser
        /// Report it like any other failure of a request: the page says why.
        case report
    }

    /// Everything Webex can't give us falls back to the browser: an unrecognized page or answer,
    /// a stream without HLS, a failed hop. What stays a report is what the browser can't fix and
    /// the page already knows how to say: the Polimi session lapsing, Polimi being unreachable, a
    /// missing confirmed email (the product decision: no Webex email page is shown to the
    /// student), and cancellation.
    nonisolated static func streamFailureOutcome(_ error: Error) -> StreamFailureOutcome {
        if error is CancellationError { return .report }
        switch error as? RecmanBrowserError {
        case .needsSignIn, .needsEmail, .unavailable: return .report
        default: return .browser
        }
    }

    /// What to do about a failed play. A stream that never started goes to the browser (the
    /// player already closed its window). One that stopped mid-lecture gets one fresh stream at
    /// the position it stopped, then the browser: a second failure in the same Play means the
    /// problem isn't an expired address.
    nonisolated static func recovery(for failure: RecordingPlaybackFailure, alreadyRecovered: Bool) -> Recovery {
        switch failure {
        case .beforeReady: return .browser
        case .duringPlayback(_, let position): return alreadyRecovered ? .browser : .freshStream(at: position)
        }
    }

    /// Why a Play didn't reach BeepBar's player, for the Play diagnostics (#148, package F fix).
    /// Before them every such Play logged the same "opening the browser" line, so a user report
    /// ("Play opens the browser") couldn't say which step failed.
    enum PlayFailureReason: String, Equatable {
        /// Webex answered something native playback doesn't handle (`playbackUnavailable`): the
        /// resolver's own `stream:` lines say which step and what it saw.
        case nativeUnavailable = "native-unavailable"
        /// The Polimi session lapsed: the page asks for a sign-in.
        case needsSignIn = "needs-sign-in"
        /// Webex needs a sign-in and no Polimi email was confirmed in Settings.
        case noEmail = "no-email"
        /// Polimi or Webex didn't answer (offline, a timeout).
        case unreachable = "unreachable"
        /// Interrupted (a newer operation, the user closed the sign-in window).
        case cancelled = "cancelled"
        /// Any other error on the way to the stream (the archive looked different, an error
        /// BeepBar doesn't know).
        case streamError = "stream-error"
        /// The stream was found but the player couldn't play it.
        case playerFailure = "player-failure"
    }

    nonisolated static func playFailureReason(_ error: Error) -> PlayFailureReason {
        if error is CancellationError { return .cancelled }
        switch error as? RecmanBrowserError {
        case .playbackUnavailable: return .nativeUnavailable
        case .needsSignIn: return .needsSignIn
        case .needsEmail: return .noEmail
        case .unavailable: return .unreachable
        case .unrecognized, .incomplete, .yearUnavailable, nil: return .streamError
        }
    }

    /// The log line of a Play whose stream lookup failed: what happens next (the browser, or
    /// nothing but the page's message), why, and the error's privacy-safe name. Pure, so tests
    /// read exactly what is logged; never the email, an address or a title.
    nonisolated static func playDiagnosis(_ error: Error) -> String {
        let next = streamFailureOutcome(error) == .browser ? "browser" : "none"
        return "play: fallback=\(next) reason=\(playFailureReason(error).rawValue) error=\(PlaybackDiagnostics.errorName(error))"
    }

    /// The log line of a play the player reported as failed, with the phase and the error's
    /// domain and code (AVFoundation's, and the underlying one that names the real cause).
    nonisolated static func playerFailureDiagnosis(_ failure: RecordingPlaybackFailure, recovery: Recovery) -> String {
        let phase: String
        let cause: Error?
        switch failure {
        case .beforeReady(let error):
            phase = "before-ready"
            cause = error
        case .duringPlayback(let error, _):
            phase = "during-playback"
            cause = error
        }
        let next: String
        switch recovery {
        case .browser: next = "browser"
        case .freshStream: next = "fresh-stream"
        }
        // `recovery`: what the controller decides (`recovery(for:alreadyRecovered:)`); with no
        // Polimi session it shows the page's message instead.
        return "play: player failed phase=\(phase) recovery=\(next) reason=\(PlayFailureReason.playerFailure.rawValue) error=\(PlaybackDiagnostics.errorName(cause))"
    }

    /// `confirmed` (typed, or read from the session file), `profile` (taken from WeBeep in this
    /// session) or `none`: the Play log's word for the address, which is never logged itself.
    nonisolated static func emailDiagnosis(_ email: PolimiEmail?, fromProfile: Bool) -> String {
        guard email != nil else { return "none" }
        return fromProfile ? "profile" : "confirmed"
    }

    private func playNatively(_ recording: RecmanRecording, request: Int, browser: RecmanBrowsing, generation: Int) async throws {
        // No address yet: the WeBeep profile's is taken now (at most once per epoch), so the
        // very first Play works without the Settings row ever having appeared.
        if confirmedEmail == nil {
            await learnEmail()
            guard generation == self.generation else { return }
        }
        // Where the address came from, never the address: with none, a Play that needs a Webex
        // sign-in can only show the message.
        let emailState = Self.emailDiagnosis(confirmedEmail, fromProfile: emailFromProfile)
        PlaybackDiagnostics.log.notice("play: start email=\(emailState, privacy: .public)")
        let stream: RecordingStream
        do {
            stream = try await browser.stream(for: recording, email: confirmedEmail)
        } catch {
            guard generation == self.generation else { return }
            let (cause, found) = Self.streamFailureCause(error)
            let diagnosis = Self.playDiagnosis(cause)
            PlaybackDiagnostics.log.notice("\(diagnosis, privacy: .public)")
            guard Self.streamFailureOutcome(cause) == .browser else { throw cause }
            log.notice("Native playback not available: opening the browser")
            let url = try await playerLink(for: recording, browser: browser, found: found)
            guard generation == self.generation else { return }
            playbackURLs[recording.id] = url
            if request == openingRequest { finishOpening(recording, url: url, action: .play) }
            return
        }
        guard generation == self.generation else { return }
        // A newer click replaced this one while the stream was being found: it wins.
        guard request == openingRequest else { return }
        recoveredLectures.remove(recording.id)
        PlaybackDiagnostics.log.notice("play: stream found, handing it to the player")
        startPlayer(stream, for: recording, startAt: RecordingPlaybackProgress.startAt(stored: storedPosition(for: recording)))
        markOpened(recording)
    }

    /// Hands the stream to the player, creating it on first use. The title is the archive's own
    /// (already on the page), not Webex's; the stream address is never logged.
    private func startPlayer(_ stream: RecordingStream, for recording: RecmanRecording, startAt: TimeInterval?) {
        let player = currentPlayer()
        // Before the call: the lecture this one replaces reports its position inside `play`.
        nowPlaying[recording.id] = recording
        currentLectureID = recording.id
        player.play(stream.url, title: recording.title.isEmpty ? (stream.title ?? "") : recording.title, cookies: [], startAt: startAt, recordingID: recording.id)
        nowPlaying = nowPlaying.filter { $0.key == recording.id }
        recoveredLectures = recoveredLectures.intersection(nowPlaying.keys)
    }

    private func currentPlayer() -> RecordingPlaying {
        if let player { return player }
        let player = makePlayer()
        player.onPositionCheckpoint = { [weak self] id, position, duration in
            self?.playerCheckpoint(id: id, position: position, duration: duration)
        }
        player.onFailure = { [weak self] id, failure in
            self?.playerFailed(id: id, failure: failure)
        }
        self.player = player
        return player
    }

    var isPlayerOpen: Bool { player?.isOpen ?? false }

    /// For code that raised BeepBar to a regular app and finds a lecture open when it is done
    /// (`WeBeepAuthenticationController.chooseRoot`): the player restores `policy` when it closes.
    func keepPolicyAfterLecture(_ policy: NSApplication.ActivationPolicy) {
        player?.adoptPolicyToRestore(policy)
    }

    /// The identity the lecture belongs to is going away (turn-off, disconnect, university or
    /// account change): the player closes and its last report is refused. Safe with no player.
    private func closePlayerForIdentityChange() {
        nowPlaying = [:]
        currentLectureID = nil
        recoveredLectures = []
        player?.close()
    }

    // MARK: Where you stopped

    private func resumeOwner() -> Int? {
        guard isEnabled, let owner = sessionOwner ?? ownerUserID() else { return nil }
        // The account WeBeep says is connected, when it is known, must be the one the session
        // was made for: positions are never written under a different one.
        if let current = ownerUserID(), current != owner { return nil }
        return owner
    }

    /// The stored positions of `owner`: another account's are never read, and unreadable ones
    /// count as empty (a lost position costs a few seconds of scrubbing, not data).
    private func loadedResumePoints(owner: Int) -> RecordingResumePoints {
        if let resumePoints, resumePoints.owner == owner { return resumePoints }
        var loaded = RecordingResumePoints(owner: owner)
        if let data = defaults.data(forKey: Self.resumePointsKey),
           let stored = try? PropertyListDecoder().decode(RecordingResumePoints.self, from: data), stored.owner == owner {
            loaded = stored
        }
        resumePoints = loaded
        return loaded
    }

    private func storedPosition(for recording: RecmanRecording) -> TimeInterval? {
        guard let owner = resumeOwner() else { return nil }
        return loadedResumePoints(owner: owner).position(for: RecordingsStudyState.identity(recording))
    }

    /// The player's report of where the student stopped. Written only when it changes what is
    /// stored; a lecture watched to the end is forgotten and counts as seen.
    private func playerCheckpoint(id: String, position: TimeInterval, duration: TimeInterval?) {
        guard let recording = nowPlaying[id], let owner = resumeOwner() else { return }
        let update = RecordingPlaybackProgress.update(position: position, duration: duration)
        var points = loadedResumePoints(owner: owner)
        if points.apply(update, for: RecordingsStudyState.identity(recording)) {
            resumePoints = points
            if points.entries.isEmpty {
                if defaults.object(forKey: Self.resumePointsKey) != nil { defaults.removeObject(forKey: Self.resumePointsKey) }
            } else if let data = try? PropertyListEncoder().encode(points) {
                defaults.set(data, forKey: Self.resumePointsKey)
            } else {
                log.error("Couldn't save the playback position")
            }
        }
        if update == .finished, let key = RecmanCourseKey(courseCode: recording.courseCode, academicYear: recording.academicYear) {
            scheduleAcknowledge([recording.id], for: key)
        }
    }

    /// Removes stored positions that don't belong to `owner`, without a controller: an account
    /// change in a launch that never created Recordings must not leave the previous account's
    /// places behind. Unreadable data goes too (it can't be shown to be this account's).
    nonisolated static func forgetResumePoints(in defaults: UserDefaults, notOwnedBy owner: Int) {
        guard let data = defaults.data(forKey: resumePointsKey) else { return }
        if let stored = try? PropertyListDecoder().decode(RecordingResumePoints.self, from: data), stored.owner == owner { return }
        defaults.removeObject(forKey: resumePointsKey)
    }

    /// Removes the "email removed" marker (`emailDeclinedKey`) unless it is `owner`'s, without a
    /// controller: an account change in a launch that never created Recordings.
    nonisolated static func forgetEmailOptOut(in defaults: UserDefaults, notOwnedBy owner: Int) {
        guard defaults.object(forKey: emailDeclinedKey) != nil, defaults.integer(forKey: emailDeclinedKey) != owner else { return }
        defaults.removeObject(forKey: emailDeclinedKey)
    }

    /// The marker goes with the identity: turn-off, disconnect and account change.
    private func forgetEmailOptOut() {
        if defaults.object(forKey: Self.emailDeclinedKey) != nil { defaults.removeObject(forKey: Self.emailDeclinedKey) }
    }

    /// Whether the student of `owner` removed the address in Settings (in any launch).
    private func emailDeclined(by owner: Int?) -> Bool {
        guard let owner, defaults.object(forKey: Self.emailDeclinedKey) != nil else { return false }
        return defaults.integer(forKey: Self.emailDeclinedKey) == owner
    }

    /// Positions go with the session: turn-off, disconnect and account change.
    private func forgetResumePoints() {
        resumePoints = nil
        if defaults.object(forKey: Self.resumePointsKey) != nil { defaults.removeObject(forKey: Self.resumePointsKey) }
    }

    // MARK: Recovery

    private func playerFailed(id: String, failure: RecordingPlaybackFailure) {
        guard isEnabled, let recording = nowPlaying[id] else { return }
        // The retry is spent when the recovery runs (`recoverPlayback`), not here: a failure
        // that can't be recovered now (no Polimi session) or a recovery that never starts must
        // not use it up.
        let recovery = Self.recovery(for: failure, alreadyRecovered: recoveredLectures.contains(id))
        // A stream that was found but never played ends in the browser from here: without this
        // line it looked exactly like a stream that was never found (#148, package F diagnostics).
        let diagnosis = Self.playerFailureDiagnosis(failure, recovery: recovery)
        PlaybackDiagnostics.log.notice("\(diagnosis, privacy: .public)")
        guard access == .ready else {
            // No Polimi session to look anything up with: the student has to sign in again.
            if case .beforeReady = failure { openingProblem = .playbackUnavailable }
            return
        }
        if visiblePages == 0 { closesBrowserWhenIdle = true }
        queue.insert(.recover(recording, recovery), at: 0)
        startWorker()
    }

    private func recoverPlayback(_ recording: RecmanRecording, _ recovery: Recovery, browser: RecmanBrowsing, generation: Int) async throws {
        // The player link a failed fresh-stream lookup already found, for the browser below.
        var found: URL?
        if case .freshStream(let position) = recovery {
            guard stillShowing(recording) else { return }
            recoveredLectures.insert(recording.id)
            if confirmedEmail == nil {
                await learnEmail()
                guard generation == self.generation else { return }
            }
            do {
                let stream = try await browser.stream(for: recording, email: confirmedEmail)
                guard generation == self.generation, stillShowing(recording) else { return }
                startPlayer(stream, for: recording, startAt: position)
                return
            } catch {
                guard generation == self.generation else { return }
                let (cause, player) = Self.streamFailureCause(error)
                found = player
                let diagnosis = "play: recovery stream failed reason=\(Self.playFailureReason(cause).rawValue) error=\(PlaybackDiagnostics.errorName(cause))"
                PlaybackDiagnostics.log.notice("\(diagnosis, privacy: .public)")
                if cause is CancellationError || (cause as? RecmanBrowserError) == .needsSignIn { throw cause }
                if (cause as? RecmanBrowserError) == .needsEmail {
                    // Same decision as for Play: no Webex page for the student, only the sentence.
                    // The window stays, paused at the place it stopped.
                    openingProblem = RecordingsProblem(cause)
                    log.notice("Fresh stream needs a confirmed email")
                    return
                }
                log.notice("Fresh stream not available: opening the browser")
            }
        }
        do {
            let url = try await playerLink(for: recording, browser: browser, found: found)
            guard generation == self.generation else { return }
            playbackURLs[recording.id] = url
            // The window of a lecture that can't continue is no use next to the browser. Closing
            // it reports the position, so the student's place is kept.
            if currentLectureID == recording.id { player?.close() }
            openURL(url)
        } catch {
            guard generation == self.generation else { return }
            if error is CancellationError || (error as? RecmanBrowserError) == .needsSignIn { throw error }
            openingProblem = RecordingsProblem(error)
            log.error("Couldn't open a failed lecture in the browser")
        }
    }

    /// Whether `recording` is still the lecture in the player's window: the student may have
    /// closed it or started another while a stream was being found.
    private func stillShowing(_ recording: RecmanRecording) -> Bool {
        currentLectureID == recording.id && (player?.isOpen ?? false)
    }

    private func record(_ recordings: [RecmanRecording], for key: RecmanCourseKey, generation: Int) async {
        guard let owner = sessionOwner ?? ownerUserID() else {
            listings[key]?.isLoading = false
            listings[key]?.problem = .historyUnavailable
            return
        }
        let history = seenHistory
        let legacy = legacy(for: owner)
        await historyResetTask?.value
        guard isCurrentHistory(history, owner: owner, generation: generation) else { return }
        do {
            let ids = recordings.map(\.id)
            var seen: Set<String>
            while true {
                let revision = historyRevision[key, default: 0]
                seen = try await history.seen(owner: owner, key: key, ids: ids, legacy: legacy)
                guard isCurrentHistory(history, owner: owner, generation: generation) else { return }
                // An acknowledgement can commit/publish while this snapshot returns. Requery
                // rather than overwrite that newer state with an older membership snapshot.
                if historyRevision[key, default: 0] == revision { break }
            }
            discardLegacyDefaults()
            var listing = listings[key] ?? RecordingsListing()
            listing.recordings = recordings
            listing.seenIDs = seen
            listing.historyReadFailed = false
            listing.isLoading = queue.contains(.list(key))
            listing.problem = nil
            listing.updatedAt = now()
            // Publish the list and its history together. A failed refresh retains the previous
            // pair, so a newly returned list cannot use an incomplete/stale membership cache.
            listings[key] = listing
            updateStudy { $0.reconcile(recordings, for: key) }
        } catch {
            guard isCurrentHistory(history, owner: owner, generation: generation) else { return }
            listings[key, default: RecordingsListing()].isLoading = queue.contains(.list(key))
            listings[key]?.problem = .historyUnavailable
            listings[key]?.historyReadFailed = true
            log.error("Couldn't load recording history")
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
        case .recover:
            // Not a click: the lecture's window already says what happened to it.
            break
        }
        // Offline or Polimi down: every other request would wait for the same timeout.
        guard problem == .unavailable else { return .next }
        for job in queue {
            switch job {
            case .list(let key): listings[key]?.problem = problem
            // A Play or Copy still waiting is dropped with the rest: it says why instead of the
            // click doing nothing.
            case .open: openingProblem = problem
            case .recover: break
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

    /// Sign-in, turn-off and an account change decide access themselves: the first visit's check
    /// must not overrule them when its read finishes.
    private func supersedeInitialSessionCheck() {
        initialSessionCheck = nil
    }

    /// Stops the worker and any sign-in for good: they belong to an older generation from now on.
    private func invalidate() {
        // A pending explicit acknowledgement may commit after the page closes. Its old
        // generation cannot publish, so force a history reload when this list returns.
        for key in pendingAcknowledgements.values { listings[key]?.updatedAt = nil }
        generation += 1
        worker?.cancel()
        worker = nil
        signInTask?.cancel()
        signInTask = nil
        clearQueue()
    }

    // MARK: Polimi email for the Webex sign-in (#148)

    /// What the Settings field offers for the text in it. Pure, so the rules are tested without a
    /// view.
    enum EmailFieldState: Equatable {
        /// Nothing typed and nothing confirmed.
        case empty
        /// The text is the confirmed address.
        case confirmed
        /// Nothing typed but an address is confirmed: confirming removes it.
        case removable
        /// A valid Polimi address that isn't confirmed yet.
        case ready(PolimiEmail)
        /// Not a Polimi address (`PolimiEmail` is the single gate).
        case invalid
    }

    nonisolated static func emailFieldState(draft: String, confirmed: PolimiEmail?) -> EmailFieldState {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return confirmed == nil ? .empty : .removable }
        guard let email = PolimiEmail(trimmed) else { return .invalid }
        return email == confirmed ? .confirmed : .ready(email)
    }

    enum EmailEntry: Equatable {
        case saved
        case cleared
        case unchanged
        case invalid
    }

    /// Called when the Settings field appears: the same lookup as a Play's (`learnEmail`).
    func prepareEmailField() async {
        await learnEmail()
    }

    /// Learns the address to sign in to Webex with, when none is known: first the saved
    /// session's, then (product decision 2026-10-11) the WeBeep profile's, taken as confirmed
    /// with no confirmation step, so the first Play works without opening Settings.
    ///
    /// - Lazy and bounded: called by the Settings field and by Play when no address is known,
    ///   never at rest; WeBeep is asked at most once per epoch (`suggestionAttempted`), and
    ///   concurrent callers share one lookup (`emailLookup`).
    /// - The student wins: nothing is taken after they edited or removed the address in this
    ///   launch (`emailEditedByUser`), or removed it for this account in any launch
    ///   (`emailDeclinedKey`).
    /// - Identity: an answer that arrives after a turn-off, logout or account change (a new
    ///   `emailEpoch`) is dropped; `fetchProfileEmail` itself checks the account is unchanged.
    /// - Failure is silent: a profile that can't be read, a function the token isn't allowed to
    ///   call or an address that isn't Polimi's leave no address (Play then shows its message),
    ///   never an error. The address is never logged.
    /// - Stored like a typed one: into the session file now when there is one
    ///   (`storeEmail`), and by the next save (`saveSession`, fingerprint included) otherwise.
    func learnEmail() async {
        // Before the cache: a lookup refused while the feature is off must not stand for the
        // epoch once it is turned on.
        guard isEnabled else { return }
        if let emailLookup, emailLookup.epoch == emailEpoch {
            await emailLookup.task.value
            return
        }
        let epoch = emailEpoch
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performEmailLookup(epoch: epoch)
        }
        emailLookup = (epoch, task)
        await task.value
    }

    private func performEmailLookup(epoch: Int) async {
        guard isEnabled, epoch == emailEpoch else { return }
        if !emailLoaded {
            _ = await savedCookies()
            // No browser means no opening cycle to share the read with: don't keep it around.
            if browser == nil { sessionLoad = nil }
            guard epoch == emailEpoch, isEnabled else { return }
        }
        guard confirmedEmail == nil, !emailEditedByUser, !suggestionAttempted,
              !emailDeclined(by: sessionOwner ?? ownerUserID()) else { return }
        suggestionAttempted = true
        emailAccount = sessionOwner ?? ownerUserID()
        let raw = await fetchProfileEmail()
        // A reset (turn-off, account change) already cleared the flag for its own cycle.
        guard epoch == emailEpoch else { return }
        guard isEnabled, confirmedEmail == nil, !emailEditedByUser, let raw, let email = PolimiEmail(raw) else { return }
        confirmedEmail = email
        emailFromProfile = true
        storeEmail(email)
    }

    /// The student confirms, changes or removes the address. Only a Polimi address is accepted
    /// (`PolimiEmail`); an empty field removes it. It is written into the saved session at once,
    /// keeping its cookies; with no saved session yet it stays in memory and the next successful
    /// sign-in writes it. It is never logged.
    ///
    /// Refused while no WeBeep account is known (an expired token at launch, before a new
    /// sign-in): an address must belong to an account (`emailAccount`), and one typed then could
    /// only be handed to whichever account signs in next (PR #152 review).
    @discardableResult
    func confirmEmail(_ text: String) -> EmailEntry {
        guard isEnabled, (sessionOwner ?? ownerUserID()) != nil else { return .unchanged }
        switch Self.emailFieldState(draft: text, confirmed: confirmedEmail) {
        case .invalid: return .invalid
        case .empty, .confirmed: return .unchanged
        case .removable:
            setConfirmedEmail(nil)
            return .cleared
        case .ready(let email):
            setConfirmedEmail(email)
            return .saved
        }
    }

    private func setConfirmedEmail(_ email: PolimiEmail?) {
        confirmedEmail = email
        emailFromProfile = false
        emailEditedByUser = true
        let owner = sessionOwner ?? ownerUserID()
        emailAccount = owner
        // A removal is remembered for the account, so the profile's address doesn't come back
        // at the next launch (the empty file alone can't say it was removed on purpose).
        if email == nil, let owner {
            defaults.set(owner, forKey: Self.emailDeclinedKey)
        } else if email != nil {
            forgetEmailOptOut()
        }
        storeEmail(email)
    }

    /// Writes the address into the existing session file at once, keeping its cookies; with no
    /// file yet the next sign-in's save writes it.
    private func storeEmail(_ email: PolimiEmail?) {
        guard let owner = sessionOwner ?? ownerUserID() else { return }
        let update = vault.updateEmail(email?.value, ownerUserID: owner, epoch: vault.epoch, now: now())
        Task { [log] in
            if case .failed(let errorType) = await update.value {
                log.error("Couldn't save the Polimi email errorType=\(errorType, privacy: .public)")
            }
        }
    }

    /// The session (and so the email) is gone: nothing of the address stays in memory, and an
    /// answer still on its way for the old one is dropped.
    private func resetEmail() {
        emailEpoch += 1
        confirmedEmail = nil
        emailFromProfile = false
        emailLoaded = false
        emailEditedByUser = false
        suggestionAttempted = false
        emailLookup = nil
        emailAccount = nil
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
        sessionLoad = nil
    }

    /// The saved session's cookies, checked against the WeBeep account. A file that can't be
    /// decoded, or that belongs to another known account, is deleted; one that can't be read
    /// right now (a disk error) is kept for the next try. Read off the main actor, once per
    /// opening cycle: later callers in the same cycle share the first read.
    private func savedCookies() async -> [HTTPCookie] {
        if let sessionLoad { return await sessionLoad.task.value }
        sessionLoads += 1
        let id = sessionLoads
        // Read before the load is enqueued: a discard after this point makes the answer stale.
        let epoch = vault.epoch
        let read = vault.load(now: now())
        let task = Task { [weak self] () -> [HTTPCookie] in
            let outcome = await read.value
            guard let self else { return [] }
            return self.adopt(outcome, epoch: epoch, load: id)
        }
        sessionLoad = (id, task)
        return await task.value
    }

    /// Applies a finished read on the main actor, unless turn-off, logout or an account change
    /// discarded the session since it started: what was read is being deleted.
    private func adopt(_ outcome: RecmanSessionVault.LoadOutcome, epoch: Int, load: Int) -> [HTTPCookie] {
        guard vault.epoch == epoch else { return [] }
        let snapshot: RecmanSessionCodec.Snapshot
        switch outcome {
        case .unreadable:
            log.error("Couldn't read the saved Polimi session")
            if sessionLoad?.id == load { sessionLoad = nil }
            return []
        case .none:
            // v1 history has no owner. Without a verifiable saved session, attaching it to
            // the next sign-in could leak another student’s state; v2 is already scoped.
            legacySeen = .init(ids: [], baselines: [])
            discardLegacyDefaults()
            emailLoaded = true
            return []
        case .undecodable:
            log.notice("Saved Polimi session unreadable: dropped")
            legacySeen = .init(ids: [], baselines: [])
            discardLegacyDefaults()
            discardSessionFile()
            return []
        case .session(let saved):
            snapshot = saved
        }
        if let current = ownerUserID(), current != snapshot.ownerUserID {
            log.notice("Saved Polimi session belongs to another WeBeep account: dropped")
            closePlayerForIdentityChange()
            listings.removeAll()
            playbackURLs.removeAll()
            forgetSeen()
            forgetResumePoints()
            forgetEmailOptOut()
            discardSessionFile()
            return []
        }
        sessionOwner = snapshot.ownerUserID
        legacyOwner = snapshot.ownerUserID
        // What the file says, unless the student has already changed it in this launch. An
        // address that isn't a Polimi one (a damaged or foreign file) is simply not an address.
        // A profile address taken in this launch also stays when a later read finds a file
        // without one: it is not written yet (no session file then, or a write still queued),
        // and the next save writes it.
        let fileEmail = snapshot.email.flatMap(PolimiEmail.init)
        if !emailEditedByUser, !(emailFromProfile && fileEmail == nil) {
            if fileEmail != confirmedEmail { emailFromProfile = false }
            confirmedEmail = fileEmail
        }
        emailAccount = snapshot.ownerUserID
        emailLoaded = true
        return snapshot.cookies
    }

    /// Saves the browser's session after a success, under the account it belongs to, unless it
    /// is what the file already holds. The vault epoch is read before awaiting WebKit: a turn-off,
    /// logout or account change from then on makes this save stale, and the vault refuses it at
    /// commit time even after the guards below have passed. Today those paths also bump
    /// `generation`, which stops the save first, and `adopt`'s own discards can't land in this
    /// window (this cycle's read has already finished, after every earlier one). The epoch is the
    /// guarantee that doesn't depend on either, so no test can fail without it yet.
    private func saveSession(_ generation: Int) async {
        guard let browser else { return }
        let epoch = vault.epoch
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
        // Read here, right before the save is enqueued: the email in the file is always the one
        // the student has confirmed at this moment, never one captured before the WebKit wait.
        // A session file that couldn't be read (a disk error) has an email nobody knows: keep
        // what the file holds rather than writing "none" over it. A student's own edit wins.
        let keepFileEmail = !emailLoaded && !emailEditedByUser
        switch await vault.save(cookies, ownerUserID: owner, email: confirmedEmail?.value, keepingFileEmail: keepFileEmail, epoch: epoch, now: now()).value {
        case .saved:
            // The cycle's cached read now describes an older file.
            sessionLoad = nil
        case .unchanged:
            break
        case .stale:
            log.notice("Polimi session not saved: discarded while saving")
        case .failed(let errorType):
            log.error("Couldn't save the Polimi session errorType=\(errorType, privacy: .public)")
        }
    }

    /// Bumps the vault epoch now, so every save already under way is refused, and deletes the
    /// file in turn, off the main actor.
    private func discardSessionFile() {
        sessionOwner = nil
        sessionLoad = nil
        // The email lives in the file and goes with it, in memory too.
        resetEmail()
        let delete = vault.discard()
        Task { [log] in
            if case .failed(let errorType) = await delete.value {
                log.error("Couldn't delete the saved Polimi session errorType=\(errorType, privacy: .public)")
            }
        }
    }

    /// Waits until the session file reflects every call made so far. For tests, which read the
    /// file from outside the vault.
    func settleSessionFile() async {
        await vault.settle()
    }
}
