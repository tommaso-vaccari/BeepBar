import Foundation
import os
import Testing
@testable import BeepbarCore
@testable import BeepbarApp

/// The Recordings refresh that follows a materials sync (package C of "refresh recordings at every
/// sync"): when it starts, where it sits relative to the scheduler and to "Esci", and that it never
/// touches the materials result. The refresh itself is a fake behind `recordingsRefresh`, so no
/// WebKit is involved. Each test says what it proves and which mutation turns it red.
@MainActor struct RecordingsSyncFollowUpTests {
    private static let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!

    /// Waits until `gate` has a waiter, at most 45 s: a bound against a hang, not a time the test
    /// asserts. When it runs out, records `event` as the missing signal and returns false; the
    /// caller then releases its gates and awaits its tasks so the test ends.
    private static func waitUntilWaiting(_ gate: FakeRecmanBrowser.Gate, _ event: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(45)
        while !gate.isWaiting {
            if ContinuousClock.now >= deadline {
                Issue.record("\(event)")
                return false
            }
            await Task.yield()
        }
        return true
    }

    // MARK: The gate: nothing is created for a skipped follow-up

    /// Proves that with the Recordings switch off, or on a non-Polimi site, an automatic sync and a
    /// manual one never call the refresh and never create `RecordingsController` (so no WebKit, no
    /// session read). Guards against the follow-up building the controller "just to ask it".
    @Test(arguments: [false, true])
    func switchOffOrAnotherUniversityStartsNothing(otherUniversity: Bool) async throws {
        let harness = try await Harness(site: otherUniversity ? MoodleSite.all.first { $0.university == .unipd }! : .polimi, switchedOn: otherUniversity)
        defer { harness.remove() }

        await harness.controller.runAutomaticSyncForTesting()
        harness.controller.synchronizeNow()
        await harness.settle()

        #expect(harness.seam.calls.isEmpty)
        #expect(harness.controller.recordingsIfCreated == nil)
        #expect(harness.controller.recordingsFollowUpForTesting == nil)
    }

    // MARK: Placement

    /// Proves the order of an automatic run: the materials state is already `.synced` while the
    /// refresh is gated, and the scheduler's completion is delivered only after the refresh ends
    /// (the system activity covers it, within the default hold); the refresh respects the freshness
    /// window (`force: false`) and gets the course's key. Guards against starting it after
    /// `completion` (the activity would end under it), awaiting it before the materials result, or
    /// forcing automatic runs.
    @Test func anAutomaticRunFollowsUpBeforeTheSchedulerCompletes() async throws {
        let schedule = TestSchedule()
        let harness = try await Harness(schedule: schedule)
        defer { harness.remove() }
        let gate = FakeRecmanBrowser.Gate()
        harness.seam.gate = gate
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let fired = Task { @MainActor in
            let result = await schedule.fire(0)
            log.withLock { $0.append("completion") }
            return result
        }

        guard await Self.waitUntilWaiting(gate, "the refresh did not reach its gate") else {
            gate.release(); _ = await fired.value
            return
        }
        guard case .synced = harness.controller.syncState else {
            Issue.record("Expected the materials result, got \(harness.controller.syncState)")
            gate.release(); _ = await fired.value
            return
        }
        #expect(log.withLock { $0.isEmpty }, "the scheduler completed while the refresh was still running")
        #expect(harness.seam.calls.count == 1)
        #expect(harness.seam.calls.first?.keys == [Self.key])
        #expect(harness.seam.calls.first?.force == false)
        log.withLock { $0.append("released") }
        gate.release()
        #expect(await fired.value == .finished)
        #expect(log.withLock { $0 } == ["released", "completion"])
        #expect(harness.controller.lastRecordingsOutcome == .refreshed(newlyPublished: 0, failedKeys: 0))
    }

    /// Proves that the scheduler's completion is delivered once the hold runs out even though the
    /// follow-up is still blocked (as behind a Play waiting for a Webex sign-in), that the
    /// follow-up keeps going and still publishes its result afterwards, and that an automatic run
    /// fired meanwhile starts no second refresh. Guards against awaiting the follow-up without a
    /// bound (#187): `completion` never called, so no automatic sync was ever scheduled again.
    /// The follow-up stays on its gate until the end, so `completion` arriving at all can only
    /// come from the hold running out (200 ms is the behavior under test, not a bound in the
    /// assertion); a watchdog releases the gate and records a failure if completion stalls.
    @Test(.timeLimit(.minutes(2))) func theSchedulerCompletesWhileTheFollowUpIsStillBlocked() async throws {
        let schedule = TestSchedule()
        let harness = try await Harness(schedule: schedule)
        defer { harness.remove() }
        harness.controller.setFollowUpActivityHoldForTesting(.milliseconds(200))
        let gate = FakeRecmanBrowser.Gate()
        harness.seam.gate = gate
        let fired = Task { @MainActor in await schedule.fire(0) }
        let started = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if await gate.isWaiting { return true }
                    await Task.yield()
                }
                return false
            }
            group.addTask { do { try await Task.sleep(for: .seconds(45)) } catch { return false }; return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard started else {
            fired.cancel()
            gate.release()
            Issue.record("follow-up did not reach the gate")
            return
        }
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            gate.release()
            return true
        }
        #expect(await fired.value == .finished)
        #expect(gate.isWaiting, "the follow-up must still be blocked when completion arrives")
        let followUp = try #require(harness.controller.recordingsFollowUpForTesting, "the follow-up was dropped at the hold")
        #expect(harness.controller.lastRecordingsOutcome == nil)

        // The next automatic run, while the first follow-up is still blocked.
        #expect(await schedule.fire(0) == .finished)
        #expect(gate.isWaiting, "the follow-up must still be blocked after the second completion")
        watchdog.cancel()
        #expect(await watchdog.value == false, "scheduler waited for the follow-up")
        #expect(harness.seam.calls.count == 1)

        gate.release()
        await followUp.value
        #expect(harness.controller.lastRecordingsOutcome == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(harness.seam.calls.count == 1)
    }

    /// Proves that a manual sync starts its follow-up with `force: true` after the list is loaded
    /// from an empty one ("Sincronizza ora" right after launch): the keys come from the freshly
    /// loaded `courses`. Guards against reading the keys before the list is loaded, or against
    /// manual syncs respecting the 300 s window.
    @Test func aManualSyncWithAnEmptyListLoadsItThenFollowsUpForced() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        harness.controller.forgetCourseListForTesting()
        #expect(harness.controller.courses.isEmpty)

        harness.controller.synchronizeNow()
        guard await harness.waitForCalls(1) else {
            await harness.cleanUpFailedWait()
            return
        }

        #expect(harness.seam.calls.first?.force == true)
        #expect(harness.seam.calls.first?.keys == [Self.key])
        #expect(!harness.controller.courses.isEmpty)
    }

    /// Proves that a second "Sincronizza ora" while the follow-up is still running does not start
    /// another refresh, and that the extra sync is not held back by it. Guards against two WebKit
    /// listing runs at once (one browser, one page operation at a time).
    @Test(.timeLimit(.minutes(2))) func aSecondManualSyncMergesWithTheRunningFollowUp() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        harness.seam.gate = gate
        harness.controller.synchronizeNow()
        let started = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if await gate.isWaiting { return true }
                    await Task.yield()
                }
                return false
            }
            group.addTask { do { try await Task.sleep(for: .seconds(45)) } catch { return false }; return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard started else {
            gate.release()
            harness.controller.cancelSynchronization()
            await harness.controller.waitForSyncForTesting()
            Issue.record("follow-up did not reach the gate")
            return
        }
        let first = try #require(harness.controller.recordingsFollowUpForTesting)

        harness.controller.synchronizeNow()
        #expect(harness.controller.isSyncActive, "the second sync did not start")
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            gate.release()
            return true
        }
        await harness.controller.waitForSyncForTesting()
        #expect(gate.isWaiting, "the follow-up must still be blocked")
        watchdog.cancel()
        #expect(await watchdog.value == false, "second sync did not finish")

        #expect(harness.seam.calls.count == 1)
        #expect(!harness.controller.isSyncActive, "the follow-up held the second sync")
        if case .synced = harness.controller.syncState {} else {
            Issue.record("Expected the second materials sync to finish, got \(harness.controller.syncState)")
        }
        #expect(harness.controller.recordingsFollowUpForTesting == first)
        gate.release()
        await first.value
        #expect(harness.seam.calls.count == 1)
    }

    // MARK: Independence from the materials result

    @Test func overlappingNotificationTailsPreserveBothRunFollowUps() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let gates = [FakeRecmanBrowser.Gate(), FakeRecmanBrowser.Gate()]
        var notifications = 0
        harness.controller.setBeforeNotificationForTesting {
            let gate = gates[notifications]
            notifications += 1
            await gate.wait()
        }
        let summary = SyncProgress(completed: 0, total: 0, added: 0, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        let firstID = UUID()
        harness.controller.setOperationForTesting(firstID)
        let first = Task { @MainActor in
            await harness.controller.completeSyncForTesting(firstID, summary: summary)
            await harness.controller.startFollowUpForTesting(firstID, trigger: .manual)?.value
        }
        guard await Self.waitUntilWaiting(gates[0], "the first notification did not reach its gate") else {
            gates.forEach { $0.release() }
            await first.value
            return
        }
        #expect(!harness.controller.isSyncActive)
        let secondID = UUID()
        harness.controller.setOperationForTesting(secondID)
        let second = Task { @MainActor in
            await harness.controller.completeSyncForTesting(secondID, summary: summary)
            await harness.controller.startFollowUpForTesting(secondID, trigger: .manual)?.value
        }
        guard await Self.waitUntilWaiting(gates[1], "the second notification did not reach its gate") else {
            gates.forEach { $0.release() }
            await first.value
            await second.value
            return
        }

        gates[0].release()
        await first.value
        #expect(harness.seam.calls.count == 1)
        gates[1].release()
        await second.value
        #expect(harness.seam.calls.count == 2)
        #expect(harness.seam.calls.allSatisfy { $0.keys == [Self.key] && $0.force })
    }

    @Test func changingTheRootWhileNotificationWaitsRetiresTheOldRunFollowUp() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let gate = FakeRecmanBrowser.Gate()
        harness.controller.setBeforeNotificationForTesting { await gate.wait() }
        let operationID = UUID()
        harness.controller.setOperationForTesting(operationID)
        let completed = Task { @MainActor in
            await harness.controller.completeSyncForTesting(operationID, summary: SyncProgress(completed: 0, total: 0, added: 0, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0))
            await harness.controller.startFollowUpForTesting(operationID, trigger: .manual)?.value
        }
        guard await Self.waitUntilWaiting(gate, "the notification did not reach its gate") else {
            gate.release()
            await completed.value
            return
        }
        let newRoot = harness.root.appending(path: "new-root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        await harness.controller.useRootForTesting(newRoot)
        #expect(harness.controller.rootURL == newRoot)
        #expect(harness.controller.enabledCourseIDs == [1])

        gate.release()
        await completed.value
        #expect(harness.seam.calls.isEmpty)
        #expect(harness.controller.lastRecordingsOutcome == nil)
    }

    /// Proves that a refresh ending `.unavailable`, `.needsSignIn` or `.cancelled` with nothing
    /// newly published leaves the materials state and the notifications exactly as a refresh that
    /// skipped would. Guards against the follow-up reporting its trouble through `setSyncState` or
    /// a failure notification.
    @Test(arguments: [RecordingsSyncOutcome.unavailable(newlyPublished: 0), .needsSignIn(newlyPublished: 0), .cancelled])
    func aRecordingsFailureLeavesTheSyncStateAndNotificationsAlone(_ outcome: RecordingsSyncOutcome) async throws {
        let baseline = try await Harness()
        defer { baseline.remove() }
        baseline.seam.result = .skipped(.noCourses)
        await baseline.controller.runAutomaticSyncForTesting()
        let expectedSent = baseline.center.sent

        let harness = try await Harness()
        defer { harness.remove() }
        harness.seam.result = outcome
        await harness.controller.runAutomaticSyncForTesting()

        #expect(harness.seam.calls.count == 1)
        guard case .synced = harness.controller.syncState, case .synced = baseline.controller.syncState else {
            Issue.record("Expected both runs to end synced, got \(harness.controller.syncState)")
            return
        }
        // The identifiers carry a random run id: what must match is what was sent, not its id.
        #expect(harness.center.sent.map { $0.prefix(17) } == expectedSent.map { $0.prefix(17) })
        #expect(!harness.center.sent.isEmpty)
        #expect(harness.controller.lastRecordingsOutcome == outcome)
    }

    /// Proves that a refresh cut short after publishing new lectures still announces them through
    /// the follow-up, and only them: one "new recordings" notification on top of what a skipped
    /// refresh sends (issue #190). Mutation: make `count(for:)` return nil for the early endings.
    @Test(arguments: [RecordingsSyncOutcome.unavailable(newlyPublished: 2), .needsSignIn(newlyPublished: 2)])
    func aRefreshCutShortStillAnnouncesWhatItPublished(_ outcome: RecordingsSyncOutcome) async throws {
        let baseline = try await Harness()
        defer { baseline.remove() }
        baseline.seam.result = .skipped(.noCourses)
        await baseline.controller.runAutomaticSyncForTesting()

        let harness = try await Harness()
        defer { harness.remove() }
        harness.seam.result = outcome
        await harness.controller.runAutomaticSyncForTesting()
        #expect(harness.center.sent.filter { $0 == "beepbar-new-recordings" }.count == 1)
        #expect(harness.center.sent.count == baseline.center.sent.count + 1)
    }

    /// Proves the follow-up decision after a failed materials run: a WeBeep service failure still
    /// refreshes (Recman is another service), a connectivity failure and an expired sign-in do
    /// not. Guards against mapping every failure to "skip" (or none).
    @Test(arguments: [
        (WeBeepAPIError.transport(503), true),
        (.invalidResponse, true),
        (.network(.offline), false),
        (.invalidToken, false),
    ])
    func serviceFailuresRefreshButConnectivityDoesNot(_ error: WeBeepAPIError, _ refreshes: Bool) async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let operationID = UUID()
        harness.controller.setOperationForTesting(operationID)
        await harness.controller.failSyncForTesting(operationID, error: error, automatic: false)
        let followUp = harness.controller.startFollowUpForTesting(operationID, trigger: .manual)

        await followUp?.value
        #expect((followUp != nil) == refreshes)
        #expect(harness.seam.calls.count == (refreshes ? 1 : 0))
    }

    /// Proves that a sync cancelled by the student starts no follow-up. Guards against mapping
    /// `cancelledSync` to a finished run.
    @Test func cancellingTheMaterialsRunStartsNoFollowUp() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        harness.controller.synchronizeNow()
        harness.controller.cancelSynchronization()
        await harness.settle()

        #expect(harness.seam.calls.isEmpty)
        #expect(harness.controller.recordingsFollowUpForTesting == nil)
    }

    // MARK: Low power and Data Saver

    /// Proves that Low Power Mode, a Data Saver pause at the start and a Data Saver pause midway
    /// never reach the refresh. Guards against the follow-up ignoring the gating of the run that
    /// triggered it.
    @Test(arguments: ["lowPower", "pausedAtStart", "pausedMidway"])
    func deferredAndPausedRunsNeverRefresh(_ scenario: String) async throws {
        let harness = try await Harness(networks: scenario == "pausedMidway" ? [.unrestricted, .hotspot] : [.hotspot], lowPowerMode: scenario == "lowPower")
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)
        if scenario == "pausedMidway" { MoodleRecordingProtocol.setOnHotspot(token: harness.token, true) }

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(outcome == .deferred)
        #expect(harness.seam.calls.isEmpty)
    }

    /// Proves that with Data Saver on, the network is read again when the follow-up is about to
    /// start: a Mac that moved to a hotspot during the run skips the refresh, an ordinary network
    /// runs it. Guards against reusing the network read at the start of the run.
    @Test(arguments: [(NetworkPathConditions.hotspot, false), (.lowDataMode, false), (.unrestricted, true)])
    func dataSaverRereadsTheNetworkWhenTheFollowUpStarts(_ later: NetworkPathConditions, _ refreshes: Bool) async throws {
        let harness = try await Harness(networks: [.unrestricted, later])
        defer { harness.remove() }
        harness.controller.setDataSaver(enabled: true)

        let outcome = await harness.controller.runAutomaticSyncForTesting()

        #expect(outcome == .finished)
        guard case .synced = harness.controller.syncState else {
            Issue.record("Expected the materials run to finish synced, got \(harness.controller.syncState)")
            return
        }
        #expect(harness.networkReads == 2)
        #expect(harness.seam.calls.count == (refreshes ? 1 : 0))
    }

    // MARK: Cancellation and quit

    /// Proves, through the real scheduler callback, that turning automatic sync off while the
    /// follow-up of an automatic run is still inside the system activity cancels the refresh and
    /// delivers `completion`. The hold is 90 seconds and the refresh
    /// ends only when cancelled, so `completion` arriving at all proves the cancellation ended the
    /// hold and reached the refresh (`sawCancellation`); no elapsed-time bound decides it. Guards
    /// against the callback task having no handle (#188): before, nothing in the app could cancel
    /// it, and this test cancelled a task of its own instead, proving a path the app never took.
    @Test(.timeLimit(.minutes(2))) func cancellingAnAutomaticRunStopsTheFollowUp() async throws {
        let schedule = TestSchedule()
        let harness = try await Harness(schedule: schedule)
        defer { harness.remove() }
        harness.controller.setFollowUpActivityHoldForTesting(Self.fallbackTimeout)
        harness.seam.honorsCancellation = true
        let fired = Task { @MainActor in await schedule.fire(0) }
        guard await harness.waitForCalls(1) else {
            await harness.cleanUpFailedWait()
            _ = await fired.value
            return
        }

        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            return true
        }
        harness.controller.setAutomaticSync(enabled: false)
        let result = await fired.value
        watchdog.cancel()
        #expect(await watchdog.value == false, "automatic completion did not follow cancellation")

        // The materials run had already finished: cancelling the follow-up doesn't rewrite that.
        #expect(result == .finished)
        // The refresh sees the cancellation as it unwinds, a moment after `completion`.
        await harness.waitForCancellation()
        #expect(harness.seam.sawCancellation)
        guard case .synced = harness.controller.syncState else {
            Issue.record("Expected the materials result to stay, got \(harness.controller.syncState)")
            return
        }
    }

    /// Proves that dropping the schedule (here: automatic sync turned off) while an automatic run
    /// holds a follow-up that "Sincronizza ora" started does not stop the user's refresh, and
    /// still delivers `completion`. The hold is 90 seconds, so `completion` arriving while the manual
    /// refresh is still running (not cancelled, not finished) can only be the cancellation ending
    /// the hold; a stalled hold triggers the watchdog. Guards
    /// against the automatic run's cancellation handler cancelling whatever follow-up it merged
    /// into (RB-001 of #188). `isCancelled` is set synchronously by the cancellation and the
    /// handler runs before `completion`, so reading it right after `completion` is exact, with
    /// no wait for the refresh to notice.
    @Test(.timeLimit(.minutes(2))) func droppingTheScheduleKeepsAManualRefreshTheAutomaticRunJoined() async throws {
        let schedule = TestSchedule(observeDeferral: true)
        let harness = try await Harness(schedule: schedule)
        defer { harness.remove() }
        harness.controller.setFollowUpActivityHoldForTesting(Self.fallbackTimeout)
        harness.seam.honorsCancellation = true
        harness.controller.synchronizeNow()
        await harness.controller.waitForSyncForTesting()
        guard await harness.waitForCalls(1) else {
            await harness.cleanUpFailedWait()
            return
        }
        let manual = try #require(harness.controller.recordingsFollowUpForTesting)

        let fired = Task { @MainActor in await schedule.fire(0) }
        let events = schedule.deferralEvents
        let reached = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events { return true }
                return false
            }
            group.addTask { do { try await Task.sleep(for: .seconds(45)) } catch { return false }; return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard reached else {
            fired.cancel()
            manual.cancel()
            // Both tasks end before the fixture is removed, so nothing writes into a deleted folder.
            _ = await fired.value
            await manual.value
            Issue.record("automatic run did not reach follow-up decision")
            return
        }
        #expect(harness.seam.calls.count == 1, "the automatic run started a refresh of its own")
        #expect(harness.controller.recordingsFollowUpForTesting == manual)

        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            return true
        }
        harness.controller.setAutomaticSync(enabled: false)
        #expect(await fired.value == .finished)
        watchdog.cancel()
        #expect(await watchdog.value == false, "automatic completion did not follow cancellation")
        #expect(!manual.isCancelled, "the manual refresh was cancelled with the schedule")
        #expect(harness.controller.recordingsFollowUpForTesting == manual, "the manual refresh was no longer running when completion arrived")
        manual.cancel()
        await manual.value
    }

    /// The other order: an automatic run's follow-up is held when "Sincronizza ora" merges into
    /// it, then the schedule is dropped. The refresh the user's sync now relies on keeps running.
    /// Guards against deciding from who created the follow-up alone (RB-001 of #188). As above:
    /// the hold is 90 seconds, so `completion` arriving while the refresh still runs and is not
    /// cancelled proves the cancellation ended the hold (RB-102 of #225: a hold waiting out its
    /// whole length), with no elapsed-time bound.
    @Test(.timeLimit(.minutes(2))) func droppingTheScheduleKeepsAnAutomaticRefreshAManualSyncJoined() async throws {
        let schedule = TestSchedule()
        let harness = try await Harness(schedule: schedule)
        defer { harness.remove() }
        harness.controller.setFollowUpActivityHoldForTesting(Self.fallbackTimeout)
        harness.seam.honorsCancellation = true
        let fired = Task { @MainActor in await schedule.fire(0) }
        guard await harness.waitForCalls(1) else {
            await harness.cleanUpFailedWait()
            _ = await fired.value
            return
        }
        let followUp = try #require(harness.controller.recordingsFollowUpForTesting)
        harness.controller.synchronizeNow()
        await harness.controller.waitForSyncForTesting()
        #expect(harness.seam.calls.count == 1)

        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            return true
        }
        harness.controller.setAutomaticSync(enabled: false)
        #expect(await fired.value == .finished)
        watchdog.cancel()
        #expect(await watchdog.value == false, "automatic completion did not follow cancellation")
        #expect(!followUp.isCancelled, "the refresh a manual sync joined was cancelled with the schedule")
        #expect(harness.controller.recordingsFollowUpForTesting == followUp, "the refresh was no longer running when completion arrived")
        followUp.cancel()
        await followUp.value
    }

    /// A follow-up the dropped schedule already cancelled but that has not finished unwinding (its
    /// refresh ignores cancellation for a while, as a WebKit listing can) must not take in a
    /// "Sincronizza ora": the user's sync would end with no refresh at all. Proves the manual
    /// sync starts a refresh of its own. Guards against the merge branch of
    /// `startRecordingsFollowUp` returning a cancelled task (RB-104 of #225). The hold is 90 seconds,
    /// so `completion` arriving while the refresh is still held on its gate comes from the
    /// cancellation, not from the hold running out.
    @Test(.timeLimit(.minutes(2))) func aManualSyncDoesNotMergeIntoAFollowUpTheDroppedScheduleCancelled() async throws {
        let schedule = TestSchedule()
        let harness = try await Harness(schedule: schedule)
        defer { harness.remove() }
        harness.controller.setFollowUpActivityHoldForTesting(Self.fallbackTimeout)
        let gate = FakeRecmanBrowser.Gate()
        harness.seam.gate = gate
        let fired = Task { @MainActor in await schedule.fire(0) }
        guard await harness.waitForCalls(1) else {
            await harness.cleanUpFailedWait()
            _ = await fired.value
            return
        }
        let cancelled = try #require(harness.controller.recordingsFollowUpForTesting)

        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            gate.release()
            return true
        }
        harness.controller.setAutomaticSync(enabled: false)
        #expect(await fired.value == .finished)
        watchdog.cancel()
        #expect(await watchdog.value == false, "automatic completion did not follow cancellation")
        #expect(cancelled.isCancelled, "no manual sync relied on it, so the schedule stopped it")
        #expect(harness.controller.recordingsFollowUpForTesting == cancelled, "it is still unwinding")

        harness.controller.synchronizeNow()
        guard await harness.waitForCalls(2) else {
            await harness.cleanUpFailedWait()
            await cancelled.value
            return
        }
        #expect(harness.seam.calls.count == 2, "the manual sync got no refresh of its own")
        #expect(harness.seam.calls.last?.force == true)
        let fresh = try #require(harness.controller.recordingsFollowUpForTesting)
        #expect(fresh != cancelled)

        gate.release()
        await cancelled.value
        await fresh.value
        #expect(harness.controller.recordingsFollowUpForTesting == nil)
    }

    /// A finite fallback beyond the watchdog bounds a hold if cancellation is broken (#243).
    private static let fallbackTimeout = Duration.seconds(90)

    /// Proves that when the system asks background work to defer (`shouldDefer`), an automatic
    /// run still finishes its materials but starts no recordings refresh. Guards against ignoring
    /// the scheduler's request (#188): the WebKit listings ran under thermal or battery pressure.
    @Test func aSchedulerAskingToDeferSkipsTheFollowUp() async throws {
        let schedule = TestSchedule()
        schedule.defers.withLock { $0 = true }
        let harness = try await Harness(schedule: schedule)
        defer { harness.remove() }

        #expect(await schedule.fire(0) == .finished)
        await harness.settle()

        guard case .synced = harness.controller.syncState else {
            Issue.record("Expected the materials run to finish synced, got \(harness.controller.syncState)")
            return
        }
        #expect(harness.seam.calls.isEmpty)
        #expect(harness.controller.recordingsFollowUpForTesting == nil)
    }

    /// Proves that "Esci" with a follow-up running does not wait for it and does not get it from
    /// `prepareForTermination`. Guards against the quit-path hang (AGENTS.md): a WebKit listing
    /// inside `syncTask` or returned for waiting would hold every quit. The quit's own wait
    /// bound is longer than the watchdog; a stalled quit releases the follow-up and fails.
    @Test(.timeLimit(.minutes(2))) func menuQuitDoesNotWaitForTheFollowUp() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let gate = FakeRecmanBrowser.Gate()
        harness.seam.gate = gate
        harness.controller.synchronizeNow()
        guard await harness.waitForCalls(1) else {
            await harness.cleanUpFailedWait()
            return
        }
        #expect(harness.controller.recordingsFollowUpForTesting != nil)

        #expect(harness.controller.prepareForTermination() == nil)
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return false }
            gate.release()
            return true
        }
        #expect(await harness.controller.prepareForMenuQuit(timeout: Self.fallbackTimeout))
        watchdog.cancel()
        #expect(await watchdog.value == false, "quit waited for the follow-up")
        #expect(harness.controller.menuQuitDrained)
        gate.release()
    }

    /// Proves that a run ending after the app started quitting starts no recordings listing. A quit
    /// from outside waits for `syncTask`, which can still finish successfully; a follow-up started
    /// then would create WebKit work on the way out. Fails if `startRecordingsFollowUp` loses its
    /// `isTerminating` guard (release review I-C1).
    @Test func aRunEndingWhileQuittingStartsNoFollowUp() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        #expect(harness.controller.prepareForTermination() == nil)
        harness.controller.synchronizeNow()
        await harness.settle()
        #expect(harness.controller.recordingsFollowUpForTesting == nil)
        #expect(harness.seam.calls.isEmpty)
    }

    /// Proves that a sign-out (the list is forgotten) while the follow-up runs cancels it and its
    /// result is never published. Guards against a finished refresh of the previous account
    /// reporting itself.
    @Test func signingOutDropsTheRunningFollowUp() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let gate = FakeRecmanBrowser.Gate()
        harness.seam.gate = gate
        harness.controller.synchronizeNow()
        guard await harness.waitForCalls(1) else {
            await harness.cleanUpFailedWait()
            return
        }
        let followUp = harness.controller.recordingsFollowUpForTesting

        harness.controller.forgetCourseListForTesting()
        #expect(harness.controller.recordingsFollowUpForTesting == nil)
        gate.release()
        await followUp?.value

        #expect(harness.controller.lastRecordingsOutcome == nil)
    }

    // MARK: Menu lines without a window

    /// Proves that an automatic run in a launch where `courses` was never loaded still gives the
    /// menu its recordings lines (from `lastRunCourses`), identical to the lines drawn with the
    /// list loaded. Guards against the pre-existing gap (summaries seeded, no lines) and against
    /// `lastRunCourses` changing the lines of a window that did load the list.
    @Test func aWindowLessAutomaticRunProducesTheMenuLines() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let summary = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 45, unknownDurationCount: 0)
        harness.controller.setWatchSummariesForTesting([Self.key: summary])
        let withList = harness.controller.recordingMenuLines
        #expect(!withList.isEmpty)

        harness.controller.forgetCourseListForTesting()
        harness.controller.setWatchSummariesForTesting([Self.key: summary])
        #expect(harness.controller.recordingMenuLines.isEmpty)
        await harness.controller.runAutomaticSyncForTesting()

        #expect(harness.controller.courses.isEmpty)
        #expect(harness.controller.recordingMenuLines == withList)
    }

    // MARK: The mapping table

    /// Proves every row of the mapping table in `RecordingsMaterialsOutcome`'s doc comment.
    /// Guards against any run ending being defaulted to "synced".
    @Test(arguments: [
        (MaterialsRunEnd.completed(conflicts: 1, failures: 2), RecordingsMaterialsOutcome.conflicts),
        (.completed(conflicts: 0, failures: 2), .partial),
        (.completed(conflicts: 0, failures: 0), .synced),
        (.pendingChoicesUnreadable, .localFailure),
        (.cancelled, .cancelled),
        (.serviceFailure(.transport(503)), .failed(.serviceUnavailable)),
        (.serviceFailure(.network(.offline)), .failed(.connectivity)),
        (.serviceFailure(.invalidToken), .failed(.authenticationExpired)),
        (.localFailure, .localFailure),
        (.pausedMidRun(.hotspot), .pausedByDataSaver(.hotspot)),
        (.notRun(.deferForLowPowerMode), .notRun(.deferForLowPowerMode)),
        (.notRun(.pause(.lowDataMode)), .notRun(.pause(.lowDataMode))),
        (.scheduleChanged, .cancelled),
        (.unconfigured, .notRun(.skipUnconfigured)),
        (.deferredWhileBusy, .notRun(.deferWhileBusy)),
        (.credentialUnavailable, .accountUnavailable),
    ])
    func everyRunEndingMapsToItsOutcome(_ end: MaterialsRunEnd, _ expected: RecordingsMaterialsOutcome) {
        #expect(WeBeepAuthenticationController.recordingsOutcome(for: end) == expected)
    }

    /// Proves that a superseded run maps to no outcome at all (the nil row of the table). Guards
    /// against a replaced operation starting a follow-up of its own.
    @Test func aSupersededRunHasNoOutcome() {
        #expect(WeBeepAuthenticationController.recordingsOutcome(for: .superseded) == nil)
    }

    /// Proves the ending paths record what the table says, and only for the active operation:
    /// `failedSync` with a WeBeep error, with none, and a run that is no longer active. Guards
    /// against a path forgetting to record (silently no follow-up) or a superseded one recording.
    @Test func endingPathsRecordTheirRunEnd() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let first = UUID()
        harness.controller.setOperationForTesting(first)
        await harness.controller.failSyncForTesting(first, error: .transport(503), automatic: false)
        #expect(harness.controller.takeRunEndForTesting(first) == .serviceFailure(.transport(503)))

        let second = UUID()
        harness.controller.setOperationForTesting(second)
        await harness.controller.failSyncForTesting(second, error: nil, automatic: false)
        #expect(harness.controller.takeRunEndForTesting(second) == .localFailure)

        let stale = UUID()
        await harness.controller.failSyncForTesting(stale, error: nil, automatic: false)
        #expect(harness.controller.takeRunEndForTesting(stale) == nil)
    }
}

// MARK: Harness

/// The fake behind `recordingsRefresh`: records each call, can wait on a gate, can honour
/// cancellation like the real refresh must.
@MainActor private final class RefreshSeam {
    var calls: [(keys: Set<RecmanCourseKey>, force: Bool)] = []
    let callEvents = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var result: RecordingsSyncOutcome = .refreshed(newlyPublished: 0, failedKeys: 0)
    var gate: FakeRecmanBrowser.Gate?
    var honorsCancellation = false
    private(set) var sawCancellation = false

    func refresh(_ keys: Set<RecmanCourseKey>, _ force: Bool) async -> RecordingsSyncOutcome {
        calls.append((keys, force))
        callEvents.continuation.yield(calls.count)
        if honorsCancellation {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            sawCancellation = true
            return .cancelled
        }
        if let gate { await gate.wait() }
        return result
    }
}

private final class RecordingCenter: NotificationCenterClient, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    var sent: [String] { state.withLock { $0 } }
    func authorization() async -> NotificationAuthorization { .allowed }
    func requestAuthorization() async {}
    func send(identifier: String, title: String, body: String, destination: NotificationDestination) async {
        state.withLock { $0.append(identifier) }
    }
}

private final class NetworkSequence: Sendable {
    private let state: OSAllocatedUnfairLock<(networks: [NetworkPathConditions?], reads: Int)>
    init(_ networks: [NetworkPathConditions?]) { state = OSAllocatedUnfairLock(initialState: (networks, 0)) }
    var reads: Int { state.withLock { $0.reads } }
    func next() async -> NetworkPathConditions? {
        state.withLock { state in
            state.reads += 1
            return state.networks.count > 1 ? state.networks.removeFirst() : state.networks.first ?? nil
        }
    }
}

/// A controller signed in to a local Moodle where course 1, "058167 - ANALISI 2 [2026-27]" (a
/// Recman key), is selected and lists `a.txt`, with the refresh seam faked and a recording
/// notification center.
@MainActor private struct Harness {
    let controller: WeBeepAuthenticationController
    let token: String
    let root: URL
    let seam = RefreshSeam()
    let center = RecordingCenter()
    let sequence: NetworkSequence

    init(networks: [NetworkPathConditions?] = [.unrestricted], lowPowerMode: Bool = false, schedule: TestSchedule? = nil, site: MoodleSite = .polimi, switchedOn: Bool = true) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 1, displayName: "Course", localFolder: "Course", enabled: true))
        let token = MoodleRecordingProtocol.register(courses: [(1, "058167 - ANALISI 2 [2026-27]")], files: [1: ["a.txt"]])
        self.token = token
        let sequence = NetworkSequence(networks)
        self.sequence = sequence
        let environment = AutomaticSyncEnvironment(isLowPowerModeEnabled: { lowPowerMode }, currentNetwork: { await sequence.next() })
        let stored = OSAllocatedUnfairLock(initialState: token)
        let vault = CredentialVault(read: { _ in stored.withLock { $0 } }, write: { renewed in stored.withLock { $0 = renewed } })
        let defaults = UserDefaults(suiteName: "recordings-sync-followup-\(UUID().uuidString)")!
        // The switch defaults to on; the "other university" case keeps it on too, so only the site decides.
        if !switchedOn { defaults.set(false, forKey: RecordingsController.enabledKey) }
        controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID, notificationCenter: center, apiClient: MoodleRecordingProtocol.makeClient(), downloader: MoodleRecordingProtocol.makeDownloader(), credentialVault: vault, deleteCredential: {}, defaults: defaults, automaticSyncEnvironment: environment, site: site)
        let seam = seam
        controller.recordingsRefresh = { keys, force in await seam.refresh(keys, force) }
        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        #expect(controller.courseLoadError == nil)
        if let schedule { controller.setBackgroundSchedulerForTesting { interval, callback in schedule.register(interval, callback) } }
        controller.setAutomaticSync(enabled: true)
    }

    var networkReads: Int { sequence.reads }

    /// Waits until the seam has been called `count` times.
    func waitForCalls(_ count: Int) async -> Bool {
        if seam.calls.count >= count { return true }
        let events = seam.callEvents.stream
        let reached = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await value in events where value >= count { return true }
                return false
            }
            group.addTask { do { try await Task.sleep(for: .seconds(45)) } catch { return false }; return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !reached { Issue.record("refresh did not reach call \(count)") }
        return reached
    }

    func cleanUpFailedWait() async {
        let initial = controller.recordingsFollowUpForTesting
        seam.gate?.release()
        controller.cancelSynchronization()
        await controller.waitForSyncForTesting()
        controller.setAutomaticSync(enabled: false)
        let later = controller.recordingsFollowUpForTesting
        initial?.cancel()
        later?.cancel()
        await initial?.value
        await later?.value
    }

    /// Waits for the refresh fake to observe cancellation, with a failure bound if it never does.
    func waitForCancellation() async {
        let deadline = ContinuousClock.now + .seconds(45)
        while !seam.sawCancellation {
            if ContinuousClock.now >= deadline {
                Issue.record("the refresh did not observe cancellation")
                return
            }
            await Task.yield()
        }
    }

    /// Lets a manual sync end and anything it would start get going, for "nothing happened" checks.
    func settle() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while controller.isSyncActive, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(100))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Deterministic registration of the scheduler callback.
@MainActor private final class TestSchedule {
    private var callbacks: [@Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void] = []
    let deferralEvents: AsyncStream<Void>
    private let deferralContinuation: AsyncStream<Void>.Continuation?

    init(observeDeferral: Bool = false) {
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        deferralEvents = events.stream
        deferralContinuation = observeDeferral ? events.continuation : nil
    }
    /// What the registration answers for `shouldDefer`.
    let defers = OSAllocatedUnfairLock(initialState: false)
    func register(_ interval: TimeInterval, _ callback: @escaping @Sendable (@escaping NSBackgroundActivityScheduler.CompletionHandler) -> Void) -> BackgroundActivityRegistration {
        callbacks.append(callback)
        let defers = defers
        let continuation = deferralContinuation
        return BackgroundActivityRegistration(invalidate: { }, shouldDefer: {
            continuation?.yield(())
            return defers.withLock { $0 }
        })
    }
    func fire(_ index: Int) async -> NSBackgroundActivityScheduler.Result {
        let callback = callbacks[index]
        return await withCheckedContinuation { continuation in callback { continuation.resume(returning: $0) } }
    }
}
