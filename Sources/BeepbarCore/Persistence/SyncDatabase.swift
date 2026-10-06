import CSQLite
import Foundation

public enum SyncDatabaseError: Error, Sendable, Equatable {
    case open
    case statement
    case execution
    case invalidPath
    case legacyPendingOperation
}

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer?
    /// Write transactions this connection committed, counted by SQLite's commit hook. Owned here so
    /// it lives exactly as long as the connection the hook belongs to: `sqlite3_close` runs in
    /// `deinit`, before the stored properties are released.
    let commits = CommitCounter()

    init(_ pointer: OpaquePointer?) {
        self.pointer = pointer
        // A commit hook only observes: returning 0 lets every commit through. It fires for each
        // committed write transaction, including an explicit one that changed no row and a write
        // statement that matched none, and never for reads. Unlike `sqlite3_wal_hook`, it doesn't
        // replace the WAL auto-checkpoint, so counting changes nothing about how the database runs.
        sqlite3_commit_hook(pointer, { context in
            Unmanaged<CommitCounter>.fromOpaque(context!).takeUnretainedValue().value += 1
            return 0
        }, Unmanaged.passUnretained(commits).toOpaque())
    }
    deinit { sqlite3_close(pointer) }
}

/// Only touched from inside `sqlite3_step`, on the `SyncDatabase` actor that owns the connection.
private final class CommitCounter: @unchecked Sendable {
    var value = 0
}

/// How much one `SyncDatabase` connection has written since it opened, for the benchmark harness and
/// for tests that prove a run wrote nothing. Three separate measures, because they answer different
/// questions:
/// - `rowChanges` (`sqlite3_total_changes64`): rows inserted, updated or deleted, including an update
///   that rewrote a row with the same values and rows of a transaction later rolled back.
/// - `commits`: write transactions committed. An empty `BEGIN IMMEDIATE … COMMIT` or an `UPDATE`
///   matching no row still counts. Only a commit that wrote pages appends to the WAL and, with
///   `synchronous = FULL`, waits for an `fsync`; an empty one costs a lock round trip.
/// - `pagesWritten` (`SQLITE_DBSTATUS_CACHE_WRITE`): database pages written to the WAL, i.e. WAL
///   frames. SQLite doesn't dirty a page an `UPDATE` leaves byte-identical, so an identical update
///   counts a row change and a commit without a page (an identical upsert still writes one).
/// `PRAGMA data_version` would not do: it ignores the connection's own commits.
package struct SyncDatabaseWriteCounters: Sendable, Equatable, Codable {
    package var rowChanges: Int64
    package var commits: Int
    package var pagesWritten: Int

    package init(rowChanges: Int64 = 0, commits: Int = 0, pagesWritten: Int = 0) {
        self.rowChanges = rowChanges
        self.commits = commits
        self.pagesWritten = pagesWritten
    }

    /// What was written between `earlier` and `self`, both read from the same connection.
    package func since(_ earlier: SyncDatabaseWriteCounters) -> SyncDatabaseWriteCounters {
        SyncDatabaseWriteCounters(rowChanges: rowChanges - earlier.rowChanges, commits: commits - earlier.commits, pagesWritten: pagesWritten - earlier.pagesWritten)
    }
}

/// Advances `statement` by one row: `true` on `SQLITE_ROW`, `false` on `SQLITE_DONE`. Any other result
/// (`SQLITE_BUSY`, `SQLITE_IOERR`, `SQLITE_CORRUPT`, `SQLITE_FULL`, ...) is an error and must never be
/// mistaken for the end of the result set, or callers would act on a truncated view of the database.
private func stepRow(_ statement: OpaquePointer) throws -> Bool {
    switch sqlite3_step(statement) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: throw SyncDatabaseError.execution
    }
}

public actor SyncDatabase {
    private let handle: SQLiteHandle
    private var database: OpaquePointer? { handle.pointer }

    public init(url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw SyncDatabaseError.open
        }
        self.handle = SQLiteHandle(database)
        guard sqlite3_busy_timeout(database, 5000) == SQLITE_OK else { throw SyncDatabaseError.open }
        try Self.execute(database, "PRAGMA foreign_keys = ON")
        try Self.execute(database, "PRAGMA journal_mode = WAL")
        // Every change to a synced file is journaled first: a pending row, then the filesystem
        // change (each `FileStore` rename is followed by `fsync`), then the commit that finishes
        // it. Recovery relies on the row reaching the disk before the change it describes. In WAL
        // mode the system SQLite defaults to NORMAL, which syncs the log only at checkpoints: a
        // kernel panic or power cut can then drop rows that were already committed while the
        // rename they describe survives, leaving an installed file or a moved course folder that
        // no pending row explains. FULL syncs the log on every commit. Process crashes were
        // already safe under NORMAL (a committed row is in the log file); this is for the machine
        // going down. Commits don't ask for `F_FULLFSYNC` (`PRAGMA fullfsync` stays off; only
        // checkpoints use it, `checkpoint_fullfsync` being on in the system build), and
        // `FileStore` uses plain `fsync`, so on macOS the drive's own cache can still reorder
        // writes on sudden power loss. A run with nothing new writes no WAL frame, and a commit
        // that wrote nothing doesn't sync, so FULL costs it nothing. An explicit `synchronous`
        // holds after switching to WAL, so the order of these two pragmas doesn't matter.
        try Self.execute(database, "PRAGMA synchronous = FULL")
        try Self.migrate(database)
    }

    /// The durability settings this connection actually runs with, read back from SQLite so tests
    /// check the effective values rather than the statements that set them.
    func durabilitySettings() throws -> (journalMode: String, synchronous: Int32, fullFsync: Int32, checkpointFullFsync: Int32) {
        func value(_ pragma: String) throws -> (text: String?, number: Int32) {
            try withStatement("PRAGMA \(pragma)") { statement in
                guard try stepRow(statement) else { throw SyncDatabaseError.execution }
                return (text(statement, 0), sqlite3_column_int(statement, 0))
            }
        }
        guard let journalMode = try value("journal_mode").text else { throw SyncDatabaseError.execution }
        return (journalMode, try value("synchronous").number, try value("fullfsync").number, try value("checkpoint_fullfsync").number)
    }

    public func migrate() throws {
        try Self.migrate(database)
    }

    /// Everything this connection has written since it opened, opening migrations included; take
    /// the difference of two readings (`since`) to measure one operation.
    package func writeCounters() -> SyncDatabaseWriteCounters {
        var pages: Int32 = 0
        var highwater: Int32 = 0
        sqlite3_db_status(database, SQLITE_DBSTATUS_CACHE_WRITE, &pages, &highwater, 0)
        return SyncDatabaseWriteCounters(rowChanges: sqlite3_total_changes64(database), commits: handle.commits.value, pagesWritten: Int(pages))
    }

    /// Records the sync folder, or brings its row up to date. Called on every launch (before
    /// recovery), on every recovery retry and when a folder is chosen, almost always with the
    /// values already stored. The `WHERE` makes that case a no-op: SQLite rewrites a row an upsert
    /// matches even when nothing changes, so without it each launch appended a WAL frame and,
    /// under `synchronous = FULL`, waited for an `fsync`. `IS NOT` compares NULL bookmarks as equal.
    public func registerRoot(id: UUID, canonicalPath: String, securityBookmark: Data? = nil) throws {
        try withStatement("INSERT INTO roots(id, canonical_path, security_bookmark) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET canonical_path = excluded.canonical_path, security_bookmark = excluded.security_bookmark WHERE canonical_path IS NOT excluded.canonical_path OR security_bookmark IS NOT excluded.security_bookmark") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            try bind(canonicalPath, to: statement, index: 2)
            if let securityBookmark {
                guard sqlite3_bind_blob(statement, 3, [UInt8](securityBookmark), Int32(securityBookmark.count), transientDestructor) == SQLITE_OK else { throw SyncDatabaseError.execution }
            } else { sqlite3_bind_null(statement, 3) }
            try stepDone(statement)
        }
    }

    public func rootID(canonicalPath: String) throws -> UUID? {
        try withStatement("SELECT id FROM roots WHERE canonical_path = ?") { statement in
            try bind(canonicalPath, to: statement, index: 1)
            guard try stepRow(statement) else { return nil }
            guard let id = uuid(statement, 0) else { throw SyncDatabaseError.execution }
            return id
        }
    }

    public func baseline(rootID: UUID, remoteID: String) throws -> Baseline? {
        try withStatement("SELECT relative_path, base_sha256, remote_revision, course_id, module_id FROM items WHERE root_id = ? AND remote_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            try bind(remoteID, to: statement, index: 2)
            guard try stepRow(statement) else { return nil }
            guard let pathText = sqlite3_column_text(statement, 0), let hashText = sqlite3_column_text(statement, 1), let revisionText = sqlite3_column_text(statement, 2) else { throw SyncDatabaseError.execution }
            let path = try RelativePath(String(cString: pathText))
            return Baseline(remoteID: remoteID, relativePath: path, sha256: String(cString: hashText), remoteRevision: String(cString: revisionText), courseID: optionalInt64(statement, 3), moduleID: optionalInt64(statement, 4))
        }
    }

    public func migrateLegacyBaseline(rootID: UUID, legacyRemoteID: String, remoteID: String, courseID: Int64, moduleID: Int64) throws -> Baseline? {
        try execute("BEGIN IMMEDIATE")
        do {
            guard try baseline(rootID: rootID, remoteID: remoteID) == nil,
                  let legacy = try baseline(rootID: rootID, remoteID: legacyRemoteID),
                  !(try hasOpenConflictForMigration(rootID: rootID, remoteID: legacyRemoteID)),
                  !(try hasOpenConflictForMigration(rootID: rootID, remoteID: remoteID)),
                  !(try hasPendingOperationForMigration(rootID: rootID, remoteID: legacyRemoteID)),
                  !(try hasPendingOperationForMigration(rootID: rootID, remoteID: remoteID)) else {
                try execute("COMMIT")
                return nil
            }
            try withStatement("UPDATE items SET remote_id = ?, last_seen_at = ?, course_id = ?, module_id = ? WHERE root_id = ? AND remote_id = ?") { statement in
                try bind(remoteID, to: statement, index: 1)
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                guard sqlite3_bind_int64(statement, 3, courseID) == SQLITE_OK, sqlite3_bind_int64(statement, 4, moduleID) == SQLITE_OK else { throw SyncDatabaseError.execution }
                try bind(rootID.uuidString, to: statement, index: 5)
                try bind(legacyRemoteID, to: statement, index: 6)
                try stepDone(statement)
            }
            try execute("COMMIT")
            return Baseline(remoteID: remoteID, relativePath: legacy.relativePath, sha256: legacy.sha256, remoteRevision: legacy.remoteRevision, courseID: courseID, moduleID: moduleID)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func baselines(rootID: UUID) throws -> [String: Baseline] {
        try withStatement("SELECT remote_id, relative_path, base_sha256, remote_revision, course_id, module_id FROM items WHERE root_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var values: [String: Baseline] = [:]
            while try stepRow(statement) {
                guard let remoteID = text(statement, 0), let pathText = text(statement, 1), let hashText = text(statement, 2), let revisionText = text(statement, 3) else { throw SyncDatabaseError.execution }
                values[remoteID] = Baseline(remoteID: remoteID, relativePath: try RelativePath(pathText), sha256: hashText, remoteRevision: revisionText, courseID: optionalInt64(statement, 4), moduleID: optionalInt64(statement, 5))
            }
            return values
        }
    }

    public func upsertBaseline(rootID: UUID, baseline: Baseline) throws {
        try withStatement("INSERT INTO items(root_id, remote_id, relative_path, base_sha256, remote_revision, last_seen_at, course_id, module_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(root_id, remote_id) DO UPDATE SET relative_path = excluded.relative_path, base_sha256 = excluded.base_sha256, remote_revision = excluded.remote_revision, last_seen_at = excluded.last_seen_at, course_id = COALESCE(excluded.course_id, items.course_id), module_id = COALESCE(excluded.module_id, items.module_id)") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            try bind(baseline.remoteID, to: statement, index: 2)
            try bind(baseline.relativePath.value, to: statement, index: 3)
            try bind(baseline.sha256, to: statement, index: 4)
            try bind(baseline.remoteRevision, to: statement, index: 5)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            try bind(baseline.courseID, to: statement, index: 7)
            try bind(baseline.moduleID, to: statement, index: 8)
            try stepDone(statement)
        }
        try deleteRows("detached_items", rootID: rootID, remoteID: baseline.remoteID)
    }

    public func backfillModuleOwnership(rootID: UUID, files: [RemoteFileCandidate]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let owners = Dictionary(grouping: files, by: \.id).compactMapValues { candidates -> (Int64, Int64)? in
                let values = Set(candidates.map { "\($0.courseID):\($0.moduleID)" })
                guard values.count == 1, let file = candidates.first else { return nil }
                return (file.courseID, file.moduleID)
            }
            for (remoteID, owner) in owners {
                try withStatement("UPDATE items SET course_id = ?, module_id = ? WHERE root_id = ? AND remote_id = ? AND course_id IS NULL AND module_id IS NULL") { statement in
                    guard sqlite3_bind_int64(statement, 1, owner.0) == SQLITE_OK,
                          sqlite3_bind_int64(statement, 2, owner.1) == SQLITE_OK else { throw SyncDatabaseError.execution }
                    try bind(rootID.uuidString, to: statement, index: 3)
                    try bind(remoteID, to: statement, index: 4)
                    try stepDone(statement)
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func modulePathOverrides(rootID: UUID, courseID: Int64) throws -> [Int64: ModulePathOverride] {
        try withStatement("SELECT module_id, local_folder, last_known_name FROM module_path_overrides WHERE root_id = ? AND course_id = ? ORDER BY module_id") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            guard sqlite3_bind_int64(statement, 2, courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            var values: [Int64: ModulePathOverride] = [:]
            while try stepRow(statement) {
                guard let folder = text(statement, 1), let name = text(statement, 2) else { throw SyncDatabaseError.execution }
                let moduleID = sqlite3_column_int64(statement, 0)
                values[moduleID] = ModulePathOverride(rootID: rootID, courseID: courseID, moduleID: moduleID, localFolder: folder, lastKnownName: name)
            }
            return values
        }
    }

    public func modulePathOverrides(rootID: UUID) throws -> [ModulePathOverride] {
        try withStatement("SELECT course_id, module_id, local_folder, last_known_name FROM module_path_overrides WHERE root_id = ? ORDER BY course_id, module_id") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var values: [ModulePathOverride] = []
            while try stepRow(statement) {
                guard let folder = text(statement, 2), let name = text(statement, 3) else { throw SyncDatabaseError.execution }
                values.append(ModulePathOverride(rootID: rootID, courseID: sqlite3_column_int64(statement, 0), moduleID: sqlite3_column_int64(statement, 1), localFolder: folder, lastKnownName: name))
            }
            return values
        }
    }

    public func modulePathOverride(rootID: UUID, courseID: Int64, moduleID: Int64) throws -> ModulePathOverride? {
        try modulePathOverrides(rootID: rootID, courseID: courseID)[moduleID]
    }

    public func updateModulePathOverrideName(rootID: UUID, courseID: Int64, moduleID: Int64, name: String) throws {
        try withStatement("UPDATE module_path_overrides SET last_known_name = ? WHERE root_id = ? AND course_id = ? AND module_id = ?") { statement in
            try bind(name, to: statement, index: 1); try bind(rootID.uuidString, to: statement, index: 2)
            guard sqlite3_bind_int64(statement, 3, courseID) == SQLITE_OK, sqlite3_bind_int64(statement, 4, moduleID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            try stepDone(statement)
        }
    }

    /// Where Moodle placed each tracked file when it was last seen, keyed by remote id. Rows
    /// written before this was recorded (every baseline from an older version) have no entry.
    public func remotePlacements(rootID: UUID) throws -> [String: RemotePlacement] {
        try withStatement("SELECT remote_id, placement_section, placement_module, placement_single FROM items WHERE root_id = ? AND placement_section IS NOT NULL AND placement_module IS NOT NULL AND placement_single IS NOT NULL") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var values: [String: RemotePlacement] = [:]
            while try stepRow(statement) {
                guard let remoteID = text(statement, 0), let section = text(statement, 1), let module = text(statement, 2) else { throw SyncDatabaseError.execution }
                values[remoteID] = RemotePlacement(sectionName: section, moduleName: module, isSingleFileResource: sqlite3_column_int64(statement, 3) != 0)
            }
            return values
        }
    }

    /// Stores the Moodle placement of tracked files in one transaction. With `onlyIfMissing`, a
    /// placement already recorded is kept: that is how files downloaded by this run, and every
    /// baseline from an older version, get their first placement without hiding a move.
    public func recordRemotePlacements(rootID: UUID, _ placements: [String: RemotePlacement], onlyIfMissing: Bool) throws {
        guard !placements.isEmpty else { return }
        let sql = "UPDATE items SET placement_section = ?, placement_module = ?, placement_single = ? WHERE root_id = ? AND remote_id = ?" + (onlyIfMissing ? " AND placement_section IS NULL" : "")
        try execute("BEGIN IMMEDIATE")
        do {
            for (remoteID, placement) in placements {
                try withStatement(sql) { statement in
                    try bindPlacement(placement, to: statement, from: 1)
                    try bind(rootID.uuidString, to: statement, index: 4)
                    try bind(remoteID, to: statement, index: 5)
                    try stepDone(statement)
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func bindPlacement(_ placement: RemotePlacement?, to statement: OpaquePointer, from index: Int32) throws {
        guard let placement else {
            sqlite3_bind_null(statement, index); sqlite3_bind_null(statement, index + 1); sqlite3_bind_null(statement, index + 2)
            return
        }
        try bind(placement.sectionName, to: statement, index: index)
        try bind(placement.moduleName, to: statement, index: index + 1)
        guard sqlite3_bind_int64(statement, index + 2, placement.isSingleFileResource ? 1 : 0) == SQLITE_OK else { throw SyncDatabaseError.execution }
    }

    private func placement(_ statement: OpaquePointer, from column: Int32) -> RemotePlacement? {
        guard let section = text(statement, column), let module = text(statement, column + 1), sqlite3_column_type(statement, column + 2) != SQLITE_NULL else { return nil }
        return RemotePlacement(sectionName: section, moduleName: module, isSingleFileResource: sqlite3_column_int64(statement, column + 2) != 0)
    }

    // MARK: Moves made to follow Moodle

    /// Journals moves before their files are renamed (see `PendingRemoteMove`).
    public func beginRemoteMoves(rootID: UUID, _ moves: [PendingRemoteMove]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for move in moves {
                try withStatement("INSERT OR REPLACE INTO pending_remote_moves(root_id, remote_id, batch_id, from_path, to_path, sha256, placement_section, placement_module, placement_single) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
                    try bind(rootID.uuidString, to: statement, index: 1); try bind(move.remoteID, to: statement, index: 2)
                    try bind(move.batchID.uuidString, to: statement, index: 3)
                    try bind(move.from.value, to: statement, index: 4); try bind(move.to.value, to: statement, index: 5)
                    try bind(move.sha256, to: statement, index: 6)
                    try bindPlacement(move.placement, to: statement, from: 7)
                    try stepDone(statement)
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func pendingRemoteMoves(rootID: UUID) throws -> [PendingRemoteMove] {
        try withStatement("SELECT remote_id, batch_id, from_path, to_path, sha256, placement_section, placement_module, placement_single FROM pending_remote_moves WHERE root_id = ? ORDER BY batch_id, remote_id") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var moves: [PendingRemoteMove] = []
            while try stepRow(statement) {
                guard let remoteID = text(statement, 0), let batch = uuid(statement, 1), let from = text(statement, 2), let to = text(statement, 3), let sha = text(statement, 4) else { throw SyncDatabaseError.execution }
                moves.append(PendingRemoteMove(batchID: batch, remoteID: remoteID, from: try RelativePath(from), to: try RelativePath(to), sha256: sha, placement: placement(statement, from: 5)))
            }
            return moves
        }
    }

    /// Points each baseline at the place its file was moved to, records the placement that caused
    /// the move, and closes the journal rows and any entry about those files, all in one
    /// transaction. Throws, changing nothing, when a baseline is no longer at the path it was
    /// moved from.
    public func commitRemoteMoves(rootID: UUID, _ moves: [PendingRemoteMove]) throws {
        guard !moves.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for move in moves {
                let sql = move.placement == nil
                    ? "UPDATE items SET relative_path = ? WHERE root_id = ? AND remote_id = ? AND relative_path = ?"
                    : "UPDATE items SET relative_path = ?, placement_section = ?, placement_module = ?, placement_single = ? WHERE root_id = ? AND remote_id = ? AND relative_path = ?"
                try withStatement(sql) { statement in
                    try bind(move.to.value, to: statement, index: 1)
                    var index: Int32 = 2
                    if move.placement != nil { try bindPlacement(move.placement, to: statement, from: 2); index = 5 }
                    try bind(rootID.uuidString, to: statement, index: index); try bind(move.remoteID, to: statement, index: index + 1)
                    try bind(move.from.value, to: statement, index: index + 2)
                    try stepDone(statement)
                    guard sqlite3_changes(database) == 1 else { throw SyncDatabaseError.execution }
                }
                try deleteRows("pending_remote_moves", rootID: rootID, remoteID: move.remoteID)
                if move.placement != nil { try deleteRows("remote_changes", rootID: rootID, remoteID: move.remoteID) }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Drops journal rows for moves that did not happen.
    public func discardRemoteMoves(rootID: UUID, remoteIDs: [String]) throws {
        for remoteID in remoteIDs { try deleteRows("pending_remote_moves", rootID: rootID, remoteID: remoteID) }
    }

    /// Hands a tracked file's baseline over to the new remote item Moodle uploaded with the same
    /// contents, at `baseline.relativePath`. Returns false, changing nothing, when the old baseline
    /// is no longer at `oldPath` or the new item already has a baseline.
    public func transferBaseline(rootID: UUID, from oldRemoteID: String, at oldPath: RelativePath, to baseline: Baseline, placement: RemotePlacement) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            guard try self.baseline(rootID: rootID, remoteID: baseline.remoteID) == nil,
                  try self.baseline(rootID: rootID, remoteID: oldRemoteID)?.relativePath == oldPath else {
                try execute("COMMIT")
                return false
            }
            try deleteRows("items", rootID: rootID, remoteID: oldRemoteID)
            try deleteRows("remote_changes", rootID: rootID, remoteID: oldRemoteID)
            try upsertBaseline(rootID: rootID, baseline: baseline)
            try withStatement("UPDATE items SET placement_section = ?, placement_module = ?, placement_single = ? WHERE root_id = ? AND remote_id = ?") { statement in
                try bindPlacement(placement, to: statement, from: 1)
                try bind(rootID.uuidString, to: statement, index: 4); try bind(baseline.remoteID, to: statement, index: 5)
                try stepDone(statement)
            }
            try execute("COMMIT")
            return true
        } catch { try? execute("ROLLBACK"); throw error }
    }

    // MARK: Changes waiting for the user's choice

    private static let remoteChangeColumns = "id, course_id, remote_id, kind, relative_path, target_path, new_remote_id, placement_section, placement_module, placement_single, local_sha256, locally_modified, detected_at"

    public func remoteChanges(rootID: UUID) throws -> [RemoteChange] {
        try withStatement("SELECT \(Self.remoteChangeColumns) FROM remote_changes WHERE root_id = ? ORDER BY detected_at DESC, relative_path") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var changes: [RemoteChange] = []
            while try stepRow(statement) { changes.append(try remoteChange(statement, rootID: rootID)) }
            return changes
        }
    }

    public func remoteChange(rootID: UUID, id: UUID) throws -> RemoteChange? {
        try withStatement("SELECT \(Self.remoteChangeColumns) FROM remote_changes WHERE root_id = ? AND id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(id.uuidString, to: statement, index: 2)
            guard try stepRow(statement) else { return nil }
            return try remoteChange(statement, rootID: rootID)
        }
    }

    private func remoteChange(_ statement: OpaquePointer, rootID: UUID) throws -> RemoteChange {
        guard let id = uuid(statement, 0), let remoteID = text(statement, 2), let kindText = text(statement, 3), let kind = RemoteChange.Kind(rawValue: kindText),
              let path = text(statement, 4), let sha = text(statement, 10) else { throw SyncDatabaseError.execution }
        return RemoteChange(id: id, rootID: rootID, courseID: sqlite3_column_int64(statement, 1), remoteID: remoteID, kind: kind, relativePath: try RelativePath(path), targetPath: try text(statement, 5).map { try RelativePath($0) }, newRemoteID: text(statement, 6), placement: placement(statement, from: 7), localSHA256: sha, isLocallyModified: sqlite3_column_int(statement, 11) != 0, detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)))
    }

    /// Replaces the entries of `courseIDs` with `desired`, in one transaction: an entry that asks
    /// the same question as before is kept as it is, one no longer needed is closed. Entries of
    /// other courses (not read by this sync) are left alone. Returns the entries that are new.
    @discardableResult
    public func reconcileRemoteChanges(rootID: UUID, courseIDs: Set<Int64>, desired: [RemoteChange]) throws -> [RemoteChange] {
        let existing = try remoteChanges(rootID: rootID).filter { courseIDs.contains($0.courseID) }
        let existingByRemoteID = Dictionary(existing.map { ($0.remoteID, $0) }, uniquingKeysWith: { first, _ in first })
        let desiredIDs = Set(desired.map(\.remoteID))
        var created: [RemoteChange] = []
        // A sync with nothing new must not write: skip the transaction when every entry stands.
        let unchanged = existing.allSatisfy { desiredIDs.contains($0.remoteID) }
            && desired.allSatisfy { change in existingByRemoteID[change.remoteID].map { $0.describesSameChange(as: change) } ?? false }
        guard !unchanged else { return [] }
        try execute("BEGIN IMMEDIATE")
        do {
            for change in existing where !desiredIDs.contains(change.remoteID) {
                try deleteRows("remote_changes", rootID: rootID, remoteID: change.remoteID)
            }
            for change in desired {
                if let current = existingByRemoteID[change.remoteID], current.describesSameChange(as: change) { continue }
                try withStatement("INSERT OR REPLACE INTO remote_changes(root_id, \(Self.remoteChangeColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
                    try bind(rootID.uuidString, to: statement, index: 1); try bind(change.id.uuidString, to: statement, index: 2)
                    guard sqlite3_bind_int64(statement, 3, change.courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
                    try bind(change.remoteID, to: statement, index: 4); try bind(change.kind.rawValue, to: statement, index: 5)
                    try bind(change.relativePath.value, to: statement, index: 6); try bind(change.targetPath?.value, to: statement, index: 7)
                    try bind(change.newRemoteID, to: statement, index: 8)
                    try bindPlacement(change.placement, to: statement, from: 9)
                    try bind(change.localSHA256, to: statement, index: 12)
                    guard sqlite3_bind_int(statement, 13, change.isLocallyModified ? 1 : 0) == SQLITE_OK else { throw SyncDatabaseError.execution }
                    sqlite3_bind_double(statement, 14, change.detectedAt.timeIntervalSince1970)
                    try stepDone(statement)
                }
                created.append(change)
            }
            try execute("COMMIT")
            return created
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Records what the user's file contains now, after an action refused to run because it changed.
    public func updateRemoteChangeContents(rootID: UUID, id: UUID, sha256: String, isLocallyModified: Bool) throws {
        try withStatement("UPDATE remote_changes SET local_sha256 = ?, locally_modified = ? WHERE root_id = ? AND id = ?") { statement in
            try bind(sha256, to: statement, index: 1)
            guard sqlite3_bind_int(statement, 2, isLocallyModified ? 1 : 0) == SQLITE_OK else { throw SyncDatabaseError.execution }
            try bind(rootID.uuidString, to: statement, index: 3); try bind(id.uuidString, to: statement, index: 4)
            try stepDone(statement)
        }
    }

    public func deleteRemoteChange(rootID: UUID, id: UUID) throws {
        try withStatement("DELETE FROM remote_changes WHERE root_id = ? AND id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(id.uuidString, to: statement, index: 2)
            try stepDone(statement)
        }
    }

    /// "Lascia qui": the file stays where it is and Moodle's new placement is recorded, so the
    /// move is not proposed again.
    public func keepInPlace(_ change: RemoteChange) throws {
        guard let placement = change.placement else { throw SyncDatabaseError.execution }
        try execute("BEGIN IMMEDIATE")
        do {
            try withStatement("UPDATE items SET placement_section = ?, placement_module = ?, placement_single = ? WHERE root_id = ? AND remote_id = ? AND relative_path = ?") { statement in
                try bindPlacement(placement, to: statement, from: 1)
                try bind(change.rootID.uuidString, to: statement, index: 4); try bind(change.remoteID, to: statement, index: 5)
                try bind(change.relativePath.value, to: statement, index: 6)
                try stepDone(statement)
                guard sqlite3_changes(database) == 1 else { throw SyncDatabaseError.execution }
            }
            try deleteRemoteChange(rootID: change.rootID, id: change.id)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Retains identity and location for a file kept outside sync, so only that returning material
    /// can reuse its local copy; an unrelated new download must choose a free name.
    func detachedPaths(rootID: UUID) throws -> [String: RelativePath] {
        try withStatement("SELECT remote_id, relative_path FROM detached_items WHERE root_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var values: [String: RelativePath] = [:]
            while try stepRow(statement) {
                guard let id = text(statement, 0), let path = text(statement, 1) else { throw SyncDatabaseError.execution }
                values[id] = try RelativePath(path)
            }
            return values
        }
    }

    func rememberDetachedPath(rootID: UUID, remoteID: String, path: RelativePath) throws {
        try withStatement("INSERT INTO detached_items(root_id, remote_id, relative_path) VALUES (?, ?, ?) ON CONFLICT(root_id, remote_id) DO UPDATE SET relative_path = excluded.relative_path") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            try bind(remoteID, to: statement, index: 2)
            try bind(path.value, to: statement, index: 3)
            try stepDone(statement)
        }
    }

    /// Stops tracking the file and closes its entry, retaining its path when the user keeps it.
    public func stopTracking(_ change: RemoteChange) throws {
        try stopTracking(change, rememberingPath: false)
    }

    func stopTracking(_ change: RemoteChange, rememberingPath: Bool) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if rememberingPath {
                try rememberDetachedPath(rootID: change.rootID, remoteID: change.remoteID, path: change.relativePath)
            }
            try withStatement("DELETE FROM items WHERE root_id = ? AND remote_id = ? AND relative_path = ?") { statement in
                try bind(change.rootID.uuidString, to: statement, index: 1); try bind(change.remoteID, to: statement, index: 2)
                try bind(change.relativePath.value, to: statement, index: 3)
                try stepDone(statement)
                guard sqlite3_changes(database) == 1 else { throw SyncDatabaseError.execution }
            }
            try deleteRemoteChange(rootID: change.rootID, id: change.id)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Drops the baseline of a file the user deleted, if it is still at `path`, together with any
    /// entry about it: the file is then downloaded again as a new one.
    public func forgetBaseline(rootID: UUID, remoteID: String, at path: RelativePath) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try withStatement("DELETE FROM items WHERE root_id = ? AND remote_id = ? AND relative_path = ?") { statement in
                try bind(rootID.uuidString, to: statement, index: 1); try bind(remoteID, to: statement, index: 2)
                try bind(path.value, to: statement, index: 3)
                try stepDone(statement)
            }
            try deleteRows("remote_changes", rootID: rootID, remoteID: remoteID)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func deleteRows(_ table: String, rootID: UUID, remoteID: String) throws {
        try withStatement("DELETE FROM \(table) WHERE root_id = ? AND remote_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(remoteID, to: statement, index: 2)
            try stepDone(statement)
        }
    }

    public func beginModuleMove(_ move: PendingModuleMove) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try withStatement("INSERT INTO pending_module_moves(id, root_id, course_id, module_id, action, old_folder, new_folder, last_known_name, phase) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'prepared')") { statement in
                try bind(move.id.uuidString, to: statement, index: 1); try bind(move.rootID.uuidString, to: statement, index: 2)
                guard sqlite3_bind_int64(statement, 3, move.courseID) == SQLITE_OK, sqlite3_bind_int64(statement, 4, move.moduleID) == SQLITE_OK else { throw SyncDatabaseError.execution }
                try bind(move.action.rawValue, to: statement, index: 5); try bind(move.oldFolder, to: statement, index: 6); try bind(move.newFolder, to: statement, index: 7)
                try bind(move.lastKnownName, to: statement, index: 8); try stepDone(statement)
            }
            for file in move.files {
                try withStatement("INSERT INTO pending_module_move_files(move_id, remote_id, old_path, new_path, source_kind, source_device, source_inode, source_sha256) VALUES (?, ?, ?, ?, ?, ?, ?, ?)") { statement in
                    try bind(move.id.uuidString, to: statement, index: 1); try bind(file.remoteID, to: statement, index: 2)
                    try bind(file.oldPath.value, to: statement, index: 3); try bind(file.newPath.value, to: statement, index: 4)
                    switch file.source {
                    case .missing:
                        try bind("MISSING", to: statement, index: 5); sqlite3_bind_null(statement, 6); sqlite3_bind_null(statement, 7); sqlite3_bind_null(statement, 8)
                    case .present(let snapshot):
                        try bind("PRESENT", to: statement, index: 5)
                        guard sqlite3_bind_int64(statement, 6, snapshot.device) == SQLITE_OK,
                              sqlite3_bind_int64(statement, 7, Int64(bitPattern: snapshot.inode)) == SQLITE_OK else { throw SyncDatabaseError.execution }
                        try bind(snapshot.sha256, to: statement, index: 8)
                    }
                    try stepDone(statement)
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func pendingModuleMoves(rootID: UUID? = nil) throws -> [PendingModuleMove] {
        let sql = rootID == nil
            ? "SELECT id, root_id, course_id, module_id, action, old_folder, new_folder, last_known_name FROM pending_module_moves"
            : "SELECT id, root_id, course_id, module_id, action, old_folder, new_folder, last_known_name FROM pending_module_moves WHERE root_id = ?"
        return try withStatement(sql) { statement in
            if let rootID { try bind(rootID.uuidString, to: statement, index: 1) }
            var moves: [PendingModuleMove] = []
            while try stepRow(statement) {
                guard let id = uuid(statement, 0), let root = uuid(statement, 1),
                      let actionText = text(statement, 4), let action = ModuleMoveAction(rawValue: actionText),
                      let name = text(statement, 7) else { throw SyncDatabaseError.execution }
                moves.append(PendingModuleMove(id: id, rootID: root, courseID: sqlite3_column_int64(statement, 2), moduleID: sqlite3_column_int64(statement, 3), action: action, oldFolder: text(statement, 5), newFolder: text(statement, 6), lastKnownName: name, files: try pendingModuleMoveFiles(id: id)))
            }
            return moves
        }
    }

    public func commitModuleMove(_ move: PendingModuleMove) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for file in move.files {
                try withStatement("UPDATE items SET relative_path = ?, course_id = ?, module_id = ? WHERE root_id = ? AND remote_id = ? AND relative_path = ? AND ((course_id = ? AND module_id = ?) OR (course_id IS NULL AND module_id IS NULL))") { statement in
                    try bind(file.newPath.value, to: statement, index: 1)
                    guard sqlite3_bind_int64(statement, 2, move.courseID) == SQLITE_OK,
                          sqlite3_bind_int64(statement, 3, move.moduleID) == SQLITE_OK else { throw SyncDatabaseError.execution }
                    try bind(move.rootID.uuidString, to: statement, index: 4)
                    try bind(file.remoteID, to: statement, index: 5)
                    try bind(file.oldPath.value, to: statement, index: 6)
                    guard sqlite3_bind_int64(statement, 7, move.courseID) == SQLITE_OK,
                          sqlite3_bind_int64(statement, 8, move.moduleID) == SQLITE_OK else { throw SyncDatabaseError.execution }
                    try stepDone(statement)
                    guard sqlite3_changes(database) == 1 else { throw SyncDatabaseError.execution }
                }
                // An entry about the file names its old path; the next sync asks again if needed.
                try deleteRows("remote_changes", rootID: move.rootID, remoteID: file.remoteID)
            }
            switch move.action {
            case .set:
                guard let folder = move.newFolder else { throw SyncDatabaseError.execution }
                try withStatement("INSERT INTO module_path_overrides(root_id, course_id, module_id, local_folder, last_known_name) VALUES (?, ?, ?, ?, ?) ON CONFLICT(root_id, course_id, module_id) DO UPDATE SET local_folder = excluded.local_folder, last_known_name = excluded.last_known_name") { statement in
                    try bind(move.rootID.uuidString, to: statement, index: 1); guard sqlite3_bind_int64(statement, 2, move.courseID) == SQLITE_OK, sqlite3_bind_int64(statement, 3, move.moduleID) == SQLITE_OK else { throw SyncDatabaseError.execution }
                    try bind(folder, to: statement, index: 4); try bind(move.lastKnownName, to: statement, index: 5); try stepDone(statement)
                }
            case .remove:
                try withStatement("DELETE FROM module_path_overrides WHERE root_id = ? AND course_id = ? AND module_id = ?") { statement in
                    try bind(move.rootID.uuidString, to: statement, index: 1); guard sqlite3_bind_int64(statement, 2, move.courseID) == SQLITE_OK, sqlite3_bind_int64(statement, 3, move.moduleID) == SQLITE_OK else { throw SyncDatabaseError.execution }; try stepDone(statement)
                }
            }
            try withStatement("DELETE FROM pending_module_moves WHERE id = ?") { statement in try bind(move.id.uuidString, to: statement, index: 1); try stepDone(statement) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Drops a module move that cannot be completed, recording where each tracked file really is.
    ///
    /// `actualPaths` maps a remote id to the path its file was found at, or to `nil` when the file
    /// is at neither end of the move: that baseline is dropped so the next sync treats the file as
    /// new and never overwrites whatever now sits at either path. The module's folder rule is left
    /// as it was before the move, because only a committed move changes it.
    public func abandonModuleMove(_ move: PendingModuleMove, actualPaths: [String: RelativePath?]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for file in move.files {
                guard let actual = actualPaths[file.remoteID] else { continue }
                try deleteRows("remote_changes", rootID: move.rootID, remoteID: file.remoteID)
                if let actual {
                    guard actual != file.oldPath else { continue }
                    try withStatement("UPDATE items SET relative_path = ? WHERE root_id = ? AND remote_id = ? AND relative_path = ?") { statement in
                        try bind(actual.value, to: statement, index: 1); try bind(move.rootID.uuidString, to: statement, index: 2)
                        try bind(file.remoteID, to: statement, index: 3); try bind(file.oldPath.value, to: statement, index: 4)
                        try stepDone(statement)
                    }
                } else {
                    try withStatement("DELETE FROM items WHERE root_id = ? AND remote_id = ? AND relative_path = ?") { statement in
                        try bind(move.rootID.uuidString, to: statement, index: 1); try bind(file.remoteID, to: statement, index: 2)
                        try bind(file.oldPath.value, to: statement, index: 3)
                        try stepDone(statement)
                    }
                }
            }
            try withStatement("DELETE FROM pending_module_moves WHERE id = ?") { statement in try bind(move.id.uuidString, to: statement, index: 1); try stepDone(statement) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func pendingModuleMoveFiles(id: UUID) throws -> [PendingModuleMoveFile] {
        try withStatement("SELECT remote_id, old_path, new_path, source_kind, source_device, source_inode, source_sha256 FROM pending_module_move_files WHERE move_id = ? ORDER BY remote_id") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            var files: [PendingModuleMoveFile] = []
            while try stepRow(statement) {
                guard let remoteID = text(statement, 0), let old = text(statement, 1), let new = text(statement, 2), let kind = text(statement, 3) else { throw SyncDatabaseError.execution }
                let source: FileSnapshotState
                switch kind {
                case "MISSING": source = .missing
                case "PRESENT":
                    guard let sha = text(statement, 6), sqlite3_column_type(statement, 4) != SQLITE_NULL, sqlite3_column_type(statement, 5) != SQLITE_NULL else { throw SyncDatabaseError.execution }
                    source = .present(FileSnapshot(device: sqlite3_column_int64(statement, 4), inode: UInt64(bitPattern: sqlite3_column_int64(statement, 5)), sha256: sha))
                default: throw SyncDatabaseError.execution
                }
                files.append(PendingModuleMoveFile(remoteID: remoteID, oldPath: try RelativePath(old), newPath: try RelativePath(new), source: source))
            }
            return files
        }
    }

    public func upsertScope(_ scope: SyncScope) throws {
        try withStatement("INSERT INTO sync_scopes(root_id, course_id, display_name, local_folder, enabled, managed_directory, directory_device, directory_inode) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(root_id, course_id) DO UPDATE SET display_name = excluded.display_name, local_folder = excluded.local_folder, enabled = excluded.enabled, managed_directory = CASE WHEN excluded.managed_directory = 1 THEN 1 ELSE sync_scopes.managed_directory END, directory_device = CASE WHEN excluded.managed_directory = 1 THEN excluded.directory_device ELSE sync_scopes.directory_device END, directory_inode = CASE WHEN excluded.managed_directory = 1 THEN excluded.directory_inode ELSE sync_scopes.directory_inode END") { statement in
            try bind(scope.rootID.uuidString, to: statement, index: 1)
            guard sqlite3_bind_int64(statement, 2, scope.courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            try bind(scope.displayName, to: statement, index: 3)
            try bind(scope.localFolder, to: statement, index: 4)
            guard sqlite3_bind_int(statement, 5, scope.enabled ? 1 : 0) == SQLITE_OK else { throw SyncDatabaseError.execution }
            guard sqlite3_bind_int(statement, 6, scope.managedDirectory == nil ? 0 : 1) == SQLITE_OK else { throw SyncDatabaseError.execution }
            if let identity = scope.managedDirectory {
                guard sqlite3_bind_int64(statement, 7, identity.device) == SQLITE_OK,
                      sqlite3_bind_int64(statement, 8, Int64(bitPattern: identity.inode)) == SQLITE_OK else { throw SyncDatabaseError.execution }
            } else { sqlite3_bind_null(statement, 7); sqlite3_bind_null(statement, 8) }
            try stepDone(statement)
        }
    }

    /// Turns every course of the root off, keeping folders and directory identities. Used when the
    /// account moves to another Moodle site: course ids are only unique within one site, so the old
    /// site's selection must never be read as a selection of the new site's courses.
    public func disableAllScopes(rootID: UUID) throws {
        try withStatement("UPDATE sync_scopes SET enabled = 0 WHERE root_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            try stepDone(statement)
        }
    }

    private static let scopeColumns = "course_id, display_name, local_folder, enabled, managed_directory, directory_device, directory_inode"

    public func scopes(rootID: UUID, enabledOnly: Bool = false) throws -> [SyncScope] {
        let sql = enabledOnly
            ? "SELECT \(Self.scopeColumns) FROM sync_scopes WHERE root_id = ? AND enabled = 1 ORDER BY display_name, course_id"
            : "SELECT \(Self.scopeColumns) FROM sync_scopes WHERE root_id = ? ORDER BY display_name, course_id"
        return try withStatement(sql) { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var scopes: [SyncScope] = []
            while try stepRow(statement) {
                scopes.append(try scope(statement, rootID: rootID))
            }
            return scopes
        }
    }

    private func scope(_ statement: OpaquePointer, rootID: UUID) throws -> SyncScope {
        guard let displayName = text(statement, 1), let localFolder = text(statement, 2) else { throw SyncDatabaseError.execution }
        let identity: DirectoryIdentity? = sqlite3_column_int(statement, 4) != 0 && sqlite3_column_type(statement, 5) != SQLITE_NULL && sqlite3_column_type(statement, 6) != SQLITE_NULL ? DirectoryIdentity(device: sqlite3_column_int64(statement, 5), inode: UInt64(bitPattern: sqlite3_column_int64(statement, 6))) : nil
        return SyncScope(rootID: rootID, courseID: sqlite3_column_int64(statement, 0), displayName: displayName, localFolder: localFolder, enabled: sqlite3_column_int(statement, 3) != 0, managedDirectory: identity)
    }

    public func beginScopeMove(_ move: PendingScopeMove) throws {
        try withStatement("INSERT INTO pending_scope_moves(id, root_id, course_id, old_folder, new_folder, phase) VALUES (?, ?, ?, ?, ?, 'prepared')") { statement in
            try bind(move.id.uuidString, to: statement, index: 1); try bind(move.rootID.uuidString, to: statement, index: 2)
            guard sqlite3_bind_int64(statement, 3, move.courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            try bind(move.oldFolder, to: statement, index: 4); try bind(move.newFolder, to: statement, index: 5); try stepDone(statement)
        }
    }

    /// Drops a prepared scope move without touching the scope or the tracked paths.
    ///
    /// Used to roll back a rename that failed after the row was written: the table is unique per
    /// (root, course) and per (root, new folder), so a leftover row would block every later rename
    /// of the same course and would be replayed as an unresolvable move at the next launch.
    public func abortScopeMove(id: UUID) throws {
        try withStatement("DELETE FROM pending_scope_moves WHERE id = ?") { statement in
            try bind(id.uuidString, to: statement, index: 1); try stepDone(statement)
        }
    }

    public func commitScopeMove(_ move: PendingScopeMove) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try withStatement("UPDATE sync_scopes SET local_folder = ? WHERE root_id = ? AND course_id = ? AND local_folder = ?") { statement in
                try bind(move.newFolder, to: statement, index: 1); try bind(move.rootID.uuidString, to: statement, index: 2)
                guard sqlite3_bind_int64(statement, 3, move.courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
                try bind(move.oldFolder, to: statement, index: 4); try stepDone(statement)
                guard sqlite3_changes(database) == 1 else { throw SyncDatabaseError.execution }
            }
            try withStatement("UPDATE items SET relative_path = ? || substr(relative_path, length(?) + 1) WHERE root_id = ? AND (relative_path = ? OR substr(relative_path, 1, length(?) + 1) = ? || '/')") { statement in
                try bind(move.newFolder, to: statement, index: 1); try bind(move.oldFolder, to: statement, index: 2); try bind(move.rootID.uuidString, to: statement, index: 3)
                try bind(move.oldFolder, to: statement, index: 4); try bind(move.oldFolder, to: statement, index: 5); try bind(move.oldFolder, to: statement, index: 6); try stepDone(statement)
            }
            // Entries and journaled moves about the course's files follow the folder too: an entry's
            // action would find the file gone, and a journaled move could no longer be recovered.
            for (table, column) in [("detached_items", "relative_path"), ("remote_changes", "relative_path"), ("remote_changes", "target_path"), ("pending_remote_moves", "from_path"), ("pending_remote_moves", "to_path")] {
                try withStatement("UPDATE \(table) SET \(column) = ? || substr(\(column), length(?) + 1) WHERE root_id = ? AND (\(column) = ? OR substr(\(column), 1, length(?) + 1) = ? || '/')") { statement in
                    try bind(move.newFolder, to: statement, index: 1); try bind(move.oldFolder, to: statement, index: 2); try bind(move.rootID.uuidString, to: statement, index: 3)
                    try bind(move.oldFolder, to: statement, index: 4); try bind(move.oldFolder, to: statement, index: 5); try bind(move.oldFolder, to: statement, index: 6); try stepDone(statement)
                }
            }
            try withStatement("DELETE FROM pending_scope_moves WHERE id = ?") { statement in try bind(move.id.uuidString, to: statement, index: 1); try stepDone(statement) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func insertConflict(_ conflict: ConflictRecord) throws {
        try withStatement("INSERT INTO conflicts(id, root_id, remote_id, relative_path, incoming_path, base_sha256, local_sha256, remote_sha256, remote_revision, detected_at, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            try bind(conflict.id.uuidString, to: statement, index: 1)
            try bind(conflict.rootID.uuidString, to: statement, index: 2)
            try bind(conflict.remoteID, to: statement, index: 3)
            try bind(conflict.relativePath.value, to: statement, index: 4)
            try bind(conflict.incomingPath.value, to: statement, index: 5)
            try bind(conflict.baseSHA256, to: statement, index: 6)
            try bind(conflict.localSHA256, to: statement, index: 7)
            try bind(conflict.remoteSHA256, to: statement, index: 8)
            try bind(conflict.remoteRevision, to: statement, index: 9)
            sqlite3_bind_double(statement, 10, conflict.detectedAt.timeIntervalSince1970)
            try bind(conflict.status.rawValue, to: statement, index: 11)
            try stepDone(statement)
        }
    }

    public func conflicts(rootID: UUID) throws -> [ConflictRecord] {
        try withStatement("SELECT id, remote_id, relative_path, incoming_path, base_sha256, local_sha256, remote_sha256, remote_revision, detected_at, status FROM conflicts WHERE root_id = ? AND status = 'open' ORDER BY detected_at DESC") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            var records: [ConflictRecord] = []
            while try stepRow(statement) {
                guard let id = uuid(statement, 0), let remoteID = text(statement, 1), let relativePath = text(statement, 2), let incomingPath = text(statement, 3), let remoteSHA256 = text(statement, 6), let revision = text(statement, 7), let statusText = text(statement, 9), let status = ConflictStatus(rawValue: statusText) else { throw SyncDatabaseError.execution }
                records.append(ConflictRecord(id: id, rootID: rootID, remoteID: remoteID, relativePath: try RelativePath(relativePath), incomingPath: try RelativePath(internal: incomingPath), baseSHA256: text(statement, 4), localSHA256: text(statement, 5), remoteSHA256: remoteSHA256, remoteRevision: revision, detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)), status: status))
            }
            return records
        }
    }

    public func conflict(id: UUID) throws -> ConflictRecord? {
        try withStatement("SELECT root_id, remote_id, relative_path, incoming_path, base_sha256, local_sha256, remote_sha256, remote_revision, detected_at, status FROM conflicts WHERE id = ? AND status = 'open'") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            guard try stepRow(statement) else { return nil }
            guard let rootID = uuid(statement, 0), let remoteID = text(statement, 1), let relativePath = text(statement, 2), let incomingPath = text(statement, 3), let remoteSHA256 = text(statement, 6), let revision = text(statement, 7), let statusText = text(statement, 9), let status = ConflictStatus(rawValue: statusText) else { throw SyncDatabaseError.execution }
            return ConflictRecord(id: id, rootID: rootID, remoteID: remoteID, relativePath: try RelativePath(relativePath), incomingPath: try RelativePath(internal: incomingPath), baseSHA256: text(statement, 4), localSHA256: text(statement, 5), remoteSHA256: remoteSHA256, remoteRevision: revision, detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)), status: status)
        }
    }

    public func acceptRemoteAndResolve(id: UUID) throws -> ConflictRecord {
        guard let conflict = try conflict(id: id) else { throw SyncDatabaseError.execution }
        let baseline = Baseline(remoteID: conflict.remoteID, relativePath: conflict.relativePath, sha256: conflict.remoteSHA256, remoteRevision: conflict.remoteRevision)
        try resolveConflict(id: id, resolution: .keepLocal, baseline: baseline)
        return conflict
    }

    public func markResolved(id: UUID) throws {
        try withStatement("UPDATE conflicts SET status = 'resolved' WHERE id = ? AND status = 'open'") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            try stepDone(statement)
        }
    }

    public func resolveConflict(id: UUID, resolution _: ConflictResolution, baseline: Baseline) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let rootID = try withStatement("SELECT root_id FROM conflicts WHERE id = ?") { statement in
                try bind(id.uuidString, to: statement, index: 1)
                guard try stepRow(statement), let rootID = uuid(statement, 0) else { throw SyncDatabaseError.execution }
                return rootID
            }
            try upsertBaseline(rootID: rootID, baseline: baseline)
            try withStatement("UPDATE conflicts SET status = 'resolved' WHERE id = ?") { statement in
                try bind(id.uuidString, to: statement, index: 1)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func beginOperation(_ operation: PendingOperation) throws {
        try withStatement("INSERT INTO pending_operations(id, root_id, remote_id, destination_path, stage_path, expected_local_kind, expected_local_sha256, remote_sha256, remote_revision, phase, course_id, module_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            try bind(operation.id.uuidString, to: statement, index: 1)
            try bind(operation.rootID.uuidString, to: statement, index: 2)
            try bind(operation.remoteID, to: statement, index: 3)
            try bind(operation.destination.value, to: statement, index: 4)
            try bind(operation.stagePath.value, to: statement, index: 5)
            switch operation.expectedLocal {
            case .missing:
                try bind("missing", to: statement, index: 6)
                try bind(nil as String?, to: statement, index: 7)
            case .present(let sha256):
                try bind("present", to: statement, index: 6)
                try bind(sha256, to: statement, index: 7)
            }
            try bind(operation.remoteSHA256, to: statement, index: 8)
            try bind(operation.remoteRevision, to: statement, index: 9)
            try bind(operation.phase.rawValue, to: statement, index: 10)
            try bind(operation.courseID, to: statement, index: 11); try bind(operation.moduleID, to: statement, index: 12)
            try stepDone(statement)
        }
    }

    public func markCommitted(id: UUID, baseline: Baseline) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let rootID = try rootID(forOperation: id)
            try upsertBaseline(rootID: rootID, baseline: baseline)
            try withStatement("UPDATE pending_operations SET phase = 'committed' WHERE id = ?") { statement in
                try bind(id.uuidString, to: statement, index: 1)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func finishOperation(id: UUID) throws {
        try withStatement("DELETE FROM pending_operations WHERE id = ?") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            try stepDone(statement)
        }
    }

    public func finishAsConflict(id: UUID, conflict: ConflictRecord) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try insertConflict(conflict)
            try finishOperation(id: id)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func pendingOperations(rootID: UUID? = nil) throws -> [PendingOperation] {
        let sql = rootID == nil ? "SELECT id, root_id, remote_id, destination_path, stage_path, expected_local_kind, expected_local_sha256, remote_sha256, remote_revision, phase, course_id, module_id FROM pending_operations" : "SELECT id, root_id, remote_id, destination_path, stage_path, expected_local_kind, expected_local_sha256, remote_sha256, remote_revision, phase, course_id, module_id FROM pending_operations WHERE root_id = ?"
        return try withStatement(sql) { statement in
            if let rootID { try bind(rootID.uuidString, to: statement, index: 1) }
            var operations: [PendingOperation] = []
            while try stepRow(statement) {
                guard let id = uuid(statement, 0), let rootID = uuid(statement, 1), let remoteID = text(statement, 2), let destination = text(statement, 3), let stage = text(statement, 4), let expectedKind = text(statement, 5), let remoteSHA256 = text(statement, 7), let remoteRevision = text(statement, 8), let phaseText = text(statement, 9), let phase = PendingOperationPhase(rawValue: phaseText) else { throw SyncDatabaseError.execution }
                let expectedLocal: LocalState
                switch expectedKind {
                case "missing": expectedLocal = .missing
                case "present":
                    guard let hash = text(statement, 6) else { throw SyncDatabaseError.execution }
                    expectedLocal = .present(sha256: hash)
                default: throw SyncDatabaseError.legacyPendingOperation
                }
                operations.append(PendingOperation(id: id, rootID: rootID, remoteID: remoteID, destination: try RelativePath(destination), stagePath: try RelativePath(internal: stage), expectedLocal: expectedLocal, remoteSHA256: remoteSHA256, remoteRevision: remoteRevision, phase: phase, courseID: optionalInt64(statement, 10), moduleID: optionalInt64(statement, 11)))
            }
            return operations
        }
    }

    public func pendingScopeMoves(rootID: UUID? = nil) throws -> [PendingScopeMove] {
        let sql = rootID == nil ? "SELECT id, root_id, course_id, old_folder, new_folder FROM pending_scope_moves" : "SELECT id, root_id, course_id, old_folder, new_folder FROM pending_scope_moves WHERE root_id = ?"
        return try withStatement(sql) { statement in
            if let rootID { try bind(rootID.uuidString, to: statement, index: 1) }
            var moves: [PendingScopeMove] = []
            while try stepRow(statement) {
                guard let id = uuid(statement, 0), let root = uuid(statement, 1), let old = text(statement, 3), let new = text(statement, 4) else { throw SyncDatabaseError.execution }
                moves.append(PendingScopeMove(id: id, rootID: root, courseID: sqlite3_column_int64(statement, 2), oldFolder: old, newFolder: new))
            }
            return moves
        }
    }

    public func scopeFolder(rootID: UUID, courseID: Int64) throws -> String? {
        try withStatement("SELECT local_folder FROM sync_scopes WHERE root_id = ? AND course_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            guard sqlite3_bind_int64(statement, 2, courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            guard try stepRow(statement) else { return nil }
            guard let folder = text(statement, 0) else { throw SyncDatabaseError.execution }
            return folder
        }
    }

    public func scope(rootID: UUID, courseID: Int64) throws -> SyncScope? {
        try withStatement("SELECT \(Self.scopeColumns) FROM sync_scopes WHERE root_id = ? AND course_id = ?") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            guard sqlite3_bind_int64(statement, 2, courseID) == SQLITE_OK else { throw SyncDatabaseError.execution }
            guard try stepRow(statement) else { return nil }
            return try scope(statement, rootID: rootID)
        }
    }

    public func renameScopeMetadata(rootID: UUID, courseID: Int64, from oldFolder: String, to newFolder: String) throws {
        let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: courseID, oldFolder: oldFolder, newFolder: newFolder)
        try commitScopeMove(move)
    }

    public func hasOpenConflicts(rootID: UUID, prefix: String) throws -> Bool { try hasPath("conflicts", column: "relative_path", rootID: rootID, prefix: prefix, extra: "AND status = 'open'") }
    public func hasOpenConflict(rootID: UUID, remoteID: String, revision: String) throws -> Bool {
        try withStatement("SELECT 1 FROM conflicts WHERE root_id = ? AND remote_id = ? AND remote_revision = ? AND status = 'open' LIMIT 1") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(remoteID, to: statement, index: 2); try bind(revision, to: statement, index: 3)
            return try stepRow(statement)
        }
    }
    public func hasPendingOperations(rootID: UUID, prefix: String) throws -> Bool { try hasPath("pending_operations", column: "destination_path", rootID: rootID, prefix: prefix, extra: "") }
    public func hasPendingModuleMoves(rootID: UUID) throws -> Bool {
        try withStatement("SELECT 1 FROM pending_module_moves WHERE root_id = ? LIMIT 1") { statement in
            try bind(rootID.uuidString, to: statement, index: 1)
            return try stepRow(statement)
        }
    }
    public func trackedItemCount(rootID: UUID, prefix: String) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM items WHERE root_id = ? AND (relative_path = ? OR substr(relative_path, 1, length(?) + 1) = ? || '/')") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(prefix, to: statement, index: 2); try bind(prefix, to: statement, index: 3); try bind(prefix, to: statement, index: 4)
            guard try stepRow(statement) else { throw SyncDatabaseError.execution }; return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func hasPath(_ table: String, column: String, rootID: UUID, prefix: String, extra: String) throws -> Bool {
        try withStatement("SELECT 1 FROM \(table) WHERE root_id = ? AND (\(column) = ? OR substr(\(column), 1, length(?) + 1) = ? || '/') \(extra) LIMIT 1") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(prefix, to: statement, index: 2); try bind(prefix, to: statement, index: 3); try bind(prefix, to: statement, index: 4)
            return try stepRow(statement)
        }
    }

    private func hasOpenConflictForMigration(rootID: UUID, remoteID: String) throws -> Bool {
        try withStatement("SELECT 1 FROM conflicts WHERE root_id = ? AND remote_id = ? AND status = 'open' LIMIT 1") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(remoteID, to: statement, index: 2)
            return try stepRow(statement)
        }
    }

    private func hasPendingOperationForMigration(rootID: UUID, remoteID: String) throws -> Bool {
        try withStatement("SELECT 1 FROM pending_operations WHERE root_id = ? AND remote_id = ? LIMIT 1") { statement in
            try bind(rootID.uuidString, to: statement, index: 1); try bind(remoteID, to: statement, index: 2)
            return try stepRow(statement)
        }
    }

    private var transientDestructor: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func execute(_ sql: String) throws {
        try Self.execute(database, sql)
    }

    private static func migrate(_ database: OpaquePointer?) throws {
        try execute(database, "BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute(database, "ROLLBACK") } }
        try execute(database, "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY)")
        try execute(database, "CREATE TABLE IF NOT EXISTS roots (id TEXT PRIMARY KEY, canonical_path TEXT NOT NULL UNIQUE, security_bookmark BLOB, settings_json TEXT NOT NULL DEFAULT '{}')")
        try execute(database, "CREATE TABLE IF NOT EXISTS sync_scopes (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, display_name TEXT NOT NULL, local_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)), auto_sync INTEGER NOT NULL DEFAULT 0 CHECK(auto_sync IN (0, 1)), managed_directory INTEGER NOT NULL DEFAULT 0 CHECK(managed_directory IN (0, 1)), directory_device INTEGER, directory_inode INTEGER, PRIMARY KEY(root_id, course_id), UNIQUE(root_id, local_folder))")
        // `auto_sync` is unused: automatic sync is one app-wide setting, not per course. The
        // column stays because installed databases already have it and dropping a column means
        // rebuilding the table; nothing reads it, and new rows get the default.
        if try !columnExists(database, table: "sync_scopes", column: "auto_sync") { try execute(database, "ALTER TABLE sync_scopes ADD COLUMN auto_sync INTEGER NOT NULL DEFAULT 0") }
        try execute(database, "CREATE TABLE IF NOT EXISTS remote_observations (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, remote_id TEXT NOT NULL, observed_revision TEXT NOT NULL, observed_sha256 TEXT, relative_path TEXT NOT NULL, size INTEGER NOT NULL, first_seen_at REAL NOT NULL, last_seen_at REAL NOT NULL, last_notified_revision TEXT, PRIMARY KEY(root_id, remote_id))")
        try execute(database, "CREATE TABLE IF NOT EXISTS items (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, relative_path TEXT NOT NULL, base_sha256 TEXT NOT NULL, remote_revision TEXT NOT NULL, last_seen_at REAL, course_id INTEGER, module_id INTEGER, PRIMARY KEY(root_id, remote_id), CHECK((course_id IS NULL AND module_id IS NULL) OR (course_id IS NOT NULL AND module_id IS NOT NULL)))")
        if try !columnExists(database, table: "items", column: "course_id") { try execute(database, "ALTER TABLE items ADD COLUMN course_id INTEGER") }
        if try !columnExists(database, table: "items", column: "module_id") { try execute(database, "ALTER TABLE items ADD COLUMN module_id INTEGER") }
        try execute(database, "UPDATE items SET course_id = NULL, module_id = NULL WHERE (course_id IS NULL) != (module_id IS NULL)")
        // Where Moodle placed each file when it was last seen, so a later sync can tell a move made
        // on Moodle from a change in Beepbar's own path rules. Existing rows start empty and are
        // filled on their next sync without moving anything (see `RemoteMovePolicy`).
        if try !columnExists(database, table: "items", column: "placement_section") { try execute(database, "ALTER TABLE items ADD COLUMN placement_section TEXT") }
        if try !columnExists(database, table: "items", column: "placement_module") { try execute(database, "ALTER TABLE items ADD COLUMN placement_module TEXT") }
        if try !columnExists(database, table: "items", column: "placement_single") { try execute(database, "ALTER TABLE items ADD COLUMN placement_single INTEGER") }
        // Entries waiting for the user's choice about files Moodle moved or removed (see
        // `RemoteChange`), and moves journaled before their rename (see `PendingRemoteMove`). An
        // older version ignores both tables.
        try execute(database, "CREATE TABLE IF NOT EXISTS detached_items (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, relative_path TEXT NOT NULL, PRIMARY KEY(root_id, remote_id))")
        try execute(database, "CREATE TABLE IF NOT EXISTS remote_changes (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, id TEXT PRIMARY KEY, course_id INTEGER NOT NULL, remote_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('moved', 'removed', 'reuploaded')), relative_path TEXT NOT NULL, target_path TEXT, new_remote_id TEXT, placement_section TEXT, placement_module TEXT, placement_single INTEGER, local_sha256 TEXT NOT NULL, locally_modified INTEGER NOT NULL CHECK(locally_modified IN (0, 1)), detected_at REAL NOT NULL, UNIQUE(root_id, remote_id))")
        try execute(database, "CREATE TABLE IF NOT EXISTS pending_remote_moves (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, batch_id TEXT NOT NULL, from_path TEXT NOT NULL, to_path TEXT NOT NULL, sha256 TEXT NOT NULL, placement_section TEXT, placement_module TEXT, placement_single INTEGER, PRIMARY KEY(root_id, remote_id))")
        try execute(database, "CREATE TABLE IF NOT EXISTS conflicts (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, relative_path TEXT NOT NULL, incoming_path TEXT NOT NULL, base_sha256 TEXT, local_sha256 TEXT, remote_sha256 TEXT NOT NULL, remote_revision TEXT NOT NULL, detected_at REAL NOT NULL, status TEXT NOT NULL CHECK(status IN ('open', 'resolved')))")
        try execute(database, "CREATE TABLE IF NOT EXISTS pending_operations (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, destination_path TEXT NOT NULL, stage_path TEXT NOT NULL, expected_local_kind TEXT NOT NULL DEFAULT 'unknown' CHECK(expected_local_kind IN ('missing', 'present', 'unknown')), expected_local_sha256 TEXT, remote_sha256 TEXT NOT NULL DEFAULT '', remote_revision TEXT NOT NULL DEFAULT '', phase TEXT NOT NULL DEFAULT 'prepared' CHECK(phase IN ('prepared', 'committed')), course_id INTEGER, module_id INTEGER, UNIQUE(root_id, remote_id), UNIQUE(root_id, destination_path))")
        if try !columnExists(database, table: "pending_operations", column: "course_id") { try execute(database, "ALTER TABLE pending_operations ADD COLUMN course_id INTEGER") }
        if try !columnExists(database, table: "pending_operations", column: "module_id") { try execute(database, "ALTER TABLE pending_operations ADD COLUMN module_id INTEGER") }
        try execute(database, "CREATE TABLE IF NOT EXISTS pending_scope_moves (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, old_folder TEXT NOT NULL, new_folder TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('prepared')), UNIQUE(root_id, course_id), UNIQUE(root_id, new_folder))")
        try execute(database, "CREATE TABLE IF NOT EXISTS module_path_overrides (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, module_id INTEGER NOT NULL, local_folder TEXT NOT NULL, last_known_name TEXT NOT NULL, PRIMARY KEY(root_id, course_id, module_id))")
        try execute(database, "CREATE TABLE IF NOT EXISTS pending_module_moves (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, module_id INTEGER NOT NULL, action TEXT NOT NULL CHECK(action IN ('set', 'remove')), old_folder TEXT, new_folder TEXT, last_known_name TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase = 'prepared'), UNIQUE(root_id, course_id, module_id))")
        try execute(database, "CREATE TABLE IF NOT EXISTS pending_module_move_files (move_id TEXT NOT NULL REFERENCES pending_module_moves(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, old_path TEXT NOT NULL, new_path TEXT NOT NULL, source_kind TEXT NOT NULL CHECK(source_kind IN ('MISSING', 'PRESENT')), source_device INTEGER, source_inode INTEGER, source_sha256 TEXT, PRIMARY KEY(move_id, remote_id), CHECK((source_kind = 'MISSING' AND source_device IS NULL AND source_inode IS NULL AND source_sha256 IS NULL) OR (source_kind = 'PRESENT' AND source_device IS NOT NULL AND source_inode IS NOT NULL AND source_sha256 IS NOT NULL)))")
        if try !columnExists(database, table: "pending_operations", column: "expected_local_kind") { try execute(database, "ALTER TABLE pending_operations ADD COLUMN expected_local_kind TEXT NOT NULL DEFAULT 'unknown'") }
        if try !columnExists(database, table: "pending_operations", column: "expected_local_sha256") { try execute(database, "ALTER TABLE pending_operations ADD COLUMN expected_local_sha256 TEXT") }
        if try !columnExists(database, table: "pending_operations", column: "remote_sha256") { try execute(database, "ALTER TABLE pending_operations ADD COLUMN remote_sha256 TEXT NOT NULL DEFAULT ''") }
        if try !columnExists(database, table: "pending_operations", column: "remote_revision") { try execute(database, "ALTER TABLE pending_operations ADD COLUMN remote_revision TEXT NOT NULL DEFAULT ''") }
        if try !columnExists(database, table: "pending_operations", column: "phase") { try execute(database, "ALTER TABLE pending_operations ADD COLUMN phase TEXT NOT NULL DEFAULT 'prepared'") }
        if try !columnExists(database, table: "sync_scopes", column: "local_folder") {
            try execute(database, "ALTER TABLE sync_scopes ADD COLUMN local_folder TEXT NOT NULL DEFAULT ''")
        }
        if try !columnExists(database, table: "sync_scopes", column: "managed_directory") { try execute(database, "ALTER TABLE sync_scopes ADD COLUMN managed_directory INTEGER NOT NULL DEFAULT 0") }
        if try !columnExists(database, table: "sync_scopes", column: "directory_device") { try execute(database, "ALTER TABLE sync_scopes ADD COLUMN directory_device INTEGER") }
        if try !columnExists(database, table: "sync_scopes", column: "directory_inode") { try execute(database, "ALTER TABLE sync_scopes ADD COLUMN directory_inode INTEGER") }
        try execute(database, "CREATE UNIQUE INDEX IF NOT EXISTS pending_operations_root_remote ON pending_operations(root_id, remote_id)")
        try execute(database, "CREATE UNIQUE INDEX IF NOT EXISTS pending_operations_root_destination ON pending_operations(root_id, destination_path)")
        try execute(database, "CREATE INDEX IF NOT EXISTS conflicts_root_remote_status ON conflicts(root_id, remote_id, status)")
        try execute(database, "CREATE INDEX IF NOT EXISTS items_root_course_module ON items(root_id, course_id, module_id)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (1)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (2)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (3)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (4)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (5)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (6)")
        try execute(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES (7)")
        try execute(database, "COMMIT")
        committed = true
    }

    private static func execute(_ database: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw SyncDatabaseError.execution }
    }

    private static func columnExists(_ database: OpaquePointer?, table: String, column: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else { throw SyncDatabaseError.statement }
        defer { sqlite3_finalize(statement) }
        while try stepRow(statement) {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SyncDatabaseError.statement }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String?, to statement: OpaquePointer, index: Int32) throws {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        guard sqlite3_bind_text(statement, index, value, -1, transientDestructor) == SQLITE_OK else { throw SyncDatabaseError.execution }
    }

    private func bind(_ value: Int64?, to statement: OpaquePointer, index: Int32) throws {
        guard let value else { sqlite3_bind_null(statement, index); return }
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw SyncDatabaseError.execution }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SyncDatabaseError.execution }
    }

    private func rootID(forOperation id: UUID) throws -> UUID {
        try withStatement("SELECT root_id FROM pending_operations WHERE id = ?") { statement in
            try bind(id.uuidString, to: statement, index: 1)
            guard try stepRow(statement), let rootID = uuid(statement, 0) else { throw SyncDatabaseError.execution }
            return rootID
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func optionalInt64(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    private func uuid(_ statement: OpaquePointer, _ column: Int32) -> UUID? {
        text(statement, column).flatMap(UUID.init(uuidString:))
    }
}
