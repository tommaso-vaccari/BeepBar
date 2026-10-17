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
/// - **Quiet at rest.** Nothing runs on its own: no timer, no observer. Work starts only when the
///   Recordings page is shown, a sign-in starts, a lecture is played, or a sync run asks for its
///   listings follow-up (`refreshForSync`, see below). The browser is closed as soon as none of
///   these needs it any more, unless a sign-in is on screen. Nothing here takes part in quitting
///   or in `expireCredential()`.
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
///   Settings window does not: a lecture keeps playing with the window closed, and a Play still
///   finding its stream goes on (`suspend`).
/// - **Where you stopped is written only when the player reports it** (pause, close, a newer
///   Play, a failure), never on a clock; a lecture watched to the end starts from the beginning
///   again and counts as seen. Positions survive disabling; identity changes remove them.
/// - **The Polimi email stays in the session file** (`RecmanSessionVault`) and nowhere else, is
///   never logged, and is deleted with the file.
/// - **A failed lecture is recovered once.** A stream that dies mid-lecture is resolved again and
///   resumes where it stopped; after that, or if it never started, the browser opens.
///
/// Watch progress (how much of each lecture was watched, and whether it is done; rules in Core's
/// `RecordingWatchProgress`). What this class keeps, each guarded by `RecordingsWatchProgressTests`:
/// - **Ticks stay in memory.** While a lecture plays, the player's ~30 s ticks move the window's
///   bar (`watchProgress.live`) and write nothing, neither the database nor the settings.
/// - **Saved at checkpoints only, and only when something changed**: pause, close, replacement,
///   failure, and the student's tick. One serial write chain keeps them in order.
/// - **Done only when the lecture ends** (closed, or replaced by another lecture) at 90 % or
///   more, or ticked. Recovery and Play again on the same lecture are not an end.
/// - **Belongs to the account**, like seen state: turn-off, disconnect and account change forget
///   it, and a write that finishes afterwards is never shown.
/// - **The menu's summary changes only when the saved state does** (`watchSummaries`), never on a
///   tick, and is stored as numbers (plus the next lecture's archive row) so a language switch
///   needs nothing.
///
/// Menu bar Play (a click on a course's line plays its next lecture). What this class keeps, each
/// guarded by `RecordingsMenuPlayTests`:
/// - **The saved summary carries the next lecture** (`CourseWatchSummary.next`), recomputed from
///   committed entries only: it moves at a checkpoint or when a lecture is marked done, never on a
///   periodic tick, and a lecture finished with no listing loaded stops being offered.
/// - **Same Play as the window's, without the window** (`playFromMenu`): the window opens only
///   when it is needed, i.e. the Polimi session needs a sign-in or the lecture can't be opened
///   (`onMenuPlayNeedsPage`); a window Play's failure never opens anything.
/// - **Closing the window doesn't cancel a Play** (window or menu) that is queued or running,
///   as it never cancelled a recovery (`suspend`). Accepted consequence (owner, 2026-10-12): a
///   Webex sign-in window or the browser fallback of that Play may appear seconds after
///   Settings was closed.
///
/// Refreshing the listings at every sync (owner decision 2026-10-12; `refreshForSync`, called by
/// the sync's follow-up, which decides first with Core's `RecordingsSyncPolicy`). What this class
/// keeps, each guarded by `RecordingsSyncRefreshTests`:
/// - **Listings and seen state only.** The same `.list` jobs as the page's, through the same
///   worker and `record`: never a stream, never a download, never a window. A lapsed Polimi
///   session ends it as `.needsSignIn` (no sign-in window, no activation); no saved session
///   ends it before the browser is even created.
/// - **Free when there is nothing to do.** Off, no account, a sign-in running or needed, no
///   courses, or every course listed within `freshness` (automatic runs only; "Sincronizza ora"
///   passes `force`): no file read, no browser, no write.
/// - **Next to the page, never in its way.** Its courses go after what the page queued and
///   never replace it; the page's own `enqueue` and closing the window don't drop them
///   (`backgroundKeys`); one browser, one request at a time, as always. With no page on screen
///   the browser closes when the queue has drained.
/// - **Answered exactly once.** The caller's await ends when its courses are done, when the
///   identity changes (turn-off, sign-out, account or university change, a sign-in:
///   `invalidate`), or when its task is cancelled (well within a second: nothing is awaited
///   first). A failure of this refresh is never shown as a sync failure.
@MainActor final class RecordingsController: ObservableObject {
    nonisolated static let enabledKey = "io.github.tvaccari.beepbar.recordings-enabled.v1"
    /// The session file is obsolete (turn-off, logout, account change, damage): never read it.
    /// Cleared when its deletion is confirmed (`trackSessionDeletion`) or a new session is saved.
    /// While set, every new controller and every session read retries the deletion (#200).
    private static let sessionDiscardedKey = "io.github.tvaccari.beepbar.recordings-session-discarded.v1"

    /// The switch as saved: on by default, and off wherever the feature isn't available. Shared by
    /// `init` and by readers that must not create the controller (daily telemetry).
    nonisolated static func storedEnabled(in defaults: UserDefaults, isAvailable: Bool) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool ?? true) && isAvailable
    }
    static let acknowledgedKey = "io.github.tvaccari.beepbar.recordings-acknowledged.v1"
    static let baselinedKey = "io.github.tvaccari.beepbar.recordings-baselined.v1"
    /// Durable reset tombstone: a failed file removal can never reuse the old namespace.
    static let historyNamespaceKey = "io.github.tvaccari.beepbar.recordings-history-namespace.v2"
    /// Where the student stopped in each lecture (`RecordingResumePoints`), for one account.
    /// Removed on disconnect, university change and account change.
    nonisolated static let resumePointsKey = "io.github.tvaccari.beepbar.recordings-resume.v1"
    /// The last known `CourseWatchSummary` of each course, for one account
    /// (`StoredWatchSummaries`), so the menu bar can show it without a network request or a
    /// controller. Written only when a value changes; removed with the session.
    nonisolated static let watchSummaryKey = "io.github.tvaccari.beepbar.recordings-watch-summary.v1"
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
    /// The WeBeep course list, read when a lecture starts: its course's name and picture go to
    /// macOS's Now Playing (`RecordingPlaybackMetadata`, issue #148 follow-up).
    private let courses: @MainActor () -> [RemoteCourseSummary]
    /// The WeBeep course of the last menu Play (`RecordingMenuTarget.courseID`), by recording id:
    /// the course the student clicked, used for Now Playing when two courses share an archive key.
    private var menuPlayCourse: (recordingID: String, courseID: Int64)?
    /// The Now Playing metadata of the lecture last handed to the player, so a recovery
    /// (`startPlayer` again with a fresh stream) shows the same course and picture even if the
    /// page has moved to another course meanwhile. Reused only for a recovery
    /// (`recoveredLectures`), never for a new Play of the same lecture: that one may come from
    /// another course's page, or after the course list gained the picture (the first launch
    /// after an update has none yet). Cleared when the player closes, on identity change, and
    /// replaced by the next lecture.
    private var playbackMetadata: (recordingID: String, metadata: RecordingPlaybackMetadata)?
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
    private var playbackIntent = 0
    /// Lectures already given their one fresh stream since the student pressed Play.
    private var recoveredLectures: Set<String> = []
    private var resumePoints: RecordingResumePoints?
    /// A recovery ran with no Recordings page on screen: the browser it opened closes after it.
    private var closesBrowserWhenIdle = false
    /// The generation of a recovery or Play executing outside the queue. An invalidated
    /// worker must neither keep the browser alive nor clear a newer worker's running state.
    private var runningRecoveryGeneration: Int?
    private var runningPlayGeneration: Int?

    // MARK: Menu bar Play state

    /// The Play a click on a course's menu line started (`playFromMenu`), until it reaches the
    /// player or the browser fallback, fails, or a newer click replaces it. Only this Play's
    /// failure may call `onMenuPlayNeedsPage`: a window Play's failure is shown on the page the
    /// student is looking at. Cleared by any newer `open` and by `invalidate` (its job is gone).
    private var menuPlay: (request: Int, key: RecmanCourseKey)?
    /// A menu Play failed with no Recordings page on screen (the Polimi session lapsed, or the
    /// lecture can't be opened): the owner shows that course's page, where the usual message or
    /// "Accedi con Polimi" explains it. Set by `WeBeepAuthenticationController` (package P3);
    /// called on the main actor, never for a window Play.
    var onMenuPlayNeedsPage: (@MainActor (RecmanCourseKey) -> Void)?

    // MARK: Watch progress state

    /// What the window draws of watch progress. Separate from this controller so a tick doesn't
    /// re-evaluate every view observing the controller (see the model's comment).
    let watchProgress = RecordingsWatchProgressModel()
    /// The playing session of each lecture in `nowPlaying`, by recording id. Memory only. A
    /// session is the unit of the un-tick crossing rule, so it survives a recovery and a Play
    /// again of the same lecture (neither is an end) and goes when the lecture ends.
    private var sessions: [String: LiveWatchSession] = [:]
    /// Numbers sessions, so a failed checkpoint is superseded only by a later one of its session.
    private var sessionSerial = 0
    /// The recording id handed to `player.play` while that call runs, nil otherwise. The player
    /// reports the lecture it replaces synchronously inside `play`, before anything else changes:
    /// this is the only way that report can tell a different lecture (an end) from the same one
    /// re-played (recovery, Play again), which is not an end. Main actor only.
    private var pendingPlayID: String?
    /// The tail of the serial chain of progress writes. Separate tasks calling an actor are not
    /// ordered, so each write awaits the previous one: a tick, an un-tick and a close must commit
    /// in the order they happened. Never cancelled by closing the page or the player: the store
    /// refuses an event from a cancelled task (`RecordingsSeenHistory.applyProgress`), and a final
    /// checkpoint must not be lost. A reset drops it; the invalidated actor refuses what's queued.
    private var progressChain: Task<Void, Never>?
    /// Checkpoints whose save failed (a disk error), by session serial: retried before the next
    /// checkpoint, never with a timer and never with a banner, at most `maxUnsavedCheckpoints`.
    /// A newer checkpoint of the same session supersedes the old one (its session includes
    /// everything the old one saw), so this holds at most one event per session.
    ///
    /// A retry runs *after* writes queued since the failure, so it is out of order by design.
    /// That is safe for furthest (it never goes down) and for completion of a lecture not
    /// un-ticked meanwhile; an un-tick in between is handled by `untickCounts`: the retried
    /// session's crossing is forgotten, so an old close can't undo the student's later choice.
    private var unsavedCheckpoints: [Int: UnsavedCheckpoint] = [:]
    /// How many un-ticks were queued per identity in this account's lifetime. A checkpoint
    /// records the count when queued; a retry that finds it changed was overtaken by an un-tick.
    private var untickCounts: [String: Int] = [:]
    /// The bulk save that holds each course's lock (`watchProgress.pendingCourses`). Only that
    /// save releases it, also when it stops at an identity change that resets nothing (the
    /// WeBeep account changing with no saved Polimi session): without this the whole course
    /// would stay disabled until the next reset. A save superseded by a reset finds another
    /// token, or none, and leaves the new account's locks alone.
    private var bulkTokens: [RecmanCourseKey: UUID] = [:]
    /// The last saved summary of each course, for the menu bar (package F reads it through
    /// `onWatchSummaryChange` and `storedWatchSummaries(in:owner:)`). Changes only when a listing
    /// is published or a progress write commits, never on a tick: the in-memory position moves
    /// only `watchProgress.summaries`. A course absent here is unknown, never "0/0".
    ///
    /// `[:]` before the first store in this launch does NOT mean "no summaries": the saved ones
    /// are read lazily, at the first change (`storeWatchSummary`). The menu must seed itself from
    /// `storedWatchSummaries(in:owner:)` and take pushes as updates; only the `[:]` pushed by a
    /// reset (`forgetSeen`) means the account's summaries are gone.
    private(set) var watchSummaries: [RecmanCourseKey: CourseWatchSummary] = [:] {
        didSet { if watchSummaries != oldValue { onWatchSummaryChange?(watchSummaries) } }
    }
    /// Pushed from the main actor whenever `watchSummaries` changes (the pattern of
    /// `WeBeepAuthenticationController.onMenuBarSymbolChange`): the menu never asks this
    /// controller from an AppKit callback. Each push is the full dictionary of courses known *in
    /// this controller*; see `watchSummaries` for why the first one is not the whole picture
    /// unless it follows a read of the saved summaries.
    var onWatchSummaryChange: (@MainActor ([RecmanCourseKey: CourseWatchSummary]) -> Void)?
    /// The account `watchSummaries` was read for; nil until the first use with a known account.
    private var watchSummaryOwner: Int?

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
    /// The session-file deletion in flight (a discard or its retry), so a read while it runs
    /// doesn't enqueue another one. Its id tells a finished deletion whether it is still the
    /// tracked one.
    private var sessionDeletion: Int?
    private var sessionDeletions = 0

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

    // MARK: Sync refresh state

    /// One caller of `refreshForSync` still waiting for its courses.
    private struct BackgroundWaiter {
        /// Its courses not finished yet: queued (by it or by the page) or in flight.
        var pending: Set<RecmanCourseKey>
        /// The courses it appended to the queue itself, the only ones a cancellation may drop.
        var added: Set<RecmanCourseKey>
        var newlyPublished = 0
        var failedKeys = 0
        /// Nil only between registration and the moment the caller starts waiting (no
        /// suspension point in between today; `backgroundResults` covers it regardless).
        var continuation: CheckedContinuation<RecordingsSyncOutcome, Never>?
    }
    /// The callers of `refreshForSync` still waiting, by id. Every way out goes through
    /// `resolveBackground`, which removes the entry before resuming: that is what makes each
    /// continuation resume exactly once.
    private var backgroundWaiters: [Int: BackgroundWaiter] = [:]
    /// Outcomes decided before their caller attached its continuation; taken when it does.
    private var backgroundResults: [Int: RecordingsSyncOutcome] = [:]
    private var backgroundWaiterSerial = 0

    /// The courses some sync refresh is still waiting for. The page's `enqueue`, closing the
    /// window (`suspend`) and `dropQueuedListings` keep these queued: only `clearQueue` (which
    /// answers the waiters) and a cancellation of their own caller remove them.
    private var backgroundKeys: Set<RecmanCourseKey> {
        backgroundWaiters.values.reduce(into: Set<RecmanCourseKey>()) { $0.formUnion($1.pending) }
    }

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
        courses: @escaping @MainActor () -> [RemoteCourseSummary] = { [] },
        fetchProfileEmail: @escaping @MainActor () async -> String? = { nil },
        listingCapacity: Int = RecordingsController.listingCapacity,
        playbackURLCapacity: Int = RecordingsController.playbackURLCapacity
    ) {
        self.makePlayer = makePlayer
        self.courses = courses
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
        let enabled = Self.storedEnabled(in: defaults, isAvailable: isAvailable())
        isEnabled = enabled
        access = enabled ? .ready : .off
        legacySeen = .init(ids: enabled ? defaults.stringArray(forKey: Self.acknowledgedKey) ?? [] : [], baselines: enabled ? defaults.stringArray(forKey: Self.baselinedKey) ?? [] : [])
        // A deletion that failed, or never ran because the app quit first, would otherwise leave
        // the old account's Polimi and Webex cookies and email on disk for good (#200). Off the
        // main actor, and only while the flag says there is something to delete.
        retryObsoleteSessionDeletion()
    }

    /// The saved switch, on unless turned off; Polimi still decides (`isAvailable`). Shared with
    /// the menu bar, which reads it at launch without creating this controller.
    static func isSwitchedOn(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
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
            turnOff(preservingResumePoints: true)
            defaults.set(false, forKey: Self.enabledKey)
        }
    }

    /// Browser closed and session/history forgotten; a persisted opaque namespace prevents reuse
    /// if history cleanup fails. Account-scoped study choices and playback positions survive disabling the feature.
    /// Also called when the WeBeep account is disconnected or the university changes, whether or
    /// not the feature was on, so no session outlives the account it was made for.
    func turnOff(preservingResumePoints: Bool = false) {
        supersedeInitialSessionCheck()
        // Disabling saves the final checkpoint before clearing the playback identity.
        closePlayerForIdentityChange(preservingResumePoints: preservingResumePoints)
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
        if !preservingResumePoints { forgetResumePoints() }
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
        let freshSession: Bool
        if case .needsSignIn = access { freshSession = true } else { freshSession = false }
        access = .signingIn
        let generation = self.generation
        signInTask = Task { [weak self] in await self?.runSignIn(generation, freshSession: freshSession) }
    }

    private func runSignIn(_ generation: Int, freshSession: Bool) async {
        let browser = currentBrowser()
        let cookies = await savedCookies()
        guard generation == self.generation else { return }
        await browser.open(cookies: freshSession ? [] : cookies)
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
    ///
    /// With no session owner (a Polimi sign-in completed while the WeBeep account was unknown,
    /// so nothing was saved), the live browser and whatever the controller holds in memory
    /// (listings, playback links, watch progress) can't be attributed to anyone: they are
    /// dropped as well, or the new account would use the previous student's Polimi login and
    /// see their lectures (#191). Only memory goes in that case: the seen history, the resume
    /// points and the session file are scoped by owner (and checked when read), and wiping
    /// them could erase the same student's progress when the account merely became known. The
    /// cost is one more "Accedi con Polimi" in that rare case. Nothing in memory, nothing done:
    /// the account becoming known at a normal launch stays free.
    func webBeepAccountChanged(to userID: Int) {
        loadStudy()
        // Before the session check: an address learned with no Polimi session yet belongs to the
        // account that was signed in then, not to this one.
        if let emailAccount, emailAccount != userID {
            log.notice("Polimi email belongs to another WeBeep account: dropped")
            resetEmail()
        }
        resumePoints = nil
        Self.forgetResumePoints(in: defaults, notOwnedBy: userID)
        let foreignSession = sessionOwner.map { $0 != userID } ?? false
        let unattributedMemory = sessionOwner == nil && (browser != nil || !playbackURLs.isEmpty
            || !watchProgress.known.isEmpty || listings.values.contains { $0.recordings != nil })
        guard foreignSession || unattributedMemory else { return }
        log.notice("Polimi session belongs to another or an unknown WeBeep account: dropped foreign=\(foreignSession, privacy: .public)")
        supersedeInitialSessionCheck()
        closePlayerForIdentityChange()
        invalidate()
        closeBrowser()
        listings.removeAll()
        playbackURLs.removeAll()
        if foreignSession {
            forgetSeen()
            forgetResumePoints()
            forgetEmailOptOut()
            discardSessionFile()
        } else {
            watchProgress.reset()
        }
        if isEnabled { access = .needsSignIn(nil) }
    }

    // MARK: Page

    func pageAppeared() {
        loadStudy()
        visiblePages += 1
        // Keep launch and disabled recordings quiet; check only the first visit, before refresh
        // can open WebKit. Later visits must preserve a session established by explicit sign-in.
        guard isEnabled, access == .ready, !hasCheckedInitialSession else { return }
        let check = beginInitialSessionCheck()
        // Not tied to `generation`: closing the page while the file is read must not lose the
        // answer, or the next visit would open the browser without a session to show.
        Task { [weak self] in
            guard let self else { return }
            let cookies = await self.savedCookies()
            _ = self.answerInitialSessionCheck(check, cookies: cookies)
        }
    }

    /// Starts the one check of the saved session per launch (the page's first visit, or a sync
    /// refresh that comes first). Until it answers, `startWorker` opens nothing.
    private func beginInitialSessionCheck() -> Int {
        hasCheckedInitialSession = true
        initialSessionChecks += 1
        initialSessionCheck = initialSessionChecks
        return initialSessionChecks
    }

    private enum InitialSessionAnswer { case superseded, noSession, session }

    /// Applies the first check's answer, for the page and for a sync refresh alike.
    /// - Superseded (sign-in, turn-off, an account change) or no longer ready: nothing.
    /// - No saved session: `.needsSignIn`, and whatever was queued meanwhile is dropped (a menu
    ///   Play asks for its page; a sync refresh is answered `.needsSignIn`). No browser was or
    ///   will be created for it: the student's own "Accedi con Polimi" is the only way on.
    /// - A session: what the page asked for while the file was read is queued (no `force` to
    ///   carry over: nothing has been listed yet, so every key loads anyway), and the worker starts.
    private func answerInitialSessionCheck(_ check: Int, cookies: [HTTPCookie]) -> InitialSessionAnswer {
        guard initialSessionCheck == check else { return .superseded }
        initialSessionCheck = nil
        guard isEnabled, access == .ready else { return .superseded }
        if cookies.isEmpty {
            // A menu Play queued while the file was read can't run without a session.
            let needsPage = takeMenuPlayNeedingPage(failing: nil, queued: true)
            clearQueue(background: .needsSignIn)
            access = .needsSignIn(nil)
            if let needsPage { onMenuPlayNeedsPage?(needsPage) }
            return .noSession
        }
        if visiblePages > 0 { enqueue(pageKeys, selected: selectedKey, force: false) }
        startWorker()
        return .session
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
    /// (`suspend` stops only requests and the browser, and the stream needs neither; a Play or a
    /// recovery still finding its stream finishes first).
    func windowClosed() {
        visiblePages = 0
        suspend()
    }

    /// Back to quiet: requests stop and the browser goes, while the lists stay in memory so the
    /// page shows them at once next time. A sign-in on screen is left alone: the user may be
    /// typing in it with BeepBar's window closed.
    ///
    /// A lecture the student asked to watch is the exception (`hasPlayOrRecovery`):
    /// - a recovery (queued or running): the student is watching a lecture that stopped, and
    ///   cancelling its fresh stream because a window closed would leave it paused and silent
    ///   with its one retry spent;
    /// - a Play (queued or running), from the window or from the menu bar line: the student
    ///   asked for that lecture, and closing Settings does not stop a lecture (the player
    ///   already outlives the window), so it doesn't stop one that is about to start either.
    ///   Before the menu bar Play this closed-window case cancelled a window Play in flight;
    ///   now a window Play pressed just before closing the window still starts.
    /// A sync refresh still waiting (`backgroundWaiters`) is the third exception: it was never
    /// the page's, so closing the window doesn't cancel it either.
    /// Only the listings the page alone wanted and the other clicks (Open in browser, Copy link)
    /// are dropped then; the browser closes when the queue has drained (`closesBrowserWhenIdle`).
    private func suspend() {
        guard access != .signingIn else { return }
        if hasPlayOrRecovery || hasBackgroundRequest {
            dropQueuedListings()
            dropQueuedOpenings()
            closesBrowserWhenIdle = true
            return
        }
        invalidate()
        closeBrowser()
    }

    /// Whether a sync refresh is still waiting for its courses (`refreshForSync`).
    private var hasBackgroundRequest: Bool { !backgroundWaiters.isEmpty }

    /// Whether a recovery or a Play is queued or running: work for a lecture the student asked
    /// to watch, which closing the window must not cancel (`suspend`).
    private var hasPlayOrRecovery: Bool {
        runningRecoveryGeneration == generation || runningPlayGeneration == generation || queue.contains { job in
            switch job {
            case .recover, .open(_, .play, _): true
            case .list, .open: false
            }
        }
    }

    /// Removes the listings still waiting (not the one in flight) and their spinners, except
    /// those a sync refresh is waiting for (`backgroundKeys`): they were never the page's to drop.
    private func dropQueuedListings() {
        let kept = backgroundKeys
        let dropped: (Job) -> Bool = { job in
            if case .list(let key) = job { !kept.contains(key) } else { false }
        }
        for job in queue where dropped(job) {
            if case .list(let key) = job, key != runningKey { listings[key]?.isLoading = false }
        }
        queue.removeAll(where: dropped)
    }

    /// Removes the clicks still waiting other than a Play (Open in browser, Copy link) and their
    /// spinner: with the window closed nobody is waiting for them, and they would otherwise open a
    /// browser or a sign-in window after the work ahead of them (PR #152 review). A queued Play is
    /// kept: closing the window doesn't cancel a lecture the student asked for (see `suspend`).
    /// The one in flight, if any, finishes, as it did before the recovery exception.
    private func dropQueuedOpenings() {
        let dropped: (Job) -> Bool = { job in
            if case .open(_, let action, _) = job { action != .play } else { false }
        }
        for job in queue where dropped(job) {
            if case .open(let recording, _, _) = job, openingRecordingID == recording.id { openingRecordingID = nil }
        }
        queue.removeAll(where: dropped)
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

    /// Plays `recording` for a click on its course's menu bar line, without opening the
    /// Recordings window. Returns false when only the window can help: the feature is off, the
    /// Polimi session needs a sign-in (or one is running), or the stored lecture fails
    /// `validatedNext`; the caller then shows the course's page, with its message, "Accedi con
    /// Polimi" or the course's real list. True means handled here, including a stale click
    /// that is ignored.
    ///
    /// `owner` is the WeBeep account the menu line was built for (P3's `RecordingMenuTarget`
    /// payload, passed through unchanged). A click on a line built for another account (the
    /// account changed while the menu was open) is ignored: nothing plays, nothing opens, true.
    /// The caller checks the owner too; this is defence in depth, at the point of action.
    ///
    /// Same path as the Play button (`open(_, .play)`): the stored resume position, the
    /// acknowledgement as seen, the watch session and its checkpoints, the regular activation
    /// policy while the player is open, replacing whatever was playing, and the browser fallback.
    /// On top of it:
    /// - the lecture already in the player is brought forward, not played again (a re-Play would
    ///   restart it from its stored point);
    /// - the course's listing is queued after the Play when it isn't fresh in memory, so a
    ///   completion while the lecture plays updates the course's count and next lecture
    ///   (`refreshWatchSummary` needs it). Appended, never through `enqueue`, which replaces the
    ///   page's queued listings with its own keys;
    /// - with no page on screen, the browser closes once the queue has drained;
    /// - a failure with no page on screen calls `onMenuPlayNeedsPage` (`takeMenuPlayNeedingPage`).
    ///
    /// `recording` comes from the saved summary (UserDefaults), so it is untrusted: the caller
    /// checks it with `validatedNext` first, and it is checked again here; an invalid one is
    /// never opened, and the course page is asked for instead (false) so the click isn't silent.
    func playFromMenu(_ recording: RecmanRecording, owner: Int, courseID: Int64? = nil) -> Bool {
        guard isEnabled else { return false }
        switch access {
        case .off, .needsSignIn, .signingIn: return false
        case .ready: break
        }
        guard resumeOwner() == owner else { return true }
        guard let key = Self.courseKey(of: recording), Self.validatedNext(recording, for: key) else { return false }
        if stillShowing(recording) {
            // The player's own front API, not `NSApp.activate()`: a minimized window has to be
            // restored from the Dock, or the click does nothing visible (issue #193).
            player?.bringToFront()
            return true
        }
        open(recording, .play)
        menuPlay = (openingRequest, key)
        menuPlayCourse = courseID.map { (recording.id, $0) }
        if needsLoad(key, force: false), !queue.contains(.list(key)) {
            listings[key, default: RecordingsListing()].isLoading = true
            listings[key]?.problem = nil
            queue.append(.list(key))
        }
        if visiblePages == 0 { closesBrowserWhenIdle = true }
        startWorker()
        return true
    }

    /// Whether a stored next lecture (`CourseWatchSummary.next`, read back from UserDefaults and
    /// so untrusted) may be played for `key`: it belongs to that course and academic year, and
    /// its preview link is an archive preview link for its own id (`RecmanURLPolicy`, the check
    /// `RecmanWebSession.playbackURL(for:)` makes before following it). Anything else, e.g. an
    /// edited settings file pointing at another host, is never opened.
    nonisolated static func validatedNext(_ recording: RecmanRecording, for key: RecmanCourseKey) -> Bool {
        recording.courseCode == key.courseCode && recording.academicYear == key.academicYear
            && RecmanURLPolicy.previewTransferID(recording.previewURL) == recording.id
    }

    /// The menu Play failed (`failing` is its job) or is being dropped with the queue (`queued`,
    /// when the whole queue is about to be cleared): forgets it, and returns its course when no
    /// page is on screen, for `onMenuPlayNeedsPage`. The caller calls that only after updating
    /// its own state (`access`, the queue), so the page it opens reads the final state. A window
    /// Play never matches: any newer `open` clears `menuPlay`, and only a job carrying the menu
    /// Play's request does.
    private func takeMenuPlayNeedingPage(failing job: Job?, queued: Bool) -> RecmanCourseKey? {
        guard let menuPlay else { return nil }
        let isMenuPlay: (Job) -> Bool = { job in
            if case .open(_, .play, let request) = job { request == menuPlay.request } else { false }
        }
        guard job.map(isMenuPlay) == true || (queued && queue.contains(where: isMenuPlay)) else { return nil }
        self.menuPlay = nil
        return visiblePages == 0 ? menuPlay.key : nil
    }

    private func open(_ recording: RecmanRecording, _ action: OpenAction) {
        guard isEnabled, access == .ready else { return }
        // A newer click replaces a menu Play: its failure is no longer the menu's.
        menuPlay = nil
        openingRequest += 1
        if action == .play { playbackIntent += 1 }
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

    private func scheduleAcknowledge(_ ids: [String], for key: RecmanCourseKey, opening: Int? = nil, preserveHistoryProblem: Bool = false) {
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
                // The unseen count of the saved summary (menu line) changes with the dots.
                if self.listings[key]?.seenIDs != nil { self.refreshWatchSummary(for: key, persist: true) }
                if !preserveHistoryProblem, self.listings[key]?.historyReadFailed != true, self.listings[key]?.problem == .historyUnavailable { self.listings[key]?.problem = nil }
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

    /// Forgets the account's history: seen state and watch progress (which share the namespace),
    /// the window's progress model, the playing sessions, the progress writes still queued (their
    /// actor is invalidated below, so they are refused, and a late commit fails the identity check
    /// in `commitProgress`), and the persisted menu summary.
    private func forgetSeen() {
        for key in listings.keys { listings[key]?.seenIDs = nil }
        watchProgress.reset()
        sessions = [:]
        unsavedCheckpoints = [:]
        untickCounts = [:]
        bulkTokens = [:]
        progressChain = nil
        watchSummaryOwner = nil
        // The menu may hold summaries this controller never loaded (seeded from the saved copy
        // at launch), so the reset is announced even when there is nothing here to clear:
        // `watchSummaries`' own `didSet` stays silent for `[:]` → `[:]`.
        if watchSummaries.isEmpty { onWatchSummaryChange?([:]) } else { watchSummaries = [:] }
        if defaults.object(forKey: Self.watchSummaryKey) != nil { defaults.removeObject(forKey: Self.watchSummaryKey) }
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
        // A sync refresh's queued courses stay, after the page's, in their order: the page
        // replaces only what it asked for itself (`backgroundKeys`).
        let background = backgroundKeys
        let kept = queue.filter { job in
            if case .list(let key) = job { background.contains(key) && !wanted.contains(key) } else { false }
        }
        // The page's current keys replace queued listings. Keep explicit openings and the
        // in-flight listing, but stop showing spinners for work that will no longer run.
        for job in queue {
            if case .list(let key) = job, !wanted.contains(key), !background.contains(key), key != runningKey {
                listings[key]?.isLoading = false
            }
        }
        queue = opens + wanted.map(Job.list) + kept
        for key in wanted {
            // A new attempt replaces the last one's failure: its banner next to the spinner read
            // as the new attempt having failed already.
            listings[key, default: RecordingsListing()].isLoading = true
            listings[key]?.problem = nil
        }
        startWorker()
    }

    // MARK: Sync refresh (listings at every sync)

    /// Refreshes the listings of `keys` in the background, for the follow-up of a sync run, and
    /// answers when they are done. Listings and seen state only (never a stream, never a window).
    ///
    /// - Zero-cost answers, before anything is read or opened: switched off, owner unknown, a
    ///   sign-in running or needed, no courses; and courses all listed within `freshness` when
    ///   `force` is false (an automatic run; "Sincronizza ora" passes `force`).
    /// - No session checked yet this launch: the session file is read once. Without cookies the
    ///   answer is `.needsSignIn` and no browser was created.
    /// - The courses are appended after what the page queued (`enqueueBackground`); the page's
    ///   own queue is never replaced, and its window closing doesn't cancel them (`suspend`).
    /// - The task's cancellation ends the wait at once: with nothing else needing the browser
    ///   (`backgroundCancelled`) it stops the worker and closes the browser, otherwise it only
    ///   drops the courses nobody else wants.
    ///
    /// The continuation resumes exactly once, through `resolveBackground`.
    func refreshForSync(_ keys: Set<RecmanCourseKey>, force: Bool) async -> RecordingsSyncOutcome {
        guard isEnabled else { return .skipped(.switchedOff) }
        guard sessionOwner ?? ownerUserID() != nil else { return .skipped(.ownerUnknown) }
        switch access {
        case .off: return .skipped(.switchedOff)
        case .signingIn: return .skipped(.signingIn)
        case .needsSignIn: return .skipped(.needsSignIn)
        case .ready: break
        }
        guard !keys.isEmpty else { return .skipped(.noCourses) }
        guard !Task.isCancelled else { return .cancelled }
        let wanted = keys.filter { $0 == runningKey || needsLoad($0, force: force) }
            .sorted { ($0.courseCode, $0.academicYear) < ($1.courseCode, $1.academicYear) }
        // Everything is fresh: nothing to ask, nothing to write.
        guard !wanted.isEmpty else { return .refreshed(newlyPublished: 0, failedKeys: 0) }

        backgroundWaiterSerial += 1
        let id = backgroundWaiterSerial
        let queued = Set(queue.compactMap { job -> RecmanCourseKey? in if case .list(let key) = job { key } else { nil } })
        backgroundWaiters[id] = BackgroundWaiter(pending: Set(wanted),
                                                 added: Set(wanted).subtracting(queued).subtracting([runningKey].compactMap { $0 }))
        // With a page on screen the browser stays for it; otherwise it closes when the queue drains.
        if visiblePages == 0 { closesBrowserWhenIdle = true }
        // The session check first: `startWorker` opens nothing while it is pending, and without
        // a saved session the browser must never be created.
        if !hasCheckedInitialSession {
            let check = beginInitialSessionCheck()
            Task { [weak self] in
                guard let self else { return }
                let cookies = await self.savedCookies()
                _ = self.answerInitialSessionCheck(check, cookies: cookies)
            }
        }
        enqueueBackground(wanted)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RecordingsSyncOutcome, Never>) in
                if let result = backgroundResults.removeValue(forKey: id) {
                    continuation.resume(returning: result)
                } else if backgroundWaiters[id] != nil {
                    backgroundWaiters[id]?.continuation = continuation
                } else {
                    continuation.resume(returning: .cancelled)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.backgroundCancelled(id) }
        }
    }

    /// Appends the courses not queued or in flight yet, after everything already queued: the
    /// page's listings, its openings and any Play keep their place. Unlike `enqueue`, never
    /// removes anything.
    private func enqueueBackground(_ keys: [RecmanCourseKey]) {
        for key in keys where key != runningKey && !queue.contains(.list(key)) {
            queue.append(.list(key))
            listings[key, default: RecordingsListing()].isLoading = true
            listings[key]?.problem = nil
        }
        startWorker()
    }

    /// A course of some waiting refresh finished (listed and recorded, or failed). The waiters
    /// answer when the worker has saved the session and closed the browser
    /// (`resolveFinishedBackground`), not here.
    private func finishBackgroundKey(_ key: RecmanCourseKey, _ result: RecordResult) {
        for id in Array(backgroundWaiters.keys) {
            guard backgroundWaiters[id]?.pending.contains(key) == true else { continue }
            switch result {
            case .published(let newly):
                backgroundWaiters[id]?.pending.remove(key)
                backgroundWaiters[id]?.newlyPublished += newly
            case .failed:
                backgroundWaiters[id]?.pending.remove(key)
                backgroundWaiters[id]?.failedKeys += 1
            case .stale:
                // The identity moved on while the history was read: nothing was published.
                resolveBackground(id, .cancelled)
            }
        }
    }

    /// Answers the waiters whose courses are all done. A course that is neither queued nor in
    /// flight any more cannot be coming: counted as failed rather than waited for forever.
    private func resolveFinishedBackground() {
        for id in Array(backgroundWaiters.keys) {
            guard var waiter = backgroundWaiters[id] else { continue }
            waiter.pending = waiter.pending.filter { key in queue.contains(.list(key)) || key == runningKey }
            let lost = (backgroundWaiters[id]?.pending.count ?? 0) - waiter.pending.count
            if waiter.pending.isEmpty {
                resolveBackground(id, .refreshed(newlyPublished: waiter.newlyPublished, failedKeys: waiter.failedKeys + lost))
            }
        }
    }

    /// The only way a waiter ends: removes it first, so its continuation resumes exactly once. A
    /// result decided before the caller attached its continuation is kept for it.
    private func resolveBackground(_ id: Int, _ outcome: RecordingsSyncOutcome) {
        guard let waiter = backgroundWaiters.removeValue(forKey: id) else { return }
        if let continuation = waiter.continuation {
            continuation.resume(returning: outcome)
        } else {
            backgroundResults[id] = outcome
        }
    }

    /// The caller's task was cancelled. Nothing is awaited first, so the answer is immediate.
    /// - Nothing else needs the browser (no page, no sign-in, no Play or recovery, no other
    ///   waiter): the whole thing stops, like a window closing used to (`invalidate`), and the
    ///   browser goes.
    /// - Otherwise only the courses this refresh added and nobody else wants are dropped; an
    ///   in-flight listing finishes and is recorded as usual.
    private func backgroundCancelled(_ id: Int) {
        guard let waiter = backgroundWaiters[id] else { return }
        let othersWait = backgroundWaiters.contains { $0.key != id }
        if visiblePages == 0, access != .signingIn, !hasPlayOrRecovery, !othersWait {
            invalidate()
            closeBrowser()
            resolveBackground(id, .cancelled)
            return
        }
        let wantedByOthers = backgroundWaiters.filter { $0.key != id }.reduce(into: Set<RecmanCourseKey>()) { $0.formUnion($1.value.pending) }
        let wantedByPage = visiblePages > 0 ? Set(pageKeys) : []
        let drop = waiter.added.subtracting(wantedByOthers).subtracting(wantedByPage)
        for key in drop where key != runningKey { listings[key]?.isLoading = false }
        queue.removeAll { if case .list(let key) = $0 { drop.contains(key) } else { false } }
        resolveBackground(id, .cancelled)
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
                    let recorded = await record(recordings, for: key, generation: generation)
                    guard generation == self.generation else { return }
                    runningKey = nil
                    finishBackgroundKey(key, recorded)
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
                    runningPlayGeneration = generation
                    defer { if runningPlayGeneration == generation { runningPlayGeneration = nil } }
                    try await playNatively(recording, request: request, browser: browser, generation: generation)
                    guard generation == self.generation else { return }
                    // Reached the player or the browser fallback: no longer the menu's to report.
                    if menuPlay?.request == request { menuPlay = nil }
                case .recover(let recording, let recovery):
                    runningRecoveryGeneration = generation
                    defer { if runningRecoveryGeneration == generation { runningRecoveryGeneration = nil } }
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
        // A recovery, a Play (from the menu bar, or from a window closed meanwhile) or a sync
        // refresh ran while no Recordings page was on screen: the browser it needed has no
        // reason to stay open (a stream doesn't use it).
        if closesBrowserWhenIdle, queue.isEmpty, visiblePages == 0, access != .signingIn {
            closesBrowserWhenIdle = false
            closeBrowser()
        }
        // After the save and the close, so a caller that returns finds both done (and the
        // system activity of an automatic sync covers them).
        resolveFinishedBackground()
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
        // The replaced lecture's report inside `play` reads this to tell an end from a re-play.
        pendingPlayID = recording.id
        let metadata = playbackMetadata(for: recording, stream: stream)
        playbackMetadata = (recording.id, metadata)
        player.play(stream.url, title: recording.title.isEmpty ? (stream.title ?? "") : recording.title, cookies: [], startAt: startAt, recordingID: recording.id, metadata: metadata)
        pendingPlayID = nil
        nowPlaying = nowPlaying.filter { $0.key == recording.id }
        recoveredLectures = recoveredLectures.intersection(nowPlaying.keys)
        startWatchSession(for: recording, at: startAt ?? 0, streamDuration: stream.duration)
    }

    /// What Now Playing shows for `recording`: the same metadata as before when this is a
    /// recovery of the lecture still in the player, else its title with the course the student
    /// chose (`playbackCourse`), read afresh.
    private func playbackMetadata(for recording: RecmanRecording, stream: RecordingStream) -> RecordingPlaybackMetadata {
        if let playbackMetadata, playbackMetadata.recordingID == recording.id, recoveredLectures.contains(recording.id) {
            return playbackMetadata.metadata
        }
        var preferred: Int64?
        if let menuPlayCourse, menuPlayCourse.recordingID == recording.id { preferred = menuPlayCourse.courseID }
        else if case .course(let id) = study.destination { preferred = id }
        menuPlayCourse = nil
        let course = Self.playbackCourse(for: recording, preferredID: preferred, in: courses())
        return RecordingPlaybackMetadata(recording: recording, course: course, streamTitle: stream.title)
    }

    /// The WeBeep course `recording` is played from: the course the student chose
    /// (`preferredID`: the menu line's course, or the page's selected course) when it is the
    /// recording's own (same archive key); otherwise the one course with that key, nil when none
    /// or several. Two WeBeep courses can share a key (a course split in sections): re-matching
    /// alone would then drop the name and picture of the one the student opened.
    nonisolated static func playbackCourse(for recording: RecmanRecording, preferredID: Int64?, in courses: [RemoteCourseSummary]) -> RemoteCourseSummary? {
        if let preferredID, let course = courses.first(where: { $0.id == preferredID }),
           let key = RecmanCourseKey(course: course), key == RecmanCourseKey(courseCode: recording.courseCode, academicYear: recording.academicYear) {
            return course
        }
        return RecordingPlaybackMetadata.course(of: recording, in: courses)
    }

    private func currentPlayer() -> RecordingPlaying {
        if let player { return player }
        let player = makePlayer()
        // Both arrive on the main actor (the player hops before calling them).
        player.onPositionCheckpoint = { [weak self] checkpoint in
            self?.playerCheckpoint(checkpoint)
        }
        player.onProgress = { [weak self] id, position, duration in
            self?.playerProgress(id: id, position: position, duration: duration)
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

    /// The identity the lecture belongs to is going away (disconnect, university or
    /// account change): the player closes and its last report is refused. Disabling instead
    /// preserves its final checkpoint. Safe with no player.
    private func closePlayerForIdentityChange(preservingResumePoints: Bool = false) {
        if preservingResumePoints { player?.close() }
        nowPlaying = [:]
        currentLectureID = nil
        recoveredLectures = []
        // `playbackMetadata = nil` is a defensive duplicate: the metadata is only read for a
        // lecture in `recoveredLectures` (`playbackMetadata(for:stream:)`), which was just emptied,
        // so no test can tell it from the line above (`anAccountChangeDropsThePlaybackMetadata`
        // checks the observable result). It stays so the previous account's course name and
        // picture address never linger in memory if that read condition is ever loosened.
        // `menuPlayCourse = nil` is NOT redundant: it is consumed only by a Play that reaches the
        // player, so one that ended in the browser leaves it set, and it beats the selected course
        // (`aMenuCourseNeverPlayedDoesNotSurviveAnAccountChange`).
        playbackMetadata = nil
        menuPlayCourse = nil
        // The sessions belong to the account going away; `forgetSeen` clears the rest.
        sessions = [:]
        if !preservingResumePoints { player?.close() }
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

    /// The player's report of where the student stopped. The resume point is written only when it
    /// changes what is stored; a lecture watched to the end is forgotten and counts as seen. The
    /// same report is a watch-progress checkpoint (`recordWatchCheckpoint`).
    private func playerCheckpoint(_ checkpoint: RecordingCheckpoint) {
        let id = checkpoint.id
        if checkpoint.reason == .closed, currentLectureID == id { playbackIntent += 1 }
        // The lecture left the player: its Now Playing metadata is no longer a recovery's to reuse.
        // A defensive duplicate of the `recoveredLectures` condition in `playbackMetadata(for:stream:)`
        // (a fresh Play removes the lecture from that set first); it only frees the stored value.
        // The rule itself is tested by `aReplayAfterAWindowClosedBeforeReadyReadsTheCourseAgain`,
        // which closes without a checkpoint so only the set's condition decides.
        if checkpoint.reason == .closed, playbackMetadata?.recordingID == id { playbackMetadata = nil }
        guard let recording = nowPlaying[id], let owner = resumeOwner() else { return }
        recordWatchCheckpoint(checkpoint, of: recording, owner: owner)
        let update = RecordingPlaybackProgress.update(position: checkpoint.position, duration: checkpoint.duration)
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

    /// Positions are removed on disconnect, university change and account change.
    private func forgetResumePoints() {
        resumePoints = nil
        if defaults.object(forKey: Self.resumePointsKey) != nil { defaults.removeObject(forKey: Self.resumePointsKey) }
    }

    // MARK: Watch progress

    /// One lecture's playing session, numbered so a failed save can be superseded by a later
    /// checkpoint of the same session only.
    private struct LiveWatchSession {
        let serial: Int
        /// `RecordingsStudyState.identity` of the lecture, for its live value in the model.
        let identity: String
        var progress: RecordingWatchSession
    }

    /// A checkpoint whose save failed, kept for the next checkpoint (`unsavedCheckpoints`).
    /// `owner` travels with the event and is checked again at commit (`isCurrentIdentity`), so a
    /// retry can never be written under another account, even across an account change that
    /// doesn't go through `forgetSeen` (no saved Polimi session; see `webBeepAccountChanged`).
    private struct UnsavedCheckpoint {
        let recording: RecmanRecording
        let owner: Int
        var event: RecordingProgressEvent
        /// `untickCounts[identity]` when the event was queued: see `retryUnsavedCheckpoints`.
        var untickEpoch: Int
    }

    /// At most this many failed checkpoints are kept for a retry (the most recent sessions). Under
    /// a disk that keeps failing each ended lecture would add one and every checkpoint re-queue
    /// them all (principle 6); a lecture dropped here loses only its unsaved progress, never a
    /// done mark (those are the student's ticks, which report their failure instead).
    static let maxUnsavedCheckpoints = 20

    /// Whether the student can tick lectures: on, and the account known (rows are keyed by it).
    var canEditProgress: Bool { resumeOwner() != nil }

    /// Starts (or continues) the session of the lecture just handed to the player, observing
    /// where it starts. A recovery or a Play again of the same lecture continues its session:
    /// neither ends the lecture, so a crossing seen before it still counts at the close. Sessions
    /// of lectures no longer in `nowPlaying` go (a stream that never started reports nothing).
    /// `start` is 0 from the beginning; with no known length (neither the stream's nor the
    /// archive's) the session starts unobserved (`RecordingWatchSession(start: nil)`).
    ///
    /// The start is not published as a live value: a stream that never becomes ready reports
    /// nothing (no tick, no checkpoint), and a live value set here would linger on the row and in
    /// the summary as a percentage nobody saved. The first tick or checkpoint shows it.
    private func startWatchSession(for recording: RecmanRecording, at start: TimeInterval, streamDuration: TimeInterval?) {
        // A lecture closed before it was ready leaves the player without a report: its session
        // goes when another lecture takes its place.
        for (id, gone) in sessions where nowPlaying[id] == nil {
            sessions[id] = nil
            watchProgress.setLive(nil, for: gone.identity)
        }
        guard resumeOwner() != nil else { return }
        let fraction = RecordingWatchProgress.fraction(position: start, playerDuration: streamDuration, archiveMinutes: recording.minutes)
        if var session = sessions[recording.id] {
            if let fraction { session.progress.observe(fraction) }
            sessions[recording.id] = session
        } else {
            sessions[recording.id] = newSession(for: recording, start: fraction)
        }
    }

    /// The stream of `id` never started (`RecordingPlaybackFailure.beforeReady`): the player
    /// closed its window without a report, so the session ends here, with nothing to save. Kept
    /// otherwise, a Play of the same lecture after the browser fallback would continue it.
    private func endWatchSessionBeforeReady(_ id: String) {
        guard let gone = sessions.removeValue(forKey: id) else { return }
        watchProgress.setLive(nil, for: gone.identity)
    }

    /// A periodic tick from the playing lecture: memory only. Moves the window's bar and the
    /// course's live summary; never a write, never `watchSummaries` (the menu changes at
    /// checkpoints only). Refused for a lecture no longer playing or an unknown account.
    private func playerProgress(id: String, position: TimeInterval, duration: TimeInterval?) {
        guard let recording = nowPlaying[id], resumeOwner() != nil,
              let fraction = RecordingWatchProgress.fraction(position: position, playerDuration: duration, archiveMinutes: recording.minutes) else { return }
        var session = sessions[id] ?? newSession(for: recording, start: nil)
        session.progress.observe(fraction)
        sessions[id] = session
        publishLive(of: recording)
    }

    private func newSession(for recording: RecmanRecording, start: Double?) -> LiveWatchSession {
        sessionSerial += 1
        return LiveWatchSession(serial: sessionSerial, identity: RecordingsStudyState.identity(recording), progress: RecordingWatchSession(start: start))
    }

    /// The session's furthest point into the model and the course's live summary, if it moved.
    private func publishLive(of recording: RecmanRecording) {
        let identity = RecordingsStudyState.identity(recording)
        let fraction = sessions[recording.id]?.progress.maxFraction
        guard watchProgress.live[identity] != fraction else { return }
        watchProgress.setLive(fraction, for: identity)
        if let key = Self.courseKey(of: recording) { refreshWatchSummary(for: key, persist: false) }
    }

    /// A player checkpoint as watch progress. The checkpoint's own position is observed first:
    /// ticks stop at a pause, so it is the only report of where the lecture really stopped. A
    /// close, or a replacement by another lecture (`pendingPlayID`), ends the session. Then the
    /// event goes on the write chain, after any checkpoint whose save failed earlier.
    private func recordWatchCheckpoint(_ checkpoint: RecordingCheckpoint, of recording: RecmanRecording, owner: Int) {
        var session = sessions[checkpoint.id] ?? newSession(for: recording, start: nil)
        if let fraction = RecordingWatchProgress.fraction(position: checkpoint.position, playerDuration: checkpoint.duration, archiveMinutes: recording.minutes) {
            session.progress.observe(fraction)
        }
        let closes = RecordingWatchProgress.checkpointCloses(reason: checkpoint.reason, reportedID: checkpoint.id, nextID: pendingPlayID)
        sessions[checkpoint.id] = closes ? nil : session
        if !closes { publishLive(of: recording) }
        // This session's own older failed checkpoint is superseded by this one.
        unsavedCheckpoints[session.serial] = nil
        retryUnsavedCheckpoints()
        enqueueProgress(.checkpoint(session: session.progress, closes: closes), for: recording, owner: owner, serial: session.serial,
                        untickEpoch: untickCounts[session.identity, default: 0])
    }

    /// Re-queues every failed checkpoint, oldest session first. One overtaken by an un-tick of
    /// its lecture (the count changed since it was queued) loses its crossing first: retried as
    /// it was, a close seen at 95 % before the un-tick would complete the lecture again, undoing
    /// the student's choice (`applyCheckpoint` completes a blocked lecture on a crossing).
    private func retryUnsavedCheckpoints() {
        for serial in unsavedCheckpoints.keys.sorted() {
            guard var unsaved = unsavedCheckpoints.removeValue(forKey: serial) else { continue }
            let identity = RecordingsStudyState.identity(unsaved.recording)
            let current = untickCounts[identity, default: 0]
            if unsaved.untickEpoch != current, case .checkpoint(var session, let closes) = unsaved.event {
                session.resetCrossing()
                unsaved.event = .checkpoint(session: session, closes: closes)
                unsaved.untickEpoch = current
            }
            enqueueProgress(unsaved.event, for: unsaved.recording, owner: unsaved.owner, serial: serial, untickEpoch: unsaved.untickEpoch)
        }
    }

    /// The student ticks (`done`) or un-ticks a lecture ("done / attended in person"). The row
    /// keeps showing the saved value, disabled, until the write commits, like the "new" dots;
    /// a failed save says so with the history banner and leaves the saved value. Un-ticking also
    /// forgets the crossing the playing session has seen, at once rather than at commit: a close
    /// queued behind the un-tick must already carry the reset session.
    func setDone(_ recording: RecmanRecording, _ done: Bool) {
        // The key first: a recording without a valid course key can't be written, and must not
        // leave its checkbox pending forever.
        guard let owner = resumeOwner(), Self.courseKey(of: recording) != nil else { return }
        let identity = RecordingsStudyState.identity(recording)
        guard !watchProgress.pending.contains(identity) else { return }
        if !done {
            sessions[recording.id]?.progress.resetCrossing()
            untickCounts[identity, default: 0] += 1
        }
        watchProgress.setPending(true, for: identity)
        enqueueProgress(.manual(done: done), for: recording, owner: owner, serial: nil, untickEpoch: untickCounts[identity, default: 0])
    }

    /// One serial operation for the full course listing. Entries publish only after their
    /// commits; summary and acknowledgement are batched once, avoiding a full-list scan per row.
    /// Capture the history and owner before queueing so a reset cannot redirect these writes.
    func toggleAllDone(_ key: RecmanCourseKey) {
        let recordings = listings[key]?.recordings
        let action = RecordingsPresentation.WatchValues(watchProgress, canEdit: canEditProgress)
            .bulkAction(for: key, recordings: recordings)
        guard action.enabled, let recordings, let owner = resumeOwner(),
              recordings.allSatisfy({ Self.courseKey(of: $0) == key }) else { return }
        let done = !action.allDone
        let identities = Set(recordings.map(RecordingsStudyState.identity))
        if !done {
            for recording in recordings {
                sessions[recording.id]?.progress.resetCrossing()
                untickCounts[RecordingsStudyState.identity(recording), default: 0] += 1
            }
        }
        watchProgress.setPending(true, for: identities, course: key)
        let token = UUID()
        bulkTokens[key] = token
        let history = seenHistory
        let reset = historyResetTask
        let previous = progressChain
        progressChain = Task { [weak self] in
            await previous?.value
            await reset?.value
            guard let self else { return }
            defer {
                if self.bulkTokens[key] == token {
                    self.bulkTokens[key] = nil
                    self.watchProgress.setPending(false, for: identities, course: key)
                }
            }
            var completed: [String] = []
            var failed = false
            for recording in recordings {
                guard self.isCurrentIdentity(history, owner: owner) else { return }
                let changedDone = await self.commitProgress(.manual(done: done), for: recording, key: key,
                    owner: owner, history: history, serial: nil,
                    untickEpoch: self.untickCounts[RecordingsStudyState.identity(recording), default: 0],
                    deferCourseUpdate: true)
                guard let changedDone else { failed = true; break }
                if changedDone { completed.append(recording.id) }
            }
            guard self.isCurrentIdentity(history, owner: owner) else { return }
            self.refreshWatchSummary(for: key, persist: true)
            // A refresh may have evicted the listing meanwhile, and then the summary above can't
            // be recomputed: drop a saved `next` that was just completed, as the per-row path does.
            let completedIDs = Set(completed)
            for recording in recordings where completedIDs.contains(recording.id) {
                self.clearSavedNextIfCompleted(recording, in: key)
            }
            self.scheduleAcknowledge(completed, for: key, preserveHistoryProblem: failed)
        }
    }

    /// Appends one write to the serial chain. The task is unstructured and kept only as the next
    /// write's predecessor: nothing cancels it, so the store's cancellation check can't drop it.
    /// The history actor is captured now, not when the write runs: a write queued before a reset
    /// must reach the old (invalidated) actor and be refused, never the next namespace. The
    /// owner travels with the event too and is checked again at commit (`isCurrentIdentity`).
    private func enqueueProgress(_ event: RecordingProgressEvent, for recording: RecmanRecording, owner: Int, serial: Int?, untickEpoch: Int) {
        guard let key = Self.courseKey(of: recording) else { return }
        let history = seenHistory
        let reset = historyResetTask
        let previous = progressChain
        progressChain = Task { [weak self] in
            await previous?.value
            await reset?.value
            await self?.commitProgress(event, for: recording, key: key, owner: owner, history: history, serial: serial, untickEpoch: untickEpoch)
        }
    }

    /// Runs one write and publishes what it committed, only while the identity it belongs to is
    /// still current (`isCurrentIdentity`, deliberately not the page `generation`: a pause saved
    /// after the window closed is still this account's progress).
    /// - `CancellationError` (before or after the commit): the identity is gone; discard silently.
    /// - Unchanged: the stored entry is still published (it may be the first time the model
    ///   learns it, e.g. a Watchlist row with no listing loaded, or a tick on a lecture already
    ///   done in the store), but nothing was written, so no revision bump and no acknowledgement.
    /// - Changed: the entry, a bumped `historyRevision` (an older listing snapshot then requeries
    ///   instead of overwriting it), the course summary, and the "new" dot when it is done.
    /// - Other errors: a checkpoint is kept for the next one, logged, no banner; a tick shows the
    ///   history banner and the row keeps its saved value.
    @discardableResult
    private func commitProgress(_ event: RecordingProgressEvent, for recording: RecmanRecording, key: RecmanCourseKey, owner: Int, history: RecordingsSeenHistory, serial: Int?, untickEpoch: Int, deferCourseUpdate: Bool = false) async -> Bool? {
        let identity = RecordingsStudyState.identity(recording)
        let isManual = if case .manual = event { true } else { false }
        guard isCurrentIdentity(history, owner: owner) else { return nil }
        let result: RecordingProgressResult
        do {
            result = try await history.applyProgress(owner: owner, key: key, id: recording.id, event: event)
        } catch is CancellationError {
            if isManual, !deferCourseUpdate, isCurrentIdentity(history, owner: owner) { watchProgress.setPending(false, for: identity) }
            return nil
        } catch {
            guard isCurrentIdentity(history, owner: owner) else { return nil }
            if isManual {
                if !deferCourseUpdate { watchProgress.setPending(false, for: identity) }
                listings[key]?.problem = .historyUnavailable
                log.error("Couldn't save a lecture's done mark")
            } else if let serial {
                // Failures arrive in chain order, so this replaces an older failure of the same
                // session. Retrying it later, after writes queued since, can't lower anything
                // (furthest never decreases) and can't end the session early (a close is always a
                // session's last event); an un-tick in between is neutralised at retry time
                // (`retryUnsavedCheckpoints`).
                unsavedCheckpoints[serial] = UnsavedCheckpoint(recording: recording, owner: owner, event: event, untickEpoch: untickEpoch)
                // Keep the most recent sessions only (serials grow with time).
                while unsavedCheckpoints.count > Self.maxUnsavedCheckpoints, let oldest = unsavedCheckpoints.keys.min() {
                    unsavedCheckpoints[oldest] = nil
                }
                log.error("Couldn't save watch progress; retried at the next checkpoint")
            }
            return nil
        }
        // Not only a second layer behind the store's own invalidation (which reports a commit
        // racing a reset as a cancellation): the WeBeep account can change without a reset when
        // no Polimi session was saved, and then only this check keeps the old account's entry off
        // the screen.
        guard isCurrentIdentity(history, owner: owner) else { return nil }
        if isManual && !deferCourseUpdate { watchProgress.setPending(false, for: identity) }
        // An ended session's position now lives in the entry (or never will, if the save failed
        // and is waiting for a retry): the live value goes unless the lecture is playing again.
        if case .checkpoint(_, true) = event, sessions[recording.id] == nil { watchProgress.setLive(nil, for: identity) }
        let published = watchProgress.setEntry(result.entry, for: identity)
        if result.changed { historyRevision[key, default: 0] += 1 }
        if !deferCourseUpdate && (result.changed || published) { refreshWatchSummary(for: key, persist: true) }
        if !deferCourseUpdate, result.changed, result.entry?.isCompleted == true {
            clearSavedNextIfCompleted(recording, in: key)
            scheduleAcknowledge([recording.id], for: key)
        }
        return result.changed && result.entry?.isCompleted == true
    }

    private static func courseKey(of recording: RecmanRecording) -> RecmanCourseKey? {
        RecmanCourseKey(courseCode: recording.courseCode, academicYear: recording.academicYear)
    }

    /// Recomputes a loaded course's summary, with its next lecture (`CourseWatchSummary.next`,
    /// what a click on the course's menu line plays). The window's (`watchProgress.summaries`)
    /// includes the playing lecture's live position; the saved one (`watchSummaries`, `persist`)
    /// uses saved entries only, so a tick never changes the menu or writes the settings. `next`
    /// is the same in both: `nextToWatch` reads committed entries only, never `live`, so it moves
    /// at a checkpoint (an untouched lecture first saved past 0 %, a completion), never on a tick.
    /// A course whose listing isn't loaded keeps its last saved summary (but see
    /// `clearSavedNextIfCompleted`).
    ///
    /// `newCount` (the menu line's " · N nuove") is computed here from the listing in memory:
    /// the lectures of the listing that are unseen (no "new" dot cleared yet: `seenIDs`) AND not
    /// completed. A lecture ticked as attended in person without being opened is therefore not
    /// "new", and `menuLine`'s "all done" guard never has to hide a contradiction. Nil (nothing
    /// claimed) while the listing's seen state is unknown (its history read failed, or it was
    /// forgotten with the account). Callers recompute it whenever one of its inputs changes: a
    /// listing (`record`), a committed acknowledgement (`scheduleAcknowledge`) and a committed
    /// progress write (`commitProgress`); the saved summary is rewritten only when the value
    /// differs (`storeWatchSummary`), so a refresh that finds nothing new writes nothing.
    private func refreshWatchSummary(for key: RecmanCourseKey, persist: Bool) {
        guard let listing = listings[key], let recordings = listing.recordings else { return }
        let owner = resumeOwner()
        if let owner { loadWatchSummaries(owner: owner) }
        var entries: [String: RecordingWatchEntry] = [:]
        var live: [String: Double] = [:]
        for recording in recordings {
            let identity = RecordingsStudyState.identity(recording)
            entries[recording.id] = watchProgress.entries[identity]
            live[recording.id] = watchProgress.live[identity]
        }
        let newCount = listing.seenIDs.map { seen in
            recordings.reduce(0) { count, recording in
                count + (!seen.contains(recording.id) && entries[recording.id]?.isCompleted != true ? 1 : 0)
            }
        }
        watchProgress.setSummary(RecordingWatchProgress.courseSummary(recordings: recordings, entries: entries, live: live, newCount: newCount), for: key)
        guard persist, let owner else { return }
        storeWatchSummary(RecordingWatchProgress.courseSummary(recordings: recordings, entries: entries, live: [:], newCount: newCount), for: key, owner: owner)
    }

    /// A lecture just completed in a course whose listing isn't in memory (a menu Play whose
    /// listing failed, a Watchlist row's tick): `refreshWatchSummary` can't recompute the
    /// course, so the saved summary would keep offering, on the menu line, the lecture that was
    /// just finished. When that lecture is the saved `next`, it is dropped (the line goes grey
    /// until the next listing works out the new one); the counts stay as they were, since they
    /// can't be recomputed without the listing either.
    private func clearSavedNextIfCompleted(_ recording: RecmanRecording, in key: RecmanCourseKey) {
        guard listings[key]?.recordings == nil, let owner = resumeOwner() else { return }
        loadWatchSummaries(owner: owner)
        guard let saved = watchSummaries[key], saved.next?.id == recording.id else { return }
        storeWatchSummary(CourseWatchSummary(done: saved.done, total: saved.total, remainingMinutes: saved.remainingMinutes,
                                             unknownDurationCount: saved.unknownDurationCount, next: nil, newCount: saved.newCount), for: key, owner: owner)
    }

    /// Reads the saved summaries of `owner` once per account, before the first change of a
    /// launch, so a change to one course keeps the others.
    private func loadWatchSummaries(owner: Int) {
        guard watchSummaryOwner != owner else { return }
        watchSummaryOwner = owner
        watchSummaries = Self.storedWatchSummaries(in: defaults, owner: owner) ?? [:]
    }

    /// Saves a course's summary under `owner`, only when it differs from the saved one: a listing
    /// or a write that changes nothing in it writes nothing. The comparison is of the whole value,
    /// `next` included, so only a change of the counts or of the next lecture writes. Both sides
    /// go through the saved projection (`StoredCourseWatchSummary.persisted`): after a relaunch
    /// the in-memory copy is the decoded one, whose `next` lacks the date, kind and size, and a
    /// raw comparison rewrote and republished every course after each launch (#189).
    private func storeWatchSummary(_ summary: CourseWatchSummary, for key: RecmanCourseKey, owner: Int) {
        loadWatchSummaries(owner: owner)
        guard watchSummaries[key].map({ StoredCourseWatchSummary($0).persisted }) != StoredCourseWatchSummary(summary).persisted else { return }
        var updated = watchSummaries
        updated[key] = summary
        let stored = StoredWatchSummaries(owner: owner, courses: Dictionary(uniqueKeysWithValues: updated.map { (Self.baselineID(courseCode: $0.key.courseCode, academicYear: $0.key.academicYear), $0.value) }))
        guard let data = try? PropertyListEncoder().encode(stored) else {
            // Only the menu's copy is lost; the progress itself is in the database.
            log.error("Couldn't save the recordings summary")
            return
        }
        defaults.set(data, forKey: Self.watchSummaryKey)
        watchSummaries = updated
    }

    /// What `watchSummaryKey` holds: one account's counts and minimal next-lecture targets,
    /// by "code-year". The menu rebuilds its text in the current language.
    struct StoredWatchSummaries: Codable, Equatable {
        let owner: Int
        let courses: [String: CourseWatchSummary]

        private enum CodingKeys: String, CodingKey { case owner, courses }

        init(owner: Int, courses: [String: CourseWatchSummary]) {
            self.owner = owner
            self.courses = courses
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            owner = try values.decode(Int.self, forKey: .owner)
            courses = try values.decode([String: StoredCourseWatchSummary].self, forKey: .courses).mapValues(\.summary)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(owner, forKey: .owner)
            try values.encode(courses.mapValues { StoredCourseWatchSummary($0) }, forKey: .courses)
        }
    }

    /// The saved summaries of `owner`, or nil when there are none, they are unreadable, or they
    /// belong to another account. For the menu bar at launch, without a controller.
    nonisolated static func storedWatchSummaries(in defaults: UserDefaults, owner: Int) -> [RecmanCourseKey: CourseWatchSummary]? {
        guard let data = defaults.data(forKey: watchSummaryKey),
              let stored = try? PropertyListDecoder().decode(StoredWatchSummaries.self, from: data),
              stored.owner == owner else { return nil }
        var result: [RecmanCourseKey: CourseWatchSummary] = [:]
        for (id, summary) in stored.courses {
            // "code-year": the year is after the last dash, whatever the code contains.
            guard let dash = id.lastIndex(of: "-"), let year = Int(id[id.index(after: dash)...]),
                  let key = RecmanCourseKey(courseCode: String(id[..<dash]), academicYear: year) else { continue }
            result[key] = summary
        }
        return result
    }

    /// Removes saved summaries that don't belong to `owner`, without a controller (the pattern of
    /// `forgetResumePoints(in:notOwnedBy:)`): an account change in a launch that never created
    /// Recordings must not show the previous account's numbers. Unreadable data goes too.
    nonisolated static func forgetWatchSummary(in defaults: UserDefaults, notOwnedBy owner: Int) {
        guard let data = defaults.data(forKey: watchSummaryKey) else { return }
        if let stored = try? PropertyListDecoder().decode(StoredWatchSummaries.self, from: data), stored.owner == owner { return }
        defaults.removeObject(forKey: watchSummaryKey)
    }

    // MARK: Recovery

    private func playerFailed(id: String, failure: RecordingPlaybackFailure) {
        guard isEnabled, let recording = nowPlaying[id] else { return }
        if case .beforeReady = failure { endWatchSessionBeforeReady(id) }
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
            switch failure {
            case .beforeReady: openingProblem = .playbackUnavailable
            // The window stays open, paused where the stream stopped: it says why (#197).
            case .duringPlayback: reportStoppedLecture(recording, message: Self.signInToContinueMessage)
            }
            return
        }
        if visiblePages == 0 { closesBrowserWhenIdle = true }
        queue.insert(.recover(recording, recovery), at: 0)
        startWorker()
    }

    private func recoverPlayback(_ recording: RecmanRecording, _ recovery: Recovery, browser: RecmanBrowsing, generation: Int) async throws {
        // The player link a failed fresh-stream lookup already found, for the browser below.
        var found: URL?
        let intent = playbackIntent
        let needsOpenPlayer: Bool
        if case .freshStream = recovery { needsOpenPlayer = true } else { needsOpenPlayer = false }
        let isCurrent = {
            generation == self.generation && intent == self.playbackIntent
                && self.currentLectureID == recording.id && (!needsOpenPlayer || self.stillShowing(recording))
        }
        if case .freshStream(let position) = recovery {
            guard stillShowing(recording) else { return }
            recoveredLectures.insert(recording.id)
            if confirmedEmail == nil {
                await learnEmail()
                guard isCurrent() else { return }
            }
            do {
                let stream = try await browser.stream(for: recording, email: confirmedEmail)
                guard isCurrent() else { return }
                startPlayer(stream, for: recording, startAt: position)
                return
            } catch {
                guard isCurrent() else { return }
                let (cause, player) = Self.streamFailureCause(error)
                found = player
                let diagnosis = "play: recovery stream failed reason=\(Self.playFailureReason(cause).rawValue) error=\(PlaybackDiagnostics.errorName(cause))"
                PlaybackDiagnostics.log.notice("\(diagnosis, privacy: .public)")
                if (cause as? RecmanBrowserError) == .needsSignIn {
                    reportStoppedLecture(recording, message: Self.signInToContinueMessage)
                    throw cause
                }
                if cause is CancellationError { throw cause }
                if (cause as? RecmanBrowserError) == .needsEmail {
                    // Same decision as for Play: no Webex page for the student, only the sentence.
                    // The window stays, paused at the place it stopped, and says it too (#197).
                    openingProblem = RecordingsProblem(cause)
                    reportStoppedLecture(recording, message: RecordingsProblem(cause).message)
                    log.notice("Fresh stream needs a confirmed email")
                    return
                }
                log.notice("Fresh stream not available: opening the browser")
            }
        }
        do {
            let url = try await playerLink(for: recording, browser: browser, found: found)
            guard isCurrent() else { return }
            playbackURLs[recording.id] = url
            // The window of a lecture that can't continue is no use next to the browser. Closing
            // it reports the position, so the student's place is kept.
            if currentLectureID == recording.id { player?.close() }
            openURL(url)
        } catch {
            guard isCurrent() else { return }
            if (error as? RecmanBrowserError) == .needsSignIn {
                reportStoppedLecture(recording, message: Self.signInToContinueMessage)
                throw error
            }
            if error is CancellationError { throw error }
            openingProblem = RecordingsProblem(error)
            // A second mid-lecture failure leaves its window open: it says why too (#197).
            reportStoppedLecture(recording, message: RecordingsProblem(error).message)
            log.error("Couldn't open a failed lecture in the browser")
        }
    }

    /// A mid-lecture failure whose recovery ended with neither a new stream nor the browser
    /// (issue #197): `openingProblem` reaches only a Recordings page, and a lecture started from
    /// the menu bar may have none, so the player window, still paused where the stream stopped,
    /// shows the reason too. Only while that lecture is still the one on screen.
    private func reportStoppedLecture(_ recording: RecmanRecording, message: String) {
        guard stillShowing(recording) else { return }
        player?.showProblem(message)
    }

    /// What the paused player window says when the lecture can't continue because the Polimi
    /// session lapsed: the page shows "Accedi con Polimi", the window points there. Resolved when
    /// shown (`tr`), never cached.
    static var signInToContinueMessage: String {
        tr("Accedi di nuovo con Polimi nella pagina Registrazioni per continuare.", "Sign in with Polimi again on the Recordings page to continue.")
    }

    /// Whether `recording` is still the lecture in the player's window: the student may have
    /// closed it or started another while a stream was being found.
    private func stillShowing(_ recording: RecmanRecording) -> Bool {
        currentLectureID == recording.id && (player?.isOpen ?? false)
    }

    /// What `record` did with a complete listing, for a sync refresh waiting on its course.
    private enum RecordResult: Equatable {
        /// Published with its seen state; `newlyPublished` lectures were first observed now.
        case published(newlyPublished: Int)
        /// The history couldn't be read (or no account is known): the previous list stays.
        case failed
        /// The identity changed while the history was read: nothing was published.
        case stale
    }

    /// The only publisher of a listing: the list, its seen IDs and its watch progress together.
    /// Called only with a complete listing (a partial one throws `incomplete` before), so the
    /// #106 baseline is created only here; every failure keeps the previous list and seen state.
    @discardableResult
    private func record(_ recordings: [RecmanRecording], for key: RecmanCourseKey, generation: Int) async -> RecordResult {
        guard let owner = sessionOwner ?? ownerUserID() else {
            listings[key]?.isLoading = false
            listings[key]?.problem = .historyUnavailable
            return .failed
        }
        let history = seenHistory
        let legacy = legacy(for: owner)
        await historyResetTask?.value
        guard isCurrentHistory(history, owner: owner, generation: generation) else { return .stale }
        do {
            let ids = recordings.map(\.id)
            var snapshot: RecordingsHistorySnapshot
            while true {
                let revision = historyRevision[key, default: 0]
                snapshot = try await history.seenAndProgress(owner: owner, key: key, ids: ids, legacy: legacy)
                guard isCurrentHistory(history, owner: owner, generation: generation) else { return .stale }
                // An acknowledgement or a progress write can commit/publish while this snapshot
                // returns. Requery rather than overwrite that newer state with an older snapshot.
                if historyRevision[key, default: 0] == revision { break }
            }
            let seen = snapshot.seen
            discardLegacyDefaults()
            // Read before anything below replaces them: the listing held in memory and the
            // saved summary's total are what "first observed in this refresh" compares with.
            // `isBaseline` is false on purpose: the store creates a baseline by marking every
            // listed ID seen in the same transaction (#106), so a baseline listing has no unseen
            // lecture and counts 0 whatever the flag says; the snapshot doesn't report whether
            // this read created it, and the controller must not guess from its own memory.
            loadWatchSummaries(owner: owner)
            let newlyPublished = RecordingsSyncPolicy.newlyPublishedCount(
                previousIDs: listings[key]?.recordings.map { Set($0.map(\.id)) },
                currentIDs: Set(ids), seenIDs: seen, isBaseline: false,
                storedTotal: watchSummaries[key]?.total)
            var listing = listings[key] ?? RecordingsListing()
            listing.recordings = recordings
            listing.seenIDs = seen
            listing.historyReadFailed = false
            listing.isLoading = queue.contains(.list(key))
            listing.problem = nil
            listing.updatedAt = now()
            // Publish the list and its history (seen IDs and watch progress) together, in one
            // main-actor turn. A failed refresh retains the previous triple, so a newly returned
            // list cannot use an incomplete/stale membership cache or show 0 % for a lecture
            // whose progress wasn't read.
            listings[key] = listing
            var identities: [String] = []
            var entries: [String: RecordingWatchEntry] = [:]
            identities.reserveCapacity(recordings.count)
            for recording in recordings {
                let identity = RecordingsStudyState.identity(recording)
                identities.append(identity)
                entries[identity] = snapshot.progress[recording.id]
            }
            watchProgress.setEntries(entries, for: identities)
            refreshWatchSummary(for: key, persist: true)
            updateStudy { $0.reconcile(recordings, for: key) }
            return .published(newlyPublished: newlyPublished)
        } catch {
            guard isCurrentHistory(history, owner: owner, generation: generation) else { return .stale }
            listings[key, default: RecordingsListing()].isLoading = queue.contains(.list(key))
            listings[key]?.problem = .historyUnavailable
            listings[key]?.historyReadFailed = true
            log.error("Couldn't load recording history")
            return .failed
        }
    }

    private func handle(_ error: Error, of job: Job) -> Outcome {
        // A menu Play this failure ends, told last, once access and the queue say what happened.
        var needsPage: RecmanCourseKey?
        defer { if let needsPage { onMenuPlayNeedsPage?(needsPage) } }
        if case RecmanBrowserError.needsSignIn = error {
            log.notice("Polimi session lapsed")
            // Before the queue is cleared: a menu Play failing, or waiting behind a listing that
            // found the session gone, needs the page's "Accedi con Polimi".
            needsPage = takeMenuPlayNeedingPage(failing: job, queued: true)
            access = .needsSignIn(nil)
            // A sync refresh ends here too, silently: no sign-in window, no activation; every
            // later sync skips Recordings until the student signs in again.
            clearQueue(background: .needsSignIn)
            closeBrowser()
            return .stopWithoutSaving
        }
        // Only another operation on the browser interrupts one, and only a sign-in starts one
        // while the worker runs, after bumping the generation. Nothing to tell the user.
        if error is CancellationError {
            // The menu Play's job goes with the queue and nobody is told (a cancellation is
            // never the student's problem): forgotten, so `menuPlay` names only a live job.
            menuPlay = nil
            clearQueue(background: .cancelled)
            return .stopWithoutSaving
        }
        let problem = RecordingsProblem(error)
        log.error("Recordings request failed problem=\(String(describing: problem), privacy: .public)")
        switch job {
        case .list(let key):
            listings[key, default: RecordingsListing()].problem = problem
            listings[key]?.isLoading = queue.contains(.list(key))
            // One course that couldn't be read is counted and the batch goes on; Polimi not
            // answering ends every waiter as `.unavailable` below instead.
            if problem != .unavailable { finishBackgroundKey(key, .failed) }
        case .open(let recording, _, _):
            if openingRecordingID == recording.id { openingRecordingID = nil }
            openingProblem = problem
            // `openingProblem` is shown by the page; with none on screen a menu Play asks for it.
            needsPage = takeMenuPlayNeedingPage(failing: job, queued: false)
        case .recover:
            // Not a click: `recoverPlayback` already told the lecture's window (#197) and only
            // rethrows a cancellation or a lapsed session.
            break
        }
        // Offline or Polimi down: every other request would wait for the same timeout.
        guard problem == .unavailable else { return .next }
        // A menu Play dropped with the rest says why on its course's page.
        needsPage = needsPage ?? takeMenuPlayNeedingPage(failing: nil, queued: true)
        for job in queue {
            switch job {
            case .list(let key): listings[key]?.problem = problem
            // A Play or Copy still waiting is dropped with the rest: it says why instead of the
            // click doing nothing.
            case .open: openingProblem = problem
            case .recover: break
            }
        }
        clearQueue(background: .unavailable)
        return .stop
    }

    /// Empties the queue, and with it every sync refresh still waiting, answered `background`
    /// (what emptied it: the session lapsed, Polimi not answering, a cancellation). Required, so
    /// no new way of clearing the queue can leave a caller of `refreshForSync` waiting forever.
    private func clearQueue(background end: BackgroundEnd) {
        queue.removeAll()
        runningKey = nil
        openingRecordingID = nil
        for key in listings.keys where listings[key]?.isLoading == true {
            listings[key]?.isLoading = false
        }
        for id in Array(backgroundWaiters.keys) {
            // Each waiter keeps the lectures its finished courses already published (#190).
            let newlyPublished = backgroundWaiters[id]?.newlyPublished ?? 0
            switch end {
            case .needsSignIn: resolveBackground(id, .needsSignIn(newlyPublished: newlyPublished))
            case .unavailable: resolveBackground(id, .unavailable(newlyPublished: newlyPublished))
            case .cancelled: resolveBackground(id, .cancelled)
            }
        }
    }

    /// What emptied the queue (`clearQueue`), turned into each waiting sync refresh's outcome with
    /// its own count: the early endings carry the lectures its finished courses already published
    /// (issue #190), a cancellation carries nothing (`RecordingsSyncOutcome.cancelled`).
    private enum BackgroundEnd {
        case needsSignIn, unavailable, cancelled
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
        // Its job goes with the queue below; nothing of it is left to report.
        menuPlay = nil
        worker?.cancel()
        worker = nil
        signInTask?.cancel()
        signInTask = nil
        // Turn-off, sign-out, an account or university change, a sign-in: a sync refresh's
        // results would belong to a generation that no longer exists.
        clearQueue(background: .cancelled)
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

    /// Whether the Settings field can take an address now: the feature is on and a WeBeep account
    /// is known to own it (see `confirmEmail`). The field is disabled and says why otherwise.
    var canConfirmEmail: Bool { isEnabled && (sessionOwner ?? ownerUserID()) != nil }

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
        guard canConfirmEmail else { return .unchanged }
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
        if defaults.bool(forKey: Self.sessionDiscardedKey) {
            retryObsoleteSessionDeletion()
            emailLoaded = true
            return []
        }
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
        guard vault.epoch == epoch, !defaults.bool(forKey: Self.sessionDiscardedKey) else { return [] }
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
            if generation == self.generation, vault.epoch == epoch, defaults.bool(forKey: Self.sessionDiscardedKey) {
                defaults.removeObject(forKey: Self.sessionDiscardedKey)
            }
            // The cycle's cached read now describes an older file.
            sessionLoad = nil
        case .unchanged:
            if generation == self.generation, vault.epoch == epoch, defaults.bool(forKey: Self.sessionDiscardedKey) {
                defaults.removeObject(forKey: Self.sessionDiscardedKey)
            }
        case .stale:
            log.notice("Polimi session not saved: discarded while saving")
        case .failed(let errorType):
            log.error("Couldn't save the Polimi session errorType=\(errorType, privacy: .public)")
        }
    }

    /// Bumps the vault epoch now, so every save already under way is refused, and deletes the
    /// file in turn, off the main actor.
    private func discardSessionFile() {
        defaults.set(true, forKey: Self.sessionDiscardedKey)
        sessionOwner = nil
        sessionLoad = nil
        // The email lives in the file and goes with it, in memory too.
        resetEmail()
        let delete = vault.discard()
        trackSessionDeletion(delete, epoch: vault.epoch)
    }

    /// Deletes again a session file discarded earlier (`sessionDiscardedKey`) whose deletion
    /// failed or never ran (#200). `RecmanSessionVault.retryDiscard` keeps a file a new session
    /// was saved to since, and bumps no epoch, so a sign-in in progress is not disturbed.
    private func retryObsoleteSessionDeletion() {
        guard sessionDeletion == nil, defaults.bool(forKey: Self.sessionDiscardedKey) else { return }
        trackSessionDeletion(vault.retryDiscard(), epoch: vault.epoch)
    }

    /// Clears the discard flag once the deletion is confirmed, unless a newer discard happened
    /// meanwhile (`epoch`): that one's own deletion decides. A failure keeps the flag, so the
    /// next controller or session read retries; it is only logged.
    private func trackSessionDeletion(_ delete: Task<RecmanSessionVault.DeleteOutcome, Never>, epoch: Int) {
        sessionDeletions += 1
        let id = sessionDeletions
        sessionDeletion = id
        Task { [weak self, log] in
            let outcome = await delete.value
            if case .failed(let errorType) = outcome {
                log.error("Couldn't delete the saved Polimi session errorType=\(errorType, privacy: .public)")
            }
            guard let self else { return }
            if self.sessionDeletion == id { self.sessionDeletion = nil }
            if outcome == .deleted, self.vault.epoch == epoch {
                self.defaults.removeObject(forKey: Self.sessionDiscardedKey)
            }
        }
    }

    /// Waits until every progress write queued so far has finished and published. For tests,
    /// which must prove that a write did *not* happen without guessing how long one takes.
    func settleWatchProgress() async {
        await progressChain?.value
    }

    /// Waits until the session file reflects every call made so far. For tests, which read the
    /// file from outside the vault.
    func settleSessionFile() async {
        await vault.settle()
    }
}
