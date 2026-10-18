import Combine
import Foundation
import Testing
import os
@testable import BeepbarCore
@testable import BeepbarApp

/// The course list saved between launches (#98), through the real controller: a local Moodle
/// (`MoodleRecordingProtocol`), a real sync database and a throwaway folder for the saved list.
/// Each "launch" of one install gets a store of its own over that folder, as two processes would,
/// so nothing a store remembers in memory carries over. Each test names the acceptance rule it
/// guards; the codec and store rules themselves are in `CourseListSnapshotTests`.
@MainActor struct SavedCourseListTests {
    /// One install: a sync folder with its database (course 1 enabled in "Analisi I", course 2
    /// off), and the folder the saved list lives in.
    private struct Install {
        let root: URL
        let database: SyncDatabase
        let rootID: UUID
        let storeFolder: URL

        static func make() async throws -> Install {
            let root = FileManager.default.temporaryDirectory.appending(path: "SavedCourseListTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
            let rootID = UUID()
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Analisi", localFolder: "Analisi I", enabled: true))
            try await database.upsertScope(SyncScope(rootID: rootID, courseID: 2, displayName: "Fisica", localFolder: "Fisica", enabled: false))
            let storeFolder = root.appending(path: "support", directoryHint: .isDirectory)
            return Install(root: root, database: database, rootID: rootID, storeFolder: storeFolder)
        }

        var file: URL { storeFolder.appending(path: CourseListSnapshotStore.fileName) }

        /// The saved list's store as a new process opens it.
        func store() -> CourseListSnapshotStore {
            let folder = storeFolder
            return CourseListSnapshotStore { folder }
        }

        /// A controller as one launch of the app makes it, signed in with `token`.
        @MainActor func launch(token: String) -> WeBeepAuthenticationController {
            launch(vault: CredentialVault(read: { _ in token }, write: { _ in }))
        }

        @MainActor func launch(vault: CredentialVault) -> WeBeepAuthenticationController {
            WeBeepAuthenticationController(
                testRootURL: root, database: database, rootID: rootID,
                apiClient: MoodleRecordingProtocol.makeClient(), downloader: MoodleRecordingProtocol.makeDownloader(),
                credentialVault: vault, deleteCredential: {},
                courseListStore: store()
            )
        }

        /// A launch whose network-path changes come from `reachability` (#168).
        @MainActor func launch(token: String, reachability: FakeReachability) -> WeBeepAuthenticationController {
            WeBeepAuthenticationController(
                testRootURL: root, database: database, rootID: rootID,
                apiClient: MoodleRecordingProtocol.makeClient(), downloader: MoodleRecordingProtocol.makeDownloader(),
                credentialVault: CredentialVault(read: { _ in token }, write: { _ in }), deleteCredential: {},
                reachabilityChanges: reachability.changes,
                courseListStore: store()
            )
        }

        /// Writes a saved list directly, as an earlier launch would have.
        func save(_ courses: [RemoteCourseSummary], token: String) async throws {
            try await store().save(courses, identity: identity(token: token))
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

    /// A hang detector, not a timing bound: on the 3-core CI runner an actor hop can wait behind a
    /// busy cooperative pool for well over 10 s, which failed two tests after #138 merged (as in
    /// 02b7dad). Locally these conditions hold within milliseconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
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

    /// A course-folder rename settled in the database by an earlier operation (#183) while the
    /// window still shows the old name, which is what a rename whose flush failed leaves behind:
    /// "Sincronizza ora" syncs into the renamed folder (RA-001). Fails if the manual sync builds
    /// its targets from the stale name: it would recreate an empty "Analisi I", point the course
    /// at it and download there, splitting the course between two folders.
    @Test func aManualSyncFollowsACourseRenameSettledEarlier() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")], files: [1: ["a.txt"]])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = await launchAndSave(install, token: token)
        try #require(controller.courseFolders[1] == "Analisi I")
        // A current list, so the sync does not reload it (and the folders with it) first.
        try #require(controller.courseListFreshness == .current)
        let store = try FileStore(root: install.root)
        let identity = try await store.ensureTopLevelDirectory("Renamed").identity
        try await install.database.upsertScope(SyncScope(rootID: install.rootID, courseID: 1, displayName: "Analisi", localFolder: "Renamed", enabled: true, managedDirectory: identity))

        controller.synchronizeNow()
        await controller.waitForSyncForTesting()
        #expect(!FileManager.default.fileExists(atPath: install.root.appending(path: "Analisi I").path), "the sync recreated the old folder")
        #expect(FileManager.default.fileExists(atPath: install.root.appending(path: "Renamed/Lezioni/a.txt").path))
        let scope = try await install.database.scope(rootID: install.rootID, courseID: 1)
        #expect(scope?.localFolder == "Renamed")
        #expect(scope?.managedDirectory == identity)
        #expect(controller.courseFolders[1] == "Renamed")
    }

    /// A rename (here of course 2) that settles another course's non-durable rename (#183)
    /// leaves the window showing the folder the database now records, not the old name
    /// (RA-001). Fails if `renameFolder` only reads back its own course's success.
    @Test func aRenameThatSettlesAnEarlierOneShowsItsNewFolder() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = await launchAndSave(install, token: token)
        try #require(controller.courseFolders[1] == "Analisi I")
        let store = try FileStore(root: install.root)
        for (course, name, folder) in [(Int64(1), "Analisi", "Analisi I"), (2, "Fisica", "Fisica")] {
            let identity = try await store.ensureTopLevelDirectory(folder).identity
            try await install.database.upsertScope(SyncScope(rootID: install.rootID, courseID: course, displayName: name, localFolder: folder, enabled: course == 1, managedDirectory: identity))
        }
        // What a rename whose flush failed leaves: the folder renamed on disk, the row pending.
        try FileManager.default.moveItem(at: install.root.appending(path: "Analisi I"), to: install.root.appending(path: "Renamed"))
        try await install.database.beginScopeMove(PendingScopeMove(id: UUID(), rootID: install.rootID, courseID: 1, oldFolder: "Analisi I", newFolder: "Renamed"))

        controller.renameFolder(for: controller.courses.first { $0.id == 2 }!, to: "Fisica 2")
        try await waitUntil { controller.renamingCourseID == nil }
        #expect(controller.courseRenameErrors.isEmpty)
        #expect(try await install.database.pendingScopeMoves().isEmpty)
        #expect(controller.courseFolders[2] == "Fisica 2")
        #expect(controller.courseFolders[1] == "Renamed")
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

    // MARK: Review round 1

    private func course(_ id: Int64, _ name: String) -> RemoteCourseSummary {
        RemoteCourseSummary(id: id, shortName: name, displayName: name, isVisible: true, startDate: nil, endDate: nil)
    }

    /// A window opened while a sync runs, with nothing saved (every user's first opening after
    /// updating): the page shows the loading state, not "no courses", and the list is loaded as
    /// soon as the sync ends. Fails if the deferred load is dropped (the page would stay empty
    /// until the refresh button) or the loading state ends early.
    @Test func aWindowOpenedDuringASyncLoadsTheListWhenItEnds() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = install.launch(token: token)
        let operation = UUID()
        controller.setOperationForTesting(operation)

        await controller.refreshOnWindowOpen().value
        #expect(controller.courses.isEmpty)
        #expect(controller.isPreparingCourseList, "the page said no courses while the list was only waiting for the sync")
        #expect(!MoodleRecordingProtocol.requests(token: token).contains { $0.function == "core_enrol_get_users_courses" })

        await controller.failSyncForTesting(operation)
        // Nil, and so no wait, if ending the sync started no load.
        await controller.waitForCourseLoadForTesting()
        #expect(controller.courses.map(\.id) == [1, 2], "the list the window asked for did not load when the sync ended")
        #expect(controller.courseListFreshness == .current)
        #expect(!controller.isPreparingCourseList)
    }

    /// The same with a saved list: it is shown at once, says it is refreshing while the sync holds
    /// the load back, and is confirmed when the sync ends. Closing the window first cancels the
    /// deferred load, so a closed window sends nothing.
    @Test func aSavedListOpenedDuringASyncIsConfirmedWhenItEndsUnlessTheWindowClosed() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        _ = await launchAndSave(install, token: token)

        let relaunched = install.launch(token: token)
        let operation = UUID()
        relaunched.setOperationForTesting(operation)
        await relaunched.refreshOnWindowOpen().value
        guard case .saved = relaunched.courseListFreshness else {
            Issue.record("The saved list was not shown during the sync: \(relaunched.courseListFreshness)")
            return
        }
        #expect(relaunched.isPreparingCourseList)
        await relaunched.failSyncForTesting(operation)
        await relaunched.waitForCourseLoadForTesting()
        #expect(relaunched.courseListFreshness == .current)

        let closing = install.launch(token: token)
        let second = UUID()
        closing.setOperationForTesting(second)
        await closing.refreshOnWindowOpen().value
        closing.windowClosed()
        let requests = MoodleRecordingProtocol.requests(token: token).count
        await closing.failSyncForTesting(second)
        await closing.waitForCourseLoadForTesting()
        #expect(MoodleRecordingProtocol.requests(token: token).count == requests, "a closed window still loaded the list when the sync ended")
    }

    /// The window closed while its refresh still waited for the launch bootstrap: nothing is
    /// asked of Moodle for a window nobody sees, and no loading state is left behind. Fails if
    /// the refresh loads the list regardless (or defers it to the end of a sync).
    @Test func aWindowClosedBeforeItsRefreshStartsAsksNothing() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = install.launch(token: token)
        let (released, release) = AsyncStream<Void>.makeStream()
        controller.holdBootstrapForTesting(Task { for await _ in released {} })

        let refresh = controller.refreshOnWindowOpen()
        #expect(controller.isPreparingCourseList)
        controller.windowClosed()
        release.finish()
        await refresh.value
        await controller.waitForCourseLoadForTesting()
        #expect(!controller.isPreparingCourseList)
        #expect(!controller.isLoadingCourses)
        #expect(MoodleRecordingProtocol.requests(token: token).isEmpty, "a closed window asked Moodle for the list")
    }

    /// Defence in depth: a sync that cannot ask Moodle for the list (not connected) never takes
    /// its selection from a saved list on screen. Fails if the saved list's enabled course is
    /// synced.
    @Test func aSyncThatCannotRefreshNeverSyncsTheSavedList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.save([course(1, "Analisi")], token: token)
        let controller = install.launch(token: token)
        await controller.restoreSavedCourseListForTesting()
        try #require(controller.isShowingSavedCourseList)
        try #require(controller.enabledCourseIDs.contains(1))

        controller.setDisconnectedForTesting()
        controller.synchronizeNow()
        await controller.waitForSyncForTesting()
        #expect(MoodleRecordingProtocol.requests(token: token).isEmpty, "the saved list decided what was synced")
    }

    /// No credential at launch, so no account the saved list could belong to (an older BeepBar
    /// signed out, or a sign-out's deletion never ran): the file is deleted, as the behaviour
    /// documents, instead of waiting for a sign-in that may never come.
    @Test func aLaunchWithoutACredentialDeletesTheSavedList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.save([course(1, "Analisi")], token: token)
        #expect(FileManager.default.fileExists(atPath: install.file.path))

        let controller = install.launch(token: token)
        await controller.applyBootstrapWithoutCredentialForTesting()
        await controller.waitForCourseListWriteForTesting()
        #expect(!controller.hasStoredCredential)
        #expect(!FileManager.default.fileExists(atPath: install.file.path), "the saved list outlived the credential")
    }

    /// No credential at launch while a pending operation blocks recovery: the saved list is
    /// deleted all the same (the blocked-recovery return used to skip it), whether the credential
    /// is absent or unreadable as corrupt. Fails if the deletion waits for recovery.
    @Test(arguments: [false, true]) func aBlockedLaunchWithoutACredentialStillDeletesTheSavedList(corrupt: Bool) async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.save([course(1, "Analisi")], token: token)
        #expect(FileManager.default.fileExists(atPath: install.file.path))

        let controller = install.launch(token: token)
        await controller.applyBootstrapWithoutCredentialForTesting(recoveryBlocked: true, corrupt: corrupt)
        await controller.waitForCourseListWriteForTesting()
        #expect(controller.recoveryBlocked)
        #expect(!FileManager.default.fileExists(atPath: install.file.path), "the saved list outlived the credential behind a blocked recovery")
    }

    /// A list older than 30 days goes at launch even if the window never opens, the only moment
    /// the file is otherwise read; a younger one stays for the next opening.
    @Test func aLaunchDeletesAnExpiredListWithoutTheWindow() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.store().save([course(1, "Analisi")], identity: install.identity(token: token), now: Date().addingTimeInterval(-CourseListSnapshotCodec.maximumAge + 3_600))

        let first = install.launch(token: token)
        await first.applyBootstrapWithCredentialForTesting()
        await first.waitForCourseListWriteForTesting()
        #expect(FileManager.default.fileExists(atPath: install.file.path), "a list within 30 days was deleted at launch")

        try await install.store().save([course(1, "Analisi"), course(2, "Fisica")], identity: install.identity(token: token), now: Date().addingTimeInterval(-CourseListSnapshotCodec.maximumAge - 3_600))
        let second = install.launch(token: token)
        await second.applyBootstrapWithCredentialForTesting()
        await second.waitForCourseListWriteForTesting()
        #expect(second.hasStoredCredential)
        #expect(!FileManager.default.fileExists(atPath: install.file.path), "an expired list outlived the launch")
    }

    /// A launch with a credential but a blocked recovery runs no sync, so the launch is the only
    /// moment the age limit can be enforced: an expired list goes all the same.
    @Test func aBlockedLaunchStillDeletesAnExpiredList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.store().save([course(1, "Analisi")], identity: install.identity(token: token), now: Date().addingTimeInterval(-CourseListSnapshotCodec.maximumAge - 3_600))

        let controller = install.launch(token: token)
        await controller.applyBootstrapWithCredentialForTesting(recoveryBlocked: true)
        await controller.waitForCourseListWriteForTesting()
        #expect(controller.recoveryBlocked)
        #expect(!FileManager.default.fileExists(atPath: install.file.path), "an expired list outlived a blocked launch")
    }

    /// A menu-bar-only user, app running for weeks: the automatic sync, which never reads or
    /// writes the saved list, still deletes it once it is older than 30 days.
    @Test func anAutomaticSyncDeletesAnExpiredList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.store().save([course(1, "Analisi")], identity: install.identity(token: token), now: Date().addingTimeInterval(-CourseListSnapshotCodec.maximumAge - 3_600))

        let controller = install.launch(token: token)
        await controller.runAutomaticSyncForTesting()
        await controller.waitForCourseListWriteForTesting()
        #expect(!FileManager.default.fileExists(atPath: install.file.path), "an expired list outlived the automatic sync")
    }

    /// The same from the menu: a long-running session whose list Moodle confirmed weeks ago, a
    /// «Sincronizza ora» over that current list (which asks Moodle nothing and saves nothing)
    /// still deletes the expired file.
    @Test func aSyncOverACurrentListDeletesAnExpiredList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.store().save([course(1, "Analisi")], identity: install.identity(token: token), now: Date().addingTimeInterval(-CourseListSnapshotCodec.maximumAge - 3_600))

        let controller = install.launch(token: token)
        controller.setCoursesForTesting([course(1, "Analisi")])
        controller.synchronizeNow()
        await controller.waitForSyncForTesting()
        await controller.waitForCourseListWriteForTesting()
        #expect(!FileManager.default.fileExists(atPath: install.file.path), "an expired list outlived «Sincronizza ora»")
    }

    /// The credential found missing or corrupt while loading the list: signed out in all but
    /// name, so the saved list goes too.
    @Test func aCredentialFoundMissingDeletesTheSavedList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.save([course(1, "Analisi")], token: token)

        let controller = install.launch(vault: CredentialVault(read: { _ in throw CredentialStorageError.absent }, write: { _ in }))
        await controller.refreshOnWindowOpen().value
        await controller.waitForCourseListWriteForTesting()
        #expect(!controller.hasStoredCredential)
        #expect(controller.courses.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: install.file.path))
    }

    /// Choosing another university (only possible signed out) deletes a saved list left behind.
    @Test func choosingAnotherUniversityDeletesTheSavedList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.save([course(1, "Analisi")], token: token)

        let controller = install.launch(token: token)
        controller.setDisconnectedForTesting()
        let other = try #require(MoodleSite.unipd.first { $0 != controller.selectedSite })
        controller.selectSite(other)
        await controller.waitForCourseListWriteForTesting()
        #expect(controller.selectedSite == other)
        #expect(!FileManager.default.fileExists(atPath: install.file.path))
    }

    /// A failure of the previous account's token, answered after another account signed in, says
    /// nothing about the new one: it must not mark the new sign-in expired or show an error.
    @Test func aLateFailureOfThePreviousTokenDoesNotExpireTheNewSignIn() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let a = MoodleRecordingProtocol.register(courses: [(1, "Analisi")], userID: 11)
        let b = MoodleRecordingProtocol.register(courses: [(3, "Chimica")], userID: 22)
        defer { MoodleRecordingProtocol.revoke(token: a); MoodleRecordingProtocol.revoke(token: b) }
        let controller = install.launch(token: a)

        MoodleRecordingProtocol.holdCourseLists(token: a)
        controller.loadCourses()
        try await waitUntil { MoodleRecordingProtocol.heldCourseListCount(token: a) == 1 }
        let login = Task { await controller.completeLoginForTesting(moodleLoginCallback(token: b)) }
        try await waitUntil {
            MoodleRecordingProtocol.requests(token: b).contains { $0.function == "core_webservice_get_site_info" } && !controller.isAuthenticating
        }
        MoodleRecordingProtocol.reject(token: a)
        MoodleRecordingProtocol.releaseCourseLists(token: a)
        await login.value
        await controller.waitForCourseLoadForTesting()

        #expect(controller.accountState == .connected, "the previous token's rejection expired the new sign-in")
        #expect(controller.courseLoadError == nil)
        #expect(controller.courses.map(\.id) == [3])
    }

    /// The second check in a refresh: a sign-out while the folders are being read, after Moodle
    /// answered, still drops the answer instead of publishing it, and saves nothing.
    @Test func aSignOutDuringTheFolderReadDropsTheRefresh() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = install.launch(token: token)
        var published: [[Int64]] = []
        let subscription = controller.$courses.dropFirst().sink { published.append($0.map(\.id)) }
        defer { subscription.cancel() }
        controller.setBeforeScopeRestoreForTesting {
            controller.setDisconnectedForTesting()
            controller.forgetCourseListForTesting()
        }

        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        let nothingPublished = published.allSatisfy { $0.isEmpty }
        #expect(nothingPublished, "a refresh that began for the previous account was published: \(published)")
        #expect(controller.courseListFreshness == .unknown)
        await controller.waitForCourseListWriteForTesting()
        #expect(!FileManager.default.fileExists(atPath: install.file.path))
    }

    /// The restore only reads: a saved name that differs from the database's (renamed on Moodle
    /// since) is shown, but no record is updated and no folder renamed until Moodle confirms it;
    /// the folder shown is the database's. Fails if the restore goes through `restoreScopes`, or
    /// if a switch or a folder rename is accepted over the saved list.
    @Test func restoringASavedListRecordsNothing() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.save([course(1, "Analisi matematica"), course(2, "Fisica")], token: token)
        let before = try await install.database.scopes(rootID: install.rootID)

        let controller = install.launch(token: token)
        await controller.restoreSavedCourseListForTesting()
        #expect(controller.isShowingSavedCourseList)
        #expect(controller.courses.map(\.displayName).contains("Analisi matematica"))
        #expect(controller.folder(for: controller.courses.first { $0.id == 1 }!) == "Analisi I")
        let after = try await install.database.scopes(rootID: install.rootID)
        #expect(after.map(\.displayName) == before.map(\.displayName))
        #expect(after.map(\.localFolder) == before.map(\.localFolder))

        // Nor can the user record anything for it: switches and renames wait for Moodle's list.
        let enabled = controller.enabledCourseIDs
        controller.setCourse(controller.courses.first { $0.id == 2 }!, enabled: true)
        #expect(controller.enabledCourseIDs == enabled)
        #expect(try await install.database.scopes(rootID: install.rootID).map(\.enabled) == before.map(\.enabled))

        // A rename is refused before it starts: no rename in progress, no error, the folder on
        // disk and in the database untouched. Fails if `renameFolder` accepts a saved list.
        try FileManager.default.createDirectory(at: install.root.appending(path: "Analisi I", directoryHint: .isDirectory), withIntermediateDirectories: true)
        controller.renameFolder(for: controller.courses.first { $0.id == 1 }!, to: "Analisi rinominata")
        #expect(controller.renamingCourseID == nil, "a rename started over a saved list")
        #expect(controller.courseRenameErrors.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await install.database.scopes(rootID: install.rootID).map(\.localFolder) == before.map(\.localFolder))
        #expect(!FileManager.default.fileExists(atPath: install.root.appending(path: "Analisi rinominata").path))
    }

    /// Choosing another folder over a saved list: the saved list is set aside and Moodle's list
    /// loaded, so the new folder's records come from Moodle only. A course in the saved list that
    /// Moodle no longer lists (course 9) gets no record there. Fails if the saved list goes
    /// through `restoreScopes` for the new folder.
    @Test func choosingAFolderOverASavedListUsesMoodlesList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        try await install.save([course(1, "Analisi"), course(2, "Fisica"), course(9, "Corso finito")], token: token)
        let controller = install.launch(token: token)
        await controller.restoreSavedCourseListForTesting()
        #expect(controller.courses.map(\.id).contains(9))

        let newRoot = FileManager.default.temporaryDirectory.appending(path: "SavedCourseListTests-new-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: newRoot) }
        await controller.useRootForTesting(newRoot)
        await controller.waitForCourseLoadForTesting()
        let newRootID = try #require(try await install.database.rootID(canonicalPath: newRoot.resolvingSymlinksInPath().path))
        let scopes = try await install.database.scopes(rootID: newRootID)
        #expect(!scopes.contains { $0.courseID == 9 }, "the saved list created records in the new folder")
        #expect(controller.courses.map(\.id) == [1, 2])
        #expect(controller.courseListFreshness == .current)
    }

    /// A sync from the menu right after a launch, before the window ever opened, confirms an
    /// unchanged list: nothing is written (no disk write when nothing changed).
    @Test func aSyncAfterARelaunchDoesNotRewriteAnUnchangedList() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        _ = await launchAndSave(install, token: token)
        let written = try Data(contentsOf: install.file)

        let relaunched = install.launch(token: token)
        relaunched.synchronizeNow()
        await relaunched.waitForSyncForTesting()
        await relaunched.waitForCourseListWriteForTesting()
        #expect(relaunched.courseListFreshness == .current)
        #expect(try Data(contentsOf: install.file) == written, "an unchanged list was rewritten at the first sync of a launch")
    }

    // MARK: Refresh error after the connection returns (#168)

    /// The refresh a sync runs over a saved list confirms it, so the error of an earlier offline
    /// refresh goes with it, even with the window closed (nothing else would retry). Fails if a
    /// confirmed list leaves `courseLoadError` set, as before #168, when only a new
    /// `loadCourses()` cleared it.
    @Test func aSyncThatConfirmsTheListClearsTheRefreshError() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        _ = await launchAndSave(install, token: token)
        MoodleRecordingProtocol.setOffline(token: token, true)
        let relaunched = install.launch(token: token)
        await relaunched.refreshOnWindowOpen().value
        try #require(relaunched.courseLoadError != nil)
        relaunched.windowClosed()

        MoodleRecordingProtocol.setOffline(token: token, false)
        relaunched.synchronizeNow()
        await relaunched.waitForSyncForTesting()
        #expect(relaunched.courseListFreshness == .current)
        #expect(relaunched.courseLoadError == nil, "the list was confirmed but its old refresh error stayed")
    }

    /// The reported case where a sync was running: the window opens over an earlier refresh error
    /// while a sync runs over a list already confirmed. `loadCourses` returns before clearing the
    /// error and that sync never refreshes the list, so the list is reloaded when the sync ends.
    /// A window closed before then asks nothing. Fails if `endOperation` reloads only
    /// `isPreparingCourseList` (the banner stays up until the refresh button is pressed).
    @Test func aWindowOpenedOverAnErrorDuringASyncRetriesWhenItEnds() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = await launchAndSave(install, token: token)
        MoodleRecordingProtocol.setOffline(token: token, true)
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        try #require(controller.courseLoadError != nil)
        controller.windowClosed()

        MoodleRecordingProtocol.setOffline(token: token, false)
        let operation = UUID()
        controller.setOperationForTesting(operation)
        await controller.refreshOnWindowOpen().value
        #expect(controller.courseLoadError != nil, "the error went away without a refresh")
        await controller.failSyncForTesting(operation)
        await controller.waitForCourseLoadForTesting()
        #expect(controller.courseLoadError == nil, "the error of a refresh before the sync stayed up after it")
        #expect(controller.courseListFreshness == .current)

        // The same, with the window closed before the sync ends: no request for a window nobody sees.
        MoodleRecordingProtocol.setOffline(token: token, true)
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        try #require(controller.courseLoadError != nil)
        MoodleRecordingProtocol.setOffline(token: token, false)
        let second = UUID()
        controller.setOperationForTesting(second)
        await controller.refreshOnWindowOpen().value
        controller.windowClosed()
        let requests = MoodleRecordingProtocol.requests(token: token).count
        await controller.failSyncForTesting(second)
        await controller.waitForCourseLoadForTesting()
        #expect(MoodleRecordingProtocol.requests(token: token).count == requests, "a closed window reloaded the list when the sync ended")
    }

    /// The reported bug: the window opens right after waking, before Wi-Fi is up, and the refresh
    /// fails. When the network comes back the refresh is retried by itself and the banner goes.
    /// A retry that fails again keeps the same watch (one per failure, so no loop of requests),
    /// and confirming the list stops it, so nothing watches the network at rest. Fails if the
    /// watch is never started, retries nothing, or outlives the confirmed list.
    @Test func aRefreshThatFailedOfflineIsRetriedWhenTheNetworkReturns() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi"), (2, "Fisica")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        _ = await launchAndSave(install, token: token)
        MoodleRecordingProtocol.setOffline(token: token, true)
        let reachability = FakeReachability()
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        try #require(controller.courseLoadError != nil)
        #expect(reachability.starts == 1, "a connection failure in an open window started no watch")

        // A route appears but Moodle still can't be reached: one retry, which fails, same watch.
        var requests = MoodleRecordingProtocol.requests(token: token).count
        reachability.send(true)
        try await waitUntil { MoodleRecordingProtocol.requests(token: token).count > requests && !controller.isLoadingCourses && controller.courseLoadError != nil }
        await controller.waitForCourseLoadForTesting()
        #expect(reachability.starts == 1, "a failed retry started another watch")

        MoodleRecordingProtocol.setOffline(token: token, false)
        requests = MoodleRecordingProtocol.requests(token: token).count
        reachability.send(true)
        try await waitUntil { controller.courseListFreshness == .current }
        await controller.waitForCourseLoadForTesting()
        #expect(MoodleRecordingProtocol.requests(token: token).count > requests)
        #expect(controller.courseLoadError == nil)
        try await waitUntil { reachability.terminated == 1 }
        #expect(reachability.starts == 1)
    }

    /// Closing the window ends the watch: a failure nobody sees is not retried, and no monitor
    /// keeps running at rest. Fails if `windowClosed()` leaves the watch alive.
    @Test func closingTheWindowStopsWatchingTheNetwork() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        MoodleRecordingProtocol.setOffline(token: token, true)
        let reachability = FakeReachability()
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        try #require(controller.courseLoadError != nil)
        try #require(reachability.starts == 1)

        controller.windowClosed()
        try await waitUntil { reachability.terminated == 1 }
    }

    /// Only a connection failure is watched: a server answer that isn't a course list doesn't end
    /// when the network changes, and a failure while the window is closed has nobody to show it
    /// to. Fails if either starts a watch.
    @Test func onlyAConnectionFailureInAnOpenWindowWatchesTheNetwork() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        MoodleRecordingProtocol.setMalformedCourseLists(token: token, true)
        let reachability = FakeReachability()
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        try #require(controller.courseLoadError != nil)
        #expect(reachability.starts == 0, "a server error started watching the network")

        let closed = install.launch(token: token, reachability: reachability)
        MoodleRecordingProtocol.setMalformedCourseLists(token: token, false)
        MoodleRecordingProtocol.setOffline(token: token, true)
        closed.loadCourses()
        await closed.waitForCourseLoadForTesting()
        try #require(closed.courseLoadError != nil)
        #expect(reachability.starts == 0, "a failure with the window closed started watching the network")
    }

    // MARK: Review round 1 (#168)

    /// How many times this account asked Moodle for its course list.
    private func courseListRequests(_ token: String) -> Int {
        MoodleRecordingProtocol.requests(token: token).filter { $0.function == "core_enrol_get_users_courses" }.count
    }

    /// A sync ending with the window open and no error asks Moodle for nothing: the reload at the
    /// end of a sync is for a connection failure only. Fails if every sync with the window open
    /// reloads the list (a site-info and course-list request per sync, for nothing new).
    @Test func aSyncEndingInAnOpenWindowWithoutAnErrorAsksNothing() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = await launchAndSave(install, token: token)
        try #require(controller.courseLoadError == nil)
        let operation = UUID()
        controller.setOperationForTesting(operation)
        let requests = MoodleRecordingProtocol.requests(token: token).count
        await controller.failSyncForTesting(operation)
        await controller.waitForCourseLoadForTesting()
        #expect(MoodleRecordingProtocol.requests(token: token).count == requests, "a sync with no refresh error reloaded the list")
    }

    /// A server error is not retried by itself, not even when a sync ends with the window open:
    /// the specification says it waits for the refresh button. Fails if the end of a sync reloads
    /// on any error.
    @Test func aServerErrorIsNotRetriedWhenASyncEnds() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        let controller = await launchAndSave(install, token: token)
        MoodleRecordingProtocol.setMalformedCourseLists(token: token, true)
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        try #require(controller.courseLoadError != nil)
        let operation = UUID()
        controller.setOperationForTesting(operation)
        let requests = courseListRequests(token)
        await controller.failSyncForTesting(operation)
        await controller.waitForCourseLoadForTesting()
        #expect(courseListRequests(token) == requests, "a server error was retried at the end of a sync")
        #expect(controller.courseLoadError != nil)
    }

    /// A quit stops the network watch and, winding a sync down, starts no course refresh on its
    /// way out, even with the window open over a connection failure (no Keychain or network work
    /// while quitting). Fails if `prepareForTermination` leaves the watch running or
    /// `endOperation` reloads during termination.
    @Test func aQuitStopsTheWatchAndStartsNoCourseRefresh() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        MoodleRecordingProtocol.setOffline(token: token, true)
        let reachability = FakeReachability()
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        try #require(controller.courseLoadError != nil)
        try #require(reachability.starts == 1)
        MoodleRecordingProtocol.setOffline(token: token, false)
        let operation = UUID()
        controller.setOperationForTesting(operation)
        _ = controller.prepareForTermination()
        try await waitUntil { reachability.terminated == 1 }
        let requests = MoodleRecordingProtocol.requests(token: token).count
        await controller.failSyncForTesting(operation)
        await controller.waitForCourseLoadForTesting()
        #expect(MoodleRecordingProtocol.requests(token: token).count == requests, "a quit started a course refresh")
    }

    /// A refresh that then fails for another reason (a server error, from the refresh button)
    /// ends the watch: a network change can't fix it. Fails if the watch outlives a failure that
    /// is not a connection one.
    @Test func aServerErrorAfterAConnectionFailureStopsTheWatch() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        MoodleRecordingProtocol.setOffline(token: token, true)
        let reachability = FakeReachability()
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        try #require(reachability.starts == 1)
        MoodleRecordingProtocol.setOffline(token: token, false)
        MoodleRecordingProtocol.setMalformedCourseLists(token: token, true)
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        try #require(controller.courseLoadError != nil)
        try await waitUntil { reachability.terminated == 1 }
    }

    /// A watch whose stream ends by itself (no path monitor available) does not block the next
    /// one: a later connection failure watches again. Fails if the finished watch stays recorded
    /// as running.
    @Test func aWatchWhoseStreamEndedLetsTheNextFailureWatch() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        MoodleRecordingProtocol.setOffline(token: token, true)
        let reachability = FakeReachability()
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        try #require(reachability.starts == 1)
        reachability.finish()
        try await waitUntil { !controller.isWatchingForNetworkReturnForTesting }
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        #expect(reachability.starts == 2, "an ended watch kept the next failure from watching")
    }

    /// `NWPathMonitor` reports the current path at once: if the route is already back when the
    /// watch starts, the list is retried once straight away, and a retry that fails again waits
    /// for a real network change instead of looping. Fails if the first value is skipped (Wi-Fi
    /// back before the watch started would never be retried) or each failure re-arms a watch.
    @Test func aRouteAlreadyBackIsRetriedOnceAtOnce() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        MoodleRecordingProtocol.setOffline(token: token, true)
        let reachability = FakeReachability(initial: true)
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        // The window's attempt, then one immediate retry, which fails too. Offline, each attempt
        // stops at its first request (site info), so two attempts are two requests.
        try await waitUntil { MoodleRecordingProtocol.requests(token: token).count == 2 && !controller.isLoadingCourses && controller.courseLoadError != nil }
        await controller.waitForCourseLoadForTesting()
        for _ in 0..<50 { await Task.yield() }
        #expect(MoodleRecordingProtocol.requests(token: token).count == 2, "a failed retry kept retrying without a network change")
        #expect(reachability.starts == 1)

        MoodleRecordingProtocol.setOffline(token: token, false)
        reachability.send(true)
        try await waitUntil { controller.courseListFreshness == .current }
        #expect(controller.courseLoadError == nil)
    }

    /// "WeBeep isn't responding" is a connection failure too: it is watched and retried when the
    /// network changes. Fails if the timeout branch starts no watch.
    @Test func aTimeoutIsRetriedWhenTheNetworkReturns() async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        MoodleRecordingProtocol.setTimingOut(token: token, true)
        let reachability = FakeReachability()
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        try #require(controller.courseLoadError != nil)
        #expect(reachability.starts == 1, "a timeout started no watch")
        MoodleRecordingProtocol.setTimingOut(token: token, false)
        reachability.send(true)
        try await waitUntil { controller.courseListFreshness == .current }
        #expect(controller.courseLoadError == nil)
    }

    /// Signing out, or the sign-in expiring, ends the watch: the network coming back fixes
    /// neither. Fails if either leaves the path monitor running with the window open.
    @Test(arguments: [false, true]) func losingTheAccountStopsWatchingTheNetwork(expire: Bool) async throws {
        let install = try await Install.make()
        defer { install.remove() }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Analisi")])
        defer { MoodleRecordingProtocol.revoke(token: token) }
        MoodleRecordingProtocol.setOffline(token: token, true)
        let reachability = FakeReachability()
        let controller = install.launch(token: token, reachability: reachability)
        await controller.refreshOnWindowOpen().value
        try #require(reachability.starts == 1)
        if expire {
            MoodleRecordingProtocol.setOffline(token: token, false)
            MoodleRecordingProtocol.reject(token: token)
            reachability.send(true)
            try await waitUntil { controller.accountState == .expired }
        } else {
            controller.signOut(removeFile: { _ in })
        }
        try await waitUntil { reachability.terminated == 1 }
    }
}

/// Network-path changes a test sends by hand in place of `NWPathMonitor` (#168). Counts the
/// watches started and ended, so a test can tell whether anything still watches the network.
final class FakeReachability: Sendable {
    /// What a new watch hears first, as `NWPathMonitor` reports the current path at once; `nil`
    /// sends nothing until `send(_:)`.
    private let initial: Bool?
    init(initial: Bool? = nil) { self.initial = initial }

    private struct State {
        var continuation: AsyncStream<Bool>.Continuation?
        var starts = 0
        var terminated = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var changes: @Sendable () -> AsyncStream<Bool> {
        { [self] in
            let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
            continuation.onTermination = { [self] _ in state.withLock { $0.terminated += 1 } }
            state.withLock { $0.continuation = continuation; $0.starts += 1 }
            if let initial { continuation.yield(initial) }
            return stream
        }
    }

    func send(_ reachable: Bool) { _ = state.withLock { $0.continuation }?.yield(reachable) }
    /// Ends the current watch's stream, as a monitor that stops delivering would.
    func finish() { state.withLock { $0.continuation }?.finish() }
    var starts: Int { state.withLock { $0.starts } }
    var terminated: Int { state.withLock { $0.terminated } }
}
