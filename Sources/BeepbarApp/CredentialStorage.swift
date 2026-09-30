import Foundation
import BeepbarCore

/// File-backed storage for the revocable Moodle mobile token.
enum FileTokenStore {
    /// BeepBar's folder in Application Support, holding the token and `sync.sqlite`.
    /// It keeps the old `Beepbar` spelling on purpose even though the product name is now
    /// `BeepBar` (#56): every existing install stores its token and sync database here, and a
    /// renamed folder would make BeepBar start signed out, with an empty database, on update.
    static let applicationSupportDirectoryName = "Beepbar"
    /// Overridable only from tests (`@testable import`) so they can point at an isolated,
    /// throwaway subdirectory instead of the developer's real Application Support folder.
    nonisolated(unsafe) static var directoryName = applicationSupportDirectoryName
    private static let fileName = "credential.token"
    private static let tempFilePrefix = ".credential-"
    private static let tempFileSuffix = ".tmp"

    static func save(_ token: String) throws {
        let url = try fileURL()
        guard let data = token.data(using: .utf8) else { throw CredentialStorageError.write }
        try? cleanUpOrphanedTempFiles(in: url.deletingLastPathComponent())
        // Written with 0600 permissions from the moment the file is created (rather than
        // written-then-chmod'd), and moved into place atomically, so there is never a window
        // where the token sits on disk under the default, more permissive umask.
        let tempURL = url.deletingLastPathComponent().appendingPathComponent("\(tempFilePrefix)\(UUID().uuidString)\(tempFileSuffix)")
        do {
            guard FileManager.default.createFile(atPath: tempURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CredentialStorageError.write
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL, options: .usingNewMetadataOnly)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw CredentialStorageError.write
        }
    }

    static func load(_ access: CredentialAccess) throws -> String {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { throw CredentialStorageError.absent }
        guard let data = try? Data(contentsOf: url) else { throw CredentialStorageError.write }
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw CredentialStorageError.corrupt
        }
        return token
    }

    static func containsCredential() throws -> Bool {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url) else { throw CredentialStorageError.write }
        guard let token = String(data: data, encoding: .utf8) else { return false }
        return !token.isEmpty
    }

    /// A crash or force-quit between creating the temp file and replacing the destination in
    /// `save()` leaves a stray `.tmp` behind; sweep those up before writing a new one.
    private static func cleanUpOrphanedTempFiles(in directory: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in contents where item.lastPathComponent.hasPrefix(tempFilePrefix) && item.lastPathComponent.hasSuffix(tempFileSuffix) {
            try FileManager.default.removeItem(at: item)
        }
    }

    static func delete(removeFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        let url = try fileURL()
        try cleanUpOrphanedTempFiles(in: url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) { try removeFile(url) }
    }

    private static func fileURL() throws -> URL {
        do {
            let directory = try applicationSupportDirectory().appendingPathComponent(directoryName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            // The same "Beepbar" directory also holds the sync database, created independently
            // by `WeBeepAuthenticationController.databaseDirectory()` with default permissions
            // when it runs first — re-assert 0700 here so the credential file's directory is
            // never left group/world-readable regardless of creation order.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return directory.appendingPathComponent(fileName)
        } catch {
            throw CredentialStorageError.write
        }
    }

    /// Never the developer's real Application Support folder when running a `--ui-preview` /
    /// `--ui-preview-onboarding` debug build, so a preview run's login/save calls can't touch the
    /// developer's real stored token.
    private static func applicationSupportDirectory() throws -> URL {
        if PreviewMode.isActive {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-credential-preview", isDirectory: true)
        }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
}

enum PreviewMode {
    static var isActive: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-preview") || ProcessInfo.processInfo.arguments.contains("--ui-preview-onboarding")
#else
        false
#endif
    }
}
