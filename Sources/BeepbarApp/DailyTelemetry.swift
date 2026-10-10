import AppKit
import Combine
import CryptoKit
import Foundation
import os

/// Public ingest identifiers and the only application metadata sent in a daily signal.
struct DailyTelemetryConfiguration: Sendable {
    let appID: String
    let namespace: String
    let version: String

    init?(appID: String, namespace: String, version: String) {
        guard UUID(uuidString: appID) != nil, !namespace.isEmpty,
              namespace.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }),
              !version.isEmpty else { return nil }
        self.appID = appID.lowercased()
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

    func request(installationID: String) throws -> URLRequest {
        let user = SHA256.hash(data: Data((appID + ":" + installationID).utf8))
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
            "payload": ["BeepBar.appVersion": version]
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
@MainActor
final class DailyTelemetryController: ObservableObject {
    static let enabledKey = "dailyTelemetryEnabled"
    static let installationKey = "dailyTelemetryInstallationID"
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
    }

    func start(observing notifications: [(NotificationCenter, Notification.Name)] = []) async {
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

    func startForApplication() async {
        await start(observing: [
            (.default, NSApplication.didBecomeActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        ])
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            Task { await startForApplication() }
        } else {
            stop()
        }
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
        let installationID: String
        if let stored = defaults.string(forKey: Self.installationKey), UUID(uuidString: stored) != nil {
            installationID = stored
        } else {
            installationID = UUID().uuidString
            defaults.set(installationID, forKey: Self.installationKey)
        }
        guard let request = try? configuration.request(installationID: installationID) else { return }
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
