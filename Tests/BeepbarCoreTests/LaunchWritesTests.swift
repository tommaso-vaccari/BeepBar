import Foundation
import Testing
@testable import BeepbarCore

/// Launching BeepBar on a database that already knows its sync folder writes nothing to it.
///
/// Every launch opens `sync.sqlite`, registers the sync folder again and runs recovery, almost
/// always with nothing new to record. `registerRoot` used to rewrite the folder's row anyway:
/// SQLite rewrites any row an upsert matches, so each launch appended a WAL frame and, under
/// `synchronous = FULL`, waited for an `fsync`. These tests pin both halves: an unchanged folder
/// writes no page, and a real change (another path, a bookmark) still reaches the row.
struct LaunchWritesTests {
    private struct Fixture {
        let directory: URL
        let root: URL
        let databaseURL: URL
        let rootID = UUID()

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            root = directory.appending(path: "WeBeep", directoryHint: .isDirectory)
            databaseURL = directory.appending(path: "sync.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        /// What the folder's row holds now, read through a separate connection.
        func storedRow() throws -> (path: String, bookmark: String) {
            let raw = try RawSQLite(url: databaseURL)
            let path = try raw.query("SELECT canonical_path FROM roots WHERE id = '\(rootID.uuidString)'")
            let bookmark = try raw.query("SELECT quote(security_bookmark) FROM roots WHERE id = '\(rootID.uuidString)'")
            guard path.count == 1, bookmark.count == 1 else { throw RawSQLite.Failure(message: "expected one row, got \(path.count)") }
            return (path[0], bookmark[0])
        }
    }

    /// The launch sequence (open, `registerRoot`, recovery) on a database from an earlier launch
    /// writes no page. Opening still commits its migration transaction, which is empty and costs
    /// neither a frame nor an `fsync`. Guards against any step of a launch with nothing to record
    /// writing to disk, the `registerRoot` rewrite first of all.
    @Test func relaunchingWithAKnownFolderWritesNoPage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        do {
            let firstLaunch = try SyncDatabase(url: fixture.databaseURL)
            try await firstLaunch.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path)
            for course in 1...3 {
                try await firstLaunch.upsertScope(SyncScope(rootID: fixture.rootID, courseID: Int64(course), displayName: "Corso \(course)", localFolder: "Corso \(course)", enabled: true))
            }
        }

        let database = try SyncDatabase(url: fixture.databaseURL)
        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path)
        let report = try await RecoveryCoordinator(rootID: fixture.rootID, database: database, fileStore: try FileStore(root: fixture.root) { _ in }).recover()

        #expect(report == RecoveryReport())
        let written = await database.writeCounters()
        #expect(written.pagesWritten == 0)
        #expect(written.rowChanges == 0)
    }

    /// Registering the same folder again, with or without a stored bookmark, changes no row and
    /// writes no page. The bookmark case guards the comparison on a non-NULL blob; the NULL case,
    /// which is what the app passes today, guards against `!=`, under which NULL never equals NULL.
    @Test(arguments: [nil, Data([0xB0, 0x0C])])
    func registeringTheSameFolderAgainWritesNothing(bookmark: Data?) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let database = try SyncDatabase(url: fixture.databaseURL)
        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path, securityBookmark: bookmark)
        let before = await database.writeCounters()

        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path, securityBookmark: bookmark)

        let delta = await database.writeCounters().since(before)
        #expect(delta.pagesWritten == 0)
        #expect(delta.rowChanges == 0)
    }

    /// The same folder id at another path (the folder moved or was chosen again elsewhere) still
    /// updates the row. Guards against a condition that skips every conflicting upsert.
    @Test func aNewPathForTheSameFolderIsStored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let database = try SyncDatabase(url: fixture.databaseURL)
        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path)
        let moved = fixture.directory.appending(path: "Università", directoryHint: .isDirectory).path

        try await database.registerRoot(id: fixture.rootID, canonicalPath: moved)

        #expect(try await database.rootID(canonicalPath: moved) == fixture.rootID)
        #expect(try await database.rootID(canonicalPath: fixture.root.path) == nil)
    }

    /// A bookmark added, replaced or removed on the same path still reaches the row. Guards
    /// against a condition that only compares the path, and against `!=`, which treats a change
    /// from or to NULL as no change.
    @Test func aChangedBookmarkIsStored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let database = try SyncDatabase(url: fixture.databaseURL)
        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path)

        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path, securityBookmark: Data([0xB0, 0x0C]))
        #expect(try fixture.storedRow().bookmark == "X'B00C'")

        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path, securityBookmark: Data([0xCA, 0xFE]))
        #expect(try fixture.storedRow().bookmark == "X'CAFE'")

        try await database.registerRoot(id: fixture.rootID, canonicalPath: fixture.root.path)
        #expect(try fixture.storedRow() == (fixture.root.path, "NULL"))
    }
}
