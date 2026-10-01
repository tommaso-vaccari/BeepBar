import Testing
@testable import BeepbarCore

/// The decisions behind BeepBar's notifications and the "Notifiche" switch (#64).
struct NotificationPolicyTests {
    /// On by default: an install that never touched the switch (every existing user) keeps its
    /// notifications, and only a stored `false` turns them off.
    @Test func theSwitchIsOnUnlessTurnedOff() {
        #expect(NotificationPolicy.isEnabled(storedValue: nil))
        #expect(NotificationPolicy.isEnabled(storedValue: true))
        #expect(!NotificationPolicy.isEnabled(storedValue: false))
        #expect(NotificationPolicy.isEnabled(storedValue: "garbage"), "an unreadable value must not silence notifications")
    }

    /// macOS is asked for permission only while the switch is on and it never asked: with the
    /// switch off, a sync must not make macOS's prompt appear.
    @Test func permissionIsRequestedOnlyWhenOnAndNeverAsked() {
        #expect(NotificationPolicy.shouldRequestAuthorization(enabled: true, authorization: .notDetermined))
        #expect(!NotificationPolicy.shouldRequestAuthorization(enabled: false, authorization: .notDetermined))
        #expect(!NotificationPolicy.shouldRequestAuthorization(enabled: true, authorization: .denied))
        #expect(!NotificationPolicy.shouldRequestAuthorization(enabled: true, authorization: .allowed))
    }

    /// A notification needs both the switch and macOS's permission.
    @Test func sendingNeedsTheSwitchAndMacOSPermission() {
        #expect(NotificationPolicy.canSend(enabled: true, authorization: .allowed))
        #expect(!NotificationPolicy.canSend(enabled: false, authorization: .allowed))
        #expect(!NotificationPolicy.canSend(enabled: true, authorization: .denied))
        #expect(!NotificationPolicy.canSend(enabled: true, authorization: .notDetermined))
    }

    /// A click opens the page the notification is about; dismissing it opens nothing; a
    /// notification without a readable destination (e.g. sent by an older version) opens Courses.
    @Test func aClickOpensThePageTheNotificationIsAbout() {
        #expect(NotificationPolicy.destination(isDefaultAction: true, userInfo: ["destination": "conflicts"]) == .conflicts)
        #expect(NotificationPolicy.destination(isDefaultAction: true, userInfo: ["destination": "activity"]) == .activity)
        #expect(NotificationPolicy.destination(isDefaultAction: true, userInfo: ["destination": "home"]) == .home)
        #expect(NotificationPolicy.destination(isDefaultAction: true, userInfo: [:]) == .home)
        #expect(NotificationPolicy.destination(isDefaultAction: true, userInfo: ["destination": "unknown"]) == .home)
        #expect(NotificationPolicy.destination(isDefaultAction: true, userInfo: ["destination": 3]) == .home)
        #expect(NotificationPolicy.destination(isDefaultAction: false, userInfo: ["destination": "conflicts"]) == nil)
    }

    /// The key stored in `UserDefaults` is part of the installed app's state: renaming it would
    /// silently turn notifications back on for everyone who turned them off.
    @Test func theStoredKeyNeverChanges() {
        #expect(NotificationPolicy.enabledKey == "io.github.tvaccari.beepbar.notifications-enabled.v1")
        #expect(NotificationPolicy.destinationKey == "destination")
    }
}
