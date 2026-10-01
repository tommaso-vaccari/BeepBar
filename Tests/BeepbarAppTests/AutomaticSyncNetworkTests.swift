import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct AutomaticSyncNetworkTests {
    /// Known issue: proves that a scheduled run sends every Moodle request (site info, enrolled
    /// courses, course contents) over a metered hotspot and under Low Data Mode, while
    /// docs/sync-behavior §6 says automatic sync uses neither; only file downloads are restricted.
    /// The Core test `automaticSyncReadsCourseContentsWithoutExpensiveOrConstrainedNetworkAccess`
    /// covers the course contents alone; this one also covers the requests the app makes itself.
    ///
    /// It sees the restrictions set on each request, as downloads do today. Whether the code or
    /// the specification changes is still to be decided:
    /// - every request restricted: `withKnownIssue` reports that the issue no longer occurs; remove
    ///   the wrapper and keep the test;
    /// - the whole run deferred on a metered or Low Data network: no request is sent and the sanity
    ///   checks below fail; rewrite the test around the deferral;
    /// - the specification changed instead: delete this test and its Core counterpart, and update
    ///   both `sync-behavior` files.
    @Test @MainActor func automaticSyncKeepsEveryMoodleRequestOffMeteredAndLowDataNetworks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: true))
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")])
        let vault = CredentialVault(read: { _ in token }, write: { _ in Issue.record("An automatic sync must not store a token") })
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault)

        await controller.runAutomaticSyncForTesting()

        // The run really completed and asked Moodle for everything a scheduled run needs: a run
        // that stopped early, or a broken local Moodle, would leave nothing to check.
        guard case .synced = controller.syncState else {
            Issue.record("The automatic sync did not complete: \(controller.syncState)")
            return
        }
        let requests = MoodleRecordingProtocol.requests(token: token)
        #expect(Set(requests.map(\.function)) == ["core_webservice_get_site_info", "core_enrol_get_users_courses", "core_course_get_contents"])
        withKnownIssue("Automatic sync sends Moodle requests over metered and Low Data networks") {
            #expect(requests.allSatisfy { !$0.allowsExpensiveNetworkAccess && !$0.allowsConstrainedNetworkAccess })
        }
    }
}
