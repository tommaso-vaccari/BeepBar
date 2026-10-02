import Foundation

public struct RecoveryReport: Sendable, Equatable {
    public let recovered: [UUID]
    public let conflicts: [UUID]
    public let unresolved: [UUID]

    public init(recovered: [UUID] = [], conflicts: [UUID] = [], unresolved: [UUID] = []) {
        self.recovered = recovered
        self.conflicts = conflicts
        self.unresolved = unresolved
    }
}

public actor RecoveryCoordinator {
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let rootID: UUID

    public init(rootID: UUID, database: SyncDatabase, fileStore: FileStore) {
        self.rootID = rootID; self.database = database; self.fileStore = fileStore
    }

    /// Recovers every pending operation and scope move of the root. A row whose recovery throws
    /// (an invalid stage path, a destination that is no longer a regular file, a database error)
    /// is reported as unresolved and left pending so that the remaining rows are still processed.
    public func recover() async throws -> RecoveryReport {
        var report = RecoveryReport()
        let operations = try await database.pendingOperations(rootID: rootID)
        try await fileStore.sweepUnreferencedStages(referencedPaths: Set(operations.map(\.stagePath)))
        for operation in operations {
            let outcome: Outcome
            do { outcome = try await recover(operation) } catch { outcome = .unresolved }
            switch outcome {
            case .recovered: report = RecoveryReport(recovered: report.recovered + [operation.id], conflicts: report.conflicts, unresolved: report.unresolved)
            case .conflict: report = RecoveryReport(recovered: report.recovered, conflicts: report.conflicts + [operation.id], unresolved: report.unresolved)
            case .unresolved: report = RecoveryReport(recovered: report.recovered, conflicts: report.conflicts, unresolved: report.unresolved + [operation.id])
            }
        }
        for move in try await database.pendingScopeMoves(rootID: rootID) {
            let outcome: Outcome
            do { outcome = try await recover(move) } catch { outcome = .unresolved }
            switch outcome {
            case .recovered: report = RecoveryReport(recovered: report.recovered + [move.id], conflicts: report.conflicts, unresolved: report.unresolved)
            case .unresolved: report = RecoveryReport(recovered: report.recovered, conflicts: report.conflicts, unresolved: report.unresolved + [move.id])
            case .conflict: break
            }
        }
        for move in try await database.pendingModuleMoves(rootID: rootID) {
            do {
                if try await ModuleMoveRecovery.recover(move, database: database, fileStore: fileStore) {
                    report = RecoveryReport(recovered: report.recovered + [move.id], conflicts: report.conflicts, unresolved: report.unresolved)
                } else {
                    report = RecoveryReport(recovered: report.recovered, conflicts: report.conflicts, unresolved: report.unresolved + [move.id])
                }
            } catch {
                report = RecoveryReport(recovered: report.recovered, conflicts: report.conflicts, unresolved: report.unresolved + [move.id])
            }
        }
        return report
    }

    private enum Outcome { case recovered, conflict, unresolved }

    private func recover(_ operation: PendingOperation) async throws -> Outcome {
        let stage = try await fileStore.stagedArtifact(at: operation.stagePath)
        let destination = try await fileStore.inspect(operation.destination)
        let baseline = Baseline(remoteID: operation.remoteID, relativePath: operation.destination, sha256: operation.remoteSHA256, remoteRevision: operation.remoteRevision, courseID: operation.courseID, moduleID: operation.moduleID)

        switch operation.phase {
        case .prepared:
            return try await recoverPrepared(operation, stage: stage, destination: destination, baseline: baseline)
        case .committed:
            guard let stage else {
                try await database.finishOperation(id: operation.id)
                return .recovered
            }
            guard case .present(let expectedHash) = operation.expectedLocal, stage.sha256 == expectedHash else { return .unresolved }
            try await fileStore.discard(stage)
            try await database.finishOperation(id: operation.id)
            return .recovered
        }
    }

    private func recover(_ move: PendingScopeMove) async throws -> Outcome {
        guard let scope = try await database.scope(rootID: move.rootID, courseID: move.courseID),
              scope.localFolder == move.oldFolder,
              let managedDirectory = scope.managedDirectory else { return .unresolved }
        let old = try await fileStore.topLevelDirectoryState(move.oldFolder)
        let new = try await fileStore.topLevelDirectoryState(move.newFolder)
        switch (old, new) {
        case (.directory, .missing):
            guard try await fileStore.topLevelDirectoryIdentity(move.oldFolder) == managedDirectory else { return .unresolved }
            try await fileStore.renameTopLevelDirectory(from: move.oldFolder, to: move.newFolder)
            guard try await fileStore.topLevelDirectoryIdentity(move.newFolder) == managedDirectory else { return .unresolved }
            try await database.commitScopeMove(move)
            return .recovered
        case (.missing, .directory):
            guard try await fileStore.topLevelDirectoryIdentity(move.newFolder) == managedDirectory else { return .unresolved }
            try await database.commitScopeMove(move)
            return .recovered
        default:
            return .unresolved
        }
    }

    private func recoverPrepared(_ operation: PendingOperation, stage: StagedArtifact?, destination: LocalState, baseline: Baseline) async throws -> Outcome {
        guard let stage else {
            let incomingPath = try RelativePath(internal: ".beepbar/conflicts/\(operation.id.uuidString)/\(operation.destination.value)")
            if let incoming = try await fileStore.conflictArtifact(at: incomingPath),
               incoming.sha256 == operation.remoteSHA256,
               destination != .present(sha256: operation.remoteSHA256) {
                let conflict = ConflictRecord(id: operation.id, rootID: operation.rootID, remoteID: operation.remoteID, relativePath: operation.destination, incomingPath: incomingPath, baseSHA256: operation.expectedLocal.sha256, localSHA256: destination.sha256, remoteSHA256: operation.remoteSHA256, remoteRevision: operation.remoteRevision, detectedAt: Date(), status: .open)
                try await database.finishAsConflict(id: operation.id, conflict: conflict)
                return .conflict
            }
            if destination == .present(sha256: operation.remoteSHA256) {
                try await database.markCommitted(id: operation.id, baseline: baseline)
                try await database.finishOperation(id: operation.id)
                return .recovered
            }
            // The download is gone and was never kept aside as a conflict: the row has nothing
            // left to finish. Either the install or conflict copy failed after journaling and the
            // engine discarded the staged download (no crash needed), or a crash came right after
            // installing and the user then edited or deleted the file before BeepBar started.
            // Leaving it unresolved blocked every sync behind "Intervento richiesto" until another
            // folder was chosen. Dropping it leaves the decision to the next sync, which
            // compares the file as it is now with Moodle and the last synced version, and never
            // overwrites a local change. A conflict copy with other bytes is not something this
            // sequence writes, so that stays unresolved.
            if try await fileStore.conflictArtifact(at: incomingPath) == nil {
                try await database.finishOperation(id: operation.id)
                return .recovered
            }
            return .unresolved
        }

        if stage.sha256 != operation.remoteSHA256 {
            guard case .present(let expectedHash) = operation.expectedLocal, stage.sha256 == expectedHash else { return .unresolved }
            guard destination != operation.expectedLocal else { return .unresolved }
            try await database.markCommitted(id: operation.id, baseline: baseline)
            try await fileStore.discard(stage)
            try await database.finishOperation(id: operation.id)
            return .recovered
        }
        if destination == operation.expectedLocal {
            // Recovery replaces a file only when the sequence that journaled the row would have:
            // over the last synced version (a sync's install), or over the copy an open conflict
            // recorded (the user chose Moodle's version). Releases before this check journaled a
            // conflict with the user's edit as `expectedLocal`; such a row must not install over
            // the edit, so anything else is kept and recorded as a conflict.
            if case .present(let hash) = destination, !(try await mayReplace(hash, for: operation)) {
                let synced = try await database.baseline(rootID: operation.rootID, remoteID: operation.remoteID)
                return try await preserveConflict(operation, stage: stage, destination: destination, base: synced?.sha256)
            }
            switch try await fileStore.install(stage, at: operation.destination, expectedLocal: operation.expectedLocal) {
            case .installedNew:
                try await database.markCommitted(id: operation.id, baseline: baseline)
                try await database.finishOperation(id: operation.id)
                return .recovered
            case .installedReplacing(let rollback):
                try await database.markCommitted(id: operation.id, baseline: baseline)
                try await fileStore.discard(rollback)
                try await database.finishOperation(id: operation.id)
                return .recovered
            case .localChanged:
                return try await preserveConflict(operation, stage: stage, destination: try await fileStore.inspect(operation.destination))
            }
        }
        return try await preserveConflict(operation, stage: stage, destination: destination)
    }

    /// Whether a prepared row may install over the file it found, `hash`: the last synced version,
    /// or the local copy of an open conflict on the same file whose Moodle version is the one
    /// being installed (`ConflictResolver.useRemote` installs exactly that). Matching the download
    /// too matters: an older release's conflict row for a newer Moodle version would otherwise
    /// pass on the earlier conflict's local copy, which is the user's edit.
    private func mayReplace(_ hash: String, for operation: PendingOperation) async throws -> Bool {
        if try await database.baseline(rootID: operation.rootID, remoteID: operation.remoteID)?.sha256 == hash { return true }
        return try await database.conflicts(rootID: operation.rootID).contains {
            $0.remoteID == operation.remoteID && $0.relativePath == operation.destination && $0.localSHA256 == hash && $0.remoteSHA256 == operation.remoteSHA256
        }
    }

    /// `base` overrides the conflict's last synced version; `.some(nil)` means there is none, while
    /// leaving it out uses the row's expected file.
    private func preserveConflict(_ operation: PendingOperation, stage: StagedArtifact, destination: LocalState, base: String?? = nil) async throws -> Outcome {
        let incoming = try await fileStore.preserveAsConflict(stage, conflictID: operation.id, at: operation.destination)
        let conflict = ConflictRecord(id: operation.id, rootID: operation.rootID, remoteID: operation.remoteID, relativePath: operation.destination, incomingPath: incoming, baseSHA256: base ?? operation.expectedLocal.sha256, localSHA256: destination.sha256, remoteSHA256: operation.remoteSHA256, remoteRevision: operation.remoteRevision, detectedAt: Date(), status: .open)
        try await database.finishAsConflict(id: operation.id, conflict: conflict)
        return .conflict
    }
}

private extension LocalState {
    var sha256: String? {
        if case .present(let sha256) = self { return sha256 }
        return nil
    }
}
