import Foundation

public struct PreparedSyncItem: Sendable, Equatable, Identifiable {
    public let remote: RemoteFileCandidate
    public let destination: RelativePath

    public var id: String { remote.id }

    public init(remote: RemoteFileCandidate, destination: RelativePath) {
        self.remote = remote
        self.destination = destination
    }
}

public struct SyncedItem: Sendable, Equatable, Codable, Identifiable, Hashable {
    public enum Kind: Sendable, Equatable, Codable { case added, updated }

    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct FailedSyncItem: Sendable, Equatable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let reason: String

    public init(id: String, name: String, reason: String) {
        self.id = id
        self.name = name
        self.reason = reason
    }
}

public struct CourseSyncCount: Sendable, Equatable, Codable, Identifiable {
    public let courseID: Int64
    public let courseFolder: String
    public let added: Int
    public let updated: Int
    public let items: [SyncedItem]
    public let failedItems: [FailedSyncItem]
    /// Set when the course's contents could not be read at all, so none of its files were checked.
    public let courseFailure: String?

    public var id: Int64 { courseID }
    public var total: Int { added + updated + failedItems.count + (courseFailure == nil ? 0 : 1) }

    public init(courseID: Int64, courseFolder: String, added: Int, updated: Int, items: [SyncedItem] = [], failedItems: [FailedSyncItem] = [], courseFailure: String? = nil) {
        self.courseID = courseID
        self.courseFolder = courseFolder
        self.added = added
        self.updated = updated
        self.items = items
        self.failedItems = failedItems
        self.courseFailure = courseFailure
    }

    private enum CodingKeys: String, CodingKey { case courseID, courseFolder, added, updated, items, failedItems, courseFailure }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        courseID = try values.decode(Int64.self, forKey: .courseID)
        courseFolder = try values.decode(String.self, forKey: .courseFolder)
        added = try values.decode(Int.self, forKey: .added)
        updated = try values.decode(Int.self, forKey: .updated)
        items = try values.decodeIfPresent([SyncedItem].self, forKey: .items) ?? []
        failedItems = try values.decodeIfPresent([FailedSyncItem].self, forKey: .failedItems) ?? []
        courseFailure = try values.decodeIfPresent(String.self, forKey: .courseFailure)
    }
}

public struct SyncProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let added: Int
    public let updated: Int
    public let preservedLocal: Int
    public let unchanged: Int
    public let conflicts: Int
    public let failures: Int
    public let perCourse: [CourseSyncCount]

    public var installed: Int { added + updated }
    /// Courses whose contents could not be read; each one also counts as one failure.
    public var failedCourses: Int { perCourse.filter { $0.courseFailure != nil }.count }

    /// The same run with `failures` courses that could not be read at all folded in.
    func addingCourseFailures(_ failures: [CourseSyncCount]) -> SyncProgress {
        guard !failures.isEmpty else { return self }
        let merged = (perCourse + failures).sorted { $0.courseFolder.localizedStandardCompare($1.courseFolder) == .orderedAscending }
        return SyncProgress(completed: completed, total: total, added: added, updated: updated, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: self.failures + failures.count, perCourse: merged)
    }

    public init(completed: Int, total: Int, added: Int, updated: Int, preservedLocal: Int, unchanged: Int, conflicts: Int, failures: Int, perCourse: [CourseSyncCount] = []) {
        self.completed = completed
        self.total = total
        self.added = added
        self.updated = updated
        self.preservedLocal = preservedLocal
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.failures = failures
        self.perCourse = perCourse
    }

    public init(completed: Int, total: Int, installed: Int, preservedLocal: Int, unchanged: Int, conflicts: Int, failures: Int) {
        self.init(completed: completed, total: total, added: installed, updated: 0, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: failures)
    }
}

public enum SyncDownloadError: Error, Sendable, Equatable {
    case authorizationRejected(Int)
}

public actor ManualSyncRun {
    private let rootID: UUID
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate
    private let maximumConcurrentDownloads: Int
    private let downloader: RemoteDownloader
    private let networkAccess: NetworkAccess

    public init(rootID: UUID, database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate, downloader: RemoteDownloader, networkAccess: NetworkAccess, maximumConcurrentDownloads: Int = 3) {
        self.rootID = rootID
        self.database = database
        self.fileStore = fileStore
        self.gate = gate
        self.maximumConcurrentDownloads = maximumConcurrentDownloads
        self.downloader = downloader
        self.networkAccess = networkAccess
    }

    public func start(items: [PreparedSyncItem], token: String, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        let runID = UUID()
        return try await gate.withLease(.syncing(runID)) {
            try await self.startWithinLease(items: items, token: token, progress: progress)
        }
    }

    public func startWithinLease(items: [PreparedSyncItem], token: String, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        let normalizedDestinations = items.map(\.destination.comparisonKey)
        guard Set(items.map(\.id)).count == items.count, Set(normalizedDestinations).count == items.count else { throw SyncDatabaseError.execution }
        return try await execute(items: items, token: token, progress: progress)
    }

    private func execute(items: [PreparedSyncItem], token: String, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        let trace = PerformanceTrace.shared.begin("sync.downloadBatch", category: .sync)
        defer { PerformanceTrace.shared.end("sync.downloadBatch", category: .sync, state: trace) }
        var completed = 0
        var added = 0
        var updated = 0
        var preservedLocal = 0
        var unchanged = 0
        var conflicts = 0
        var failures = 0
        var perCourseAdded: [Int64: Int] = [:]
        var perCourseUpdated: [Int64: Int] = [:]
        var perCourseFolder: [Int64: String] = [:]
        var perCourseItems: [Int64: [SyncedItem]] = [:]
        var perCourseFailures: [Int64: [FailedSyncItem]] = [:]
        var serviceFailures = 0
        var firstServiceStatus: Int?
        try await withThrowingTaskGroup(of: (PreparedSyncItem, ManualSyncOutcome?, String?, Int?).self) { group in
            var next = 0
            func enqueue(_ item: PreparedSyncItem) {
                group.addTask { [rootID, database, fileStore, downloader, networkAccess] in
                    do {
                        let engine = ManualSyncEngine(rootID: rootID, database: database, fileStore: fileStore, downloader: downloader, networkAccess: networkAccess)
                        return (item, try await engine.sync(file: item.remote, destination: item.destination, token: token), nil, nil)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as RemoteDownloadError {
                        switch error {
                        case .network(let failure):
                            throw WeBeepAPIError.network(failure)
                        case .transport(let status) where status == 401 || status == 403:
                            throw SyncDownloadError.authorizationRejected(status)
                        case .transport(let status) where status >= 500:
                            return (item, nil, tr("Errore del server (\(status)).", "Server error (\(status))."), status)
                        case .unsupportedFile:
                            return (item, nil, tr("Formato non supportato.", "Unsupported format."), nil)
                        case .missingURL, .invalidSize:
                            return (item, nil, tr("Metadati del file non validi.", "Invalid file metadata."), nil)
                        case .unsafeURL, .unexpectedRedirect:
                            return (item, nil, tr("Indirizzo di download non sicuro.", "Unsafe download address."), nil)
                        case .invalidResponse:
                            return (item, nil, tr("Risposta di download non valida.", "Invalid download response."), nil)
                        case .tooLarge:
                            return (item, nil, tr("File troppo grande.", "File too large."), nil)
                        default:
                            return (item, nil, tr("Download non riuscito.", "Download failed."), nil)
                        }
                    } catch {
                        return (item, nil, tr("Impossibile salvare il file.", "Could not save the file."), nil)
                    }
                }
            }
            while next < min(maximumConcurrentDownloads, items.count) { enqueue(items[next]); next += 1 }
            while let (item, outcome, failureReason, serviceStatus) = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                let courseID = item.remote.courseID
                switch outcome {
                case .installedNew?:
                    added += 1
                    perCourseAdded[courseID, default: 0] += 1
                    perCourseFolder[courseID] = Self.courseFolder(for: item.destination)
                    perCourseItems[courseID, default: []].append(Self.syncedItem(for: item, kind: .added))
                case .installedReplacing?:
                    updated += 1
                    perCourseUpdated[courseID, default: 0] += 1
                    perCourseFolder[courseID] = Self.courseFolder(for: item.destination)
                    perCourseItems[courseID, default: []].append(Self.syncedItem(for: item, kind: .updated))
                case .adoptedRemoteBaseline?: unchanged += 1
                case .preservedLocal?: preservedLocal += 1
                case .unchanged?, .skipped?: unchanged += 1
                case .conflict?: conflicts += 1
                case nil:
                    failures += 1
                    perCourseFolder[courseID] = Self.courseFolder(for: item.destination)
                    perCourseFailures[courseID, default: []].append(Self.failedItem(for: item, reason: failureReason ?? tr("Errore sconosciuto.", "Unknown error.")))
                    if let serviceStatus {
                        serviceFailures += 1
                        firstServiceStatus = firstServiceStatus ?? serviceStatus
                    }
                }
                if next < items.count { enqueue(items[next]); next += 1 }
                await progress(SyncProgress(completed: completed, total: items.count, added: added, updated: updated, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: failures))
            }
        }
        try Task.checkCancellation()
        if !items.isEmpty, serviceFailures == items.count { throw WeBeepAPIError.transport(firstServiceStatus ?? 503) }
        return SyncProgress(completed: completed, total: items.count, added: added, updated: updated, preservedLocal: preservedLocal, unchanged: unchanged, conflicts: conflicts, failures: failures, perCourse: Self.snapshotPerCourse(added: perCourseAdded, updated: perCourseUpdated, folders: perCourseFolder, items: perCourseItems, failures: perCourseFailures))
    }

    static func courseFolder(for destination: RelativePath) -> String {
        destination.value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? destination.value
    }

    static func syncedItem(for item: PreparedSyncItem, kind: SyncedItem.Kind) -> SyncedItem {
        let name = item.destination.value.split(separator: "/").last.map(String.init) ?? item.destination.value
        return SyncedItem(id: item.id, name: name, kind: kind)
    }

    static func failedItem(for item: PreparedSyncItem, reason: String) -> FailedSyncItem {
        let name = item.destination.value.split(separator: "/").last.map(String.init) ?? item.destination.value
        return FailedSyncItem(id: item.id, name: name, reason: reason)
    }

    static func snapshotPerCourse(added: [Int64: Int], updated: [Int64: Int], folders: [Int64: String], items: [Int64: [SyncedItem]], failures: [Int64: [FailedSyncItem]] = [:]) -> [CourseSyncCount] {
        let ids = Set(added.keys).union(updated.keys).union(failures.keys)
        return ids.map { id in
            let sortedItems = (items[id] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let sortedFailures = (failures[id] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return CourseSyncCount(courseID: id, courseFolder: folders[id] ?? "", added: added[id] ?? 0, updated: updated[id] ?? 0, items: sortedItems, failedItems: sortedFailures)
        }.sorted { $0.courseFolder.localizedStandardCompare($1.courseFolder) == .orderedAscending }
    }
}
