import CryptoKit
import Foundation

public enum ModulePathMigrationError: Error, Sendable, Equatable, LocalizedError {
    case invalidFolder
    case unavailableModule
    case duplicateModule
    case duplicateFileID
    case ownershipMismatch
    case destinationOccupied(String)
    case trackedPathCollision(String)
    case normalizedPathCollision(String)
    case pendingOperation
    case openConflict
    case pendingRecovery
    case planChanged
    case unresolvedMove
    case noRule
    case ruleNowPresent

    public var errorDescription: String? {
        switch self {
        case .invalidFolder: tr("Il percorso della cartella non è valido o supera i limiti consentiti.", "The folder path is invalid or exceeds the allowed limits.")
        case .unavailableModule: tr("Il modulo non è più disponibile su Moodle.", "The module is no longer available on Moodle.")
        case .duplicateModule, .duplicateFileID: tr("Moodle ha restituito identificativi ambigui; aggiorna i contenuti e riprova.", "Moodle returned ambiguous identifiers; refresh the contents and try again.")
        case .ownershipMismatch: tr("Non è possibile attribuire con sicurezza tutti i file a questo modulo.", "Not every file can be safely attributed to this module.")
        case .destinationOccupied(let path): tr("La destinazione è già occupata: \(path).", "The destination is already taken: \(path).")
        case .trackedPathCollision(let path): tr("La destinazione è già assegnata a un altro file tracciato: \(path).", "The destination is already assigned to another tracked file: \(path).")
        case .normalizedPathCollision(let path): tr("Due file finirebbero nella stessa destinazione: \(path).", "Two files would end up at the same destination: \(path).")
        case .pendingOperation: tr("Completa prima le altre operazioni di sincronizzazione.", "Finish the other sync operations first.")
        case .openConflict: tr("Risolvi prima i conflitti aperti per questo modulo.", "Resolve the open conflicts for this module first.")
        case .pendingRecovery: tr("Completa il recupero locale prima di modificare le cartelle.", "Finish the local recovery before changing folders.")
        case .planChanged: tr("I contenuti o i file locali sono cambiati dopo l’anteprima. Generane una nuova.", "The contents or local files changed after the preview. Generate a new one.")
        case .unresolvedMove: tr("Lo spostamento non è stato completato. I file non sono stati sovrascritti; riprova il recupero.", "The move wasn’t completed. No files were overwritten; retry the recovery.")
        case .noRule: tr("Non è presente una regola da eliminare.", "There is no rule to remove.")
        case .ruleNowPresent: tr("Il modulo è di nuovo presente su Moodle; aggiorna l’elenco e riprova.", "The module is back on Moodle; refresh the list and try again.")
        }
    }
}

public actor ModulePathMigrator {
    private let rootID: UUID
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate
    private let apiClient: WeBeepAPIClient

    public init(rootID: UUID, database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate, apiClient: WeBeepAPIClient) {
        self.rootID = rootID
        self.database = database
        self.fileStore = fileStore
        self.gate = gate
        self.apiClient = apiClient
    }

    public func ruleRows(courseID: Int64, contents: RemoteCourseContents) async throws -> [ModulePathRuleRow] {
        let modules = contents.sections.flatMap(\.modules)
        guard Set(modules.map(\.id)).count == modules.count else { throw ModulePathMigrationError.duplicateModule }
        let overrides = try await database.modulePathOverrides(rootID: rootID, courseID: courseID)
        let baselines = try await database.baselines(rootID: rootID)
        let availableIDs = Set(modules.map(\.id))
        var rows = modules.map { module in
            let candidates = module.files
            let ownedIDs = Set(baselines.values.compactMap { baseline -> String? in
                guard baseline.courseID == courseID, baseline.moduleID == module.id else { return nil }
                return baseline.remoteID
            })
            let exactUnattributed = Set(candidates.compactMap { candidate -> String? in
                guard let baseline = baselines[candidate.id], baseline.courseID == nil, baseline.moduleID == nil else { return nil }
                return candidate.id
            })
            return ModulePathRuleRow(
                moduleID: module.id,
                name: module.name.isEmpty ? tr("Modulo senza nome · ID \(module.id)", "Untitled module · ID \(module.id)") : module.name,
                moduleType: candidates.first?.moduleType ?? "",
                exposedFileCount: candidates.count,
                trackedFileCount: ownedIDs.union(exactUnattributed).count,
                localFolder: overrides[module.id]?.localFolder,
                isAvailable: true
            )
        }
        for rule in overrides.values where !availableIDs.contains(rule.moduleID) {
            let count = baselines.values.filter { $0.courseID == courseID && $0.moduleID == rule.moduleID }.count
            rows.append(ModulePathRuleRow(moduleID: rule.moduleID, name: rule.lastKnownName.isEmpty ? tr("Modulo non più disponibile · ID \(rule.moduleID)", "Module no longer available · ID \(rule.moduleID)") : rule.lastKnownName, moduleType: "", exposedFileCount: 0, trackedFileCount: count, localFolder: rule.localFolder, isAvailable: false))
        }
        return rows.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.moduleID < $1.moduleID : order == .orderedAscending
        }
    }

    public func preview(courseID: Int64, moduleID: Int64, courseFolder: String, action: ModuleMoveAction, folder: String?, contents: RemoteCourseContents) async throws -> ModuleMovePreview {
        try await gate.withLease(.movingModule(courseID, moduleID)) {
            try await self.makePreview(courseID: courseID, moduleID: moduleID, courseFolder: courseFolder, action: action, folder: folder, contents: contents)
        }
    }

    public func apply(_ preview: ModuleMovePreview, courseFolder: String, token: String) async throws {
        guard preview.rootID == rootID else { throw ModulePathMigrationError.planChanged }
        try await gate.withLease(.movingModule(preview.courseID, preview.moduleID)) {
            guard try await self.database.hasPendingModuleMoves(rootID: self.rootID) == false else { throw ModulePathMigrationError.pendingRecovery }
            let contents = try await self.apiClient.fetchContents(courseID: preview.courseID, token: token)
            let fresh = try await self.makePreview(courseID: preview.courseID, moduleID: preview.moduleID, courseFolder: courseFolder, action: preview.action, folder: preview.newFolder, contents: contents)
            guard fresh.fingerprint == preview.fingerprint else { throw ModulePathMigrationError.planChanged }
            let manifest = fresh.files.map { file in
                PendingModuleMoveFile(remoteID: file.remoteID, oldPath: file.oldPath, newPath: file.newPath, source: file.source)
            }
            let move = PendingModuleMove(rootID: rootID, courseID: fresh.courseID, moduleID: fresh.moduleID, action: fresh.action, oldFolder: fresh.oldFolder, newFolder: fresh.newFolder, lastKnownName: fresh.lastKnownName, files: manifest)
            try await database.beginModuleMove(move)
            guard try await ModuleMoveRecovery.recover(move, database: database, fileStore: fileStore) else { throw ModulePathMigrationError.unresolvedMove }
        }
    }

    public func deleteUnavailableRule(courseID: Int64, moduleID: Int64, token: String) async throws {
        try await gate.withLease(.movingModule(courseID, moduleID)) {
            guard try await self.database.hasPendingModuleMoves(rootID: self.rootID) == false else { throw ModulePathMigrationError.pendingRecovery }
            guard try await self.database.pendingScopeMoves(rootID: self.rootID).isEmpty else { throw ModulePathMigrationError.pendingRecovery }
            guard try await self.database.pendingOperations(rootID: self.rootID).isEmpty else { throw ModulePathMigrationError.pendingOperation }
            let contents = try await self.apiClient.fetchContents(courseID: courseID, token: token)
            let modules = contents.sections.flatMap(\.modules)
            guard !modules.contains(where: { $0.id == moduleID }) else { throw ModulePathMigrationError.ruleNowPresent }
            guard let rule = try await self.database.modulePathOverride(rootID: self.rootID, courseID: courseID, moduleID: moduleID) else { throw ModulePathMigrationError.noRule }
            let move = PendingModuleMove(rootID: self.rootID, courseID: courseID, moduleID: moduleID, action: .remove, oldFolder: rule.localFolder, newFolder: nil, lastKnownName: rule.lastKnownName, files: [])
            try await self.database.commitModuleMove(move)
        }
    }

    private func makePreview(courseID: Int64, moduleID: Int64, courseFolder: String, action: ModuleMoveAction, folder: String?, contents: RemoteCourseContents) async throws -> ModuleMovePreview {
        guard try await database.hasPendingModuleMoves(rootID: rootID) == false else { throw ModulePathMigrationError.pendingRecovery }
        let modules = contents.sections.flatMap(\.modules).filter { $0.id == moduleID }
        guard !modules.isEmpty else { throw ModulePathMigrationError.unavailableModule }
        guard modules.count == 1 else { throw ModulePathMigrationError.duplicateModule }
        let module = modules[0]
        guard module.files.allSatisfy({ $0.courseID == courseID && $0.moduleID == moduleID }) else { throw ModulePathMigrationError.ownershipMismatch }
        guard Set(module.files.map(\.id)).count == module.files.count else { throw ModulePathMigrationError.duplicateFileID }
        let desiredFolder: String?
        switch action {
        case .set:
            guard let folder else { throw ModulePathMigrationError.invalidFolder }
            do { desiredFolder = try LocalPathPolicy.moduleFolder(folder).value }
            catch { throw ModulePathMigrationError.invalidFolder }
        case .remove:
            guard try await database.modulePathOverride(rootID: rootID, courseID: courseID, moduleID: moduleID) != nil else { throw ModulePathMigrationError.noRule }
            desiredFolder = nil
        }
        let override = try await database.modulePathOverride(rootID: rootID, courseID: courseID, moduleID: moduleID)
        let baselines = try await database.baselines(rootID: rootID)
        let candidates = Dictionary(uniqueKeysWithValues: module.files.map { ($0.id, $0) })
        let ownedBaselines = baselines.values.filter { $0.courseID == courseID && $0.moduleID == moduleID }
        let candidateIDs = Set(candidates.keys)
        let excluded = ownedBaselines.filter { !candidateIDs.contains($0.remoteID) }.map(\.remoteID).sorted()
        guard try await database.pendingOperations(rootID: rootID).isEmpty else { throw ModulePathMigrationError.pendingOperation }
        guard try await database.pendingScopeMoves(rootID: rootID).isEmpty else { throw ModulePathMigrationError.pendingRecovery }
        let openConflicts = try await database.conflicts(rootID: rootID)
        let trackedIDs = Set(ownedBaselines.map(\.remoteID)).union(candidateIDs.filter { baselines[$0]?.courseID == nil })
        guard !openConflicts.contains(where: { trackedIDs.contains($0.remoteID) }) else { throw ModulePathMigrationError.openConflict }

        var snapshots: [String: FileSnapshotState] = [:]
        var targetByID: [String: RelativePath] = [:]
        for candidate in module.files {
            let sameID = contents.sections.flatMap(\.modules).flatMap(\.files).filter { $0.id == candidate.id }
            guard sameID.count == 1 else { throw ModulePathMigrationError.ownershipMismatch }
            let destination: RelativePath
            do {
                destination = try LocalPathPolicy.destination(courseFolder: courseFolder, file: candidate, moduleFolderOverride: desiredFolder)
            } catch {
                throw ModulePathMigrationError.invalidFolder
            }
            targetByID[candidate.id] = destination
            if let baseline = baselines[candidate.id] {
                if baseline.courseID == nil && baseline.moduleID == nil { continue }
                guard baseline.courseID == courseID, baseline.moduleID == moduleID else { throw ModulePathMigrationError.ownershipMismatch }
            }
        }
        var targetIDsByPath: [String: Set<String>] = [:]
        for id in candidateIDs {
            guard let target = targetByID[id] else { continue }
            targetIDsByPath[target.comparisonKey, default: []].insert(id)
        }
        for (path, ids) in targetIDsByPath where ids.count > 1 {
            throw ModulePathMigrationError.normalizedPathCollision(path)
        }
        var files: [ModuleMoveFile] = []
        for candidate in module.files.sorted(by: { $0.id < $1.id }) {
            let baseline = baselines[candidate.id]
            if let baseline, baseline.courseID != nil || baseline.moduleID != nil {
                guard baseline.courseID == courseID, baseline.moduleID == moduleID else { throw ModulePathMigrationError.ownershipMismatch }
            }
            guard let target = targetByID[candidate.id] else { throw ModulePathMigrationError.ownershipMismatch }
            let targetKey = target.comparisonKey
            if openConflicts.contains(where: { $0.remoteID != candidate.id && $0.relativePath.comparisonKey == targetKey }) {
                throw ModulePathMigrationError.trackedPathCollision(target.value)
            }
            let trackedOwner = baselines.values.first { $0.remoteID != candidate.id && $0.relativePath.comparisonKey == targetKey }
            guard trackedOwner == nil else { throw ModulePathMigrationError.trackedPathCollision(target.value) }
            if baseline?.relativePath != target, try await fileStore.migrationDestinationIsOccupied(target) {
                throw ModulePathMigrationError.destinationOccupied(target.value)
            }
            guard let baseline else { continue }
            let source = try await fileStore.snapshotRegularFile(baseline.relativePath)
            snapshots[candidate.id] = source
            files.append(ModuleMoveFile(remoteID: candidate.id, oldPath: baseline.relativePath, newPath: target, source: source, baselineSHA256: baseline.sha256, baselineRevision: baseline.remoteRevision, observedRevision: candidate.observedRevision))
        }
        let ownerlessCount = Self.ownerlessBaselineCount(baselines: baselines, courseFolder: courseFolder, excluding: candidateIDs)
        let fingerprint = Self.fingerprint(rootID: rootID, courseID: courseID, moduleID: moduleID, courseFolder: courseFolder, action: action, oldFolder: override?.localFolder, newFolder: desiredFolder, moduleName: module.name, candidates: module.files, baselines: baselines, files: files, excluded: excluded, ownerlessCount: ownerlessCount, snapshots: snapshots)
            return ModuleMovePreview(rootID: rootID, courseID: courseID, moduleID: moduleID, action: action, oldFolder: override?.localFolder, newFolder: desiredFolder, lastKnownName: module.name, files: files, excludedRemoteIDs: excluded, ownerlessBaselineCount: ownerlessCount, fingerprint: fingerprint)
    }

    /// Older files of this course that no sync has attributed to a module yet, so the move
    /// leaves them where they are; the preview tells the user how many. Counted inside the
    /// course folder only: the count is part of the fingerprint, and a root-wide count changed
    /// whenever a sync of any other course attributed its own older files, so `apply` rejected
    /// an untouched preview with `planChanged` (ultrareview finding on `rootUnattributedBaselineCount`).
    static func ownerlessBaselineCount(baselines: [String: Baseline], courseFolder: String, excluding candidateIDs: Set<String>) -> Int {
        let prefix = PathKey.of(LocalPathPolicy.component(courseFolder)) + "/"
        return baselines.values.filter { baseline in
            baseline.courseID == nil && baseline.moduleID == nil
                && !candidateIDs.contains(baseline.remoteID)
                && baseline.relativePath.comparisonKey.hasPrefix(prefix)
        }.count
    }

    private static func fingerprint(rootID: UUID, courseID: Int64, moduleID: Int64, courseFolder: String, action: ModuleMoveAction, oldFolder: String?, newFolder: String?, moduleName: String, candidates: [RemoteFileCandidate], baselines: [String: Baseline], files: [ModuleMoveFile], excluded: [String], ownerlessCount: Int, snapshots: [String: FileSnapshotState]) -> String {
        var data = Data()
        func append(_ value: String?) {
            let bytes = Array((value ?? "<nil>").utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: bytes)
        }
        append(rootID.uuidString); append(String(courseID)); append(String(moduleID)); append(courseFolder); append(action.rawValue)
        append(oldFolder); append(newFolder); append(moduleName); append(String(ownerlessCount))
        for candidate in candidates.sorted(by: { $0.id < $1.id }) {
            append(candidate.id); append(String(candidate.moduleID)); append(candidate.remoteFilePath); append(candidate.filename); append(candidate.moduleType); append(candidate.observedRevision)
            if let baseline = baselines[candidate.id] {
                append(baseline.relativePath.value); append(baseline.sha256); append(baseline.remoteRevision); append(baseline.courseID.map(String.init)); append(baseline.moduleID.map(String.init))
            } else {
                append(nil); append(nil); append(nil); append(nil); append(nil)
            }
            if let state = snapshots[candidate.id] {
                switch state {
                case .missing: append("missing")
                case .present(let snapshot): append("present"); append(String(snapshot.device)); append(String(snapshot.inode)); append(snapshot.sha256)
                }
            } else { append("untracked") }
        }
        for id in excluded.sorted() {
            append(id)
            if let baseline = baselines[id] { append(baseline.relativePath.value); append(baseline.sha256); append(baseline.remoteRevision) }
        }
        for file in files.sorted(by: { $0.remoteID < $1.remoteID }) {
            append(file.remoteID); append(file.oldPath.value); append(file.newPath.value); append(file.observedRevision)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
