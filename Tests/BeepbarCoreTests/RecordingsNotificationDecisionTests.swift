@testable import BeepbarCore
import Testing

/// The decision behind "N nuove registrazioni": which endings of the Recordings follow-up announce.
struct RecordingsNotificationDecisionTests {
    /// A refresh that first observed lectures announces exactly that count, and only with the
    /// "Notifiche" switch on. Guards against announcing nothing, a wrong count, or ignoring the switch.
    @Test func aRefreshWithNewLecturesAnnouncesTheirCount() {
        #expect(RecordingsNotificationDecision.count(for: .refreshed(newlyPublished: 3, failedKeys: 0), notificationsEnabled: true) == 3)
        #expect(RecordingsNotificationDecision.count(for: .refreshed(newlyPublished: 1, failedKeys: 0), notificationsEnabled: true) == 1)
        #expect(RecordingsNotificationDecision.count(for: .refreshed(newlyPublished: 3, failedKeys: 0), notificationsEnabled: false) == nil)
    }

    /// Nothing new (and so a baseline listing, which publishes 0) is silent: guards against telling
    /// a student who just turned Recordings on that the whole archive is new.
    @Test func nothingNewIsSilent() {
        #expect(RecordingsNotificationDecision.count(for: .refreshed(newlyPublished: 0, failedKeys: 0), notificationsEnabled: true) == nil)
        #expect(RecordingsNotificationDecision.count(for: .refreshed(newlyPublished: 0, failedKeys: 4), notificationsEnabled: true) == nil)
    }

    /// Every ending that is not a refresh is silent, an expired session and failures included:
    /// guards against notifying a sign-in prompt or an outage.
    @Test func everyOtherEndingIsSilent() {
        let outcomes: [RecordingsSyncOutcome] = [.skipped(.switchedOff), .skipped(.notPolimi), .skipped(.ownerUnknown), .skipped(.noCourses),
                                                 .skipped(.materialsCancelled), .skipped(.materialsDeferred), .needsSignIn, .unavailable, .cancelled]
        for outcome in outcomes {
            #expect(RecordingsNotificationDecision.count(for: outcome, notificationsEnabled: true) == nil)
        }
    }

    /// Some courses failing does not hide the lectures the others published; the failure itself is not notified.
    @Test func partialFailureStillAnnouncesTheRealNewLectures() {
        #expect(RecordingsNotificationDecision.count(for: .refreshed(newlyPublished: 2, failedKeys: 1), notificationsEnabled: true) == 2)
    }
}
