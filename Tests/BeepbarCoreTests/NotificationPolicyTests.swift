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

    /// "recordings" opens the Recordings page, and a destination this build doesn't know (one a
    /// newer build sent, still clickable in Notification Centre after a rollback) falls back to
    /// Courses instead of failing; raw values are what older builds read and never change. Guards
    /// against a new-recordings notification opening the wrong page, and against an unknown value
    /// crashing or swallowing the click. Mutation: rename the case's raw value (e.g. "recording")
    /// and the first two expectations fail; drop the `?? .home` fallback and the unknown ones are nil.
    @Test func recordingsDestinationAndUnknownValuesAreSafe() {
        #expect(NotificationPolicy.destination(isDefaultAction: true, userInfo: ["destination": "recordings"]) == .recordings)
        #expect(NotificationDestination.recordings.rawValue == "recordings")
        #expect(NotificationDestination.conflicts.rawValue == "conflicts" && NotificationDestination.activity.rawValue == "activity"
                && NotificationDestination.home.rawValue == "home")
        for unknown in ["recordings-v2", "Recordings", "", "watchlist"] {
            #expect(NotificationPolicy.destination(isDefaultAction: true, userInfo: ["destination": unknown]) == .home, "\(unknown)")
        }
    }

    /// The new-recordings notification: nothing for zero (or a negative count), singular and
    /// plural agree in both languages, and the text carries only the count, never a course or
    /// lecture name. Guards against a "0 nuove registrazioni" notification after every quiet sync
    /// and against ungrammatical singulars. Mutation: drop the `newCount > 0` guard and the zero
    /// case returns text; drop the singular branch and 1 reads "1 nuove registrazioni".
    @Test func recordingsNotificationText() throws {
        #expect(NotificationPolicy.recordingsNotification(newCount: 0) == nil)
        #expect(NotificationPolicy.recordingsNotification(newCount: -2) == nil)
        let one = try #require(NotificationPolicy.recordingsNotification(newCount: 1))
        #expect(one.title == BilingualText("1 nuova registrazione", "1 new recording"))
        #expect(one.body == BilingualText("È disponibile in Registrazioni.", "It's available in Recordings."))
        let three = try #require(NotificationPolicy.recordingsNotification(newCount: 3))
        #expect(three.title == BilingualText("3 nuove registrazioni", "3 new recordings"))
        #expect(three.body == BilingualText("Sono disponibili in Registrazioni.", "They're available in Recordings."))
    }

    /// The key stored in `UserDefaults` is part of the installed app's state: renaming it would
    /// silently turn notifications back on for everyone who turned them off.
    @Test func theStoredKeyNeverChanges() {
        #expect(NotificationPolicy.enabledKey == "io.github.tvaccari.beepbar.notifications-enabled.v1")
        #expect(NotificationPolicy.destinationKey == "destination")
    }
}
