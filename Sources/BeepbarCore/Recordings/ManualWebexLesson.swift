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
    /// The lesson's length in seconds, as Webex's stream answer gave it at a Play; nil until
    /// then. Shown as the row's length and used for the hours left, like Recman's minutes.
    public var durationSeconds: Double?
    /// How much of it was watched, and whether it is done: the same entry and rules
    /// (`RecordingWatchProgress`) as an archive lecture's, kept here because the store's
    /// `progress` table is keyed by course (`RecmanCourseKey`), which a manual lesson has none of.
    /// Nil while untouched.
    public var progress: RecordingWatchEntry?

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

    /// `durationSeconds` and `progress` were added after the first lessons were saved (by a
    /// build that never shipped, 2026-11-09): absent, they decode as nil. Each is decoded on
    /// its own and a damaged one reads as nil, so it costs that lesson's length or progress,
    /// never every lesson (an undecodable list is shown as none, `manualLessonsUnreadable`).
    /// A rollback to that build drops both fields at its next save; the lessons stay.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        courseName = try container.decode(String.self, forKey: .courseName)
        link = try container.decode(URL.self, forKey: .link)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        durationSeconds = (try? container.decodeIfPresent(Double.self, forKey: .durationSeconds)).flatMap { $0 }.flatMap(Self.plausibleDuration)
        progress = (try? container.decodeIfPresent(RecordingWatchEntry.self, forKey: .progress)).flatMap { $0 }
    }

    /// The row the Watchlist and the player work with. `kind` "Webex" is what an untitled lesson
    /// shows (`RecmanPresentation.title`). The duration is Recman's form ("97 min",
    /// `RecmanRecording.minutes`) once a Play has read it, empty until then.
    public var recording: RecmanRecording {
        let minutes = durationSeconds.map { Int(($0 / 60).rounded()) }
        return RecmanRecording(id: id, courseCode: Self.courseCode, academicYear: 0, title: title, recordedAt: addedAt,
                               kind: "Webex", duration: minutes.map { "\($0) min" } ?? "", size: nil, previewURL: link)
    }

    /// What a Play learned from Webex's answer: its title when the student gave none, and the
    /// length. A title the student typed is never replaced. Returns whether anything changed.
    @discardableResult
    public mutating func learn(title streamTitle: String?, duration: Double?) -> Bool {
        var changed = false
        if title.isEmpty, let streamTitle, case let cleaned = Self.cleaned(streamTitle), !cleaned.isEmpty {
            title = cleaned
            changed = true
        }
        if let duration = duration.flatMap(Self.plausibleDuration), duration != durationSeconds {
            durationSeconds = duration
            changed = true
        }
        return changed
    }

    /// A length taken at face value: finite, positive, at most a day
    /// (`RecmanRecording.maxPlausibleMinutes`); anything else is an unknown length.
    static func plausibleDuration(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds > 0 && seconds <= Double(RecmanRecording.maxPlausibleMinutes * 60) ? seconds : nil
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
    /// The result is `canonical`: rebuilt from the recording id alone, so whatever else the
    /// address bar carried (tracking parameters, a fragment, a trailing slash) is neither stored
    /// nor handed back by "Copy link", and two pastes of one recording compare equal.
    public static func normalizedLink(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return nil }
        if let accepted = RecmanURLPolicy.playbackURL(url) { return canonical(accepted) }
        guard var components = WebexSite.safeComponents(url), components.host == WebexSite.host else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var trimmedSegments = segments
        if trimmedSegments.last == "" { trimmedSegments.removeLast() }
        guard trimmedSegments.count == 7, trimmedSegments[0] == "", shareApps.contains(trimmedSegments[1]), trimmedSegments[2] == "sites",
              trimmedSegments[3] == WebexSite.name, trimmedSegments[4] == "recording", trimmedSegments[6] == "playback",
              trimmedSegments[5].range(of: WebexPlayerLink.uuidPattern, options: .regularExpression) != nil else { return nil }
        components.percentEncodedPath = "/recordingservice/sites/\(WebexSite.name)/recording/playback/\(trimmedSegments[5])"
        components.fragment = nil
        guard let rewritten = components.url, let accepted = RecmanURLPolicy.playbackURL(rewritten) else { return nil }
        return canonical(accepted)
    }

    /// The one form of a link `RecmanURLPolicy.playbackURL` accepted, built from its recording id:
    /// `ldr.php` keeps its path and only `RCID`; a playback page with a Webex uuid becomes
    /// `/recordingservice/sites/<site>/recording/playback/<uuid>`; any other accepted playback
    /// path keeps its path without a trailing slash. No query (but `RCID`), no fragment. Also the
    /// key `ManualWebexLessons.add` compares, applied to stored links too, so a lesson saved
    /// before this form existed (query kept as pasted) still refuses its duplicate without being
    /// rewritten on disk. Nil for a link the policy refuses.
    /// Deliberately not merged: a uuid in other letter case, or the same `RCID` under two loader
    /// paths. Whether Webex treats them as one recording is not known (never checked on real
    /// data), and a wrong merge would refuse a different lesson as a duplicate; at worst the
    /// student sees the same lesson twice and removes one.
    static func canonical(_ url: URL) -> URL? {
        guard RecmanURLPolicy.playbackURL(url) != nil, let components = WebexSite.safeComponents(url) else { return nil }
        var rebuilt = URLComponents()
        rebuilt.scheme = "https"
        rebuilt.host = WebexSite.host
        if WebexPlayerLink.isLoader(url) {
            guard let id = components.queryItems?.first(where: { $0.name == "RCID" })?.value else { return nil }
            rebuilt.path = components.path
            rebuilt.queryItems = [URLQueryItem(name: "RCID", value: id)]
        } else if let page = WebexPlayerLink.playbackPage(fromPlayerURL: url) {
            rebuilt.percentEncodedPath = "/recordingservice/sites/\(WebexSite.name)/recording/playback/\(page.uuid)"
        } else {
            var path = components.percentEncodedPath
            if path.hasSuffix("/") { path.removeLast() }
            rebuilt.percentEncodedPath = path
        }
        return rebuilt.url
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

    /// Adds the lesson at `text`, or says why not. Duplicates compare canonical links
    /// (`ManualWebexLesson.canonical`) on both sides, so the share form, the playback form and a
    /// copy with other parameters of one recording are the same lesson, including against a
    /// lesson stored by an earlier build with its query as pasted.
    @discardableResult
    public mutating func add(link text: String, title: String, courseName: String, now: Date = Date()) throws -> ManualWebexLesson {
        guard let link = ManualWebexLesson.normalizedLink(text) else { throw AddError.invalidLink }
        guard !lessons.contains(where: { ManualWebexLesson.canonical($0.link) == link }) else { throw AddError.duplicate }
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

    /// The lesson `id`, nil when it isn't in the list.
    public func lesson(id: String) -> ManualWebexLesson? {
        lessons.first { $0.id == id }
    }

    /// The same lessons with their watch progress forgotten; titles and lengths stay. What
    /// forgetting the account's history does to lessons added by link (the Watchlist itself
    /// survives it, its progress does not).
    public func forgettingProgress() -> ManualWebexLessons {
        ManualWebexLessons(lessons: lessons.map { var lesson = $0; lesson.progress = nil; return lesson })
    }

    /// Replaces the lesson with the same id; false when it isn't in the list (removed meanwhile).
    @discardableResult
    public mutating func replace(_ lesson: ManualWebexLesson) -> Bool {
        guard let index = lessons.firstIndex(where: { $0.id == lesson.id }) else { return false }
        lessons[index] = lesson
        return true
    }
}
