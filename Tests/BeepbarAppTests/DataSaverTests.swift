import Foundation
import os
import Testing
@testable import BeepbarCore
@testable import BeepbarApp

/// "Risparmio dati" (Data Saver), end to end through the controller against a local Moodle (see
/// `MoodleRecordingProtocol`): what an automatic run sends, what the user sees, and what clears
/// the pause. The pure rules are in `AutomaticSyncPolicyTests` (Core) and at the bottom of this file.
@MainActor struct DataSaverTests {
    private nonisolated static let lastResult = SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 1_800_000_000), added: 3, updated: 0, unchanged: 10, preservedLocal: 0, conflicts: 0, failures: 0)

    /// A nonempty selection keeps the original deadline; empty selection and recovery stop activity.
    @Test func schedulerKeepsDeadlineAndTracksRecovery() async throws {
        let schedule = TestSchedule()
        let harness = try await Harness(networks: [.hotspot], schedule: schedule)
        defer { harness.remove() }
        #expect(schedule.registrations == 1)
        let deadline = schedule.deadline
        schedule.now = 120
        let second = RemoteCourseSummary(id: 2, shortName: "Second", displayName: "Second", isVisible: nil, startDate: nil, endDate: nil)
        harness.controller.setCourse(second, enabled: true)
        #expect(schedule.registrations == 1)
        #expect(schedule.deadline == deadline)
        harness.controller.setCourse(harness.controller.courses[0], enabled: false)
        #expect(schedule.registrations == 1)
        harness.controller.setCourse(second, enabled: false)
        #expect(!schedule.active)
        harness.controller.setCourse(second, enabled: true)
        #expect(schedule.registrations == 2 && schedule.active)
        harness.controller.setRecoveryBlockedForTesting(true)
        #expect(!schedule.active)
        harness.controller.setRecoveryBlockedForTesting(true)
        #expect(schedule.registrations == 2)
        harness.controller.setRecoveryBlockedForTesting(false)
        #expect(schedule.registrations == 3 && schedule.active)
        harness.controller.setRecoveryBlockedForTesting(false)
        #expect(schedule.registrations == 3)
    }

    /// A queued callback from an invalidated registration must finish without reading the network.
    @Test func invalidatedSchedulerCallbackDoesNotRun() async throws {
        let schedule = TestSchedule()
        let harness = try await Harness(networks: [.hotspot], schedule: schedule)
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setAutomaticSync(enabled: false)
        harness.controller.setAutomaticSync(enabled: true)
        #expect(await schedule.fire(0) == .finished)
        #expect(harness.networkReads == 0)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(await schedule.fire(1) == .deferred)
        #expect(harness.networkReads == 1)
        #expect(harness.controller.dataSaverPause == .hotspot)
    }

    /// Selection changes clear a pause and reject pending path answers without replacing the timer.
    @Test func selectionInvalidatesPathButNotDeadline() async throws {
        let schedule = TestSchedule()
        let harness = try await Harness(networks: [.hotspot, .hotspot], schedule: schedule)
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        #expect(await schedule.fire(0) == .deferred)
        let deadline = schedule.deadline
        let first = harness.controller.courses[0]
        harness.controller.setCourse(RemoteCourseSummary(id: 2, shortName: "Second", displayName: "Second", isVisible: nil, startDate: nil, endDate: nil), enabled: true)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(schedule.registrations == 1 && schedule.deadline == deadline)
        harness.sequence.onRead(2) { harness.controller.setCourse(first, enabled: false) }
        #expect(await schedule.fire(0) == .finished)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(schedule.registrations == 1 && schedule.deadline == deadline)
    }

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

    /// Proves that an automatic run skipped because nothing can be synced clears an earlier pause,
    /// since finishing leaves no retry behind. Signing out here bypasses the rebuild on purpose: it
    /// stands in for a blocked local recovery, the one real way to stop being able to sync without
    /// one. Guards against "In attesa del Wi-Fi" coming back over the last result, even on Wi-Fi,
    /// for a whole interval once the recovery is resolved.
    @Test func aRunThatCannotSyncClearsThePause() async throws {
        let harness = try await Harness(networks: [.hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        #expect(await harness.controller.runAutomaticSyncForTesting() == .deferred)
        #expect(harness.controller.dataSaverPause == .hotspot)
        harness.controller.setDisconnectedForTesting()

        #expect(await harness.controller.runAutomaticSyncForTesting() == .finished)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(harness.networkReads == 1)
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

    /// Proves that "Annulla" while a refused run reads the network ends the run as cancelled:
    /// "Pronto", like any cancelled sync, with no pause and no failure. Guards against the
    /// cancellation being lost and the run reported as paused, or as "Connessione assente".
    @Test func cancellingWhileTheRefusalIsCheckedCancels() async throws {
        let harness = try await Harness(networks: [.unrestricted, .hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.synced(Self.lastResult))
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)
        harness.sequence.onRead(2) { harness.controller.cancelSynchronization() }

        await harness.controller.runAutomaticSyncForTesting()

        #expect(harness.networkReads == 2)
        #expect(harness.controller.syncState == .readyUnchecked)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(!harness.controller.isSyncActive)
    }

    /// Proves that a run whose operation was replaced while it read the network leaves the new
    /// operation alone: no pause, no state of its own. Guards against a stale run painting a pause
    /// and an old result over whatever replaced it.
    @Test func aRunReplacedWhileTheRefusalIsCheckedLeavesTheNewOneAlone() async throws {
        let harness = try await Harness(networks: [.unrestricted, .hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.synced(Self.lastResult))
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)
        harness.sequence.onRead(2) { harness.controller.setOperationForTesting(UUID()) }

        await harness.controller.runAutomaticSyncForTesting()

        #expect(harness.networkReads == 2)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(harness.controller.syncState == .syncing)
        #expect(harness.controller.isSyncActive)
        harness.controller.setOperationForTesting(nil)
    }

    /// Proves that a run paused midway still shows what waits in Conflicts, as a finished run
    /// would: files handled before the refusal may have opened conflicts. Guards against the
    /// Conflicts notice staying hidden until some later run.
    @Test func aPauseMidwayStillShowsConflicts() async throws {
        let harness = try await Harness(networks: [.unrestricted, .hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.synced(Self.lastResult))
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)
        // Stands in for a conflict recorded before the refusal, which the controller has not read.
        try await harness.database.insertConflict(ConflictRecord(id: UUID(), rootID: harness.rootID, remoteID: "pending",
            relativePath: try RelativePath("Course/pending.pdf"), incomingPath: try RelativePath(internal: ".beepbar/conflicts/pending.pdf"),
            baseSHA256: "base", localSHA256: "local", remoteSHA256: "remote", remoteRevision: "2", detectedAt: .now, status: .open))
        #expect(harness.controller.conflicts.isEmpty)

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(outcome == .deferred)
        #expect(harness.controller.conflicts.count == 1)
        #expect(harness.controller.syncState == .conflicts(1, nil))
    }

    /// Proves that a run paused midway does not bring back an error from before it: it got as far
    /// as downloading, so that error is gone, and the pause shows instead. Guards against an old
    /// "Servizio non disponibile" hiding the pause and reporting a problem that no longer exists.
    @Test func aPauseMidwayDoesNotBringBackAnOldError() async throws {
        let harness = try await Harness(networks: [.unrestricted, .hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.failed(.serviceUnavailable))
        MoodleRecordingProtocol.setOnHotspot(token: harness.token, true)

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(!harness.downloads.isEmpty)
        #expect(outcome == .deferred)
        #expect(harness.controller.syncState == .readyUnchecked)
        #expect(harness.controller.visibleDataSaverPause == .hotspot)
    }

    /// Proves what a pause midway puts back: everything still true stays, an error gives way to
    /// "Pronto". Guards against a stale error coming back, or a result being lost.
    @Test(arguments: [
        (AppSyncState.synced(lastResult), AppSyncState.synced(lastResult)),
        (.readyUnchecked, .readyUnchecked),
        (.conflicts(2, lastResult), .conflicts(2, lastResult)),
        (.partial(lastResult), .partial(lastResult)),
        (.failed(.connectivity), .readyUnchecked),
        (.failed(.serviceUnavailable), .readyUnchecked),
        (.failed(.partialSync), .readyUnchecked)
    ])
    func aPauseMidwayPutsBackWhatIsStillTrue(_ before: AppSyncState, _ expected: AppSyncState) {
        #expect(WeBeepAuthenticationController.stateAfterPauseMidway(before) == expected)
    }

    /// Proves that turning automatic sync off while a run reads the network stops that run: no
    /// pause on a hotspot, no sync on Wi-Fi, even if it is turned back on at once (the schedule
    /// that started the run is gone either way). Guards against a pause nothing would clear (the
    /// Data Saver switch is disabled while automatic sync is off, and the new schedule runs a
    /// whole interval later), and a sync after the user said no.
    @Test(arguments: [(NetworkPathConditions.hotspot, false), (.unrestricted, false), (.hotspot, true), (.unrestricted, true)])
    func turningAutomaticSyncOffWhileTheNetworkIsReadStopsTheRun(_ network: NetworkPathConditions, _ backOnAtOnce: Bool) async throws {
        let harness = try await Harness(networks: [network])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.synced(Self.lastResult))
        harness.sequence.onRead(1) {
            harness.controller.setAutomaticSync(enabled: false)
            if backOnAtOnce { harness.controller.setAutomaticSync(enabled: true) }
        }
        let requestsBefore = harness.requests.count

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(outcome == .finished)
        #expect(harness.networkReads == 1)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(harness.requests.count == requestsBefore)
        #expect(!harness.downloaded("a.txt"))
        #expect(harness.controller.syncState == .synced(Self.lastResult))
    }

    @Test func cancelledNetworkReadDoesNotStartAutomaticSync() async throws {
        let harness = try await Harness(networks: [nil])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.synced(Self.lastResult))
        let requestsBefore = harness.requests.count
        let task = Task { await harness.controller.runAutomaticSyncForTesting() }
        harness.sequence.onRead(1) { task.cancel() }
        #expect(await task.value == .finished)
        #expect(harness.requests.count == requestsBefore)
        #expect(!harness.controller.isSyncActive)
        #expect(harness.controller.dataSaverPause == nil)
        #expect(harness.controller.syncState == .synced(Self.lastResult))
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

    /// Proves that turning Data Saver or automatic sync off, changing Frequenza or signing out
    /// clears the pause at once, and that with Data Saver off the next run on the hotspot
    /// downloads. Guards against the window still saying "In pausa per Risparmio dati" for
    /// something no longer on, or after the schedule that would retry was replaced.
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

        harness.controller.setAutomaticSync(enabled: true)
        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.controller.dataSaverPause == .hotspot)
        harness.controller.setAutomaticSyncInterval(3_600)
        #expect(harness.controller.automaticSyncInterval == 3_600)
        #expect(harness.controller.dataSaverPause == nil)

        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.controller.dataSaverPause == .hotspot)
        harness.controller.signOut()
        #expect(harness.controller.dataSaverPause == nil)
    }

    /// Proves that the pause does not come back after the sign-in expires and is renewed: both
    /// rebuild the schedule, which drops the retry the pause promised, so the next run is a whole
    /// interval away. Guards against "In attesa del Wi-Fi" staying on screen for hours after
    /// signing in again, possibly back on Wi-Fi.
    @Test func anExpiredSignInDoesNotBringThePauseBack() async throws {
        let harness = try await Harness(networks: [.hotspot])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.controller.dataSaverPause == .hotspot)

        // Moodle stops accepting the token: the next course refresh finds the sign-in expired.
        MoodleRecordingProtocol.revoke(token: harness.token)
        harness.controller.loadCourses()
        await harness.controller.waitForCourseLoadForTesting()
        #expect(harness.controller.accountState == .expired)
        #expect(harness.controller.dataSaverPause == nil)

        let renewed = MoodleRecordingProtocol.register(courses: [(1, "Course")], files: [1: ["a.txt"]])
        await harness.controller.completeLoginForTesting(moodleLoginCallback(token: renewed))
        #expect(harness.controller.accountState == .connected)
        #expect(harness.controller.syncState == .readyUnchecked)
        #expect(harness.controller.visibleDataSaverPause == nil)
        #expect(harness.controller.menuBarSnapshot.title != "In pausa per Risparmio dati")
    }

    // MARK: The menu bar icon

    /// Proves that the menu bar icon shows the pause, pushed to the status item, instead of the
    /// warning an earlier "Connessione assente" gives, and goes back when the pause ends. Guards
    /// against a warning triangle next to a menu that says all is calm.
    @Test func theIconShowsThePause() async throws {
        let harness = try await Harness(networks: [.hotspot])
        defer { harness.remove() }
        let pushed = SymbolLog()
        harness.controller.onMenuBarSymbolChange = { pushed.symbols.append($0) }
        harness.controller.setDataSaver(enabled: true)
        harness.controller.setSyncStateForTesting(.failed(.connectivity))
        #expect(pushed.symbols.last == "exclamationmark.triangle")

        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.controller.visibleDataSaverPause == .hotspot)
        #expect(pushed.symbols.last == "pause.circle")

        harness.controller.setDataSaver(enabled: false)
        #expect(pushed.symbols.last == "exclamationmark.triangle")
    }

    /// Proves the icon for each case: the pause the user sees wins over the state underneath, and
    /// without one the state decides as before.
    @Test(arguments: [
        (AppSyncState.failed(.connectivity), DataSaverPause?.some(.hotspot), "pause.circle"),
        (.synced(lastResult), .lowDataMode, "pause.circle"),
        (.failed(.connectivity), nil, "exclamationmark.triangle"),
        (.synced(lastResult), nil, "arrow.triangle.2.circlepath")
    ])
    func iconForEachCase(_ state: AppSyncState, _ pause: DataSaverPause?, _ expected: String) {
        #expect(WeBeepAuthenticationController.menuBarSymbol(for: state, pause: pause) == expected)
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

/// The icons the controller pushed to the status item, in order.
@MainActor private final class SymbolLog {
    var symbols: [String] = []
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
/// folder of its own, a scripted network, and automatic sync on, as users have it.
@MainActor private struct Harness {
    let controller: WeBeepAuthenticationController
    let token: String
    let root: URL
    let database: SyncDatabase
    let rootID: UUID
    let sequence: NetworkSequence

    init(networks: [NetworkPathConditions?], lowPowerMode: Bool = false, schedule: TestSchedule? = nil) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: true))
        self.database = database
        self.rootID = rootID
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], files: [1: ["a.txt"]])
        self.token = token
        let sequence = NetworkSequence(networks)
        self.sequence = sequence
        let environment = AutomaticSyncEnvironment(isLowPowerModeEnabled: { lowPowerMode }, currentNetwork: { await sequence.next() })
        // The stored token, which a renewed sign-in replaces, as it replaces the real one.
        let stored = OSAllocatedUnfairLock(initialState: token)
        let vault = CredentialVault(read: { _ in stored.withLock { $0 } }, write: { renewed in stored.withLock { $0 = renewed } })
        controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), downloader: MoodleRecordingProtocol.makeDownloader(), credentialVault: vault, deleteCredential: {}, automaticSyncEnvironment: environment)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        // Signed in through the local Moodle, with course 1 selected: every run below can sync.
        #expect(controller.courseLoadError == nil)
        #expect(controller.enabledCourseIDs == [1])
        // A test controller registers no real background activity, so this is safe here.
        if let schedule { controller.setBackgroundSchedulerForTesting { interval, callback in schedule.register(interval, callback) } }
        controller.setAutomaticSync(enabled: true)
        #expect(controller.automaticSyncEnabled)
    }

    var requests: [MoodleRecordingProtocol.RecordedRequest] { MoodleRecordingProtocol.requests(token: token) }
    var downloads: [MoodleRecordingProtocol.RecordedRequest] { requests.filter { $0.function == MoodleRecordingProtocol.downloadFunction } }
    var networkReads: Int { sequence.reads }

    func downloaded(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: "Course/Lezioni/\(name)").path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Deterministic registration clock; keeps old callbacks to model macOS callbacks already queued.
@MainActor private final class TestSchedule {
    var now: TimeInterval = 0
    private(set) var deadline: TimeInterval?
    private(set) var active = false
    private var callbacks: [@Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void] = []
    var registrations: Int { callbacks.count }
    func register(_ interval: TimeInterval, _ callback: @escaping @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void) -> BackgroundActivityRegistration {
        callbacks.append(callback)
        deadline = now + interval
        active = true
        return BackgroundActivityRegistration { self.active = false; self.deadline = nil }
    }
    func fire(_ index: Int) async -> NSBackgroundActivityScheduler.Result {
        let callback = callbacks[index]
        return await withCheckedContinuation { continuation in callback { continuation.resume(returning: $0) } }
    }
}
