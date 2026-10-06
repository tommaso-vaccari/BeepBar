import Darwin
import Foundation
import Testing
@testable import BeepbarCore

/// `install` reuses the hash `inspect` computed for the user's copy, instead of reading the whole
/// file again before swapping an update in, only while the file is provably in the same state.
///
/// Outcomes alone can't prove any of this: after the swap, `install` hashes the displaced copy in
/// full and swaps back if it changed, so a broken reuse still ends as `.localChanged` with the
/// user's bytes intact. Each test therefore pins how many full reads `install` itself made
/// (`filesHashed`): 1 means the pre-swap check reused `inspect`'s hash, 2 means it read the file.
struct InstallHashReuseTests {
    private struct Fixture {
        let root: URL
        let store: FileStore
        let path: RelativePath
        var file: URL { root.appending(path: path.value) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: "Analisi"), withIntermediateDirectories: true)
            path = try RelativePath("Analisi/lezione.pdf")
            try Data("versione dell'utente".utf8).write(to: root.appending(path: path.value))
            store = try FileStore(root: root) { _ in }
        }

        /// Stages Moodle's new version the way a download does.
        func stagedUpdate() async throws -> StagedArtifact {
            let download = FileManager.default.temporaryDirectory.appending(path: "Beepbar-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: download) }
            let bytes = Data("versione nuova di Moodle".utf8)
            try bytes.write(to: download)
            return try await store.importDownloadedFile(at: download, expectedSize: Int64(bytes.count), maximumSize: 1 << 20)
        }

        /// Full reads made by `body` alone.
        func hashes(during body: () async throws -> InstallResult) async throws -> (result: InstallResult, filesHashed: Int) {
            let before = await store.counters().filesHashed
            let result = try await body()
            return (result, await store.counters().filesHashed - before)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// The common update: the copy `inspect` read is still untouched, so `install` reads only the
    /// displaced copy after the swap. Guards against the reuse never happening (one wasted read of
    /// the user's file per update, the read this change removes).
    @Test func untouchedFileIsNotReadAgainBeforeTheSwap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let local = try await fixture.store.inspect(fixture.path)
        let update = try await fixture.stagedUpdate()

        let install = try await fixture.hashes { try await fixture.store.install(update, at: fixture.path, expectedLocal: local) }

        guard case .installedReplacing = install.result else { Issue.record("expected an install, got \(install.result)"); return }
        #expect(install.filesHashed == 1)
        #expect(try Data(contentsOf: fixture.file) == Data("versione nuova di Moodle".utf8))
    }

    /// An edit that keeps the size and puts the mtime back (as `utimes`, a sync tool or a careless
    /// editor can) still changes the ctime, which only the kernel sets. The check must read the
    /// file and refuse before swapping. Guards against a stamp that ignores the ctime: that would
    /// reuse the stale hash, swap, and rely on the post-swap rollback (2 reads instead of 1).
    @Test func sameSizeEditWithRestoredMtimeIsReadAndRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let local = try await fixture.store.inspect(fixture.path)
        let update = try await fixture.stagedUpdate()
        var original = stat()
        try #require(stat(fixture.file.path, &original) == 0)
        let edited = Data("VERSIONE DELL'UTENTE".utf8)
        let handle = try FileHandle(forUpdating: fixture.file)
        try handle.write(contentsOf: edited)
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        try #require(utimensat(AT_FDCWD, fixture.file.path, &times, 0) == 0)
        var after = stat()
        try #require(stat(fixture.file.path, &after) == 0)
        // Preconditions: only the content and the ctime differ, so the ctime alone must catch it.
        try #require(after.st_size == original.st_size && after.st_ino == original.st_ino)
        try #require(after.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)

        let install = try await fixture.hashes { try await fixture.store.install(update, at: fixture.path, expectedLocal: local) }

        #expect(install.result == .localChanged)
        #expect(install.filesHashed == 1, "the pre-swap check must read the file and refuse before swapping")
        #expect(try Data(contentsOf: fixture.file) == edited)
    }

    /// An app that saves by writing a new file and renaming it over the old one leaves a new
    /// inode at the path, even with identical bytes. The check must read it, and the install
    /// still goes ahead because the bytes match. Guards against keying the reuse on the path, or
    /// against skipping the check whenever a hash is remembered at all.
    @Test func atomicSaveWithIdenticalBytesIsReadAndInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let local = try await fixture.store.inspect(fixture.path)
        let update = try await fixture.stagedUpdate()
        let saved = fixture.root.appending(path: "Analisi/.lezione.pdf.tmp")
        try Data("versione dell'utente".utf8).write(to: saved)
        try #require(rename(saved.path, fixture.file.path) == 0)

        let install = try await fixture.hashes { try await fixture.store.install(update, at: fixture.path, expectedLocal: local) }

        guard case .installedReplacing = install.result else { Issue.record("expected an install, got \(install.result)"); return }
        #expect(install.filesHashed == 2)
    }

    /// A store that never inspected the file, as recovery after a crash uses with the journal's
    /// expected state, reads it in full: nothing is remembered across stores or launches.
    @Test func freshStoreReadsTheFileBeforeTheSwap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let local = try await fixture.store.inspect(fixture.path)
        let update = try await fixture.stagedUpdate()
        let recovery = try FileStore(root: fixture.root) { _ in }

        let before = await recovery.counters().filesHashed
        let result = try await recovery.install(update, at: fixture.path, expectedLocal: local)

        guard case .installedReplacing = result else { Issue.record("expected an install, got \(result)"); return }
        #expect(await recovery.counters().filesHashed - before == 2)
    }

    /// Only the most recent inspections are kept: one pushed out by 64 later ones is read in full.
    /// Guards the bound that stops a first sync of thousands of files from remembering them all.
    @Test func oldInspectionsAreForgotten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let local = try await fixture.store.inspect(fixture.path)
        for index in 0..<64 {
            let other = try RelativePath("Analisi/altro-\(index).pdf")
            try Data("altro \(index)".utf8).write(to: fixture.root.appending(path: other.value))
            _ = try await fixture.store.inspect(other)
        }
        let update = try await fixture.stagedUpdate()

        let install = try await fixture.hashes { try await fixture.store.install(update, at: fixture.path, expectedLocal: local) }

        guard case .installedReplacing = install.result else { Issue.record("expected an install, got \(install.result)"); return }
        #expect(install.filesHashed == 2)
    }
}
