import Foundation

/// The file that keeps the Polimi session of the Recordings feature between launches:
/// `recordings-session.plist` in BeepBar's Application Support folder, next to the WeBeep token.
///
/// It holds Polimi sign-on cookies (`RecmanSessionCodec`), so it is written like the token: 0600
/// from the moment it exists, in a 0700 folder, replaced whole so a crash never leaves half a
/// session. It is a file and not the Keychain on purpose: reading it never prompts, and it is
/// gone the moment the feature is turned off or the WeBeep account is disconnected.
///
/// Nothing touches the disk until a method is called: the controller reads the file only when
/// the Recordings page needs the session, never at launch.
struct RecordingsSessionStore: Sendable {
    static let maximumAge: TimeInterval = 10 * 24 * 60 * 60
    static let fileName = "recordings-session.plist"
    private static let tempPrefix = ".recordings-session-"
    private static let tempSuffix = ".tmp"

    /// Resolved on each use, so creating the store costs nothing.
    let directory: @Sendable () throws -> URL

    /// BeepBar's real folder; tests pass a throwaway one instead. A `--ui-preview` run shares the
    /// installed app's bundle id but must never read or replace its Polimi session, so it gets a
    /// temporary folder, as `FileTokenStore` does for the token.
    static let standard = RecordingsSessionStore {
        if PreviewMode.isActive {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-recordings-preview", isDirectory: true)
        }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(FileTokenStore.directoryName, isDirectory: true)
    }

    /// The saved session, or nil when there is none.
    func load(now: Date = Date()) throws -> Data? {
        let url = try directory().appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if try expirationDate(at: url, now: now) <= now {
            try delete()
            return nil
        }
        return try Data(contentsOf: url)
    }

    func expirationDate(now: Date = Date()) throws -> Date? {
        let folder = try directory()
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            var temporary = folder.appendingPathComponent(name)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try temporary.setResourceValues(values)
        }
        let url = folder.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try expirationDate(at: url, now: now)
    }

    private func expirationDate(at file: URL, now: Date) throws -> Date {
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, let created = attributes[.creationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
        return created > now ? now : created.addingTimeInterval(Self.maximumAge)
    }

    func save(_ data: Data, now: Date = Date()) throws {
        let folder = try directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int ?? 0o700
        try FileManager.default.setAttributes([.posixPermissions: permissions & 0o700], ofItemAtPath: folder.path)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let destination = folder.appendingPathComponent(Self.fileName)
        let created = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.creationDate] as? Date) ?? now
        // Created with 0600 rather than chmod'ed afterwards, then moved into place in one step:
        // the cookies are never on disk under the default permissions, nor half written.
        var temporary = folder.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try temporary.setResourceValues(values)
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: temporary.path)
            try data.write(to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        if rename(temporary.path, destination.path) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes the session and any temporary file a crash left behind. No file is not an error.
    func delete(removeFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        let folder = try directory()
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        var failure: (any Error)?
        let url = folder.appendingPathComponent(Self.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try removeFile(url) } catch { failure = error }
        }
        do {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
                do { try removeFile(folder.appendingPathComponent(name)) } catch { failure = failure ?? error }
            }
        } catch { failure = failure ?? error }
        if let failure { throw failure }
    }
}
