import Foundation
import CryptoKit
import Testing
import SQLite3
@testable import BeepbarCore
@testable import BeepbarApp

struct SyncFinalizationTests {
    /// Restoring a valid summary publishes every detail without writing the timestamp or JSON again.
    @Test @MainActor func restoredSummaryDoesNotPersistAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = CountingDefaults(suiteName: suite)!
        let summary = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 123), added: 1, updated: 2, unchanged: 3, preservedLocal: 4, conflicts: 0, failures: 0)
        let key = "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString
        let bytes = try JSONEncoder().encode(summary)
        defaults.set(bytes, forKey: key)
        defaults.resetWrites()
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
        defaults.resetWrites()
        await controller.restorePersistedSyncStateForTesting()
        #expect(controller.syncState == .synced(summary))
        #expect(defaults.writes.isEmpty)
        #expect(defaults.data(forKey: key) == bytes)
    }

    /// Corrupt summaries fall back safely; timestamp-only installs migrate once, preserving old data.
    @Test(arguments: [false, true]) @MainActor func legacySummaryMigratesOnlyOnce(_ corrupt: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = CountingDefaults(suiteName: suite)!
        let timestampKey = "io.github.tvaccari.beepbar.last-successful-reconciliation.v1." + rootID.uuidString
        let summaryKey = "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString
        defaults.set(123.0, forKey: timestampKey)
        if corrupt { defaults.set(Data("invalid".utf8), forKey: summaryKey) }
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
        defaults.resetWrites()
        await controller.restorePersistedSyncStateForTesting()
        #expect(controller.lastSyncSummary?.completedAt == Date(timeIntervalSince1970: 123))
        #expect(defaults.writes == [timestampKey, summaryKey])
        defaults.resetWrites()
        await controller.restorePersistedSyncStateForTesting()
        #expect(defaults.writes.isEmpty)
    }

    /// A missing or corrupt summary without a legacy timestamp is not a successful reconciliation.
    @Test(arguments: [false, true]) @MainActor func missingSuccessfulStateDoesNotWrite(_ corrupt: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = CountingDefaults(suiteName: suite)!
        if corrupt { defaults.set(Data("invalid".utf8), forKey: "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString) }
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
        defaults.resetWrites()
        await controller.restorePersistedSyncStateForTesting()
        #expect(controller.syncState == .readyUnchecked)
        #expect(defaults.writes.isEmpty)
    }

    /// A newly completed sync persists all details, so the next launch has the same result.
    @Test @MainActor func completedSyncPersistsSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = CountingDefaults(suiteName: suite)!
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
        let operation = UUID()
        controller.setOperationForTesting(operation)
        let item = SyncedItem(id: "new", name: "new.pdf", kind: .added)
        let course = CourseSyncCount(courseID: 1, courseFolder: "Course", added: 1, updated: 0, items: [item])
        await controller.completeSyncForTesting(operation, summary: SyncProgress(completed: 1, total: 1, added: 1, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0, perCourse: [course]))
        let bytes = try #require(defaults.data(forKey: "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString))
        let summary = try JSONDecoder().decode(SyncCompletionSummary.self, from: bytes)
        #expect(summary == controller.lastSyncSummary)
        #expect(summary.perCourse == [course])
        #expect(defaults.double(forKey: "io.github.tvaccari.beepbar.last-successful-reconciliation.v1." + rootID.uuidString) == summary.completedAt.timeIntervalSince1970)
    }

    /// A decode finishing after a newer result, sign-out, root change or sync must not publish/save.
    @Test(arguments: ["sync", "signout", "root", "root-roundtrip", "replacement", "cancel"]) @MainActor
    func delayedSummaryCannotReplaceCurrentState(_ action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = CountingDefaults(suiteName: suite)!
        let old = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 123), added: 1, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)
        defaults.set(try JSONEncoder().encode(old), forKey: "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        controller.setBeforeRestoredSummaryPublicationForTesting {
            started.continuation.yield()
            for await _ in release.stream { break }
        }
        let restore = Task { await controller.restorePersistedSyncStateForTesting() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        switch action {
        case "sync": controller.setOperationForTesting(UUID()); controller.setSyncStateForTesting(.syncing)
        case "signout": controller.setDisconnectedForTesting()
        case "root": controller.setRootIDForTesting(UUID()); controller.setSyncStateForTesting(.needsFolder)
        case "root-roundtrip": controller.setRootIDForTesting(UUID()); controller.setRootIDForTesting(rootID)
        case "cancel": restore.cancel()
        default:
            let newer = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 456), added: 2, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)
            controller.setSyncStateForTesting(.synced(newer))
        }
        let expected = controller.syncState
        defaults.resetWrites()
        release.continuation.yield()
        await restore.value
        #expect(controller.syncState == expected)
        #expect(defaults.writes.isEmpty)
    }

    /// Two syncs in a row, each with a new successful result, then a third result published
    /// directly: as each returns, both keys already hold it, and the next launch shows the newest
    /// (R01, #109). The encode
    /// moved off the main actor; this guards what must not move with it. Fails if the save becomes
    /// a write that lands after the publication (fire-and-forget), if the encoded bytes are
    /// dropped, or if the newer result does not replace the older one, which the next launch would
    /// then show as the last sync.
    @Test @MainActor func newestCompletedResultIsSavedWithItsPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = CountingDefaults(suiteName: suite)!
        let summaryKey = "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString
        let timestampKey = "io.github.tvaccari.beepbar.last-successful-reconciliation.v1." + rootID.uuidString
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
        // A large result, then a small one: a background writer would finish the larger one last.
        for details in [2000, 3] {
            let progress = Self.syntheticProgress(details: details, courses: 10)
            let operation = UUID()
            controller.setOperationForTesting(operation)
            defaults.resetWrites()
            await controller.completeSyncForTesting(operation, summary: progress)
            let published = try #require(controller.lastSyncSummary)
            #expect(controller.syncState == .synced(published))
            #expect(published.perCourse == progress.perCourse)
            // Each key written once, the time first; the sync also saves unrelated keys.
            #expect(defaults.writes.filter { [timestampKey, summaryKey].contains($0) } == [timestampKey, summaryKey], "\(defaults.writes)")
            let bytes = try #require(defaults.data(forKey: summaryKey))
            #expect(try JSONDecoder().decode(SyncCompletionSummary.self, from: bytes) == published)
            #expect(defaults.double(forKey: timestampKey) == published.completedAt.timeIntervalSince1970)
        }
        // The same turn, with no suspension to let a deferred write catch up: once the result is
        // published, both keys already hold it. Fails if the save moves into a task.
        let direct = await EncodedSyncSummary.encode(Self.syntheticSummary(details: 3, courses: 1, completedAt: Date(timeIntervalSince1970: 456)))
        defaults.resetWrites()
        controller.setSyncStateForTesting(synced: direct)
        #expect(controller.syncState == .synced(direct.summary))
        #expect(defaults.writes == [timestampKey, summaryKey])
        #expect(defaults.data(forKey: summaryKey) == direct.data)
        #expect(defaults.double(forKey: timestampKey) == 456)
        let newest = controller.lastSyncSummary
        // The next launch: a new controller on a second handle of the same suite.
        let relaunched = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: try #require(UserDefaults(suiteName: suite)))
        await relaunched.restorePersistedSyncStateForTesting()
        #expect(relaunched.lastSyncSummary == newest)
        #expect(relaunched.lastSyncSummary?.completedAt == Date(timeIntervalSince1970: 456))
    }

    /// A sync's new result is encoded off the main thread (R01, #109): the encode of 15,000 file
    /// details takes longer than a frame. Fails if the completion path goes back to encoding
    /// inside the main-actor turn (`setSyncState(.synced)`), or if `EncodedSyncSummary.encode`
    /// runs on the main actor.
    @Test @MainActor func newResultIsEncodedOffTheMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: MemoryCountingDefaults.isolated())
        let operation = UUID()
        controller.setOperationForTesting(operation)
        await controller.completeSyncForTesting(operation, summary: Self.syntheticProgress(details: 50, courses: 3))
        #expect(controller.lastSyncSummary?.added == 50)
        #expect(controller.summaryEncodedOnMainThreadForTesting == false)
    }

    /// A sync cancelled, or replaced by a newer operation, while its result is being encoded
    /// publishes nothing and saves nothing: the previous result stays, whole, for the next launch
    /// (R01, #109). Cancelling is what "Esci" does before waiting for the sync. Signing out and
    /// choosing another folder are refused while a sync is active (`signOut` and the folder
    /// picker check `isSyncActive`), so these are the two ways a sync loses its operation here.
    /// Fails if the new result is saved before the operation's guard, or if the guard stops
    /// covering the time spent encoding.
    @Test(arguments: ["cancel", "superseded"]) @MainActor
    func syncCancelledDuringTheEncodeKeepsThePreviousResult(_ invalidation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = UUID()
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = CountingDefaults(suiteName: suite)!
        let summaryKey = "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString
        let timestampKey = "io.github.tvaccari.beepbar.last-successful-reconciliation.v1." + rootID.uuidString
        let previous = Self.syntheticSummary(details: 4, courses: 2, completedAt: Date(timeIntervalSince1970: 123))
        let previousBytes = try JSONEncoder().encode(previous)
        defaults.set(123.0, forKey: timestampKey)
        defaults.set(previousBytes, forKey: summaryKey)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
        let operation = UUID()
        controller.setOperationForTesting(operation)
        // The hook runs after the encode and before the operation's guard.
        let encoded = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        controller.setBeforeReconciliationStateForTesting {
            encoded.continuation.yield()
            for await _ in resume.stream { break }
        }
        defaults.resetWrites()
        let completion = Task { await controller.completeSyncForTesting(operation, summary: Self.syntheticProgress(details: 2000, courses: 10)) }
        controller.setOperationForTesting(operation, task: completion)
        var started = encoded.stream.makeAsyncIterator()
        _ = await started.next()
        // Set when the encode finished: proves the encode ran before the hook, so before the guard.
        #expect(controller.summaryEncodedOnMainThreadForTesting == false)
        if invalidation == "cancel" {
            controller.cancelSynchronization()
        } else {
            controller.setOperationForTesting(UUID())
            controller.setSyncStateForTesting(.syncing)
        }
        resume.continuation.yield()
        await completion.value
        #expect(controller.syncState == (invalidation == "cancel" ? .readyUnchecked : .syncing))
        #expect(defaults.writes.isEmpty)
        #expect(defaults.data(forKey: summaryKey) == previousBytes)
        #expect(defaults.double(forKey: timestampKey) == 123)
        let relaunched = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: try #require(UserDefaults(suiteName: suite)))
        await relaunched.restorePersistedSyncStateForTesting()
        #expect(relaunched.lastSyncSummary == previous)
    }

    /// On-demand Release measurement of the save of a sync's new result (R01, #109), with
    /// synthetic details and a throwaway suite in a temporary folder (docs/benchmarks.md,
    /// "Persisted Activity summary save"). Per sample, each with its own `completedAt` as every
    /// real sync has, so no write repeats identical bytes:
    /// - `inline_turn`: `setSyncState(.synced)`, the main-actor turn that encodes and writes. This
    ///   was the completion path before R01 and stays the legacy-migration path;
    /// - `encode` and `writes`: its two parts alone;
    /// - `off_main_encode`: `EncodedSyncSummary.encode`, awaited from the main actor;
    /// - `turn`: `setSyncState(synced:)`, the main-actor turn of the completion path since R01,
    ///   which publishes and writes bytes already encoded.
    /// `details=0` has no course entries, as a sync with nothing new; it is the frequent case.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEEPBAR_PERSIST_BENCHMARK"] == "1")) @MainActor
    func benchmarkSummaryPersist() async throws {
        let runs = 5
        for details in [0, 1000, 5000, 15000] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let rootID = UUID()
            let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
            defer { removeTestDefaults(suite) }
            let defaults = CountingDefaults(suiteName: suite)!
            let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
            let summaryKey = "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString
            let timestampKey = "io.github.tvaccari.beepbar.last-successful-reconciliation.v1." + rootID.uuidString
            let courses = details == 0 ? 0 : 10
            var samples: [String: [Double]] = [:]
            var bytes = 0
            /// Validity, outside the timed windows: two writes, holding every detail.
            func check(_ summary: SyncCompletionSummary) throws {
                #expect(defaults.writes == [timestampKey, summaryKey])
                let saved = try #require(defaults.data(forKey: summaryKey))
                #expect(try JSONDecoder().decode(SyncCompletionSummary.self, from: saved) == summary)
                #expect(controller.lastSyncSummary == summary)
                bytes = saved.count
            }
            // One warm-up, then `runs` samples.
            for run in 0...runs {
                let base = Double(run * 3 + 1)
                var timings: [String: Double] = [:]
                let inline = Self.syntheticSummary(details: details, courses: courses, completedAt: Date(timeIntervalSince1970: base))
                defaults.resetWrites()
                var start = ContinuousClock.now
                controller.setSyncStateForTesting(.synced(inline))
                timings["inline_turn"] = Self.milliseconds(ContinuousClock.now - start)
                try check(inline)

                let parts = Self.syntheticSummary(details: details, courses: courses, completedAt: Date(timeIntervalSince1970: base + 1))
                start = ContinuousClock.now
                let data = try JSONEncoder().encode(parts)
                let encodeEnd = ContinuousClock.now
                defaults.set(parts.completedAt.timeIntervalSince1970, forKey: timestampKey)
                defaults.set(data, forKey: summaryKey)
                timings["encode"] = Self.milliseconds(encodeEnd - start)
                timings["writes"] = Self.milliseconds(ContinuousClock.now - encodeEnd)

                let summary = Self.syntheticSummary(details: details, courses: courses, completedAt: Date(timeIntervalSince1970: base + 2))
                start = ContinuousClock.now
                let encoded = await EncodedSyncSummary.encode(summary)
                timings["off_main_encode"] = Self.milliseconds(ContinuousClock.now - start)
                #expect(!encoded.encodedOnMainThread)
                defaults.resetWrites()
                start = ContinuousClock.now
                controller.setSyncStateForTesting(synced: encoded)
                timings["turn"] = Self.milliseconds(ContinuousClock.now - start)
                try check(summary)
                guard run > 0 else { continue }
                for (name, value) in timings { samples[name, default: []].append(value) }
                print("PERSIST_BENCH details=\(details) bytes=\(bytes) " + timings.keys.sorted().map { "\($0)_ms=\(String(format: "%.3f", timings[$0]!))" }.joined(separator: " "))
            }
            func stats(_ values: [Double]) -> String {
                let sorted = values.sorted()
                // Nearest rank: with five samples the p95 is the maximum.
                let p95 = sorted[min(sorted.count - 1, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
                return String(format: "median=%.3f p95=%.3f", sorted[sorted.count / 2], p95)
            }
            print("PERSIST_SUMMARY details=\(details) bytes=\(bytes) runs=\(runs) " + ["inline_turn", "encode", "writes", "off_main_encode", "turn"].map { "\($0)_ms[\(stats(samples[$0]!))]" }.joined(separator: " "))
        }
    }

    /// A first sync's result: `details` added files spread over `courses` courses, with ids of the
    /// coordinator's `course:module:/folder:name` form, the shape the D05 restore benchmark uses.
    private static func syntheticSummary(details: Int, courses: Int, completedAt: Date) -> SyncCompletionSummary {
        SyncCompletionSummary(progress: syntheticProgress(details: details, courses: courses), completedAt: completedAt)
    }

    private static func syntheticProgress(details: Int, courses: Int) -> SyncProgress {
        let perCourse = (0..<courses).map { index -> CourseSyncCount in
            let course = index + 1
            let items = stride(from: index, to: details, by: courses).map { SyncedItem(id: "\(course):100:/:file-\($0).pdf", name: "file-\($0).pdf", kind: .added) }
            return CourseSyncCount(courseID: Int64(course), courseFolder: "Course \(course)", added: items.count, updated: 0, items: items)
        }
        return SyncProgress(completed: details, total: details, added: details, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0, perCourse: perCourse)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// On-demand Release measurement of the actual controller restore, with synthetic file details.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEEPBAR_RESTORE_BENCHMARK"] == "1")) @MainActor
    func benchmarkSummaryRestore() async throws {
        for count in [1000, 15000] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let rootID = UUID()
            let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = CountingDefaults(suiteName: suite)!
            let items = (0..<count).map { SyncedItem(id: "1:100:/:file-\($0).pdf", name: "file-\($0).pdf", kind: .added) }
            let summary = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 123), added: count, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0, perCourse: [CourseSyncCount(courseID: 1, courseFolder: "Course", added: count, updated: 0, items: items)])
            let bytes = try JSONEncoder().encode(summary)
            defaults.set(bytes, forKey: "io.github.tvaccari.beepbar.last-successful-summary.v1." + rootID.uuidString)
            let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, defaults: defaults)
            for run in 0..<8 {
                defaults.resetWrites()
                let codecStart = ContinuousClock.now
                let decoded = try JSONDecoder().decode(SyncCompletionSummary.self, from: bytes)
                let decodeTime = ContinuousClock.now - codecStart
                let encodeStart = ContinuousClock.now
                _ = try JSONEncoder().encode(decoded)
                let encodeTime = ContinuousClock.now - encodeStart
                let start = ContinuousClock.now
                await controller.restorePersistedSyncStateForTesting()
                let elapsed = ContinuousClock.now - start
                #expect(controller.lastSyncSummary == summary)
                if run > 0 { print("RESTORE_BENCH files=\(count) bytes=\(bytes.count) ms=\(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) writes=\(defaults.writes.count) decode_ms=\(Double(decodeTime.components.seconds) * 1000 + Double(decodeTime.components.attoseconds) / 1e15) encode_ms=\(Double(encodeTime.components.seconds) * 1000 + Double(encodeTime.components.attoseconds) / 1e15)") }
            }
        }
    }

    @Test(arguments: ["refresh-sync", "restore-sync", "refresh-signout", "restore-signout", "refresh-root", "restore-root"]) @MainActor
    func delayedPendingChoicesCannotReplaceNewAccountOrSyncState(_ action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let conflict = ConflictRecord(id: UUID(), rootID: rootID, remoteID: "pending",
            relativePath: try RelativePath("Course/pending.pdf"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/pending.pdf"),
            baseSHA256: "base", localSHA256: "local", remoteSHA256: "remote", remoteRevision: "2", detectedAt: .now, status: .open)
        try await database.insertConflict(conflict)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        let readStarted = AsyncStream<Void>.makeStream()
        let releaseRead = AsyncStream<Void>.makeStream()
        controller.setBeforePendingChoicesForTesting {
            readStarted.continuation.yield()
            for await _ in releaseRead.stream { break }
        }
        let read = Task {
            if action.hasPrefix("restore") { await controller.restorePersistedSyncStateForTesting() }
            else { await controller.reloadPendingChoicesForTesting() }
        }
        var started = readStarted.stream.makeAsyncIterator()
        _ = await started.next()
        let signingOut = action.hasSuffix("signout")
        let changingRoot = action.hasSuffix("root")
        if changingRoot {
            controller.setRootIDForTesting(UUID())
            controller.setSyncStateForTesting(.needsFolder)
        }
        else if signingOut { controller.setDisconnectedForTesting() }
        else {
            controller.setOperationForTesting(UUID())
            controller.setSyncStateForTesting(.syncing)
        }
        releaseRead.continuation.yield()
        await read.value
        #expect(controller.syncState == (changingRoot ? .needsFolder : signingOut ? .loginRequired : .syncing))
        #expect(controller.isSyncActive == (!signingOut && !changingRoot))
        #expect(controller.conflicts.isEmpty)
    }

    @Test(arguments: ["completion", "refresh", "restore"]) @MainActor
    func readFailurePreservesPendingChoicesWithoutRecordingSuccess(_ action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "state.sqlite")
        let database = try SyncDatabase(url: url)
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let change = RemoteChange(rootID: rootID, courseID: 1, remoteID: "old", kind: .removed,
            relativePath: try RelativePath("Course/old.pdf"), localSHA256: "local", isLocallyModified: false)
        _ = try await database.reconcileRemoteChanges(rootID: rootID, courseIDs: [1], desired: [change])
        let conflict = ConflictRecord(id: UUID(), rootID: rootID, remoteID: "conflict",
            relativePath: try RelativePath("Course/conflict.pdf"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/conflict.pdf"),
            baseSHA256: "base", localSHA256: "local", remoteSHA256: "remote", remoteRevision: "2", detectedAt: .now, status: .open)
        try await database.insertConflict(conflict)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        await controller.reloadPendingChoicesForTesting()
        let beforeConflicts = controller.conflicts
        let beforeChanges = controller.remoteChanges
        #expect(beforeChanges.count == 1)
        #expect(beforeConflicts.count == 1)
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "UPDATE conflicts SET status = 'resolved'", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(connection, "DROP TABLE remote_changes", nil, nil, nil) == SQLITE_OK)
        var notificationSent = false
        controller.setBeforeNotificationForTesting { notificationSent = true }
        switch action {
        case "completion":
            let operationID = UUID()
            controller.setOperationForTesting(operationID)
            await controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 1, total: 1, added: 1, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
        case "refresh": await controller.reloadPendingChoicesForTesting()
        default: await controller.restorePersistedSyncStateForTesting()
        }
        #expect(controller.conflicts == beforeConflicts)
        #expect(controller.remoteChanges == beforeChanges)
        guard case .failed(.local) = controller.syncState else {
            Issue.record("A database read failure must be visible")
            return
        }
        #expect(!controller.isSyncActive)
        #expect(controller.lastSuccessfulTimestampForTesting() == 0)
        #expect(!notificationSent)
    }

    @Test @MainActor func cancellationDuringReconciliationDoesNotRestoreCompletedState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)

        let reconciliationStarted = AsyncStream<Void>.makeStream()
        let resumeReconciliation = AsyncStream<Void>.makeStream()
        controller.setBeforeReconciliationStateForTesting {
            reconciliationStarted.continuation.yield()
            for await _ in resumeReconciliation.stream { break }
        }
        var notificationSent = false
        controller.setBeforeNotificationForTesting { notificationSent = true }
        let completion = Task {
            await controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 1, total: 1, added: 1, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
        }
        controller.setOperationForTesting(operationID, task: completion)
        var started = reconciliationStarted.stream.makeAsyncIterator()
        _ = await started.next()

        controller.setCourse(RemoteCourseSummary(id: 1, shortName: "1", displayName: "Course", isVisible: true, startDate: nil, endDate: nil), enabled: false)
        #expect(controller.enabledCourseIDs == [1])
        controller.cancelSynchronization()
        resumeReconciliation.continuation.yield()
        await completion.value

        #expect(controller.syncState == .readyUnchecked)
        #expect(!controller.isSyncActive)
        #expect(!notificationSent)
    }

    @Test @MainActor func completedRunCannotBeCancelledWhileNotificationIsPending() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)

        let notificationStarted = AsyncStream<Void>.makeStream()
        let releaseNotification = AsyncStream<Void>.makeStream()
        controller.setBeforeNotificationForTesting {
            notificationStarted.continuation.yield()
            for await _ in releaseNotification.stream { break }
        }
        let completion = Task {
            await controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 1, total: 1, added: 1, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
        }
        var started = notificationStarted.stream.makeAsyncIterator()
        _ = await started.next()

        #expect(!controller.isSyncActive)
        #expect(controller.canSynchronize)
        let state = controller.syncState
        controller.cancelSynchronization()
        #expect(controller.syncState == state)

        releaseNotification.continuation.yield()
        await completion.value
    }

    @Test @MainActor func failedRunCannotBeCancelledWhileNotificationIsPending() async {
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)

        let notificationStarted = AsyncStream<Void>.makeStream()
        let releaseNotification = AsyncStream<Void>.makeStream()
        controller.setBeforeNotificationForTesting {
            notificationStarted.continuation.yield()
            for await _ in releaseNotification.stream { break }
        }
        let completion = Task { await controller.failSyncForTesting(operationID) }
        var started = notificationStarted.stream.makeAsyncIterator()
        _ = await started.next()

        #expect(!controller.isSyncActive)
        #expect(controller.canSynchronize)
        #expect(controller.syncState == .failed(.partialSync))
        controller.cancelSynchronization()
        #expect(controller.syncState == .failed(.partialSync))

        releaseNotification.continuation.yield()
        await completion.value
    }
}

/// Holds the first real permission read while the controller can accept account/folder/run changes.
/// Subsequent reads proceed, so a later notification proves obsolete delivery did not poison deduplication.
private actor SuspendedNotificationCenter: NotificationCenterClient {
    nonisolated let started = AsyncStream<Void>.makeStream()
    nonisolated let release = AsyncStream<Void>.makeStream()
    private var held = false
    private let holdSend: Bool
    init(holdSend: Bool = false) { self.holdSend = holdSend }
    private(set) var sent: [NotificationDestination] = []

    func authorization() async -> NotificationAuthorization {
        if !held && !holdSend {
            held = true
            started.continuation.yield()
            for await _ in release.stream { break }
        }
        return .allowed
    }
    func requestAuthorization() async {}
    func send(identifier: String, title: String, body: String, destination: NotificationDestination) async {
        sent.append(destination)
        if holdSend && !held {
            held = true
            started.continuation.yield()
            for await _ in release.stream { break }
        }
    }
}

extension SyncFinalizationTests {
    /// Runs the actual coordinator after completion/failure, rather than the notification test hook.
    /// Old notices must be dropped after disconnect, folder changes, a newer run or its successful result;
    /// a discarded failure must also leave a subsequent genuine failure eligible for notification.
    @Test(arguments: [false, true], ["disconnect", "root", "new-run", "new-result"]) @MainActor
    func obsoleteNotificationsAreDroppedWithoutRecording(failed: Bool, replacement: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let center = SuspendedNotificationCenter()
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, notificationCenter: center)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)
        let completion = Task {
            if failed { await controller.failSyncForTesting(operationID) }
            else {
                await controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 1, total: 1, added: 1, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
            }
        }
        var started = center.started.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(!controller.isSyncActive, "notification permission must not leave Cancel active")
        switch replacement {
        case "disconnect": controller.setDisconnectedForTesting()
        case "root": controller.setRootIDForTesting(UUID())
        case "new-run": controller.setOperationForTesting(UUID())
        default:
            let newer = UUID()
            controller.setOperationForTesting(newer)
            await controller.completeSyncForTesting(newer, summary: SyncProgress(completed: 0, total: 0, added: 0, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
        }
        center.release.continuation.yield()
        await completion.value
        #expect(await center.sent.isEmpty)
        if failed {
            let newerFailure = UUID()
            controller.setOperationForTesting(newerFailure)
            await controller.failSyncForTesting(newerFailure)
            #expect(await center.sent == [.home], "discarded failure must not suppress the next genuine failure")
        }
    }
}


extension SyncFinalizationTests {
    /// Real automatic completion keeps one validity snapshot for conflicts and its subsequent
    /// materials/failure notice, even when a disconnect or a new run occurs during the first send.
    @Test(arguments: [0, 1], ["disconnect", "new-run"]) @MainActor
    func automaticNotificationSequenceUsesOriginalResult(failures: Int, replacement: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.insertConflict(ConflictRecord(id: UUID(), rootID: rootID, remoteID: "pending",
            relativePath: try RelativePath("Course/pending.pdf"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/pending.pdf"),
            baseSHA256: "base", localSHA256: "local", remoteSHA256: "remote", remoteRevision: "2", detectedAt: .now, status: .open))
        let center = SuspendedNotificationCenter(holdSend: true)
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, notificationCenter: center)
        let operationID = UUID()
        controller.setOperationForTesting(operationID)
        let completion = Task {
            await controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 2, total: 2, added: 1, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 1, failures: failures), automatic: true)
        }
        var started = center.started.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(!controller.isSyncActive)
        if replacement == "disconnect" { controller.setDisconnectedForTesting() }
        else { controller.setOperationForTesting(UUID()) }
        center.release.continuation.yield()
        await completion.value
        #expect(await center.sent == [.conflicts])
    }
}

/// Exercises actual resolver refusals and filesystem failures, rather than just their copy.
struct ConflictChoiceFeedbackTests {
    @Test(arguments: ["source-changed", "twin-changed", "io-error"]) @MainActor
    func remoteRefusalIsVisibleAndSuccessfulChoiceClearsIt(_ failure: String) async throws {
        let fixture = try await ChoiceFixture()
        defer { fixture.remove() }
        try fixture.write("mine", path: "Course/old.txt")
        try fixture.write("remote", path: "Course/new.txt")
        let oldHash = try await fixture.hash("Course/old.txt")
        let newHash = try await fixture.hash("Course/new.txt")
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: "old", relativePath: try RelativePath("Course/old.txt"), sha256: "original", remoteRevision: "1", courseID: 1, moduleID: 1))
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: "new", relativePath: try RelativePath("Course/new.txt"), sha256: newHash, remoteRevision: "1", courseID: 1, moduleID: 1))
        let change = RemoteChange(rootID: fixture.rootID, courseID: 1, remoteID: "old", kind: .reuploaded, relativePath: try RelativePath("Course/old.txt"), targetPath: try RelativePath("Course/new.txt"), newRemoteID: "new", localSHA256: oldHash, isLocallyModified: true)
        _ = try await fixture.database.reconcileRemoteChanges(rootID: fixture.rootID, courseIDs: [1], desired: [change])
        let controller = fixture.controller()
        if failure == "source-changed" { try fixture.write("edited again", path: "Course/old.txt") }
        if failure == "twin-changed" { try fixture.write("edited new copy", path: "Course/new.txt") }
        if failure == "io-error" {
            // A blocked parent is a real traversal failure, not an injected result.
            try FileManager.default.removeItem(at: fixture.root.appending(path: "Course"))
            try fixture.write("blocked", path: "Course")
        }
        controller.resolve(change, with: .replaceNewCopy)
        try await waitForChoice(controller)
        let feedback = try #require(controller.conflictChoiceFeedback)
        if failure == "source-changed" { #expect(feedback.english.contains("changed in the meantime")) }
        else if failure == "twin-changed" { #expect(feedback.english.contains("was edited")) }
        else { #expect(feedback.english.contains("Couldn't carry out")) }
        #expect(!feedback.italian.isEmpty)
        #expect(try await fixture.database.remoteChange(rootID: fixture.rootID, id: change.id) != nil)
        controller.resolve(change, with: .keepBoth)
        try await waitForChoice(controller)
        #expect(controller.conflictChoiceFeedback == nil)
        #expect(try await fixture.database.remoteChange(rootID: fixture.rootID, id: change.id) == nil)
    }

    @Test(arguments: [false, true]) @MainActor
    func ordinaryConflictRefusalAndFailureAreVisible(_ missingArtifact: Bool) async throws {
        let fixture = try await ChoiceFixture()
        defer { fixture.remove() }
        try fixture.write("mine", path: "Course/file.txt")
        let shownHash = try await fixture.hash("Course/file.txt")
        try fixture.write("remote", path: ".beepbar/conflicts/fixture/remote.txt")
        let remoteHash = try await fixture.hash(".beepbar/conflicts/fixture/remote.txt")
        let conflict = ConflictRecord(id: UUID(), rootID: fixture.rootID, remoteID: "file", relativePath: try RelativePath("Course/file.txt"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/fixture/remote.txt"), baseSHA256: "original", localSHA256: shownHash, remoteSHA256: remoteHash, remoteRevision: "2", detectedAt: .now, status: .open)
        try await fixture.database.insertConflict(conflict)
        if missingArtifact { try FileManager.default.removeItem(at: fixture.root.appending(path: ".beepbar/conflicts/fixture/remote.txt")) }
        else { try fixture.write("edited again", path: "Course/file.txt") }
        let controller = fixture.controller()
        controller.resolve(conflict, with: .useRemote)
        try await waitForChoice(controller)
        let feedback = try #require(controller.conflictChoiceFeedback)
        #expect(feedback.english.contains(missingArtifact ? "Couldn't finish resolving" : "changed in the meantime"))
        #expect(try String(contentsOf: fixture.root.appending(path: "Course/file.txt"), encoding: .utf8) == (missingArtifact ? "mine" : "edited again"))
        // The next successful choice clears the reason, even if the first conflict was superseded.
        let pending = try #require(try await fixture.database.conflicts(rootID: fixture.rootID).first)
        controller.resolve(pending, with: .keepLocal)
        try await waitForChoice(controller)
        #expect(controller.conflictChoiceFeedback == nil)
    }

    @Test @MainActor func lateDatabaseFailureDoesNotPromiseLocalPreservation() async throws {
        let fixture = try await ChoiceFixture()
        defer { fixture.remove() }
        try fixture.write("mine", path: "Course/file.txt")
        try fixture.write("remote", path: ".beepbar/conflicts/fixture/remote.txt")
        let conflict = ConflictRecord(id: UUID(), rootID: fixture.rootID, remoteID: "file", relativePath: try RelativePath("Course/file.txt"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/fixture/remote.txt"), baseSHA256: "original", localSHA256: try await fixture.hash("Course/file.txt"), remoteSHA256: try await fixture.hash(".beepbar/conflicts/fixture/remote.txt"), remoteRevision: "2", detectedAt: .now, status: .open)
        try await fixture.database.insertConflict(conflict)
        var connection: OpaquePointer?
        #expect(sqlite3_open(fixture.root.appending(path: "state.sqlite").path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "CREATE TRIGGER reject_resolution BEFORE UPDATE OF status ON conflicts BEGIN SELECT RAISE(ABORT, 'injected late failure'); END", nil, nil, nil) == SQLITE_OK)
        let controller = fixture.controller()
        controller.resolve(conflict, with: .useRemote)
        try await waitForChoice(controller)
        #expect(try String(contentsOf: fixture.root.appending(path: "Course/file.txt"), encoding: .utf8) == "remote")
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).count == 1)
        let feedback = try #require(controller.conflictChoiceFeedback)
        #expect(feedback.english == "Couldn't finish resolving this conflict. Check the file and refresh before retrying.")
        #expect(!feedback.italian.contains("nessun file locale"))
    }

    @Test(arguments: [false, true]) @MainActor
    func changedRootOrDisconnectClearsChoiceFeedback(_ disconnect: Bool) async throws {
        let fixture = try await ChoiceFixture()
        defer { fixture.remove() }
        let conflict = ConflictRecord(id: UUID(), rootID: fixture.rootID, remoteID: "missing", relativePath: try RelativePath("Course/missing.txt"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/missing.txt"), baseSHA256: "base", localSHA256: "local", remoteSHA256: "remote", remoteRevision: "2", detectedAt: .now, status: .open)
        try await fixture.database.insertConflict(conflict)
        let controller = fixture.controller()
        controller.resolve(conflict, with: .useRemote)
        try await waitForChoice(controller)
        #expect(controller.conflictChoiceFeedback != nil)
        if disconnect { controller.setDisconnectedForTesting() }
        else { controller.setRootIDForTesting(UUID()) }
        #expect(controller.conflictChoiceFeedback == nil)
    }

    @MainActor private func waitForChoice(_ controller: WeBeepAuthenticationController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.resolvingConflictID != nil || controller.resolvingRemoteChangeID != nil {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            await Task.yield()
        }
    }
}

private struct ChoiceFixture {
    let root: URL
    let database: SyncDatabase
    let rootID = UUID()

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
    }

    func write(_ value: String, path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    func hash(_ path: String) async throws -> String {
        let data = try Data(contentsOf: root.appending(path: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor func controller() -> WeBeepAuthenticationController {
        WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
