#if UI_PERFORMANCE_HARNESS && !DEBUG
#error("The isolated UI harness requires DEBUG injection seams while retaining Release optimization")
#endif
#if DEBUG
import AppKit
import SwiftUI
import BeepbarCore
import os

/// Strict, finite workloads: a typo must not silently turn a large-corpus measurement into a
/// smaller one. This constructor is available to tests; the alternate entry point is opt-in.
struct UIFixtureScenario: Equatable {
    static let names = ["launch-cold", "launch-warm", "launch-offline", "courses-100", "courses-500", "reopen-sync", "activity-1000", "activity-15000", "recordings-1000", "recordings-5000", "progress-burst", "memory-cycles", "idle"]
    let name: String
    let report: URL
    var courseCount: Int { name == "courses-500" ? 500 : 100 }
    var activityCount: Int { name == "activity-15000" ? 15_000 : name == "activity-1000" ? 1_000 : 0 }
    var recordingsCount: Int { name == "recordings-5000" ? 5_000 : name == "recordings-1000" ? 1_000 : 0 }
    var cycles: Int { name == "memory-cycles" ? 10 : ["launch-warm", "reopen-sync"].contains(name) ? 2 : 1 }
    var idleSeconds: Int { name == "idle" ? 1_800 : 0 }
    var page: ShellPage { activityCount > 0 ? .activity : recordingsCount > 0 ? .recordings : .home }
    var requiredContent: UIContentKind { activityCount > 0 ? .expandedActivity : recordingsCount > 0 ? .recordings : .courses }

    init(arguments: [String]) throws {
        guard arguments.count == 4, arguments[0] == "--scenario", Self.names.contains(arguments[1]), arguments[2] == "--report", arguments[3].hasPrefix("/") else {
            throw UIFixtureError.invalidArguments
        }
        name = arguments[1]
        report = URL(fileURLWithPath: arguments[3])
        guard !FileManager.default.fileExists(atPath: report.path) else { throw UIFixtureError.existingReport }
    }
}

enum UIFixtureError: Error { case invalidArguments, existingReport, missingContent, noKeyWindow, unexpectedResponse, missingAccount }

/// A later activation is not the first key event. Keep the first timestamp for this open;
/// a new value is created for each window generation rather than reusing a focus transition.
struct UIFixtureWindowTiming {
    private(set) var keyMilliseconds: Double?
    mutating func becameKey(milliseconds: Double) -> Bool {
        guard keyMilliseconds == nil else { return false }
        keyMilliseconds = milliseconds
        return true
    }
}

/// A fail-closed Moodle: *all* URLSession requests are intercepted, including an unknown URL.
/// Accounts are keyed by synthetic token so parallel isolation tests cannot cross workloads.
final class UIFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Account: Sendable {
        let courses: [RemoteCourseSummary]
        var offline = false
        var requests = 0
        var holdContents = false
        var heldRequests: [UIFixtureProtocol] = []
    }
    static let accounts = OSAllocatedUnfairLock(initialState: [String: Account]())

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UIFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private struct Pending: Sendable { var stopped = false; var response: HTTPURLResponse?; var data: Data? }
    private let pending = OSAllocatedUnfairLock(initialState: Pending())

    override func stopLoading() { pending.withLock { $0.stopped = true; $0.data = nil; $0.response = nil } }

    /// Releases exactly the requests owned by this token, after the measured reopen has finished.
    static func releaseContents(token: String) {
        let held = accounts.withLock { values -> [UIFixtureProtocol] in
            let held = values[token]?.heldRequests ?? []
            values[token]?.holdContents = false
            values[token]?.heldRequests = []
            return held
        }
        held.forEach { $0.deliver() }
    }

    private func deliver() {
        let payload = pending.withLock { state -> (HTTPURLResponse, Data)? in
            guard !state.stopped, let response = state.response, let data = state.data else { return nil }
            state.stopped = true; state.response = nil; state.data = nil
            return (response, data)
        }
        // URLProtocol callbacks can synchronously reenter stopLoading; never call them under
        // our non-recursive state lock. A cancelled request is not allowed to resume twice.
        guard let (response, data) = payload else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        do {
            let fields = Self.fields(request)
            let account = Self.accounts.withLock { values -> Account? in
                guard let token = fields["wstoken"], values[token] != nil else { return nil }
                values[token]!.requests += 1
                return values[token]
            }
            guard let account else { throw UIFixtureError.missingAccount }
            if account.offline { throw URLError(.notConnectedToInternet) }
            guard request.url?.host == "webeep.polimi.it" else { throw URLError(.unsupportedURL) }
            let body: Any
            switch fields["wsfunction"] {
            case "core_webservice_get_site_info":
                body = ["userid": 7, "siteurl": "https://webeep.polimi.it", "functions": [["name": "core_enrol_get_users_courses"], ["name": "core_course_get_contents"]]]
            case "core_enrol_get_users_courses":
                body = account.courses.map { ["id": $0.id, "shortname": $0.shortName, "fullname": $0.displayName, "visible": 1] as [String: Any] }
            case "core_course_get_contents": body = [] as [Int]
            default: throw URLError(.unsupportedURL)
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { throw UIFixtureError.unexpectedResponse }
            pending.withLock { $0.response = response; $0.data = data }
            let held = Self.accounts.withLock { values -> Bool in
                guard let token = fields["wstoken"], fields["wsfunction"] == "core_course_get_contents", values[token]?.holdContents == true else { return false }
                values[token]?.heldRequests.append(self)
                return true
            }
            if !held { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private static func fields(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let items = URLComponents(string: "https://fixture.invalid/?" + (String(data: data, encoding: .utf8) ?? ""))?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}

/// No WebKit, default browser, pasteboard or SSO. The controller still exercises its real
/// session codec/store and listing state transitions using a synthetic reusable cookie.
@MainActor final class UIFixtureBrowser: RecmanBrowsing {
    var isOpen = false
    let count: Int
    init(count: Int) { self.count = count }
    static var cookie: HTTPCookie { HTTPCookie(properties: [.name: "fixture", .value: "synthetic", .domain: "aunicalogin.polimi.it", .path: "/", .secure: "TRUE"])! }
    func open(cookies: [HTTPCookie]) async { isOpen = true }
    func cookies() async -> [HTTPCookie] { [Self.cookie] }
    func signIn() async throws { throw UIFixtureError.unexpectedResponse }
    func playbackURL(for recording: RecmanRecording) async throws -> URL { throw UIFixtureError.unexpectedResponse }
    func close() { isOpen = false }
    func recordings(for key: RecmanCourseKey) async throws -> [RecmanRecording] {
        (0..<count).map { index in
            RecmanRecording(id: "fixture-\(index)", courseCode: key.courseCode, academicYear: key.academicYear, title: "Synthetic lecture \(index)", recordedAt: Date(timeIntervalSince1970: 1_791_504_000 - Double(index) * 3_600), kind: "Lecture", duration: "60 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link&transfer_id=fixture-\(index)")!)
        }
    }
}

/// Owns *every* persistent dependency. Destruction removes only this fresh UUID directory and
/// unregisters its token. No production constructor/default store may enter this factory.
@MainActor final class UIFixture {
    let root: URL
    let rootID: UUID
    /// Immutable identity crosses the protocol's Sendable lock closures, never controller state.
    nonisolated let token: String
    let session: URLSession
    let controller: WeBeepAuthenticationController
    let database: SyncDatabase
    let defaults: UserDefaults
    let browser: UIFixtureBrowser
    let scenario: UIFixtureScenario

    static func make(_ scenario: UIFixtureScenario) async throws -> UIFixture {
        let parent = ProcessInfo.processInfo.environment["BEEPBAR_UI_FIXTURE_TEMP_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw UIFixtureError.invalidArguments }
        let root = parent.appending(path: "BeepbarUIFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = "fixture-\(UUID().uuidString)"
        do {
            let courses = (1...scenario.courseCount).map { index in
                RemoteCourseSummary(id: Int64(index), shortName: String(format: "%06d", 58_000 + index), displayName: String(format: "%06d", 58_000 + index) + " - SYNTHETIC COURSE \(index) [2026-27]", isVisible: true, startDate: nil, endDate: nil)
            }
            UIFixtureProtocol.accounts.withLock { $0[token] = .init(courses: courses) }
            let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
            let rootID = UUID()
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: courses[0].displayName, localFolder: "Synthetic course", enabled: true))
            guard let defaults = UserDefaults(suiteName: root.appending(path: "defaults").path) else { throw UIFixtureError.unexpectedResponse }
            let session = UIFixtureProtocol.session()
            let browser = UIFixtureBrowser(count: scenario.recordingsCount)
            let store = RecordingsSessionStore { root.appending(path: "recordings") }
            let vault = CredentialVault(read: { _ in token }, write: { _ in })
            let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, apiClient: WeBeepAPIClient(session: session), downloader: RemoteDownloader(session: session), credentialVault: vault, deleteCredential: {}, defaults: defaults, recordingsStore: store, recordingsBrowser: { browser })
            // Validate the synthetic account through the injected refresh path; never enter
            // login/sign-out UI, which owns installed-account lifecycle side effects.
            await controller.refreshOnWindowOpen().value
            guard controller.courses.count == scenario.courseCount, controller.recordingsOwnerUserID == 7 else { throw UIFixtureError.missingContent }
            try store.save(RecmanSessionCodec.encode([UIFixtureBrowser.cookie], ownerUserID: 7))
            if scenario.activityCount > 0 {
                let items = (0..<scenario.activityCount).map { SyncedItem(id: "fixture-\($0)", name: "Synthetic slides \($0).pdf", kind: .added) }
                controller.setSyncStateForTesting(.synced(SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 1_791_504_000), added: items.count, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0, perCourse: [CourseSyncCount(courseID: 1, courseFolder: "Synthetic course", added: items.count, updated: 0, items: items)])))
            }
            if scenario.name == "launch-offline" { UIFixtureProtocol.accounts.withLock { $0[token]?.offline = true } }
            return UIFixture(root: root, rootID: rootID, token: token, session: session, controller: controller, database: database, defaults: defaults, browser: browser, scenario: scenario)
        } catch {
            UIFixtureProtocol.accounts.withLock { $0[token] = nil }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private init(root: URL, rootID: UUID, token: String, session: URLSession, controller: WeBeepAuthenticationController, database: SyncDatabase, defaults: UserDefaults, browser: UIFixtureBrowser, scenario: UIFixtureScenario) {
        self.root = root; self.rootID = rootID; self.token = token; self.session = session; self.controller = controller; self.database = database; self.defaults = defaults; self.browser = browser; self.scenario = scenario
    }

    /// Call after sync is drained and the hosting tree is released, before deleting owned files.
    func dispose() {
        session.invalidateAndCancel()
        browser.close()
        UIFixtureProtocol.accounts.withLock { $0[token] = nil }
        defaults.removePersistentDomain(forName: root.appending(path: "defaults").path)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif

#if UI_PERFORMANCE_HARNESS
import Darwin

/// This entry point never constructs AppDelegate, the real credential store, Sparkle or
/// LaunchAtLoginController. Release optimization stays on; DEBUG enables only existing DI seams.
@main enum UIPerformanceMain {
    @MainActor static func main() {
        do {
            if Array(CommandLine.arguments.dropFirst()) == ["--harness-identity"] {
                print("beepbar-isolated-ui-fixture-v1")
                return
            }
            let scenario = try UIFixtureScenario(arguments: Array(CommandLine.arguments.dropFirst()))
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = UIFixtureDelegate(scenario: scenario)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            fputs("UI fixture refused: \(error)\n", stderr)
            exit(64)
        }
    }
}

/// The passive process counters need no polling timer, and distinguish fixture requests from
/// OS work. CPU uses the Mach timebase, not nanoseconds guessed from raw ticks.
struct UIFixtureResources: Codable {
    let footprintBytes: UInt64
    let cpuNanoseconds: Double
    let diskBytesWritten: UInt64
    let logicalBytesWritten: UInt64
    let interruptWakeups: UInt64
    let idleWakeups: UInt64
    static func read() throws -> Self {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Self(footprintBytes: info.ri_phys_footprint, cpuNanoseconds: Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom), diskBytesWritten: info.ri_diskio_byteswritten, logicalBytesWritten: info.ri_logical_writes, interruptWakeups: info.ri_interrupt_wkups, idleWakeups: info.ri_pkg_idle_wkups)
    }
}

struct UIFixtureCycle: Codable {
    let index: Int
    let keyMilliseconds: Double
    let contentMilliseconds: [String: Double]
    let resourcesAfterClose: UIFixtureResources
}

struct UIFixtureReport: Encodable {
    let schemaVersion = 1
    let scenario: String
    let valid: Bool
    let error: String?
    let courseCount: Int
    let activityCount: Int
    let recordingsCount: Int
    let fixtureSetupMilliseconds: Double
    let iconConstructionMilliseconds: Double
    let cycles: [UIFixtureCycle]
    let idleSeconds: Int
    let idleBefore: UIFixtureResources?
    let idleAfter: UIFixtureResources?
    let fixtureRequestsDuringIdle: Int?
    let scheduledChecksDuringIdle = 0
    let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    let thermalState = ProcessInfo.processInfo.thermalState.rawValue
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let limitations: [String]
}

/// Hosts the actual application shell in the normal makeWindow window. Window callbacks only
/// send immutable timestamp/signal values to the main actor, preserving the AppKit boundary.
@MainActor final class UIFixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let scenario: UIFixtureScenario
    var fixture: UIFixture?
    var window: NSWindow?
    var icon: StatusItemController?
    var router: ShellRouter?
    var openedAt: UInt64 = 0
    var timing = UIFixtureWindowTiming()
    var keyMilliseconds: Double? { timing.keyMilliseconds }
    var contentMilliseconds: [String: Double] = [:]
    var ready: CheckedContinuation<Void, Error>?
    var timedOut = false
    var generation = 0
    var cycles: [UIFixtureCycle] = []
    var setupMilliseconds = 0.0
    var iconMilliseconds = 0.0
    var idleBefore: UIFixtureResources?
    var idleAfter: UIFixtureResources?
    var idleRequests: Int?
    init(scenario: UIFixtureScenario) { self.scenario = scenario }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in await self?.run() }
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        // The notification is not sent across executors; the sender's identity is immutable.
        let identifier = (notification.object as? NSWindow).map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, identifier == ObjectIdentifier(window) else { return }
            guard self.timing.becameKey(milliseconds: self.elapsed(since: self.openedAt, until: timestamp)) else { return }
            PerformanceTrace.shared.event("ui.windowKey", category: .ui)
            self.signalReady()
        }
    }

    private func elapsed(since: UInt64, until: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Double { Double(until - since) / 1_000_000 }

    private func signalReady() {
        guard keyMilliseconds != nil, contentMilliseconds[scenario.requiredContent.rawValue] != nil else { return }
        ready?.resume(); ready = nil
    }

    private func open(_ fixture: UIFixture) async throws {
        generation += 1
        let generation = generation
        timing = UIFixtureWindowTiming(); contentMilliseconds = [:]; timedOut = false
        let router = ShellRouter(); router.page = scenario.page; self.router = router
        openedAt = DispatchTime.now().uptimeNanoseconds
        PerformanceTrace.shared.event("ui.fixtureOpen", category: .ui)
        // The immutable fixture is automated: disabling controls prevents a user click/shortcut
        // from launching settings, a real browser, login, folder panels or updater preferences.
        let root = BeepbarShellView(authentication: fixture.controller, recordings: fixture.controller.recordings, router: router)
            .environment(\.uiFixtureExpandedActivity, scenario.activityCount > 0)
            .environment(\.uiContentObserver, { [weak self] kind in
                guard let self, self.generation == generation, self.contentMilliseconds[kind.rawValue] == nil else { return }
                self.contentMilliseconds[kind.rawValue] = self.elapsed(since: self.openedAt)
                self.signalReady()
            })
            .disabled(true)
        let window = ConfigurationWindowController.makeWindow(content: root)
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == generation else { return }
            self.timedOut = true
            self.ready?.resume(throwing: UIFixtureError.missingContent); self.ready = nil
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if timedOut { continuation.resume(throwing: UIFixtureError.missingContent) }
            else { ready = continuation; signalReady() }
        }
        // The real refresh path still runs against mock Moodle, including the offline failure.
        await fixture.controller.refreshOnWindowOpen().value
        if scenario.name == "launch-offline", fixture.controller.courseLoadError == nil {
            throw UIFixtureError.unexpectedResponse
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    private func close() async throws {
        window?.delegate = nil
        window?.close(); window = nil; router = nil
        fixture?.controller.recordingsIfCreated?.windowClosed()
        // A fixed, documented settling window gives AppKit/autorelease/SwiftUI release work time.
        try await Task.sleep(for: .seconds(3))
    }

    private func run() async {
        var failure: Error?
        do {
            let setupStart = DispatchTime.now().uptimeNanoseconds
            let fixture = try await UIFixture.make(scenario); self.fixture = fixture
            setupMilliseconds = elapsed(since: setupStart)
            let iconStart = DispatchTime.now().uptimeNanoseconds
            icon = StatusItemController(authentication: fixture.controller)
            iconMilliseconds = elapsed(since: iconStart)
            for index in 1...scenario.cycles {
                if scenario.name == "memory-cycles" || (scenario.name == "reopen-sync" && index == 1) {
                    UIFixtureProtocol.accounts.withLock { $0[fixture.token]?.holdContents = true }
                    fixture.controller.synchronizeNow()
                    guard fixture.controller.isSyncActive else { throw UIFixtureError.unexpectedResponse }
                }
                try await open(fixture)
                if scenario.name == "reopen-sync" {
                    guard fixture.controller.isSyncActive else { throw UIFixtureError.unexpectedResponse }
                }
                if scenario.name == "progress-burst" {
                    fixture.controller.setOperationForTesting(UUID())
                    fixture.controller.setSyncStateForTesting(.syncing)
                    await fixture.controller.progressStore.reset(automatic: false)
                    let controller = fixture.controller
                    let trace = PerformanceTrace.shared.begin("ui.fixtureProgressBurst", category: .ui)
                    // The producer runs off-main and calls the same publish method as sync.
                    // Intermediate events retain the application's real throttling behavior.
                    await Task.detached {
                        for batch in 0..<10 {
                            for index in 1...1_000 {
                                let completed = batch * 1_000 + index
                                await controller.publishProgressForTesting(SyncProgress(completed: completed, total: 10_000, installed: completed, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
                            }
                            try? await Task.sleep(for: .milliseconds(16))
                        }
                    }.value
                    PerformanceTrace.shared.end("ui.fixtureProgressBurst", category: .ui, state: trace)
                    fixture.controller.setOperationForTesting(nil)
                    fixture.controller.setSyncStateForTesting(.readyUnchecked)
                }
                if scenario.name != "reopen-sync" || index == scenario.cycles {
                    UIFixtureProtocol.releaseContents(token: fixture.token)
                    await fixture.controller.waitForSyncForTesting()
                }
                let key = keyMilliseconds!; let content = contentMilliseconds
                try await close()
                cycles.append(UIFixtureCycle(index: index, keyMilliseconds: key, contentMilliseconds: content, resourcesAfterClose: try UIFixtureResources.read()))
            }
            if scenario.idleSeconds > 0 {
                let requestsBefore = UIFixtureProtocol.accounts.withLock { $0[fixture.token]?.requests ?? 0 }
                idleBefore = try UIFixtureResources.read()
                // No sampling/polling timer: only the one end-of-window deadline is armed.
                try await Task.sleep(for: .seconds(scenario.idleSeconds))
                idleAfter = try UIFixtureResources.read()
                idleRequests = UIFixtureProtocol.accounts.withLock { ($0[fixture.token]?.requests ?? 0) - requestsBefore }
            }
        } catch { failure = error }
        let report = UIFixtureReport(scenario: scenario.name, valid: failure == nil && cycles.count == scenario.cycles, error: failure.map { String(describing: $0) }, courseCount: scenario.courseCount, activityCount: scenario.activityCount, recordingsCount: scenario.recordingsCount, fixtureSetupMilliseconds: setupMilliseconds, iconConstructionMilliseconds: iconMilliseconds, cycles: cycles, idleSeconds: scenario.idleSeconds, idleBefore: idleBefore, idleAfter: idleAfter, fixtureRequestsDuringIdle: idleRequests, limitations: [
            "Synthetic controller DI startup; production credential/bootstrap/migration and process-loader latency are not measured.",
            "Content is SwiftUI onAppear of populated data; not compositor presentation. Key window latency is separate.",
            "Fixtures seed known courses online before offline refresh; this does not prove persisted course restoration at offline app launch (D10).",
            "Activity expands via a fixture-only state seam; manual scrolling and actions require a separate isolated interactive verification.",
            "Controls are disabled to forbid interactive external side effects; fixture status item has no menu.",
            "Progress stressor uses an off-main producer and the current sync publication path; deterministic producer ingress counts remain D08.",
            "Real scheduler, notifications, login-at-launch and Sparkle are absent. Idle measures the isolated closed-window baseline, not due production checks.",
            "Five samples produce a maximum labeled p95; no reliable tail claim. Main-thread occupancy requires a Time Profiler trace."
        ])
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: scenario.report, options: .withoutOverwriting)
        } catch { failure = error; fputs("Cannot write UI report: \(error)\n", stderr) }
        window?.delegate = nil; window?.close(); window = nil
        if let fixture {
            UIFixtureProtocol.releaseContents(token: fixture.token)
            _ = fixture.controller.prepareForTermination()
            await fixture.controller.waitForSyncForTesting()
            fixture.dispose()
        }
        fixture = nil
        if let failure { fputs("UI fixture failed: \(failure)\n", stderr); exit(1) }
        NSApp.terminate(nil)
    }
}
#endif
