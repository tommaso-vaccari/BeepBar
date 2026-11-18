import Foundation

public struct SyncProgressThrottle: Sendable {
    private let minimumInterval: Duration
    private var lastEmission: ContinuousClock.Instant?
    private var lastProgress: SyncProgress?

    public init(minimumInterval: Duration) {
        self.minimumInterval = minimumInterval
    }

    public mutating func reset() {
        lastEmission = nil
        lastProgress = nil
    }

    public mutating func accept(_ progress: SyncProgress, now: ContinuousClock.Instant) -> SyncProgress? {
        guard progress.completed >= (lastProgress?.completed ?? -1), progress != lastProgress else { return nil }
        let isFinal = progress.total > 0 && progress.completed == progress.total
        if !isFinal, let lastEmission, lastEmission.duration(to: now) < minimumInterval { return nil }
        lastProgress = progress
        lastEmission = now
        return progress
    }
}
