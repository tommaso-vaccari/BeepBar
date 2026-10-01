import Foundation
import CryptoKit
import Testing
import SQLite3
@testable import BeepbarCore
@testable import BeepbarApp

struct SyncFinalizationTests {
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
