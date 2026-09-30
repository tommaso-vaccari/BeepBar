import AppKit
import BeepbarCore
import ServiceManagement
import os

/// The part of macOS's login-item registry BeepBar uses. `MainAppLoginItemService` in the app;
/// tests use a fake so they never add or remove the developer's real login items.
protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// BeepBar itself as a login item, through `SMAppService.mainApp` (macOS 13+). Stateless, so the
/// blocking XPC calls behind it can run off the main actor.
struct MainAppLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// A login-item registry that only lives in memory, for `--ui-preview` runs: a preview build
/// shares the installed app's bundle identifier, so touching the real registry would change what
/// the installed BeepBar does at login.
final class InMemoryLoginItemService: LoginItemService, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: LoginItemStatus.notRegistered)
    var status: LoginItemStatus { lock.withLock { $0 } }
    func register() throws { lock.withLock { $0 = .enabled } }
    func unregister() throws { lock.withLock { $0 = .notRegistered } }
    func openSystemSettings() {}
}

/// Drives the "Apri BeepBar al login" switch in Settings and the one-time default at launch.
/// Every decision lives in `LaunchAtLoginPolicy`; this class only calls macOS and publishes the
/// result. macOS's status is re-read after every change and whenever Settings is shown, because
/// the user can also change it in System Settings while BeepBar is running.
@MainActor final class LaunchAtLoginController: ObservableObject {
    static let shared: LaunchAtLoginController = {
        if PreviewMode.isActive {
            // Throwaway suite: the preview must not mark the default as applied for the real install.
            let defaults = UserDefaults(suiteName: "io.github.tvaccari.beepbar.preview.login") ?? UserDefaults()
            defaults.removeObject(forKey: defaultAppliedKey)
            return LaunchAtLoginController(service: InMemoryLoginItemService(), defaults: defaults, location: .applications)
        }
        return LaunchAtLoginController(
            service: MainAppLoginItemService(),
            defaults: .standard,
            location: AppLocation.classify(bundlePath: Bundle.main.bundleURL.path, homeDirectory: NSHomeDirectory())
        )
    }()

    /// Set once the on-by-default registration has been applied, or once the user flipped the
    /// switch themselves. Its absence is what makes the default apply, so it must never be reset.
    nonisolated static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    /// macOS's status, `nil` until it has been read off the main actor: the read is a blocking XPC
    /// call and the first one happens at launch, where the main thread must stay free.
    @Published private(set) var status: LoginItemStatus?
    /// Shown under the switch after a change the user asked for failed. Launch failures stay silent:
    /// the user did nothing, and the next launch retries.
    @Published private(set) var errorMessage: BilingualText?
    /// True while BeepBar is registering or unregistering, including the default at launch. The
    /// switch is disabled meanwhile, so a tap cannot race a call already in flight (a second
    /// `register()` would fail with `kSMErrorAlreadyRegistered` and show a false error).
    @Published private(set) var isUpdating = false
    let location: AppLocation

    private let service: LoginItemService
    private let defaults: UserDefaults

    init(service: LoginItemService, defaults: UserDefaults, location: AppLocation) {
        self.service = service
        self.defaults = defaults
        self.location = location
    }

    var isOn: Bool { status.map(LaunchAtLoginPolicy.isOn) ?? false }
    var canChange: Bool {
        guard let status, !isUpdating else { return false }
        return LaunchAtLoginPolicy.canChange(status: status, location: location)
    }

    /// Applies the on-by-default setting once. Called at every launch; it registers only on the
    /// first launch from Applications, and never after the user turned it off.
    func applyDefaultOnLaunch() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        let current = await readStatus()
        status = current
        guard !defaults.bool(forKey: Self.defaultAppliedKey) else { return }
        var registered = false
        if LaunchAtLoginPolicy.shouldRegisterOnLaunch(defaultApplied: false, status: current, location: location) {
            let service = service
            do {
                try await Task.detached { try service.register() }.value
                registered = true
                BeepbarLog.lifecycle.notice("Registered as login item by default")
            } catch {
                BeepbarLog.lifecycle.error("Default login item registration failed: \(error.localizedDescription, privacy: .public)")
            }
            status = await readStatus()
        }
        if LaunchAtLoginPolicy.defaultAppliedAfterLaunch(location: location, registrationSucceeded: registered, statusAfterLaunch: status ?? current) {
            defaults.set(true, forKey: Self.defaultAppliedKey)
        }
    }

    /// The user flipped the switch. Their choice always counts as "default applied", so a later
    /// launch never registers again behind their back.
    func setEnabled(_ enabled: Bool) async {
        guard let current = status, !isUpdating, enabled != LaunchAtLoginPolicy.isOn(current),
              LaunchAtLoginPolicy.canChange(status: current, location: location) else { return }
        isUpdating = true
        defer { isUpdating = false }
        errorMessage = nil
        defaults.set(true, forKey: Self.defaultAppliedKey)
        if enabled, LaunchAtLoginPolicy.needsSystemSettings(current) {
            service.openSystemSettings()
            return
        }
        let service = service
        var failure: Error?
        do {
            try await Task.detached { enabled ? try service.register() : try service.unregister() }.value
        } catch {
            failure = error
        }
        let after = await readStatus()
        status = after
        if LaunchAtLoginPolicy.changeFailed(enabling: enabled, statusAfter: after) {
            BeepbarLog.lifecycle.error("Login item change failed enabled=\(enabled, privacy: .public): \(failure?.localizedDescription ?? "no error, status unchanged", privacy: .public)")
            errorMessage = enabled
                ? BilingualText("Non è stato possibile aggiungere BeepBar agli elementi di login.", "Couldn't add BeepBar to your login items.")
                : BilingualText("Non è stato possibile rimuovere BeepBar dagli elementi di login.", "Couldn't remove BeepBar from your login items.")
        } else if enabled, LaunchAtLoginPolicy.needsSystemSettings(after) {
            service.openSystemSettings()
        }
    }

    /// Re-reads macOS's status, e.g. after the user changed it in System Settings. A status that
    /// moved on also retires an earlier error, which described a state that no longer holds.
    func refresh() async {
        let previous = status
        let now = await readStatus()
        status = now
        if previous != now { errorMessage = nil }
    }

    private func readStatus() async -> LoginItemStatus {
        let service = service
        return await Task.detached { service.status }.value
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
