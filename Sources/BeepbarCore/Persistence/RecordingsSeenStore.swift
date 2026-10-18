import CSQLite
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Exact recording history scoped to the WeBeep account, course and academic year (#106).
/// Only IDs supplied by the current listing are queried: old history stays on disk, never in
/// a process-wide set. No time-based eviction is safe because Recman can publish old lectures.
/// Calls are synchronous primitives owned by RecordingsSeenHistory off the main actor; each
/// call closes its connection. A namespace tombstone makes failed cleanup safe across relaunch.
///
/// The same file also holds per-recording watch progress (`progress` table, same
/// account/course/year/ID key; rules in `RecordingWatchProgress`). It lives here so it is
/// scoped, serialized and removed exactly like seen state: namespace rotation and `delete()` take
/// it with them on disable, disconnect or account change.
/// - The table is created lazily with `CREATE TABLE IF NOT EXISTS`, without a schema version or a
///   migration: an older build opening the file ignores it, and an existing v2 file simply gains
///   it. Nothing is backfilled, because seen state can't tell "opened" from the first-listing
///   baseline, so every lecture starts at 0 %.
/// - No eviction, ever: a row may be the student's manual "done", which must never be dropped.
///   Rows exist only for recordings that reached a player checkpoint that changed something or
///   were ticked, so the table is bounded by the account's archive (one row per recording).
/// - Schema rule for every future build: `progress` may only gain nullable or defaulted columns,
///   never lose, rename or retype one. Writes name their columns and update only the three they
///   own, so an older build keeps working on a newer file and leaves a newer column's value alone.
public struct RecordingsSeenStore: Sendable {
    public static let fileName = "recordings-seen-v2.sqlite"
    private let directory: @Sendable () throws -> URL
    public let databaseFileName: String
    private let removeFile: @Sendable (URL) throws -> Void
    private let probe: Probe?
    public init(directory: @escaping @Sendable () throws -> URL, namespace: UUID? = nil) {
        self.init(directory: directory, namespace: namespace, removeFile: Self.unlinkFile)
    }

    /// Test injection changes only file removal and observation, so reset and write-count
    /// regressions use the real database. `probe` is nil in the app and costs nothing there.
    package init(directory: @escaping @Sendable () throws -> URL, namespace: UUID? = nil, removeFile: @escaping @Sendable (URL) throws -> Void, probe: Probe? = nil) {
        self.directory = directory
        databaseFileName = namespace.map { "recordings-seen-v2-\($0.uuidString).sqlite" } ?? Self.fileName
        self.removeFile = removeFile
        self.probe = probe
    }

    /// What the store's connections did, for tests proving that an unchanged progress event
    /// writes nothing and that a listing read looks up only its own IDs. Counters accumulate over
    /// every connection the store opens while the probe is attached.
    package final class Probe: @unchecked Sendable {
        package struct Counts: Equatable, Sendable {
            /// `sqlite3_total_changes64` summed over closed connections: rows inserted, updated or
            /// deleted, including a rewrite with identical values. DDL is not counted.
            package var rowChanges: Int64 = 0
            /// `BEGIN IMMEDIATE` statements issued, committed or not.
            package var writeTransactions = 0
            /// `progress` rows returned to the store by any query.
            package var progressRowsRead = 0
            /// `SQLITE_STMTSTATUS_FULLSCAN_STEP` of progress lookups: nonzero means a lookup
            /// walked the table instead of seeking its primary key.
            package var progressFullScanSteps = 0
        }
        private let lock = NSLock()
        private var counts = Counts()
        /// Runs inside `applyProgress` between the unlocked first read and `BEGIN IMMEDIATE`, so a
        /// test can change the row through another connection and prove the decision is re-made
        /// under the write lock.
        fileprivate let afterUnlockedRead: (@Sendable () -> Void)?
        package init(afterUnlockedRead: (@Sendable () -> Void)? = nil) { self.afterUnlockedRead = afterUnlockedRead }
        package var current: Counts { lock.withLock { counts } }
        fileprivate func record(_ change: (inout Counts) -> Void) { lock.withLock { change(&counts) } }
    }

    /// unlink never recursively removes a directory unexpectedly replacing a database file.
    private static func unlinkFile(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// v1 did not retain the course of each seen ID. Keep its surviving IDs in a small legacy
    /// table and consult them for migrated courses only; evicted IDs cannot be recovered.
    public struct Legacy: Sendable {
        public let ids: [String]
        public let baselines: [String]
        public init(ids: [String], baselines: [String]) { self.ids = ids; self.baselines = baselines }
    }

    /// nil means this course has no baseline; otherwise returns only seen IDs in `ids`.
    /// A first complete listing creates its baseline and all initial seen IDs atomically.
    public func seen(owner: Int, key: RecmanCourseKey, ids: [String], establishBaseline: Bool, legacy: Legacy) throws -> Set<String>? {
        try withDatabase { db in try seen(owner: owner, key: key, ids: ids, establishBaseline: establishBaseline, legacy: legacy, db: db) }
    }

    private func seen(owner: Int, key: RecmanCourseKey, ids: [String], establishBaseline: Bool, legacy: Legacy, db: OpaquePointer) throws -> Set<String>? {
        try migrate(legacy, owner: owner, db: db)
        let scope = [String(owner), key.courseCode, String(key.academicYear)]
        let baseline = try exists("SELECT 1 FROM baseline WHERE owner=? AND course=? AND year=?", scope, db: db)
        if !baseline && establishBaseline {
            try transaction(db) {
                try run("INSERT INTO baseline VALUES (?,?,?,0)", scope, db: db)
                try insert(ids, scope: scope, db: db)
            }
            return Set(ids)
        }
        guard baseline else { return nil }
        let migrated = try exists("SELECT 1 FROM baseline WHERE owner=? AND course=? AND year=? AND legacy=1", scope, db: db)
        var result = Set<String>()
        // One reusable indexed lookup per current ID; neither historic course contents nor
        // the account's history are materialized. SQLite's page cache is bounded to 2 MiB.
        let statement = try prepare("SELECT 1 FROM seen WHERE owner=? AND course=? AND year=? AND id=?", db: db)
        defer { sqlite3_finalize(statement) }
        let old = migrated ? try prepare("SELECT 1 FROM legacy_seen WHERE owner=? AND id=?", db: db) : nil
        defer { if let old { sqlite3_finalize(old) } }
        for id in ids {
            try bind(scope + [id], to: statement)
            if try hasRow(statement) { result.insert(id); continue }
            if let old {
                try bind([String(owner), id], to: old)
                if try hasRow(old) { result.insert(id) }
            }
        }
        return result
    }

    /// `seen` plus the stored watch progress of the same IDs, read on one connection so a listing
    /// publishes both from the same moment. Progress is returned only for IDs in `ids` that have a
    /// row, through one primary-key seek per ID: neither the course's nor the account's progress is
    /// materialized. A missing ID means untouched (0 %, not done). Progress doesn't depend on the
    /// baseline: `seen` may be nil while progress is still returned.
    public func seenAndProgress(owner: Int, key: RecmanCourseKey, ids: [String], establishBaseline: Bool, legacy: Legacy) throws -> (seen: Set<String>?, progress: [String: RecordingWatchEntry]) {
        try withDatabase { db in
            let seen = try seen(owner: owner, key: key, ids: ids, establishBaseline: establishBaseline, legacy: legacy, db: db)
            var progress: [String: RecordingWatchEntry] = [:]
            let statement = try prepare(Self.progressLookup, db: db)
            defer { finalizeProgress(statement) }
            for id in ids {
                if let row = try readProgress(statement, owner: owner, key: key, id: id) { progress[id] = row.entry }
            }
            return (seen, progress)
        }
    }

    /// Applies one watch-progress event to one recording and reports what is stored afterwards.
    ///
    /// The pure rules (`RecordingWatchProgress.applyCheckpoint` / `setManual`) decide; this only
    /// reads, decides and writes atomically:
    /// - A first read, without a write lock, decides whether anything would change. When nothing
    ///   would (a pause at the same place, a tick on a lecture already done), the call returns
    ///   without opening a write transaction or touching a row: an unchanged checkpoint costs no
    ///   journal and no `fsync`.
    /// - Otherwise the row is read again and the rules applied again inside one `BEGIN IMMEDIATE`
    ///   transaction, and the row is written only if it still changes. Re-deciding under the lock
    ///   keeps the write right even if another connection changed the row in between; in the app
    ///   the serial `RecordingsSeenHistory` actor is the only writer of a namespace.
    /// - A row whose `completed` value this build doesn't know (written by a newer build) reads as
    ///   done and is never rewritten by a checkpoint, so going back to that build loses neither the
    ///   completion nor its kind. Ticking it is a no-op (already done); un-ticking is the student's
    ///   explicit choice and is applied like on any done lecture.
    public func applyProgress(owner: Int, key: RecmanCourseKey, id: String, event: RecordingProgressEvent) throws -> RecordingProgressResult {
        try withDatabase { db in
            let statement = try prepare(Self.progressLookup, db: db)
            defer { finalizeProgress(statement) }
            func decide() throws -> (stored: StoredProgress?, new: RecordingWatchEntry?) {
                let stored = try readProgress(statement, owner: owner, key: key, id: id)
                return (stored, Self.apply(event, to: stored))
            }
            let first = try decide()
            var result = RecordingProgressResult(entry: first.stored?.entry, changed: false)
            guard first.new != nil else { return result }
            probe?.afterUnlockedRead?()
            try transaction(db) {
                let (stored, new) = try decide()
                result = RecordingProgressResult(entry: new ?? stored?.entry, changed: new != nil)
                guard let new else { return }
                try write(new, owner: owner, key: key, id: id, db: db)
            }
            return result
        }
    }

    /// Applies the same watch-progress event to several recordings of one course, in one
    /// connection and at most one `BEGIN IMMEDIATE` transaction (issue #208: "Mark all as
    /// completed" opened a connection and committed a durable transaction per lecture). Returns
    /// one result per element of `ids`, in order.
    ///
    /// Same rules as `applyProgress(owner:key:id:event:)`, per entry: an unlocked first read
    /// decides whether anything would change (nothing: no transaction, no journal), and inside the
    /// transaction every row is read and decided again and written only if it still changes.
    ///
    /// All or nothing: a failure on any row rolls back the rows written before it, so a failed
    /// batch leaves every recording exactly as it was and a retry redoes the whole set. A
    /// repeated ID is decided after the earlier occurrence's write, so it reports no change.
    public func applyProgress(owner: Int, key: RecmanCourseKey, ids: [String], event: RecordingProgressEvent) throws -> [RecordingProgressResult] {
        guard !ids.isEmpty else { return [] }
        return try withDatabase { db in
            let statement = try prepare(Self.progressLookup, db: db)
            defer { finalizeProgress(statement) }
            let results = try ids.map { id -> RecordingProgressResult in
                let stored = try readProgress(statement, owner: owner, key: key, id: id)
                return RecordingProgressResult(entry: stored?.entry, changed: Self.apply(event, to: stored) != nil)
            }
            guard results.contains(where: \.changed) else { return results }
            probe?.afterUnlockedRead?()
            var decided = results
            try transaction(db) {
                for (index, id) in ids.enumerated() {
                    let stored = try readProgress(statement, owner: owner, key: key, id: id)
                    let new = Self.apply(event, to: stored)
                    decided[index] = RecordingProgressResult(entry: new ?? stored?.entry, changed: new != nil)
                    if let new { try write(new, owner: owner, key: key, id: id, db: db) }
                }
            }
            return decided
        }
    }

    /// One stored row as this build understands it. `unknownCompletion` marks a non-null
    /// `completed` value other than the known raw values: `entry` then reads as done (`.manual`,
    /// the kind no checkpoint can undo) and checkpoints must leave the row untouched.
    private struct StoredProgress {
        let entry: RecordingWatchEntry
        let unknownCompletion: Bool
    }

    /// The pure decision for one event, or nil when the stored row must stay as it is.
    private static func apply(_ event: RecordingProgressEvent, to stored: StoredProgress?) -> RecordingWatchEntry? {
        switch event {
        case .checkpoint(let session, let closes):
            if stored?.unknownCompletion == true { return nil }
            return RecordingWatchProgress.applyCheckpoint(stored?.entry, session: session, closes: closes)
        case .manual(let done):
            return RecordingWatchProgress.setManual(stored?.entry, done: done)
        }
    }

    /// Primary-key seek: the whole key is bound, so SQLite never walks the table. The owner must
    /// stay in the key: without it one account would read another's progress.
    private static let progressLookup = "SELECT furthest, completed, blocked FROM progress WHERE owner=? AND course=? AND year=? AND id=?"

    private func readProgress(_ statement: OpaquePointer, owner: Int, key: RecmanCourseKey, id: String) throws -> StoredProgress? {
        try bind([String(owner), key.courseCode, String(key.academicYear), id], to: statement)
        guard try hasRow(statement) else { return nil }
        probe?.record { $0.progressRowsRead += 1 }
        // `furthest` is NOT NULL, but a damaged value (out of range, or text read as 0) is clamped
        // by the entry's initializer rather than trusted.
        let furthest = sqlite3_column_double(statement, 0)
        var unknown = false
        var completed: RecordingWatchEntry.Completion?
        if sqlite3_column_type(statement, 1) != SQLITE_NULL {
            completed = RecordingWatchEntry.Completion(rawValue: Int(sqlite3_column_int64(statement, 1)))
            if completed == nil {
                completed = .manual
                unknown = true
            }
        }
        let blocked = sqlite3_column_int64(statement, 2) != 0
        // Release the statement's read lock now: an unlocked first read must not keep blocking
        // other connections until the next bind.
        sqlite3_reset(statement)
        return StoredProgress(entry: RecordingWatchEntry(furthest: furthest, completed: completed, autoCompletionBlocked: blocked), unknownCompletion: unknown)
    }

    /// Typed bindings: `furthest` must be stored as REAL and `completed` as NULL or an integer.
    /// Named columns and an upsert that sets only this build's three columns, never
    /// `INSERT OR REPLACE` with positional values: those fail once a newer build adds a column
    /// ("7 values for 8 columns") and REPLACE would reset that column on an existing row.
    private func write(_ entry: RecordingWatchEntry, owner: Int, key: RecmanCourseKey, id: String, db: OpaquePointer) throws {
        let upsert = try prepare("""
            INSERT INTO progress(owner, course, year, id, furthest, completed, blocked) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(owner, course, year, id) DO UPDATE SET furthest=excluded.furthest, completed=excluded.completed, blocked=excluded.blocked
            """, db: db)
        defer { sqlite3_finalize(upsert) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var ok = sqlite3_bind_int64(upsert, 1, Int64(owner)) == SQLITE_OK
        ok = ok && key.courseCode.withCString { sqlite3_bind_text(upsert, 2, $0, -1, transient) } == SQLITE_OK
        ok = ok && sqlite3_bind_int64(upsert, 3, Int64(key.academicYear)) == SQLITE_OK
        ok = ok && id.withCString { sqlite3_bind_text(upsert, 4, $0, -1, transient) } == SQLITE_OK
        ok = ok && sqlite3_bind_double(upsert, 5, entry.furthest) == SQLITE_OK
        if let completed = entry.completed {
            ok = ok && sqlite3_bind_int64(upsert, 6, Int64(completed.rawValue)) == SQLITE_OK
        } else {
            ok = ok && sqlite3_bind_null(upsert, 6) == SQLITE_OK
        }
        ok = ok && sqlite3_bind_int64(upsert, 7, entry.autoCompletionBlocked ? 1 : 0) == SQLITE_OK
        guard ok else { throw SyncDatabaseError.statement }
        _ = try hasRow(upsert)
    }

    private func finalizeProgress(_ statement: OpaquePointer) {
        if let probe {
            let scans = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
            probe.record { $0.progressFullScanSteps += scans }
        }
        sqlite3_finalize(statement)
    }

    /// Adds IDs without changing a course's baseline. No rows are evicted across courses.
    public func acknowledge(owner: Int, key: RecmanCourseKey, ids: [String], legacy: Legacy) throws {
        guard !ids.isEmpty else { return }
        try withDatabase { db in
            try migrate(legacy, owner: owner, db: db)
            try transaction(db) { try insert(ids, scope: [String(owner), key.courseCode, String(key.academicYear)], db: db) }
        }
    }

    /// Remove this namespace. Its worker must invalidate pending operations first; a controller
    /// tombstone has already rotated the active namespace before this cleanup runs.
    public func delete() throws {
        let folder = try directory()
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let url = folder.appendingPathComponent(databaseFileName + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try removeFile(url) }
        }
    }

    /// Retry obsolete tombstoned files on actual history work, never with an idle timer.
    /// A failed deletion does not prevent the new namespace from storing its own baseline.
    public func removeObsoleteFiles() throws {
        let folder = try directory()
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let base = name.replacingOccurrences(of: #"-(journal|wal|shm)$"#, with: "", options: .regularExpression)
            guard base != databaseFileName,
                  base == Self.fileName || base.range(of: #"^recordings-seen-v2-[0-9A-Fa-f-]{36}\.sqlite$"#, options: .regularExpression) != nil else { continue }
            try removeFile(folder.appendingPathComponent(name))
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let folder = try directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // SQLite NOFOLLOW checks every path component. Darwin realpath is required here:
        // Foundation normalizes /private/var back to symlinked /var on macOS. Resolve only
        // the existing parent, preserving NOFOLLOW for the final history file itself.
        guard let resolved = realpath(folder.path, nil) else { throw SyncDatabaseError.invalidPath }
        let path = String(cString: resolved) + "/" + databaseFileName
        free(resolved)
        // Create privately before SQLite opens it; never chmod a newly exposed history file.
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        if fd >= 0 { close(fd) } else if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw SyncDatabaseError.open
        }
        defer {
            if let probe { let changes = sqlite3_total_changes64(db); probe.record { $0.rowChanges += changes } }
            sqlite3_close(db)
        }
        sqlite3_busy_timeout(db, 2_000)
        try run("PRAGMA synchronous=FULL", [], db: db)
        try run("PRAGMA cache_size=-2048", [], db: db)
        try run("CREATE TABLE IF NOT EXISTS baseline(owner INTEGER, course TEXT, year INTEGER, legacy INTEGER NOT NULL, PRIMARY KEY(owner,course,year)) WITHOUT ROWID", [], db: db)
        try run("CREATE TABLE IF NOT EXISTS seen(owner INTEGER, course TEXT, year INTEGER, id TEXT, PRIMARY KEY(owner,course,year,id)) WITHOUT ROWID", [], db: db)
        try run("CREATE TABLE IF NOT EXISTS legacy_seen(owner INTEGER, id TEXT, PRIMARY KEY(owner,id)) WITHOUT ROWID", [], db: db)
        try run("CREATE TABLE IF NOT EXISTS migrated(owner INTEGER PRIMARY KEY)", [], db: db)
        // Watch progress (see the type's comment). `completed` holds
        // `RecordingWatchEntry.Completion` raw values or NULL; `blocked` is 0 or 1.
        try run("CREATE TABLE IF NOT EXISTS progress(owner INTEGER, course TEXT, year INTEGER, id TEXT, furthest REAL NOT NULL, completed INTEGER, blocked INTEGER NOT NULL, PRIMARY KEY(owner,course,year,id)) WITHOUT ROWID", [], db: db)
        return try body(db)
    }

    private func migrate(_ legacy: Legacy, owner: Int, db: OpaquePointer) throws {
        guard try !exists("SELECT 1 FROM migrated WHERE owner=?", [String(owner)], db: db) else { return }
        try transaction(db) {
            for baseline in legacy.baselines {
                let parts = baseline.split(separator: "-")
                guard parts.count == 2, let year = Int(parts[1]), let key = RecmanCourseKey(courseCode: String(parts[0]), academicYear: year) else { continue }
                try run("INSERT OR IGNORE INTO baseline VALUES (?,?,?,1)", [String(owner), key.courseCode, String(key.academicYear)], db: db)
            }
            for id in Set(legacy.ids) { try run("INSERT OR IGNORE INTO legacy_seen VALUES (?,?)", [String(owner), id], db: db) }
            try run("INSERT INTO migrated VALUES (?)", [String(owner)], db: db)
        }
    }

    private func insert(_ ids: [String], scope: [String], db: OpaquePointer) throws {
        let statement = try prepare("INSERT OR IGNORE INTO seen VALUES (?,?,?,?)", db: db)
        defer { sqlite3_finalize(statement) }
        for id in ids { try bind(scope + [id], to: statement); _ = try hasRow(statement) }
    }
    private func transaction(_ db: OpaquePointer, _ body: () throws -> Void) throws {
        probe?.record { $0.writeTransactions += 1 }
        try run("BEGIN IMMEDIATE", [], db: db)
        do { try body(); try run("COMMIT", [], db: db) }
        catch { try? run("ROLLBACK", [], db: db); throw error }
    }
    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SyncDatabaseError.statement }
        return statement
    }
    private func bind(_ values: [String], to statement: OpaquePointer) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (index, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw SyncDatabaseError.statement }
        }
    }
    private func hasRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) { case SQLITE_ROW: return true; case SQLITE_DONE: return false; default: throw SyncDatabaseError.execution }
    }
    private func exists(_ sql: String, _ values: [String], db: OpaquePointer) throws -> Bool {
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        return try hasRow(statement)
    }
    private func run(_ sql: String, _ values: [String], db: OpaquePointer) throws {
        _ = try exists(sql, values, db: db)
    }
}

/// One change to a recording's watch progress, applied by `RecordingsSeenStore.applyProgress`.
public enum RecordingProgressEvent: Equatable, Sendable {
    /// A player checkpoint. `session` already includes the checkpoint's own position; `closes`
    /// comes from `RecordingWatchProgress.checkpointCloses` and is the only way playback completes.
    case checkpoint(session: RecordingWatchSession, closes: Bool)
    /// The student ticked (`done: true`) or un-ticked the lecture.
    case manual(done: Bool)
}

/// What a progress event left in the store.
public struct RecordingProgressResult: Equatable, Sendable {
    /// The stored entry after the event; nil when the recording still has no row (untouched).
    public let entry: RecordingWatchEntry?
    /// Whether this event wrote a row. False means nothing was written and nothing needs
    /// publishing: the caller can skip every follow-up (UI, summary, acknowledgement).
    public let changed: Bool
    public init(entry: RecordingWatchEntry?, changed: Bool) {
        self.entry = entry
        self.changed = changed
    }
}

/// A listing's seen IDs and watch progress, read together so they are published together.
public struct RecordingsHistorySnapshot: Equatable, Sendable {
    /// Seen IDs among the requested ones (the first listing makes all of them seen).
    public let seen: Set<String>
    /// Stored progress of the requested IDs that have any; a missing ID is untouched.
    public let progress: [String: RecordingWatchEntry]
    public init(seen: Set<String>, progress: [String: RecordingWatchEntry]) {
        self.seen = seen
        self.progress = progress
    }
}

/// Synchronous, cheap invalidation also rejects actor calls queued after a reset. The lock is
/// never held during disk work, so closing a page/account cannot wait for SQLite on the main.
private final class RecordingHistoryValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func invalidate() { lock.withLock { active = false } }
    var isActive: Bool { lock.withLock { active } }
}

/// Serial executor for durable history operations. No SQLite call runs on the main actor.
/// After invalidation, a queued old request cannot recreate a reset namespace. The UUID namespace
/// selected by the controller prevents reuse even if removal itself fails (e.g. permissions).
public actor RecordingsSeenHistory {
    private let store: RecordingsSeenStore
    private nonisolated let validity = RecordingHistoryValidity()
    private let beforeRead: @Sendable () async -> Void
    private let beforeAcknowledge: @Sendable () async -> Void
    private let afterRead: @Sendable () async -> Void
    private let beforeProgress: @Sendable () async -> Void
    private let afterProgress: @Sendable () async -> Void

    public init(store: RecordingsSeenStore) {
        self.store = store
        beforeRead = {}
        beforeAcknowledge = {}
        afterRead = {}
        beforeProgress = {}
        afterProgress = {}
    }

    /// Gates exercise real actor reentrancy, late results and resets in isolated tests.
    /// `afterProgress` runs after a progress commit, before the final validity check.
    package init(store: RecordingsSeenStore, beforeRead: @escaping @Sendable () async -> Void = {}, beforeAcknowledge: @escaping @Sendable () async -> Void = {}, afterRead: @escaping @Sendable () async -> Void = {}, beforeProgress: @escaping @Sendable () async -> Void = {}, afterProgress: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.beforeRead = beforeRead
        self.beforeAcknowledge = beforeAcknowledge
        self.afterRead = afterRead
        self.beforeProgress = beforeProgress
        self.afterProgress = afterProgress
    }

    public func seen(owner: Int, key: RecmanCourseKey, ids: [String], legacy: RecordingsSeenStore.Legacy) async throws -> Set<String> {
        await beforeRead()
        guard validity.isActive, !Task.isCancelled else { throw CancellationError() }
        try? store.removeObsoleteFiles()
        // This synchronous actor segment has no await between identity validation and commit.
        let seen = try store.seen(owner: owner, key: key, ids: ids, establishBaseline: true, legacy: legacy) ?? []
        await afterRead()
        guard validity.isActive, !Task.isCancelled else { throw CancellationError() }
        return seen
    }

    public func acknowledge(owner: Int, key: RecmanCourseKey, ids: [String], legacy: RecordingsSeenStore.Legacy) async throws {
        await beforeAcknowledge()
        guard validity.isActive, !Task.isCancelled else { throw CancellationError() }
        try? store.removeObsoleteFiles()
        // A store error caused by a concurrent reset is a cancellation, not a storage failure.
        do { try store.acknowledge(owner: owner, key: key, ids: ids, legacy: legacy) }
        catch { throw validity.isActive ? error : CancellationError() }
    }

    /// `seen` plus the watch progress of the same IDs (see `RecordingsSeenStore.seenAndProgress`),
    /// with the same baseline rule and the same validity checks before and after the read, so a
    /// result that returns after a reset is never published.
    ///
    /// Snapshots are not ordered against `applyProgress` or `acknowledge` commits: one taken
    /// before a commit can return after it. The caller must keep a per-course revision bumped on
    /// each commit and requery when it changed during the read, or it would publish older progress
    /// over a newer committed entry.
    public func seenAndProgress(owner: Int, key: RecmanCourseKey, ids: [String], legacy: RecordingsSeenStore.Legacy) async throws -> RecordingsHistorySnapshot {
        await beforeRead()
        guard validity.isActive, !Task.isCancelled else { throw CancellationError() }
        try? store.removeObsoleteFiles()
        let read = try store.seenAndProgress(owner: owner, key: key, ids: ids, establishBaseline: true, legacy: legacy)
        await afterRead()
        guard validity.isActive, !Task.isCancelled else { throw CancellationError() }
        return RecordingsHistorySnapshot(seen: read.seen ?? [], progress: read.progress)
    }

    /// Applies one watch-progress event (see `RecordingsSeenStore.applyProgress`) on this serial
    /// worker. Like `acknowledge`, an invalidated namespace refuses the event before touching the
    /// disk: a checkpoint or tick queued before a logout, account change or turn-off can't
    /// recreate the file the reset is removing. There is no await between that check and the
    /// commit. A write that committed while a reset was being requested is reported as cancelled
    /// so the caller doesn't publish it; the reset's `invalidateAndDelete`, queued on this actor,
    /// then removes it with the rest of the namespace.
    ///
    /// Contract for the caller (the app's recordings controller):
    /// - `Task.isCancelled` also refuses the event. Final checkpoints and ticks must not run inside
    ///   a task that closing the page or tearing the player down cancels, or they are lost.
    /// - `CancellationError` (before or after the commit) means "discard silently": no banner, no
    ///   revert of what the UI shows, no retry. The identity it belonged to is gone.
    /// - A store error raised while a reset is in progress (e.g. the file vanishing under the
    ///   connection) is reported as `CancellationError` too, never as a storage failure.
    /// - Results of separate calls are not ordered against `seenAndProgress` snapshots: a listing
    ///   read that started before a commit may return after it. Bump a per-course revision on
    ///   every commit and requery a snapshot that raced one, as `acknowledge` already requires.
    public func applyProgress(owner: Int, key: RecmanCourseKey, id: String, event: RecordingProgressEvent) async throws -> RecordingProgressResult {
        await beforeProgress()
        guard validity.isActive, !Task.isCancelled else { throw CancellationError() }
        try? store.removeObsoleteFiles()
        let result: RecordingProgressResult
        do { result = try store.applyProgress(owner: owner, key: key, id: id, event: event) }
        catch { throw validity.isActive ? error : CancellationError() }
        await afterProgress()
        // Deliberately no `Task.isCancelled` here: a committed write is durable and is reported
        // as long as its namespace is still the active one.
        guard validity.isActive else { throw CancellationError() }
        return result
    }

    /// `applyProgress` for one event over several recordings of one course, in one store
    /// transaction (`RecordingsSeenStore.applyProgress(owner:key:ids:event:)`, issue #208), with
    /// exactly the same validity contract as the single-recording call: refused before the disk
    /// once invalidated or cancelled, a commit racing a reset reported as `CancellationError`,
    /// and all or nothing on failure.
    public func applyProgress(owner: Int, key: RecmanCourseKey, ids: [String], event: RecordingProgressEvent) async throws -> [RecordingProgressResult] {
        await beforeProgress()
        guard validity.isActive, !Task.isCancelled else { throw CancellationError() }
        try? store.removeObsoleteFiles()
        let results: [RecordingProgressResult]
        do { results = try store.applyProgress(owner: owner, key: key, ids: ids, event: event) }
        catch { throw validity.isActive ? error : CancellationError() }
        await afterProgress()
        guard validity.isActive else { throw CancellationError() }
        return results
    }

    public nonisolated func invalidate() { validity.invalidate() }

    public func removeObsoleteFiles() throws {
        try store.removeObsoleteFiles()
    }

    public func invalidateAndDelete() throws {
        invalidate()
        try store.delete()
    }
}
