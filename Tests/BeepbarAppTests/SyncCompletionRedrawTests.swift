import Combine
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

@MainActor struct SyncCompletionRedrawTests {
    @Test func endingOperationAfterFinalStateInvalidatesWindow() async {
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory)
        var invalidations = 0
        let subscription = controller.objectWillChange.sink { invalidations += 1 }
        defer { subscription.cancel() }

        let summary = SyncCompletionSummary(completedAt: Date(), added: 63, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)
        for finalState in [AppSyncState.synced(summary), .failed(.connectivity), .readyUnchecked] {
            controller.setOperationForTesting(UUID())
            controller.setSyncStateForTesting(.syncing)
            controller.setSyncStateForTesting(finalState)
            await Task.yield()

            #expect(controller.isSyncActive)
            #expect(!controller.canSynchronize)
            let beforeEnd = invalidations
            controller.setOperationForTesting(nil)
            #expect(invalidations > beforeEnd)
            #expect(!controller.isSyncActive)
            #expect(controller.canSynchronize)
        }
    }

    /// Known issue: proves that finishing a sync reassigns the course list even when its order did
    /// not change. The assignment invalidates the window and, through `courses`' `didSet`, recomputes
    /// every default course folder (milliseconds with hundreds of courses), on every sync. Once
    /// `finishReconciliation` assigns only a list that differs, `withKnownIssue` reports that the
    /// issue no longer occurs: remove the wrapper and keep the test.
    @Test func finishingASyncDoesNotRepublishAnUnchangedCourseList() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)
        var courseUpdates = 0
        let subscription = controller.$courses.dropFirst().sink { _ in courseUpdates += 1 }
        defer { subscription.cancel() }

        await controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))

        // The sync really reached its final state: a run that stopped early would publish nothing
        // either, and the test would prove nothing.
        guard case .synced = controller.syncState else {
            Issue.record("The sync did not complete: \(controller.syncState)")
            return
        }
        #expect(!controller.isSyncActive)
        withKnownIssue("Finishing a sync republishes an unchanged course list") {
            #expect(courseUpdates == 0)
        }
    }
}
