import AppKit
import Foundation
import Testing
@testable import BeepbarApp

/// "Esci" must wind the sync down *before* calling `NSApp.terminate`, and the delegate must then
/// answer `.terminateNow`: `.terminateLater` from inside the menu's main-actor hop hangs BeepBar
/// for good (`prepareForMenuQuit()`). The AppKit hang itself only shows in a real app, so
/// `scripts/quit-probe` covers it; these tests pin the decisions that keep BeepBar off that path.
struct MenuQuitTests {
    /// Guards the rule that hangs BeepBar when broken: once "Esci" has drained, the answer is
    /// `.terminateNow` even if the sync outlived the timeout. A quit from outside still waits.
    @Test func menuQuitIsNeverAnsweredLater() {
        #expect(WeBeepAuthenticationController.terminationReply(menuQuitDrained: true, hasPendingSync: true) == .terminateNow)
        #expect(WeBeepAuthenticationController.terminationReply(menuQuitDrained: true, hasPendingSync: false) == .terminateNow)
        #expect(WeBeepAuthenticationController.terminationReply(menuQuitDrained: false, hasPendingSync: true) == .terminateLater)
        #expect(WeBeepAuthenticationController.terminationReply(menuQuitDrained: false, hasPendingSync: false) == .terminateNow)
    }

    /// A sync that stops when cancelled lets "Esci" go ahead as soon as it has stopped, not after
    /// the full timeout. Fails if the sync isn't cancelled, or if the wait ignores its end. A watchdog records a failure if the sync does not stop; the finite timeout also bounds the wait (#243).
    @Test(.timeLimit(.minutes(2))) @MainActor func menuQuitCancelsTheSyncAndGoesOnOnceItStops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WeBeepAuthenticationController(testRootURL: root)
        var syncFinished = false
        let sync = Task { @MainActor in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            syncFinished = true
        }
        controller.setOperationForTesting(UUID(), task: sync)
        controller.setSyncStateForTesting(.syncing)

        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            sync.cancel()
            return true
        }
        #expect(await controller.prepareForMenuQuit(timeout: .seconds(90)))
        #expect(syncFinished)
        watchdog.cancel()
        #expect(await watchdog.value == false, "quit did not stop the sync")
        #expect(sync.isCancelled)
        #expect(controller.syncState == .cancelling)
        #expect(controller.menuQuitDrained)
    }

    /// A sync that doesn't stop in time can't hold the quit hostage: "Esci" goes ahead after the
    /// timeout, as a quit from outside does. Fails if the wait is `await syncTask.value` (which
    /// ignores cancellation) instead of a capped wait. A watchdog releases the gate and records a failure if the quit does not return.
    @Test(.timeLimit(.minutes(2))) @MainActor func menuQuitGivesUpWaitingAfterTheTimeout() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WeBeepAuthenticationController(testRootURL: root)
        let gate = FakeRecmanBrowser.Gate()
        var syncFinished = false
        let sync = Task { @MainActor in
            await gate.wait()
            syncFinished = true
        }
        while !gate.isWaiting { await Task.yield() }
        controller.setOperationForTesting(UUID(), task: sync)
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            gate.release()
            return true
        }

        let timeout = Duration.milliseconds(200)
        let started = ContinuousClock.now
        #expect(await controller.prepareForMenuQuit(timeout: timeout))
        #expect(ContinuousClock.now - started >= timeout)
        watchdog.cancel()
        #expect(await watchdog.value == false, "quit did not respect its timeout")
        #expect(!syncFinished)
        #expect(sync.isCancelled)
        #expect(controller.menuQuitDrained)
        gate.release()
        await sync.value
    }

    /// With no sync running, "Esci" goes ahead straight away.
    @Test @MainActor func menuQuitWithoutSyncIsImmediate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WeBeepAuthenticationController(testRootURL: root)
        #expect(!controller.menuQuitDrained)
        #expect(await controller.prepareForMenuQuit(timeout: .seconds(30)))
        #expect(controller.menuQuitDrained)
    }

    /// A second click on "Esci" while the first is still waiting does nothing, so `terminate` is
    /// called once. Fails without the in-progress guard: the second call would wait and return true.
    @Test @MainActor func secondMenuQuitIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WeBeepAuthenticationController(testRootURL: root)
        let release = AsyncStream<Void>.makeStream()
        let sync = Task { @MainActor in for await _ in release.stream { break } }
        controller.setOperationForTesting(UUID(), task: sync)

        let first = Task { @MainActor in await controller.prepareForMenuQuit(timeout: .seconds(30)) }
        await Task.yield()
        while !controller.isMenuQuitInProgressForTesting { await Task.yield() }
        #expect(await controller.prepareForMenuQuit(timeout: .seconds(30)) == false)
        #expect(!controller.menuQuitDrained)
        release.continuation.yield()
        #expect(await first.value)
        #expect(controller.menuQuitDrained)
    }

    /// The capped wait itself: it returns when the task ends, or when the timeout passes. A watchdog records a failure and releases the held task if either wait stalls (#243).
    @Test(.timeLimit(.minutes(2))) @MainActor func cappedWaitReturnsOnWhicheverComesFirst() async {
        let quick = Task<Void, Never> {}
        let quickWatchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            return true
        }
        await WeBeepAuthenticationController.wait(for: quick, atMost: .seconds(90))
        quickWatchdog.cancel()
        #expect(await quickWatchdog.value == false, "wait did not observe the finished task")

        let gate = FakeRecmanBrowser.Gate()
        var slowFinished = false
        let slow = Task<Void, Never> {
            await gate.wait()
            slowFinished = true
        }
        while !gate.isWaiting { await Task.yield() }
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            gate.release()
            return true
        }
        let timeout = Duration.milliseconds(100)
        let started = ContinuousClock.now
        await WeBeepAuthenticationController.wait(for: slow, atMost: timeout)
        #expect(ContinuousClock.now - started >= timeout)
        watchdog.cancel()
        #expect(await watchdog.value == false, "wait did not respect its timeout")
        #expect(!slowFinished)
        gate.release()
        await slow.value
    }
}
