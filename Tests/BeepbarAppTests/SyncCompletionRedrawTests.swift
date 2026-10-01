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
    /// not change. The window is invalidated in that turn anyway (conflicts, sync state); what the
    /// reassignment adds is one more `objectWillChange` and, through `courses`' `didSet`, a fresh
    /// computation of every default course folder, milliseconds with hundreds of courses, on every
    /// sync. The sort itself still has to run. Once `finishReconciliation` assigns only a list that
    /// differs, `withKnownIssue` reports that the issue no longer occurs: remove the wrapper and keep
    /// the test. `finishingASyncReordersCoursesEnabledDuringTheSession` guards the other side.
    @Test func finishingASyncDoesNotRepublishAnUnchangedCourseList() async throws {
        let (controller, cleanup) = try await controllerWithLoadedCourses()
        defer { cleanup() }
        let operationID = UUID()
        controller.setOperationForTesting(operationID)
        var published: [[Int64]] = []
        let subscription = controller.$courses.dropFirst().sink { published.append($0.map(\.id)) }
        defer { subscription.cancel() }

        await controller.completeSyncForTesting(operationID, summary: Self.emptySummary)

        // The sync really reached its final state: a run that stopped early would publish nothing
        // either, and the test would prove nothing.
        guard case .synced = controller.syncState else {
            Issue.record("The sync did not complete: \(controller.syncState)")
            return
        }
        #expect(!controller.isSyncActive)
        #expect(controller.courses.map(\.id) == [1, 2])
        withKnownIssue("Finishing a sync republishes an unchanged course list") {
            #expect(published.isEmpty)
        }
    }

    /// Proves that finishing a sync still moves a course enabled during the session to the top:
    /// enabling a course leaves its row where it is, and the list is re-sorted only when the sync
    /// ends. Guards against a fix for the test above that drops the re-sort, or skips it whenever
    /// the list looks unchanged, instead of assigning only a list that differs.
    @Test func finishingASyncReordersCoursesEnabledDuringTheSession() async throws {
        let (controller, cleanup) = try await controllerWithLoadedCourses()
        defer { cleanup() }
        let alpha = try #require(controller.courses.first { $0.id == 2 })
        controller.setCourse(alpha, enabled: true)
        #expect(controller.courses.map(\.id) == [1, 2])
        let operationID = UUID()
        controller.setOperationForTesting(operationID)
        var published: [[Int64]] = []
        let subscription = controller.$courses.dropFirst().sink { published.append($0.map(\.id)) }
        defer { subscription.cancel() }

        await controller.completeSyncForTesting(operationID, summary: Self.emptySummary)

        guard case .synced = controller.syncState else {
            Issue.record("The sync did not complete: \(controller.syncState)")
            return
        }
        // Both courses are enabled now, so they are in name order: Alpha before Beta, published once.
        #expect(published == [[2, 1]])
    }

    private static let emptySummary = SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)

    /// A controller signed in to a local Moodle (see `MoodleRecordingProtocol`) whose course list
    /// was loaded the way the app loads it: Beta, the enabled course, first, then Alpha.
    private func controllerWithLoadedCourses() async throws -> (WeBeepAuthenticationController, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let token = MoodleRecordingProtocol.register(courses: [(1, "Beta"), (2, "Alpha")])
        let vault = CredentialVault(read: { _ in token }, write: { _ in })
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        // The list really came from the local Moodle, in display order.
        #expect(controller.courseLoadError == nil)
        #expect(controller.courses.map(\.id) == [1, 2])
        return (controller, { try? FileManager.default.removeItem(at: root) })
    }
}
