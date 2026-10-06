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
    /// the full timeout. Fails if the sync isn't cancelled, or if the wait ignores its end.
    @Test @MainActor func menuQuitCancelsTheSyncAndGoesOnOnceItStops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WeBeepAuthenticationController(testRootURL: root)
        let sync = Task { @MainActor in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        controller.setOperationForTesting(UUID(), task: sync)
        controller.setSyncStateForTesting(.syncing)

        let started = ContinuousClock.now
        #expect(await controller.prepareForMenuQuit(timeout: .seconds(30)))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(sync.isCancelled)
        #expect(controller.syncState == .cancelling)
        #expect(controller.menuQuitDrained)
    }

    /// A sync that doesn't stop in time can't hold the quit hostage: "Esci" goes ahead after the
    /// timeout, as a quit from outside does. Fails if the wait is `await syncTask.value` (which
    /// ignores cancellation) instead of a capped wait.
    @Test @MainActor func menuQuitGivesUpWaitingAfterTheTimeout() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WeBeepAuthenticationController(testRootURL: root)
        // Ignores cancellation and ends on its own a few seconds later, so the test never hangs.
        let stubborn = Task.detached { try? await Task.sleep(for: .seconds(4)) }
        let sync = Task { @MainActor in _ = await stubborn.value }
        controller.setOperationForTesting(UUID(), task: sync)

        let started = ContinuousClock.now
        #expect(await controller.prepareForMenuQuit(timeout: .milliseconds(200)))
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(controller.menuQuitDrained)
        stubborn.cancel()
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

    /// The capped wait itself: it returns when the task ends, or when the timeout passes.
    @Test func cappedWaitReturnsOnWhicheverComesFirst() async {
        let quick = Task<Void, Never> {}
        var started = ContinuousClock.now
        await WeBeepAuthenticationController.wait(for: quick, atMost: .seconds(30))
        #expect(ContinuousClock.now - started < .seconds(5))

        let slow = Task<Void, Never> { try? await Task.sleep(for: .seconds(4)) }
        started = ContinuousClock.now
        await WeBeepAuthenticationController.wait(for: slow, atMost: .milliseconds(100))
        #expect(ContinuousClock.now - started < .seconds(2))
        slow.cancel()
    }
}
