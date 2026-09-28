import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct SyncFinalizationTests {
    @Test @MainActor func terminalRunCannotBeCancelledWhileNotificationIsPending() async {
        let summary = SyncCompletionSummary(completedAt: Date(), added: 1, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)
        for finalState in [AppSyncState.synced(summary), .failed(.partialSync)] {
            let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory)
            let operationID = UUID()
            controller.setOperationForTesting(operationID)
            controller.setSyncStateForTesting(finalState)

            let notificationStarted = AsyncStream<Void>.makeStream()
            let releaseNotification = AsyncStream<Void>.makeStream()
            let completion = Task { @MainActor in
                await controller.finishOperationBeforeNotification(operationID) {
                    notificationStarted.continuation.yield()
                    for await _ in releaseNotification.stream { break }
                }
            }
            var started = notificationStarted.stream.makeAsyncIterator()
            _ = await started.next()

            #expect(!controller.isSyncActive)
            #expect(controller.canSynchronize)
            controller.cancelSynchronization()
            #expect(controller.syncState == finalState)

            releaseNotification.continuation.yield()
            await completion.value
        }
    }
}
