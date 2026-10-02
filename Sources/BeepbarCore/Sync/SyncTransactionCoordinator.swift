import Foundation

public enum TransactionOutcome: Sendable, Equatable {
    case installedNew
    case installedReplacing
    case conflict(ConflictRecord)

    public var isInstalled: Bool {
        switch self {
        case .installedNew, .installedReplacing: true
        case .conflict: false
        }
    }
}

/// A point between two durable steps of a journaled change, where a crash can leave it.
enum JournalStep: Sendable, Equatable, CaseIterable {
    /// The pending row is committed; nothing on disk has changed yet.
    case journaled
    /// The filesystem change is done (installed, swapped or kept aside as a conflict); the row
    /// still says it is pending.
    case filesystemChanged
    /// The baseline is committed; the row is still there.
    case committed
    /// The replaced copy is gone; only removing the row is left.
    case rollbackDiscarded
}

/// Installs a downloaded file through the journal: pending row, filesystem change, baseline,
/// cleanup, row removed. `RecoveryCoordinator` finishes the sequence from any step at which a
/// crash interrupts it, so a step can be reordered only together with recovery.
public actor SyncTransactionCoordinator {
    private let database: SyncDatabase
    private let fileStore: FileStore
    /// Called after each durable step. Tests throw from it to stop the sequence exactly where a
    /// crash would; nothing in this type cleans up after an error, so what is left on disk is what
    /// a crash would leave. Always `nil` in the app.
    private let interruption: (@Sendable (JournalStep) throws -> Void)?

    public init(database: SyncDatabase, fileStore: FileStore) {
        self.init(database: database, fileStore: fileStore, interruption: nil)
    }

    init(database: SyncDatabase, fileStore: FileStore, interruption: (@Sendable (JournalStep) throws -> Void)?) {
        self.database = database
        self.fileStore = fileStore
        self.interruption = interruption
    }

    public func install(rootID: UUID, remoteID: String, courseID: Int64? = nil, moduleID: Int64? = nil, destination: RelativePath, expectedLocal: LocalState, remote: RemoteState, artifact: StagedArtifact) async throws -> TransactionOutcome {
        guard (courseID == nil) == (moduleID == nil) else { throw SyncDatabaseError.execution }
        let trace = PerformanceTrace.shared.begin("database.installTransaction", category: .database)
        defer { PerformanceTrace.shared.end("database.installTransaction", category: .database, state: trace) }
        guard artifact.sha256 == remote.sha256 else { throw FileStoreError.invalidStage }
        let operation = PendingOperation(rootID: rootID, remoteID: remoteID, destination: destination, stagePath: artifact.stagePath, expectedLocal: expectedLocal, remoteSHA256: remote.sha256, remoteRevision: remote.revision, courseID: courseID, moduleID: moduleID)
        try await database.beginOperation(operation)
        try interruption?(.journaled)
        let result = try await fileStore.install(artifact, at: destination, expectedLocal: expectedLocal)
        switch result {
        case .installedNew:
            try interruption?(.filesystemChanged)
            try await database.markCommitted(id: operation.id, baseline: Baseline(remoteID: remoteID, relativePath: destination, sha256: remote.sha256, remoteRevision: remote.revision, courseID: courseID, moduleID: moduleID))
            try interruption?(.committed)
            try await database.finishOperation(id: operation.id)
            return .installedNew
        case .installedReplacing(let rollback):
            try interruption?(.filesystemChanged)
            try await database.markCommitted(id: operation.id, baseline: Baseline(remoteID: remoteID, relativePath: destination, sha256: remote.sha256, remoteRevision: remote.revision, courseID: courseID, moduleID: moduleID))
            try interruption?(.committed)
            try await fileStore.discard(rollback)
            try interruption?(.rollbackDiscarded)
            try await database.finishOperation(id: operation.id)
            return .installedReplacing
        case .localChanged:
            let conflictID = operation.id
            let incoming = try await fileStore.preserveAsConflict(artifact, conflictID: conflictID, at: destination)
            try interruption?(.filesystemChanged)
            let local = try await fileStore.inspect(destination)
            let conflict = ConflictRecord(id: conflictID, rootID: rootID, remoteID: remoteID, relativePath: destination, incomingPath: incoming, baseSHA256: expectedLocal.sha256, localSHA256: local.sha256, remoteSHA256: remote.sha256, remoteRevision: remote.revision, detectedAt: Date(), status: .open)
            try await database.finishAsConflict(id: operation.id, conflict: conflict)
            return .conflict(conflict)
        }
    }

    public func recordConflict(rootID: UUID, remoteID: String, courseID: Int64? = nil, moduleID: Int64? = nil, destination: RelativePath, local: LocalState, remote: RemoteState, artifact: StagedArtifact) async throws -> ConflictRecord {
        guard (courseID == nil) == (moduleID == nil) else { throw SyncDatabaseError.execution }
        guard artifact.sha256 == remote.sha256 else { throw FileStoreError.invalidStage }
        // The row journals what an install would have expected to replace, the last synced
        // version, never the user's current copy. Recovery reads a prepared row as "install the
        // download if the file still matches `expectedLocal`": journaling `local` here made a
        // crash before `preserveAsConflict` install the download over the very edit that caused
        // the conflict, and delete the edit with the replaced copy. With the synced version, an
        // edited file never matches, so recovery keeps it and records the conflict.
        let synced = try await database.baseline(rootID: rootID, remoteID: remoteID)
        let operation = PendingOperation(rootID: rootID, remoteID: remoteID, destination: destination, stagePath: artifact.stagePath, expectedLocal: synced.map { .present(sha256: $0.sha256) } ?? .missing, remoteSHA256: remote.sha256, remoteRevision: remote.revision, courseID: courseID, moduleID: moduleID)
        try await database.beginOperation(operation)
        try interruption?(.journaled)
        let incoming = try await fileStore.preserveAsConflict(artifact, conflictID: operation.id, at: destination)
        try interruption?(.filesystemChanged)
        let conflict = ConflictRecord(id: operation.id, rootID: rootID, remoteID: remoteID, relativePath: destination, incomingPath: incoming, baseSHA256: synced?.sha256, localSHA256: local.sha256, remoteSHA256: remote.sha256, remoteRevision: remote.revision, detectedAt: Date(), status: .open)
        try await database.finishAsConflict(id: operation.id, conflict: conflict)
        return conflict
    }
}

private extension LocalState {
    var sha256: String? {
        if case .present(let sha256) = self { return sha256 }
        return nil
    }
}
