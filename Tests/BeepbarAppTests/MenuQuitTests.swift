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
    /// the full timeout. Fails if the sync isn't cancelled, or if the wait ignores its end. The
    /// timeout is a day, so the wait can only end because the sync stopped; a wait that ignored
    /// its end hangs until the `.timeLimit` guard (no elapsed-time comparison: #243).
    @Test(.timeLimit(.minutes(1))) @MainActor func menuQuitCancelsTheSyncAndGoesOnOnceItStops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WeBeepAuthenticationController(testRootURL: root)
        let sync = Task { @MainActor in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        controller.setOperationForTesting(UUID(), task: sync)
        controller.setSyncStateForTesting(.syncing)

        #expect(await controller.prepareForMenuQuit(timeout: .seconds(86_400)))
        #expect(sync.isCancelled)
        #expect(controller.syncState == .cancelling)
        #expect(controller.menuQuitDrained)
    }

    /// A sync that doesn't stop in time can't hold the quit hostage: "Esci" goes ahead after the
    /// timeout, as a quit from outside does. Fails if the wait is `await syncTask.value` (which
    /// ignores cancellation) instead of a capped wait. The sync stays on its gate for the whole
    /// test (no watchdog that would release it after 30 s and so end the wait by itself): only the
    /// 200 ms timeout can return the quit, and a wait without it hangs until the `.timeLimit` guard.
    @Test(.timeLimit(.minutes(1))) @MainActor func menuQuitGivesUpWaitingAfterTheTimeout() async throws {
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

        #expect(await controller.prepareForMenuQuit(timeout: .milliseconds(200)))
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

    /// The capped wait itself: it returns when the task ends, or when the timeout passes. Each half
    /// is proved by making the other unable to happen: a day-long timeout with a task that ends,
    /// and a task held on a gate (no watchdog) with a 100 ms timeout. Returning at all is the
    /// proof; a wait missing either half hangs until the `.timeLimit` guard (#243).
    @Test(.timeLimit(.minutes(1))) @MainActor func cappedWaitReturnsOnWhicheverComesFirst() async {
        let quick = Task<Void, Never> {}
        await WeBeepAuthenticationController.wait(for: quick, atMost: .seconds(86_400))

        let gate = FakeRecmanBrowser.Gate()
        var slowFinished = false
        let slow = Task<Void, Never> {
            await gate.wait()
            slowFinished = true
        }
        while !gate.isWaiting { await Task.yield() }
        await WeBeepAuthenticationController.wait(for: slow, atMost: .milliseconds(100))
        #expect(!slowFinished)
        gate.release()
        await slow.value
    }
}
