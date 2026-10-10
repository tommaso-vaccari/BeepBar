#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import BeepbarCore

/// Stops the real journaled sequences (`SyncTransactionCoordinator`, `CourseFolderRenamer`) after
/// each durable step, as a crash of the app would, then relaunches: a fresh `SyncDatabase` reads
/// the journal back from disk and `RecoveryCoordinator` runs as it does at launch. Each test
/// checks the state the user ends up with: the downloaded version in place, or their own copy
/// kept with the download set aside as a conflict, and nothing left half done that would block
/// later syncs ("Intervento richiesto").
///
/// What this proves and what it doesn't: a process crash loses nothing that was already written,
/// so stopping the sequence and reopening from disk reproduces it exactly. A kernel panic or power
/// cut can also lose writes that weren't yet synced to the drive; that is what
/// `synchronous = FULL` (`SyncDatabase.init`) and the `fsync` after every `FileStore` rename are
/// for, and no test in a running process can show it. Also not reached here: a crash inside
/// `FileStore.install` between a swap and its swap back (recovery leaves it unresolved, which is
/// safe), and `ConflictResolver.useRemote`, which doesn't take the hook (its install is covered
/// by `chosenRemoteVersionIsInstalledAfterACrash`; a crash before `markResolved` leaves the old
/// conflict listed).
struct InterruptedSyncRecoveryTests {
    /// A new file, interrupted after each step, ends up installed and tracked.
    @Test(arguments: [JournalStep.journaled, .filesystemChanged, .committed])
    func newFileIsFinishedAfterACrash(at step: JournalStep) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.crashInstalling("remote", expectedLocal: .missing, at: step)

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.conflicts.isEmpty && report.recovered.count == 1)
        #expect(try fixture.contents() == "remote")
        #expect(try await fixture.database().baseline(rootID: fixture.rootID, remoteID: "file")?.sha256 == hash("remote"))
        #expect(try await fixture.database().pendingOperations().isEmpty)
        #expect(try fixture.stagedFiles().isEmpty)
    }

    /// An update of a file the user never touched, interrupted after each step, ends up replaced
    /// and tracked, and the old copy doesn't linger in the staging folder.
    @Test(arguments: JournalStep.allCases)
    func replacementIsFinishedAfterACrash(at step: JournalStep) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.synced("base")
        try await fixture.crashInstalling("remote", expectedLocal: .present(sha256: hash("base")), at: step)

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.conflicts.isEmpty && report.recovered.count == 1)
        #expect(try fixture.contents() == "remote")
        #expect(try await fixture.database().baseline(rootID: fixture.rootID, remoteID: "file")?.sha256 == hash("remote"))
        #expect(try await fixture.database().pendingOperations().isEmpty)
        #expect(try fixture.stagedFiles().isEmpty)
    }

    /// The user had edited the file before the sync, so the download goes aside as a conflict. A
    /// crash at either step still ends with their copy untouched and the conflict listed.
    @Test(arguments: [JournalStep.journaled, .filesystemChanged])
    func localEditBecomesAConflictAfterACrash(at step: JournalStep) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.synced("base")
        try fixture.writeLocal("mine")
        try await fixture.crashInstalling("remote", expectedLocal: .present(sha256: hash("base")), at: step)

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.conflicts.count == 1)
        try await fixture.expectConflictKeepingLocal("mine")
    }

    /// `recordConflict` (a conflict found before any install: the user edited a synced file, or
    /// had a file of their own where a new one was going) interrupted after each step. A crash
    /// right after journaling used to install the download over the edit and delete the edit.
    @Test(arguments: [JournalStep.journaled, .filesystemChanged], [true, false])
    func recordedConflictSurvivesACrash(at step: JournalStep, wasSynced: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLocal("mine")
        let (database, store) = try await fixture.open()
        if wasSynced {
            try await database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: "file", relativePath: fixture.path, sha256: hash("base"), remoteRevision: "1"))
        }
        let artifact = try await fixture.stage("remote", in: store)
        let coordinator = SyncTransactionCoordinator(database: database, fileStore: store, interruption: Fixture.crash(at: step))
        await #expect(throws: Fixture.Crash.self) {
            _ = try await coordinator.recordConflict(rootID: fixture.rootID, remoteID: "file", destination: fixture.path, local: .present(sha256: hash("mine")), remote: RemoteState(sha256: artifact.sha256, revision: "2"), artifact: artifact)
        }

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.conflicts.count == 1)
        try await fixture.expectConflictKeepingLocal("mine")
        #expect(try await fixture.database().conflicts(rootID: fixture.rootID).first?.baseSHA256 == (wasSynced ? hash("base") : nil))
    }

    /// The crash hits before the swap, and the user edits the file before BeepBar starts again.
    /// Recovery must not install over the edit: the edit stays, the download becomes a conflict.
    @Test func editMadeAfterACrashBeforeTheSwapIsKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.synced("base")
        try await fixture.crashInstalling("remote", expectedLocal: .present(sha256: hash("base")), at: .journaled)
        try fixture.writeLocal("edited while BeepBar was closed")

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.conflicts.count == 1)
        try await fixture.expectConflictKeepingLocal("edited while BeepBar was closed")
    }

    /// Same for a new file: the user puts their own file where the download was going.
    @Test func fileCreatedAfterACrashBeforeTheInstallIsKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.crashInstalling("remote", expectedLocal: .missing, at: .journaled)
        try fixture.writeLocal("my own file")

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.conflicts.count == 1)
        try await fixture.expectConflictKeepingLocal("my own file")
    }

    /// The crash hits right after the swap, and the user then edits the new version. Recovery
    /// keeps the edit and records the download as the baseline, so the next sync sees a local
    /// change and leaves the file alone.
    @Test func editOfTheSwappedFileAfterACrashIsKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.synced("base")
        try await fixture.crashInstalling("remote", expectedLocal: .present(sha256: hash("base")), at: .filesystemChanged)
        try fixture.writeLocal("annotated")

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.recovered.count == 1)
        #expect(try fixture.contents() == "annotated")
        let baseline = try #require(try await fixture.database().baseline(rootID: fixture.rootID, remoteID: "file"))
        #expect(SyncPlanner.decide(baseline: baseline, local: .present(sha256: hash("annotated")), remote: RemoteState(sha256: hash("remote"), revision: "2")) == .preserveLocal)
        #expect(try await fixture.database().pendingOperations().isEmpty)
        #expect(try fixture.stagedFiles().isEmpty)
    }

    /// The crash hits right after a new file was installed, before it was recorded, and the user
    /// then edits it. Nothing is left to finish (the download is the file they edited), and this
    /// used to stay unresolved, blocking every sync behind "Intervento richiesto" with no way out
    /// but choosing another folder. Now the journal row goes and the edit stays. No sync runs
    /// here: the planner check only shows what the next one decides from this state (no synced
    /// version and a file unlike Moodle's: a conflict, never an overwrite).
    @Test func editOfANewFileAfterACrashDoesNotBlockSyncing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.crashInstalling("remote", expectedLocal: .missing, at: .filesystemChanged)
        try fixture.writeLocal("annotated")

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty)
        #expect(try fixture.contents() == "annotated")
        let baseline = try await fixture.database().baseline(rootID: fixture.rootID, remoteID: "file")
        #expect(SyncPlanner.decide(baseline: baseline, local: .present(sha256: hash("annotated")), remote: RemoteState(sha256: hash("remote"), revision: "2")) == .conflict)
        #expect(try await fixture.database().pendingOperations().isEmpty)
    }

    /// Same, but the user deletes the new file. The planner check shows the next sync downloads it
    /// again, as for any file deleted on the Mac (run end to end in
    /// `ManualSyncEngineIntegrationTests.installFailingAfterItWasJournaledDoesNotBlockLaterSyncs`).
    @Test func deletionOfANewFileAfterACrashDoesNotBlockSyncing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.crashInstalling("remote", expectedLocal: .missing, at: .filesystemChanged)
        try FileManager.default.removeItem(at: fixture.destinationURL)

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        let baseline = try await fixture.database().baseline(rootID: fixture.rootID, remoteID: "file")
        #expect(SyncPlanner.decide(baseline: baseline, local: .missing, remote: RemoteState(sha256: hash("remote"), revision: "2")) == .installRemote)
        #expect(try await fixture.database().pendingOperations().isEmpty)
    }

    /// A stage that vanished while a conflict copy with other bytes sits where recovery would look
    /// for it is not a state recovery understands: it stays unresolved rather than guessing.
    @Test func unexpectedConflictCopyStaysUnresolved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.crashInstalling("remote", expectedLocal: .missing, at: .filesystemChanged)
        try fixture.writeLocal("annotated")
        let operation = try #require(try await fixture.database().pendingOperations().first)
        let stray = fixture.root.appending(path: ".beepbar/conflicts/\(operation.id.uuidString)/\(fixture.path.value)")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("something else".utf8).write(to: stray)

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved == [operation.id])
        #expect(try fixture.contents() == "annotated")
        #expect(try await fixture.database().pendingOperations().map(\.id) == [operation.id])
    }

    /// A conflict row as releases before this fix journaled it: the user's edit as the file to
    /// replace. Recovery must not install over it; the edit stays and the download becomes a
    /// conflict against the last synced version. With `earlierRemote`, the same edit is already
    /// in an open conflict with an older Moodle version: that conflict must not count as the user
    /// choosing this newer download, even when only Moodle's revision changed.
    @Test(arguments: [nil, "older remote", "remote"] as [String?])
    func olderConflictRowNeverInstallsOverTheEdit(earlierRemote: String?) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.synced("base")
        try fixture.writeLocal("mine")
        let (database, store) = try await fixture.open()
        if let earlierRemote {
            let older = try await fixture.stage(earlierRemote, in: store)
            _ = try await SyncTransactionCoordinator(database: database, fileStore: store).recordConflict(rootID: fixture.rootID, remoteID: "file", destination: fixture.path, local: .present(sha256: hash("mine")), remote: RemoteState(sha256: older.sha256, revision: "2"), artifact: older)
        }
        let artifact = try await fixture.stage("remote", in: store)
        try await database.beginOperation(PendingOperation(rootID: fixture.rootID, remoteID: "file", destination: fixture.path, stagePath: artifact.stagePath, expectedLocal: .present(sha256: hash("mine")), remoteSHA256: artifact.sha256, remoteRevision: "3"))

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.conflicts.count == 1)
        #expect(try fixture.contents() == "mine")
        let conflicts = try await fixture.database().conflicts(rootID: fixture.rootID)
        #expect(conflicts.count == (earlierRemote != nil ? 2 : 1))
        let recovered = try #require(conflicts.first { $0.remoteRevision == "3" })
        #expect(try String(contentsOf: fixture.root.appending(path: recovered.incomingPath.value), encoding: .utf8) == "remote")
        #expect(recovered.localSHA256 == hash("mine"))
        #expect(recovered.baseSHA256 == hash("base"))
        #expect(try await fixture.database().pendingOperations().isEmpty)
        #expect(try fixture.stagedFiles().isEmpty)
    }

    /// The user chose Moodle's version of a conflict ("Usa versione Moodle"), and the install was
    /// interrupted before the swap: recovery still installs it over the edit, as the user asked.
    /// Guards the other side of the check above, which must not turn a choice into a new conflict.
    @Test func chosenRemoteVersionIsInstalledAfterACrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.synced("base")
        try fixture.writeLocal("mine")
        let (database, store) = try await fixture.open()
        let first = try await fixture.stage("remote", in: store)
        _ = try await SyncTransactionCoordinator(database: database, fileStore: store).recordConflict(rootID: fixture.rootID, remoteID: "file", destination: fixture.path, local: .present(sha256: hash("mine")), remote: RemoteState(sha256: first.sha256, revision: "2"), artifact: first)
        // `useRemote` installs a copy of the download, expecting the user's copy it recorded.
        let copy = try await fixture.stage("remote", in: store)
        let coordinator = SyncTransactionCoordinator(database: database, fileStore: store, interruption: Fixture.crash(at: .journaled))
        await #expect(throws: Fixture.Crash.self) {
            _ = try await coordinator.install(rootID: fixture.rootID, remoteID: "file", destination: fixture.path, expectedLocal: .present(sha256: hash("mine")), remote: RemoteState(sha256: copy.sha256, revision: "2"), artifact: copy)
        }

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.conflicts.isEmpty && report.recovered.count == 1)
        #expect(try fixture.contents() == "remote")
        #expect(try await fixture.database().pendingOperations().isEmpty)
    }

    /// A course folder rename interrupted after each step ends with the folder, its files and
    /// their tracked paths under the new name.
    @Test(arguments: [JournalStep.journaled, .filesystemChanged])
    func courseRenameIsFinishedAfterACrash(at step: JournalStep) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (database, store) = try await fixture.open()
        let identity = try await store.ensureTopLevelDirectory("Course").identity
        try await database.upsertScope(SyncScope(rootID: fixture.rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: true, managedDirectory: identity))
        try fixture.writeLocal("notes")
        try await database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: "file", relativePath: fixture.path, sha256: hash("notes"), remoteRevision: "1"))
        let renamer = CourseFolderRenamer(database: database, fileStore: store, gate: RootOperationGate(), interruption: Fixture.crash(at: step))
        await #expect(throws: Fixture.Crash.self) {
            try await renamer.rename(rootID: fixture.rootID, courseID: 1, from: "Course", to: "Renamed")
        }
        #expect(try await fixture.database().pendingScopeMoves().count == 1, "the crash must leave the move journaled on disk")

        let report = try await fixture.relaunchAndRecover()

        #expect(report.unresolved.isEmpty && report.recovered.count == 1)
        #expect(try String(contentsOf: fixture.root.appending(path: "Renamed/notes.txt"), encoding: .utf8) == "notes")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course").path))
        let relaunched = try fixture.database()
        #expect(try await relaunched.scope(rootID: fixture.rootID, courseID: 1)?.localFolder == "Renamed")
        #expect(try await relaunched.baseline(rootID: fixture.rootID, remoteID: "file")?.relativePath.value == "Renamed/notes.txt")
        #expect(try await relaunched.pendingScopeMoves().isEmpty)
    }
}

private func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// A sync root and its database in separate folders, as in the app (the database lives in
/// Application Support, not in the synced folder).
private struct Fixture {
    struct Crash: Error {}

    let root: URL
    let support: URL
    let rootID = UUID()
    let path: RelativePath
    var destinationURL: URL { root.appending(path: path.value) }
    private var databaseURL: URL { support.appending(path: "sync.sqlite") }

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        root = base.appending(path: "root", directoryHint: .isDirectory)
        support = base.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        path = try RelativePath("Course/notes.txt")
    }

    func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    /// A new connection, as after a relaunch: it sees only what reached the database file.
    func database() throws -> SyncDatabase { try SyncDatabase(url: databaseURL) }

    /// A fresh connection and file store with the root registered, as the app opens them.
    func open() async throws -> (SyncDatabase, FileStore) {
        let database = try database()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        return (database, try FileStore(root: root))
    }

    static func crash(at step: JournalStep) -> @Sendable (JournalStep) throws -> Void {
        { if $0 == step { throw Crash() } }
    }

    func stage(_ contents: String, in store: FileStore) async throws -> StagedArtifact {
        let stage = try await store.createStage()
        try await store.write(Data(contents.utf8), to: stage)
        return try await store.finalize(stage)
    }

    /// Runs the real install of `contents` and stops it right after `step`.
    func crashInstalling(_ contents: String, expectedLocal: LocalState, at step: JournalStep) async throws {
        let (database, store) = try await open()
        let artifact = try await stage(contents, in: store)
        let coordinator = SyncTransactionCoordinator(database: database, fileStore: store, interruption: Fixture.crash(at: step))
        await #expect(throws: Crash.self, "the install must reach \(step)") {
            _ = try await coordinator.install(rootID: rootID, remoteID: "file", destination: path, expectedLocal: expectedLocal, remote: RemoteState(sha256: artifact.sha256, revision: "2"), artifact: artifact)
        }
        #expect(try await self.database().pendingOperations().count == 1, "the crash must leave the operation journaled on disk")
    }

    /// Recovery as the app runs it at launch, on a fresh connection and file store.
    func relaunchAndRecover() async throws -> RecoveryReport {
        let (database, store) = try await open()
        return try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: store).recover()
    }

    /// A file BeepBar already synced: on disk and recorded as the last synced version, as every
    /// replacement starts.
    func synced(_ contents: String) async throws {
        try writeLocal(contents)
        try await open().0.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "file", relativePath: path, sha256: hash(contents), remoteRevision: "1"))
    }

    func writeLocal(_ contents: String) throws {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: destinationURL)
    }

    func contents() throws -> String { try String(contentsOf: destinationURL, encoding: .utf8) }

    func stagedFiles() throws -> [String] {
        let staging = root.appending(path: ".beepbar/staging")
        guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: staging.path)
    }

    /// The user's copy is untouched, the download sits in the conflict folder, the conflict is
    /// listed, and nothing is pending.
    func expectConflictKeepingLocal(_ local: String) async throws {
        #expect(try contents() == local)
        let relaunched = try database()
        let conflicts = try await relaunched.conflicts(rootID: rootID)
        #expect(conflicts.count == 1)
        if let conflict = conflicts.first {
            #expect(try String(contentsOf: root.appending(path: conflict.incomingPath.value), encoding: .utf8) == "remote")
            #expect(conflict.localSHA256 == hash(local))
        }
        #expect(try await relaunched.pendingOperations().isEmpty)
        #expect(try stagedFiles().isEmpty)
    }
}
