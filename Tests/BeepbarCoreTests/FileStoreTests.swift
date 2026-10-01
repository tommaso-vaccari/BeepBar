import CryptoKit
import Darwin
import Foundation
import Testing
@testable import BeepbarCore

struct FileStoreTests {
    @Test func hidesInternalBookkeepingDirectoryFromFinder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        _ = try await store.createStage()

        var info = stat()
        let path = root.appending(path: ".beepbar").path
        #expect(stat(path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_HIDDEN) != 0)
    }

    @Test func installsOnlyWhenDestinationIsStillMissing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let path = try RelativePath("Course/notes.txt")
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)

        #expect(try await store.install(artifact, at: path, expectedLocal: .missing) == .installedNew)
        #expect(try String(contentsOf: root.appending(path: path.value), encoding: .utf8) == "remote")
    }

    @Test func preservesConcurrentLocalReplacement() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Course/notes.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("base".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let path = try RelativePath("Course/notes.txt")
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)
        try Data("local".utf8).write(to: destination)

        #expect(try await store.install(artifact, at: path, expectedLocal: .present(sha256: SHA256Digest.hash("base"))) == .localChanged)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "local")
    }

    @Test func rejectsAnExistingFileWhenTheExpectedLocalStateIsMissing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Course/notes.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: destination)
        let store = try FileStore(root: root)
        let stage = try await store.createStage()
        try await store.write(Data("remote".utf8), to: stage)
        let artifact = try await store.finalize(stage)

        #expect(try await store.install(artifact, at: RelativePath("Course/notes.txt"), expectedLocal: .missing) == .localChanged)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "local")
    }

    @Test func detectsRegularFilesWithoutReadingTheirContents() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let path = try RelativePath("Course/material.txt")
        #expect(try await store.containsRegularFile(path) == false)

        let destination = root.appending(path: path.value)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: destination)
        #expect(try await store.containsRegularFile(path))
    }

    @Test func bulkExistenceCheckTreatsNonRegularEntriesAsAbsentWithoutHashing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let regular = try RelativePath("Course/material.txt")
        let directory = try RelativePath("Course/folder.txt")
        let symlink = try RelativePath("Course/link.txt")
        let missing = try RelativePath("Course/missing.txt")
        let underFile = try RelativePath("Course/material.txt/nested.txt")
        let underSymlink = try RelativePath("Course/link.txt/nested.txt")
        try FileManager.default.createDirectory(at: root.appending(path: "Course"), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: root.appending(path: regular.value))
        try FileManager.default.createDirectory(at: root.appending(path: directory.value), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appending(path: symlink.value), withDestinationURL: root.appending(path: regular.value))

        let existing = try await store.existingRegularFiles([regular, directory, symlink, missing, underFile, underSymlink])

        #expect(existing == [regular])
        #expect(await store.hashCount == 0)
    }

    @Test func refusesTopLevelNamesInTheReservedNamespaceRegardlessOfCase() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        for name in [".BEEPBAR", ".Beepbar", ".BEEPBAR-backup"] {
            await #expect(throws: FileStoreError.invalidStage) { _ = try await store.ensureTopLevelDirectory(name) }
            await #expect(throws: FileStoreError.invalidStage) { _ = try await store.topLevelDirectoryIdentity(name) }
            await #expect(throws: FileStoreError.invalidStage) { _ = try await store.topLevelDirectoryState(name) }
        }
        _ = try await store.ensureTopLevelDirectory("Corso")
        await #expect(throws: FileStoreError.invalidStage) { try await store.renameTopLevelDirectory(from: "Corso", to: ".BEEPBAR") }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".BEEPBAR").path))
    }

    @Test func migrationPathEntryMatchingBlocksCaseAndUnicodeAliases() {
        #expect(FileStore.migrationDirectoryEntryMatch("Lectures", entries: ["LECTURES"]) == .differentSpelling)
        #expect(FileStore.migrationDirectoryEntryMatch("é", entries: ["e\u{301}"]) == .differentSpelling)
        #expect(FileStore.migrationDirectoryEntryMatch("Lectures", entries: ["Lectures", "LECTURES"]) == .ambiguous)
        #expect(FileStore.migrationDirectoryEntryMatch("Lectures", entries: ["Other"]) == .missing)
    }

    @Test func migrationDestinationTreatsSymlinkParentAsOccupied() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let actualParent = root.appending(path: "Actual")
        try FileManager.default.createDirectory(at: actualParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Course"), withDestinationURL: actualParent)
        let store = try FileStore(root: root)

        #expect(try await store.migrationDestinationIsOccupied(RelativePath("Course/Custom/file.pdf")))
    }

    @Test func repeatedMigrationDestinationChecksStillSeeOccupiedEntries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = root.appending(path: "Course/Custom/file.pdf")
        try FileManager.default.createDirectory(at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: occupied)
        let store = try FileStore(root: root)

        #expect(!(try await store.migrationDestinationIsOccupied(RelativePath("Missing/file.pdf"))))
        #expect(try await store.migrationDestinationIsOccupied(RelativePath("Course/Custom/file.pdf")))
        #expect(try await store.migrationDestinationIsOccupied(RelativePath("Course/Custom/file.pdf")))
    }

    @Test func moveLeavesAnInPlaceEditAtItsOriginalLocation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Course/Old/file.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source)
        let store = try FileStore(root: root)
        let old = try RelativePath("Course/Old/file.txt")
        let new = try RelativePath("Course/New/file.txt")
        guard case .present(let snapshot) = try await store.snapshotRegularFile(old) else { Issue.record("Missing source"); return }

        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.close()

        await #expect(throws: FileStoreError.localChanged) {
            try await store.moveRegularFile(from: old, to: new, expected: snapshot)
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "edited")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: new.value).path))
    }

    @Test func swapLeavesBothInPlaceEditsAtTheirOriginalLocations() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appending(path: "Course/First.txt")
        let secondURL = root.appending(path: "Course/Second.txt")
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let store = try FileStore(root: root)
        let first = try RelativePath("Course/First.txt")
        let second = try RelativePath("Course/Second.txt")
        guard case .present(let firstSnapshot) = try await store.snapshotRegularFile(first),
              case .present(let secondSnapshot) = try await store.snapshotRegularFile(second) else { Issue.record("Missing source"); return }

        let handle = try FileHandle(forWritingTo: secondURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("edited".utf8))
        try handle.close()

        await #expect(throws: FileStoreError.localChanged) {
            try await store.swapRegularFiles(first, expected: firstSnapshot, with: second, expected: secondSnapshot)
        }
        #expect(try String(contentsOf: firstURL, encoding: .utf8) == "first")
        #expect(try String(contentsOf: secondURL, encoding: .utf8) == "edited")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum SHA256Digest {
    static func hash(_ value: String) -> String {
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
