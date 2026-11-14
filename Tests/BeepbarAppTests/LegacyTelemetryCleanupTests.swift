import Foundation
import Testing
@testable import BeepbarApp

struct LegacyTelemetryCleanupTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: suite).deletingLastPathComponent())
        }
        try body(defaults)
    }

    /// Proves the upgrade path of #239: starting from the preferences the removed telemetry left
    /// (all seven keys, plus look-alikes and unrelated settings), the telemetry keys are gone, every
    /// other preference is intact, and a second run removes and changes nothing. Guards against
    /// shipping without the cleanup, against a prefix match that eats unrelated keys, and against
    /// a cleanup that rewrites preferences on every launch.
    @Test func removesOnlyTheTelemetryPreferencesAndIsIdempotent() throws {
        try withDefaults { defaults in
            for key in LegacyTelemetryCleanup.preferenceKeys { defaults.set("old", forKey: key) }
            defaults.set(true, forKey: "dailyTelemetryEnabled")
            defaults.set(Date(), forKey: "dailyTelemetryLastAttempt")
            let unrelated: [String: Any] = [
                "automaticSyncEnabled": true,
                "dailyTelemetryLookalike": "keep",
                "telemetryNotes": 3,
                "io.github.tvaccari.beepbar.recordings-acknowledged.v1": true,
            ]
            for (key, value) in unrelated { defaults.set(value, forKey: key) }

            let removed = LegacyTelemetryCleanup.removeLeftovers(from: defaults)

            #expect(Set(removed) == Set(LegacyTelemetryCleanup.preferenceKeys))
            #expect(LegacyTelemetryCleanup.preferenceKeys.count == 7)
            for key in LegacyTelemetryCleanup.preferenceKeys { #expect(defaults.object(forKey: key) == nil, "\(key) survived") }
            #expect(defaults.object(forKey: "automaticSyncEnabled") as? Bool == true)
            #expect(defaults.string(forKey: "dailyTelemetryLookalike") == "keep")
            #expect(defaults.integer(forKey: "telemetryNotes") == 3)
            #expect(defaults.object(forKey: "io.github.tvaccari.beepbar.recordings-acknowledged.v1") as? Bool == true)

            let before = defaults.dictionaryRepresentation().filter { unrelated.keys.contains($0.key) }.count
            #expect(LegacyTelemetryCleanup.removeLeftovers(from: defaults).isEmpty)
            #expect(defaults.dictionaryRepresentation().filter { unrelated.keys.contains($0.key) }.count == before)
        }
    }

    /// A fresh install has none of the keys: the cleanup removes nothing and leaves other settings alone.
    @Test func freshInstallIsUntouched() throws {
        try withDefaults { defaults in
            defaults.set(42, forKey: "somethingElse")
            #expect(LegacyTelemetryCleanup.removeLeftovers(from: defaults).isEmpty)
            #expect(defaults.integer(forKey: "somethingElse") == 42)
        }
    }
}
