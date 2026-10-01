import Foundation

/// The key under which the sync root's volume treats two names as the same entry. macOS
/// volumes are case-insensitive and normalization-insensitive by default, so `Appunti.pdf`,
/// `APPUNTI.pdf` and a decomposed spelling of an accented name all address one file. Every
/// check that two paths would land on the same file must compare these keys: a site that
/// compared raw strings, or normalized differently from the others, would let two downloads,
/// a move or a new course folder claim the same file. Keep this the single definition.
public enum PathKey {
    public static func of(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// The hidden directory Beepbar keeps its own staging area and conflict copies in.
/// macOS volumes are case-insensitive by default, so a folder called `.BEEPBAR` is the
/// same directory: every check against the reserved name has to ignore case too.
public enum ReservedNamespace {
    public static let folderName = ".beepbar"

    /// `true` when `component` names the reserved directory itself, ignoring case.
    public static func isReservedComponent(_ component: String) -> Bool {
        PathKey.of(component) == folderName
    }

    /// `true` when `name` is the reserved directory or any sibling name that shares its
    /// prefix, ignoring case. Used for the names Beepbar creates directly in the sync root.
    public static func isReservedTopLevelName(_ name: String) -> Bool {
        PathKey.of(name).hasPrefix(folderName)
    }
}

public struct RelativePath: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws {
        try self.init(value, allowsReservedNamespace: false)
    }

    init(internal value: String) throws {
        try self.init(value, allowsReservedNamespace: true)
    }

    private init(_ value: String, allowsReservedNamespace: Bool) throws {
        guard !value.isEmpty, !value.utf8.contains(0) else { throw RelativePathError.invalid }
        let normalized = value.precomposedStringWithCanonicalMapping
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              allowsReservedNamespace || !ReservedNamespace.isReservedComponent(String(components.first ?? "")) else {
            throw RelativePathError.invalid
        }
        self.value = components.joined(separator: "/")
    }

    public var description: String { value }
    public var components: [String] { value.split(separator: "/").map(String.init) }
    /// Equal for two paths that name the same file on disk; see `PathKey`.
    public var comparisonKey: String { PathKey.of(value) }
}

public enum RelativePathError: Error, Sendable, Equatable {
    case invalid
}

public struct Baseline: Sendable, Equatable {
    public let remoteID: String
    public let relativePath: RelativePath
    public let sha256: String
    public let remoteRevision: String
    public let courseID: Int64?
    public let moduleID: Int64?

    public init(remoteID: String, relativePath: RelativePath, sha256: String, remoteRevision: String, courseID: Int64? = nil, moduleID: Int64? = nil) {
        precondition((courseID == nil) == (moduleID == nil))
        self.remoteID = remoteID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.remoteRevision = remoteRevision
        self.courseID = courseID
        self.moduleID = moduleID
    }
}

public struct SyncScope: Sendable, Equatable, Identifiable {
    public let rootID: UUID
    public let courseID: Int64
    public let displayName: String
    public let localFolder: String
    public let enabled: Bool
    public let managedDirectory: DirectoryIdentity?

    public var id: String { "\(rootID.uuidString):\(courseID)" }

    public init(rootID: UUID, courseID: Int64, displayName: String, localFolder: String, enabled: Bool, managedDirectory: DirectoryIdentity? = nil) {
        self.rootID = rootID
        self.courseID = courseID
        self.displayName = displayName
        self.localFolder = localFolder
        self.enabled = enabled
        self.managedDirectory = managedDirectory
    }
}

public struct DirectoryIdentity: Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct ModulePathOverride: Sendable, Equatable, Identifiable {
    public let rootID: UUID
    public let courseID: Int64
    public let moduleID: Int64
    public let localFolder: String
    public let lastKnownName: String

    public var id: String { "\(rootID.uuidString):\(courseID):\(moduleID)" }

    public init(rootID: UUID, courseID: Int64, moduleID: Int64, localFolder: String, lastKnownName: String) {
        self.rootID = rootID
        self.courseID = courseID
        self.moduleID = moduleID
        self.localFolder = localFolder
        self.lastKnownName = lastKnownName
    }
}

public struct ModulePathRuleRow: Sendable, Equatable, Identifiable {
    public let moduleID: Int64
    public let name: String
    public let moduleType: String
    public let exposedFileCount: Int
    public let trackedFileCount: Int
    public let localFolder: String?
    public let isAvailable: Bool

    public var id: Int64 { moduleID }

    public init(moduleID: Int64, name: String, moduleType: String, exposedFileCount: Int, trackedFileCount: Int, localFolder: String?, isAvailable: Bool) {
        self.moduleID = moduleID
        self.name = name
        self.moduleType = moduleType
        self.exposedFileCount = exposedFileCount
        self.trackedFileCount = trackedFileCount
        self.localFolder = localFolder
        self.isAvailable = isAvailable
    }
}

public struct FileSnapshot: Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64
    public let sha256: String

    public init(device: Int64, inode: UInt64, sha256: String) {
        self.device = device
        self.inode = inode
        self.sha256 = sha256
    }
}

public enum FileSnapshotState: Sendable, Equatable {
    case missing
    case present(FileSnapshot)
}

public enum ModuleMoveAction: String, Sendable, Equatable {
    case set
    case remove
}

public struct ModuleMoveFile: Sendable, Equatable, Identifiable {
    public let remoteID: String
    public let oldPath: RelativePath
    public let newPath: RelativePath
    public let source: FileSnapshotState
    public let baselineSHA256: String
    public let baselineRevision: String
    public let observedRevision: String

    public var id: String { remoteID }

    public init(remoteID: String, oldPath: RelativePath, newPath: RelativePath, source: FileSnapshotState, baselineSHA256: String, baselineRevision: String, observedRevision: String) {
        self.remoteID = remoteID
        self.oldPath = oldPath
        self.newPath = newPath
        self.source = source
        self.baselineSHA256 = baselineSHA256
        self.baselineRevision = baselineRevision
        self.observedRevision = observedRevision
    }
}

public struct ModuleMovePreview: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let courseID: Int64
    public let moduleID: Int64
    public let action: ModuleMoveAction
    public let oldFolder: String?
    public let newFolder: String?
    public let lastKnownName: String
    public let files: [ModuleMoveFile]
    public let excludedRemoteIDs: [String]
    public let ownerlessBaselineCount: Int
    public let fingerprint: String

    public var changedFileCount: Int {
        files.filter { file in
            guard case .present = file.source else { return false }
            return file.oldPath != file.newPath
        }.count
    }
    public var localModifiedCount: Int {
        files.filter { file in
            guard case .present(let snapshot) = file.source else { return false }
            return snapshot.sha256 != file.baselineSHA256
        }.count
    }

    public init(id: UUID = UUID(), rootID: UUID, courseID: Int64, moduleID: Int64, action: ModuleMoveAction, oldFolder: String?, newFolder: String?, lastKnownName: String, files: [ModuleMoveFile], excludedRemoteIDs: [String], ownerlessBaselineCount: Int, fingerprint: String) {
        self.id = id
        self.rootID = rootID
        self.courseID = courseID
        self.moduleID = moduleID
        self.action = action
        self.oldFolder = oldFolder
        self.newFolder = newFolder
        self.lastKnownName = lastKnownName
        self.files = files.sorted { $0.remoteID < $1.remoteID }
        self.excludedRemoteIDs = excludedRemoteIDs.sorted()
        self.ownerlessBaselineCount = ownerlessBaselineCount
        self.fingerprint = fingerprint
    }
}

public struct PendingModuleMoveFile: Sendable, Equatable, Identifiable {
    public let remoteID: String
    public let oldPath: RelativePath
    public let newPath: RelativePath
    public let source: FileSnapshotState

    public var id: String { remoteID }

    public init(remoteID: String, oldPath: RelativePath, newPath: RelativePath, source: FileSnapshotState) {
        self.remoteID = remoteID
        self.oldPath = oldPath
        self.newPath = newPath
        self.source = source
    }
}

public struct PendingModuleMove: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let courseID: Int64
    public let moduleID: Int64
    public let action: ModuleMoveAction
    public let oldFolder: String?
    public let newFolder: String?
    public let lastKnownName: String
    public let files: [PendingModuleMoveFile]

    public init(id: UUID = UUID(), rootID: UUID, courseID: Int64, moduleID: Int64, action: ModuleMoveAction, oldFolder: String?, newFolder: String?, lastKnownName: String, files: [PendingModuleMoveFile]) {
        self.id = id
        self.rootID = rootID
        self.courseID = courseID
        self.moduleID = moduleID
        self.action = action
        self.oldFolder = oldFolder
        self.newFolder = newFolder
        self.lastKnownName = lastKnownName
        self.files = files
    }
}

public enum LocalState: Sendable, Equatable {
    case missing
    case present(sha256: String)
}

public struct RemoteState: Sendable, Equatable {
    public let sha256: String
    public let revision: String

    public init(sha256: String, revision: String) {
        self.sha256 = sha256
        self.revision = revision
    }
}

public enum SyncDecision: Sendable, Equatable {
    case installRemote
    case preserveLocal
    case adoptRemoteBaseline
    case conflict
    case noOp
}

public struct ConflictRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let remoteID: String
    public let relativePath: RelativePath
    public let incomingPath: RelativePath
    public let baseSHA256: String?
    public let localSHA256: String?
    public let remoteSHA256: String
    public let remoteRevision: String
    public let detectedAt: Date
    public let status: ConflictStatus
}

public enum ConflictStatus: String, Sendable, Equatable {
    case open
    case resolved
}

public enum ConflictResolution: String, Sendable, Equatable {
    case keepLocal
    case useRemote
}

public struct PendingScopeMove: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let courseID: Int64
    public let oldFolder: String
    public let newFolder: String
}

public struct PendingOperation: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let rootID: UUID
    public let remoteID: String
    public let destination: RelativePath
    public let stagePath: RelativePath
    public let expectedLocal: LocalState
    public let remoteSHA256: String
    public let remoteRevision: String
    public let phase: PendingOperationPhase
    public let courseID: Int64?
    public let moduleID: Int64?

    public init(id: UUID = UUID(), rootID: UUID, remoteID: String, destination: RelativePath, stagePath: RelativePath, expectedLocal: LocalState, remoteSHA256: String, remoteRevision: String, phase: PendingOperationPhase = .prepared, courseID: Int64? = nil, moduleID: Int64? = nil) {
        precondition((courseID == nil) == (moduleID == nil))
        self.id = id
        self.rootID = rootID
        self.remoteID = remoteID
        self.destination = destination
        self.stagePath = stagePath
        self.expectedLocal = expectedLocal
        self.remoteSHA256 = remoteSHA256
        self.remoteRevision = remoteRevision
        self.phase = phase
        self.courseID = courseID
        self.moduleID = moduleID
    }
}

public enum PendingOperationPhase: String, Sendable, Equatable {
    case prepared
    case committed
}
