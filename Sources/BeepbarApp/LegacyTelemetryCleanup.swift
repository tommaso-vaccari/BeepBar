import Foundation

/// One-time cleanup for people who update from a version that still had the daily telemetry
/// (TelemetryDeck), removed in #239. That version kept its state in these preferences; this
/// version never reads or writes them, so a leftover value is dead data that no longer
/// matches the privacy notice.
///
/// Why the code stays in the app: users can skip releases or leave the app closed for months,
/// and the first launch of whatever version they update to must still clear the leftovers.
/// Remove it only with evidence that those users have updated (#239).
///
/// Invariants a future edit must keep:
/// - Only the exact keys below are ever removed. Never match by prefix: an unrelated preference
///   must survive even if its name resembles one of these.
/// - Idempotent and cheap: a key that is absent is not touched, so a launch with nothing left
///   performs no preferences write (the app is meant to be silent at rest).
/// - No background scheduling to cancel here: the old version scheduled its daily check-in with
///   an in-process `NSBackgroundActivityScheduler` (identifier `…daily-telemetry`), which does not
///   survive a relaunch. The updated app starts without that registration and never creates it.
/// - Not on the quit path: it runs once, from `applicationDidFinishLaunching`.
enum LegacyTelemetryCleanup {
    /// Every preference the removed telemetry wrote, including the identifiers of its older
    /// versions (`dailyTelemetryInstallationID`, `dailyTelemetryMonthlyID`).
    nonisolated static let preferenceKeys: [String] = [
        "dailyTelemetryEnabled",
        "dailyTelemetryDisclosureVersion",
        "dailyTelemetryLastAttempt",
        "dailyTelemetryCountedMonth",
        "dailyTelemetryMonth",
        "dailyTelemetryMonthlyID",
        "dailyTelemetryInstallationID",
    ]

    /// Removes the leftover preferences that are present and returns the keys removed (empty
    /// when there was nothing to remove).
    @discardableResult
    nonisolated static func removeLeftovers(from defaults: UserDefaults) -> [String] {
        var removed: [String] = []
        for key in preferenceKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        return removed
    }
}
