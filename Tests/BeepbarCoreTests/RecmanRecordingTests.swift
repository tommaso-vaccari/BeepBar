import Foundation
import Testing
@testable import BeepbarCore

/// The archive rows and the course they belong to. Each test guards a way the Recordings page could
/// show the wrong list without saying so: another year's or course's recordings, a row silently
/// dropped, a link BeepBar shouldn't follow.
struct RecmanRecordingTests {
    private let preview = "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=evento&transfer_id=123"
    /// A row as the real archive lays it out (cells copied from a live page, ids replaced).
    private var cells: [String] { ["", "2026 / 27", "30/09/2026 12:29", "058167 - NUMERICAL LINEAR ALGEBRA (DOCENTE)", "Laboratorio", "Linear systems solvers", "", "97 min", "179 MB"] }

    private func course(_ shortName: String, _ displayName: String) -> RemoteCourseSummary {
        RemoteCourseSummary(id: 1, shortName: shortName, displayName: displayName, isVisible: true, startDate: nil, endDate: nil)
    }

    /// The course code and year come from the WeBeep names, and only when they are unambiguous:
    /// a guess would list another course's or another year's recordings as this one's.
    @Test func courseKeyNeedsOneCodeAndOneValidYear() {
        let key = RecmanCourseKey(course: course("058167 - NUMERICAL LINEAR ALG... 890097", "058167 - NUMERICAL LINEAR ALGEBRA [2026-27]"))
        #expect(key?.courseCode == "058167")
        #expect(key?.academicYear == 2026)
        #expect(key?.academicYearLabel == "2026 / 27")
        // No year anywhere.
        #expect(RecmanCourseKey(course: course("058167 - NLA", "058167 - NLA")) == nil)
        // Two different codes, or two different years, between the two names.
        #expect(RecmanCourseKey(course: course("058165 - NLA [2026-27]", "058167 - NLA [2026-27]")) == nil)
        #expect(RecmanCourseKey(course: course("058167 - NLA [2025-26]", "058167 - NLA [2026-27]")) == nil)
        // A malformed year label next to a valid one is not ignored.
        #expect(RecmanCourseKey(course: course("058167 - NLA [2026-28]", "058167 - NLA [2026-27]")) == nil)
        // A code that isn't six digits followed by " -".
        #expect(RecmanCourseKey(course: course("58167 - NLA [2026-27]", "58167 - NLA [2026-27]")) == nil)
    }

    @Test func academicYearLabelsMustBeConsecutiveYears() {
        #expect(RecmanCourseKey.normalizedYear("2026 / 2027") == 2026)
        #expect(RecmanCourseKey.normalizedYear("2026\t/\t27") == 2026)
        #expect(RecmanCourseKey.normalizedYear("2026-27") == 2026)
        #expect(RecmanCourseKey.normalizedYear("2099/00") == nil)
        #expect(RecmanCourseKey.normalizedYear("2026/28") == nil)
        #expect(RecmanCourseKey.normalizedYear("2026/2026") == nil)
        #expect(RecmanCourseKey.normalizedYear("26/27") == nil)
        #expect(RecmanCourseKey(courseCode: "05816", academicYear: 2026) == nil)
        #expect(RecmanCourseKey(courseCode: "058167", academicYear: 1999) == nil)
        #expect(RecmanCourseKey(courseCode: "058167", academicYear: 2009)?.academicYearLabel == "2009 / 10")
    }

    /// Dates are Rome wall-clock times: 12:29 in late September is 10:29 UTC. Read in the Mac's
    /// own zone, a recording would show at the wrong hour (or day) for anyone travelling.
    @Test func decodesEveryFieldAndReadsTheDateInRomeTime() throws {
        let row = try #require(RecmanRecordingParser.recording(cells: cells, previewURL: preview))
        #expect(row.id == "123")
        #expect(row.courseCode == "058167")
        #expect(row.academicYear == 2026)
        #expect(row.kind == "Laboratorio")
        #expect(row.title == "Linear systems solvers")
        #expect(row.duration == "97 min")
        #expect(row.size == "179 MB")
        #expect(row.recordedAt == ISO8601DateFormatter().date(from: "2026-09-30T10:29:00Z"))
        var untitled = cells
        untitled[5] = ""
        #expect(RecmanRecordingParser.recording(cells: untitled, previewURL: preview)?.title == "")
        var noSize = cells
        noSize.removeLast()
        #expect(RecmanRecordingParser.recording(cells: noSize, previewURL: preview)?.size == nil)
    }

    /// The search asks for one course and year, but the page may still carry others: only the
    /// course's own rows are kept, once each, newest first.
    @Test func keepsOnlyTheCourseAndYearOnceEachNewestFirst() throws {
        var old = cells
        old[1] = "2025 / 26"
        var other = cells
        other[3] = "058165 - PARALLEL COMPUTING"
        var earlier = cells
        earlier[2] = "23/09/2026 12:26"
        let data = try JSONSerialization.data(withJSONObject: [
            ["cells": earlier, "previewURL": preview.replacingOccurrences(of: "123", with: "122")],
            ["cells": cells, "previewURL": preview],
            ["cells": cells, "previewURL": preview],
            ["cells": old, "previewURL": preview.replacingOccurrences(of: "123", with: "124")],
            ["cells": other, "previewURL": preview.replacingOccurrences(of: "123", with: "125")],
        ])
        let key = try #require(RecmanCourseKey(courseCode: "058167", academicYear: 2026))
        #expect(try RecmanRecordingParser.decode(data, matching: key).map(\.id) == ["123", "122"])
        #expect(try RecmanRecordingParser.decode(data).count == 4)
    }

    /// One unreadable row fails the page: a layout change must surface as "can't read the
    /// archive", never as a shorter list that looks complete.
    @Test func anUnreadableRowFailsThePageInsteadOfDisappearing() throws {
        #expect(RecmanRecordingParser.recording(cells: [], previewURL: preview) == nil)
        for (index, value) in [(2, "31/02/2026 12:29"), (2, "30/09/26 12:29"), (7, "unknown"), (1, "2026"), (3, "NUMERICAL LINEAR ALGEBRA")] {
            var invalid = cells
            invalid[index] = value
            #expect(RecmanRecordingParser.recording(cells: invalid, previewURL: preview) == nil, "cell \(index) = \(value)")
        }
        var invalid = cells
        invalid[7] = "unknown"
        let mixed = try JSONSerialization.data(withJSONObject: [["cells": cells, "previewURL": preview], ["cells": invalid, "previewURL": preview]])
        #expect(throws: RecmanRecordingParser.ParseError.incompatibleRows) { try RecmanRecordingParser.decode(mixed) }
        let noLink = try JSONSerialization.data(withJSONObject: [["cells": cells, "previewURL": ""]])
        #expect(throws: RecmanRecordingParser.ParseError.incompatibleRows) { try RecmanRecordingParser.decode(noLink) }
        #expect(try RecmanRecordingParser.decode(Data("[]".utf8)).isEmpty)
    }

    /// The links come from a web page, so BeepBar follows only the exact shapes it knows.
    @Test func followsOnlyWellFormedPreviewAndPlaybackLinks() throws {
        #expect(RecmanURLPolicy.previewTransferID(try #require(URL(string: preview))) == "123")
        let badPreviews = [
            preview.replacingOccurrences(of: "https:", with: "http:"),
            preview.replacingOccurrences(of: "onlineservices.polimi.it", with: "onlineservices.polimi.it.evil.com"),
            preview.replacingOccurrences(of: "onlineservices.polimi.it", with: "onlineservices.polimi.it:8443"),
            preview + "&transfer_id=456",
            preview.replacingOccurrences(of: "transfer_id=123", with: "transfer_id=1%2F2"),
            preview.replacingOccurrences(of: "https://", with: "https://user:secret@"),
            preview.replacingOccurrences(of: "evn_preview_link", with: "other"),
        ]
        for bad in badPreviews {
            #expect(RecmanURLPolicy.previewTransferID(try #require(URL(string: bad))) == nil, "\(bad)")
        }
        for good in ["https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc123", "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/abc123"] {
            #expect(RecmanURLPolicy.playbackURL(try #require(URL(string: good))) != nil)
        }
        for bad in ["https://politecnicomilano.webex.com/ldr.php", "http://politecnicomilano.webex.com/ldr.php?RCID=a", "https://politecnicomilano.webex.com.evil.com/ldr.php?RCID=a", "https://user@politecnicomilano.webex.com/ldr.php?RCID=a", "https://politecnicomilano.webex.com/recordingservice/login", "https://politecnicomilano.webex.com/ldr.php?RCID=a&RCID=b"] {
            #expect(RecmanURLPolicy.playbackURL(try #require(URL(string: bad))) == nil, "\(bad)")
        }
    }
}
