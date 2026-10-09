import Foundation
import Network
import os

/// Takes one network-path snapshot for Data Saver, without leaving a monitor running at rest.
public enum NetworkPathReader {
    /// Returns `nil` on timeout or cancellation. Callers must check cancellation before starting work.
    public static func current(timeout: Duration = .seconds(2)) async -> NetworkPathConditions? {
        await current { receive, timedOut in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "io.github.tvaccari.beepbar.network-path")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            monitor.pathUpdateHandler = { path in
                receive(NetworkPathConditions(isSatisfied: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained))
            }
            let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
            timer.schedule(deadline: .now() + .nanoseconds(Int(nanoseconds)))
            timer.setEventHandler(handler: timedOut)
            monitor.start(queue: queue)
            timer.resume()
            return {
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                timer.setEventHandler(handler: nil)
                timer.cancel()
            }
        }
    }

    internal static func current(start: @Sendable (
        @escaping @Sendable (NetworkPathConditions?) -> Void,
        @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void) async -> NetworkPathConditions? {
        let read = PathRead()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard read.install(continuation) else { return }
                // A callback or cancellation can finish during start. In that case the returned
                // cleanup is run immediately, rather than leaving newly started resources alive.
                let cleanup = start({ read.finish($0) }, { read.finish(nil) })
                read.install(cleanup)
            }
        } onCancel: {
            read.finish(nil)
        }
    }
}

private final class PathRead: Sendable {
    private struct State {
        var completed = false
        var continuation: CheckedContinuation<NetworkPathConditions?, Never>?
        var cleanup: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<NetworkPathConditions?, Never>) -> Bool {
        let installed = state.withLock { state in
            guard !state.completed else { return false }
            state.continuation = continuation
            return true
        }
        if !installed { continuation.resume(returning: nil) }
        return installed
    }

    func install(_ cleanup: @escaping @Sendable () -> Void) {
        let completed = state.withLock { state in
            guard !state.completed else { return true }
            state.cleanup = cleanup
            return false
        }
        if completed { cleanup() }
    }

    func finish(_ result: NetworkPathConditions?) {
        let resources = state.withLock { state -> (CheckedContinuation<NetworkPathConditions?, Never>?, (@Sendable () -> Void)?) in
            guard !state.completed else { return (nil, nil) }
            state.completed = true
            defer { state.continuation = nil; state.cleanup = nil }
            return (state.continuation, state.cleanup)
        }
        resources.1?()
        resources.0?.resume(returning: result)
    }
}
