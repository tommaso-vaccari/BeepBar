import Foundation
import SQLite3
import Testing
@testable import BeepbarCore

struct SyncDatabaseTests {
    @Test func keptPathsSurviveReopeningAndStayWithinTheirRoot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let rootID = UUID()
        let other = UUID()
        let database = try SyncDatabase(url: url)
        try await database.registerRoot(id: rootID, canonicalPath: root.path + "/a")
        try await database.registerRoot(id: other, canonicalPath: root.path + "/b")
        let path = try RelativePath("Course/file.txt")
        let baseline = Baseline(remoteID: "file", relativePath: path, sha256: "hash", remoteRevision: "1", courseID: 1, moduleID: 100)
        try await database.upsertBaseline(rootID: rootID, baseline: baseline)
        let change = RemoteChange(rootID: rootID, courseID: 1, remoteID: "file", kind: .removed, relativePath: path, localSHA256: "hash", isLocallyModified: false)
        try await database.stopTracking(change, rememberingPath: true)

        let reopened = try SyncDatabase(url: url)
        #expect(try await reopened.detachedPaths(rootID: rootID) == ["file": path])
        #expect(try await reopened.detachedPaths(rootID: other).isEmpty)
        #expect(try await reopened.baseline(rootID: rootID, remoteID: "file") == nil)
        try await reopened.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: true))
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: 1, oldFolder: "Course", newFolder: "Renamed")
        try await reopened.beginScopeMove(move)
        try await reopened.commitScopeMove(move)
        let afterRename = try SyncDatabase(url: url)
        #expect(try await afterRename.detachedPaths(rootID: rootID) == ["file": RelativePath("Renamed/file.txt")])
        try await reopened.upsertBaseline(rootID: rootID, baseline: baseline)
        #expect(try await reopened.detachedPaths(rootID: rootID).isEmpty)
    }

    @Test func aFailedDetachedMigrationRollsBackAndRetries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let rootID = UUID()
        let database = try SyncDatabase(url: url)
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let baseline = Baseline(remoteID: "file", relativePath: try RelativePath("Course/file.txt"), sha256: "hash", remoteRevision: "1", courseID: 1, moduleID: 100)
        try await database.upsertBaseline(rootID: rootID, baseline: baseline)
        let raw = try RawSQLite(url: url)
        try raw.execute("DROP TABLE detached_items")
        try raw.execute("DELETE FROM schema_migrations WHERE version = 7")
        try raw.execute("CREATE TRIGGER interrupt_migration BEFORE INSERT ON schema_migrations WHEN NEW.version = 7 BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        await #expect(throws: SyncDatabaseError.execution) { try await database.migrate() }
        #expect(try raw.query("SELECT name FROM sqlite_master WHERE name = 'detached_items'").isEmpty)
        #expect(try await database.baseline(rootID: rootID, remoteID: "file") == baseline)
        try raw.execute("DROP TRIGGER interrupt_migration")
        let reopened = try SyncDatabase(url: url)
        #expect(try await reopened.detachedPaths(rootID: rootID).isEmpty)
        #expect(try await reopened.baseline(rootID: rootID, remoteID: "file") == baseline)
    }

    @Test func migrationRepairsMissingDetachedTableWithoutChangingExistingBaselines() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let rootID = UUID()
        let database = try SyncDatabase(url: url)
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let baseline = Baseline(remoteID: "file", relativePath: try RelativePath("Course/file.txt"), sha256: "hash", remoteRevision: "1", courseID: 1, moduleID: 100)
        try await database.upsertBaseline(rootID: rootID, baseline: baseline)
        try RawSQLite(url: url).execute("DROP TABLE detached_items")
        let reopened = try SyncDatabase(url: url)
        #expect(try await reopened.detachedPaths(rootID: rootID).isEmpty)
        #expect(try await reopened.baseline(rootID: rootID, remoteID: "file") == baseline)
        try await reopened.migrate()
        #expect(try await reopened.baseline(rootID: rootID, remoteID: "file") == baseline)
    }

    /// Every read must surface a failing `sqlite3_step` as an error. Dropping the table through a second
    /// connection leaves the first connection's cached schema intact, so `sqlite3_prepare_v2` still succeeds
    /// and the failure only shows up at step time, which is the path `SQLITE_BUSY`/`IOERR`/`CORRUPT` take.
    @Test(arguments: ReadCase.all) func readThrowsWhenSteppingFails(_ readCase: ReadCase) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let rootID = UUID()
        let database = try SyncDatabase(url: url)
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await readCase.read(database, rootID)

        try RawSQLite(url: url).execute("DROP TABLE \(readCase.table)")

        await #expect(throws: SyncDatabaseError.execution) {
            try await readCase.read(database, rootID)
        }
    }

    @Test func disablingAllScopesKeepsFoldersAndIdentitiesAndOnlyTouchesThatRoot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        let otherRootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path + "/a")
        try await database.registerRoot(id: otherRootID, canonicalPath: root.path + "/b")
        let identity = DirectoryIdentity(device: 1, inode: 2)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "A", localFolder: "a", enabled: true, managedDirectory: identity))
        try await database.upsertScope(SyncScope(rootID: otherRootID, courseID: 1, displayName: "A", localFolder: "a", enabled: true))

        try await database.disableAllScopes(rootID: rootID)

        let scope = try #require(await database.scope(rootID: rootID, courseID: 1))
        #expect(!scope.enabled)
        #expect(scope.localFolder == "a")
        #expect(scope.managedDirectory == identity)
        #expect(try await database.scope(rootID: otherRootID, courseID: 1)?.enabled == true)
    }

    @Test func writeWaitsForABusyDatabaseInsteadOfFailingImmediately() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let rootID = UUID()
        let database = try SyncDatabase(url: url)
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let baseline = Baseline(remoteID: "file", relativePath: try RelativePath("Course/notes.txt"), sha256: "abc", remoteRevision: "1")

        let writer = try RawSQLite(url: url)
        try writer.execute("BEGIN IMMEDIATE")
        let write = Task { try await database.upsertBaseline(rootID: rootID, baseline: baseline) }
        try await Task.sleep(for: .milliseconds(300))
        try writer.execute("COMMIT")

        try await write.value
        #expect(try await database.baselines(rootID: rootID) == ["file": baseline])
    }

    /// The journal row of a sync step must be on disk before the rename it describes, so every
    /// commit syncs the log (`synchronous = FULL`, 2). WAL alone would leave the system SQLite at
    /// NORMAL (1), which can drop committed rows on a kernel panic or power cut. Checked on a new
    /// database, after a write, and on a database an older release left in WAL mode without the
    /// setting: the pragma is per connection, so existing users get it as soon as they update.
    @Test func everyConnectionSyncsTheLogOnEachCommit() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let database = try SyncDatabase(url: url)
        var settings = try await database.durabilitySettings()
        #expect(settings.journalMode == "wal")
        #expect(settings.synchronous == 2)
        try await database.registerRoot(id: UUID(), canonicalPath: root.path)
        #expect(try await database.durabilitySettings().synchronous == 2)

        let older = root.appending(path: "older.sqlite")
        FileManager.default.createFile(atPath: older.path, contents: nil)
        do {
            let raw = try RawSQLite(url: older)
            try raw.execute("PRAGMA journal_mode = WAL")
            try raw.execute("CREATE TABLE leftover (x)")
        }
        let upgraded = try SyncDatabase(url: older)
        settings = try await upgraded.durabilitySettings()
        #expect(settings.journalMode == "wal")
        #expect(settings.synchronous == 2)
        // Documented, not chosen by accident (see `SyncDatabase.init`): commits use plain fsync,
        // like `FileStore`; only checkpoints flush the drive cache (F_FULLFSYNC).
        #expect(settings.fullFsync == 0)
        #expect(settings.checkpointFullFsync == 1)
    }

    @Test func reopeningMigratesIdempotentlyAndKeepsData() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let rootID = UUID()
        let baseline = Baseline(remoteID: "file", relativePath: try RelativePath("Course/notes.txt"), sha256: "abc", remoteRevision: "1")
        do {
            let database = try SyncDatabase(url: url)
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            try await database.upsertBaseline(rootID: rootID, baseline: baseline)
        }

        let reopened = try SyncDatabase(url: url)
        try await reopened.migrate()

        #expect(try await reopened.rootID(canonicalPath: root.path) == rootID)
        #expect(try await reopened.baselines(rootID: rootID) == ["file": baseline])
    }

    @Test func reopeningCompletesPartiallyAppliedColumnGroups() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let raw = try RawSQLite(url: url)
        try raw.execute("CREATE TABLE pending_operations (id TEXT PRIMARY KEY, root_id TEXT NOT NULL, remote_id TEXT NOT NULL, destination_path TEXT NOT NULL, stage_path TEXT NOT NULL, expected_local_kind TEXT NOT NULL DEFAULT 'unknown')")
        try raw.execute("CREATE TABLE sync_scopes (root_id TEXT NOT NULL, course_id INTEGER NOT NULL, display_name TEXT NOT NULL, local_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL, auto_sync INTEGER NOT NULL DEFAULT 0, managed_directory INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(root_id, course_id))")

        let database = try SyncDatabase(url: url)
        #expect(try raw.query("SELECT name FROM pragma_table_info('pending_operations')").contains("expected_local_sha256"))
        #expect(try raw.query("SELECT name FROM pragma_table_info('pending_operations')").contains("remote_sha256"))
        #expect(try raw.query("SELECT name FROM pragma_table_info('pending_operations')").contains("remote_revision"))
        #expect(try raw.query("SELECT name FROM pragma_table_info('pending_operations')").contains("phase"))
        #expect(try raw.query("SELECT name FROM pragma_table_info('sync_scopes')").contains("directory_device"))
        #expect(try raw.query("SELECT name FROM pragma_table_info('sync_scopes')").contains("directory_inode"))
        #expect(try await database.pendingOperations(rootID: UUID()).isEmpty)
        #expect(try await database.scopes(rootID: UUID()).isEmpty)
    }

    @Test func reopeningClearsPartiallyAttributedModuleOwners() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let rootID = UUID()
        let database = try SyncDatabase(url: url)
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        for remoteID in ["course-only", "module-only"] {
            try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: remoteID, relativePath: try RelativePath("Course/\(remoteID).txt"), sha256: "hash", remoteRevision: "1", courseID: 3, moduleID: 4))
        }
        try RawSQLite(url: url).execute("PRAGMA ignore_check_constraints = ON; UPDATE items SET module_id = NULL WHERE remote_id = 'course-only'; UPDATE items SET course_id = NULL WHERE remote_id = 'module-only'")

        let reopened = try SyncDatabase(url: url)
        let baselines = try await reopened.baselines(rootID: rootID)

        #expect(baselines["course-only"]?.courseID == nil && baselines["course-only"]?.moduleID == nil)
        #expect(baselines["module-only"]?.courseID == nil && baselines["module-only"]?.moduleID == nil)
    }

    /// Current ownership and missing rows must not acquire a write lock or attempt UPDATEs.
    @Test func ownershipBackfillDoesNoWorkWithoutLegacyCandidates() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "owned", relativePath: try RelativePath("Course/a.txt"), sha256: "hash", remoteRevision: "1", courseID: 1, moduleID: 10))
        let before = await database.writeCounters()
        try await database.backfillModuleOwnership(rootID: rootID, files: [ownershipFile("owned"), ownershipFile("missing")])
        try await database.backfillModuleOwnership(rootID: rootID, files: [])
        #expect(await database.ownershipBackfillCounters == OwnershipBackfillCounters())
        #expect(await database.writeCounters().since(before) == SyncDatabaseWriteCounters())
    }

    /// Migrate only unambiguous legacy rows in this root, and discover later legacy arrivals.
    @Test func ownershipBackfillMigratesOnlyMatchingLegacyRows() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID(), other = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.registerRoot(id: other, canonicalPath: root.path + "/other")
        for (id, owner) in [("legacy", rootID), ("absent", rootID), ("ambiguous", rootID), ("legacy", other)] {
            try await database.upsertBaseline(rootID: owner, baseline: Baseline(remoteID: id, relativePath: try RelativePath("Course/\(id).txt"), sha256: "hash", remoteRevision: "1"))
        }
        let files = [ownershipFile("legacy"), ownershipFile("legacy"), ownershipFile("ambiguous"), ownershipFile("ambiguous", module: 11), ownershipFile("missing")]
        try await database.backfillModuleOwnership(rootID: rootID, files: files)
        #expect(await database.ownershipBackfillCounters == OwnershipBackfillCounters(transactions: 1, updates: 1))
        #expect(try await database.baseline(rootID: rootID, remoteID: "legacy")?.moduleID == 10)
        for (id, owner) in [("absent", rootID), ("ambiguous", rootID), ("legacy", other)] {
            #expect(try await database.baseline(rootID: owner, remoteID: id)?.courseID == nil)
        }
        try await database.backfillModuleOwnership(rootID: rootID, files: files)
        #expect(await database.ownershipBackfillCounters == OwnershipBackfillCounters(transactions: 1, updates: 1))
        try await database.backfillModuleOwnership(rootID: rootID, files: [ownershipFile("absent")])
        #expect(try await database.baseline(rootID: rootID, remoteID: "absent")?.courseID == 1)
        #expect(await database.ownershipBackfillCounters == OwnershipBackfillCounters(transactions: 2, updates: 2))
    }

    /// Candidate query failures must propagate, rather than treating an unreadable DB as current.
    @Test func ownershipBackfillRejectsAnUnreadableCandidateTable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let database = try SyncDatabase(url: url)
        try RawSQLite(url: url).execute("DROP TABLE items")
        await #expect(throws: SyncDatabaseError.self) {
            try await database.backfillModuleOwnership(rootID: UUID(), files: [ownershipFile("missing")])
        }
    }

    private func ownershipFile(_ id: String, module: Int64 = 10) -> RemoteFileCandidate {
        RemoteFileCandidate(id: id, courseID: 1, sectionID: 1, moduleID: module, sectionName: "S", moduleName: "A", filename: "a.txt", remoteFilePath: "/", canonicalPluginPath: "/a", downloadURL: nil, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true)
    }

    @Test func ownershipBackfillSkipsAmbiguousRemoteIDs() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "shared", relativePath: try RelativePath("Course/shared.txt"), sha256: "hash", remoteRevision: "1"))
        let files = [
            RemoteFileCandidate(id: "shared", courseID: 1, sectionID: 1, moduleID: 10, sectionName: "S", moduleName: "A", filename: "a.txt", remoteFilePath: "/", canonicalPluginPath: "/a", downloadURL: nil, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true),
            RemoteFileCandidate(id: "shared", courseID: 1, sectionID: 1, moduleID: 11, sectionName: "S", moduleName: "B", filename: "b.txt", remoteFilePath: "/", canonicalPluginPath: "/b", downloadURL: nil, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true),
        ]

        try await database.backfillModuleOwnership(rootID: rootID, files: files)

        #expect(try await database.baseline(rootID: rootID, remoteID: "shared")?.courseID == nil)
        #expect(try await database.baseline(rootID: rootID, remoteID: "shared")?.moduleID == nil)
    }

    @Test func syncRejectsDuplicateRemoteIDsBeforePlanning() throws {
        let files = [
            RemoteFileCandidate(id: "shared", courseID: 1, sectionID: 1, moduleID: 10, sectionName: "S", moduleName: "A", filename: "a.txt", remoteFilePath: "/", canonicalPluginPath: "/a", downloadURL: nil, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true),
            RemoteFileCandidate(id: "shared", courseID: 1, sectionID: 1, moduleID: 11, sectionName: "S", moduleName: "B", filename: "b.txt", remoteFilePath: "/", canonicalPluginPath: "/b", downloadURL: nil, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true),
        ]

        #expect(throws: SyncDatabaseError.execution) { try SyncCoordinator.validateUniqueRemoteIDs(files) }
    }

    @Test func conflictsTableIsIndexedForOpenConflictLookups() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        _ = try SyncDatabase(url: url)

        let raw = try RawSQLite(url: url)
        let indexes = try raw.query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'conflicts'")
        #expect(indexes.contains("conflicts_root_remote_status"))
        #expect(try raw.query("SELECT name FROM pragma_index_info('conflicts_root_remote_status') ORDER BY seqno") == ["root_id", "remote_id", "status"])
        let plan = try raw.query("EXPLAIN QUERY PLAN SELECT 1 FROM conflicts WHERE root_id = 'r' AND remote_id = 'f' AND remote_revision = '1' AND status = 'open' LIMIT 1", column: 3)
        #expect(plan.contains { $0.contains("USING INDEX conflicts_root_remote_status") }, "plan: \(plan)")
    }

    @Test func scopeLookupReturnsOnlyTheMatchingRow() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let firstRoot = UUID(), secondRoot = UUID()
        try await database.registerRoot(id: firstRoot, canonicalPath: root.path)
        try await database.registerRoot(id: secondRoot, canonicalPath: root.appending(path: "other").path)
        let managed = SyncScope(rootID: firstRoot, courseID: 1, displayName: "Analisi", localFolder: "Analisi", enabled: true, managedDirectory: DirectoryIdentity(device: 7, inode: 42))
        let disabled = SyncScope(rootID: firstRoot, courseID: 2, displayName: "Fisica", localFolder: "Fisica", enabled: false)
        let otherRoot = SyncScope(rootID: secondRoot, courseID: 1, displayName: "Analisi (bis)", localFolder: "Analisi bis", enabled: true)
        for scope in [managed, disabled, otherRoot] { try await database.upsertScope(scope) }

        #expect(try await database.scope(rootID: firstRoot, courseID: 1) == managed)
        #expect(try await database.scope(rootID: firstRoot, courseID: 2) == disabled)
        #expect(try await database.scope(rootID: secondRoot, courseID: 1) == otherRoot)
        #expect(try await database.scope(rootID: firstRoot, courseID: 3) == nil)
        #expect(try await database.scope(rootID: UUID(), courseID: 1) == nil)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

struct ReadCase: Sendable, CustomTestStringConvertible {
    let name: String
    let table: String
    let read: @Sendable (SyncDatabase, UUID) async throws -> Void

    var testDescription: String { name }

    static let all: [ReadCase] = [
        ReadCase(name: "rootID", table: "roots") { database, _ in _ = try await database.rootID(canonicalPath: "/nowhere") },
        ReadCase(name: "baseline", table: "items") { database, rootID in _ = try await database.baseline(rootID: rootID, remoteID: "file") },
        ReadCase(name: "detachedPaths", table: "detached_items") { database, rootID in _ = try await database.detachedPaths(rootID: rootID) },
        ReadCase(name: "baselines", table: "items") { database, rootID in _ = try await database.baselines(rootID: rootID) },
        ReadCase(name: "scopes", table: "sync_scopes") { database, rootID in _ = try await database.scopes(rootID: rootID) },
        ReadCase(name: "scope", table: "sync_scopes") { database, rootID in _ = try await database.scope(rootID: rootID, courseID: 1) },
        ReadCase(name: "scopeFolder", table: "sync_scopes") { database, rootID in _ = try await database.scopeFolder(rootID: rootID, courseID: 1) },
        ReadCase(name: "conflicts", table: "conflicts") { database, rootID in _ = try await database.conflicts(rootID: rootID) },
        ReadCase(name: "conflict", table: "conflicts") { database, _ in _ = try await database.conflict(id: UUID()) },
        ReadCase(name: "hasOpenConflict", table: "conflicts") { database, rootID in _ = try await database.hasOpenConflict(rootID: rootID, remoteID: "file", revision: "1") },
        ReadCase(name: "hasOpenConflicts", table: "conflicts") { database, rootID in _ = try await database.hasOpenConflicts(rootID: rootID, prefix: "Course") },
        ReadCase(name: "pendingOperations", table: "pending_operations") { database, rootID in _ = try await database.pendingOperations(rootID: rootID) },
        ReadCase(name: "hasPendingOperations", table: "pending_operations") { database, rootID in _ = try await database.hasPendingOperations(rootID: rootID, prefix: "Course") },
        ReadCase(name: "pendingScopeMoves", table: "pending_scope_moves") { database, rootID in _ = try await database.pendingScopeMoves(rootID: rootID) },
        ReadCase(name: "trackedItemCount", table: "items") { database, rootID in _ = try await database.trackedItemCount(rootID: rootID, prefix: "Course") },
    ]
}

/// A second, independent connection to the same file, used to change or read the database behind `SyncDatabase`'s back.
final class RawSQLite {
    struct Failure: Error { let message: String }

    private var handle: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw Failure(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: String(cString: sqlite3_errmsg(handle))) }
    }

    func query(_ sql: String, column: Int32 = 0) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure(message: String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
            case SQLITE_DONE: return rows
            default: throw Failure(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
