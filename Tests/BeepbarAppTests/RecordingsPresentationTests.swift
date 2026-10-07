import Foundation
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
}
