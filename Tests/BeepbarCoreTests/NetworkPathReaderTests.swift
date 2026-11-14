import Foundation
#if canImport(os)
import os
#endif
import Testing
@testable import BeepbarCore

struct NetworkPathReaderTests {
    /// The course list's network watch (#168) must not outlive its consumer: cancelling the task
    /// that iterates the stream stops the monitor. Fails if `onTermination` no longer stops it,
    /// which would leave a path monitor running at rest after the window closes.
    @Test func cancellingTheWatchStopsTheMonitor() async throws {
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let (started, markStarted) = AsyncStream<Void>.makeStream()
        let stream = NetworkPathReader.reachabilityChanges { yield in
            yield(true)
            markStarted.yield()
            return { stops.withLock { $0 += 1 } }
        }
        let task = Task { var values: [Bool] = []; for await value in stream { values.append(value) }; return values }
        for await _ in started { break }
        #expect(stops.withLock { $0 } == 0)
        task.cancel()
        #expect(await task.value == [true])
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while stops.withLock({ $0 }) == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(stops.withLock { $0 } == 1)
    }

    /// The same when the stream is dropped without ever being iterated to the end.
    @Test func droppingTheStreamStopsTheMonitor() async {
        let stops = OSAllocatedUnfairLock(initialState: 0)
        do {
            let stream = NetworkPathReader.reachabilityChanges { _ in { stops.withLock { $0 += 1 } } }
            _ = stream
        }
        #expect(stops.withLock { $0 } == 1)
    }

    @Test func cancellationBeforeInstallationStartsNothing() async {
        let provider = PathProvider()
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            return await NetworkPathReader.current { receive, timeout in
                let cleanup = provider.start(receive: receive, timeout: timeout)
                timeout()
                return cleanup
            }
        }
        task.cancel()
        gate.continuation.finish()
        #expect(await task.value == nil)
        #expect(provider.starts == 0)
        #expect(provider.cleanups == 0)
    }

    /// A provider that never answers (and whose timeout is never fired) ends only by cancellation:
    /// the read returns nil and the provider's cleanup has run. Finishing at all proves the
    /// cancellation arrived (a watchdog fires the provider timeout if cancellation is ignored); no
    /// 100 ms bound decides it, as it failed on a loaded machine (#243).
    @Test(.timeLimit(.minutes(2))) func cancellationOfSilentProviderIsPromptAndCleansUp() async {
        let provider = PathProvider()
        let task = Task { await NetworkPathReader.current(start: provider.start) }
        // Armed before waiting for the start, so a start that never comes is bounded too.
        let watchdog = Task.detached {
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            provider.finishStartSignal()
            provider.timeout()
            return true
        }
        guard await provider.waitForStart() else {
            task.cancel()
            watchdog.cancel()
            Issue.record("provider did not start")
            return
        }
        task.cancel()
        #expect(await task.value == nil)
        watchdog.cancel()
        #expect(await watchdog.value == false, "cancellation did not end the read")
        #expect(provider.cleanups == 1)
    }

    /// A cancellation that arrives while the provider is still installing (its `start` has not
    /// returned) still releases what it installs once it returns. The provider stays silent and its
    /// timeout is never fired, so the read ends only through the cancellation; awaiting it
    /// replaces the 100 ms poll that failed on a loaded machine (#243).
    @Test(.timeLimit(.minutes(2))) func cancellationDuringInstallationReleasesLateResources() async {
        let provider = PathProvider()
        let release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            await NetworkPathReader.current { receive, timeout in
                let cleanup = provider.start(receive: receive, timeout: timeout)
                release.wait()
                return cleanup
            }
        }
        let watchdog = Task.detached {
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            provider.finishStartSignal()
            provider.timeout()
            return true
        }
        guard await provider.waitForStart() else {
            task.cancel()
            release.signal()
            Issue.record("provider did not start")
            return
        }
        task.cancel()
        release.signal()
        #expect(await task.value == nil)
        watchdog.cancel()
        #expect(await watchdog.value == false, "cancellation did not end the read")
        #expect(provider.cleanups == 1)
    }

    @Test func synchronousCallbackReleasesResourcesInstalledLater() async {
        let provider = PathProvider()
        let result = await NetworkPathReader.current { receive, timeout in
            let cleanup = provider.start(receive: receive, timeout: timeout)
            receive(.hotspot)
            return cleanup
        }
        #expect(result == .hotspot)
        #expect(provider.cleanups == 1)
    }

    @Test func timeoutWithoutAPathCleansUp() async {
        let provider = PathProvider()
        let task = Task { await NetworkPathReader.current(start: provider.start) }
        await provider.waitForStart()
        provider.timeout()
        #expect(await task.value == nil)
        #expect(provider.cleanups == 1)
    }

    @Test(arguments: 0..<30) func callbackTimeoutAndCancellationRace(_ iteration: Int) async {
        let provider = PathProvider()
        let task = Task { await NetworkPathReader.current(start: provider.start) }
        await provider.waitForStart()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { provider.receive(.hotspot) }
            group.addTask { provider.timeout() }
            group.addTask { task.cancel() }
        }
        let result = await task.value
        #expect(result == nil || result == .hotspot)
        #expect(provider.cleanups == 1)
        provider.receive(.offline)
        provider.timeout()
        #expect(provider.cleanups == 1)
    }
}

private final class PathProvider: Sendable {
    private struct State {
        var starts = 0
        var cleanups = 0
        var receive: (@Sendable (NetworkPathConditions?) -> Void)?
        var timeout: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let started = AsyncStream<Void>.makeStream()
    var starts: Int { state.withLock { $0.starts } }
    var cleanups: Int { state.withLock { $0.cleanups } }

    func start(receive: @escaping @Sendable (NetworkPathConditions?) -> Void, timeout: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        state.withLock { $0.starts += 1; $0.receive = receive; $0.timeout = timeout }
        started.continuation.yield(())
        return { [self] in
            state.withLock { $0.cleanups += 1; $0.receive = nil; $0.timeout = nil }
        }
    }
    @discardableResult func waitForStart() async -> Bool {
        for await _ in started.stream { return true }
        return false
    }
    func finishStartSignal() { started.continuation.finish() }
    func receive(_ result: NetworkPathConditions?) { state.withLock { $0.receive }?(result) }
    func timeout() { state.withLock { $0.timeout }?() }
}
