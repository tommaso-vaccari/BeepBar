import CSQLite
import Foundation
import Testing
@testable import BeepbarCore

/// Watch progress stored in the seen-history database: exact scoping, no write without a change,
/// package A's rules applied atomically, compatibility with existing v2 files and newer builds,
/// removal with the namespace and refusal of late writes after a reset. Isolated temporary
/// folders only; never the user's database.
struct RecordingsWatchProgressStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("progress-store-\(UUID().uuidString)")
    private let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private let empty = RecordingsSeenStore.Legacy(ids: [], baselines: [])
    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    private func store(probe: RecordingsSeenStore.Probe? = nil, namespace: UUID? = nil) -> RecordingsSeenStore {
        let folder = folder
        return RecordingsSeenStore(directory: { folder }, namespace: namespace, removeFile: { url in
            if unlink(url.path) != 0, errno != ENOENT { throw POSIXError(.EIO) }
        }, probe: probe)
    }
    private var databaseURL: URL { folder.appendingPathComponent(RecordingsSeenStore.fileName) }

    private func session(_ fractions: Double...) -> RecordingWatchSession {
        var session = RecordingWatchSession(start: fractions.first)
        for fraction in fractions.dropFirst() { session.observe(fraction) }
        return session
    }
    private func progress(_ store: RecordingsSeenStore, owner: Int = 42, key: RecmanCourseKey? = nil, ids: [String]) throws -> [String: RecordingWatchEntry] {
        try store.seenAndProgress(owner: owner, key: key ?? self.key, ids: ids, establishBaseline: false, legacy: empty).progress
    }

    /// Runs raw SQL against the fixture database, for rows an older or newer build would write.
    private func execute(_ sql: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SyncDatabaseError.execution
        }
    }
    /// The raw stored columns of one row, rendered as text (`nil` column → "NULL").
    private func rawRow(owner: Int = 42, id: String) throws -> [String]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SyncDatabaseError.open }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT furthest, completed, blocked FROM progress WHERE owner=\(owner) AND id='\(id)'", -1, &statement, nil) == SQLITE_OK else { throw SyncDatabaseError.statement }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (0..<3).map { column in
            sqlite3_column_type(statement, column) == SQLITE_NULL ? "NULL" : String(cString: sqlite3_column_text(statement, column))
        }
    }

    /// Proves: the same recording ID in two accounts, two courses and two academic years keeps
    /// six independent entries, both when read and when an event decides from the stored row; a
    /// read returns only requested IDs.
    /// Guards against: progress leaking between accounts or courses (mutation: drop `owner=?` from
    /// the progress lookup, or bind another scope; the owner-43 tick then sees owner 42's row).
    @Test func progressIsScopedByOwnerCourseAndYear() throws {
        defer { cleanUp() }
        let store = store()
        let other = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!
        let year = RecmanCourseKey(courseCode: key.courseCode, academicYear: 2025)!
        _ = try store.applyProgress(owner: 42, key: key, id: "x", event: .manual(done: true))
        _ = try store.applyProgress(owner: 42, key: other, id: "x", event: .checkpoint(session: session(0.5), closes: false))
        _ = try store.applyProgress(owner: 42, key: year, id: "x", event: .checkpoint(session: session(0.25), closes: false))
        // Owner 43's tick must not be a no-op because owner 42's row is already done.
        #expect(try store.applyProgress(owner: 43, key: key, id: "x", event: .manual(done: true)).changed)
        _ = try store.applyProgress(owner: 43, key: key, id: "x", event: .manual(done: false))
        _ = try store.applyProgress(owner: 43, key: other, id: "x", event: .checkpoint(session: session(0.75), closes: false))

        #expect(try progress(store, ids: ["x", "unknown"]) == ["x": RecordingWatchEntry(completed: .manual)])
        #expect(try progress(store, key: other, ids: ["x"]) == ["x": RecordingWatchEntry(furthest: 0.5)])
        #expect(try progress(store, key: year, ids: ["x"]) == ["x": RecordingWatchEntry(furthest: 0.25)])
        #expect(try progress(store, owner: 43, ids: ["x"]) == ["x": RecordingWatchEntry(autoCompletionBlocked: true)])
        #expect(try progress(store, owner: 43, key: other, ids: ["x"]) == ["x": RecordingWatchEntry(furthest: 0.75)])
        #expect(try progress(store, owner: 43, key: year, ids: ["x"]).isEmpty)
        #expect(try progress(store, owner: 44, ids: ["x"]).isEmpty)
        #expect(try progress(store, ids: []).isEmpty)
    }

    /// Proves: an event that changes nothing (pause at the same place, a lower position, a tick on
    /// a done lecture, an un-tick on one not done) writes no row and opens no write transaction,
    /// while a real change writes exactly one row.
    /// Guards against: a disk write (journal + fsync) on every pause (mutations: drop the early
    /// return before `BEGIN IMMEDIATE` → `writeTransactions` red; upsert even when the rules say
    /// nil → `rowChanges` red).
    @Test func unchangedEventWritesNothing() throws {
        defer { cleanUp() }
        let probe = RecordingsSeenStore.Probe()
        let store = store(probe: probe)
        let first = try store.applyProgress(owner: 42, key: key, id: "a", event: .checkpoint(session: session(0, 0.4), closes: false))
        #expect(first == RecordingProgressResult(entry: RecordingWatchEntry(furthest: 0.4), changed: true))
        let afterFirst = probe.current
        #expect(afterFirst.rowChanges == 1)
        #expect(afterFirst.writeTransactions == 1)

        let unchanged: [RecordingProgressEvent] = [
            .checkpoint(session: session(0, 0.4), closes: false),
            .checkpoint(session: session(0.1), closes: false),
            .checkpoint(session: session(0.4), closes: true),
            .manual(done: false),
        ]
        for event in unchanged {
            let result = try store.applyProgress(owner: 42, key: key, id: "a", event: event)
            #expect(result == RecordingProgressResult(entry: RecordingWatchEntry(furthest: 0.4), changed: false))
        }
        // An untouched recording that stays untouched reports no row and writes nothing either.
        #expect(try store.applyProgress(owner: 42, key: key, id: "b", event: .manual(done: false)) == RecordingProgressResult(entry: nil, changed: false))
        #expect(try store.applyProgress(owner: 42, key: key, id: "b", event: .checkpoint(session: RecordingWatchSession(start: nil), closes: true)) == RecordingProgressResult(entry: nil, changed: false))
        #expect(probe.current.rowChanges == afterFirst.rowChanges)
        #expect(probe.current.writeTransactions == afterFirst.writeTransactions)

        _ = try store.applyProgress(owner: 42, key: key, id: "a", event: .manual(done: true))
        let afterTick = probe.current
        #expect(afterTick.rowChanges == afterFirst.rowChanges + 1)
        #expect(try store.applyProgress(owner: 42, key: key, id: "a", event: .manual(done: true)).changed == false)
        #expect(probe.current.rowChanges == afterTick.rowChanges)
        #expect(probe.current.writeTransactions == afterTick.writeTransactions)
    }

    /// Proves: a pause checkpoint then a close checkpoint commit exactly package A's entries
    /// (furthest raised, then completed by playback at the close), and both survive a new store
    /// instance (a relaunch).
    /// Guards against: the store deciding differently from `applyCheckpoint`, losing `completed`
    /// on write, or storing `furthest` with lost precision (mutations: bind `completed` as NULL →
    /// red; pass `closes: false` to the rules → red).
    @Test func pauseThenCloseCommitsPackageAResults() throws {
        defer { cleanUp() }
        let store = store()
        var live = RecordingWatchSession(start: 0)
        live.observe(0.437)
        let paused = try store.applyProgress(owner: 42, key: key, id: "a", event: .checkpoint(session: live, closes: false))
        let expectedPause = RecordingWatchProgress.applyCheckpoint(nil, session: live, closes: false)
        #expect(paused == RecordingProgressResult(entry: expectedPause, changed: true))
        #expect(expectedPause == RecordingWatchEntry(furthest: 0.437))

        live.observe(0.93)
        let closed = try store.applyProgress(owner: 42, key: key, id: "a", event: .checkpoint(session: live, closes: true))
        let expectedClose = RecordingWatchProgress.applyCheckpoint(expectedPause, session: live, closes: true)
        #expect(closed == RecordingProgressResult(entry: expectedClose, changed: true))
        #expect(expectedClose == RecordingWatchEntry(furthest: 0.93, completed: .playback))

        #expect(try progress(self.store(), ids: ["a"]) == ["a": RecordingWatchEntry(furthest: 0.93, completed: .playback)])
        #expect(try rawRow(id: "a") == ["0.93", "1", "0"])
    }

    /// Proves: tick → un-tick → tick round-trips through disk, the un-tick's block flag is
    /// persisted and read back by a new store instance, and the furthest point is kept.
    /// Guards against: losing the un-tick block on relaunch, which would let a lecture resumed at
    /// 92 % silently complete again at close (mutation: bind `blocked` as 0 → red).
    @Test func manualTickUntickRoundTripSurvivesReopen() throws {
        defer { cleanUp() }
        _ = try store().applyProgress(owner: 42, key: key, id: "a", event: .checkpoint(session: session(0, 0.6), closes: false))
        #expect(try store().applyProgress(owner: 42, key: key, id: "a", event: .manual(done: true)).entry == RecordingWatchEntry(furthest: 0.6, completed: .manual))
        #expect(try progress(store(), ids: ["a"])["a"] == RecordingWatchEntry(furthest: 0.6, completed: .manual))
        #expect(try store().applyProgress(owner: 42, key: key, id: "a", event: .manual(done: false)).entry == RecordingWatchEntry(furthest: 0.6, autoCompletionBlocked: true))
        #expect(try progress(store(), ids: ["a"])["a"] == RecordingWatchEntry(furthest: 0.6, autoCompletionBlocked: true))
        #expect(try rawRow(id: "a") == ["0.6", "NULL", "1"])
        #expect(try store().applyProgress(owner: 42, key: key, id: "a", event: .manual(done: true)).entry == RecordingWatchEntry(furthest: 0.6, completed: .manual))
        #expect(try rawRow(id: "a") == ["0.6", "2", "0"])
    }

    /// Proves: a sequence of tick, un-tick and checkpoints applied one after another produces, at
    /// every step, exactly what folding package A's functions over the same events produces,
    /// including the un-tick rule (a close resumed past the threshold doesn't complete; a close
    /// after a crossing in one session does).
    /// Guards against: the store reading a stale row or applying the wrong rule for an event
    /// (mutations: decide from `nil` instead of the stored row → red; route `.manual(false)` to
    /// `setManual(done: true)` → red).
    @Test func sequentialEventsMatchPackageAFold() throws {
        defer { cleanUp() }
        let store = store()
        var resumedPastThreshold = RecordingWatchSession(start: 0.92)
        resumedPastThreshold.observe(0.95)
        var crossing = RecordingWatchSession(start: 0.3)
        crossing.observe(0.91)
        var crossedThenReset = crossing
        crossedThenReset.resetCrossing()
        let events: [RecordingProgressEvent] = [
            .checkpoint(session: session(0, 0.5), closes: false),
            .manual(done: true),
            .checkpoint(session: session(0.5, 0.7), closes: true),
            .manual(done: false),
            .checkpoint(session: resumedPastThreshold, closes: true),
            .checkpoint(session: crossedThenReset, closes: true),
            .checkpoint(session: crossing, closes: false),
            .checkpoint(session: crossing, closes: true),
            .manual(done: false),
            .manual(done: true),
        ]
        var expected: RecordingWatchEntry?
        for event in events {
            let next: RecordingWatchEntry?
            switch event {
            case .checkpoint(let session, let closes): next = RecordingWatchProgress.applyCheckpoint(expected, session: session, closes: closes)
            case .manual(let done): next = RecordingWatchProgress.setManual(expected, done: done)
            }
            expected = next ?? expected
            let result = try store.applyProgress(owner: 42, key: key, id: "a", event: event)
            #expect(result == RecordingProgressResult(entry: expected, changed: next != nil), "after \(event)")
            #expect(try progress(store, ids: ["a"])["a"] == expected, "after \(event)")
        }
        // The un-tick block held against the resumed close; only the crossing completed it.
        #expect(expected == RecordingWatchEntry(furthest: 0.95, completed: .manual))
    }

    /// Proves: an existing v2 file written by the previous build (only baseline/seen/legacy/
    /// migrated tables) keeps its seen state, gains the `progress` table on first use, and both
    /// `seen` and the combined read keep working; every recording starts at 0 % (no row).
    /// Guards against: first launch after updating failing to read history or to save progress
    /// (mutation: remove the `CREATE TABLE IF NOT EXISTS progress` → red).
    @Test func existingV2FileGainsProgressTable() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try execute("""
            CREATE TABLE baseline(owner INTEGER, course TEXT, year INTEGER, legacy INTEGER NOT NULL, PRIMARY KEY(owner,course,year)) WITHOUT ROWID;
            CREATE TABLE seen(owner INTEGER, course TEXT, year INTEGER, id TEXT, PRIMARY KEY(owner,course,year,id)) WITHOUT ROWID;
            CREATE TABLE legacy_seen(owner INTEGER, id TEXT, PRIMARY KEY(owner,id)) WITHOUT ROWID;
            CREATE TABLE migrated(owner INTEGER PRIMARY KEY);
            INSERT INTO migrated VALUES (42);
            INSERT INTO baseline VALUES (42,'058167',2026,0);
            INSERT INTO seen VALUES (42,'058167',2026,'old');
            """)
        let store = store()
        #expect(try store.seen(owner: 42, key: key, ids: ["old", "new"], establishBaseline: true, legacy: empty) == ["old"])
        let read = try store.seenAndProgress(owner: 42, key: key, ids: ["old", "new"], establishBaseline: true, legacy: empty)
        #expect(read.seen == ["old"])
        #expect(read.progress.isEmpty)
        #expect(try store.applyProgress(owner: 42, key: key, id: "old", event: .manual(done: true)).changed)
        #expect(try store.seen(owner: 42, key: key, ids: ["old", "new"], establishBaseline: true, legacy: empty) == ["old"])
        #expect(try progress(store, ids: ["old", "new"]) == ["old": RecordingWatchEntry(completed: .manual)])
    }

    /// Proves: `delete()` (what namespace rotation runs on disable, disconnect or account change)
    /// removes progress with seen state; a later read of the same namespace finds none.
    /// Guards against: a student's progress surviving logout and reappearing for the next account
    /// (mutation, in a disposable copy: skip the main database file in `delete()` → red).
    @Test func deleteRemovesProgress() throws {
        defer { cleanUp() }
        let store = store()
        _ = try store.applyProgress(owner: 42, key: key, id: "a", event: .manual(done: true))
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        try store.delete()
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(try progress(store, ids: ["a"]).isEmpty)
    }

    /// Proves: a row whose `completed` is a value this build doesn't know (a newer build's new
    /// completion kind) reads as done, checkpoints leave it byte-for-byte untouched (even one that
    /// would raise furthest), a tick is a no-op, and an out-of-range stored furthest is clamped.
    /// The explicit un-tick is applied (documented choice).
    /// Guards against: downgrading silently undoing a completion (mutations: map an unknown value
    /// to nil → red; drop the `unknownCompletion` check for checkpoints → raw row rewritten, red).
    @Test func unknownCompletionReadsDoneAndIsNotRewritten() throws {
        defer { cleanUp() }
        let store = store()
        _ = try progress(store, ids: [])
        try execute("INSERT INTO progress VALUES (42,'058167',2026,'future',0.4,7,0); INSERT INTO progress VALUES (42,'058167',2026,'damaged',3.5,NULL,0)")
        let read = try progress(store, ids: ["future", "damaged"])
        #expect(read["future"]?.isCompleted == true)
        #expect(read["future"]?.furthest == 0.4)
        #expect(read["damaged"] == RecordingWatchEntry(furthest: 1))

        for event: RecordingProgressEvent in [.checkpoint(session: session(0.2, 0.99), closes: true), .checkpoint(session: session(0.99), closes: false), .manual(done: true)] {
            #expect(try store.applyProgress(owner: 42, key: key, id: "future", event: event).changed == false)
        }
        #expect(try rawRow(id: "future") == ["0.4", "7", "0"])

        #expect(try store.applyProgress(owner: 42, key: key, id: "future", event: .manual(done: false)) == RecordingProgressResult(entry: RecordingWatchEntry(furthest: 0.4, autoCompletionBlocked: true), changed: true))
        #expect(try rawRow(id: "future") == ["0.4", "NULL", "1"])
    }

    /// Proves: reading progress for a 10,000-ID listing seeks each ID by primary key and returns
    /// only the rows of those IDs in this scope: 5,000 rows of another course and 5,000 of
    /// another account are never read, and no lookup walks the table.
    /// Guards against: materializing a course's or the account's progress on every listing
    /// (mutation: write `owner+0=CAST(? AS INTEGER)` in the lookup, which keeps results right but
    /// disables the key seek → full-scan steps red; selecting the whole course and filtering in
    /// memory → rows-read red).
    @Test func largeListingReadSeeksPerID() throws {
        defer { cleanUp() }
        let probe = RecordingsSeenStore.Probe()
        let store = store(probe: probe)
        _ = try progress(store, ids: [])
        var sql = "BEGIN;"
        for index in 0..<5_000 {
            sql += "INSERT INTO progress VALUES (42,'052499',2026,'id\(index)',0.5,NULL,0);"
            sql += "INSERT INTO progress VALUES (43,'058167',2026,'id\(index)',0.5,NULL,0);"
        }
        sql += "INSERT INTO progress VALUES (42,'058167',2026,'id7',0.1,NULL,0);"
        sql += "INSERT INTO progress VALUES (42,'058167',2026,'id9999',0.2,2,0);"
        sql += "INSERT INTO progress VALUES (42,'058167',2026,'notListed',0.3,NULL,0);"
        sql += "COMMIT;"
        try execute(sql)
        let before = probe.current
        let ids = (0..<10_000).map { "id\($0)" }
        let read = try store.seenAndProgress(owner: 42, key: key, ids: ids, establishBaseline: true, legacy: empty)
        #expect(read.seen?.count == 10_000)
        #expect(read.progress == ["id7": RecordingWatchEntry(furthest: 0.1), "id9999": RecordingWatchEntry(furthest: 0.2, completed: .manual)])
        #expect(probe.current.progressRowsRead - before.progressRowsRead == 2)
        #expect(probe.current.progressFullScanSteps == 0)
    }
}

/// The actor's validity discipline for progress, mirroring the acknowledgement reset gates.
struct RecordingsWatchProgressHistoryTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("progress-history-\(UUID().uuidString)")
    private let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private let empty = RecordingsSeenStore.Legacy(ids: [], baselines: [])
    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    private var store: RecordingsSeenStore { let folder = folder; return .init { folder } }
    private var databaseURL: URL { folder.appendingPathComponent(RecordingsSeenStore.fileName) }

    /// Proves: once a history is invalidated (reset requested), `applyProgress` and
    /// `seenAndProgress` refuse with `CancellationError` before touching the disk, so not even
    /// the database file is created.
    /// Guards against: a checkpoint queued before logout writing into the abandoned namespace
    /// (mutation: drop the validity guard at the start of `applyProgress` → file created, red).
    @Test func invalidatedHistoryRefusesProgress() async throws {
        defer { cleanUp() }
        let history = RecordingsSeenHistory(store: store)
        history.invalidate()
        await #expect(throws: CancellationError.self) {
            try await history.applyProgress(owner: 42, key: key, id: "a", event: .manual(done: true))
        }
        await #expect(throws: CancellationError.self) {
            try await history.seenAndProgress(owner: 42, key: key, ids: ["a"], legacy: empty)
        }
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    }

    /// Proves: a progress write already queued on the actor when a reset deletes the namespace
    /// is refused after the reset, and the deleted file isn't recreated with its row.
    /// Guards against: a late tick or close checkpoint resurrecting a removed account's progress
    /// (mutation: drop the validity guard after `beforeProgress` → file and row exist, red).
    @Test func lateProgressAfterResetDoesNotRecreateState() async throws {
        defer { cleanUp() }
        let gate = Gate()
        let history = RecordingsSeenHistory(store: store, beforeProgress: { await gate.wait() })
        _ = try store.seenAndProgress(owner: 42, key: key, ids: ["a"], establishBaseline: true, legacy: empty)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        let key = key
        let late = Task { try await history.applyProgress(owner: 42, key: key, id: "a", event: .manual(done: true)) }
        await gate.waitUntilEntered()
        try await history.invalidateAndDelete()
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        gate.open()
        await #expect(throws: CancellationError.self) { try await late.value }
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(try store.seenAndProgress(owner: 42, key: key, ids: ["a"], establishBaseline: false, legacy: empty).progress.isEmpty)
    }

    /// Proves: on a valid history the actor applies the event and returns the committed entry,
    /// and the combined read returns seen IDs and progress together.
    /// Guards against: the actor wrapper dropping the result or reading another scope.
    @Test func validHistoryAppliesAndReadsTogether() async throws {
        defer { cleanUp() }
        let history = RecordingsSeenHistory(store: store)
        let first = try await history.seenAndProgress(owner: 42, key: key, ids: ["a", "b"], legacy: empty)
        #expect(first == RecordingsHistorySnapshot(seen: ["a", "b"], progress: [:]))
        let result = try await history.applyProgress(owner: 42, key: key, id: "b", event: .manual(done: true))
        #expect(result == RecordingProgressResult(entry: RecordingWatchEntry(completed: .manual), changed: true))
        let second = try await history.seenAndProgress(owner: 42, key: key, ids: ["a", "b", "c"], legacy: empty)
        #expect(second == RecordingsHistorySnapshot(seen: ["a", "b"], progress: ["b": RecordingWatchEntry(completed: .manual)]))
    }
}

/// A one-shot gate: the gated operation announces it has arrived, then waits to be opened.
private final class Gate: @unchecked Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()
    func wait() async {
        entered.continuation.yield()
        for await _ in release.stream { break }
    }
    func waitUntilEntered() async {
        for await _ in entered.stream { break }
    }
    func open() { release.continuation.yield() }
}
