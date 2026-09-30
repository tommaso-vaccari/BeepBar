import BeepbarCore
import Foundation
import Testing
import os
@testable import BeepbarApp

/// Stands in for macOS's login-item registry, so these tests never add or remove the developer's
/// real login items. It follows the rules `SMAppService.h` documents for `mainApp`:
/// - `register()` fails while the user holds the item for approval (`kSMErrorLaunchDeniedByUser`)
///   and when it is already registered (`kSMErrorAlreadyRegistered`), leaving the status as is;
/// - `unregister()` fails when there is nothing to remove (`kSMErrorJobNotFound`).
/// Tests can additionally force failures, or make macOS ask for approval of a new registration.
private final class FakeLoginItemService: LoginItemService, @unchecked Sendable {
    enum RegisterOutcome { case enable, requireApproval, fail }
    private struct State {
        var status: LoginItemStatus
        var registerOutcome = RegisterOutcome.enable
        var failUnregister = false
        var registerCalls = 0
        var unregisterCalls = 0
        var settingsOpened = 0
    }
    private let state: OSAllocatedUnfairLock<State>
    /// When set, `register()` waits on it: lets a test hold a change in flight.
    let registerGate: DispatchSemaphore?

    init(status: LoginItemStatus, registerOutcome: RegisterOutcome = .enable, failUnregister: Bool = false, registerGate: DispatchSemaphore? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(status: status, registerOutcome: registerOutcome, failUnregister: failUnregister))
        self.registerGate = registerGate
    }

    var status: LoginItemStatus { state.withLock { $0.status } }
    var registerCalls: Int { state.withLock { $0.registerCalls } }
    var unregisterCalls: Int { state.withLock { $0.unregisterCalls } }
    var settingsOpened: Int { state.withLock { $0.settingsOpened } }
    func setStatus(_ status: LoginItemStatus) { state.withLock { $0.status = status } }
    func setRegisterOutcome(_ outcome: RegisterOutcome) { state.withLock { $0.registerOutcome = outcome } }

    func register() throws {
        state.withLock { $0.registerCalls += 1 }
        registerGate?.wait()
        let (status, outcome) = state.withLock { ($0.status, $0.registerOutcome) }
        if status == .requiresApproval || status == .enabled { throw CocoaError(.featureUnsupported) }
        switch outcome {
        case .enable: state.withLock { $0.status = .enabled }
        case .requireApproval: state.withLock { $0.status = .requiresApproval }
        case .fail: throw CocoaError(.featureUnsupported)
        }
    }

    func unregister() throws {
        let (status, fail) = state.withLock { $0.unregisterCalls += 1; return ($0.status, $0.failUnregister) }
        if fail || status == .notRegistered || status == .notFound { throw CocoaError(.featureUnsupported) }
        state.withLock { $0.status = .notRegistered }
    }

    func openSystemSettings() { state.withLock { $0.settingsOpened += 1 } }
}

/// Exercises the controller end to end against the fake registry and a throwaway defaults suite,
/// launch after launch, the way an installed BeepBar would see them.
@MainActor final class LaunchAtLoginControllerTests {
    private let suiteName = "LaunchAtLoginControllerTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let couldNotAdd = BilingualText("Non è stato possibile aggiungere BeepBar agli elementi di login.", "Couldn't add BeepBar to your login items.")
    private let couldNotRemove = BilingualText("Non è stato possibile rimuovere BeepBar dagli elementi di login.", "Couldn't remove BeepBar from your login items.")

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func launch(_ service: FakeLoginItemService, from location: AppLocation = .applications) async -> LaunchAtLoginController {
        let controller = LaunchAtLoginController(service: service, defaults: defaults, location: location)
        await controller.applyDefaultOnLaunch()
        return controller
    }

    /// Settings shows a controller that has only read macOS's status, as a later window would.
    private func settings(_ service: FakeLoginItemService, at location: AppLocation = .applications) async -> LaunchAtLoginController {
        let controller = LaunchAtLoginController(service: service, defaults: defaults, location: location)
        await controller.refresh()
        return controller
    }

    /// The status is read off the main actor, never in `init`: until it arrives the switch reads
    /// off and cannot be flipped, so no change is based on a status nobody read.
    @Test func noStatusIsReadUntilAskedAndTheSwitchWaitsForIt() async {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LaunchAtLoginController(service: service, defaults: defaults, location: .applications)
        #expect(controller.status == nil)
        #expect(!controller.isOn)
        #expect(!controller.canChange)
        await controller.setEnabled(false)
        #expect(service.unregisterCalls == 0)
        await controller.refresh()
        #expect(controller.isOn)
        #expect(controller.canChange)
    }

    /// A new install and an existing user updating both start with no flag: the first launch from
    /// Applications turns it on, and the switch shows it.
    @Test func firstLaunchFromApplicationsTurnsItOn() async {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = await launch(service)
        #expect(service.registerCalls == 1)
        #expect(controller.isOn)
        #expect(defaults.bool(forKey: LaunchAtLoginController.defaultAppliedKey))
        #expect(controller.errorMessage == nil)
    }

    /// The core promise: after the user turns it off in BeepBar, no later launch turns it back on.
    @Test func turningItOffIsNeverOverriddenByALaterLaunch() async {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = await launch(service)
        await controller.setEnabled(false)
        #expect(service.unregisterCalls == 1)
        #expect(!controller.isOn)

        let relaunched = await launch(service)
        #expect(service.registerCalls == 1, "the relaunch must not register again")
        #expect(!relaunched.isOn)
    }

    /// Same promise for every way macOS can report that the user took it away in System Settings:
    /// removed from the list, not found, or approval revoked.
    @Test(arguments: [LoginItemStatus.notRegistered, .notFound, .requiresApproval])
    func turningItOffInSystemSettingsIsRespectedAtRelaunch(status: LoginItemStatus) async {
        let service = FakeLoginItemService(status: .notRegistered)
        _ = await launch(service)
        service.setStatus(status)

        let relaunched = await launch(service)
        #expect(service.registerCalls == 1, "the relaunch must not register again")
        #expect(!relaunched.isOn)
        #expect(relaunched.status == status)
    }

    /// Someone whose approval was already revoked before this version (e.g. a dev build registered
    /// it) is not overridden by the new default either.
    @Test func anItemAlreadyHeldForApprovalIsNotRegisteredByTheDefault() async {
        let service = FakeLoginItemService(status: .requiresApproval)
        let controller = await launch(service)
        #expect(service.registerCalls == 0)
        #expect(!controller.isOn)
        #expect(defaults.bool(forKey: LaunchAtLoginController.defaultAppliedKey))
    }

    /// Running from Downloads, the DMG or a translocated path registers nothing, and the copy the
    /// user then moves to Applications still gets the default at its first launch.
    @Test(arguments: [AppLocation.elsewhere, .translocated])
    func unstableLocationsWaitForTheCopyInApplications(location: AppLocation) async {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = await launch(service, from: location)
        #expect(service.registerCalls == 0)
        #expect(!controller.canChange, "the switch cannot turn it on from here")
        #expect(!defaults.bool(forKey: LaunchAtLoginController.defaultAppliedKey))

        await controller.setEnabled(true)
        #expect(service.registerCalls == 0, "the switch must not register an unstable path either")

        let moved = await launch(service, from: .applications)
        #expect(service.registerCalls == 1)
        #expect(moved.isOn)
    }

    /// An enabled item can always be turned off, even from a copy outside Applications.
    @Test(arguments: [AppLocation.elsewhere, .translocated])
    func anEnabledItemCanBeTurnedOffFromAnyLocation(location: AppLocation) async {
        let service = FakeLoginItemService(status: .enabled)
        let controller = await settings(service, at: location)
        #expect(controller.canChange)
        await controller.setEnabled(false)
        #expect(service.unregisterCalls == 1)
        #expect(!controller.isOn)
        #expect(controller.errorMessage == nil)
    }

    /// A failed default registration is silent (the user did nothing) and retried next launch.
    @Test func failedDefaultRegistrationIsSilentAndRetried() async {
        let service = FakeLoginItemService(status: .notRegistered, registerOutcome: .fail)
        let controller = await launch(service)
        #expect(controller.errorMessage == nil)
        #expect(!controller.isOn)
        #expect(!defaults.bool(forKey: LaunchAtLoginController.defaultAppliedKey))

        service.setRegisterOutcome(.enable)
        let retried = await launch(service)
        #expect(service.registerCalls == 2)
        #expect(retried.isOn)
    }

    /// A change the user asked for that fails says so under the switch, and the switch falls back
    /// to macOS's real status instead of showing the value that was requested.
    @Test func failedChangesRequestedByTheUserAreShownAndTheSwitchReflectsMacOS() async {
        let failingOn = FakeLoginItemService(status: .notRegistered, registerOutcome: .fail)
        let controller = await settings(failingOn)
        await controller.setEnabled(true)
        #expect(controller.errorMessage == couldNotAdd)
        #expect(!controller.isOn)

        let failingOff = FakeLoginItemService(status: .enabled, failUnregister: true)
        let other = await settings(failingOff)
        await other.setEnabled(false)
        #expect(other.errorMessage == couldNotRemove)
        #expect(other.isOn)
    }

    /// On the same switch, a later successful change clears the earlier error.
    @Test func aSuccessfulRetryClearsThePreviousError() async {
        let service = FakeLoginItemService(status: .notRegistered, registerOutcome: .fail)
        let controller = await settings(service)
        await controller.setEnabled(true)
        #expect(controller.errorMessage == couldNotAdd)

        service.setRegisterOutcome(.enable)
        await controller.setEnabled(true)
        #expect(controller.errorMessage == nil)
        #expect(controller.isOn)
    }

    /// An error stops being shown once macOS's status moves on, e.g. the user removed BeepBar in
    /// System Settings after "remove" failed in BeepBar; a refresh with no change keeps it.
    @Test func anErrorIsRetiredWhenMacOSStatusMovesOn() async {
        let service = FakeLoginItemService(status: .enabled, failUnregister: true)
        let controller = await settings(service)
        await controller.setEnabled(false)
        #expect(controller.errorMessage == couldNotRemove)

        await controller.refresh()
        #expect(controller.errorMessage == couldNotRemove, "nothing changed, the error still applies")

        service.setStatus(.notRegistered)
        await controller.refresh()
        #expect(controller.errorMessage == nil)
        #expect(!controller.isOn)
    }

    /// Turning it on while approval is revoked can only be finished in System Settings: BeepBar
    /// opens Login Items there, does not call `register()` (which would fail) and shows no error.
    @Test func turningOnAnItemHeldForApprovalOpensSystemSettingsWithoutAnError() async {
        let service = FakeLoginItemService(status: .requiresApproval)
        let controller = await settings(service)
        #expect(controller.canChange)
        await controller.setEnabled(true)
        #expect(service.registerCalls == 0)
        #expect(service.settingsOpened == 1)
        #expect(controller.errorMessage == nil)
        #expect(!controller.isOn)
    }

    /// If macOS asks for approval of a fresh registration, BeepBar sends the user there too,
    /// without calling it a failure; a normal "on" opens nothing.
    @Test func aRegistrationMacOSHoldsForApprovalOpensSystemSettings() async {
        let held = FakeLoginItemService(status: .notRegistered, registerOutcome: .requireApproval)
        let controller = await settings(held)
        await controller.setEnabled(true)
        #expect(held.registerCalls == 1)
        #expect(held.settingsOpened == 1)
        #expect(controller.errorMessage == nil)

        let normal = FakeLoginItemService(status: .notRegistered)
        let other = await settings(normal)
        await other.setEnabled(true)
        #expect(normal.settingsOpened == 0)
        #expect(other.isOn)
    }

    /// macOS throws for a change that is already done (here: registered from System Settings
    /// while the switch still read off). Judged by the resulting status, that is not a failure.
    @Test func aNoOpThatMacOSReportsAsAnErrorIsNotShownAsAFailure() async {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = await settings(service)
        #expect(!controller.isOn)
        service.setStatus(.enabled)
        await controller.setEnabled(true)
        #expect(service.registerCalls == 1)
        #expect(controller.errorMessage == nil)
        #expect(controller.isOn)
    }

    /// A user's own choice counts as the default being applied, even before any launch applied it.
    @Test func theUsersOwnChoiceUsesUpTheDefault() async {
        let service = FakeLoginItemService(status: .enabled)
        let controller = await settings(service)
        await controller.setEnabled(false)
        #expect(defaults.bool(forKey: LaunchAtLoginController.defaultAppliedKey))
        _ = await launch(service)
        #expect(service.registerCalls == 0)
    }

    /// While a change is in flight the switch is disabled and a second tap is ignored. The switch
    /// still shows the old value until macOS answers, so the second tap asks for the same change
    /// again: without the guard it would register twice, racing the first call.
    @Test func aSecondTapWhileAChangeIsInFlightIsIgnored() async {
        let gate = DispatchSemaphore(value: 0)
        let service = FakeLoginItemService(status: .notRegistered, registerGate: gate)
        let controller = await settings(service)
        let first = Task { await controller.setEnabled(true) }
        await waitUntil { service.registerCalls > 0 }
        #expect(controller.isUpdating)
        #expect(!controller.canChange)

        let second = Task { await controller.setEnabled(true) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(service.registerCalls == 1, "the second tap must not start another registration")

        // Two signals so that a regression (a second, blocked register call) fails instead of hanging.
        gate.signal()
        gate.signal()
        await first.value
        await second.value
        #expect(service.registerCalls == 1)
        #expect(controller.isOn)
        #expect(!controller.isUpdating)
        #expect(controller.canChange)
    }

    /// The default registration at launch also locks the switch: a tap while it runs would
    /// otherwise hit `kSMErrorAlreadyRegistered` and show a false "couldn't add" error.
    @Test func theDefaultRegistrationAtLaunchLocksTheSwitch() async {
        let gate = DispatchSemaphore(value: 0)
        let service = FakeLoginItemService(status: .notRegistered, registerGate: gate)
        let controller = LaunchAtLoginController(service: service, defaults: defaults, location: .applications)
        let launching = Task { await controller.applyDefaultOnLaunch() }
        await waitUntil { service.registerCalls > 0 }
        #expect(controller.isUpdating)
        #expect(!controller.canChange)

        let tap = Task { await controller.setEnabled(true) }
        try? await Task.sleep(for: .milliseconds(50))
        gate.signal()
        gate.signal()
        await launching.value
        await tap.value
        #expect(service.registerCalls == 1)
        #expect(controller.errorMessage == nil)
        #expect(controller.isOn)
    }

    /// The switch follows changes made in System Settings while BeepBar runs, once it re-reads.
    @Test func refreshPicksUpChangesMadeInSystemSettings() async {
        let service = FakeLoginItemService(status: .enabled)
        let controller = await settings(service)
        #expect(controller.isOn)
        service.setStatus(.requiresApproval)
        await controller.refresh()
        #expect(!controller.isOn)
        #expect(controller.status == .requiresApproval)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(condition(), "timed out waiting for the fake registry")
    }
}
