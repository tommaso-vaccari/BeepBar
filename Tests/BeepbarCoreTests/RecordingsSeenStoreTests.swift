import CSQLite
import Foundation
import Testing
@testable import BeepbarCore

/// Isolated history fixtures: exact identity, bounded queries, transaction recovery and reset.
struct RecordingsSeenStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seen-store-\(UUID().uuidString)")
    private let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private var store: RecordingsSeenStore { let folder = folder; return .init { folder } }
    private let empty = RecordingsSeenStore.Legacy(ids: [], baselines: [])
    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// Same ID in another course/year/account is unrelated; deleting another course from
    /// selection must not destroy its history. Query result includes only supplied IDs.
    @Test func scopesAndOnlyRequestedIDs() throws {
        defer { cleanUp() }
        let many = (0..<10_000).map { "id\($0)" }
        #expect(try store.seen(owner: 42, key: key, ids: many, establishBaseline: true, legacy: empty)?.count == 10_000)
        #expect(try store.seen(owner: 42, key: key, ids: ["id0", "new"], establishBaseline: false, legacy: empty) == ["id0"])
        let other = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!
        let year = RecmanCourseKey(courseCode: key.courseCode, academicYear: 2025)!
        #expect(try store.seen(owner: 43, key: key, ids: ["id0"], establishBaseline: false, legacy: empty) == nil)
        #expect(try store.seen(owner: 42, key: other, ids: ["id0"], establishBaseline: false, legacy: empty) == nil)
        #expect(try store.seen(owner: 42, key: year, ids: ["id0"], establishBaseline: false, legacy: empty) == nil)
        // Empty first listing remains a real baseline: later arrivals must be New.
        #expect(try store.seen(owner: 42, key: other, ids: [], establishBaseline: true, legacy: empty) == [])
        #expect(try store.seen(owner: 42, key: other, ids: ["id0"], establishBaseline: true, legacy: empty) == [])
        try store.acknowledge(owner: 42, key: other, ids: ["id0", "id0"], legacy: empty)
        #expect(try store.seen(owner: 42, key: other, ids: ["id0"], establishBaseline: false, legacy: empty) == ["id0"])
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(RecordingsSeenStore.fileName).path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: folder.path))[.posixPermissions] as? Int == 0o700)
        try store.delete()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(RecordingsSeenStore.fileName).path))
        #expect(try store.seen(owner: 42, key: key, ids: ["id0"], establishBaseline: false, legacy: empty) == nil)
    }

    /// A write failing midway must roll back both the new baseline and its seen IDs.
    /// Retrying then starts from a complete baseline instead of classifying half as New.
    @Test func baselineAndIDsRollbackTogether() throws {
        defer { cleanUp() }
        #expect(try store.seen(owner: 42, key: key, ids: [], establishBaseline: false, legacy: empty) == nil)
        var db: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent(RecordingsSeenStore.fileName).path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TRIGGER fail_seen BEFORE INSERT ON seen WHEN NEW.id='fail' BEGIN SELECT RAISE(ABORT, 'fixture'); END", nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { try store.seen(owner: 42, key: key, ids: ["a", "fail"], establishBaseline: true, legacy: empty) }
        #expect(try store.seen(owner: 42, key: key, ids: ["a"], establishBaseline: false, legacy: empty) == nil)
        #expect(sqlite3_exec(db, "DROP TRIGGER fail_seen", nil, nil, nil) == SQLITE_OK)
        #expect(try store.seen(owner: 42, key: key, ids: ["a", "fail"], establishBaseline: true, legacy: empty) == ["a", "fail"])
    }

    /// Cleanup must not recursively delete local files if the expected database path is
    /// unexpectedly a directory. Reset can tombstone it; removal reports the collision.
    @Test func cleanupDoesNotRecursivelyDeleteUnexpectedDatabaseDirectory() throws {
        defer { cleanUp() }
        let collision = folder.appendingPathComponent(RecordingsSeenStore.fileName)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let sentinel = collision.appendingPathComponent("local.fixture")
        try Data("preserve".utf8).write(to: sentinel)
        #expect(throws: (any Error).self) { try store.delete() }
        #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
    }

    /// An acknowledgement before the first listing must not turn that scope into a baseline.
    /// Legacy survivor matching is limited to migrated courses, not fresh course baselines.
    @Test func openingBeforeListingAndMigrationAreDistinct() throws {
        defer { cleanUp() }
        let legacy = RecordingsSeenStore.Legacy(ids: ["survivor"], baselines: ["058167-2026", "malformed"])
        #expect(try store.seen(owner: 42, key: key, ids: ["survivor", "lost"], establishBaseline: true, legacy: legacy) == ["survivor"])
        let other = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!
        try store.acknowledge(owner: 42, key: other, ids: ["opened"], legacy: empty)
        #expect(try store.seen(owner: 42, key: other, ids: ["opened"], establishBaseline: false, legacy: empty) == nil)
        #expect(try store.seen(owner: 42, key: other, ids: ["opened"], establishBaseline: true, legacy: empty) == ["opened"])
        #expect(try store.seen(owner: 42, key: other, ids: ["survivor"], establishBaseline: false, legacy: empty) == [])
        #expect(try store.seen(owner: 42, key: key, ids: ["survivor", "lost"], establishBaseline: false, legacy: empty) == ["survivor"])
    }
}
