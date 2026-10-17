# S-0005 — Estratti del codice pubblico

Commit: `c9a04dc2f510fb02d0662f1c66ce0c53f54e5296`. Acquisizione: 2026-10-10.
Estratti verbatim da git, non copie complete. Nessun dato runtime.

## App/Info.plist:44-47

```
	<key>SUScheduledCheckInterval</key>
	<integer>28800</integer>
</dict>
</plist>
```

## Sources/BeepbarApp/CredentialStorage.swift:15-37

```
    private static let tempFilePrefix = ".credential-"
    private static let tempFileSuffix = ".tmp"

    static func save(_ token: String) throws {
        let url = try fileURL()
        guard let data = token.data(using: .utf8) else { throw CredentialStorageError.write }
        try? cleanUpOrphanedTempFiles(in: url.deletingLastPathComponent())
        // Written with 0600 permissions from the moment the file is created (rather than
        // written-then-chmod'd), and moved into place atomically, so there is never a window
        // where the token sits on disk under the default, more permissive umask.
        let tempURL = url.deletingLastPathComponent().appendingPathComponent("\(tempFilePrefix)\(UUID().uuidString)\(tempFileSuffix)")
        do {
            guard FileManager.default.createFile(atPath: tempURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CredentialStorageError.write
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL, options: .usingNewMetadataOnly)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw CredentialStorageError.write
        }
    }

    static func load(_ access: CredentialAccess) throws -> String {
```

## Sources/BeepbarApp/CredentialStorage.swift:57-84

```
    private static func cleanUpOrphanedTempFiles(in directory: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in contents where item.lastPathComponent.hasPrefix(tempFilePrefix) && item.lastPathComponent.hasSuffix(tempFileSuffix) {
            try FileManager.default.removeItem(at: item)
        }
    }

    static func delete(removeFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        let url = try fileURL()
        try cleanUpOrphanedTempFiles(in: url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) { try removeFile(url) }
    }

    private static func fileURL() throws -> URL {
        do {
            let directory = try applicationSupportDirectory().appendingPathComponent(directoryName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            // The same "Beepbar" directory also holds the sync database, created independently
            // by `WeBeepAuthenticationController.databaseDirectory()` with default permissions
            // when it runs first — re-assert 0700 here so the credential file's directory is
            // never left group/world-readable regardless of creation order.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return directory.appendingPathComponent(fileName)
        } catch {
            throw CredentialStorageError.write
        }
```

## Sources/BeepbarApp/RecordingsSessionStore.swift:32-65

```
    /// The saved session, or nil when there is none.
    func load() throws -> Data? {
        let url = try directory().appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func save(_ data: Data) throws {
        let folder = try directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created with 0600 rather than chmod'ed afterwards, then moved into place in one step:
        // the cookies are never on disk under the default permissions, nor half written.
        let temporary = folder.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, folder.appendingPathComponent(Self.fileName).path) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes the session and any temporary file a crash left behind. No file is not an error.
    func delete() throws {
        let folder = try directory()
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let url = folder.appendingPathComponent(Self.fileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
```

## Sources/BeepbarCore/Recordings/RecmanSessionCodec.swift:31-57

```
    public static func encode(_ cookies: [HTTPCookie], ownerUserID: Int, now: Date = Date()) throws -> Data {
        let kept: [[String: Any]] = cookies.filter { keeps($0, now: now) }.compactMap { cookie in
            cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        let snapshot: [String: Any] = ["version": currentVersion, "owner": ownerUserID, "cookies": kept]
        return try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> Snapshot {
        guard let snapshot = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = snapshot["version"] as? Int else { throw DecodeError.unreadable }
        guard version == currentVersion else { throw DecodeError.unsupportedVersion }
        guard let owner = snapshot["owner"] as? Int, let values = snapshot["cookies"] as? [[String: Any]] else { throw DecodeError.unreadable }
        let cookies = values.compactMap { value in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: value.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
        return Snapshot(ownerUserID: owner, cookies: cookies.filter { keeps($0, now: now) })
    }

    /// A cookie of polimi.it or one of its subdomains that hasn't expired. Session cookies (no
    /// expiry) are kept: they are the single sign-on session itself.
    public static func keeps(_ cookie: HTTPCookie, now: Date) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard PolimiPage.isPolimiHost(domain) else { return false }
        return cookie.expiresDate.map { $0 > now } ?? true
    }
}
```

## Sources/BeepbarApp/WeBeepAuthenticationController.swift:943-982

```
    /// Forgets the stored token so another account, or another university, can be connected.
    /// The sync folder, its files and the course selection stay as they are; the Recordings
    /// feature is turned off and its Polimi session deleted.
    func signOut(removeFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        guard hasStoredCredential, !isSyncActive, !isAuthenticating, !isVerifying, !isLoadingCourses else { return }
        do {
#if DEBUG
            if let deleteCredentialForTesting {
                try deleteCredentialForTesting()
            } else {
                try FileTokenStore.delete(removeFile: removeFile)
            }
#else
            try FileTokenStore.delete(removeFile: removeFile)
#endif
        } catch {
            setSyncState(.failed(.local(BilingualText("Impossibile eliminare il token salvato. Riprova a disconnetterti.", "Couldn't remove the stored token. Try disconnecting again."))))
            return
        }
        Task { await credentialVault.invalidate() }
        Self.defaults.removeObject(forKey: Self.credentialExpiredKey)
        notificationCoordinator.clearFailure()
        siteInfo = nil
        courses = []
        courseLoadError = nil
        hasStoredCredential = false
        accountState = .notConnected
        setSyncState(recoveryBlocked ? .recoveryBlocked : .loginRequired)
        configureBackgroundScheduler()
        // Whether or not it was on in this launch: a session saved in an earlier one goes too.
        recordings.turnOff()
    }

    /// Italian text for an error raised while organizing module folders. Errors that already carry
    /// a description keep it; the rest would otherwise surface as a generic English system string.
    nonisolated static func moduleFolderErrorMessage(_ error: Error) -> String {
        switch error {
        case let error as ModulePathMigrationError: return error.errorDescription ?? tr("Operazione non riuscita. Riprova.", "Operation failed. Try again.")
        case is RootOperationGateError: return tr("Un'altra operazione è in corso sulla cartella. Riprova tra poco.", "Another operation is running on the folder. Try again shortly.")
        case let error as WeBeepAPIError:
```

## Sources/BeepbarApp/WeBeepAuthenticationController.swift:1975-1998

```
    private static func databaseDirectory() throws -> URL {
        guard !isUIPreview, !isUIPreviewOnboarding else {
            // Same reasoning as `defaults`: don't let a manual preview run touch the real
            // installed app's sync database. A fresh throwaway directory per launch also gives
            // onboarding testing a clean "first install" every time.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Beepbar-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        return installedDatabaseDirectory(applicationSupport: try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
    }

    /// Where an installed BeepBar keeps `sync.sqlite`: the same Application Support folder as the
    /// token, under a name that must never change with the product's spelling (see
    /// `FileTokenStore.applicationSupportDirectoryName`).
    nonisolated static func installedDatabaseDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(FileTokenStore.applicationSupportDirectoryName, isDirectory: true)
    }

    private func restoreScopes(for courses: [RemoteCourseSummary]) async throws {
#if DEBUG
        beforeScopeRestoreForTesting?()
#endif
        await scopeWriteTask?.value
```

## Sources/BeepbarApp/WeBeepAuthenticationController.swift:2708-2720

```

    init(site: MoodleSite, completion: @escaping (Result<URL, LoginWindowError>) -> Void) {
        self.site = site
        self.completion = completion
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        retryButton = NSButton(title: tr("Ricarica", "Reload"), target: nil, action: nil)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded

        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .regular
        spinner.startAnimation(nil); spinner.translatesAutoresizingMaskIntoConstraints = false
```

## Sources/BeepbarApp/RecordingsController.swift:173-205

```
    nonisolated static func studyKey(owner: Int) -> String { "io.github.tvaccari.beepbar.recordings-study.v1.\(owner)" }

    /// Account isolation applies even when there is no saved Polimi session to invalidate.
    private func loadStudy() {
        let owner = isEnabled ? ownerUserID() : nil
        guard !studyLoaded || studyOwner != owner else { return }
        studyLoaded = true
        studyOwner = owner
        study = RecordingsStudyState()
        studyProblem = nil
        studyUnreadable = false
        guard let owner, let data = defaults.data(forKey: Self.studyKey(owner: owner)) else { return }
        do { study = try PropertyListDecoder().decode(RecordingsStudyState.self, from: data) }
        catch {
            studyUnreadable = true
            studyProblem = BilingualText("La watchlist salvata non è leggibile. I dati originali sono stati conservati.", "The saved watchlist couldn't be read. The original data has been preserved.")
        }
    }

    /// Never overwrite unreadable saved choices or write personal data before the account is known.
    private func updateStudy(_ change: (inout RecordingsStudyState) -> Void) {
        loadStudy()
        guard isEnabled, let owner = studyOwner, owner == ownerUserID(), !studyUnreadable else { return }
        var updated = study
        change(&updated)
        guard updated != study else { return }
        do {
            let data = try PropertyListEncoder().encode(updated)
            defaults.set(data, forKey: Self.studyKey(owner: owner))
            study = updated
        } catch {
            studyProblem = BilingualText("Non è stato possibile salvare la watchlist. Riprova.", "Couldn't save the watchlist. Try again.")
        }
```

## Sources/BeepbarApp/RecordingsController.swift:244-264

```

    /// Browser closed and session forgotten; account-scoped study choices survive disabling the feature.
    /// Also called when the WeBeep account is disconnected or the university changes, whether or
    /// not the feature was on, so no session outlives the account it was made for.
    func turnOff() {
        invalidate()
        closeBrowser()
        isEnabled = false
        access = .off
        listings = [:]
        openingProblem = nil
        playbackURLs = [:]
        pageKeys = []
        selectedKey = nil
        forgetSeen()
        studyLoaded = false
        loadStudy()
        defaults.removeObject(forKey: Self.enabledKey)
        discardSessionFile()
    }

```

## Sources/BeepbarApp/RecordingsStudyState.swift:10-24

```
/// Personal study choices belong to an account, not to the expiring Polimi browser session.
/// Bookmarks retain metadata so the global list is useful before courses are loaded again.
struct RecordingsStudyState: Codable, Equatable {
    struct Bookmark: Codable, Equatable, Identifiable {
        var recording: RecmanRecording
        var courseName: String
        var unavailable = false
        var id: String { RecordingsStudyState.identity(recording) }
    }

    var bookmarks: [Bookmark] = []
    var destination: RecordingsDestination?

    /// Course and year keep reused remote identifiers from sharing personal state.
    nonisolated static func identity(_ recording: RecmanRecording) -> String {
```

## Sources/BeepbarCore/Network/WeBeepAPIClient.swift:345-383

```
    }

    static func coursesRequest(userID: Int, token: String) -> URLRequest {
        request(function: .courses, token: token, fields: ["userid": String(userID)], endpoint: endpoint)
    }

    static func contentsRequest(courseID: Int64, token: String) -> URLRequest {
        request(function: .contents, token: token, fields: ["courseid": String(courseID)], endpoint: endpoint)
    }

    private static func request(function: AllowedFunction, token: String, fields: [String: String], endpoint: URL) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form(fields.merging([
            "wstoken": token,
            "wsfunction": function.rawValue,
            "moodlewsrestformat": "json",
            "moodlewssettingfilter": "true",
            "moodlewssettinglang": "it"
        ]) { _, required in required })
        return request
    }

    private static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
```

## Sources/BeepbarApp/UpdaterController.swift:1-24

```
import Sparkle

@MainActor final class UpdaterController {
    static let shared = UpdaterController()

    static var startsAutomatically: Bool {
#if DEBUG
        false
#else
        true
#endif
    }

    let controller = SPUStandardUpdaterController(startingUpdater: startsAutomatically, updaterDelegate: nil, userDriverDelegate: nil)

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
```
