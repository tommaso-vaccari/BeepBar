import Combine
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The course list saved between launches (#98), through the real controller: a local Moodle
/// (`MoodleRecordingProtocol`), a real sync database and a real store in a throwaway folder that
/// every "launch" of one install shares. Each test names the acceptance rule it guards; the codec
/// and store rules themselves are in `CourseListSnapshotTests`.
@MainActor struct SavedCourseListTests {
    /// One install: a sync folder with its database (course 1 enabled in "Analisi I", course 2
    /// off), and the folder the saved list lives in.
    private struct Install {
        let root: URL
        let database: SyncDatabase
        let rootID: UUID
        let storeFolder: URL
        let store: CourseListSnapshotStore

        static func make() async throws -> Install {
            let root = FileManager.default.temporaryDirectory.appending(path: "SavedCourseListTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
            let rootID = UUID()
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Analisi", localFolder: "Analisi I", enabled: true))
            try await database.upsertScope(SyncScope(rootID: rootID, courseID: 2, displayName: "Fisica", localFolder: "Fisica", enabled: false))
            let storeFolder = root.appending(path: "support", directoryHint: .isDirectory)
            return Install(root: root, database: database, rootID: rootID, storeFolder: storeFolder, store: CourseListSnapshotStore { storeFolder })
        }

        var file: URL { storeFolder.appending(path: CourseListSnapshotStore.fileName) }

        /// A controller as one launch of the app makes it, signed in with `token`.
        @MainActor func launch(token: String) -> WeBeepAuthenticationController {
            WeBeepAuthenticationController(
                testRootURL: root, database: database, rootID: rootID,
                apiClient: MoodleRecordingProtocol.makeClient(), downloader: MoodleRecordingProtocol.makeDownloader(),
                credentialVault: CredentialVault(read: { _ in token }, write: { _ in }), deleteCredential: {},
                courseListStore: store
            )
        }

        func identity(token: String) -> CourseListSnapshot.Identity {
            CourseListSnapshot.Identity(siteID: MoodleSite.site(id: nil).id, rootID: rootID, token: token)
        }

        func savedSnapshot(token: String) throws -> CourseListSnapshot {
            try CourseListSnapshotCodec.decode(Data(contentsOf: file), expecting: identity(token: token), now: Date())
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// What the window shows each time `courseListFreshness` changes.
    private struct Observation {
        let freshness: CourseListFreshness
        let courseIDs: [Int64]
        let firstFolder: String?
        let requestsSoFar: Int
    }

    /// A first launch that loads Moodle's list and saves it.
    private func launchAndSave(_ install: Install, token: String) async -> WeBeepAuthenticationController {
        let controller = install.launch(token: token)
        await controller.refreshOnWindowOpen().value
        await controller.waitForCourseListWriteForTesting()
        return controller
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    /// The main path: a list Moodle confirmed is saved, and the next launch shows it, with the
    /// folders the database holds and the "saved" state, before any request reaches Moodle;
    /// Moodle's answer then replaces it and marks it current. Fails if the restore is removed,
    /// runs after the network, or takes the folders from anywhere but the database.
    @Test func aRelaunchShowsTheSavedListBeforeAskingMoodle() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let first = await launchAndSave(install, token: token)
        #expect(first.courseListFreshness == .current)
        #expect(FileManager.default.fileExists(atPath: install.file.path))

        let relaunched = install.launch(token: token)
        let requestsBefore = MoodleRecordingProtocol.requests(token: token).count
        var seen: [Observation] = []
        let subscription = relaunched.$courseListFreshness.dropFirst().sink { freshness in
            seen.append(Observation(
                freshness: freshness,
                courseIDs: relaunched.courses.map(\.id),
                firstFolder: relaunched.courses.first.map { relaunched.folder(for: $0) },
                requestsSoFar: MoodleRecordingProtocol.requests(token: token).count - requestsBefore
            ))
        }
        defer { subscription.cancel() }
        await relaunched.refreshOnWindowOpen().value

        try #require(seen.count == 2, "expected the saved list, then Moodle's")
        guard case .saved = seen[0].freshness else {
            Issue.record("The first list shown was not the saved one: \(seen[0].freshness)")
            return
        }
        #expect(seen[0].courseIDs == [1, 2])
        #expect(seen[0].firstFolder == "Analisi I", "the saved list's folder did not come from the database")
        #expect(seen[0].requestsSoFar == 0, "the saved list waited for the network")
        #expect(seen[1].freshness == .current)
        #expect(seen[1].requestsSoFar > 0)
        #expect(relaunched.courses.map(\.id) == [1, 2])
    }

    /// Offline at launch: the saved list stays on screen as "saved", the failure is reported, the
    /// loading state ends, and the file is kept for the next launch.
    @Test func anOfflineLaunchKeepsTheSavedListAndReportsTheFailure() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        _ = await launchAndSave(install, token: token)
        MoodleRecordingProtocol.setOffline(token: token, true)

        let relaunched = install.launch(token: token)
        await relaunched.refreshOnWindowOpen().value
        #expect(relaunched.courses.map(\.id) == [1, 2])
        guard case .saved = relaunched.courseListFreshness else {
            Issue.record("Offline, the saved list was not kept as saved: \(relaunched.courseListFreshness)")
            return
        }
        #expect(relaunched.courseLoadError != nil)
        #expect(!relaunched.isLoadingCourses)
        #expect(!relaunched.isPreparingCourseList)
        #expect(FileManager.default.fileExists(atPath: install.file.path))
    }

    /// Account A → B on one Mac: B never sees A's list, not even offline, where nothing else
    /// would replace it, and A's file is deleted rather than left for a later launch.
    @Test func anotherSignInNeverSeesTheSavedList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let a = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        let b = MoodleRecordingProtocol.register(courses: [(3, "Chimica")])
        defer { MoodleRecordingProtocol.revoke(token: a); MoodleRecordingProtocol.revoke(token: b) }
        _ = await launchAndSave(install, token: a)
        MoodleRecordingProtocol.setOffline(token: b, true)

        let other = install.launch(token: b)
        await other.refreshOnWindowOpen().value
        #expect(other.courses.isEmpty)
        #expect(other.courseListFreshness == .unknown)
        #expect(!FileManager.default.fileExists(atPath: install.file.path), "account A's list was left on disk")
    }

    /// Sign-out clears the list on screen and deletes the saved one.
    @Test func signingOutDeletesTheSavedList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = await launchAndSave(install, token: token)
        #expect(FileManager.default.fileExists(atPath: install.file.path))

        controller.signOut()
        await controller.waitForCourseListWriteForTesting()
        #expect(!controller.hasStoredCredential)
        #expect(controller.courses.isEmpty)
        #expect(controller.courseListFreshness == .unknown)
        #expect(!FileManager.default.fileExists(atPath: install.file.path))
    }

    /// Saved enrollments are not an authorization: "Sincronizza ora" over a saved list asks
    /// Moodle first, so a course the account left since (course 1, still enabled locally) is not
    /// synced, and the list on screen becomes Moodle's. With the old `courses.isEmpty` check the
    /// sync would download course 1's file from the saved list.
    @Test func aSyncOverTheSavedListAsksMoodleFirst() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")], files: [1: ["a.txt"]])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        _ = await launchAndSave(install, token: token)
        MoodleRecordingProtocol.setCourses(token: token, courses: [(2, "Fisica")])

        let relaunched = install.launch(token: token)
        await relaunched.restoreSavedCourseListForTesting()
        guard case .saved = relaunched.courseListFreshness else {
            Issue.record("The saved list was not restored: \(relaunched.courseListFreshness)")
            return
        }
        #expect(relaunched.courses.map(\.id) == [1, 2])
        let requestsBefore = MoodleRecordingProtocol.requests(token: token).count
        relaunched.synchronizeNow()
        await relaunched.waitForSyncForTesting()

        let functions = MoodleRecordingProtocol.requests(token: token).dropFirst(requestsBefore).map(\.function)
        #expect(functions.contains("core_enrol_get_users_courses"))
        #expect(!functions.contains("core_course_get_contents"), "a course from the saved list was synced")
        #expect(!functions.contains(MoodleRecordingProtocol.downloadFunction))
        #expect(relaunched.courseListFreshness == .current)
        #expect(relaunched.courses.map(\.id) == [2])
    }

    /// Late results are refused: a refresh still waiting for Moodle when another account signs in
    /// must not show the previous account's list once it answers, nor hand the previous account's
    /// Moodle id back to Recordings; the new account's list is loaded instead, and the saved file
    /// ends up being the new account's.
    @Test func aRefreshThatAnswersAfterANewSignInIsDropped() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let a = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")], userID: 11)
        let b = MoodleRecordingProtocol.register(courses: [(3, "Chimica")], userID: 22)
        defer { MoodleRecordingProtocol.revoke(token: a); MoodleRecordingProtocol.revoke(token: b) }
        let controller = install.launch(token: a)
        var published: [[Int64]] = []
        let subscription = controller.$courses.dropFirst().sink { published.append($0.map(\.id)) }
        defer { subscription.cancel() }

        MoodleRecordingProtocol.holdCourseLists(token: a)
        controller.loadCourses()
        try await waitUntil { MoodleRecordingProtocol.heldCourseListCount(token: a) == 1 }
        let login = Task { await controller.completeLoginForTesting(moodleLoginCallback(token: b)) }
        try await waitUntil {
            MoodleRecordingProtocol.requests(token: b).contains { $0.function == "core_webservice_get_site_info" } && !controller.isAuthenticating
        }
        MoodleRecordingProtocol.releaseCourseLists(token: a)
        await login.value
        await controller.waitForCourseLoadForTesting()
        await controller.waitForCourseListWriteForTesting()

        #expect(controller.courses.map(\.id) == [3])
        #expect(controller.courseListFreshness == .current)
        #expect(controller.recordingsOwnerUserID == 22, "the previous account's Moodle id came back")
        #expect(published.allSatisfy { !$0.contains(1) && !$0.contains(2) }, "account A's late list reached the window: \(published)")
        #expect(controller.courseLoadError == nil)
        #expect(try install.savedSnapshot(token: b).summaries.map(\.id) == [3])
    }

    /// First use, nothing saved: the window shows the loading state from the moment it asks for
    /// courses, not "no courses" while the launch finishes, and the state ends with the load.
    @Test func aFirstOpeningShowsTheLoadingStateAtOnce() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = install.launch(token: token)

        let refresh = controller.refreshOnWindowOpen()
        #expect(controller.isPreparingCourseList || controller.isLoadingCourses, "the window showed no courses before the load started")
        await refresh.value
        #expect(!controller.isPreparingCourseList)
        #expect(!controller.isLoadingCourses)
        #expect(controller.courses.map(\.id) == [1, 2])
    }

    /// Cost proportional to what changed: refreshing an unchanged list rewrites nothing (same
    /// date and bytes on disk), while a renamed course is written at once.
    @Test func anUnchangedRefreshWritesNothing() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = await launchAndSave(install, token: token)
        let original = try Data(contentsOf: install.file)
        let savedAt = try install.savedSnapshot(token: token).savedAt

        for _ in 0..<3 {
            controller.loadCourses()
            await controller.waitForCourseLoadForTesting()
            await controller.waitForCourseListWriteForTesting()
        }
        #expect(try Data(contentsOf: install.file) == original)
        #expect(try install.savedSnapshot(token: token).savedAt == savedAt)

        MoodleRecordingProtocol.setCourses(token: token, courses: [(1, "Analisi matematica"), (2, "Fisica")])
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        await controller.waitForCourseListWriteForTesting()
        #expect(try install.savedSnapshot(token: token).summaries.map(\.displayName) == ["Analisi matematica", "Fisica"])
    }
}
