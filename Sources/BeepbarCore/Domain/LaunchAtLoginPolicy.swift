import Foundation

/// macOS's view of BeepBar as a login item, mirrored from `SMAppService.Status` so the decisions
/// below can be tested without touching the real login-item registry.
public enum LoginItemStatus: Sendable, Equatable {
    /// Opens at login.
    case enabled
    /// Registered, but switched off in System Settings → General → Login Items (or never
    /// approved there). Only the user can turn it back on, from System Settings.
    case requiresApproval
    /// Not a login item.
    case notRegistered
    /// macOS could not find BeepBar's registration; treated like `notRegistered`.
    case notFound
}

/// Where the running copy of BeepBar lives, which decides whether it may register itself.
public enum AppLocation: Sendable, Equatable {
    /// `/Applications` or `~/Applications`: a stable path that login can reopen.
    case applications
    /// Launched from quarantine by Gatekeeper's App Translocation: a random read-only path that
    /// disappears, so registering it would leave a login item pointing nowhere.
    case translocated
    /// Anywhere else (Downloads, the mounted DMG, a build folder): the copy is likely to be moved
    /// or deleted, and the login item would open a stale copy or nothing.
    case elsewhere

    /// Classifies a bundle path. `homeDirectory` is passed in so tests don't depend on the user.
    public static func classify(bundlePath: String, homeDirectory: String) -> AppLocation {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        for folder in ["/Applications/", home + "/Applications/"] where bundlePath.hasPrefix(folder) {
            return .applications
        }
        return .elsewhere
    }
}

/// Decisions behind "Apri BeepBar al login": on by default for everyone, applied once, and never
/// forced back on after the user turned it off, either from BeepBar's switch or from System
/// Settings. macOS's own status is the source of truth for what the switch shows.
public enum LaunchAtLoginPolicy {
    /// Whether this launch should register BeepBar as a login item. Only the first launch from a
    /// stable location does: `defaultApplied` is recorded once the default has been applied (or
    /// the user chose for themselves), so a user who later turns it off is never overridden.
    public static func shouldRegisterOnLaunch(defaultApplied: Bool, status: LoginItemStatus, location: AppLocation) -> Bool {
        guard !defaultApplied, location == .applications else { return false }
        return status == .notRegistered || status == .notFound
    }

    /// Whether the default counts as applied after this launch. A launch from outside Applications
    /// doesn't count, so the copy the user later moves there still gets the default. A failed
    /// registration doesn't count either, so it is retried at the next launch.
    public static func defaultAppliedAfterLaunch(location: AppLocation, statusAfterLaunch: LoginItemStatus) -> Bool {
        guard location == .applications else { return false }
        return statusAfterLaunch != .notRegistered && statusAfterLaunch != .notFound
    }

    /// What the switch shows: on only when macOS will actually open BeepBar at login.
    public static func isOn(_ status: LoginItemStatus) -> Bool {
        status == .enabled
    }

    /// The switch can always turn an enabled item off; turning it on needs a stable location.
    public static func canChange(status: LoginItemStatus, location: AppLocation) -> Bool {
        status == .enabled || location == .applications
    }

    /// After the user asks to turn it on, macOS may still hold it for approval (the user switched it
    /// off in System Settings before): only System Settings can turn it back on, so open it there.
    public static func needsSystemSettings(afterEnablingStatus status: LoginItemStatus) -> Bool {
        status == .requiresApproval
    }
}
