import Foundation

/// The file that keeps `CourseListSnapshot` between launches: `course-list.json` in BeepBar's
/// Application Support folder, next to `sync.sqlite` and the token (#98).
///
/// An actor, so a save racing a delete (sign out, then sign in again at once) is applied in call
/// order and the encode/decode work runs off the main actor: the controller awaits a result and
/// never touches the file itself. Written like the token: created 0600, replaced whole with one
/// rename, so a crash never leaves a half list and the names are never on disk under default
/// permissions. The file holds course names and ids only, never the token.
///
/// Every rejected file (unreadable, foreign identity, too old, too large, future version) is
/// deleted on load, so a bad file is paid for once and an old account's list cannot linger.
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

    /// Resolved on each use, so creating the store costs nothing and a preview run can point it
    /// at a throwaway folder.
    private let directory: @Sendable () throws -> URL
    /// What this store last wrote or restored, so `save` can skip a rewrite of an unchanged list
    /// (`CourseListSnapshotCodec.shouldSave`). Reset by `delete`, never trusted across launches.
    private var lastWritten: CourseListSnapshot?

    public init(directory: @escaping @Sendable () throws -> URL) {
        self.directory = directory
    }

    /// The saved list for `identity`, if there is one this launch may show.
    public func load(expecting identity: CourseListSnapshot.Identity, now: Date = Date()) -> LoadOutcome {
        guard let url = try? directory().appendingPathComponent(Self.fileName), FileManager.default.fileExists(atPath: url.path) else { return .missing }
        // The size is checked before the bytes are read: the limit exists so a damaged file is
        // never loaded into memory, which reading it first would defeat.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > CourseListSnapshotCodec.maximumBytes {
            try? FileManager.default.removeItem(at: url)
            return .discarded(.tooLarge)
        }
        guard let data = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            return .discarded(.unreadable)
        }
        do {
            let snapshot = try CourseListSnapshotCodec.decode(data, expecting: identity, now: now)
            lastWritten = snapshot
            return .restored(snapshot)
        } catch let error as CourseListSnapshotCodec.DecodeError {
            try? FileManager.default.removeItem(at: url)
            return .discarded(error)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .discarded(.unreadable)
        }
    }

    /// Writes `courses` as the confirmed list for `identity`, unless an equal list was written
    /// recently. Returns whether a file was written. More courses than the limit are not saved
    /// and remove any older file, so a shorter stale list cannot survive a longer live one.
    @discardableResult
    public func save(_ courses: [RemoteCourseSummary], identity: CourseListSnapshot.Identity, now: Date = Date()) throws -> Bool {
        guard CourseListSnapshotCodec.shouldSave(courses, identity: identity, after: lastWritten, now: now) else { return false }
        let snapshot = CourseListSnapshot(identity: identity, savedAt: now, courses: courses)
        let data: Data
        do {
            data = try CourseListSnapshotCodec.encode(snapshot)
        } catch CourseListSnapshotCodec.EncodeError.tooManyCourses {
            try delete()
            return false
        }
        let folder = try directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
        return true
    }

    /// Removes the list and any temporary file a crash left behind. No file is not an error.
    public func delete() throws {
        lastWritten = nil
        let folder = try directory()
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let url = folder.appendingPathComponent(Self.fileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
