import Foundation

/// A tracked file that Moodle moved, removed, or deleted and uploaded again, in a way Beepbar will
/// not settle on its own because it could cost the user something (see "Il professore riorganizza
/// o rimuove materiali" in `docs/sync-behavior.en.md`). It waits in the Conflicts page until the
/// user chooses.
///
/// Entries are derived state: every sync that reads a course recomputes the entries that course
/// needs and drops the rest, so an entry closes by itself when the file comes back on Moodle or
/// the user moves or deletes it. Actions re-check the file before doing anything
/// (`RemoteChangeResolver`), since an entry can be stale by the time the user clicks.
public struct RemoteChange: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// Moodle moved the file, which the user had edited.
        case moved
        /// Moodle no longer lists the file.
        case removed
        /// Moodle lists a new file with the same contents elsewhere; the user's copy was edited.
        case reuploaded
    }

    public let id: UUID
    public let rootID: UUID
    public let courseID: Int64
    /// The tracked file the entry is about.
    public let remoteID: String
    public let kind: Kind
    /// Where the user's file is.
    public let relativePath: RelativePath
    /// `moved`: where Moodle now puts the file. `reuploaded`: where the new copy was downloaded.
    public let targetPath: RelativePath?
    /// `reuploaded`: the new file's remote id.
    public let newRemoteID: String?
    /// `moved`: the placement recorded once the user chooses, so the move is not proposed again.
    public let placement: RemotePlacement?
    /// The file's contents when the entry was made. An action that moves or trashes the file only
    /// runs while the file still has these contents.
    public let localSHA256: String
    public let isLocallyModified: Bool
    public let detectedAt: Date

    public init(id: UUID = UUID(), rootID: UUID, courseID: Int64, remoteID: String, kind: Kind, relativePath: RelativePath, targetPath: RelativePath? = nil, newRemoteID: String? = nil, placement: RemotePlacement? = nil, localSHA256: String, isLocallyModified: Bool, detectedAt: Date = Date()) {
        self.id = id
        self.rootID = rootID
        self.courseID = courseID
        self.remoteID = remoteID
        self.kind = kind
        self.relativePath = relativePath
        self.targetPath = targetPath
        self.newRemoteID = newRemoteID
        self.placement = placement
        self.localSHA256 = localSHA256
        self.isLocallyModified = isLocallyModified
        self.detectedAt = detectedAt
    }

    /// True when `other` asks the user the same question about the same file, so the existing
    /// entry (its id, date and recorded contents) is kept instead of being replaced.
    func describesSameChange(as other: RemoteChange) -> Bool {
        remoteID == other.remoteID && kind == other.kind && relativePath == other.relativePath
            && targetPath == other.targetPath && newRemoteID == other.newRemoteID && placement == other.placement
    }
}

/// One step of a move made to follow Moodle, written before the file is renamed so a crash in
/// between can be told apart from a user edit. Without it, a file moved to a numbered name, a
/// file moved by the user's choice (edited, so not the downloaded contents) or a swapped pair
/// would lose its baseline after a crash: the next run would look for it at the old path,
/// download Moodle's copy there again and leave the moved file untracked.
public struct PendingRemoteMove: Sendable, Equatable {
    /// Moves written together (the two halves of a swap) are recovered together.
    public let batchID: UUID
    public let remoteID: String
    public let from: RelativePath
    public let to: RelativePath
    /// The contents being moved.
    public let sha256: String
    /// Recorded with the move; `nil` for a file that only steps aside during a swap and still has
    /// to reach its own new place.
    public let placement: RemotePlacement?

    public init(batchID: UUID, remoteID: String, from: RelativePath, to: RelativePath, sha256: String, placement: RemotePlacement?) {
        self.batchID = batchID
        self.remoteID = remoteID
        self.from = from
        self.to = to
        self.sha256 = sha256
        self.placement = placement
    }
}

/// A path of an interrupted Moodle move that recovery could not read: a symbolic link, a folder,
/// or a permission error where the file should be. Recovery keeps the move's row and stops until
/// the path is readable again, so the app names the path and the user knows what to fix (release
/// review I-A4); before, the folder showed only "Sincronizzazione incompleta".
public struct RemoteMoveRecoveryError: Error, Sendable, Equatable {
    /// Relative to the sync folder, the path that could not be read.
    public let path: RelativePath
}

/// Completes or drops the moves a crash interrupted (see `PendingRemoteMove`).
enum RemoteMoveJournal {
    /// Settles every interrupted move from what is on disk. Recovery writes no file: it only moves
    /// a baseline (commit) or drops the row (discard), and the caller's three-way comparison then
    /// keeps every edited file (as before #171).
    ///
    /// - A single move is done when its destination holds the moved contents and its origin no
    ///   longer does. A single move whose origin is gone and whose destination holds something
    ///   else also happened: the file was edited after it moved, so the baseline follows it and the
    ///   edit is then a local change.
    /// - The two halves of a swap (`swapRegularFiles`, one atomic `RENAME_SWAP`) are done together
    ///   or not at all, so either file proves which side of the swap the disk is on. The swap is
    ///   done when one path holds the other's contents and neither still holds its own: an edit or
    ///   a deletion of one file after the swap no longer hides it (release review I-A3), and a
    ///   journal written just before a crash, or a swap reverted by a power loss, still shows its
    ///   own contents and is dropped. With both files edited or both gone nothing tells the two
    ///   sides apart, and the row is dropped as before.
    /// - Any other readable state is dropped.
    ///
    /// Only a path that cannot be read keeps its row and fails recovery with
    /// `RemoteMoveRecoveryError`, so a transient read error never loses a completed move (R-004).
    /// Readable states never block: an edited or deleted file used to keep the row forever, and
    /// with it every sync, conflict choice and folder tidy-up of that folder, with nothing the user
    /// could do (release review I-A1). Every batch is settled before the first read error is
    /// reported, so one unreadable batch does not hold back the others.
    ///
    /// Batches are visited in the database's order (by batch id), not a dictionary's: the order
    /// changes nothing for the user, but a fixed one lets a test put the unreadable batch first and
    /// prove the others are still settled behind it (#224).
    static func recover(rootID: UUID, database: SyncDatabase, fileStore: FileStore) async throws {
        let pending = try await database.pendingRemoteMoves(rootID: rootID)
        guard !pending.isEmpty else { return }
        let grouped = Dictionary(grouping: pending, by: \.batchID)
        var seen = Set<UUID>()
        let batchIDs = pending.map(\.batchID).filter { seen.insert($0).inserted }
        var unreadable: Error?
        for batchID in batchIDs {
            guard let batch = grouped[batchID] else { continue }
            var states: [(move: PendingRemoteMove, destination: FileSnapshotState, source: FileSnapshotState)] = []
            do {
                for move in batch {
                    states.append((move, try await read(move.to, fileStore: fileStore), try await read(move.from, fileStore: fileStore)))
                }
            } catch {
                unreadable = unreadable ?? error
                continue
            }
            if happened(states) {
                try await database.commitRemoteMoves(rootID: rootID, batch)
                if let move = batch.first, batch.count == 1 { try? await fileStore.removeEmptyParentDirectories(of: move.from) }
            } else {
                try await database.discardRemoteMoves(rootID: rootID, remoteIDs: batch.map(\.remoteID))
            }
        }
        if let unreadable { throw unreadable }
    }

    private static func read(_ path: RelativePath, fileStore: FileStore) async throws -> FileSnapshotState {
        do { return try await fileStore.snapshotRegularFile(path, checksCancellation: false) }
        catch { throw RemoteMoveRecoveryError(path: path) }
    }

    /// Whether the disk shows the batch's moves as made (see `recover`).
    static func happened(_ states: [(move: PendingRemoteMove, destination: FileSnapshotState, source: FileSnapshotState)]) -> Bool {
        func holds(_ state: FileSnapshotState, _ sha256: String) -> Bool {
            if case .present(let file) = state { return file.sha256 == sha256 }
            return false
        }
        if states.count == 1, let only = states.first {
            let arrived = holds(only.destination, only.move.sha256) && !holds(only.source, only.move.sha256)
            let movedThenEdited = only.destination != .missing && only.source == .missing
            return arrived || movedThenEdited
        }
        if states.count == 2, states[0].move.from == states[1].move.to, states[1].move.from == states[0].move.to {
            let swapped = states.contains { holds($0.destination, $0.move.sha256) }
            let unswapped = states.contains { holds($0.source, $0.move.sha256) }
            return swapped && !unswapped
        }
        // Not a shape `SyncCoordinator` writes: done only if every file arrived.
        return states.allSatisfy { holds($0.destination, $0.move.sha256) }
    }
}
