import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct LanguageResolutionTests {
    @Test func storedChoiceAlwaysWins() {
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: "en", needsOnboarding: false, preferredLanguages: ["it-IT"]) == .english)
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: "it", needsOnboarding: true, preferredLanguages: ["en-US"]) == .italian)
    }

    @Test func existingInstallWithoutAChoiceStaysItalian() {
        // Every install set up before the setting existed only ever had Italian copy.
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: nil, needsOnboarding: false, preferredLanguages: ["en-US"]) == .italian)
    }

    @Test func freshInstallStartsFromTheSystemLanguage() {
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: nil, needsOnboarding: true, preferredLanguages: ["it-IT", "en-US"]) == .italian)
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: nil, needsOnboarding: true, preferredLanguages: ["de-DE", "it-IT"]) == .english)
    }

    @Test func unknownStoredValueFallsBackLikeNoChoice() {
        #expect(WeBeepAuthenticationController.resolveLanguage(stored: "fr", needsOnboarding: false, preferredLanguages: ["en-US"]) == .italian)
    }

    @Test func systemPreferenceWithNoLanguagesDefaultsToItalian() {
        #expect(AppLanguage.preferred(from: []) == .italian)
    }
}

struct PreferredLanguageTests {
    @Test(arguments: [
        (["it-CH"], AppLanguage.italian),
        (["IT"], .italian),
        (["it"], .italian),
        (["en-GB", "it-IT"], .english),
        (["fr-FR"], .english),
    ])
    func followsTheFirstPreferredLanguage(languages: [String], expected: AppLanguage) {
        #expect(AppLanguage.preferred(from: languages) == expected)
    }
}

struct MenuBarSymbolTests {
    private static let summary = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 0), added: 0, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0)

    @Test(arguments: [AppSyncState.checking, .syncing, .cancelling])
    func activeSyncShowsTheDownloadGlyph(state: AppSyncState) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state) == "arrow.down.circle")
    }

    /// Proves the states that need the user keep the warning triangle, including every failure
    /// reason that is not a retry-by-itself or a lost connection. Guards against a state that only
    /// the user can fix looking calm.
    @Test(arguments: [
        AppSyncState.conflicts(1, nil), .recoveryBlocked, .loginRequired, .needsFolder,
        .failed(.authenticationExpired), .failed(.incompatibleResponse), .failed(.credentialUnavailable),
        .failed(.local(BilingualText("x", "x"))),
    ])
    func statesNeedingTheUserShowAWarning(state: AppSyncState) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state) == "exclamationmark.triangle")
    }

    /// Proves a lost connection has its own glyph (#271), instead of the warning it shared with
    /// everything else.
    @Test func noConnectionShowsTheOfflineGlyph() {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: .failed(.connectivity)) == "wifi.slash")
    }

    /// Proves the problems BeepBar retries by itself (platform unreachable, some materials not
    /// updated) show a calm glyph, not the warning (#271).
    @Test(arguments: [AppSyncState.failed(.serviceUnavailable), .failed(.partialSync), .partial(summary)])
    func problemsRetriedByThemselvesShowACalmGlyph(state: AppSyncState) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state) == "clock.arrow.circlepath")
    }

    /// Proves the Data Saver pause wins over every state, whatever level the state would have.
    @Test(arguments: [
        AppSyncState.failed(.connectivity), .failed(.serviceUnavailable), .partial(summary), .conflicts(1, nil),
        .loginRequired, .synced(summary),
    ])
    func thePauseOverridesEveryState(state: AppSyncState) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state, pause: .hotspot) == "pause.circle")
    }

    @Test(arguments: [AppSyncState.starting, .readyUnchecked, .synced(summary)])
    func idleStatesKeepTheDefaultGlyph(state: AppSyncState) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state) == "arrow.triangle.2.circlepath")
    }
}
