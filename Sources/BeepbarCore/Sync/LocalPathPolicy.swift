import CryptoKit
import Foundation

public enum LocalPathPolicyError: Error, Sendable, Equatable {
    case invalidRemotePath
}

public enum LocalPathPolicy {
    // Compiled once: `defaultCourseFolder` runs for every course each time the folder map is
    // rebuilt, and an `NSRegularExpression` is immutable, so one shared instance is safe.
    private static let forkStyleCourseName = try? NSRegularExpression(pattern: "\\d+ - (.+) \\(.+\\)")
    private static let unipdCourseSuffix = try? NSRegularExpression(
        pattern: "\\s+\\d{4}-\\d{4}\\s+-\\s+INQ\\d+\\s*$",
        options: [.caseInsensitive]
    )

    public static func defaultCourseFolder(_ courseName: String) -> String {
        courseSlug(courseLabel(courseName))
    }

    public static func courseFolderSlug(_ courseName: String) -> String {
        courseSlug(courseName)
    }

    /// `folder` made unique by the course's Moodle ID, for when two courses would otherwise
    /// get the same folder (identical names, or a name matching another course's folder).
    /// Only the ID is guaranteed to differ between two courses, so nothing derived from the
    /// name alone can separate them (ultrareview finding on `defaultFolders`).
    public static func courseFolder(_ folder: String, disambiguatedBy courseID: Int64) -> String {
        limited("\(folder)-\(courseID)")
    }

    private static func courseLabel(_ courseName: String) -> String {
        let range = NSRange(courseName.startIndex..., in: courseName)
        if let match = forkStyleCourseName?.firstMatch(in: courseName, range: range), let captured = Range(match.range(at: 1), in: courseName) {
            return String(courseName[captured])
        }
        return unipdCourseSuffix?.stringByReplacingMatches(in: courseName, range: range, withTemplate: "") ?? courseName
    }

    private static func courseSlug(_ courseName: String) -> String {
        var slug = ""
        var needsSeparator = false
        for scalar in courseName.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                needsSeparator = false
            } else if !slug.isEmpty {
                needsSeparator = true
            }
        }
        return limited(slug.isEmpty ? "_" : slug)
    }

    private static func legacyCourseFolder(_ courseName: String) -> String {
        let range = NSRange(courseName.startIndex..., in: courseName)
        if let match = forkStyleCourseName?.firstMatch(in: courseName, range: range), let captured = Range(match.range(at: 1), in: courseName) {
            return component(String(courseName[captured]))
        }
        return component(courseName)
    }

    public static func generatedCourseFolderReplacement(
        storedFolder: String,
        storedCourseName: String,
        currentCourseName: String,
        courseID: Int64,
        currentDefaultFolder: String? = nil
    ) -> String? {
        let currentDefault = currentDefaultFolder ?? defaultCourseFolder(currentCourseName)
        guard !equivalent(storedFolder, currentDefault) else { return nil }
        let storedDefault = legacyCourseFolder(storedCourseName)
        let currentLegacyDefault = legacyCourseFolder(currentCourseName)
        let legacyDefaults = [storedDefault, "\(storedDefault) (\(courseID))", currentLegacyDefault, "\(currentLegacyDefault) (\(courseID))"]
        let decodedStoredFolder = MoodleText.normalized(storedFolder).map(component)
        guard legacyDefaults.contains(where: { equivalent(storedFolder, $0) })
                || decodedStoredFolder.map({ decoded in legacyDefaults.contains(where: { equivalent(decoded, $0) }) }) == true else { return nil }
        return currentDefault
    }

    public static func destination(courseFolder: String, file: RemoteFileCandidate, moduleFolderOverride: String? = nil) throws -> RelativePath {
        let course = component(courseFolder)
        let module = component(file.moduleName)
        let remotePath = try file.remoteFilePath.split(separator: "/", omittingEmptySubsequences: true)
            .map { try validRemoteComponent(String($0)) }
        let sectionName = file.sectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: [String]
        if let moduleFolderOverride {
            prefix = [course] + (try moduleFolder(moduleFolderOverride).components)
        } else {
            prefix = sectionName.isEmpty || sectionName.localizedCaseInsensitiveContains("material")
                ? [course]
                : [course, component(sectionName)]
        }
        if file.moduleType == "resource", file.isSingleFileResource {
            let ext = URL(fileURLWithPath: file.filename).pathExtension
            let resourceName = ext.isEmpty ? module : "\(module).\(component(ext))"
            return try RelativePath((prefix + remotePath + [resourceName]).joined(separator: "/"))
        }
        let modulePrefix = moduleFolderOverride == nil && !file.moduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [module] : []
        return try RelativePath((prefix + modulePrefix + remotePath + [fileComponent(file.filename)]).joined(separator: "/"))
    }

    public static func moduleFolder(_ input: String) throws -> RelativePath {
        guard input.utf8.count <= 512 else { throw RelativePathError.invalid }
        let path = try RelativePath(input)
        guard path.components.allSatisfy({
            $0.utf8.count <= 255 && !ReservedNamespace.isReservedComponent($0)
        }) else { throw RelativePathError.invalid }
        return path
    }

    public static func uniqueDestination(_ destination: RelativePath, reserving paths: inout Set<String>) throws -> RelativePath {
        var candidate = destination
        var suffix = 1
        while !paths.insert(candidate.comparisonKey).inserted {
            candidate = try destinationByAddingSuffix(suffix, to: destination)
            suffix += 1
        }
        return candidate
    }

    public static func component(_ input: String) -> String {
        let normalized = input.precomposedStringWithCanonicalMapping
        let replaced = normalized.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 9, 10, 13: return " "
            case 42, 58, 60, 62, 63, 34, 124: return "_"
            case 0, 47: return "-"
            case 1...31: return "-"
            default: return Character(String(scalar))
            }
        }
        let collapsed = String(replaced).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "..", with: "-")
        let safe = collapsed.isEmpty || collapsed == "." || collapsed == ".." || ReservedNamespace.isReservedComponent(collapsed) ? "_" : collapsed
        return limited(safe)
    }

    private static func validRemoteComponent(_ input: String) throws -> String {
        guard input != ".", input != "..", !ReservedNamespace.isReservedComponent(input), !input.contains("\0") else {
            throw LocalPathPolicyError.invalidRemotePath
        }
        return component(input)
    }

    private static func fileComponent(_ input: String) -> String {
        component(input.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_"))
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        lhs.precomposedStringWithCanonicalMapping.localizedCaseInsensitiveCompare(
            rhs.precomposedStringWithCanonicalMapping
        ) == .orderedSame
    }

    private static func destinationByAddingSuffix(_ suffix: Int, to path: RelativePath) throws -> RelativePath {
        let value = path.value as NSString
        let directory = value.deletingLastPathComponent
        let filename = value.lastPathComponent as NSString
        let ext = filename.pathExtension
        let stem = filename.deletingPathExtension
        let renamed = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
        return try RelativePath(directory.isEmpty ? renamed : "\(directory)/\(renamed)")
    }

    private static func limited(_ value: String) -> String {
        guard value.utf8.count > 100 else { return value }
        let digest = SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        var prefix = ""
        for character in value {
            guard (prefix + String(character)).utf8.count <= 87 else { break }
            prefix.append(character)
        }
        return "\(prefix)-\(digest)"
    }
}
