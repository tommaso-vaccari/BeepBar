import AppKit
import Foundation
import Testing
import os
import BeepbarCore
@testable import BeepbarApp

@MainActor
struct DailyTelemetryTests {
    private let configuration = DailyTelemetryConfiguration(appID: "AD3B2F70-8FAE-47B1-A58B-4870921E2398", namespace: "com.beepbar", version: "1.2.3")!

    private let context = DailyTelemetryContext(language: .english, systemMajorVersion: 15, automaticSyncEnabled: true,
                                                automaticSyncInterval: 28_800, dataSaverEnabled: false,
                                                recordingsEnabled: true, launchAtLogin: true)

    /// The wire contract: one shared identifier and exactly the allowed fields, under the SDK's key
    /// names and value formats where TelemetryDeck's built-in insights read them. Fails if a field
    /// is added, renamed, or reformatted (e.g. a full macOS build instead of the major version).
    @Test func payloadIsMinimalAndStable() throws {
        let first = try configuration.request(firstInMonth: false, context: context)
        let second = try configuration.request(firstInMonth: false, context: context)
        let other = try configuration.request(firstInMonth: true, context: context)
        let body = try #require(first.httpBody)
        let signals = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let signal = try #require(signals.first)
        #expect(signals.count == 1)
        #expect(Set(signal.keys) == ["appID", "clientUser", "type", "payload"])
        #expect(signal["appID"] as? String == "AD3B2F70-8FAE-47B1-A58B-4870921E2398")
        #expect(signal["type"] as? String == "BeepBar.dailyActive.v2")
        #expect(signal["payload"] as? [String: String] == [
            "TelemetryDeck.AppInfo.version": "1.2.3",
            "TelemetryDeck.Device.platform": "macOS",
            "TelemetryDeck.Device.operatingSystem": "macOS",
            "TelemetryDeck.Device.systemMajorVersion": "macOS 15",
        ])
        #expect(!String(decoding: body, as: UTF8.self).contains("installation-a"))
        #expect(signal["clientUser"] as? String == "aggregate")
        #expect(try identity(first) == identity(second))
        #expect(try identity(first) == identity(other))
        #expect(try eventType(other) == "BeepBar.monthlyActive.v2")
        #expect(first.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(first.url?.absoluteString == "https://nom.telemetrydeck.com/v2/namespace/com.beepbar/")
        #expect(first.httpMethod == "POST")
        #expect(first.timeoutInterval == 10)
    }

    /// Settings and language never enter the payload, even when their values are known.
    @Test func unknownLoginItemIsOmitted() {
        var unknown = context
        unknown.launchAtLogin = nil
        unknown.language = .italian
        let payload = configuration.payload(unknown)
        #expect(payload["BeepBar.launchAtLogin"] == nil)
        #expect(payload["TelemetryDeck.RunContext.language"] == nil)
        #expect(payload == configuration.payload(context))
    }

    /// Fallback context follows the same minimal wire contract.
    @Test func fallbackContextOmitsSettings() {
        #expect(Set(configuration.payload(.system(language: .italian)).keys) == [
            "TelemetryDeck.AppInfo.version", "TelemetryDeck.Device.platform", "TelemetryDeck.Device.operatingSystem",
            "TelemetryDeck.Device.systemMajorVersion",
        ])
    }

    /// Telemetry off at launch, then switched on in Settings: the signal still reads the context
    /// through the provider the launch installed, not the fallback.
    @Test func launchProviderSurvivesEnablingLater() async throws {
        let harness = Harness()
        defer { harness.remove() }
        harness.defaults.set(false, forKey: DailyTelemetryController.enabledKey)
        let recorder = Recorder()
        let controller = harness.controller(configuration, recorder: recorder)
        let provided = context
        await controller.start(context: { provided })
        #expect(await recorder.count == 0)
        controller.setEnabled(true)
        for _ in 0..<1_000 {
            if await recorder.count == 1 { break }
            await Task.yield()
        }
        let payloads = try await recorder.requests.map(payload)
        #expect(payloads.first == configuration.payload(context))
        controller.stop()
    }

    /// Recordings is reported from its saved switch without building the controller, on by
    /// default for Polimi; once the controller exists, its live state wins.
    @Test func recordingsAreReadWithoutCreatingTheController() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beepbar-telemetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        let authentication = WeBeepAuthenticationController(testRootURL: root, deleteCredential: {}, defaults: defaults)
        #expect(authentication.selectedSite.university == .polimi)
        #expect(authentication.recordingsEnabledWithoutCreating)
        defaults.set(false, forKey: RecordingsController.enabledKey)
        #expect(!authentication.recordingsEnabledWithoutCreating)
        #expect(authentication.recordingsIfCreated == nil)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        #expect(authentication.recordings.isEnabled)
        // The saved value changing behind the controller doesn't matter once it exists.
        defaults.set(false, forKey: RecordingsController.enabledKey)
        #expect(authentication.recordingsEnabledWithoutCreating)
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

    /// Information is presented before scheduling, creating markers or sending, once per version.
    @Test func disclosurePrecedesFirstAttemptAndSurvivesRelaunch() async {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        var shown = 0
        harness.disclosure = {
            shown += 1
            #expect(harness.callbacks.isEmpty)
            #expect(harness.defaults.object(forKey: DailyTelemetryController.attemptKey) == nil)
            #expect(harness.defaults.object(forKey: DailyTelemetryController.countedMonthKey) == nil)
            return true
        }
        let first = harness.controller(configuration, recorder: recorder)
        await first.start()
        first.stop()
        let second = harness.controller(configuration, recorder: recorder)
        await second.start()
        #expect(shown == 1)
        #expect(await recorder.count == 1)
        second.stop()
    }

    /// Rejecting the notice saves opt-out; an existing opt-out or missing config never prompts.
    @Test func disclosureOptOutPreventsAllActivity() async {
        for configured in [false, true] {
            let harness = Harness()
            defer { harness.remove() }
            let recorder = Recorder()
            var shown = 0
            harness.disclosure = { shown += 1; return false }
            let first = harness.controller(configured ? configuration : nil, recorder: recorder)
            await first.start()
            #expect(shown == (configured ? 1 : 0))
            #expect(await recorder.count == 0)
            #expect(harness.callbacks.isEmpty)
            #expect(harness.defaults.object(forKey: DailyTelemetryController.attemptKey) == nil)
            let second = harness.controller(configured ? configuration : nil, recorder: recorder)
            await second.start()
            #expect(shown == (configured ? 1 : 0))
            #expect(await recorder.count == 0)
        }
    }

    /// Saved monthly IDs are deleted even when enabled; an old daily attempt prevents duplicate
    /// reporting on upgrade. A separate monthly marker starts only on the next permitted day.
    @Test func migrationDeletesIdentityAndRespectsTodaysAttempt() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        harness.defaults.set(UUID().uuidString, forKey: DailyTelemetryController.monthlyIDKey)
        harness.defaults.set("2027-01", forKey: DailyTelemetryController.monthKey)
        harness.defaults.set(clock.date, forKey: DailyTelemetryController.attemptKey)
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthlyIDKey) == nil)
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthKey) == nil)
        await controller.start()
        #expect(await recorder.count == 0)
        clock.date += 86_400
        await controller.checkIn()
        #expect(try await recorder.requests.map(eventType) == ["BeepBar.monthlyActive.v2"])
        controller.stop()
    }

    /// Two independent installations share the same wire identifier. Monthly reports are event
    /// counts, not unique-user queries; only each installation's first daily attempt is monthly.
    @Test func separateInstallationsCannotBeDistinguishedByClientUser() async throws {
        let recorder = Recorder()
        for _ in 0..<2 {
            let harness = Harness()
            defer { harness.remove() }
            let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
            let controller = harness.controller(configuration, clock: clock, recorder: recorder)
            await controller.start()
            clock.date += 86_400
            await controller.checkIn()
            controller.stop()
        }
        #expect(try await recorder.requests.map(identity) == ["aggregate", "aggregate", "aggregate", "aggregate"])
        #expect(try await recorder.requests.map(eventType) == ["BeepBar.monthlyActive.v2", "BeepBar.dailyActive.v2", "BeepBar.monthlyActive.v2", "BeepBar.dailyActive.v2"])
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
            #expect(harness.defaults.object(forKey: DailyTelemetryController.monthlyIDKey) == nil)
            #expect(await recorder.count == 0)
        }
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let controller = harness.controller(nil, recorder: recorder)
        await controller.start()
        #expect(harness.callbacks.isEmpty)
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthlyIDKey) == nil)
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
        try #require(requests.count == 2)
        // Re-enabling does not create another monthly count or an individual identifier.
        #expect(try identity(requests[0]) == identity(requests[1]))
        #expect(try eventType(requests[1]) == "BeepBar.dailyActive.v2")
        #expect(harness.defaults.bool(forKey: DailyTelemetryController.enabledKey))
        relaunched.stop()
        let enabledAgain = harness.controller(configuration, clock: clock, recorder: recorder)
        #expect(enabledAgain.isEnabled)
        await enabledAgain.start()
        #expect(await recorder.count == 2)
        enabledAgain.stop()
    }

    /// A failed request consumes the daily attempt and resumes the next day, without retrying on wake.
    @Test func failureDoesNotRetryUntilNextDay() async throws {
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
        #expect(try await recorder.requests.map(eventType) == ["BeepBar.monthlyActive.v2", "BeepBar.dailyActive.v2"])
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

    /// Updates retain the shared identity while reporting the version from the new build.
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
        #expect((signals.first?["payload"] as? [String: String])?["TelemetryDeck.AppInfo.version"] == "1.2.4")
        second.stop()
    }

    /// Monthly counting is local; the same shared identity is used by every daily report.
    /// A rollback cannot count an earlier month again, even if the daily marker is lost.
    @Test func monthlyCountHasNoLinkableIdentity() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let clock = Clock(Date(timeIntervalSince1970: 1_801_310_400))
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        await controller.start()
        clock.date = Date(timeIntervalSince1970: 1_801_439_999)
        await controller.checkIn()
        clock.date += 1
        await controller.checkIn()
        clock.date += 86_400
        await controller.checkIn()
        clock.date = Date(timeIntervalSince1970: 1_801_310_400)
        await controller.checkIn()
        #expect(await recorder.count == 4)
        harness.defaults.removeObject(forKey: DailyTelemetryController.attemptKey)
        await controller.checkIn()
        let requests = await recorder.requests
        #expect(try requests.map(eventType) == ["BeepBar.monthlyActive.v2", "BeepBar.dailyActive.v2", "BeepBar.monthlyActive.v2", "BeepBar.dailyActive.v2", "BeepBar.dailyActive.v2"])
        #expect(try Set(requests.map(identity)) == ["aggregate"])
        #expect(harness.defaults.string(forKey: DailyTelemetryController.countedMonthKey) == "2027-02")
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthlyIDKey) == nil)
        controller.stop()
    }

    /// A clock rollback cannot send again until the next UTC day after the last attempt;
    /// catching up within the saved month retains that month's identifier.
    @Test func clockRollbackWaitsForTheNextDayWithoutRecountingTheMonth() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        // 2027-02-02 00:00 UTC.
        let clock = Clock(Date(timeIntervalSince1970: 1_801_526_400))
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        await controller.start()
        clock.date = Date(timeIntervalSince1970: 1_801_439_999)
        await controller.checkIn()
        clock.date = Date(timeIntervalSince1970: 1_801_612_799)
        await controller.checkIn()
        #expect(await recorder.count == 1)
        clock.date += 1
        await controller.checkIn()
        let ids = try await recorder.requests.map(identity)
        try #require(ids.count == 2)
        #expect(ids[0] == ids[1])
        controller.stop()
    }

    /// The first build's permanent installation UUID is deleted on construction, enabled or not,
    /// and never used as the identifier.
    @Test func legacyInstallationIDIsDeleted() async throws {
        for enabled in [true, false] {
            let harness = Harness()
            defer { harness.remove() }
            harness.defaults.set("A3237D19-A407-407A-A07F-57DEB6688981", forKey: DailyTelemetryController.legacyInstallationKey)
            harness.defaults.set(enabled, forKey: DailyTelemetryController.enabledKey)
            let recorder = Recorder()
            let controller = harness.controller(configuration, recorder: recorder)
            #expect(harness.defaults.object(forKey: DailyTelemetryController.legacyInstallationKey) == nil)
            await controller.start()
            for request in await recorder.requests { #expect(try identity(request) == "aggregate") }
            #expect(await recorder.count == (enabled ? 1 : 0))
            controller.stop()
        }
    }

    /// Turning telemetry off deletes the identifier, also when the opt-out was saved by an older
    /// build that kept it.
    @Test func optOutDeletesTheIdentifier() async {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let controller = harness.controller(configuration, recorder: recorder)
        await controller.start()
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthlyIDKey) == nil)
        #expect(harness.defaults.string(forKey: DailyTelemetryController.countedMonthKey) != nil)
        controller.setEnabled(false)
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthlyIDKey) == nil)
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthKey) == nil)
        harness.defaults.set(UUID().uuidString, forKey: DailyTelemetryController.monthlyIDKey)
        harness.defaults.set("2027-01", forKey: DailyTelemetryController.monthKey)
        _ = harness.controller(configuration, recorder: recorder)
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthlyIDKey) == nil)
        #expect(harness.defaults.object(forKey: DailyTelemetryController.monthKey) == nil)
    }

    /// Settings are read when the signal is sent, not when telemetry starts: a change made today
    /// shows up in tomorrow's signal.
    @Test func contextIsReadAtSendTime() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let recorder = Recorder()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let state = Clock(Date(timeIntervalSince1970: 0))
        let controller = harness.controller(configuration, clock: clock, recorder: recorder)
        let base = context
        await controller.start(context: {
            var current = base
            current.systemMajorVersion = state.date.timeIntervalSince1970 > 0 ? 16 : 15
            return current
        })
        state.date = Date(timeIntervalSince1970: 1)
        clock.date += 86_400
        await controller.checkIn()
        let payloads = try await recorder.requests.map(payload)
        #expect(payloads.map { $0["TelemetryDeck.Device.systemMajorVersion"] } == ["macOS 15", "macOS 16"])
        controller.stop()
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

    /// Opt-out reaches the real URLSession task, rather than only cancelling a mocked sender.
    /// The fixture holds response headers; cancellation must stop it before its normal timeout.
    @Test func optOutStopsTheInFlightTransportAndSurvivesRelaunch() async throws {
        let harness = Harness()
        defer { harness.remove() }
        let id = UUID().uuidString
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [TelemetryProtocol.self]
        TelemetryProtocol.statuses.withLock { $0[id] = 200 }
        defer {
            TelemetryProtocol.statuses.withLock { _ = $0.removeValue(forKey: id) }
            TelemetryProtocol.started.withLock { _ = $0.remove(id) }
            TelemetryProtocol.stopped.withLock { _ = $0.remove(id) }
        }
        let controller = DailyTelemetryController(defaults: harness.defaults, configuration: configuration,
            defaultEnabled: true, disclose: { true }, send: { request in
                var fixture = request
                fixture.url = URL(string: "https://telemetry.invalid/\(id)?stall")!
                try await DailyTelemetryTransport.send(fixture, configuration: session)
            }, schedule: { _, _ in BackgroundActivityRegistration(invalidate: {}) })
        defer { controller.stop() }
        let launch = Task { await controller.start() }
        for _ in 0..<1_000 {
            if TelemetryProtocol.started.withLock({ $0.contains(id) }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(TelemetryProtocol.started.withLock { $0.contains(id) })
        controller.setEnabled(false)
        for _ in 0..<1_000 {
            if TelemetryProtocol.stopped.withLock({ $0.contains(id) }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(TelemetryProtocol.stopped.withLock { $0.contains(id) })
        await launch.value
        #expect(harness.defaults.bool(forKey: DailyTelemetryController.enabledKey) == false)
        let recorder = Recorder()
        let relaunched = harness.controller(configuration, recorder: recorder)
        await relaunched.start()
        #expect(!relaunched.isEnabled)
        #expect(await recorder.count == 0)
        relaunched.stop()
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

    private func payload(_ request: URLRequest) throws -> [String: String] {
        let data = try #require(request.httpBody)
        let signals = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try #require(signals.first?["payload"] as? [String: String])
    }

    private func eventType(_ request: URLRequest) throws -> String {
        let body = try #require(request.httpBody)
        let signals = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        return try #require(signals.first?["type"] as? String)
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
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        let defaults: UserDefaults
        var callbacks: [@Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void] = []
        var intervals: [TimeInterval] = []
        var invalidations = 0
        var disclosure: @MainActor () -> Bool = { true }
        init() { defaults = UserDefaults(suiteName: suite)! }
        func controller(_ configuration: DailyTelemetryConfiguration?, clock: Clock = Clock(Date()), recorder: Recorder) -> DailyTelemetryController {
            DailyTelemetryController(defaults: defaults, configuration: configuration, defaultEnabled: true,
                now: { clock.date }, disclose: { [self] in disclosure() }, send: { try await recorder.send($0) }, schedule: { [self] interval, callback in
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
        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: suite).deletingLastPathComponent())
        }
    }
}
