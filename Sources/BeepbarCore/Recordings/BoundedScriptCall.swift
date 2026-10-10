import Foundation
#if canImport(os)
import os
#endif

/// How a call into the page's JavaScript ended, as `RecmanWebSession` sees it (issue #112).
public enum ScriptCallOutcome<Answer: Sendable & Equatable>: Sendable, Equatable {
    /// WebKit called back: the script's answer, or nil when it threw or answered something else.
    case answered(Answer)
    /// `close()`, a newer operation or the awaiting task's cancellation ended the call. The page
    /// may still be running the script; its answer, if it ever comes, is ignored.
    case interrupted
    /// The script answered nothing within the allowed time.
    case timedOut
}

/// The decision of when a script call is over, kept apart from WebKit so Core tests cover it.
///
/// `callAsyncJavaScript` calls back when the script's Promise settles. A Promise that never
/// settles (a page that changed, a web process that stalled) would leave whoever awaits it
/// suspended for as long as WebKit keeps the callback alive, and nothing in the session could end
/// it: `close()` and a new operation ended entries and page loads, not scripts (#112). This state
/// machine settles exactly once, from whichever signal comes first, and records what arrives
/// after that so a late native callback can never resume a continuation twice or hand an old
/// operation's answer to a new one.
public struct ScriptCallState<Answer: Sendable & Equatable>: Sendable, Equatable {
    public typealias Outcome = ScriptCallOutcome<Answer>

    /// The signal that ended the call, once one has.
    public private(set) var outcome: Outcome?
    /// Signals that arrived after the call had ended, in order. Diagnostics only.
    public private(set) var lateSignals: [Outcome] = []

    public init() {}

    /// Records `signal`. Returns true exactly once per call: for the signal that ended it, which
    /// is when the awaiting continuation must be resumed. Every later signal is kept in
    /// `lateSignals` and changes nothing else.
    public mutating func settle(_ signal: Outcome) -> Bool {
        guard outcome == nil else {
            lateSignals.append(signal)
            return false
        }
        outcome = signal
        return true
    }
}

/// One pending script call: WebKit answers it, the session may interrupt it, a timer bounds it,
/// and `wait(timeout:)` returns the first of those exactly once.
///
/// Signals may come from any thread, so the state sits behind a lock instead of an actor: the
/// cancellation handler of `withTaskCancellationHandler` runs synchronously wherever the task
/// is cancelled, and a hop to the main actor there would be one more thing that cannot run while
/// the awaiting task is what blocks it. WebKit's completion handlers arrive on the main actor; the
/// lock makes that irrelevant to correctness.
public final class BoundedScriptCall<Answer: Sendable & Equatable>: @unchecked Sendable {
    public typealias Outcome = ScriptCallOutcome<Answer>

    private struct Storage {
        var state = ScriptCallState<Answer>()
        var continuation: CheckedContinuation<Outcome, Never>?
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    public init() {}

    /// What ended the call, or nil while it is pending.
    public var outcome: Outcome? { storage.withLock { $0.state.outcome } }
    /// Signals that came after the call had ended, in order.
    public var lateSignals: [Outcome] { storage.withLock { $0.state.lateSignals } }

    /// The native callback: the script's answer.
    public func answer(_ answer: Answer) { settle(.answered(answer)) }

    /// Ends the call now if it is still pending: `close()`, a newer operation, or a cancelled task.
    public func interrupt() { settle(.interrupted) }

    /// Returns the first signal, waiting at most `timeout` for it. Cancelling the awaiting task
    /// ends the wait with `.interrupted` right away. Called once per call.
    public func wait(timeout: Duration) async -> Outcome {
        let timer = Task { [weak self] in
            // A cancelled sleep must not count as a timeout: the call ended some other way.
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.settle(.timedOut)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let settled: Outcome? = storage.withLock { box in
                    if let outcome = box.state.outcome { return outcome }
                    box.continuation = continuation
                    return nil
                }
                if let settled { continuation.resume(returning: settled) }
            }
        } onCancel: {
            settle(.interrupted)
        }
    }

    private func settle(_ signal: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>? = storage.withLock { box in
            guard box.state.settle(signal) else { return nil }
            defer { box.continuation = nil }
            return box.continuation
        }
        // Outside the lock: the state is already settled, so later signals need not wait while the
        // waiting task is handed back to the runtime.
        continuation?.resume(returning: signal)
    }
}
