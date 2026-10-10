import Foundation
import Testing
@testable import BeepbarCore

/// Bounded pagination of an expanded course in Attività (#99): which rows a course shows, in
/// what order, under which ids, and how many at a time. These are the decisions the SwiftUI card
/// draws; a wrong one shows rows out of order, loses the last element behind "Mostra altri", or
/// gives two rows one id (SwiftUI then draws the wrong row or none). Italian wording, since
/// tests run with the default language and must not switch `AppLanguage.current`.
struct ActivityRowLayoutTests {
    private func course(id: Int64 = 7, failure: String? = nil, files: [SyncedItem] = [], moved: [MovedSyncItem] = [], failed: [FailedSyncItem] = []) -> CourseSyncCount {
        CourseSyncCount(courseID: id, courseFolder: "Analisi", added: files.filter { $0.kind == .added }.count, updated: files.filter { $0.kind == .updated }.count, items: files, failedItems: failed, courseFailure: failure, movedItems: moved)
    }

    private func files(_ count: Int, prefix: String = "f") -> [SyncedItem] {
        (0..<count).map { SyncedItem(id: "\(prefix)\($0)", name: "\(prefix)\($0).pdf", kind: $0.isMultiple(of: 2) ? .added : .updated) }
    }

    private func itemID(_ row: ActivityRow) -> String {
        switch row.content {
        case .courseFailure: "failure"
        case .file(let item): item.id
        case .moved(let item): item.id
        case .failed(let item): item.id
        }
    }

    // MARK: Order and content

    /// A course with every kind of row shows them in the order the card always had: the course
    /// failure first, then new/updated files, then moved files, then failed ones, each group in
    /// the order Core delivered (Core sorts by name). The row carries the item itself, so names,
    /// kinds, outcomes and reasons reach the view unchanged.
    @Test func rowsKeepTheFailureFilesMovedFailedOrderAndTheirContent() {
        let file = SyncedItem(id: "a", name: "a.pdf", kind: .updated)
        let moved = MovedSyncItem(id: "m", name: "m.pdf", folder: "Lezioni", outcome: .keptEdited)
        let failed = FailedSyncItem(id: "x", name: "x.pdf", reason: "Errore del server (503).")
        let page = ActivityRowLayout.page(for: course(failure: "Corso non leggibile", files: [file], moved: [moved], failed: [failed]), visible: 10)

        #expect(page.rows.map(\.content) == [.courseFailure("Corso non leggibile"), .file(file), .moved(moved), .failed(failed)])
        #expect(page.isComplete)
        #expect(page.hiddenCount == 0)
        #expect(ActivityRowLayout.rowCount(for: course(failure: "Corso non leggibile", files: [file], moved: [moved], failed: [failed])) == 4)
    }

    /// Moves and errors mixed with files, more than one page: the page boundary falls inside a
    /// group and the next page continues exactly where the first stopped, with no row skipped or
    /// repeated; the last page ends on the last failed item.
    @Test func pagesCutAcrossGroupsWithoutSkippingOrRepeating() {
        let moved = (0..<3).map { MovedSyncItem(id: "m\($0)", name: "m\($0).pdf", folder: "", outcome: $0 == 1 ? .keptEdited : .moved) }
        let failed = (0..<2).map { FailedSyncItem(id: "x\($0)", name: "x\($0).pdf", reason: "r") }
        let course = course(files: files(4), moved: moved, failed: failed)
        let all = ActivityRowLayout.page(for: course, visible: Int.max, pageSize: 3).rows
        #expect(all.map(itemID) == ["f0", "f1", "f2", "f3", "m0", "m1", "m2", "x0", "x1"])

        var visible = 3
        var seen: [ActivityRow] = []
        // Bounded so a step that stops growing fails here instead of hanging the suite.
        for _ in 0..<10 {
            let page = ActivityRowLayout.page(for: course, visible: visible, pageSize: 3)
            #expect(Array(page.rows.prefix(seen.count)) == seen, "a longer page must start with the shorter one")
            seen = page.rows
            if page.isComplete { break }
            let next = ActivityRowLayout.nextVisibleCount(after: visible, total: ActivityRowLayout.rowCount(for: course), pageSize: 3)
            #expect(next > visible, "every step must reveal at least one row")
            visible = next
        }
        #expect(seen == all)
        #expect(seen.last.map(itemID) == "x1")
    }

    // MARK: Ids

    /// The same remote id can appear as a file, a moved file and a failed file of one course, and
    /// the same remote id appears in two courses: every row still gets its own id, and no course
    /// shares an id with another, so a flattened or per-card `ForEach` never sees duplicates.
    @Test func idsAreUniqueAcrossKindsAndCourses() {
        let shared = "same-remote-id"
        let a = course(id: 1, failure: "f", files: [SyncedItem(id: shared, name: "a.pdf", kind: .updated)], moved: [MovedSyncItem(id: shared, name: "a.pdf", folder: "", outcome: .moved)], failed: [FailedSyncItem(id: shared, name: "a.pdf", reason: "r")])
        let b = course(id: 2, failure: "f", files: [SyncedItem(id: shared, name: "a.pdf", kind: .updated)], moved: [MovedSyncItem(id: shared, name: "a.pdf", folder: "", outcome: .moved)], failed: [FailedSyncItem(id: shared, name: "a.pdf", reason: "r")])
        let ids = (ActivityRowLayout.page(for: a, visible: 10).rows + ActivityRowLayout.page(for: b, visible: 10).rows).map(\.id)

        #expect(ids.count == 8)
        #expect(Set(ids).count == ids.count, "\(ids)")

        // Uniqueness must come from the kind, not from the repeat suffix: a moved row keeps its id
        // whether or not a file row with the same remote id precedes it, otherwise SwiftUI would
        // re-identify (and rebuild) the moved row when the file row disappears.
        let onlyMoved = course(id: 1, moved: [MovedSyncItem(id: shared, name: "a.pdf", folder: "", outcome: .moved)])
        let movedIDs = { (page: ActivityRowPage) in page.rows.filter { if case .moved = $0.content { true } else { false } }.map(\.id) }
        #expect(movedIDs(ActivityRowLayout.page(for: a, visible: 10)) == movedIDs(ActivityRowLayout.page(for: onlyMoved, visible: 10)))
        #expect(movedIDs(ActivityRowLayout.page(for: a, visible: 10)).allSatisfy { !$0.contains("#") }, "no suffix is needed when kinds differ")
    }

    /// Even when Core reports one remote id twice inside the same group (a file retried in one
    /// run), the rows differ, and the repeat keeps the same id whether it is revealed on the
    /// first page or a later one: the suffix counts repeats over the prefix, which never changes.
    @Test func aRepeatedIdInsideOneGroupStaysUniqueAndStableAcrossPages() {
        let twice = [SyncedItem(id: "dup", name: "a.pdf", kind: .added), SyncedItem(id: "other", name: "b.pdf", kind: .added), SyncedItem(id: "dup", name: "a.pdf", kind: .updated)]
        let course = course(files: twice)
        let firstPage = ActivityRowLayout.page(for: course, visible: 2, pageSize: 2)
        let all = ActivityRowLayout.page(for: course, visible: 3, pageSize: 2)

        #expect(Set(all.rows.map(\.id)).count == 3, "\(all.rows.map(\.id))")
        #expect(all.rows[0].id != all.rows[2].id)
        #expect(Array(all.rows.prefix(2)) == firstPage.rows)
        #expect(all.rows.map(\.content) == twice.map { .file($0) })
    }

    /// Two refreshes of the same summary (a new `CourseSyncCount` value with equal contents, as
    /// the controller republishes after restore) produce identical rows and ids, so SwiftUI keeps
    /// row identity and nothing is rebuilt or re-identified. Ids do not depend on position:
    /// a row keeps its id when a row before it disappears.
    @Test func idsAreStableAcrossRefreshesAndDoNotDependOnPosition() {
        let items = files(5)
        let first = ActivityRowLayout.page(for: course(files: items), visible: 5)
        let again = ActivityRowLayout.page(for: course(files: items), visible: 5)
        #expect(first == again)

        let withoutFirst = ActivityRowLayout.page(for: course(files: Array(items.dropFirst())), visible: 5)
        #expect(withoutFirst.rows.map(\.id) == Array(first.rows.dropFirst()).map(\.id))
    }

    // MARK: Bounds

    /// The first expansion shows exactly one page and reports what is left; `visible` beyond the
    /// course clamps to the whole course with nothing hidden; a negative count shows nothing but
    /// still says how much the first click reveals.
    @Test func pageBoundsClampToTheCourse() {
        let course = course(files: files(450))
        let first = ActivityRowLayout.page(for: course, visible: 200)
        #expect(first.rows.count == 200)
        #expect(first.hiddenCount == 250)
        #expect(first.nextIncrement == 200)
        #expect(first.rows.last.map(itemID) == "f199")

        let beyond = ActivityRowLayout.page(for: course, visible: 10_000)
        #expect(beyond.rows.count == 450)
        #expect(beyond.isComplete)
        #expect(beyond.nextIncrement == 0)
        #expect(beyond.rows.last.map(itemID) == "f449")

        let negative = ActivityRowLayout.page(for: course, visible: -1)
        #expect(negative.rows.isEmpty)
        #expect(negative.hiddenCount == 450)
        #expect(negative.nextIncrement == 200)
    }

    /// An exact multiple of the page size ends with no hidden rows and no further step, rather
    /// than an empty last page behind a "Mostra altri" that reveals nothing.
    @Test func anExactMultipleOfThePageSizeNeedsNoEmptyLastPage() {
        let course = course(files: files(400))
        let page = ActivityRowLayout.page(for: course, visible: 400)
        #expect(page.isComplete)
        #expect(page.nextIncrement == 0)
        #expect(ActivityRowLayout.showMoreTitle(for: page) == nil)
        #expect(ActivityRowLayout.hiddenCaption(for: page) == nil)
        #expect(ActivityRowLayout.nextVisibleCount(after: 400, total: 400) == 400)
    }

    /// "Mostra altri" steps grow with what is shown (200, 400, 800…) and stop at the total, so a
    /// course of 15.000 rows is fully reachable in a few clicks and the last click lands exactly
    /// on the last row; a step never exceeds the hidden rows.
    @Test func showMoreStepsDoubleAndLandExactlyOnTheLastRow() {
        let total = 15_000
        var visible = ActivityRowLayout.pageSize
        var steps: [Int] = [visible]
        while visible < total {
            let next = ActivityRowLayout.nextVisibleCount(after: visible, total: total)
            #expect(next > visible)
            #expect(next <= total)
            visible = next
            steps.append(visible)
        }
        #expect(steps == [200, 400, 800, 1_600, 3_200, 6_400, 12_800, 15_000])
        #expect(ActivityRowLayout.nextVisibleCount(after: 0, total: 50) == 50)
        #expect(ActivityRowLayout.nextVisibleCount(after: -5, total: 50) == 50)
        #expect(ActivityRowLayout.nextVisibleCount(after: 60, total: 50) == 50)
    }

    // MARK: Empty and single-row cases

    /// A course without rows (only counters, as a legacy summary can carry) is complete at once
    /// and offers nothing to reveal; a course whose only row is its failure shows that row.
    @Test func emptyAndSingleRowCourses() {
        let empty = ActivityRowLayout.page(for: course(), visible: ActivityRowLayout.pageSize)
        #expect(empty.rows.isEmpty)
        #expect(empty.isComplete)
        #expect(empty.nextIncrement == 0)
        #expect(ActivityRowLayout.rowCount(for: course()) == 0)

        let onlyFailure = ActivityRowLayout.page(for: course(failure: "Non leggibile"), visible: ActivityRowLayout.pageSize)
        #expect(onlyFailure.rows.map(\.content) == [.courseFailure("Non leggibile")])
        #expect(onlyFailure.isComplete)

        let single = ActivityRowLayout.page(for: course(moved: [MovedSyncItem(id: "m", name: "m.pdf", folder: "", outcome: .moved)]), visible: 1)
        #expect(single.rows.count == 1)
        #expect(single.isComplete)
    }

    // MARK: Wording

    /// The control says how many rows it reveals; when the next step reaches the end it says so
    /// ("gli ultimi N", or "l’ultimo elemento" for one), and the caption counts what is hidden
    /// with the right singular. Nothing is offered once everything is shown.
    @Test func showMoreWordingFollowsTheRemainingRows() {
        let page = ActivityRowLayout.page(for: course(files: files(1_000)), visible: 200)
        #expect(ActivityRowLayout.showMoreTitle(for: page) == "Mostra altri 200")
        #expect(ActivityRowLayout.hiddenCaption(for: page) == "800 elementi non mostrati")

        let lastStep = ActivityRowLayout.page(for: course(files: files(350)), visible: 200)
        #expect(lastStep.nextIncrement == 150)
        #expect(ActivityRowLayout.showMoreTitle(for: lastStep) == "Mostra gli ultimi 150")

        let lastOne = ActivityRowLayout.page(for: course(files: files(201)), visible: 200)
        #expect(ActivityRowLayout.showMoreTitle(for: lastOne) == "Mostra l’ultimo elemento")
        #expect(ActivityRowLayout.hiddenCaption(for: lastOne) == "1 elemento non mostrato")

        let complete = ActivityRowLayout.page(for: course(files: files(3)), visible: 3)
        #expect(ActivityRowLayout.showMoreTitle(for: complete) == nil)
        #expect(ActivityRowLayout.hiddenCaption(for: complete) == nil)
    }

    // MARK: Reset

    /// Revealed rows survive only while the same summary stays expanded. A collapse, or a new
    /// sync summary under the same course id (SwiftUI keeps the card's state for both), goes back
    /// to one page; keeping 15000 revealed rows would rebuild them all on the next expansion.
    @Test func revealedRowsResetOnCollapseAndOnANewSummary() {
        #expect(ActivityRowLayout.visibleCount(keeping: 15_000, isExpanded: true, sameSummary: true) == 15_000)
        #expect(ActivityRowLayout.visibleCount(keeping: 15_000, isExpanded: false, sameSummary: true) == ActivityRowLayout.pageSize)
        #expect(ActivityRowLayout.visibleCount(keeping: 15_000, isExpanded: true, sameSummary: false) == ActivityRowLayout.pageSize)
        #expect(ActivityRowLayout.visibleCount(keeping: 15_000, isExpanded: false, sameSummary: false) == ActivityRowLayout.pageSize)
        #expect(ActivityRowLayout.visibleCount(keeping: 800, isExpanded: false, sameSummary: true, pageSize: 3) == 3)
    }
}
