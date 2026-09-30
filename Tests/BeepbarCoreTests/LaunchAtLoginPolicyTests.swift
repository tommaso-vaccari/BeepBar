import Testing
@testable import BeepbarCore

/// The decisions behind "Apri BeepBar al login": on by default for everyone, applied once, only
/// from a stable location, and never forced back on after the user turned it off.
struct LaunchAtLoginPolicyTests {
    private let home = "/Users/someone"

    /// Only a copy in Applications may register: a login item has to point at a path that still
    /// exists at the next login. Also guards the prefix check against look-alike folder names.
    @Test(arguments: [
        ("/Applications/Beepbar.app", AppLocation.applications),
        ("/Users/someone/Applications/Beepbar.app", .applications),
        ("/Applications/Utilities/Beepbar.app", .applications),
        ("/Users/someone/Downloads/Beepbar.app", .elsewhere),
        ("/Volumes/BeepBar/Beepbar.app", .elsewhere),
        ("/ApplicationsOld/Beepbar.app", .elsewhere),
        ("/Users/someoneelse/Applications/Beepbar.app", .elsewhere),
        ("/Users/someone/Coding/BeepBar/build/Release/Beepbar.app", .elsewhere),
        ("/private/var/folders/xy/T/AppTranslocation/1234-ABCD/d/Beepbar.app", .translocated),
    ])
    func classifiesWhereTheRunningCopyLives(path: String, expected: AppLocation) {
        #expect(AppLocation.classify(bundlePath: path, homeDirectory: home) == expected)
        #expect(AppLocation.classify(bundlePath: path, homeDirectory: home + "/") == expected, "a trailing slash on the home directory must not change the result")
    }

    /// The default applies on the first launch from Applications, for new and updated installs alike.
    @Test(arguments: [LoginItemStatus.notRegistered, .notFound])
    func firstLaunchFromApplicationsRegisters(status: LoginItemStatus) {
        #expect(LaunchAtLoginPolicy.shouldRegisterOnLaunch(defaultApplied: false, status: status, location: .applications))
    }

    /// Once applied, the default never runs again: this is what keeps a user's "off" from being
    /// overridden at the next launch, whether they turned it off in BeepBar or in System Settings.
    @Test(arguments: [LoginItemStatus.notRegistered, .notFound, .requiresApproval, .enabled])
    func neverRegistersAgainOnceApplied(status: LoginItemStatus) {
        #expect(!LaunchAtLoginPolicy.shouldRegisterOnLaunch(defaultApplied: true, status: status, location: .applications))
    }

    /// Already a login item, or switched off in System Settings before this version ever ran:
    /// nothing to register, and registering would override the user's choice in System Settings.
    @Test(arguments: [LoginItemStatus.enabled, .requiresApproval])
    func doesNotRegisterWhatMacOSAlreadyKnows(status: LoginItemStatus) {
        #expect(!LaunchAtLoginPolicy.shouldRegisterOnLaunch(defaultApplied: false, status: status, location: .applications))
        #expect(LaunchAtLoginPolicy.defaultAppliedAfterLaunch(location: .applications, statusAfterLaunch: status))
    }

    /// A copy run from Downloads, the DMG or a translocated path registers nothing and does not
    /// use up the default, so the copy later moved to Applications still gets it.
    @Test(arguments: [AppLocation.elsewhere, .translocated])
    func unstableLocationsNeitherRegisterNorUseUpTheDefault(location: AppLocation) {
        #expect(!LaunchAtLoginPolicy.shouldRegisterOnLaunch(defaultApplied: false, status: .notRegistered, location: location))
        #expect(!LaunchAtLoginPolicy.defaultAppliedAfterLaunch(location: location, statusAfterLaunch: .notRegistered))
        #expect(!LaunchAtLoginPolicy.defaultAppliedAfterLaunch(location: location, statusAfterLaunch: .enabled))
    }

    /// A registration that failed leaves macOS without a login item; the default stays pending so
    /// the next launch retries instead of silently giving up.
    @Test(arguments: [LoginItemStatus.notRegistered, .notFound])
    func failedRegistrationIsRetriedAtNextLaunch(status: LoginItemStatus) {
        #expect(!LaunchAtLoginPolicy.defaultAppliedAfterLaunch(location: .applications, statusAfterLaunch: status))
    }

    /// The switch shows on only when BeepBar will really open at login: an item switched off in
    /// System Settings (`requiresApproval`) must read as off.
    @Test func switchIsOnOnlyWhenMacOSWillOpenBeepBar() {
        #expect(LaunchAtLoginPolicy.isOn(.enabled))
        #expect(!LaunchAtLoginPolicy.isOn(.requiresApproval))
        #expect(!LaunchAtLoginPolicy.isOn(.notRegistered))
        #expect(!LaunchAtLoginPolicy.isOn(.notFound))
    }

    /// Outside Applications the switch cannot turn it on, but can always turn an enabled item off.
    @Test func switchCanAlwaysTurnOffButOnlyTurnOnFromApplications() {
        #expect(LaunchAtLoginPolicy.canChange(status: .notRegistered, location: .applications))
        #expect(!LaunchAtLoginPolicy.canChange(status: .notRegistered, location: .elsewhere))
        #expect(!LaunchAtLoginPolicy.canChange(status: .requiresApproval, location: .translocated))
        #expect(LaunchAtLoginPolicy.canChange(status: .enabled, location: .elsewhere))
    }

    /// Only System Settings can re-enable an item the user switched off there.
    @Test func turningOnAnItemHeldForApprovalSendsTheUserToSystemSettings() {
        #expect(LaunchAtLoginPolicy.needsSystemSettings(afterEnablingStatus: .requiresApproval))
        #expect(!LaunchAtLoginPolicy.needsSystemSettings(afterEnablingStatus: .enabled))
        #expect(!LaunchAtLoginPolicy.needsSystemSettings(afterEnablingStatus: .notRegistered))
    }
}
