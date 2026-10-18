import Foundation
import Testing
@testable import BeepbarCore

struct CourseFolderRenamerTests {
    @Test func retainsTheScopeJournalWhenDirectorySyncFailsAfterRename() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let databaseURL = root.appending(path: "state.sqlite")
        let database = try SyncDatabase(url: databaseURL)
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root, beforeMove: nil, syncDirectory: { _ in throw FileStoreError.ioFailure })
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try Data("local edit".utf8).write(to: root.appending(path: "Old/file.txt"))
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file", relativePath: RelativePath("Old/file.txt"), sha256: "original", remoteRevision: "1"))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        await #expect(throws: FileStoreError.self) { try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New") }
        #expect(try await database.pendingScopeMoves().count == 1)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")
        #expect(try Data(contentsOf: root.appending(path: "New/file.txt")) == Data("local edit".utf8))
        let reopened = try SyncDatabase(url: databaseURL)
        _ = try await RecoveryCoordinator(rootID: rootID, database: reopened, fileStore: FileStore(root: root)).recover()
        #expect(try await reopened.pendingScopeMoves().isEmpty)
        #expect(try await reopened.scope(rootID: rootID, courseID: 1)?.localFolder == "New")
        #expect(try await reopened.baseline(rootID: rootID, remoteID: "file")?.relativePath == RelativePath("New/file.txt"))
    }

    /// While a rename whose flush failed is unfinished (#183), renaming another course refuses
    /// with `PendingCourseFolderRenameError` (the specific error the app explains, not the generic
    /// database one) and moves nothing: both the pending rename and the other course stay as they
    /// are. Launch recovery settles the row, after which the same rename succeeds. Fails if the
    /// renamer settles the pending rename in-session or lets the second rename run.
    @Test func anUnfinishedRenameBlocksTheNextRenameUntilLaunchRecovery() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let flush = FlushFailures()
        let store = try FileStore(root: root, beforeMove: nil, syncDirectory: { try flush.sync($0) })
        for (course, folder) in [(Int64(1), "Old"), (2, "Other")] {
            let identity = try await store.ensureTopLevelDirectory(folder).identity
            try await database.upsertScope(SyncScope(rootID: rootID, courseID: course, displayName: folder, localFolder: folder, enabled: true, managedDirectory: identity))
        }
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        flush.failNext(1)
        await #expect(throws: FileStoreError.mutationNotDurable) { try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New") }

        await #expect(throws: PendingCourseFolderRenameError()) { try await renamer.rename(rootID: rootID, courseID: 2, from: "Other", to: "Renamed") }
        #expect(try await database.pendingScopeMoves().count == 1)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")
        #expect(try await database.scope(rootID: rootID, courseID: 2)?.localFolder == "Other")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Other").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Renamed").path))

        _ = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: FileStore(root: root)).recover()
        #expect(try await database.pendingScopeMoves().isEmpty)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "New")
        try await renamer.rename(rootID: rootID, courseID: 2, from: "Other", to: "Renamed")
        #expect(try await database.scope(rootID: rootID, courseID: 2)?.localFolder == "Renamed")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Renamed").path))
    }

    @Test func renamesDirectoryCreatedAfterScopeRegistration() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true))
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "New").path))
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "New")
    }

    @Test func renamesManagedDirectoryAndTrackedPath() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let path = try RelativePath("Old/notes.txt")
        try Data("local bytes".utf8).write(to: root.appending(path: path.value))
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file", relativePath: path, sha256: "base", remoteRevision: "1"))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        #expect(try String(contentsOf: root.appending(path: "New/notes.txt"), encoding: .utf8) == "local bytes")
        #expect(try await database.baseline(rootID: rootID, remoteID: "file")?.relativePath.value == "New/notes.txt")
        #expect(try await database.pendingScopeMoves().isEmpty)
    }

    @Test func recoveryFinishesRenameAfterFilesystemMove() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: 1, oldFolder: "Old", newFolder: "New")
        try await database.beginScopeMove(move)
        try await store.renameTopLevelDirectory(from: "Old", to: "New")
        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.recovered.contains(move.id))
        #expect(try await database.pendingScopeMoves().isEmpty)
    }

    @Test func recoveryLeavesReplacementAtOldPathUnresolved() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: 1, oldFolder: "Old", newFolder: "New")
        try await database.beginScopeMove(move)
        try FileManager.default.removeItem(at: root.appending(path: "Old"))
        try FileManager.default.createDirectory(at: root.appending(path: "Old"), withIntermediateDirectories: true)

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.unresolved.contains(move.id))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Old").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "New").path))
        #expect(try await database.pendingScopeMoves().contains(where: { $0.id == move.id }))
    }

    @Test func recoveryDoesNotCommitReplacementAtNewPath() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: 1, oldFolder: "Old", newFolder: "New")
        try await database.beginScopeMove(move)
        try FileManager.default.removeItem(at: root.appending(path: "Old"))
        try FileManager.default.createDirectory(at: root.appending(path: "New"), withIntermediateDirectories: true)

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.unresolved.contains(move.id))
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")
        #expect(try await database.pendingScopeMoves().contains(where: { $0.id == move.id }))
    }

    @Test func refusesToRenameUnmanagedDirectory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true))
        try FileManager.default.createDirectory(at: root.appending(path: "Old"), withIntermediateDirectories: true)
        let renamer = CourseFolderRenamer(database: database, fileStore: try FileStore(root: root), gate: RootOperationGate())
        await #expect(throws: SyncDatabaseError.self) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Old").path))
    }

    @Test func refusesToRenameIntoTheReservedNamespace() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        await #expect(throws: FileStoreError.invalidStage) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: ".BEEPBAR")
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Old").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".BEEPBAR").path))
        #expect(try await database.pendingScopeMoves().isEmpty)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")
    }

    @Test func refusesToRenameOntoAnExistingFolderAndKeepsTheCourseRenameable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        _ = try await store.ensureTopLevelDirectory("Taken")
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())

        await #expect(throws: CourseRenameError.folderAlreadyExists) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "Taken")
        }
        #expect(CourseRenameError.folderAlreadyExists.errorDescription == "Esiste già una cartella con questo nome.")
        #expect(try await database.pendingScopeMoves().isEmpty)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")

        try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "New")
    }

    @Test func rollsBackThePendingMoveWhenTheDirectoryRenameFails() async throws {
        let root = try temporaryRoot()
        let databaseDirectory = try temporaryRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: databaseDirectory)
        }
        let rootID = UUID()
        let database = try SyncDatabase(url: databaseDirectory.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())

        // A read-only sync root lets every check pass and makes the directory rename itself fail,
        // which is the moment the pending row has already been written.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        await #expect(throws: (any Error).self) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        }
        #expect(try await database.pendingScopeMoves().isEmpty)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")

        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.unresolved.isEmpty)

        // The course is still renameable once the cause of the failure is gone.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "New")
        #expect(try await database.pendingScopeMoves().isEmpty)
    }

    @Test(arguments: ["device", "inode", "both"])
    func renamesRestoredDirectoryWithAStaleIdentity(_ changed: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        let stale = DirectoryIdentity(device: identity.device + (changed == "inode" ? 0 : 1), inode: identity.inode + (changed == "device" ? 0 : 1))
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: stale))
        try Data("edited notes".utf8).write(to: root.appending(path: "Old/notes.txt"))
        try Data("personal".utf8).write(to: root.appending(path: "Old/personal.txt"))
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file", relativePath: try RelativePath("Old/notes.txt"), sha256: "original", remoteRevision: "1"))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        #expect(try String(contentsOf: root.appending(path: "New/notes.txt"), encoding: .utf8) == "edited notes")
        #expect(try String(contentsOf: root.appending(path: "New/personal.txt"), encoding: .utf8) == "personal")
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.managedDirectory == identity)
        #expect(try await database.baseline(rootID: rootID, remoteID: "file")?.relativePath.value == "New/notes.txt")
        try await renamer.rename(rootID: rootID, courseID: 1, from: "New", to: "Again")
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Again")
        #expect(try await database.pendingScopeMoves().isEmpty)
    }

    @Test(arguments: [JournalStep.journaled, .filesystemChanged])
    func recoversARestoredDirectoryRename(_ stoppedAt: JournalStep) async throws {
        struct Interrupted: Error {}
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: DirectoryIdentity(device: identity.device + 1, inode: identity.inode + 1)))
        try Data("notes".utf8).write(to: root.appending(path: "Old/notes.txt"))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate(), interruption: { step in
            if step == stoppedAt { throw Interrupted() }
        })
        await #expect(throws: Interrupted.self) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        }
        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.unresolved.isEmpty)
        #expect(try String(contentsOf: root.appending(path: "New/notes.txt"), encoding: .utf8) == "notes")
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.managedDirectory == identity)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "New")
        #expect(try await database.pendingScopeMoves().isEmpty)
    }

    @Test func aRetryDoesNotChangeTheIdentityOfAnUnfinishedRename() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let pending = PendingScopeMove(id: UUID(), rootID: rootID, courseID: 1, oldFolder: "Old", newFolder: "New")
        try await database.beginScopeMove(pending)
        try FileManager.default.moveItem(at: root.appending(path: "Old"), to: root.appending(path: "Saved"))
        _ = try await store.ensureTopLevelDirectory("Old")
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate())
        await #expect(throws: PendingCourseFolderRenameError()) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "Again")
        }
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.managedDirectory == identity)
        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
        #expect(report.unresolved.contains(pending.id))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Old").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "New").path))
    }

    @Test func refusesAReplacementAfterTheRenameWasPrepared() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let store = try FileStore(root: root)
        let identity = try await store.ensureTopLevelDirectory("Old").identity
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Old", enabled: true, managedDirectory: identity))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate(), interruption: { step in
            if step == .journaled {
                try FileManager.default.moveItem(at: root.appending(path: "Old"), to: root.appending(path: "Saved"))
                try FileManager.default.createDirectory(at: root.appending(path: "Old"), withIntermediateDirectories: false)
                try Data("replacement".utf8).write(to: root.appending(path: "Old/personal.txt"))
            }
        })
        await #expect(throws: FileStoreError.invalidStage) {
            try await renamer.rename(rootID: rootID, courseID: 1, from: "Old", to: "New")
        }
        #expect(try String(contentsOf: root.appending(path: "Old/personal.txt"), encoding: .utf8) == "replacement")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Saved").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "New").path))
        #expect(try await database.pendingScopeMoves().isEmpty)
        #expect(try await database.scope(rootID: rootID, courseID: 1)?.localFolder == "Old")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

/// Makes the next `n` directory flushes fail, then flushes for real.
final class FlushFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0
    func failNext(_ count: Int) { lock.withLock { remaining = count } }
    func sync(_ descriptor: Int32) throws {
        let fail = lock.withLock { () -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if fail { throw FileStoreError.ioFailure }
        guard fsync(descriptor) == 0 else { throw FileStoreError.ioFailure }
    }
}
