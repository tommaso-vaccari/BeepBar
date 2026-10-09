import Foundation
import Testing
@testable import BeepbarCore

/// The database and filesystem counters behind the benchmark harness (docs/benchmarks.md). A
/// performance PR proves "a run with nothing new writes nothing" or "unchanged files are not
/// hashed" by reading them, so each one must count exactly what its documentation says: a counter
/// that stays at zero would make every such claim pass.
struct WorkCountersTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func scope(_ rootID: UUID, course: Int64 = 1, name: String = "Analisi") -> SyncScope {
        SyncScope(rootID: rootID, courseID: course, displayName: name, localFolder: name, enabled: true)
    }

    /// Inserting a row is one commit, one row change and at least one page. Guards the commit
    /// hook (a hook not installed, or counting into a counter nobody reads, leaves `commits` at 0)
    /// and the `CACHE_WRITE` and `total_changes` readings.
    @Test func insertCountsACommitARowAndPages() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let before = await database.writeCounters()

        try await database.upsertScope(scope(rootID))

        let delta = await database.writeCounters().since(before)
        #expect(delta.commits == 1)
        #expect(delta.rowChanges == 1)
        #expect(delta.pagesWritten > 0)
    }

    /// Reads write nothing by any measure: the baseline a "nothing new" run is compared with.
    @Test func readsCountNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(scope(rootID))
        let before = await database.writeCounters()

        _ = try await database.scopes(rootID: rootID, enabledOnly: true)
        _ = try await database.baselines(rootID: rootID)
        _ = try await database.conflicts(rootID: rootID)
        _ = try await database.remoteChanges(rootID: rootID)

        #expect(await database.writeCounters().since(before) == SyncDatabaseWriteCounters())
    }

    /// An `UPDATE` that sets a row to the values it already has commits and counts a row change
    /// but writes no page: the three measures are distinct, and a fix that drops the rewrite shows
    /// up in `commits` and `rowChanges` even though the WAL didn't grow. Guards against
    /// `pagesWritten` reading something other than pages actually written. (An identical upsert,
    /// `INSERT … ON CONFLICT DO UPDATE`, does write a page: SQLite rewrites the row there.)
    @Test func identicalUpdateCommitsWithoutWritingPages() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(scope(rootID))
        try await database.disableAllScopes(rootID: rootID)
        let before = await database.writeCounters()

        try await database.disableAllScopes(rootID: rootID)

        let delta = await database.writeCounters().since(before)
        #expect(delta.commits == 1)
        #expect(delta.rowChanges == 1)
        #expect(delta.pagesWritten == 0)
    }

    /// A delete that matches no row still commits (an `fsync` with synchronous=FULL) but changes
    /// no row: exactly the kind of hidden write `commits` exists to expose.
    @Test func writeMatchingNoRowCountsOnlyACommit() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let before = await database.writeCounters()

        try await database.deleteRemoteChange(rootID: rootID, id: UUID())

        let delta = await database.writeCounters().since(before)
        #expect(delta.commits == 1)
        #expect(delta.rowChanges == 0)
        #expect(delta.pagesWritten == 0)
    }

    /// Each connection counts only its own writes, so parallel tests and the harness's fixtures
    /// never see each other's work.
    @Test func countersBelongToTheirConnection() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try SyncDatabase(url: root.appending(path: "first.sqlite"))
        let second = try SyncDatabase(url: root.appending(path: "second.sqlite"))
        let secondBefore = await second.writeCounters()

        try await first.registerRoot(id: UUID(), canonicalPath: root.path)

        #expect(await second.writeCounters().since(secondBefore) == SyncDatabaseWriteCounters())
    }

    /// Failed ownership UPDATEs count attempts, while rollback preserves the legacy row.
    @Test func ownershipAttemptsCountFailuresAndStayConnectionLocal() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let first = try SyncDatabase(url: url)
        let second = try SyncDatabase(url: url)
        let rootID = UUID()
        try await first.registerRoot(id: rootID, canonicalPath: root.path)
        try await first.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "legacy", relativePath: try RelativePath("a.txt"), sha256: "hash", remoteRevision: "1"))
        try RawSQLite(url: url).execute("CREATE TRIGGER reject_owner BEFORE UPDATE OF course_id ON items BEGIN SELECT RAISE(ABORT, 'test'); END")
        let before = await first.ownershipBackfillCounters
        let file = RemoteFileCandidate(id: "legacy", courseID: 1, sectionID: 1, moduleID: 10, sectionName: "S", moduleName: "A", filename: "a.txt", remoteFilePath: "/", canonicalPluginPath: "/a", downloadURL: nil, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true)

        await #expect(throws: SyncDatabaseError.self) {
            try await first.backfillModuleOwnership(rootID: rootID, files: [file])
        }
        #expect(await first.ownershipBackfillCounters.since(before) == OwnershipBackfillCounters(transactions: 1, updates: 1))
        #expect(await second.ownershipBackfillCounters == OwnershipBackfillCounters())
        #expect(try await first.baseline(rootID: rootID, remoteID: "legacy")?.courseID == nil)
    }

    /// Hashing a file counts one file and exactly its bytes, across the 1 MiB read chunks, and one
    /// path lookup. Guards `bytesHashed` (which tells one big file read twice from two small ones)
    /// against counting chunks, capacities or only the first read.
    @Test func inspectCountsTheBytesItHashes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = 3 * (1 << 20) + 12_345
        try FileManager.default.createDirectory(at: root.appending(path: "Analisi"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: size).write(to: root.appending(path: "Analisi/lezione.pdf"))
        let store = try FileStore(root: root) { _ in }

        _ = try await store.inspect(try RelativePath("Analisi/lezione.pdf"))

        #expect(await store.counters() == FileStoreCounters(filesHashed: 1, bytesHashed: Int64(size), pathLookups: 1))
    }

    /// Checking that a file exists resolves its path but never reads it: the cheap check a "nothing
    /// new" run is allowed. Guards against `pathLookups` missing calls that don't hash, and against
    /// `filesHashed` counting lookups.
    @Test func existenceCheckCountsALookupButNoHash() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appending(path: "a.txt"))
        let store = try FileStore(root: root) { _ in }

        #expect(try await store.containsRegularFile(try RelativePath("a.txt")))
        #expect(try await store.containsRegularFile(try RelativePath("missing/b.txt")) == false)

        #expect(await store.counters() == FileStoreCounters(filesHashed: 0, bytesHashed: 0, pathLookups: 2))
    }

    /// `since` subtracts field by field, so a measured window excludes everything before it.
    @Test func sinceSubtractsEveryField() {
        #expect(SyncDatabaseWriteCounters(rowChanges: 9, commits: 5, pagesWritten: 7).since(SyncDatabaseWriteCounters(rowChanges: 4, commits: 2, pagesWritten: 3)) == SyncDatabaseWriteCounters(rowChanges: 5, commits: 3, pagesWritten: 4))
        #expect(OwnershipBackfillCounters(transactions: 5, updates: 9).since(OwnershipBackfillCounters(transactions: 2, updates: 4)) == OwnershipBackfillCounters(transactions: 3, updates: 5))
        #expect(FileStoreCounters(filesHashed: 3, bytesHashed: 100, pathLookups: 8).since(FileStoreCounters(filesHashed: 1, bytesHashed: 40, pathLookups: 5)) == FileStoreCounters(filesHashed: 2, bytesHashed: 60, pathLookups: 3))
    }
}
