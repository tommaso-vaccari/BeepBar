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

/// Completes or drops the moves a crash interrupted (see `PendingRemoteMove`).
enum RemoteMoveJournal {
    /// A move counts as done when its destination holds the moved contents and, for a single move,
    /// its origin no longer does; the two halves of a swap are done together or not at all. A single
    /// move whose origin is gone and whose destination holds something else also happened: the file
    /// was edited after it moved, so the baseline follows it and the edit is then a local change. Any
    /// other readable state is dropped and the files are looked at afresh by the caller, whose
    /// three-way comparison keeps every edited file (as before #171).
    ///
    /// Only a path that cannot be read (a symlink, a folder, a permission error) keeps its row and
    /// fails recovery, so a transient read error never loses a completed move (R-004). Readable
    /// states never block: an edited or deleted file used to keep the row forever, and with it every
    /// sync, conflict choice and folder tidy-up of that folder, with nothing the user could do.
    /// Every batch is settled before the first read error is reported, so one unreadable batch does
    /// not hold back the others.
    static func recover(rootID: UUID, database: SyncDatabase, fileStore: FileStore) async throws {
        let pending = try await database.pendingRemoteMoves(rootID: rootID)
        guard !pending.isEmpty else { return }
        var unreadable: Error?
        for batch in Dictionary(grouping: pending, by: \.batchID).values {
            var arrived = true
            var movedThenEdited = batch.count == 1
            do {
                for move in batch {
                    let destination = try await fileStore.snapshotRegularFile(move.to, checksCancellation: false)
                    let source = try await fileStore.snapshotRegularFile(move.from, checksCancellation: false)
                    let destinationMatches: Bool
                    if case .present(let there) = destination { destinationMatches = there.sha256 == move.sha256 }
                    else { destinationMatches = false }
                    let sourceMatches: Bool
                    if case .present(let left) = source { sourceMatches = left.sha256 == move.sha256 }
                    else { sourceMatches = false }
                    arrived = arrived && destinationMatches && (batch.count > 1 || !sourceMatches)
                    movedThenEdited = movedThenEdited && destination != .missing && source == .missing
                }
            } catch {
                unreadable = unreadable ?? error
                continue
            }
            if arrived || movedThenEdited {
                try await database.commitRemoteMoves(rootID: rootID, batch)
                if let move = batch.first, batch.count == 1 { try? await fileStore.removeEmptyParentDirectories(of: move.from) }
            } else {
                try await database.discardRemoteMoves(rootID: rootID, remoteIDs: batch.map(\.remoteID))
            }
        }
        if let unreadable { throw unreadable }
    }
}
