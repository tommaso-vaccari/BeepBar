import Combine
import Foundation
import Testing
import SQLite3
import BeepbarCore
@testable import BeepbarApp

struct CourseSelectionDuringRefreshTests {
    private let course = RemoteCourseSummary(id: 1, shortName: "1", displayName: "Course", isVisible: true, startDate: nil, endDate: nil)

    @Test @MainActor func unreadableScopesFailRefreshInsteadOfUsingGeneratedFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let database = try SyncDatabase(url: url)
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "DROP TABLE sync_scopes", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: SyncDatabaseError.execution) {
            try await controller.restoreScopesForTesting([course])
        }
        #expect(controller.enabledCourseIDs == [1])
        #expect(controller.courseFolders.isEmpty)
        _ = await controller.runAutomaticSyncForTesting()
        guard case .failed(.local) = controller.syncState else {
            Issue.record("Unreadable selected courses must fail automatic sync")
            return
        }
        #expect(!controller.isSyncActive)
        #expect(controller.lastSuccessfulTimestampForTesting() == 0)
    }

    @Test @MainActor func courseSelectionCannotChangeDuringRefresh() {
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory)
        controller.setLoadingCoursesForTesting(true)
        controller.setCourse(course, enabled: false)
        #expect(controller.enabledCourseIDs == [1])
    }

    @Test @MainActor func refreshWaitsForPendingCourseSelectionWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: false))
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)

        let releaseWrite = AsyncStream<Void>.makeStream()
        let write = Task {
            for await _ in releaseWrite.stream { break }
            try? await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: true))
        }
        controller.setScopeWriteTaskForTesting(write)
        let restoreStarted = AsyncStream<Void>.makeStream()
        controller.setBeforeScopeRestoreForTesting { restoreStarted.continuation.yield() }
        let refresh = Task { @MainActor in try await controller.restoreScopesForTesting([course]) }
        var started = restoreStarted.stream.makeAsyncIterator()
        _ = await started.next()
        try await Task.sleep(for: .milliseconds(100))
        releaseWrite.continuation.yield()
        try await refresh.value

        #expect(controller.enabledCourseIDs == [1])
    }

    /// Known issue: proves that refreshing the course list republishes the course folders and the
    /// selection even when nothing changed. `courseFolders` is assigned once per course: with 100
    /// unchanged courses that is about 100 `objectWillChange` sends and dictionary copies in one
    /// main-actor turn (SwiftUI coalesces them into one update), plus one for the selection. The two
    /// halves have separate wrappers so fixing one is noticed on its own. Once the refresh assigns
    /// only values that differ, `withKnownIssue` reports that the issue no longer occurs: remove the
    /// wrapper and keep the test. `refreshingChangedCoursesPublishesEachChangeOnce` guards the other
    /// side.
    @Test @MainActor func refreshingUnchangedCoursesPublishesNothing() async throws {
        let (controller, _, _, cleanup) = try await restoredController()
        defer { cleanup() }

        var folderUpdates = 0
        var selectionUpdates = 0
        let folders = controller.$courseFolders.dropFirst().sink { _ in folderUpdates += 1 }
        let selection = controller.$enabledCourseIDs.dropFirst().sink { _ in selectionUpdates += 1 }
        defer { folders.cancel(); selection.cancel() }
        try await controller.restoreScopesForTesting([course])

        #expect(controller.courseFolders == [1: "Course"])
        #expect(controller.enabledCourseIDs == [1])
        withKnownIssue("A refresh republishes unchanged course folders") {
            #expect(folderUpdates == 0)
        }
        withKnownIssue("A refresh republishes an unchanged course selection") {
            #expect(selectionUpdates == 0)
        }
    }

    /// Proves that a refresh still publishes a folder and a selection that changed in the database
    /// since the last one, each exactly once with the new value. Guards against a fix for the test
    /// above that skips the restore whenever the course list itself is unchanged.
    @Test @MainActor func refreshingChangedCoursesPublishesEachChangeOnce() async throws {
        let (controller, database, rootID, cleanup) = try await restoredController()
        defer { cleanup() }
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course renamed", enabled: false))

        var folderValues: [[Int64: String]] = []
        var selectionValues: [Set<Int64>] = []
        let folders = controller.$courseFolders.dropFirst().sink { folderValues.append($0) }
        let selection = controller.$enabledCourseIDs.dropFirst().sink { selectionValues.append($0) }
        defer { folders.cancel(); selection.cancel() }
        try await controller.restoreScopesForTesting([course])

        #expect(folderValues == [[1: "Course renamed"]])
        #expect(selectionValues == [[]])
    }

    /// A controller whose first refresh restored course 1's saved folder ("Course") and selection.
    @MainActor private func restoredController() async throws -> (WeBeepAuthenticationController, SyncDatabase, UUID, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: true))
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        try await controller.restoreScopesForTesting([course])
        // The first refresh really restored the saved folder and selection.
        #expect(controller.courseFolders == [1: "Course"])
        #expect(controller.enabledCourseIDs == [1])
        return (controller, database, rootID, { try? FileManager.default.removeItem(at: root) })
    }
}
