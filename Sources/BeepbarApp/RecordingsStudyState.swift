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

    /// What the Watchlist lists: the archive bookmarks plus the bookmarked Webex lessons, each
    /// as a `Bookmark` of its synthetic row, filtered and sorted like `visibleBookmarks`. A manual
    /// lesson without a course label shows `fallbackCourseName` ("Link Webex", resolved by the
    /// caller in the current language), which search matches too.
    nonisolated func watchlistEntries(manual: ManualWebexLessons, visibleCourseIDs: Set<Int64> = [], fallbackCourseName: String, query: String) -> [Bookmark] {
        var combined = self
        combined.bookmarks += manual.lessons.filter { Self.showsInWatchlist($0, visibleCourseIDs: visibleCourseIDs) }.map {
            Bookmark(recording: $0.recording, courseName: $0.courseName.isEmpty ? fallbackCourseName : $0.courseName)
        }
        return combined.visibleBookmarks(query: query)
    }

    struct WatchlistSection: Identifiable {
        enum ID: Hashable { case archive(String, Int), course(Int64), unassigned }
        let id: ID
        let title: String
        var bookmarks: [Bookmark]
    }

    /// Keep archive identities distinct even when course titles coincide; only map a course ID
    /// to an archive key when that mapping is unambiguous.
    nonisolated static func watchlistSections(_ entries: [Bookmark], manual: ManualWebexLessons,
                                               courses: [RemoteCourseSummary], fallback: String) -> [WatchlistSection] {
        let manualByID = Dictionary(manual.lessons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byKey = Dictionary(grouping: courses.compactMap { course in
            RecmanCourseKey(course: course).map { ($0, course) }
        }, by: { $0.0 })
        var sections: [WatchlistSection.ID: WatchlistSection] = [:]
        for bookmark in entries {
            let id: WatchlistSection.ID
            if let lesson = manualByID[bookmark.recording.id], ManualWebexLesson.isManual(bookmark.recording) {
                if let courseID = lesson.courseID {
                    if let course = courses.first(where: { $0.id == courseID }), let key = RecmanCourseKey(course: course),
                       Set((byKey[key] ?? []).map { $0.1.id }).count == 1 {
                        id = .archive(key.courseCode, key.academicYear)
                    } else { id = .course(courseID) }
                } else { id = .unassigned }
            } else {
                id = .archive(bookmark.recording.courseCode, bookmark.recording.academicYear)
            }
            if sections[id] == nil {
                let title = id == .unassigned ? fallback : bookmark.courseName
                sections[id] = WatchlistSection(id: id, title: title, bookmarks: [])
            }
            sections[id]?.bookmarks.append(bookmark)
        }
        return sections.values.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return String(describing: $0.id) < String(describing: $1.id)
        }
    }

    /// A linked lesson without a visible course needs a row even if it was previously unbookmarked.
    nonisolated static func showsInWatchlist(_ lesson: ManualWebexLesson, visibleCourseIDs: Set<Int64>) -> Bool {
        guard let courseID = lesson.courseID else { return true }
        return lesson.isWatchlisted || !visibleCourseIDs.contains(courseID)
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
    func stream(for recording: RecmanRecording, email: PolimiEmail?) async throws -> RecordingStream { throw RecmanBrowserError.playbackUnavailable }
}
#endif
