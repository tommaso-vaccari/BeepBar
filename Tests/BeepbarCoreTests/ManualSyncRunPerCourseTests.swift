import Foundation
import Testing
@testable import BeepbarCore

struct ManualSyncRunPerCourseTests {
    /// Concurrent downloads stay independent; finishing one must not clear the other.
    @Test func transferCountersCombineAndRemoveOnlyFinishedTransfer() {
        let counters = TransferProgressCounters()
        counters.begin("a", total: 100)
        counters.begin("b", total: 200)
        #expect(counters.snapshot() == nil)
        counters.add(50, id: "a")
        counters.add(25, id: "b")
        #expect(counters.snapshot() == SyncTransferProgress(received: 75, total: 300))
        counters.end("a")
        #expect(counters.snapshot() == SyncTransferProgress(received: 25, total: 200))
        counters.end("b")
        #expect(counters.snapshot() == nil)
        counters.begin("a", total: Int64.max)
        counters.begin("b", total: 1)
        counters.add(1, id: "a")
        #expect(counters.snapshot() == nil)
    }

    private func item(id: String, courseID: Int64, destination: String) -> PreparedSyncItem {
        let remote = RemoteFileCandidate(id: id, courseID: courseID, sectionID: 1, moduleID: 1, sectionName: "", moduleName: "", filename: "f", remoteFilePath: "/", canonicalPluginPath: "/p", downloadURL: nil, size: 0, modifiedAt: nil, observedRevision: "r", isSupported: true)
        return PreparedSyncItem(remote: remote, destination: try! RelativePath(destination))
    }

    @Test func syncedItemTakesOnlyTheFileNameNotTheFullPath() {
        let synced = ManualSyncRun.syncedItem(for: item(id: "a", courseID: 1, destination: "Corso/Lezioni/slide 3.pdf"), kind: .added)
        #expect(synced.name == "slide 3.pdf")
        #expect(synced.id == "a")
        #expect(synced.kind == .added)
    }

    @Test func courseFolderTakesOnlyTheFirstPathComponent() {
        #expect(ManualSyncRun.courseFolder(for: try! RelativePath("Analisi 2/Esercizi/e1.pdf")) == "Analisi 2")
    }

    @Test func snapshotPerCourseGroupsCountsAndItemsPerCourseAndSortsBothLevels() {
        let items: [Int64: [SyncedItem]] = [
            1: [SyncedItem(id: "a1", name: "Zeta.pdf", kind: .added), SyncedItem(id: "a2", name: "Alpha.pdf", kind: .added)],
            2: [SyncedItem(id: "b1", name: "Only.pdf", kind: .updated)],
        ]
        let snapshot = ManualSyncRun.snapshotPerCourse(
            added: [1: 2],
            updated: [2: 1],
            folders: [1: "Zeta Course", 2: "Alpha Course"],
            items: items
        )

        // Courses come back sorted by folder name, not by course ID.
        #expect(snapshot.map(\.courseFolder) == ["Alpha Course", "Zeta Course"])

        let alpha = snapshot.first { $0.courseID == 2 }
        #expect(alpha?.added == 0)
        #expect(alpha?.updated == 1)
        #expect(alpha?.items.map(\.name) == ["Only.pdf"])

        let zeta = snapshot.first { $0.courseID == 1 }
        #expect(zeta?.added == 2)
        #expect(zeta?.updated == 0)
        // Items within a course come back sorted by name too, not insertion order.
        #expect(zeta?.items.map(\.name) == ["Alpha.pdf", "Zeta.pdf"])
    }

    @Test func snapshotPerCourseIncludesNamedFailures() {
        let failures = [
            FailedSyncItem(id: "b", name: "Zeta.pdf", reason: "Errore del server (503)."),
            FailedSyncItem(id: "a", name: "Alpha.pdf", reason: "Risposta non valida."),
        ]
        let snapshot = ManualSyncRun.snapshotPerCourse(
            added: [:],
            updated: [:],
            folders: [1: "Analisi"],
            items: [:],
            failures: [1: failures]
        )

        #expect(snapshot.count == 1)
        #expect(snapshot[0].failedItems.map(\.name) == ["Alpha.pdf", "Zeta.pdf"])
        #expect(snapshot[0].total == 2)
    }

    @Test func snapshotPerCourseOmitsCoursesWithNoActivity() {
        let snapshot = ManualSyncRun.snapshotPerCourse(added: [:], updated: [:], folders: [1: "Untouched"], items: [:])
        #expect(snapshot.isEmpty)
    }
}
