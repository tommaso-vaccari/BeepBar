import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// Isolation tests use only the injected protocol/browser and owned UUID directories. Removing
/// the offline guard is a safe mutation: it still answers synthetic Moodle in-process (#95).
@MainActor struct UIFixtureTests {
    private func scenario(_ name: String) throws -> UIFixtureScenario {
        try UIFixtureScenario(arguments: ["--scenario", name, "--report", "/tmp/ui-fixture-unused-\(UUID().uuidString).json"])
    }

    /// A typo, partial arguments or relative output must fail before touching any dependency.
    @Test func malformedWorkloadsAreRefused() {
        for arguments in [[], ["--scenario", "activity-1500", "--report", "/tmp/x"], ["--scenario", "courses-500", "--report", "x"], ["--scenario", "courses-500", "--report", "/tmp/x", "--extra"]] {
            #expect(throws: UIFixtureError.self) { try UIFixtureScenario(arguments: arguments) }
        }
    }

    /// Retained evidence is immutable: the fixture must not overwrite a previous output file.
    @Test func existingReportIsRefusedWithoutChangingIt() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "UIFixtureReport-\(UUID().uuidString)")
        try Data("kept".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: UIFixtureError.self) { try UIFixtureScenario(arguments: ["--scenario", "courses-100", "--report", file.path]) }
        #expect(try Data(contentsOf: file) == Data("kept".utf8))
    }

    /// Two controllers retain their own courses/credential/session/defaults; one cannot borrow
    /// the other's token or grow a corpus silently. Both owned roots disappear on disposal.
    @Test func independentFixturesOwnEveryPersistentDependency() async throws {
        let small = try await UIFixture.make(scenario("courses-100"))
        let large = try await UIFixture.make(scenario("courses-500"))
        defer { small.dispose(); large.dispose() }
        #expect(small.root != large.root && small.token != large.token)
        #expect(small.controller.courses.count == 100 && large.controller.courses.count == 500)
        #expect(small.controller.recordingsOwnerUserID == 7 && large.controller.recordingsOwnerUserID == 7)
        #expect(small.controller.automaticSyncEnabled == false)
        #expect(small.controller.rootURL == small.root)
        #expect(try await small.database.scopes(rootID: small.rootID, enabledOnly: true).count == 1)
        small.defaults.set("only small", forKey: "fixture-test")
        #expect(large.defaults.object(forKey: "fixture-test") == nil)
        small.dispose()
        #expect(!FileManager.default.fileExists(atPath: small.root.path))
        #expect(UIFixtureProtocol.accounts.withLock { $0[small.token] == nil })
        #expect(FileManager.default.fileExists(atPath: large.root.path))
    }

    /// An unknown address still enters the fixture protocol and fails; it cannot fall through
    /// to real DNS/network or expose a synthetic credential to a different host.
    @Test func unknownNetworkRequestFailsClosed() async throws {
        let session = UIFixtureProtocol.session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://fixture.invalid/unregistered")!)
            Issue.record("Unknown request escaped the fail-closed protocol")
        } catch {}
    }

    /// The offline fixture keeps its known UI model while a real controller refresh reports
    /// an error. This proves an offline *refresh*, not persisted course restoration (D10).
    @Test func offlineRefreshRetainsKnownCoursesAndReportsFailure() async throws {
        let fixture = try await UIFixture.make(scenario("launch-offline"))
        defer { fixture.dispose() }
        let before = fixture.controller.courses
        await fixture.controller.refreshOnWindowOpen().value
        #expect(fixture.controller.courseLoadError != nil)
        #expect(fixture.controller.courses == before)
        #expect(UIFixtureProtocol.accounts.withLock { ($0[fixture.token]?.requests ?? 0) > 2 })
    }

    /// The reopen scenario can hold a genuine sync at course contents, close/rebuild its UI,
    /// then release the request and finish. Merely assigning `.syncing` would fail this test.
    @Test(.timeLimit(.minutes(1))) func contentsGateKeepsARealSyncRunningUntilReleased() async throws {
        let fixture = try await UIFixture.make(scenario("reopen-sync"))
        defer { UIFixtureProtocol.releaseContents(token: fixture.token); fixture.dispose() }
        UIFixtureProtocol.accounts.withLock { $0[fixture.token]?.holdContents = true }
        fixture.controller.synchronizeNow()
        try await waitUntil { UIFixtureProtocol.accounts.withLock { $0[fixture.token]?.heldRequests.count == 1 } }
        #expect(fixture.controller.isSyncActive)
        UIFixtureProtocol.releaseContents(token: fixture.token)
        await fixture.controller.waitForSyncForTesting()
        #expect(!fixture.controller.isSyncActive)
        if case .synced = fixture.controller.syncState {} else { Issue.record("Synthetic sync did not complete successfully") }
        #expect(UIFixtureProtocol.accounts.withLock { $0[fixture.token]?.heldRequests.isEmpty == true })
    }

    /// Activity and Recordings retain their full large corpus. The browser exercises the real
    /// controller's listing/session flow; it never uses WebKit or a real sign-in.
    @Test(.timeLimit(.minutes(1))) func largeCorporaReachRealControllers() async throws {
        let activity = try await UIFixture.make(scenario("activity-15000"))
        defer { activity.dispose() }
        #expect(activity.controller.lastSyncSummary?.perCourse.first?.items.count == 15_000)
        let fixture = try await UIFixture.make(scenario("recordings-5000"))
        defer { fixture.dispose() }
        let recordings = fixture.controller.recordings
        let key = try #require(RecmanCourseKey(course: fixture.controller.courses[0]))
        recordings.pageAppeared()
        recordings.refresh([key], selected: key)
        try await waitUntil { recordings.listings[key]?.recordings?.count == 5_000 }
        #expect(recordings.access == .ready)
        recordings.pageDisappeared()
        try await waitUntil { !fixture.browser.isOpen }
        #expect(!fixture.browser.isOpen)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
        if !condition() { throw UIFixtureError.missingContent }
    }
}
