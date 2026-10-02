import AppKit
import Foundation
import SwiftUI
import os
import WebKit
import BeepbarCore

enum AppFailure: Equatable {
    case authenticationExpired
    case connectivity
    case serviceUnavailable
    case incompatibleResponse
    case credentialUnavailable
    case partialSync
    case local(BilingualText)

    var title: String {
        switch self {
        case .authenticationExpired: tr("Accesso scaduto", "Sign-in expired")
        case .connectivity: tr("Connessione assente", "No connection")
        case .serviceUnavailable: tr("Piattaforma non disponibile", "Platform unavailable")
        case .incompatibleResponse: tr("Problema con la piattaforma", "Platform problem")
        case .credentialUnavailable: tr("Credenziale non disponibile", "Credential unavailable")
        case .partialSync: tr("Sincronizzazione incompleta", "Sync incomplete")
        case .local: tr("Richiede attenzione", "Needs attention")
        }
    }

    var compactDetail: String {
        switch self {
        case .authenticationExpired: tr("Accedi di nuovo", "Sign in again")
        case .connectivity: tr("Nessuna connessione", "No connection")
        case .serviceUnavailable: tr("Piattaforma non raggiungibile", "Platform unreachable")
        case .incompatibleResponse: tr("Risposta inattesa, riprova più tardi", "Unexpected response, try again later")
        case .credentialUnavailable: tr("Credenziale non leggibile", "Credential unreadable")
        case .partialSync: tr("Alcuni materiali non aggiornati", "Some materials not updated")
        case .local: tr("Apri BeepBar per i dettagli", "Open BeepBar for details")
        }
    }

    var detail: String {
        switch self {
        case .authenticationExpired: tr("Accedi di nuovo per riprendere la sincronizzazione.", "Sign in again to resume syncing.")
        case .connectivity: tr("Controlla la connessione. BeepBar riproverà automaticamente.", "Check your connection. BeepBar will retry automatically.")
        case .serviceUnavailable: tr("La piattaforma non risponde. I materiali locali restano disponibili.", "The platform isn't responding. Your local materials remain available.")
        case .incompatibleResponse: tr("La piattaforma ha restituito una risposta inattesa. Riprova più tardi.", "The platform returned an unexpected response. Try again later.")
        case .credentialUnavailable: tr("BeepBar non riesce a salvare o leggere la credenziale locale. Riprova più tardi.", "BeepBar can't save or read the local credential. Try again later.")
        case .partialSync: tr("Alcuni materiali non sono stati aggiornati. I file esistenti sono al sicuro.", "Some materials weren't updated. Your existing files are safe.")
        case .local(let message): message.text
        }
    }
}

/// What "Risparmio dati" (Data Saver) shows while it holds automatic sync back. Written for
/// people who don't know what a metered network is: what is happening, that it resumes by itself,
/// and that «Sincronizza ora» still downloads.
extension DataSaverPause {
    /// Window headline and menu title. Names the setting, so the user knows where it comes from.
    var title: String { tr("In pausa per Risparmio dati", "Paused by Data Saver") }

    /// One short line for the status menu.
    var compactDetail: String {
        switch self {
        case .hotspot: tr("In attesa del Wi-Fi", "Waiting for Wi-Fi")
        // Not "waiting for Wi-Fi": Low Data Mode is often turned on for a Wi-Fi network.
        case .lowDataMode: tr("Modalità dati ridotti attiva", "Low Data Mode is on")
        }
    }

    /// The window's explanation.
    var detail: String {
        switch self {
        case .hotspot: tr("Il Mac usa l'hotspot del telefono: BeepBar riprende da sola quando torni sul Wi-Fi, così non consuma i tuoi dati. «Sincronizza ora» scarica subito.", "Your Mac is using your phone's hotspot: BeepBar picks up again by itself once you're back on Wi-Fi, so it doesn't use up your data. “Sync now” downloads right away.")
        case .lowDataMode: tr("Su questa rete è attiva la Modalità dati ridotti: BeepBar riprende da sola quando passi a un'altra rete o la disattivi. «Sincronizza ora» scarica subito.", "Low Data Mode is on for this network: BeepBar picks up again by itself when you switch to another network or turn Low Data Mode off. “Sync now” downloads right away.")
        }
    }
}

/// What an automatic run reads about the Mac before it starts. Injected so tests can stand in for
/// Low Power Mode, a phone hotspot or a network change midway without depending on the Mac that
/// runs them; no test may reach the real `NWPathMonitor`.
struct AutomaticSyncEnvironment: Sendable {
    var isLowPowerModeEnabled: @Sendable () -> Bool
    /// Read only while "Risparmio dati" is on; `nil` when macOS gives no answer.
    var currentNetwork: @Sendable () async -> NetworkPathConditions?

    static let system = AutomaticSyncEnvironment(
        isLowPowerModeEnabled: { ProcessInfo.processInfo.isLowPowerModeEnabled },
        currentNetwork: { await NetworkPathReader.current() }
    )

    /// A Mac on mains power and an ordinary network, whatever the real one is doing.
    static func fixed(lowPowerMode: Bool = false, network: NetworkPathConditions? = .unrestricted) -> AutomaticSyncEnvironment {
        AutomaticSyncEnvironment(isLowPowerModeEnabled: { lowPowerMode }, currentNetwork: { network })
    }
}

enum AppSyncState: Equatable {
    case starting
    case loginRequired
    case needsFolder
    case readyUnchecked
    case checking
    case syncing
    case cancelling
    case synced(SyncCompletionSummary)
    case conflicts(Int, SyncCompletionSummary?)
    case partial(SyncCompletionSummary)
    case failed(AppFailure)
    case recoveryBlocked

    var title: String {
        switch self {
        case .starting: tr("Avvio", "Starting")
        case .loginRequired: tr("Accedi", "Sign in")
        case .needsFolder: tr("Apri Impostazioni", "Open Settings")
        case .readyUnchecked: tr("Pronto", "Ready")
        case .checking: tr("Controllo aggiornamenti", "Checking for updates")
        case .syncing: tr("Sincronizzazione in corso", "Syncing")
        case .cancelling: tr("Annullamento in corso", "Cancelling")
        case .synced: tr("Sincronizzato", "Synced")
        case .conflicts(let count, _): SyncCopy.conflictsTitle(count)
        case .partial: tr("Sincronizzazione incompleta", "Sync incomplete")
        case .failed(let failure): failure.title
        case .recoveryBlocked: tr("Intervento richiesto", "Action required")
        }
    }

    var detail: String {
        switch self {
        case .starting: tr("Preparazione dello stato locale…", "Preparing local state…")
        case .loginRequired: tr("Collega il tuo account per iniziare.", "Connect your account to get started.")
        case .needsFolder: tr("Scegli la cartella dei materiali nelle Impostazioni.", "Choose the materials folder in Settings.")
        case .readyUnchecked: tr("Controlla gli aggiornamenti quando vuoi.", "Check for updates whenever you like.")
        case .checking: tr("Verifica delle modifiche remote in corso…", "Checking for remote changes…")
        case .syncing: tr("I file locali non vengono mai sovrascritti senza una scelta.", "Local files are never overwritten without your choice.")
        case .cancelling: tr("I file incompleti non verranno installati.", "Incomplete files won't be installed.")
        case .synced(let summary): summary.detail
        case .conflicts(_, let summary): summary?.conflictDetail ?? tr("Scegli quale versione mantenere nella sezione Conflitti.", "Choose which version to keep in the Conflicts section.")
        case .partial(let summary): summary.partialDetail
        case .failed(let failure): failure.detail
        case .recoveryBlocked: tr("Il recupero locale non è stato completato. Riprova dal menu o scegli un'altra cartella.", "Local recovery wasn't completed. Retry from the menu or choose another folder.")
        }
    }

    var systemImage: String {
        switch self {
        case .synced: "checkmark.circle.fill"
        case .checking, .syncing, .cancelling: "arrow.triangle.2.circlepath"
        case .conflicts, .partial: "exclamationmark.triangle.fill"
        case .loginRequired, .needsFolder, .failed, .recoveryBlocked: "exclamationmark.circle.fill"
        case .starting, .readyUnchecked: "arrow.triangle.2.circlepath"
        }
    }
}

struct SyncCompletionSummary: Codable, Equatable {
    let completedAt: Date
    let added: Int
    let updated: Int
    let unchanged: Int
    let preservedLocal: Int
    let conflicts: Int
    let failures: Int
    let perCourse: [CourseSyncCount]

    init(progress: SyncProgress, completedAt: Date = Date()) {
        self.completedAt = completedAt
        added = progress.added
        updated = progress.updated
        unchanged = progress.unchanged
        preservedLocal = progress.preservedLocal
        conflicts = progress.conflicts
        failures = progress.failures
        perCourse = progress.perCourse
    }

    init(completedAt: Date, added: Int, updated: Int, unchanged: Int, preservedLocal: Int, conflicts: Int, failures: Int, perCourse: [CourseSyncCount] = []) {
        self.completedAt = completedAt
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
        self.preservedLocal = preservedLocal
        self.conflicts = conflicts
        self.failures = failures
        self.perCourse = perCourse
    }

    var affectedCourses: [CourseSyncCount] { perCourse.filter { $0.total > 0 } }
    var hasDetail: Bool { !affectedCourses.isEmpty }
    /// Files moved to follow a move made on Moodle. Derived from `perCourse` rather than stored,
    /// so summaries saved before moves were followed still decode.
    var moved: Int { perCourse.reduce(0) { $0 + $1.moved } }

    var detail: String {
        let activity: String
        switch (added, updated) {
        case (0, 0):
            activity = tr("Nessun nuovo materiale.", "No new materials.")
        case let (a, 0):
            activity = a == 1 ? tr("1 nuovo materiale scaricato.", "1 new material downloaded.") : tr("\(a) nuovi materiali scaricati.", "\(a) new materials downloaded.")
        case let (0, u):
            activity = u == 1 ? tr("1 materiale aggiornato.", "1 material updated.") : tr("\(u) materiali aggiornati.", "\(u) materials updated.")
        case let (a, u):
            let addedPart = a == 1 ? tr("1 nuovo materiale", "1 new material") : tr("\(a) nuovi materiali", "\(a) new materials")
            let updatedPart = u == 1 ? tr("1 aggiornato", "1 updated") : tr("\(u) aggiornati", "\(u) updated")
            activity = "\(addedPart) · \(updatedPart)."
        }
        return activity + movedSuffix + preservedSuffix
    }

    /// "+12 nuovi · 4 aggiornati" — for places with room for a few words only.
    var compactDetail: String {
        var parts: [String] = []
        if added > 0 { parts.append(added == 1 ? tr("1 nuovo", "1 new") : tr("\(added) nuovi", "\(added) new")) }
        if updated > 0 { parts.append(updated == 1 ? tr("1 aggiornato", "1 updated") : tr("\(updated) aggiornati", "\(updated) updated")) }
        // Moves are left out on purpose: this text is the menu bar's, and the sync behavior document
        // (section 7) keeps moves and removals out of the menu bar.
        return parts.isEmpty ? tr("Nessuna novità", "Nothing new") : parts.joined(separator: " · ")
    }

    var conflictDetail: String { detail + tr(" Apri Conflitti per scegliere quale versione mantenere.", " Open Conflicts to choose which version to keep.") }
    var partialDetail: String {
        let failedCourses = perCourse.filter { $0.courseFailure != nil }.count
        return SyncCopy.partialDetail(failedFiles: max(0, failures - failedCourses), failedCourses: failedCourses)
    }
    private var movedSuffix: String {
        guard moved > 0 else { return "" }
        return moved == 1 ? tr(" 1 file spostato nella sua nuova cartella.", " 1 file moved to its new folder.") : tr(" \(moved) file spostati nella loro nuova cartella.", " \(moved) files moved to their new folder.")
    }
    private var preservedSuffix: String {
        guard preservedLocal > 0 else { return "" }
        return preservedLocal == 1 ? tr(" 1 modifica locale conservata.", " 1 local change kept.") : tr(" \(preservedLocal) modifiche locali conservate.", " \(preservedLocal) local changes kept.")
    }
}

/// User-facing counts, with Italian singular and plural forms.
enum SyncCopy {
    /// What happened after a choice about a file Moodle moved or removed.
    static func remoteChangeStatus(_ outcome: RemoteChangeOutcome, action: RemoteChangeAction) -> String {
        remoteChangeFeedback(outcome, action: action).text
    }

    static func remoteChangeFeedback(_ outcome: RemoteChangeOutcome, action: RemoteChangeAction) -> BilingualText {
        switch outcome {
        case .done:
            switch action {
            case .moveMine: BilingualText("File spostato nella nuova cartella.", "File moved to the new folder.")
            case .leaveHere: BilingualText("Il file resta dov’è e continua a essere sincronizzato lì.", "The file stays where it is and keeps syncing there.")
            case .keep, .keepBoth: BilingualText("Il file resta sul Mac ed esce dalla sincronizzazione.", "The file stays on your Mac and is no longer synced.")
            case .trash: BilingualText("File spostato nel Cestino.", "File moved to the Trash.")
            case .replaceNewCopy: BilingualText("La tua versione ha preso il posto della copia nuova, che è nel Cestino.", "Your version took the new copy’s place; the new copy is in the Trash.")
            }
        case .fileChanged:
            BilingualText("Il file è cambiato nel frattempo: non è stato toccato. Controlla e scegli di nuovo.", "The file changed in the meantime and was not touched. Check it and choose again.")
        case .gone:
            BilingualText("Il file non è più dove era: non c’è più niente da scegliere.", "The file is no longer where it was: there is nothing left to choose.")
        case .newCopyUnavailable:
            BilingualText("La copia nuova non è disponibile. Riprova la sincronizzazione prima di spostare la tua nel Cestino.", "The new copy is unavailable. Retry synchronization before moving yours to the Trash.")
        case .newCopyNotReplaceable:
            BilingualText("La copia nuova non è ancora scaricata o è stata modificata: non è stata sostituita.", "The new copy isn’t downloaded yet or was edited, so it wasn’t replaced.")
        }
    }

    static func conflictsTitle(_ count: Int) -> String {
        count == 1 ? tr("1 conflitto da risolvere", "1 conflict to resolve") : tr("\(count) conflitti da risolvere", "\(count) conflicts to resolve")
    }

    static func conflictNotificationBody(_ count: Int) -> String {
        count == 1
            ? tr("BeepBar ha conservato separatamente 1 versione remota.", "BeepBar kept 1 remote version separately.")
            : tr("BeepBar ha conservato separatamente \(count) versioni remote.", "BeepBar kept \(count) remote versions separately.")
    }

    static func newMaterialsNotificationBody(_ count: Int) -> String {
        count == 1
            ? tr("BeepBar ha aggiunto 1 materiale nella cartella scelta.", "BeepBar added 1 material to your chosen folder.")
            : tr("BeepBar ha aggiunto \(count) materiali nella cartella scelta.", "BeepBar added \(count) materials to your chosen folder.")
    }

    static func partialDetail(failedFiles: Int, failedCourses: Int) -> String {
        var parts: [String] = []
        if failedCourses > 0 { parts.append(failedCourses == 1 ? tr("1 corso non accessibile.", "1 course not accessible.") : tr("\(failedCourses) corsi non accessibili.", "\(failedCourses) courses not accessible.")) }
        if failedFiles > 0 || parts.isEmpty { parts.append(failedFiles == 1 ? tr("1 materiale non aggiornato.", "1 material not updated.") : tr("\(failedFiles) materiali non aggiornati.", "\(failedFiles) materials not updated.")) }
        return (parts + [tr("I file esistenti sono al sicuro.", "Your existing files are safe.")]).joined(separator: " ")
    }
}

extension CourseSyncCount {
    var addedLabel: String { added == 1 ? tr("1 nuovo", "1 new") : tr("\(added) nuovi", "\(added) new") }
    var updatedLabel: String { updated == 1 ? tr("1 aggiornato", "1 updated") : tr("\(updated) aggiornati", "\(updated) updated") }
    var movedLabel: String { moved == 1 ? tr("1 spostato", "1 moved") : tr("\(moved) spostati", "\(moved) moved") }
    var keptInPlace: Int { movedItems.count - moved }
    var keptInPlaceLabel: String { keptInPlace == 1 ? tr("1 da scegliere in Conflitti", "1 to decide in Conflicts") : tr("\(keptInPlace) da scegliere in Conflitti", "\(keptInPlace) to decide in Conflicts") }
}

enum AccountState: Equatable {
    case notConnected
    case connected
    case expired

    var title: String {
        switch self {
        case .notConnected: tr("Nessun account collegato", "No account connected")
        case .connected: tr("Account collegato", "Account connected")
        case .expired: tr("Accesso scaduto", "Sign-in expired")
        }
    }
}

/// Everything `StatusItemController.menuNeedsUpdate(_:)` needs to draw the menu, precomputed
/// on the main actor and read back without touching any `@MainActor`-isolated member. See
/// `menuBarSnapshot` for why this exists.
struct MenuBarSnapshot: Sendable {
    let title: String
    let detail: String
    let actionTitle: String
    let openTitle: String
    let quitTitle: String
}

@MainActor final class WeBeepAuthenticationController: NSObject, ObservableObject {
    // Plain, non-isolated, single-writer/single-reader-on-main-thread cache of the menu bar's
    // derived text. StatusItemController's NSMenuDelegate/target-action methods are invoked by
    // AppKit via Objective-C dispatch, which forces the Swift runtime to dynamically re-verify
    // "is this the main executor?" before touching any `@MainActor`-isolated member — a check
    // that crashed with SIGBUS at a fixed address in libswiftCore.dylib on every morning wake,
    // both pre- and post- the MenuBarExtra→NSStatusItem rewrite (issue #30, PR #31). Reading a
    // `nonisolated(unsafe)` plain struct instead of calling an isolated computed property skips
    // that dynamic check entirely rather than relocating it. Safe because every write happens
    // synchronously on the main actor (already the only thread that ever mutates this object),
    // and the only other reader is AppKit's menu-tracking callback, which also only ever runs
    // on the main thread.
    //
    // `refreshMenuBarSnapshot()` is called from `didSet` on every stored property that feeds
    // `menuBarAction`/`menuBarTitle`/`menuBarActionTitle`/`menuBarDetail`/`menuBarSymbol` (currently: syncState,
    // accountState, hasStoredCredential, recoveryBlocked, conflicts, rootURL, activeOperationID,
    // dataSaverPause), and
    // `setLanguage(_:)` calls it since every label depends on `AppLanguage.current`. If you make
    // those computed properties depend on anything else, add a matching
    // `didSet { refreshMenuBarSnapshot() }` to that property too, or the menu bar will silently
    // go stale instead of crashing loudly.
    private(set) nonisolated(unsafe) var menuBarSnapshot = MenuBarSnapshot(title: "", detail: "", actionTitle: "", openTitle: "", quitTitle: "")
    /// Pushes the status item's icon from the main actor whenever `menuBarSymbol` changes, so
    /// StatusItemController never has to read it from an AppKit callback (same reason as
    /// `menuBarSnapshot`). Set once by StatusItemController's `@MainActor` init.
    var onMenuBarSymbolChange: (@MainActor (String) -> Void)?
    private var lastMenuBarSymbol: String?

    // Invariant for the window: every stored property a view reads, directly or through a
    // computed property (`isSyncActive`, `canSynchronize`, `lastSyncSummary`…), must be
    // `@Published` or derived synchronously from one (like `defaultCourseFolders` from `courses`).
    // A plain `var` redraws nothing on its own and only looks right while some other published
    // change happens to follow it; see `activeOperationID` for the stuck "Annulla" this caused.
    // A property feeding both the menu bar and the window needs `@Published` and the
    // `refreshMenuBarSnapshot()` `didSet` described above.
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isVerifying = false
    @Published private(set) var isLoadingCourses = false
    @Published private(set) var courseLoadError: BilingualText?
    @Published private(set) var courses: [RemoteCourseSummary] = [] {
        didSet { defaultCourseFolders = Self.defaultFolders(for: courses, saved: courseFolders) }
    }
    @Published private(set) var hasStoredCredential: Bool {
        didSet {
            if !hasStoredCredential {
                conflictChoiceFeedback = nil
                authenticationFeedback = nil
            }
            refreshMenuBarSnapshot()
        }
    }
    /// Refused or failed choices stay visible on the Conflicts page until the next choice.
    @Published private(set) var conflictChoiceFeedback: BilingualText?
    /// Login failures belong beside the sign-in button, including during onboarding.
    @Published private(set) var authenticationFeedback: BilingualText?
    @Published private(set) var status = tr("Avvio BeepBar…", "Starting BeepBar…")
    @Published private(set) var syncState: AppSyncState = .starting {
        didSet { notificationGeneration += 1; refreshMenuBarSnapshot() }
    }
    @Published private(set) var accountState: AccountState = .notConnected {
        didSet { refreshMenuBarSnapshot() }
    }
    @Published private(set) var selectedSite: MoodleSite
    @Published private(set) var rootURL: URL? {
        didSet { refreshMenuBarSnapshot() }
    }
    @Published private(set) var needsOnboarding: Bool
    /// Mirrors `AppLanguage.current`; published so the window rebuilds in the new language.
    @Published private(set) var language: AppLanguage
    @Published private(set) var enabledCourseIDs: Set<Int64>
    @Published private(set) var automaticSyncEnabled: Bool
    /// The "Notifiche" switch (#64). On unless the user turned it off; see `NotificationPolicy`.
    @Published private(set) var notificationsEnabled: Bool
    /// macOS's permission for BeepBar's notifications, `nil` until first read. Shown under the
    /// switch when macOS blocks them, since only System Settings can change that.
    @Published private(set) var notificationAuthorization: NotificationAuthorization?
    @Published private(set) var automaticSyncInterval: Int
    /// The "Risparmio dati" switch: off unless the user turns it on. When on, automatic sync
    /// pauses on a phone hotspot or a Low Data Mode network; «Sincronizza ora» always downloads.
    @Published private(set) var dataSaverEnabled: Bool
    /// Why the last automatic run was held back by "Risparmio dati", or `nil`. Never persisted:
    /// it describes the network at that moment, and the next run that goes ahead clears it. Read
    /// through `visibleDataSaverPause`, which decides whether it is what the user sees.
    /// Invariant: it is only shown while the deferred retry that will replace it is still pending.
    /// So it is cleared when a sync starts, when the switch is turned off, when the folder changes,
    /// when an automatic run is skipped because nothing can be synced, and whenever
    /// `configureBackgroundScheduler()` rebuilds the scheduler (automatic sync turned off,
    /// Frequenza or the selected courses changed, signed out, sign-in expired or renewed…), since
    /// each of these drops the retry.
    @Published private(set) var dataSaverPause: DataSaverPause? {
        didSet { refreshMenuBarSnapshot() }
    }
    @Published private(set) var recoveryBlocked = false {
        didSet { refreshMenuBarSnapshot() }
    }
    @Published private(set) var courseFolders: [Int64: String] = [:]
    @Published private(set) var courseRenameErrors: [Int64: String] = [:]
    @Published private(set) var renamingCourseID: Int64?
    let progressStore = SyncProgressStore()
    @Published private(set) var conflicts: [ConflictRecord] = [] {
        didSet { refreshMenuBarSnapshot() }
    }
    @Published private(set) var resolvingConflictID: UUID?
    /// Files Moodle moved or removed that wait for the user's choice in Conflicts. Not shown in the
    /// menu bar or in notifications (sync behavior document, section 7), so no menu bar refresh.
    @Published private(set) var remoteChanges: [RemoteChange] = []
    @Published private(set) var resolvingRemoteChangeID: UUID?
    /// A module move left half done that recovery cannot finish; the user can abandon it.
    @Published private(set) var hasPendingModuleMoves = false
    // Default folder name per course id, derived from `courses` and rebuilt only when that list
    // changes: `folder(for:)` runs for every row on every render of the course list, so it has
    // to be a lookup, not a rescan of every course name.
    private var defaultCourseFolders: [Int64: String] = [:]
    private var loginWindow: LoginWindowController?
    private var siteInfo: WeBeepSiteInfo?
    private var database: SyncDatabase?
    /// Opens or reveals a file clicked in Attività; a fake in tests, so no test opens real apps.
    private let fileOpener: ActivityFileOpening
    /// Attività items whose click found a problem, shown on their row. Cleared whenever the
    /// displayed summary or the sync folder changes: remote ids repeat across syncs, and a file
    /// downloaded again must not inherit the previous run's warning.
    @Published private(set) var activityItemProblems: [String: ActivityItemProblem] = [:]
    private let operationGate = RootOperationGate()
    private var apiClient: WeBeepAPIClient
    // One downloader for the whole app lifetime: a per-run one would leave its URLSession and
    // delegate alive forever, since nothing invalidates them when a run ends.
    private var downloader: RemoteDownloader
    private let credentialVault: CredentialVault
    private let notificationCoordinator: SyncNotificationCoordinator
    private var backgroundScheduler: NSBackgroundActivityScheduler?
    private var bootstrapTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var scopeWriteTask: Task<Void, Never>?
    // Published because views read it through `isSyncActive` / `canSynchronize` (Annulla vs
    // Sincronizza ora). An operation often ends after a suspension (the new-materials notification,
    // a failure notice) with no other published change following it: when this was a plain `var`,
    // clearing it redrew nothing and the window stayed on "Annulla" after a sync that downloaded
    // new files, with a button that no longer did anything.
    @Published private var activeOperationID: UUID? {
        didSet {
            if activeOperationID != nil { notificationGeneration += 1 }
            refreshMenuBarSnapshot()
        }
    }
    /// Survives operation finalization, so awaiting notification permission cannot resurrect an
    /// earlier result once a new run or account state has replaced it.
    private var notificationGeneration = 0
    private var automaticOutcome: AutomaticSyncOutcome = .finished
    private let automaticSyncEnvironment: AutomaticSyncEnvironment
    private var rootID: UUID? {
        didSet { if rootID != oldValue { conflictChoiceFeedback = nil } }
    }
    private var scheduledConfiguration: BackgroundScheduleConfiguration?
    /// Bumped on every real rebuild of the scheduler. Tells an automatic run whether the schedule
    /// that started it still exists: comparing configurations can't, since turning automatic sync
    /// off and on again rebuilds twice and ends on an equal configuration.
    private var schedulerGeneration = 0
#if DEBUG
    private var beforeReconciliationStateForTesting: (@MainActor () async -> Void)?
    private var beforePendingChoicesForTesting: (@MainActor () async -> Void)?
    private var courseLoadTaskForTesting: Task<Void, Never>?
    private var deleteCredentialForTesting: (() throws -> Void)?
    private var testDefaults: UserDefaults?
    /// Off in every test controller, so a test can turn automatic sync on, as users have it,
    /// without registering a real background activity on the Mac running the tests.
    private var registersBackgroundActivity = true
    private var beforeScopeRestoreForTesting: (@MainActor () -> Void)?
#endif

    // Pure and independently testable: whether onboarding should show depends only on these two
    // inputs. An existing root always wins, regardless of the persisted flag — this is what makes
    // an update to an already-set-up install never retrigger onboarding, even before this feature
    // existed to ever set the flag in the first place.
    nonisolated static func resolveNeedsOnboarding(existingRootURL: URL?, onboardingAlreadyCompleted: Bool) -> Bool {
        existingRootURL == nil && !onboardingAlreadyCompleted
    }

    /// A stored choice always wins. Without one, installs set up before the setting existed stay
    /// Italian (the only language they ever had) instead of flipping to the system language on
    /// update; a fresh install starts from the system language, changeable in onboarding.
    nonisolated static func resolveLanguage(stored: String?, needsOnboarding: Bool, preferredLanguages: [String]) -> AppLanguage {
        if let stored, let language = AppLanguage(rawValue: stored) { return language }
        return needsOnboarding ? AppLanguage.preferred(from: preferredLanguages) : .italian
    }

    override init() {
        credentialVault = CredentialVault(read: FileTokenStore.load, write: FileTokenStore.save)
        fileOpener = WorkspaceFileOpener()
        let selectedSite = MoodleSite.site(id: Self.defaults.string(forKey: Self.selectedSiteKey))
        self.selectedSite = selectedSite
        hasStoredCredential = false
        // A preview build shares the installed app's bundle identifier, and macOS keeps the
        // notification permission per bundle: a preview must never prompt or post for real.
        notificationCoordinator = SyncNotificationCoordinator(defaults: Self.defaults, center: Self.isUIPreview || Self.isUIPreviewOnboarding ? InertNotificationCenter(authorization: .allowed) : SystemNotificationCenter())
        notificationsEnabled = Self.storedNotificationsEnabled(in: Self.defaults)
        let resolvedRootURL = Self.storedRootURL()
        rootURL = resolvedRootURL
        let resolvedNeedsOnboarding = Self.resolveNeedsOnboarding(existingRootURL: resolvedRootURL, onboardingAlreadyCompleted: Self.defaults.bool(forKey: Self.onboardingCompletedKey))
        needsOnboarding = resolvedNeedsOnboarding
        if resolvedRootURL != nil {
            Self.defaults.set(true, forKey: Self.onboardingCompletedKey)
        }
        let resolvedLanguage = Self.resolveLanguage(stored: Self.defaults.string(forKey: Self.languageKey), needsOnboarding: resolvedNeedsOnboarding, preferredLanguages: Locale.preferredLanguages)
        language = resolvedLanguage
        AppLanguage.current = resolvedLanguage
        Self.defaults.set(resolvedLanguage.rawValue, forKey: Self.languageKey)
        status = tr("Avvio BeepBar…", "Starting BeepBar…")
        enabledCourseIDs = Set(Self.defaults.stringArray(forKey: Self.enabledCoursesKey)?.compactMap(Int64.init) ?? [])
        automaticSyncEnabled = Self.defaults.bool(forKey: Self.autoSyncKey)
        let storedAutomaticSyncInterval = Self.validatedAutomaticInterval(Self.defaults.object(forKey: Self.autoSyncIntervalKey) as? Int)
        automaticSyncInterval = storedAutomaticSyncInterval
        Self.defaults.set(storedAutomaticSyncInterval, forKey: Self.autoSyncIntervalKey)
        dataSaverEnabled = Self.storedDataSaverEnabled(in: Self.defaults)
        automaticSyncEnvironment = .system
        rootID = Self.storedRootID()
        apiClient = WeBeepAPIClient(policy: selectedSite.serverPolicy)
        downloader = RemoteDownloader(policy: apiClient.policy)
        database = nil
        super.init()
        refreshMenuBarSnapshot()
        BeepbarLog.lifecycle.notice("Controller initialized automaticSync=\(self.automaticSyncEnabled, privacy: .public) intervalSeconds=\(self.automaticSyncInterval, privacy: .public) dataSaver=\(self.dataSaverEnabled, privacy: .public)")
#if DEBUG
        if Self.isUIPreviewOnboarding {
            // Fall through to the real bootstrap flow below (with the isolated preview
            // database/defaults) instead of returning early, so "Scegli cartella…" in the
            // onboarding UI exercises the actual chooseRoot() codepath, not a mock.
            needsOnboarding = true
            rootURL = nil
            hasStoredCredential = false
            accountState = .notConnected
        }
        if Self.isUIPreview {
            needsOnboarding = false
            let mockCourses = (1...100).map { index in
                RemoteCourseSummary(id: Int64(index), shortName: String(format: "%06d", 58000 + index), displayName: "CORSO DI PROVA \(index) — MATERIALI E ATTIVITÀ", isVisible: true, startDate: nil, endDate: nil)
            }
            enabledCourseIDs = Set(mockCourses.prefix(64).map(\.id))
            courses = Self.orderedForDisplay(mockCourses, enabledCourseIDs: enabledCourseIDs)
            courseFolders = Dictionary(uniqueKeysWithValues: mockCourses.map { ($0.id, "Corso di prova \($0.id)") })
            hasStoredCredential = true
            accountState = .connected
            rootURL = FileManager.default.temporaryDirectory
            func mockItems(added: Int, updated: Int) -> [SyncedItem] {
                (0..<added).map { SyncedItem(id: "a\($0)", name: "Slide \($0 + 1).pdf", kind: .added) }
                    + (0..<updated).map { SyncedItem(id: "u\($0)", name: "Esercizi \($0 + 1).pdf", kind: .updated) }
            }
            let mockPerCourse = [
                CourseSyncCount(courseID: 1, courseFolder: "Corso di prova 1", added: 5, updated: 1, items: mockItems(added: 5, updated: 1)),
                CourseSyncCount(courseID: 7, courseFolder: "Corso di prova 7", added: 4, updated: 0, items: mockItems(added: 4, updated: 0)),
                CourseSyncCount(courseID: 23, courseFolder: "Corso di prova 23", added: 2, updated: 2, items: mockItems(added: 2, updated: 2)),
                CourseSyncCount(courseID: 41, courseFolder: "Corso di prova 41", added: 1, updated: 1, items: mockItems(added: 1, updated: 1)),
            ]
            setSyncState(.synced(SyncCompletionSummary(completedAt: Date(), added: 12, updated: 4, unchanged: 83, preservedLocal: 1, conflicts: 0, failures: 0, perCourse: mockPerCourse)))
            return
        }
#endif
        accountState = hasStoredCredential ? .connected : .notConnected
        setSyncState(.starting)
        let bootstrap = BootstrapService()
        let rootURL = self.rootURL
        let rootID = self.rootID
        let operationGate = self.operationGate
        let credentialVault = self.credentialVault
        bootstrapTask = Task { [weak self] in
            let trace = PerformanceTrace.shared.begin("bootstrap.total", category: .bootstrap)
            defer { PerformanceTrace.shared.end("bootstrap.total", category: .bootstrap, state: trace) }
            do {
                let result = try await bootstrap.prepare(databaseDirectory: Self.databaseDirectory(), rootURL: rootURL, rootID: rootID, gate: operationGate, credentialVault: credentialVault)
                guard let self else { return }
                self.database = result.database
                await self.applyBootstrap(result)
                BeepbarLog.lifecycle.notice("Bootstrap completed recoveryBlocked=\(result.recoveryBlocked, privacy: .public)")
            } catch {
                BeepbarLog.lifecycle.error("Bootstrap failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                self?.setSyncState(.failed(.local(BilingualText("Impossibile preparare lo stato locale. Riapri BeepBar.", "Couldn't prepare the local state. Reopen BeepBar."))))
            }
        }
    }

#if DEBUG
    /// `defaults` lets a test reopen the same settings in a second controller, as a relaunch would;
    /// without it every controller gets its own throwaway suite. `automaticSyncEnvironment`
    /// defaults to mains power and an ordinary network, so no test depends on the Mac running it.
    init(testRootURL: URL, database: SyncDatabase? = nil, rootID: UUID? = nil, notificationCenter: NotificationCenterClient = InertNotificationCenter(), fileOpener: ActivityFileOpening = InertFileOpener(), apiClient: WeBeepAPIClient? = nil, downloader: RemoteDownloader? = nil, credentialVault: CredentialVault? = nil, deleteCredential: (() throws -> Void)? = nil, defaults: UserDefaults? = nil, automaticSyncEnvironment: AutomaticSyncEnvironment = .fixed()) {
        deleteCredentialForTesting = deleteCredential
        self.credentialVault = credentialVault ?? CredentialVault(read: FileTokenStore.load, write: FileTokenStore.save)
        self.fileOpener = fileOpener
        let site = MoodleSite.site(id: nil)
        selectedSite = site
        hasStoredCredential = true
        let isolatedDefaults = defaults ?? Self.throwawayDefaults()
        testDefaults = isolatedDefaults
        notificationCoordinator = SyncNotificationCoordinator(defaults: isolatedDefaults, center: notificationCenter)
        notificationsEnabled = Self.storedNotificationsEnabled(in: isolatedDefaults)
        rootURL = testRootURL
        needsOnboarding = false
        language = .italian
        enabledCourseIDs = [1]
        automaticSyncEnabled = false
        automaticSyncInterval = 28_800
        registersBackgroundActivity = false
        dataSaverEnabled = Self.storedDataSaverEnabled(in: isolatedDefaults)
        self.automaticSyncEnvironment = automaticSyncEnvironment
        self.apiClient = apiClient ?? WeBeepAPIClient(policy: site.serverPolicy)
        self.downloader = downloader ?? RemoteDownloader(policy: self.apiClient.policy)
        self.database = database
        self.rootID = rootID
        super.init()
        accountState = .connected
        refreshMenuBarSnapshot()
    }

    /// Defaults for a test controller, stored in a temporary folder instead of ~/Library/Preferences:
    /// a named suite leaves a file there that the preferences daemon rewrites even after it is
    /// deleted, so every test run used to add files to the user's Preferences folder.
    nonisolated static func throwawayDefaults() -> UserDefaults {
        UserDefaults(suiteName: throwawayDefaultsSuite())!
    }

    /// The suite name behind `throwawayDefaults()`: an absolute path, which keeps the property list
    /// in that folder. Tests that need a second handle on the same suite open it by this name.
    nonisolated static func throwawayDefaultsSuite() -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "BeepbarTestDefaults-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "defaults").path
    }

    var apiHostForTesting: String { apiClient.policy.host }

    func completeLoginForTesting(_ callback: URL) async {
        await completeLogin(.success(callback))?.value
        await courseLoadTaskForTesting?.value
    }

    func setOperationForTesting(_ operationID: UUID?, task: Task<Void, Never>? = nil) {
        activeOperationID = operationID
        syncTask = task
    }

    func setSyncStateForTesting(_ state: AppSyncState) {
        setSyncState(state)
    }

    func setLoadingCoursesForTesting(_ loading: Bool) {
        isLoadingCourses = loading
    }

    func setScopeWriteTaskForTesting(_ task: Task<Void, Never>) {
        scopeWriteTask = task
    }

    func setBeforeScopeRestoreForTesting(_ action: @escaping @MainActor () -> Void) {
        beforeScopeRestoreForTesting = action
    }

    func restoreScopesForTesting(_ courses: [RemoteCourseSummary]) async throws {
        try await restoreScopes(for: courses)
    }

    /// Sends what a finished manual sync would, through the controller's own coordinator: proves
    /// the switch writes to the same defaults the coordinator reads.
    func notifyManualRunForTesting(added: Int) async {
        await notificationCoordinator.notifyManualRun(added: added)
    }

    func setBeforeNotificationForTesting(_ action: @escaping @MainActor () async -> Void) {
        notificationCoordinator.beforeNotificationForTesting = action
    }

    func completeSyncForTesting(_ operationID: UUID, summary: SyncProgress, automatic: Bool = false) async {
        await completeSync(operationID, summary: summary, automatic: automatic)
    }

    func setBeforeReconciliationStateForTesting(_ action: @escaping @MainActor () async -> Void) {
        beforeReconciliationStateForTesting = action
    }

    @discardableResult func runAutomaticSyncForTesting() async -> AutomaticSyncOutcome { await runAutomaticSync() }

    /// Waits for the sync `synchronizeNow()` started, which it does not return.
    func waitForSyncForTesting() async { await syncTask?.value }

    /// Waits for the course refresh `loadCourses()` started, which it does not return.
    func waitForCourseLoadForTesting() async { await courseLoadTaskForTesting?.value }

    func setRootIDForTesting(_ id: UUID) { rootID = id }

    /// Runs inside `openActivityItem` after it captured the folder and before it looks the file
    /// up: lets a test change the folder mid-lookup.
    var beforeActivityLookupForTesting: (@MainActor () async -> Void)?

    func setDisconnectedForTesting() {
        hasStoredCredential = false
        accountState = .notConnected
        setSyncState(.loginRequired)
    }

    func setBeforePendingChoicesForTesting(_ action: @escaping @MainActor () async -> Void) { beforePendingChoicesForTesting = action }

    func reloadPendingChoicesForTesting() async { await reloadPendingChoices() }
    func restorePersistedSyncStateForTesting() async { await restorePersistedSyncState() }
    func lastSuccessfulTimestampForTesting() -> Double {
        guard let rootID else { return 0 }
        return operationDefaults.double(forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
    }

    func failSyncForTesting(_ operationID: UUID) async {
        await failedSync(operationID, error: nil, automatic: true)
    }
#endif

    /// Applies the outcome of the launch bootstrap or of a recovery retry. A blocked recovery keeps
    /// every root operation gated; otherwise the account and the persisted sync state are restored.
    private func applyBootstrap(_ result: BootstrapService.Result) async {
        await refreshPendingModuleMoves()
        if result.recoveryBlocked {
            recoveryBlocked = true
            setSyncState(.recoveryBlocked)
            return
        }
        recoveryBlocked = false
        switch result.credential {
        case .present:
            hasStoredCredential = true
            if Self.defaults.bool(forKey: Self.credentialExpiredKey) {
                accountState = .expired
                setSyncState(.failed(.authenticationExpired))
            } else {
                accountState = .connected
                await restorePersistedSyncState()
            }
            configureBackgroundScheduler()
        case .absent:
            hasStoredCredential = false
            accountState = .notConnected
            await restorePersistedSyncState()
            configureBackgroundScheduler()
        case .unavailable(let error):
            await handleCredentialStorageError(error)
        }
    }

    /// Re-runs the launch recovery for the current root without re-picking the folder, so a pending
    /// operation that could not be recovered (for example after the user fixed the file on disk)
    /// no longer keeps every sync blocked.
    func retryRecovery() {
        guard recoveryBlocked, case .recoveryBlocked = syncState, !isSyncActive, let rootURL, let rootID, let database else { return }
        setSyncState(.starting)
        let bootstrap = BootstrapService()
        let operationGate = self.operationGate
        Task { [weak self] in
            let trace = PerformanceTrace.shared.begin("bootstrap.retryRecovery", category: .bootstrap)
            defer { PerformanceTrace.shared.end("bootstrap.retryRecovery", category: .bootstrap, state: trace) }
            do {
                let result = try await bootstrap.retryRecovery(rootURL: rootURL, rootID: rootID, database: database, gate: operationGate)
                await self?.applyBootstrap(result)
            } catch {
                self?.setSyncState(.recoveryBlocked)
            }
        }
    }

    private func refreshPendingModuleMoves() async {
        guard let database, let rootID else { hasPendingModuleMoves = false; return }
        hasPendingModuleMoves = (try? await database.hasPendingModuleMoves(rootID: rootID)) ?? false
    }

    /// Gives up on every module move recovery cannot finish (issue #49). Files are never touched:
    /// each one keeps the path it is really at, and the module keeps its previous folder rule.
    /// Recovery then runs again so the root unblocks if nothing else is pending.
    func abandonPendingModuleMoves() {
        guard recoveryBlocked, hasPendingModuleMoves, !isSyncActive, let rootURL, let rootID, let database else { return }
        setSyncState(.starting)
        let operationGate = self.operationGate
        Task { [weak self] in
            do {
                try await operationGate.withLease(.recovering) {
                    let fileStore = try FileStore(root: rootURL)
                    for move in try await database.pendingModuleMoves(rootID: rootID) {
                        try await ModuleMoveRecovery.abandon(move, database: database, fileStore: fileStore)
                    }
                }
                let result = try await BootstrapService().retryRecovery(rootURL: rootURL, rootID: rootID, database: database, gate: operationGate)
                await self?.applyBootstrap(result)
            } catch {
                await self?.refreshPendingModuleMoves()
                self?.setSyncState(.recoveryBlocked)
            }
        }
    }

    /// Forgets the stored token so another account, or another university, can be connected.
    /// The sync folder, its files and the course selection stay as they are.
    func signOut(removeFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        guard hasStoredCredential, !isSyncActive, !isAuthenticating, !isVerifying, !isLoadingCourses else { return }
        do {
#if DEBUG
            if let deleteCredentialForTesting {
                try deleteCredentialForTesting()
            } else {
                try FileTokenStore.delete(removeFile: removeFile)
            }
#else
            try FileTokenStore.delete(removeFile: removeFile)
#endif
        } catch {
            setSyncState(.failed(.local(BilingualText("Impossibile eliminare il token salvato. Riprova a disconnetterti.", "Couldn't remove the stored token. Try disconnecting again."))))
            return
        }
        Task { await credentialVault.invalidate() }
        Self.defaults.removeObject(forKey: Self.credentialExpiredKey)
        notificationCoordinator.clearFailure()
        siteInfo = nil
        courses = []
        courseLoadError = nil
        hasStoredCredential = false
        accountState = .notConnected
        setSyncState(recoveryBlocked ? .recoveryBlocked : .loginRequired)
        configureBackgroundScheduler()
    }

    /// Italian text for an error raised while organizing module folders. Errors that already carry
    /// a description keep it; the rest would otherwise surface as a generic English system string.
    nonisolated static func moduleFolderErrorMessage(_ error: Error) -> String {
        switch error {
        case let error as ModulePathMigrationError: return error.errorDescription ?? tr("Operazione non riuscita. Riprova.", "Operation failed. Try again.")
        case is RootOperationGateError: return tr("Un'altra operazione è in corso sulla cartella. Riprova tra poco.", "Another operation is running on the folder. Try again shortly.")
        case let error as WeBeepAPIError:
            switch SyncServiceFailure(error) {
            case .authenticationExpired: return AppFailure.authenticationExpired.detail
            case .connectivity: return tr("Connessione assente. Riprova quando sei online.", "No connection. Try again when you're online.")
            case .serviceUnavailable: return AppFailure.serviceUnavailable.detail
            case .incompatibleResponse: return AppFailure.incompatibleResponse.detail
            }
        case is CredentialStorageError: return AppFailure.credentialUnavailable.detail
        case is FileStoreError: return tr("Impossibile accedere ai file del corso. Controlla la cartella e riprova.", "Couldn't access the course files. Check the folder and try again.")
        default: return tr("Operazione non riuscita. Riprova.", "Operation failed. Try again.")
        }
    }

    /// Lets the icon itself say whether a sync is running or something needs attention, since the
    /// menu closes as soon as "Sincronizza ora" is clicked.
    var menuBarSymbol: String { Self.menuBarSymbol(for: syncState, pause: visibleDataSaverPause) }

    /// `pause` is the pause the user sees (`visibleDataSaverPause`), not the stored one: when it
    /// shows, the icon says so instead of the warning a "Connessione assente" underneath would give,
    /// matching the calm pause in the menu and the window.
    nonisolated static func menuBarSymbol(for syncState: AppSyncState, pause: DataSaverPause? = nil) -> String {
        if pause != nil { return "pause.circle" }
        return switch syncState {
        case .checking, .syncing, .cancelling: "arrow.down.circle"
        case .conflicts, .partial, .failed, .recoveryBlocked, .loginRequired, .needsFolder: "exclamationmark.triangle"
        case .starting, .readyUnchecked, .synced: "arrow.triangle.2.circlepath"
        }
    }

    var menuBarTitle: String {
        visibleDataSaverPause?.title ?? syncState.title
    }

    /// The "Risparmio dati" pause when it is what the window and the menu should show.
    var visibleDataSaverPause: DataSaverPause? {
        Self.visibleDataSaverPause(dataSaverPause, syncState: syncState, syncActive: isSyncActive)
    }

    /// The pause only stands in for states that describe an earlier run and that the next
    /// automatic run would replace anyway: the last result, "Pronto", and an earlier
    /// "Connessione assente" (the Mac has a network again, a limited one, so the pause is the
    /// current news). Anything that asks the user to act (conflicts, sign in,
    /// choose a folder, blocked recovery), an incomplete sync, every other failure and a running
    /// sync stay in front: hiding them behind "In pausa" would hide the real problem.
    nonisolated static func visibleDataSaverPause(_ pause: DataSaverPause?, syncState: AppSyncState, syncActive: Bool) -> DataSaverPause? {
        guard let pause, !syncActive else { return nil }
        switch syncState {
        case .readyUnchecked, .synced, .failed(.connectivity): return pause
        default: return nil
        }
    }

    var menuBarActionTitle: String {
        switch menuBarAction {
        case .cancelSync: tr("Annulla sincronizzazione", "Cancel sync")
        case .openConflicts: tr("Apri conflitti", "Open conflicts")
        case .signIn: accountState == .expired ? tr("Accedi di nuovo", "Sign in again") : tr("Accedi", "Sign in")
        case .retryCredentialStorage: tr("Riprova", "Retry")
        case .retryRecovery: tr("Riprova recupero", "Retry recovery")
        case .openSettings: tr("Apri Impostazioni", "Open Settings")
        case .synchronize: tr("Sincronizza ora", "Sync now")
        }
    }

    private func refreshMenuBarSnapshot() {
        menuBarSnapshot = MenuBarSnapshot(
            title: menuBarTitle,
            detail: menuBarDetail,
            actionTitle: menuBarActionTitle,
            openTitle: tr("Apri BeepBar…", "Open BeepBar…"),
            quitTitle: tr("Esci da BeepBar", "Quit BeepBar")
        )
        let symbol = menuBarSymbol
        if symbol != lastMenuBarSymbol {
            lastMenuBarSymbol = symbol
            onMenuBarSymbolChange?(symbol)
        }
    }

    /// One short line for the status menu; the full sentences live in the window.
    private var menuBarDetail: String {
        if let pause = visibleDataSaverPause { return pause.compactDetail }
        return switch syncState {
        case .starting: tr("Preparazione…", "Preparing…")
        case .loginRequired: tr("Collega il tuo account", "Connect your account")
        case .needsFolder: tr("Scegli la cartella dei materiali", "Choose the materials folder")
        case .readyUnchecked: tr("Nessun controllo eseguito", "Not checked yet")
        case .checking: tr("Verifica delle novità…", "Checking for new materials…")
        case .syncing: Self.progressDetail(progressStore.progress) ?? tr("In corso…", "In progress…")
        case .cancelling: tr("Attendi…", "Please wait…")
        case .synced(let summary): summary.compactDetail
        case .conflicts: tr("Scegli quale versione tenere", "Choose which version to keep")
        case .partial: tr("Alcuni materiali non aggiornati", "Some materials not updated")
        case .failed(let failure): failure.compactDetail
        case .recoveryBlocked: tr("Recupero locale non completato", "Local recovery not completed")
        }
    }

    nonisolated static func progressDetail(_ progress: SyncProgress) -> String? {
        guard progress.total > 0 else { return nil }
        return tr("\(progress.completed) di \(progress.total) file", "\(progress.completed) of \(englishCount(progress.total, "file", "files"))")
    }

    private var menuBarAction: MenuBarAction {
        let account: MenuBarAccountCondition
        if case .failed(.credentialUnavailable) = syncState {
            account = .credentialUnavailable
        } else if accountState != .connected || !hasStoredCredential {
            account = .loginRequired
        } else {
            account = .connected
        }
        return MenuBarActionPolicy.action(
            syncActive: isSyncActive,
            recoveryBlocked: recoveryBlocked,
            hasConflicts: !conflicts.isEmpty,
            account: account,
            hasRoot: rootURL != nil
        )
    }

    /// Whether a sync is running; picks "Annulla" over "Sincronizza ora" in the window.
    var isSyncActive: Bool {
        activeOperationID != nil
    }

    private func setSyncState(_ newState: AppSyncState) {
        let previousSummary = lastSyncSummary
        syncState = newState
        if lastSyncSummary != previousSummary { activityItemProblems = [:] }
        status = newState.detail
        if case .synced(let summary) = newState, let rootID {
            operationDefaults.set(summary.completedAt.timeIntervalSince1970, forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
            if let data = try? JSONEncoder().encode(summary) {
                operationDefaults.set(data, forKey: Self.lastSuccessfulSummaryKey + rootID.uuidString)
            }
        }
    }

    private func restorePersistedSyncState() async {
        guard !Self.isUIPreview else { return }
        guard !recoveryBlocked else { setSyncState(.recoveryBlocked); return }
        guard accountState != .expired else { setSyncState(.failed(.authenticationExpired)); return }
        guard hasStoredCredential else { setSyncState(.loginRequired); return }
        guard rootURL != nil, let rootID else { setSyncState(.needsFolder); return }
        let open: [ConflictRecord]
        do {
            let pending = try await loadPendingChoices()
            guard self.rootID == rootID, hasStoredCredential, accountState != .expired, !isSyncActive else { return }
            open = pending.conflicts
            conflicts = open
            remoteChanges = pending.changes
        } catch {
            guard self.rootID == rootID, hasStoredCredential, accountState != .expired, !isSyncActive else { return }
            reportPendingChoicesReadFailure()
            return
        }
        if !open.isEmpty { setSyncState(.conflicts(open.count, nil)); return }
        if let data = operationDefaults.data(forKey: Self.lastSuccessfulSummaryKey + rootID.uuidString),
           let summary = try? JSONDecoder().decode(SyncCompletionSummary.self, from: data) {
            setSyncState(.synced(summary))
            return
        }
        let timestamp = operationDefaults.double(forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
        let legacy = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: timestamp), added: 0, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)
        setSyncState(timestamp > 0 ? .synced(legacy) : .readyUnchecked)
    }

    var lastSyncSummary: SyncCompletionSummary? {
        switch syncState {
        case .synced(let summary), .partial(let summary): return summary
        case .conflicts(_, let summary): return summary
        default: return nil
        }
    }

    var canSynchronize: Bool {
        accountState == .connected && hasStoredCredential && rootURL != nil && !enabledCourseIDs.isEmpty && !isSyncActive && !isLoadingCourses && !recoveryBlocked
    }

    func performMenuBarAction() {
        switch menuBarAction {
        case .cancelSync: cancelSynchronization()
        case .openConflicts: ConfigurationWindowController.shared.show(self, page: .conflicts)
        case .signIn: startLogin()
        case .retryCredentialStorage: validateConnection()
        case .retryRecovery: retryRecovery()
        case .openSettings: ConfigurationWindowController.shared.show(self)
        case .synchronize: synchronizeNow()
        }
    }

    func refreshOnWindowOpen() {
        Task { [weak self] in
            guard let self else { return }
            await self.bootstrapTask?.value
            self.loadCourses()
        }
        refreshConflicts()
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = tr("Scegli la cartella dei materiali BeepBar", "Choose the BeepBar materials folder")
        panel.message = tr("BeepBar creerà una sottocartella per ogni corso abilitato.", "BeepBar will create a subfolder for each enabled course.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // An accessory (menu-bar-only) app can show the panel without it owning keyboard focus, so
        // typing the name of a "New Folder" (or anywhere else in the panel) is silently swallowed.
        // Activating alone is not enough on recent macOS: while the panel is open Beepbar runs as a
        // regular app, then goes back to living in the menu bar.
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(previousPolicy)
            NSApp.activate(ignoringOtherApps: true)
        }
        guard response == .OK, let url = panel.url else { return }
        // Registered by its resolved path, so the same folder reached through a symlink (the folder
        // itself or a parent) maps to one root instead of losing its baselines to a second record.
        let pickedURL = url.standardizedFileURL
        let selectedURL = pickedURL.resolvingSymlinksInPath()
        guard !isSyncActive else { return }
        Task { [weak self] in
            do {
                guard let self else { return }
                await self.bootstrapTask?.value
                guard let database = self.database else { throw SyncDatabaseError.open }
                _ = try FileStore(root: selectedURL)
                // A root registered before paths were resolved is still found by the path it was
                // picked with, and moves to the resolved one.
                let existingID = try await database.rootID(canonicalPath: selectedURL.path)
                let legacyID = pickedURL.path == selectedURL.path ? nil : try await database.rootID(canonicalPath: pickedURL.path)
                let selectedID = existingID ?? legacyID ?? UUID()
                try await database.registerRoot(id: selectedID, canonicalPath: selectedURL.path)
                let report = try await operationGate.withLease(.recovering) {
                    try await RecoveryCoordinator(rootID: selectedID, database: database, fileStore: try FileStore(root: selectedURL)).recover()
                }
                guard report.unresolved.isEmpty else { throw SyncDatabaseError.execution }
                rootURL = selectedURL; rootID = selectedID; recoveryBlocked = false; hasPendingModuleMoves = false
                activityItemProblems = [:]
                dataSaverPause = nil
                courseFolders = [:]; conflicts = []; remoteChanges = []
                try await restoreScopes(for: courses)
                Self.defaults.set(selectedURL.path, forKey: Self.rootKey)
                Self.defaults.set(selectedID.uuidString, forKey: Self.rootIDKey)
                await self.restorePersistedSyncState()
                self.configureBackgroundScheduler()
            } catch {
                self?.setSyncState(.failed(.local(BilingualText("Non è stato possibile usare questa cartella. Scegline un'altra.", "This folder couldn't be used. Choose another one."))))
            }
        }
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        AppLanguage.current = newLanguage
        language = newLanguage
        Self.defaults.set(newLanguage.rawValue, forKey: Self.languageKey)
        // The menu is drawn from a snapshot, so it has to be rebuilt in the new language too.
        refreshMenuBarSnapshot()
        // Inline rename errors come from Core already resolved; they're transient, so drop them
        // rather than leave them in the old language.
        courseRenameErrors = [:]
    }

    func completeOnboarding() {
        needsOnboarding = false
        Self.defaults.set(true, forKey: Self.onboardingCompletedKey)
    }

    func isCourseEnabled(_ course: RemoteCourseSummary) -> Bool {
        enabledCourseIDs.contains(course.id)
    }

    func setCourse(_ course: RemoteCourseSummary, enabled: Bool) {
        guard !isSyncActive, !isLoadingCourses else { return }
        if enabled { enabledCourseIDs.insert(course.id) }
        else { enabledCourseIDs.remove(course.id) }
        operationDefaults.set(enabledCourseIDs.map(String.init).sorted(), forKey: Self.enabledCoursesKey)
        configureBackgroundScheduler()
        if let database, let rootID {
            let folder = courseFolders[course.id] ?? defaultFolder(for: course)
            courseFolders[course.id] = folder
            let previousWrite = scopeWriteTask
            scopeWriteTask = Task { [weak self] in
                await previousWrite?.value
                do {
                    try await database.upsertScope(SyncScope(rootID: rootID, courseID: course.id, displayName: course.displayName, localFolder: folder, enabled: enabled))
                } catch {
                    self?.courseRenameErrors[course.id] = tr("Impossibile salvare la selezione del corso.", "Couldn't save the course selection.")
                }
            }
        }
    }

    func setAutomaticSync(enabled: Bool, interval: Int? = nil) {
        guard !isSyncActive else { return }
        let wasEnabled = automaticSyncEnabled
        automaticSyncEnabled = enabled
        operationDefaults.set(enabled, forKey: Self.autoSyncKey)
        if let interval {
            automaticSyncInterval = Self.validatedAutomaticInterval(interval)
            operationDefaults.set(automaticSyncInterval, forKey: Self.autoSyncIntervalKey)
        }
        // Through the helper, not the coordinator directly: it also refreshes the Settings footer.
        if enabled && !wasEnabled { Task { await requestNotificationPermissionIfNeeded() } }
        configureBackgroundScheduler()
    }
    /// A click on a file in Attività (`showInFinder` for the context menu's "Mostra nel Finder").
    /// The file is looked up by its remote id in the sync database now, not when the sync ran, so
    /// a file a later sync moved still opens. What is at that path is checked by `FileStore`,
    /// off the main actor and without following symbolic links; see `ActivityFilePolicy` for what
    /// opens and what is only shown in Finder.
    func openActivityItem(id: String, name: String, showInFinder: Bool) async {
        // Captured together before any await, so a folder change during the lookup can't apply
        // one folder's path to another.
        guard let database, let rootID, let rootURL else { report(.unavailable, for: id); return }
#if DEBUG
        await beforeActivityLookupForTesting?()
#endif
        let action: ActivityFileAction
        do {
            let trackedPath = try await database.baseline(rootID: rootID, remoteID: id)?.relativePath
            let fileState: OpenableFileState
            if let trackedPath {
                let store: FileStore
                do { store = try FileStore(root: rootURL) } catch {
                    guard self.rootID == rootID else { return }
                    report(.folderUnavailable, for: id)
                    return
                }
                fileState = try await store.openableFileState(trackedPath)
            } else {
                fileState = .missing
            }
            action = ActivityFilePolicy.action(trackedPath: trackedPath, root: rootURL, fileState: fileState)
        } catch {
            guard self.rootID == rootID else { return }
            report(.unavailable, for: id)
            return
        }
        guard self.rootID == rootID else { return }
        switch action {
        case .open(let url):
            activityItemProblems[id] = nil
            if showInFinder { fileOpener.reveal(url) } else { fileOpener.open(url) }
        case .reveal(let url):
            activityItemProblems[id] = nil
            fileOpener.reveal(url)
        case .missing:
            report(.missing, for: id)
        case .unreadable:
            report(.unreadable, for: id)
        }
    }

    /// Shows the problem on the row and announces it to VoiceOver on every click, including a
    /// repeated one on a row that already shows it (the row itself doesn't change then).
    private func report(_ problem: ActivityItemProblem, for id: String) {
        activityItemProblems[id] = problem
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [.announcement: problem.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// "Risparmio dati" at launch: the stored choice, off when never set, so every existing user
    /// keeps automatic sync downloading on any network until they turn it on.
    nonisolated static func storedDataSaverEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: dataSaverKey)
    }

    /// The "Risparmio dati" switch. Takes effect from the next automatic run: a run already going
    /// keeps the limits it started with. Turning it off drops a pause on screen at once, since
    /// nothing holds automatic sync back any more; the scheduler retries the deferred run.
    func setDataSaver(enabled: Bool) {
        dataSaverEnabled = enabled
        operationDefaults.set(enabled, forKey: Self.dataSaverKey)
        if !enabled { dataSaverPause = nil }
    }

    /// What the switch shows at launch: the stored choice, on when never set.
    nonisolated static func storedNotificationsEnabled(in defaults: UserDefaults) -> Bool {
        NotificationPolicy.isEnabled(storedValue: defaults.object(forKey: NotificationPolicy.enabledKey))
    }

    /// The "Notifiche" switch. Turning it on asks macOS for permission if it never asked; turning it
    /// off stops every notification before it reaches macOS, and never prompts (#64).
    func setNotifications(enabled: Bool) async {
        notificationsEnabled = enabled
        operationDefaults.set(enabled, forKey: NotificationPolicy.enabledKey)
        guard enabled else {
            // Forgotten, not kept: permission may change while off (no reads then), and a stale
            // "blocked" would flash under the switch when it is turned back on.
            notificationAuthorization = nil
            return
        }
        await requestNotificationPermissionIfNeeded()
    }

    /// Asks macOS once if notifications are on and it never asked (turning on the switch, a sync,
    /// or automatic sync), then shows its answer under the switch.
    func requestNotificationPermissionIfNeeded() async {
        await notificationCoordinator.requestAuthorizationIfNeeded()
        await refreshNotificationAuthorization()
    }

    /// Re-reads macOS's permission, e.g. after the user changed it in System Settings. Only while
    /// the switch is on: with it off BeepBar doesn't contact the notification center at all, and
    /// the footer that shows the permission is only shown when on. Published only on change, so
    /// each app activation doesn't redraw the window.
    func refreshNotificationAuthorization() async {
        guard notificationsEnabled else { return }
        let authorization = await notificationCoordinator.authorization()
        guard notificationsEnabled, authorization != notificationAuthorization else { return }
        notificationAuthorization = authorization
    }

    func setAutomaticSyncInterval(_ seconds: Int) { guard !isSyncActive else { return }; automaticSyncInterval = Self.validatedAutomaticInterval(seconds); operationDefaults.set(automaticSyncInterval, forKey: Self.autoSyncIntervalKey); configureBackgroundScheduler() }

    func renameFolder(for course: RemoteCourseSummary, to newFolder: String) {
        guard let rootURL, let rootID, let database, !recoveryBlocked, !isSyncActive else { return }
        let oldFolder = folder(for: course)
        let trimmedFolder = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFolder.isEmpty, !ReservedNamespace.isReservedTopLevelName(trimmedFolder) else {
            courseRenameErrors[course.id] = tr("Nome cartella non valido.", "Invalid folder name.")
            return
        }
        courseRenameErrors[course.id] = nil
        renamingCourseID = course.id
        Task { [weak self] in
            defer { self?.renamingCourseID = nil }
            do {
                guard let self else { return }
                let renamer = CourseFolderRenamer(database: database, fileStore: try FileStore(root: rootURL), gate: self.operationGate)
                try await renamer.rename(rootID: rootID, courseID: course.id, from: oldFolder, to: trimmedFolder)
                self.courseFolders[course.id] = trimmedFolder
            } catch {
                self?.courseRenameErrors[course.id] = (error as? CourseRenameError)?.errorDescription ?? tr("Rinomina non riuscita.", "Rename failed.")
            }
        }
    }

    func clearRenameError(for course: RemoteCourseSummary) {
        guard courseRenameErrors[course.id] != nil else { return }
        courseRenameErrors[course.id] = nil
    }

    func synchronizeNow() {
#if DEBUG
        if Self.isUIPreview {
            courses = Self.orderedForDisplay(courses, enabledCourseIDs: enabledCourseIDs)
            simulatePreviewSync()
            return
        }
#endif
        guard !recoveryBlocked else { setSyncState(.recoveryBlocked); return }
        guard activeOperationID == nil, !isLoadingCourses else { return }
        let operationID = UUID()
        activeOperationID = operationID
        // «Sincronizza ora» always downloads, on any network: nothing is paused any more.
        dataSaverPause = nil
        setSyncState(.checking)
        // Through the helper, not the coordinator directly: it also refreshes the Settings footer.
        Task { await requestNotificationPermissionIfNeeded() }
        syncTask = Task { [weak self] in
            do {
                guard let self else { return }
                await self.bootstrapTask?.value
                try Task.checkCancellation()
                guard self.activeOperationID == operationID else { return }
                // The course list is only loaded when the window opens, so a sync started from the
                // menu right after launch would otherwise find nothing selected and do nothing.
                if self.courses.isEmpty, self.hasStoredCredential, self.accountState == .connected {
                    let token = try await self.credentialVault.load()
                    try await self.refreshCourseList(token: token)
                    try Task.checkCancellation()
                    guard self.activeOperationID == operationID else { return }
                }
                let selected = self.courses.filter { self.enabledCourseIDs.contains($0.id) }
                guard !selected.isEmpty else {
                    self.setSyncState(.readyUnchecked)
                    self.endOperation(operationID)
                    return
                }
                guard let database = self.database else { throw SyncDatabaseError.open }
                guard let rootURL = self.rootURL, let rootID = self.rootID else {
                    self.setSyncState(.needsFolder)
                    self.endOperation(operationID)
                    return
                }
                let targets = selected.map { SyncTarget(courseID: $0.id, localFolder: self.folder(for: $0)) }
                let token = try await self.credentialVault.load()
                let coordinator = try SyncCoordinator(rootID: rootID, rootURL: rootURL, database: database, gate: self.operationGate, apiClient: self.apiClient, downloader: self.downloader, platformName: self.selectedSite.platformName)
                await self.beginTransfer(operationID, automatic: false)
                let summary = try await coordinator.synchronize(targets: targets, token: token, mode: .manual, networkAccess: .unrestricted) { [weak self] progress in
                    await self?.publishProgress(progress)
                }
                await self.completeSync(operationID, summary: summary, automatic: false)
            } catch is CancellationError {
                self?.cancelledSync(operationID)
            } catch let error as WeBeepAPIError {
                await self?.failedSync(operationID, error: error, automatic: false)
            } catch let error as CredentialStorageError {
                await self?.handleCredentialStorageError(error)
                self?.endOperation(operationID)
            } catch is RootOperationGateError {
                self?.busySync(operationID)
            } catch {
                await self?.failedSync(operationID, error: nil, automatic: false)
            }
        }
    }

#if DEBUG
    /// `--ui-preview` only: a few seconds of fake progress so the sync UI (progress line,
    /// Annulla, menu bar detail, last-sync time) can be exercised without network or files.
    private func simulatePreviewSync() {
        guard activeOperationID == nil else { return }
        let previous = lastSyncSummary
        activeOperationID = UUID()
        setSyncState(.syncing)
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.progressStore.reset(automatic: false)
            let total = 40
            for completed in 1...total {
                try? await Task.sleep(for: .milliseconds(90))
                if Task.isCancelled { break }
                await self.publishProgress(SyncProgress(completed: completed, total: total, added: completed / 8, updated: completed / 20, preservedLocal: 0, unchanged: completed, conflicts: 0, failures: 0))
            }
            let cancelled = Task.isCancelled
            self.syncTask = nil
            if cancelled, let previous {
                self.setSyncState(.synced(previous))
            } else {
                self.setSyncState(.synced(SyncCompletionSummary(completedAt: Date(), added: 5, updated: 2, unchanged: 93, preservedLocal: 0, conflicts: 0, failures: 0, perCourse: previous?.perCourse ?? [])))
            }
            await Task.yield()
            self.activeOperationID = nil
        }
    }
#endif

    func cancelSynchronization() {
        guard let operationID = activeOperationID else { return }
        guard let syncTask else {
            cancelledSync(operationID)
            return
        }
        syncTask.cancel()
        setSyncState(.cancelling)
    }

    func prepareForTermination() -> Task<Void, Never>? {
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
        scheduledConfiguration = nil
        guard let syncTask else { return nil }
        syncTask.cancel()
        setSyncState(.cancelling)
        return syncTask
    }

    func refreshConflicts() {
        guard !isSyncActive else { return }
        guard database != nil, rootID != nil else { return }
        Task { [weak self] in await self?.reloadPendingChoices() }
    }

    private func reloadPendingChoices() async {
        let expectedRootID = rootID
        do {
            let pending = try await loadPendingChoices()
            guard rootID == expectedRootID, hasStoredCredential, accountState != .expired, !isSyncActive else { return }
            conflicts = pending.conflicts
            remoteChanges = pending.changes
            if !conflicts.isEmpty { setSyncState(.conflicts(conflicts.count, nil)) }
            else if case .conflicts = syncState { await restorePersistedSyncState() }
        } catch {
            guard rootID == expectedRootID, hasStoredCredential, accountState != .expired, !isSyncActive else { return }
            reportPendingChoicesReadFailure()
        }
    }

    /// Both lists form one displayed snapshot: a failed second read must not hide either list.
    private func loadPendingChoices() async throws -> (conflicts: [ConflictRecord], changes: [RemoteChange]) {
        guard let database, let rootID else { throw SyncDatabaseError.open }
        let open = try await database.conflicts(rootID: rootID)
        let changes = try await database.remoteChanges(rootID: rootID)
#if DEBUG
        await beforePendingChoicesForTesting?()
#endif
        return (open, changes)
    }

    private func reportPendingChoicesReadFailure() {
        setSyncState(.failed(.local(BilingualText("Impossibile leggere le scelte in sospeso. Riprova.", "Couldn't read pending choices. Try again."))))
    }

    func resolve(_ conflict: ConflictRecord, with resolution: ConflictResolution) {
        guard resolvingConflictID == nil, resolvingRemoteChangeID == nil, let rootURL, let rootID, let database, !recoveryBlocked, !isSyncActive else { return }
        conflictChoiceFeedback = nil
        resolvingConflictID = conflict.id
        Task { [weak self] in
            defer { self?.resolvingConflictID = nil }
            do {
                guard let self else { return }
                let resolver = ConflictResolver(database: database, fileStore: try FileStore(root: rootURL), gate: self.operationGate)
                switch resolution {
                case .keepLocal:
                    try await resolver.keepLocal(id: conflict.id)
                    self.status = tr("Conflitto risolto: la modifica locale è stata mantenuta.", "Conflict resolved: the local change was kept.")
                case .useRemote:
                    let result = try await resolver.useRemote(id: conflict.id)
                    guard result.isInstalled else {
                        self.reportConflictChoiceFeedback(BilingualText("Il file locale è cambiato nel frattempo: conflitto lasciato aperto.", "The local file changed in the meantime: the conflict was left open."), rootID: rootID)
                        self.refreshConflicts()
                        return
                    }
                    self.status = tr("Conflitto risolto: la versione remota è stata installata.", "Conflict resolved: the remote version was installed.")
                }
                self.refreshConflicts()
            } catch {
                self?.reportConflictChoiceFeedback(BilingualText("Impossibile completare la risoluzione del conflitto. Controlla il file e aggiorna prima di riprovare.", "Couldn't finish resolving this conflict. Check the file and refresh before retrying."), rootID: rootID)
                self?.refreshConflicts()
            }
        }
    }

    /// Carries out a choice about a file Moodle moved or removed. The file is re-checked first, so a
    /// stale entry never moves or trashes anything (see `RemoteChangeResolver`).
    func resolve(_ change: RemoteChange, with action: RemoteChangeAction) {
        guard resolvingRemoteChangeID == nil, resolvingConflictID == nil, let rootURL, let rootID, let database, !recoveryBlocked, !isSyncActive else { return }
        conflictChoiceFeedback = nil
        resolvingRemoteChangeID = change.id
        Task { [weak self] in
            defer { self?.resolvingRemoteChangeID = nil }
            do {
                guard let self else { return }
                let resolver = RemoteChangeResolver(database: database, fileStore: try FileStore(root: rootURL), gate: self.operationGate)
                let outcome = try await resolver.perform(action, on: change.id, rootID: rootID)
                self.status = SyncCopy.remoteChangeStatus(outcome, action: action)
                switch outcome {
                case .done, .gone: break
                default: self.reportConflictChoiceFeedback(SyncCopy.remoteChangeFeedback(outcome, action: action), rootID: rootID)
                }
            } catch {
                self?.reportConflictChoiceFeedback(BilingualText("Impossibile completare la scelta. Nessun file è stato sovrascritto o cancellato definitivamente.", "Couldn't carry out the choice. No file was overwritten or permanently deleted."), rootID: rootID)
            }
            self?.refreshConflicts()
        }
    }

    private func reportConflictChoiceFeedback(_ feedback: BilingualText, rootID: UUID) {
        guard self.rootID == rootID, hasStoredCredential else { return }
        conflictChoiceFeedback = feedback
    }

    func startLogin() {
        guard !isAuthenticating, !isVerifying else { return }
        authenticationFeedback = nil
        isAuthenticating = true; status = tr("Autenticazione \(selectedSite.displayName) in corso…", "Signing in to \(selectedSite.displayName)…")
#if DEBUG
        if testDefaults != nil { return }
#endif
        loginWindow = LoginWindowController(site: selectedSite) { [weak self] result in _ = self?.completeLogin(result) }
        loginWindow?.showWindow(nil)
    }

    func selectUniversity(_ university: MoodleUniversity) {
        guard !hasStoredCredential, !isAuthenticating, !isVerifying else { return }
        selectSite(university == .polimi ? .polimi : MoodleSite.unipd[0])
    }

    func selectSite(_ site: MoodleSite) {
        guard !hasStoredCredential, !isAuthenticating, !isVerifying, site != selectedSite else { return }
        selectedSite = site
        operationDefaults.set(site.id, forKey: Self.selectedSiteKey)
        apiClient = WeBeepAPIClient(policy: site.serverPolicy)
        downloader = RemoteDownloader(policy: site.serverPolicy)
        siteInfo = nil
        courses = []
        // Course ids belong to one site: the previous site's selection must not enable whatever
        // course happens to share an id on the new one.
        enabledCourseIDs = []
        operationDefaults.set([String](), forKey: Self.enabledCoursesKey)
        if let database, let rootID {
            let previousWrite = scopeWriteTask
            scopeWriteTask = Task { await previousWrite?.value; try? await database.disableAllScopes(rootID: rootID) }
        }
        configureBackgroundScheduler()
    }

    @discardableResult func validateConnection() -> Task<Void, Never>? {
        guard !Self.isUIPreview, !isVerifying, !isAuthenticating else { return nil }
        isVerifying = true; status = tr("Verifica connessione \(selectedSite.platformName) in corso…", "Checking the \(selectedSite.platformName) connection…")
        return Task { [weak self] in
            defer { self?.isVerifying = false }
            do {
                guard let self else { return }
                let token = try await self.credentialVault.load()
                let siteInfo = try await self.apiClient.validateToken(token)
                self.siteInfo = siteInfo
                self.accountState = .connected
                self.operationDefaults.removeObject(forKey: Self.credentialExpiredKey)
                self.notificationCoordinator.clearFailure()
                self.setSyncState(self.rootURL == nil ? .needsFolder : .readyUnchecked)
                self.configureBackgroundScheduler()
            } catch let error as WeBeepAPIError {
                _ = await self?.handleServiceFailure(error, automatic: false)
            } catch let error as CredentialStorageError {
                await self?.handleCredentialStorageError(error)
            } catch {
                self?.setSyncState(.failed(.local(BilingualText("Non è stato possibile verificare la piattaforma. Riprova più tardi.", "The platform couldn't be verified. Try again later."))))
            }
        }
    }

    func loadCourses() {
        guard !Self.isUIPreview else { return }
        guard accountState == .connected, hasStoredCredential, !isLoadingCourses, !isSyncActive else { return }
        courseLoadError = nil
        isLoadingCourses = true
        let task = Task { [weak self] in
            defer { self?.isLoadingCourses = false }
            do {
                guard let self else { return }
                await self.bootstrapTask?.value
                try Task.checkCancellation()
                let token = try await self.credentialVault.load()
                try await self.refreshCourseList(token: token)
            } catch let error as WeBeepAPIError {
                guard let self else { return }
                if error == .invalidToken {
                    await self.expireCredential()
                } else if error == .network(.timedOut) {
                    self.courseLoadError = BilingualText("\(self.selectedSite.platformName) non risponde. Riprova.", "\(self.selectedSite.platformName) isn't responding. Try again.")
                } else {
                    self.courseLoadError = BilingualText("Impossibile aggiornare i corsi da \(self.selectedSite.platformName). Riprova.", "Couldn't refresh courses from \(self.selectedSite.platformName). Try again.")
                }
            } catch let error as CredentialStorageError {
                await self?.handleCredentialStorageError(error)
            } catch {
                self?.courseLoadError = BilingualText("Impossibile aggiornare i corsi. Riprova.", "Couldn't refresh courses. Try again.")
            }
        }
#if DEBUG
        courseLoadTaskForTesting = task
#else
        _ = task
#endif
    }

    /// Fetches the enrolled courses and makes them the current list. Shared by the course list
    /// refresh and by a sync started before the list was ever loaded (from the menu right after
    /// launch), which cannot go through `loadCourses` because that refuses to run during a sync.
    private func refreshCourseList(token: String) async throws {
        let courses = try await fetchEnrolledCourses(token: token)
        // The account may have been disconnected while the list was loading.
        guard hasStoredCredential else { return }
        try await restoreScopes(for: courses)
        self.courses = Self.orderedForDisplay(courses, enabledCourseIDs: enabledCourseIDs)
        accountState = .connected
        operationDefaults.removeObject(forKey: Self.credentialExpiredKey)
    }

    private func fetchEnrolledCourses(token: String) async throws -> [RemoteCourseSummary] {
        let siteInfo: WeBeepSiteInfo
        if let existing = self.siteInfo {
            siteInfo = existing
        } else {
            siteInfo = try await apiClient.validateToken(token)
        }
        let courses = try await apiClient.fetchCourses(userID: siteInfo.userID, token: token)
        self.siteInfo = siteInfo
        return courses
    }

    private static let onboardingCompletedKey = "io.github.tvaccari.beepbar.onboarding-completed.v1"
    private static let rootKey = "io.github.tvaccari.beepbar.root-path.v1"
    private static let rootIDKey = "io.github.tvaccari.beepbar.root-id.v1"
    private static let enabledCoursesKey = "io.github.tvaccari.beepbar.enabled-courses.v1"
    private static let autoSyncKey = "io.github.tvaccari.beepbar.auto-sync.v1"
    private static let autoSyncIntervalKey = "io.github.tvaccari.beepbar.auto-sync-interval.v1"
    private nonisolated static let dataSaverKey = "io.github.tvaccari.beepbar.data-saver.v1"
    private static let lastSuccessfulReconciliationKey = "io.github.tvaccari.beepbar.last-successful-reconciliation.v1."
    private static let lastSuccessfulSummaryKey = "io.github.tvaccari.beepbar.last-successful-summary.v1."
    private static let credentialExpiredKey = "io.github.tvaccari.beepbar.credential-expired.v1"
    private static let selectedSiteKey = "io.github.tvaccari.beepbar.moodle-site.v1"
    private static let languageKey = "io.github.tvaccari.beepbar.language.v1"
    private static var isUIPreview: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-preview")
#else
        false
#endif
    }

    private static var isUIPreviewOnboarding: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-preview-onboarding")
#else
        false
#endif
    }

    /// Every persisted setting goes through this instead of `Self.defaults` directly:
    /// the raw `--ui-preview`/`--ui-preview-onboarding` binaries share the real app's bundle
    /// identifier (they're unsigned executables built from the same target), so writing straight
    /// to `.standard` during manual preview testing would silently overwrite the real installed
    /// app's settings (sync root, credentials-expired flag, etc). Preview runs get their own
    /// throwaway suite, wiped at launch so every preview run starts from a clean slate.
    private static let defaults: UserDefaults = {
        guard isUIPreview || isUIPreviewOnboarding else { return .standard }
        let suiteName = "io.github.tvaccari.beepbar.preview"
        let store = UserDefaults(suiteName: suiteName) ?? .standard
        if let domain = store.persistentDomain(forName: suiteName) {
            for key in domain.keys { store.removeObject(forKey: key) }
        }
        return store
    }()

    private var operationDefaults: UserDefaults {
#if DEBUG
        if let testDefaults { return testDefaults }
#endif
        return Self.defaults
    }

    private static let automaticIntervals: Set<Int> = [1_800, 3_600, 7_200, 14_400, 28_800]

    private static func validatedAutomaticInterval(_ value: Int?) -> Int {
        guard let value, automaticIntervals.contains(value) else { return 28_800 }
        return value
    }

    private static func storedRootURL() -> URL? {
        guard let path = Self.defaults.string(forKey: rootKey), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    @discardableResult private func completeLogin(_ result: Result<URL, LoginWindowError>) -> Task<Void, Never>? {
        loginWindow = nil
        authenticationFeedback = nil
        // A cancelled or failed login leaves the current account and its course list untouched.
        guard case let .success(callback) = result, let token = token(from: callback) else {
            isAuthenticating = false
            authenticationFeedback = BilingualText("Accesso a \(selectedSite.platformName) annullato o callback non valido.", "Sign-in to \(selectedSite.platformName) cancelled or invalid callback.")
            return nil
        }
        isAuthenticating = true
        return Task { [weak self] in
            defer { self?.isAuthenticating = false }
            do {
                guard let self else { return }
                let siteInfo = try await self.apiClient.validateToken(token)
                try await self.credentialVault.save(token)
                // Only a token that was accepted and stored replaces the previous account's state.
                self.courses = []
                self.siteInfo = siteInfo
                self.hasStoredCredential = true
                self.accountState = .connected
                self.operationDefaults.removeObject(forKey: Self.credentialExpiredKey)
                self.notificationCoordinator.clearFailure()
                self.setSyncState(self.rootURL == nil ? .needsFolder : .readyUnchecked)
                self.configureBackgroundScheduler()
                self.loadCourses()
            } catch let error as WeBeepAPIError where error == .invalidToken {
                self?.authenticationFeedback = BilingualText("Il token ricevuto non è valido. Accedi di nuovo alla piattaforma.", "The received token isn't valid. Sign in to the platform again.")
            } catch {
                self?.authenticationFeedback = BilingualText("Impossibile verificare l'accesso alla piattaforma. Il token non è stato salvato.", "Couldn't verify access to the platform. The token wasn't saved.")
            }
        }
    }

    private func token(from callback: URL) -> String? {
        let prefix = "moodlemobile://token="
        let encoded = callback.absoluteString.hasPrefix(prefix)
            ? String(callback.absoluteString.dropFirst(prefix.count))
            : URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value
        guard let encoded, encoded.utf8.count <= 32_768,
              let payload = encoded.removingPercentEncoding,
              let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let fields = decoded.components(separatedBy: ":::")
        guard (fields.count == 2 || fields.count == 3), fields.allSatisfy({ !$0.isEmpty }) else { return nil }
        return fields[1]
    }

    private static func storedRootID() -> UUID? {
        Self.defaults.string(forKey: rootIDKey).flatMap(UUID.init(uuidString:))
    }

    /// The installed path must go through `installedDatabaseDirectory(applicationSupport:)`, which
    /// is what `ProductNameTests` pins: a literal here would escape that test (#56).
    private static func databaseDirectory() throws -> URL {
        guard !isUIPreview, !isUIPreviewOnboarding else {
            // Same reasoning as `defaults`: don't let a manual preview run touch the real
            // installed app's sync database. A fresh throwaway directory per launch also gives
            // onboarding testing a clean "first install" every time.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        return installedDatabaseDirectory(applicationSupport: try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
    }

    /// Where an installed BeepBar keeps `sync.sqlite`: the same Application Support folder as the
    /// token, under a name that must never change with the product's spelling (see
    /// `FileTokenStore.applicationSupportDirectoryName`).
    nonisolated static func installedDatabaseDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(FileTokenStore.applicationSupportDirectoryName, isDirectory: true)
    }

    private func restoreScopes(for courses: [RemoteCourseSummary]) async throws {
#if DEBUG
        beforeScopeRestoreForTesting?()
#endif
        await scopeWriteTask?.value
        guard let database, let rootID else { return }
        let scopes = try await database.scopes(rootID: rootID)
        let remoteIDs = Set(courses.map(\.id))
        let scopesByCourse = Dictionary(scopes.map { ($0.courseID, $0) }, uniquingKeysWith: { first, _ in first })
        let defaults = Self.defaultFolders(for: courses, saved: Dictionary(scopes.map { ($0.courseID, $0.localFolder) }, uniquingKeysWith: { first, _ in first }))
        enabledCourseIDs = Self.restoredEnabledCourseIDs(scopes: scopes, current: enabledCourseIDs, remoteIDs: remoteIDs)
        for course in courses {
            if let scope = scopesByCourse[course.id], !scope.localFolder.isEmpty {
                let replacement = LocalPathPolicy.generatedCourseFolderReplacement(
                    storedFolder: scope.localFolder,
                    storedCourseName: scope.displayName,
                    currentCourseName: course.displayName,
                    courseID: course.id,
                    currentDefaultFolder: defaults[course.id]
                )
                if let replacement, let rootURL {
                    do {
                        let renamer = CourseFolderRenamer(database: database, fileStore: try FileStore(root: rootURL), gate: operationGate)
                        try await renamer.rename(rootID: rootID, courseID: course.id, from: scope.localFolder, to: replacement)
                        courseFolders[course.id] = replacement
                        try await database.upsertScope(SyncScope(
                            rootID: rootID,
                            courseID: course.id,
                            displayName: course.displayName,
                            localFolder: replacement,
                            enabled: scope.enabled,
                            managedDirectory: scope.managedDirectory
                        ))
                    } catch {
                        courseFolders[course.id] = scope.localFolder
                    }
                } else {
                    courseFolders[course.id] = scope.localFolder
                    if scope.displayName != course.displayName {
                        try? await database.upsertScope(SyncScope(
                            rootID: rootID,
                            courseID: course.id,
                            displayName: course.displayName,
                            localFolder: scope.localFolder,
                            enabled: scope.enabled,
                            managedDirectory: scope.managedDirectory
                        ))
                    }
                }
            } else {
                courseFolders[course.id] = defaults[course.id] ?? LocalPathPolicy.defaultCourseFolder(course.displayName)
                if scopes.isEmpty {
                    do {
                        try await database.upsertScope(SyncScope(rootID: rootID, courseID: course.id, displayName: course.displayName, localFolder: courseFolders[course.id]!, enabled: enabledCourseIDs.contains(course.id)))
                    } catch {
                        courseRenameErrors[course.id] = tr("Impossibile salvare la selezione del corso.", "Couldn't save the course selection.")
                    }
                }
            }
        }
        operationDefaults.set(enabledCourseIDs.map(String.init).sorted(), forKey: Self.enabledCoursesKey)
    }

    func folder(for course: RemoteCourseSummary) -> String {
        courseFolders[course.id] ?? defaultFolder(for: course)
    }

    func modulePathRules(for course: RemoteCourseSummary) async throws -> [ModulePathRuleRow] {
        await bootstrapTask?.value
        guard !recoveryBlocked, let rootURL, let rootID, let database else { throw ModulePathMigrationError.pendingRecovery }
        let token = try await credentialVault.load()
        let contents = try await apiClient.fetchContents(courseID: course.id, token: token)
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: try FileStore(root: rootURL), gate: operationGate, apiClient: apiClient)
        return try await migrator.ruleRows(courseID: course.id, contents: contents)
    }

    func previewModulePath(for course: RemoteCourseSummary, moduleID: Int64, action: ModuleMoveAction, proposedFolder: String?) async throws -> ModuleMovePreview {
        await bootstrapTask?.value
        guard !recoveryBlocked, let rootURL, let rootID, let database else { throw ModulePathMigrationError.pendingRecovery }
        let token = try await credentialVault.load()
        let contents = try await apiClient.fetchContents(courseID: course.id, token: token)
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: try FileStore(root: rootURL), gate: operationGate, apiClient: apiClient)
        return try await migrator.preview(courseID: course.id, moduleID: moduleID, courseFolder: folder(for: course), action: action, folder: proposedFolder, contents: contents)
    }

    func applyModulePath(_ preview: ModuleMovePreview, for course: RemoteCourseSummary) async throws {
        await bootstrapTask?.value
        guard !recoveryBlocked, let rootURL, let rootID, let database else { throw ModulePathMigrationError.pendingRecovery }
        let token = try await credentialVault.load()
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: try FileStore(root: rootURL), gate: operationGate, apiClient: apiClient)
        do {
            try await migrator.apply(preview, courseFolder: folder(for: course), token: token)
        } catch {
            if (try? await database.hasPendingModuleMoves(rootID: rootID)) == true {
                hasPendingModuleMoves = true
                recoveryBlocked = true
                setSyncState(.recoveryBlocked)
            }
            throw error
        }
    }

    func deleteUnavailableModuleRule(for course: RemoteCourseSummary, moduleID: Int64) async throws {
        await bootstrapTask?.value
        guard !recoveryBlocked, let rootURL, let rootID, let database else { throw ModulePathMigrationError.pendingRecovery }
        let token = try await credentialVault.load()
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: try FileStore(root: rootURL), gate: operationGate, apiClient: apiClient)
        do {
            try await migrator.deleteUnavailableRule(courseID: course.id, moduleID: moduleID, token: token)
        } catch {
            if (try? await database.hasPendingModuleMoves(rootID: rootID)) == true {
                hasPendingModuleMoves = true
                recoveryBlocked = true
                setSyncState(.recoveryBlocked)
            }
            throw error
        }
    }

    private func defaultFolder(for course: RemoteCourseSummary) -> String {
        defaultCourseFolders[course.id] ?? LocalPathPolicy.defaultCourseFolder(course.displayName)
    }

    nonisolated static func orderedForDisplay(_ courses: [RemoteCourseSummary], enabledCourseIDs: Set<Int64>) -> [RemoteCourseSummary] {
        courses.sorted { lhs, rhs in
            let lhsEnabled = enabledCourseIDs.contains(lhs.id)
            let rhsEnabled = enabledCourseIDs.contains(rhs.id)
            if lhsEnabled != rhsEnabled { return lhsEnabled }
            let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    nonisolated static func restoredEnabledCourseIDs(scopes: [SyncScope], current: Set<Int64>, remoteIDs: Set<Int64>) -> Set<Int64> {
        guard !scopes.isEmpty else { return current.intersection(remoteIDs) }
        return Set(scopes.lazy.filter { $0.enabled && remoteIDs.contains($0.courseID) }.map(\.courseID))
    }

    /// Pure and independently testable: a distinct default folder for each course. Courses whose
    /// short folder collides fall back to their full name; courses that still collide (identical
    /// names, e.g. two "Tesi di laurea") also get their Moodle ID, then a counter if even that
    /// name is taken by a folder saved for another course. A collision is with another
    /// course's default or with a folder already `saved` for another course (a user may have
    /// renamed one onto a name another course would get). Every result must differ on disk: a
    /// scope's folder is unique per root, so two courses sharing one left the second impossible
    /// to enable, forever (ultrareview finding).
    nonisolated static func defaultFolders(for courses: [RemoteCourseSummary], saved: [Int64: String] = [:]) -> [Int64: String] {
        let uniqueCourses = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let savedOwners = Dictionary(grouping: saved.keys, by: { PathKey.of(saved[$0]!) }).mapValues(Set.init)
        // Each course climbs these levels only while its folder collides with another course's.
        func candidate(_ course: RemoteCourseSummary, level: Int) -> String {
            switch level {
            case 0: LocalPathPolicy.defaultCourseFolder(course.displayName)
            case 1: LocalPathPolicy.courseFolderSlug(course.displayName)
            case 2: LocalPathPolicy.courseFolder(LocalPathPolicy.courseFolderSlug(course.displayName), disambiguatedBy: course.id)
            default: LocalPathPolicy.courseFolder(LocalPathPolicy.courseFolder(LocalPathPolicy.courseFolderSlug(course.displayName), disambiguatedBy: course.id), disambiguatedBy: Int64(level - 1))
            }
        }
        // From level 2 on, a course's candidates all differ from one another, and it climbs only
        // when a folder saved for another course takes its name or when it loses the tie-break
        // between two ID-carrying names below. The bound leaves room for both: one level per
        // saved folder and one per course, past which one of its candidates must be free.
        let maximumLevel = 3 + saved.count + uniqueCourses.count
        var levels = uniqueCourses.mapValues { _ in 0 }
        while true {
            let folders = Dictionary(uniqueKeysWithValues: levels.map { id, level in (id, candidate(uniqueCourses[id]!, level: level)) })
            let groups = Dictionary(grouping: folders.keys, by: { PathKey.of(folders[$0]!) })
            let colliding = folders.keys.filter { id in
                let key = PathKey.of(folders[id]!)
                if !(savedOwners[key] ?? []).subtracting([id]).isEmpty { return true }
                let group = groups[key]!
                guard group.count > 1 else { return false }
                // A course already carrying its ID keeps its name against a name-derived one,
                // which moves aside. Between two ID-carrying names (only possible through the
                // counter, e.g. "a-5" + counter 2 against a course called "A 5" with ID 2) the
                // lowest ID keeps it, so every pass still makes progress.
                if levels[id]! < 2 { return true }
                let named = group.filter { levels[$0]! < 2 }
                return named.isEmpty && id != group.min()!
            }.filter { levels[$0]! < maximumLevel }
            // Terminates: every pass raises at least one level, and levels stop at `maximumLevel`.
            guard !colliding.isEmpty else { return folders }
            for id in colliding { levels[id]! += 1 }
        }
    }

    private func finishReconciliation(progress: SyncProgress, operationID: UUID) async throws {
        let pending = try await loadPendingChoices()
        let open = pending.conflicts
        let changes = pending.changes
#if DEBUG
        await beforeReconciliationStateForTesting?()
#endif
        // Cancellation keeps the operation ID until its task unwinds. Checking the ID alone
        // would publish a completed result over the user's pending cancellation.
        guard activeOperationID == operationID, !Task.isCancelled else { return }
        conflicts = open
        remoteChanges = changes
        courses = Self.orderedForDisplay(courses, enabledCourseIDs: enabledCourseIDs)
        let summary = SyncCompletionSummary(progress: progress)
        if progress.failures > 0 {
            setSyncState(.partial(summary))
        } else if !open.isEmpty {
            setSyncState(.conflicts(open.count, summary))
        } else {
            setSyncState(.synced(summary))
        }
    }

    private func configureBackgroundScheduler() {
        let configuration = BackgroundScheduleConfiguration(
            enabled: automaticSyncEnabled,
            interval: automaticSyncInterval,
            connected: accountState == .connected,
            rootConfigured: rootURL != nil,
            enabledCourseCount: enabledCourseIDs.count,
            recoveryBlocked: recoveryBlocked
        )
        guard configuration != scheduledConfiguration else { return }
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
        scheduledConfiguration = configuration
        schedulerGeneration += 1
        // The pause promised a retry soon; that retry belonged to the scheduler just dropped, and
        // the new one first runs a whole interval later. Left on screen, "In attesa del Wi-Fi"
        // could stay for hours, through a renewed sign-in, after the Mac is back on Wi-Fi.
        dataSaverPause = nil
        let policy = BackgroundScheduleInput(
            automaticSyncEnabled: configuration.enabled,
            hasCredential: configuration.connected,
            hasRoot: configuration.rootConfigured,
            enabledCourseCount: configuration.enabledCourseCount,
            recoveryBlocked: recoveryBlocked
        )
        guard BackgroundSchedulePolicy.shouldSchedule(policy) else {
            BeepbarLog.scheduler.notice("Scheduler disabled enabled=\(configuration.enabled, privacy: .public) connected=\(configuration.connected, privacy: .public) root=\(configuration.rootConfigured, privacy: .public) courses=\(configuration.enabledCourseCount, privacy: .public) recoveryBlocked=\(configuration.recoveryBlocked, privacy: .public)")
            return
        }
#if DEBUG
        guard registersBackgroundActivity else { return }
#endif
        let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.tvaccari.beepbar.auto-sync")
        scheduler.repeats = true
        scheduler.interval = TimeInterval(automaticSyncInterval)
        scheduler.tolerance = TimeInterval(automaticSyncInterval) * 0.5
        scheduler.qualityOfService = .utility
        BeepbarLog.scheduler.notice("Scheduler configured intervalSeconds=\(self.automaticSyncInterval, privacy: .public) toleranceSeconds=\(Int(scheduler.tolerance), privacy: .public)")
        scheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                BeepbarLog.scheduler.notice("Scheduler callback started")
                let trace = PerformanceTrace.shared.begin("scheduler.callback", category: .scheduler)
                defer { PerformanceTrace.shared.end("scheduler.callback", category: .scheduler, state: trace) }
                let outcome = await self?.runAutomaticSync() ?? .finished
                BeepbarLog.scheduler.notice("Scheduler callback completed outcome=\(outcome.diagnosticName, privacy: .public)")
                completion(outcome.schedulerResult)
            }
        }
        backgroundScheduler = scheduler
    }

    /// Whether an automatic run has everything it needs to sync at all.
    private var isAutomaticSyncConfigured: Bool {
        rootURL != nil && rootID != nil && database != nil && accountState == .connected && !recoveryBlocked
    }

    private func runAutomaticSync() async -> AutomaticSyncOutcome {
        let lowPowerMode = automaticSyncEnvironment.isLowPowerModeEnabled()
        // The network is read only with "Risparmio dati" on, and only when the run could otherwise
        // go ahead. That read is the only suspension before the decision, so every other input is
        // read after it, in the same main-actor turn as the decision and the start of the run.
        var network: NetworkPathConditions?
        if dataSaverEnabled, !lowPowerMode, activeOperationID == nil, !isLoadingCourses, isAutomaticSyncConfigured {
            let generation = schedulerGeneration
            network = await automaticSyncEnvironment.currentNetwork()
            // Rebuilt meanwhile (automatic sync turned off, Frequenza changed, signed out…), even
            // if back to the same settings: this callback belongs to a schedule that no longer
            // exists, and the new one takes over. Going on would sync after the user turned
            // automatic sync off, or show a pause nothing would clear, since the rebuild that
            // clears it has already happened.
            guard schedulerGeneration == generation else {
                BeepbarLog.sync.notice("Automatic synchronization skipped reason=schedule-changed")
                return .finished
            }
        }
        switch AutomaticSyncPolicy.decision(lowPowerMode: lowPowerMode, busy: activeOperationID != nil || isLoadingCourses, configured: isAutomaticSyncConfigured, dataSaverEnabled: dataSaverEnabled, network: network) {
        case .deferForLowPowerMode:
            BeepbarLog.sync.notice("Automatic synchronization deferred reason=low-power")
            return .deferred
        case .deferWhileBusy:
            BeepbarLog.sync.notice("Automatic synchronization deferred reason=operation-active")
            return .deferred
        case .skipUnconfigured:
            BeepbarLog.sync.notice("Automatic synchronization skipped reason=configuration-unavailable")
            // Finishing leaves no retry behind, so a pause from an earlier attempt must go too.
            // A blocked local recovery gets here without a rebuild (`recoveryBlocked` doesn't
            // reconfigure the scheduler), and resolving it restores an equal schedule: left in
            // place, "In attesa del Wi-Fi" would come back over the last result, even on Wi-Fi,
            // until the next run a whole interval later.
            dataSaverPause = nil
            return .finished
        case .pause(let pause):
            // Nothing is sent and the state on screen is left alone (the last result, "sincronizzato
            // X fa"): the pause is shown on top of it. Deferred, so the scheduler retries soon
            // instead of waiting a whole interval.
            BeepbarLog.sync.notice("Automatic synchronization deferred reason=data-saver")
            dataSaverPause = pause
            return .deferred
        case .run:
            break
        }
        guard let rootURL, let rootID, let database else { return .finished }
        dataSaverPause = nil
        // Captured once: switching "Risparmio dati" during the run changes the next run, not this one.
        let networkAccess: NetworkAccess = dataSaverEnabled ? .dataSaver : .unrestricted
        let operationID = UUID()
        activeOperationID = operationID
        automaticOutcome = .finished
        await scopeWriteTask?.value
        guard activeOperationID == operationID else { return .cancelled }
        // Nothing to check: leave the last result on screen instead of replacing it with "Pronto".
        let automaticScopes: [SyncScope]
        do { automaticScopes = try await database.scopes(rootID: rootID, enabledOnly: true) }
        catch {
            guard activeOperationID == operationID else { return .cancelled }
            guard !Task.isCancelled else { cancelledSync(operationID); return .cancelled }
            setSyncState(.failed(.local(BilingualText("Impossibile leggere i corsi selezionati. Riprova.", "Couldn't read selected courses. Try again."))))
            endOperation(operationID)
            return .finished
        }
        guard !automaticScopes.isEmpty else {
            guard activeOperationID == operationID else { return .cancelled }
            BeepbarLog.sync.notice("Automatic synchronization skipped reason=no-enabled-courses")
            endOperation(operationID)
            return .finished
        }
        guard activeOperationID == operationID else { return .cancelled }
        BeepbarLog.sync.notice("Automatic synchronization started dataSaver=\(networkAccess == .dataSaver, privacy: .public)")
        // Put back if "Risparmio dati" stops the run midway, so the last result stays on screen.
        let stateBeforeRun = syncState
        setSyncState(.checking)
        let apiClient = self.apiClient
        let downloader = self.downloader
        let gate = operationGate
        let platformName = selectedSite.platformName
        let task = Task { [weak self] in
            do {
                guard let self else { return }
                let token = try await self.credentialVault.load(.nonInteractive)
                // A course stays enabled in the database after the user leaves it; only the courses
                // the account is still enrolled in are checked.
                let enrolled = Set(try await self.fetchEnrolledCourses(token: token).map(\.id))
                let targets = Self.automaticTargets(scopes: automaticScopes, enrolledCourseIDs: enrolled)
                let coordinator = try SyncCoordinator(rootID: rootID, rootURL: rootURL, database: database, gate: gate, apiClient: apiClient, downloader: downloader, platformName: platformName)
                await self.beginTransfer(operationID, automatic: true)
                let summary = try await coordinator.synchronize(targets: targets, token: token, mode: .automatic, networkAccess: networkAccess) { [weak self] progress in
                    await self?.publishProgress(progress)
                }
                await self.completeSync(operationID, summary: summary, automatic: true)
            } catch is CancellationError {
                self?.cancelledSync(operationID)
            } catch let error as WeBeepAPIError {
                guard let self else { return }
                if networkAccess == .dataSaver, await self.pausedMidRun(operationID, error: error, restoring: stateBeforeRun) { return }
                await self.failedSync(operationID, error: error, automatic: true)
            } catch let error as CredentialStorageError {
                await self?.handleCredentialStorageError(error)
                self?.endOperation(operationID)
            } catch is RootOperationGateError {
                self?.deferredAutomaticSync(operationID)
            } catch {
                await self?.failedSync(operationID, error: nil, automatic: true)
            }
        }
        syncTask = task
        await task.value
        return Task.isCancelled ? .cancelled : automaticOutcome
    }

    nonisolated static func automaticTargets(scopes: [SyncScope], enrolledCourseIDs: Set<Int64>) -> [SyncTarget] {
        scopes.filter { $0.enabled && enrolledCourseIDs.contains($0.courseID) }
            .map { SyncTarget(courseID: $0.courseID, localFolder: $0.localFolder) }
    }

    private func beginTransfer(_ operationID: UUID, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        await progressStore.reset(automatic: automatic)
        guard activeOperationID == operationID, !Task.isCancelled else { return }
        setSyncState(.syncing)
    }

    private func publishProgress(_ progress: SyncProgress) async {
        guard await progressStore.publish(progress) else { return }
        refreshMenuBarSnapshot()
    }

    private func completeSync(_ operationID: UUID, summary: SyncProgress, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        do {
            try await finishReconciliation(progress: summary, operationID: operationID)
        } catch {
            guard activeOperationID == operationID else { return }
            if Task.isCancelled { cancelledSync(operationID); return }
            reportPendingChoicesReadFailure()
            endOperation(operationID)
            return
        }
        guard activeOperationID == operationID else { return }
        guard !Task.isCancelled else { cancelledSync(operationID); return }
        if summary.failures == 0 { notificationCoordinator.clearFailure() }
        BeepbarLog.sync.notice("Synchronization completed automatic=\(automatic, privacy: .public) total=\(summary.total, privacy: .public) installed=\(summary.installed, privacy: .public) conflicts=\(summary.conflicts, privacy: .public) failures=\(summary.failures, privacy: .public)")
        configureBackgroundScheduler()
        let isCurrent = currentNotificationCheck()
        await finishOperationBeforeNotification(operationID) {
            if automatic {
                await notificationCoordinator.notifyAutomaticRun(installed: summary.installed, conflicts: conflicts, failures: summary.failures, isCurrent: isCurrent)
            } else {
                await notificationCoordinator.notifyManualRun(added: summary.added, isCurrent: isCurrent)
            }
        }
    }

    /// Captures notification validity separately from the active operation, which must end before
    /// delivery. Checking the captured account and folder also covers changes with no sync state write.
    private func currentNotificationCheck() -> @MainActor () -> Bool {
        let generation = notificationGeneration
        let site = selectedSite
        let root = rootID
        let folder = rootURL
        let credential = hasStoredCredential
        return { [weak self] in
            guard let self else { return false }
            return self.notificationGeneration == generation && self.selectedSite == site
                && self.rootID == root && self.rootURL == folder && self.hasStoredCredential == credential
        }
    }

    func finishOperationBeforeNotification(_ operationID: UUID, notify: () async -> Void) async {
        endOperation(operationID)
        await notify()
    }

    private func cancelledSync(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        BeepbarLog.sync.notice("Synchronization cancelled")
        setSyncState(.readyUnchecked)
        endOperation(operationID)
    }

    /// A manual sync found the folder busy with a rename, a module move or a conflict being resolved.
    private func busySync(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        setSyncState(.failed(.local(BilingualText("Un'altra operazione è in corso sulla cartella. Riprova tra poco.", "Another operation is running on the folder. Try again shortly."))))
        endOperation(operationID)
    }

    /// An automatic run that started with "Risparmio dati" on and then lost the network: macOS
    /// refuses a download on a hotspot or a Low Data Mode network as if the Mac were offline, which
    /// used to show a false "Connessione assente". The network is read again: if the Mac is now on
    /// a hotspot or a Low Data Mode network, the run ends as a pause (deferred, the earlier state
    /// back on screen as `stateAfterPauseMidway` decides, nothing reported as failed) and returns
    /// `true`. On an ordinary or no network it returns `false` and the failure is reported as
    /// usual, so a real outage still says so.
    private func pausedMidRun(_ operationID: UUID, error: WeBeepAPIError, restoring stateBeforeRun: AppSyncState) async -> Bool {
        guard SyncServiceFailure(error) == .connectivity, activeOperationID == operationID else { return false }
        let network = await automaticSyncEnvironment.currentNetwork()
        // The run may have been cancelled, or the app quit, while the network was read.
        guard activeOperationID == operationID else { return true }
        if Task.isCancelled { cancelledSync(operationID); return true }
        // An ordinary network now: the refusal was a real outage, reported as one.
        guard let pause = AutomaticSyncPolicy.dataSaverPause(for: network) else { return false }
        BeepbarLog.sync.notice("Automatic synchronization deferred midway reason=data-saver")
        automaticOutcome = .deferred
        setSyncState(Self.stateAfterPauseMidway(stateBeforeRun))
        // Turned off while the run was going: nothing to show, and the retry runs without limits.
        // Either way the refusal came from the run's limits, so it is not shown as an outage.
        dataSaverPause = dataSaverEnabled ? pause : nil
        endOperation(operationID)
        // Files handled before the refusal may have opened conflicts; show them like any run would.
        await reloadPendingChoices()
        return true
    }

    /// What a run stopped midway by "Risparmio dati" puts back on screen: the state from before
    /// the run (the last result, "Pronto", conflicts, an incomplete sync), which is still true.
    /// Except an error: the run got as far as downloading, so the site answered and the Mac was
    /// online, and showing that error again would report a problem that is gone, and hide the
    /// pause behind it. "Pronto" takes its place, with the pause shown over it.
    nonisolated static func stateAfterPauseMidway(_ stateBeforeRun: AppSyncState) -> AppSyncState {
        if case .failed = stateBeforeRun { return .readyUnchecked }
        return stateBeforeRun
    }

    private func deferredAutomaticSync(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        automaticOutcome = .deferred
        setSyncState(.readyUnchecked)
        endOperation(operationID)
    }

    private func failedSync(_ operationID: UUID, error: WeBeepAPIError?, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        BeepbarLog.sync.error("Synchronization failed automatic=\(automatic, privacy: .public) errorType=\(error.map { String(reflecting: type(of: $0)) } ?? "unknown", privacy: .public)")
        let issue: AutomaticNotificationIssue?
        if let error {
            issue = await handleServiceFailure(error, automatic: automatic)
        } else {
            setSyncState(.failed(.partialSync))
            issue = automatic ? .partialSync : nil
        }
        let isCurrent = currentNotificationCheck()
        await finishOperationBeforeNotification(operationID) {
            if let issue { await notificationCoordinator.notify(issue: issue, isCurrent: isCurrent) }
        }
    }

    private func handleServiceFailure(_ error: WeBeepAPIError, automatic: Bool) async -> AutomaticNotificationIssue? {
        switch SyncServiceFailure(error) {
        case .authenticationExpired:
            await expireCredential()
            return automatic ? .authenticationExpired : nil
        case .connectivity:
            setSyncState(.failed(.connectivity))
            return nil
        case .serviceUnavailable:
            setSyncState(.failed(.serviceUnavailable))
            return automatic ? .serviceUnavailable : nil
        case .incompatibleResponse:
            setSyncState(.failed(.incompatibleResponse))
            return automatic ? .incompatibleResponse : nil
        }
    }

    private func expireCredential() async {
        await credentialVault.invalidate()
        operationDefaults.set(true, forKey: Self.credentialExpiredKey)
        accountState = .expired
        setSyncState(.failed(.authenticationExpired))
        configureBackgroundScheduler()
    }

    private func handleCredentialStorageError(_ error: CredentialStorageError) async {
        await credentialVault.invalidate()
        switch error {
        case .absent, .corrupt:
            hasStoredCredential = false
            accountState = .notConnected
            setSyncState(.loginRequired)
        case .write:
            setSyncState(.failed(.credentialUnavailable))
        }
        configureBackgroundScheduler()
    }

    private func endOperation(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        syncTask = nil
    }

}

private struct BackgroundScheduleConfiguration: Equatable {
    let enabled: Bool
    let interval: Int
    let connected: Bool
    let rootConfigured: Bool
    let enabledCourseCount: Int
    let recoveryBlocked: Bool
}

@MainActor final class SyncProgressStore: ObservableObject {
    @Published private(set) var progress = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
    private let relay = SyncProgressRelay()

    func reset(automatic: Bool) async {
        await relay.reset(interval: automatic ? .seconds(1) : .milliseconds(200))
        progress = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
    }
    nonisolated func publish(_ value: SyncProgress) async -> Bool {
        guard let update = await relay.next(value) else { return false }
        await receive(update)
        return true
    }

    private func receive(_ update: SyncProgress) {
        progress = update
    }
}

private actor SyncProgressRelay {
    private let clock = ContinuousClock()
    private var throttle = SyncProgressThrottle(minimumInterval: .milliseconds(200))

    func reset(interval: Duration) {
        throttle = SyncProgressThrottle(minimumInterval: interval)
    }

    func next(_ progress: SyncProgress) -> SyncProgress? {
        throttle.accept(progress, now: clock.now)
    }
}

private actor BootstrapService {
    struct Result: Sendable {
        let database: SyncDatabase
        let recoveryBlocked: Bool
        let credential: CredentialStatus
    }

    enum CredentialStatus: Sendable {
        case present
        case absent
        case unavailable(CredentialStorageError)
    }

    func prepare(databaseDirectory: URL, rootURL: URL?, rootID: UUID?, gate: RootOperationGate, credentialVault: CredentialVault) async throws -> Result {
        let trace = PerformanceTrace.shared.begin("bootstrap.databaseRecovery", category: .bootstrap)
        defer { PerformanceTrace.shared.end("bootstrap.databaseRecovery", category: .bootstrap, state: trace) }
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: databaseDirectory.appendingPathComponent("sync.sqlite"))
        let credential = try credentialStatus()
        guard let rootURL, let rootID else { return Result(database: database, recoveryBlocked: false, credential: credential) }
        let blocked = try await recoveryBlocked(rootURL: rootURL, rootID: rootID, database: database, gate: gate)
        return Result(database: database, recoveryBlocked: blocked, credential: credential)
    }

    /// Runs the same recovery as `prepare` on an already-open database, under the `.recovering` lease.
    func retryRecovery(rootURL: URL, rootID: UUID, database: SyncDatabase, gate: RootOperationGate) async throws -> Result {
        let credential = try credentialStatus()
        let blocked = try await recoveryBlocked(rootURL: rootURL, rootID: rootID, database: database, gate: gate)
        return Result(database: database, recoveryBlocked: blocked, credential: credential)
    }

    private func credentialStatus() throws -> CredentialStatus {
        do {
            return try FileTokenStore.containsCredential() ? .present : .absent
        } catch let error as CredentialStorageError {
            return .unavailable(error)
        }
    }

    private func recoveryBlocked(rootURL: URL, rootID: UUID, database: SyncDatabase, gate: RootOperationGate) async throws -> Bool {
        try await database.registerRoot(id: rootID, canonicalPath: rootURL.path)
        let report = try await gate.withLease(.recovering) {
            try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: try FileStore(root: rootURL)).recover()
        }
        return !report.unresolved.isEmpty
    }
}

enum LoginWindowError: Error { case cancelled }

enum AutomaticSyncOutcome: Equatable {
    case finished, deferred, cancelled

    var diagnosticName: String {
        switch self {
        case .finished: "finished"
        case .deferred: "deferred"
        case .cancelled: "cancelled"
        }
    }

    var isDeferred: Bool {
        if case .deferred = self { true } else { false }
    }

    var schedulerResult: NSBackgroundActivityScheduler.Result {
        switch self {
        case .finished: .finished
        case .deferred: .deferred
        case .cancelled: .finished
        }
    }
}

@MainActor final class LoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private enum Phase { case signingIn, launchingMobile, finished }
    private static let maximumAutomaticRetries = 2
    private let site: MoodleSite
    private var phase: Phase = .signingIn
    private var completion: ((Result<URL, LoginWindowError>) -> Void)?
    private let webView: WKWebView
    private let retryButton: NSButton
    private let waitingOverlay: NSView
    private var automaticRetriesRemaining = LoginWindowController.maximumAutomaticRetries

    init(site: MoodleSite, completion: @escaping (Result<URL, LoginWindowError>) -> Void) {
        self.site = site
        self.completion = completion
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        retryButton = NSButton(title: tr("Ricarica", "Reload"), target: nil, action: nil)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded

        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .regular
        spinner.startAnimation(nil); spinner.translatesAutoresizingMaskIntoConstraints = false
        let waitingLabel = NSTextField(wrappingLabelWithString: tr("In attesa di risposta da \(site.displayName), può richiedere qualche secondo.\nSe il caricamento non va a buon fine, chiudi e riprova, oppure premi Ricarica.", "Waiting for \(site.displayName) to respond, this can take a few seconds.\nIf loading fails, close and try again, or press Reload."))
        waitingLabel.alignment = .center; waitingLabel.textColor = .secondaryLabelColor
        waitingLabel.translatesAutoresizingMaskIntoConstraints = false
        let waitingStack = NSStackView(views: [spinner, waitingLabel])
        waitingStack.orientation = .vertical; waitingStack.alignment = .centerX; waitingStack.spacing = 10
        waitingStack.translatesAutoresizingMaskIntoConstraints = false
        waitingOverlay = NSView()
        waitingOverlay.addSubview(waitingStack)
        NSLayoutConstraint.activate([
            waitingStack.centerXAnchor.constraint(equalTo: waitingOverlay.centerXAnchor),
            waitingStack.centerYAnchor.constraint(equalTo: waitingOverlay.centerYAnchor),
            waitingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])

        let container = NSView()
        container.addSubview(webView); container.addSubview(waitingOverlay); container.addSubview(retryButton)
        waitingOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            waitingOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            waitingOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            waitingOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            waitingOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            retryButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            retryButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Accesso \(site.displayName)", "Sign in to \(site.displayName)"); window.contentView = container
        super.init(window: window); window.delegate = self; webView.navigationDelegate = self; webView.uiDelegate = self
        retryButton.target = self; retryButton.action = #selector(retryTapped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Without this, an accessory (menu-bar-only) app can leave the window visible but not
        // key: it draws on screen but doesn't actually own keyboard focus, so the WebView's
        // fields silently reject typing and pasting.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: site.loginURL))
    }

    @objc private func retryTapped() {
        automaticRetriesRemaining = Self.maximumAutomaticRetries
        phase = .signingIn
        waitingOverlay.isHidden = false
        webView.load(URLRequest(url: site.loginURL))
    }

    func windowWillClose(_ notification: Notification) { finish(.failure(.cancelled)) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        waitingOverlay.isHidden = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retryAutomaticallyOrGiveUp(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retryAutomaticallyOrGiveUp(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        automaticRetriesRemaining = Self.maximumAutomaticRetries
        waitingOverlay.isHidden = true
    }

    // A first navigation attempt can occasionally fail outright (no network yet, DNS hiccup,
    // etc), leaving a blank window with no feedback. Retrying automatically (plus always offering
    // a one-click "Ricarica") means the user never has to close and reopen the whole window for
    // that.
    //
    // Only ever retry on a genuine network failure (NSURLErrorDomain). decidePolicyFor below
    // intentionally cancels navigations mid-flow — once to intercept the moodlemobile:// scheme,
    // once to redirect into launch.php — and WKWebView reports each of those as a navigation
    // "failure" too (WKErrorDomain, WKErrorFrameLoadInterruptedByPolicyChange). Retrying on those
    // as well would restart the login from scratch every time it was about to succeed, which is
    // exactly the infinite-reset loop this shipped with until caught.
    private func retryAutomaticallyOrGiveUp(_ error: Error) {
        guard phase != .finished else { return }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain, nsError.code != NSURLErrorCancelled else { return }
        guard automaticRetriesRemaining > 0 else { return }
        automaticRetriesRemaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.phase != .finished else { return }
            self.phase = .signingIn
            self.webView.load(URLRequest(url: self.site.loginURL))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "moodlemobile" {
            decisionHandler(.cancel); guard phase == .launchingMobile else { return }; webView.stopLoading(); finish(.success(url)); return
        }
        guard url.scheme == "https" else { decisionHandler(.cancel); return }
        if phase == .signingIn, site.isAuthenticatedLandingURL(url) {
            phase = .launchingMobile; decisionHandler(.cancel)
            webView.load(URLRequest(url: site.mobileLaunchURL)); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url, url.scheme == "https" else { return nil }
        webView.load(action.request); return nil
    }

    private func finish(_ result: Result<URL, LoginWindowError>) {
        guard phase != .finished else { return }; phase = .finished; webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        let completion = completion; self.completion = nil; completion?(result); window?.close()
    }
}

enum CredentialStorageError: Error, Sendable, Equatable {
    case write
    case absent
    case corrupt
}
