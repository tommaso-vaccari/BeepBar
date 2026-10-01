import Foundation
import Testing
@testable import BeepbarCore

/// What a click on a file in Attività does.
struct ActivityFilePolicyTests {
    private let root = URL(fileURLWithPath: "/Users/someone/WeBeep", isDirectory: true)

    /// Course material opens directly, whatever its case or lack of extension.
    @Test(arguments: ["Slide 1.pdf", "Esercizi.DOCX", "lab.pptx", "voti.xlsx", "codice.zip", "foto.png", "lezione.mp4", "note.txt", "notebook.ipynb", "README", "pagina.html"])
    func courseMaterialOpensDirectly(filename: String) {
        #expect(ActivityFilePolicy.opensDirectly(filename: filename))
    }

    /// Anything macOS would run or follow instead of showing is only shown in Finder: one click in
    /// BeepBar must never execute a teacher's upload (a `.command` runs in Terminal).
    @Test(arguments: ["avvia.command", "AVVIA.COMMAND", "setup.sh", "build.zsh", "Tool.app", "install.pkg", "script.scpt", "run.applescript", "lib.jar", "link.webloc", "sito.url", "auto.workflow", "esercizio.py", "tool.tool"])
    func runnableFilesAreOnlyShownInFinder(filename: String) {
        #expect(!ActivityFilePolicy.opensDirectly(filename: filename))
    }

    /// A tracked file that exists opens at its path inside the sync folder.
    @Test func aTrackedFileThatExistsOpensAtItsPath() throws {
        let path = try RelativePath("Analisi/Lezioni/Slide 1.pdf")
        let action = ActivityFilePolicy.action(trackedPath: path, root: root, filename: "Slide 1.pdf", fileExists: { _ in true }, isExecutableFile: { _ in false })
        #expect(action == .open(root.appending(path: "Analisi/Lezioni/Slide 1.pdf", directoryHint: .notDirectory)))
    }

    /// Not tracked any more, or not where BeepBar put it: nothing is opened in its place.
    @Test func anUntrackedOrMissingFileIsReportedMissing() throws {
        #expect(ActivityFilePolicy.action(trackedPath: nil, root: root, filename: "x.pdf", fileExists: { _ in true }, isExecutableFile: { _ in false }) == .missing)
        let path = try RelativePath("Analisi/x.pdf")
        #expect(ActivityFilePolicy.action(trackedPath: path, root: root, filename: "x.pdf", fileExists: { _ in false }, isExecutableFile: { _ in false }) == .missing)
    }

    /// A runnable type, or a file with the execute permission even if its name looks harmless,
    /// is revealed rather than opened.
    @Test func runnableOrExecutableFilesAreRevealed() throws {
        let script = try RelativePath("Analisi/avvia.command")
        #expect(ActivityFilePolicy.action(trackedPath: script, root: root, filename: "avvia.command", fileExists: { _ in true }, isExecutableFile: { _ in false }) == .reveal(root.appending(path: "Analisi/avvia.command", directoryHint: .notDirectory)))
        let executable = try RelativePath("Analisi/programma")
        #expect(ActivityFilePolicy.action(trackedPath: executable, root: root, filename: "programma", fileExists: { _ in true }, isExecutableFile: { _ in true }) == .reveal(root.appending(path: "Analisi/programma", directoryHint: .notDirectory)))
    }

    /// The decision follows the name on disk, not the name stored in the activity list: a file a
    /// later sync renamed to `.command` is still only revealed.
    @Test func theNameOnDiskDecidesNotTheStoredName() throws {
        let renamed = try RelativePath("Analisi/avvia.command")
        #expect(ActivityFilePolicy.action(trackedPath: renamed, root: root, filename: "avvia.pdf", fileExists: { _ in true }, isExecutableFile: { _ in false }) == .reveal(root.appending(path: "Analisi/avvia.command", directoryHint: .notDirectory)))
    }
}
