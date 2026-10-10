import Foundation
import Testing
@testable import BeepbarCore

/// The decision that ends a page-script call exactly once (#112). The failure these tests guard
/// is the one `RecmanWebSession` could not rule out before: a script whose Promise never settles
/// keeping an operation suspended through `close()`, a new operation or a cancelled task, or a
/// callback that arrives after the call ended resuming a continuation twice or handing an old
/// operation's answer to the next one.
struct BoundedScriptCallTests {
    typealias State = ScriptCallState<String>
    typealias Call = BoundedScriptCall<String>

    /// Generous enough that a slow CI machine never reaches it in the tests that must end another way.
    private let never: Duration = .seconds(10)

    // MARK: The pure state

    /// Only the first signal ends the call; the ones after it are kept apart and change nothing.
    @Test func onlyTheFirstSignalSettlesAndTheRestAreRecordedAsLate() {
        var state = State()
        #expect(state.outcome == nil)
        let first = state.settle(.timedOut)
        #expect(first)
        #expect(state.outcome == .timedOut)
        // The native callback coming after the timeout: the typical late signal.
        let lateAnswer = state.settle(.answered("late"))
        let lateInterrupt = state.settle(.interrupted)
        #expect(lateAnswer == false)
        #expect(lateInterrupt == false)
        #expect(state.outcome == .timedOut)
        #expect(state.lateSignals == [.answered("late"), .interrupted])
    }

    @Test func anAnswerBeforeAnythingElseIsTheOutcome() {
        var state = State()
        let first = state.settle(.answered("ok"))
        let late = state.settle(.timedOut)
        #expect(first)
        #expect(late == false)
        #expect(state.outcome == .answered("ok"))
        #expect(state.lateSignals == [.timedOut])
    }

    // MARK: The pending call

    /// The normal path: WebKit answers, the timer is beaten, nothing is late.
    @Test func theNativeAnswerEndsTheWait() async {
        let call = Call()
        let waiting = Task { await call.wait(timeout: never) }
        call.answer("submitted")
        #expect(await waiting.value == .answered("submitted"))
        #expect(call.lateSignals.isEmpty)
    }

    /// `close()` or a newer operation ends a script whose Promise never settles; the answer that
    /// never came is not waited for.
    @Test func anInterruptEndsAScriptThatNeverAnswers() async {
        let call = Call()
        let waiting = Task { await call.wait(timeout: never) }
        call.interrupt()
        #expect(await waiting.value == .interrupted)
    }

    /// The session may interrupt a call before the operation gets to await it (a cancellation that
    /// lands between starting the script and the suspension): the wait must not hang on a signal
    /// that already came.
    @Test func anInterruptBeforeTheWaitIsNotLost() async {
        let call = Call()
        call.interrupt()
        #expect(await call.wait(timeout: never) == .interrupted)
    }

    /// Cancelling the awaiting task (the controller's `worker?.cancel()`) ends the wait right
    /// away, without waiting for WebKit or the timeout.
    @Test func cancellingTheAwaitingTaskInterruptsTheCall() async {
        let call = Call()
        let started = Mark()
        let waiting = Task {
            await started.set()
            return await call.wait(timeout: never)
        }
        await started.wait()
        waiting.cancel()
        #expect(await waiting.value == .interrupted)
        #expect(call.outcome == .interrupted)
    }

    @Test func aTaskCancelledBeforeWaitingDoesNotWait() async {
        let call = Call()
        let waiting = Task {
            // The task is cancelled before it gets here; the wait must still return at once.
            await Mark.yieldUntilCancelled()
            return await call.wait(timeout: never)
        }
        waiting.cancel()
        #expect(await waiting.value == .interrupted)
    }

    /// A Promise that never settles ends at the timeout, not never.
    @Test func aScriptThatNeverAnswersTimesOut() async {
        let call = Call()
        #expect(await call.wait(timeout: .milliseconds(30)) == .timedOut)
        // The native callback coming in afterwards is ignored, exactly once was already used up.
        call.answer("late")
        #expect(call.outcome == .timedOut)
        #expect(call.lateSignals == [.answered("late")])
    }

    /// An answer in time is not turned into a timeout by the timer firing later.
    @Test func anAnswerInTimeIsNotOvertakenByTheTimer() async throws {
        let call = Call()
        let waiting = Task { await call.wait(timeout: .milliseconds(40)) }
        call.answer("fast")
        #expect(await waiting.value == .answered("fast"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(call.outcome == .answered("fast"))
        #expect(call.lateSignals.isEmpty)
    }

    /// After an interrupt, both the late native answer and a late timer leave the outcome alone.
    @Test func lateSignalsAfterAnInterruptAreIgnored() async throws {
        let call = Call()
        let waiting = Task { await call.wait(timeout: .milliseconds(40)) }
        call.interrupt()
        #expect(await waiting.value == .interrupted)
        call.answer("late")
        try await Task.sleep(for: .milliseconds(120))
        #expect(call.outcome == .interrupted)
        #expect(call.lateSignals == [.answered("late")])
    }

    /// A flag a task raises so the test knows it has reached the await before cancelling it.
    private actor Mark {
        private var raised = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func set() {
            raised = true
            waiters.forEach { $0.resume() }
            waiters = []
        }

        func wait() async {
            if raised { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        static func yieldUntilCancelled() async {
            while !Task.isCancelled { await Task.yield() }
        }
    }
}
