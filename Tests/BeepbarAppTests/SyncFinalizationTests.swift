import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct SyncFinalizationTests {
    @Test @MainActor func cancellationDuringReconciliationDoesNotRestoreCompletedState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)

        let reconciliationStarted = AsyncStream<Void>.makeStream()
        let resumeReconciliation = AsyncStream<Void>.makeStream()
        controller.setBeforeReconciliationStateForTesting {
            reconciliationStarted.continuation.yield()
            for await _ in resumeReconciliation.stream { break }
        }
        var notificationSent = false
        controller.setBeforeNotificationForTesting { notificationSent = true }
        let completion = Task {
            await controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 1, total: 1, added: 1, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
        }
        var started = reconciliationStarted.stream.makeAsyncIterator()
        _ = await started.next()

        controller.cancelSynchronization()
        resumeReconciliation.continuation.yield()
        await completion.value

        #expect(controller.syncState == .readyUnchecked)
        #expect(!controller.isSyncActive)
        #expect(!notificationSent)
    }

    @Test @MainActor func completedRunCannotBeCancelledWhileNotificationIsPending() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)

        let notificationStarted = AsyncStream<Void>.makeStream()
        let releaseNotification = AsyncStream<Void>.makeStream()
        controller.setBeforeNotificationForTesting {
            notificationStarted.continuation.yield()
            for await _ in releaseNotification.stream { break }
        }
        let completion = Task {
            await controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 1, total: 1, added: 1, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
        }
        var started = notificationStarted.stream.makeAsyncIterator()
        _ = await started.next()

        #expect(!controller.isSyncActive)
        let state = controller.syncState
        controller.cancelSynchronization()
        #expect(controller.syncState == state)

        releaseNotification.continuation.yield()
        await completion.value
    }

    @Test @MainActor func failedRunCannotBeCancelledWhileNotificationIsPending() async {
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)

        let notificationStarted = AsyncStream<Void>.makeStream()
        let releaseNotification = AsyncStream<Void>.makeStream()
        controller.setBeforeNotificationForTesting {
            notificationStarted.continuation.yield()
            for await _ in releaseNotification.stream { break }
        }
        let completion = Task { await controller.failSyncForTesting(operationID) }
        var started = notificationStarted.stream.makeAsyncIterator()
        _ = await started.next()

        #expect(!controller.isSyncActive)
        #expect(controller.syncState == .failed(.partialSync))
        controller.cancelSynchronization()
        #expect(controller.syncState == .failed(.partialSync))

        releaseNotification.continuation.yield()
        await completion.value
    }
}
