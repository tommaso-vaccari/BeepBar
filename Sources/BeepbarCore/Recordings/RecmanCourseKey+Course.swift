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
        /// The local folder of each course, as the app already holds it in memory
        /// (`WeBeepAuthenticationController.courseFolders`). Part of the cache key, so renaming a
        /// folder renames the sidebar row, and nothing is read from disk to draw it.
        public var folders: [Int64: String]

        public init(courses: [RemoteCourseSummary], enabledIDs: Set<Int64>, folders: [Int64: String] = [:]) {
            self.courses = courses
            self.enabledIDs = enabledIDs
            self.folders = folders
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let course: RemoteCourseSummary
        public let key: RecmanCourseKey
        public let name: String
        /// What the sidebar row shows: `name`, with the base part replaced by the course's
        /// renamed local folder (`sidebarName`). Titles, headers and lookups keep using `name`.
        public let sidebarName: String
        public var id: Int64 { course.id }
    }

    public struct Unsearchable: Equatable, Sendable, Identifiable {
        public let course: RemoteCourseSummary
        public let name: String
        public let sidebarName: String
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
                let name = Self.courseName(course, key: key)
                searchable.append(Entry(course: course, key: key, name: name, sidebarName: Self.sidebarName(courseName: name, courseDisplayName: course.displayName, courseID: course.id, localFolderName: inputs.folders[course.id])))
            } else {
                let name = Self.courseName(course, key: nil)
                unsearchable.append(Unsearchable(course: course, name: name, sidebarName: Self.sidebarName(courseName: name, courseDisplayName: course.displayName, courseID: course.id, localFolderName: inputs.folders[course.id])))
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

    // MARK: Renamed folders

    /// The part in parentheses at the end of a course name, which on WeBeep is usually the teacher
    /// ("CODE - NAME (Teacher) [2026-27]"; once `courseName` has removed the code and the year
    /// the group is last) but may be a section ("ANALISI 2 (sezione B)"). It is kept or dropped as
    /// a whole, whatever it holds. Only one level of parentheses: a nested group is not matched.
    private static let trailingGroup = try? NSRegularExpression(pattern: #"\s*(\([^()]*\))\s*$"#)

    /// The name the sidebar row shows. `courseName` is the cleaned name (`courseName(_:)`),
    /// `courseDisplayName` the raw WeBeep one the default folder is derived from
    /// (`LocalPathPolicy.defaultCourseFolder`), `localFolderName` the folder BeepBar syncs into.
    ///
    /// The student may rename that folder to something short ("GAL"); the row then follows it, but
    /// keeps the teacher, who tells apart two courses with the same name: "Geometria algebra
    /// lineare (Claude Sonnet)" with the folder "GAL" reads "GAL (Claude Sonnet)".
    ///
    /// The cleaned name is returned unchanged when there is no folder (nil, empty, blank) or when
    /// the folder matches a generated name (`renamedFolder`). Anything else is the student's
    /// choice. Only the trailing parenthesised part is kept ("A (B) (C)" keeps "(C)"); a folder
    /// that already ends with that part is not given it twice. Pure and total: odd input yields
    /// the cleaned name or the folder.
    public static func sidebarName(courseName: String, courseDisplayName: String, courseID: Int64, localFolderName: String?) -> String {
        guard let folder = renamedFolder(courseDisplayName: courseDisplayName, courseID: courseID, localFolderName: localFolderName) else { return courseName }
        let key = PathKey.of(folder)
        guard let teacher = teacherGroup(of: courseName) else { return folder }
        if key.hasSuffix(PathKey.of(teacher)) { return folder }
        return "\(folder) \(teacher)"
    }

    /// The name the status-bar menu shows for a course: the renamed folder alone, no teacher (a
    /// menu line is a glance and must stay short), else the cleaned name without its trailing
    /// teacher group. Same "renamed" rule as `sidebarName`. A name that is only a group, or has
    /// none, is returned as it is.
    public static func menuName(courseName: String, courseDisplayName: String, courseID: Int64, localFolderName: String?) -> String {
        if let folder = renamedFolder(courseDisplayName: courseDisplayName, courseID: courseID, localFolderName: localFolderName) { return folder }
        guard teacherGroup(of: courseName) != nil, let trailingGroup else { return courseName }
        let stripped = trailingGroup.stringByReplacingMatches(in: courseName, range: NSRange(courseName.startIndex..., in: courseName), withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let folderTeacherGroup = try? NSRegularExpression(pattern: #"\s+\([^()]*\)(?=\s*(?:\[[^\]]*\])?\s*$)"#)

    /// Match generated names, not their character shape: lowercase custom names are valid.
    /// A historical default that cannot be derived from the current course is kept as its name.
    private static func renamedFolder(courseDisplayName: String, courseID: Int64, localFolderName: String?) -> String? {
        guard let folder = localFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty else { return nil }
        let key = PathKey.of(folder)
        let withoutTeacher = folderTeacherGroup?.stringByReplacingMatches(in: courseDisplayName, range: NSRange(courseDisplayName.startIndex..., in: courseDisplayName), withTemplate: "") ?? courseDisplayName
        let generated = [courseDisplayName, withoutTeacher].flatMap { name in
            let plain = LocalPathPolicy.defaultCourseFolder(name)
            let whole = LocalPathPolicy.courseFolderSlug(name)
            return [plain, whole, LocalPathPolicy.courseFolder(plain, disambiguatedBy: courseID), LocalPathPolicy.courseFolder(whole, disambiguatedBy: courseID)]
        }
        if generated.contains(where: { PathKey.of($0) == key }) { return nil }
        if let counter = folder.split(separator: "-").last.flatMap({ Int64($0) }), counter >= 2,
           generated.filter({ $0.hasSuffix("-\(courseID)") }).contains(where: { PathKey.of(LocalPathPolicy.courseFolder($0, disambiguatedBy: counter)) == key }) { return nil }
        if LocalPathPolicy.generatedCourseFolderReplacement(storedFolder: folder, storedCourseName: courseDisplayName, currentCourseName: courseDisplayName, courseID: courseID) != nil { return nil }
        return folder
    }

    /// The teacher group of a cleaned name, nil when there is none or the name is only that group.
    private static func teacherGroup(of name: String) -> String? {
        guard let trailingGroup else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = trailingGroup.firstMatch(in: name, range: range),
              let whole = Range(match.range, in: name), let group = Range(match.range(at: 1), in: name),
              !name[..<whole.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(name[group])
    }
}
