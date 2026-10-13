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

    /// Regression for the name-edit scenario: BeepBar keeps a folder already in its naming scheme
    /// when WeBeep edits the course name, so a generated slug of an OLDER name must not be mistaken
    /// for a student's rename. Fails if "generated" means only "equals the current name's default".
    @Test func aGeneratedFolderOfAnOlderNameIsNotARename() {
        let edited = "058167 - ANALISI 2 (ROSSI) [2026-27]"
        let cleaned = "ANALISI 2 (ROSSI)"
        #expect(name("058167-analisi-2-2026-27", cleaned: cleaned, raw: edited) == cleaned)
        #expect(name("analisi-2", cleaned: cleaned, raw: edited) == cleaned)
        #expect(name("analisi-2-11-3", cleaned: cleaned, raw: edited) == cleaned, "counter-suffixed default")
        #expect(name("fisica-è-più-bella", cleaned: cleaned, raw: edited) == cleaned, "accented lowercase slug")
        #expect(name("Analisi 2 (11)", cleaned: cleaned, raw: edited, id: 11) == cleaned, "legacy NAME (id) with the course's own id")
        #expect(name("analisi-2--11", cleaned: cleaned, raw: edited, id: 11) == cleaned, "a run of hyphens left by truncation")
        #expect(RecmanCourseSidebar.menuName(courseName: cleaned, courseDisplayName: edited, courseID: 11, localFolderName: "058167-analisi-2-2026-27") == "ANALISI 2")
    }

    /// The documented trade-off of the slug heuristic: mixed or upper case and names with spaces
    /// are honoured, an all-lowercase single word is not. Fails if the heuristic is widened or removed.
    @Test func theSlugHeuristicHonoursMixedCaseButNotPlainLowercase() {
        #expect(name("GAL") == "GAL (Claude Sonnet)")
        #expect(name("Gal") == "Gal (Claude Sonnet)")
        #expect(name("Geometria 2") == "Geometria 2 (Claude Sonnet)")
        #expect(name("gal") == Self.cleaned)
        // The legacy "NAME (id)" form is the course's OWN id only: other numbers are real renames.
        #expect(name("GAL (2026)") == "GAL (2026) (Claude Sonnet)")
        #expect(name("Fisica (2)") == "Fisica (2) (Claude Sonnet)")
        #expect(name("Geometria (7)") == Self.cleaned, "id 7 is this course's own")
    }

    /// The trailing part in parentheses is not always a teacher (a section here): it is kept
    /// as it is. Fails if the code assumed a teacher's shape.
    @Test func aSectionInParenthesesIsKeptLikeATeacher() {
        #expect(name("AN2", cleaned: "ANALISI 2 (sezione B)", raw: "058167 - ANALISI 2 (sezione B) [2026-27]") == "AN2 (sezione B)")
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
