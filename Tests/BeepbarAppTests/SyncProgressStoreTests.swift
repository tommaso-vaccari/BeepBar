import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// D08 (#96): progress events are throttled before the main actor, not after.
///
/// `SyncCoordinator` reports progress from its own tasks, once per file or more. The old relay
/// entered the main actor for every event and only then asked the throttle; a run over thousands
/// of files therefore queued thousands of main-queue turns while the user had the menu open.
/// These tests drive the real controller sink from a detached task and count the main-actor
/// entries the store records, so moving the hop back before the throttle makes them fail.
@MainActor
struct SyncProgressStoreTests {
    private func controller() -> WeBeepAuthenticationController {
        let root = FileManager.default.temporaryDirectory.appending(path: "beepbar-progress-\(UUID().uuidString)", directoryHint: .isDirectory)
        return WeBeepAuthenticationController(testRootURL: root)
    }

    nonisolated private static func progress(_ completed: Int, total: Int) -> SyncProgress {
        SyncProgress(completed: completed, total: total, installed: 0, preservedLocal: 0, unchanged: completed, conflicts: 0, failures: 0)
    }

    /// Proves the throttle runs off the main actor: 10 000 events reach the main actor at most
    /// once per 200 ms plus the final one. With the hop before the throttle the counter reaches
    /// 10 000 and the bound fails by three orders of magnitude.
    @Test func burstOfEventsEntersTheMainActorOncePerInterval() async throws {
        let controller = controller()
        let operationID = UUID()
        controller.setOperationForTesting(operationID)
        let sink = controller.beginTransferForTesting(operationID, automatic: false)
        let total = 10_000
        let start = ContinuousClock.now
        await Task.detached {
            for completed in 1...total {
                await sink(Self.progress(completed, total: total))
            }
        }.value
        let elapsed = start.duration(to: .now)
        let allowed = 2 + Int(elapsed / .milliseconds(200))
        let entries = controller.progressStore.mainActorEntries
        #expect(entries >= 1, "the first event and the final totals must be shown")
        #expect(entries <= allowed, "\(entries) main-actor entries for \(total) events in \(elapsed); at most \(allowed) allowed")
        #expect(controller.progressStore.progress.completed == total, "the final totals are never throttled")
        #expect(controller.progressStore.progress.total == total)
    }

    /// Guards the ordering rule the throttle already has, now exercised through the real sink:
    /// an older event delivered late never moves the shown counter backwards.
    @Test func lateOlderEventIsIgnored() async {
        let controller = controller()
        let operationID = UUID()
        controller.setOperationForTesting(operationID)
        let sink = controller.beginTransferForTesting(operationID, automatic: false)
        await sink(Self.progress(10, total: 100))
        await sink(Self.progress(3, total: 100))
        #expect(controller.progressStore.progress.completed == 10)
    }

    /// Events of a run that `beginTransfer` refused (its operation was no longer active) carry
    /// the superseded token and never touch the store, so a stale task cannot repaint the UI.
    @Test func supersededRunNeverReachesTheStore() async {
        let controller = controller()
        let active = UUID()
        controller.setOperationForTesting(active)
        let activeSink = controller.beginTransferForTesting(active, automatic: false)
        await activeSink(Self.progress(5, total: 100))
        let staleSink = controller.beginTransferForTesting(UUID(), automatic: false)
        await staleSink(Self.progress(90, total: 100))
        await staleSink(Self.progress(100, total: 100))
        #expect(controller.progressStore.progress.completed == 5)
        #expect(controller.progressStore.mainActorEntries == 1)
    }

    /// Once the operation ends, late progress from its still-unwinding tasks is dropped at the
    /// relay, off the main actor: the completed state stays what `completeSync` left.
    @Test func eventsAfterTheRunClosedAreDropped() async {
        let controller = controller()
        let operationID = UUID()
        controller.setOperationForTesting(operationID)
        let sink = controller.beginTransferForTesting(operationID, automatic: false)
        await sink(Self.progress(1, total: 3))
        let entriesBefore = controller.progressStore.mainActorEntries
        await controller.completeSyncForTesting(operationID, summary: Self.progress(3, total: 3))
        await sink(Self.progress(2, total: 3))
        await sink(Self.progress(3, total: 3))
        #expect(controller.progressStore.mainActorEntries == entriesBefore)
        #expect(controller.progressStore.progress.completed == 1, "the run's own stream is closed; the summary is shown through lastSyncSummary, not progress")
    }

    /// A new run starts from zero and is not polluted by the previous run's token.
    @Test func resetRetiresThePreviousRun() async {
        let controller = controller()
        let first = UUID()
        controller.setOperationForTesting(first)
        let firstSink = controller.beginTransferForTesting(first, automatic: false)
        await firstSink(Self.progress(7, total: 10))
        await controller.completeSyncForTesting(first, summary: Self.progress(10, total: 10))
        let second = UUID()
        controller.setOperationForTesting(second)
        let secondSink = controller.beginTransferForTesting(second, automatic: true)
        #expect(controller.progressStore.progress.completed == 0)
        #expect(controller.progressStore.mainActorEntries == 0)
        await firstSink(Self.progress(9, total: 10))
        #expect(controller.progressStore.progress.completed == 0)
        await secondSink(Self.progress(2, total: 10))
        #expect(controller.progressStore.progress.completed == 2)
    }
}
