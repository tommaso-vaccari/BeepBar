@testable import BeepbarCore
import Foundation
import Testing
import os
@testable import BeepbarApp

/// Stands in for macOS's notification center and records everything that reaches it, so tests
/// can prove what a user would see, and that nothing reaches it when notifications are off.
private final class FakeNotificationCenter: NotificationCenterClient, @unchecked Sendable {
    struct Sent: Equatable { let identifier: String; let title: String; let destination: NotificationDestination }
    private struct State {
        var authorization: NotificationAuthorization
        var authorizationAfterRequest: NotificationAuthorization
        var sent: [Sent] = []
        var requests = 0
        var authorizationReads = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(authorization: NotificationAuthorization = .allowed, afterRequest: NotificationAuthorization = .allowed) {
        state = OSAllocatedUnfairLock(initialState: State(authorization: authorization, authorizationAfterRequest: afterRequest))
    }

    var sent: [Sent] { state.withLock { $0.sent } }
    var requests: Int { state.withLock { $0.requests } }
    /// Every contact with macOS: permission reads, requests and sends.
    var contacts: Int { state.withLock { $0.authorizationReads + $0.requests + $0.sent.count } }
    func setAuthorization(_ value: NotificationAuthorization) { state.withLock { $0.authorization = value } }

    func authorization() async -> NotificationAuthorization { state.withLock { $0.authorizationReads += 1; return $0.authorization } }
    func requestAuthorization() async { state.withLock { $0.requests += 1; $0.authorization = $0.authorizationAfterRequest } }
    func send(identifier: String, title: String, body: String, destination: NotificationDestination) async {
        state.withLock { $0.sent.append(Sent(identifier: identifier, title: title, destination: destination)) }
    }
}

/// The coordinator against the fake center and a throwaway defaults suite (#64).
@MainActor final class SyncNotificationCoordinatorTests {
    private let suiteName = "SyncNotificationCoordinatorTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: suiteName)! }
    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    private func conflict(_ remoteID: String) throws -> ConflictRecord {
        ConflictRecord(id: UUID(), rootID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, remoteID: remoteID,
            relativePath: try RelativePath("Course/\(remoteID).pdf"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/\(remoteID).pdf"),
            baseSHA256: "base", localSHA256: "local", remoteSHA256: "remote", remoteRevision: "2", detectedAt: .now, status: .open)
    }

    private func turnOff() { defaults.set(false, forKey: NotificationPolicy.enabledKey) }
    private func turnOn() { defaults.set(true, forKey: NotificationPolicy.enabledKey) }

    /// With the switch never touched (every existing user), notifications keep working, and each
    /// kind carries the page a click should open.
    @Test func onByDefaultEachNotificationCarriesItsPage() async throws {
        let center = FakeNotificationCenter()
        let coordinator = SyncNotificationCoordinator(defaults: defaults, center: center)
        await coordinator.notifyAutomaticRun(installed: 2, conflicts: [try conflict("a")], failures: 0)
        await coordinator.notifyManualRun(added: 1)
        await coordinator.notify(issue: .authenticationExpired)
        #expect(center.sent.map(\.destination) == [.conflicts, .activity, .activity, .home])
        #expect(center.sent.first?.identifier == "beepbar-conflicts")
        #expect(center.sent.last?.identifier == "beepbar-authenticationExpired")
    }

    /// The core promise of the switch: with it off, no path reaches macOS at all, not even a
    /// permission read or prompt.
    @Test func withTheSwitchOffNothingReachesMacOS() async throws {
        turnOff()
        let center = FakeNotificationCenter(authorization: .notDetermined)
        let coordinator = SyncNotificationCoordinator(defaults: defaults, center: center)
        await coordinator.requestAuthorizationIfNeeded()
        await coordinator.notifyAutomaticRun(installed: 3, conflicts: [try conflict("a")], failures: 0)
        await coordinator.notifyAutomaticRun(installed: 0, conflicts: [], failures: 2)
        await coordinator.notifyManualRun(added: 4)
        for issue in [AutomaticNotificationIssue.authenticationExpired, .serviceUnavailable, .incompatibleResponse, .partialSync] {
            await coordinator.notify(issue: issue)
        }
        #expect(center.contacts == 0)
    }

    /// A conflict that arose while notifications were off is not recorded as already notified:
    /// once they are back on, the next run still announces it.
    @Test func aConflictFromWhileOffIsAnnouncedOnceBackOn() async throws {
        let center = FakeNotificationCenter()
        let coordinator = SyncNotificationCoordinator(defaults: defaults, center: center)
        let open = [try conflict("a")]
        turnOff()
        await coordinator.notifyAutomaticRun(installed: 0, conflicts: open, failures: 0)
        #expect(center.sent.isEmpty)

        turnOn()
        await coordinator.notifyAutomaticRun(installed: 0, conflicts: open, failures: 0)
        #expect(center.sent.map(\.identifier) == ["beepbar-conflicts"])

        await coordinator.notifyAutomaticRun(installed: 0, conflicts: open, failures: 0)
        #expect(center.sent.count == 1, "deduplication still applies once notified")
    }

    /// Same for an account or sync problem that started while notifications were off.
    @Test func anIssueFromWhileOffIsAnnouncedOnceBackOn() async {
        let center = FakeNotificationCenter()
        let coordinator = SyncNotificationCoordinator(defaults: defaults, center: center)
        turnOff()
        await coordinator.notify(issue: .serviceUnavailable)
        turnOn()
        await coordinator.notify(issue: .serviceUnavailable)
        #expect(center.sent.map(\.identifier) == ["beepbar-serviceUnavailable"])
    }

    /// Permission is asked only while on and never asked before.
    @Test func permissionIsRequestedOnlyWhenOnAndNeverAsked() async {
        let never = FakeNotificationCenter(authorization: .notDetermined)
        await SyncNotificationCoordinator(defaults: defaults, center: never).requestAuthorizationIfNeeded()
        #expect(never.requests == 1)

        let denied = FakeNotificationCenter(authorization: .denied)
        await SyncNotificationCoordinator(defaults: defaults, center: denied).requestAuthorizationIfNeeded()
        #expect(denied.requests == 0)
    }

    /// Without macOS's permission nothing is sent, and nothing is recorded as notified, so the
    /// conflict is announced once the user allows notifications in System Settings.
    @Test func withoutMacOSPermissionNothingIsSentOrRecorded() async throws {
        let center = FakeNotificationCenter(authorization: .denied)
        let coordinator = SyncNotificationCoordinator(defaults: defaults, center: center)
        let open = [try conflict("a")]
        await coordinator.notifyAutomaticRun(installed: 1, conflicts: open, failures: 0)
        #expect(center.sent.isEmpty)
        center.setAuthorization(.allowed)
        await coordinator.notifyAutomaticRun(installed: 0, conflicts: open, failures: 0)
        #expect(center.sent.map(\.destination) == [.conflicts])
    }
}

/// The switch as the Settings page drives it, through the controller (#64).
@MainActor struct NotificationSwitchTests {
    private func controller(_ center: FakeNotificationCenter) -> WeBeepAuthenticationController {
        WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory, notificationCenter: center)
    }

    /// On for an install that never touched it; turning it off is stored and stops notifications.
    @Test func turningItOffStopsNotificationsAndIsRemembered() async {
        let center = FakeNotificationCenter()
        let controller = controller(center)
        #expect(controller.notificationsEnabled)
        await controller.setNotifications(enabled: false)
        #expect(!controller.notificationsEnabled)
        await controller.notifyManualRunForTesting(added: 2)
        #expect(center.sent.isEmpty)
        await controller.setNotifications(enabled: true)
        await controller.notifyManualRunForTesting(added: 2)
        #expect(center.sent.map(\.destination) == [.activity])
    }

    /// Turning it back on asks macOS for permission if it never asked, and shows macOS's answer.
    @Test func turningItOnAsksMacOSOnceAndShowsItsAnswer() async {
        let center = FakeNotificationCenter(authorization: .notDetermined, afterRequest: .denied)
        let controller = controller(center)
        await controller.setNotifications(enabled: false)
        #expect(center.requests == 0)
        await controller.setNotifications(enabled: true)
        #expect(center.requests == 1)
        #expect(controller.notificationAuthorization == .denied)
        await controller.setNotifications(enabled: true)
        #expect(center.requests == 1, "macOS already answered; it is not asked again")
    }

    /// The Settings footer follows a permission changed in System Settings once it re-reads.
    @Test func refreshPicksUpPermissionChangedInSystemSettings() async {
        let center = FakeNotificationCenter(authorization: .denied)
        let controller = controller(center)
        await controller.refreshNotificationAuthorization()
        #expect(controller.notificationAuthorization == .denied)
        center.setAuthorization(.allowed)
        await controller.refreshNotificationAuthorization()
        #expect(controller.notificationAuthorization == .allowed)
    }
}
