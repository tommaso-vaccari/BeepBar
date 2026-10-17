import Foundation

/// Whether the Recordings follow-up of a sync announces new lectures, and with which count.
///
/// One aggregated notification per sync ("2 nuove registrazioni"), and only for lectures first
/// observed in this refresh (`RecordingsSyncOutcome.refreshed(newlyPublished:)`), which is
/// already 0 for a baseline listing (a course's first complete listing, #106): a student who
/// turns Recordings on is not told that the whole archive is "new".
///
/// A batch cut short by the Polimi session lapsing or Polimi not answering still announces the
/// lectures its earlier courses already published (issue #190): they are on the page with their
/// dots, and the next sync compares against them, so staying silent would lose that announcement
/// for good. The ending itself is never notified: an expired session degrades to the sign-in
/// prompt on the Recordings page (no window), an outage is not the student's problem.
///
/// Every other ending is silent, by the owner's decision: a cancelled refresh (the sync stopped,
/// Recordings turned off, a sign-in or an account change) and a skipped refresh that asked
/// nothing. The materials notifications (`SyncNotificationCoordinator`) are unaffected either way.
public enum RecordingsNotificationDecision {
    /// The count to announce, or nil to stay silent.
    ///
    /// - `notificationsEnabled` is the "Notifiche" switch; macOS's permission and the result
    ///   still being current are checked by the coordinator at send time, after this decision.
    /// - A refresh where some courses failed (`failedKeys > 0`) still announces the lectures the
    ///   other courses newly published: those are real, and the failure itself is never notified.
    /// - A batch ended by `needsSignIn` or `unavailable` announces the count it carries (#190).
    public static func count(for outcome: RecordingsSyncOutcome, notificationsEnabled: Bool) -> Int? {
        guard notificationsEnabled else { return nil }
        let newlyPublished: Int
        switch outcome {
        case .refreshed(let count, _), .needsSignIn(let count), .unavailable(let count): newlyPublished = count
        case .skipped, .cancelled: return nil
        }
        return newlyPublished > 0 ? newlyPublished : nil
    }
}
