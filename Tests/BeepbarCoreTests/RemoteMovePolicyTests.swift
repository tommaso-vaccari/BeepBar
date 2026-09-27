import Foundation
import Testing
@testable import BeepbarCore

struct RemoteMovePolicyTests {
    private func file(section: String = "Lab 0", module: String = "Esercizi", single: Bool = false, filename: String = "es1.pdf") -> RemoteFileCandidate {
        RemoteFileCandidate(id: "1:4:/:\(filename)", courseID: 1, sectionID: 1, moduleID: 4, sectionName: section, moduleName: module, moduleType: single ? "resource" : "folder", isSingleFileResource: single, filename: filename, remoteFilePath: "/", canonicalPluginPath: "/pluginfile.php/\(filename)", downloadURL: nil, size: 1, modifiedAt: nil, observedRevision: "1", isSupported: true)
    }

    private func placement(section: String = "Lab 0", module: String = "Esercizi", single: Bool = false) -> RemotePlacement {
        RemotePlacement(sectionName: section, moduleName: module, isSingleFileResource: single)
    }

    @Test func aBaselineWithNoRecordedPlacementIsOnlyRecorded() throws {
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Corso/Lab 1/Esercizi/es1.pdf"), recorded: nil, file: file(), courseFolder: "Corso", moduleFolderOverride: nil)
        #expect(decision == .record)
    }

    @Test func anUnchangedPlacementDoesNothing() throws {
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Corso/Lab 0/Esercizi/es1.pdf"), recorded: placement(), file: file(), courseFolder: "Corso", moduleFolderOverride: nil)
        #expect(decision == .unchanged)
    }

    @Test func aModuleMovedToAnotherSectionMovesTheFile() throws {
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Corso/Lab 1/Esercizi/es1.pdf"), recorded: placement(section: "Lab 1"), file: file(section: "Lab 0"), courseFolder: "Corso", moduleFolderOverride: nil)
        #expect(decision == .move(to: try RelativePath("Corso/Lab 0/Esercizi/es1.pdf")))
    }

    @Test func aNumberedCopyKeepsItsNameInTheNewFolder() throws {
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Corso/Lab 1/Esercizi/es1 (1).pdf"), recorded: placement(section: "Lab 1"), file: file(section: "Lab 0"), courseFolder: "Corso", moduleFolderOverride: nil)
        #expect(decision == .move(to: try RelativePath("Corso/Lab 0/Esercizi/es1 (1).pdf")))
    }

    @Test func aFileSavedByAnOlderPathRuleJoinsItsNeighboursOnARealMove() throws {
        // Not where today's rules would have put it; Moodle moving the module is what moves it,
        // into the folder its neighbours go to.
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Corso/Vecchio schema/es1.pdf"), recorded: placement(section: "Lab 1"), file: file(section: "Lab 0"), courseFolder: "Corso", moduleFolderOverride: nil)
        #expect(decision == .move(to: try RelativePath("Corso/Lab 0/Esercizi/es1.pdf")))
    }

    @Test func aFileOutsideItsCourseFolderIsNeverMoved() throws {
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Altro corso/Esercizi/es1.pdf"), recorded: placement(section: "Lab 1"), file: file(section: "Lab 0"), courseFolder: "Corso", moduleFolderOverride: nil)
        #expect(decision == .record)
    }

    @Test func aModuleFolderRuleMakesSectionMovesIrrelevant() throws {
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Corso/Laboratori/es1.pdf"), recorded: placement(section: "Lab 1"), file: file(section: "Lab 0"), courseFolder: "Corso", moduleFolderOverride: "Laboratori")
        #expect(decision == .record)
    }

    @Test func sectionsNamedLikeMaterialsShareTheCourseFolder() throws {
        // "Materiali" is flattened into the course folder, so moving between two such sections
        // changes nothing on disk.
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Corso/Esercizi/es1.pdf"), recorded: placement(section: "Materiali"), file: file(section: "Altro materiale"), courseFolder: "Corso", moduleFolderOverride: nil)
        #expect(decision == .record)
    }

    @Test func aRenamedSingleFileResourceIsRenamed() throws {
        let decision = try RemoteMovePolicy.decide(baselinePath: RelativePath("Corso/Lab 0/Consegna.pdf"), recorded: placement(module: "Consegna", single: true), file: file(module: "Consegna finale", single: true), courseFolder: "Corso", moduleFolderOverride: nil)
        #expect(decision == .move(to: try RelativePath("Corso/Lab 0/Consegna finale.pdf")))
    }

    @Test func aSummarySavedBeforeMovesWereTrackedStillDecodes() throws {
        let json = Data(#"{"courseID":1,"courseFolder":"Corso","added":1,"updated":0,"items":[{"id":"a","name":"a.pdf","kind":{"added":{}}}]}"#.utf8)
        let course = try JSONDecoder().decode(CourseSyncCount.self, from: json)
        #expect(course.movedItems.isEmpty)
        #expect(course.total == 1)
    }

    @Test func anOutcomeFromANewerVersionDoesNotMakeTheSummaryUnreadable() throws {
        let json = Data(#"{"courseID":1,"courseFolder":"Corso","added":0,"updated":0,"movedItems":[{"id":"a","name":"a.pdf","folder":"Lab 0","outcome":"somethingNew"}]}"#.utf8)
        let course = try JSONDecoder().decode(CourseSyncCount.self, from: json)
        #expect(course.movedItems.isEmpty)
    }

    @Test func movedItemsSurviveARoundTrip() throws {
        let original = CourseSyncCount(courseID: 1, courseFolder: "Corso", added: 0, updated: 0, movedItems: [MovedSyncItem(id: "a", name: "a.pdf", folder: "Lab 0", outcome: .keptEdited)])
        let decoded = try JSONDecoder().decode(CourseSyncCount.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.moved == 0 && decoded.total == 1)
    }
}
