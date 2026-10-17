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

    @Test func cancellationOfSilentProviderIsPromptAndCleansUp() async {
        let provider = PathProvider()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            let result = await NetworkPathReader.current(start: provider.start)
            finished.withLock { $0 = true }
            return result
        }
        await provider.waitForStart()
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        while !finished.withLock({ $0 }), clock.now - start < .milliseconds(100) { await Task.yield() }
        #expect(finished.withLock { $0 })
        #expect(provider.cleanups == 1)
        // Also lets the cancellation mutation terminate, rather than hanging the suite.
        provider.timeout()
        #expect(await task.value == nil)
    }

    @Test func cancellationDuringInstallationReleasesLateResources() async {
        let provider = PathProvider()
        let release = DispatchSemaphore(value: 0)
        let task = Task.detached {
            await NetworkPathReader.current { receive, timeout in
                let cleanup = provider.start(receive: receive, timeout: timeout)
                release.wait()
                return cleanup
            }
        }
        await provider.waitForStart()
        task.cancel()
        release.signal()
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(100)
        while provider.cleanups == 0, clock.now < deadline { await Task.yield() }
        #expect(provider.cleanups == 1)
        provider.timeout()
        #expect(await task.value == nil)
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
    func waitForStart() async { for await _ in started.stream { return } }
    func receive(_ result: NetworkPathConditions?) { state.withLock { $0.receive }?(result) }
    func timeout() { state.withLock { $0.timeout }?() }
}
