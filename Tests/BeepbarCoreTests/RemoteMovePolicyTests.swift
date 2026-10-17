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

    /// Contradictory or missing names never replace a saved override, in either response order.
    @Test func ambiguousOverrideMetadataKeepsSavedName() {
        let saved = ModulePathOverride(rootID: UUID(), courseID: 1, moduleID: 4, localFolder: "Custom", lastKnownName: "Saved")
        for names in [["First", "Second"], ["Second", "First"], ["", "First"], ["First", ""], [""]] {
            let files = names.map { file(module: $0) }
            #expect(SyncCoordinator.moduleOverrideRenames(files: files, overrides: [1: [4: saved]]).isEmpty)
        }
        #expect(SyncCoordinator.moduleOverrideRenames(files: [file(module: "First"), file(module: "First")], overrides: [1: [4: saved]]) == [1: [4: "First"]])
        #expect(SyncCoordinator.moduleOverrideRenames(files: [file(module: "Saved")], overrides: [1: [4: saved]]).isEmpty)
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

/// Pins every clause of `RemoteMoveJournal.happened`, the decision recovery uses to commit or drop
/// an interrupted Moodle move (#219). The end-to-end tests never leave the moved bytes at both ends
/// of a move nor swap two byte-identical files, so dropping `&& !holds(source)` or `&& !unswapped`
/// survived the whole suite; the identical-copy rows below fail under either mutation.
struct RemoteMoveJournalDecisionTests {
    private enum Disk { case missing, moved, other }

    private func state(_ disk: Disk, moved: String) -> FileSnapshotState {
        switch disk {
        case .missing: return .missing
        case .moved: return .present(FileSnapshot(device: 1, inode: 1, sha256: moved))
        case .other: return .present(FileSnapshot(device: 1, inode: 2, sha256: "edited"))
        }
    }

    /// A single move, as (destination, origin) on disk -> whether recovery commits it. The rule:
    /// the destination holds the moved bytes and the origin no longer does, or the origin is gone
    /// and the destination holds anything (moved, then edited).
    @Test func aSingleMoveIsDecidedFromBothEnds() throws {
        let move = PendingRemoteMove(batchID: UUID(), remoteID: "r1", from: try RelativePath("C/Old/a.pdf"), to: try RelativePath("C/New/a.pdf"), sha256: "A", placement: nil)
        let table: [(destination: Disk, origin: Disk, happened: Bool)] = [
            (.moved, .missing, true),
            (.moved, .other, true),
            // A byte-identical copy at the destination while the origin is untouched: not moved.
            (.moved, .moved, false),
            (.other, .missing, true),
            (.other, .moved, false),
            (.missing, .moved, false),
            (.other, .other, false),
            (.missing, .missing, false),
        ]
        for row in table {
            let decided = RemoteMoveJournal.happened([(move, state(row.destination, moved: "A"), state(row.origin, moved: "A"))])
            #expect(decided == row.happened, "destination \(row.destination), origin \(row.origin)")
        }
    }

    /// The two halves of a swap, as (contents of `a`, contents of `b`) -> whether the swap is
    /// done. `a` started with "A" and moves to `b`; `b` started with "B" and moves to `a`.
    @Test func aSwapIsDoneOnlyWhenNeitherPathStillHoldsItsOwnContents() throws {
        let a = try RelativePath("C/a.pdf"), b = try RelativePath("C/b.pdf")
        let batch = UUID()
        func decide(a onA: String?, b onB: String?, contentsA: String = "A", contentsB: String = "B") -> Bool {
            let first = PendingRemoteMove(batchID: batch, remoteID: "r1", from: a, to: b, sha256: contentsA, placement: nil)
            let second = PendingRemoteMove(batchID: batch, remoteID: "r2", from: b, to: a, sha256: contentsB, placement: nil)
            func disk(_ sha: String?) -> FileSnapshotState { sha.map { .present(FileSnapshot(device: 1, inode: 9, sha256: $0)) } ?? .missing }
            return RemoteMoveJournal.happened([(first, disk(onB), disk(onA)), (second, disk(onA), disk(onB))])
        }
        #expect(decide(a: "B", b: "A"))
        #expect(decide(a: "edited", b: "A"))
        #expect(decide(a: nil, b: "A"))
        #expect(!decide(a: "A", b: "B"))
        #expect(!decide(a: "A", b: "edited"))
        #expect(!decide(a: "edited", b: "edited"))
        #expect(!decide(a: nil, b: nil))
        // Two byte-identical files: both "swapped" and "unswapped" hold, so nothing proves the
        // swap and the rows are dropped.
        #expect(!decide(a: "same", b: "same", contentsA: "same", contentsB: "same"))
    }

    /// Any batch shape `SyncCoordinator` does not write is done only when every file arrived.
    @Test func anUnknownShapeIsDoneOnlyIfEveryFileArrived() throws {
        let batch = UUID()
        let moves = try (1...3).map { PendingRemoteMove(batchID: batch, remoteID: "r\($0)", from: try RelativePath("C/o\($0)"), to: try RelativePath("C/n\($0)"), sha256: "S\($0)", placement: nil) }
        let arrived = moves.map { ($0, state(.moved, moved: $0.sha256), FileSnapshotState.missing) }
        #expect(RemoteMoveJournal.happened(arrived))
        var oneMissing = arrived
        oneMissing[1] = (moves[1], .missing, state(.moved, moved: moves[1].sha256))
        #expect(!RemoteMoveJournal.happened(oneMissing))
    }
}
