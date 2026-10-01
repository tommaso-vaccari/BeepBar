import Foundation
import os
import Testing
import BeepbarCore
@testable import BeepbarApp

/// "Risparmio dati" (Data Saver), end to end through the controller against a local Moodle (see
/// `MoodleRecordingProtocol`): what an automatic run sends, what the user sees, and what clears
/// the pause. The pure rules are in `AutomaticSyncPolicyTests` (Core) and at the bottom of this file.
@MainActor struct DataSaverTests {
    private nonisolated static let lastResult = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 1_800_000_000), added: 3, updated: 0, unchanged: 10, preservedLocal: 0, conflicts: 0, failures: 0)

    // MARK: Before a run

    /// Proves that with Data Saver on, an automatic run on a hotspot or a Low Data Mode network
    /// sends nothing, leaves the last result on screen and says why it is waiting, in the menu
    /// too. Guards against the pause being reported as a failure, replacing "sincronizzato X fa",
    /// or sending requests before giving up.
    @Test(arguments: [
        (NetworkPathConditions.hotspot, DataSaverPause.hotspot, "In attesa del Wi-Fi"),
        (.lowDataMode, .lowDataMode, "Modalità dati ridotti attiva")
    ])
    func pausesBeforeSendingAnything(_ network: NetworkPathConditions, _ pause: DataSaverPause, _ menuDetail: String) async throws {
        let harness = try await Harness(networks: [network])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.synced(Self.lastResult))
        let requestsBefore = harness.requests.count

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(outcome == .deferred)
        #expect(harness.requests.count == requestsBefore)
        #expect(harness.controller.syncState == .synced(Self.lastResult))
        #expect(harness.controller.dataSaverPause == pause)
        #expect(harness.controller.visibleDataSaverPause == pause)
        #expect(harness.controller.menuBarSnapshot.title == "In pausa per Risparmio dati")
        #expect(harness.controller.menuBarSnapshot.detail == menuDetail)
        #expect(!harness.controller.isSyncActive)
        #expect(!harness.downloaded("a.txt"))
        #expect(harness.networkReads == 1)
    }

    /// Proves that with Data Saver off, the default, an automatic run on a hotspot downloads like
    /// any other, without even reading the network. This is the false "Connessione assente" users
    /// saw on a hotspot. Guards against automatic runs restricting themselves again, and against
    /// the network being read when nothing depends on it (quiet at rest).
    @Test func withDataSaverOffAHotspotDownloadsAsUsual() async throws {
        let harness = try await Harness(networks: [.hotspot])
        defer { harness.remove() }
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(outcome == .finished)
        guard case .synced = harness.controller.syncState else {
            Issue.record("Expected a completed sync, got \(harness.controller.syncState)")
            return
        }
        #expect(harness.downloaded("a.txt"))
        #expect(harness.downloads.allSatisfy { $0.allowsExpensiveNetworkAccess && $0.allowsConstrainedNetworkAccess })
        #expect(harness.controller.dataSaverPause == nil)
        #expect(harness.networkReads == 0)
    }

    /// Proves that with Data Saver on and an ordinary network, an automatic run downloads, and
    /// asks macOS to keep its downloads off a hotspot in case the Mac moves to one midway.
    /// Guards against the switch blocking every run, or the run forgetting its limits.
    @Test func withDataSaverOnAnOrdinaryNetworkDownloadsWithLimits() async throws {
        let harness = try await Harness(networks: [.unrestricted])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(outcome == .finished)
        #expect(harness.downloaded("a.txt"))
        #expect(!harness.downloads.isEmpty)
        #expect(harness.downloads.allSatisfy { !$0.allowsExpensiveNetworkAccess && !$0.allowsConstrainedNetworkAccess })
        #expect(harness.controller.dataSaverPause == nil)
    }

    /// Proves that Low Power Mode and another operation still defer first, without reading the
    /// network or showing a pause. Guards against Data Saver taking over a deferral that has
    /// another cause, which would tell a user on Wi-Fi that BeepBar waits for Wi-Fi.
    @Test func lowPowerModeAndABusyAppDeferWithoutAPause() async throws {
        let harness = try await Harness(networks: [.hotspot], lowPowerMode: true)
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        #expect(await harness.controller.runAutomaticSyncForTesting() == .deferred)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(harness.networkReads == 0)

        let busy = try await Harness(networks: [.hotspot])
        defer { busy.remove() }
        busy.controller.setDataSaver(enabled: true)
        busy.controller.setOperationForTesting(UUID())
        #expect(await busy.controller.runAutomaticSyncForTesting() == .deferred)
        #expect(busy.controller.dataSaverPause == nil)
        #expect(busy.networkReads == 0)
    }

    /// Proves that a signed-out app is never shown as paused: the real problem, signing in, stays
    /// in front. Guards against Data Saver hiding a state the user has to act on.
    @Test func aSignedOutAppIsNeverPaused() async throws {
        let harness = try await Harness(networks: [.hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.signOut()
        #expect(harness.controller.accountState == .notConnected)

        #expect(await harness.controller.runAutomaticSyncForTesting() == .finished)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(harness.networkReads == 0)
    }

    // MARK: Midway

    /// Proves that when the Mac moves to a hotspot during a Data Saver run, macOS's refusal ends
    /// the run as a pause: the last result comes back, nothing is reported as failed, and the
    /// scheduler retries soon. Guards against the false "Connessione assente" this used to show.
    @Test func aHotspotMidwayPausesInsteadOfReportingNoConnection() async throws {
        let harness = try await Harness(networks: [.unrestricted, .hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.synced(Self.lastResult))
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        // The run really reached the downloads, and macOS refused them.
        #expect(!harness.downloads.isEmpty)
        #expect(!harness.downloaded("a.txt"))
        #expect(outcome == .deferred)
        #expect(harness.controller.syncState == .synced(Self.lastResult))
        #expect(harness.controller.dataSaverPause == .hotspot)
        #expect(harness.controller.menuBarSnapshot.title == "In pausa per Risparmio dati")
        #expect(!harness.controller.isSyncActive)
        #expect(harness.networkReads == 2)
    }

    /// Proves that a refusal is still reported as "Connessione assente" when the network read
    /// afterwards is an ordinary one or none at all: that is a real outage. Guards against every
    /// connection failure of a Data Saver run being hidden behind the pause.
    @Test(arguments: [NetworkPathConditions.unrestricted, .offline])
    func aRealOutageMidwayStillSaysNoConnection(_ networkAfterwards: NetworkPathConditions) async throws {
        let harness = try await Harness(networks: [.unrestricted, networkAfterwards])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)

        _ = await harness.controller.runAutomaticSyncForTesting()

        #expect(!harness.downloads.isEmpty)
        #expect(harness.controller.syncState == .failed(.connectivity))
        #expect(harness.controller.dataSaverPause == nil)
        #expect(!harness.controller.isSyncActive)
    }

    /// Proves that turning Data Saver off while its run is refused midway brings the last result
    /// back without showing a pause the user just switched off, and defers so the retry comes
    /// soon, without limits. Guards against the refusal, caused by the run's own limits, being
    /// reported as an outage, and against a pause that outlives its switch.
    @Test func switchingDataSaverOffMidwayShowsNeitherPauseNorFailure() async throws {
        let harness = try await Harness(networks: [.unrestricted, .hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.synced(Self.lastResult))
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)
        harness.sequence.onRead(2) { harness.controller.setDataSaver(enabled: false) }

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(!harness.controller.dataSaverEnabled)
        #expect(outcome == .deferred)
        #expect(harness.controller.syncState == .synced(Self.lastResult))
        #expect(harness.controller.dataSaverPause == nil)
        #expect(!harness.controller.isSyncActive)
    }

    // MARK: What clears the pause

    /// Proves that "Sincronizza ora" on a hotspot clears the pause and downloads at once, Data
    /// Saver or not: the user asked for it. Guards against the pause outliving a manual sync, or
    /// manual syncs inheriting the automatic limits.
    @Test func syncNowOnAHotspotClearsThePauseAndDownloads() async throws {
        let harness = try await Harness(networks: [.hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)
        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.controller.dataSaverPause == .hotspot)

        harness.controller.synchronizeNow()
        #expect(harness.controller.dataSaverPause == nil)
        await harness.controller.waitForSyncForTesting()

        #expect(harness.downloaded("a.txt"))
        guard case .synced = harness.controller.syncState else {
            Issue.record("Expected a completed sync, got \(harness.controller.syncState)")
            return
        }
    }

    /// Proves that the pause ends when the next automatic run finds an ordinary network, and that
    /// run downloads. Guards against a pause that sticks after the Mac is back on Wi-Fi.
    @Test func theNextRunOnWiFiClearsThePause() async throws {
        let harness = try await Harness(networks: [.hotspot, .unrestricted])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        #expect(await harness.controller.runAutomaticSyncForTesting() == .deferred)
        #expect(harness.controller.dataSaverPause == .hotspot)

        #expect(await harness.controller.runAutomaticSyncForTesting() == .finished)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(harness.downloaded("a.txt"))
    }

    /// Proves that turning Data Saver or automatic sync off, or signing out, clears the pause at
    /// once, and that with Data Saver off the next run on the hotspot downloads. Guards against
    /// the window still saying "In pausa per Risparmio dati" for something no longer on.
    @Test func turningThingsOffClearsThePause() async throws {
        let harness = try await Harness(networks: [.hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)

        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.controller.dataSaverPause == .hotspot)
        harness.controller.setDataSaver(enabled: false)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(await harness.controller.runAutomaticSyncForTesting() == .finished)
        #expect(harness.downloaded("a.txt"))

        harness.controller.setDataSaver(enabled: true)
        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.controller.dataSaverPause == .hotspot)
        harness.controller.setAutomaticSync(enabled: false)
        #expect(harness.controller.dataSaverPause == nil)

        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.controller.dataSaverPause == .hotspot)
        harness.controller.signOut()
        #expect(harness.controller.dataSaverPause == nil)
    }

    // MARK: The setting

    /// Proves that Data Saver is off on a first launch and that turning it on survives a relaunch.
    /// Guards against a default that would silently hold back every existing user's downloads on
    /// a hotspot, and against a switch that forgets itself.
    @Test func theSettingIsOffByDefaultAndPersists() {
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let first = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory, defaults: UserDefaults(suiteName: suite)!)
        #expect(!first.dataSaverEnabled)

        first.setDataSaver(enabled: true)
        let relaunched = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory, defaults: UserDefaults(suiteName: suite)!)
        #expect(relaunched.dataSaverEnabled)

        relaunched.setDataSaver(enabled: false)
        let again = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory, defaults: UserDefaults(suiteName: suite)!)
        #expect(!again.dataSaverEnabled)
    }

    // MARK: When the pause shows

    /// Proves where the pause is shown: only over a calm state ("Pronto", the last result, or the
    /// connection failure it explains), never during a run or over something the user must act
    /// on. Guards against "In pausa" hiding conflicts, a sign-in or a blocked recovery.
    @Test(arguments: [
        (DataSaverPause?.some(.hotspot), AppSyncState.readyUnchecked, false, DataSaverPause?.some(.hotspot)),
        (.hotspot, .synced(lastResult), false, .hotspot),
        (.lowDataMode, .failed(.connectivity), false, .lowDataMode),
        (.hotspot, .synced(lastResult), true, nil),
        (.hotspot, .checking, true, nil),
        (.hotspot, .conflicts(2, lastResult), false, nil),
        (.hotspot, .partial(lastResult), false, nil),
        (.hotspot, .loginRequired, false, nil),
        (.hotspot, .needsFolder, false, nil),
        (.hotspot, .recoveryBlocked, false, nil),
        (.hotspot, .failed(.authenticationExpired), false, nil),
        (.hotspot, .failed(.serviceUnavailable), false, nil),
        (nil, .synced(lastResult), false, nil)
    ])
    func showsThePauseOnlyOverACalmState(_ pause: DataSaverPause?, _ state: AppSyncState, _ active: Bool, _ expected: DataSaverPause?) {
        #expect(WeBeepAuthenticationController.visibleDataSaverPause(pause, syncState: state, syncActive: active) == expected)
    }
}

/// Answers the controller's network reads in order, repeating the last answer, and counts them.
/// `onRead` runs an action on the main actor just before a given read answers, to change
/// something while a run is waiting on it.
private final class NetworkSequence: Sendable {
    private struct State {
        var networks: [NetworkPathConditions?]
        var reads = 0
        var actions: [Int: @MainActor @Sendable () -> Void] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ networks: [NetworkPathConditions?]) {
        state = OSAllocatedUnfairLock(initialState: State(networks: networks))
    }

    var reads: Int { state.withLock { $0.reads } }

    func onRead(_ number: Int, _ action: @escaping @MainActor @Sendable () -> Void) {
        state.withLock { $0.actions[number] = action }
    }

    func next() async -> NetworkPathConditions? {
        let (network, action) = state.withLock { state -> (NetworkPathConditions?, (@MainActor @Sendable () -> Void)?) in
            state.reads += 1
            let network = state.networks.count > 1 ? state.networks.removeFirst() : state.networks.first ?? nil
            return (network, state.actions[state.reads])
        }
        if let action { await action() }
        return network
    }
}

/// A controller signed in to a local Moodle where course 1 is selected and lists `a.txt`, with a
/// folder of its own and a scripted network.
@MainActor private struct Harness {
    let controller: WeBeepAuthenticationController
    let token: String
    let root: URL
    let sequence: NetworkSequence

    init(networks: [NetworkPathConditions?], lowPowerMode: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: true))
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], files: [1: ["a.txt"]])
        self.token = token
        let sequence = NetworkSequence(networks)
        self.sequence = sequence
        let environment = AutomaticSyncEnvironment(isLowPowerModeEnabled: { lowPowerMode }, currentNetwork: { await sequence.next() })
        let vault = CredentialVault(read: { _ in token }, write: { _ in })
        controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), downloader: MoodleRecordingProtocol.makeDownloader(), credentialVault: vault, deleteCredential: {}, automaticSyncEnvironment: environment)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        // Signed in through the local Moodle, with course 1 selected: every run below can sync.
        #expect(controller.courseLoadError == nil)
        #expect(controller.enabledCourseIDs == [1])
    }

    var requests: [MoodleRecordingProtocol.RecordedRequest] { MoodleRecordingProtocol.requests(token: token) }
    var downloads: [MoodleRecordingProtocol.RecordedRequest] { requests.filter { $0.function == MoodleRecordingProtocol.downloadFunction } }
    var networkReads: Int { sequence.reads }

    func downloaded(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: "Course/Lezioni/\(name)").path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
