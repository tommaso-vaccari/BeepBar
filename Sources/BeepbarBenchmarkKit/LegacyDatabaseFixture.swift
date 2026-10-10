import BeepbarCore
import CSQLite
import Foundation

/// A `sync.sqlite` an older release could have left behind, for the `startup` scenario (R02,
/// issue #110): what the first launch after updating repairs, and what every later launch costs.
///
/// The database is built through today's `SyncDatabase` (folder, courses, `files` tracked files)
/// and then degraded behind its back on a raw connection, the way `StartupMigrationTests` does:
/// `legacyFraction` of the tracked files lose their owning course and module, as releases before
/// module ownership left them; `partialRows` of the remaining ones keep the course but lose the
/// module, a half attribution today's `CHECK` forbids (written with constraints off, as an old
/// table without the constraint would hold it); the recorded migration versions are deleted; and
/// the tables and the index added by later releases are dropped. The next open must put all of
/// it back in one transaction, and the opens after that must find nothing to do.
///
/// Safety: everything lives in a new temporary folder that `remove()` deletes; the user's
/// database, preferences, keychain and sync folder are never touched.
package final class LegacyDatabaseFixture: Sendable {
    package let container: URL
    package let root: URL
    package let databaseURL: URL
    package let rootID = UUID()
    package let files: Int
    /// Half-attributed rows the fixture actually produced: at most `partialRows`, and never more
    /// than the rows that kept an owner.
    package let partialRows: Int

    package init(files: Int, legacyFraction: Double = 0.5, partialRows: Int = 40, courses: Int = 15) async throws {
        precondition(files >= 0 && courses > 0 && (0...1).contains(legacyFraction) && partialRows >= 0)
        // Which rows keep an owner is decided by their index, so the count is known up front and
        // every stored property is set before the fixture starts creating anything.
        func hasOwner(_ index: Int) -> Bool { Double(index % 1000) >= legacyFraction * 1000 }
        let owned = (0..<files).filter(hasOwner).count
        self.files = files
        self.partialRows = min(partialRows, owned)
        let container = FileManager.default.temporaryDirectory.appending(path: "beepbar-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = container.appending(path: "Sync", directoryHint: .isDirectory)
        let databaseURL = container.appending(path: "sync.sqlite")
        let rootID = self.rootID
        self.container = container
        self.root = root
        self.databaseURL = databaseURL
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                // Scoped so the connection closes before the raw writes below: the degraded
                // state must be what the first measured launch opens.
                let database = try SyncDatabase(url: databaseURL)
                try await database.registerRoot(id: rootID, canonicalPath: root.path)
                for course in 1...courses {
                    try await database.upsertScope(SyncScope(rootID: rootID, courseID: Int64(course), displayName: "Corso \(course)", localFolder: "Corso \(course)", enabled: true))
                }
            }
            let raw = try RawConnection(url: databaseURL)
            // One transaction: the fixture's own writes are not what is measured, and thousands of
            // single commits under `synchronous = FULL` would take minutes.
            try raw.execute("BEGIN")
            for index in 0..<files {
                let course = index % courses + 1
                let ownership = hasOwner(index) ? "\(course), \(course * 100)" : "NULL, NULL"
                // Keep the column list in step with the `items` schema in `SyncDatabase.migrate`.
                try raw.execute("INSERT INTO items(root_id, remote_id, relative_path, base_sha256, remote_revision, last_seen_at, course_id, module_id) VALUES ('\(rootID.uuidString)', '\(course):\(course * 100):/:\(index).pdf', 'Corso \(course)/\(index).pdf', '\(String(repeating: "a", count: 64))', '1', 0, \(ownership))")
            }
            try raw.execute("COMMIT")
            if self.partialRows > 0 {
                try raw.execute("PRAGMA ignore_check_constraints = ON; UPDATE items SET module_id = NULL WHERE rowid IN (SELECT rowid FROM items WHERE course_id IS NOT NULL LIMIT \(self.partialRows)); PRAGMA ignore_check_constraints = OFF")
            }
            try raw.execute("DELETE FROM schema_migrations; DROP TABLE detached_items; DROP TABLE remote_changes; DROP TABLE pending_remote_moves; DROP INDEX items_root_course_module")
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
    }

    /// Deletes everything the fixture created.
    package func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    /// Tracked files attributed to a course without a module or the reverse: what the first
    /// launch's repair clears.
    package func halfAttributedRows() throws -> Int {
        try RawConnection(url: databaseURL).count("SELECT count(*) FROM items WHERE (course_id IS NULL) != (module_id IS NULL)")
    }

    /// Tracked files still in the database, whatever their ownership.
    package func trackedRows() throws -> Int {
        try RawConnection(url: databaseURL).count("SELECT count(*) FROM items")
    }

    /// The objects the fixture dropped, counted back: 4 once the migration has recreated the
    /// three tables and the index, plus the 7 recorded versions.
    package func laterReleaseObjects() throws -> (tables: Int, versions: Int) {
        let raw = try RawConnection(url: databaseURL)
        return (try raw.count("SELECT count(*) FROM sqlite_master WHERE name IN ('detached_items', 'remote_changes', 'pending_remote_moves', 'items_root_course_module')"), try raw.count("SELECT count(*) FROM schema_migrations"))
    }

    /// One launch's database work, as `BootstrapService.prepare` runs it in the app: open (which
    /// migrates), register the folder, recover. The connection closes when `database` goes away,
    /// so each call is a cold open of the file, as a relaunch is. `open` is the open alone, the
    /// part whose cost the migration decides.
    package func launch() async throws -> (open: Duration, total: Duration, written: SyncDatabaseWriteCounters, report: RecoveryReport) {
        let clock = ContinuousClock()
        let start = clock.now
        let database = try SyncDatabase(url: databaseURL)
        let opened = clock.now
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: try FileStore(root: root) { _ in }).recover()
        let end = clock.now
        return (opened - start, end - start, await database.writeCounters(), report)
    }
}

/// A second, independent connection to the fixture's file, to change or read it behind
/// `SyncDatabase`'s back. Benchmark code only.
private final class RawConnection {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { "sqlite: \(message)" }
    }

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

    /// The first column of the first row of a `count(*)` query.
    func count(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure(message: String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(handle))) }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
