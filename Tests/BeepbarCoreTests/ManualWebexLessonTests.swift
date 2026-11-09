import Foundation
import Testing
@testable import BeepbarCore

/// Lessons added to the Watchlist by their Webex link: which links are accepted, and that the
/// synthetic row they become stays out of everything keyed by an archive course.
struct ManualWebexLessonTests {
    private let uuid = "0123456789abcdef0123456789abcdef"

    /// The two forms Recman's own rows lead to are accepted unchanged, also with the whitespace a
    /// copied line carries. Guards against a manual lesson that the stream resolver can't read.
    @Test func acceptsThePlayerFormsTheResolverReads() throws {
        let loader = "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc123"
        #expect(ManualWebexLesson.normalizedLink("  \(loader)\n")?.absoluteString == loader)
        let playback = "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)"
        let page = try #require(ManualWebexLesson.normalizedLink(playback))
        #expect(page.absoluteString == playback)
        #expect(WebexPlayerLink.playbackPage(fromPlayerURL: page)?.uuid == uuid)
    }

    /// The exact shape of a link a student copied from Webex (2026-11-09, uuid replaced by a
    /// synthetic one): no query, no trailing slash.
    @Test func acceptsTheShapeStudentsCopy() throws {
        let copied = "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/\(uuid)/playback"
        let link = try #require(ManualWebexLesson.normalizedLink(copied))
        #expect(link.absoluteString == "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)")
        #expect(WebexPlayerLink.playbackPage(fromPlayerURL: link)?.uuid == uuid)
    }

    /// The address Webex's newer web app shows for a recording (`/webappng/…`, as a student
    /// pasted it on 2026-11-09, uuid replaced by a synthetic one) becomes the same playback form.
    /// Guards against refusing the link most students will copy from their browser.
    @Test func acceptsTheWebAppAddress() throws {
        let copied = "https://politecnicomilano.webex.com/webappng/sites/politecnicomilano/recording/\(uuid)/playback"
        let link = try #require(ManualWebexLesson.normalizedLink(copied))
        #expect(link.absoluteString == "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)")
        #expect(WebexPlayerLink.playbackPage(fromPlayerURL: link)?.uuid == uuid)
    }

    /// The share form (`/recording/<uuid>/playback`) becomes the playback form the resolver
    /// reads; without the rewrite it would be refused, since `RecmanURLPolicy` doesn't know it.
    @Test func rewritesTheShareFormToThePlaybackForm() throws {
        let share = "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/\(uuid)/playback?from=share#t=10"
        #expect(RecmanURLPolicy.playbackURL(URL(string: share)!) == nil)
        let link = try #require(ManualWebexLesson.normalizedLink(share))
        #expect(link.path == "/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)")
        #expect(link.fragment == nil)
        #expect(WebexPlayerLink.playbackPage(fromPlayerURL: link)?.uuid == uuid)
    }

    /// Anything that isn't a recording on Polimi's Webex site, over https, is refused rather than
    /// followed: other hosts and lookalikes, http, credentials, odd ports, other paths, ids that
    /// aren't 32 lowercase hex in the rewritten form, and text that isn't one URL.
    @Test(arguments: [
        "",
        "   ",
        "not a link",
        "https://evil.example/recordingservice/sites/politecnicomilano/recording/playback/0123456789abcdef0123456789abcdef",
        "https://politecnicomilano.webex.com.evil.com/politecnicomilano/ldr.php?RCID=abc",
        "https://othersite.webex.com/othersite/ldr.php?RCID=abc",
        "http://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc",
        "https://user:pw@politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc",
        "https://politecnicomilano.webex.com:8443/politecnicomilano/ldr.php?RCID=abc",
        "https://politecnicomilano.webex.com/meet/someone",
        "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/0123456789ABCDEF0123456789ABCDEF/playback",
        "https://politecnicomilano.webex.com/recordingservice/sites/othersite/recording/0123456789abcdef0123456789abcdef/playback",
        "https://politecnicomilano.webex.com/webappng/sites/othersite/recording/0123456789abcdef0123456789abcdef/playback",
        "https://politecnicomilano.webex.com/otherapp/sites/politecnicomilano/recording/0123456789abcdef0123456789abcdef/playback",
        "https://politecnicomilano.webex.com/webappng/sites/politecnicomilano/recording/0123456789abcdef0123456789abcd/playback",
        "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/..%2F/playback",
        "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc https://evil.example",
    ])
    func refusesEverythingElse(text: String) {
        #expect(ManualWebexLesson.normalizedLink(text) == nil)
    }

    /// The synthetic row has no archive course key, so no listing is ever asked for it and
    /// `reconcile` can't mark it unavailable; its player link is its own link.
    @Test func theRowStaysOutOfArchiveCourses() throws {
        var lessons = ManualWebexLessons()
        let lesson = try lessons.add(link: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc", title: "  Guest lecture  ", courseName: "", now: Date(timeIntervalSince1970: 1_800_000_000))
        let row = lesson.recording
        #expect(RecmanCourseKey(courseCode: row.courseCode, academicYear: row.academicYear) == nil)
        #expect(ManualWebexLesson.isManual(row))
        #expect(ManualWebexLesson.playerLink(for: row) == lesson.link)
        #expect(row.title == "Guest lecture")
        #expect(row.minutes == nil)
        #expect(row.id.hasPrefix(ManualWebexLesson.idPrefix))
        let untitled = ManualWebexLesson(title: "  ", courseName: "", link: lesson.link, addedAt: .now)
        #expect(RecmanPresentation.title(untitled.recording) == "Webex")
    }

    /// An archive row is never treated as manual, even if its link were a Webex player: the
    /// archive path (and its transfer-id check) stays the only one for it.
    @Test func archiveRowsAreNeverManual() {
        let archive = RecmanRecording(id: "manual-x", courseCode: "058167", academicYear: 2026, title: "t", recordedAt: .now, kind: "Lezione", duration: "90 min", size: nil,
                                      previewURL: URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc")!)
        #expect(!ManualWebexLesson.isManual(archive))
        #expect(ManualWebexLesson.playerLink(for: archive) == nil)
    }

    /// A row read back from disk whose link no longer passes the policy (an edited settings file)
    /// is never followed.
    @Test func aTamperedLinkIsNotFollowed() {
        let tampered = ManualWebexLesson(title: "x", courseName: "", link: URL(string: "https://evil.example/ldr.php?RCID=abc")!, addedAt: .now)
        #expect(ManualWebexLesson.isManual(tampered.recording))
        #expect(ManualWebexLesson.playerLink(for: tampered.recording) == nil)
    }

    /// One recording is one lesson, whichever of its forms is pasted; invalid text never adds.
    @Test func duplicatesAndInvalidLinksAreRefused() throws {
        var lessons = ManualWebexLessons()
        try lessons.add(link: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)", title: "", courseName: "")
        #expect(throws: ManualWebexLessons.AddError.duplicate) {
            try lessons.add(link: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/\(uuid)/playback", title: "", courseName: "")
        }
        #expect(throws: ManualWebexLessons.AddError.invalidLink) { try lessons.add(link: "https://example.com", title: "", courseName: "") }
        #expect(lessons.lessons.count == 1)
    }

    /// Only the recording id survives a paste: the address bar's parameters, fragment and trailing
    /// slash are neither stored nor given back by "Copy link", and `RCID` is the one query item an
    /// `ldr.php` link keeps. Guards against storing whatever the browser appended (review of #235).
    @Test func theStoredLinkCarriesOnlyTheRecordingID() throws {
        let page = try #require(ManualWebexLesson.normalizedLink(
            "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)/?from=mail&t=10#x"))
        #expect(page.absoluteString == "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)")
        let share = try #require(ManualWebexLesson.normalizedLink(
            "https://politecnicomilano.webex.com/webappng/sites/politecnicomilano/recording/\(uuid)/playback?from=share"))
        #expect(share == page)
        let loader = try #require(ManualWebexLesson.normalizedLink("https://politecnicomilano.webex.com/politecnicomilano/ldr.php?utm=x&RCID=abc123#t"))
        #expect(loader.absoluteString == "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc123")
        #expect(WebexPlayerLink.isLoader(loader))
    }

    /// One recording pasted again with other parameters or a trailing slash is a duplicate, also
    /// against a lesson an earlier build stored with its query as pasted, which stays as it was on
    /// disk. Guards against the same lesson appearing twice in the Watchlist.
    @Test func aRecordingWithOtherParametersIsADuplicate() throws {
        var lessons = ManualWebexLessons()
        try lessons.add(link: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)", title: "", courseName: "")
        #expect(throws: ManualWebexLessons.AddError.duplicate) {
            try lessons.add(link: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/\(uuid)/?from=mail", title: "", courseName: "")
        }
        let stored = URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc123&from=mail")!
        var older = ManualWebexLessons(lessons: [ManualWebexLesson(title: "", courseName: "", link: stored, addedAt: .now)])
        #expect(throws: ManualWebexLessons.AddError.duplicate) {
            try older.add(link: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc123", title: "", courseName: "")
        }
        #expect(older.lessons.map(\.link) == [stored])
        try older.add(link: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc124", title: "", courseName: "")
        #expect(older.lessons.count == 2)
    }

    /// Titles and labels are trimmed and bounded, so a pasted page can't bloat the settings file;
    /// each lesson gets its own id; removal is by id only.
    @Test func textIsBoundedAndIdsAreUnique() throws {
        var lessons = ManualWebexLessons()
        let a = try lessons.add(link: "https://politecnicomilano.webex.com/ldr.php?RCID=a", title: String(repeating: "x", count: 5_000), courseName: " NLA ")
        let b = try lessons.add(link: "https://politecnicomilano.webex.com/ldr.php?RCID=b", title: "", courseName: "")
        #expect(a.title.count == ManualWebexLesson.maxTextLength)
        #expect(a.courseName == "NLA")
        #expect(a.id != b.id)
        lessons.remove(id: a.id)
        #expect(lessons.lessons.map(\.id) == [b.id])
    }

    /// The stored form round-trips, so a restart shows the same lessons.
    @Test func roundTripsThroughThePropertyList() throws {
        var lessons = ManualWebexLessons()
        try lessons.add(link: "https://politecnicomilano.webex.com/ldr.php?RCID=a", title: "T", courseName: "C", now: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try PropertyListEncoder().encode(lessons)
        #expect(try PropertyListDecoder().decode(ManualWebexLessons.self, from: data) == lessons)
    }

    /// Lessons saved before `durationSeconds` and `progress` existed (the installed build of
    /// 2026-11-09) still load, with neither; a damaged value of either costs only that field,
    /// never the lessons. Guards against synthesized decoding, which would make one bad field
    /// (or, before `decodeIfPresent`, a missing one) turn the whole list unreadable.
    @Test func olderAndDamagedLessonsStillLoad() throws {
        // Optionals left nil are not encoded at all: these bytes are what the older build wrote.
        let saved = ManualWebexLessons(lessons: [ManualWebexLesson(id: "manual-a", title: "T", courseName: "", link: URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a")!, addedAt: Date(timeIntervalSince1970: 1_800_000_000))])
        let oldData = try PropertyListEncoder().encode(saved)
        let old = try #require(try PropertyListSerialization.propertyList(from: oldData, format: nil) as? [String: Any])
        #expect(((old["lessons"] as? [[String: Any]])?.first?.keys).map { Set($0) } == ["id", "title", "courseName", "link", "addedAt"])
        let loaded = try PropertyListDecoder().decode(ManualWebexLessons.self, from: oldData)
        #expect(loaded.lessons.map(\.id) == ["manual-a"])
        #expect(loaded.lessons[0].durationSeconds == nil && loaded.lessons[0].progress == nil)
        #expect(loaded.lessons[0].recording.duration == "")

        var damaged = old
        var lesson = (old["lessons"] as! [[String: Any]])[0]
        lesson["durationSeconds"] = "long"
        lesson["progress"] = ["furthest": "half"]
        damaged["lessons"] = [lesson]
        let damagedData = try PropertyListSerialization.data(fromPropertyList: damaged, format: .binary, options: 0)
        let read = try PropertyListDecoder().decode(ManualWebexLessons.self, from: damagedData)
        #expect(read.lessons.map(\.id) == ["manual-a"])
        #expect(read.lessons[0].durationSeconds == nil && read.lessons[0].progress == nil)
    }

    /// A Play fills in what the student left out, never what they typed: the title only when
    /// empty, the length whenever Webex gives a plausible one, shown in Recman's form so the
    /// row's length and the hours-left sum read it (`RecmanRecording.minutes`). Implausible
    /// lengths (zero, negative, infinite, over a day) are ignored rather than shown.
    @Test func aPlayFillsInTheTitleAndLengthOnly() throws {
        var lesson = ManualWebexLesson(title: "", courseName: "", link: URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a")!, addedAt: .now)
        let learned = lesson.learn(title: "  Lezione 12 - Fourier  ", duration: 5_830)
        #expect(learned)
        #expect(lesson.title == "Lezione 12 - Fourier")
        #expect(lesson.recording.duration == "97 min" && lesson.recording.minutes == 97)
        let again = lesson.learn(title: "Another", duration: 5_830)
        #expect(!again, "a known title and the same length change nothing")
        #expect(lesson.title == "Lezione 12 - Fourier")
        for bad in [0, -5, .infinity, .nan, 90_000] as [Double] {
            let changed = lesson.learn(title: nil, duration: bad)
            #expect(!changed, "\(bad)")
        }
        #expect(lesson.durationSeconds == 5_830)

        var typed = ManualWebexLesson(title: "Guest lecture", courseName: "", link: URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=b")!, addedAt: .now)
        typed.learn(title: "Webex's name", duration: nil)
        #expect(typed.title == "Guest lecture")
        var untitled = ManualWebexLesson(title: "", courseName: "", link: URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=c")!, addedAt: .now)
        let blank = untitled.learn(title: "   ", duration: nil)
        #expect(!blank, "a blank title from Webex is no title")
        #expect(untitled.title.isEmpty)
    }

    /// Progress and length round-trip with the lesson, and `replace` updates by id only.
    @Test func progressAndLengthAreSavedWithTheLesson() throws {
        var lessons = ManualWebexLessons()
        var lesson = try lessons.add(link: "https://politecnicomilano.webex.com/ldr.php?RCID=a", title: "T", courseName: "", now: Date(timeIntervalSince1970: 1_800_000_000))
        lesson.durationSeconds = 3_600
        lesson.progress = RecordingWatchEntry(furthest: 0.5, completed: .manual, autoCompletionBlocked: false)
        let replaced = lessons.replace(lesson)
        #expect(replaced)
        let data = try PropertyListEncoder().encode(lessons)
        let read = try PropertyListDecoder().decode(ManualWebexLessons.self, from: data)
        #expect(read.lesson(id: lesson.id) == lesson)
        lessons.remove(id: lesson.id)
        let readded = lessons.replace(lesson)
        #expect(!readded, "a lesson removed meanwhile is not added back")
        #expect(lessons.lessons.isEmpty)
    }
}
