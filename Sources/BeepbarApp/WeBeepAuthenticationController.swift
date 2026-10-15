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

struct SyncCompletionSummary: Codable, Equatable, Sendable {
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

/// A sync's new successful result with its JSON, encoded off the main actor before it is published
/// (R01, #109). Encoding 15,000 file details takes about 19 ms on an M5, more than a frame, and
/// used to run on the main actor at the end of the sync. Publishing and saving still happen
/// together, in one main-actor turn (`setSyncState(synced:)`), so no published result ever waits
/// to be saved and no write can land after a newer one. Only `encode(_:)` builds it, so the bytes
/// always belong to `summary`.
struct EncodedSyncSummary: Sendable {
    let summary: SyncCompletionSummary
    /// nil when encoding failed. As before R01, the time of the sync is still saved and the
    /// previous summary is left in place; nothing is encoded again on the main actor.
    let data: Data?
#if DEBUG
    /// Where the encode ran; `SyncFinalizationTests` proves it is never the main thread.
    let encodedOnMainThread: Bool
#endif

    private init(summary: SyncCompletionSummary, data: Data?, encodedOnMainThread: Bool) {
        self.summary = summary
        self.data = data
#if DEBUG
        self.encodedOnMainThread = encodedOnMainThread
#endif
    }

    /// Encodes on a detached task, never on the caller's actor. Today a nonisolated async function
    /// already leaves the main actor, but under `nonisolated(nonsending)`, the default that
    /// Swift's approachable-concurrency setting turns on, it would run on its caller's: the
    /// detached task keeps the encode off the main actor either way. It keeps the sync's own
    /// priority, so an automatic sync in the background does not encode at user-initiated
    /// priority. Not interruptible: a sync cancelled meanwhile waits for it, about 20 ms at 15,000
    /// details, and then drops the result at its own guard.
    static func encode(_ summary: SyncCompletionSummary) async -> EncodedSyncSummary {
        await Task.detached(priority: Task.currentPriority) { encodeNow(summary) }.value
    }

    /// Synchronous, so it can tell which thread it runs on.
    private static func encodeNow(_ summary: SyncCompletionSummary) -> EncodedSyncSummary {
        EncodedSyncSummary(summary: summary, data: try? JSONEncoder().encode(summary), encodedOnMainThread: Thread.isMainThread)
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
    /// Header of the recordings section ("Registrazioni"); unused while `recordingLines` is empty.
    let recordingsTitle: String
    /// One line per synced course with a known watch summary ("Analisi 2 — 12/30 · ~14 h"), at
    /// most `WeBeepAuthenticationController.maxRecordingMenuLines`, already in the current
    /// language. Empty means the menu has no recordings section at all.
    let recordingLines: [RecordingMenuLine]
}

/// What a click on a course's recordings line in the menu bar carries to the main actor: who,
/// which course, which archive key, and nothing else. The lecture itself is deliberately not in
/// it: the main actor re-resolves the course's *current* next lecture when the click arrives
/// (`WeBeepAuthenticationController.playNextRecording`), so a click on a menu drawn before a
/// checkpoint plays what the student is missing now. A plain `Sendable` value, because it is the
/// item's `representedObject` and is read by the `nonisolated` menu action, which must touch no
/// main-actor state (issue #30).
struct RecordingMenuTarget: Sendable, Equatable {
    /// The WeBeep account (`recordingsOwnerUserID`) the line was drawn for: a click on a menu
    /// drawn for another account is ignored.
    let owner: Int
    /// The WeBeep course the line stands for, which must still be synced when the click arrives.
    let courseID: Int64
    /// The archive key whose summary's `next` is played.
    let key: RecmanCourseKey
}

/// One recordings line as the menu draws it, in one language (`recordingMenuSection`).
/// `target` is nil for a line with nothing to play (every lecture done, or no known next
/// lecture): such a line stays grey and has no action.
struct RecordingMenuLine: Sendable, Equatable {
    let title: String
    /// "Riproduci: «Lezione 3»", only on a line with a target.
    let toolTip: String?
    let target: RecordingMenuTarget?
}

/// One recordings line in both languages, as `WeBeepAuthenticationController` keeps it between
/// rebuilds (a language switch needs no rebuild). `hint` and `target` are both set or both nil.
struct RecordingMenuEntry: Equatable {
    let text: BilingualText
    let hint: BilingualText?
    let target: RecordingMenuTarget?
}

/// How one materials run ended, named after the app's own code paths, so each path records what
/// happened and the mapping to `RecordingsMaterialsOutcome` stays one pure, table-tested function
/// (`WeBeepAuthenticationController.recordingsOutcome(for:)`). A run that never ended for its own
/// operation (superseded, never started) records nothing at all: there is deliberately no case
/// that a forgotten path could fall into by default.
enum MaterialsRunEnd: Equatable, Sendable {
    /// `completeSync` finished and published its result.
    case completed(conflicts: Int, failures: Int)
    /// `completeSync`: `finishReconciliation` threw (the pending choices couldn't be read).
    case pendingChoicesUnreadable
    /// `cancelledSync`, from any path ("Annulla", a cancelled task, quit).
    case cancelled
    /// `failedSync` with a WeBeep error.
    case serviceFailure(WeBeepAPIError)
    /// A local failure: `failedSync(error: nil)`, `busySync`, the enabled scopes unreadable.
    case localFailure
    /// `pausedMidRun`: Data Saver stopped an automatic run midway.
    case pausedMidRun(DataSaverPause)
    /// `runAutomaticSync`: `AutomaticSyncPolicy.decision` held the run back.
    case notRun(AutomaticSyncDecision)
    /// `runAutomaticSync`: the schedule was rebuilt while the network was read.
    case scheduleChanged
    /// Nothing to sync with: no root or database, no enabled course, nothing selected, no folder.
    case unconfigured
    /// `deferredAutomaticSync`: the folder was busy (`RootOperationGateError`) for an automatic run.
    case deferredWhileBusy
    /// `handleCredentialStorageError`, from a manual or an automatic run.
    case credentialUnavailable
    /// Superseded (sign-out, site or folder change mid-run) or never started (another operation
    /// was active): nothing ended for this operation.
    case superseded
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
    // `setLanguage(_:)` calls it since every label depends on `AppLanguage.current`. The
    // recordings lines (`recordingMenuLines`) are fed by courses, lastRunCourses (stands in for
    // `courses` while it is empty), enabledCourseIDs,
    // courseFolders, watchSummaries and siteInfo (the account is the `owner` of each line's click
    // target, so a menu drawn for one account never plays for another), whose `didSet` calls
    // `recordingMenuInputsChanged()`, which rebuilds the lines (text, tooltip and click target)
    // and then calls `refreshMenuBarSnapshot()`. If you make
    // those computed properties depend on anything else, add a matching
    // `didSet { refreshMenuBarSnapshot() }` to that property too, or the menu bar will silently
    // go stale instead of crashing loudly.
    private(set) nonisolated(unsafe) var menuBarSnapshot = MenuBarSnapshot(title: "", detail: "", actionTitle: "", openTitle: "", quitTitle: "", recordingsTitle: "", recordingLines: [])
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
        didSet {
            defaultCourseFolders = Self.defaultFolders(for: courses, saved: courseFolders)
            recordingMenuInputsChanged()
        }
    }
    /// Where `courses` comes from (#98): `.saved` while the window shows the list saved at an
    /// earlier launch and Moodle has not confirmed it in this one, `.current` once it has. Every
    /// assignment of `courses` that changes its origin sets this in the same main-actor turn, so
    /// the label under "Corsi" never describes another list. A sync asks Moodle for the list
    /// first unless this is `.current`: saved enrollments never decide what is synced.
    @Published private(set) var courseListFreshness: CourseListFreshness = .unknown
    /// The course list saved for the next launch (`course-list.json` next to `sync.sqlite`). Tests
    /// and previews point it at a throwaway folder, never at the installed app's.
    private let courseListStore: CourseListSnapshotStore
    /// Bumped whenever the account the course list belongs to may change: sign-out, another
    /// university, a new sign-in, the stored credential gone. A network refresh, a restore or a
    /// save that began under an earlier value belongs to someone else and is dropped, and the
    /// store refuses saves from retired epochs (#98).
    private var courseListEpoch = 0
    /// The epoch whose saved list was already read, so reopening the window doesn't read the
    /// file again when the first read found nothing to show.
    private var courseListRestoreEpoch: Int?
    /// A course list load the window wants that has not started yet (#98): from the moment the
    /// window opens until the load starts (`isLoadingCourses` takes over in the same turn), and
    /// while a running sync holds it back (`endOperation` starts it). The window shows the
    /// loading state meanwhile instead of "no courses", or "refreshing" over a saved list.
    /// Cleared when nothing will be loaded (signed out), when the list arrives, and when the
    /// window closes, so a closed window never causes a request (`windowClosed()`).
    @Published private(set) var isPreparingCourseList = false
    /// Bumped when the configuration window closes, so a window-open refresh still waiting for
    /// the bootstrap or the saved list knows its window is gone and loads nothing (#98).
    private var windowGeneration = 0
    /// True once the launch bootstrap has finished (always, in a test controller): until then the
    /// account isn't known, so an opening window shows the loading state, not a sign-in prompt.
    private var hasBootstrapped = false
    /// The saved list's reads, writes and deletions, chained so each starts after the previous one
    /// ended (#98). Actor calls made from separate tasks carry no ordering promise: without the
    /// chain the save of a new sign-in could reach the store before the deletion that sign-in
    /// asked for, and be wiped by it, or a restore's read could run after a later save.
    private var courseListIO: Task<Void, Never>?
    /// Whether the window shows the list saved at an earlier launch: its switches and renames are
    /// off until Moodle confirms it, so a saved list never records anything (#98).
    var isShowingSavedCourseList: Bool {
        if case .saved = courseListFreshness { return true }
        return false
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
    @Published private(set) var enabledCourseIDs: Set<Int64> {
        didSet {
            guard enabledCourseIDs != oldValue else { return }
            schedulerGeneration += 1
            dataSaverPause = nil
            configureBackgroundScheduler()
            // A deselected course leaves the menu; its summary stays in `watchSummaries`, so
            // selecting it again brings the line back without a request.
            recordingMenuInputsChanged()
        }
    }
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
    /// Frequenza changed, signed out, sign-in expired or renewed…), since each drops the retry.
    /// Selection changes also clear it and invalidate pending network checks without moving
    /// an eligible scheduler's deadline.
    @Published private(set) var dataSaverPause: DataSaverPause? {
        didSet { refreshMenuBarSnapshot() }
    }
    @Published private(set) var recoveryBlocked = false {
        didSet {
            refreshMenuBarSnapshot()
            if recoveryBlocked != oldValue { configureBackgroundScheduler() }
        }
    }
    @Published private(set) var courseFolders: [Int64: String] = [:] {
        didSet { if courseFolders != oldValue { recordingMenuInputsChanged() } }
    }
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
    private var siteInfo: WeBeepSiteInfo? {
        didSet {
            // Only a controller that already exists can hold another account's session; one
            // created later checks the saved session's owner when it reads it.
            guard siteInfo?.userID != oldValue?.userID else { return }
            // A recordings follow-up belongs to the account it started for (its owner namespace
            // and keys): another account, or none, stops it and publishes nothing.
            cancelRecordingsFollowUp()
            // The previous account's enrolled courses must not name the new account's menu lines.
            if oldValue != nil { lastRunCourses = [] }
            // The account is each recordings line's click owner (`RecordingMenuTarget.owner`):
            // rebuild the lines on every path below, even when `watchSummaries` ends up equal and
            // its own `didSet` stays silent, or the menu would keep the previous account as owner
            // and every click would be ignored (or, worse, the lines would outlive the account).
            defer { recordingMenuInputsChanged() }
            guard let userID = siteInfo?.userID else {
                // Signed out or another university: no account, so no account's numbers.
                watchSummaries = [:]
                return
            }
            // The previous account's places in lectures, watch summaries and email opt-out go with the account
            // (#148). Always, not only without a controller: one that exists but has no Polimi
            // session yet (`sessionOwner` nil) forgets nothing in `webBeepAccountChanged`, and
            // an earlier launch's copy for another account must not stay on disk. All the forgets
            // are cheap and idempotent (one settings read, a removal only for another owner).
            RecordingsController.forgetResumePoints(in: operationDefaults, notOwnedBy: userID)
            RecordingsController.forgetWatchSummary(in: operationDefaults, notOwnedBy: userID)
            RecordingsController.forgetEmailOptOut(in: operationDefaults, notOwnedBy: userID)
            recordingsStorage?.webBeepAccountChanged(to: userID)
            // After the forgets above, so a previous account's numbers can't be read back. Read
            // here, once per account, and never by creating the controller: the menu shows the
            // last known numbers without a request (lazy guarantee of `recordingsStorage`).
            let recordingsOn = (recordingsStorage?.isEnabled ?? RecordingsController.isSwitchedOn(in: operationDefaults))
                && selectedSite.university == .polimi
            watchSummaries = recordingsOn ? RecordingsController.storedWatchSummaries(in: operationDefaults, owner: userID) ?? [:] : [:]
        }
    }
    /// The last known watch summary of each Recordings course, for the menu bar. Seeded from the
    /// saved copy when the account becomes known (`siteInfo`), then replaced by each push of the
    /// controller (`onWatchSummaryChange`, wired in `makeRecordings`), whose pushes are always the
    /// whole picture: before its first push the controller holds `[:]` without that meaning
    /// "none", so this is never overwritten from the controller's state, only from its pushes.
    /// Cleared when the account goes; a push of `[:]` is a reset (turn-off, account change).
    /// A deselected course keeps its entry here and is only hidden by `recordingMenuLines`.
    ///
    /// `@Published` so the Recordings sidebar's orange marker (which reads it, not the Recordings
    /// controller's copy, empty until a listing loads) redraws on a commit and only then: it never
    /// changes on a playback tick. Assigned only when the value changes, except by the account
    /// handlers above. Everything observing `authentication` (every page, not only this sidebar)
    /// redraws when a saved summary changes: at a checkpoint, a completion or a listing change,
    /// never on ticks.
    @Published private(set) var watchSummaries: [RecmanCourseKey: CourseWatchSummary] = [:] {
        didSet { if watchSummaries != oldValue { recordingMenuInputsChanged() } }
    }

    /// Reads the saved summaries when the Recordings page opens with none in memory: the seed
    /// in `siteInfo.didSet` is empty when Recordings was switched on after the account became
    /// known. Cheap (one settings read, once per appearance), never creates the Recordings
    /// controller, and does nothing without an account or with Recordings off.
    func seedWatchSummariesIfNeeded() {
        guard watchSummaries.isEmpty, let userID = siteInfo?.userID, selectedSite.university == .polimi,
              recordingsStorage?.isEnabled ?? RecordingsController.isSwitchedOn(in: operationDefaults),
              let stored = RecordingsController.storedWatchSummaries(in: operationDefaults, owner: userID) else { return }
        watchSummaries = stored
    }

#if DEBUG
    /// Test seams for the sidebar tests: set what the page reads, as a commit or a rename would.
    func setWatchSummariesForTesting(_ summaries: [RecmanCourseKey: CourseWatchSummary]) { watchSummaries = summaries }
    func setCourseFoldersForTesting(_ folders: [Int64: String]) { courseFolders = folders }
#endif
    /// The enrolled courses the last automatic run fetched from WeBeep (`fetchEnrolledCourses`),
    /// memory only. An automatic run never sets `courses` (only the window and "Sincronizza ora"
    /// do), so in a launch where the window was never opened the menu's recordings lines and the
    /// recordings follow-up's keys come from here instead; while `courses` is loaded it wins and
    /// this changes nothing. Cleared with the account (`forgetCourseList`). Feeds the menu: its
    /// `didSet` calls `recordingMenuInputsChanged()` (invariant on `menuBarSnapshot`).
    private(set) var lastRunCourses: [RemoteCourseSummary] = [] {
        didSet { if lastRunCourses != oldValue { recordingMenuInputsChanged() } }
    }
    /// The menu's recordings lines in both languages, with their click targets, rebuilt only when
    /// `courses` (or `lastRunCourses`), `enabledCourseIDs`, `courseFolders`, `watchSummaries` or the
    /// account (`siteInfo`) change, so the frequent snapshot refreshes during a sync don't rerun the course-name
    /// regexes. Resolved to one language in `refreshMenuBarSnapshot()`, which is why a language
    /// switch needs no rebuild here.
    private(set) var recordingMenuLines: [RecordingMenuEntry] = []
    /// While above zero (`restoreScopes`) a change of the menu's inputs only marks the lines stale;
    /// the holder rebuilds once at the end.
    private var menuRebuildHolds = 0
    private var menuRebuildPending = false
#if DEBUG
    /// How many times the lines were actually recomputed (not held back): lets a test prove the
    /// rebuild is coalesced during `restoreScopes`.
    private(set) var menuRebuildCountForTesting = 0
#endif
    private var database: SyncDatabase?
    /// Created on first use (the window, a sign-out), so a launch with the window closed doesn't
    /// read anything for a feature that may be off.
    private var recordingsStorage: RecordingsController?
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
    private var backgroundScheduler: BackgroundActivityRegistration?
    /// Owns the real registration; tests replace it with a clock-backed registration, never macOS activity.
    private var scheduleBackgroundActivity: (TimeInterval, @escaping @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void) -> BackgroundActivityRegistration = { interval, callback in
        let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.tvaccari.beepbar.auto-sync")
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = interval * 0.5
        scheduler.qualityOfService = .utility
        scheduler.schedule(callback)
        return BackgroundActivityRegistration(invalidate: { scheduler.invalidate() })
    }
    private var bootstrapTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    /// The Recordings listings refresh that follows a sync run (owner decision 2026-10-12, see
    /// `RecordingsSyncPolicy`). Deliberately OUTSIDE `syncTask`: "Esci" and a quit from outside
    /// wait for `syncTask` (`prepareForTermination`), and a WebKit listing must never hold a quit
    /// (AGENTS.md, quit path). For the same reason `prepareForTermination` neither returns nor
    /// touches it: the process simply exits under it. It never calls `setSyncState`, never touches
    /// `activeOperationID` and never notifies a failure, so the menu and Home keep showing the
    /// materials result only. At most one runs: a sync ending while it runs merges into it.
    /// Cancelled with the identity it was started for (`cancelRecordingsFollowUp`).
    private var recordingsFollowUp: Task<Void, Never>?
    /// Identifies `recordingsFollowUp`, so a finishing task clears only itself.
    private var recordingsFollowUpID: UUID?
    /// Bumped by `cancelRecordingsFollowUp`: a follow-up that resumes under an older value belongs
    /// to an account, site or folder that is gone and publishes nothing.
    private var recordingsFollowUpGeneration = 0
    /// How each operation's materials run ended, recorded by its ending path while it is still
    /// the active operation and taken once by the tail that starts the follow-up. An operation
    /// with no entry was superseded: no follow-up (`MaterialsRunEnd.superseded`).
    /// Notification delivery can suspend after the active operation ends, allowing another run.
    private var materialsRunEnds: [UUID: (generation: Int, end: MaterialsRunEnd)] = [:]
    /// How the last recordings follow-up ended, memory only (for the "N nuove registrazioni"
    /// notification and the menu, package D). Nil until one ends, and again with the account.
    private(set) var lastRecordingsOutcome: RecordingsSyncOutcome?
    /// Refreshes the Recordings listings of `keys` for a sync follow-up; the Bool is `force`
    /// (ignore the 300 s freshness window: manual sync only). A seam so the integration is tested
    /// with a fake, without WebKit.
    /// Nil in production: the follow-up then calls `recordings.refreshForSync(keys, force:)`.
    /// Tests set it to a fake so no WebKit or Polimi request is involved.
    var recordingsRefresh: (@MainActor (Set<RecmanCourseKey>, Bool) async -> RecordingsSyncOutcome)?
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
        didSet { if rootID != oldValue { notificationGeneration += 1; conflictChoiceFeedback = nil } }
    }
    private var scheduledConfiguration: BackgroundScheduleConfiguration?
    /// Bumped on every real rebuild of the scheduler. Tells an automatic run whether the schedule
    /// that started it still exists: comparing configurations can't, since turning automatic sync
    /// off and on again rebuilds twice and ends on an equal configuration.
    private var schedulerGeneration = 0
    private var schedulerRegistrationGeneration = 0
#if DEBUG
    private var recordingsStoreForTesting: RecordingsSessionStore?
    private var recordingsBrowserForTesting: (@MainActor () -> RecmanBrowsing)?
    /// Set by a test before the first use of `recordings`; the real player is never built in tests.
    var recordingsPlayerForTesting: (@MainActor () -> RecordingPlaying)?
    /// Replaces opening the window on the Recordings page (`showRecordingsCourse`), so a test can
    /// see that it was asked for, and for which course (nil: the page as it was), without a
    /// window.
    var showRecordingsPageForTesting: (@MainActor (Int64?) -> Void)?
    private var beforeReconciliationStateForTesting: (@MainActor () async -> Void)?
    /// Whether the last sync result to be encoded was encoded on the main thread; nil until one
    /// is (R01, #109). Set by the pre-encode in `finishReconciliation` and by the inline
    /// `setSyncState(_:)` save, which always encodes on the main actor, so a completion path that
    /// goes back to the inline save shows up as `true`.
    private(set) var summaryEncodedOnMainThreadForTesting: Bool?
    private var beforeRestoredSummaryPublicationForTesting: (@MainActor () async -> Void)?
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
        // Resolved once here (a path lookup, no file is touched): the store calls it off the main
        // actor, where the preview flags can't be read.
        let courseListFolder = Self.courseListDirectory()
        courseListStore = CourseListSnapshotStore {
            guard let courseListFolder else { throw CocoaError(.fileNoSuchFile) }
            return courseListFolder
        }
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
            // Real Polimi course names ("058167 - NAME [2026-27]", one per line) can be passed in
            // BEEPBAR_PREVIEW_COURSES to try Recordings against the real archive: the mock names
            // carry no code or year, so they have no recordings.
            let previewNames = ProcessInfo.processInfo.arguments.contains("--watchlist-preview") ? WatchlistPreviewBrowser.courseNames.joined(separator: "\n") : (ProcessInfo.processInfo.environment["BEEPBAR_PREVIEW_COURSES"] ?? "")
            let recordingsCourses = previewNames
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.enumerated()
                .map { RemoteCourseSummary(id: Int64(1_000 + $0.offset), shortName: $0.element, displayName: $0.element, isVisible: true, startDate: nil, endDate: nil) }
            let mockCourses = recordingsCourses + (1...100).map { index in
                RemoteCourseSummary(id: Int64(index), shortName: String(format: "%06d", 58000 + index), displayName: "CORSO DI PROVA \(index) — MATERIALI E ATTIVITÀ", isVisible: true, startDate: nil, endDate: nil)
            }
            // With real courses, only they are synced, as in the user's own app: Recordings lists
            // synced courses only, and the mock ones would bury them.
            enabledCourseIDs = Set((recordingsCourses.isEmpty ? Array(mockCourses.prefix(64)) : recordingsCourses).map(\.id))
            courses = Self.orderedForDisplay(mockCourses, enabledCourseIDs: enabledCourseIDs)
            // Real courses keep the folder name the app would give them, so they're recognizable
            // on the Recordings page, which lists courses by folder.
            courseFolders = Dictionary(uniqueKeysWithValues: mockCourses.dropFirst(recordingsCourses.count).map { ($0.id, "Corso di prova \($0.id)") })
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
            defer { self?.hasBootstrapped = true }
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
    ///
    /// The Recordings session goes to `recordingsStore`, or to a throwaway folder: never to the
    /// real one, which a sign-out in any test would otherwise delete. The saved course list goes
    /// to `courseListStore`, or nowhere; a test that relaunches gives each controller a store of
    /// its own over the same folder, as two launches would have. `site` is Polimi unless a test
    /// needs another university from the first moment (Recordings exist only for Polimi).
    /// `language` sets the controller's own `language` only (see the init body).
    init(testRootURL: URL, database: SyncDatabase? = nil, rootID: UUID? = nil, notificationCenter: NotificationCenterClient = InertNotificationCenter(), fileOpener: ActivityFileOpening = InertFileOpener(), apiClient: WeBeepAPIClient? = nil, downloader: RemoteDownloader? = nil, credentialVault: CredentialVault? = nil, deleteCredential: (() throws -> Void)? = nil, defaults: UserDefaults? = nil, automaticSyncEnvironment: AutomaticSyncEnvironment = .fixed(), recordingsStore: RecordingsSessionStore? = nil, recordingsBrowser: (@MainActor () -> RecmanBrowsing)? = nil, courseListStore: CourseListSnapshotStore? = nil, site: MoodleSite = .site(id: nil), language: AppLanguage = .italian) {
        deleteCredentialForTesting = deleteCredential
        let throwawayRecordingsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("beepbar-recordings-test-\(UUID().uuidString)", isDirectory: true)
        recordingsStoreForTesting = recordingsStore ?? RecordingsSessionStore { throwawayRecordingsFolder }
        // Without a store of its own a test controller saves nothing anywhere: no folder is left
        // behind, and nothing reaches the installed app's file.
        self.courseListStore = courseListStore ?? CourseListSnapshotStore { throw CocoaError(.fileNoSuchFile) }
        recordingsBrowserForTesting = recordingsBrowser
        self.credentialVault = credentialVault ?? CredentialVault(read: FileTokenStore.load, write: FileTokenStore.save)
        self.fileOpener = fileOpener
        selectedSite = site
        hasStoredCredential = true
        let isolatedDefaults = defaults ?? Self.throwawayDefaults()
        testDefaults = isolatedDefaults
        notificationCoordinator = SyncNotificationCoordinator(defaults: isolatedDefaults, center: notificationCenter)
        notificationsEnabled = Self.storedNotificationsEnabled(in: isolatedDefaults)
        rootURL = testRootURL
        needsOnboarding = false
        // Only this controller's `language`, never `AppLanguage.current` (process-global, shared
        // by tests running in parallel); the menu bar's recordings section reads this one.
        self.language = language
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
        hasBootstrapped = true
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

    func setSyncStateForTesting(synced result: EncodedSyncSummary) {
        setSyncState(synced: result, rootID: rootID)
    }

    /// Stands for a list Moodle confirmed in this session, as every caller assumed before #98.
    func setCoursesForTesting(_ courses: [RemoteCourseSummary]) {
        self.courses = courses
        courseListFreshness = courses.isEmpty ? .unknown : .current
    }

    /// Waits for every read, save or deletion of the saved course list issued so far.
    func waitForCourseListWriteForTesting() async { await courseListIO?.value }

    /// The restore a window opening does before the network refresh, without that refresh.
    func restoreSavedCourseListForTesting() async { await restoreSavedCourseList() }

    /// The launch bootstrap finding no stored credential, for a test controller (which has none).
    func applyBootstrapWithoutCredentialForTesting(recoveryBlocked: Bool = false, corrupt: Bool = false) async {
        guard let database else { return }
        await applyBootstrap(BootstrapService.Result(database: database, recoveryBlocked: recoveryBlocked, credential: corrupt ? .unavailable(.corrupt) : .absent))
    }

    /// The launch bootstrap finding the stored credential, for a test controller.
    func applyBootstrapWithCredentialForTesting(recoveryBlocked: Bool = false) async {
        guard let database else { return }
        await applyBootstrap(BootstrapService.Result(database: database, recoveryBlocked: recoveryBlocked, credential: .present))
    }

    /// Makes everything that waits for the launch bootstrap wait for `task` instead.
    func holdBootstrapForTesting(_ task: Task<Void, Never>) { bootstrapTask = task }

    /// The folder handling after the open panel, with `url` as if picked there.
    func useRootForTesting(_ url: URL) async {
        let picked = url.standardizedFileURL
        await useRoot(picked: picked, resolved: picked.resolvingSymlinksInPath())
    }

    /// The account going away as `forgetCourseList()` sees it, at a moment a test chooses.
    func forgetCourseListForTesting() { forgetCourseList() }

    func setBackgroundSchedulerForTesting(_ register: @escaping (TimeInterval, @escaping @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void) -> BackgroundActivityRegistration) {
        scheduleBackgroundActivity = register
        registersBackgroundActivity = true
    }

    func setRecoveryBlockedForTesting(_ blocked: Bool) { recoveryBlocked = blocked }

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

    /// Starts `operationID`'s progress stream exactly as a sync does and returns the callback the
    /// coordinator would receive, so a test can drive it from off the main actor.
    func beginTransferForTesting(_ operationID: UUID, automatic: Bool) -> @Sendable (SyncProgress) async -> Void {
        progressSink(operationID, run: beginTransfer(operationID, automatic: automatic))
    }

    /// Completes `operationID` as a run that synced `syncedRootID`, by default the folder current at
    /// this call, as the real runs capture it before syncing (#167).
    func completeSyncForTesting(_ operationID: UUID, summary: SyncProgress, automatic: Bool = false, syncedRootID: UUID? = nil) async {
        await completeSync(operationID, rootID: syncedRootID ?? rootID, summary: summary, automatic: automatic)
    }

    func setBeforeReconciliationStateForTesting(_ action: @escaping @MainActor () async -> Void) {
        beforeReconciliationStateForTesting = action
    }

    @discardableResult func runAutomaticSyncForTesting() async -> AutomaticSyncOutcome { await runAutomaticSync() }

    /// Waits for the sync `synchronizeNow()` started, which it does not return.
    func waitForSyncForTesting() async { await syncTask?.value }

    /// The running recordings follow-up, nil when none runs.
    var recordingsFollowUpForTesting: Task<Void, Never>? { recordingsFollowUp }

    /// Ends `operationID` through `failedSync`, as a run that failed with `error` would.
    func failSyncForTesting(_ operationID: UUID, error: WeBeepAPIError?, automatic: Bool) async {
        await failedSync(operationID, error: error, automatic: automatic)
    }

    /// Starts the follow-up of `operationID` the way the manual tail does, and returns its task.
    @discardableResult
    func startFollowUpForTesting(_ operationID: UUID, trigger: RecordingsSyncTrigger) -> Task<Void, Never>? {
        followUpAfterRun(operationID, trigger: trigger)
    }

    /// Takes what `operationID`'s ending path recorded, as the follow-up's tail does.
    func takeRunEndForTesting(_ operationID: UUID) -> MaterialsRunEnd? { takeRunEnd(operationID) }

    var isMenuQuitInProgressForTesting: Bool { menuQuitInProgress }

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

    func setBeforeRestoredSummaryPublicationForTesting(_ action: @escaping @MainActor () async -> Void) { beforeRestoredSummaryPublicationForTesting = action }

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
        // Before the blocked-recovery return: a launch without a credential deletes the saved
        // course list whether or not a pending operation blocks recovery, as documented (#98).
        // The rest of the credential handling waits for recovery, as before.
        // An expired list is pruned at every launch with a credential, blocked recovery included:
        // no sync runs then, so nothing else would enforce the age limit.
        if Self.credentialIsGone(result.credential) { forgetCourseList() } else { pruneExpiredCourseList() }
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
            // No credential, so no account the saved list could belong to: an older BeepBar that
            // signed out, or a sign-out whose deletion never ran, must not leave it on disk (#98).
            // Deleted above, before the blocked-recovery return.
            await restorePersistedSyncState()
            configureBackgroundScheduler()
        case .unavailable(let error):
            await handleCredentialStorageError(error)
        }
    }

    /// Whether the launch found no usable credential: absent, or unreadable as absent or corrupt
    /// (what `handleCredentialStorageError` treats as signed out). A write error is not one.
    private nonisolated static func credentialIsGone(_ status: BootstrapService.CredentialStatus) -> Bool {
        switch status {
        case .present, .unavailable(.write): false
        case .absent, .unavailable(.absent), .unavailable(.corrupt): true
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

    /// The Recordings feature (Polimi lecture recordings), created on first use.
    var recordings: RecordingsController {
        if let recordingsStorage { return recordingsStorage }
        let controller = makeRecordings()
        recordingsStorage = controller
        return controller
    }

    /// The Recordings controller only if something already created it, for paths that must not
    /// create it just to tell it nothing is happening (the window closing).
    var recordingsIfCreated: RecordingsController? { recordingsStorage }

    /// Whether Recordings is on, read without creating its controller (daily telemetry asks once a
    /// day and must not build the feature just to report it is off).
    var recordingsEnabledWithoutCreating: Bool {
        if let recordingsStorage { return recordingsStorage.isEnabled }
        return RecordingsController.storedEnabled(in: operationDefaults, isAvailable: selectedSite.university == .polimi)
    }

    /// The WeBeep account the saved Polimi session is bound to; nil until the account is
    /// validated in this launch (`siteInfo`).
    var recordingsOwnerUserID: Int? {
#if DEBUG
        // A preview validates no account: a fixed id lets the switch and the session work.
        if Self.isUIPreview { return 1 }
#endif
        return siteInfo?.userID
    }

    private func makeRecordings() -> RecordingsController {
        var store = RecordingsSessionStore.standard
        var makeBrowser: @MainActor () -> RecmanBrowsing = { RecmanWebSession() }
        // The player fetches the course picture for Now Playing through `courseImage`, which
        // holds the token; the player never sees it.
        var makePlayer: @MainActor () -> RecordingPlaying = { [weak self] in
            RecordingPlayerController(artworkLoader: { [weak self] url in
                guard let self else { throw CancellationError() }
                return try await self.courseImage(url)
            })
        }
#if DEBUG
        if let recordingsPlayerForTesting { makePlayer = recordingsPlayerForTesting }
        if let recordingsStoreForTesting { store = recordingsStoreForTesting }
        if let recordingsBrowserForTesting { makeBrowser = recordingsBrowserForTesting }
#endif
#if DEBUG
        if Self.isUIPreview && ProcessInfo.processInfo.arguments.contains("--watchlist-preview") {
            makeBrowser = { WatchlistPreviewBrowser() }
            store = RecordingsSessionStore { FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-watchlist-preview-session", isDirectory: true) }
        }
#endif
        let controller = RecordingsController(
            makeBrowser: makeBrowser,
            store: store,
            defaults: operationDefaults,
            ownerUserID: { [weak self] in self?.recordingsOwnerUserID },
            isAvailable: { [weak self] in self?.selectedSite.university == .polimi },
            makePlayer: makePlayer,
            courses: { [weak self] in self?.courses ?? [] },
            fetchProfileEmail: { [weak self] in await self?.profileEmail() }
        )
        // Pushed from the main actor (never read from the menu's AppKit callback). Each push is
        // the controller's whole picture, `[:]` included: that one is a reset.
        controller.onWatchSummaryChange = { [weak self] summaries in self?.watchSummaries = summaries }
        // A menu Play that failed with no Recordings page on screen (session lapsed, lecture
        // can't be opened): show that course's page, where the message or "Accedi con Polimi"
        // explains it. Called on the main actor, never for a window Play.
        controller.onMenuPlayNeedsPage = { [weak self] key in self?.showRecordingsCourse(for: key) }
#if DEBUG
        if Self.isUIPreview && ProcessInfo.processInfo.arguments.contains("--watchlist-preview") {
            if controllerDefaultsHaveNoWatchlist {
                for course in courses.prefix(2) {
                    if let key = RecmanCourseKey(course: course), let lesson = WatchlistPreviewBrowser.lessons(for: key).first {
                        controller.toggleWatchlist(lesson, courseName: RecordingsPresentation.courseName(course))
                    }
                }
                controller.selectDestination(.watchlist)
            }
            controller.signIn()
        }
#endif
        return controller
    }

    /// The address on the WeBeep profile, used for the Webex sign-in without a confirmation step
    /// (#148, product decision 2026-10-11; `RecordingsController.learnEmail`, from the Settings
    /// row or the first Play). Asked only when the site lists the function for this token. Every
    /// failure (no function, no token, offline, an odd answer) is nil: the student then types the address, and
    /// nothing reaches the sync status or the log. The address is personal data and is never
    /// logged here.
    /// The bytes of a WeBeep course picture (`RemoteCourseSummary.imageURL`) for the artwork of
    /// the lecture playing in Now Playing (issue #148 follow-up). Runs on the main actor only to
    /// read the client, the account and the token; the request itself is `fetchCourseImage`'s
    /// (bounded, no redirects, image only, token never logged). A picture that arrives after the
    /// account or the site changed is refused: it belongs to the previous identity.
    private func courseImage(_ url: URL) async throws -> Data {
        let client = apiClient
        let userID = siteInfo?.userID
        let token = try await credentialVault.load(.nonInteractive)
        let data = try await client.fetchCourseImage(url, token: token)
        // The account clause is what `aCoursePictureArrivingAfterAnAccountChangeIsDropped` pins.
        // `apiClient === client` is a defensive duplicate for a site change: `selectSite` swaps
        // the client but also clears `siteInfo`, so `userID` already differs; it is kept for the
        // case where a future site switch keeps `siteInfo` (same user id on two sites).
        guard apiClient === client, siteInfo?.userID == userID else { throw CancellationError() }
        return data
    }

    private func profileEmail() async -> String? {
        guard let info = siteInfo, info.availableFunctions.contains(WeBeepAPIClient.ownEmailFunction) else { return nil }
        do {
            let token = try await credentialVault.load(.nonInteractive)
            let address = try await apiClient.fetchOwnEmail(userID: info.userID, token: token)
            // Another account may have signed in while WeBeep answered: its address is not ours to offer.
            return siteInfo?.userID == info.userID ? address : nil
        } catch {
            return nil
        }
    }

#if DEBUG
    /// The profile lookup Recordings uses, called directly so tests can check its own guards
    /// (the listed function, the account after the answer) apart from Recordings' epochs.
    func profileEmailForTesting() async -> String? { await profileEmail() }
    /// The course-picture fetch the player is given, called directly to test its identity guard.
    func courseImageForTesting(_ url: URL) async throws -> Data { try await courseImage(url) }

    private var controllerDefaultsHaveNoWatchlist: Bool {
        operationDefaults.data(forKey: RecordingsController.studyKey(owner: 1)) == nil
    }
#endif

    /// Forgets the stored token so another account, or another university, can be connected.
    /// The sync folder, its files and the course selection stay as they are; the Recordings
    /// feature is turned off and its Polimi session deleted, and so is the saved course list.
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
        forgetCourseList()
        courseLoadError = nil
        hasStoredCredential = false
        accountState = .notConnected
        setSyncState(recoveryBlocked ? .recoveryBlocked : .loginRequired)
        configureBackgroundScheduler()
        // Whether or not it was on in this launch: a session saved in an earlier one goes too.
        recordings.turnOff()
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
        // `language` mirrors `AppLanguage.current` (both set in `init` and `setLanguage`); reading
        // the property lets a test check an English menu without switching the process-global
        // language.
        let recordings = Self.recordingMenuSection(recordingMenuLines, language: language)
        menuBarSnapshot = MenuBarSnapshot(
            title: menuBarTitle,
            detail: menuBarDetail,
            actionTitle: menuBarActionTitle,
            openTitle: tr("Apri BeepBar", "Open BeepBar"),
            quitTitle: tr("Esci da BeepBar", "Quit BeepBar"),
            recordingsTitle: recordings.title,
            recordingLines: recordings.lines
        )
        let symbol = menuBarSymbol
        if symbol != lastMenuBarSymbol {
            lastMenuBarSymbol = symbol
            onMenuBarSymbolChange?(symbol)
        }
    }

    /// The most recordings lines the menu shows: past ten courses the menu would outgrow its
    /// purpose (a glance), and the window has them all.
    nonisolated static let maxRecordingMenuLines = 10

    /// Rebuilds `recordingMenuLines` from its inputs and refreshes the snapshot when they
    /// changed. Called from the `didSet` of `courses`, `lastRunCourses`, `enabledCourseIDs`, `courseFolders`,
    /// `watchSummaries` and `siteInfo` (see the invariant comment on `menuBarSnapshot`). Costs
    /// nothing when no summary is known (every launch without Recordings), since the pure builder
    /// returns before any course.
    private func recordingMenuInputsChanged() {
        if menuRebuildHolds > 0 { menuRebuildPending = true; return }
#if DEBUG
        menuRebuildCountForTesting += 1
#endif
        // `lastRunCourses` only while `courses` is empty: a window-less launch still gets its
        // lines from what the last automatic run fetched, and a loaded list changes nothing.
        let lines = Self.recordingMenuLines(courses: courses.isEmpty ? lastRunCourses : courses, enabledIDs: enabledCourseIDs, summaries: watchSummaries, owner: recordingsOwnerUserID, folders: courseFolders)
        guard lines != recordingMenuLines else { return }
        recordingMenuLines = lines
        refreshMenuBarSnapshot()
    }

    /// The menu's recordings lines: the synced courses (`enabledIDs`) in sidebar order (`courses`,
    /// as the Recordings page lists them) that have an archive key and a known summary, named as
    /// the Recordings page names them, at most `maxRecordingMenuLines`.
    /// - A course with no known summary is left out, never shown as "0/0" (nothing before a page
    ///   has loaded it once); so is one with `total == 0` (see `RecordingWatchProgress.menuLine`).
    /// - Two WeBeep courses with the same archive key (two sections of one course) show the same
    ///   recordings and the same summary: one line, the first course's. The Recordings page
    ///   (`RecordingsPresentation.syncedCourses`) still lists both rows, so either can be opened;
    ///   the menu is a glance, where the same numbers twice would read as two courses. The
    ///   difference between page and menu is intentional.
    /// - A line is clickable (has a `target` and a "Riproduci: «…»" hint) only when its summary
    ///   has a `next` lecture that `RecordingsController.validatedNext` accepts and the account
    ///   (`owner`) is known; otherwise it stays grey (every lecture done, nothing known to play,
    ///   or a stored `next` that couldn't be played anyway). The click re-checks all of it
    ///   (`menuPlayRecording`): the line only tells the student what a click would do.
    /// - The line's name is the course's renamed local folder (`folders`), else its name without
    ///   the part in parentheses at the end (`RecmanCourseSidebar.menuName`).
    nonisolated static func recordingMenuLines(courses: [RemoteCourseSummary], enabledIDs: Set<Int64>, summaries: [RecmanCourseKey: CourseWatchSummary], owner: Int?, folders: [Int64: String] = [:]) -> [RecordingMenuEntry] {
        guard !summaries.isEmpty, !enabledIDs.isEmpty else { return [] }
        var lines: [RecordingMenuEntry] = []
        var shown: Set<RecmanCourseKey> = []
        for course in courses where enabledIDs.contains(course.id) {
            guard let key = RecmanCourseKey(course: course), let summary = summaries[key], summary.total > 0,
                  shown.insert(key).inserted else { continue }
            let name = RecmanCourseSidebar.menuName(courseName: RecordingsPresentation.courseName(course), courseDisplayName: course.displayName, courseID: course.id, localFolderName: folders[course.id])
            let text = RecordingWatchProgress.menuLine(courseName: name, summary)
            if let owner, let next = summary.next, RecordingsController.validatedNext(next, for: key) {
                lines.append(RecordingMenuEntry(
                    text: text,
                    hint: recordingMenuHint(title: RecordingsPresentation.title(next)),
                    target: RecordingMenuTarget(owner: owner, courseID: course.id, key: key)
                ))
            } else {
                lines.append(RecordingMenuEntry(text: text, hint: nil, target: nil))
            }
            if lines.count == maxRecordingMenuLines { break }
        }
        return lines
    }

    /// The tooltip of a clickable recordings line: "Riproduci: «title»" / "Play: “title”". The
    /// archive's title can carry line breaks and runs of spaces, which a one-line tooltip would
    /// show as gaps or extra lines, so every run of whitespace becomes one space; an empty title
    /// (nothing left after that) gives just "Riproduci" / "Play" rather than empty quotes.
    nonisolated static func recordingMenuHint(title: String) -> BilingualText {
        let clean = title.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !clean.isEmpty else { return BilingualText("Riproduci", "Play") }
        return BilingualText("Riproduci: «\(clean)»", "Play: “\(clean)”")
    }

    /// The recordings section's header and lines in `language`. Takes the language explicitly
    /// (the app passes `AppLanguage.current`) so tests can check both without switching the
    /// process-global language; resolved at every snapshot refresh, never cached, so
    /// `setLanguage(_:)` rebuilds it (title and tooltip alike; the target has no text).
    nonisolated static func recordingMenuSection(_ lines: [RecordingMenuEntry], language: AppLanguage) -> (title: String, lines: [RecordingMenuLine]) {
        let pick = { (text: BilingualText) in language == .italian ? text.italian : text.english }
        return (pick(BilingualText("Registrazioni", "Recordings")), lines.map {
            RecordingMenuLine(title: pick($0.text), toolTip: $0.hint.map(pick), target: $0.target)
        })
    }

    // MARK: Menu bar Play

    /// A click on a course's recordings line, delivered on the main actor by
    /// `StatusItemController.dispatchRecordingClick` (after its `Task { @MainActor in … }` hop).
    /// Plays the course's current next lecture through the Play button's path, without opening
    /// the window. The click is a stale snapshot (the menu may have been drawn before a sign-out,
    /// an account change, a turn-off, a deselection or a checkpoint), so everything is re-checked
    /// here (`menuPlayRecording`); a click that no longer applies does nothing and, in particular,
    /// never creates the Recordings controller. Only an accepted click uses `recordings` (lazy:
    /// an explicit user action). When the controller can't play without the window (Recordings
    /// off for it, the Polimi session needs a sign-in), the course's Recordings page opens,
    /// where the usual message or "Accedi con Polimi" shows.
    func playNextRecording(_ target: RecordingMenuTarget) {
        let switchOn = recordingsStorage?.isEnabled ?? RecordingsController.isSwitchedOn(in: operationDefaults)
        guard let recording = Self.menuPlayRecording(target: target, owner: recordingsOwnerUserID, isPolimi: selectedSite.university == .polimi,
                                                     switchOn: switchOn, enabledIDs: enabledCourseIDs, summaries: watchSummaries) else {
            BeepbarLog.lifecycle.notice("Menu recording click ignored: no longer applies")
            return
        }
        BeepbarLog.lifecycle.notice("Menu recording click: playing the course's next lecture")
        if !startMenuPlay(recording, owner: target.owner, courseID: target.courseID) {
            showRecordingsCourse(target.courseID)
        }
    }

    /// The lecture a menu click on `target` may play, or nil when the click no longer applies:
    /// - another account than the one the line was drawn for (`owner`), or none;
    /// - not Polimi, or Recordings switched off;
    /// - the course no longer synced;
    /// - no known next lecture for the key (all done since, or a reset);
    /// - a stored next that fails `RecordingsController.validatedNext`: it was read back from
    ///   UserDefaults and is untrusted (another course or year, a foreign link).
    /// Pure, so each rejection is tested without a controller or a window.
    nonisolated static func menuPlayRecording(target: RecordingMenuTarget, owner: Int?, isPolimi: Bool, switchOn: Bool,
                                              enabledIDs: Set<Int64>, summaries: [RecmanCourseKey: CourseWatchSummary]) -> RecmanRecording? {
        guard let owner, owner == target.owner, isPolimi, switchOn, enabledIDs.contains(target.courseID),
              let next = summaries[target.key]?.next, RecordingsController.validatedNext(next, for: target.key) else { return nil }
        return next
    }

    /// The single call into the Recordings controller's menu Play, so the controller's signature
    /// can change in one place. `owner` is the account the click was made for; the controller
    /// ignores (true, nothing happens) a click whose owner isn't its own resume owner, and
    /// answers false when it can't play without the window (off, sign-in needed or running, an
    /// invalid stored next): the caller then shows the course's page.
    private func startMenuPlay(_ recording: RecmanRecording, owner: Int, courseID: Int64) -> Bool {
        recordings.playFromMenu(recording, owner: owner, courseID: courseID)
    }

    /// Opens BeepBar on the Recordings page of WeBeep course `courseID`: the page a menu Play
    /// needs when it can't go on without the window (sign-in, a lecture that can't be opened).
    private func showRecordingsCourse(_ courseID: Int64) {
        recordings.selectDestination(.course(courseID))
#if DEBUG
        if let showRecordingsPageForTesting { showRecordingsPageForTesting(courseID); return }
#endif
        ConfigurationWindowController.shared.show(self, page: .recordings)
    }

    /// `onMenuPlayNeedsPage` hands over an archive key: the synced course with that key that the
    /// menu showed (the first in sidebar order, as `recordingMenuLines` picks it), else any course
    /// with it; with none (the course left the list meanwhile) the Recordings page opens as it was.
    private func showRecordingsCourse(for key: RecmanCourseKey) {
        let matching = courses.filter { RecmanCourseKey(course: $0) == key }
        if let course = matching.first(where: { enabledCourseIDs.contains($0.id) }) ?? matching.first {
            showRecordingsCourse(course.id)
            return
        }
#if DEBUG
        if let showRecordingsPageForTesting { showRecordingsPageForTesting(nil); return }
#endif
        ConfigurationWindowController.shared.show(self, page: .recordings)
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

    /// Publishing restored state must not encode and persist a result that is already saved.
    private func publishSyncState(_ newState: AppSyncState) {
        let previousSummary = lastSyncSummary
        syncState = newState
        if lastSyncSummary != previousSummary { activityItemProblems = [:] }
        status = newState.detail
    }

    /// New successful results and explicit legacy migration retain their durable timestamp and detail.
    /// Encodes on the main actor, which only small summaries may do (legacy migration, previews):
    /// a sync's new result goes through `setSyncState(synced:)`, already encoded (R01, #109).
    private func setSyncState(_ newState: AppSyncState) {
        publishSyncState(newState)
        if case .synced(let summary) = newState, rootID != nil {
#if DEBUG
            summaryEncodedOnMainThreadForTesting = true
#endif
            saveSuccessfulResult(summary, data: try? JSONEncoder().encode(summary), rootID: rootID)
        }
    }

    /// Publishes a sync's new successful result and saves it in the same main-actor turn, with the
    /// bytes encoded off the main actor (R01, #109). Keep both in this one synchronous function:
    /// saving later, from a task, would let a quit or a newer result find the shown result unsaved,
    /// or let an older write land last. `rootID` is the folder the sync ran on, never read from
    /// `self` here: saved under the folder current at completion, a result could land under a
    /// folder picked mid-sync, which would then show the old folder's result (#167).
    private func setSyncState(synced result: EncodedSyncSummary, rootID: UUID?) {
        publishSyncState(.synced(result.summary))
        saveSuccessfulResult(result.summary, data: result.data, rootID: rootID)
    }

    /// Both keys of a successful result, the time first, as releases before R01 wrote them, under
    /// the folder the caller names (#167).
    private func saveSuccessfulResult(_ summary: SyncCompletionSummary, data: Data?, rootID: UUID?) {
        guard let rootID else { return }
        operationDefaults.set(summary.completedAt.timeIntervalSince1970, forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
        if let data {
            operationDefaults.set(data, forKey: Self.lastSuccessfulSummaryKey + rootID.uuidString)
        }
    }

    private func restorePersistedSyncState() async {
        guard !Self.isUIPreview else { return }
        guard !recoveryBlocked else { setSyncState(.recoveryBlocked); return }
        guard accountState != .expired else { setSyncState(.failed(.authenticationExpired)); return }
        guard hasStoredCredential else { setSyncState(.loginRequired); return }
        guard rootURL != nil, let rootID else { setSyncState(.needsFolder); return }
        let generation = notificationGeneration
        let expectedSite = selectedSite
        let expectedURL = rootURL
        let open: [ConflictRecord]
        do {
            let pending = try await loadPendingChoices()
            guard self.rootID == rootID, selectedSite == expectedSite, rootURL == expectedURL, notificationGeneration == generation, hasStoredCredential, accountState != .expired, !recoveryBlocked, !isSyncActive, !Task.isCancelled else { return }
            open = pending.conflicts
            conflicts = open
            remoteChanges = pending.changes
        } catch {
            guard self.rootID == rootID, selectedSite == expectedSite, rootURL == expectedURL, notificationGeneration == generation, hasStoredCredential, accountState != .expired, !recoveryBlocked, !isSyncActive, !Task.isCancelled else { return }
            reportPendingChoicesReadFailure()
            return
        }
        if !open.isEmpty { setSyncState(.conflicts(open.count, nil)); return }
        if let data = operationDefaults.data(forKey: Self.lastSuccessfulSummaryKey + rootID.uuidString) {
            // A large Activity summary can take more than a frame to decode. A detached task
            // keeps that CPU work off the UI; its result remains subject to the captured identity.
            let summary = await Task.detached(priority: .userInitiated) {
                try? JSONDecoder().decode(SyncCompletionSummary.self, from: data)
            }.value
#if DEBUG
            await beforeRestoredSummaryPublicationForTesting?()
#endif
            guard self.rootID == rootID, selectedSite == expectedSite, rootURL == expectedURL,
                  notificationGeneration == generation, hasStoredCredential,
                  accountState != .expired, !recoveryBlocked, !isSyncActive, !Task.isCancelled else { return }
            if let summary {
                publishSyncState(.synced(summary))
                return
            }
        }
        let timestamp = operationDefaults.double(forKey: Self.lastSuccessfulReconciliationKey + rootID.uuidString)
        let legacy = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: timestamp), added: 0, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)
        // Timestamp-only installs migrate once; later restores take the read-only summary path.
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

    /// Fills the Corsi page when the window opens: the course list saved at an earlier launch
    /// first, read from disk without waiting for the network, then Moodle's list (#98).
    @discardableResult func refreshOnWindowOpen() -> Task<Void, Never> {
        // A list on its way (signed in, or the launch bootstrap still deciding) and none confirmed
        // on screen: the loading state shows from the first frame, not once the bootstrap and the
        // saved list are done. Signed out or expired, nothing loads, so nothing flashes.
        if !Self.isUIPreview, courseListFreshness != .current, hasBootstrapped ? (hasStoredCredential && accountState == .connected) : true {
            isPreparingCourseList = true
        }
        let generation = windowGeneration
        let refresh = Task { [weak self] in
            guard let self else { return }
            await self.bootstrapTask?.value
            await self.restoreSavedCourseList()
            // Closed while the bootstrap or the restore ran: no request for a window nobody sees
            // (quiet at rest). The loading state was cleared by `windowClosed()`, and a reopened
            // window's own refresh owns it now, so it is left alone.
            guard self.windowGeneration == generation else { return }
            // Starts the load in this turn (`isLoadingCourses` takes over), holds it until a
            // running sync ends, or ends the loading state when nothing will be loaded.
            self.loadCourses()
#if DEBUG
            // The isolated UI harness awaits the real refresh completion instead of sleeping.
            await self.courseLoadTaskForTesting?.value
#endif
        }
        refreshConflicts()
        return refresh
    }

    /// What `chooseRoot` does with the activation policy once its folder panel is closed.
    enum PanelPolicyOutcome: Equatable {
        /// Put `previous` back: the panel raised BeepBar and nothing else has since.
        case restore
        /// A lecture window is open: leave BeepBar regular and let the player restore `previous`
        /// when it closes.
        case handToPlayer
        /// Not ours to change: the panel didn't raise BeepBar, or someone else changed the policy
        /// since.
        case leave
    }

    /// Pure, so it is tested without a panel. Restores only if BeepBar is still `.regular` (the
    /// state `chooseRoot` itself set), never over a policy someone else chose meanwhile, and never
    /// under an open lecture window (#148).
    nonisolated static func panelPolicyOutcome(previous: NSApplication.ActivationPolicy, current: NSApplication.ActivationPolicy, playerOpen: Bool) -> PanelPolicyOutcome {
        guard previous != .regular, current == .regular else { return .leave }
        return playerOpen ? .handToPlayer : .restore
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
        // `runModal` keeps servicing main-actor jobs, so a Lecture Play can open the native
        // player meanwhile. Putting `.accessory` back unconditionally would then drop the Dock
        // icon from under the lecture window (#148).
        let lectureOpen = recordingsIfCreated?.isPlayerOpen ?? false
        switch Self.panelPolicyOutcome(previous: previousPolicy, current: NSApp.activationPolicy(), playerOpen: lectureOpen) {
        case .restore:
            NSApp.setActivationPolicy(previousPolicy)
            NSApp.activate(ignoringOtherApps: true)
        case .handToPlayer:
            // The player restores it when the lecture closes.
            recordingsIfCreated?.keepPolicyAfterLecture(previousPolicy)
        case .leave:
            break
        }
        guard response == .OK, let url = panel.url else { return }
        // Registered by its resolved path, so the same folder reached through a symlink (the folder
        // itself or a parent) maps to one root instead of losing its baselines to a second record.
        let pickedURL = url.standardizedFileURL
        let selectedURL = pickedURL.resolvingSymlinksInPath()
        guard !isSyncActive else { return }
        Task { [weak self] in await self?.useRoot(picked: pickedURL, resolved: selectedURL) }
    }

    /// Makes the folder chosen in the open panel the sync root: registers it, recovers anything
    /// left pending in it, and reads its records for the course list on screen.
    private func useRoot(picked pickedURL: URL, resolved selectedURL: URL) async {
        do {
            await bootstrapTask?.value
            guard let database else { throw SyncDatabaseError.open }
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
            // `chooseRoot` checked for a running sync only before the awaits above, and a sync can
            // start during them. Switching under it would hand its result to the new folder
            // (#167), so the folder stays as it was, quietly as in `chooseRoot`: throwing would
            // show a failure over the running sync. Keep no `await` between this check and the
            // assignment below, or the window reopens.
            guard !isSyncActive else { return }
            guard report.unresolved.isEmpty else { throw SyncDatabaseError.execution }
            rootURL = selectedURL; rootID = selectedID; recoveryBlocked = false; hasPendingModuleMoves = false
            // Started for the previous folder's run: the new folder's next sync decides again.
            cancelRecordingsFollowUp()
            activityItemProblems = [:]
            dataSaverPause = nil
            courseFolders = [:]; conflicts = []; remoteChanges = []
            // Only a list Moodle confirmed may create the new folder's records: a saved one is set
            // aside and Moodle's list loaded instead, as when the window opens (#98).
            let setAside = isShowingSavedCourseList
            if setAside {
                courses = []
                courseListFreshness = .unknown
            } else {
                try await restoreScopes(for: courses)
            }
            // Through `operationDefaults`, like every other setting: a test controller's folder
            // must not reach the test runner's own preferences.
            operationDefaults.set(selectedURL.path, forKey: Self.rootKey)
            operationDefaults.set(selectedID.uuidString, forKey: Self.rootIDKey)
            await restorePersistedSyncState()
            configureBackgroundScheduler()
            if setAside {
                loadCourses()
            } else if courseListFreshness == .current, !courses.isEmpty {
                // The saved list names its folder: saved again for this one, so the next launch
                // can show it. Captured before the token read, and dropped if the account or the
                // folder changed meanwhile.
                let confirmed = courses
                let epoch = courseListEpoch
                if let token = try? await credentialVault.load(), courseListEpoch == epoch, rootID == selectedID, courseListFreshness == .current {
                    saveConfirmedCourseList(confirmed, token: token)
                }
            }
        } catch {
            setSyncState(.failed(.local(BilingualText("Non è stato possibile usare questa cartella. Scegline un'altra.", "This folder couldn't be used. Choose another one."))))
        }
    }

    /// The configuration window closed: a course list load still waiting for a sync to end is no
    /// longer wanted, so the end of that sync sends no request (quiet at rest, #98).
    func windowClosed() {
        windowGeneration += 1
        isPreparingCourseList = false
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
        // A saved list is not Moodle's: its courses get no records until it is confirmed (#98).
        guard !isSyncActive, !isLoadingCourses, !isShowingSavedCourseList else { return }
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
        guard let rootURL, let rootID, let database, !recoveryBlocked, !isSyncActive, !isShowingSavedCourseList else { return }
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
        pruneExpiredCourseList()
        // «Sincronizza ora» always downloads, on any network: nothing is paused any more.
        dataSaverPause = nil
        setSyncState(.checking)
        // Through the helper, not the coordinator directly: it also refreshes the Settings footer.
        Task { await requestNotificationPermissionIfNeeded() }
        syncTask = Task { [weak self] in
            // On every exit, once the run has ended (its operation, `syncTask` included, is over
            // by then): the recordings follow-up starts as a task of its own, never awaited here,
            // so "Esci" never waits for it. A superseded run recorded nothing and starts nothing.
            defer { self?.followUpAfterRun(operationID, trigger: .manual) }
            do {
                guard let self else { return }
                await self.bootstrapTask?.value
                try Task.checkCancellation()
                guard self.activeOperationID == operationID else { return }
                // The course list is only loaded when the window opens, so a sync started from the
                // menu right after launch would otherwise find nothing selected and do nothing. A
                // list restored from disk is not enough either: saved enrollments never decide
                // what is synced, so until Moodle confirmed the list in this session it is asked
                // first (#98).
                if self.courseListFreshness != .current, self.hasStoredCredential, self.accountState == .connected {
                    let token = try await self.credentialVault.load()
                    try await self.refreshCourseList(token: token)
                    try Task.checkCancellation()
                    guard self.activeOperationID == operationID else { return }
                }
                // Only a list Moodle confirmed selects anything: if the refresh above could not run
                // (not connected), a saved list on screen still selects nothing (#98).
                let selected = self.courseListFreshness == .current ? self.courses.filter { self.enabledCourseIDs.contains($0.id) } : []
                guard !selected.isEmpty else {
                    self.recordRunEnd(operationID, .unconfigured)
                    self.setSyncState(.readyUnchecked)
                    self.endOperation(operationID)
                    return
                }
                guard let database = self.database else { throw SyncDatabaseError.open }
                guard let rootURL = self.rootURL, let rootID = self.rootID else {
                    self.recordRunEnd(operationID, .unconfigured)
                    self.setSyncState(.needsFolder)
                    self.endOperation(operationID)
                    return
                }
                let targets = selected.map { SyncTarget(courseID: $0.id, localFolder: self.folder(for: $0)) }
                let token = try await self.credentialVault.load()
                let coordinator = try SyncCoordinator(rootID: rootID, rootURL: rootURL, database: database, gate: self.operationGate, apiClient: self.apiClient, downloader: self.downloader, platformName: self.selectedSite.platformName)
                let run = self.beginTransfer(operationID, automatic: false)
                let summary = try await coordinator.synchronize(targets: targets, token: token, mode: .manual, networkAccess: .unrestricted, progress: self.progressSink(operationID, run: run))
                await self.completeSync(operationID, rootID: rootID, summary: summary, automatic: false)
            } catch is CancellationError {
                self?.cancelledSync(operationID)
            } catch let error as WeBeepAPIError {
                await self?.failedSync(operationID, error: error, automatic: false)
            } catch let error as CredentialStorageError {
                self?.recordRunEnd(operationID, .credentialUnavailable)
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
        let operationID = UUID()
        activeOperationID = operationID
        setSyncState(.syncing)
        syncTask = Task { [weak self] in
            guard let self else { return }
            let sink = self.progressSink(operationID, run: self.progressStore.reset(automatic: false))
            let total = 40
            for completed in 1...total {
                try? await Task.sleep(for: .milliseconds(90))
                if Task.isCancelled { break }
                await sink(SyncProgress(completed: completed, total: total, added: completed / 8, updated: completed / 20, preservedLocal: 0, unchanged: completed, conflicts: 0, failures: 0))
            }
            let cancelled = Task.isCancelled
            self.syncTask = nil
            if cancelled, let previous {
                self.setSyncState(.synced(previous))
            } else {
                self.setSyncState(.synced(SyncCompletionSummary(completedAt: Date(), added: 5, updated: 2, unchanged: 93, preservedLocal: 0, conflicts: 0, failures: 0, perCourse: previous?.perCourse ?? [])))
            }
            await Task.yield()
            self.progressStore.closeCurrentRun()
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

    /// Stops what must not outlive the app: the background scheduler and a running sync, which is
    /// cancelled and returned so the caller can wait for it to wind down.
    ///
    /// Keep this cheap and synchronous. Both quit paths call it: `applicationShouldTerminate` for a
    /// quit from outside (Sparkle's installer, logout, the Dock), and `prepareForMenuQuit()` for
    /// "Esci". Anything returned here is something a quit waits for, so no file, WebKit, Keychain
    /// or network work, and never a task that is always present: a Recordings branch once saved
    /// its cookies here and made every quit wait (see `prepareForMenuQuit()` for why waiting is
    /// dangerous on the menu path).
    func prepareForTermination() -> Task<Void, Never>? {
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
        scheduledConfiguration = nil
        guard let syncTask else { return nil }
        syncTask.cancel()
        setSyncState(.cancelling)
        return syncTask
    }

    /// True once "Esci" has finished its shutdown work and is about to call `NSApp.terminate`.
    /// `applicationShouldTerminate` then answers `.terminateNow` without waiting again (see
    /// `terminationReply`). Lives here rather than on `AppDelegate` because `NSApp.delegate` is
    /// SwiftUI's adaptor proxy, not our delegate object.
    private(set) var menuQuitDrained = false
    private var menuQuitInProgress = false

    /// The shutdown work of "Esci", done *before* `NSApp.terminate` is called.
    ///
    /// Why not just call `NSApp.terminate(nil)` and let `applicationShouldTerminate` wait with
    /// `.terminateLater`, as a quit from outside does: the menu's quit runs inside a main-queue job
    /// (the `Task { @MainActor in … }` hop that `StatusItemController` must use, issue #30). When
    /// `terminate` is called from inside a main-queue job and the delegate answers
    /// `.terminateLater`, AppKit spins a nested run loop that never runs main-actor work, so the
    /// task it waits for, the 5-second fallback and every later menu action all stall, and BeepBar
    /// never quits. `DispatchQueue.main.async` hangs the same way; only `perform(_:afterDelay:)`
    /// escapes, and it is banned on that path (issue #30). Verified with `scripts/quit-probe`.
    ///
    /// So "Esci" winds the sync down first, here, while the main actor is free, waiting at most
    /// `timeout` as the outside path does, then sets `menuQuitDrained` so that `terminate` is
    /// answered `.terminateNow` with nothing left pending. Returns `false` when a quit is already
    /// on its way, so a second click on "Esci" does nothing.
    func prepareForMenuQuit(timeout: Duration = .seconds(5)) async -> Bool {
        guard !menuQuitInProgress else { return false }
        menuQuitInProgress = true
        if let syncTask = prepareForTermination() {
            BeepbarLog.lifecycle.notice("Menu quit waiting for active synchronization")
            await Self.wait(for: syncTask, atMost: timeout)
        }
        menuQuitDrained = true
        return true
    }

    /// What `applicationShouldTerminate` answers. After "Esci" has drained (`menuQuitDrained`) it
    /// is always `.terminateNow`, even if the sync outlived the timeout: answering `.terminateLater`
    /// on that path is exactly what hangs (`prepareForMenuQuit()`). A quit from outside waits for a
    /// sync still winding down; AppKit runs main-actor work while it waits on that path.
    nonisolated static func terminationReply(menuQuitDrained: Bool, hasPendingSync: Bool) -> NSApplication.TerminateReply {
        if menuQuitDrained { return .terminateNow }
        return hasPendingSync ? .terminateLater : .terminateNow
    }

    /// Waits until `task` finishes or `timeout` passes, whichever comes first. `task.value` ignores
    /// cancellation, so a task group would wait for the whole task; two unstructured tasks racing
    /// to resume one continuation stop at the first.
    nonisolated static func wait(for task: Task<Void, Never>, atMost timeout: Duration) async {
        let gate = FirstResume()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.arm(continuation)
            Task { await task.value; gate.resume() }
            Task { try? await Task.sleep(for: timeout); gate.resume() }
        }
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
        forgetCourseList()
        // Recordings exist only for Polimi, and a Polimi session must not wait for the next
        // Polimi account.
        recordings.turnOff()
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
        guard accountState == .connected, hasStoredCredential else { isPreparingCourseList = false; return }
        // A load already running answers this request too.
        guard !isLoadingCourses else { isPreparingCourseList = false; return }
        guard !isSyncActive else {
            // Started when the sync ends (`endOperation`), so a window opened during a sync does
            // not stay on an empty or unconfirmed list (#98).
            if courseListFreshness != .current { isPreparingCourseList = true }
            return
        }
        isPreparingCourseList = false
        courseLoadError = nil
        isLoadingCourses = true
        let epoch = courseListEpoch
        let task = Task { [weak self] in
            defer {
                if let self {
                    self.isLoadingCourses = false
                    // A new sign-in replaced the account while this load ran: its result was
                    // dropped, and the sign-in's own `loadCourses` found this one running and did
                    // nothing, so the new account's list is loaded now (#98).
                    if self.courseListEpoch != epoch { self.loadCourses() }
                }
            }
            do {
                guard let self else { return }
                await self.bootstrapTask?.value
                try Task.checkCancellation()
                let token = try await self.credentialVault.load()
                try await self.refreshCourseList(token: token)
            } catch is CancellationError {
                // Superseded (a new sign-in) or cancelled: nothing failed that the user must see.
            } catch {
                // A failure of the previous account's token says nothing about the account
                // signed in now: expiring or reporting it would blame the new sign-in (#98).
                guard let self, self.courseListEpoch == epoch else { return }
                switch error {
                case let error as WeBeepAPIError where error == .invalidToken:
                    await self.expireCredential()
                case let error as WeBeepAPIError where error == .network(.timedOut):
                    self.courseLoadError = BilingualText("\(self.selectedSite.platformName) non risponde. Riprova.", "\(self.selectedSite.platformName) isn't responding. Try again.")
                case is WeBeepAPIError:
                    self.courseLoadError = BilingualText("Impossibile aggiornare i corsi da \(self.selectedSite.platformName). Riprova.", "Couldn't refresh courses from \(self.selectedSite.platformName). Try again.")
                case let error as CredentialStorageError:
                    await self.handleCredentialStorageError(error)
                default:
                    self.courseLoadError = BilingualText("Impossibile aggiornare i corsi. Riprova.", "Couldn't refresh courses. Try again.")
                }
            }
        }
#if DEBUG
        courseLoadTaskForTesting = task
#else
        _ = task
#endif
    }

    /// Fetches the enrolled courses and makes them the current list. Shared by the course list
    /// refresh and by a sync started before the list was confirmed (from the menu right after
    /// launch, or over a saved list), which cannot go through `loadCourses` because that refuses
    /// to run during a sync. The confirmed list replaces a saved one and is saved for the next
    /// launch (#98).
    private func refreshCourseList(token: String) async throws {
        let epoch = courseListEpoch
        let courses = try await fetchEnrolledCourses(token: token)
        // The account may have been disconnected or replaced while the list was loading.
        guard hasStoredCredential, courseListEpoch == epoch else { return }
        try await restoreScopes(for: courses)
        guard hasStoredCredential, courseListEpoch == epoch else { return }
        let ordered = Self.orderedForDisplay(courses, enabledCourseIDs: enabledCourseIDs)
        // #94: equal @Published assignments still invalidate every course subscriber.
        if self.courses != ordered { self.courses = ordered }
        if courseListFreshness != .current { courseListFreshness = .current }
        if isPreparingCourseList { isPreparingCourseList = false }
        accountState = .connected
        operationDefaults.removeObject(forKey: Self.credentialExpiredKey)
        saveConfirmedCourseList(courses, token: token)
    }

    private func fetchEnrolledCourses(token: String) async throws -> [RemoteCourseSummary] {
        let epoch = courseListEpoch
        let siteInfo: WeBeepSiteInfo
        if let existing = self.siteInfo {
            siteInfo = existing
        } else {
            siteInfo = try await apiClient.validateToken(token)
        }
        let courses = try await apiClient.fetchCourses(userID: siteInfo.userID, token: token)
        // A sign-in that replaced this account meanwhile owns `siteInfo` now: writing the old
        // account's back would hand its id to Recordings (#98).
        guard courseListEpoch == epoch else { throw CancellationError() }
        self.siteInfo = siteInfo
        return courses
    }

    /// Shows the course list saved at an earlier launch while nothing is on screen (#98). The
    /// file is read and decoded off the main actor by `courseListStore`, and only a list saved
    /// for this site, this sync folder and this very sign-in is accepted. Folders come from the
    /// sync database, read only: a saved list never renames, enables or records anything; that
    /// is `restoreScopes`, once Moodle has answered. Whatever changes meanwhile (sign-out, a new
    /// sign-in, another folder, Moodle's list arriving first) makes the result stale, and it is
    /// dropped.
    private func restoreSavedCourseList() async {
        guard !Self.isUIPreview, courses.isEmpty, courseListFreshness == .unknown, courseListRestoreEpoch != courseListEpoch,
              hasStoredCredential, let rootID, let database else { return }
        let epoch = courseListEpoch
        courseListRestoreEpoch = epoch
        let site = selectedSite
        // A token that can't be read shows nothing here; the refresh that follows reports it.
        guard let token = try? await credentialVault.load() else { return }
        // Checked again before the read: a read for an identity that is no longer current would
        // delete the file of the current one as foreign.
        guard courseListEpoch == epoch, self.rootID == rootID, selectedSite == site else { return }
        let identity = CourseListSnapshot.Identity(siteID: site.id, rootID: rootID, token: token)
        let outcome = await enqueueCourseListIO(priority: .userInitiated) { await $0.load(expecting: identity) }.value
        guard case .restored(let snapshot) = outcome else {
            if case .discarded(let reason) = outcome {
                BeepbarLog.lifecycle.notice("Saved course list discarded reason=\(String(describing: reason), privacy: .public)")
            }
            return
        }
        // Without the database's folders the list would show names it doesn't have: nothing then.
        guard let scopes = try? await database.scopes(rootID: rootID) else { return }
        guard courseListEpoch == epoch, courses.isEmpty, courseListFreshness == .unknown, self.rootID == rootID, selectedSite == site, hasStoredCredential else { return }
        // The folders `restoreScopes` would show, without its renames and records: a course's
        // saved folder, else the default it would get next to every folder already taken.
        let savedFolders = Dictionary(scopes.compactMap { $0.localFolder.isEmpty ? nil : ($0.courseID, $0.localFolder) }, uniquingKeysWith: { first, _ in first })
        let defaults = Self.defaultFolders(for: snapshot.summaries, saved: savedFolders)
        // Before `courses`, whose didSet derives the default folders from these.
        for course in snapshot.summaries {
            let folder = savedFolders[course.id] ?? defaults[course.id] ?? LocalPathPolicy.defaultCourseFolder(course.displayName)
            if courseFolders[course.id] != folder { courseFolders[course.id] = folder }
        }
        courses = Self.orderedForDisplay(snapshot.summaries, enabledCourseIDs: enabledCourseIDs)
        courseListFreshness = .saved(snapshot.savedAt)
    }

    /// Runs `work` on the saved list's store after every read, save and deletion issued before
    /// it (`courseListIO`), off the main actor.
    private func enqueueCourseListIO<Value: Sendable>(priority: TaskPriority, _ work: @escaping @Sendable (CourseListSnapshotStore) async -> Value) -> Task<Value, Never> {
        let previous = courseListIO
        let store = courseListStore
        let task = Task.detached(priority: priority) { () async -> Value in
            await previous?.value
            return await work(store)
        }
        courseListIO = Task.detached(priority: priority) { _ = await task.value }
        return task
    }

    /// Saves a list Moodle just confirmed for the next launch, without waiting: the store writes
    /// only when the list changed or a day has passed, and refuses the write if the account was
    /// forgotten meanwhile (`courseListEpoch`).
    private func saveConfirmedCourseList(_ courses: [RemoteCourseSummary], token: String) {
        guard !Self.isUIPreview, let rootID else { return }
        let identity = CourseListSnapshot.Identity(siteID: selectedSite.id, rootID: rootID, token: token)
        let epoch = courseListEpoch
        _ = enqueueCourseListIO(priority: .utility) { (store: CourseListSnapshotStore) async -> Void in
            do { try await store.save(courses, identity: identity, epoch: epoch) }
            catch { BeepbarLog.lifecycle.error("Saved course list not written errorType=\(String(reflecting: type(of: error)), privacy: .public)") }
        }
    }

    /// Deletes the saved course list once it is older than 30 days, without retiring the account
    /// (#98, PR #138). Called at launch and when a sync runs, so the age limit holds for a user who
    /// never opens the window, where `restoreSavedCourseList` would otherwise be the only check.
    /// Costs a `stat` when there is no file and nothing once the store knows the file's date.
    private func pruneExpiredCourseList() {
        guard !Self.isUIPreview else { return }
        _ = enqueueCourseListIO(priority: .utility) { (store: CourseListSnapshotStore) async -> Void in
            if await store.removeIfExpired() {
                BeepbarLog.lifecycle.notice("Saved course list removed reason=expired")
            }
        }
    }

    /// Clears the course list of an account that is going away (sign-out, another university, a
    /// new sign-in, the stored credential gone) and deletes its saved copy. Bumps the epoch first,
    /// so a refresh, a restore or a save still running for that account is dropped (#98).
    private func forgetCourseList() {
        courseListEpoch += 1
        // The account goes: its recordings follow-up, its last fetched enrollments and the last
        // follow-up's result go with it (memory only).
        cancelRecordingsFollowUp()
        lastRunCourses = []
        lastRecordingsOutcome = nil
        courses = []
        courseListFreshness = .unknown
        isPreparingCourseList = false
        let epoch = courseListEpoch
        _ = enqueueCourseListIO(priority: .utility) { (store: CourseListSnapshotStore) async -> Void in
            do { try await store.delete(retiringEpochsBelow: epoch) }
            catch { BeepbarLog.lifecycle.error("Saved course list not deleted errorType=\(String(reflecting: type(of: error)), privacy: .public)") }
        }
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
    /// separate suite, wiped at launch except for the watchlist demo, which keeps choices
    /// so manual testing can verify restoration after relaunch.
    private static let defaults: UserDefaults = {
        guard isUIPreview || isUIPreviewOnboarding else { return .standard }
        let watchlistPreview = isUIPreview && ProcessInfo.processInfo.arguments.contains("--watchlist-preview")
        let suiteName = watchlistPreview ? "io.github.tvaccari.beepbar.preview.watchlist" : "io.github.tvaccari.beepbar.preview"
        let store = UserDefaults(suiteName: suiteName) ?? .standard
        if !watchlistPreview, let domain = store.persistentDomain(forName: suiteName) {
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
                // Only a token that was accepted and stored replaces the previous account's state,
                // including the course list saved for the previous sign-in, even if it is the same
                // account: the new token has its own fingerprint (#98).
                self.forgetCourseList()
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

    /// Where the saved course list lives (#98): next to `sync.sqlite` for the installed app, and in
    /// a throwaway folder for the `--ui-preview` builds, which share the installed app's identity
    /// and must never read or replace its file. `nil` when Application Support can't be found:
    /// then nothing is saved or restored and the window simply waits for the network, as before.
    private static func courseListDirectory() -> URL? {
        guard !isUIPreview, !isUIPreviewOnboarding else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-preview-course-list", isDirectory: true)
        }
        return try? databaseDirectory()
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
        let restoredSelection = Self.restoredEnabledCourseIDs(scopes: scopes, current: enabledCourseIDs, remoteIDs: remoteIDs)
        // @Published sends even for equal values; unchanged refreshes must leave the UI quiet.
        if enabledCourseIDs != restoredSelection { enabledCourseIDs = restoredSelection }
        // `courseFolders` is assigned one course at a time below and each assignment would rebuild
        // the menu lines (a name regex pass over every course: quadratic at launch). The rebuild
        // is held back and runs once when the loop is done, whichever way it ends.
        menuRebuildHolds += 1
        defer {
            menuRebuildHolds -= 1
            if menuRebuildHolds == 0, menuRebuildPending { menuRebuildPending = false; recordingMenuInputsChanged() }
        }
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
                        if courseFolders[course.id] != replacement { courseFolders[course.id] = replacement }
                        try await database.upsertScope(SyncScope(
                            rootID: rootID,
                            courseID: course.id,
                            displayName: course.displayName,
                            localFolder: replacement,
                            enabled: scope.enabled
                        ))
                    } catch {
                        if courseFolders[course.id] != scope.localFolder { courseFolders[course.id] = scope.localFolder }
                    }
                } else {
                    if courseFolders[course.id] != scope.localFolder { courseFolders[course.id] = scope.localFolder }
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
                let folder = defaults[course.id] ?? LocalPathPolicy.defaultCourseFolder(course.displayName)
                if courseFolders[course.id] != folder { courseFolders[course.id] = folder }
                if scopes.isEmpty {
                    do {
                        try await database.upsertScope(SyncScope(rootID: rootID, courseID: course.id, displayName: course.displayName, localFolder: courseFolders[course.id]!, enabled: enabledCourseIDs.contains(course.id)))
                    } catch {
                        courseRenameErrors[course.id] = tr("Impossibile salvare la selezione del corso.", "Couldn't save the course selection.")
                    }
                }
            }
        }
        let selection = enabledCourseIDs.map(String.init).sorted()
        // Compare persisted data, not just the in-memory set: missing/legacy values still need repair.
        if operationDefaults.stringArray(forKey: Self.enabledCoursesKey) != selection {
            operationDefaults.set(selection, forKey: Self.enabledCoursesKey)
        }
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

    /// Publishes the end of `operationID`, which synced the folder `rootID`. Both guards also
    /// require that folder to be still the current one: the pending choices just read and the
    /// state published belong to the current folder, so a run whose folder was replaced
    /// meanwhile has nothing it may publish or save; `completeSync` then ends it as superseded
    /// (#167).
    private func finishReconciliation(progress: SyncProgress, operationID: UUID, rootID: UUID?) async throws {
        let pending = try await loadPendingChoices()
        let open = pending.conflicts
        let changes = pending.changes
        // The same check as the guard below, before paying for the encode: a sync cancelled or
        // replaced while its pending choices were read has nothing left to encode (R01, #109).
        guard activeOperationID == operationID, self.rootID == rootID, !Task.isCancelled else { return }
        let summary = SyncCompletionSummary(progress: progress)
        // Only a successful result is saved. Its encode runs off the main actor here, while this
        // operation is still the active one, and before the guard below, which then also drops a
        // result superseded or cancelled during the encode (R01, #109). Encoding after the guard
        // would publish across a suspension the guard no longer covers.
        let encoded = progress.failures == 0 && open.isEmpty ? await EncodedSyncSummary.encode(summary) : nil
#if DEBUG
        if let encoded { summaryEncodedOnMainThreadForTesting = encoded.encodedOnMainThread }
        await beforeReconciliationStateForTesting?()
#endif
        // Cancellation keeps the operation ID until its task unwinds. Checking the ID alone
        // would publish a completed result over the user's pending cancellation.
        guard activeOperationID == operationID, self.rootID == rootID, !Task.isCancelled else { return }
        conflicts = open
        remoteChanges = changes
        let ordered = Self.orderedForDisplay(courses, enabledCourseIDs: enabledCourseIDs)
        if courses != ordered { courses = ordered }
        if let encoded {
            setSyncState(synced: encoded, rootID: rootID)
        } else if progress.failures > 0 {
            setSyncState(.partial(summary))
        } else {
            setSyncState(.conflicts(open.count, summary))
        }
    }

    private func configureBackgroundScheduler() {
        let configuration = BackgroundScheduleConfiguration(
            enabled: automaticSyncEnabled,
            interval: automaticSyncInterval,
            connected: accountState == .connected,
            rootConfigured: rootURL != nil,
            hasEnabledCourses: !enabledCourseIDs.isEmpty,
            recoveryBlocked: recoveryBlocked
        )
        guard configuration != scheduledConfiguration else { return }
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
        scheduledConfiguration = configuration
        schedulerGeneration += 1
        schedulerRegistrationGeneration += 1
        // The pause promised a retry soon; that retry belonged to the scheduler just dropped, and
        // the new one first runs a whole interval later. Left on screen, "In attesa del Wi-Fi"
        // could stay for hours, through a renewed sign-in, after the Mac is back on Wi-Fi.
        dataSaverPause = nil
        let policy = BackgroundScheduleInput(
            automaticSyncEnabled: configuration.enabled,
            hasCredential: configuration.connected,
            hasRoot: configuration.rootConfigured,
            enabledCourseCount: configuration.hasEnabledCourses ? 1 : 0,
            recoveryBlocked: recoveryBlocked
        )
        guard BackgroundSchedulePolicy.shouldSchedule(policy) else {
            BeepbarLog.scheduler.notice("Scheduler disabled enabled=\(configuration.enabled, privacy: .public) connected=\(configuration.connected, privacy: .public) root=\(configuration.rootConfigured, privacy: .public) courses=\(self.enabledCourseIDs.count, privacy: .public) recoveryBlocked=\(configuration.recoveryBlocked, privacy: .public)")
            return
        }
#if DEBUG
        guard registersBackgroundActivity else { return }
#endif
        BeepbarLog.scheduler.notice("Scheduler configured intervalSeconds=\(self.automaticSyncInterval, privacy: .public)")
        let registrationGeneration = schedulerRegistrationGeneration
        let scheduler = scheduleBackgroundActivity(TimeInterval(automaticSyncInterval)) { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self, self.schedulerRegistrationGeneration == registrationGeneration,
                      self.backgroundScheduler != nil else {
                    completion(.finished)
                    return
                }
                BeepbarLog.scheduler.notice("Scheduler callback started")
                let trace = PerformanceTrace.shared.begin("scheduler.callback", category: .scheduler)
                defer { PerformanceTrace.shared.end("scheduler.callback", category: .scheduler, state: trace) }
                let outcome = await self.runAutomaticSync()
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
            guard !Task.isCancelled, schedulerGeneration == generation else {
                BeepbarLog.sync.notice("Automatic synchronization skipped reason=schedule-changed")
                startRecordingsFollowUp(after: .scheduleChanged, trigger: .automatic)
                return .finished
            }
        }
        let decision = AutomaticSyncPolicy.decision(lowPowerMode: lowPowerMode, busy: activeOperationID != nil || isLoadingCourses, configured: isAutomaticSyncConfigured, dataSaverEnabled: dataSaverEnabled, network: network)
        switch decision {
        case .deferForLowPowerMode:
            BeepbarLog.sync.notice("Automatic synchronization deferred reason=low-power")
            startRecordingsFollowUp(after: .notRun(decision), trigger: .automatic)
            return .deferred
        case .deferWhileBusy:
            BeepbarLog.sync.notice("Automatic synchronization deferred reason=operation-active")
            startRecordingsFollowUp(after: .notRun(decision), trigger: .automatic)
            return .deferred
        case .skipUnconfigured:
            BeepbarLog.sync.notice("Automatic synchronization skipped reason=configuration-unavailable")
            // Finishing leaves no retry behind, so a pause from an earlier attempt must go too.
            dataSaverPause = nil
            startRecordingsFollowUp(after: .notRun(decision), trigger: .automatic)
            return .finished
        case .pause(let pause):
            // Nothing is sent and the state on screen is left alone (the last result, "sincronizzato
            // X fa"): the pause is shown on top of it. Deferred, so the scheduler retries soon
            // instead of waiting a whole interval.
            BeepbarLog.sync.notice("Automatic synchronization deferred reason=data-saver")
            dataSaverPause = pause
            startRecordingsFollowUp(after: .notRun(decision), trigger: .automatic)
            return .deferred
        case .run:
            break
        }
        guard let rootURL, let rootID, let database else {
            startRecordingsFollowUp(after: .unconfigured, trigger: .automatic)
            return .finished
        }
        dataSaverPause = nil
        pruneExpiredCourseList()
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
            recordRunEnd(operationID, .localFailure)
            setSyncState(.failed(.local(BilingualText("Impossibile leggere i corsi selezionati. Riprova.", "Couldn't read selected courses. Try again."))))
            endOperation(operationID)
            followUpAfterRun(operationID, trigger: .automatic)
            return .finished
        }
        guard !automaticScopes.isEmpty else {
            guard activeOperationID == operationID else { return .cancelled }
            BeepbarLog.sync.notice("Automatic synchronization skipped reason=no-enabled-courses")
            recordRunEnd(operationID, .unconfigured)
            endOperation(operationID)
            followUpAfterRun(operationID, trigger: .automatic)
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
                let enrolledCourses = try await self.fetchEnrolledCourses(token: token)
                // Kept for the menu's recordings lines and the recordings follow-up's keys in a
                // launch where the window never loaded `courses`: no extra WeBeep request.
                if self.lastRunCourses != enrolledCourses { self.lastRunCourses = enrolledCourses }
                let enrolled = Set(enrolledCourses.map(\.id))
                let targets = Self.automaticTargets(scopes: automaticScopes, enrolledCourseIDs: enrolled)
                let coordinator = try SyncCoordinator(rootID: rootID, rootURL: rootURL, database: database, gate: gate, apiClient: apiClient, downloader: downloader, platformName: platformName)
                let run = self.beginTransfer(operationID, automatic: true)
                let summary = try await coordinator.synchronize(targets: targets, token: token, mode: .automatic, networkAccess: networkAccess, progress: self.progressSink(operationID, run: run))
                await self.completeSync(operationID, rootID: rootID, summary: summary, automatic: true)
            } catch is CancellationError {
                self?.cancelledSync(operationID)
            } catch let error as WeBeepAPIError {
                guard let self else { return }
                if networkAccess == .dataSaver, await self.pausedMidRun(operationID, error: error, restoring: stateBeforeRun) { return }
                await self.failedSync(operationID, error: error, automatic: true)
            } catch let error as CredentialStorageError {
                self?.recordRunEnd(operationID, .credentialUnavailable)
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
        // Captured before the follow-up, which never changes the materials outcome.
        let outcome = Task.isCancelled ? AutomaticSyncOutcome.cancelled : automaticOutcome
        // After the run and before the scheduler's `completion`: the system activity that ran the
        // materials covers the recordings listings too, with no timer of our own. Never inside
        // `task` (`syncTask`), which a quit waits for.
        if let followUp = followUpAfterRun(operationID, trigger: .automatic, schedulerCancelled: Task.isCancelled) {
            await withTaskCancellationHandler { await followUp.value } onCancel: { followUp.cancel() }
        }
        return outcome
    }

    /// Starts the recordings follow-up of `operationID` from what its ending path recorded, or
    /// nothing when it recorded nothing (superseded). An automatic run whose scheduler task was
    /// cancelled ends as `.cancelled` (mapping table: `runAutomaticSync` returning `.cancelled`).
    /// Returns the task that runs (new or merged into), nil when skipped.
    @discardableResult
    private func followUpAfterRun(_ operationID: UUID, trigger: RecordingsSyncTrigger, schedulerCancelled: Bool = false) -> Task<Void, Never>? {
        guard let end = takeRunEnd(operationID) else { return nil }
        return startRecordingsFollowUp(after: schedulerCancelled ? .cancelled : end, trigger: trigger)
    }

    /// Records how `operationID`'s materials run ended. Only the active operation records: a
    /// superseded one (sign-out or site change mid-run, or a folder change, which ends it through
    /// `supersededByFolderChange`) leaves nothing, and so starts no follow-up.
    private func recordRunEnd(_ operationID: UUID, _ end: MaterialsRunEnd) {
        guard activeOperationID == operationID else { return }
        materialsRunEnds[operationID] = (recordingsFollowUpGeneration, end)
    }

    /// Takes (and forgets) what `operationID` recorded; nil for a superseded or never-started run.
    private func takeRunEnd(_ operationID: UUID) -> MaterialsRunEnd? {
        guard let recorded = materialsRunEnds.removeValue(forKey: operationID),
              recorded.generation == recordingsFollowUpGeneration else { return nil }
        return recorded.end
    }

    /// The mapping table of `RecordingsMaterialsOutcome`, as one pure function. nil means nothing
    /// ended for the operation: no follow-up, not even a skipping one.
    nonisolated static func recordingsOutcome(for end: MaterialsRunEnd) -> RecordingsMaterialsOutcome? {
        switch end {
        case .completed(let conflicts, let failures):
            if conflicts > 0 { return .conflicts }
            return failures > 0 ? .partial : .synced
        case .pendingChoicesUnreadable, .localFailure: return .localFailure
        case .cancelled, .scheduleChanged: return .cancelled
        case .serviceFailure(let error): return .failed(SyncServiceFailure(error))
        case .pausedMidRun(let pause): return .pausedByDataSaver(pause)
        case .notRun(let decision): return .notRun(decision)
        case .unconfigured: return .notRun(.skipUnconfigured)
        case .deferredWhileBusy: return .notRun(.deferWhileBusy)
        case .credentialUnavailable: return .accountUnavailable
        case .superseded: return nil
        }
    }

    /// The Recman keys the follow-up refreshes: the selected courses, deduplicated. A manual sync
    /// has loaded `courses` by now; an automatic one uses what `fetchEnrolledCourses` returned
    /// (`lastRunCourses`), so no extra WeBeep request is made.
    private func recordingsSyncKeys(trigger: RecordingsSyncTrigger) -> Set<RecmanCourseKey> {
        let source = trigger == .manual ? courses : lastRunCourses
        return Set(RecordingsPresentation.syncedCourses(source, enabledIDs: enabledCourseIDs).compactMap { RecmanCourseKey(course: $0) })
    }

    /// The gate's inputs, read without creating `RecordingsController`: with no controller the
    /// switch is read from defaults and access can only be `.ready` (a missing session is found
    /// by the refresh itself, never here).
    private func recordingsSyncDecision(after outcome: RecordingsMaterialsOutcome, trigger: RecordingsSyncTrigger, network: NetworkPathConditions?) -> (RecordingsSyncDecision, Set<RecmanCourseKey>) {
        let switchedOn = recordingsStorage?.isEnabled ?? RecordingsController.isSwitchedOn(in: operationDefaults)
        let access: RecordingsSyncAccess
        switch recordingsStorage?.access {
        case nil, .ready?: access = switchedOn ? .ready : .off
        case .off?: access = .off
        case .signingIn?: access = .signingIn
        case .needsSignIn?: access = .needsSignIn
        }
        // The keys are only computed when the cheap standing reasons don't already skip.
        let keys = switchedOn && selectedSite.university == .polimi ? recordingsSyncKeys(trigger: trigger) : []
        let decision = RecordingsSyncPolicy.decision(switchedOn: switchedOn, university: selectedSite.university, ownerKnown: recordingsOwnerUserID != nil, courseKeys: keys, outcome: outcome, trigger: trigger, dataSaverEnabled: dataSaverEnabled, currentNetwork: network, access: access)
        return (decision, keys)
    }

    /// Starts the Recordings listings refresh that follows a materials run, or nothing when the
    /// gate skips it (silently: a skip is never a failure). Returns the running task (new, or the
    /// one it merges into), nil when skipped.
    ///
    /// Never calls `setSyncState`, never touches `activeOperationID`, never notifies a failure and
    /// is not returned by `prepareForTermination`: the materials result stays what the menu and
    /// Home show, and a quit never waits for WebKit (AGENTS.md, quit path). The decision is taken
    /// twice: now without the network (cheap skips, and the merge), and again inside the task right
    /// before the refresh, for an automatic run with Data Saver on with the network read then,
    /// since the Mac may have moved to a hotspot during the run. Merge: a refresh already running
    /// serves this request too (a manual request does not upgrade a running automatic one to
    /// `force`; the next manual sync will).
    @discardableResult
    private func startRecordingsFollowUp(after end: MaterialsRunEnd, trigger: RecordingsSyncTrigger) -> Task<Void, Never>? {
        guard let materials = Self.recordingsOutcome(for: end) else { return nil }
        guard case .refresh = recordingsSyncDecision(after: materials, trigger: trigger, network: nil).0 else { return nil }
        if let recordingsFollowUp { return recordingsFollowUp }
        let generation = recordingsFollowUpGeneration
        let id = UUID()
        recordingsFollowUpID = id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.recordingsFollowUpID == id { self.recordingsFollowUp = nil; self.recordingsFollowUpID = nil } }
            // Only an automatic run with Data Saver on cares about the network now; a nil network
            // (unknown) never pauses.
            let network: NetworkPathConditions? = trigger == .automatic && self.dataSaverEnabled ? await self.automaticSyncEnvironment.currentNetwork() : nil
            guard !Task.isCancelled, self.recordingsFollowUpGeneration == generation else { return }
            let (decision, keys) = self.recordingsSyncDecision(after: materials, trigger: trigger, network: network)
            guard case .refresh(let force) = decision else { return }
            let result: RecordingsSyncOutcome
            if let refresh = self.recordingsRefresh {
                result = await refresh(keys, force)
            } else {
                result = await self.recordings.refreshForSync(keys, force: force)
            }
            // An account, site or folder change meanwhile: the result belongs to a world that is gone.
            guard self.recordingsFollowUpGeneration == generation else { return }
            self.lastRecordingsOutcome = result
            // One aggregated notification for the lectures first seen by this refresh (nothing for a
            // baseline, a failure or an expired session; the coordinator applies the Notifiche switch).
            await self.notificationCoordinator.announceRecordingsRefresh(result, isCurrent: { [weak self] in self?.recordingsFollowUpGeneration == generation })
        }
        recordingsFollowUp = task
        return task
    }

    /// Stops the follow-up of a context that no longer exists (sign-out, site, account, folder
    /// change): it publishes nothing and the seam is told through task cancellation.
    private func cancelRecordingsFollowUp() {
        recordingsFollowUpGeneration += 1
        materialsRunEnds.removeAll()
        recordingsFollowUp?.cancel()
        recordingsFollowUp = nil
        recordingsFollowUpID = nil
    }

    nonisolated static func automaticTargets(scopes: [SyncScope], enrolledCourseIDs: Set<Int64>) -> [SyncTarget] {
        scopes.filter { $0.enabled && enrolledCourseIDs.contains($0.courseID) }
            .map { SyncTarget(courseID: $0.courseID, localFolder: $0.localFolder) }
    }

    /// Opens the progress stream of `operationID` and shows the sync as running. Returns the run
    /// token its events carry; `.superseded` when the operation is no longer the active one, so
    /// nothing it reports is ever shown.
    private func beginTransfer(_ operationID: UUID, automatic: Bool) -> SyncProgressRun {
        guard activeOperationID == operationID, !Task.isCancelled else { return .superseded }
        let run = progressStore.reset(automatic: automatic)
        setSyncState(.syncing)
        return run
    }

    /// The progress callback handed to `SyncCoordinator`. It runs on the sync's own tasks: the
    /// throttle decides there, and the main actor is entered only for the updates it keeps and
    /// for the final totals (D08, #96). Moving the hop before `accept` brings back one main-queue
    /// turn per file; `SyncProgressStoreTests` counts them.
    nonisolated private func progressSink(_ operationID: UUID, run: SyncProgressRun) -> @Sendable (SyncProgress) async -> Void {
        let store = progressStore
        return { [weak self] progress in
            guard let update = store.accept(progress, run: run) else { return }
            await self?.progressAccepted(update, run: run, operationID: operationID)
        }
    }

    /// Main actor: applies an accepted update when the operation is still the active one, and
    /// keeps the menu bar detail in the same turn as the state (AGENTS.md hard rules).
    private func progressAccepted(_ update: SyncProgress, run: SyncProgressRun, operationID: UUID) {
        // Counted before any guard: this measures main-actor entries, not accepted updates.
        // Moving it behind a guard, or into `receive`, blinds the D08 regression test to a hop
        // placed before `accept` (the test would then count the throttle instead of the actor).
        progressStore.recordMainActorEntry()
        guard activeOperationID == operationID, progressStore.receive(update, run: run) else { return }
        refreshMenuBarSnapshot()
    }

    /// Ends `operationID`, a run that synced the folder `rootID` (captured when it started). The
    /// folder is checked again after every suspension: if it was replaced meanwhile, the run ends
    /// as superseded instead of reporting over the new folder (#167).
    private func completeSync(_ operationID: UUID, rootID: UUID?, summary: SyncProgress, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        do {
            try await finishReconciliation(progress: summary, operationID: operationID, rootID: rootID)
        } catch {
            guard activeOperationID == operationID else { return }
            guard self.rootID == rootID else { await supersededByFolderChange(operationID); return }
            if Task.isCancelled { cancelledSync(operationID); return }
            recordRunEnd(operationID, .pendingChoicesUnreadable)
            reportPendingChoicesReadFailure()
            endOperation(operationID)
            return
        }
        guard activeOperationID == operationID else { return }
        guard self.rootID == rootID else { await supersededByFolderChange(operationID); return }
        guard !Task.isCancelled else { cancelledSync(operationID); return }
        recordRunEnd(operationID, .completed(conflicts: summary.conflicts, failures: summary.failures))
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

    /// Ends a run whose folder was replaced while it ran (#167). It records no run end, so no
    /// recordings follow-up starts for the old folder, sends no notification, and saves nothing.
    /// The new folder's own saved state is then restored: `useRoot` skipped that restore because
    /// this run was still active, and without it the window would stay on "checking".
    private func supersededByFolderChange(_ operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        BeepbarLog.sync.notice("Synchronization superseded by a folder change")
        endOperation(operationID)
        await restorePersistedSyncState()
    }

    private func cancelledSync(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        BeepbarLog.sync.notice("Synchronization cancelled")
        recordRunEnd(operationID, .cancelled)
        setSyncState(.readyUnchecked)
        endOperation(operationID)
    }

    /// A manual sync found the folder busy with a rename, a module move or a conflict being resolved.
    private func busySync(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        recordRunEnd(operationID, .localFailure)
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
        recordRunEnd(operationID, .pausedMidRun(pause))
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
        recordRunEnd(operationID, .deferredWhileBusy)
        automaticOutcome = .deferred
        setSyncState(.readyUnchecked)
        endOperation(operationID)
    }

    private func failedSync(_ operationID: UUID, error: WeBeepAPIError?, automatic: Bool) async {
        guard activeOperationID == operationID else { return }
        recordRunEnd(operationID, error.map(MaterialsRunEnd.serviceFailure) ?? .localFailure)
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
            // Signed out in all but name: the list of an account with no credential goes too (#98).
            forgetCourseList()
            setSyncState(.loginRequired)
        case .write:
            setSyncState(.failed(.credentialUnavailable))
        }
        configureBackgroundScheduler()
    }

    private func endOperation(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        progressStore.closeCurrentRun()
        activeOperationID = nil
        syncTask = nil
        // The course list the window asked for while this sync ran (#98).
        if isPreparingCourseList { loadCourses() }
    }

}

/// A registration can be invalidated without coupling schedule identity to an enabled-course count.
struct BackgroundActivityRegistration {
    let invalidate: () -> Void
}

private struct BackgroundScheduleConfiguration: Equatable {
    let enabled: Bool
    let interval: Int
    let connected: Bool
    let rootConfigured: Bool
    let hasEnabledCourses: Bool
    let recoveryBlocked: Bool
}

/// Shows the running sync's progress. Only `SyncProgressLine` observes it, so a tick re-renders
/// that line and nothing else.
///
/// Progress arrives from the sync's own tasks, thousands of times per run. The decision whether
/// an event is worth showing is taken where it arrives, in `accept`, behind a lock and off the
/// main actor; the main actor is entered in `receive` only for the events that survived the
/// throttle (D08, #96). Before that change every event hopped to the main actor first and most
/// were then thrown away there, so a big run cost the UI one main-queue turn per file.
///
/// Each run gets a `SyncProgressRun` token from `reset`; `close` retires it when the run reaches
/// its terminal state. An event carrying another run's token is dropped at both steps, so a late
/// callback from a cancelled or finished run can never overwrite the completed state, nor the
/// next run's first ticks.
@MainActor final class SyncProgressStore: ObservableObject {
    @Published private(set) var progress = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
    /// Main-actor entries on the progress path since the last `reset`, recorded by the controller
    /// at the top of `progressAccepted` before any guard. What D08's regression test measures;
    /// not shown anywhere.
    private(set) var mainActorEntries = 0
    private let relay = SyncProgressRelay()

    /// Starts a run with the cadence its kind deserves (200 ms manual, 1 s automatic) and returns
    /// the token its events must carry. Any earlier run is retired.
    func reset(automatic: Bool) -> SyncProgressRun {
        progress = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        mainActorEntries = 0
        return relay.reset(interval: automatic ? .seconds(1) : .milliseconds(200))
    }

    /// Retires whatever run is open. `endOperation` calls it for every way an operation ends,
    /// including cancellation, so a token kept by a still-running sync task goes dead.
    func closeCurrentRun() {
        relay.closeCurrent()
    }

    /// Called by the controller the moment the progress path enters the main actor, before it
    /// decides whether the update is still wanted. See `progressAccepted`.
    func recordMainActorEntry() {
        mainActorEntries += 1
    }

    /// Off the main actor: the throttle's verdict for one event. `nil` means nothing to show.
    nonisolated func accept(_ value: SyncProgress, run: SyncProgressRun) -> SyncProgress? {
        relay.next(value, run: run)
    }

    /// On the main actor, for accepted updates only. Returns `false` when `run` was retired
    /// between `accept` and this call, which leaves the shown progress untouched.
    func receive(_ update: SyncProgress, run: SyncProgressRun) -> Bool {
        guard relay.isCurrent(run) else { return false }
        progress = update
        return true
    }
}

/// Identifies one sync run's progress stream; see `SyncProgressStore`.
struct SyncProgressRun: Sendable, Equatable {
    fileprivate let generation: Int
    /// A token no event is ever accepted for: handed out when a run was superseded before it
    /// could start.
    static let superseded = SyncProgressRun(generation: -1)
}

/// The throttle and the current run token, behind a lock so sync tasks can consult them without
/// entering any actor. Not an actor on purpose: an actor hop would be the very cost D08 removes.
private final class SyncProgressRelay: Sendable {
    private struct State {
        var throttle = SyncProgressThrottle(minimumInterval: .milliseconds(200))
        var current = SyncProgressRun.superseded
        var generation = 0
    }
    private let clock = ContinuousClock()
    private let state = OSAllocatedUnfairLock(initialState: State())

    func reset(interval: Duration) -> SyncProgressRun {
        state.withLock { state in
            state.generation += 1
            state.current = SyncProgressRun(generation: state.generation)
            state.throttle = SyncProgressThrottle(minimumInterval: interval)
            return state.current
        }
    }

    /// Closing sets `current` to `.superseded`. That is why `isCurrent` and `next` also refuse
    /// `run == .superseded` explicitly: otherwise a sink handed the superseded token (a run refused
    /// by `beginTransfer`) would match the closed state and pass the relay after any run ended.
    func closeCurrent() {
        state.withLock { $0.current = .superseded }
    }

    func isCurrent(_ run: SyncProgressRun) -> Bool {
        state.withLock { $0.current == run && run != .superseded }
    }

    func next(_ progress: SyncProgress, run: SyncProgressRun) -> SyncProgress? {
        let now = clock.now
        return state.withLock { state in
            guard state.current == run, run != .superseded else { return nil }
            return state.throttle.accept(progress, now: now)
        }
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

/// Resumes one continuation once, whichever caller comes first (`WeBeepAuthenticationController.wait`).
private final class FirstResume: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume() {
        let pending = continuation.withLock { value -> CheckedContinuation<Void, Never>? in
            defer { value = nil }
            return value
        }
        pending?.resume()
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
