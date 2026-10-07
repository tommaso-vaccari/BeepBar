import Foundation
import Testing
@testable import BeepbarCore

/// Paging through one course's search. Every test here guards the same promise from a different
/// side: the Recordings page shows the whole list or says it couldn't, never a shorter list that
/// looks complete.
struct RecmanArchiveListingTests {
    private let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!

    private func recording(_ id: String, code: String = "058167", year: Int = 2026, day: Int = 1) -> RecmanRecording {
        RecmanRecording(id: id, courseCode: code, academicYear: year, title: "Lecture \(id)", recordedAt: Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + day * 86_400)),
                        kind: "Lezione", duration: "90 min", size: nil,
                        previewURL: URL(string: "https://onlineservices.polimi.it\(RecmanURLPolicy.archivePath)?evn_preview_link=evento&transfer_id=\(id)")!)
    }

    private func page(_ recordings: [RecmanRecording], total: Int? = nil, next: Bool = false, empty: Bool = false, code: String = "058167", year: String = "2026") -> RecmanResultsPage {
        RecmanResultsPage(recordings: recordings, declaredTotal: total, hasNext: next, saysEmpty: empty, searchedCode: code, searchedYear: year)
    }

    @Test func followsEveryPageAndKeepsTheCourseNewestFirst() throws {
        var listing = RecmanArchiveListing(key: key)
        #expect(try listing.add(page([recording("1", day: 1), recording("2", day: 3)], total: 4, next: true)))
        // A row of another course or year that the search let through is not this course's.
        #expect(try listing.add(page([recording("3", code: "058165", day: 2), recording("4", year: 2025, day: 4)], total: 4)) == false)
        #expect(listing.recordings.map(\.id) == ["2", "1"])
    }

    /// Without a total on the page, the end of "prossima" is the end of the list.
    @Test func aListWithoutADeclaredTotalEndsWithTheLastPage() throws {
        var listing = RecmanArchiveListing(key: key)
        #expect(try listing.add(page([recording("1")], next: true)))
        #expect(try listing.add(page([recording("2"), recording("1")])) == false)
        #expect(Set(listing.recordings.map(\.id)) == ["1", "2"])
    }

    /// A total that doesn't match the rows received means pages were lost on the way.
    @Test func aTotalThatDoesNotMatchTheRowsFailsTheList() throws {
        var short = RecmanArchiveListing(key: key)
        #expect(try short.add(page([recording("1")], total: 3, next: true)))
        #expect(throws: RecmanArchiveListing.ListingError.incomplete) { try short.add(page([recording("2")], total: 3)) }
        // The total changing between pages: the search moved under BeepBar's feet.
        var moving = RecmanArchiveListing(key: key)
        #expect(try moving.add(page([recording("1")], total: 2, next: true)))
        #expect(throws: RecmanArchiveListing.ListingError.incomplete) { try moving.add(page([recording("2")], total: 3)) }
    }

    /// "prossima" that leads to the same rows would loop forever; one that never ends stops at
    /// `maximumPages`.
    @Test func aNextLinkThatDoesNotMoveOrNeverEndsFailsTheList() throws {
        var stuck = RecmanArchiveListing(key: key)
        #expect(try stuck.add(page([recording("1"), recording("2")], next: true)))
        #expect(throws: RecmanArchiveListing.ListingError.incomplete) { try stuck.add(page([recording("1"), recording("2")], next: true)) }
        var endless = RecmanArchiveListing(key: key)
        for index in 0..<RecmanArchiveListing.maximumPages {
            #expect(try endless.add(page([recording("\(index)")], next: true)))
        }
        #expect(throws: RecmanArchiveListing.ListingError.incomplete) { try endless.add(page([recording("last")], next: true)) }
    }

    /// An empty table is "no recordings" only when the archive says so, in its total or in words.
    @Test func anEmptyTableNeedsTheArchiveToSayItIsEmpty() throws {
        var zero = RecmanArchiveListing(key: key)
        #expect(try zero.add(page([], total: 0)) == false)
        #expect(zero.recordings.isEmpty)
        var notice = RecmanArchiveListing(key: key)
        #expect(try notice.add(page([], empty: true)) == false)
        for silent in [page([]), page([], total: 5), page([], total: 0, next: true), page([], total: 5, empty: true)] {
            var listing = RecmanArchiveListing(key: key)
            #expect(throws: RecmanArchiveListing.ListingError.incompatiblePage) { try listing.add(silent) }
        }
        // An empty page after rows: the table lost its rows half-way.
        var halfway = RecmanArchiveListing(key: key)
        #expect(try halfway.add(page([recording("1")], next: true)))
        #expect(throws: RecmanArchiveListing.ListingError.incompatiblePage) { try halfway.add(page([], empty: true)) }
    }

    /// The form on the page must still hold this search. If the Recman session lapsed, the archive
    /// can start over on its default page, whose rows would otherwise pass as this course's.
    @Test func aPageForAnotherSearchIsNotThisCoursesList() throws {
        var listing = RecmanArchiveListing(key: key)
        #expect(throws: RecmanArchiveListing.ListingError.notThisSearch) { try listing.add(page([recording("1")], code: "")) }
        #expect(throws: RecmanArchiveListing.ListingError.notThisSearch) { try listing.add(page([recording("1")], year: "")) }
        #expect(throws: RecmanArchiveListing.ListingError.notThisSearch) { try listing.add(page([recording("1")], year: "2025")) }
        #expect(try listing.add(page([recording("1")], next: true)))
        #expect(throws: RecmanArchiveListing.ListingError.notThisSearch) { try listing.add(page([recording("2")], code: "058165")) }
    }

    /// The script's JSON is read whole: one unreadable row, or a field missing, fails the page.
    @Test func decodesTheScriptsReportWholeOrNotAtAll() throws {
        let preview = "https://onlineservices.polimi.it\(RecmanURLPolicy.archivePath)?evn_preview_link=evento&transfer_id=7"
        let cells = ["", "2026 / 27", "30/09/2026 12:29", "058167 - NLA (DOCENTE)", "Lezione", "Title", "", "97 min", "179 MB"]
        func report(_ rows: [[String: Any]], extra: [String: Any] = [:]) throws -> String {
            var object: [String: Any] = ["rows": rows, "total": 1, "hasNext": false, "saysEmpty": false, "searchedCode": "058167", "searchedYear": "2026"]
            object.merge(extra) { $1 }
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let decoded = try RecmanResultsPage.decode(report([["cells": cells, "previewURL": preview]]))
        #expect(decoded.recordings.map(\.id) == ["7"])
        #expect(decoded.declaredTotal == 1)
        #expect(try RecmanResultsPage.decode(report([], extra: ["total": NSNull()])).declaredTotal == nil)
        var broken = cells
        broken[2] = "yesterday"
        #expect(throws: RecmanRecordingParser.ParseError.incompatibleRows) { try RecmanResultsPage.decode(report([["cells": cells, "previewURL": preview], ["cells": broken, "previewURL": preview]])) }
        #expect(throws: RecmanRecordingParser.ParseError.incompatibleRows) { try RecmanResultsPage.decode(#"{"rows":[],"hasNext":false}"#) }
        #expect(throws: RecmanRecordingParser.ParseError.incompatibleRows) { try RecmanResultsPage.decode("not json") }
    }
}
