import Foundation
import Testing
@testable import BeepbarCore

/// What a launch costs on a large database left by an older release (R02, issue #110).
///
/// Every launch opens `sync.sqlite`, which reruns the whole schema migration inside one write
/// transaction (`SyncDatabase.migrate`), registers the sync folder and runs recovery. On a
/// database from an earlier release this is also where repairs happen: tables and indexes the
/// older release never had are created, and tracked files attributed to a course without a module
/// (or the reverse) lose that half attribution so the next sync's ownership backfill can redo it.
/// These tests pin that the repair runs once and that every later launch writes nothing, on a
/// corpus large enough (15,000 tracked files, half of them without an owning module as older
/// releases left them) for a cost proportional to the database to show. They also print the
/// measured durations, labelled with the platform and build, as the indicative evidence R02 asks
/// for where no Mac is available; the Release arm64 numbers come from `scripts/benchmark.sh startup`.
///
/// The fixture below is a sibling of `LegacyDatabaseFixture` in `BeepbarBenchmarkKit`, kept here on
/// purpose: this target depends only on `BeepbarCore` and also runs on Linux, where the benchmark
/// kit is left out of the manifest. They degrade the database the same way but differ in detail:
/// here legacy rows are chosen per thousand and `partialRows` is taken as given; the kit chooses
/// per ten (so smoke corpora get both kinds), clamps `partialRows` to the owned rows and counts
/// the versions and objects it removed. Only this file builds the v2.0.106 database. A change to
/// how older releases left the database belongs in both.
struct StartupMigrationTests {
    /// A database an older release could have left behind, built through today's schema and then
    /// degraded behind `SyncDatabase`'s back: `files` tracked files, `legacyFraction` of them
    /// without an owning module, `partialRows` of them attributed to a course only (which the
    /// current `CHECK` forbids, so they are written with constraints off, as an old table without
    /// the constraint would hold them), the recorded migration versions removed, and the tables
    /// and index added by later releases dropped.
    private struct LegacyFixture {
        let directory: URL
        let root: URL
        let databaseURL: URL
        let rootID = UUID()
        let files: Int
        let partialRows: Int

        init(files: Int, legacyFraction: Double, partialRows: Int) async throws {
            self.files = files
            self.partialRows = partialRows
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            root = directory.appending(path: "WeBeep", directoryHint: .isDirectory)
            databaseURL = directory.appending(path: "sync.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                let database = try SyncDatabase(url: databaseURL)
                try await database.registerRoot(id: rootID, canonicalPath: root.path)
                for course in 1...15 {
                    try await database.upsertScope(SyncScope(rootID: rootID, courseID: Int64(course), displayName: "Corso \(course)", localFolder: "Corso \(course)", enabled: true))
                }
            }
            let raw = try RawSQLite(url: databaseURL)
            // One transaction: the fixture's own writes are not what is measured, and 15k single
            // commits under `synchronous = FULL` would take minutes.
            try raw.execute("BEGIN")
            for index in 0..<files {
                let course = index % 15 + 1
                let owned = Double(index % 1000) >= legacyFraction * 1000
                let ownership = owned ? "\(course), \(course * 100)" : "NULL, NULL"
                try raw.execute("INSERT INTO items(root_id, remote_id, relative_path, base_sha256, remote_revision, last_seen_at, course_id, module_id) VALUES ('\(rootID.uuidString)', '\(course):\(course * 100):/:\(index).pdf', 'Corso \(course)/\(index).pdf', '\(String(repeating: "a", count: 64))', '1', 0, \(ownership))")
            }
            try raw.execute("COMMIT")
            if partialRows > 0 {
                try raw.execute("PRAGMA ignore_check_constraints = ON; UPDATE items SET module_id = NULL WHERE rowid IN (SELECT rowid FROM items WHERE course_id IS NOT NULL LIMIT \(partialRows)); PRAGMA ignore_check_constraints = OFF")
            }
            try raw.execute("DELETE FROM schema_migrations; DROP TABLE detached_items; DROP TABLE remote_changes; DROP TABLE pending_remote_moves; DROP INDEX items_root_course_module")
        }

        /// The database release v2.0.106 (`0dfa75a`) left, for users who skipped every release
        /// since: its schema statements copied verbatim, so `items` has none of the ownership or
        /// placement columns, no `CHECK` and no ownership index, and versions 1 to 3 are recorded.
        /// `files` tracked files, all without a course or module, as that release stored them.
        init(release2_0_106 files: Int) throws {
            self.files = files
            partialRows = 0
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            root = directory.appending(path: "WeBeep", directoryHint: .isDirectory)
            databaseURL = directory.appending(path: "sync.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let raw = try RawSQLite(url: databaseURL, create: true)
            // As v2.0.106 opened it; a rollback-journal file would add the mode switch's commit.
            try raw.execute("PRAGMA journal_mode = WAL")
            try raw.execute("BEGIN")
            for statement in [
                "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY)",
                "CREATE TABLE IF NOT EXISTS roots (id TEXT PRIMARY KEY, canonical_path TEXT NOT NULL UNIQUE, security_bookmark BLOB, settings_json TEXT NOT NULL DEFAULT '{}')",
                "CREATE TABLE IF NOT EXISTS sync_scopes (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, display_name TEXT NOT NULL, local_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)), auto_sync INTEGER NOT NULL DEFAULT 0 CHECK(auto_sync IN (0, 1)), managed_directory INTEGER NOT NULL DEFAULT 0 CHECK(managed_directory IN (0, 1)), directory_device INTEGER, directory_inode INTEGER, PRIMARY KEY(root_id, course_id), UNIQUE(root_id, local_folder))",
                "CREATE TABLE IF NOT EXISTS remote_observations (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, remote_id TEXT NOT NULL, observed_revision TEXT NOT NULL, observed_sha256 TEXT, relative_path TEXT NOT NULL, size INTEGER NOT NULL, first_seen_at REAL NOT NULL, last_seen_at REAL NOT NULL, last_notified_revision TEXT, PRIMARY KEY(root_id, remote_id))",
                "CREATE TABLE IF NOT EXISTS items (root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, relative_path TEXT NOT NULL, base_sha256 TEXT NOT NULL, remote_revision TEXT NOT NULL, last_seen_at REAL, PRIMARY KEY(root_id, remote_id))",
                "CREATE TABLE IF NOT EXISTS conflicts (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, relative_path TEXT NOT NULL, incoming_path TEXT NOT NULL, base_sha256 TEXT, local_sha256 TEXT, remote_sha256 TEXT NOT NULL, remote_revision TEXT NOT NULL, detected_at REAL NOT NULL, status TEXT NOT NULL CHECK(status IN ('open', 'resolved')))",
                "CREATE TABLE IF NOT EXISTS pending_operations (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, remote_id TEXT NOT NULL, destination_path TEXT NOT NULL, stage_path TEXT NOT NULL, expected_local_kind TEXT NOT NULL DEFAULT 'unknown' CHECK(expected_local_kind IN ('missing', 'present', 'unknown')), expected_local_sha256 TEXT, remote_sha256 TEXT NOT NULL DEFAULT '', remote_revision TEXT NOT NULL DEFAULT '', phase TEXT NOT NULL DEFAULT 'prepared' CHECK(phase IN ('prepared', 'committed')), UNIQUE(root_id, remote_id), UNIQUE(root_id, destination_path))",
                "CREATE TABLE IF NOT EXISTS pending_scope_moves (id TEXT PRIMARY KEY, root_id TEXT NOT NULL REFERENCES roots(id) ON DELETE CASCADE, course_id INTEGER NOT NULL, old_folder TEXT NOT NULL, new_folder TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('prepared')), UNIQUE(root_id, course_id), UNIQUE(root_id, new_folder))",
                "CREATE UNIQUE INDEX IF NOT EXISTS pending_operations_root_remote ON pending_operations(root_id, remote_id)",
                "CREATE UNIQUE INDEX IF NOT EXISTS pending_operations_root_destination ON pending_operations(root_id, destination_path)",
                "CREATE INDEX IF NOT EXISTS conflicts_root_remote_status ON conflicts(root_id, remote_id, status)",
                "INSERT INTO schema_migrations(version) VALUES (1), (2), (3)",
                "INSERT INTO roots(id, canonical_path) VALUES ('\(rootID.uuidString)', '\(root.path)')",
            ] {
                try raw.execute(statement)
            }
            for course in 1...15 {
                try raw.execute("INSERT INTO sync_scopes(root_id, course_id, display_name, local_folder, enabled) VALUES ('\(rootID.uuidString)', \(course), 'Corso \(course)', 'Corso \(course)', 1)")
            }
            for index in 0..<files {
                let course = index % 15 + 1
                try raw.execute("INSERT INTO items(root_id, remote_id, relative_path, base_sha256, remote_revision, last_seen_at) VALUES ('\(rootID.uuidString)', '\(course):\(course * 100):/:\(index).pdf', 'Corso \(course)/\(index).pdf', '\(String(repeating: "a", count: 64))', '1', 0)")
            }
            try raw.execute("COMMIT")
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func partialRowCount() throws -> Int {
            Int(try RawSQLite(url: databaseURL).query("SELECT count(*) FROM items WHERE (course_id IS NULL) != (module_id IS NULL)").first ?? "-1") ?? -1
        }
    }

    /// One launch's database work, as `BootstrapService.prepare` runs it: open (which migrates),
    /// register the folder, recover. The connection closes when `database` goes away, so each
    /// call is a cold open of the file, as a relaunch is.
    private struct Launch {
        let openMilliseconds: Double
        let totalMilliseconds: Double
        let written: SyncDatabaseWriteCounters
        let report: RecoveryReport
    }

    private func launch(_ fixture: LegacyFixture) async throws -> Launch {
        let clock = ContinuousClock()
        let start = clock.now
        let database = try SyncDatabase(url: fixture.databaseURL)
        let opened = clock.now
        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path)
        let report = try await RecoveryCoordinator(rootID: fixture.rootID, database: database, fileStore: try FileStore(root: fixture.root) { _ in }).recover()
        let end = clock.now
        return Launch(openMilliseconds: milliseconds(opened - start), totalMilliseconds: milliseconds(end - start), written: await database.writeCounters(), report: report)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private var platformLabel: String {
#if os(Linux)
        let platform = "Linux"
#else
        let platform = "macOS"
#endif
#if arch(arm64)
        let architecture = "arm64"
#else
        let architecture = "x86_64"
#endif
#if DEBUG
        return "\(platform) \(architecture) debug"
#else
        return "\(platform) \(architecture) release"
#endif
    }

    /// The first launch after updating repairs the legacy database once: the missing tables and
    /// index come back, the half-attributed rows are cleared (exactly those rows change), all in
    /// the migration's single commit, with recovery finding nothing to do. Every launch after that
    /// writes no page and changes no row, with the same two empty commits `LaunchWritesTests` pins
    /// (the migration transaction and the skipped `registerRoot` update), however many tracked
    /// files the database holds. Guards against a repair that keeps rewriting rows it already
    /// fixed, against a migration step that writes on a current database, and against the repair
    /// being dropped (the partial rows would survive the first launch). Durations are printed, not
    /// asserted: a shared runner cannot carry a timing budget.
    @Test func firstLaunchRepairsOnceAndLaterLaunchesWriteNothing() async throws {
        let fixture = try await LegacyFixture(files: 15_000, legacyFraction: 0.5, partialRows: 40)
        defer { fixture.remove() }
        #expect(try fixture.partialRowCount() == 40)

        let first = try await launch(fixture)
        #expect(first.report == RecoveryReport())
        #expect(try fixture.partialRowCount() == 0)
        // The repair's UPDATE is the only statement that touches rows: the versions are
        // re-inserted (7 rows) and the rest is DDL, which `total_changes` does not count.
        #expect(first.written.rowChanges == 40 + 7)
        #expect(first.written.pagesWritten > 0)
        #expect(first.written.commits == 2)
        let raw = try RawSQLite(url: fixture.databaseURL)
        #expect(try raw.query("SELECT count(*) FROM sqlite_master WHERE name IN ('detached_items', 'remote_changes', 'pending_remote_moves', 'items_root_course_module')") == ["4"])
        #expect(try raw.query("SELECT count(*) FROM schema_migrations") == ["7"])
        #expect(try raw.query("SELECT count(*) FROM items WHERE course_id IS NULL") == ["7540"])

        var later: [Launch] = []
        for _ in 0..<3 {
            let launch = try await launch(fixture)
            later.append(launch)
            #expect(launch.report == RecoveryReport())
            #expect(launch.written == SyncDatabaseWriteCounters(rowChanges: 0, commits: 2, pagesWritten: 0))
        }
        #expect(try raw.query("SELECT count(*) FROM items") == ["15000"])

        let steady = later.map(\.openMilliseconds).sorted()
        print("""
        [R02 \(platformLabel)] startup on 15,000 tracked files (50% without module, 40 half-attributed):
          first launch (repair): open+migrate \(String(format: "%.1f", first.openMilliseconds)) ms, with registerRoot+recovery \(String(format: "%.1f", first.totalMilliseconds)) ms, \(first.written.pagesWritten) pages written
          later launches: open+migrate median \(String(format: "%.1f", steady[steady.count / 2])) ms (min \(String(format: "%.1f", steady[0])), max \(String(format: "%.1f", steady[steady.count - 1]))), total median \(String(format: "%.1f", later.map(\.totalMilliseconds).sorted()[later.count / 2])) ms, 0 pages written
        """)
    }

    /// The migration's cost on a current database grows with the tracked files only through the
    /// half-attribution repair, a scan of `items` that finds nothing. Opening an empty database
    /// and one with 15,000 current rows are both printed so the proportional part can be read
    /// off; neither writes anything. Guards against a migration step whose write shows up only on
    /// a populated database (an `UPDATE` without a `WHERE`, a version row re-inserted as a change).
    @Test func openingACurrentDatabaseWritesNothingWhateverItsSize() async throws {
        let empty = try await LegacyFixture(files: 0, legacyFraction: 0, partialRows: 0)
        defer { empty.remove() }
        let populated = try await LegacyFixture(files: 15_000, legacyFraction: 0, partialRows: 0)
        defer { populated.remove() }
        // The first open repairs the degraded fixture; what is measured is the current state.
        _ = try await launch(empty)
        _ = try await launch(populated)

        var emptyOpens: [Double] = []
        var populatedOpens: [Double] = []
        for _ in 0..<5 {
            let emptyLaunch = try await launch(empty)
            let populatedLaunch = try await launch(populated)
            #expect(emptyLaunch.written == SyncDatabaseWriteCounters(rowChanges: 0, commits: 2, pagesWritten: 0))
            #expect(populatedLaunch.written == SyncDatabaseWriteCounters(rowChanges: 0, commits: 2, pagesWritten: 0))
            emptyOpens.append(emptyLaunch.openMilliseconds)
            populatedOpens.append(populatedLaunch.openMilliseconds)
        }
        print("[R02 \(platformLabel)] open+migrate median: empty \(String(format: "%.1f", emptyOpens.sorted()[2])) ms, 15,000 current rows \(String(format: "%.1f", populatedOpens.sorted()[2])) ms")
    }

    /// A user who skipped every release since v2.0.106 opens a database whose `items` predates
    /// module ownership and placements. The first launch adds those columns and the later
    /// releases' tables, index and versions in its single migration commit, without rewriting a
    /// tracked file's row: all 15,000 keep their path and baseline, and stay unattributed for the
    /// next sync's ownership backfill. Every launch after that writes nothing. Guards against an
    /// upgrade step that rewrites `items` (or loses rows) on the way from an old release, and
    /// against one that keeps writing on every launch once upgraded.
    @Test func aDatabaseFromV2_0_106IsUpgradedOnceWithoutRewritingItsRows() async throws {
        let fixture = try LegacyFixture(release2_0_106: 15_000)
        defer { fixture.remove() }

        let first = try await launch(fixture)
        #expect(first.report == RecoveryReport())
        // Only the four versions the old release never recorded are rows; the rest is DDL.
        #expect(first.written.rowChanges == 4)
        #expect(first.written.commits == 2)
        let raw = try RawSQLite(url: fixture.databaseURL)
        let columns = Set(try raw.query("SELECT name FROM pragma_table_info('items')"))
        #expect(columns.isSuperset(of: ["course_id", "module_id", "placement_section", "placement_module", "placement_single"]))
        #expect(try raw.query("SELECT count(*) FROM sqlite_master WHERE name IN ('detached_items', 'remote_changes', 'pending_remote_moves', 'items_root_course_module')") == ["4"])
        #expect(try raw.query("SELECT count(*) FROM schema_migrations") == ["7"])
        #expect(try raw.query("SELECT count(*) FROM items WHERE course_id IS NULL AND module_id IS NULL AND base_sha256 = '\(String(repeating: "a", count: 64))' AND relative_path LIKE 'Corso %/%.pdf'") == ["15000"])

        var later: [Launch] = []
        for _ in 0..<3 {
            let launch = try await launch(fixture)
            later.append(launch)
            #expect(launch.report == RecoveryReport())
            #expect(launch.written == SyncDatabaseWriteCounters(rowChanges: 0, commits: 2, pagesWritten: 0))
        }
        let steady = later.map(\.openMilliseconds).sorted()
        print("[R02 \(platformLabel)] v2.0.106 database with 15,000 tracked files: first launch open+migrate \(String(format: "%.1f", first.openMilliseconds)) ms, \(first.written.pagesWritten) pages written; later launches open+migrate median \(String(format: "%.1f", steady[steady.count / 2])) ms, 0 pages written")
    }
}
