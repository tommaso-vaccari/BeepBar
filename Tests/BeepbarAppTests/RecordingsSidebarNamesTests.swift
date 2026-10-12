import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The Recordings sidebar's renamed-folder titles and its orange "lectures to watch" marker.
struct RecordingsSidebarNamesTests {
    private static let raw = "058167 - GEOMETRIA ALGEBRA LINEARE (Claude Sonnet) [2026-27]"
    private static let cleaned = "GEOMETRIA ALGEBRA LINEARE (Claude Sonnet)"

    private func name(_ folder: String?, cleaned: String = cleaned, raw: String = raw, id: Int64 = 7) -> String {
        RecordingsPresentation.sidebarName(courseName: cleaned, courseDisplayName: raw, courseID: id, localFolderName: folder)
    }

    private func course(_ id: Int64, _ display: String) -> RemoteCourseSummary {
        RemoteCourseSummary(id: id, shortName: display, displayName: display, isVisible: true, startDate: nil, endDate: nil)
    }

    private func summary(done: Int, total: Int, next: RecmanRecording? = nil) -> CourseWatchSummary {
        CourseWatchSummary(done: done, total: total, remainingMinutes: 0, unknownDurationCount: 0, next: next)
    }

    // MARK: Folder names

    /// Guards the common case: a course whose folder was never renamed keeps its WeBeep name, in
    /// every form of the generated folder (slug, whole-name slug, ID-suffixed, other case).
    /// Without the "generated folder" check every row would show the slug "geometria-algebra-lineare".
    @Test func anUntouchedOrGeneratedFolderLeavesTheNameAlone() {
        #expect(name(nil) == Self.cleaned)
        #expect(name("geometria-algebra-lineare") == Self.cleaned)
        #expect(name("Geometria-Algebra-Lineare") == Self.cleaned)
        #expect(name("geometria-algebra-lineare-7") == Self.cleaned)
        #expect(name("058167-geometria-algebra-lineare-claude-sonnet-2026-27") == Self.cleaned)
    }

    /// The example of the feature: the folder replaces the base, the teacher stays.
    @Test func aRenamedFolderReplacesTheBaseAndKeepsTheTeacher() {
        #expect(name("GAL") == "GAL (Claude Sonnet)")
        #expect(name("  GAL \n") == "GAL (Claude Sonnet)")
    }

    /// Without a trailing group there is no teacher to keep: just the folder.
    @Test func aNameWithoutTeacherBecomesJustTheFolder() {
        #expect(name("GAL", cleaned: "GEOMETRIA", raw: "058167 - GEOMETRIA [2026-27]") == "GAL")
    }

    /// A missing, empty or blank folder must never blank the row.
    @Test func anEmptyFolderIsIgnored() {
        #expect(name("") == Self.cleaned)
        #expect(name("   \n\t") == Self.cleaned)
    }

    /// Only the trailing group is the teacher; earlier groups belong to the base that is replaced.
    @Test func onlyTheTrailingGroupIsKept() {
        let cleaned = "ANALISI (Mod. A) II (Rossi)"
        #expect(name("AN2", cleaned: cleaned, raw: "058168 - \(cleaned) [2026-27]") == "AN2 (Rossi)")
        // A name that is only a group has no base to separate it from: the group is not kept twice.
        #expect(name("X", cleaned: "(Rossi)", raw: "(Rossi)") == "X")
        // Nested parentheses are not a teacher.
        #expect(name("X", cleaned: "Foo (a (b))", raw: "Foo (a (b))") == "X")
    }

    /// Odd folders must not crash, duplicate the teacher or lose their characters.
    @Test func oddFoldersAreHandled() {
        #expect(name("Algebra (Claude Sonnet)") == "Algebra (Claude Sonnet)")
        #expect(name("algebra (claude sonnet)") == "algebra (claude sonnet)")
        #expect(name("Analisi 🧮 ✨") == "Analisi 🧮 ✨ (Claude Sonnet)")
        #expect(name("Fisica (") == "Fisica ( (Claude Sonnet)")
        #expect(name("Caf\u{65}\u{301}") == "Caf\u{65}\u{301} (Claude Sonnet)")
        #expect(name("GAL", cleaned: "", raw: "") == "GAL")
    }

    /// The sidebar derivation wires the names from the folders map: rows follow the map, titles
    /// used elsewhere (`name`) do not, and a course with no entry keeps its own.
    @Test func theSidebarFollowsTheFolderMap() {
        let courses = [course(1, Self.raw), course(2, "058168 - FISICA [2026-27]"), course(3, "Seminar (Rossi)")]
        let sidebar = RecmanCourseSidebar(.init(courses: courses, enabledIDs: [1, 2, 3], folders: [1: "GAL", 3: "Sem"]))
        #expect(sidebar.searchable.map(\.sidebarName) == ["GAL (Claude Sonnet)", "FISICA"])
        #expect(sidebar.searchable.map(\.name) == [Self.cleaned, "FISICA"])
        #expect(sidebar.unsearchable.map(\.sidebarName) == ["Sem (Rossi)"])
        #expect(sidebar.searchable.map(\.key) == RecmanCourseSidebar(.init(courses: courses, enabledIDs: [1, 2, 3])).searchable.map(\.key))
        // Changing the folder changes the cache key of the page's derivation.
        #expect(RecmanCourseSidebar.Inputs(courses: courses, enabledIDs: [1], folders: [1: "A"]) != .init(courses: courses, enabledIDs: [1], folders: [1: "B"]))
    }

    /// Searching finds the course under the original or the renamed name, and not under others.
    @Test func searchMatchesBothNames() {
        let renamed = name("GAL")
        #expect(RecmanCourseSidebar.matches(query: "gal", courseName: Self.cleaned, sidebarName: renamed))
        #expect(RecmanCourseSidebar.matches(query: "geometria", courseName: Self.cleaned, sidebarName: renamed))
        #expect(RecmanCourseSidebar.matches(query: "  sonnet ", courseName: Self.cleaned, sidebarName: renamed))
        #expect(RecmanCourseSidebar.matches(query: "", courseName: Self.cleaned, sidebarName: renamed))
        #expect(!RecmanCourseSidebar.matches(query: "fisica", courseName: Self.cleaned, sidebarName: renamed))
    }

    // MARK: Orange marker

    /// The marker shows only when something is left; unknown claims nothing, finished and empty
    /// courses show nothing. `next` is irrelevant (old data has counts without it).
    @Test func theMarkerShowsOnlyWhenKnownAndNotAllDone() {
        #expect(RecordingsPresentation.hasLecturesToWatch(summary: summary(done: 3, total: 10)))
        #expect(RecordingsPresentation.hasLecturesToWatch(summary: summary(done: 0, total: 1)))
        #expect(!RecordingsPresentation.hasLecturesToWatch(summary: summary(done: 10, total: 10)))
        #expect(!RecordingsPresentation.hasLecturesToWatch(summary: summary(done: 0, total: 0)))
        #expect(!RecordingsPresentation.hasLecturesToWatch(summary: nil))
    }

    /// VoiceOver reads the label and the number left in both languages.
    @Test func theMarkerSpeaksInBothLanguages() {
        #expect(RecordingsPresentation.lecturesToWatchLabel == BilingualText("Lezioni da guardare", "Lectures to watch"))
        let value = RecordingsPresentation.lecturesToWatchValue(summary(done: 7, total: 10))
        #expect(value.italian == "3 da guardare")
        #expect(value.english == "3 left")
    }
}
