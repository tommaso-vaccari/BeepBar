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
public struct RecordingsSeenStore: Sendable {
    public static let fileName = "recordings-seen-v2.sqlite"
    private let directory: @Sendable () throws -> URL
    public let databaseFileName: String
    private let removeFile: @Sendable (URL) throws -> Void
    public init(directory: @escaping @Sendable () throws -> URL, namespace: UUID? = nil) {
        self.init(directory: directory, namespace: namespace, removeFile: Self.unlinkFile)
    }

    /// Test injection changes only file removal, so reset regressions use the real database.
    package init(directory: @escaping @Sendable () throws -> URL, namespace: UUID? = nil, removeFile: @escaping @Sendable (URL) throws -> Void) {
        self.directory = directory
        databaseFileName = namespace.map { "recordings-seen-v2-\($0.uuidString).sqlite" } ?? Self.fileName
        self.removeFile = removeFile
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
        try withDatabase { db in
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
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        try run("PRAGMA synchronous=FULL", [], db: db)
        try run("PRAGMA cache_size=-2048", [], db: db)
        try run("CREATE TABLE IF NOT EXISTS baseline(owner INTEGER, course TEXT, year INTEGER, legacy INTEGER NOT NULL, PRIMARY KEY(owner,course,year)) WITHOUT ROWID", [], db: db)
        try run("CREATE TABLE IF NOT EXISTS seen(owner INTEGER, course TEXT, year INTEGER, id TEXT, PRIMARY KEY(owner,course,year,id)) WITHOUT ROWID", [], db: db)
        try run("CREATE TABLE IF NOT EXISTS legacy_seen(owner INTEGER, id TEXT, PRIMARY KEY(owner,id)) WITHOUT ROWID", [], db: db)
        try run("CREATE TABLE IF NOT EXISTS migrated(owner INTEGER PRIMARY KEY)", [], db: db)
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

    public init(store: RecordingsSeenStore) {
        self.store = store
        beforeRead = {}
        beforeAcknowledge = {}
        afterRead = {}
    }

    /// Gates exercise real actor reentrancy, late results and resets in isolated tests.
    package init(store: RecordingsSeenStore, beforeRead: @escaping @Sendable () async -> Void = {}, beforeAcknowledge: @escaping @Sendable () async -> Void = {}, afterRead: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.beforeRead = beforeRead
        self.beforeAcknowledge = beforeAcknowledge
        self.afterRead = afterRead
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
        try store.acknowledge(owner: owner, key: key, ids: ids, legacy: legacy)
    }

    public nonisolated func invalidate() { validity.invalidate() }

    public func invalidateAndDelete() throws {
        invalidate()
        try store.delete()
    }
}
