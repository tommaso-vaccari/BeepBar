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
