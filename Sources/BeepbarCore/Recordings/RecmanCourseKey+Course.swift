import Foundation

// Kept apart from RecmanRecording.swift because it is the only Recordings code that needs another
// Core type (`RemoteCourseSummary`): the rest compiles on its own into `scripts/recman-probe`.

extension RecmanCourseKey {
    /// The Recman search for a WeBeep course, read from its names: Polimi courses are named
    /// "058167 - NUMERICAL LINEAR ALGEBRA [2026-27]". Nil unless both names agree on exactly one
    /// code and one year: guessing could show another course's or another year's recordings.
    public init?(course: RemoteCourseSummary) {
        let names = [course.shortName, course.displayName]
        let codes = Set(names.flatMap { recmanMatches(#"^\s*[0-9]{6}(?=\s*-)"#, in: $0).map { $0.trimmingCharacters(in: .whitespaces) } })
        let yearLabels = names.flatMap { recmanMatches(#"(?<![0-9])20[0-9]{2}\s*[-/]\s*(?:20[0-9]{2}|[0-9]{2})(?![0-9])"#, in: $0) }
        let normalizedYears = yearLabels.compactMap(Self.normalizedYear)
        let years = Set(normalizedYears)
        // Every year-looking label must be valid: "[2026-28]" next to "[2025-26]" is not "2025".
        guard codes.count == 1, years.count == 1, normalizedYears.count == yearLabels.count,
              let code = codes.first, let year = years.first else { return nil }
        self.init(courseCode: code, academicYear: year)
    }
}

/// The Recordings sidebar, derived once per change of the synced courses instead of once per
/// `body` (#100): each course's archive key costs two regular expressions per name, and its
/// display name two more, so a page with many courses paid that on every controller publication.
public struct RecmanCourseSidebar: Equatable, Sendable {
    public struct Inputs: Equatable, Sendable {
        public var courses: [RemoteCourseSummary]
        public var enabledIDs: Set<Int64>

        public init(courses: [RemoteCourseSummary], enabledIDs: Set<Int64>) {
            self.courses = courses
            self.enabledIDs = enabledIDs
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let course: RemoteCourseSummary
        public let key: RecmanCourseKey
        public let name: String
        public var id: Int64 { course.id }
    }

    public struct Unsearchable: Equatable, Sendable, Identifiable {
        public let course: RemoteCourseSummary
        public let name: String
        public var id: Int64 { course.id }
    }

    /// The synced courses, in WeBeep's order.
    public let courses: [RemoteCourseSummary]
    /// Those with a code and a year, so the archive can be searched.
    public let searchable: [Entry]
    /// The rest, shown so the user knows why they can't be searched.
    public let unsearchable: [Unsearchable]
    public let keys: [RecmanCourseKey]

    public init(_ inputs: Inputs) {
        courses = inputs.courses.filter { inputs.enabledIDs.contains($0.id) }
        var searchable: [Entry] = []
        var unsearchable: [Unsearchable] = []
        for course in courses {
            if let key = RecmanCourseKey(course: course) {
                searchable.append(Entry(course: course, key: key, name: Self.courseName(course, key: key)))
            } else {
                unsearchable.append(Unsearchable(course: course, name: Self.courseName(course, key: nil)))
            }
        }
        self.searchable = searchable
        self.unsearchable = unsearchable
        keys = searchable.map(\.key)
    }

    /// The course to show: the chosen one, else the first searchable one, else the first.
    public func selectedCourse(id selectedID: Int64?) -> RemoteCourseSummary? {
        courses.first { $0.id == selectedID } ?? searchable.first?.course ?? courses.first
    }

    /// Hide recognized archive identifiers without changing the course's wording or acronyms.
    public static func courseName(_ course: RemoteCourseSummary) -> String {
        courseName(course, key: RecmanCourseKey(course: course))
    }

    private static func courseName(_ course: RemoteCourseSummary, key: RecmanCourseKey?) -> String {
        let displayName = course.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.isEmpty ? course.shortName.trimmingCharacters(in: .whitespacesAndNewlines) : displayName
        guard let key else { return name }
        let nextYear = key.academicYear + 1
        let year = "\(key.academicYear)\\s*[-/]\\s*(?:\(nextYear)|\(String(format: "%02d", nextYear % 100)))"
        let suffix = "\\s*(?:\\[\\s*\(year)\\s*\\]|\\(\\s*\(year)\\s*\\))\\s*$"
        let cleaned = name
            .replacingOccurrences(of: #"^\s*[0-9]{6}\s*-\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: suffix, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? name : cleaned
    }
}
