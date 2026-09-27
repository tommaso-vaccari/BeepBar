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
    public init(rootID: UUID, rootURL: URL, database: SyncDatabase, gate: RootOperationGate, apiClient: WeBeepAPIClient, downloader: RemoteDownloader, platformName: String = "Moodle", fileStore: FileStore? = nil) throws {
        self.rootID = rootID
        self.rootURL = rootURL
        self.database = database
        self.fileStore = try fileStore ?? FileStore(root: rootURL)
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
        // Before any baseline is read: a move interrupted by a crash is completed or dropped first.
        try await RemoteMoveJournal.recover(rootID: rootID, database: database, fileStore: fileStore)
        try await ensureManagedDirectories(targets)
        let baselines: [String: Baseline]
        do {
            let trace = PerformanceTrace.shared.begin("sync.baselines", category: .database)
            defer { PerformanceTrace.shared.end("sync.baselines", category: .database, state: trace) }
            baselines = try await database.baselines(rootID: rootID)
        }
        let prepared: PreparedRun
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
            let moved = try await recordRemoteChanges(prepared)
            return SyncProgress(completed: 0, total: 0, added: 0, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
                .addingCourseFailures(prepared.failedCourses)
                .addingMovedItems(moved, folders: courseFolders)
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
            let moved = try await recordRemoteChanges(prepared)
            return result
                .addingCourseFailures(prepared.failedCourses)
                .addingMovedItems(moved, folders: courseFolders)
        } catch SyncDownloadError.authorizationRejected(let status) {
            do {
                _ = try await apiClient.validateToken(token)
            } catch WeBeepAPIError.invalidToken {
                throw WeBeepAPIError.invalidToken
            }
            throw WeBeepAPIError.transport(status)
        }
    }

    /// Everything the metadata phase decided, handed to the download phase and to the summary.
    private struct PreparedRun {
        let items: [PreparedSyncItem]
        let baselines: [String: Baseline]
        let failedCourses: [CourseSyncCount]
        /// Files moved to follow Moodle in this run, by course.
        let moved: [Int64: [MovedSyncItem]]
        /// Courses Moodle listed in full this run: only their entries in Conflicts are replaced.
        let readCourseIDs: Set<Int64>
        /// The entries those courses need now (see `RemoteChange`).
        let changes: [RemoteChange]
    }

    /// Replaces the entries of the courses this run read, once the run has succeeded: a run that
    /// throws or is cancelled leaves the previous entries as they were. Returns the moved files to
    /// report, including each edited file that newly waits in Conflicts because Moodle moved it.
    private func recordRemoteChanges(_ prepared: PreparedRun) async throws -> [Int64: [MovedSyncItem]] {
        let created = try await database.reconcileRemoteChanges(rootID: rootID, courseIDs: prepared.readCourseIDs, desired: prepared.changes)
        var moved = prepared.moved
        for change in created where change.kind == .moved {
            guard let target = change.targetPath else { continue }
            moved[change.courseID, default: []].append(Self.movedItem(id: change.remoteID, at: target, outcome: .keptEdited))
        }
        return moved
    }

    /// What Moodle listed for one course, beyond the files that can be downloaded: used to tell a
    /// file that is gone from one Moodle only hid from this run.
    private struct CourseListing {
        let remoteIDs: Set<String>
        let modulesWithDroppedEntries: Set<Int64>
        let isComplete: Bool
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

    private func prepareItems(targets: [SyncTarget], token: String, baselines: [String: Baseline], concurrency: Int) async throws -> PreparedRun {
        try await withThrowingTaskGroup(of: (Int, Result<RemoteCourseContents, WeBeepAPIError>).self) { group in
            var next = 0
            var fetched: [(Int, [RemoteFileCandidate])] = []
            var listings: [Int64: CourseListing] = [:]
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
                    return (index, .success(contents))
                }
            }
            while next < min(concurrency, targets.count) { enqueue(next); next += 1 }
            while let (index, result) = try await group.next() {
                switch result {
                case .success(let contents):
                    let files = contents.sections.flatMap(\.modules).flatMap(\.files)
                    fetched.append((index, files.filter(\.isSupported)))
                    // Files Moodle lists but Beepbar cannot download still count as listed: they are
                    // not removed (a file that became an external link stays where it is).
                    listings[targets[index].courseID] = CourseListing(remoteIDs: Set(files.map(\.id)), modulesWithDroppedEntries: contents.modulesWithDroppedEntries, isComplete: contents.isComplete)
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
            let openChanges = Dictionary(try await database.remoteChanges(rootID: rootID).map { ($0.remoteID, $0) }, uniquingKeysWith: { first, _ in first })
            let unsettled = Set(try await database.conflicts(rootID: rootID).map(\.remoteID)).union(try await database.pendingOperations(rootID: rootID).map(\.remoteID))
            // Before any destination is chosen: a file that follows Moodle keeps its new path as its
            // destination for the rest of the run, and the paths reserved below are the new ones.
            let followed = try await followRemoteMoves(fetched: fetched, targets: targets, baselines: currentBaselines, overrides: overridesByCourse, skipping: deferredIDs, unsettled: unsettled, openChanges: openChanges)
            currentBaselines = followed.baselines
            var moved = followed.moved
            var changes = followed.changes
            let vanished = try await vanishedFiles(listings: listings, fetched: fetched, baselines: currentBaselines, excluding: unsettled.union(deferredLegacyIDs), deferredIDs: deferredIDs, openChanges: openChanges)
            changes += vanished.changes
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
                    var destination: RelativePath
                    if let baseline = currentBaselines[file.id] {
                        destination = baseline.relativePath
                    } else {
                        let override = overridesByCourse[file.courseID]?[file.moduleID]?.localFolder
                        let preferred = try LocalPathPolicy.destination(courseFolder: targets[index].localFolder, file: file, moduleFolderOverride: override)
                        let reupload = vanished.reuploads[file.id]
                        if let reupload, preferred.comparisonKey == reupload.ghost.relativePath.comparisonKey {
                            // Uploaded again in the very same place: the file already there is it,
                            // edited or not, so it just changes identity. Downloading the new copy
                            // onto an edited one would open a conflict about contents that did not
                            // change on Moodle.
                            destination = reupload.ghost.relativePath
                            if let adopted = try await adoptReupload(file, ghost: reupload.ghost, snapshot: nil, at: destination) {
                                currentBaselines.removeValue(forKey: reupload.ghost.remoteID)
                                currentBaselines[file.id] = adopted
                            }
                        } else if let reupload {
                            destination = try LocalPathPolicy.uniqueDestination(preferred, reserving: &reservedPaths)
                            if reupload.isModified {
                                // The new copy is downloaded; the user's edited copy waits in Conflicts.
                                changes.append(RemoteChange(rootID: rootID, courseID: file.courseID, remoteID: reupload.ghost.remoteID, kind: .reuploaded, relativePath: reupload.ghost.relativePath, targetPath: destination, newRemoteID: file.id, localSHA256: reupload.localSHA256, isLocallyModified: true))
                            } else if let adopted = try await adoptReupload(file, ghost: reupload.ghost, snapshot: reupload.snapshot, at: destination) {
                                currentBaselines.removeValue(forKey: reupload.ghost.remoteID)
                                currentBaselines[file.id] = adopted
                                if adopted.relativePath != reupload.ghost.relativePath {
                                    moved[file.courseID, default: []].append(Self.movedItem(id: file.id, at: adopted.relativePath, outcome: .moved))
                                }
                            } else {
                                // It could not be moved: the new copy is downloaded and the old one is
                                // treated as removed from Moodle.
                                changes.append(RemoteChange(rootID: rootID, courseID: file.courseID, remoteID: reupload.ghost.remoteID, kind: .removed, relativePath: reupload.ghost.relativePath, localSHA256: reupload.localSHA256, isLocallyModified: false))
                            }
                        } else {
                            destination = try LocalPathPolicy.uniqueDestination(preferred, reserving: &reservedPaths)
                        }
                    }
                    items.append(PreparedSyncItem(remote: file, destination: destination))
                }
            }
            try validateNoDestinationCollisions(items)
            return PreparedRun(items: items, baselines: currentBaselines, failedCourses: failedCourses, moved: moved, readCourseIDs: Set(listings.keys), changes: changes)
        }
    }

    /// Moves tracked files that Moodle moved to another section, or whose module it renamed, so the
    /// local folders keep matching Moodle (see `RemoteMovePolicy` for what counts as a move).
    ///
    /// Local files are never overwritten or lost:
    /// - A file whose contents are still exactly what was downloaded follows Moodle. When its new
    ///   place is taken by a file that is moving away too, the moves are ordered, and files that
    ///   swapped places are exchanged in one atomic rename. When it is taken by any other file, it
    ///   arrives with a number, as a download would (`Slide (1).pdf`).
    /// - A file edited since stays where it is and gets an entry in Conflicts; nothing is recorded,
    ///   so every sync re-checks the move and the entry closes by itself if Moodle moves it back.
    /// - A file with an open conflict or an unfinished download is skipped, so it follows the move
    ///   once that is settled.
    ///
    /// Every rename is journaled first (`PendingRemoteMove`), so a crash between the rename and the
    /// baseline update is completed by `RemoteMoveJournal.recover` at the next run.
    private func followRemoteMoves(fetched: [(Int, [RemoteFileCandidate])], targets: [SyncTarget], baselines: [String: Baseline], overrides: [Int64: [Int64: ModulePathOverride]], skipping: Set<String>, unsettled: Set<String>, openChanges: [String: RemoteChange]) async throws -> (baselines: [String: Baseline], moved: [Int64: [MovedSyncItem]], changes: [RemoteChange]) {
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
        var state = MoveState(current: baselines)
        var changes: [RemoteChange] = []
        if !planned.isEmpty {
            // Who owns each path, so a file never moves onto another tracked file or an open conflict.
            for (remoteID, baseline) in baselines { state.owners[baseline.relativePath.comparisonKey] = remoteID }
            for conflict in try await database.conflicts(rootID: rootID) where state.owners[conflict.relativePath.comparisonKey] == nil {
                state.owners[conflict.relativePath.comparisonKey] = conflict.remoteID
            }
            var movers: [Mover] = []
            for plan in planned.sorted(by: { $0.file.id < $1.file.id }) {
                try Task.checkCancellation()
                let id = plan.file.id
                guard !unsettled.contains(id) else { continue }
                let placement = RemotePlacement(plan.file)
                let old = plan.baseline.relativePath
                // Only the letter case changed: on a case-insensitive disk it is the same place.
                if plan.target.comparisonKey == old.comparisonKey { changedPlacements[id] = placement; continue }
                // An entry already asks the user about this very move: keep it without reading the
                // file again, so a sync with nothing new hashes nothing. The action re-checks it.
                if let open = openChanges[id], open.kind == .moved, open.relativePath == old, open.targetPath == plan.target, open.placement == placement,
                   !(try await fileStore.existingRegularFiles([old]).isEmpty) {
                    changes.append(open)
                    continue
                }
                let source: FileSnapshotState
                // Unreadable right now (permissions, an evicted cloud file, an I/O error): nothing
                // is recorded, so the move is tried again next run instead of being forgotten.
                do { source = try await fileStore.snapshotRegularFile(old) } catch { continue }
                switch source {
                case .missing:
                    // Nothing to move: the user deleted it, and it is downloaded again in its new
                    // place. Only the baseline follows: to that place when it is free, or already
                    // holds exactly the downloaded contents untracked (a move finished before a
                    // crash), and otherwise to a numbered name, as a download would. Never onto a
                    // path another tracked file owns, even with identical contents: two baselines
                    // on one path would make every later run fail its collision check.
                    let heldByAnother = state.owners[plan.target.comparisonKey].map { $0 != id } ?? false
                    var destination = plan.target
                    if heldByAnother {
                        destination = try await numberedFreePath(for: plan.target, owners: state.owners)
                    } else if case .present(let there)? = try? await fileStore.snapshotRegularFile(plan.target) {
                        if there.sha256 != plan.baseline.sha256 { destination = try await numberedFreePath(for: plan.target, owners: state.owners) }
                    } else if try await fileStore.migrationDestinationIsOccupied(plan.target) {
                        destination = try await numberedFreePath(for: plan.target, owners: state.owners)
                    }
                    let step = PendingRemoteMove(batchID: UUID(), remoteID: id, from: old, to: destination, sha256: plan.baseline.sha256, placement: placement)
                    guard (try? await database.commitRemoteMoves(rootID: rootID, [step])) != nil else { continue }
                    state.record(step, baseline: plan.baseline)
                case .present(let snapshot):
                    guard snapshot.sha256 == plan.baseline.sha256 else {
                        changes.append(RemoteChange(rootID: rootID, courseID: plan.file.courseID, remoteID: id, kind: .moved, relativePath: old, targetPath: plan.target, placement: placement, localSHA256: snapshot.sha256, isLocallyModified: true))
                        continue
                    }
                    movers.append(Mover(id: id, courseID: plan.file.courseID, baseline: plan.baseline, from: old, target: plan.target, snapshot: snapshot, placement: placement))
                }
            }
            try await perform(movers, state: &state)
        }
        try await database.recordRemotePlacements(rootID: rootID, firstPlacements, onlyIfMissing: true)
        try await database.recordRemotePlacements(rootID: rootID, changedPlacements, onlyIfMissing: false)
        return (state.current, state.moved, changes)
    }

    /// A file that follows a move made on Moodle; its contents are still what was downloaded.
    private struct Mover {
        let id: String
        let courseID: Int64
        let baseline: Baseline
        /// Where the file is now; changes when it steps aside during a swap.
        var from: RelativePath
        let target: RelativePath
        let snapshot: FileSnapshot
        let placement: RemotePlacement
    }

    /// The bookkeeping of a batch of moves: baselines, who owns each path, and what to report.
    private struct MoveState {
        var current: [String: Baseline]
        var owners: [String: String] = [:]
        var moved: [Int64: [MovedSyncItem]] = [:]

        init(current: [String: Baseline]) { self.current = current }

        mutating func record(_ step: PendingRemoteMove, baseline: Baseline) {
            if owners[step.from.comparisonKey] == step.remoteID { owners.removeValue(forKey: step.from.comparisonKey) }
            owners[step.to.comparisonKey] = step.remoteID
            current[step.remoteID] = Baseline(remoteID: step.remoteID, relativePath: step.to, sha256: baseline.sha256, remoteRevision: baseline.remoteRevision, courseID: baseline.courseID, moduleID: baseline.moduleID)
        }
    }

    /// Carries out the moves of unedited files in an order where none lands on another's place:
    /// first every move whose place is free, then (numbered) every move blocked by a file that is
    /// not moving, and when only moves waiting on each other remain, the files that swapped places
    /// are exchanged. A move that fails (the file changed meanwhile) leaves that file where it is,
    /// to be tried again next run.
    private func perform(_ movers: [Mover], state: inout MoveState) async throws {
        var pending = movers
        while !pending.isEmpty {
            try Task.checkCancellation()
            var free: Int?
            var blocked: Int?
            for (index, mover) in pending.enumerated() {
                let owner = state.owners[mover.target.comparisonKey]
                if owner == nil || owner == mover.id {
                    if try await fileStore.migrationDestinationIsOccupied(mover.target) { blocked = blocked ?? index } else { free = index; break }
                } else if !pending.contains(where: { $0.id == owner }) {
                    blocked = blocked ?? index
                }
            }
            if let index = free ?? blocked {
                let mover = pending.remove(at: index)
                let destination = free == nil ? try await numberedFreePath(for: mover.target, owners: state.owners) : mover.target
                try await move(mover, to: destination, state: &state)
                continue
            }
            // Every remaining file waits for another one to leave: a cycle, such as two sections
            // whose names were swapped. Exchange the first file with the one holding its place.
            let mover = pending.removeFirst()
            guard let holderID = state.owners[mover.target.comparisonKey], let holderIndex = pending.firstIndex(where: { $0.id == holderID }) else { continue }
            let holder = pending[holderIndex]
            let batch = UUID()
            let holderArrives = holder.target.comparisonKey == mover.from.comparisonKey
            // Paths as they are spelled on disk, which may differ in letter case from the targets.
            let first = PendingRemoteMove(batchID: batch, remoteID: mover.id, from: mover.from, to: holder.from, sha256: mover.snapshot.sha256, placement: mover.placement)
            let second = PendingRemoteMove(batchID: batch, remoteID: holder.id, from: holder.from, to: mover.from, sha256: holder.snapshot.sha256, placement: holderArrives ? holder.placement : nil)
            try await database.beginRemoteMoves(rootID: rootID, [first, second])
            do {
                try await fileStore.swapRegularFiles(mover.from, expected: mover.snapshot, with: holder.from, expected: holder.snapshot)
            } catch FileStoreError.unsupported {
                // This volume cannot exchange two files: the first one takes a numbered name, which
                // frees the cycle for the others.
                try await database.discardRemoteMoves(rootID: rootID, remoteIDs: [mover.id, holder.id])
                try await move(mover, to: try await numberedFreePath(for: mover.target, owners: state.owners), state: &state)
                continue
            } catch {
                try await database.discardRemoteMoves(rootID: rootID, remoteIDs: [mover.id, holder.id])
                continue
            }
            try await database.commitRemoteMoves(rootID: rootID, [first, second])
            state.record(first, baseline: mover.baseline)
            state.record(second, baseline: holder.baseline)
            state.owners[first.to.comparisonKey] = mover.id
            state.moved[mover.courseID, default: []].append(Self.movedItem(id: mover.id, at: first.to, outcome: .moved))
            if holderArrives {
                pending.remove(at: holderIndex)
                state.moved[holder.courseID, default: []].append(Self.movedItem(id: holder.id, at: second.to, outcome: .moved))
            } else {
                pending[holderIndex].from = second.to
            }
        }
    }

    private func move(_ mover: Mover, to destination: RelativePath, state: inout MoveState) async throws {
        let step = PendingRemoteMove(batchID: UUID(), remoteID: mover.id, from: mover.from, to: destination, sha256: mover.snapshot.sha256, placement: mover.placement)
        try await database.beginRemoteMoves(rootID: rootID, [step])
        do {
            try await fileStore.moveRegularFilePreservingCurrentContents(from: mover.from, to: destination, expected: mover.snapshot)
        } catch {
            // Changed or unreadable while being moved, or its place taken meanwhile: left alone and
            // tried again next run.
            try await database.discardRemoteMoves(rootID: rootID, remoteIDs: [mover.id])
            return
        }
        try await database.commitRemoteMoves(rootID: rootID, [step])
        state.record(step, baseline: mover.baseline)
        // Tidying up is best effort; the move is already recorded.
        try? await fileStore.removeEmptyParentDirectories(of: mover.from)
        state.moved[mover.courseID, default: []].append(Self.movedItem(id: mover.id, at: destination, outcome: .moved))
    }

    /// `path` with the first number (`Slide (1).pdf`, `Slide (2).pdf`, …) that no tracked file,
    /// open conflict or file on disk holds: the rule downloads follow for a name already taken.
    private func numberedFreePath(for path: RelativePath, owners: [String: String]) async throws -> RelativePath {
        for suffix in 1...999 {
            let candidate = try LocalPathPolicy.destinationByAddingSuffix(suffix, to: path)
            if owners[candidate.comparisonKey] == nil, !(try await fileStore.migrationDestinationIsOccupied(candidate)) { return candidate }
        }
        throw SyncDatabaseError.execution
    }

    static func movedItem(id: String, at path: RelativePath, outcome: MovedSyncItem.Outcome) -> MovedSyncItem {
        MovedSyncItem(id: id, name: path.components.last ?? path.value, folder: path.components.dropFirst().dropLast().joined(separator: "/"), outcome: outcome)
    }

    /// A tracked file Moodle no longer lists, uploaded again elsewhere with the same contents.
    private struct Reupload {
        let ghost: Baseline
        /// Set when the file was read now; absent when an open entry was carried over.
        let snapshot: FileSnapshot?
        let localSHA256: String
        let isModified: Bool
    }

    /// Finds the tracked files Moodle no longer lists, in courses it listed in full this run, and
    /// decides what each needs (sections 4.2 and 4.3 of the sync behavior document):
    /// - uploaded again elsewhere with the same contents: returned in `reuploads`, keyed by the
    ///   new file's id, so the download step moves an unedited copy there instead of downloading a
    ///   second one, or asks the user about an edited one;
    /// - otherwise an entry "removed from Moodle". A file is never deleted by a sync.
    ///
    /// A file only counts as gone when Moodle listed its course in full and its module had no
    /// unreadable entry, and never while it has an open conflict or an unfinished download.
    /// Baselines from older versions with no course recorded are skipped: they cannot be told
    /// apart from files the current path rules no longer recognize.
    private func vanishedFiles(listings: [Int64: CourseListing], fetched: [(Int, [RemoteFileCandidate])], baselines: [String: Baseline], excluding: Set<String>, deferredIDs: Set<String>, openChanges: [String: RemoteChange]) async throws -> (changes: [RemoteChange], reuploads: [String: Reupload]) {
        var changes: [RemoteChange] = []
        var candidates: [Baseline] = []
        for baseline in baselines.values.sorted(by: { $0.remoteID < $1.remoteID }) {
            // Ids in the old download-URL format belong to baselines the current rules have not
            // matched yet (see `isLegacyRemoteID`): absent from the listing by construction.
            guard let courseID = baseline.courseID, let listing = listings[courseID],
                  !listing.remoteIDs.contains(baseline.remoteID), !excluding.contains(baseline.remoteID),
                  !baseline.remoteID.contains(":/webservice/pluginfile.php/"), !baseline.remoteID.contains(":/pluginfile.php/") else { continue }
            guard listing.isComplete, let moduleID = baseline.moduleID, !listing.modulesWithDroppedEntries.contains(moduleID) else {
                // Not knowable this run: whatever the user was asked stays as it was.
                if let open = openChanges[baseline.remoteID] { changes.append(open) }
                continue
            }
            candidates.append(baseline)
        }
        guard !candidates.isEmpty else { return (changes, [:]) }
        // A file the user deleted or moved away needs nothing.
        let present = try await fileStore.existingRegularFiles(candidates.map(\.relativePath))
        let ghosts = candidates.filter { present.contains($0.relativePath) }

        // Files new to this run, by course and Moodle content hash.
        var newFiles: [Int64: [String: [RemoteFileCandidate]]] = [:]
        for (_, files) in fetched {
            for file in files where baselines[file.id] == nil && !deferredIDs.contains(file.id) && Self.isContentHash(file.observedRevision) {
                newFiles[file.courseID, default: [:]][file.observedRevision, default: []].append(file)
            }
        }
        var ghostsByHash: [Int64: [String: Int]] = [:]
        for ghost in ghosts where Self.isContentHash(ghost.remoteRevision) {
            ghostsByHash[ghost.courseID ?? 0, default: [:]][ghost.remoteRevision, default: 0] += 1
        }
        var reuploads: [String: Reupload] = [:]
        for ghost in ghosts {
            try Task.checkCancellation()
            let courseID = ghost.courseID ?? 0
            let open = openChanges[ghost.remoteID].flatMap { $0.relativePath == ghost.relativePath ? $0 : nil }
            // An edited copy already waiting for a choice about its re-uploaded twin, whose new copy
            // was downloaded by an earlier run: the question stands while the twin is on Moodle.
            if let open, open.kind == .reuploaded, let twin = open.newRemoteID, listings[courseID]?.remoteIDs.contains(twin) == true {
                changes.append(RemoteChange(id: open.id, rootID: rootID, courseID: courseID, remoteID: ghost.remoteID, kind: .reuploaded, relativePath: ghost.relativePath, targetPath: baselines[twin]?.relativePath ?? open.targetPath, newRemoteID: twin, localSHA256: open.localSHA256, isLocallyModified: true, detectedAt: open.detectedAt))
                continue
            }
            // Matched only when exactly one vanished file and one new file share the contents, in
            // the same course. Anything else is ambiguous: Beepbar does not guess.
            if let twins = newFiles[courseID]?[ghost.remoteRevision], twins.count == 1, ghostsByHash[courseID]?[ghost.remoteRevision] == 1, let twin = twins.first {
                if case .present(let snapshot) = try await fileStore.snapshotRegularFile(ghost.relativePath) {
                    let isModified = snapshot.sha256 != ghost.sha256
                    reuploads[twin.id] = Reupload(ghost: ghost, snapshot: isModified ? nil : snapshot, localSHA256: snapshot.sha256, isModified: isModified)
                }
                continue
            }
            if let open, open.kind == .removed {
                changes.append(open)
                continue
            }
            guard case .present(let snapshot) = try await fileStore.snapshotRegularFile(ghost.relativePath) else { continue }
            changes.append(RemoteChange(rootID: rootID, courseID: courseID, remoteID: ghost.remoteID, kind: .removed, relativePath: ghost.relativePath, localSHA256: snapshot.sha256, isLocallyModified: snapshot.sha256 != ghost.sha256))
        }
        return (changes, reuploads)
    }

    /// Moves the unedited copy of a vanished file to where Moodle's re-upload of it belongs and
    /// hands its baseline to the new file, so it is not downloaded a second time. Returns nil,
    /// having changed nothing, when that is not possible; the new file is then downloaded as usual.
    ///
    /// No journal is needed: after a crash between the rename and the baseline update, the next
    /// run downloads the new file onto the moved copy, finds identical contents and adopts it.
    /// `snapshot` is required to move the file; it may be nil when `destination` is where the file
    /// already is.
    private func adoptReupload(_ file: RemoteFileCandidate, ghost: Baseline, snapshot: FileSnapshot?, at destination: RelativePath) async throws -> Baseline? {
        if destination != ghost.relativePath {
            guard let snapshot, try await fileStore.migrationDestinationIsOccupied(destination) == false else { return nil }
            do { try await fileStore.moveRegularFilePreservingCurrentContents(from: ghost.relativePath, to: destination, expected: snapshot) }
            catch { return nil }
        }
        let adopted = Baseline(remoteID: file.id, relativePath: destination, sha256: ghost.sha256, remoteRevision: file.observedRevision, courseID: file.courseID, moduleID: file.moduleID)
        guard try await database.transferBaseline(rootID: rootID, from: ghost.remoteID, at: ghost.relativePath, to: adopted, placement: RemotePlacement(file)) else { return nil }
        if destination != ghost.relativePath { try? await fileStore.removeEmptyParentDirectories(of: ghost.relativePath) }
        return adopted
    }

    /// Moodle's content hash (SHA-1, or SHA-256 on newer sites), as opposed to the date-and-size
    /// revision used when a site does not report one. Only a real hash proves identical contents.
    static func isContentHash(_ revision: String) -> Bool {
        (revision.utf8.count == 40 || revision.utf8.count == 64) && revision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
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
