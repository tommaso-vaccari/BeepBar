import BeepbarCore
import Foundation
import Testing
import os
@testable import BeepbarApp

/// Stands in for macOS's login-item registry, so these tests never add or remove the developer's
/// real login items. It behaves like `SMAppService.mainApp`: registering enables the item unless
/// the user switched it off in System Settings, in which case it stays held for approval.
private final class FakeLoginItemService: LoginItemService, @unchecked Sendable {
    enum RegisterOutcome { case enable, holdForApproval, fail }
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

    func register() throws {
        state.withLock { $0.registerCalls += 1 }
        registerGate?.wait()
        let outcome = state.withLock { $0.registerOutcome }
        switch outcome {
        case .enable: state.withLock { $0.status = .enabled }
        case .holdForApproval: state.withLock { $0.status = .requiresApproval }
        case .fail: throw CocoaError(.featureUnsupported)
        }
    }

    func unregister() throws {
        let fail = state.withLock { $0.unregisterCalls += 1; return $0.failUnregister }
        if fail { throw CocoaError(.featureUnsupported) }
        state.withLock { $0.status = .notRegistered }
    }

    func openSystemSettings() { state.withLock { $0.settingsOpened += 1 } }
}

/// Exercises the controller end to end against the fake registry and a throwaway defaults suite,
/// launch after launch, the way an installed BeepBar would see them.
@MainActor final class LaunchAtLoginControllerTests {
    private let suiteName = "LaunchAtLoginControllerTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

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

    /// The core promise: after the user turns it off, no later launch turns it back on.
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

    /// Same promise when the user turned it off in System Settings instead of in BeepBar.
    @Test func switchingItOffInSystemSettingsIsRespectedAtRelaunch() async {
        let service = FakeLoginItemService(status: .notRegistered)
        _ = await launch(service)
        service.setStatus(.requiresApproval)

        let relaunched = await launch(service)
        #expect(service.registerCalls == 1)
        #expect(!relaunched.isOn)
        #expect(relaunched.status == .requiresApproval)
    }

    /// Someone who switched BeepBar off in System Settings before this version (e.g. a dev build
    /// registered it) is not overridden by the new default either.
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

    /// A failed default registration is silent (the user did nothing) and retried next launch.
    @Test func failedDefaultRegistrationIsSilentAndRetried() async {
        let service = FakeLoginItemService(status: .notRegistered, registerOutcome: .fail)
        let controller = await launch(service)
        #expect(controller.errorMessage == nil)
        #expect(!controller.isOn)
        #expect(!defaults.bool(forKey: LaunchAtLoginController.defaultAppliedKey))

        let failingAgain = await launch(service)
        #expect(service.registerCalls == 2)
        #expect(!failingAgain.isOn)
    }

    /// A change the user asked for that fails says so under the switch, and the switch falls back
    /// to macOS's real status instead of showing the value that was requested.
    @Test func failedChangesRequestedByTheUserAreShownAndTheSwitchReflectsMacOS() async {
        let failingOn = FakeLoginItemService(status: .notRegistered, registerOutcome: .fail)
        let controller = LaunchAtLoginController(service: failingOn, defaults: defaults, location: .applications)
        await controller.setEnabled(true)
        #expect(controller.errorMessage == BilingualText("Non è stato possibile aggiungere BeepBar agli elementi di login.", "Couldn't add BeepBar to your login items."))
        #expect(!controller.isOn)

        let failingOff = FakeLoginItemService(status: .enabled, failUnregister: true)
        let other = LaunchAtLoginController(service: failingOff, defaults: defaults, location: .applications)
        await other.setEnabled(false)
        #expect(other.errorMessage == BilingualText("Non è stato possibile rimuovere BeepBar dagli elementi di login.", "Couldn't remove BeepBar from your login items."))
        #expect(other.isOn)

    }

    /// A later success clears the previous error.
    @Test func aSuccessfulChangeClearsThePreviousError() async {
        let service = FakeLoginItemService(status: .notRegistered, registerOutcome: .fail)
        let controller = LaunchAtLoginController(service: service, defaults: defaults, location: .applications)
        await controller.setEnabled(true)
        #expect(controller.errorMessage != nil)
        let recovered = FakeLoginItemService(status: .enabled)
        let again = LaunchAtLoginController(service: recovered, defaults: defaults, location: .applications)
        await again.setEnabled(false)
        #expect(again.errorMessage == nil)
        #expect(!again.isOn)
    }

    /// Turning it on while macOS holds it for approval can only be finished in System Settings,
    /// so BeepBar opens Login Items there; a normal "on" does not.
    @Test func turningOnAnItemHeldForApprovalOpensSystemSettings() async {
        let held = FakeLoginItemService(status: .requiresApproval, registerOutcome: .holdForApproval)
        let controller = LaunchAtLoginController(service: held, defaults: defaults, location: .applications)
        await controller.setEnabled(true)
        #expect(held.settingsOpened == 1)
        #expect(!controller.isOn)

        let normal = FakeLoginItemService(status: .notRegistered)
        let other = LaunchAtLoginController(service: normal, defaults: defaults, location: .applications)
        await other.setEnabled(true)
        #expect(normal.settingsOpened == 0)
        #expect(other.isOn)
    }

    /// A user's own choice counts as the default being applied, even before any launch applied it.
    @Test func theUsersOwnChoiceUsesUpTheDefault() async {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LaunchAtLoginController(service: service, defaults: defaults, location: .applications)
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
        let controller = LaunchAtLoginController(service: service, defaults: defaults, location: .applications)
        let first = Task { await controller.setEnabled(true) }
        let deadline = Date().addingTimeInterval(5)
        while service.registerCalls == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(service.registerCalls == 1)
        #expect(controller.isUpdating)
        #expect(!controller.canChange)

        let second = Task { await controller.setEnabled(true) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(service.registerCalls == 1, "the second tap must not start another registration")
        #expect(service.unregisterCalls == 0)

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

    /// The switch follows changes made in System Settings while BeepBar runs, once it re-reads.
    @Test func refreshPicksUpChangesMadeInSystemSettings() async {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LaunchAtLoginController(service: service, defaults: defaults, location: .applications)
        #expect(controller.isOn)
        service.setStatus(.requiresApproval)
        await controller.refresh()
        #expect(!controller.isOn)
        #expect(controller.status == .requiresApproval)
    }
}
