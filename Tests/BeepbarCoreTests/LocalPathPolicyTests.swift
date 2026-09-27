import Foundation
import Testing
@testable import BeepbarCore

struct LocalPathPolicyTests {
    @Test func migratesOnlyGeneratedCourseFolderNames() {
        let current = "056902 - GPUS & HETEROGENEOUS SYSTEMS (PROGRAMMING MODELS AND ARCHITECTURES) (MIELE) [2026-27]"
        #expect(LocalPathPolicy.generatedCourseFolderReplacement(
            storedFolder: "GPUS &amp; HETEROGENEOUS SYSTEMS (PROGRAMMING MODELS AND ARCHITECTURES)",
            storedCourseName: current,
            currentCourseName: current,
            courseID: 24_760
        ) == "gpus-heterogeneous-systems-programming-models-and-architectures")
        #expect(LocalPathPolicy.generatedCourseFolderReplacement(
            storedFolder: "My GPU course",
            storedCourseName: current,
            currentCourseName: current,
            courseID: 24_760
        ) == nil)
    }

    @Test func disambiguatedCourseFolderAppendsTheIDAndStaysWithinTheLengthLimit() {
        #expect(LocalPathPolicy.courseFolder("tesi-di-laurea", disambiguatedBy: 31) == "tesi-di-laurea-31")
        let long = LocalPathPolicy.courseFolderSlug(String(repeating: "corso lungo ", count: 20))
        let first = LocalPathPolicy.courseFolder(long, disambiguatedBy: 1)
        let second = LocalPathPolicy.courseFolder(long, disambiguatedBy: 2)
        #expect(first.utf8.count <= 100 && second.utf8.count <= 100)
        #expect(first != second)
    }

    @Test func aSavedFolderIsNotRenamedWhenItsDefaultGainsTheCourseID() {
        // Users who already enabled one of two identically named courses keep its folder.
        #expect(LocalPathPolicy.generatedCourseFolderReplacement(
            storedFolder: "tesi-di-laurea",
            storedCourseName: "Tesi di laurea",
            currentCourseName: "Tesi di laurea",
            courseID: 31,
            currentDefaultFolder: "tesi-di-laurea-31"
        ) == nil)
        // One-word and hyphenated names read the same as their legacy spelling, ignoring case:
        // the current-scheme folder must still be kept.
        for (name, folder) in [("Tirocinio", "tirocinio"), ("Fisica", "Fisica"), ("Analisi-1", "analisi-1"),
                               ("054221 - Tirocinio (2025-26)", "054221-tirocinio-2025-26"), ("054221 - Tirocinio (2025-26)", "tirocinio")] {
            #expect(LocalPathPolicy.generatedCourseFolderReplacement(
                storedFolder: folder,
                storedCourseName: name,
                currentCourseName: name,
                courseID: 31,
                currentDefaultFolder: LocalPathPolicy.courseFolder(LocalPathPolicy.courseFolderSlug(name), disambiguatedBy: 31)
            ) == nil, "\(folder) was renamed")
        }
        // A folder from the old naming scheme still moves to the (now distinct) default.
        #expect(LocalPathPolicy.generatedCourseFolderReplacement(
            storedFolder: "Tesi di laurea (31)",
            storedCourseName: "Tesi di laurea",
            currentCourseName: "Tesi di laurea",
            courseID: 31,
            currentDefaultFolder: "tesi-di-laurea-31"
        ) == "tesi-di-laurea-31")
    }

    @Test func uniqueDestinationTreatsCaseAndAccentSpellingAsTheSameFile() throws {
        var reserved: Set<String> = []
        let composed = try RelativePath("Corso/Lezione \u{E8}.pdf")
        let decomposed = try RelativePath("CORSO/LEZIONE e\u{300}.PDF")
        #expect(try LocalPathPolicy.uniqueDestination(composed, reserving: &reserved) == composed)
        #expect(try LocalPathPolicy.uniqueDestination(decomposed, reserving: &reserved).value == "CORSO/LEZIONE \u{E8} (1).PDF")
    }

    @Test func buildsStableSafeDestination() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Settimana 1", moduleName: "Lezioni", filename: "Analisi è.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file).value == "Analisi/Settimana 1/Lezioni/Analisi è.pdf")
    }

    @Test func blocksReservedRemotePath() {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "S", moduleName: "M", filename: "a.pdf", remoteFilePath: "/.beepbar/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: false)
        #expect(throws: LocalPathPolicyError.invalidRemotePath) { try LocalPathPolicy.destination(courseFolder: "Analisi", file: file) }
    }

    @Test func omitsMaterialsSectionAndFlattensSingleResource() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Materiali", moduleName: "Dispensa", moduleType: "resource", isSingleFileResource: true, filename: "originale.pdf", remoteFilePath: "/dispense/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file).value == "Analisi/dispense/Dispensa.pdf")
    }

    @Test func keepsSectionAndRemotePathForSingleResource() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Esami", moduleName: "Regole esame", moduleType: "resource", isSingleFileResource: true, filename: "originale.pdf", remoteFilePath: "/2026/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file).value == "Analisi/Esami/2026/Regole esame.pdf")
    }

    @Test func moduleFolderReplacesMoodlePrefixAndKeepsRemotePathAndFilename() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Esami", moduleName: "Regole esame", filename: "originale.pdf", remoteFilePath: "/2026/appelli/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)

        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file, moduleFolderOverride: "Esami/Orali").value == "Analisi/Esami/Orali/2026/appelli/originale.pdf")
    }

    @Test func moduleFolderPreservesSingleResourceNaming() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Esami", moduleName: "Regole esame", moduleType: "resource", isSingleFileResource: true, filename: "originale.pdf", remoteFilePath: "/2026/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)

        #expect(try LocalPathPolicy.destination(courseFolder: "Analisi", file: file, moduleFolderOverride: "Materiali/Esame").value == "Analisi/Materiali/Esame/2026/Regole esame.pdf")
    }

    @Test func moduleFolderRejectsUnsafePathsAndOverlongComponents() {
        for path in ["/outside", "../outside", "notes/../outside", ".beepbar", "notes/.BEEPBAR", String(repeating: "a", count: 256)] {
            #expect(throws: RelativePathError.invalid) { try LocalPathPolicy.moduleFolder(path) }
        }
        #expect(throws: RelativePathError.invalid) { try LocalPathPolicy.moduleFolder(String(repeating: "a", count: 513)) }
    }

    @Test func omitsUnnamedSection() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "", moduleName: "LECTURES", filename: "intro.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "ALGEBRA", file: file).value == "ALGEBRA/LECTURES/intro.pdf")
    }

    @Test func flattensUnnamedModuleIntoCourseFolder() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "", moduleName: "", filename: "P0_Antonietti.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: URL(string: "https://webeep.polimi.it/pluginfile.php/a.pdf"), size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "NUMERICAL LINEAR ALGEBRA", file: file).value == "NUMERICAL LINEAR ALGEBRA/P0_Antonietti.pdf")
    }

    @Test func numbersDuplicateFilenames() throws {
        let original = try RelativePath("ALGEBRA/LECTURES/notes.pdf")
        var reserved = Set<String>()

        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes.pdf")
        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes (1).pdf")
        #expect(try LocalPathPolicy.uniqueDestination(original, reserving: &reserved).value == "ALGEBRA/LECTURES/notes (2).pdf")
    }

    @Test func replacesFilenameSeparatorsWithoutCreatingDirectories() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "", moduleName: "LECTURES", filename: "part/one\\draft.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "ALGEBRA", file: file).value == "ALGEBRA/LECTURES/part_one_draft.pdf")
    }

    @Test func sanitizesSpecialCharacters() throws {
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "Exam:\t2026", moduleName: "Rules?*", filename: "draft\n\"one\"<>|.pdf", remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: true)
        #expect(try LocalPathPolicy.destination(courseFolder: "ALGEBRA", file: file).value == "ALGEBRA/Exam_ 2026/Rules__/draft _one____.pdf")
    }

    @Test func treatsCaseAndUnicodeEquivalentDestinationsAsDuplicates() throws {
        var reserved = Set<String>()
        let uppercase = try RelativePath("ALGEBRA/Notes.pdf")
        let lowercase = try RelativePath("algebra/notes.pdf")
        let decomposed = try RelativePath("ALGEBRA/Cafe\u{301}.pdf")
        let composed = try RelativePath("ALGEBRA/Caf\u{e9}.pdf")

        #expect(try LocalPathPolicy.uniqueDestination(uppercase, reserving: &reserved).value == "ALGEBRA/Notes.pdf")
        #expect(try LocalPathPolicy.uniqueDestination(lowercase, reserving: &reserved).value == "algebra/notes (1).pdf")
        #expect(try LocalPathPolicy.uniqueDestination(decomposed, reserving: &reserved).value == "ALGEBRA/Cafe\u{301}.pdf")
        #expect(try LocalPathPolicy.uniqueDestination(composed, reserving: &reserved).value == "ALGEBRA/Caf\u{e9} (1).pdf")
    }

    @Test func extractsForkStyleCourseFolder() {
        #expect(LocalPathPolicy.defaultCourseFolder("054221 - FONDAMENTI DI CALCOLO (2025-26)") == "fondamenti-di-calcolo")
    }

    @Test func removesUnipdMetadataFromCourseFolder() {
        #expect(LocalPathPolicy.defaultCourseFolder("BIOENGINEERING FOR NEUROREHABILITATION 2025-2026 - INQ4105620") == "bioengineering-for-neurorehabilitation")
    }

    @Test func migratesGeneratedUnipdFolderButPreservesCustomFolder() {
        let course = "BIOMARKERS, PRECISION MEDICINE AND DRUG DEVELOPMENT 2024-2025 - INQ1096858"
        #expect(LocalPathPolicy.generatedCourseFolderReplacement(
            storedFolder: course,
            storedCourseName: course,
            currentCourseName: course,
            courseID: 10_968_58
        ) == "biomarkers-precision-medicine-and-drug-development")
        #expect(LocalPathPolicy.generatedCourseFolderReplacement(
            storedFolder: "My biomarkers course",
            storedCourseName: course,
            currentCourseName: course,
            courseID: 10_968_58
        ) == nil)
    }

    @Test func treatsTheReservedNamespaceAsReservedRegardlessOfCase() {
        #expect(LocalPathPolicy.component(".BEEPBAR") == "_")
        #expect(LocalPathPolicy.component(".Beepbar") == "_")
        let file = RemoteFileCandidate(id: "9:4:/pluginfile.php/a.pdf", courseID: 9, sectionID: 1, moduleID: 4, sectionName: "S", moduleName: "M", filename: "a.pdf", remoteFilePath: "/.BEEPBAR/", canonicalPluginPath: "/pluginfile.php/a.pdf", downloadURL: nil, size: 4, modifiedAt: nil, observedRevision: "1:4", isSupported: false)
        #expect(throws: LocalPathPolicyError.invalidRemotePath) { try LocalPathPolicy.destination(courseFolder: "Analisi", file: file) }
    }
}
