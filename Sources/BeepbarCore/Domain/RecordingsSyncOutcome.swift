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
    case needsSignIn
    /// Polimi did not answer (one timeout stops the batch).
    case unavailable
    /// The surrounding task was cancelled or the identity changed mid-refresh.
    case cancelled
}
