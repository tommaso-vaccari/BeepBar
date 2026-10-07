import Foundation
import Testing
@testable import BeepbarApp

/// The file that carries the Polimi session between launches. It holds sign-on cookies, so it
/// must be private from the first byte, never half written, and gone without a trace on delete.
struct RecordingsSessionStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-store-\(UUID().uuidString)", isDirectory: true)
    private var store: RecordingsSessionStore {
        let folder = folder
        return RecordingsSessionStore { folder }
    }
    private var file: URL { folder.appendingPathComponent(RecordingsSessionStore.fileName) }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != RecordingsSessionStore.fileName }
    }

    /// No file is "no session", not an error: the first launch with the feature on starts here.
    @Test func noFileMeansNoSession() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try store.load() == nil)
        try store.delete()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// Saved and read back byte for byte, owner-only (0600) in an owner-only folder (0700), with
    /// no temporary file left next to it. Guards against cookies sitting on disk readable by
    /// other users of the Mac.
    @Test func savesPrivatelyAndReadsBack() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.save(Data("first".utf8))
        try store.save(Data("second".utf8))
        #expect(try store.load() == Data("second".utf8))
        #expect(try permissions(file) == 0o600)
        #expect(try permissions(folder) == 0o700)
        #expect(try leftovers().isEmpty)
    }

    /// Delete removes the session and the temporary files a crash mid-save can leave, but
    /// nothing else in BeepBar's folder (the token and the sync database live there too).
    @Test func deleteRemovesTheSessionAndCrashLeftoversOnly() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.save(Data("session".utf8))
        let orphan = folder.appendingPathComponent(".recordings-session-\(UUID().uuidString).tmp")
        let neighbour = folder.appendingPathComponent("credential.token")
        FileManager.default.createFile(atPath: orphan.path, contents: Data("half".utf8))
        FileManager.default.createFile(atPath: neighbour.path, contents: Data("token".utf8))
        try store.delete()
        #expect(try store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
    }

    /// A folder BeepBar can't write to makes the save fail loudly and leaves the previous
    /// session as it was, with no temporary file behind.
    @Test func aFailedSaveKeepsThePreviousSession() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try store.save(Data("previous".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(throws: (any Error).self) { try store.save(Data("next".utf8)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(try store.load() == Data("previous".utf8))
        #expect(try leftovers().isEmpty)
    }
}
