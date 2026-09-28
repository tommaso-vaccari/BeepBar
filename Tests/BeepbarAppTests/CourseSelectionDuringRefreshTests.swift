import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct CourseSelectionDuringRefreshTests {
    private let course = RemoteCourseSummary(id: 1, shortName: "1", displayName: "Course", isVisible: true, startDate: nil, endDate: nil)

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
        let refresh = Task { @MainActor in await controller.restoreScopesForTesting([course]) }
        var started = restoreStarted.stream.makeAsyncIterator()
        _ = await started.next()
        try await Task.sleep(for: .milliseconds(100))
        releaseWrite.continuation.yield()
        await refresh.value

        #expect(controller.enabledCourseIDs == [1])
    }
}
