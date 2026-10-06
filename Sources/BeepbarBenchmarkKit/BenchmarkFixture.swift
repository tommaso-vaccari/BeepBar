import BeepbarCore
import Foundation

/// A complete, disposable BeepBar sync setup: a sync folder, a database, a trash folder and a mock
/// Moodle, all inside one temporary directory.
///
/// Safety: nothing here touches the user's data. The database is a new file in the temporary
/// directory (never `~/Library/Application Support/Beepbar/sync.sqlite`), the token is a fixed fake
/// string (never the keychain), nothing reads or writes UserDefaults, deleted files go to the
/// fixture's own trash folder (never the user's Trash), and the network is the in-process mock.
package final class BenchmarkFixture: @unchecked Sendable {
    /// The only token the mock accepts.
    package static let token = "benchmark-token"

    package let container: URL
    package let root: URL
    package let supportDirectory: URL
    package let trashDirectory: URL
    package let rootID = UUID()
    package let database: SyncDatabase
    package let upstream: BenchmarkUpstream
    package let gate = RootOperationGate()
    private let apiClient: WeBeepAPIClient
    private let downloader: RemoteDownloader
    /// Cached after the first run, as the app caches it after signing in: later automatic runs
    /// never ask for the site info again.
    private var siteInfo: WeBeepSiteInfo?

    /// Creates the folders and the database, and enables every course of `corpus` with a folder
    /// named after it, as a user who ticked them all in "Corsi" would have.
    package init(corpus: CorpusSpec) async throws {
        container = FileManager.default.temporaryDirectory.appending(path: "beepbar-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = container.appending(path: "Sync", directoryHint: .isDirectory)
        supportDirectory = container.appending(path: "Support", directoryHint: .isDirectory)
        trashDirectory = container.appending(path: "Trash", directoryHint: .isDirectory)
        for directory in [root, supportDirectory, trashDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        database = try SyncDatabase(url: supportDirectory.appending(path: "sync.sqlite"))
        upstream = BenchmarkUpstream()
        upstream.populate(corpus)
        apiClient = WeBeepAPIClient(policy: upstream.policy, session: upstream.session)
        downloader = RemoteDownloader(session: upstream.session, policy: upstream.policy)
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        for course in upstream.courseIDs {
            try await database.upsertScope(SyncScope(rootID: rootID, courseID: course, displayName: Self.folder(course), localFolder: Self.folder(course), enabled: true))
        }
    }

    /// Deletes everything the fixture created.
    package func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    package static func folder(_ course: Int64) -> String { "Corso \(course)" }

    /// A new `FileStore` on the sync folder whose trash is the fixture's folder. The app creates a
    /// new store for every run, so a fresh store's counters measure exactly one run.
    package func makeFileStore() throws -> FileStore {
        let trash = trashDirectory
        return try FileStore(root: root) { url in
            try FileManager.default.moveItem(at: url, to: trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
        }
    }

    /// What one automatic run returned and what the app would show afterwards.
    package struct RunResult: Sendable {
        package let summary: SyncProgress
        package let openConflicts: Int
        package let pendingChanges: Int
    }

    /// The Core work of one automatic run, in the app's order (`runAutomaticSync` and
    /// `completeSync` in `WeBeepAuthenticationController`):
    /// 1. read the enabled courses from the database;
    /// 2. ask for the site info, only the first time;
    /// 3. list the enrolled courses, and keep the enabled ones still enrolled;
    /// 4. a new `SyncCoordinator` runs `.automatic` with unrestricted network;
    /// 5. read the open conflicts and the pending remote changes, as the window's lists.
    /// What it leaves out is app-level: the keychain read, UserDefaults writes of the sync state,
    /// notifications and UI updates. Keep this in step with the app when that sequence changes.
    @discardableResult
    package func automaticRun(fileStore: FileStore? = nil, progress: @escaping @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> RunResult {
        let scopes = try await database.scopes(rootID: rootID, enabledOnly: true)
        let info: WeBeepSiteInfo
        if let siteInfo { info = siteInfo } else { info = try await apiClient.validateToken(Self.token) }
        siteInfo = info
        let enrolled = Set(try await apiClient.fetchCourses(userID: info.userID, token: Self.token).map(\.id))
        let targets = scopes.filter { $0.enabled && enrolled.contains($0.courseID) }.map { SyncTarget(courseID: $0.courseID, localFolder: $0.localFolder) }
        let coordinator = try SyncCoordinator(rootID: rootID, rootURL: root, database: database, gate: gate, apiClient: apiClient, downloader: downloader, platformName: "WeBeep", fileStore: try fileStore ?? makeFileStore())
        let summary = try await coordinator.synchronize(targets: targets, token: Self.token, mode: .automatic, networkAccess: .unrestricted, progress: progress)
        let conflicts = try await database.conflicts(rootID: rootID)
        let changes = try await database.remoteChanges(rootID: rootID)
        return RunResult(summary: summary, openConflicts: conflicts.count, pendingChanges: changes.count)
    }

    /// The installed file for `key`, from its baseline; `nil` until a sync installed it.
    package func installedURL(for key: SyntheticFileKey) async throws -> URL? {
        try await database.baseline(rootID: rootID, remoteID: Self.remoteID(key)).map { root.appending(path: $0.relativePath.value) }
    }

    /// The id the coordinator gives a Moodle file: course, module, folder path and name.
    package static func remoteID(_ key: SyntheticFileKey) -> String { "\(key.course):\(key.module):/:\(key.name)" }
}
