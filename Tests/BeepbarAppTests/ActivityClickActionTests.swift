import Testing
@testable import BeepbarApp

/// The words shown for a click on an Attività file (on hover, tooltip, VoiceOver, context menu)
/// must match what the click does: "Apri" only for files that open, "Mostra nel Finder" for the
/// rest. Italian, the language tests run in (`AppLanguage.current` must not be switched here).
struct ActivityClickActionTests {
    /// Documents say "Apri", with the open-in-app symbol, the file name in the tooltip and a
    /// matching VoiceOver hint.
    @Test(arguments: ["Slide 1.pdf", "esercizi.DOCX", "foto.png"])
    func documentsAreLabelledOpen(name: String) {
        let action = ActivityClickAction(filename: name)
        #expect(action == .open)
        #expect(action.title == "Apri")
        #expect(action.systemImage == "arrow.up.forward.square")
        #expect(action.help(for: name) == "Apri “\(name)”")
        #expect(action.accessibilityHint == "Apre il file")
    }

    /// Files that are only shown in Finder never say "Apri": the label, tooltip and hint all
    /// say what really happens.
    @Test(arguments: ["esercizio.py", "setup.term", "schema.svg", "README"])
    func everythingElseIsLabelledShowInFinder(name: String) {
        let action = ActivityClickAction(filename: name)
        #expect(action == .showInFinder)
        #expect(action.title == "Mostra nel Finder")
        #expect(action.systemImage == "folder")
        #expect(action.help(for: name) == "Mostra “\(name)” nel Finder")
        #expect(action.accessibilityHint == "Mostra il file nel Finder")
    }
}
