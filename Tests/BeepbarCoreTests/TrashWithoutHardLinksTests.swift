#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import BeepbarCore

/// `FileStore.trashRegularFile` on volumes that cannot hard-link (#182). Every test injects the
/// `linkat` result through the `hardLink` seam and a synthetic Trash that only moves files inside
/// the test's own folder, so neither the user's Trash nor a real exFAT volume is needed. The seam
/// runs after the first verification of the file and before the fallback's last check, which is
/// where these tests change the file.
struct TrashWithoutHardLinksTests {
    /// A temporary sync root holding `Course/file.txt` = "original", and paths around it.
    private struct Setup {
        let container: URL
        let root: URL
        let source: URL
        let trashDestination: URL
        let path: RelativePath

        init() throws {
            container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            root = container.appending(path: "Sync", directoryHint: .isDirectory)
            source = root.appending(path: "Course/file.txt")
            trashDestination = container.appending(path: "SyntheticTrash.txt")
            path = try RelativePath("Course/file.txt")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source)
        }

        func remove() { try? FileManager.default.removeItem(at: container) }
    }

    /// Records what the synthetic Trash was asked to move and how often the link was attempted.
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var _trashed: [String] = []
        private var _links = 0
        var trashed: [String] { lock.withLock { _trashed } }
        var links: Int { lock.withLock { _links } }
        func trash(_ url: URL) { lock.withLock { _trashed.append(url.standardizedFileURL.path) } }
        func link() { lock.withLock { _links += 1 } }
    }

    private func store(_ setup: Setup, record: Record, moveToTrash: Bool = true, hardLink: @escaping @Sendable (Int32, String, Int32, String) -> Int32) throws -> FileStore {
        let destination = setup.trashDestination
        return try FileStore(root: setup.root, beforeMove: nil, trash: { url in
            record.trash(url)
            if moveToTrash { try FileManager.default.moveItem(at: url, to: destination) }
        }, hardLink: { from, name, to, linkName in
            record.link()
            return hardLink(from, name, to, linkName)
        })
    }

    private func snapshot(_ store: FileStore, _ path: RelativePath) async throws -> FileSnapshot {
        guard case .present(let snapshot) = try await store.snapshotRegularFile(path) else { throw FileStoreError.ioFailure }
        return snapshot
    }

    /// The main path of the fix: each `linkat` error meaning "no hard links here" falls back to
    /// trashing the user's own path, and the file ends up in the Trash, gone from the folder.
    /// Guards against the regression itself (every such error used to throw `ioFailure`).
    @Test(arguments: [ENOTSUP, EPERM, EXDEV])
    func trashesTheVerifiedFileByItsPathWhenTheVolumeRefusesHardLinks(_ error: Int32) async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let record = Record()
        let store = try store(setup, record: record) { _, _, _, _ in error }
        let expected = try await snapshot(store, setup.path)

        try await store.trashRegularFile(setup.path, expected: expected)

        #expect(record.links == 1)
        #expect(record.trashed == [setup.source.standardizedFileURL.path])
        #expect(try Data(contentsOf: setup.trashDestination) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: setup.source.path))
    }

    /// The fallback's last check before the Trash: a write after the file was verified (in place,
    /// or a save that replaces the file) must leave the user's file where it is, untouched, and
    /// report `localChanged` so the choice stays open. Guards against trashing an edit the user
    /// made after the entry was checked (guarantee 3).
    @Test(arguments: ["in-place", "replaced"])
    func leavesAFileChangedAfterVerificationInPlace(_ mode: String) async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let record = Record()
        let source = setup.source
        let store = try store(setup, record: record) { _, _, _, _ in
            if mode == "in-place" {
                // Same size, different bytes, written into the same file.
                let handle = try! FileHandle(forWritingTo: source)
                try! handle.write(contentsOf: Data("ORIGINAL".utf8))
                try! handle.close()
            } else {
                try! Data("saved again".utf8).write(to: source, options: .atomic)
            }
            return ENOTSUP
        }
        let expected = try await snapshot(store, setup.path)

        await #expect(throws: FileStoreError.localChanged) { try await store.trashRegularFile(setup.path, expected: expected) }

        #expect(record.trashed.isEmpty)
        #expect(try Data(contentsOf: source) == Data((mode == "in-place" ? "ORIGINAL" : "saved again").utf8))
        #expect(!FileManager.default.fileExists(atPath: setup.trashDestination.path))
    }

    /// The Trash API resolves a path, so the fallback checks that the path still leads to the
    /// verified file: a course folder swapped for a symbolic link to another folder holding a file
    /// of the same name must not send that other file to the Trash, nor the original.
    @Test func refusesAParentFolderSwappedForASymbolicLink() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let record = Record()
        let course = setup.source.deletingLastPathComponent()
        let moved = setup.container.appending(path: "Moved", directoryHint: .isDirectory)
        let elsewhere = setup.container.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: elsewhere.appending(path: "file.txt"))
        let store = try store(setup, record: record) { _, _, _, _ in
            try! FileManager.default.moveItem(at: course, to: moved)
            try! FileManager.default.createSymbolicLink(at: course, withDestinationURL: elsewhere)
            return ENOTSUP
        }
        let expected = try await snapshot(store, setup.path)

        await #expect(throws: FileStoreError.localChanged) { try await store.trashRegularFile(setup.path, expected: expected) }

        #expect(record.trashed.isEmpty)
        #expect(try Data(contentsOf: moved.appending(path: "file.txt")) == Data("original".utf8))
        #expect(try Data(contentsOf: elsewhere.appending(path: "file.txt")) == Data("unrelated".utf8))
    }

    /// The check after the Trash call: if the verified file is still at its path, the Trash took
    /// something else (the path changed inside the residual window), so the call must not report
    /// success, which would close the entry as if the user's file were in the Trash.
    @Test func reportsAChangeWhenTheVerifiedFileIsStillInPlaceAfterTheTrash() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let record = Record()
        let store = try store(setup, record: record, moveToTrash: false) { _, _, _, _ in ENOTSUP }
        let expected = try await snapshot(store, setup.path)

        await #expect(throws: FileStoreError.localChanged) { try await store.trashRegularFile(setup.path, expected: expected) }

        #expect(record.trashed.count == 1)
        #expect(try Data(contentsOf: setup.source) == Data("original".utf8))
    }

    /// Cancellation is honoured at the last point where nothing has changed on disk: a task
    /// cancelled before the fallback's Trash call throws `CancellationError`, the Trash is never
    /// asked to move anything and the file stays in place. Guards against a cancelled choice
    /// still trashing the file.
    @Test func cancellingBeforeTheTrashLeavesTheFileInPlace() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let record = Record()
        let store = try store(setup, record: record) { _, _, _, _ in
            // The seam runs synchronously inside the trashing task: cancel that very task.
            withUnsafeCurrentTask { $0?.cancel() }
            return ENOTSUP
        }
        let expected = try await snapshot(store, setup.path)
        let path = setup.path

        let task = Task { try await store.trashRegularFile(path, expected: expected) }
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(record.links == 1)
        #expect(record.trashed.isEmpty)
        #expect(try Data(contentsOf: setup.source) == Data("original".utf8))
    }

    /// Any other `linkat` failure (here `EACCES`) is not a volume without hard links, and trashing
    /// by path would not be the right answer to it: the call fails as before, touching nothing.
    @Test func otherLinkFailuresStillFailWithoutTrashing() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let record = Record()
        let store = try store(setup, record: record) { _, _, _, _ in EACCES }
        let expected = try await snapshot(store, setup.path)

        await #expect(throws: FileStoreError.ioFailure) { try await store.trashRegularFile(setup.path, expected: expected) }

        #expect(record.trashed.isEmpty)
        #expect(try Data(contentsOf: setup.source) == Data("original".utf8))
    }

    /// The hard-link path is unchanged where links work: the Trash receives the pinned link in the
    /// private staging folder, never the user's path, and the original name is removed afterwards.
    /// Guards against the fallback being taken on volumes that support hard links.
    @Test func volumesWithHardLinksStillTrashThePinnedLink() async throws {
        let setup = try Setup()
        defer { setup.remove() }
        let record = Record()
        let store = try store(setup, record: record) { from, name, to, linkName in
            linkat(from, name, to, linkName, 0) == 0 ? 0 : errno
        }
        let expected = try await snapshot(store, setup.path)

        try await store.trashRegularFile(setup.path, expected: expected)

        #expect(record.links == 1)
        #expect(record.trashed.count == 1)
        #expect(record.trashed.first != setup.source.standardizedFileURL.path)
        #expect(!(record.trashed.first ?? "").hasPrefix(setup.root.standardizedFileURL.path))
        #expect(try Data(contentsOf: setup.trashDestination) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(atPath: setup.source.path))
    }

    /// Which `linkat` errors select the fallback, pinned so a change to the list is deliberate.
    @Test func onlyNoHardLinkErrorsSelectTheFallback() {
        #expect([ENOTSUP, EOPNOTSUPP, EPERM, EXDEV].allSatisfy(FileStore.meansNoHardLinks))
        #expect(![EACCES, ENOENT, EEXIST, EIO, ENOSPC, ELOOP].contains(where: FileStore.meansNoHardLinks))
    }
}
