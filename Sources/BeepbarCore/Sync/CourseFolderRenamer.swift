import Foundation

public enum CourseRenameError: Error, Sendable, Equatable, LocalizedError {
    /// Something already occupies the requested folder name inside the sync root.
    case folderAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .folderAlreadyExists: tr("Esiste già una cartella con questo nome.", "A folder with this name already exists.")
        }
    }
}

/// A course-folder rename of this sync folder is still unfinished: its `pending_scope_moves` row
/// exists, typically because the rename happened on disk but the flush of the sync folder failed
/// (`FileStoreError.mutationNotDurable`, #183). Thrown by every operation that would read or
/// write course folders while the row is there: a sync (`SyncCoordinator`), another rename
/// (`CourseFolderRenamer`) and "Organizza cartelle" (`ModulePathMigrator`).
///
/// These operations cannot settle the row themselves: their callers may already hold the old
/// folder in a target, selection write or module preview (PR #225). Recovery must run with root
/// operations blocked, drain old writes and reload the app's displayed folders before unblocking.
/// The app exposes this through "Retry recovery"; launch recovery uses the same coordinator.
public struct PendingCourseFolderRenameError: Error, Sendable, Equatable {
    public init() {}
}

public actor CourseFolderRenamer {
    private let database: SyncDatabase
    private let fileStore: FileStore
    private let gate: RootOperationGate
    /// Called after each durable step (`.journaled`, `.filesystemChanged`) so tests can stop the
    /// rename where a crash would; see `SyncTransactionCoordinator`. Always `nil` in the app.
    private let interruption: (@Sendable (JournalStep) throws -> Void)?

    public init(database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate) {
        self.init(database: database, fileStore: fileStore, gate: gate, interruption: nil)
    }

    init(database: SyncDatabase, fileStore: FileStore, gate: RootOperationGate, interruption: (@Sendable (JournalStep) throws -> Void)?) {
        self.database = database; self.fileStore = fileStore; self.gate = gate; self.interruption = interruption
    }

    public func rename(rootID: UUID, courseID: Int64, from oldFolder: String, to newFolder: String) async throws {
        guard oldFolder != newFolder, oldFolder.localizedCaseInsensitiveCompare(newFolder) != .orderedSame,
              !ReservedNamespace.isReservedTopLevelName(newFolder) else { throw FileStoreError.invalidStage }
        try await gate.withLease(.renaming(courseID)) { [database, fileStore, interruption] in
            guard try await database.hasPendingModuleMoves(rootID: rootID) == false else { throw SyncDatabaseError.execution }
            // Settled only by launch recovery; see `PendingCourseFolderRenameError` (#183).
            guard try await database.pendingScopeMoves(rootID: rootID).isEmpty else { throw PendingCourseFolderRenameError() }
            guard !(try await database.hasOpenConflicts(rootID: rootID, prefix: oldFolder)),
                  !(try await database.hasPendingOperations(rootID: rootID, prefix: oldFolder)),
                  let scope = try await database.scope(rootID: rootID, courseID: courseID), scope.localFolder == oldFolder else { throw SyncDatabaseError.execution }
            guard let currentIdentity = try await fileStore.topLevelDirectoryIdentity(oldFolder) else {
                try await database.renameScopeMetadata(rootID: rootID, courseID: courseID, from: oldFolder, to: newFolder)
                return
            }
            guard scope.managedDirectory != nil else { throw SyncDatabaseError.execution }
            // `renameTopLevelDirectory` uses RENAME_EXCL, so an occupied target fails. Catch it here,
            // before the pending row exists, and report it as its own error the UI can explain.
            guard try await fileStore.topLevelDirectoryState(newFolder) == .missing else { throw CourseRenameError.folderAlreadyExists }
            if currentIdentity != scope.managedDirectory {
                try await database.upsertScope(SyncScope(rootID: rootID, courseID: courseID, displayName: scope.displayName, localFolder: oldFolder, enabled: scope.enabled, managedDirectory: currentIdentity))
            }
            let move = PendingScopeMove(id: UUID(), rootID: rootID, courseID: courseID, oldFolder: oldFolder, newFolder: newFolder)
            try await database.beginScopeMove(move)
            // Outside the `do` below: a crash here leaves the row behind, unlike a failed rename.
            try interruption?(.journaled)
            do {
                try await fileStore.renameTopLevelDirectory(from: oldFolder, to: newFolder, expectedIdentity: currentIdentity)
            } catch FileStoreError.mutationNotDurable {
                throw FileStoreError.mutationNotDurable
            } catch {
                // Nothing moved, so the prepared row describes a move that will never happen. Leaving
                // it behind would trip the table's unique constraints on every later rename of this
                // course and would come back as an unresolvable move at the next launch.
                try? await database.abortScopeMove(id: move.id)
                throw error
            }
            try interruption?(.filesystemChanged)
            try await database.commitScopeMove(move)
        }
    }
}
