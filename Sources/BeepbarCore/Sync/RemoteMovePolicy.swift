import Foundation

/// Where Moodle places a file: the parts of a remote item that decide its local folder and name
/// but are not part of its identity. A module moved to another section, or renamed, keeps its id
/// and so its files keep their remote ids; only this changes.
public struct RemotePlacement: Sendable, Equatable, Hashable {
    public let sectionName: String
    public let moduleName: String
    public let isSingleFileResource: Bool

    public init(sectionName: String, moduleName: String, isSingleFileResource: Bool) {
        self.sectionName = sectionName
        self.moduleName = moduleName
        self.isSingleFileResource = isSingleFileResource
    }

    public init(_ file: RemoteFileCandidate) {
        self.init(sectionName: file.sectionName, moduleName: file.moduleName, isSingleFileResource: file.isSingleFileResource)
    }
}

/// Decides whether a tracked file follows a move made on Moodle.
///
/// Only a change in the file's `RemotePlacement` counts. Both the old and the new destination are
/// computed with the *current* path rules, course folder and module folder rule, so changing any
/// of those never moves a file: `LocalPathPolicy` changed several times in September 2026, and
/// comparing a baseline path with today's rules would have reorganized long-time users' folders on
/// their first sync after updating. For the same reason a baseline with no recorded placement (any
/// file tracked by an older version) only has its placement recorded, never moved: moves are
/// followed from the first sync that knows the placement onwards, not retroactively.
public enum RemoteMovePolicy {
    public enum Decision: Sendable, Equatable {
        /// The recorded placement is still current.
        case unchanged
        /// Store the current placement; the local file stays where it is.
        case record
        /// Moodle moved the file: it belongs at this path now.
        case move(to: RelativePath)
    }

    public static func decide(baselinePath: RelativePath, recorded: RemotePlacement?, file: RemoteFileCandidate, courseFolder: String, moduleFolderOverride: String?) throws -> Decision {
        let current = RemotePlacement(file)
        guard let recorded else { return .record }
        guard recorded != current else { return .unchanged }
        let old = try LocalPathPolicy.destination(courseFolder: courseFolder, file: file.placed(recorded), moduleFolderOverride: moduleFolderOverride)
        let new = try LocalPathPolicy.destination(courseFolder: courseFolder, file: file, moduleFolderOverride: moduleFolderOverride)
        guard old != new else { return .record }
        // Only ever within the course folder the file is already in.
        guard baselinePath.components.first == new.components.first else { return .record }
        let name = baselinePath.components.last ?? baselinePath.value
        let target: RelativePath
        if name == old.components.last {
            // Named as Moodle named it: take the new name too (a renamed single-file resource).
            target = new
        } else {
            // A numbered " (1)" copy given out to avoid a name collision, or a name from an older
            // path rule: it joins its neighbours in the new folder and keeps the name it has.
            target = try RelativePath((new.components.dropLast() + [name]).joined(separator: "/"))
        }
        return target == baselinePath ? .record : .move(to: target)
    }
}

extension RemoteFileCandidate {
    /// The same file as Moodle placed it according to `placement`.
    func placed(_ placement: RemotePlacement) -> RemoteFileCandidate {
        RemoteFileCandidate(
            id: id, courseID: courseID, sectionID: sectionID, moduleID: moduleID,
            sectionName: placement.sectionName, moduleName: placement.moduleName,
            moduleType: moduleType, isSingleFileResource: placement.isSingleFileResource,
            filename: filename, remoteFilePath: remoteFilePath, canonicalPluginPath: canonicalPluginPath,
            downloadURL: downloadURL, size: size, modifiedAt: modifiedAt, observedRevision: observedRevision,
            isSupported: isSupported, ineligibilityReason: ineligibilityReason
        )
    }
}
