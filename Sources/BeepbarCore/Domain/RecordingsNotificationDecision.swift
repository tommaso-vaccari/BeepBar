import Foundation

/// Whether the Recordings follow-up of a sync announces new lectures, and with which count.
///
/// One aggregated notification per sync ("2 nuove registrazioni"), and only for lectures first
/// observed in this refresh (`RecordingsSyncOutcome.refreshed(newlyPublished:)`), which is
/// already 0 for a baseline listing (a course's first complete listing, #106): a student who
/// turns Recordings on is not told that the whole archive is "new".
///
/// Every other ending is silent, by the owner's decision: an expired Polimi session degrades to
/// the sign-in prompt on the Recordings page (no notification, no window), Polimi not answering
/// and a cancelled refresh are not the student's problem, and a skipped refresh asked nothing.
/// The materials notifications (`SyncNotificationCoordinator`) are unaffected either way.
public enum RecordingsNotificationDecision {
    /// The count to announce, or nil to stay silent.
    ///
    /// - `notificationsEnabled` is the "Notifiche" switch; macOS's permission and the result
    ///   still being current are checked by the coordinator at send time, after this decision.
    /// - A refresh where some courses failed (`failedKeys > 0`) still announces the lectures the
    ///   other courses newly published: those are real, and the failure itself is never notified.
    public static func count(for outcome: RecordingsSyncOutcome, notificationsEnabled: Bool) -> Int? {
        guard notificationsEnabled, case let .refreshed(newlyPublished, _) = outcome, newlyPublished > 0 else { return nil }
        return newlyPublished
    }
}
