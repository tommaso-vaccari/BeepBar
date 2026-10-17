import Foundation
import AppKit
import SwiftUI
import Testing
import BeepbarCore
@testable import BeepbarApp

struct RecordingsPresentationTests {
    private func course(_ id: Int64, _ name: String) -> RemoteCourseSummary {
        RemoteCourseSummary(id: id, shortName: name, displayName: name, isVisible: true, startDate: nil, endDate: nil)
    }

    private func recording(_ id: String, _ date: String, title: String = "Lesson", kind: String = "Laboratorio") -> RecmanRecording {
        RecmanRecording(id: id, courseCode: "058167", academicYear: 2026, title: title,
                        recordedAt: ISO8601DateFormatter().date(from: date)!, kind: kind,
                        duration: "97 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/")!)
    }

    @Test func sidebarExcludesDisabledCoursesInBothSections() {
        let courses = [course(1, "058167 - Course [2026/27]"), course(2, "058168 - Course [2026/27]"), course(3, "No code"), course(4, "Another unknown")]
        let shown = RecordingsPresentation.syncedCourses(courses, enabledIDs: [1, 3])
        #expect(shown.map(\.id) == [1, 3])
        #expect(shown.filter { RecmanCourseKey(course: $0) != nil }.map(\.id) == [1])
        #expect(shown.filter { RecmanCourseKey(course: $0) == nil }.map(\.id) == [3])
        #expect(RecordingsPresentation.syncedCourses(courses, enabledIDs: []).isEmpty)
    }

    @Test func selectionFallsBackWhenEveryCourseLacksCodeOrYear() {
        let unknown = course(1, "No code")
        let searchable = course(2, "058167 - Course [2026/27]")
        #expect(RecordingsPresentation.selectedCourse([unknown], selectedID: nil)?.id == 1)
        #expect(RecordingsPresentation.selectedCourse([unknown, searchable], selectedID: nil)?.id == 2)
        #expect(RecordingsPresentation.selectedCourse([unknown, searchable], selectedID: 1)?.id == 1)
        #expect(RecordingsPresentation.selectedCourse([unknown], selectedID: 99)?.id == 1)
        #expect(RecordingsPresentation.selectedCourse([], selectedID: nil) == nil)
    }

    /// Course labels retain their human wording while archive metadata moves to the header summary.
    @Test func courseNamesRemoveOnlyRecognizedArchiveMetadata() {
        #expect(RecordingsPresentation.courseName(course(1, "058167 - NUMERICAL LINEAR ALGEBRA [2026-27]")) == "NUMERICAL LINEAR ALGEBRA")
        #expect(RecordingsPresentation.courseName(course(2, "058167 - HPC (2026-2027)")) == "HPC")
        #expect(RecordingsPresentation.courseName(course(3, "058167 - C++ (Prof. Rossi) [2026/27]")) == "C++ (Prof. Rossi)")
        #expect(RecordingsPresentation.courseName(course(4, "Seminar (Prof. Rossi)")) == "Seminar (Prof. Rossi)")
        #expect(RecordingsPresentation.courseName(course(5, "058167 - HPC [2026-28]")) == "058167 - HPC [2026-28]")
        let fallback = RemoteCourseSummary(id: 6, shortName: "058167 - HPC [2026-27]", displayName: "  ", isVisible: true, startDate: nil, endDate: nil)
        #expect(RecordingsPresentation.courseName(fallback) == "HPC")
        #expect(RecordingsPresentation.courseName(course(7, "058167 - [2026-27]")) == "058167 - [2026-27]")
    }

    @Test func durationFormatting() {
        #expect(RecordingsPresentation.minutes("97 min") == 97)
        #expect(RecordingsPresentation.minutes("") == nil)
        #expect(RecordingsPresentation.durationText(minutes: 45) == "45 min")
        #expect(RecordingsPresentation.durationText(minutes: 97) == "1 h 37 min")
        #expect(RecordingsPresentation.durationText(minutes: 2160) == "36 h")
    }

    @Test func searchAndTitleFallback() {
        let item = recording("a", "2026-10-06T10:00:00Z", title: "Éigen solvers")
        #expect(RecordingsPresentation.matches(item, query: "  eigen  "))
        #expect(RecordingsPresentation.matches(item, query: "laboratorio"))
        #expect(RecordingsPresentation.matches(item, query: " "))
        #expect(!RecordingsPresentation.matches(item, query: "unrelated"))
        #expect(RecordingsPresentation.title(item) == "Éigen solvers")
        #expect(RecordingsPresentation.title(recording("b", "2026-10-06T10:00:00Z", title: "")) == "Laboratorio")
    }

    @Test func numbersUseChronologyAndStableTieBreak() {
        let a = recording("a", "2026-10-05T10:00:00Z")
        let b = recording("b", "2026-10-05T10:00:00Z")
        let c = recording("c", "2026-10-06T10:00:00Z")
        #expect(RecordingsPresentation.numbers([c, b, a]) == ["a": 1, "b": 2, "c": 3])
    }

    @Test func weeksStartMondayAndSortNewestFirstAcrossDST() {
        let cal = RecordingsPresentation.calendar(timeZone: TimeZone(identifier: "Europe/Rome")!)
        let sunday = recording("sun", "2026-10-25T10:00:00Z")
        let monday = recording("mon", "2026-10-26T10:00:00Z")
        let earlier = recording("old", "2026-10-19T10:00:00Z")
        let sections = RecordingsPresentation.weekSections([earlier, monday, sunday], now: monday.recordedAt, calendar: cal, locale: Locale(identifier: "en_GB"))
        #expect(sections.map { $0.recordings.map(\.id) } == [["mon"], ["sun", "old"]])
        #expect(RecordingsPresentation.weekSections([], now: monday.recordedAt, calendar: cal, locale: .current).isEmpty)
    }

    @Test func olderWeekRangesIncludeYearAndCrossMonth() {
        let cal = RecordingsPresentation.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let now = recording("now", "2026-10-06T10:00:00Z").recordedAt
        let start = recording("old", "2025-12-29T10:00:00Z").recordedAt
        let text = RecordingsPresentation.weekRange(from: start, now: now, calendar: cal, locale: Locale(identifier: "en_GB"))
        #expect(text.contains("Dec"))
        #expect(text.contains("Jan"))
        let past = recording("past", "2025-09-15T10:00:00Z").recordedAt
        #expect(RecordingsPresentation.weekRange(from: past, now: now, calendar: cal, locale: Locale(identifier: "en_GB")).contains("2025"))
    }

    @Test @MainActor func debugBuildDoesNotStartSparkle() {
#if DEBUG
        #expect(!UpdaterController.startsAutomatically)
#endif
    }
    /// Global search finds courses and titles without removing bookmarks.
    @Test func globalWatchlistSearchFindsCoursesAndTitles() {
        let a = recording("a", "2026-10-05T10:00:00Z", title: "Eigenvalues")
        let b = recording("b", "2026-10-06T10:00:00Z", title: "GPU")
        var study = RecordingsStudyState()
        study.bookmarks = [.init(recording: a, courseName: "NLA"), .init(recording: b, courseName: "HPC")]
        #expect(study.visibleBookmarks(query: " nla ").map(\.recording.id) == ["a"])
        #expect(study.visibleBookmarks(query: "eigen").map(\.recording.id) == ["a"])
        #expect(study.visibleBookmarks(query: "").map(\.recording.id) == ["b", "a"])
        #expect(study.bookmarks.count == 2)
    }

    /// Bookmarks from the first demo survive removal of its completion flags and all become visible.
    @Test func earlierPreviewCompletionFlagsDoNotHideSavedBookmarks() throws {
        let lesson = recording("legacy", "2026-10-05T10:00:00Z")
        var state = RecordingsStudyState()
        state.bookmarks = [.init(recording: lesson, courseName: "NLA")]
        state.destination = .watchlist
        let data = try PropertyListEncoder().encode(state)
        var legacy = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        legacy["watched"] = [RecordingsStudyState.identity(lesson)]
        legacy["showWatchedInWatchlist"] = false
        legacy["hideWatchedInCourses"] = true
        let oldData = try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
        let restored = try PropertyListDecoder().decode(RecordingsStudyState.self, from: oldData)
        #expect(restored == state)
        #expect(restored.visibleBookmarks(query: "").map(\.recording.id) == ["legacy"])
    }

}


extension RecordingsPresentationTests {
    /// Removing the last bookmark must not move the search field or header down the page.
    @MainActor @Test func watchlistHeaderStaysAtTopWhenLastLessonIsRemoved() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watchlist-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "watchlist-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let authentication = WeBeepAuthenticationController(testRootURL: root, defaults: defaults)
        let controller = RecordingsController(makeBrowser: { WatchlistPreviewBrowser() },
            store: RecordingsSessionStore { root }, defaults: defaults, ownerUserID: { 42 }, isAvailable: { true })
        let key = try #require(RecmanCourseKey(courseCode: "058167", academicYear: 2026))
        let lesson = WatchlistPreviewBrowser.lessons(for: key)[0]
        controller.toggleWatchlist(lesson, courseName: "NLA")
        controller.selectDestination(.watchlist)
        controller.signIn()
        for _ in 0..<100 where controller.access != .ready { await Task.yield() }
        #expect(controller.access == .ready)
        let host = NSHostingView(rootView: RecordingsPage(authentication: authentication, recordings: controller))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.close(); controller.turnOff() }
        func searchField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let field = try #require(searchField(in: host))
        let initial = field.convert(field.bounds, to: host).minY
        controller.toggleWatchlist(lesson, courseName: "NLA")
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let empty = try #require(searchField(in: host))
        #expect(abs(empty.convert(empty.bounds, to: host).minY - initial) < 1)
    }
}
