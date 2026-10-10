import Foundation
import Testing
@testable import BeepbarCore

/// R03 (#111): what a run with nothing new costs in directory traversal. `existingRegularFiles` is
/// the only per-file filesystem call such a run makes (`SyncCoordinator.itemsRequiringReconciliation`),
/// so its syscalls per tracked file are the whole local filesystem cost of an unchanged check.
struct DirectoryTraversalProfileTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes `files` empty files spread round-robin over `directories` folders of depth `depth`
    /// (e.g. `Corso 1/Sezione/Modulo/lezione-00001.pdf` at depth 3) and returns their paths.
    private func corpus(at root: URL, files: Int, directories: Int, depth: Int) throws -> [RelativePath] {
        var paths: [RelativePath] = []
        for index in 0..<files {
            let folder = index % directories
            var components = ["Corso \(folder % 10 + 1)"]
            for level in 1..<depth { components.append("Livello \(level) cartella \(folder)") }
            let directory = components.joined(separator: "/")
            if index < directories { try FileManager.default.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true) }
            let path = try RelativePath("\(directory)/lezione-\(String(format: "%05d", index)).pdf")
            try Data().write(to: root.appending(path: path.value))
            paths.append(path)
        }
        return paths
    }

    /// Indicative timing only, on demand: `BEEPBAR_TRAVERSAL_PROFILE=1 swift test --filter DirectoryTraversalProfileTests`.
    /// Prints wall time and the store's counters for an unchanged check over three layouts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEEPBAR_TRAVERSAL_PROFILE"] == "1"))
    func profileUnchangedCheck() async throws {
        let files = Int(ProcessInfo.processInfo.environment["BEEPBAR_TRAVERSAL_FILES"] ?? "") ?? 15_000
        for (label, directories, depth) in [("benchmark-like, 50 dirs, depth 2", 50, 2), ("deep shared, 500 dirs, depth 4", 500, 4), ("one file per dir, depth 3", files, 3)] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = try corpus(at: root, files: files, directories: directories, depth: depth)
            let store = try FileStore(root: root) { _ in }
            _ = try await store.existingRegularFiles(paths) // warm-up
            let before = await store.counters()
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                let present = try await store.existingRegularFiles(paths)
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                #expect(present.count == files)
            }
            let delta = await store.counters().since(before)
            print("traversal-profile \(label): files=\(files) median=\(String(format: "%.1f", samples.sorted()[2])) ms max=\(String(format: "%.1f", samples.max()!)) ms per run; counters over 5 runs: \(delta)")
        }
    }
}
