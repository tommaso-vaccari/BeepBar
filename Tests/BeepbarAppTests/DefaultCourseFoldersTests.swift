import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct DefaultCourseFoldersTests {
    private func course(_ id: Int64, _ displayName: String) -> RemoteCourseSummary {
        RemoteCourseSummary(id: id, shortName: String(id), displayName: displayName, isVisible: true, startDate: nil, endDate: nil)
    }

    @Test func mapsEveryCourseToItsForkStyleFolder() {
        let folders = WeBeepAuthenticationController.defaultFolders(for: [
            course(1, "054221 - FONDAMENTI DI CALCOLO (2025-26)"),
            course(2, "056902 - ANALISI MATEMATICA 1 (2025-26)"),
            course(3, "Tesi di laurea"),
        ])
        #expect(folders == [1: "fondamenti-di-calcolo", 2: "analisi-matematica-1", 3: "tesi-di-laurea"])
    }

    @Test func fallsBackToTheFullNameOnlyForCoursesWhoseDefaultsCollide() {
        // Two editions of the same course would otherwise share one folder (the comparison is
        // case-insensitive); the courses that collide keep their full name, the others do not.
        let folders = WeBeepAuthenticationController.defaultFolders(for: [
            course(1, "054221 - FONDAMENTI DI CALCOLO (2024-25)"),
            course(2, "054221 - Fondamenti di Calcolo (2025-26)"),
            course(3, "056902 - ANALISI MATEMATICA 1 (2025-26)"),
        ])
        #expect(folders[1] == "054221-fondamenti-di-calcolo-2024-25")
        #expect(folders[2] == "054221-fondamenti-di-calcolo-2025-26")
        #expect(folders[3] == "analisi-matematica-1")
    }

    @Test func identicalNamesGetTheCourseIDSoBothCanBeEnabled() {
        // Generic titles repeat across programmes with different course IDs. A name-derived
        // fallback gives both the same folder, and the second scope can then never be saved.
        let folders = WeBeepAuthenticationController.defaultFolders(for: [
            course(31, "Tesi di laurea"),
            course(47, "Tesi di laurea"),
            course(3, "056902 - ANALISI MATEMATICA 1 (2025-26)"),
        ])
        #expect(folders == [31: "tesi-di-laurea-31", 47: "tesi-di-laurea-47", 3: "analisi-matematica-1"])
    }

    @Test func namesDifferingOnlyInCaseOrAccentSpellingAreTheSameFolder() {
        // The disk treats these as one folder, so they must be told apart like identical names.
        let composed = "Prova finale e\u{301}".precomposedStringWithCanonicalMapping
        let decomposed = "Prova finale e\u{301}".decomposedStringWithCanonicalMapping
        let folders = WeBeepAuthenticationController.defaultFolders(for: [
            course(1, composed), course(2, decomposed.uppercased()), course(3, "PROVA FINALE \(composed.suffix(1))"),
        ])
        #expect(Set(folders.values.map(PathKey.of)).count == 3)
        #expect(folders[1]?.hasSuffix("-1") == true)
        #expect(folders[2]?.hasSuffix("-2") == true)
        #expect(folders[3]?.hasSuffix("-3") == true)
    }

    @Test func aCourseIDSuffixNeverLandsOnAnotherCoursesFolder() {
        // "Analisi" twice becomes "analisi-5" and "analisi-6"; a course really called
        // "Analisi 5" must not end up sharing a folder with the first one.
        let folders = WeBeepAuthenticationController.defaultFolders(for: [
            course(5, "Analisi"), course(6, "Analisi"), course(7, "Analisi 5"),
        ])
        #expect(Set(folders.values.map(PathKey.of)).count == 3)
        #expect(folders[7] == "analisi-5-7")
    }

    @Test func everyCourseGetsADistinctFolderWhateverTheNames() {
        let names = ["Tesi di laurea", "TESI DI LAUREA", "Tesi-di-laurea", "Tesi di laurea 12",
                     "054221 - Tesi di laurea (2024-25)", "054221 - Tesi di laurea (2025-26)",
                     "Tirocinio", "Tirocinio", "Tirocinio", "", "", "!!!",
                     String(repeating: "Corso molto lungo ", count: 20), String(repeating: "Corso molto lungo ", count: 20)]
        let courses = names.enumerated().map { course(Int64($0.offset + 10), $0.element) }
        let folders = WeBeepAuthenticationController.defaultFolders(for: courses)
        #expect(folders.count == courses.count)
        #expect(Set(folders.values.map(PathKey.of)).count == courses.count)
        #expect(folders.values.allSatisfy { !$0.isEmpty && $0.utf8.count <= 100 })
        // Deterministic: the same catalog always yields the same folders.
        #expect(WeBeepAuthenticationController.defaultFolders(for: courses.reversed()) == folders)
    }

    @Test func coursesWithoutACollisionKeepTheirShortFolder() {
        let folders = WeBeepAuthenticationController.defaultFolders(for: [
            course(1, "Tesi di laurea"), course(2, "Tesi di laurea"), course(3, "Tirocinio"),
        ])
        #expect(folders[3] == "tirocinio")
    }

    @Test func aDefaultTakenByAnotherCoursesSavedFolderGetsTheCourseID() {
        // Course 1 was renamed by the user onto "analisi", which course 9 would get by default.
        let folders = WeBeepAuthenticationController.defaultFolders(
            for: [course(1, "Fisica"), course(9, "Analisi"), course(4, "Chimica")],
            saved: [1: "Analisi"]
        )
        #expect(folders[9] == "analisi-9")
        #expect(folders[4] == "chimica")
    }

    @Test func aCourseKeepsItsDefaultWhenOnlyItsOwnSavedFolderMatches() {
        let folders = WeBeepAuthenticationController.defaultFolders(
            for: [course(9, "Analisi"), course(4, "Chimica")],
            saved: [9: "analisi", 4: "CHIMICA"]
        )
        #expect(folders == [9: "analisi", 4: "chimica"])
    }

    @Test func theIDSuffixForcedByASavedFolderNeverLandsOnAnotherCourse() {
        // "analisi" is saved for course 1, so course 9 gets "analisi-9": course 20, really
        // called "Analisi 9", must then move aside instead of sharing that folder.
        let folders = WeBeepAuthenticationController.defaultFolders(
            for: [course(1, "Fisica"), course(9, "Analisi"), course(20, "Analisi 9")],
            saved: [1: "analisi"]
        )
        #expect(folders[9] == "analisi-9")
        #expect(folders[20] == "analisi-9-20")
        let saved: [Int64: String] = [1: "analisi"]
        let all = folders.filter { $0.key != 1 }.values.map(PathKey.of) + saved.values.map(PathKey.of)
        #expect(Set(all).count == all.count)
    }

    @Test func aCounterIsAddedWhenEvenTheIDNameIsSavedForAnotherCourse() {
        // The user renamed other courses' folders onto the names course 47 would fall back to.
        let saved: [Int64: String] = [1: "Tesi-di-laurea-47", 2: "tesi-di-laurea-47-2", 3: "tesi-di-laurea"]
        let folders = WeBeepAuthenticationController.defaultFolders(for: [course(47, "Tesi di laurea")], saved: saved)
        #expect(folders[47] == "tesi-di-laurea-47-3")
    }

    @Test func twoIDCarryingNamesThatCoincideAreStillSeparated() {
        // Course 5 "A" climbs to "a-5-2" (its "a-5" is saved elsewhere); course 2, really
        // called "A 5", climbs to "a-5-2" as well because "a-5" is saved.
        let folders = WeBeepAuthenticationController.defaultFolders(
            for: [course(5, "A"), course(6, "A"), course(2, "A 5")],
            saved: [100: "a-5", 101: "a"]
        )
        let values = folders.values.map(PathKey.of) + ["a-5", "a"]
        #expect(Set(values).count == values.count)
    }

    @Test func emptyCourseListYieldsEmptyMap() {
        #expect(WeBeepAuthenticationController.defaultFolders(for: []).isEmpty)
    }

    @Test func identicalNamesUseIDAsAStrictTieBreaker() {
        let ordered = WeBeepAuthenticationController.orderedForDisplay([
            course(3, "Analisi"), course(1, "Analisi"), course(2, "Analisi")
        ], enabledCourseIDs: [])
        #expect(ordered.map(\.id) == [1, 2, 3])
    }

    @Test func progressDetailIncludesCompletedAndTotalFiles() {
        let progress = SyncProgress(completed: 3, total: 10, installed: 2, preservedLocal: 0, unchanged: 1, conflicts: 0, failures: 0)
        #expect(WeBeepAuthenticationController.progressDetail(progress) == "3 di 10 file")
    }

    @Test func newRootKeepsCurrentSelectionsForAvailableCourses() {
        let restored = WeBeepAuthenticationController.restoredEnabledCourseIDs(
            scopes: [], current: [1, 3, 99], remoteIDs: [1, 2, 3]
        )
        #expect(restored == [1, 3])
    }

    @Test func existingRootUsesPersistedSelections() {
        let rootID = UUID()
        let scopes = [
            SyncScope(rootID: rootID, courseID: 1, displayName: "One", localFolder: "One", enabled: false),
            SyncScope(rootID: rootID, courseID: 2, displayName: "Two", localFolder: "Two", enabled: true),
        ]
        let restored = WeBeepAuthenticationController.restoredEnabledCourseIDs(
            scopes: scopes, current: [1], remoteIDs: [1, 2]
        )
        #expect(restored == [2])
    }
}
