import Foundation

public enum ManualSyncOutcome: Sendable, Equatable {
    case installedNew
    case installedReplacing
    case preservedLocal
    case adoptedRemoteBaseline
    case conflict(ConflictRecord)
    case unchanged
    case skipped(String)
}

public actor ManualSyncEngine {
    private let rootID: UUID
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let downloader: RemoteDownloader
    private let networkAccess: NetworkAccess
    private let transactions: SyncTransactionCoordinator

    public init(rootID: UUID, database: SyncDatabase, fileStore: FileStore, downloader: RemoteDownloader, networkAccess: NetworkAccess) {
        self.rootID = rootID
        self.database = database
        self.fileStore = fileStore
        self.downloader = downloader
        self.networkAccess = networkAccess
        transactions = SyncTransactionCoordinator(database: database, fileStore: fileStore)
    }

    public func sync(file: RemoteFileCandidate, destination: RelativePath, token: String) async throws -> ManualSyncOutcome {
        try Task.checkCancellation()
        guard file.isSupported else { return .skipped(file.ineligibilityReason ?? tr("materiale non supportato", "unsupported material")) }
        guard !(try await database.hasOpenConflict(rootID: rootID, remoteID: file.id, revision: file.observedRevision)) else { return .skipped(tr("conflitto già aperto", "conflict already open")) }
        let baseline = try await database.baseline(rootID: rootID, remoteID: file.id)
        if let oldPath = baseline?.relativePath, oldPath != destination,
           try await fileStore.containsRegularFile(oldPath) {
            throw SyncDatabaseError.execution
        }
        let local = try await fileStore.inspect(destination)
        if let baseline, baseline.remoteRevision == file.observedRevision, case .present = local {
            return try await apply(SyncPlanner.decide(baseline: baseline, local: local, remote: RemoteState(sha256: baseline.sha256, revision: file.observedRevision)), remoteID: file.id, courseID: file.courseID, moduleID: file.moduleID, baseline: baseline, destination: destination, local: local, remote: RemoteState(sha256: baseline.sha256, revision: file.observedRevision), artifact: nil)
        }
        try Task.checkCancellation()
        let downloaded = try await downloader.download(file, token: token, access: networkAccess)
        // The import copies the body out of the temporary file, so nothing else ever removes it.
        defer { try? FileManager.default.removeItem(at: downloaded.temporaryURL) }
        try Task.checkCancellation()
        let artifact = try await fileStore.importDownloadedFile(at: downloaded.temporaryURL, expectedSize: downloaded.expectedSize, maximumSize: downloader.maximumSize)
        let remote = RemoteState(sha256: artifact.sha256, revision: file.observedRevision)
        do {
            try Task.checkCancellation()
            return try await apply(SyncPlanner.decide(baseline: baseline, local: local, remote: remote), remoteID: file.id, courseID: file.courseID, moduleID: file.moduleID, baseline: baseline, destination: destination, local: local, remote: remote, artifact: artifact)
        } catch {
            try? await fileStore.discard(artifact)
            throw error
        }
    }

    private func apply(_ decision: SyncDecision, remoteID: String, courseID: Int64, moduleID: Int64, baseline: Baseline?, destination: RelativePath, local: LocalState, remote: RemoteState, artifact: StagedArtifact?) async throws -> ManualSyncOutcome {
        switch decision {
        case .noOp:
            if let artifact { try await fileStore.discard(artifact) }
            return .unchanged
        case .preserveLocal:
            if let artifact { try await fileStore.discard(artifact) }
            // The remote bytes still match the baseline, so only the revision moved. Catch the
            // baseline up or the unchanged remote gets re-downloaded on every following run.
            if let baseline, baseline.remoteRevision != remote.revision {
                try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: remoteID, relativePath: destination, sha256: baseline.sha256, remoteRevision: remote.revision, courseID: courseID, moduleID: moduleID))
            }
            return .preservedLocal
        case .adoptRemoteBaseline:
            if let artifact { try await fileStore.discard(artifact) }
            try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: remoteID, relativePath: destination, sha256: remote.sha256, remoteRevision: remote.revision, courseID: courseID, moduleID: moduleID))
            return .adoptedRemoteBaseline
        case .installRemote:
            guard let artifact else { throw FileStoreError.invalidStage }
            switch try await transactions.install(rootID: rootID, remoteID: remoteID, courseID: courseID, moduleID: moduleID, destination: destination, expectedLocal: local, remote: remote, artifact: artifact) {
            case .installedNew: return .installedNew
            case .installedReplacing: return .installedReplacing
            case .conflict(let conflict): return .conflict(conflict)
            }
        case .conflict:
            guard let artifact else { throw FileStoreError.invalidStage }
            return .conflict(try await transactions.recordConflict(rootID: rootID, remoteID: remoteID, courseID: courseID, moduleID: moduleID, destination: destination, local: local, remote: remote, artifact: artifact))
        }
    }
}
