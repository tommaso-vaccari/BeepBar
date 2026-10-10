#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

public enum FileStoreError: Error, Sendable, Equatable { case invalidRoot, symbolicLink, invalidStage, localChanged, destinationExists, sizeMismatch, tooLarge, ioFailure, unsupported }

private struct FileIdentity: Sendable, Equatable {
    let device: Int64
    let inode: UInt64
}

/// A file's state as `fstat` reports it, in nanoseconds: see `FileStore.contentStamp(of:)`.
private struct ContentStamp: Hashable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modified: Int64
    let changed: Int64
}

public struct StageHandle: Sendable, Equatable {
    fileprivate let name: String
    fileprivate let identity: FileIdentity
    public let relativePath: RelativePath
}

public struct StagedArtifact: Sendable, Equatable {
    fileprivate let name: String
    fileprivate let identity: FileIdentity
    public let stagePath: RelativePath
    public let sha256: String
    public let size: Int64
}

public struct RecoveryArtifact: Sendable, Equatable {
    fileprivate let name: String
    fileprivate let identity: FileIdentity
    public let relativePath: RelativePath
    public let sha256: String
}

public enum InstallResult: Sendable, Equatable {
    case installedNew
    case installedReplacing(rollback: RecoveryArtifact)
    case localChanged
}

public enum TopLevelDirectoryState: Sendable, Equatable { case missing, directory, other }

enum MigrationDirectoryEntryMatch: Equatable { case missing, exact, differentSpelling, ambiguous }

/// A reading of `FileStore.counters()`; subtract two with `since` to measure one operation.
package struct FileStoreCounters: Sendable, Equatable, Codable {
    package var filesHashed: Int
    package var bytesHashed: Int64
    package var pathLookups: Int

    package init(filesHashed: Int = 0, bytesHashed: Int64 = 0, pathLookups: Int = 0) {
        self.filesHashed = filesHashed
        self.bytesHashed = bytesHashed
        self.pathLookups = pathLookups
    }

    package func since(_ earlier: FileStoreCounters) -> FileStoreCounters {
        FileStoreCounters(filesHashed: filesHashed - earlier.filesHashed, bytesHashed: bytesHashed - earlier.bytesHashed, pathLookups: pathLookups - earlier.pathLookups)
    }
}

public actor FileStore {
    private let rootFD: Int32
    private let rootURL: URL
    private let trash: @Sendable (URL) throws -> Void
    private let beforeMove: (@Sendable (RelativePath, RelativePath) throws -> Void)?
    /// Tests change the destination after `install`'s pre-swap check and before the swap, the
    /// window only the post-swap check of the displaced copy guards.
    private let beforeSwap: (@Sendable (RelativePath) throws -> Void)?
    private let beforeReadChunk: (@Sendable (Bool, Int64) -> Void)?
    /// Number of times a file's full contents were read to compute a SHA-256 digest.
    /// Test instrumentation: lets tests prove that unchanged files are not re-read on every sync.
    private(set) var hashCount = 0
    /// Bytes read to compute those digests: tells one large file read twice from two small ones.
    private var bytesHashed: Int64 = 0
    /// Directory resolutions from the root, one `openat` per component, before a call touches the
    /// files in that directory. Per-file calls (`inspect`, `containsRegularFile`, occupancy checks,
    /// moves) resolve once per path; `existingRegularFiles` resolves once per distinct parent
    /// directory per call (R03, #111), so for a run with nothing new this counts module folders,
    /// not tracked files.
    private var pathLookups = 0
    /// Hashes `inspect` computed during this store's life, keyed by the exact state of the file
    /// they were read from. Only `install`'s check before replacing a file consults them, through
    /// `currentSHA256(of:)`; see there for why that one check, and no other, may.
    private var inspectedHashes: [ContentStamp: String] = [:]
    /// Insertion order of `inspectedHashes`, to forget the oldest past `inspectedHashLimit`.
    private var inspectedOrder: [ContentStamp] = []
    /// Only files present on the Mac whose Moodle revision changed get an entry (an update, a
    /// revision-only change, a conflict path, the re-inspect after `.localChanged`): unchanged
    /// files never reach `inspect` (the `unchanged` benchmark hashes nothing), and new ones are
    /// missing. An entry is used shortly after, when that update installs, so the bound is reached
    /// only when 64 other files are inspected while one download is still running, which then costs
    /// the one extra read this memo saves. The bound keeps such a batch from holding them all.
    private static let inspectedHashLimit = 64

    /// The filesystem work this store has done since it was created, for the benchmark harness and
    /// for tests that prove a run left unchanged files alone. Instance-scoped, so parallel tests
    /// with their own stores never see each other's work.
    package func counters() -> FileStoreCounters {
        FileStoreCounters(filesHashed: hashCount, bytesHashed: bytesHashed, pathLookups: pathLookups)
    }

    /// `trash` moves a file to the Trash; tests replace it so they never touch the user's Trash.
    public init(root: URL, trash: @escaping @Sendable (URL) throws -> Void = FileStore.defaultTrash) throws {
        try self.init(root: root, beforeMove: nil, trash: trash)
    }

    /// Tests inject a filesystem change after destination selection, before move validation.
    /// `beforeSwap` comes last so that existing trailing closures keep binding to `trash`.
    init(root: URL, beforeMove: (@Sendable (RelativePath, RelativePath) throws -> Void)?, trash: @escaping @Sendable (URL) throws -> Void = FileStore.defaultTrash, beforeSwap: (@Sendable (RelativePath) throws -> Void)? = nil, beforeReadChunk: (@Sendable (Bool, Int64) -> Void)? = nil) throws {
        let fd = open(root.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw FileStoreError.invalidRoot }
        guard (try? Self.identity(of: fd)) != nil else { close(fd); throw FileStoreError.invalidRoot }
        rootFD = fd
        rootURL = root.standardizedFileURL
        self.trash = trash
        self.beforeMove = beforeMove
        self.beforeSwap = beforeSwap
        self.beforeReadChunk = beforeReadChunk
    }

    deinit { close(rootFD) }

    /// Ordinary reads can stop; recovery and a journaled change explicitly finish their read.
    public func inspect(_ path: RelativePath, checksCancellation: Bool = true) throws -> LocalState {
        let parentAndName: (Int32, String)
        do {
            parentAndName = try parentDirectory(for: path, create: false)
        } catch where errno == ENOENT {
            return .missing
        }
        let (parent, name) = parentAndName
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return .missing }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        return .present(sha256: try rememberingSHA256(of: fd, checksCancellation: checksCancellation))
    }

    public func containsRegularFile(_ path: RelativePath) throws -> Bool {
        let parentAndName: (Int32, String)
        do {
            parentAndName = try parentDirectory(for: path, create: false)
        } catch where errno == ENOENT {
            return false
        }
        let (parent, name) = parentAndName
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return false }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        return true
    }

    /// What sits at a tracked path, for opening it from Attività: nothing, something that isn't a
    /// plain file reached directly (a folder, a FIFO, or a symbolic link at the file or in any
    /// folder on the way: every folder is opened with `O_NOFOLLOW` and the file itself is only
    /// `fstatat`ed with `AT_SYMLINK_NOFOLLOW`), a path BeepBar has no permission to look into, or
    /// a readable regular file that isn't a Finder alias, and whether it carries an execute permission. Never opens the file, so it
    /// can't block on a FIFO or download an iCloud-evicted file just to look at it.
    public func openableFileState(_ path: RelativePath) throws -> OpenableFileState {
        let parentAndName: (Int32, String)
        do {
            parentAndName = try parentDirectory(for: path, create: false)
        } catch where errno == ENOENT {
            return .missing
        } catch where errno == ELOOP || errno == ENOTDIR {
            return .notARegularFile
        } catch where errno == EACCES || errno == EPERM {
            return .unreadable
        }
        let (parent, name) = parentAndName
        defer { close(parent) }
        var metadata = stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            switch errno {
            case ENOENT: return .missing
            case EACCES, EPERM: return .unreadable
            default: throw fileStoreError()
            }
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { return .notARegularFile }
#if canImport(Darwin)
        // Finder aliases are regular files, but Launch Services follows them even when their
        // name says PDF. Read FinderInfo relative to the checked parent without following links.
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_FNDRINFO)
        var finderInfo = [UInt8](repeating: 0, count: 36) // Four-byte length, then 32-byte FinderInfo.
        let result = finderInfo.withUnsafeMutableBytes {
            getattrlistat(parent, name, &attributes, $0.baseAddress, $0.count, UInt(FSOPT_NOFOLLOW))
        }
        guard result == 0 else {
            if errno == ENOENT { return .missing }
            if errno == EACCES || errno == EPERM { return .unreadable }
            throw fileStoreError()
        }
        // Finder flags are big-endian at byte eight; 0x8000 marks an alias.
        guard finderInfo[12] & 0x80 == 0 else { return .notARegularFile }
#endif
        // stat does not check permission to read the leaf. Effective access also honors ACLs,
        // without opening or hydrating an evicted document just to check permission.
        guard faccessat(parent, name, R_OK, AT_EACCESS) == 0 else {
            if errno == ENOENT { return .missing }
            if errno == EACCES || errno == EPERM { return .unreadable }
            throw fileStoreError()
        }
        return .regular(executable: metadata.st_mode & 0o111 != 0)
    }

    public func snapshotRegularFile(_ path: RelativePath, checksCancellation: Bool = true) throws -> FileSnapshotState {
        try requireMovablePath(path)
        let (parent, name): (Int32, String)
        do { (parent, name) = try parentDirectory(for: path, create: false) }
        catch where errno == ENOENT { return .missing }
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return .missing }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        let identity = try Self.identity(of: fd)
        return .present(FileSnapshot(device: identity.device, inode: identity.inode, sha256: try sha256(of: fd, checksCancellation: checksCancellation)))
    }

    public func regularFileIdentity(_ path: RelativePath) throws -> DirectoryIdentity? {
        try requireMovablePath(path)
        let (parent, name): (Int32, String)
        do { (parent, name) = try parentDirectory(for: path, create: false) }
        catch where errno == ENOENT { return nil }
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        let identity = try Self.identity(of: fd)
        return DirectoryIdentity(device: identity.device, inode: identity.inode)
    }

    public func destinationIsOccupied(_ path: RelativePath) throws -> Bool {
        try requireMovablePath(path)
        let (parent, name): (Int32, String)
        do { (parent, name) = try parentDirectory(for: path, create: false) }
        catch where errno == ENOENT { return false }
        defer { close(parent) }
        var metadata = stat()
        if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw fileStoreError()
    }

    func downloadDestinationIsOccupied(_ path: RelativePath) throws -> Bool {
        try requireMovablePath(path)
        var parent = dup(rootFD)
        guard parent >= 0 else { throw fileStoreError() }
        defer { close(parent) }
        for (index, component) in path.components.enumerated() {
            let matches = try directoryEntryNames(at: parent).filter { PathKey.of($0) == PathKey.of(component) }
            guard !matches.isEmpty else { return false }
            if index == path.components.count - 1 { return true }
            guard matches.count == 1 else { return false }
            let next = openat(parent, matches[0], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else {
                if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return false }
                throw fileStoreError()
            }
            close(parent)
            parent = next
        }
        return false
    }

    public func migrationDestinationIsOccupied(_ path: RelativePath) throws -> Bool {
        try requireMovablePath(path)
        var parent = dup(rootFD)
        guard parent >= 0 else { throw fileStoreError() }
        defer { close(parent) }
        for (index, component) in path.components.enumerated() {
            let match = Self.migrationDirectoryEntryMatch(component, entries: try directoryEntryNames(at: parent))
            switch match {
            case .missing:
                return false
            case .differentSpelling, .ambiguous:
                return true
            case .exact:
                if index == path.components.count - 1 { return true }
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else {
                    if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return true }
                    throw fileStoreError()
                }
                close(parent)
                parent = next
            }
        }
        return false
    }

    static func migrationDirectoryEntryMatch(_ component: String, entries: [String]) -> MigrationDirectoryEntryMatch {
        let key = PathKey.of(component)
        let matches = entries.filter { PathKey.of($0) == key }
        guard matches.count == 1 else { return matches.isEmpty ? .missing : .ambiguous }
        return matches[0].utf8.elementsEqual(component.utf8) ? .exact : .differentSpelling
    }

    public func moveRegularFile(from source: RelativePath, to destination: RelativePath, expected: FileSnapshot) throws {
        try moveRegularFile(from: source, to: destination, expected: expected, preservingCurrentContents: false)
    }

    public func moveRegularFilePreservingCurrentContents(from source: RelativePath, to destination: RelativePath, expected: FileSnapshot) throws {
        try moveRegularFile(from: source, to: destination, expected: expected, preservingCurrentContents: true)
    }

    private func moveRegularFile(from source: RelativePath, to destination: RelativePath, expected: FileSnapshot, preservingCurrentContents: Bool) throws {
        try requireMovablePath(source)
        try requireMovablePath(destination)
        guard source != destination else { return }
        try beforeMove?(source, destination)
        let (sourceParent, sourceName) = try parentDirectory(for: source, create: false)
        defer { close(sourceParent) }
        let sourceFD = openat(sourceParent, sourceName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw fileStoreError() }
        defer { close(sourceFD) }
        try requireRegularFile(sourceFD)
        guard try Self.identity(of: sourceFD) == FileIdentity(device: expected.device, inode: expected.inode) else { throw FileStoreError.localChanged }
        if !preservingCurrentContents {
            guard try sha256(of: sourceFD, checksCancellation: false) == expected.sha256 else { throw FileStoreError.localChanged }
        }
        let (destinationParent, destinationName) = try parentDirectory(for: destination, create: true)
        defer { close(destinationParent) }
        var current = stat()
        guard fstatat(sourceParent, sourceName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Int64(current.st_dev) == expected.device, UInt64(current.st_ino) == expected.inode else { throw FileStoreError.localChanged }
        guard renameatx_np(sourceParent, sourceName, destinationParent, destinationName, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw FileStoreError.destinationExists }
            throw fileStoreError()
        }
        guard fsync(sourceParent) == 0, fsync(destinationParent) == 0 else { throw fileStoreError() }
    }

    /// Exchanges two regular files in one atomic rename (`RENAME_SWAP`), each checked to still be
    /// the file that was hashed. Used when Moodle swaps two files' places, so neither ever needs a
    /// temporary name that a crash could strand. Throws `unsupported` on a volume that cannot swap.
    public func swapRegularFiles(_ first: RelativePath, expected firstSnapshot: FileSnapshot, with second: RelativePath, expected secondSnapshot: FileSnapshot) throws {
        try requireMovablePath(first)
        try requireMovablePath(second)
        let (firstParent, firstName) = try parentDirectory(for: first, create: false)
        defer { close(firstParent) }
        let (secondParent, secondName) = try parentDirectory(for: second, create: false)
        defer { close(secondParent) }
        for (parent, name, snapshot) in [(firstParent, firstName, firstSnapshot), (secondParent, secondName, secondSnapshot)] {
            let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw FileStoreError.localChanged }
            defer { close(fd) }
            try requireRegularFile(fd)
            guard try Self.identity(of: fd) == FileIdentity(device: snapshot.device, inode: snapshot.inode),
                  try sha256(of: fd, checksCancellation: false) == snapshot.sha256 else { throw FileStoreError.localChanged }
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  Int64(current.st_dev) == snapshot.device, UInt64(current.st_ino) == snapshot.inode else { throw FileStoreError.localChanged }
        }
        guard renameatx_np(firstParent, firstName, secondParent, secondName, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOTSUP || errno == EINVAL { throw FileStoreError.unsupported }
            throw fileStoreError()
        }
        guard fsync(firstParent) == 0, fsync(secondParent) == 0 else { throw fileStoreError() }
    }

    /// Moves a regular file to the Trash, where the user can still recover it, provided it is
    /// still the file that was hashed (`expected`).
    public func trashRegularFile(_ path: RelativePath, expected: FileSnapshot) throws {
        guard case .present(let current) = try snapshotRegularFile(path, checksCancellation: false), current == expected else { throw FileStoreError.localChanged }
        do { try trash(rootURL.appending(path: path.value, directoryHint: .notDirectory)) }
        catch { throw FileStoreError.ioFailure }
    }

    /// Removes the directories that held `path` while they are empty, deepest first, stopping at the
    /// first one that still has an entry. The top-level course folder is never removed: its sync
    /// scope records its identity. `rmdir` only succeeds on an empty directory, so nothing a user
    /// put there (even a `.DS_Store`) can be lost.
    public func removeEmptyParentDirectories(of path: RelativePath) throws {
        try requireMovablePath(path)
        let components = path.components
        guard components.count > 2 else { return }
        for length in stride(from: components.count - 1, through: 2, by: -1) {
            let parent: Int32
            do { parent = try directoryFD(for: Array(components.prefix(length - 1)), create: false) }
            catch { return }
            defer { close(parent) }
            guard unlinkat(parent, components[length - 1], AT_REMOVEDIR) == 0 else { return }
            _ = fsync(parent)
        }
    }

    /// Returns the subset of `paths` that currently exist as regular files, using one `fstatat` per
    /// path and never reading file contents. Directories, symbolic links and other non-regular
    /// entries, as well as paths whose parent is missing or is no longer a directory, are reported
    /// as absent rather than thrown.
    ///
    /// Each distinct parent directory is resolved once per call and its descriptor reused for the
    /// files it holds (R03, #111, PR #142). A run with nothing new checks every tracked file this
    /// way, and resolving `Corso/Modulo` again for each of its files cost one `dup`, one `openat`
    /// per component and as many `close` calls per file, several times the one `fstatat` that
    /// answers the question (unchanged 15k benchmark: CPU 424 → 184 ms on Apple M5).
    ///
    /// The checks are the ones the per-file version made: every directory is reached from the
    /// root descriptor pinned at `init` through `O_NOFOLLOW` opens, and each name is looked at
    /// with `AT_SYMLINK_NOFOLLOW`, so no symbolic link is followed and nothing outside the root is
    /// seen. A missing directory, a file where a directory should be, or a symbolic link in the
    /// path makes only that directory's files absent; any other error (a folder that cannot be
    /// opened or searched) still fails the whole call rather than being read as a deletion.
    /// `ExistingRegularFilesSafetyTests` pins each of these.
    ///
    /// The one difference is timing: a directory replaced while this call is checking its files
    /// is noticed by the next call instead of at the next file. The answer was already a snapshot
    /// that can go stale right after the `fstatat`, and every caller tolerates staleness both
    /// ways: a stale "present" only skips reconciliation until the next run, reserves a name, or
    /// opens a Conflicts entry whose action re-checks the file; a stale "absent" sends the item to
    /// `inspect`/`install`, whose expected-state checks refuse to overwrite anything. Descriptors
    /// live only for this call, never in a cache, so a later call never trusts a directory it did
    /// not open itself.
    public func existingRegularFiles(_ paths: [RelativePath]) throws -> Set<RelativePath> {
        var existing: Set<RelativePath> = []
        var namesByParent: [[String]: [(path: RelativePath, name: String)]] = [:]
        var parents: [[String]] = []
        for path in paths {
            let components = path.components
            let parent = Array(components.dropLast())
            if namesByParent[parent] == nil { parents.append(parent) }
            namesByParent[parent, default: []].append((path, components.last!))
        }
        for parent in parents {
            try Task.checkCancellation()
            let directory: Int32
            do {
                directory = try directoryFD(for: parent, create: false)
            } catch FileStoreError.symbolicLink {
                continue
            } catch where errno == ENOENT || errno == ENOTDIR {
                continue
            }
            defer { close(directory) }
            for (path, name) in namesByParent[parent]! {
                try Task.checkCancellation()
                var metadata = stat()
                guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT || errno == ENOTDIR { continue }
                    throw fileStoreError()
                }
                if (metadata.st_mode & S_IFMT) == S_IFREG { existing.insert(path) }
            }
        }
        return existing
    }

    public func renameTopLevelDirectory(from old: String, to new: String) throws {
        guard isSafeTopLevelName(old), isSafeTopLevelName(new) else { throw FileStoreError.invalidStage }
        let oldFD = openat(rootFD, old, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard oldFD >= 0 else { throw fileStoreError() }
        defer { close(oldFD) }
        guard renameatx_np(rootFD, old, rootFD, new, UInt32(RENAME_EXCL)) == 0 else { throw fileStoreError() }
        guard fsync(rootFD) == 0 else { throw fileStoreError() }
    }

    public func topLevelDirectoryIdentity(_ name: String) throws -> DirectoryIdentity? {
        guard isSafeTopLevelName(name) else { throw FileStoreError.invalidStage }
        let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw fileStoreError() }
        defer { close(fd) }
        let identity = try Self.identity(of: fd)
        return DirectoryIdentity(device: identity.device, inode: identity.inode)
    }

    public func ensureTopLevelDirectory(_ name: String) throws -> (identity: DirectoryIdentity, created: Bool) {
        guard isSafeTopLevelName(name) else { throw FileStoreError.invalidStage }
        if mkdirat(rootFD, name, S_IRWXU) == 0 {
            guard let identity = try topLevelDirectoryIdentity(name) else { throw fileStoreError() }
            return (identity, true)
        }
        guard errno == EEXIST, let identity = try topLevelDirectoryIdentity(name) else { throw fileStoreError() }
        return (identity, false)
    }

    public func topLevelDirectoryState(_ name: String) throws -> TopLevelDirectoryState {
        guard isSafeTopLevelName(name) else { throw FileStoreError.invalidStage }
        let fd = openat(rootFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return .missing }; throw fileStoreError() }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw fileStoreError() }
        return (metadata.st_mode & S_IFMT) == S_IFDIR ? .directory : .other
    }

    public func createStage() throws -> StageHandle {
        let fd = try directoryFD(for: [".beepbar", "staging"], create: true)
        defer { close(fd) }
        let name = UUID().uuidString + ".partial"
        let stage = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard stage >= 0 else { throw fileStoreError() }
        defer { close(stage) }
        return StageHandle(name: name, identity: try Self.identity(of: stage), relativePath: try RelativePath(internal: ".beepbar/staging/\(name)"))
    }

    public func write(_ data: Data, to stage: StageHandle) throws {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let fd = try openStage(stage, in: staging, flags: O_WRONLY | O_APPEND)
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = posixWrite(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw fileStoreError() }
                offset += count
            }
        }
    }

    public func importDownloadedFile(at source: URL, expectedSize: Int64, maximumSize: Int64) throws -> StagedArtifact {
        let trace = PerformanceTrace.shared.begin("filesystem.import", category: .filesystem)
        defer { PerformanceTrace.shared.end("filesystem.import", category: .filesystem, state: trace) }
        try Task.checkCancellation()
        guard expectedSize >= 0, expectedSize <= maximumSize else { throw FileStoreError.tooLarge }
        let sourceFD = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw fileStoreError() }
        defer { close(sourceFD) }
        try requireRegularFile(sourceFD)
        guard try fileSize(of: sourceFD) == expectedSize else { throw FileStoreError.sizeMismatch }

        let stage = try createStage()
        do {
            let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
            defer { close(staging) }
            let stageFD = try openStage(stage, in: staging, flags: O_WRONLY | O_TRUNC)
            defer { close(stageFD) }
            let copied = try hashContents(of: sourceFD, copyingTo: stageFD, maximumSize: maximumSize, checksCancellation: true)
            guard copied.size == expectedSize else { throw FileStoreError.sizeMismatch }
            guard fsync(stageFD) == 0 else { throw fileStoreError() }
            return StagedArtifact(name: stage.name, identity: stage.identity, stagePath: stage.relativePath, sha256: copied.sha256, size: copied.size)
        } catch {
            try? discard(stage)
            throw error
        }
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = posixWrite(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FileStoreError.ioFailure }
                offset += count
            }
        }
    }

    public func finalize(_ stage: StageHandle) throws -> StagedArtifact {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw fileStoreError() }
        return StagedArtifact(name: stage.name, identity: stage.identity, stagePath: stage.relativePath, sha256: try sha256(of: fd, checksCancellation: true), size: try fileSize(of: fd))
    }

    // Once journaled, installation, displaced-copy validation and rollback finish even if the
    // caller cancels. Interruptible inspection happens before the journal is written.
    public func install(_ artifact: StagedArtifact, at path: RelativePath, expectedLocal: LocalState) throws -> InstallResult {
        let trace = PerformanceTrace.shared.begin("filesystem.install", category: .filesystem)
        defer { PerformanceTrace.shared.end("filesystem.install", category: .filesystem, state: trace) }
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let verified = StageHandle(name: artifact.name, identity: artifact.identity, relativePath: try RelativePath(internal: ".beepbar/staging/\(artifact.name)"))
        let stageFD = try openStage(verified, in: staging, flags: O_RDONLY)
        guard fsync(stageFD) == 0 else { close(stageFD); throw fileStoreError() }
        close(stageFD)

        let (destinationParent, destinationName) = try parentDirectory(for: path, create: true)
        defer { close(destinationParent) }
        let result: InstallResult
        switch expectedLocal {
        case .missing:
            guard renameatx_np(staging, artifact.name, destinationParent, destinationName, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { return .localChanged }
                throw fileStoreError()
            }
            result = .installedNew
        case .present(let expectedHash):
            let existing = openat(destinationParent, destinationName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if existing < 0 { if errno == ENOENT { return .localChanged }; throw fileStoreError() }
            defer { close(existing) }
            try requireRegularFile(existing)
            guard try currentSHA256(of: existing) == expectedHash else { return .localChanged }
            try beforeSwap?(path)
            guard renameatx_np(staging, artifact.name, destinationParent, destinationName, UInt32(RENAME_SWAP)) == 0 else {
                if errno == ENOENT { return .localChanged }
                throw fileStoreError()
            }
            let rollbackIfRemoteIsStillInstalled: () throws -> Bool = {
                let current = openat(destinationParent, destinationName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard current >= 0 else { return false }
                defer { close(current) }
                try self.requireRegularFile(current)
                guard try self.sha256(of: current, checksCancellation: false) == artifact.sha256 else { return false }
                guard renameatx_np(staging, artifact.name, destinationParent, destinationName, UInt32(RENAME_SWAP)) == 0 else { throw self.fileStoreError() }
                guard fsync(staging) == 0, fsync(destinationParent) == 0 else { throw self.fileStoreError() }
                return true
            }
            do {
                let displacedFD = openat(staging, artifact.name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard displacedFD >= 0 else { throw fileStoreError() }
                defer { close(displacedFD) }
                try requireRegularFile(displacedFD)
                let displacedHash = try sha256(of: displacedFD, checksCancellation: false)
                guard displacedHash == expectedHash else {
                    guard try rollbackIfRemoteIsStillInstalled() else { throw FileStoreError.localChanged }
                    return .localChanged
                }
                result = .installedReplacing(rollback: RecoveryArtifact(name: artifact.name, identity: try Self.identity(of: displacedFD), relativePath: try RelativePath(internal: ".beepbar/staging/\(artifact.name)"), sha256: expectedHash))
            } catch {
                if (try? rollbackIfRemoteIsStillInstalled()) == true { return .localChanged }
                throw error
            }
        }
        guard fsync(staging) == 0, fsync(destinationParent) == 0 else { throw fileStoreError() }
        return result
    }

    public func discard(_ recovery: RecoveryArtifact) throws {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let stage = StageHandle(name: recovery.name, identity: recovery.identity, relativePath: recovery.relativePath)
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        let hash = try sha256(of: fd, checksCancellation: false)
        close(fd)
        guard hash == recovery.sha256 else { throw FileStoreError.localChanged }
        guard unlinkat(staging, recovery.name, 0) == 0 else { throw fileStoreError() }
        guard fsync(staging) == 0 else { throw fileStoreError() }
    }

    public func preserveAsConflict(_ artifact: StagedArtifact, conflictID: UUID, at path: RelativePath) throws -> RelativePath {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let stage = StageHandle(name: artifact.name, identity: artifact.identity, relativePath: try RelativePath(internal: ".beepbar/staging/\(artifact.name)"))
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        close(fd)
        let incoming = try RelativePath(internal: ".beepbar/conflicts/\(conflictID.uuidString)/\(path.value)")
        let (parent, name) = try parentDirectory(for: incoming, create: true)
        defer { close(parent) }
        guard renameatx_np(staging, artifact.name, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw fileStoreError() }
        guard fsync(staging) == 0, fsync(parent) == 0 else { throw fileStoreError() }
        return incoming
    }

    public func conflictArtifact(at path: RelativePath, checksCancellation: Bool = true) throws -> StagedArtifact? {
        let components = path.components
        guard components.count >= 4, components[0] == ".beepbar", components[1] == "conflicts" else { throw FileStoreError.invalidStage }
        let (parent, name): (Int32, String)
        do {
            (parent, name) = try parentDirectory(for: path, create: false)
        } catch where errno == ENOENT {
            return nil
        }
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        return StagedArtifact(name: name, identity: try Self.identity(of: fd), stagePath: path, sha256: try sha256(of: fd, checksCancellation: checksCancellation), size: try fileSize(of: fd))
    }

    public func copyConflictArtifactToStage(at path: RelativePath, expectedSHA256: String) throws -> StagedArtifact {
        guard let artifact = try conflictArtifact(at: path), artifact.sha256 == expectedSHA256 else { throw FileStoreError.invalidStage }
        let sourceParent = try parentDirectory(for: path, create: false)
        defer { close(sourceParent.0) }
        let source = openat(sourceParent.0, sourceParent.1, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard source >= 0 else { throw fileStoreError() }
        defer { close(source) }
        try requireRegularFile(source)
        let stage = try createStage()
        do {
            let duplicate = dup(source)
            guard duplicate >= 0 else { throw FileStoreError.ioFailure }
            let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
            defer { try? handle.close() }
            var copiedBytes: Int64 = 0
            try Self.forEachChunk(of: handle) { chunk in
                beforeReadChunk?(true, copiedBytes)
                try Task.checkCancellation()
                try write(chunk, to: stage)
                copiedBytes += Int64(chunk.count)
            }
            let copied = try finalize(stage)
            guard copied.sha256 == expectedSHA256 && copied.size == artifact.size else { throw FileStoreError.invalidStage }
            return copied
        } catch {
            try? discard(stage)
            throw error
        }
    }

    public func discardConflictArtifact(at path: RelativePath, expectedSHA256: String) throws {
        guard let artifact = try conflictArtifact(at: path, checksCancellation: false), artifact.sha256 == expectedSHA256 else { throw FileStoreError.localChanged }
        let (parent, name) = try parentDirectory(for: path, create: false)
        defer { close(parent) }
        guard unlinkat(parent, name, 0) == 0 else { throw fileStoreError() }
        guard fsync(parent) == 0 else { throw fileStoreError() }
        let components = path.components
        guard components.count > 3 else { return }
        for index in stride(from: components.count - 2, through: 2, by: -1) {
            guard let ancestorParent = try? directoryFD(for: Array(components.prefix(index)), create: false) else { break }
            defer { close(ancestorParent) }
            guard unlinkat(ancestorParent, components[index], AT_REMOVEDIR) == 0 else { break }
            _ = fsync(ancestorParent)
        }
    }

    public func sweepUnreferencedStages(referencedPaths: Set<RelativePath>) throws {
        let referencedNames = Set(referencedPaths.compactMap { path -> String? in
            let components = path.components
            guard components.count == 3, components[0] == ".beepbar", components[1] == "staging", components[2].hasSuffix(".partial") else { return nil }
            return components[2]
        })
        let staging: Int32
        do { staging = try directoryFD(for: [".beepbar", "staging"], create: false) }
        catch where errno == ENOENT { return }
        defer { close(staging) }
        guard let directory = fdopendir(dup(staging)) else { throw fileStoreError() }
        defer { closedir(directory) }
        var removed = false
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            guard name.hasSuffix(".partial"), !referencedNames.contains(name) else { continue }
            var metadata = stat()
            guard fstatat(staging, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG else { continue }
            guard unlinkat(staging, name, 0) == 0 else { throw fileStoreError() }
            removed = true
        }
        if removed, fsync(staging) != 0 { throw fileStoreError() }
    }

    public func discard(_ artifact: StagedArtifact) throws {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let stage = StageHandle(name: artifact.name, identity: artifact.identity, relativePath: try RelativePath(internal: ".beepbar/staging/\(artifact.name)"))
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        close(fd)
        guard unlinkat(staging, artifact.name, 0) == 0 else { throw fileStoreError() }
    }

    public func discard(_ stage: StageHandle) throws {
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let fd = try openStage(stage, in: staging, flags: O_RDONLY)
        close(fd)
        guard unlinkat(staging, stage.name, 0) == 0 else { throw fileStoreError() }
        guard fsync(staging) == 0 else { throw fileStoreError() }
    }

    public func stagedArtifact(at path: RelativePath) throws -> StagedArtifact? {
        let components = path.components
        guard components.count == 3, components[0] == ".beepbar", components[1] == "staging", components[2].hasSuffix(".partial") else { throw FileStoreError.invalidStage }
        let staging = try directoryFD(for: [".beepbar", "staging"], create: false)
        defer { close(staging) }
        let fd = openat(staging, components[2], O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw fileStoreError() }
        defer { close(fd) }
        try requireRegularFile(fd)
        return StagedArtifact(name: components[2], identity: try Self.identity(of: fd), stagePath: path, sha256: try sha256(of: fd, checksCancellation: false), size: try fileSize(of: fd))
    }

    private func parentDirectory(for path: RelativePath, create: Bool) throws -> (Int32, String) {
        let components = path.components
        return (try directoryFD(for: Array(components.dropLast()), create: create), components.last!)
    }

    private func directoryEntryNames(at fd: Int32) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard copy >= 0 else { throw fileStoreError() }
        guard let directory = fdopendir(copy) else { close(copy); throw fileStoreError() }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw fileStoreError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            names.append(name)
        }
        return names
    }

    private func isSafeTopLevelName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0) && !ReservedNamespace.isReservedTopLevelName(name)
    }

    private func requireMovablePath(_ path: RelativePath) throws {
        guard path.components.allSatisfy({ !ReservedNamespace.isReservedComponent($0) }) else { throw FileStoreError.invalidStage }
    }

    private func directoryFD(for components: [String], create: Bool) throws -> Int32 {
        pathLookups += 1
        var fd = dup(rootFD)
        guard fd >= 0 else { throw fileStoreError() }
        do {
            for component in components {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, S_IRWXU) == 0 || errno == EEXIST else { throw fileStoreError() }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw fileStoreError() }
                if component == ".beepbar" { fchflags(next, UInt32(UF_HIDDEN)) }
                close(fd)
                fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private func openStage(_ stage: StageHandle, in staging: Int32, flags: Int32) throws -> Int32 {
        guard stage.name.hasSuffix(".partial") else { throw FileStoreError.invalidStage }
        let fd = openat(staging, stage.name, flags | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw fileStoreError() }
        guard try Self.identity(of: fd) == stage.identity else { close(fd); throw FileStoreError.invalidStage }
        try requireRegularFile(fd)
        return fd
    }

    private func requireRegularFile(_ fd: Int32) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw fileStoreError() }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw FileStoreError.ioFailure }
    }

    private func fileSize(of fd: Int32) throws -> Int64 {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw fileStoreError() }
        return Int64(metadata.st_size)
    }

    private func fileStoreError() -> FileStoreError { errno == ELOOP ? .symbolicLink : .ioFailure }

    private static func identity(of fd: Int32) throws -> FileIdentity {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw FileStoreError.ioFailure }
        return FileIdentity(device: Int64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private func sha256(of fd: Int32, checksCancellation: Bool) throws -> String {
        try hashContents(of: fd, checksCancellation: checksCancellation).sha256
    }

    /// Hashes the file like `sha256(of:)` and remembers the result for `currentSHA256(of:)`, but
    /// only when the file's state was the same before and after the read, so a hash of half-old,
    /// half-new bytes is never stored. Belt and braces: the entry is keyed by the stamp taken
    /// before the read, which a write during the read has already left behind.
    private func rememberingSHA256(of fd: Int32, checksCancellation: Bool) throws -> String {
        let before = try Self.contentStamp(of: fd)
        let hash = try sha256(of: fd, checksCancellation: checksCancellation)
        if try Self.contentStamp(of: fd) == before, inspectedHashes.updateValue(hash, forKey: before) == nil {
            inspectedOrder.append(before)
            if inspectedOrder.count > Self.inspectedHashLimit { inspectedHashes[inspectedOrder.removeFirst()] = nil }
        }
        return hash
    }

    /// The file's current SHA-256, reusing the one `inspect` computed when the file is provably in
    /// the same state, and reading it in full otherwise, exactly as before. Used only by
    /// `install`'s check before it swaps a downloaded update in: an update used to read the user's
    /// old copy in `inspect` and again here, a whole extra read of a possibly large file.
    ///
    /// Why reuse is safe here and only here: this check is not the last line of defence. It only
    /// ever saw the open file while the swap acts on the path, so even before this memo a change
    /// in between was caught by what follows: after the atomic swap, `install` hashes the
    /// displaced copy in full and swaps back if it isn't the expected one
    /// (`InstallHashReuseTests.editBetweenCheckAndSwapIsSwappedBack`). So a change the stamp can
    /// miss (see `contentStamp(of:)`) still ends as `.localChanged` with the user's file in place;
    /// after a crash between swap and that check, recovery finds the user's bytes in staging and
    /// leaves the operation unresolved rather than deleting anything. The displaced-copy hash,
    /// `discard`, rollbacks and conflict paths have nothing behind them and must keep reading in
    /// full; never route them through here.
    ///
    /// Any difference in the stamp falls back to a full hash rather than to `.localChanged`, so the
    /// outcome never changes: a file edited and then restored to identical bytes still installs.
    private func currentSHA256(of fd: Int32) throws -> String {
        if let known = inspectedHashes[try Self.contentStamp(of: fd)] { return known }
        return try sha256(of: fd, checksCancellation: false)
    }

    /// What `fstat` says about a file's identity and content state. On APFS, the sync folder's
    /// usual home, any write changes the ctime to the nanosecond, and only the kernel sets it
    /// (`utimes` can restore the mtime, not the ctime); a save that replaces the file changes the
    /// inode. Elsewhere it is weaker: HFS+ keeps whole seconds, FAT and exFAT have no real ctime,
    /// SMB clients cache attributes, and writes through `mmap` are timestamped late everywhere.
    /// That is why only a check backed by the post-swap hash may trust it.
    private static func contentStamp(of fd: Int32) throws -> ContentStamp {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw FileStoreError.ioFailure }
        return ContentStamp(
            device: Int64(metadata.st_dev), inode: UInt64(metadata.st_ino), size: Int64(metadata.st_size),
            modified: Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_mtimespec.tv_nsec),
            changed: Int64(metadata.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private func hashContents(of fd: Int32, copyingTo destinationFD: Int32? = nil, maximumSize: Int64? = nil, checksCancellation: Bool) throws -> (sha256: String, size: Int64) {
        if checksCancellation { try Task.checkCancellation() }
        hashCount += 1
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw FileStoreError.ioFailure }
        let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        var total: Int64 = 0
        var hash = SHA256()
        try Self.forEachChunk(of: handle) { chunk in
            beforeReadChunk?(checksCancellation, total)
            if checksCancellation { try Task.checkCancellation() }
            total += Int64(chunk.count)
            bytesHashed += Int64(chunk.count)
            if let maximumSize, total > maximumSize { throw FileStoreError.tooLarge }
            hash.update(data: chunk)
            if let destinationFD { try Self.write(chunk, to: destinationFD) }
        }
        if checksCancellation { try Task.checkCancellation() }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    /// Reads `handle` from its current offset to the end in 1 MiB chunks, each read and handled
    /// inside its own autorelease pool. Every file read and copy in this store goes through here.
    ///
    /// `FileHandle.read(upToCount:)` returns its buffer autoreleased, and a sync runs on a
    /// cooperative thread whose pool only drains once the whole call returns. Without a pool per
    /// chunk, every chunk of the file stayed alive until then: updating a 256 MiB file, which then
    /// read it five times, peaked at about 1 GiB (`large-update` in docs/benchmarks.md). With it, the
    /// peak stays at a few MiB whatever the size, as the "peak memory independent of file size"
    /// budget in AGENTS.md requires. The read must stay inside the pool, not in a `while let`
    /// condition outside it, or its buffer escapes the drain.
    private static func forEachChunk(of handle: FileHandle, _ body: (Data) throws -> Void) throws {
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            try body(chunk)
            return true
        }) {}
    }
}

extension FileStore {
    /// Where a file goes when the user chooses to trash it and no caller supplied its own policy:
    /// the Finder trash. On Linux, where only the Core tests run and there is no trash, it is
    /// moved under a per-process folder in the temporary directory, so a test can still prove
    /// that nothing was deleted outright.
    public static let defaultTrash: @Sendable (URL) throws -> Void = {
#if canImport(Darwin)
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
#else
        let trash = FileManager.default.temporaryDirectory.appending(path: "beepbar-trash-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: $0, to: trash.appending(path: "\(UUID().uuidString)-\($0.lastPathComponent)", directoryHint: .notDirectory))
#endif
    }
}

/// `write(2)`, named so it is not shadowed by `FileStore`'s own `write` methods.
#if canImport(Darwin)
private let posixWrite = Darwin.write
#else
private let posixWrite = Glibc.write
#endif
