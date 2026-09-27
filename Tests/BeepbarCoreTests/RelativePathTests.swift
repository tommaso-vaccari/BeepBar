import Testing
@testable import BeepbarCore

struct RelativePathTests {
    @Test func acceptsNestedUnicodePath() throws {
        #expect(try RelativePath("Analisi/Lezione è.pdf").value == "Analisi/Lezione è.pdf")
    }

    @Test func rejectsUnsafePaths() {
        for value in ["", "/tmp/file", "../file", "Course/../file", "Course//file", "./file", ".beepbar/state.sqlite"] {
            #expect(throws: RelativePathError.invalid) { try RelativePath(value) }
        }
    }

    @Test func rejectsTheReservedNamespaceRegardlessOfCase() {
        for value in [".BEEPBAR", ".BEEPBAR/state.sqlite", ".Beepbar/staging/x.partial", ".BeePbAr/conflicts/a/b.pdf"] {
            #expect(throws: RelativePathError.invalid) { try RelativePath(value) }
        }
    }

    @Test func comparisonKeyMatchesWhatTheDiskTreatsAsOneFile() throws {
        let composed = try RelativePath("Analisi/Lezione \u{E8}.pdf")
        let decomposed = try RelativePath("ANALISI/lezione e\u{300}.PDF")
        #expect(composed.comparisonKey == decomposed.comparisonKey)
        #expect(composed.comparisonKey != (try RelativePath("Analisi/Lezione e.pdf")).comparisonKey)
        #expect(PathKey.of("Tesi-Di-Laurea") == PathKey.of("tesi-di-laurea"))
        #expect(PathKey.of("Tesi di laurea") != PathKey.of("tesi-di-laurea"))
    }

    @Test func reservedNamespaceChecksShareTheSameKey() {
        #expect(ReservedNamespace.isReservedComponent(".BEEPBAR"))
        #expect(ReservedNamespace.isReservedTopLevelName(".BeepBar-old"))
        #expect(!ReservedNamespace.isReservedComponent("beepbar"))
    }
}
