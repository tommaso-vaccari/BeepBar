import Foundation

/// macOS's view of BeepBar as a login item, mirrored from `SMAppService.Status` so the decisions
/// below can be tested without touching the real login-item registry.
public enum LoginItemStatus: Sendable, Equatable {
    /// Opens at login.
    case enabled
    /// Registered, but the user revoked its approval in System Settings → General → Login Items.
    /// Only the user can turn it back on there: `register()` fails with
    /// `kSMErrorLaunchDeniedByUser` in this state (see `SMAppService.h`).
    case requiresApproval
    /// Not a login item, including after the user removed BeepBar from the Login Items list.
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
    /// doesn't count, so the copy the user later moves there still gets the default. A registration
    /// that returned without error counts even if the status read right after it lags behind:
    /// otherwise a user who later removes BeepBar from Login Items would get it re-added. A failed
    /// registration that left no login item doesn't count, so it is retried at the next launch.
    public static func defaultAppliedAfterLaunch(location: AppLocation, registrationSucceeded: Bool, statusAfterLaunch: LoginItemStatus) -> Bool {
        guard location == .applications else { return false }
        return registrationSucceeded || (statusAfterLaunch != .notRegistered && statusAfterLaunch != .notFound)
    }

    /// What the switch shows: on only when macOS will actually open BeepBar at login.
    public static func isOn(_ status: LoginItemStatus) -> Bool {
        status == .enabled
    }

    /// The switch can always turn an enabled item off; turning it on needs a stable location.
    public static func canChange(status: LoginItemStatus, location: AppLocation) -> Bool {
        status == .enabled || location == .applications
    }

    /// An item held for approval can only be turned back on by the user in System Settings, so
    /// "on" opens Login Items there instead of calling `register()`, which would fail. Checked
    /// before registering and again after, in case macOS asks for approval of a new registration.
    public static func needsSystemSettings(_ status: LoginItemStatus) -> Bool {
        status == .requiresApproval
    }

    /// Whether a change the user asked for failed, judged by macOS's status afterwards rather than
    /// by whether the call threw: `register()` throws `kSMErrorAlreadyRegistered` and `unregister()`
    /// throws `kSMErrorJobNotFound` when macOS is already where the user wants it to be.
    public static func changeFailed(enabling: Bool, statusAfter: LoginItemStatus) -> Bool {
        enabling ? (statusAfter == .notRegistered || statusAfter == .notFound) : statusAfter == .enabled
    }
}
