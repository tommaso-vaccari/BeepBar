import Foundation

/// One page of search results, as `RecmanScripts.resultsPage` in the app reads it from the archive.
public struct RecmanResultsPage: Sendable, Equatable {
    /// Every row on the page, in page order. All rows parsed, or the page wasn't decoded at all.
    public let recordings: [RecmanRecording]
    /// The "totale: N" the archive prints for the whole search, if the page shows one.
    public let declaredTotal: Int?
    /// Whether an enabled "prossima" link leads to another page.
    public let hasNext: Bool
    /// Whether the page says in words that the search found nothing.
    public let saysEmpty: Bool
    /// What the search form holds on this page: the course code and the year the results are for.
    public let searchedCode: String
    public let searchedYear: String

    public init(recordings: [RecmanRecording], declaredTotal: Int?, hasNext: Bool, saysEmpty: Bool, searchedCode: String, searchedYear: String) {
        self.recordings = recordings
        self.declaredTotal = declaredTotal
        self.hasNext = hasNext
        self.saysEmpty = saysEmpty
        self.searchedCode = searchedCode
        self.searchedYear = searchedYear
    }

    private struct Payload: Decodable {
        let rows: [RecmanRecordingParser.Row]
        let total: Int?
        let hasNext: Bool
        let saysEmpty: Bool
        let searchedCode: String
        let searchedYear: String
    }

    /// The script's JSON. Anything unexpected, a single unreadable row included, is
    /// `incompatibleRows`: the page is read whole or not at all.
    public static func decode(_ json: String) throws -> RecmanResultsPage {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { throw RecmanRecordingParser.ParseError.incompatibleRows }
        return RecmanResultsPage(recordings: try RecmanRecordingParser.recordings(payload.rows), declaredTotal: payload.total, hasNext: payload.hasNext,
                                 saysEmpty: payload.saysEmpty, searchedCode: payload.searchedCode, searchedYear: payload.searchedYear)
    }
}

/// Collects the pages of one course's search and decides when the list is complete.
///
/// The Recordings page must never show a list that looks complete but isn't, so every way the
/// pages could disagree stops the listing with an error instead: a page for another search, a
/// "next" that didn't move, a total that doesn't match the rows received, an empty table the
/// archive doesn't explain. The web side (`RecmanWebSession.recordings(for:)`) only turns pages
/// and follows "prossima"; every decision is here, where it can be tested.
public struct RecmanArchiveListing: Sendable {
    public enum ListingError: Error, Equatable {
        /// The page isn't the results of this search: the Recman session lapsed mid-way and the
        /// archive started over, or the form didn't take the search. Worth one fresh attempt.
        case notThisSearch
        /// The page doesn't read as Recman's results table (layout change).
        case incompatiblePage
        /// The pages don't add up to the whole search.
        case incomplete
    }

    /// A course has at most a few hundred recordings a year, read a hundred to a page (ten if the
    /// archive ever stops offering a larger page). More pages than this means "prossima" never
    /// ends, not a long list.
    public static let maximumPages = 100

    public let key: RecmanCourseKey
    private var receivedIDs = Set<String>()
    private var kept: [RecmanRecording] = []
    private var pageFingerprints = Set<[String]>()
    private var declaredTotal: Int?
    private var pageCount = 0

    public init(key: RecmanCourseKey) {
        self.key = key
    }

    /// Adds the next page. Returns true when there is another page to fetch.
    public mutating func add(_ page: RecmanResultsPage) throws -> Bool {
        guard page.searchedCode == key.courseCode, page.searchedYear == String(key.academicYear) else { throw ListingError.notThisSearch }
        pageCount += 1
        guard pageCount <= Self.maximumPages else { throw ListingError.incomplete }
        if pageCount == 1 {
            declaredTotal = page.declaredTotal
        } else if page.declaredTotal != declaredTotal {
            throw ListingError.incomplete
        }
        if page.recordings.isEmpty {
            // An empty table is only "no recordings" when the archive says so; otherwise it is a
            // layout the script no longer reads, or a page that lost its rows.
            guard pageCount == 1, !page.hasNext, declaredTotal == 0 || (declaredTotal == nil && page.saysEmpty) else { throw ListingError.incompatiblePage }
            return false
        }
        // The same rows twice means "prossima" didn't move: following it again would loop.
        guard pageFingerprints.insert(page.recordings.map(\.id)).inserted else { throw ListingError.incomplete }
        receivedIDs.formUnion(page.recordings.map(\.id))
        kept += page.recordings.filter { $0.courseCode == key.courseCode && $0.academicYear == key.academicYear }
        guard !page.hasNext else { return true }
        if let declaredTotal, declaredTotal != receivedIDs.count { throw ListingError.incomplete }
        return false
    }

    /// This course's recordings received so far, once each, newest first.
    public var recordings: [RecmanRecording] {
        var seen = Set<String>()
        return kept.filter { seen.insert($0.id).inserted }.sorted { $0.recordedAt > $1.recordedAt }
    }
}
