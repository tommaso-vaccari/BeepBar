import BeepbarCore
import CSQLite
import Foundation

/// A degraded `sync.sqlite` with today's schema, for the `startup` scenario (R02, issue #110):
/// what a launch that has repairs to do costs, and what every later launch costs. It is not the
/// schema of a real older release; the upgrade from v2.0.106 is covered by
/// `StartupMigrationTests` in Core.
///
/// The database is built through today's `SyncDatabase` (folder, courses, `files` tracked files)
/// and then degraded behind its back on a raw connection: `legacyFraction` of the tracked files
/// lose their owning course and module; `partialRows` of the remaining ones keep the course but
/// lose the module, a half attribution today's `CHECK` forbids (written with constraints off, as
/// a table upgraded by `ADD COLUMN`, which has no such `CHECK`, could hold it); the recorded
/// migration versions are deleted; and the tables and the index added by later releases are
/// dropped. The next open must put all of
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
    /// Migration versions the database had recorded before the fixture deleted them: what the
    /// first launch must record again. Counted, not assumed, so the scenario still checks the
    /// right number on a ref with fewer or more migrations than today's.
    package let recordedVersions: Int
    /// The later releases' tables and index the fixture actually dropped (`IF EXISTS`: an older
    /// ref may not have them all): what the first launch must recreate.
    package let droppedObjects: [String]

    /// The smallest `files` that leaves a half-attributed row to repair with the default
    /// `legacyFraction` (rows 5 to 9 of every ten keep an owner): below it, `--phase first`
    /// would pass its repair checks with nothing to repair.
    package static let smallestRepairableCorpus = 6
    /// The most `files` the options accept: well beyond any real database (R02 measured 100k).
    package static let largestCorpus = 1_000_000

    /// What older releases lack and the fixture drops when present.
    private static let laterReleaseObjectNames = [("table", "detached_items"), ("table", "remote_changes"), ("table", "pending_remote_moves"), ("index", "items_root_course_module")]

    package init(files: Int, legacyFraction: Double = 0.5, partialRows: Int = 40, courses: Int = 15) async throws {
        precondition(files >= 0 && courses > 0 && (0...1).contains(legacyFraction) && partialRows >= 0)
        // Which rows keep an owner is decided by their index, so the count is known up front and
        // every stored property is set before the fixture starts creating anything.
        // Decided per ten rows, so a corpus as small as a smoke test's still gets both kinds.
        func hasOwner(_ index: Int) -> Bool { Double(index % 10) >= legacyFraction * 10 }
        // Counted per ten rows rather than by visiting every index, so a huge `--files` is
        // refused by the options rather than exhausting memory here.
        let owned = files / 10 * (0..<10).filter(hasOwner).count + (0..<files % 10).filter(hasOwner).count
        let partial = min(partialRows, owned)
        self.files = files
        self.partialRows = partial
        var recorded = 0
        var dropped: [String] = []
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
            if partial > 0 {
                try raw.execute("PRAGMA ignore_check_constraints = ON; UPDATE items SET module_id = NULL WHERE rowid IN (SELECT rowid FROM items WHERE course_id IS NOT NULL LIMIT \(partial)); PRAGMA ignore_check_constraints = OFF")
            }
            recorded = try raw.count("SELECT count(*) FROM schema_migrations")
            try raw.execute("DELETE FROM schema_migrations")
            for (kind, name) in Self.laterReleaseObjectNames where try raw.count("SELECT count(*) FROM sqlite_master WHERE type = '\(kind)' AND name = '\(name)'") == 1 {
                try raw.execute("DROP \(kind.uppercased()) \(name)")
                dropped.append(name)
            }
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
        recordedVersions = recorded
        droppedObjects = dropped
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

    /// How many of `droppedObjects` exist again and how many versions are recorded: once the
    /// first launch has run, `droppedObjects.count` and `recordedVersions`.
    package func laterReleaseObjects() throws -> (tables: Int, versions: Int) {
        let raw = try RawConnection(url: databaseURL)
        let names = droppedObjects.map { "'\($0)'" }.joined(separator: ", ")
        return (try raw.count("SELECT count(*) FROM sqlite_master WHERE name IN (\(names.isEmpty ? "''" : names))"), try raw.count("SELECT count(*) FROM schema_migrations"))
    }

    /// One measured launch: its open alone, the whole of it, and everything its connection did.
    package struct Launch: Sendable {
        package var open: Duration
        package var total: Duration
        package var written: SyncDatabaseWriteCounters
        /// Ownership backfill and module-override work the launch's connection did; zero today,
        /// reported so a launch that starts backfilling shows up in `compare`.
        package var ownershipBackfill: OwnershipBackfillCounters
        package var moduleOverrideUpdates: Int
        package var fileStore: FileStoreCounters
        package var report: RecoveryReport
    }

    /// One launch's database work, as `BootstrapService.prepare` runs it in the app: open (which
    /// migrates), register the folder, recover. The connection closes when `database` goes away,
    /// so each call is a cold open of the file, as a relaunch is. `open` is the open alone, the
    /// part whose cost the migration decides.
    package func launch() async throws -> Launch {
        let clock = ContinuousClock()
        let start = clock.now
        let database = try SyncDatabase(url: databaseURL)
        let opened = clock.now
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let fileStore = try FileStore(root: root) { _ in }
        let report = try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: fileStore).recover()
        let end = clock.now
        return Launch(
            open: opened - start, total: end - start, written: await database.writeCounters(),
            ownershipBackfill: await database.ownershipBackfillCounters, moduleOverrideUpdates: await database.moduleOverrideUpdateAttempts,
            fileStore: await fileStore.counters(), report: report
        )
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
