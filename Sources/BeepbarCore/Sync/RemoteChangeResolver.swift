import Foundation

/// A choice offered for a `RemoteChange` in the Conflicts page.
public enum RemoteChangeAction: String, Sendable, Equatable {
    /// `moved`: "Sposta la mia versione nella nuova cartella".
    case moveMine
    /// `moved`: "Lascia qui".
    case leaveHere
    /// `removed`: "Tieni".
    case keep
    /// `removed`: "Sposta nel Cestino"; `reuploaded`: "Sposta la mia nel Cestino".
    case trash
    /// `reuploaded`: "Sostituisci la copia nuova con la mia versione".
    case replaceNewCopy
    /// `reuploaded`: "Tieni entrambe".
    case keepBoth

    public static func available(for kind: RemoteChange.Kind) -> [RemoteChangeAction] {
        switch kind {
        case .moved: [.moveMine, .leaveHere]
        case .removed: [.keep, .trash]
        case .reuploaded: [.replaceNewCopy, .keepBoth, .trash]
        }
    }
}

public enum RemoteChangeOutcome: Sendable, Equatable {
    /// Done. For a move, where the file is now.
    case done(RelativePath?)
    /// The file changed since the entry was shown: nothing was done, and the entry now shows the
    /// current contents so the user can choose again knowingly.
    case fileChanged
    /// The entry no longer applies (the file was moved or deleted meanwhile): it was closed.
    case gone
    /// `replaceNewCopy`: the new copy is not downloaded yet, or was edited, so it is not replaced.
    case newCopyNotReplaceable
    /// `trash`: no separate downloaded regular copy survives, so the user’s copy stays.
    case newCopyUnavailable
}

/// Carries out the user's choice about a file Moodle moved or removed. Every action runs under the
/// root's operation gate and re-checks the file first (guarantee 3 of the sync behavior document):
/// an action that would move or trash a file only runs while the file still has the contents the
/// entry was made with, and nothing is ever overwritten.
public actor RemoteChangeResolver {
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate

    public init(database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate) {
        self.database = database
        self.fileStore = fileStore
        self.gate = gate
    }

    public func perform(_ action: RemoteChangeAction, on id: UUID, rootID: UUID) async throws -> RemoteChangeOutcome {
        try await gate.withLease(.resolving(id)) { [database, fileStore] in
            try await Self.perform(action, on: id, rootID: rootID, database: database, fileStore: fileStore)
        }
    }

    private static func perform(_ action: RemoteChangeAction, on id: UUID, rootID: UUID, database: SyncDatabase, fileStore: FileStore) async throws -> RemoteChangeOutcome {
        try await RemoteMoveJournal.recover(rootID: rootID, database: database, fileStore: fileStore)
        guard let change = try await database.remoteChange(rootID: rootID, id: id) else { return .gone }
        guard RemoteChangeAction.available(for: change.kind).contains(action) else { throw SyncDatabaseError.execution }
        guard let baseline = try await database.baseline(rootID: rootID, remoteID: change.remoteID), baseline.relativePath == change.relativePath else {
            try await database.deleteRemoteChange(rootID: rootID, id: id)
            return .gone
        }
        switch action {
        case .leaveHere:
            try await database.keepInPlace(change)
            return .done(nil)
        case .keep, .keepBoth:
            // Nothing on disk changes, so there is nothing to re-check: the file just stops being
            // tracked and becomes the user's own.
            try await database.stopTracking(change, rememberingPath: true)
            return .done(nil)
        case .moveMine, .trash, .replaceNewCopy:
            break
        }
        guard case .present(let snapshot) = try await fileStore.snapshotRegularFile(change.relativePath) else {
            try await database.deleteRemoteChange(rootID: rootID, id: id)
            return .gone
        }
        guard snapshot.sha256 == change.localSHA256 else {
            try await database.updateRemoteChangeContents(rootID: rootID, id: id, sha256: snapshot.sha256, isLocallyModified: snapshot.sha256 != baseline.sha256)
            return .fileChanged
        }
        switch action {
        case .trash:
            if change.kind == .reuploaded {
                guard let newID = change.newRemoteID,
                      let twin = try await database.baseline(rootID: rootID, remoteID: newID),
                      twin.relativePath.comparisonKey != change.relativePath.comparisonKey,
                      (try? await fileStore.containsRegularFile(twin.relativePath)) == true else { return .newCopyUnavailable }
            }
            do { try await fileStore.trashRegularFile(change.relativePath, expected: snapshot) }
            catch FileStoreError.localChanged { return .fileChanged }
            try await database.stopTracking(change)
            return .done(nil)
        case .moveMine:
            guard let target = change.targetPath else { throw SyncDatabaseError.execution }
            for _ in 0..<1000 {
                try Task.checkCancellation()
                let destination = try await freePath(for: target, excluding: change.remoteID, rootID: rootID, database: database, fileStore: fileStore)
                let step = PendingRemoteMove(batchID: UUID(), remoteID: change.remoteID, from: change.relativePath, to: destination, sha256: snapshot.sha256, placement: change.placement)
                try await database.beginRemoteMoves(rootID: rootID, [step])
                do {
                    try await fileStore.moveRegularFile(from: change.relativePath, to: destination, expected: snapshot)
                } catch {
                    try await database.discardRemoteMoves(rootID: rootID, remoteIDs: [change.remoteID])
                    if case FileStoreError.destinationExists = error { continue }
                    if case FileStoreError.localChanged = error { return .fileChanged }
                    throw error
                }
                try await database.commitRemoteMoves(rootID: rootID, [step])
                try? await fileStore.removeEmptyParentDirectories(of: change.relativePath)
                return .done(destination)
            }
            throw FileStoreError.destinationExists
        case .replaceNewCopy:
            // The new copy is only ever replaced while it is exactly what was downloaded, so the
            // one file that goes to the Trash is one the user never touched.
            guard let newID = change.newRemoteID, let newBaseline = try await database.baseline(rootID: rootID, remoteID: newID),
                  case .present(let newCopy) = try await fileStore.snapshotRegularFile(newBaseline.relativePath), newCopy.sha256 == newBaseline.sha256 else {
                return .newCopyNotReplaceable
            }
            do { try await fileStore.trashRegularFile(newBaseline.relativePath, expected: newCopy) }
            catch FileStoreError.localChanged { return .newCopyNotReplaceable }
            // A changed source stays at its original path. The downloaded copy is restored by
            // the next sync if the move cannot finish after it goes to the Trash.
            do { try await fileStore.moveRegularFile(from: change.relativePath, to: newBaseline.relativePath, expected: snapshot) }
            catch FileStoreError.localChanged { return .fileChanged }
            catch FileStoreError.destinationExists { return .newCopyNotReplaceable }
            // The new file's baseline stays as downloaded, so the user's version counts as their
            // edit of it: a later update by the teacher becomes a conflict, never an overwrite.
            try await database.stopTracking(RemoteChange(id: change.id, rootID: rootID, courseID: change.courseID, remoteID: change.remoteID, kind: change.kind, relativePath: change.relativePath, localSHA256: change.localSHA256, isLocallyModified: true))
            try? await fileStore.removeEmptyParentDirectories(of: change.relativePath)
            return .done(newBaseline.relativePath)
        case .leaveHere, .keep, .keepBoth:
            return .done(nil)
        }
    }

    /// `target`, or the first numbered name (`Slide (1).pdf`, …) that no other tracked file, open
    /// conflict or file on disk holds: never onto another file.
    private static func freePath(for target: RelativePath, excluding remoteID: String, rootID: UUID, database: SyncDatabase, fileStore: FileStore) async throws -> RelativePath {
        var taken = Set(try await database.baselines(rootID: rootID).values.filter { $0.remoteID != remoteID }.map(\.relativePath.comparisonKey))
        taken.formUnion(try await database.conflicts(rootID: rootID).map(\.relativePath.comparisonKey))
        var candidate = target
        for suffix in 1...1000 {
            if !taken.contains(candidate.comparisonKey), !(try await fileStore.downloadDestinationIsOccupied(candidate)) { return candidate }
            candidate = try LocalPathPolicy.destinationByAddingSuffix(suffix, to: target)
        }
        throw SyncDatabaseError.execution
    }
}
