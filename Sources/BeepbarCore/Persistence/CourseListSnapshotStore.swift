import Foundation

/// The file that keeps `CourseListSnapshot` between launches: `course-list.json` in BeepBar's
/// Application Support folder, next to `sync.sqlite` and the token (#98).
///
/// An actor, so the encode/decode and file work run off the main actor: the controller awaits a
/// result and never touches the file itself. Written like the token: created 0600, replaced
/// whole with one rename, so a crash never leaves a half list and the names are never on disk
/// under default permissions. The file holds course names and ids only, never the token.
///
/// Every rejected file (unreadable, foreign identity, too old, too large, future version) is
/// deleted on load, so a bad file is paid for once and an old account's list cannot linger.
///
/// Late saves: the controller saves without waiting, so a save started before a sign-out can
/// reach the actor after the deletion the sign-out asked for. Actor calls from separate tasks
/// carry no ordering promise, so each save carries the controller's epoch and `delete` retires
/// every epoch below the one it is given: a retired save is refused whichever call arrives first,
/// and the list of a signed-out account is never written back.
public actor CourseListSnapshotStore {
    public static let fileName = "course-list.json"
    private static let tempPrefix = ".course-list-"
    private static let tempSuffix = ".tmp"

    public enum LoadOutcome: Equatable, Sendable {
        /// No file: a first launch, or the list was cleared.
        case missing
        case restored(CourseListSnapshot)
        /// A file existed and was refused for this reason; it has been removed.
        case discarded(CourseListSnapshotCodec.DecodeError)
    }

    /// Resolved on each use, so creating the store costs nothing and a test or a preview run can
    /// point it at a throwaway folder.
    private let directory: @Sendable () throws -> URL
    /// What the file holds, as this store last wrote, restored or read it, so `save` can skip a
    /// rewrite of an unchanged list (`CourseListSnapshotCodec.shouldSave`). Forgotten whenever
    /// the file goes. Filled from the file by the first `save` of a launch when nothing filled it
    /// yet: a sync started from the menu before the window ever opened would otherwise rewrite an
    /// unchanged list on every launch.
    private var lastWritten: CourseListSnapshot?
    /// The age `removeIfExpired` gives a file it could not decode (another version, damaged): its
    /// modification date, since the file is only ever replaced whole. Remembered, so such a file
    /// is read once per launch, not at every sync. Forgotten with `lastWritten`.
    private var undecodedFileDate: Date?
    /// Saves made for an epoch below this are refused (see the type's comment). Only grows.
    private var firstLiveEpoch = 0

    public init(directory: @escaping @Sendable () throws -> URL) {
        self.directory = directory
    }

    /// The saved list for `identity`, if there is one this launch may show.
    public func load(expecting identity: CourseListSnapshot.Identity, now: Date = Date()) -> LoadOutcome {
        guard let url = try? directory().appendingPathComponent(Self.fileName), FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let snapshot = try read(url, expecting: identity, now: now)
            lastWritten = snapshot
            undecodedFileDate = nil
            return .restored(snapshot)
        } catch {
            try? FileManager.default.removeItem(at: url)
            lastWritten = nil
            undecodedFileDate = nil
            return .discarded(error as? CourseListSnapshotCodec.DecodeError ?? .unreadable)
        }
    }

    /// The file's snapshot for `identity`, or the reason it is refused. The size is checked
    /// before the bytes are read: the limit exists so a damaged file is never loaded into memory,
    /// which reading it first would defeat.
    private func read(_ url: URL, expecting identity: CourseListSnapshot.Identity, now: Date) throws -> CourseListSnapshot {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > CourseListSnapshotCodec.maximumBytes {
            throw CourseListSnapshotCodec.DecodeError.tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw CourseListSnapshotCodec.DecodeError.unreadable }
        return try CourseListSnapshotCodec.decode(data, expecting: identity, now: now)
    }

    /// Writes `courses` as the confirmed list for `identity`, unless an equal list was written
    /// recently or `epoch` was retired by `delete`. Returns whether a file was written. More
    /// courses than the limit are not saved and remove any older file, so a shorter stale list
    /// cannot survive a longer live one.
    @discardableResult
    public func save(_ courses: [RemoteCourseSummary], identity: CourseListSnapshot.Identity, epoch: Int = 0, now: Date = Date()) throws -> Bool {
        guard epoch >= firstLiveEpoch else { return false }
        if lastWritten == nil, let url = try? directory().appendingPathComponent(Self.fileName), FileManager.default.fileExists(atPath: url.path) {
            // Only a peek: a file this save is about to replace is not worth deleting first.
            lastWritten = try? read(url, expecting: identity, now: now)
        }
        guard CourseListSnapshotCodec.shouldSave(courses, identity: identity, after: lastWritten, now: now) else { return false }
        let snapshot = CourseListSnapshot(identity: identity, savedAt: now, courses: courses)
        let data: Data
        do {
            data = try CourseListSnapshotCodec.encode(snapshot)
        } catch CourseListSnapshotCodec.EncodeError.tooManyCourses {
            try removeFiles()
            return false
        }
        let folder = try directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A crash between creating and renaming a temporary file leaves it behind; like the token
        // store, the next write sweeps them up instead of waiting for a sign-out.
        try? removeTemporaries(in: folder)
        let temporary = folder.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, folder.appendingPathComponent(Self.fileName).path) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        lastWritten = snapshot
        undecodedFileDate = nil
        return true
    }

    /// Deletes the file once it is older than `CourseListSnapshotCodec.maximumAge`, whoever it
    /// belongs to, and returns whether it did. Storage limitation (#98, PR #138): `load` only runs
    /// when the window opens, so without this a user who only syncs from the menu bar would keep
    /// an expired list on disk for as long as the account stays signed in.
    ///
    /// Nearly free when nothing is due: no file is one `stat`, and once the file's date is known
    /// no further read happens. A file that can't be decoded (a newer format after a downgrade,
    /// damage) is aged by its modification date instead, so it can't outlive the limit either.
    /// Retires no epoch: the account is still the same, and its next confirmed list may be saved.
    @discardableResult
    public func removeIfExpired(now: Date = Date()) -> Bool {
        guard let url = try? directory().appendingPathComponent(Self.fileName), FileManager.default.fileExists(atPath: url.path) else {
            lastWritten = nil
            undecodedFileDate = nil
            return false
        }
        if lastWritten == nil, undecodedFileDate == nil {
            if let snapshot = try? readAnyIdentity(url) {
                lastWritten = snapshot
            } else {
                // No date at all: never expires here, and `load` still refuses the file.
                undecodedFileDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantFuture
            }
        }
        guard let date = lastWritten?.savedAt ?? undecodedFileDate, CourseListSnapshotCodec.isExpired(savedAt: date, now: now) else { return false }
        lastWritten = nil
        undecodedFileDate = nil
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// The file's snapshot whatever its identity, within the size and version limits: only its
    /// date is used, to decide whether it is too old to keep.
    private func readAnyIdentity(_ url: URL) throws -> CourseListSnapshot {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > CourseListSnapshotCodec.maximumBytes {
            throw CourseListSnapshotCodec.DecodeError.tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw CourseListSnapshotCodec.DecodeError.unreadable }
        return try CourseListSnapshotCodec.decodeAnyIdentity(data)
    }

    /// Removes the list and any temporary file a crash left behind, and refuses from now on
    /// every save made for an epoch below `epoch` (sign-out, another university, a new sign-in).
    /// No file is not an error. The retirement holds even when the removal throws, so a failed
    /// deletion can still not be followed by a late write of the old account's list.
    public func delete(retiringEpochsBelow epoch: Int = 0) throws {
        firstLiveEpoch = max(firstLiveEpoch, epoch)
        try removeFiles()
    }

    private func removeFiles() throws {
        lastWritten = nil
        undecodedFileDate = nil
        let folder = try directory()
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try removeTemporaries(in: folder)
        let url = folder.appendingPathComponent(Self.fileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func removeTemporaries(in folder: URL) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
