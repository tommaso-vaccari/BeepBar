import AppKit
import BeepbarCore
import Combine
import Foundation
import os

/// Internal launch context, read on the main actor at send time. Only app and major OS
/// versions enter the payload; settings and language remain local.
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

    /// Values that need no app state, before the app installs its provider.
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

    /// Only app and major OS versions are reported; settings and language stay on the Mac.
    func payload(_ context: DailyTelemetryContext) -> [String: String] {
        [
            "TelemetryDeck.AppInfo.version": version,
            "TelemetryDeck.Device.platform": "macOS",
            "TelemetryDeck.Device.operatingSystem": "macOS",
            "TelemetryDeck.Device.systemMajorVersion": "macOS \(context.systemMajorVersion)",
        ]
    }

    /// A shared identifier and event counts replace per-installation identifiers.
    func request(firstInMonth: Bool, context: DailyTelemetryContext) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://nom.telemetrydeck.com/v2/namespace/\(namespace)/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("BeepBar", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: [[
            "appID": appID,
            "clientUser": "aggregate",
            "type": firstInMonth ? "BeepBar.monthlyActive.v2" : "BeepBar.dailyActive.v2",
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
/// All installations share the same public clientUser. The first attempted report in a UTC
/// month has a distinct event type; counting these estimates monthly reporting installations
/// without linking their daily reports. The month marker is monotonic and survives opt-out.
/// Failed requests consume both slots: no retries or catch-up can reveal an individual history.
@MainActor
final class DailyTelemetryController: ObservableObject {
    static let enabledKey = "dailyTelemetryEnabled"
    /// The permanent installation UUID of the first telemetry build (on `dev` only, never released).
    /// Deleted at construction along with the later monthly UUID; no individual ID remains.
    static let legacyInstallationKey = "dailyTelemetryInstallationID"
    static let monthlyIDKey = "dailyTelemetryMonthlyID"
    static let monthKey = "dailyTelemetryMonth"
    static let attemptKey = "dailyTelemetryLastAttempt"
    static let countedMonthKey = "dailyTelemetryCountedMonth"
    static let disclosureKey = "dailyTelemetryDisclosureVersion"
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
    private var disclosing = false
    private let disclose: @MainActor () -> Bool
    private var generation = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Reads the settings at send time. Installed by `start` before its guards and never reset, so
    /// the launch provider still applies after Settings turns telemetry off and on again.
    private var context: () -> DailyTelemetryContext = { .system() }

    init(defaults: UserDefaults, configuration: DailyTelemetryConfiguration?, defaultEnabled: Bool,
         now: @escaping () -> Date = Date.init,
         disclose: @escaping @MainActor () -> Bool = DailyTelemetryController.presentDisclosure,
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
        self.disclose = disclose
        self.send = send
        self.schedule = schedule
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? defaultEnabled
        defaults.removeObject(forKey: Self.legacyInstallationKey)
        Self.forgetIdentity(in: defaults)
    }

    func start(observing notifications: [(NotificationCenter, Notification.Name)] = [],
               context: (() -> DailyTelemetryContext)? = nil) async {
        if let context { self.context = context }
        guard !running, !disclosing, isEnabled, isConfigured else { return }
        if defaults.integer(forKey: Self.disclosureKey) < 1 {
            disclosing = true
            let keepEnabled = disclose()
            disclosing = false
            defaults.set(1, forKey: Self.disclosureKey)
            if !keepEnabled { setEnabled(false) }
        }
        guard !running, isEnabled else { return }
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

    /// Inform before the first request, including upgrades. Close acknowledges the notice,
    /// not consent; Settings opt-out leaves every app feature available. Tests inject a synthetic choice.
    static func presentDisclosure() -> Bool {
        disclosureAlert().runModal() == .alertFirstButtonReturn
    }

    static func disclosureAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = tr("Statistiche di BeepBar", "BeepBar statistics")
        let details = tr(
            "Tommaso Vaccari usa TelemetryDeck per statistiche aggregate sulla diffusione delle versioni di BeepBar e macOS, per pianificare manutenzione e compatibilità. Per i dati personali trasmessi, la base è il legittimo interesse a mantenere l’app affidabile (art. 6.1.f GDPR). Telemetria facoltativa e attiva di default: al massimo un invio al giorno, senza identificativo individuale, account, corsi, file, lingua o impostazioni. Il primo invio mensile viene contato separatamente. TelemetryDeck GmbH riceve l’IP; dichiara di non conservarlo e di usare server UE. Non garantisce un termine di cancellazione degli eventi archiviati. Puoi opporti disattivando Telemetria nelle Impostazioni senza perdere funzionalità; questo non cancella gli eventi già inviati. Titolare e contatto: Tommaso Vaccari, tommaso.vaccari@mail.polimi.it. Puoi chiedere accesso, rettifica, cancellazione e limitazione nei casi applicabili, opporti e presentare reclamo al Garante. Non usiamo questi dati per profilazione o decisioni automatizzate; non raccogliamo altri dati per attribuirti gli eventi. Chiudere questo avviso non costituisce consenso.",
            "Tommaso Vaccari uses TelemetryDeck for aggregate statistics about BeepBar and macOS version adoption to plan maintenance and compatibility. For transmitted personal data, the basis is the legitimate interest in maintaining a reliable app (GDPR Article 6(1)(f)). Telemetry is optional and enabled by default: at most one daily report, without an individual identifier, accounts, courses, files, language or settings. The first monthly report is counted separately. TelemetryDeck GmbH receives your IP; it states that it does not retain it and uses EU servers. It guarantees no deletion deadline for archived events. You can object by turning off Telemetry in Settings without losing features; this does not delete previously sent events. Controller and contact: Tommaso Vaccari, tommaso.vaccari@mail.polimi.it. You may request access, correction, erasure and restriction where applicable, object and complain to your supervisory authority. We do not use these data for profiling or automated decisions, or collect additional data to attribute events to you. Closing this notice does not constitute consent.")
        alert.informativeText = tr("Statistiche facoltative giornaliere e mensili, senza identificativo individuale. Sono attive per impostazione predefinita: gli invii possono iniziare dopo aver chiuso questo avviso. Puoi disattivarle in Impostazioni → Telemetria senza perdere funzionalità.", "Optional daily and monthly statistics, without an individual identifier. They are enabled by default: reports may start after you close this notice. You can disable them in Settings → Telemetry without losing features.")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.string = details
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel(tr("Informativa sulla telemetria", "Telemetry privacy information"))
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: tr("Chiudi", "Close"))
        return alert
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
            // Retain the non-identifying attempt markers to prevent recounting after opt-out.
            Self.forgetIdentity(in: defaults)
        }
    }

    private static func forgetIdentity(in defaults: UserDefaults) {
        defaults.removeObject(forKey: monthlyIDKey)
        defaults.removeObject(forKey: monthKey)
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
        let components = Self.utcCalendar.dateComponents([.year, .month], from: timestamp)
        let month = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        let firstInMonth = month > (defaults.string(forKey: Self.countedMonthKey) ?? "")
        guard let request = try? configuration.request(firstInMonth: firstInMonth, context: context()) else { return }
        if firstInMonth { defaults.set(month, forKey: Self.countedMonthKey) }
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
