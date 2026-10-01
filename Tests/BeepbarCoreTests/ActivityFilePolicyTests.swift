import Foundation
import Testing
@testable import BeepbarCore

/// What a click on a file in Attività does (#69). Downloaded course files carry no quarantine
/// flag, so these decisions are the only thing between a teacher's upload and running it.
struct ActivityFilePolicyTests {
    private let root = URL(fileURLWithPath: "/Users/someone/WeBeep", isDirectory: true)

    /// Documents open directly: PDF, office, iWork, OpenDocument, text, images, audio, video,
    /// zip, ebooks, whatever the case of the extension.
    @Test(arguments: ["Slide 1.pdf", "Esercizi.DOCX", "vecchio.doc", "lab.pptx", "voti.xlsx", "tesi.odt", "relazione.pages", "dati.numbers", "talk.key", "note.txt", "appunti.md", "dati.csv", "testo.rtf", "foto.png", "scan.HEIC", "schema.svg", "lezione.mp4", "audio.m4a", "codice.zip", "libro.epub"])
    func documentsOpenDirectly(filename: String) {
        #expect(ActivityFilePolicy.opensDirectly(filename: filename))
    }

    /// Everything else is only shown in Finder. Covers the cases a denylist missed: `.term`
    /// (a Terminal session that runs a command) and `.tcl` (opened by Wish, which runs it), plus
    /// disk images, profiles, shortcuts, Java Web Start, macro office files, source code of any
    /// language, TeX, unknown types, and names without an extension.
    @Test(arguments: [
        "setup.term", "esercizio.tcl", "avvia.command", "AVVIA.COMMAND", "setup.sh", "Tool.app", "install.pkg",
        "disco.dmg", "immagine.iso", "profilo.mobileconfig", "flusso.shortcut", "app.jnlp", "link.webloc",
        "script.scpt", "macro.docm", "macro.XLSM", "esercizio.py", "main.c", "Main.java", "tesi.tex",
        "pagina.html", "dati.json", "notebook.ipynb", "archivio.rar", "README", "file.sconosciuto",
    ])
    func everythingElseIsOnlyShownInFinder(filename: String) {
        #expect(!ActivityFilePolicy.opensDirectly(filename: filename))
    }

    /// A tracked regular file opens at its path inside the sync folder.
    @Test func aTrackedRegularDocumentOpensAtItsPath() throws {
        let path = try RelativePath("Analisi/Lezioni/Slide 1.pdf")
        #expect(ActivityFilePolicy.action(trackedPath: path, root: root, fileState: .regular(executable: false)) == .open(root.appending(path: "Analisi/Lezioni/Slide 1.pdf", directoryHint: .notDirectory)))
    }

    /// Not tracked, not there, or not the plain file BeepBar wrote (a folder or a link): nothing
    /// is opened in its place.
    @Test func anythingButTheTrackedRegularFileIsMissing() throws {
        let path = try RelativePath("Analisi/x.pdf")
        #expect(ActivityFilePolicy.action(trackedPath: nil, root: root, fileState: .regular(executable: false)) == .missing)
        #expect(ActivityFilePolicy.action(trackedPath: path, root: root, fileState: .missing) == .missing)
        #expect(ActivityFilePolicy.action(trackedPath: path, root: root, fileState: .notARegularFile) == .missing)
    }

    /// BeepBar's own hidden folder is never opened from Attività, even if a path points there.
    @Test func theReservedFolderIsNeverOpened() throws {
        let path = try RelativePath(internal: ".beepbar/conflicts/one/x.pdf")
        #expect(ActivityFilePolicy.action(trackedPath: path, root: root, fileState: .regular(executable: false)) == .missing)
    }

    /// A file with the execute permission is revealed even when its name looks like a document;
    /// a runnable type is revealed even without it.
    @Test func executableOrRunnableFilesAreRevealed() throws {
        let disguised = try RelativePath("Analisi/slides.pdf")
        #expect(ActivityFilePolicy.action(trackedPath: disguised, root: root, fileState: .regular(executable: true)) == .reveal(root.appending(path: "Analisi/slides.pdf", directoryHint: .notDirectory)))
        let script = try RelativePath("Analisi/setup.term")
        #expect(ActivityFilePolicy.action(trackedPath: script, root: root, fileState: .regular(executable: false)) == .reveal(root.appending(path: "Analisi/setup.term", directoryHint: .notDirectory)))
    }
}
