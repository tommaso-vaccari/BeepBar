import AppKit
import BeepbarCore
@preconcurrency import UserNotifications

/// The part of macOS's notification center BeepBar uses. `SystemNotificationCenter` in the app;
/// tests use a fake, so they can prove what reaches macOS without a real notification center
/// (which a test process doesn't have).
protocol NotificationCenterClient: Sendable {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async
    func send(identifier: String, title: String, body: String, destination: NotificationDestination) async
}

/// BeepBar's notifications through `UNUserNotificationCenter`.
struct SystemNotificationCenter: NotificationCenterClient {
    func authorization() async -> NotificationAuthorization {
        Self.authorization(from: await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// `.provisional` counts as allowed: macOS delivers those notifications, quietly. BeepBar never
    /// asks for provisional permission, but a user or MDM profile may have set it.
    static func authorization(from status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized, .provisional: .allowed
        default: .denied
        }
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// What a notification carries for its click: read back by `NotificationResponder.route`.
    /// Only the destination's raw value, which older and newer builds both read safely.
    static func userInfo(for destination: NotificationDestination) -> [AnyHashable: Any] {
        [NotificationPolicy.destinationKey: destination.rawValue]
    }

    func send(identifier: String, title: String, body: String, destination: NotificationDestination) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = Self.userInfo(for: destination)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

/// Stands in for the notification center where none may be touched: test controllers that don't
/// pass their own, so no test can reach the real one, and UI previews, which report `.allowed` so
/// Settings doesn't show a misleading "blocked" warning. Never prompts, sends nothing.
struct InertNotificationCenter: NotificationCenterClient {
    var reportedAuthorization: NotificationAuthorization = .denied
    init(authorization: NotificationAuthorization = .denied) { reportedAuthorization = authorization }
    func authorization() async -> NotificationAuthorization { reportedAuthorization }
    func requestAuthorization() async {}
    func send(identifier: String, title: String, body: String, destination: NotificationDestination) async {}
}

enum AutomaticNotificationIssue: String {
    case authenticationExpired
    case serviceUnavailable
    case incompatibleResponse
    case partialSync

    var title: String {
        switch self {
        case .authenticationExpired: tr("Accesso scaduto", "Sign-in expired")
        case .serviceUnavailable: tr("Piattaforma non disponibile", "Platform unavailable")
        case .incompatibleResponse: tr("Problema con la piattaforma", "Platform problem")
        case .partialSync: tr("Sincronizzazione incompleta", "Sync incomplete")
        }
    }

    var body: String {
        switch self {
        case .authenticationExpired: tr("Apri BeepBar e accedi di nuovo per riprendere la sincronizzazione.", "Open BeepBar and sign in again to resume syncing.")
        case .serviceUnavailable: tr("La piattaforma non risponde. I materiali locali restano disponibili.", "The platform isn't responding. Your local materials remain available.")
        case .incompatibleResponse: tr("La piattaforma ha restituito una risposta inattesa. Apri BeepBar per i dettagli.", "The platform returned an unexpected response. Open BeepBar for details.")
        case .partialSync: tr("Alcuni materiali non sono stati aggiornati. Apri BeepBar per i dettagli.", "Some materials weren't updated. Open BeepBar for details.")
        }
    }
}

/// Decides and sends every BeepBar notification: the materials results of a sync and, after its
/// Recordings follow-up, "N nuove registrazioni" (`announceRecordingsRefresh`). Each path checks the "Notifiche" switch
/// (`NotificationPolicy.enabledKey` in `defaults`) and macOS's permission before recording
/// anything as notified: with the switch off nothing reaches the notification center and nothing
/// is recorded, so a conflict still open when notifications come back on is still announced (#64).
/// Clearing a record is different: when a run finds no conflicts, the conflicts record is
/// cleared even while off, so conflicts that come back later are announced as new.
@MainActor final class SyncNotificationCoordinator {
    private static let prefix = "io.github.tvaccari.beepbar.notification.v2"
    private let deduplication: NotificationDeduplicationStore
    private let defaults: UserDefaults
    private let center: NotificationCenterClient
#if DEBUG
    var beforeNotificationForTesting: (@MainActor () async -> Void)?
#endif

    init(defaults: UserDefaults = .standard, center: NotificationCenterClient = SystemNotificationCenter()) {
        self.defaults = defaults
        self.center = center
        deduplication = NotificationDeduplicationStore(defaults: defaults, prefix: Self.prefix)
    }

    var isEnabled: Bool { NotificationPolicy.isEnabled(storedValue: defaults.object(forKey: NotificationPolicy.enabledKey)) }

    func authorization() async -> NotificationAuthorization {
        await center.authorization()
    }

    func requestAuthorizationIfNeeded() async {
        guard isEnabled else { return }
        let authorization = await center.authorization()
        // Re-checked after the read: the user may have turned the switch off while it was pending,
        // and macOS's prompt must not appear after that.
        guard NotificationPolicy.shouldRequestAuthorization(enabled: isEnabled, authorization: authorization) else { return }
        await center.requestAuthorization()
    }

    /// Validity is rechecked after permission reads and between sends: a disconnected account,
    /// changed folder or newer result must not announce or record an obsolete condition.
    func notifyAutomaticRun(installed: Int, conflicts: [ConflictRecord], failures: Int, isCurrent: @MainActor () -> Bool = { true }) async {
        guard isCurrent() else { return }
        if conflicts.isEmpty { deduplication.resolve(condition: "conflicts") }
        guard await canSend(), isCurrent() else { return }
        if !conflicts.isEmpty, isEnabled {
            let fingerprint = NotificationFingerprint.conflicts(conflicts)
            if deduplication.shouldNotify(condition: "conflicts", fingerprint: fingerprint, now: Date()) {
                await center.send(identifier: "beepbar-conflicts", title: conflicts.count == 1 ? tr("Conflitto da risolvere", "Conflict to resolve") : tr("Conflitti da risolvere", "Conflicts to resolve"), body: SyncCopy.conflictNotificationBody(conflicts.count), destination: .conflicts)
            }
        }
        if failures > 0 {
            await notify(issue: .partialSync, isCurrent: isCurrent)
        } else if installed > 0, isEnabled, isCurrent() {
            await sendNewMaterials(installed)
        }
    }

    /// A manual run started from the menu leaves no menu open to show its result, so say when new
    /// materials arrived. Nothing new stays silent: the icon returning to normal is enough.
    func notifyManualRun(added: Int, isCurrent: @MainActor () -> Bool = { true }) async {
#if DEBUG
        if let beforeNotificationForTesting { await beforeNotificationForTesting(); return }
#endif
        guard added > 0, await canSend(), isCurrent() else { return }
        await sendNewMaterials(added)
    }

    func notify(issue: AutomaticNotificationIssue, isCurrent: @MainActor () -> Bool = { true }) async {
#if DEBUG
        if let beforeNotificationForTesting { await beforeNotificationForTesting(); return }
#endif
        guard await canSend(), isCurrent() else { return }
        guard isEnabled, deduplication.shouldNotify(condition: issue.rawValue, fingerprint: issue.rawValue, now: Date()) else { return }
        await center.send(identifier: "beepbar-\(issue.rawValue)", title: issue.title, body: issue.body, destination: .home)
    }

    /// Identifier of the new-recordings notification. Fixed, so a later post replaces the one
    /// still in Notification Centre instead of stacking "1 nuova registrazione" after every sync:
    /// the Recordings page's dots list every unseen lecture anyway. Never change it: an older
    /// notification would then stack next to the new one.
    static let recordingsIdentifier = "beepbar-new-recordings"

    /// The single entry point of the Recordings follow-up of a sync (automatic or manual): it
    /// announces the lectures that refresh first observed, and nothing for any other ending.
    /// The follow-up (`WeBeepAuthenticationController`) calls it once, after the refresh ends:
    /// `await notificationCoordinator.announceRecordingsRefresh(outcome, isCurrent: isCurrent)`.
    /// The decision is `RecordingsNotificationDecision` (pure, in Core); the switch is read here
    /// and read again, with macOS's permission and `isCurrent`, at send time.
    func announceRecordingsRefresh(_ outcome: RecordingsSyncOutcome, isCurrent: @MainActor () -> Bool = { true }) async {
        guard let count = RecordingsNotificationDecision.count(for: outcome, notificationsEnabled: isEnabled) else { return }
        await postRecordingsSummary(newCount: count, isCurrent: isCurrent)
    }

    /// Sends "N nuove registrazioni", opening Registrazioni on click, when `newCount` is above
    /// zero, the "Notifiche" switch is on, macOS allows it and the result is still current
    /// (`isCurrent`: a sign-out, account or site change while the permission read was pending
    /// must not announce the old account's lectures). Same gating as the materials notifications
    /// (`canSend`, then a synchronous `isEnabled` with no suspension before the send).
    ///
    /// No deduplication record: `newCount` already counts only lectures first observed in this
    /// refresh, so a later run that finds nothing new posts nothing, and a fingerprint on the
    /// count would wrongly swallow a genuine second "1 nuova registrazione". The text carries the
    /// count only, never a course or lecture name (`NotificationPolicy.recordingsNotification`).
    func postRecordingsSummary(newCount: Int, isCurrent: @MainActor () -> Bool = { true }) async {
        guard let text = NotificationPolicy.recordingsNotification(newCount: newCount), isCurrent() else { return }
        guard await canSend(), isCurrent(), isEnabled else { return }
        await center.send(identifier: Self.recordingsIdentifier, title: text.title.text, body: text.body.text, destination: .recordings)
    }

    func clearFailure() {
        for issue in [AutomaticNotificationIssue.authenticationExpired, .serviceUnavailable, .incompatibleResponse, .partialSync] {
            deduplication.resolve(condition: issue.rawValue)
        }
    }

    /// The switch first: when it is off, macOS isn't even asked for its permission status. Checked
    /// again once macOS answers, since the user may have turned it off meanwhile. Every send is
    /// also preceded by a synchronous `isEnabled` check with no suspension in between, because a
    /// run can send twice (conflicts, then new materials) with an await between the two.
    private func canSend() async -> Bool {
        guard isEnabled else { return false }
        let authorization = await center.authorization()
        return NotificationPolicy.canSend(enabled: isEnabled, authorization: authorization)
    }

    private func sendNewMaterials(_ count: Int) async {
        await center.send(identifier: "beepbar-new-files-\(UUID().uuidString)", title: count == 1 ? tr("Nuovo materiale disponibile", "New material available") : tr("Nuovi materiali disponibili", "New materials available"), body: SyncCopy.newMaterialsNotificationBody(count), destination: .activity)
    }
}

/// BeepBar's `UNUserNotificationCenterDelegate`, set at launch.
/// - A click on a notification opens BeepBar on the page it is about (`NotificationDestination`).
/// - A notification arriving while BeepBar's window is in front is still shown as a banner; without
///   a delegate macOS drops it.
/// The callbacks come from the notification center, off the main actor: they only read the
/// notification's plain values and hop to the main actor with `Task { @MainActor in … }`, never
/// touching main-actor state synchronously (AGENTS.md hard rule, issue #30).
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let open: @MainActor @Sendable (NotificationDestination) -> Void

    init(open: @escaping @MainActor @Sendable (NotificationDestination) -> Void) {
        self.open = open
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let userInfo = response.notification.request.content.userInfo
        completionHandler()
        route(isDefaultAction: isDefaultAction, userInfo: userInfo)
    }

    /// The click path without `UNNotificationResponse` (which tests can't build): reads the
    /// destination from the notification's plain values and opens it inside the main-actor hop.
    /// A destination this build doesn't know (sent by a newer build, clicked after a rollback)
    /// opens Courses (`NotificationPolicy.destination`); a dismissal opens nothing.
    func route(isDefaultAction: Bool, userInfo: [AnyHashable: Any]) {
        guard let destination = NotificationPolicy.destination(isDefaultAction: isDefaultAction, userInfo: userInfo) else { return }
        let open = open
        Task { @MainActor in open(destination) }
    }
}

extension ShellPage {
    init(_ destination: NotificationDestination) {
        switch destination {
        case .conflicts: self = .conflicts
        case .activity: self = .activity
        case .home: self = .home
        case .recordings: self = .recordings
        }
    }
}
