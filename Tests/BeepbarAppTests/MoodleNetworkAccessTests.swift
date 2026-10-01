import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct MoodleNetworkAccessTests {
    /// Proves that signing in and loading the course list may use any network, metered hotspot and
    /// Low Data Mode included: the user asked for them. Guards against a change that restricts the
    /// app's Moodle requests, the way downloads can be restricted. The Core test
    /// `manualSyncReadsCourseContentsOverAnyNetwork` guards "Sincronizza ora".
    @Test @MainActor func signingInAndLoadingCoursesUseAnyNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")])
        let vault = CredentialVault(read: { _ in token }, write: { _ in })
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault)

        await controller.completeLoginForTesting(moodleLoginCallback(token: token))

        // Sign-in and the course load really went through the local Moodle.
        #expect(controller.courseLoadError == nil)
        #expect(controller.courses.map(\.id) == [1])
        let requests = MoodleRecordingProtocol.requests(token: token)
        #expect(Set(requests.map(\.function)) == ["core_webservice_get_site_info", "core_enrol_get_users_courses"])
        #expect(requests.allSatisfy { $0.allowsExpensiveNetworkAccess && $0.allowsConstrainedNetworkAccess })
    }
}
