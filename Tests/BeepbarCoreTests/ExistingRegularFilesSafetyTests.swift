#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import BeepbarCore

/// R03 (#111, PR #142): `FileStore.existingRegularFiles` resolves each distinct parent directory
/// once per call and checks that directory's files through the same descriptor. It is the check
/// that tells a run with nothing new which tracked files the user deleted, and it sits on the
/// containment path, so these tests pin every protection the per-file version had: no symbolic
/// link followed at any component, nothing outside the sync root ever reported, resolution from
/// the root pinned when the store was created, permission errors failing the call, missing or
/// replaced directories reported as absent without hiding their neighbours, and no descriptor
/// trusted across calls. Every expectation here also holds on the per-file implementation it
/// replaced; only `WorkCountersTests` pins the number of resolutions.
struct ExistingRegularFilesSafetyTests {
    /// A container holding the sync root (`Sync`) and a sibling folder outside it (`Outside`),
    /// so a test can point a symbolic link out of the root and still clean everything up.
    private struct Layout {
        let container: URL
        var root: URL { container.appending(path: "Sync", directoryHint: .isDirectory) }
        var outside: URL { container.appending(path: "Outside", directoryHint: .isDirectory) }

        init() throws {
            container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: container.appending(path: "Sync"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: container.appending(path: "Outside"), withIntermediateDirectories: true)
        }

        func file(_ relative: String, in base: URL? = nil) throws {
            let url = (base ?? root).appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("local".utf8).write(to: url)
        }

        func directory(_ relative: String) throws {
            try FileManager.default.createDirectory(at: root.appending(path: relative), withIntermediateDirectories: true)
        }

        /// A symbolic link at `relative` in the root whose stored target is `destination` verbatim.
        func link(_ relative: String, to destination: String) throws {
            try FileManager.default.createSymbolicLink(atPath: root.appending(path: relative).path, withDestinationPath: destination)
        }

        func remove() { try? FileManager.default.removeItem(at: container) }
    }

    private func paths(_ values: [String]) throws -> [RelativePath] { try values.map { try RelativePath($0) } }

    /// A symbolic link standing in for an intermediate directory is never followed, whether it
    /// sits right under the root or deeper, even though its target is a real directory inside the
    /// root holding a regular file of the expected name. Guards against `directoryFD` losing
    /// `O_NOFOLLOW`: a followed alias would report a file the sync never put there as present,
    /// and the deleted original would not be downloaded again.
    @Test func neverFollowsASymlinkedIntermediateDirectoryInsideTheRoot() async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try layout.file("Corso/Reale/Modulo/x.pdf")
        try layout.link("Alias", to: "Corso/Reale")
        try layout.link("Corso/Scorciatoia", to: "Reale/Modulo")
        let store = try FileStore(root: layout.root) { _ in }

        let existing = try await store.existingRegularFiles(try paths(["Alias/Modulo/x.pdf", "Corso/Scorciatoia/x.pdf", "Corso/Reale/Modulo/x.pdf"]))

        #expect(existing == Set(try paths(["Corso/Reale/Modulo/x.pdf"])))
    }

    /// A symbolic link pointing out of the sync root, as a directory component or as the file
    /// itself, never makes a file outside the root count as present. Guards against `directoryFD`
    /// losing `O_NOFOLLOW` and against the final `fstatat` losing `AT_SYMLINK_NOFOLLOW`: either
    /// would let the check look outside the folder BeepBar owns.
    @Test func neverReportsAFileOutsideTheRoot() async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try layout.file("Modulo/x.pdf", in: layout.outside)
        try layout.directory("Corso")
        try layout.link("Fuga", to: layout.outside.path)
        try layout.link("Corso/Fuga", to: layout.outside.appending(path: "Modulo").path)
        try layout.link("Corso/x.pdf", to: layout.outside.appending(path: "Modulo/x.pdf").path)
        let store = try FileStore(root: layout.root) { _ in }

        let existing = try await store.existingRegularFiles(try paths(["Fuga/Modulo/x.pdf", "Corso/Fuga/x.pdf", "Corso/x.pdf"]))

        #expect(existing.isEmpty)
    }

    /// Paths resolve from the root directory pinned when the store was created, never from its
    /// path: after the sync folder is renamed away and another folder appears at its old path,
    /// answers still describe the original folder. Guards against resolving through `rootURL`
    /// (a path lookup), which would read whatever now sits at that path.
    @Test func resolvesFromThePinnedRootAfterTheRootIsReplaced() async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try layout.file("Corso/Modulo/originale.pdf")
        let store = try FileStore(root: layout.root) { _ in }
        try FileManager.default.moveItem(at: layout.root, to: layout.container.appending(path: "Spostata"))
        try layout.file("Corso/Modulo/esca.pdf")

        let existing = try await store.existingRegularFiles(try paths(["Corso/Modulo/originale.pdf", "Corso/Modulo/esca.pdf"]))

        #expect(existing == Set(try paths(["Corso/Modulo/originale.pdf"])))
    }

    /// One batch mixing every way a parent can be unusable (a symbolic link, a missing
    /// intermediate directory, a file where a directory should be) ahead of usable parents, with
    /// paths of the same parent interleaved and, inside one parent, a present file, a deleted
    /// one, a symbolic link to a regular file and a directory where a file was. Only the regular
    /// files are reported, each under its own name. Guards against a failing parent ending the
    /// whole check early (later deletions would go unseen), against presence attributed to the
    /// wrong name or wrong directory, and against non-regular entries counting as files.
    @Test func reportsExactlyTheRegularFilesInAMixedBatch() async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try layout.file("Corso/Reale/x.pdf")
        try layout.link("Corso/Alias", to: "Reale")
        try layout.file("Corso/File.pdf")
        try layout.file("A/Modulo/presente.pdf")
        try layout.file("A/Modulo/secondo.pdf")
        try layout.file("A/Modulo/bersaglio.pdf")
        try layout.link("A/Modulo/collegamento.pdf", to: "bersaglio.pdf")
        try layout.directory("A/Modulo/cartella.pdf")
        try layout.file("B/Modulo/soloB.pdf")
        try layout.file("radice.pdf")
        let store = try FileStore(root: layout.root) { _ in }

        let existing = try await store.existingRegularFiles(try paths([
            "Corso/Alias/x.pdf", "Mancante/Profonda/x.pdf", "Corso/File.pdf/x.pdf",
            "A/Modulo/presente.pdf", "B/Modulo/soloB.pdf", "A/Modulo/cancellato.pdf",
            "A/Modulo/collegamento.pdf", "B/Modulo/presente.pdf", "A/Modulo/cartella.pdf",
            "A/Modulo/secondo.pdf", "radice.pdf", "assente.pdf",
        ]))

        #expect(existing == Set(try paths(["A/Modulo/presente.pdf", "B/Modulo/soloB.pdf", "A/Modulo/secondo.pdf", "radice.pdf"])))
        #expect(await store.hashCount == 0)
    }

    /// Two directories with the same name under different parents are kept apart. Guards against
    /// grouping files by an incomplete key (the last folder name), which would check one module's
    /// files in another module's folder.
    @Test func keepsSameNamedDirectoriesUnderDifferentParentsApart() async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try layout.file("Analisi/Lezioni/soloAnalisi.pdf")
        try layout.file("Fisica/Lezioni/soloFisica.pdf")
        let store = try FileStore(root: layout.root) { _ in }

        let existing = try await store.existingRegularFiles(try paths(["Analisi/Lezioni/soloAnalisi.pdf", "Fisica/Lezioni/soloFisica.pdf", "Analisi/Lezioni/soloFisica.pdf", "Fisica/Lezioni/soloAnalisi.pdf"]))

        #expect(existing == Set(try paths(["Analisi/Lezioni/soloAnalisi.pdf", "Fisica/Lezioni/soloFisica.pdf"])))
    }

    /// The same store answers each call from directories it opens again: a module folder replaced
    /// by a symbolic link, a file replaced by a directory or by a symbolic link, and a file the
    /// user deleted, all between two calls, read as absent on the second call. Guards against
    /// keeping descriptors or answers across calls, which would trust a directory or file the
    /// store no longer checked and hide a local deletion from the next run.
    @Test func reresolvesEveryDirectoryOnEachCall() async throws {
        let layout = try Layout()
        defer { layout.remove() }
        let names = ["Corso/Modulo/a.pdf", "Corso/Altro/b.pdf", "Corso/Altro/c.pdf", "Corso/Altro/d.pdf", "Corso/Altro/e.pdf"]
        for name in names { try layout.file(name) }
        let store = try FileStore(root: layout.root) { _ in }
        #expect(try await store.existingRegularFiles(try paths(names)) == Set(try paths(names)))

        try FileManager.default.moveItem(at: layout.root.appending(path: "Corso/Modulo"), to: layout.root.appending(path: "Corso/Reale"))
        try layout.link("Corso/Modulo", to: "Reale")
        try FileManager.default.removeItem(at: layout.root.appending(path: "Corso/Altro/b.pdf"))
        try layout.directory("Corso/Altro/b.pdf")
        try FileManager.default.removeItem(at: layout.root.appending(path: "Corso/Altro/c.pdf"))
        try layout.link("Corso/Altro/c.pdf", to: "e.pdf")
        try FileManager.default.removeItem(at: layout.root.appending(path: "Corso/Altro/d.pdf"))

        #expect(try await store.existingRegularFiles(try paths(names)) == Set(try paths(["Corso/Altro/e.pdf"])))
    }

    /// A folder the check may not enter fails the whole call instead of reporting its files as
    /// absent, as before #111: either an intermediate folder that cannot be opened, or the file's
    /// own folder that can be listed but not searched. A good parent comes first so a partial
    /// answer would be visible. Guards against a broad `catch` that would turn an unreadable
    /// folder into "the user deleted these files" and send the run to re-download over them.
    /// Skipped as root, which ignores permission bits.
    @Test(.enabled(if: geteuid() != 0), arguments: [("Bloccata", 0o000), ("Bloccata/Modulo", 0o400)])
    func permissionDeniedFailsTheWholeCheck(lockedFolder: String, permissions: Int) async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try layout.file("Aperta/Modulo/x.pdf")
        try layout.file("Bloccata/Modulo/x.pdf")
        let locked = layout.root.appending(path: lockedFolder)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let store = try FileStore(root: layout.root) { _ in }

        await #expect(throws: FileStoreError.ioFailure) {
            _ = try await store.existingRegularFiles(try paths(["Aperta/Modulo/x.pdf", "Bloccata/Modulo/x.pdf"]))
        }
    }

    /// A cancelled run stops the check instead of finishing it. Guards against losing the
    /// cancellation checkpoints when the loop was reorganized by parent directory.
    @Test func stopsWhenCancelled() async throws {
        let layout = try Layout()
        defer { layout.remove() }
        try layout.file("Corso/Modulo/x.pdf")
        let store = try FileStore(root: layout.root) { _ in }
        let check = Task { () async throws -> Set<RelativePath> in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.existingRegularFiles(try paths(["Corso/Modulo/x.pdf"]))
        }

        await #expect(throws: CancellationError.self) { _ = try await check.value }
    }
}
