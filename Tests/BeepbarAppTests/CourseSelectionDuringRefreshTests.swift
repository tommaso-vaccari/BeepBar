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

    /// An unchanged refresh must not publish folders or selection again. With many courses,
    /// redundant assignments send one invalidation and copy the folder dictionary per course.
    /// `refreshingChangedCoursesPublishesEachChangeOnce` guards changes still reaching the UI.
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
        #expect(folderUpdates == 0)
        #expect(selectionUpdates == 0)
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

    /// Exercises the real network refresh: equal ordered courses and canonical selection
    /// must not republish the list or write selection again after the initial restore.
    @Test @MainActor func identicalNetworkRefreshAvoidsPublicationsAndSelectionWrites() async throws {
        let (controller, defaults, token, root) = try await networkController()
        defer { MoodleRecordingProtocol.revoke(token: token); try? FileManager.default.removeItem(at: root) }
        var updates = 0
        let subscription = controller.$courses.dropFirst().sink { _ in updates += 1 }
        defer { subscription.cancel() }
        defaults.resetWrites()
        for _ in 0..<10 {
            controller.loadCourses()
            await controller.waitForCourseLoadForTesting()
            #expect(controller.courseLoadError == nil)
        }
        #expect(updates == 0)
        #expect(defaults.writes.filter { $0 == "io.github.tvaccari.beepbar.enabled-courses.v1" }.isEmpty)
        #expect(controller.courses.map(\.id) == [1, 2])
    }

    /// A reordered response is equivalent; a real rename/removal must still reach observers,
    /// restore selected IDs from the DB, and persist the changed selection exactly once.
    @Test @MainActor func networkRefreshPreservesRealChangesAndIgnoresResponseOrder() async throws {
        let (controller, defaults, token, root) = try await networkController()
        defer { MoodleRecordingProtocol.revoke(token: token); try? FileManager.default.removeItem(at: root) }
        var values: [[RemoteCourseSummary]] = []
        let subscription = controller.$courses.dropFirst().sink { values.append($0) }
        defer { subscription.cancel() }
        defaults.resetWrites()
        MoodleRecordingProtocol.setCourses(token: token, courses: [(2, "B"), (1, "A")])
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        #expect(values.isEmpty)
        MoodleRecordingProtocol.setCourses(token: token, courses: [(2, "Renamed")])
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        #expect(values.count == 1)
        #expect(controller.courses.map(\.displayName) == ["Renamed"])
        #expect(controller.enabledCourseIDs.isEmpty)
        #expect(defaults.stringArray(forKey: "io.github.tvaccari.beepbar.enabled-courses.v1") == [])
        #expect(defaults.writes.filter { $0 == "io.github.tvaccari.beepbar.enabled-courses.v1" }.count == 1)
        #expect(controller.courseLoadError == nil)
    }

    /// Missing or noncanonical persisted selection is repaired even when the in-memory set
    /// itself is unchanged; subsequent restores leave the repaired value alone.
    @Test(arguments: [nil, ["1", "1"], ["99"]]) @MainActor
    func restoreRepairsPersistedSelectionOnce(_ saved: [String]?) async throws {
        let (controller, defaults, token, root) = try await networkController()
        defer { MoodleRecordingProtocol.revoke(token: token); try? FileManager.default.removeItem(at: root) }
        defaults.set(saved, forKey: "io.github.tvaccari.beepbar.enabled-courses.v1")
        defaults.resetWrites()
        try await controller.restoreScopesForTesting(controller.courses)
        try await controller.restoreScopesForTesting(controller.courses)
        #expect(defaults.stringArray(forKey: "io.github.tvaccari.beepbar.enabled-courses.v1") == ["1"])
        #expect(defaults.writes.filter { $0 == "io.github.tvaccari.beepbar.enabled-courses.v1" }.count == 1)
    }

    @MainActor private func networkController() async throws -> (WeBeepAuthenticationController, CountingDefaults, String, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = MemoryCountingDefaults.isolated()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "A", localFolder: "A", enabled: true))
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 2, displayName: "B", localFolder: "B", enabled: false))
        let token = MoodleRecordingProtocol.register(courses: [(1, "A"), (2, "B")])
        let vault = CredentialVault(read: { _ in token }, write: { _ in })
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID,
            apiClient: MoodleRecordingProtocol.makeClient(), downloader: MoodleRecordingProtocol.makeDownloader(),
            credentialVault: vault, defaults: defaults)
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        #expect(controller.courseLoadError == nil)
        return (controller, defaults, token, root)
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
