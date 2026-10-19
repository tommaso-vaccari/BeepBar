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

/// Where a click on a BeepBar notification takes the user. The raw value travels in the
/// notification's `userInfo` (`NotificationPolicy.destinationKey`) and outlives the build that sent
/// it: a notification still in Notification Centre can be clicked after an update or a rollback.
/// Raw values therefore never change, and a reader never trusts them: `NotificationPolicy.destination`
/// turns a missing or unknown value (e.g. "recordings" read by a build older than that case) into
/// `.home` instead of failing.
public enum NotificationDestination: String, Sendable, Equatable {
    /// "Conflitti da risolvere": the Conflicts page, where the choice is made.
    case conflicts
    /// "Nuovi materiali": the Activity page, which lists what arrived.
    case activity
    /// Account and sync problems: the Courses page, whose status explains them and offers the fix.
    case home
    /// "Nuove registrazioni": the Recordings page, where the new lectures carry their dot.
    case recordings
}

/// The words of a notification, in both languages so the text is picked when it is sent.
public struct NotificationText: Equatable, Sendable {
    public let title: BilingualText
    public let body: BilingualText

    public init(title: BilingualText, body: BilingualText) {
        self.title = title
        self.body = body
    }
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

    /// The one notification a sync sends when it finds lectures published since the previous
    /// listing ("2 nuove registrazioni"), or nil when there are none: the caller sends nothing for
    /// zero, so a run that finds nothing new is silent. One per sync, whatever the number of
    /// courses (the caller sums `RecordingsSyncPolicy.newlyPublishedCount` over them).
    ///
    /// No course name, lecture title or other personal detail: the text shows on the lock screen
    /// and in Notification Centre, and the count alone says what the click opens.
    public static func recordingsNotification(newCount: Int) -> NotificationText? {
        guard newCount > 0 else { return nil }
        if newCount == 1 {
            return NotificationText(title: BilingualText("1 nuova registrazione", "1 new recording"),
                                    body: BilingualText("È disponibile in Registrazioni.", "It's available in Recordings."))
        }
        return NotificationText(title: BilingualText("\(newCount) nuove registrazioni", englishCount(newCount, "new recording", "new recordings")),
                                body: BilingualText("Sono disponibili in Registrazioni.", "They're available in Recordings."))
    }
}
