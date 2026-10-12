import Combine
import Foundation
import Testing
import BeepbarCore
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
}
