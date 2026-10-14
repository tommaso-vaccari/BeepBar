import Foundation

/// How a background refresh of the Recordings listings ended (the follow-up of a sync run).
/// Never an error to show: a failure of this refresh must not touch the materials sync state.
public enum RecordingsSyncOutcome: Sendable, Equatable {
    case skipped(RecordingsSyncSkipReason)
    case refreshed(newlyPublished: Int, failedKeys: Int)
    case needsSignIn
    case unavailable
    case cancelled
}
