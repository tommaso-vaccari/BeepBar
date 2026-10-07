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
    func load() throws -> Data? {
        let url = try directory().appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func save(_ data: Data) throws {
        let folder = try directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created with 0600 rather than chmod'ed afterwards, then moved into place in one step:
        // the cookies are never on disk under the default permissions, nor half written.
        let temporary = folder.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, folder.appendingPathComponent(Self.fileName).path) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes the session and any temporary file a crash left behind. No file is not an error.
    func delete() throws {
        let folder = try directory()
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let url = folder.appendingPathComponent(Self.fileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
