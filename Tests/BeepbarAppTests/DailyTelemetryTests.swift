import AppKit
import Foundation
import Testing
import os
@testable import BeepbarApp

@MainActor
struct DailyTelemetryTests {
    private let configuration = DailyTelemetryConfiguration(appID: "AD3B2F70-8FAE-47B1-A58B-4870921E2398", namespace: "com.beepbar", version: "1.2.3")!

    /// The wire contract contains a stable pseudonym and only the selected app version metadata.
    @Test func payloadIsMinimalAndStable() throws {
        let first = try configuration.request(installationID: "installation-a")
        let second = try configuration.request(installationID: "installation-a")
        let other = try configuration.request(installationID: "installation-b")
        let body = try #require(first.httpBody)
        let signals = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let signal = try #require(signals.first)
        #expect(signals.count == 1)
        #expect(Set(signal.keys) == ["appID", "clientUser", "type", "payload"])
        #expect(signal["appID"] as? String == "AD3B2F70-8FAE-47B1-A58B-4870921E2398")
        #expect(signal["type"] as? String == "BeepBar.dailyActive")
        #expect(signal["payload"] as? [String: String] == ["BeepBar.appVersion": "1.2.3"])
        #expect((signal["clientUser"] as? String)?.count == 64)
        #expect(try identity(first) == identity(second))
        #expect(try identity(first) != identity(other))
        #expect(first.url?.absoluteString == "https://nom.telemetrydeck.com/v2/namespace/com.beepbar/")
        #expect(first.httpMethod == "POST")
        #expect(first.timeoutInterval == 10)
    }

    /// Invalid configuration cannot create an endpoint; debug builds cannot emit production signals.
    @Test func configurationRejectsInvalidIdentifiers() {
        #expect(DailyTelemetryConfiguration(appID: "not-a-uuid", namespace: "com.beepbar", version: "1") == nil)
        #expect(DailyTelemetryConfiguration(appID: configuration.appID, namespace: "../escape/path", version: "1") == nil)
        #expect(DailyTelemetryConfiguration(appID: configuration.appID, namespace: "", version: "1") == nil)
#if DEBUG
        #expect(DailyTelemetryConfiguration.production() == nil)
#endif
    }

    /// Restarting does not duplicate today's signal or change the identity; crossing UTC midnight permits one more.
    @Test func oneAttemptPerUTCDaySurvivesRelaunch() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_057_599))
        let recorder = Recorder()
        let first = harness.controller(configuration, clock: clock, recorder: recorder)
        await first.start()
        await first.checkIn()
        #expect(await recorder.count == 1)
        first.stop()
        let second = harness.controller(configuration, clock: clock, recorder: recorder)
        await second.start()
        #expect(await recorder.count == 1)
        clock.date = Date(timeIntervalSince1970: 1_800_057_600)
        await second.checkIn()
        #expect(await recorder.count == 2)
        let requests = await recorder.requests
        #expect(try identity(requests[0]) == identity(requests[1]))
        second.stop()
    }

    /// Disabled, missing configuration and a saved opt-out create neither identifiers nor activity.
    @Test func disabledAndUnconfiguredHaveNoSideEffects() async {
        for configured in [false, true] {
            let harness = Harness()
            defer { harness.remove() }
            harness.defaults.set(false, forKey: DailyTelemetryController.enabledKey)
            let recorder = Recorder()
            let controller = harness.controller(configured ? configuration : nil, recorder: recorder)
            await controller.start()
            await controller.checkIn()
            #expect(!controller.isEnabled)
            #expect(harness.callbacks.isEmpty)
            #expect(harness.defaults.object(forKey: DailyTelemetryController.installationKey) == nil)
            #expect(await recorder.count == 0)
        }
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let controller = harness.controller(nil, recorder: recorder)
        await controller.start()
        #expect(harness.callbacks.isEmpty)
        #expect(harness.defaults.object(forKey: DailyTelemetryController.installationKey) == nil)
        #expect(await recorder.count == 0)
    }

    /// First launches and updates send by default, but a saved opt-out survives relaunch and later opt-in.
    @Test func defaultOnAndSavedOptOutSurviveRelaunch() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        #expect(controller.isEnabled)
        await controller.start()
        #expect(await recorder.count == 1)
        controller.setEnabled(false)
        let relaunched = harness.controller(configuration, clock: clock, recorder: recorder)
        #expect(!relaunched.isEnabled)
        await relaunched.start()
        #expect(await recorder.count == 1)
        clock.date += 86_400
        relaunched.setEnabled(true)
        for _ in 0..<1_000 {
            if await recorder.count == 2 { break }
            await Task.yield()
        }
        #expect(await recorder.count == 2)
        let requests = await recorder.requests
        #expect(try identity(requests[0]) == identity(requests[1]))
        #expect(harness.defaults.bool(forKey: DailyTelemetryController.enabledKey))
        relaunched.stop()
        let enabledAgain = harness.controller(configuration, clock: clock, recorder: recorder)
        #expect(enabledAgain.isEnabled)
        await enabledAgain.start()
        #expect(await recorder.count == 2)
        enabledAgain.stop()
    }

    /// A failed request consumes the daily attempt and resumes the next day, without retrying on wake.
    @Test func failureDoesNotRetryUntilNextDay() async {
        let harness = Harness()
        defer { harness.remove() }
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let recorder = Recorder(failing: true)
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        await controller.start()
        await controller.checkIn()
        #expect(await recorder.count == 1)
        clock.date += 86_400
        await controller.checkIn()
        #expect(await recorder.count == 2)
        controller.stop()
    }

    /// Disabling cancels a suspended sender and makes a queued scheduler callback inert.
    @Test func disablingCancelsAndRejectsStaleCallback() async {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder(suspending: true)
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        let start = Task { await controller.start() }
        while await recorder.count == 0 { await Task.yield() }
        await controller.checkIn()
        #expect(await recorder.count == 1)
        controller.setEnabled(false)
        await start.value
        #expect(await recorder.cancelled)
        #expect(harness.invalidations == 1)
        clock.date += 86_400
        await harness.fire(0)
        #expect(await recorder.count == 1)
        #expect(harness.callbacks.count == 1)
        #expect(harness.defaults.bool(forKey: DailyTelemetryController.enabledKey) == false)
    }

    /// A scheduled signal re-arms the next day and preserves a user opt-out across construction.
    @Test func scheduleRearmsAndSavedChoiceWins() async {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        await controller.start()
        let interval = harness.intervals[0]
        let delay = 86_400 - clock.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        #expect(interval - min(3600, interval * 0.1) >= delay)
        #expect(interval <= 90_001)
        clock.date += 86_400
        await harness.fire(0)
        #expect(await recorder.count == 2)
        #expect(harness.callbacks.count == 2)
        controller.setEnabled(false)
        let second = harness.controller(configuration, recorder: recorder)
        #expect(!second.isEnabled)
    }

    /// Updates retain the installation identity while reporting the version from the new build.
    @Test func updateChangesVersionWithoutChangingIdentity() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let first = harness.controller(configuration, clock: clock, recorder: recorder)
        await first.start()
        first.stop()
        clock.date += 86_400
        let updated = try #require(DailyTelemetryConfiguration(appID: configuration.appID, namespace: configuration.namespace, version: "1.2.4"))
        let second = harness.controller(updated, clock: clock, recorder: recorder)
        await second.start()
        let requests = await recorder.requests
        #expect(requests.count == 2)
        #expect(try identity(requests[0]) == identity(requests[1]))
        let data = try #require(requests[1].httpBody)
        let signals = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(signals.first?["payload"] as? [String: String] == ["BeepBar.appVersion": "1.2.4"])
        second.stop()
    }

    /// A wake retries the day check; disabling removes observers and prevents future wake signals.
    @Test func wakeChecksNewDayAndOptOutRemovesObserver() async {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let center = NotificationCenter()
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        await controller.start(observing: [(center, NSWorkspace.didWakeNotification)])
        clock.date += 86_400
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<1_000 {
            if await recorder.count == 2 { break }
            await Task.yield()
        }
        #expect(await recorder.count == 2)
        controller.setEnabled(false)
        clock.date += 86_400
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<10 { await Task.yield() }
        #expect(await recorder.count == 2)
    }

    /// An unexpected early callback cannot send twice; the replacement still starts after midnight.
    @Test func earlyCallbackDoesNotCreateAnEarlyWindow() async {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_057_599))
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        await controller.start()
        await harness.fire(0)
        #expect(await recorder.count == 1)
        #expect(harness.intervals.count == 2)
        for interval in harness.intervals {
            #expect(interval - min(3600, interval * 0.1) >= 1)
        }
        clock.date += 1
        await harness.fire(1)
        #expect(await recorder.count == 2)
        controller.stop()
    }

    /// Exercise the real URLSession sender: accept success, reject errors and bound the session policy.
    @Test func transportAcceptsOnlySuccessfulHeaders() async throws {
        for status in [200, 204, 302, 500] {
            let id = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TelemetryProtocol.self]
            TelemetryProtocol.statuses.withLock { $0[id] = status }
            defer {
                TelemetryProtocol.statuses.withLock { _ = $0.removeValue(forKey: id) }
                TelemetryProtocol.redirected.withLock { _ = $0.remove(id) }
                TelemetryProtocol.stopped.withLock { _ = $0.remove(id) }
            }
            var request = URLRequest(url: URL(string: "https://telemetry.invalid/\(id)")!)
            request.httpMethod = "POST"
            var succeeded = false
            do {
                try await DailyTelemetryTransport.send(request, configuration: configuration)
                succeeded = true
            } catch { }
            #expect(succeeded == (status < 300))
            #expect(!TelemetryProtocol.redirected.withLock { $0.contains(id) })
            #expect(configuration.httpCookieStorage == nil)
            #expect(configuration.urlCache == nil)
            #expect(configuration.urlCredentialStorage == nil)
            #expect(configuration.timeoutIntervalForResource == 15)
            #expect(!configuration.waitsForConnectivity)
            #expect(!configuration.allowsConstrainedNetworkAccess)
            #expect(!configuration.allowsExpensiveNetworkAccess)
        }
    }

    /// Success requires headers only; an unfinished response stream is cancelled instead of buffered.
    @Test func transportCancelsAnUnfinishedResponseBody() async throws {
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryProtocol.self]
        TelemetryProtocol.statuses.withLock { $0[id] = 200 }
        defer {
            TelemetryProtocol.statuses.withLock { _ = $0.removeValue(forKey: id) }
            TelemetryProtocol.stopped.withLock { _ = $0.remove(id) }
        }
        let request = URLRequest(url: URL(string: "https://telemetry.invalid/\(id)?endless")!)
        try await DailyTelemetryTransport.send(request, configuration: configuration)
        for _ in 0..<200 {
            if TelemetryProtocol.stopped.withLock({ $0.contains(id) }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(TelemetryProtocol.stopped.withLock { $0.contains(id) })
    }

    /// Cancellation finishes both a running request and one cancelled before registration, without hanging.
    @Test(arguments: [false, true]) func transportCancellationFinishes(immediately: Bool) async throws {
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryProtocol.self]
        TelemetryProtocol.statuses.withLock { $0[id] = 200 }
        defer {
            TelemetryProtocol.statuses.withLock { _ = $0.removeValue(forKey: id) }
            TelemetryProtocol.started.withLock { _ = $0.remove(id) }
            TelemetryProtocol.stopped.withLock { _ = $0.remove(id) }
        }
        let request = URLRequest(url: URL(string: "https://telemetry.invalid/\(id)?stall")!)
        let task = Task {
            do {
                try await DailyTelemetryTransport.send(request, configuration: configuration)
                return false
            } catch { return (error as? URLError)?.code == .cancelled }
        }
        if !immediately {
            for _ in 0..<200 {
                if TelemetryProtocol.started.withLock({ $0.contains(id) }) { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(TelemetryProtocol.started.withLock { $0.contains(id) })
        }
        task.cancel()
        #expect(await task.value)
    }

    private final class TelemetryProtocol: URLProtocol, @unchecked Sendable {
        static let statuses = OSAllocatedUnfairLock(initialState: [String: Int]())
        static let redirected = OSAllocatedUnfairLock(initialState: Set<String>())
        static let stopped = OSAllocatedUnfairLock(initialState: Set<String>())
        static let started = OSAllocatedUnfairLock(initialState: Set<String>())
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "telemetry.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url,
                  let status = Self.statuses.withLock({ $0[url.lastPathComponent] }),
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            Self.started.withLock { _ = $0.insert(url.lastPathComponent) }
            if url.query == "stall" { return }
            if url.query == "redirected" {
                Self.redirected.withLock { _ = $0.insert(url.lastPathComponent) }
                let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: success, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            if status == 302 {
                var redirect = request
                redirect.url = URL(string: url.absoluteString + "?redirected")!
                client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if url.query == "endless" {
                client?.urlProtocol(self, didLoad: Data([0]))
                return
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {
            if let id = request.url?.lastPathComponent { Self.stopped.withLock { _ = $0.insert(id) } }
        }
    }

    private func identity(_ request: URLRequest) throws -> String {
        let data = try #require(request.httpBody)
        let signals = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try #require(signals.first?["clientUser"] as? String)
    }

    @MainActor private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private actor Recorder {
        var requests: [URLRequest] = []
        var count: Int { requests.count }
        var cancelled = false
        let failing: Bool
        let suspending: Bool
        init(failing: Bool = false, suspending: Bool = false) {
            self.failing = failing
            self.suspending = suspending
        }
        func send(_ request: URLRequest) async throws {
            requests.append(request)
            if failing { throw URLError(.notConnectedToInternet) }
            if suspending {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = Task.isCancelled; throw error }
            }
        }
    }

    @MainActor private final class Harness {
        let suite = "BeepbarTests.Telemetry.\(UUID().uuidString)"
        let defaults: UserDefaults
        var callbacks: [@Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void] = []
        var intervals: [TimeInterval] = []
        var invalidations = 0
        init() { defaults = UserDefaults(suiteName: suite)! }
        func controller(_ configuration: DailyTelemetryConfiguration?, clock: Clock = Clock(Date()), recorder: Recorder) -> DailyTelemetryController {
            DailyTelemetryController(defaults: defaults, configuration: configuration, defaultEnabled: true,
                now: { clock.date }, send: { try await recorder.send($0) }, schedule: { [self] interval, callback in
                    intervals.append(interval)
                    callbacks.append(callback)
                    return BackgroundActivityRegistration(invalidate: { self.invalidations += 1 })
                })
        }
        func fire(_ index: Int) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                callbacks[index]({ _ in continuation.resume() })
            }
        }
        func remove() { defaults.removePersistentDomain(forName: suite) }
    }
}
