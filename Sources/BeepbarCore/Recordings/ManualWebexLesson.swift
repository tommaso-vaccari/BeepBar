import Foundation

/// A lesson the student added to the Watchlist by pasting a Webex link, for recordings Recman
/// doesn't list (a guest lecture, a recording shared by the teacher, a course of another year).
///
/// Stored apart from `RecordingsStudyState` (its own UserDefaults key, see
/// `RecordingsController.manualLessonsKey`), never as a `Bookmark`: an older BeepBar re-encodes
/// the study state with only the fields it knows, so a new field there would be silently dropped
/// by a rollback, while a key it doesn't know is never touched.
///
/// The rest of Recordings (rows, player, resume points) works on `RecmanRecording`, so a lesson
/// is shown and played through `recording`, a synthetic row whose course code (`courseCode`) is
/// not six digits. That keeps it out of everything keyed by course: `RecmanCourseKey` refuses
/// it, so no archive listing is ever requested for it, `RecordingsStudyState.reconcile` never
/// marks it unavailable, it is never acknowledged as seen and never reaches the menu bar.
public struct ManualWebexLesson: Codable, Equatable, Sendable, Identifiable {
    /// `idPrefix` + a lowercase UUID, minted when the lesson is added. Its own namespace, so it
    /// can't collide with a Recman `transfer_id` in resume points or watch progress.
    public let id: String
    /// What the student typed, trimmed; empty means "no title" (shown as `kind`).
    public var title: String
    /// The optional label shown where a course name would be; empty means none.
    public var courseName: String
    /// The Webex player link, as `normalizedLink` accepted it.
    public let link: URL
    public let addedAt: Date

    /// The course code of every manual lesson's `recording`: deliberately not six digits.
    public static let courseCode = "manual"
    public static let idPrefix = "manual-"
    /// Longest title or course label kept, so a pasted page can't bloat the settings file.
    public static let maxTextLength = 200

    public init(id: String = ManualWebexLesson.idPrefix + UUID().uuidString.lowercased(), title: String, courseName: String, link: URL, addedAt: Date) {
        self.id = id
        self.title = Self.cleaned(title)
        self.courseName = Self.cleaned(courseName)
        self.link = link
        self.addedAt = addedAt
    }

    /// The row the Watchlist and the player work with. `kind` "Webex" is what an untitled lesson
    /// shows (`RecmanPresentation.title`); the duration is unknown until the player reads it.
    public var recording: RecmanRecording {
        RecmanRecording(id: id, courseCode: Self.courseCode, academicYear: 0, title: title, recordedAt: addedAt,
                        kind: "Webex", duration: "", size: nil, previewURL: link)
    }

    /// Whether `recording` is a manual lesson's row whose link is still one BeepBar follows.
    /// Checked at the point of action (`playerLink(for:)`), since the row may come back from disk.
    public static func isManual(_ recording: RecmanRecording) -> Bool {
        recording.courseCode == courseCode && recording.id.hasPrefix(idPrefix)
    }

    /// The Webex player link of a manual lesson's row, nil for an archive row or a link
    /// `RecmanURLPolicy` no longer accepts: the archive is never involved for these.
    public static func playerLink(for recording: RecmanRecording) -> URL? {
        guard isManual(recording) else { return nil }
        return RecmanURLPolicy.playbackURL(recording.previewURL)
    }

    /// The player link in `text`, or nil when it isn't a link to a recording on Polimi's Webex
    /// site. Surrounding whitespace (a copied line) is ignored. Accepted as `RecmanURLPolicy`
    /// accepts it (`ldr.php?RCID=…`, `/recordingservice/…/recording/playback/<id>`), plus the share
    /// form `/<app>/sites/<site>/recording/<uuid>/playback`, rewritten to the playback form the
    /// stream resolver reads (`WebexPlayerLink.playbackPage`). `<app>` is `recordingservice` or
    /// `webappng`, the path of Webex's newer web app, which is what the address bar shows when a
    /// student opens a recording there (a valid link was refused before, 2026-11-09). Only that
    /// exact shape and a 32-hex uuid are rewritten; anything else is refused rather than guessed.
    public static func normalizedLink(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return nil }
        if let accepted = RecmanURLPolicy.playbackURL(url) { return accepted }
        guard var components = WebexSite.safeComponents(url), components.host == WebexSite.host else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var trimmedSegments = segments
        if trimmedSegments.last == "" { trimmedSegments.removeLast() }
        guard trimmedSegments.count == 7, trimmedSegments[0] == "", shareApps.contains(trimmedSegments[1]), trimmedSegments[2] == "sites",
              trimmedSegments[3] == WebexSite.name, trimmedSegments[4] == "recording", trimmedSegments[6] == "playback",
              trimmedSegments[5].range(of: WebexPlayerLink.uuidPattern, options: .regularExpression) != nil else { return nil }
        components.percentEncodedPath = "/recordingservice/sites/\(WebexSite.name)/recording/playback/\(trimmedSegments[5])"
        components.fragment = nil
        guard let rewritten = components.url else { return nil }
        return RecmanURLPolicy.playbackURL(rewritten)
    }

    /// The first path segment of the share forms `normalizedLink` rewrites.
    static let shareApps: Set<String> = ["recordingservice", "webappng"]

    static func cleaned(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextLength))
    }
}

/// Every manual lesson of one account, in the order they were added.
public struct ManualWebexLessons: Codable, Equatable, Sendable {
    public var lessons: [ManualWebexLesson] = []

    public init(lessons: [ManualWebexLesson] = []) { self.lessons = lessons }

    public enum AddError: Error, Equatable {
        /// Not a Polimi Webex recording link (`ManualWebexLesson.normalizedLink`).
        case invalidLink
        /// The same player link is already in the list.
        case duplicate
    }

    /// Adds the lesson at `text`, or says why not. Duplicates compare the normalized link, so the
    /// share form and the playback form of one recording are the same lesson.
    @discardableResult
    public mutating func add(link text: String, title: String, courseName: String, now: Date = Date()) throws -> ManualWebexLesson {
        guard let link = ManualWebexLesson.normalizedLink(text) else { throw AddError.invalidLink }
        guard !lessons.contains(where: { $0.link == link }) else { throw AddError.duplicate }
        let lesson = ManualWebexLesson(title: title, courseName: courseName, link: link, addedAt: now)
        lessons.append(lesson)
        return lesson
    }

    public mutating func remove(id: String) {
        lessons.removeAll { $0.id == id }
    }

    public func contains(id: String) -> Bool {
        lessons.contains { $0.id == id }
    }
}
