import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct TerminalAPITests {
    /// A second caller gets the active run ID. The first caller gets that run's actual result and
    /// file changes, and a later query with a different root cannot read them.
    @Test @MainActor func waitReportsItsRunAndASecondRequestDoesNotStartAnother() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller
        let finishing = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        controller.setBeforeReconciliationStateForTesting {
            finishing.continuation.yield()
            for await _ in release.stream { break }
        }
        let waiter = Task {
            let response = await controller.terminalResponse(["sync", "--wait", "--json"])
            finishing.continuation.finish()
            return response
        }
        defer { release.continuation.finish() }
        var events = finishing.stream.makeAsyncIterator()
        guard await events.next() != nil else {
            Issue.record("The sync command returned before delivering a reconciliation.")
            return
        }

        let duplicate = await controller.terminalResponse(["sync"])
        let duplicateJSON = try payload(duplicate)
        #expect(duplicate.exitCode == 1)
        #expect(duplicateJSON["outcome"] as? String == "already_running")
        let runID = try #require(duplicateJSON["runId"] as? String)
        let status = try await payload(controller.terminalResponse(["status"]))
        #expect(status["activeRunId"] as? String == runID)
        release.continuation.finish()

        let completed = await waiter.value
        let completedJSON = try payload(completed)
        #expect(completed.exitCode == 0)
        #expect(completedJSON["runId"] as? String == runID)
        #expect(completedJSON["outcome"] as? String == "completed")
        #expect((completedJSON["counts"] as? [String: Int])?["added"] == 2)
        #expect(MoodleRecordingProtocol.requests(token: fixture.token).filter { $0.function == "core_course_get_contents" }.count == 1)

        let runs = try await payload(controller.terminalResponse(["runs", runID]))
        #expect((runs["items"] as? [[String: Any]])?.first?["runId"] as? String == runID)
        let changes = try await payload(controller.terminalResponse(["changes", "--run", runID, "--limit", "1"]))
        #expect(changes["total"] as? Int == 2)
        #expect(changes["nextOffset"] as? Int == 1)
        let change = try #require((changes["items"] as? [[String: Any]])?.first)
        #expect(change["kind"] as? String == "added")
        #expect(change["runId"] as? String == runID)
        let since = try await payload(controller.terminalResponse(["changes", "--since", runID]))
        #expect(since["total"] as? Int == 0)

        controller.setRootIDForTesting(UUID())
        let otherRoot = try await payload(controller.terminalResponse(["runs", runID]))
        #expect((otherRoot["error"] as? [String: String])?["code"] == "run_not_found")
    }

    /// A waiter only receives its own outcome when the run is cancelled or its folder changes.
    @Test(arguments: [true, false]) @MainActor
    func waitingRunReportsCancellationOrFolderChange(_ changeFolder: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller
        let finishing = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        controller.setBeforeReconciliationStateForTesting {
            finishing.continuation.yield()
            for await _ in release.stream { break }
        }
        let waiter = Task {
            let response = await controller.terminalResponse(["sync", "--wait"])
            finishing.continuation.finish()
            return response
        }
        defer { release.continuation.finish() }
        var events = finishing.stream.makeAsyncIterator()
        guard await events.next() != nil else {
            Issue.record("The run finished before the test could replace or cancel it.")
            return
        }
        let before = try await payload(controller.terminalResponse(["status"]))
        let id = try #require(before["activeRunId"] as? String)
        if changeFolder { controller.setRootIDForTesting(UUID()) }
        else { controller.cancelSynchronization() }
        release.continuation.finish()
        let result = await waiter.value
        let json = try payload(result)
        #expect(result.exitCode == 4)
        #expect(json["runId"] as? String == id)
        #expect(json["outcome"] as? String == (changeFolder ? "superseded" : "cancelled"))
        #expect(json["counts"] == nil)
    }

    /// A cold catalog query may use matching saved courses and folder names. A cache belonging
    /// to another credential is rejected and preserved on disk.
    @Test @MainActor func savedCatalogChecksCredentialsAndDoesNotWrite() async throws {
        let fixture = try await Fixture(setCurrentCourses: false)
        defer { fixture.remove() }
        let root = fixture.root
        let store = fixture.courses
        let controller = fixture.controller
        let file = root.appending(path: CourseListSnapshotStore.fileName)
        let name = "Saved course"
        let summaries = [RemoteCourseSummary(id: 1, shortName: "LAB", displayName: name, isVisible: true, startDate: nil, endDate: nil)]
        let foreign = CourseListSnapshot.Identity(siteID: controller.selectedSite.id, rootID: fixture.rootID, token: "another-user")
        try await store.save(summaries, identity: foreign)
        let original = try Data(contentsOf: file)
        let refused = try await payload(controller.terminalResponse(["courses"]))
        #expect((refused["error"] as? [String: String])?["code"] == "unavailable")
        #expect(try Data(contentsOf: file) == original)

        let matching = CourseListSnapshot.Identity(siteID: controller.selectedSite.id, rootID: fixture.rootID, token: fixture.token)
        try await store.save(summaries, identity: matching)
        let currentBytes = try Data(contentsOf: file)
        let cached = try await payload(controller.terminalResponse(["courses", "1"]))
        let item = try #require((cached["items"] as? [[String: Any]])?.first)
        #expect(cached["freshness"] as? String == "cached")
        #expect(item["id"] as? String == "1")
        #expect(item["name"] as? String == name)
        #expect(item["selected"] as? Bool == true)
        #expect(controller.courseListFreshness == .unknown)
        #expect(try Data(contentsOf: file) == currentBytes)
        #expect(MoodleRecordingProtocol.requests(token: fixture.token).isEmpty)
    }

    /// A valid empty conflict snapshot differs from a missing recording listing and bad arguments.
    @Test @MainActor func readCommandsDistinguishEmptyUnavailableAndInvalid() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let empty = try await payload(fixture.controller.terminalResponse(["conflicts"]))
        #expect(empty["total"] as? Int == 0)
        let unavailable = await fixture.controller.terminalResponse(["recordings", "--course", "1"])
        #expect(unavailable.exitCode == 1)
        #expect((try payload(unavailable)["error"] as? [String: String])?["code"] == "unavailable")
        let invalid = await fixture.controller.terminalResponse(["sync", "--course", "1"])
        #expect(invalid.exitCode == 2)
        #expect((try payload(invalid)["error"] as? [String: String])?["code"] == "invalid_arguments")
        #expect(MoodleRecordingProtocol.requests(token: fixture.token).isEmpty)
    }

    /// An otherwise successful run still needs the user's attention when choices remain open.
    @Test func existingPendingChoicesProduceTheIssuesExitCode() throws {
        let summary = SyncCompletionSummary(completedAt: Date(), added: 0, updated: 0,
            unchanged: 1, preservedLocal: 0, conflicts: 0, failures: 0)
        let end = MaterialsRunEnd.completed(conflicts: 0, failures: 0)
        let clean = TerminalRun(id: UUID(), end: end, summary: summary, pendingChoiceCount: 0)
        let pending = TerminalRun(id: UUID(), end: end, summary: summary, pendingChoiceCount: 2)
        let result = TerminalOutput.success(pending.fields, exitCode: pending.exitCode)
        let json = try payload(result)
        #expect(clean.exitCode == 0)
        #expect(result.exitCode == 3)
        #expect(json["outcome"] as? String == "completed_with_issues")
        #expect(json["pendingChoiceCount"] as? Int == 2)
        #expect((json["counts"] as? [String: Int])?["conflicts"] == 0)
    }

    /// The CLI combines known archive and linked recordings, preserves partial coverage, and
    /// pages through the combined list without making another archive request.
    @Test @MainActor func recordingsPageIncludesArchiveAndLinkedLessons() async throws {
        let browser = FakeRecmanBrowser()
        let defaults = MemoryCountingDefaults.isolated()
        var lessons = ManualWebexLessons()
        let linked = try lessons.add(
            link: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/0123456789abcdef0123456789abcdef",
            title: "Guest lecture", courseName: "Analysis", courseID: 1)
        defaults.set(try PropertyListEncoder().encode(lessons), forKey: RecordingsController.manualLessonsKey(owner: 7))
        let fixture = try await Fixture(setCurrentCourses: false,
            enrollments: [(1, "058167 - ANALISI 2 [2026-27]"), (2, "058168 - GEOMETRIA [2026-27]")],
            defaults: defaults, recordingsBrowser: { browser })
        defer { fixture.remove() }
        let controller = fixture.controller
        let key = try #require(RecmanCourseKey(courseCode: "058167", academicYear: 2026))
        let archive = RecmanRecording(id: "archive-1", courseCode: key.courseCode, academicYear: key.academicYear,
            title: "Archive lecture", recordedAt: Date(), kind: "Webex", duration: "45 min", size: nil,
            previewURL: URL(string: "https://example.invalid/recording/private")!)
        browser.listResults[key.courseCode] = .success([archive])
        await controller.completeLoginForTesting(moodleLoginCallback(token: fixture.token),
            polimiCookies: [FakeRecmanBrowser.cookie("SSO_LOGIN")])
        _ = await controller.recordings.refreshForSync([key], force: false)
        let calls = browser.listCalls

        let first = try await payload(controller.terminalResponse(["recordings", "--limit", "1"]))
        let archiveRow = try #require((first["items"] as? [[String: Any]])?.first)
        #expect(first["total"] as? Int == 2)
        #expect(first["nextOffset"] as? Int == 1)
        #expect(first["unavailableCourseIds"] as? [String] == ["2"])
        #expect((first["listingCoverage"] as? [[String: Any]])?.first?["freshness"] as? String == "current")
        #expect(archiveRow["id"] as? String == archive.id)
        #expect(archiveRow["source"] as? String == "archive")
        #expect(archiveRow["previewURL"] == nil)

        let second = try await payload(controller.terminalResponse(["recordings", "--offset", "1", "--limit", "1", "--course", "1"]))
        let linkedRow = try #require((second["items"] as? [[String: Any]])?.first)
        #expect(second["nextOffset"] is NSNull)
        #expect(linkedRow["id"] as? String == linked.id)
        #expect(linkedRow["freshness"] as? String == "local")
        #expect(linkedRow["link"] == nil)
        #expect(browser.listCalls == calls)
        await controller.recordings.settleSessionFile()
    }

    private func payload(_ response: TerminalResponse) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: response.json)
        let fields = try #require(object as? [String: Any])
        #expect(fields["schemaVersion"] as? Int == 1)
        return fields
    }

    private struct Fixture {
        let root: URL
        let rootID: UUID
        let token: String
        let courses: CourseListSnapshotStore
        let controller: WeBeepAuthenticationController

        @MainActor init(setCurrentCourses: Bool = true,
                        enrollments: [(Int64, String)] = [(1, "CLI Course")],
                        defaults: UserDefaults? = nil,
                        recordingsBrowser: (@MainActor () -> RecmanBrowsing)? = nil) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "BeepbarCLITest-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let rootID = UUID()
            let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            let token = MoodleRecordingProtocol.register(courses: enrollments, files: [1: ["first.pdf", "second.pdf"]])
            let vault = CredentialVault(read: { _ in token }, write: { _ in })
            let courses = CourseListSnapshotStore { root }
            self.root = root
            self.rootID = rootID
            self.token = token
            self.courses = courses
            self.controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID,
                apiClient: MoodleRecordingProtocol.makeClient(), downloader: MoodleRecordingProtocol.makeDownloader(), credentialVault: vault,
                defaults: defaults ?? MemoryCountingDefaults.isolated(),
                recordingsStore: RecordingsSessionStore { root.appending(path: "recordings") },
                recordingsBrowser: recordingsBrowser, courseListStore: courses)
            if setCurrentCourses {
                controller.setCoursesForTesting([RemoteCourseSummary(id: 1, shortName: "LAB", displayName: "CLI Course", isVisible: true, startDate: nil, endDate: nil)])
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
