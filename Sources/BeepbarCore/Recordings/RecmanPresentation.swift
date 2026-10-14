import Foundation

/// How the Recordings page reads a list of recordings: weeks, lesson numbers, durations, search.
/// Kept in Core so the derivations below can be cached by their inputs and tested without SwiftUI
/// (#100); the app's `RecordingsPresentation` forwards to these. Pure functions of their
/// arguments, except that the week titles go through `tr`, which reads `AppLanguage.current`.
public enum RecmanPresentation {
    public struct WeekSection: Equatable, Sendable {
        public let title: String
        public let recordings: [RecmanRecording]

        public init(title: String, recordings: [RecmanRecording]) {
            self.title = title
            self.recordings = recordings
        }
    }

    /// Weeks start on Monday, as Polimi's timetable does, whatever the Mac's region says.
    public static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = timeZone
        return calendar
    }

    /// The minutes in Recman's duration ("97 min"); the parser accepts no other shape. Delegates to
    /// `RecmanRecording.minutes(inDuration:)` so the course header's total, the row and the
    /// hours-left estimate read the same number, and an implausible length never traps the sum.
    public static func minutes(_ duration: String) -> Int? {
        RecmanRecording.minutes(inDuration: duration)
    }

    /// "45 min", "1 h 37 min", "36 h".
    public static func durationText(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Newest first, grouped by calendar week: "Questa settimana", "Settimana scorsa", then the
    /// week's dates ("14 – 20 set"), with the year only when it isn't the current one.
    public static func weekSections(_ recordings: [RecmanRecording], now: Date, calendar: Calendar, locale: Locale) -> [WeekSection] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)
        var sections: [(start: Date, recordings: [RecmanRecording])] = []
        for recording in recordings.sorted(by: { $0.recordedAt > $1.recordedAt }) {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: recording.recordedAt)?.start else { continue }
            if sections.last?.start == start {
                sections[sections.count - 1].recordings.append(recording)
            } else {
                sections.append((start, [recording]))
            }
        }
        return sections.map { section in
            let title: String
            if section.start == thisWeek {
                title = tr("Questa settimana", "This week")
            } else if section.start == lastWeek {
                title = tr("Settimana scorsa", "Last week")
            } else {
                title = weekRange(from: section.start, now: now, calendar: calendar, locale: locale)
            }
            return WeekSection(title: title, recordings: section.recordings)
        }
    }

    public static func weekRange(from start: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        var style = Date.FormatStyle(timeZone: calendar.timeZone).day().month(.abbreviated).locale(locale)
        if calendar.component(.year, from: end) != calendar.component(.year, from: now) { style = style.year() }
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let startText = sameMonth ? Date.FormatStyle(timeZone: calendar.timeZone).day().locale(locale).format(start) : style.format(start)
        return "\(startText) – \(style.format(end))"
    }

    /// Each recording's place in its course, oldest first, as students count lessons ("#12").
    public static func numbers(_ recordings: [RecmanRecording]) -> [String: Int] {
        let ordered = recordings.sorted { ($0.recordedAt, $0.id) < ($1.recordedAt, $1.id) }
        return Dictionary(ordered.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
    }

    /// What a row is called: Recman's title, or the kind of lesson when the teacher left it empty.
    public static func title(_ recording: RecmanRecording) -> String {
        recording.title.isEmpty ? recording.kind : recording.title
    }

    public static func matches(_ recording: RecmanRecording, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return recording.title.localizedStandardContains(needle) || recording.kind.localizedStandardContains(needle)
    }
}

/// What the course pane shows about a listing whatever the search: the total duration in the
/// header and each lesson's number. Derived once per listing (#100), so typing in the search,
/// which only changes `RecmanCourseListDerivation`, never re-sorts the whole list again.
public struct RecmanCourseListSummary: Equatable, Sendable {
    /// The sum of every recording's minutes, for the header; zero when no duration parsed.
    public let totalMinutes: Int
    /// Lesson numbers over the whole list, so a search doesn't renumber the lessons it shows.
    public let numbers: [String: Int]

    public init(_ recordings: [RecmanRecording]) {
        totalMinutes = recordings.compactMap { RecmanPresentation.minutes($0.duration) }.reduce(0, +)
        numbers = RecmanPresentation.numbers(recordings)
    }
}

/// What the course pane shows of a listing for the current search: the matching rows, grouped by
/// week, and the rows by id. Computed once per change of `Inputs` and held by a
/// `DerivedValueCache` in the view, instead of once per `body` (#100).
public struct RecmanCourseListDerivation: Equatable, Sendable {
    /// What the derivation depends on, and so what invalidates it. Leaving one out shows stale
    /// content: the week titles follow the language, the week boundaries the time zone,
    /// "this week" and the year suffix the day.
    public struct Inputs: Equatable, Sendable {
        /// The course's recordings as listed. Comparing two arrays that share storage is O(1), and
        /// `DerivedValueCache` keeps the latest equal input, so a refetch with the same content
        /// costs one element comparison and later evaluations none.
        public var recordings: [RecmanRecording]
        public var query: String
        /// Must be `AppLanguage.current`: the dates of older weeks are written in this language,
        /// but "Questa settimana" and "Settimana scorsa" come from `tr`, which reads the global.
        /// Part of the key so that a language switch derives the titles again.
        public var language: AppLanguage
        public var timeZoneIdentifier: String
        /// The start of "today" in that zone: the sections depend on `now` only through the
        /// week it falls in and its year, so any moment of the same day derives the same thing.
        public var day: Date

        public init(recordings: [RecmanRecording], query: String, language: AppLanguage, timeZone: TimeZone, now: Date) {
            self.recordings = recordings
            self.query = query
            self.language = language
            timeZoneIdentifier = timeZone.identifier
            day = RecmanPresentation.calendar(timeZone: timeZone).startOfDay(for: now)
        }
    }

    /// The recordings matching the query, in listing order.
    public let shown: [RecmanRecording]
    public let sections: [RecmanPresentation.WeekSection]
    /// `shown` by id, for the list's selection-based actions.
    public let byID: [String: RecmanRecording]

    public init(_ inputs: Inputs) {
        shown = inputs.recordings.filter { RecmanPresentation.matches($0, query: inputs.query) }
        let zone = TimeZone(identifier: inputs.timeZoneIdentifier) ?? .current
        sections = RecmanPresentation.weekSections(shown, now: inputs.day, calendar: RecmanPresentation.calendar(timeZone: zone), locale: inputs.language.locale)
        byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
