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

    /// Every ending with nothing newly published is silent, an expired session and an outage
    /// included, and so is every skip and cancellation: guards against notifying a sign-in prompt
    /// or an outage itself.
    @Test func everyOtherEndingIsSilent() {
        let outcomes: [RecordingsSyncOutcome] = [.skipped(.switchedOff), .skipped(.notPolimi), .skipped(.ownerUnknown), .skipped(.noCourses),
                                                 .skipped(.materialsCancelled), .skipped(.materialsDeferred), .needsSignIn(newlyPublished: 0),
                                                 .unavailable(newlyPublished: 0), .cancelled]
        for outcome in outcomes {
            #expect(RecordingsNotificationDecision.count(for: outcome, notificationsEnabled: true) == nil)
        }
    }

    /// Some courses failing does not hide the lectures the others published; the failure itself is not notified.
    @Test func partialFailureStillAnnouncesTheRealNewLectures() {
        #expect(RecordingsNotificationDecision.count(for: .refreshed(newlyPublished: 2, failedKeys: 1), notificationsEnabled: true) == 2)
    }

    /// A batch cut short by Polimi not answering or the session lapsing still announces what its
    /// earlier courses published (issue #190), with the switch on only. Mutation: make those
    /// endings return nil in `count(for:)` (the lectures are never announced).
    @Test func aBatchCutShortStillAnnouncesWhatItPublished() {
        #expect(RecordingsNotificationDecision.count(for: .unavailable(newlyPublished: 2), notificationsEnabled: true) == 2)
        #expect(RecordingsNotificationDecision.count(for: .needsSignIn(newlyPublished: 1), notificationsEnabled: true) == 1)
        #expect(RecordingsNotificationDecision.count(for: .unavailable(newlyPublished: 2), notificationsEnabled: false) == nil)
    }
}
