import Foundation

/// macOS's permission for BeepBar's notifications, mirrored from `UNAuthorizationStatus` so the
/// decisions below can be tested without the real notification center.
public enum NotificationAuthorization: Sendable, Equatable {
    /// Never asked: BeepBar may ask once.
    case notDetermined
    /// Refused or switched off in System Settings → Notifications. Only the user can change it there.
    case denied
    /// macOS delivers BeepBar's notifications (authorized, or provisional).
    case allowed
}

/// Where a click on a BeepBar notification takes the user.
public enum NotificationDestination: String, Sendable, Equatable {
    /// "Conflitti da risolvere": the Conflicts page, where the choice is made.
    case conflicts
    /// "Nuovi materiali": the Activity page, which lists what arrived.
    case activity
    /// Account and sync problems: the Courses page, whose status explains them and offers the fix.
    case home
}

/// Decisions behind BeepBar's notifications and the "Notifiche" switch (#64): on by default for
/// everyone, and when the user turns them off nothing reaches macOS's notification center, not
/// even a permission request.
public enum NotificationPolicy {
    /// The switch's `UserDefaults` key. Absent means on: existing installs keep their notifications.
    public static let enabledKey = "io.github.tvaccari.beepbar.notifications-enabled.v1"
    /// Key in a notification's `userInfo` naming its `NotificationDestination`.
    public static let destinationKey = "destination"

    /// Reads the switch from its stored value; anything that isn't a stored `Bool` means on.
    public static func isEnabled(storedValue: Any?) -> Bool {
        (storedValue as? Bool) ?? true
    }

    /// Ask macOS for permission only while notifications are on and macOS never asked. Turning
    /// the switch off must not trigger macOS's prompt as a side effect of a sync.
    public static func shouldRequestAuthorization(enabled: Bool, authorization: NotificationAuthorization) -> Bool {
        enabled && authorization == .notDetermined
    }

    /// A notification is sent only when the switch is on and macOS allows it. Checked before any
    /// deduplication bookkeeping, so a condition that arose while notifications were off is not
    /// recorded as already notified and can still be notified once they are back on.
    public static func canSend(enabled: Bool, authorization: NotificationAuthorization) -> Bool {
        enabled && authorization == .allowed
    }

    /// Where a click leads. Only a click on the notification itself opens BeepBar (`isDefaultAction`);
    /// dismissing it does nothing. A missing or unknown destination opens the Courses page.
    public static func destination(isDefaultAction: Bool, userInfo: [AnyHashable: Any]) -> NotificationDestination? {
        guard isDefaultAction else { return nil }
        return (userInfo[destinationKey] as? String).flatMap(NotificationDestination.init(rawValue:)) ?? .home
    }
}
