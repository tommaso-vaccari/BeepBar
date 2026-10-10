import Foundation

/// One row of an expanded course in Attività (#99). The app draws it; this type only decides
/// what the row is and which id identifies it, so the decision can be tested without SwiftUI.
public struct ActivityRow: Equatable, Sendable, Identifiable {
    public enum Content: Equatable, Sendable {
        /// The course's contents could not be read at all; shown first, before any file.
        case courseFailure(String)
        /// A file that arrived or was replaced (`SyncedItem.kind` says which).
        case file(SyncedItem)
        /// A file whose place on Moodle changed: moved to follow it, or left where the user edited it.
        case moved(MovedSyncItem)
        /// A file that could not be updated; there is nothing to open.
        case failed(FailedSyncItem)
    }

    /// Unique across every course and every kind of row of a summary, and the same on every
    /// refresh of the same summary (see `ActivityRowLayout.page`).
    public let id: String
    public let content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }
}

/// The rows of an expanded course that are shown right now, plus what is still hidden.
public struct ActivityRowPage: Equatable, Sendable {
    /// The first `rows.count` rows of the course, in display order.
    public let rows: [ActivityRow]
    /// Rows after the last shown one. Zero when the last element is on screen.
    public let hiddenCount: Int
    /// How many more rows "Mostra altri" reveals next: at least a page, then as many as are
    /// already shown, never more than are hidden (see `ActivityRowLayout.nextVisibleCount`).
    public let nextIncrement: Int

    public var isComplete: Bool { hiddenCount == 0 }

    public init(rows: [ActivityRow], hiddenCount: Int, nextIncrement: Int) {
        self.rows = rows
        self.hiddenCount = hiddenCount
        self.nextIncrement = nextIncrement
    }
}

/// Bounded pagination of an expanded course in Attività (#99).
///
/// The page's outer `LazyVStack` makes courses lazy, not the rows inside one: an expanded course
/// used to build every file, moved and failed row at once, so a course with thousands of items
/// cost thousands of views on expansion and on every redraw of the page. Here an expanded course
/// shows a prefix of its rows and a "Mostra altri" control; the row list is never materialized
/// beyond that prefix, so the cost of expanding is bounded by `pageSize` and grows only when the
/// user asks for more.
///
/// Rows are a prefix, never a window: the shown set only ever grows from the top, so every row
/// keeps its position and id while more are revealed, and ids derived from the prefix (the
/// duplicate suffixes below) are stable whatever the visible count. All of it is pure and
/// `nonisolated` so Swift Testing covers ordering, ids and bounds on any platform.
public enum ActivityRowLayout {
    /// Rows shown when a course is first expanded, and the smallest step "Mostra altri" takes.
    /// Two hundred rows are far more than fit in the window and cost well under a frame to build.
    public static let pageSize = 200

    /// Everything the course would show, in display order: the course failure, then new and
    /// updated files, then moved files, then failed ones, each group in Core's order (by name).
    public nonisolated static func rowCount(for course: CourseSyncCount) -> Int {
        (course.courseFailure == nil ? 0 : 1) + course.items.count + course.movedItems.count + course.failedItems.count
    }

    /// The first `visible` rows of the course, with what remains hidden. Only those rows are
    /// built: the four source lists are walked just as far as needed, so the cost is proportional
    /// to what is shown, not to the course. `visible` beyond the course clamps to all of it.
    ///
    /// Ids are `"<courseID>/<kind>/<item id>"`: the course keeps two courses' rows apart, the
    /// kind keeps the same remote id apart when a file is both updated and moved in one sync, and
    /// the item id is the remote id Core already uses. Should the same id still repeat inside one
    /// kind (a file reported twice in one run), the repeat gets a `#2`, `#3`… suffix so SwiftUI
    /// never sees two rows with one id; counting repeats over the prefix keeps the suffix the same
    /// whatever the visible count.
    public nonisolated static func page(for course: CourseSyncCount, visible: Int, pageSize: Int = pageSize) -> ActivityRowPage {
        let total = rowCount(for: course)
        let shown = min(max(visible, 0), total)
        var rows: [ActivityRow] = []
        rows.reserveCapacity(shown)
        var seen: [String: Int] = [:]

        func append(_ kind: String, _ itemID: String, _ content: ActivityRow.Content) {
            var id = "\(course.courseID)/\(kind)/\(itemID)"
            let repeats = (seen[id] ?? 0) + 1
            seen[id] = repeats
            if repeats > 1 { id += "#\(repeats)" }
            rows.append(ActivityRow(id: id, content: content))
        }

        // `prefix` stops each walk at the rows still missing, so the hidden tail of a large group
        // is never visited, not just skipped.
        if let failure = course.courseFailure, rows.count < shown {
            append("failure", "", .courseFailure(failure))
        }
        for item in course.items.prefix(shown - rows.count) {
            append("file", item.id, .file(item))
        }
        for item in course.movedItems.prefix(shown - rows.count) {
            append("moved", item.id, .moved(item))
        }
        for item in course.failedItems.prefix(shown - rows.count) {
            append("failed", item.id, .failed(item))
        }

        let hidden = total - shown
        return ActivityRowPage(rows: rows, hiddenCount: hidden, nextIncrement: nextVisibleCount(after: shown, total: total, pageSize: pageSize) - shown)
    }

    /// How many rows a card shows after it was collapsed or its summary changed. Revealed rows
    /// are kept only while the same summary stays expanded: a card collapsed after revealing
    /// 15000 rows, or a new sync summary arriving for the same course id (SwiftUI keeps the
    /// card's state across both), goes back to one page. Without this a re-expansion would build
    /// every previously revealed row at once, the unbounded cost #99 removes.
    public nonisolated static func visibleCount(keeping current: Int, isExpanded: Bool, sameSummary: Bool, pageSize: Int = pageSize) -> Int {
        isExpanded && sameSummary ? current : pageSize
    }

    /// How many rows are shown after one "Mostra altri" when `visible` are shown now. The step is
    /// at least a page and at least what is already shown, so a course of 15000 items is fully
    /// reachable in a handful of clicks (200, 400, 800…) while each step still costs only about as
    /// much as what is already on screen; it never passes `total`.
    public nonisolated static func nextVisibleCount(after visible: Int, total: Int, pageSize: Int = pageSize) -> Int {
        let shown = min(max(visible, 0), total)
        let step = max(pageSize, shown)
        return min(total, shown + step)
    }

    /// The "Mostra altri" button's title for `page`, or `nil` when every row is already shown.
    /// Wording through `tr` at display time so it follows a language switch.
    public nonisolated static func showMoreTitle(for page: ActivityRowPage) -> String? {
        guard !page.isComplete else { return nil }
        if page.nextIncrement >= page.hiddenCount {
            return page.hiddenCount == 1
                ? tr("Mostra l’ultimo elemento", "Show the last item")
                : tr("Mostra gli ultimi \(page.hiddenCount)", "Show the last \(page.hiddenCount)")
        }
        return tr("Mostra altri \(page.nextIncrement)", "Show \(page.nextIncrement) more")
    }

    /// What the button leaves out, for the caption beside it ("1800 elementi non mostrati"), or
    /// `nil` when nothing is hidden.
    public nonisolated static func hiddenCaption(for page: ActivityRowPage) -> String? {
        guard !page.isComplete else { return nil }
        return page.hiddenCount == 1
            ? tr("1 elemento non mostrato", "1 item not shown")
            : tr("\(page.hiddenCount) elementi non mostrati", "\(page.hiddenCount) items not shown")
    }
}
