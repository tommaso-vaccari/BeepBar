import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The name a menu bar line gives a course: the renamed folder alone, never the teacher.
struct RecordingsMenuNamesTests {
    private static let raw = "058167 - GEOMETRIA ALGEBRA LINEARE (Claude Sonnet) [2026-27]"
    private static let cleaned = "GEOMETRIA ALGEBRA LINEARE (Claude Sonnet)"

    private func menu(_ folder: String?, cleaned: String = cleaned, raw: String = raw) -> String {
        RecmanCourseSidebar.menuName(courseName: cleaned, courseDisplayName: raw, courseID: 7, localFolderName: folder)
    }

    /// A renamed folder is the whole name: no teacher. Guards against reusing the sidebar name,
    /// which would print "GAL (Claude Sonnet)" in the menu. Fails if the teacher is appended.
    @Test func aRenamedFolderIsShownAlone() {
        #expect(menu("GAL") == "GAL")
        #expect(menu("gal") == "gal")
        #expect(menu("Gal") == "Gal")
        #expect(menu("algebra-lineare") == "algebra-lineare")
        #expect(menu("  GAL \n") == "GAL")
        #expect(menu("Algebra (Claude Sonnet)") == "Algebra (Claude Sonnet)", "the student's own text is never edited")
    }

    /// Not renamed (missing, blank, or a folder BeepBar generated): the base name without teacher.
    /// Fails if the generated-folder check is gone (the slug would show) or the teacher stays.
    @Test func anUnrenamedFolderShowsTheBaseWithoutTeacher() {
        let base = "GEOMETRIA ALGEBRA LINEARE"
        #expect(menu(nil) == base)
        #expect(menu("") == base)
        #expect(menu("  \t") == base)
        #expect(menu("geometria-algebra-lineare") == base)
        #expect(menu("geometria-algebra-lineare-7") == base)
    }

    /// Names without a teacher stay as they are; only the trailing group goes; odd input is safe.
    /// Fails if the first group were stripped, or a name made only of a group were blanked.
    @Test func namesWithoutATeacherAreUnchanged() {
        #expect(menu(nil, cleaned: "FISICA", raw: "052499 - FISICA [2026-27]") == "FISICA")
        #expect(menu(nil, cleaned: "ANALISI (Mod. A) II (Rossi)", raw: "x") == "ANALISI (Mod. A) II")
        #expect(menu(nil, cleaned: "(Rossi)", raw: "(Rossi)") == "(Rossi)")
        #expect(menu(nil, cleaned: "", raw: "") == "")
        #expect(menu(nil, cleaned: "Foo (a (b))", raw: "x") == "Foo (a (b))")
    }

    /// A renamed course's line keeps its click target and tooltip: the new name is only text.
    /// Fails if the name change replaced the entry builder instead of feeding it.
    @Test func aRenamedLineStaysClickable() {
        let course = RemoteCourseSummary(id: 1, shortName: "a", displayName: Self.raw, isVisible: true, startDate: nil, endDate: nil)
        let key = RecmanCourseKey(course: course)!
        let next = RecmanRecording(id: "9", courseCode: key.courseCode, academicYear: key.academicYear, title: "Lezione 9",
                                   recordedAt: Date(timeIntervalSince1970: 1_790_000_000), kind: "Lezione", duration: "90 min", size: nil,
                                   previewURL: URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=1&transfer_id=9")!)
        let summary = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 45, unknownDurationCount: 0, next: next)
        let lines = WeBeepAuthenticationController.recordingMenuLines(courses: [course], enabledIDs: [1], summaries: [key: summary], owner: 7, folders: [1: "gal"])
        #expect(lines.first?.text.italian == "gal — 3/10 · ~45 min")
        #expect(lines.first?.target == RecordingMenuTarget(owner: 7, courseID: 1, key: key))
        #expect(lines.first?.hint != nil)
    }

    /// The builder feeds the folder map into the line and leaves other courses alone, and the
    /// line keeps its numbers. Fails if `folders` is ignored by `recordingMenuLines`.
    @Test func theLinesUseTheFolderMap() {
        let courses = [
            RemoteCourseSummary(id: 1, shortName: "a", displayName: Self.raw, isVisible: true, startDate: nil, endDate: nil),
            RemoteCourseSummary(id: 2, shortName: "b", displayName: "052499 - FISICA (Rossi) [2026-27]", isVisible: true, startDate: nil, endDate: nil),
        ]
        let key1 = RecmanCourseKey(course: courses[0])!, key2 = RecmanCourseKey(course: courses[1])!
        let summary = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 45, unknownDurationCount: 0)
        let lines = WeBeepAuthenticationController.recordingMenuLines(courses: courses, enabledIDs: [1, 2], summaries: [key1: summary, key2: summary], owner: nil, folders: [1: "GAL"])
        #expect(lines.map(\.text.italian) == ["GAL — 3/10 · ~45 min", "FISICA — 3/10 · ~45 min"])
        #expect(lines.map(\.text.english) == ["GAL — 3/10 · ~45 min", "FISICA — 3/10 · ~45 min"])
    }
}
