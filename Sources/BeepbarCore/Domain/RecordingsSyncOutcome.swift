import Foundation

/// How a background refresh of the Recordings listings ended (the follow-up of a sync run).
/// Never an error to show: a failure of this refresh must not touch the materials sync state.
public enum RecordingsSyncOutcome: Sendable, Equatable {
    /// Nothing was asked of Polimi (switched off, no session, not signed in, no keys, ...).
    case skipped(RecordingsSyncSkipReason)
    /// The listings were requested; `newlyPublished` lectures were first observed in this
    /// refresh (0 for a baseline), `failedKeys` courses could not be refreshed.
    case refreshed(newlyPublished: Int, failedKeys: Int)
    /// The Polimi session lapsed: the page shows the sign-in prompt; no window was opened.
    /// `newlyPublished`: lectures the courses listed before the session lapsed first published in
    /// this refresh (already on the page with their dots), 0 when it lapsed before any listing.
    case needsSignIn(newlyPublished: Int)
    /// Polimi did not answer (one timeout stops the batch). `newlyPublished`: as for
    /// `needsSignIn`, the lectures the courses listed before the timeout first published.
    case unavailable(newlyPublished: Int)
    /// The surrounding task was cancelled or the identity changed mid-refresh. Carries no count
    /// on purpose: a turn-off, a sign-in or an account change must never announce what an older
    /// identity listed, and the sync that asked for the refresh no longer wants it.
    case cancelled
}
