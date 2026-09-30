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
    /// switch is disabled meanwhile, so no second or opposing call (a quick on-then-off) races the
    /// one in flight. Stale reads are handled by `statusVersion`, see `refresh()`.
    @Published private(set) var isUpdating = false
    let location: AppLocation

    private let service: LoginItemService
    private let defaults: UserDefaults
    /// Bumped by every status write, so a refresh whose read was overtaken by a change (it started
    /// first but answered last) can tell and drop its older value.
    private var statusVersion = 0

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
        setStatus(current)
        let defaultApplied = defaults.bool(forKey: Self.defaultAppliedKey)
        var registered = false
        if LaunchAtLoginPolicy.shouldRegisterOnLaunch(defaultApplied: defaultApplied, status: current, location: location) {
            let service = service
            do {
                try await Task.detached { try service.register() }.value
                registered = true
                BeepbarLog.lifecycle.notice("Registered as login item by default")
            } catch {
                BeepbarLog.lifecycle.error("Default login item registration failed: \(error.localizedDescription, privacy: .public)")
            }
            setStatus(await readStatus())
        }
        if !defaultApplied, LaunchAtLoginPolicy.defaultAppliedAfterLaunch(location: location, registrationSucceeded: registered, statusAfterLaunch: status ?? current) {
            defaults.set(true, forKey: Self.defaultAppliedKey)
        }
    }

    /// The user flipped the switch. Turning it off, or any "on" that didn't fail, counts as
    /// "default applied", so a later launch never registers again behind their back. A failed "on"
    /// doesn't: the user asked for it and it is the default, so the next launch retries.
    func setEnabled(_ enabled: Bool) async {
        guard let current = status, !isUpdating, enabled != LaunchAtLoginPolicy.isOn(current),
              LaunchAtLoginPolicy.canChange(status: current, location: location) else { return }
        isUpdating = true
        defer { isUpdating = false }
        errorMessage = nil
        if !enabled { defaults.set(true, forKey: Self.defaultAppliedKey) }
        if enabled, LaunchAtLoginPolicy.needsSystemSettings(current) {
            defaults.set(true, forKey: Self.defaultAppliedKey)
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
        setStatus(after)
        let failed = LaunchAtLoginPolicy.changeFailed(enabling: enabled, threw: failure != nil, statusAfter: after)
        if enabled, !failed { defaults.set(true, forKey: Self.defaultAppliedKey) }
        if failed {
            BeepbarLog.lifecycle.error("Login item change failed enabled=\(enabled, privacy: .public): \(failure?.localizedDescription ?? "", privacy: .public)")
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
        // A change in flight reads the status itself when it ends. A read that started before a
        // change and answers after it is older than the change's own read: drop it.
        guard !isUpdating else { return }
        let previous = status
        let version = statusVersion
        let now = await readStatus()
        guard version == statusVersion, !isUpdating else { return }
        setStatus(now)
        if previous != now { errorMessage = nil }
    }

    private func setStatus(_ newStatus: LoginItemStatus) {
        status = newStatus
        statusVersion += 1
    }

    private func readStatus() async -> LoginItemStatus {
        let service = service
        return await Task.detached { service.status }.value
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
