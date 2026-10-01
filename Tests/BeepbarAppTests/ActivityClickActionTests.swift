import Testing
@testable import BeepbarApp
@testable import BeepbarCore

/// The words shown for a click on an Attività file (on hover, tooltip, VoiceOver, context menu)
/// must match what the click does: "Apri" only for files that open, "Mostra nel Finder" for the
/// rest. Italian, the language tests run in (`AppLanguage.current` must not be switched here).
struct ActivityClickActionTests {
    /// Documents say "Apri", with the open-in-app symbol, the file name in the tooltip and a
    /// matching VoiceOver hint. Covers every document family (PDF, office, image, video,
    /// presentation, ebook, Markdown), not just a few extensions a hardcoded list would also get right.
    @Test(arguments: ["Slide 1.pdf", "esercizi.DOCX", "foto.png", "lezione.key", "video.mov", "libro.epub", "note.md"])
    func documentsAreLabelledOpen(name: String) {
        let action = ActivityClickAction(filename: name)
        #expect(action == .open)
        #expect(action.title == "Apri")
        #expect(action.systemImage == "arrow.up.forward.square")
        #expect(action.help(for: name) == "Apri “\(name)”")
        #expect(action.accessibilityHint == "Apre il file")
    }

    /// Files that are only shown in Finder never say "Apri": the label, tooltip and hint all
    /// say what really happens. Includes names that look like documents: a script with a
    /// document extension before its real one, and a macro-enabled workbook.
    @Test(arguments: ["esercizio.py", "setup.term", "schema.svg", "README", "x.pdf.command", "macro.xlsm"])
    func everythingElseIsLabelledShowInFinder(name: String) {
        let action = ActivityClickAction(filename: name)
        #expect(action == .showInFinder)
        #expect(action.title == "Mostra nel Finder")
        #expect(action.systemImage == "folder")
        #expect(action.help(for: name) == "Mostra “\(name)” nel Finder")
        #expect(action.accessibilityHint == "Mostra il file nel Finder")
    }

    /// The label is the policy's decision, not a list of its own: for every extension the policy
    /// refuses by name, and for documents, scripts and odd names alike, "Apri" appears exactly
    /// when `ActivityFilePolicy` lets the click open the file.
    @Test func theLabelAlwaysAgreesWithThePolicy() {
        let refused = ActivityFilePolicy.excludedExtensions.flatMap { ["file.\($0)", "FILE.\($0.uppercased())"] }
        let others = ["Slide 1.pdf", "dati.csv", "audio.m4a", "codice.zip", "tesi.odt", "x.pdf.command", "a.tar.gz",
                      ".bashrc", "README", "pagina.html", "Tool.app", "disco.dmg", "file.sconosciuto", "nome.", "foto.JPEG"]
        for name in refused + others {
            let expected: ActivityClickAction = ActivityFilePolicy.opensDirectly(filename: name) ? .open : .showInFinder
            #expect(ActivityClickAction(filename: name) == expected, "\(name)")
        }
        for name in refused {
            #expect(ActivityClickAction(filename: name) == .showInFinder, "\(name)")
        }
    }
}
