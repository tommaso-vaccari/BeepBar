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

    /// A sheet cannot save into a different account or a course removed while it was open.
    @Test func manualSheetRejectsStaleOwnerAndRemovedCourse() {
        func allowed(_ owner: Int?, _ current: Int?, _ course: Int64?, _ ids: Set<Int64>) -> Bool {
            RecordingsPresentation.canSubmitManualLesson(owner: owner, currentOwner: current, courseID: course, availableIDs: ids)
        }
        #expect(allowed(42, 42, 7, [7, 8]))
        #expect(allowed(42, 42, nil, []))
        #expect(!allowed(nil, nil, nil, []))
        #expect(!allowed(42, 43, 7, [7]))
        #expect(!allowed(42, nil, 7, [7]))
        #expect(!allowed(42, 42, 7, [8]))
    }

    /// The bulk command names the whole course: linked lessons are part of the list, so there is
    /// no "archive" wording any more (#289).
    @Test func bulkLabelsNameTheWholeCourse() {
        let pending = RecordingsPresentation.BulkAction(allDone: false, enabled: true)
        let done = RecordingsPresentation.BulkAction(allDone: true, enabled: true)
        #expect(pending.label.english == "Mark all as completed")
        #expect(done.label.english == "Mark all as unseen")
    }

    /// The sidebar counts a course's linked lessons with its archive (#289): in the recording
    /// count, also before the archive's listing is known, and in "to watch", which is the
    /// archive's saved summary plus the linked lessons not done. Without linked lessons nothing
    /// changes. Guards against a course reading "No recordings" over visible lessons.
    @Test func sidebarCountsIncludeLinkedLessons() {
        func counts(done: Int, total: Int, minutes: Int = 0) -> CourseWatchSummary {
            CourseWatchSummary(done: done, total: total, remainingMinutes: minutes, unknownDurationCount: 0)
        }
        let archive = counts(done: 7, total: 10)
        let linked = counts(done: 1, total: 3)
        let listing = RecordingsListing(recordings: [recording("a", "2026-10-01T10:00:00Z")])
        #expect(RecordingsPresentation.courseSubtitle(for: listing, summary: nil, linked: linked) == "4 registrazioni · 2 da guardare")
        #expect(RecordingsPresentation.courseSubtitle(for: RecordingsListing(recordings: []), summary: nil, linked: linked) == "3 registrazioni · 2 da guardare")
        #expect(RecordingsPresentation.courseSubtitle(for: nil, summary: nil, linked: linked) == "3 registrazioni · 2 da guardare")
        #expect(RecordingsPresentation.lecturesToWatchText(summary: archive, linked: linked) == BilingualText("5 da guardare", "5 to watch"))
        #expect(RecordingsPresentation.lecturesToWatchText(summary: counts(done: 10, total: 10), linked: counts(done: 3, total: 3)) == nil)
        #expect(RecordingsPresentation.lecturesToWatchText(summary: archive, linked: nil) == BilingualText("3 da guardare", "3 to watch"))
        #expect(RecordingsPresentation.courseSubtitle(for: listing) == "1 registrazione")
        // While the archive loads or fails, its state is said beside the lessons, not over them.
        var loading = RecordingsListing(); loading.isLoading = true
        var failed = RecordingsListing(); failed.problem = .unavailable
        #expect(RecordingsPresentation.courseSubtitle(for: loading, summary: nil, linked: linked) == "3 registrazioni · Caricamento… · 2 da guardare")
        #expect(RecordingsPresentation.courseSubtitle(for: failed, summary: nil, linked: linked) == "3 registrazioni · Non disponibile · 2 da guardare")
        #expect(RecordingsPresentation.courseSubtitle(for: loading) == "Caricamento…")
        #expect(RecordingsPresentation.courseSubtitle(for: failed) == "Non disponibile")
    }


    /// Courses with the same cleaned title remain distinguishable by year or by their stable ID.
    @Test func manualPickerDistinguishesSameCourseNames() {
        let first = course(1, "058167 - Algebra [2025-26]")
        let second = course(2, "058167 - Algebra [2026-27]")
        let duplicate = course(3, "058167 - Algebra [2026-27]")
        let labels = RecordingsPresentation.manualCourseLabels([first, second, duplicate])
        #expect(labels[1]?.contains("2025-26") == true)
        #expect(labels[2]?.contains("2026-27") == true)
        #expect(labels[2] != labels[3])
    }

    /// Duplicate IDs in a readable cached snapshot must produce one stable option, without a trap.
    @Test func manualPickerDeduplicatesCachedCourseIDs() {
        let first = course(7, "First")
        let identical = course(7, "First")
        let changed = course(7, "Different")
        let other = course(8, "First")
        let input = [first, identical, changed, other]
        #expect(RecordingsPresentation.manualPickerCourses(input) == [first, other])
        let labels = RecordingsPresentation.manualCourseLabels(input)
        #expect(labels.count == 2)
        #expect(labels[7] == "First (ID 7)")
        #expect(labels[8] == "First (ID 8)")
    }

    /// Italian counts agree in number with their noun, like English ones (#195): a course with
    /// one recording reads "1 registrazione" (sidebar subtitle and course header) and one new
    /// lecture is announced as "1 nuova", never "1 registrazioni" / "1 nuove". Checked through
    /// `BilingualText` for both languages; the subtitle in the tests' Italian default proves the
    /// sidebar uses the helper. Mutation: always pass the plural to `italianCount`, or put the
    /// old `tr("\(count) registrazioni", …)` back in `courseSubtitle`, and the 1 cases fail.
    @Test func countsUseTheItalianSingularForOne() {
        #expect(italianCount(0, "registrazione", "registrazioni") == "0 registrazioni")
        #expect(italianCount(1, "registrazione", "registrazioni") == "1 registrazione")
        #expect(italianCount(2, "registrazione", "registrazioni") == "2 registrazioni")

        #expect(RecordingsPresentation.recordingCount(0) == BilingualText("0 registrazioni", "0 recordings"))
        #expect(RecordingsPresentation.recordingCount(1) == BilingualText("1 registrazione", "1 recording"))
        #expect(RecordingsPresentation.recordingCount(2) == BilingualText("2 registrazioni", "2 recordings"))

        #expect(RecordingsPresentation.newCountLabel(0) == BilingualText("0 nuove", "0 new"))
        #expect(RecordingsPresentation.newCountLabel(1) == BilingualText("1 nuova", "1 new"))
        #expect(RecordingsPresentation.newCountLabel(2) == BilingualText("2 nuove", "2 new"))

        let one = recording("a", "2026-10-01T10:00:00Z")
        #expect(RecordingsPresentation.courseSubtitle(for: RecordingsListing(recordings: [one])) == "1 registrazione")
        #expect(RecordingsPresentation.courseSubtitle(for: RecordingsListing(recordings: [one, recording("b", "2026-10-02T10:00:00Z")])) == "2 registrazioni")
        #expect(RecordingsPresentation.courseSubtitle(for: RecordingsListing(recordings: [])) == "Nessuna registrazione")
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

    /// Group by course identity, preserving the ordering, hidden linked lessons and search results.
    @Test func watchlistSectionsKeepCourseProvenance() throws {
        let courseA = course(1, "058167 - NUMERICAL LINEAR ALGEBRA [2026-27]")
        var manual = ManualWebexLessons()
        let linked = try manual.add(link: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/abc", title: "Linked", courseName: "NLA", courseID: 1)
        let hidden = try manual.add(link: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/def", title: "Hidden", courseName: "NLA", courseID: 2)
        let free = try manual.add(link: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/ghi", title: "Free", courseName: "", courseID: nil)
        var study = RecordingsStudyState()
        let archive = recording("archive", "2026-10-05T10:00:00Z")
        let other = RecmanRecording(id: "other", courseCode: "123456", academicYear: 2026, title: "Other", recordedAt: archive.recordedAt, kind: "", duration: "", size: nil, previewURL: archive.previewURL)
        study.bookmarks = [.init(recording: archive, courseName: "NLA"), .init(recording: other, courseName: "NLA")]
        let entries = study.watchlistEntries(manual: manual, visibleCourseIDs: [1], fallbackCourseName: "Webex", query: "")
        let sections = RecordingsStudyState.watchlistSections(entries, manual: manual, courses: [courseA], fallback: "Unassigned")
        let archiveSection = try #require(sections.first { $0.id == .archive("058167", 2026) })
        #expect(Set(archiveSection.bookmarks.map(\.recording.id)) == [archive.id, linked.id])
        #expect(archiveSection.bookmarks.map(\.id) == entries.filter { [archive.id, linked.id].contains($0.recording.id) }.map(\.id))
        #expect(sections.first { $0.id == .course(2) }?.bookmarks.map(\.recording.id) == [hidden.id])
        #expect(sections.first { $0.id == .unassigned }?.bookmarks.map(\.recording.id) == [free.id])
        #expect(sections.first { $0.id == .archive("123456", 2026) }?.bookmarks.map(\.recording.id) == [other.id])
        let parallelCourse = course(3, "058167 - OTHER SECTION [2026-27]")
        let ambiguous = RecordingsStudyState.watchlistSections(entries, manual: manual, courses: [courseA, parallelCourse], fallback: "Unassigned")
        #expect(ambiguous.first { $0.id == .course(1) }?.bookmarks.map(\.recording.id) == [linked.id])
        #expect(ambiguous.first { $0.id == .archive("058167", 2026) }?.bookmarks.map(\.recording.id) == [archive.id])
        let found = study.watchlistEntries(manual: manual, visibleCourseIDs: [1], fallbackCourseName: "Webex", query: "Linked")
        #expect(RecordingsStudyState.watchlistSections(found, manual: manual, courses: [courseA], fallback: "Unassigned").flatMap(\.bookmarks).map(\.recording.id) == [linked.id])
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

    /// Guards #238: the sidebar hides the new-lectures badge of the course whose list is open
    /// (its dots stay in the list until the student leaves it) and of no other course; with the
    /// Watchlist open every badge shows. Mutation: return `count` always and the open case fails.
    @Test func sidebarHidesTheBadgeOfTheOpenCourseOnly() throws {
        let open = try #require(RecmanCourseKey(courseCode: "058167", academicYear: 2026))
        let other = try #require(RecmanCourseKey(courseCode: "052499", academicYear: 2026))
        let sameCodeOtherYear = try #require(RecmanCourseKey(courseCode: "058167", academicYear: 2025))
        #expect(RecordingsPresentation.sidebarNewCount(3, rowKey: open, openKey: open) == 0)
        #expect(RecordingsPresentation.sidebarNewCount(3, rowKey: other, openKey: open) == 3)
        #expect(RecordingsPresentation.sidebarNewCount(3, rowKey: sameCodeOtherYear, openKey: open) == 3)
        #expect(RecordingsPresentation.sidebarNewCount(3, rowKey: open, openKey: nil) == 3)
        #expect(RecordingsPresentation.sidebarNewCount(0, rowKey: other, openKey: open) == 0)
    }

    /// Guards the #238 review's P0 from the page side: with no Polimi session and an empty
    /// Watchlist the page is the full sign-in screen, so no course pane (and no open course) is
    /// on screen; a saved Watchlist keeps the panes. Mutation: return true for `.needsSignIn`
    /// and the hidden course would be "left", acknowledging recordings nobody saw.
    @Test func thePanesShowOnlyWithASessionOrASavedWatchlist() {
        typealias P = RecordingsPresentation
        #expect(P.showsBrowser(access: .ready, hasBookmarks: false))
        #expect(P.showsBrowser(access: .ready, hasBookmarks: true))
        #expect(!P.showsBrowser(access: .needsSignIn(nil), hasBookmarks: false))
        #expect(!P.showsBrowser(access: .signingIn, hasBookmarks: false))
        #expect(P.showsBrowser(access: .needsSignIn(.unavailable), hasBookmarks: true))
        #expect(P.showsBrowser(access: .signingIn, hasBookmarks: true))
        #expect(!P.showsBrowser(access: .off, hasBookmarks: true))
    }

    /// Guards #237: no combination leaves the course pane empty. Without a Polimi session and
    /// without a list in memory it invites the sign-in (the case that drew nothing and let the
    /// header float); a list in memory is shown in every access state; signed in, a failure with
    /// nothing to show says so and a request about to start shows the spinner. Mutation: map
    /// `.needsSignIn` to `.loading`, or check access before the list, and these fail.
    @Test func courseContentNeverLeavesThePaneEmpty() {
        typealias P = RecordingsPresentation
        for access in [RecordingsAccess.off, .ready, .signingIn, .needsSignIn(nil), .needsSignIn(.unavailable)] {
            #expect(P.courseContent(hasList: true, isLoading: false, hasProblem: true, access: access) == .list)
            #expect(P.courseContent(hasList: false, isLoading: true, hasProblem: false, access: access) == .loading)
        }
        #expect(P.courseContent(hasList: false, isLoading: false, hasProblem: false, access: .needsSignIn(nil)) == .signIn)
        #expect(P.courseContent(hasList: false, isLoading: false, hasProblem: true, access: .needsSignIn(.unavailable)) == .signIn)
        #expect(P.courseContent(hasList: false, isLoading: false, hasProblem: false, access: .off) == .signIn)
        #expect(P.courseContent(hasList: false, isLoading: false, hasProblem: false, access: .signingIn) == .signingIn)
        #expect(P.courseContent(hasList: false, isLoading: false, hasProblem: true, access: .ready) == .unavailable)
        #expect(P.courseContent(hasList: false, isLoading: false, hasProblem: false, access: .ready) == .loading)
    }

    private var manualLesson: RecmanRecording {
        ManualWebexLesson(title: "Guest", courseName: "", link: URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=t")!, addedAt: .now).recording
    }

    /// Both the "⋯" menu and the right-click menu come from `menuEntries` (#286): a linked lesson
    /// offers the two link items and "Delete lesson…" (destructive), never a watchlist toggle; an
    /// archive lesson offers the toggle and never a delete. Mutation: offer the toggle for manual
    /// lessons, or delete for archive ones, and this fails.
    @Test func menuEntriesSeparateDeletingFromTheWatchlist() {
        let P = RecordingsPresentation.self
        let manual = P.menuEntries(for: manualLesson, isWatchlisted: true, canEdit: true, canUseLinks: true)
        #expect(manual.map(\.item) == [.openInBrowser, .copyLink, .deleteLesson])
        #expect(manual.last?.isDestructive == true)
        #expect(manual.last?.title == BilingualText("Elimina lezione…", "Delete lesson…"))
        let added = P.menuEntries(for: recording("a", "2026-10-01T10:00:00Z"), isWatchlisted: false, canEdit: true, canUseLinks: true)
        #expect(added.map(\.item) == [.openInBrowser, .copyLink, .addToWatchlist])
        let removed = P.menuEntries(for: recording("a", "2026-10-01T10:00:00Z"), isWatchlisted: true, canEdit: true, canUseLinks: true)
        #expect(removed.map(\.item) == [.openInBrowser, .copyLink, .removeFromWatchlist])
        #expect(!removed.contains { $0.isDestructive })
    }

    /// Link items need a ready session, the watchlist and delete items an editable account, each
    /// independently. Mutation: tie both to one flag and this fails.
    @Test func menuEntriesEnableEachItemOnItsOwnCondition() {
        let P = RecordingsPresentation.self
        for recording in [manualLesson, recording("a", "2026-10-01T10:00:00Z")] {
            let noLinks = P.menuEntries(for: recording, isWatchlisted: false, canEdit: true, canUseLinks: false)
            #expect(noLinks.map(\.enabled) == [false, false, true])
            let noEdit = P.menuEntries(for: recording, isWatchlisted: false, canEdit: false, canUseLinks: true)
            #expect(noEdit.map(\.enabled) == [true, true, false])
        }
    }

    /// Linked lessons join the archive's week sections by their date (#289): one played and dated
    /// by Webex lands in its own week, one not yet played under the week it was added; the search
    /// filters both; and the archive's numbering is unchanged, with no number for a linked lesson.
    /// Guards against an old recording sorting under "This week" and against numbers shifting.
    @Test func linkedLessonsJoinTheWeekSectionsByDateWithoutNumbers() throws {
        let archive = [recording("a", "2026-10-01T10:00:00Z", title: "Fourier"), recording("b", "2026-10-02T10:00:00Z", title: "Laplace")]
        let link = { (id: String) in URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=\(id)")! }
        let formatter = ISO8601DateFormatter()
        var dated = ManualWebexLesson(id: "manual-d", title: "lab1", courseName: "", link: link("d"), addedAt: formatter.date(from: "2026-10-06T09:00:00Z")!)
        _ = dated.learn(title: nil, duration: nil, recordedAt: formatter.date(from: "2026-10-01T15:00:00Z")!)
        let undated = ManualWebexLesson(id: "manual-u", title: "lab2", courseName: "", link: link("u"), addedAt: formatter.date(from: "2026-10-06T09:00:00Z")!)
        let list = archive + [dated.recording, undated.recording]
        let derived = RecmanCourseListDerivation(.init(recordings: list, query: "", language: .english, timeZone: TimeZone(identifier: "UTC")!, now: formatter.date(from: "2026-10-06T10:00:00Z")!))
        #expect(derived.sections.map { $0.recordings.map(\.id) } == [["manual-u"], ["b", "manual-d", "a"]])
        #expect(RecmanCourseListDerivation(.init(recordings: list, query: "lab1", language: .english, timeZone: TimeZone(identifier: "UTC")!, now: .now)).shown.map(\.id) == ["manual-d"])
        let numbers = RecordingsPresentation.numbers(archive)
        #expect(numbers == ["a": 1, "b": 2] && numbers["manual-d"] == nil)
    }

    /// The course pane is one list (#289): linked lessons are rows of the week sections with the
    /// archive's. When the archive has no rows, the lessons stay and what the archive is doing
    /// becomes a compact note; an empty archive or an archive search with no match needs no note
    /// once the lessons are listed. Without linked lessons nothing changes.
    @Test func coursePlanListsLinkedLessonsWithTheArchive() {
        let P = RecordingsPresentation.self
        typealias Plan = RecordingsPresentation.CoursePlan
        // No linked lessons: the archive's own state fills the pane, exactly as before.
        for part: RecordingsPresentation.ArchivePart in [.emptyArchive, .noSearchResults, .noKey, .loading, .signIn, .signingIn, .unavailable] {
            #expect(P.coursePlan(hasManual: false, manualShownCount: 0, archive: part) == Plan(showsRows: false, inlineNote: nil, fullState: part))
        }
        #expect(P.coursePlan(hasManual: false, manualShownCount: 0, archive: .rows) == Plan(showsRows: true, inlineNote: nil, fullState: nil))
        // Linked lessons and an archive with rows: one list.
        #expect(P.coursePlan(hasManual: true, manualShownCount: 2, archive: .rows) == Plan(showsRows: true, inlineNote: nil, fullState: nil))
        // Linked lessons and an archive with nothing to list: the lessons stay; the note says only
        // what the student can wait for or act on (sign in, key, loading, unavailable).
        for part: RecordingsPresentation.ArchivePart in [.noKey, .loading, .signIn, .signingIn, .unavailable] {
            #expect(P.coursePlan(hasManual: true, manualShownCount: 1, archive: part) == Plan(showsRows: true, inlineNote: part, fullState: nil))
        }
        for part: RecordingsPresentation.ArchivePart in [.emptyArchive, .noSearchResults] {
            #expect(P.coursePlan(hasManual: true, manualShownCount: 1, archive: part) == Plan(showsRows: true, inlineNote: nil, fullState: nil))
        }
        // A search that leaves only the archive's rows.
        #expect(P.coursePlan(hasManual: true, manualShownCount: 0, archive: .rows) == Plan(showsRows: true, inlineNote: nil, fullState: nil))
        // A search that leaves nothing in the list while the archive shows only a note says so.
        #expect(P.coursePlan(hasManual: true, manualShownCount: 0, isSearching: true, archive: .loading)
                == Plan(showsRows: false, inlineNote: .loading, noMatches: true, fullState: nil))
        #expect(P.coursePlan(hasManual: true, manualShownCount: 0, isSearching: true, archive: .emptyArchive)
                == Plan(showsRows: false, inlineNote: nil, noMatches: true, fullState: nil))
        #expect(P.coursePlan(hasManual: true, manualShownCount: 0, isSearching: true, archive: .rows).noMatches == false)
        // Nothing matches anywhere: the usual search state.
        #expect(P.coursePlan(hasManual: true, manualShownCount: 0, archive: .noSearchResults) == Plan(showsRows: false, inlineNote: nil, fullState: .noSearchResults))
    }

    @Test func archivePartFollowsTheListingState() {
        let P = RecordingsPresentation.self
        #expect(P.archivePart(hasKey: false, content: .list, archiveCount: 3, archiveShownCount: 3) == .noKey)
        #expect(P.archivePart(hasKey: true, content: .list, archiveCount: 0, archiveShownCount: 0) == .emptyArchive)
        #expect(P.archivePart(hasKey: true, content: .list, archiveCount: 3, archiveShownCount: 0) == .noSearchResults)
        #expect(P.archivePart(hasKey: true, content: .list, archiveCount: 3, archiveShownCount: 2) == .rows)
        #expect(P.archivePart(hasKey: true, content: .signIn, archiveCount: 0, archiveShownCount: 0) == .signIn)
        #expect(P.archivePart(hasKey: true, content: .loading, archiveCount: 0, archiveShownCount: 0) == .loading)
        #expect(P.archivePart(hasKey: true, content: .unavailable, archiveCount: 0, archiveShownCount: 0) == .unavailable)
    }
}


/// Hosts a Recordings page, so it lives in the serialized probe scope (see `ProbeHostedUI`).
extension ProbeHostedUI {
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
        /// The Watchlist's list, right of the sidebar (also a list); gone once the last
        /// bookmark is removed and the empty state replaces it.
        func detailTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.convert(table.bounds, to: nil).minX > 200 { return table }
            return view.subviews.lazy.compactMap { detailTable(in: $0) }.first
        }
        /// Lays out until `condition` holds, at most 10 s: polling on an observable fact instead
        /// of a fixed sleep a loaded runner can outlast (#223).
        func settle(until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            host.layoutSubtreeIfNeeded()
        }
        try await settle { searchField(in: host) != nil && detailTable(in: host) != nil }
        let field = try #require(searchField(in: host))
        let initial = field.convert(field.bounds, to: host).minY
        controller.toggleWatchlist(lesson, courseName: "NLA")
        try await settle { detailTable(in: host) == nil }
        #expect(detailTable(in: host) == nil, "the empty Watchlist never replaced the list")
        let empty = try #require(searchField(in: host))
        #expect(abs(empty.convert(empty.bounds, to: host).minY - initial) < 1)
    }
}
