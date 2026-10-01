import Foundation
import Testing
@testable import BeepbarCore

/// What a click on a file in Attività does (#69). Downloaded course files carry no quarantine
/// flag, so these decisions are the only thing between a teacher's upload and running it.
struct ActivityFilePolicyTests {
    private let root = URL(fileURLWithPath: "/Users/someone/WeBeep", isDirectory: true)

    /// Documents open directly: PDF, office, iWork, OpenDocument, text, images, audio, video,
    /// zip, ebooks, whatever the case of the extension.
    @Test(arguments: ["Slide 1.pdf", "Esercizi.DOCX", "vecchio.doc", "lab.pptx", "voti.xlsx", "tesi.odt", "relazione.pages", "dati.numbers", "talk.key", "note.txt", "appunti.md", "dati.csv", "testo.rtf", "foto.png", "scan.HEIC", "grafico.tiff", "lezione.mp4", "audio.m4a", "codice.zip", "libro.epub"])
    func documentsOpenDirectly(filename: String) {
        #expect(ActivityFilePolicy.opensDirectly(filename: filename))
    }

    /// Everything else is only shown in Finder. Covers the cases reviews found: `.term` (a
    /// Terminal session that runs a command), `.tcl` (opened by Wish, which runs it), `.svg` (a
    /// browser runs its script), playlists (Music imports them), and types an installed app
    /// declares as plain text or zip (`.lua`, `.dtx`, `.otm`); plus disk images, profiles,
    /// shortcuts, Java Web Start, macro office files, source code, TeX, unknown types, and names
    /// without an extension.
    @Test(arguments: [
        "setup.term", "esercizio.tcl", "avvia.command", "AVVIA.COMMAND", "setup.sh", "Tool.app", "install.pkg",
        "disco.dmg", "immagine.iso", "profilo.mobileconfig", "flusso.shortcut", "app.jnlp", "link.webloc",
        "script.scpt", "macro.docm", "macro.XLSM", "esercizio.py", "main.c", "Main.java", "tesi.tex",
        "pagina.html", "dati.json", "notebook.ipynb", "archivio.rar", "README", "file.sconosciuto",
        "schema.svg", "schema.svgz", "lista.m3u", "lista.m3u8", "radio.pls", "script.lua", "pacchetto.dtx",
        "modello.otm", "scena.dae", "radio.ram", "flusso.sdp", "figura.eps", "stampa.ps", "binario.xlsb",
    ])
    func everythingElseIsOnlyShownInFinder(filename: String) {
        #expect(!ActivityFilePolicy.opensDirectly(filename: filename))
    }

    /// The extension list holds on its own, whatever types macOS declares: every entry is refused
    /// by the list itself (not just because this macOS happens to type it as executable), in any
    /// case. Removing an entry from the list fails this test even where its type would catch it.
    @Test func theExtensionListRefusesEveryEntryByItself() {
        let required: Set<String> = [
            "docm", "dotm", "xlsm", "xltm", "xlam", "xlsb", "pptm", "potm", "ppsm", "ppam",
            "tex", "ltx", "latex", "sty", "cls", "bib", "ps", "eps", "epsf", "epsi",
            "ram", "rpm", "sdp", "command", "tool", "terminal", "term", "sh", "tcl",
        ]
        #expect(ActivityFilePolicy.excludedExtensions == required)
        for fileExtension in required {
            #expect(ActivityFilePolicy.isExcluded(fileExtension: fileExtension))
            #expect(ActivityFilePolicy.isExcluded(fileExtension: fileExtension.uppercased()))
        }
        #expect(!ActivityFilePolicy.isExcluded(fileExtension: "pdf"))
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

    /// A path BeepBar may not look at is reported as such, not as moved or deleted.
    @Test func anUnreadablePathIsReportedAsUnreadable() throws {
        let path = try RelativePath("Analisi/x.pdf")
        #expect(ActivityFilePolicy.action(trackedPath: path, root: root, fileState: .unreadable) == .unreadable)
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
