import Foundation
import Testing
@testable import BeepbarCore

struct ModulePathMigratorTests {
    @Test func previewRejectsOccupiedDestinationForUntrackedFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let courseID: Int64 = 42
        let moduleID: Int64 = 7
        let destination = try RelativePath("Course/Custom/notes.pdf")
        let destinationURL = fixture.root.appending(path: destination.value)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local untracked file".utf8).write(to: destinationURL)

        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let fileStore = try FileStore(root: fixture.root)
        let apiClient = WeBeepAPIClient(session: URLSession(configuration: .ephemeral))
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: fileStore, gate: RootOperationGate(), apiClient: apiClient)
        let file = RemoteFileCandidate(
            id: "remote-untracked",
            courseID: courseID,
            sectionID: 3,
            moduleID: moduleID,
            sectionName: "Resources",
            moduleName: "Slides",
            filename: "notes.pdf",
            remoteFilePath: "/",
            canonicalPluginPath: "pluginfile.php/42/notes.pdf",
            downloadURL: nil,
            size: 10,
            modifiedAt: nil,
            observedRevision: "1",
            isSupported: true
        )
        let contents = RemoteCourseContents(
            sections: [RemoteContentSection(id: 3, name: "Resources", modules: [RemoteContentModule(id: moduleID, name: "Slides", files: [file])])],
            issueCount: 0
        )

        await #expect(throws: ModulePathMigrationError.destinationOccupied(destination.value)) {
            try await migrator.preview(courseID: courseID, moduleID: moduleID, courseFolder: "Course", action: .set, folder: "Custom", contents: contents)
        }
        #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "local untracked file")
    }

    @Test func deletingUnavailableRuleWaitsForPendingSyncOperation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let courseID: Int64 = 42
        let moduleID: Int64 = 7
        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        try await database.beginOperation(PendingOperation(
            rootID: rootID,
            remoteID: "pending",
            destination: try RelativePath("Course/pending.pdf"),
            stagePath: try RelativePath(internal: ".beepbar/staging/pending.partial"),
            expectedLocal: .missing,
            remoteSHA256: "sha",
            remoteRevision: "1"
        ))
        let fileStore = try FileStore(root: fixture.root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectNetworkProtocol.self]
        let apiClient = WeBeepAPIClient(session: URLSession(configuration: configuration))
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: fileStore, gate: RootOperationGate(), apiClient: apiClient)

        await #expect(throws: ModulePathMigrationError.pendingOperation) {
            try await migrator.deleteUnavailableRule(courseID: courseID, moduleID: moduleID, token: "token")
        }
        #expect(try await database.pendingOperations(rootID: rootID).count == 1)
    }

    @Test func previewStaysValidWhileOtherCoursesAttributeTheirOlderFiles() async throws {
        // `apply` rebuilds the preview and refuses it when the fingerprint moved. A background
        // sync of another course attributing its own older files must not invalidate it.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootID = UUID()
        let database = try SyncDatabase(url: fixture.base.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let migrator = ModulePathMigrator(rootID: rootID, database: database, fileStore: try FileStore(root: fixture.root), gate: RootOperationGate(), apiClient: WeBeepAPIClient(session: URLSession(configuration: .ephemeral)))
        try await database.upsertBaseline(rootID: rootID, baseline: ownerless("course-old", "Course/Archivio/old.pdf"))
        try await database.upsertBaseline(rootID: rootID, baseline: ownerless("other-old", "Other/old.pdf"))
        let contents = slidesContents()

        let before = try await migrator.preview(courseID: 42, moduleID: 7, courseFolder: "Course", action: .set, folder: "Custom", contents: contents)
        #expect(before.ownerlessBaselineCount == 1)

        // What a sync of "Other" does meanwhile: attributes its older file, finds a new one.
        try await database.backfillModuleOwnership(rootID: rootID, files: [remoteFile(id: "other-old", courseID: 99, moduleID: 1)])
        try await database.upsertBaseline(rootID: rootID, baseline: ownerless("other-new", "Other/new.pdf"))
        // A sibling folder sharing the course folder's prefix is another course, too.
        try await database.upsertBaseline(rootID: rootID, baseline: ownerless("sibling-old", "Course 2/old.pdf"))

        let after = try await migrator.preview(courseID: 42, moduleID: 7, courseFolder: "Course", action: .set, folder: "Custom", contents: contents)
        #expect(after.fingerprint == before.fingerprint)
        #expect(after.ownerlessBaselineCount == 1)

        // An older file of this very course still changes the plan (spelled as the disk allows).
        try await database.upsertBaseline(rootID: rootID, baseline: ownerless("course-older", "COURSE/old2.pdf"))
        let changed = try await migrator.preview(courseID: 42, moduleID: 7, courseFolder: "Course", action: .set, folder: "Custom", contents: contents)
        #expect(changed.ownerlessBaselineCount == 2)
        #expect(changed.fingerprint != before.fingerprint)
    }

    @Test func ownerlessCountCoversOnlyThisCoursesUnattributedFilesNotBeingMoved() throws {
        let baselines = Dictionary(uniqueKeysWithValues: try [
            ownerless("a", "Course/a.pdf"),
            ownerless("b", "course/Sezione/b.pdf"),
            ownerless("moved", "Course/moved.pdf"),
            ownerless("elsewhere", "Other/c.pdf"),
            ownerless("sibling", "Course 2/d.pdf"),
            ownerless("prefix", "Coursework/e.pdf"),
            Baseline(remoteID: "owned", relativePath: try RelativePath("Course/owned.pdf"), sha256: "h", remoteRevision: "1", courseID: 42, moduleID: 3),
        ].map { ($0.remoteID, $0) })
        #expect(ModulePathMigrator.ownerlessBaselineCount(baselines: baselines, courseFolder: "Course", excluding: ["moved"]) == 2)
        #expect(ModulePathMigrator.ownerlessBaselineCount(baselines: baselines, courseFolder: "Other", excluding: []) == 1)
        #expect(ModulePathMigrator.ownerlessBaselineCount(baselines: [:], courseFolder: "Course", excluding: []) == 0)
    }

    private func ownerless(_ id: String, _ path: String) throws -> Baseline {
        Baseline(remoteID: id, relativePath: try RelativePath(path), sha256: "hash-\(id)", remoteRevision: "1")
    }

    private func remoteFile(id: String, courseID: Int64, moduleID: Int64) -> RemoteFileCandidate {
        RemoteFileCandidate(id: id, courseID: courseID, sectionID: 3, moduleID: moduleID, sectionName: "Resources", moduleName: "Slides", filename: "\(id).pdf", remoteFilePath: "/", canonicalPluginPath: "pluginfile.php/\(courseID)/\(id).pdf", downloadURL: nil, size: 10, modifiedAt: nil, observedRevision: "1", isSupported: true)
    }

    private func slidesContents() -> RemoteCourseContents {
        RemoteCourseContents(
            sections: [RemoteContentSection(id: 3, name: "Resources", modules: [RemoteContentModule(id: 7, name: "Slides", files: [remoteFile(id: "remote-new", courseID: 42, moduleID: 7)])])],
            issueCount: 0
        )
    }

    private func makeFixture() throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let root = base.appending(path: "sync", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }
}

private final class RejectNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
