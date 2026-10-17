import AppKit
import BeepbarCore
import Combine
import CryptoKit
import Foundation
import os

/// The settings a daily signal reports (#128). Each field has few possible values, but with a
/// small user base their combination, plus the source IP, can still be distinctive: the monthly
/// identifier limits linking on the client, it does not make the data anonymous.
/// Built on the main actor at send time, so a change made during the day shows up the next day.
/// A `nil` setting is unknown and left out of the payload rather than reported wrong.
struct DailyTelemetryContext: Equatable, Sendable {
    var language: AppLanguage
    /// Major macOS version only (e.g. 15): the full build would narrow installations down.
    var systemMajorVersion: Int
    var automaticSyncEnabled: Bool?
    /// One of the intervals offered in Settings, already validated by the sync controller.
    var automaticSyncInterval: Int?
    var dataSaverEnabled: Bool?
    /// True only when Polimi is selected (the default); it does not prove an authenticated account.
    var recordingsEnabled: Bool?
    /// `nil` while macOS hasn't answered yet.
    var launchAtLogin: Bool?

    /// Values that need no app state, for a signal sent before the app installed its provider
    /// (telemetry switched on in Settings during launch): the settings are then omitted.
    static func system(language: AppLanguage = .current) -> Self {
        Self(language: language, systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

/// Public ingest identifiers and the only application metadata sent in a daily signal.
struct DailyTelemetryConfiguration: Sendable {
    let appID: String
    let namespace: String
    let version: String

    init?(appID: String, namespace: String, version: String) {
        guard UUID(uuidString: appID) != nil, !namespace.isEmpty,
              namespace.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }),
              !version.isEmpty else { return nil }
        self.appID = appID
        self.namespace = namespace
        self.version = version
    }

    static func production(bundle: Bundle = .main) -> Self? {
#if DEBUG
        return nil
#else
        guard let appID = bundle.object(forInfoDictionaryKey: "BeepBarTelemetryAppID") as? String,
              let namespace = bundle.object(forInfoDictionaryKey: "BeepBarTelemetryNamespace") as? String,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        return Self(appID: appID, namespace: namespace, version: version)
#endif
    }

    /// The whole payload. App version, platform, macOS major version and language use the keys and
    /// value formats of TelemetryDeck's Swift SDK, so the dashboard's built-in version, OS and
    /// language insights read them without custom queries; nothing else from the SDK's default set
    /// (device model, screen, time zone, region, locale) is sent. BeepBar's own settings stay in the
    /// `BeepBar.` scope, as TelemetryDeck asks for custom keys. Values are strings, as the SDK sends.
    func payload(_ context: DailyTelemetryContext) -> [String: String] {
        var payload = [
            "TelemetryDeck.AppInfo.version": version,
            "TelemetryDeck.Device.platform": "macOS",
            "TelemetryDeck.Device.operatingSystem": "macOS",
            "TelemetryDeck.Device.systemMajorVersion": "macOS \(context.systemMajorVersion)",
            "TelemetryDeck.RunContext.language": context.language.rawValue,
        ]
        let flags: [(String, Bool?)] = [
            ("BeepBar.automaticSync", context.automaticSyncEnabled),
            ("BeepBar.dataSaver", context.dataSaverEnabled),
            ("BeepBar.recordings", context.recordingsEnabled),
            ("BeepBar.launchAtLogin", context.launchAtLogin),
        ]
        for case let (key, value?) in flags { payload[key] = value ? "true" : "false" }
        if let interval = context.automaticSyncInterval { payload["BeepBar.automaticSyncInterval"] = String(interval) }
        return payload
    }

    /// `clientID` is this month's random identifier; only its hash with the App ID leaves the Mac.
    func request(clientID: String, context: DailyTelemetryContext) throws -> URLRequest {
        let user = SHA256.hash(data: Data((appID + ":" + clientID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://nom.telemetrydeck.com/v2/namespace/\(namespace)/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("BeepBar", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [[
            "appID": appID,
            "clientUser": user,
            "type": "BeepBar.dailyActive",
            "payload": payload(context)
        ]])
        return request
    }
}

/// Completes on response headers and rejects the body, redirects and late cancellation callbacks.
private final class TelemetryHeaderReceiver: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var task: URLSessionDataTask?
        var result: Result<Void, any Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, any Error>) {
        let result = state.withLock { state -> Result<Void, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            state.task = task
            return nil as Result<Void, any Error>?
        }
        if let result { continuation.resume(with: result) } else { task.resume() }
    }

    func cancel() {
        finish(.failure(URLError(.cancelled)))
        state.withLock { $0.task }?.cancel()
    }

    private func finish(_ result: Result<Void, any Error>) {
        let continuation = state.withLock { state in
            guard state.result == nil else { return nil as CheckedContinuation<Void, any Error>? }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
            finish(.success(()))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(.failure(error ?? URLError(.badServerResponse)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        finish(.failure(URLError(.badServerResponse)))
        completionHandler(nil)
    }
}

enum DailyTelemetryTransport {
    static func send(_ request: URLRequest) async throws {
        try await send(request, configuration: .ephemeral)
    }

    static func send(_ request: URLRequest, configuration: URLSessionConfiguration) async throws {
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        let receiver = TelemetryHeaderReceiver()
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.begin(session.dataTask(with: request), continuation: continuation)
            }
        } onCancel: {
            receiver.cancel()
        }
    }
}

/// One best-effort attempt per UTC day, persisted across launches; disabling cancels without waiting.
///
/// Identity: a random UUID that lives for one UTC calendar month (`monthKey` records which). A
/// different month replaces it with a fresh random one, never derived from the previous one, so the
/// client keeps no link between months. The payload and source IP may still let the receiver
/// re-link them; that is a limit of the data, not something the identifier can fix. A clock moved
/// back sends nothing until the UTC day after the last attempt; then the saved identifier is
/// reused if its month matches, otherwise a fresh one is created.
/// Daily actives are the signals of a day (one per installation); monthly actives are distinct
/// identifiers within a calendar month.
@MainActor
final class DailyTelemetryController: ObservableObject {
    static let enabledKey = "dailyTelemetryEnabled"
    /// The permanent installation UUID of the first telemetry build (on `dev` only, never released).
    /// Deleted at construction so the monthly identifier is the only one left on the Mac.
    static let legacyInstallationKey = "dailyTelemetryInstallationID"
    static let monthlyIDKey = "dailyTelemetryMonthlyID"
    static let monthKey = "dailyTelemetryMonth"
    static let attemptKey = "dailyTelemetryLastAttempt"
    static let shared = DailyTelemetryController(
        defaults: PreviewMode.isActive ? UserDefaults(suiteName: "io.github.tvaccari.beepbar.preview.telemetry")! : .standard,
        configuration: .production(),
        defaultEnabled: Bundle.main.object(forInfoDictionaryKey: "BeepBarTelemetryDefaultEnabled") as? Bool ?? false
    )

    @Published private(set) var isEnabled: Bool
    var isConfigured: Bool { configuration != nil }
    private let defaults: UserDefaults
    private let configuration: DailyTelemetryConfiguration?
    private let now: () -> Date
    private let send: @Sendable (URLRequest) async throws -> Void
    private let schedule: (TimeInterval, @escaping @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void) -> BackgroundActivityRegistration
    private var activity: BackgroundActivityRegistration?
    private var requestTask: Task<Void, Never>?
    private var running = false
    private var generation = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Reads the settings at send time. Installed by `start` before its guards and never reset, so
    /// the launch provider still applies after Settings turns telemetry off and on again.
    private var context: () -> DailyTelemetryContext = { .system() }

    init(defaults: UserDefaults, configuration: DailyTelemetryConfiguration?, defaultEnabled: Bool,
         now: @escaping () -> Date = Date.init,
         send: @escaping @Sendable (URLRequest) async throws -> Void = DailyTelemetryTransport.send,
         schedule: @escaping (TimeInterval, @escaping @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void) -> BackgroundActivityRegistration = { interval, callback in
             let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.tvaccari.beepbar.daily-telemetry")
             scheduler.repeats = false
             scheduler.interval = interval
             scheduler.tolerance = min(3600, interval * 0.1)
             scheduler.qualityOfService = .background
             scheduler.schedule(callback)
             return BackgroundActivityRegistration(invalidate: { scheduler.invalidate() })
         }) {
        self.defaults = defaults
        self.configuration = configuration
        self.now = now
        self.send = send
        self.schedule = schedule
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? defaultEnabled
        defaults.removeObject(forKey: Self.legacyInstallationKey)
        if !isEnabled { Self.forgetIdentity(in: defaults) }
    }

    func start(observing notifications: [(NotificationCenter, Notification.Name)] = [],
               context: (() -> DailyTelemetryContext)? = nil) async {
        if let context { self.context = context }
        guard !running, isEnabled, isConfigured else { return }
        running = true
        for (center, name) in notifications {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in await self?.checkIn() }
            }
            observers.append((center, token))
        }
        scheduleNext()
        await checkIn()
    }

    func startForApplication(context: (() -> DailyTelemetryContext)? = nil) async {
        await start(observing: [
            (.default, NSApplication.didBecomeActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        ], context: context)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            Task { await startForApplication() }
        } else {
            stop()
            // Turning telemetry off leaves no identifier behind; turning it on again starts a new one.
            Self.forgetIdentity(in: defaults)
        }
    }

    private static func forgetIdentity(in defaults: UserDefaults) {
        defaults.removeObject(forKey: monthlyIDKey)
        defaults.removeObject(forKey: monthKey)
    }

    /// This month's identifier, created (and the previous one replaced) when the UTC month changed.
    private func clientID(at timestamp: Date) -> String {
        let components = Self.utcCalendar.dateComponents([.year, .month], from: timestamp)
        let month = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        if defaults.string(forKey: Self.monthKey) == month,
           let stored = defaults.string(forKey: Self.monthlyIDKey), UUID(uuidString: stored) != nil {
            return stored
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Self.monthlyIDKey)
        defaults.set(month, forKey: Self.monthKey)
        return fresh
    }

    func stop() {
        running = false
        generation += 1
        activity?.invalidate()
        activity = nil
        requestTask?.cancel()
        requestTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    func checkIn() async {
        guard running, isEnabled, let configuration, requestTask == nil else { return }
        let timestamp = now()
        if let attempted = defaults.object(forKey: Self.attemptKey) as? Date,
           attempted >= Self.utcCalendar.startOfDay(for: timestamp) { return }
        guard let request = try? configuration.request(clientID: clientID(at: timestamp), context: context()) else { return }
        // Persist before sending: failures and relaunches must not create retry storms.
        defaults.set(timestamp, forKey: Self.attemptKey)
        let currentGeneration = generation
        let task = Task<Void, Never> { [send] in
            do { try await send(request) } catch { }
        }
        requestTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == currentGeneration { requestTask = nil }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func scheduleNext() {
        guard running else { return }
        let timestamp = now()
        let tomorrow = Self.utcCalendar.date(byAdding: .day, value: 1, to: Self.utcCalendar.startOfDay(for: timestamp))!
        let currentGeneration = generation
        let delay = max(1, tomorrow.timeIntervalSince(timestamp))
        // tolerance extends before the nominal date; keep its earliest edge after midnight.
        let interval = delay + min(3600, delay / 9) + 1
        activity = schedule(interval) { [weak self] completion in
            Task { @MainActor in
                if let self, self.running, self.generation == currentGeneration {
                    await self.checkIn()
                    if self.running, self.generation == currentGeneration { self.scheduleNext() }
                }
                completion(.finished)
            }
        }
    }
}
