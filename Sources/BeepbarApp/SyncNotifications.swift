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
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional: .allowed
        default: .denied
        }
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func send(identifier: String, title: String, body: String, destination: NotificationDestination) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Read back by `NotificationResponder` when the user clicks the notification.
        content.userInfo = [NotificationPolicy.destinationKey: destination.rawValue]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

/// Stands in for the notification center where none may be touched: test controllers that don't
/// pass their own, so no test can reach the real one. Never asked, never allowed, sends nothing.
struct InertNotificationCenter: NotificationCenterClient {
    func authorization() async -> NotificationAuthorization { .denied }
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

/// Decides and sends every BeepBar notification. Each path first checks the "Notifiche" switch
/// (`NotificationPolicy.enabledKey` in `defaults`) and macOS's permission, before any
/// deduplication bookkeeping: with the switch off nothing reaches the notification center, and
/// nothing is recorded as notified, so a conflict still open when notifications come back on is
/// still announced (#64).
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
        guard NotificationPolicy.shouldRequestAuthorization(enabled: isEnabled, authorization: await center.authorization()) else { return }
        await center.requestAuthorization()
    }

    func notifyAutomaticRun(installed: Int, conflicts: [ConflictRecord], failures: Int) async {
        if conflicts.isEmpty { deduplication.resolve(condition: "conflicts") }
        guard await canSend() else { return }
        if !conflicts.isEmpty {
            let fingerprint = NotificationFingerprint.conflicts(conflicts)
            if deduplication.shouldNotify(condition: "conflicts", fingerprint: fingerprint, now: Date()) {
                await center.send(identifier: "beepbar-conflicts", title: conflicts.count == 1 ? tr("Conflitto da risolvere", "Conflict to resolve") : tr("Conflitti da risolvere", "Conflicts to resolve"), body: SyncCopy.conflictNotificationBody(conflicts.count), destination: .conflicts)
            }
        }
        if failures > 0 {
            await notify(issue: .partialSync)
        } else if installed > 0 {
            await sendNewMaterials(installed)
        }
    }

    /// A manual run started from the menu leaves no menu open to show its result, so say when new
    /// materials arrived. Nothing new stays silent: the icon returning to normal is enough.
    func notifyManualRun(added: Int) async {
#if DEBUG
        if let beforeNotificationForTesting { await beforeNotificationForTesting(); return }
#endif
        guard added > 0, await canSend() else { return }
        await sendNewMaterials(added)
    }

    func notify(issue: AutomaticNotificationIssue) async {
#if DEBUG
        if let beforeNotificationForTesting { await beforeNotificationForTesting(); return }
#endif
        guard await canSend() else { return }
        guard deduplication.shouldNotify(condition: issue.rawValue, fingerprint: issue.rawValue, now: Date()) else { return }
        await center.send(identifier: "beepbar-\(issue.rawValue)", title: issue.title, body: issue.body, destination: .home)
    }

    func clearFailure() {
        for issue in [AutomaticNotificationIssue.authenticationExpired, .serviceUnavailable, .incompatibleResponse, .partialSync] {
            deduplication.resolve(condition: issue.rawValue)
        }
    }

    /// The switch first: when it is off, macOS isn't even asked for its permission status.
    private func canSend() async -> Bool {
        guard isEnabled else { return false }
        return NotificationPolicy.canSend(enabled: true, authorization: await center.authorization())
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
        let destination = NotificationPolicy.destination(
            isDefaultAction: response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        completionHandler()
        guard let destination else { return }
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
        }
    }
}
