import Combine
import Foundation
import Testing
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
}
