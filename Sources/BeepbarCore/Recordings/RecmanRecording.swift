import Foundation

// Recman is Polimi's archive of lecture recordings ("Archivio registrazioni didattica"). It has no
// API: BeepBar reads its HTML table through a web view (`RecmanWebSession` in the app) and turns
// each row into a `RecmanRecording` here. Everything in this folder depends on Foundation only, so
// `scripts/recman-probe` can compile it on its own for the live check against the real archive.

/// Which Recman search a WeBeep course corresponds to: Recman files recordings by the six-digit
/// course code and the academic year it starts in (2026 for "2026 / 27").
public struct RecmanCourseKey: Sendable, Equatable, Hashable {
    public let courseCode: String
    public let academicYear: Int

    public init?(courseCode: String, academicYear: Int) {
        guard courseCode.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil, (2000...2099).contains(academicYear) else { return nil }
        self.courseCode = courseCode
        self.academicYear = academicYear
    }

    /// "2026 / 27" as Recman and WeBeep write it.
    public var academicYearLabel: String {
        "\(academicYear) / \(String(format: "%02d", (academicYear + 1) % 100))"
    }

    /// The starting year of an academic year label ("2026 / 27", "2026-2027", "2026/27"), or nil
    /// when the label isn't two consecutive years: a typo must not match the wrong year's recordings.
    public static func normalizedYear(_ value: String) -> Int? {
        let pieces = value.components(separatedBy: .whitespacesAndNewlines).joined().components(separatedBy: CharacterSet(charactersIn: "/-"))
        guard pieces.count == 2, pieces[0].count == 4, let start = Int(pieces[0]), (2000...2099).contains(start),
              let end = Int(pieces[1]), [2, 4].contains(pieces[1].count) else { return nil }
        let fullEnd = pieces[1].count == 2 ? start / 100 * 100 + end : end
        return fullEnd == start + 1 ? start : nil
    }
}

/// One row of the Recman archive. `id` is Recman's `transfer_id`, the only stable identifier a
/// row has; `previewURL` is the row's own link, which leads to the Webex player.
public struct RecmanRecording: Sendable, Equatable, Identifiable {
    public let id: String
    public let courseCode: String
    public let academicYear: Int
    public let title: String
    public let recordedAt: Date
    public let kind: String
    public let duration: String
    public let size: String?
    public let previewURL: URL

    public init(id: String, courseCode: String, academicYear: Int, title: String, recordedAt: Date, kind: String, duration: String, size: String?, previewURL: URL) {
        self.id = id
        self.courseCode = courseCode
        self.academicYear = academicYear
        self.title = title
        self.recordedAt = recordedAt
        self.kind = kind
        self.duration = duration
        self.size = size
        self.previewURL = previewURL
    }
}

/// The only links BeepBar follows from the archive: a row's preview link, and the Webex player it
/// leads to, which opens in the default browser. Both are checked strictly (https, exact host, no
/// credentials or odd port, one well-formed id) because their text comes from a web page.
public enum RecmanURLPolicy {
    public static let archiveHost = "onlineservices.polimi.it"
    public static let archivePath = "/recman_frontend/recman_frontend/controller/ArchivioListActivity.do"

    /// The `transfer_id` of a row's preview link, or nil if the URL is anything else.
    public static func previewTransferID(_ url: URL) -> String? {
        guard let components = safeComponents(url), components.host?.lowercased() == archiveHost, components.path == archivePath else { return nil }
        let items = components.queryItems ?? []
        guard items.contains(where: { $0.name == "evn_preview_link" || ($0.name == "EVN_SHOW_SCREEN" && $0.value == "evn_preview_link") }) else { return nil }
        let ids = items.filter { $0.name == "transfer_id" }.compactMap(\.value)
        guard ids.count == 1, ids[0].range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return ids[0]
    }

    /// `url` if it is a Polimi Webex recording player, nil otherwise.
    public static func playbackURL(_ url: URL) -> URL? {
        guard let components = safeComponents(url), components.host?.lowercased() == "politecnicomilano.webex.com" else { return nil }
        if components.path == "/politecnicomilano/ldr.php" || components.path == "/ldr.php" {
            let ids = (components.queryItems ?? []).filter { $0.name == "RCID" }.compactMap(\.value)
            guard ids.count == 1, ids[0].range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
            return url
        }
        guard components.path.range(of: #"^/recordingservice/(?:[^/]+/)*recording/playback/[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil else { return nil }
        return url
    }

    private static func safeComponents(_ url: URL) -> URLComponents? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil || components.port == 443 else { return nil }
        return components
    }
}

/// Turns the rows the page script extracted (`RecmanScripts.resultsPage` in the app) into recordings.
///
/// The table has no column ids, so cells are read by position, as Recman lays them out:
/// 0 play link · 1 academic year ("2026 / 27") · 2 date ("30/09/2026 12:29", Rome time) ·
/// 3 "058167 - COURSE (TEACHER)" · 4 kind · 5 title · 6 guests · 7 duration ("97 min") · 8 size.
/// A row that doesn't fit makes the whole page fail instead of being skipped: if Recman changes
/// its layout, BeepBar must say it can't read the archive, never show a silently shorter list.
public enum RecmanRecordingParser {
    struct Row: Decodable { let cells: [String]; let previewURL: String }
    public enum ParseError: Error, Equatable { case incompatibleRows }

    /// Every row of one page, newest first, without duplicates; only those of `key` when given.
    public static func decode(_ data: Data, matching key: RecmanCourseKey? = nil) throws -> [RecmanRecording] {
        let decoded = try recordings(JSONDecoder().decode([Row].self, from: data))
        var seen = Set<String>()
        return decoded.filter {
            (key == nil || ($0.courseCode == key!.courseCode && $0.academicYear == key!.academicYear)) && seen.insert($0.id).inserted
        }.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Every row in page order, or `incompatibleRows` if any of them doesn't fit.
    static func recordings(_ rows: [Row]) throws -> [RecmanRecording] {
        let formatter = makeDateFormatter()
        let decoded = rows.compactMap { recording(cells: $0.cells, previewURL: $0.previewURL, formatter: formatter) }
        guard decoded.count == rows.count else { throw ParseError.incompatibleRows }
        return decoded
    }

    /// One row, or nil if any cell the list relies on doesn't have the expected shape.
    public static func recording(cells: [String], previewURL: String) -> RecmanRecording? {
        recording(cells: cells, previewURL: previewURL, formatter: makeDateFormatter())
    }

    private static func recording(cells: [String], previewURL: String, formatter: DateFormatter) -> RecmanRecording? {
        guard cells.count >= 8, let year = RecmanCourseKey.normalizedYear(cells[1]),
              let code = recmanFirstMatch(#"^[0-9]{6}(?=\s*-)"#, in: cells[3].trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = URL(string: previewURL), let id = RecmanURLPolicy.previewTransferID(url) else { return nil }
        let dateText = cells[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = cells[7].trimmingCharacters(in: .whitespacesAndNewlines)
        // Non-lenient and round-tripped, so "31/02/2026" is refused instead of becoming 3 March.
        guard let date = formatter.date(from: dateText), formatter.string(from: date) == dateText,
              duration.range(of: #"^[0-9]+\s*min$"#, options: .regularExpression) != nil else { return nil }
        let size = cells.count > 8 ? cells[8].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return RecmanRecording(id: id, courseCode: code, academicYear: year, title: cells[5].trimmingCharacters(in: .whitespacesAndNewlines), recordedAt: date, kind: cells[4].trimmingCharacters(in: .whitespacesAndNewlines), duration: duration, size: size.isEmpty ? nil : size, previewURL: url)
    }

    /// Recman shows Rome wall-clock times; a fixed POSIX locale keeps the parse independent of the Mac's settings.
    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Rome")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        formatter.isLenient = false
        return formatter
    }
}

func recmanFirstMatch(_ pattern: String, in value: String) -> String? {
    recmanMatches(pattern, in: value).first
}

func recmanMatches(_ pattern: String, in value: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { Range($0.range, in: value).map { String(value[$0]) } }
}
