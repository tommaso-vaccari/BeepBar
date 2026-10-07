import Foundation
import Network
import os

/// Reads the network the Mac is on, once. Used only when "Risparmio dati" is on, at the start of
/// an automatic run and again if that run is refused the network midway.
///
/// Deliberately not a long-lived monitor: BeepBar must stay quiet at rest (AGENTS.md,
/// "Performance"), so the monitor exists only for the instant it takes to report the current path.
public enum NetworkPathReader {
    /// The current path, or `nil` if macOS gives no answer within `timeout`. `nil` lets the run go
    /// ahead: the per-request limits in `NetworkAccess.dataSaver` still keep downloads off a hotspot.
    public static func current(timeout: Duration = .seconds(2)) async -> NetworkPathConditions? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "io.github.tvaccari.beepbar.network-path")
            // The first path update and the timeout race; whichever comes first answers, and the
            // other must not resume the continuation a second time (that traps).
            let answered = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (NetworkPathConditions?) -> Void = { conditions in
                let isFirst = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard isFirst else { return }
                // The handler holds `finish`, which holds the monitor: without dropping it, every
                // read would leave a monitor and its queue behind (quiet at rest, AGENTS.md).
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: conditions)
            }
            monitor.pathUpdateHandler = { path in
                finish(NetworkPathConditions(isSatisfied: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained))
            }
            monitor.start(queue: queue)
            let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { finish(nil) }
        }
    }
}
