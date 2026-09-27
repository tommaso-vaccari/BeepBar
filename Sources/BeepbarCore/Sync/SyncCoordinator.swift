import Foundation

public struct SyncTarget: Sendable, Equatable {
    public let courseID: Int64
    public let localFolder: String

    public init(courseID: Int64, localFolder: String) {
        self.courseID = courseID
        self.localFolder = localFolder
    }
}

public enum SyncCoordinatorMode: Sendable {
    case manual
    case automatic

    var metadataConcurrency: Int { self == .manual ? 3 : 2 }
    var downloadConcurrency: Int { self == .manual ? 3 : 2 }
    // A scheduled run happens behind the user's back: it must not pull material over a metered
    // hotspot, and it has to honour Low Data Mode.
    var networkAccess: NetworkAccess { self == .manual ? .unrestricted : .background }
}

public actor SyncCoordinator {
    private let rootID: UUID
    private let rootURL: URL
    private let database: SyncDatabase
    let fileStore: FileStore
    private let gate: RootOperationGate
    private let apiClient: WeBeepAPIClient
    private let downloader: RemoteDownloader
    private let platformName: String

    /// `platformName` is how the user knows the site ("WeBeep", "Moodle"); it only appears in the
    /// reason shown for a course whose contents could not be read.
    public init(rootID: UUID, rootURL: URL, database: SyncDatabase, gate: RootOperationGate, apiClient: WeBeepAPIClient, downloader: RemoteDownloader, platformName: String = "Moodle") throws {
        self.rootID = rootID
        self.rootURL = rootURL
        self.database = database
        self.fileStore = try FileStore(root: rootURL)
        self.gate = gate
        self.apiClient = apiClient
        self.downloader = downloader
        self.platformName = platformName
    }

    public func synchronize(targets: [SyncTarget], token: String, mode: SyncCoordinatorMode, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        let trace = PerformanceTrace.shared.begin("sync.run", category: .sync)
        defer { PerformanceTrace.shared.end("sync.run", category: .sync, state: trace) }
        let runID = UUID()
        return try await gate.withLease(.syncing(runID)) {
            try await self.synchronizeWithinLease(targets: targets, token: token, mode: mode, progress: progress)
        }
    }

    private func synchronizeWithinLease(targets: [SyncTarget], token: String, mode: SyncCoordinatorMode, progress: @escaping @Sendable (SyncProgress) async -> Void) async throws -> SyncProgress {
        try Task.checkCancellation()
        guard try await database.hasPendingModuleMoves(rootID: rootID) == false else { throw SyncDatabaseError.execution }
        guard !targets.isEmpty else { return SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0) }
        try await ensureManagedDirectories(targets)
        let baselines: [String: Baseline]
        do {
            let trace = PerformanceTrace.shared.begin("sync.baselines", category: .database)
            defer { PerformanceTrace.shared.end("sync.baselines", category: .database, state: trace) }
            baselines = try await database.baselines(rootID: rootID)
        }
        let prepared: (items: [PreparedSyncItem], baselines: [String: Baseline], failedCourses: [CourseSyncCount], moved: [Int64: [MovedSyncItem]])
        do {
            let trace = PerformanceTrace.shared.begin("sync.metadata", category: .sync)
            defer { PerformanceTrace.shared.end("sync.metadata", category: .sync, state: trace) }
            prepared = try await prepareItems(targets: targets, token: token, baselines: baselines, concurrency: mode.metadataConcurrency)
        }
        let work: [PreparedSyncItem]
        do {
            let trace = PerformanceTrace.shared.begin("sync.planning", category: .sync)
            defer { PerformanceTrace.shared.end("sync.planning", category: .sync, state: trace) }
            work = try await itemsRequiringReconciliation(prepared.items, baselines: prepared.baselines)
        }
        let courseFolders = Dictionary(targets.map { ($0.courseID, $0.localFolder) }, uniquingKeysWith: { first, _ in first })
        // Courses Moodle refused still have to reach the summary, or a run where every other
        // course is unchanged would report a clean sync. Files moved to follow Moodle too.
        guard !work.isEmpty else {
            return SyncProgress(completed: 0, total: 0, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
                .addingCourseFailures(prepared.failedCourses)
                .addingMovedItems(prepared.moved, folders: courseFolders)
        }
        let runner = ManualSyncRun(rootID: rootID, database: database, fileStore: fileStore, gate: gate, downloader: downloader, networkAccess: mode.networkAccess, maximumConcurrentDownloads: mode.downloadConcurrency)
        do {
            let result = try await runner.startWithinLease(items: work, token: token, progress: progress)
            // Files first downloaded by this run get the placement they were downloaded with, so a
            // move made on Moodle before the next run is followed. Best effort: the run itself
            // succeeded, and a placement that is not recorded now is recorded, without moving
            // anything, by the next run.
            let placements = Dictionary(work.map { ($0.remote.id, RemotePlacement($0.remote)) }, uniquingKeysWith: { first, _ in first })
            try? await database.recordRemotePlacements(rootID: rootID, placements, onlyIfMissing: true)
            return result
                .addingCourseFailures(prepared.failedCourses)
                .addingMovedItems(prepared.moved, folders: courseFolders)
        } catch SyncDownloadError.authorizationRejected(let status) {
            do {
                _ = try await apiClient.validateToken(token)
            } catch WeBeepAPIError.invalidToken {
                throw WeBeepAPIError.invalidToken
            }
            throw WeBeepAPIError.transport(status)
        }
    }

    private func ensureManagedDirectories(_ targets: [SyncTarget]) async throws {
        let scopes = try await database.scopes(rootID: rootID)
        let scopesByCourse = Dictionary(scopes.map { ($0.courseID, $0) }, uniquingKeysWith: { first, _ in first })
        for target in targets {
            try Task.checkCancellation()
            let result = try await fileStore.ensureTopLevelDirectory(target.localFolder)
            // A folder that was already there (a root chosen again, a folder the user made first)
            // is adopted the first time it is synced into, or renaming the course could never
            // prove it is the same directory later on.
            // A freshly created folder always records the target (this also repairs a legacy scope
            // saved without a folder); adoption only applies to the folder the scope already names.
            guard let scope = scopesByCourse[target.courseID] else { continue }
            if result.created || (scope.managedDirectory == nil && scope.localFolder == target.localFolder) {
                try await database.upsertScope(SyncScope(rootID: rootID, courseID: scope.courseID, displayName: scope.displayName, localFolder: target.localFolder, enabled: scope.enabled, managedDirectory: result.identity))
            }
        }
    }

    private func prepareItems(targets: [SyncTarget], token: String, baselines: [String: Baseline], concurrency: Int) async throws -> (items: [PreparedSyncItem], baselines: [String: Baseline], failedCourses: [CourseSyncCount], moved: [Int64: [MovedSyncItem]]) {
        try await withThrowingTaskGroup(of: (Int, Result<[RemoteFileCandidate], WeBeepAPIError>).self) { group in
            var next = 0
            var fetched: [(Int, [RemoteFileCandidate])] = []
            var failedIndices: [(Int, WeBeepAPIError)] = []
            func enqueue(_ index: Int) {
                let target = targets[index]
                group.addTask { [apiClient] in
                    try Task.checkCancellation()
                    let contents: RemoteCourseContents
                    do {
                        contents = try await apiClient.fetchContents(courseID: target.courseID, token: token)
                    } catch let error as WeBeepAPIError where Self.isCourseScoped(error) {
                        return (index, .failure(error))
                    }
                    try Task.checkCancellation()
                    return (index, .success(contents.sections.flatMap(\.modules).flatMap(\.files).filter(\.isSupported)))
                }
            }
            while next < min(concurrency, targets.count) { enqueue(next); next += 1 }
            while let (index, result) = try await group.next() {
                switch result {
                case .success(let files): fetched.append((index, files))
                case .failure(let error): failedIndices.append((index, error))
                }
                if next < targets.count { enqueue(next); next += 1 }
            }
            failedIndices.sort { $0.0 < $1.0 }
            // One course the site refuses (no longer enrolled, hidden, restricted) is that course's
            // problem. When every course fails with an error about the site or the connection (a
            // server error, a captive portal answering with HTML), the site is the problem.
            if let first = failedIndices.first, fetched.isEmpty, failedIndices.allSatisfy({ Self.isSiteLevel($0.1) }) {
                throw first.1
            }
            let reason = tr("Corso non accessibile su \(platformName).", "Course not accessible on \(platformName).")
            let failedCourses = failedIndices.map { index, _ in
                CourseSyncCount(courseID: targets[index].courseID, courseFolder: targets[index].localFolder, added: 0, updated: 0, courseFailure: reason)
            }
            let allFiles = fetched.flatMap { $0.1 }
            try Self.validateUniqueRemoteIDs(allFiles)
            try await database.backfillModuleOwnership(rootID: rootID, files: allFiles)
            var currentBaselines = try await database.baselines(rootID: rootID)
            for file in allFiles {
                guard let baseline = currentBaselines[file.id] else { continue }
                guard (baseline.courseID == nil && baseline.moduleID == nil)
                        || (baseline.courseID == file.courseID && baseline.moduleID == file.moduleID) else {
                    throw SyncDatabaseError.execution
                }
            }
            var deferredIDs: Set<String> = []
            var deferredLegacyIDs: Set<String> = []
            var baselineIDsByPath: [RelativePath: [String]]?
            var overridesByCourse: [Int64: [Int64: ModulePathOverride]] = [:]
            for target in targets {
                overridesByCourse[target.courseID] = try await database.modulePathOverrides(rootID: rootID, courseID: target.courseID)
            }
            for (index, files) in fetched.sorted(by: { $0.0 < $1.0 }) {
                for file in files where currentBaselines[file.id] == nil {
                    let preferred = try LocalPathPolicy.destination(courseFolder: targets[index].localFolder, file: file)
                    if baselineIDsByPath == nil {
                        var indexed: [RelativePath: [String]] = [:]
                        for (remoteID, baseline) in currentBaselines {
                            indexed[baseline.relativePath, default: []].append(remoteID)
                        }
                        baselineIDsByPath = indexed
                    }
                    let legacyIDs = (baselineIDsByPath?[preferred] ?? []).filter { Self.isLegacyRemoteID($0, for: file) }
                    guard legacyIDs.count == 1, let legacyID = legacyIDs.first else { continue }
                    guard let migrated = try await database.migrateLegacyBaseline(rootID: rootID, legacyRemoteID: legacyID, remoteID: file.id, courseID: file.courseID, moduleID: file.moduleID) else {
                        deferredIDs.insert(file.id)
                        deferredLegacyIDs.insert(legacyID)
                        continue
                    }
                    currentBaselines.removeValue(forKey: legacyID)
                    currentBaselines[file.id] = migrated
                    baselineIDsByPath?[preferred]?.removeAll { $0 == legacyID }
                }
            }
            for file in allFiles where !file.moduleName.isEmpty && overridesByCourse[file.courseID]?[file.moduleID] != nil {
                try await database.updateModulePathOverrideName(rootID: rootID, courseID: file.courseID, moduleID: file.moduleID, name: file.moduleName)
            }
            // Before any destination is chosen: a file that follows Moodle keeps its new path as its
            // destination for the rest of the run, and the paths reserved below are the new ones.
            let followed = try await followRemoteMoves(fetched: fetched, targets: targets, baselines: currentBaselines, overrides: overridesByCourse, skipping: deferredIDs)
            currentBaselines = followed.baselines
            var items: [PreparedSyncItem] = []
            // A baseline still claimed by a remote item owns its path whether or not the local file
            // survives, so a newcomer resolving to the same name gets a suffix instead of colliding.
            // Unclaimed (ghost) baselines only keep their name while a regular file is still there.
            let claimedIDs = Set(fetched.flatMap { $0.1.map(\.id) }).union(deferredLegacyIDs)
            var reservedPaths: Set<String> = []
            var ghostPaths: [RelativePath] = []
            for (remoteID, baseline) in currentBaselines {
                if claimedIDs.contains(remoteID) {
                    reservedPaths.insert(baseline.relativePath.comparisonKey)
                } else {
                    ghostPaths.append(baseline.relativePath)
                }
            }
            for path in try await fileStore.existingRegularFiles(ghostPaths) {
                reservedPaths.insert(path.comparisonKey)
            }
            for (index, files) in fetched.sorted(by: { $0.0 < $1.0 }) {
                for file in files where !deferredIDs.contains(file.id) {
                    try Task.checkCancellation()
                    let destination: RelativePath
                    if let baseline = currentBaselines[file.id] {
                        destination = baseline.relativePath
                    } else {
                        let override = overridesByCourse[file.courseID]?[file.moduleID]?.localFolder
                        let preferred = try LocalPathPolicy.destination(courseFolder: targets[index].localFolder, file: file, moduleFolderOverride: override)
                        destination = try LocalPathPolicy.uniqueDestination(preferred, reserving: &reservedPaths)
                    }
                    items.append(PreparedSyncItem(remote: file, destination: destination))
                }
            }
            try validateNoDestinationCollisions(items)
            return (items, currentBaselines, failedCourses, followed.moved)
        }
    }

    /// Moves tracked files that Moodle moved to another section, or whose module it renamed, so the
    /// local folders keep matching Moodle (see `RemoteMovePolicy` for what counts as a move).
    ///
    /// Local files are never overwritten or lost. A file is only moved when its contents are still
    /// exactly what was downloaded and its new place is free; a file edited since, or one whose new
    /// place is taken, stays where it is and is reported, and its new placement is recorded so it
    /// is reported once. A file with an open conflict or an unfinished download is skipped without
    /// recording anything, so it follows the move once that is settled.
    ///
    /// There is no journal: the file is renamed first and the baseline updated second. A crash in
    /// between leaves the file at its new path with the old placement still recorded, and the next
    /// run finds the old path empty and the new one holding the downloaded contents, and just
    /// points the baseline there.
    private func followRemoteMoves(fetched: [(Int, [RemoteFileCandidate])], targets: [SyncTarget], baselines: [String: Baseline], overrides: [Int64: [Int64: ModulePathOverride]], skipping: Set<String>) async throws -> (baselines: [String: Baseline], moved: [Int64: [MovedSyncItem]]) {
        let placements = try await database.remotePlacements(rootID: rootID)
        var firstPlacements: [String: RemotePlacement] = [:]
        var changedPlacements: [String: RemotePlacement] = [:]
        var planned: [(file: RemoteFileCandidate, baseline: Baseline, target: RelativePath)] = []
        for (index, files) in fetched {
            let courseFolder = targets[index].localFolder
            for file in files where !skipping.contains(file.id) {
                guard let baseline = baselines[file.id] else { continue }
                let override = overrides[file.courseID]?[file.moduleID]?.localFolder
                // A name the path rules reject stays where it is; the download step reports it.
                guard let decision = try? RemoteMovePolicy.decide(baselinePath: baseline.relativePath, recorded: placements[file.id], file: file, courseFolder: courseFolder, moduleFolderOverride: override) else { continue }
                switch decision {
                case .unchanged:
                    break
                case .record:
                    if placements[file.id] == nil { firstPlacements[file.id] = RemotePlacement(file) } else { changedPlacements[file.id] = RemotePlacement(file) }
                case .move(let target):
                    planned.append((file, baseline, target))
                }
            }
        }
        var current = baselines
        var moved: [Int64: [MovedSyncItem]] = [:]
        if !planned.isEmpty {
            let conflicts = try await database.conflicts(rootID: rootID)
            let unsettled = Set(conflicts.map(\.remoteID)).union(try await database.pendingOperations(rootID: rootID).map(\.remoteID))
            // Who owns each path, so a file never moves onto another tracked file or an open conflict.
            var owners: [String: String] = [:]
            for (remoteID, baseline) in current { owners[baseline.relativePath.comparisonKey] = remoteID }
            for conflict in conflicts where owners[conflict.relativePath.comparisonKey] == nil { owners[conflict.relativePath.comparisonKey] = conflict.remoteID }
            for plan in planned.sorted(by: { $0.file.id < $1.file.id }) {
                try Task.checkCancellation()
                let id = plan.file.id
                guard !unsettled.contains(id) else { continue }
                let placement = RemotePlacement(plan.file)
                let old = plan.baseline.relativePath
                func report(_ outcome: MovedSyncItem.Outcome) {
                    let folder = plan.target.components.dropFirst().dropLast().joined(separator: "/")
                    moved[plan.file.courseID, default: []].append(MovedSyncItem(id: id, name: plan.target.components.last ?? plan.target.value, folder: folder, outcome: outcome))
                }
                // Only the letter case changed: on a case-insensitive disk it is the same place.
                if plan.target.comparisonKey == old.comparisonKey { changedPlacements[id] = placement; continue }
                if let owner = owners[plan.target.comparisonKey], owner != id {
                    changedPlacements[id] = placement
                    report(.keptOccupied)
                    continue
                }
                let source: FileSnapshotState
                do { source = try await fileStore.snapshotRegularFile(old) } catch { changedPlacements[id] = placement; continue }
                var movedFile = false
                switch source {
                case .missing:
                    // Nothing to move: the user deleted it (it is downloaded again, now in its new
                    // place) or an earlier run was interrupted right after moving it. Either way
                    // only the baseline is pointed at the new place, and only when that place is
                    // free or already holds exactly the downloaded contents.
                    if case .present(let there)? = try? await fileStore.snapshotRegularFile(plan.target) {
                        guard there.sha256 == plan.baseline.sha256 else { changedPlacements[id] = placement; continue }
                    } else if try await fileStore.migrationDestinationIsOccupied(plan.target) {
                        changedPlacements[id] = placement
                        continue
                    }
                case .present(let snapshot):
                    guard snapshot.sha256 == plan.baseline.sha256 else {
                        changedPlacements[id] = placement
                        report(.keptEdited)
                        continue
                    }
                    guard try await fileStore.migrationDestinationIsOccupied(plan.target) == false else {
                        changedPlacements[id] = placement
                        report(.keptOccupied)
                        continue
                    }
                    do {
                        try await fileStore.moveRegularFilePreservingCurrentContents(from: old, to: plan.target, expected: snapshot)
                    } catch FileStoreError.destinationExists {
                        changedPlacements[id] = placement
                        report(.keptOccupied)
                        continue
                    } catch {
                        // Changed or unreadable while being moved: left alone, tried again next run.
                        continue
                    }
                    movedFile = true
                }
                guard try await database.commitRemoteMove(rootID: rootID, remoteID: id, from: old, to: plan.target, placement: placement) else { continue }
                current[id] = Baseline(remoteID: id, relativePath: plan.target, sha256: plan.baseline.sha256, remoteRevision: plan.baseline.remoteRevision, courseID: plan.baseline.courseID, moduleID: plan.baseline.moduleID)
                owners.removeValue(forKey: old.comparisonKey)
                owners[plan.target.comparisonKey] = id
                if movedFile {
                    // Tidying up is best effort; the move is already recorded.
                    try? await fileStore.removeEmptyParentDirectories(of: old)
                    report(.moved)
                }
            }
        }
        try await database.recordRemotePlacements(rootID: rootID, firstPlacements, onlyIfMissing: true)
        try await database.recordRemotePlacements(rootID: rootID, changedPlacements, onlyIfMissing: false)
        return (current, moved)
    }

    private func itemsRequiringReconciliation(_ items: [PreparedSyncItem], baselines: [String: Baseline]) async throws -> [PreparedSyncItem] {
        func hasCurrentBaseline(_ item: PreparedSyncItem) -> Bool {
            baselines[item.remote.id]?.remoteRevision == item.remote.observedRevision
        }
        let present = try await fileStore.existingRegularFiles(items.filter(hasCurrentBaseline).map(\.destination))
        return items.filter { !(hasCurrentBaseline($0) && present.contains($0.destination)) }
    }

    private func validateNoDestinationCollisions(_ items: [PreparedSyncItem]) throws {
        var identifiersByPath: [String: [String]] = [:]
        for item in items {
            identifiersByPath[item.destination.comparisonKey, default: []].append(item.remote.id)
        }
        guard identifiersByPath.values.allSatisfy({ $0.count == 1 }) else { throw SyncDatabaseError.execution }
    }

    /// Errors that describe one course's contents rather than the account or the connection. A
    /// rejected token, a lost network or a refused authorization still stop the whole run.
    private static func isCourseScoped(_ error: WeBeepAPIError) -> Bool {
        switch error {
        case .invalidToken, .network: false
        case .transport(let status): status != 401 && status != 403
        case .invalidResponse, .unexpectedRedirect, .responseTooLarge, .malformedPayload, .unexpectedSite, .missingRequiredFunction: true
        }
    }

    /// Errors that say nothing about the course itself: the server failed or something other than
    /// Moodle answered. A Moodle exception or a 4xx is about the course.
    private static func isSiteLevel(_ error: WeBeepAPIError) -> Bool {
        switch error {
        case .transport(let status): status >= 500
        case .invalidResponse, .unexpectedRedirect: true
        default: false
        }
    }

    static func validateUniqueRemoteIDs(_ files: [RemoteFileCandidate]) throws {
        guard Set(files.map(\.id)).count == files.count else { throw SyncDatabaseError.execution }
    }

    private static func isLegacyRemoteID(_ remoteID: String, for file: RemoteFileCandidate) -> Bool {
        let prefix = "\(file.courseID):\(file.moduleID):"
        guard remoteID.hasPrefix(prefix) else { return false }
        let path = remoteID.dropFirst(prefix.count)
        return path.hasPrefix("/webservice/pluginfile.php/") || path.hasPrefix("/pluginfile.php/")
    }
}
