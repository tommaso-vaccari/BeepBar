import Foundation
import BeepbarCore

/// A navigation choice inside Registrazioni; unlike a course ID, Watchlist spans all courses.
enum RecordingsDestination: Codable, Hashable {
    case watchlist
    case course(Int64)
}

/// Personal study choices belong to an account, not to the expiring Polimi browser session.
/// Bookmarks retain metadata so the global list is useful before courses are loaded again.
struct RecordingsStudyState: Codable, Equatable {
    struct Bookmark: Codable, Equatable, Identifiable {
        var recording: RecmanRecording
        var courseName: String
        var unavailable = false
        var id: String { RecordingsStudyState.identity(recording) }
    }

    var bookmarks: [Bookmark] = []
    var destination: RecordingsDestination?

    /// Course and year keep reused remote identifiers from sharing personal state.
    nonisolated static func identity(_ recording: RecmanRecording) -> String {
        "\(recording.academicYear):\(recording.courseCode):\(recording.id)"
    }

    nonisolated func contains(_ recording: RecmanRecording) -> Bool {
        bookmarks.contains { $0.id == Self.identity(recording) }
    }

    /// Search includes the course name and preserves bookmarks outside the current results.
    nonisolated func visibleBookmarks(query: String) -> [Bookmark] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return bookmarks.filter {
            (needle.isEmpty || $0.courseName.localizedStandardContains(needle) || RecordingsPresentation.matches($0.recording, query: needle))
        }.sorted {
            if $0.recording.recordedAt != $1.recording.recordedAt { return $0.recording.recordedAt > $1.recording.recordedAt }
            return $0.id < $1.id
        }
    }

    /// Only a complete, successful listing can mark an old bookmark unavailable. Never delete it.
    nonisolated mutating func reconcile(_ recordings: [RecmanRecording], for key: RecmanCourseKey) {
        let current = Dictionary(recordings.map { (Self.identity($0), $0) }, uniquingKeysWith: { first, _ in first })
        for index in bookmarks.indices where bookmarks[index].recording.courseCode == key.courseCode && bookmarks[index].recording.academicYear == key.academicYear {
            if let fresh = current[bookmarks[index].id] {
                bookmarks[index].recording = fresh
                bookmarks[index].unavailable = false
            } else {
                bookmarks[index].unavailable = true
            }
        }
    }
}

#if DEBUG
/// Deterministic lessons for the isolated --ui-preview --watchlist-preview demo; no Polimi requests.
@MainActor final class WatchlistPreviewBrowser: RecmanBrowsing {
    static let courseNames = ["058167 - NUMERICAL LINEAR ALGEBRA [2026-27]", "052499 - HIGH PERFORMANCE COMPUTING [2026-27]", "099999 - COMPILERS [2026-27]"]
    var isOpen = false
    func open(cookies: [HTTPCookie]) async { isOpen = true }
    func cookies() async -> [HTTPCookie] { [] }
    func signIn() async throws {}
    func close() { isOpen = false }

    static func lessons(for key: RecmanCourseKey) -> [RecmanRecording] {
        let titles = key.courseCode == "058167" ? ["Sparse matrices and CSR", "Krylov methods", "Preconditioning"] :
            key.courseCode == "052499" ? ["Parallel decomposition", "GPU memory hierarchy", "Performance profiling"] :
            ["Lexical analysis", "Parsing", "Intermediate representations"]
        return titles.enumerated().map { index, title in
            let id = "demo-\(key.courseCode)-\(index)"
            return RecmanRecording(id: id, courseCode: key.courseCode, academicYear: key.academicYear,
                title: title, recordedAt: Date(timeIntervalSince1970: 1_791_000_000 - Double(index) * 86_400),
                kind: "Lezione", duration: "\(60 + index * 15) min", size: nil,
                previewURL: URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=&transfer_id=\(id)")!)
        }
    }
    func recordings(for key: RecmanCourseKey) async throws -> [RecmanRecording] { Self.lessons(for: key) }
    func playbackURL(for recording: RecmanRecording) async throws -> URL { throw RecmanBrowserError.playbackUnavailable }
}
#endif
