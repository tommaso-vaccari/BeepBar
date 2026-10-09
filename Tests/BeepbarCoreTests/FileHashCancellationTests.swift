import CryptoKit
import Foundation
import os
import Testing
@testable import BeepbarCore

struct FileHashCancellationTests {
    enum Read: String, CaseIterable, Sendable { case inspect, snapshot, stage, conflict, conflictCopy }

    @Test(arguments: Read.allCases)
    func precommitReadStopsWithoutLosingLocalBytes(_ read: Read) async throws {
        let fixture = try await Fixture(read: read)
        defer { fixture.remove() }
        let before = await fixture.store.counters()
        fixture.probe.arm(skipReads: read == .conflictCopy ? 1 : 0)
        let result = await Task { try await fixture.read() }.result
        guard case .failure(let error) = result, error is CancellationError else {
            Issue.record("Expected cancellation during \(read), got \(result)")
            return
        }
        #expect(fixture.probe.chunksAfterCancellation == 0)
        let hashed = await fixture.store.counters().since(before).bytesHashed
        #expect(hashed == (read == .conflictCopy ? Fixture.size : 8 << 20))
        #expect(try await fixture.store.inspect(fixture.path) == fixture.original)
        let artifact = try await fixture.store.stagedArtifact(at: fixture.stage.relativePath)
        if read == .stage { #expect(artifact?.sha256 == fixture.hash) }
        if let incoming = fixture.incoming {
            #expect(try await fixture.store.conflictArtifact(at: incoming)?.sha256 == fixture.hash)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: ".beepbar/staging").path).isEmpty)
        }
    }

    @Test func cancelledPartialHashIsNotMemoized() async throws {
        let fixture = try await Fixture(read: .inspect)
        defer { fixture.remove() }
        fixture.probe.arm()
        let result = await Task { try await fixture.read() }.result
        #expect(result.isCancellation)
        let stage = try await fixture.store.createStage()
        try await fixture.store.write(Data("remote".utf8), to: stage)
        let artifact = try await fixture.store.finalize(stage)
        let before = await fixture.store.counters()
        let installed = try await fixture.store.install(artifact, at: fixture.path, expectedLocal: fixture.original)
        guard case .installedReplacing(let rollback) = installed else { Issue.record("Expected replacement after partial inspection, got \(installed)"); return }
        #expect(await fixture.store.counters().since(before).filesHashed == 2)
        #expect(try String(contentsOf: fixture.root.appending(path: fixture.path.value), encoding: .utf8) == "remote")
        try await fixture.store.discard(rollback)
        try await fixture.store.discard(fixture.stage)
    }

    @Test(arguments: [JournalStep.journaled, .filesystemChanged, .committed])
    func cancellationAfterJournalFinishesTheTransaction(_ point: JournalStep) async throws {
        let fixture = try await Fixture(read: .stage)
        defer { fixture.remove() }
        try await fixture.store.discard(fixture.stage)
        let rootID = UUID()
        let database = try SyncDatabase(url: fixture.root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let stage = try await fixture.store.createStage()
        try await fixture.store.write(Data("remote".utf8), to: stage)
        let artifact = try await fixture.store.finalize(stage)
        let coordinator = SyncTransactionCoordinator(database: database, fileStore: fixture.store, interruption: { step in
            if step == point { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let result = try await Task {
            try await coordinator.install(rootID: rootID, remoteID: "file", destination: fixture.path, expectedLocal: fixture.original, remote: RemoteState(sha256: artifact.sha256, revision: "2"), artifact: artifact)
        }.value
        #expect(result == .installedReplacing)
        #expect(try String(contentsOf: fixture.root.appending(path: fixture.path.value), encoding: .utf8) == "remote")
        #expect(try await database.pendingOperations().isEmpty)
        #expect(try await database.baseline(rootID: rootID, remoteID: "file")?.sha256 == artifact.sha256)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: ".beepbar/staging").path).isEmpty)
    }

    @Test(arguments: [JournalStep.journaled, .filesystemChanged])
    func cancelledJournaledConflictPreservesBothCopies(_ point: JournalStep) async throws {
        let fixture = try await Fixture(read: .stage)
        defer { fixture.remove() }
        try await fixture.store.discard(fixture.stage)
        let rootID = UUID()
        let database = try SyncDatabase(url: fixture.root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let stage = try await fixture.store.createStage()
        try await fixture.store.write(Data("remote".utf8), to: stage)
        let artifact = try await fixture.store.finalize(stage)
        let coordinator = SyncTransactionCoordinator(database: database, fileStore: fixture.store, interruption: { step in
            if step == point { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let outcome = try await Task {
            try await coordinator.install(rootID: rootID, remoteID: "file", destination: fixture.path, expectedLocal: .present(sha256: "older baseline"), remote: RemoteState(sha256: artifact.sha256, revision: "2"), artifact: artifact)
        }.value
        guard case .conflict(let conflict) = outcome else { Issue.record("Expected conflict, got \(outcome)"); return }
        #expect(try await fixture.store.inspect(fixture.path) == fixture.original)
        #expect(try await fixture.store.conflictArtifact(at: conflict.incomingPath)?.sha256 == artifact.sha256)
        let saved = try #require(try await database.conflict(id: conflict.id))
        #expect(saved.rootID == rootID && saved.remoteID == "file")
        #expect(saved.relativePath == fixture.path && saved.incomingPath == conflict.incomingPath)
        #expect(saved.localSHA256 == fixture.hash && saved.remoteSHA256 == artifact.sha256)
        #expect(saved.baseSHA256 == "older baseline" && saved.remoteRevision == "2" && saved.status == .open)
        #expect(try await database.pendingOperations().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: ".beepbar/staging").path).isEmpty)
    }

    @Test func cancelledRecoveryStillPreservesEditedLocalCopy() async throws {
        let fixture = try await Fixture(read: .stage)
        defer { fixture.remove() }
        try await fixture.store.discard(fixture.stage)
        let rootID = UUID()
        let database = try SyncDatabase(url: fixture.root.appending(path: "state.sqlite"))
        try await database.registerRoot(id: rootID, canonicalPath: fixture.root.path)
        let stage = try await fixture.store.createStage()
        try await fixture.store.write(Data("remote".utf8), to: stage)
        let artifact = try await fixture.store.finalize(stage)
        let operation = PendingOperation(rootID: rootID, remoteID: "file", destination: fixture.path, stagePath: artifact.stagePath, expectedLocal: .present(sha256: "older baseline"), remoteSHA256: artifact.sha256, remoteRevision: "2")
        try await database.beginOperation(operation)
        let report = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RecoveryCoordinator(rootID: rootID, database: database, fileStore: fixture.store).recover()
        }.value
        #expect(report.unresolved.isEmpty)
        #expect(report.conflicts == [operation.id])
        #expect(try await fixture.store.inspect(fixture.path) == fixture.original)
        #expect(try await database.pendingOperations().isEmpty)
        let conflict = try #require(try await database.conflict(id: operation.id))
        #expect(try await fixture.store.conflictArtifact(at: conflict.incomingPath)?.sha256 == artifact.sha256)
    }

    @Test func releaseCancellationLatency() async throws {
        guard ProcessInfo.processInfo.environment["BEEPBAR_HASH_CANCEL_REPORT"] != nil else { return }
        let clock = ContinuousClock()
        for read in Read.allCases {
            let fixture = try await Fixture(read: read)
            defer { fixture.remove() }
            var samples: [Double] = []
            for sample in 0..<22 {
                fixture.probe.arm(skipReads: read == .conflictCopy ? 1 : 0)
                let result = await Task { try await fixture.read() }.result
                #expect(result.isCancellation)
                let cancelledAt = try #require(fixture.probe.cancelledAt)
                let elapsed = cancelledAt.duration(to: clock.now).components
                if sample >= 2 { samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
            }
            samples.sort()
            let p95 = samples[18]
            print("HASH_CANCEL \(read.rawValue) sizeMiB=64 warmup=2 samples=20 p95_ms=\(p95) max_ms=\(samples.last!)")
            #expect(p95 < 1000)
        }
    }

    private struct Fixture {
        static let size: Int64 = 64 << 20
        let readKind: Read
        let root: URL
        let store: FileStore
        let path: RelativePath
        let stage: StageHandle
        let incoming: RelativePath?
        let original: LocalState
        let hash: String
        let probe: CancelProbe

        init(read: Read) async throws {
            readKind = read
            root = FileManager.default.temporaryDirectory.appending(path: "Beepbar-hash-cancel-\(UUID())")
            try FileManager.default.createDirectory(at: root.appending(path: "Course"), withIntermediateDirectories: true)
            path = try RelativePath("Course/local.bin")
            let file = root.appending(path: path.value)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            let chunk = Data(repeating: 0x5a, count: 1 << 20)
            var digest = SHA256()
            for _ in 0..<64 { try handle.write(contentsOf: chunk); digest.update(data: chunk) }
            try handle.close()
            hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            original = .present(sha256: hash)
            probe = CancelProbe()
            store = try FileStore(root: root, beforeMove: nil, trash: { _ in }, beforeReadChunk: { [probe] cooperative, offset in probe.chunk(cooperative: cooperative, offset: offset) })
            stage = try await store.createStage()
            if read == .stage || read == .conflict || read == .conflictCopy {
                for _ in 0..<64 { try await store.write(chunk, to: stage) }
            }
            if read == .conflict || read == .conflictCopy {
                let artifact = try await store.finalize(stage)
                incoming = try await store.preserveAsConflict(artifact, conflictID: UUID(), at: path)
            } else { incoming = nil }
        }

        func read() async throws {
            switch readKind {
            case .inspect: _ = try await store.inspect(path)
            case .snapshot: _ = try await store.snapshotRegularFile(path)
            case .stage: _ = try await store.finalize(stage)
            case .conflict: _ = try await store.conflictArtifact(at: incoming!)
            case .conflictCopy: _ = try await store.copyConflictArtifactToStage(at: incoming!, expectedSHA256: hash)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class CancelProbe: Sendable {
    private struct State {
        var armed = false
        var skipReads = 0
        var cancelledAt: ContinuousClock.Instant?
        var skipCurrentRead = false
        var chunksAfterCancellation = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var cancelledAt: ContinuousClock.Instant? { state.withLock { $0.cancelledAt } }
    var chunksAfterCancellation: Int { state.withLock { $0.chunksAfterCancellation } }
    func arm(skipReads: Int = 0) { state.withLock { $0 = State(armed: true, skipReads: skipReads) } }
    func chunk(cooperative: Bool, offset: Int64) {
        let cancel = state.withLock { state in
            if state.cancelledAt != nil { state.chunksAfterCancellation += 1 }
            guard state.armed, cooperative else { return false }
            if offset == 0 {
                state.skipCurrentRead = state.skipReads > 0
                if state.skipCurrentRead { state.skipReads -= 1 }
            }
            guard !state.skipCurrentRead, offset == 8 << 20 else { return false }
            state.armed = false
            state.cancelledAt = ContinuousClock().now
            return true
        }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

private extension Result where Success == Void, Failure == any Error {
    var isCancellation: Bool { if case .failure(let error) = self { return error is CancellationError }; return false }
}
