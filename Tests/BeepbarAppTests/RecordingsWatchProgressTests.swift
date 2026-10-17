import AppKit
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// Holds the history actor's progress calls at chosen moments, so a test can act while a write is
/// queued (`before`) or has committed but not yet returned (`after`). `holdCall` limits the hold
/// to the n-th call (1-based), letting the others through: what proves the write chain's order.
@MainActor final class ProgressGates {
    var before: FakeRecmanBrowser.Gate?
    var after: FakeRecmanBrowser.Gate?
    /// Holds every `acknowledge` (the "new" dots being saved), so a test can choose the storage
    /// state that acknowledgement meets instead of racing it.
    var acknowledge: FakeRecmanBrowser.Gate?
    var holdCall: Int?
    private(set) var calls = 0
    func waitBefore() async {
        calls += 1
        if let holdCall, holdCall != calls { return }
        await before?.wait()
    }
    func waitAfter() async { await after?.wait() }
    func waitAcknowledge() async { await acknowledge?.wait() }
}

/// Makes the history folder unreachable while set: every store operation started meanwhile
/// throws, as a full or read-only disk would.
final class StorageFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    var isFailing: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
}

/// Watch progress in `RecordingsController` (package D of "recording view tracking"): ticks,
/// checkpoints, the done mark, the write chain, the menu summary and the account boundary. Each
/// test runs the real controller against the real SQLite history in a throwaway folder, a fake
/// browser and a fake player (`FakeRecordingPlayer`: 6000 s lectures, `tick(at:)` reaches
/// `onProgress` only), and says what it proves and which mutation turns it red.
@MainActor
struct RecordingsWatchProgressTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-progress-\(UUID().uuidString)", isDirectory: true)
    private let defaults = MemoryCountingDefaults.isolated()
    private let browser = FakeRecmanBrowser()
    private let world = RecordingsWorld()
    private let gates = ProgressGates()
    private let fault = StorageFault()
    private let probe = RecordingsSeenStore.Probe()
    private let course = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!

    private func makeController() -> RecordingsController {
        if defaults.object(forKey: RecordingsController.enabledKey) == nil {
            defaults.set(false, forKey: RecordingsController.enabledKey)
            defaults.resetWrites()
        }
        let world = world
        let browser = browser
        let gates = gates
        let fault = fault
        let probe = probe
        let folder = folder
        return RecordingsController(
            makeBrowser: { world.browsersMade += 1; return browser },
            store: RecordingsSessionStore { folder },
            defaults: defaults,
            makeSeenHistory: { namespace in
                let storage = RecordingsSeenStore(directory: {
                    if fault.isFailing { throw CocoaError(.fileWriteNoPermission) }
                    return folder
                }, namespace: namespace, removeFile: { try FileManager.default.removeItem(at: $0) }, probe: probe)
                let history = RecordingsSeenHistory(store: storage, beforeAcknowledge: { await gates.waitAcknowledge() }, afterRead: { await world.waitAfterHistoryRead() }, beforeProgress: { await gates.waitBefore() }, afterProgress: { await gates.waitAfter() })
                world.historyActors.append(history)
                return history
            },
            ownerUserID: { world.owner },
            isAvailable: { world.polimi },
            openURL: { world.opened.append($0) },
            copy: { world.copied.append($0) },
            now: { MainActor.assumeIsolated { world.now } },
            makePlayer: { world.playersMade += 1; return world.player }
        )
    }

    private let other = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!

    /// A 90-minute lecture of `course` unless told otherwise; `duration: ""` is a row whose length
    /// the archive doesn't give.
    private func recording(_ id: String, daysAgo: Double = 1, in key: RecmanCourseKey? = nil, duration: String = "90 min") -> RecmanRecording {
        let key = key ?? course
        return RecmanRecording(id: id, courseCode: key.courseCode, academicYear: key.academicYear, title: "Lezione \(id)", recordedAt: world.now.addingTimeInterval(-daysAgo * 86_400), kind: "Lezione", duration: duration, size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link&transfer_id=\(id)")!)
    }

    private func stream(_ id: String, duration: TimeInterval? = 6_000) -> RecordingStream {
        RecordingStream(url: URL(string: "https://nfg1wss.webex.com/nbr/\(id)/hls.m3u8")!, title: nil, duration: duration)
    }

    private func identity(_ id: String) -> String { RecordingsStudyState.identity(recording(id)) }

    private func settle(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("never happened: \(comment)", sourceLocation: sourceLocation)
    }

    private func drainTasks() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<50 { await Task.yield() }
    }

    /// Signed in, page shown, `ids` listed (all seen: the first listing is the baseline).
    private func listedController(_ ids: [String] = ["a", "b"]) async -> RecordingsController {
        let controller = makeController()
        controller.setEnabled(true)
        await settle("sign-in finished") { controller.access == .ready && !browser.isOpen }
        controller.pageAppeared()
        browser.listResults[course.courseCode] = .success(ids.map { recording($0) })
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        return controller
    }

    private func play(_ id: String, on controller: RecordingsController, _ played: RecmanRecording? = nil, streamDuration: TimeInterval? = 6_000) async {
        let before = world.player.plays.count
        browser.streamResults[id, default: []].append(.success(stream(id, duration: streamDuration)))
        controller.play(played ?? recording(id))
        await settle("\(id) playing") { world.player.plays.count == before + 1 }
    }

    /// Stores a resume position for `id` as an earlier launch would have.
    private func storeResumePoint(_ id: String, at position: TimeInterval) throws {
        var points = RecordingResumePoints(owner: 42)
        points.apply(.remember(position), for: identity(id))
        defaults.set(try PropertyListEncoder().encode(points), forKey: RecordingsController.resumePointsKey)
    }

    /// What the history file holds for `id` under `owner`, read through a separate connection to
    /// the controller's current namespace.
    private func storedEntry(_ id: String, owner: Int = 42) throws -> RecordingWatchEntry? {
        let namespace = defaults.string(forKey: RecordingsController.historyNamespaceKey).flatMap(UUID.init(uuidString:))
        let folder = folder
        let store = RecordingsSeenStore(directory: { folder }, namespace: namespace)
        return try store.seenAndProgress(owner: owner, key: course, ids: [id], establishBaseline: false, legacy: .init(ids: [], baselines: [])).progress[id]
    }

    private var summaryWrites: Int { defaults.writes.filter { $0 == RecordingsController.watchSummaryKey }.count }

    private func cleanUp() {
        gates.before?.release()
        gates.after?.release()
        fault.isFailing = false
        let actors = world.historyActors
        actors.forEach { $0.invalidate() }
        let folder = folder
        Task {
            for history in actors { try? await history.invalidateAndDelete() }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func bulkAction(_ controller: RecordingsController, recordings: [RecmanRecording]? = nil, canEdit: Bool? = nil) -> RecordingsPresentation.BulkAction {
        RecordingsPresentation.WatchValues(controller.watchProgress, canEdit: canEdit ?? controller.canEditProgress)
            .bulkAction(for: course, recordings: recordings ?? controller.listing(for: course)?.recordings)
    }

    /// The full listing toggles together, including rows hidden by a search, and another course
    /// is untouched. Mutations: save the first row only, or refresh the summary per row.
    @Test func bulkCompletionUsesFullListingAndOneSummary() async throws {
        defer { cleanUp() }
        let controller = await listedController(["a", "b", "c"])
        controller.setDone(recording("outside", in: other), true)
        await controller.settleWatchProgress()
        #expect(RecordingsPresentation.matches(recording("a"), query: "Lezione a"))
        #expect(!RecordingsPresentation.matches(recording("b"), query: "Lezione a"))
        defaults.resetWrites()
        controller.toggleAllDone(course)
        await controller.settleWatchProgress()
        for id in ["a", "b", "c"] {
            #expect(try storedEntry(id)?.completed == .manual)
        }
        #expect(summaryWrites == 1)
        #expect(controller.watchSummaries[course]?.done == 3)
        #expect(bulkAction(controller).allDone)
        #expect(bulkAction(controller).label.italian == "Segna tutte come non viste")
        #expect(bulkAction(controller).label.english == "Mark all as unseen")
        controller.toggleAllDone(course)
        await controller.settleWatchProgress()
        for id in ["a", "b", "c"] {
            #expect(try storedEntry(id)?.completed == nil)
            #expect(try storedEntry(id)?.autoCompletionBlocked == true)
        }
        #expect(controller.watchProgress.isCompleted(recording("outside", in: other)))
        #expect(!bulkAction(controller).allDone)
        #expect(bulkAction(controller).label.italian == "Segna tutte come completate")
        #expect(bulkAction(controller).label.english == "Mark all as completed")
        controller.turnOff()
    }

    /// Until commit, every checkbox keeps its old value and stays locked for the whole batch.
    /// Repeated bulk clicks and individual edits cannot enqueue extra writes. Page closing
    /// preserves this explicit action. Mutations: optimistic entries or clearing pending early.
    @Test func bulkPendingValuesStayCommittedAcrossPageClose() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        gates.holdCall = 2
        controller.toggleAllDone(course)
        await settle("second bulk write held") { gate.isWaiting }
        #expect(gates.calls == 2)
        #expect(controller.watchProgress.entries.values.filter(\.isCompleted).count == 1)
        #expect(controller.watchProgress.pending == Set([identity("a"), identity("b")]))
        #expect(!bulkAction(controller).enabled)
        controller.toggleAllDone(course)
        controller.setDone(recording("a"), false)
        controller.pageDisappeared()
        gate.release()
        await controller.settleWatchProgress()
        #expect(gates.calls == 2, "one chain, no duplicate bulk or per-row write")
        #expect(controller.watchProgress.pending.isEmpty)
        #expect(controller.watchProgress.pendingCourses.isEmpty)
        #expect(controller.watchProgress.isCompleted(recording("a")))
        #expect(controller.watchProgress.isCompleted(recording("b")))
        controller.turnOff()
    }

    /// Empty, unread and uneditable listings cannot authorize overwriting unknown history;
    /// a course lock survives replacing its visible list. Mutation: ignore any bulk guard.
    @Test func bulkAvailabilityRequiresKnownEditableUnblockedListing() async {
        defer { cleanUp() }
        let controller = await listedController()
        #expect(bulkAction(controller).enabled)
        #expect(!bulkAction(controller, recordings: []).enabled)
        #expect(!bulkAction(controller, recordings: [recording("unknown")]).enabled)
        #expect(!bulkAction(controller, canEdit: false).enabled)
        controller.toggleAllDone(other)
        #expect(controller.watchProgress.pending.isEmpty)
        controller.watchProgress.setPending(true, for: Set([identity("a")]), course: course)
        #expect(!bulkAction(controller, recordings: [recording("b")]).enabled)
        controller.watchProgress.setPending(false, for: Set([identity("a")]), course: course)
        controller.watchProgress.setPending(true, for: identity("b"))
        #expect(!bulkAction(controller).enabled)
        controller.watchProgress.setPending(false, for: identity("b"))
        controller.turnOff()
    }

    /// A storage failure releases all controls without inventing done values; retry succeeds.
    /// Mutation: publish before applying progress, omit pending cleanup or the history banner.
    @Test func bulkFailureKeepsValuesAndAllowsRetry() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        fault.isFailing = true
        controller.toggleAllDone(course)
        await controller.settleWatchProgress()
        #expect(controller.listing(for: course)?.problem == .historyUnavailable)
        #expect(controller.watchProgress.entries.isEmpty)
        #expect(controller.watchProgress.pending.isEmpty)
        #expect(controller.watchProgress.pendingCourses.isEmpty)
        #expect(bulkAction(controller).enabled)
        #expect(gates.calls == 1, "stop a failing batch instead of retrying every remaining row")
        fault.isFailing = false
        controller.toggleAllDone(course)
        await controller.settleWatchProgress()
        #expect(controller.watchSummaries[course]?.done == 2)
        controller.turnOff()
    }

    /// Partial commits remain real, and their acknowledgement succeeding afterwards cannot erase
    /// the banner of the save that failed later in the same batch. Two new rows guarantee that a
    /// new row is among the committed ones whatever the listing order, so an acknowledgement
    /// really runs; its gate makes it run with storage healthy again, after the failure.
    /// Mutation: drop `preserveHistoryProblem` (the acknowledgement clears the banner).
    @Test func bulkPartialFailureKeepsCommittedRowsAndError() async throws {
        defer { cleanUp() }
        let controller = await listedController(["a"])
        browser.listResults[course.courseCode] = .success([recording("a"), recording("b", daysAgo: 0), recording("c", daysAgo: 0)])
        controller.refresh([course], selected: course, force: true)
        await settle("new rows listed") { controller.newCount(for: course) == 2 }
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        gates.holdCall = 3
        let acknowledge = FakeRecmanBrowser.Gate()
        gates.acknowledge = acknowledge
        controller.toggleAllDone(course)
        await settle("third bulk save held") { gate.isWaiting }
        fault.isFailing = true
        gate.release()
        await controller.settleWatchProgress()
        await settle("acknowledgement queued") { acknowledge.isWaiting }
        fault.isFailing = false
        acknowledge.release()
        await settle("committed new row acknowledged") { controller.newCount(for: course) == 1 }
        await drainTasks()
        #expect(controller.watchProgress.entries.values.filter(\.isCompleted).count == 2)
        #expect(controller.watchSummaries[course]?.done == 2)
        #expect(controller.listing(for: course)?.problem == .historyUnavailable)
        #expect(controller.watchProgress.pending.isEmpty)
        controller.turnOff()
    }

    /// A bulk untick that fails midway leaves the first row unticked and the second still done,
    /// so the label follows the saved state back to "Mark all as completed", as the spec says.
    /// Guards a label stuck on "unseen" (or computed from what was requested) after a failure.
    @Test func bulkUntickFailureLabelFollowsSavedState() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        controller.toggleAllDone(course)
        await controller.settleWatchProgress()
        #expect(bulkAction(controller).allDone)
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        gates.holdCall = gates.calls + 2
        controller.toggleAllDone(course)
        await settle("second untick held") { gate.isWaiting }
        fault.isFailing = true
        gate.release()
        await controller.settleWatchProgress()
        fault.isFailing = false
        #expect(controller.watchProgress.entries.values.filter(\.isCompleted).count == 1)
        #expect(controller.listing(for: course)?.problem == .historyUnavailable)
        let action = bulkAction(controller)
        #expect(!action.allDone)
        #expect(action.enabled)
        #expect(action.label.english == "Mark all as completed")
        controller.turnOff()
    }

    /// Unchecking every row resets a crossing at click time and preserves furthest/resume
    /// positions; closing the player behind the queued batch cannot complete it again.
    /// Mutations: skip resetting live crossings or untick epochs in the bulk action.
    @Test func bulkUntickPreservesPositionAndDoesNotRestoreNewDots() async throws {
        defer { cleanUp() }
        let controller = await listedController(["a"])
        browser.listResults[course.courseCode] = .success([recording("a"), recording("b", daysAgo: 0)])
        controller.refresh([course], selected: course, force: true)
        await settle("new row listed") { controller.newCount(for: course) == 1 }
        controller.toggleAllDone(course)
        await controller.settleWatchProgress()
        await settle("acknowledged") { controller.newCount(for: course) == 0 }
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        controller.toggleAllDone(course)
        await settle("untick held") { gate.isWaiting }
        world.player.close()
        gate.release()
        await controller.settleWatchProgress()
        let entry = try #require(try storedEntry("a"))
        #expect(entry.furthest == 0.95)
        #expect(entry.completed == nil)
        #expect(entry.autoCompletionBlocked)
        #expect(controller.newCount(for: course) == 0)
        let resume = try #require(defaults.data(forKey: RecordingsController.resumePointsKey))
        #expect(try PropertyListDecoder().decode(RecordingResumePoints.self, from: resume).position(for: identity("a")) == 5_700)
        controller.turnOff()
    }

    /// The bulk un-tick counts as a later un-tick for a close whose save failed before it: when
    /// that close is retried, it must not complete the lecture again. Same scenario as
    /// `aRetriedCloseCannotUndoALaterUnTick`, through the bulk command.
    /// Mutation: skip the `untickCounts` bump in `toggleAllDone` (the retry completes "a").
    @Test func bulkUntickWinsOverAnEarlierFailedClose() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        fault.isFailing = true
        world.player.close()
        await controller.settleWatchProgress()
        fault.isFailing = false
        controller.toggleAllDone(course)
        await controller.settleWatchProgress()
        #expect(bulkAction(controller).allDone)
        controller.toggleAllDone(course)
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == nil)

        await play("b", on: controller)
        world.player.pause(at: 600)
        await controller.settleWatchProgress()
        let entry = try #require(try storedEntry("a"))
        #expect(entry.completed == nil, "the old close was retried without its crossing")
        #expect(entry.autoCompletionBlocked)
        #expect(!controller.watchProgress.isCompleted(recording("a")))
        controller.turnOff()
    }

    /// An account/reset boundary invalidates the captured actor and stops the remaining batch;
    /// neither account sees stale values and the old batch's lock is gone. Mutation: drop the
    /// identity check inside the loop (the remaining row is saved under the new account).
    @Test(arguments: ["turn off", "account change"])
    func bulkCannotCrossIdentityBoundary(change: String) async throws {
        defer { cleanUp() }
        let controller = await listedController()
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        controller.toggleAllDone(course)
        await settle("bulk held") { gate.isWaiting }
        if change == "turn off" { controller.setEnabled(false) }
        else { world.owner = 7; controller.webBeepAccountChanged(to: 7) }
        gate.release()
        await controller.settleWatchProgress()
        #expect(controller.watchProgress.entries.isEmpty)
        #expect(controller.watchProgress.pending.isEmpty)
        #expect(controller.watchProgress.pendingCourses.isEmpty)
        #expect(try storedEntry("a", owner: 42) == nil)
        #expect(try storedEntry("b", owner: 42) == nil)
        #expect(try storedEntry("a", owner: 7) == nil)
        #expect(gates.calls == 1)
    }

    /// Signed in to Polimi while the WeBeep account was still unknown, so no session owner was
    /// saved: an account change then resets nothing and the bulk save simply stops. It must
    /// still release the course lock, or every checkbox and the button stay disabled until the
    /// next reset. Mutation: release the lock only on the success path (drop the `defer`).
    @Test func bulkStoppedByAnUnresetAccountChangeReleasesTheCourse() async throws {
        defer { cleanUp() }
        let controller = makeController()
        controller.setEnabled(true)
        // WeBeep's account goes unknown (offline) while the Polimi sign-in runs.
        world.owner = nil
        await settle("sign-in finished") { controller.access == .ready && !browser.isOpen }
        world.owner = 42
        controller.pageAppeared()
        browser.listResults[course.courseCode] = .success([recording("a"), recording("b")])
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(bulkAction(controller).enabled)
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        controller.toggleAllDone(course)
        await settle("bulk held") { gate.isWaiting }
        world.owner = 7
        controller.webBeepAccountChanged(to: 7)
        gate.release()
        await controller.settleWatchProgress()
        #expect(controller.watchProgress.pendingCourses.isEmpty)
        #expect(controller.watchProgress.pending.isEmpty)
        #expect(gates.calls == 1, "the rest of the batch never reaches the next account")
        controller.turnOff()
    }

    // MARK: Ticks

    /// A tick moves the window's bar and live summary and nothing else: no database transaction,
    /// no settings write, no change of the saved summary the menu shows.
    /// Guards against a tick being saved (disk at every 30 s) or reaching the menu.
    /// Mutations: enqueue a checkpoint from `playerProgress` (transactions > 0); drop
    /// `publishLive` from `playerProgress` (live stays at 0).
    @Test func ticksStayInMemory() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        var pushes = 0
        controller.onWatchSummaryChange = { _ in pushes += 1 }
        let savedSummary = controller.watchSummaries[course]
        await play("a", on: controller)
        await controller.settleWatchProgress()
        let transactions = probe.current.writeTransactions
        defaults.resetWrites()

        world.player.tick(at: 1_200)
        world.player.tick(at: 2_400)
        await drainTasks()
        await controller.settleWatchProgress()

        #expect(controller.watchProgress.live[identity("a")] == 0.4)
        #expect(controller.watchProgress.fraction(for: recording("a")) == 0.4)
        #expect(controller.watchProgress.summaries[course] == CourseWatchSummary(done: 0, total: 2, remainingMinutes: 144, unknownDurationCount: 0, next: recording("a")), "the window's summary follows the live position")
        #expect(probe.current.writeTransactions == transactions, "a tick opens no write transaction")
        #expect(defaults.writes.isEmpty, "a tick writes no setting")
        #expect(controller.watchSummaries[course] == savedSummary)
        #expect(pushes == 0, "the menu doesn't change on a tick")
        #expect(try storedEntry("a") == nil)
        controller.turnOff()
    }

    // MARK: Checkpoints

    /// One pause saves once and publishes the saved entry; the same pause again opens no write
    /// transaction; the saved summary is written once with it. Guards principle 4 (cost
    /// proportional to change) and a pause that is never saved.
    /// Mutations: don't enqueue the checkpoint in `recordWatchCheckpoint` (nothing stored);
    /// drop `setEntry` in `commitProgress` (the model stays empty).
    @Test func onePauseIsOneWriteAndTheSamePauseIsNone() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        await controller.settleWatchProgress()
        let transactions = probe.current.writeTransactions
        defaults.resetWrites()

        world.player.pause(at: 3_000)
        await controller.settleWatchProgress()
        #expect(probe.current.writeTransactions == transactions + 1)
        #expect(try storedEntry("a") == RecordingWatchEntry(furthest: 0.5))
        #expect(controller.watchProgress.entries[identity("a")] == RecordingWatchEntry(furthest: 0.5))
        #expect(summaryWrites == 1)

        world.player.pause(at: 3_000)
        await controller.settleWatchProgress()
        #expect(probe.current.writeTransactions == transactions + 1, "the same place again writes nothing")
        #expect(summaryWrites == 1, "an unchanged summary is not written again")
        controller.turnOff()
    }

    /// The position of a checkpoint counts even when no tick came before it (ticks stop at a pause
    /// and a seek may jump straight to the end): a close at 95 % completes the lecture.
    /// Mutation: skip `session.progress.observe` in `recordWatchCheckpoint` (furthest stays 0,
    /// nothing completes).
    @Test func theCheckpointItselfIsObserved() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.move(to: 5_700)
        world.player.close()
        await controller.settleWatchProgress()
        let entry = try #require(try storedEntry("a"))
        #expect(entry.furthest == 0.95)
        #expect(entry.completed == .playback)
        #expect(controller.watchProgress.live[identity("a")] == nil, "an ended session leaves no live value")
        controller.turnOff()
    }

    /// Pause, failure and quitting never complete, even at 95 %: only the end of the lecture does.
    /// Quitting is not on this path at all (nothing here is in `prepareForTermination`), so the
    /// last checkpoint before it is a pause. Mutation: make `.paused` close in the call to
    /// `checkpointCloses` (pass `.closed`) and the lecture completes.
    @Test func aPauseAtNinetyFivePercentDoesNotComplete() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        world.player.pause(at: 5_700)
        await controller.settleWatchProgress()
        #expect(try storedEntry("a") == RecordingWatchEntry(furthest: 0.95))
        #expect(controller.watchProgress.isCompleted(recording("a")) == false)
        controller.turnOff()
    }

    /// A stream dying at 95 % and recovered on a fresh stream of the same lecture is not an end:
    /// the replacement inside `play` names the same id. The lecture completes at the real close
    /// afterwards, because the session continued. Mutation: pass `nextID: nil` instead of
    /// `pendingPlayID` (the recovery completes the lecture).
    @Test func aRecoveryOfTheSameLectureIsNotAClose() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.player.tick(at: 5_700)
        world.player.failDuringPlayback(at: 5_700)
        await settle("recovered on a fresh stream") { world.player.plays.count == 2 }
        await controller.settleWatchProgress()
        #expect(try storedEntry("a") == RecordingWatchEntry(furthest: 0.95), "failure and recovery save the place without completing")
        world.player.close()
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == .playback)
        controller.turnOff()
    }

    /// Play pressed again on the lecture that is playing is not an end; Play on another lecture
    /// is, and completes the old one past 90 %. Mutations: `nextID: nil` (re-Play completes);
    /// `closes: false` for every replacement (the other lecture doesn't complete it).
    @Test func playAgainIsNotACloseButAnotherLectureIs() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        await play("a", on: controller)
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == nil, "Play again on the same lecture")
        await play("b", on: controller)
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == .playback, "replaced by another lecture")
        #expect(controller.watchProgress.isCompleted(recording("a")))
        controller.turnOff()
    }

    // MARK: Done mark

    /// Ticking a lecture saves it as done, shows it only once saved (pending meanwhile), and
    /// clears its "new" dot. Mutations: drop `scheduleAcknowledge` in `commitProgress` (the dot
    /// stays); set the entry before the write (it shows while still pending).
    @Test func tickingSavesThenShowsAndClearsTheNewDot() async throws {
        defer { cleanUp() }
        let controller = await listedController(["a"])
        browser.listResults[course.courseCode] = .success([recording("b", daysAgo: 0), recording("a")])
        controller.refresh([course], selected: course, force: true)
        await settle("b is new") { controller.newCount(for: course) == 1 }
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        controller.setDone(recording("b"), true)
        await settle("held") { gate.isWaiting }
        #expect(controller.watchProgress.isPending(recording("b")))
        #expect(!controller.watchProgress.isCompleted(recording("b")), "the committed value is shown while saving")
        gate.release()
        await controller.settleWatchProgress()
        #expect(!controller.watchProgress.isPending(recording("b")))
        #expect(controller.watchProgress.entry(for: recording("b")).completed == .manual)
        #expect(try storedEntry("b")?.completed == .manual)
        await settle("new dot cleared") { controller.newCount(for: course) == 0 }
        controller.turnOff()
    }

    /// A save that fails shows the history banner, leaves the saved value and lets the student
    /// try again. Mutation: drop the `problem = .historyUnavailable` (no banner) or the
    /// `setPending(false)` (the checkbox stays disabled) in the failure branch.
    @Test func aFailedTickSaysSoAndKeepsTheSavedValue() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        fault.isFailing = true
        controller.setDone(recording("a"), true)
        await controller.settleWatchProgress()
        #expect(controller.listing(for: course)?.problem == .historyUnavailable)
        #expect(!controller.watchProgress.isPending(recording("a")))
        #expect(!controller.watchProgress.isCompleted(recording("a")))
        fault.isFailing = false
        controller.setDone(recording("a"), true)
        await controller.settleWatchProgress()
        #expect(controller.watchProgress.isCompleted(recording("a")))
        controller.turnOff()
    }

    /// Un-ticking while the lecture plays past 90 % and then closing it doesn't undo the choice:
    /// the crossing seen before the un-tick is forgotten. Mutation: drop `resetCrossing()` in
    /// `setDone` (the close completes it again).
    @Test func unTickingWhilePlayingThenClosingDoesNotComplete() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        controller.setDone(recording("a"), true)
        await controller.settleWatchProgress()
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        controller.setDone(recording("a"), false)
        await controller.settleWatchProgress()
        world.player.close()
        await controller.settleWatchProgress()
        let entry = try #require(try storedEntry("a"))
        #expect(entry.completed == nil)
        #expect(entry.autoCompletionBlocked)
        #expect(entry.furthest == 0.95)
        controller.turnOff()
    }

    /// After an un-tick, reopening a lecture that resumes at 95 % and closing it doesn't complete
    /// it; seeking back below 90 %, then past it, then closing does (the ordered crossing).
    /// Mutation: start every session at 0 in `startWatchSession` instead of the resume point
    /// (the reopen counts as a crossing and completes).
    @Test func afterAnUnTickOnlyAFreshCrossingCompletes() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        world.player.close()
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == .playback)
        controller.setDone(recording("a"), false)
        await controller.settleWatchProgress()

        await play("a", on: controller)
        #expect(world.player.plays.last?.startAt == 5_700, "resumes where it was closed")
        world.player.close()
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == nil, "resumed past 90 % and closed: still un-ticked")

        await play("a", on: controller)
        world.player.tick(at: 3_000)
        world.player.tick(at: 5_700)
        world.player.close()
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == .playback, "below, above, close: done again")
        controller.turnOff()
    }

    /// Writes commit in the order they happened even when the first one is slow: an un-tick held
    /// at the store, then a crossing and a close. In order the close completes the un-ticked
    /// lecture (a fresh crossing); out of order the close would land on the done lecture and the
    /// un-tick would leave it not done. Mutation: start each write in its own task without
    /// awaiting `previous` in `enqueueProgress` (the close overtakes the held un-tick).
    @Test func writesCommitInOrder() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        controller.setDone(recording("a"), true)
        await controller.settleWatchProgress()
        await play("a", on: controller)
        await controller.settleWatchProgress()
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        gates.holdCall = gates.calls + 1
        controller.setDone(recording("a"), false)
        await settle("un-tick held") { gate.isWaiting }
        world.player.tick(at: 3_000)
        world.player.tick(at: 5_700)
        world.player.close()
        await drainTasks()
        gate.release()
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == .playback)
        #expect(controller.watchProgress.entry(for: recording("a")).completed == .playback)
        controller.turnOff()
    }

    // MARK: Failures

    /// A checkpoint that couldn't be saved is kept, without a banner, and saved before the next
    /// checkpoint, even of another lecture. Mutation: don't store it in `unsavedCheckpoints`
    /// (a stays unsaved).
    @Test func aFailedCheckpointIsRetriedAtTheNextOneWithoutABanner() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        fault.isFailing = true
        world.player.close()
        await controller.settleWatchProgress()
        #expect(controller.listing(for: course)?.problem == nil, "no banner for a background save")
        #expect(controller.watchProgress.entries[identity("a")] == nil)
        fault.isFailing = false
        await play("b", on: controller)
        world.player.pause(at: 600)
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == .playback)
        #expect(try storedEntry("b") == RecordingWatchEntry(furthest: 0.1))
        #expect(controller.watchProgress.isCompleted(recording("a")))
        controller.turnOff()
    }

    // MARK: Listing and snapshots

    /// A listing read that started before a commit and returns after it requeries instead of
    /// publishing its older progress. Mutation: drop the `historyRevision` bump in
    /// `commitProgress` (the old snapshot hides the saved 50 %).
    @Test func aStaleSnapshotNeverOverwritesACommit() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        let gate = FakeRecmanBrowser.Gate()
        world.historyAfterReadGate = gate
        controller.refresh([course], selected: course, force: true)
        await settle("old snapshot held") { gate.isWaiting }
        world.historyAfterReadGate = nil
        world.player.pause(at: 3_000)
        await settle("pause committed") { controller.watchProgress.entries[identity("a")] != nil }
        gate.release()
        await settle("refresh finished") { controller.listing(for: course)?.isLoading == false }
        #expect(controller.watchProgress.entries[identity("a")] == RecordingWatchEntry(furthest: 0.5))
        controller.turnOff()
    }

    /// After a relaunch the listing shows the stored percentage with no playback at all, and the
    /// saved summary is read back for the same account. Mutation: publish the listing without
    /// `setEntries` in `record` (the model is empty after the relaunch).
    @Test func aRelaunchShowsTheStoredPercentage() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.pause(at: 3_000)
        await controller.settleWatchProgress()
        let summary = controller.watchSummaries[course]

        let relaunched = makeController()
        relaunched.pageAppeared()
        relaunched.refresh([course], selected: course)
        await settle("listed after relaunch") { relaunched.listing(for: course)?.recordings != nil }
        #expect(relaunched.watchProgress.fraction(for: recording("a")) == 0.5)
        // The saved form: an unchanged listing keeps the decoded copy instead of rewriting it
        // (#189), so the relaunched `next` lacks the date, kind and size.
        #expect(relaunched.watchSummaries[course].map { StoredCourseWatchSummary($0).persisted } == summary.map { StoredCourseWatchSummary($0).persisted })
        let saved = try #require(RecordingsController.storedWatchSummaries(in: defaults, owner: 42)?[course])
        #expect(saved.done == summary?.done && saved.total == summary?.total)
        #expect(saved.remainingMinutes == summary?.remainingMinutes && saved.unknownDurationCount == summary?.unknownDurationCount)
        #expect(saved.next?.id == summary?.next?.id && saved.newCount == summary?.newCount)
        controller.turnOff()
    }

    // MARK: Summary

    /// The saved summary is written when a listing first gives it a value and when a commit
    /// changes it; never for an unchanged refresh or a tick; and it goes with the session. The
    /// menu is told exactly as often. Mutation: drop the `watchSummaries[key] != summary` guard
    /// in `storeWatchSummary` (the unchanged refresh writes again).
    @Test func theSummaryIsWrittenOnlyWhenItChanges() async throws {
        defer { cleanUp() }
        var pushed: [[RecmanCourseKey: CourseWatchSummary]] = []
        let controller = makeController()
        controller.onWatchSummaryChange = { pushed.append($0) }
        controller.setEnabled(true)
        await settle("sign-in finished") { controller.access == .ready && !browser.isOpen }
        controller.pageAppeared()
        browser.listResults[course.courseCode] = .success([recording("a"), recording("b")])
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(summaryWrites == 1)
        #expect(pushed == [[course: CourseWatchSummary(done: 0, total: 2, remainingMinutes: 180, unknownDurationCount: 0, next: recording("a"))]])

        controller.refresh([course], selected: course, force: true)
        await settle("refreshed") { controller.listing(for: course)?.isLoading == false }
        await drainTasks()
        #expect(summaryWrites == 1, "an unchanged listing writes nothing")

        await play("a", on: controller)
        world.player.tick(at: 3_000)
        #expect(summaryWrites == 1, "a tick writes nothing")
        world.player.pause(at: 3_000)
        await controller.settleWatchProgress()
        #expect(summaryWrites == 2)
        #expect(pushed.last == [course: CourseWatchSummary(done: 0, total: 2, remainingMinutes: 135, unknownDurationCount: 0, next: recording("a"))])
        #expect(pushed.count == 2)

        controller.turnOff()
        #expect(defaults.object(forKey: RecordingsController.watchSummaryKey) == nil)
        #expect(pushed.last == [:], "the menu forgets it too")
    }

    /// Saved summaries of another account are neither read nor kept: the static helpers work
    /// without a controller, for a launch where the account changed before Recordings was used.
    /// The stored form is numbers only, so a language switch rebuilds the text from them in
    /// either language. Mutation: drop `stored.owner == owner` in `storedWatchSummaries` or in
    /// `forgetWatchSummary`.
    @Test func anotherAccountsSummaryIsDroppedWithoutAController() throws {
        let summary = CourseWatchSummary(done: 12, total: 30, remainingMinutes: 840, unknownDurationCount: 0)
        let stored = RecordingsController.StoredWatchSummaries(owner: 42, courses: ["058167-2026": summary])
        defaults.set(try PropertyListEncoder().encode(stored), forKey: RecordingsController.watchSummaryKey)
        #expect(RecordingsController.storedWatchSummaries(in: defaults, owner: 42) == [course: summary])
        #expect(RecordingsController.storedWatchSummaries(in: defaults, owner: 7) == nil)
        let line = RecordingWatchProgress.menuLine(courseName: "Analisi 2", try #require(RecordingsController.storedWatchSummaries(in: defaults, owner: 42)?[course]))
        #expect(line.italian == "Analisi 2 — 12/30 · ~14 h")
        #expect(line.english == "Analisi 2 — 12/30 · ~14 h")
        RecordingsController.forgetWatchSummary(in: defaults, notOwnedBy: 42)
        #expect(defaults.object(forKey: RecordingsController.watchSummaryKey) != nil, "this account's stays")
        RecordingsController.forgetWatchSummary(in: defaults, notOwnedBy: 7)
        #expect(defaults.object(forKey: RecordingsController.watchSummaryKey) == nil)
        defaults.set(Data([1, 2, 3]), forKey: RecordingsController.watchSummaryKey)
        RecordingsController.forgetWatchSummary(in: defaults, notOwnedBy: 42)
        #expect(defaults.object(forKey: RecordingsController.watchSummaryKey) == nil, "unreadable data goes")
    }

    // MARK: Account boundary

    /// Turn-off or an account change while a pause is still being saved: the window's progress,
    /// the sessions and the saved summary go at once, later ticks are ignored, the held write is
    /// refused (no row in the new namespace for either account) and nothing is published when it
    /// returns. Mutations: drop `watchProgress.reset()` or the summary removal in `forgetSeen`;
    /// drop the `nowPlaying` guard in `playerProgress` (the late tick shows).
    @Test(arguments: ["turn off", "account change"])
    func anIdentityChangeMidPlaybackLeavesNothing(change: String) async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 1_200)
        await controller.settleWatchProgress()
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        world.player.pause(at: 3_000)
        await settle("pause held") { gate.isWaiting }

        if change == "turn off" {
            controller.setEnabled(false)
        } else {
            world.owner = 7
            controller.webBeepAccountChanged(to: 7)
        }
        #expect(controller.watchProgress.entries.isEmpty)
        #expect(controller.watchProgress.live.isEmpty)
        #expect(controller.watchProgress.summaries.isEmpty)
        #expect(controller.watchProgress.known.isEmpty, "nothing of the old account counts as known")
        #expect(controller.watchSummaries.isEmpty)
        #expect(defaults.object(forKey: RecordingsController.watchSummaryKey) == nil)
        world.player.tick(at: 4_000)
        #expect(controller.watchProgress.live.isEmpty, "a tick after the change is ignored")

        gate.release()
        await drainTasks()
        await controller.settleWatchProgress()
        #expect(controller.watchProgress.entries.isEmpty, "the held write is not published")
        #expect(try storedEntry("a", owner: 42) == nil)
        #expect(try storedEntry("a", owner: 7) == nil)
    }

    /// A write that committed while the account went away is never shown, and its error (a
    /// cancellation) raises no banner on the new account's listing. Mutation: publish before the
    /// identity check in `commitProgress` and treat `CancellationError` like a failure (the entry
    /// or the banner appears).
    @Test func aLateCommitAfterAResetIsNeverShown() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        let gate = FakeRecmanBrowser.Gate()
        gates.after = gate
        controller.setDone(recording("a"), true)
        await settle("tick committed and held") { gate.isWaiting }
        controller.setEnabled(false)
        controller.setEnabled(true)
        await settle("signed in again") { controller.access == .ready }
        controller.refresh([course], selected: course, force: true)
        await settle("listed again") { controller.listing(for: course)?.recordings != nil && controller.listing(for: course)?.isLoading == false }
        gates.after = nil
        gate.release()
        await drainTasks()
        #expect(!controller.watchProgress.isCompleted(recording("a")))
        #expect(!controller.watchProgress.isPending(recording("a")))
        #expect(controller.listing(for: course)?.problem == nil)
        #expect(try storedEntry("a") == nil, "the new namespace has no row")
        controller.turnOff()
    }

    // MARK: Review fixes

    /// P1-a: a close at 95 % whose save failed, retried after the student ticked and then
    /// un-ticked the lecture, must not complete it again: the un-tick came later and wins.
    /// Mutation: skip the crossing reset in `retryUnsavedCheckpoints` (the retry completes it).
    @Test func aRetriedCloseCannotUndoALaterUnTick() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        fault.isFailing = true
        world.player.close()
        await controller.settleWatchProgress()
        fault.isFailing = false
        controller.setDone(recording("a"), true)
        await controller.settleWatchProgress()
        controller.setDone(recording("a"), false)
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == nil)

        await play("b", on: controller)
        world.player.pause(at: 600)
        await controller.settleWatchProgress()
        let entry = try #require(try storedEntry("a"))
        #expect(entry.completed == nil, "the old close was retried without its crossing")
        #expect(entry.autoCompletionBlocked)
        #expect(entry.furthest == 0.95, "its furthest point is still saved")
        #expect(!controller.watchProgress.isCompleted(recording("a")))
    }

    /// The other side of P1-a: an un-tick that came *before* the session's crossing must not
    /// neutralise it. Un-ticked earlier, played below then past 90 %, closed: the close fails and
    /// its retry still completes the lecture, since the crossing is fresh. Mutation: queue fresh
    /// checkpoints with `untickEpoch: 0` in `recordWatchCheckpoint` (the retry looks overtaken
    /// by the old un-tick, loses its crossing and the lecture stays not done).
    @Test func aRetriedFreshCrossingAfterAnEarlierUnTickStillCompletes() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        controller.setDone(recording("a"), true)
        await controller.settleWatchProgress()
        controller.setDone(recording("a"), false)
        await controller.settleWatchProgress()
        await play("a", on: controller)
        world.player.tick(at: 3_000)
        world.player.tick(at: 5_700)
        fault.isFailing = true
        world.player.close()
        await controller.settleWatchProgress()
        fault.isFailing = false
        #expect(try storedEntry("a")?.completed == nil, "the close wasn't saved yet")

        await play("b", on: controller)
        world.player.pause(at: 600)
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.completed == .playback, "the retried fresh crossing completes it")
        #expect(controller.watchProgress.isCompleted(recording("a")))
        controller.turnOff()
    }

    /// P1-b: with no listing loaded (a Watchlist row after a relaunch, offline), a tick on a
    /// lecture already done in the store changes nothing there, yet the row must learn it is done
    /// and become un-tickable; before any read the row is unknown, not "0 %, not done".
    /// Mutations: publish only when `result.changed` in `commitProgress` (the row stays not
    /// done); don't mark the identity known in `setEntry` or `setEntries`.
    @Test func anUnchangedCommitStillTeachesTheModel() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        #expect(controller.watchProgress.isKnown(recording("b")), "a listed, untouched lecture is known")
        controller.setDone(recording("a"), true)
        await controller.settleWatchProgress()

        let relaunched = makeController()
        #expect(!relaunched.watchProgress.isKnown(recording("a")), "nothing read yet: unknown")
        relaunched.setDone(recording("a"), true)
        await relaunched.settleWatchProgress()
        #expect(relaunched.watchProgress.isKnown(recording("a")))
        #expect(relaunched.watchProgress.isCompleted(recording("a")), "the stored done mark is shown")
        relaunched.setDone(recording("a"), false)
        await relaunched.settleWatchProgress()
        #expect(!relaunched.watchProgress.isCompleted(recording("a")), "and can be un-ticked")
        #expect(try storedEntry("a")?.completed == nil)
    }

    /// Completing by playback (not only by a tick) clears the "new" dot, even when the dot
    /// survived the Play because that acknowledgement failed. Mutation: drop the
    /// `scheduleAcknowledge` in `commitProgress` (the dot stays).
    @Test func completingByPlaybackClearsTheNewDot() async throws {
        defer { cleanUp() }
        let controller = await listedController(["a"])
        browser.listResults[course.courseCode] = .success([recording("b", daysAgo: 0), recording("a")])
        controller.refresh([course], selected: course, force: true)
        await settle("b is new") { controller.newCount(for: course) == 1 }
        fault.isFailing = true
        await play("b", on: controller)
        await settle("the Play's acknowledgement failed") { controller.listing(for: course)?.problem == .historyUnavailable }
        fault.isFailing = false
        #expect(controller.newCount(for: course) == 1)
        world.player.tick(at: 5_700)
        world.player.close()
        await controller.settleWatchProgress()
        #expect(try storedEntry("b")?.completed == .playback)
        await settle("new dot cleared by the completion") { controller.newCount(for: course) == 0 }
        controller.turnOff()
    }

    /// A failed checkpoint from before a turn-off is not retried after turning on again for the
    /// same account: it belonged to the forgotten history. Mutation: don't empty
    /// `unsavedCheckpoints` in `forgetSeen` (the old close lands in the new namespace).
    @Test func failedCheckpointsAreForgottenWithTheHistory() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 5_700)
        fault.isFailing = true
        world.player.close()
        await controller.settleWatchProgress()
        fault.isFailing = false
        controller.setEnabled(false)
        controller.setEnabled(true)
        await settle("signed in again") { controller.access == .ready }
        await play("b", on: controller)
        world.player.pause(at: 600)
        await controller.settleWatchProgress()
        #expect(try storedEntry("b") == RecordingWatchEntry(furthest: 0.1))
        #expect(try storedEntry("a") == nil, "nothing of the old history in the new namespace")
        controller.turnOff()
    }

    /// A write queued before a reset goes to the history it was queued for, which refuses it,
    /// never to the history of the reset that came in between. Mutation: read `seenHistory` when
    /// the write runs instead of when it is queued (the second pause lands in the new namespace).
    @Test func aQueuedWriteNeverReachesTheNextHistory() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        await controller.settleWatchProgress()
        let gate = FakeRecmanBrowser.Gate()
        gates.before = gate
        gates.holdCall = gates.calls + 1
        world.player.pause(at: 3_000)
        await settle("first pause held") { gate.isWaiting }
        world.player.tick(at: 4_000)
        world.player.pause(at: 4_000)
        controller.setEnabled(false)
        controller.setEnabled(true)
        await settle("signed in again") { controller.access == .ready }
        gate.release()
        await drainTasks()
        await drainTasks()
        #expect(try storedEntry("a") == nil)
        #expect(controller.watchProgress.entries.isEmpty)
        controller.turnOff()
    }

    /// The saved summaries are read before the first change of a launch, so updating one course
    /// keeps the others. Mutation: skip loading `storedWatchSummaries` in `storeWatchSummary`
    /// (the relaunch's first listing drops the other course).
    @Test func theFirstChangeAfterARelaunchKeepsOtherCourses() async throws {
        defer { cleanUp() }
        let controller = makeController()
        controller.setEnabled(true)
        await settle("sign-in finished") { controller.access == .ready && !browser.isOpen }
        controller.pageAppeared()
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.listResults[other.courseCode] = .success([recording("x", in: other)])
        controller.refresh([course, other], selected: course)
        await settle("both listed") { controller.listing(for: course)?.recordings != nil && controller.listing(for: other)?.recordings != nil }
        #expect(controller.watchSummaries.count == 2)

        let relaunched = makeController()
        relaunched.pageAppeared()
        browser.listResults[course.courseCode] = .success([recording("a"), recording("b", daysAgo: 0)])
        relaunched.refresh([course], selected: course)
        await settle("listed after relaunch") { relaunched.listing(for: course)?.recordings?.count == 2 }
        let stored = try #require(RecordingsController.storedWatchSummaries(in: defaults, owner: 42))
        #expect(stored[course]?.total == 2, "the changed course is saved")
        let retained = try #require(stored[other])
        #expect(retained.done == 0 && retained.total == 1 && retained.remainingMinutes == 90 && retained.unknownDurationCount == 0, "the other course is kept")
        #expect(retained.next?.id == "x" && retained.next?.courseCode == other.courseCode && retained.next?.academicYear == other.academicYear)
        controller.turnOff()
    }

    /// The saved summary is computed from saved entries only: a commit while a lecture is
    /// playing ahead of its saved point saves the summary without that live position, which only
    /// the window shows. Mutation: pass `live` to the persisted `courseSummary` in
    /// `refreshWatchSummary` (the saved remaining time is 45 instead of 90).
    @Test func theSavedSummaryIgnoresTheLivePosition() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        await play("a", on: controller)
        world.player.tick(at: 3_000)
        controller.setDone(recording("b"), true)
        await controller.settleWatchProgress()
        #expect(controller.watchSummaries[course] == CourseWatchSummary(done: 1, total: 2, remainingMinutes: 90, unknownDurationCount: 0, next: recording("a")))
        #expect(controller.watchProgress.summaries[course] == CourseWatchSummary(done: 1, total: 2, remainingMinutes: 45, unknownDurationCount: 0, next: recording("a")))
        controller.turnOff()
    }

    /// A lecture closed before it was ready reports nothing; its session ends when another
    /// lecture plays, so a later Play of it starts a fresh session. Here the first session saw
    /// 0 % and the second, of unknown start, only 95 %: continued, they'd be a crossing that
    /// completes the un-ticked lecture. Mutation: drop the pruning loop in `startWatchSession`.
    @Test func aLectureClosedBeforeReadyLeavesNoSessionBehind() async throws {
        defer { cleanUp() }
        let unknown = recording("u", duration: "")
        let controller = await listedController(["u", "b"])
        controller.setDone(unknown, true)
        await controller.settleWatchProgress()
        controller.setDone(unknown, false)
        await controller.settleWatchProgress()
        await play("u", on: controller, unknown)
        world.player.closeBeforeReady()
        await play("b", on: controller)
        world.player.closeBeforeReady()
        await play("u", on: controller, unknown, streamDuration: nil)
        world.player.tick(at: 5_700)
        world.player.close()
        await controller.settleWatchProgress()
        #expect(try storedEntry("u")?.completed == nil)
        #expect(try storedEntry("u")?.furthest == 0.95)
        controller.turnOff()
    }

    /// A stream that never starts ends its session at once (the player closed without a report),
    /// so a later Play of the same lecture doesn't continue it. Same crossing setup as above.
    /// Mutation: drop `endWatchSessionBeforeReady` in `playerFailed`.
    @Test func aStreamThatNeverStartsEndsItsSession() async throws {
        defer { cleanUp() }
        let unknown = recording("u", duration: "")
        let controller = await listedController(["u", "b"])
        controller.setDone(unknown, true)
        await controller.settleWatchProgress()
        controller.setDone(unknown, false)
        await controller.settleWatchProgress()
        await play("u", on: controller, unknown)
        world.player.failBeforeReady()
        await play("u", on: controller, unknown, streamDuration: nil)
        world.player.tick(at: 5_700)
        world.player.close()
        await controller.settleWatchProgress()
        #expect(try storedEntry("u")?.completed == nil)
        controller.turnOff()
    }

    /// Where a lecture starts is not shown as progress until the player reports it: a stream that
    /// never becomes ready would otherwise leave a percentage nobody saved on the row. Mutation:
    /// call `publishLive` at the end of `startWatchSession` (the row shows 50 %).
    @Test func theStartAloneShowsNothing() async throws {
        defer { cleanUp() }
        try storeResumePoint("a", at: 3_000)
        let controller = await listedController()
        await play("a", on: controller)
        #expect(world.player.plays.last?.startAt == 3_000)
        #expect(controller.watchProgress.live.isEmpty)
        #expect(controller.watchProgress.fraction(for: recording("a")) == 0)
        controller.turnOff()
    }

    /// The stream's own length is preferred over the archive's minutes for where a session
    /// starts (the archive rounds; here 90 min against a 100-minute stream). Mutation: pass nil
    /// as `streamDuration` to `startWatchSession` (the start reads as 100 %).
    @Test func theStreamLengthIsUsedForTheStart() async throws {
        defer { cleanUp() }
        try storeResumePoint("a", at: 5_700)
        let controller = await listedController()
        await play("a", on: controller)
        world.player.close()
        await controller.settleWatchProgress()
        #expect(try storedEntry("a")?.furthest == 0.95)
        controller.turnOff()
    }

    /// The WeBeep account can change without a reset (no saved Polimi session to drop): a write
    /// that commits afterwards is not shown, which only the controller's post-commit identity
    /// check guarantees (the store's namespace is still valid). Mutation: drop the
    /// `guard isCurrentIdentity` after `applyProgress` in `commitProgress`.
    @Test func aCommitForAnAccountNoLongerConnectedIsNotShown() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        let gate = FakeRecmanBrowser.Gate()
        gates.after = gate
        controller.setDone(recording("a"), true)
        await settle("committed and held") { gate.isWaiting }
        world.owner = 7
        gates.after = nil
        gate.release()
        await controller.settleWatchProgress()
        #expect(!controller.watchProgress.isCompleted(recording("a")))
        world.owner = 42
        controller.turnOff()
    }

    /// Under a disk that keeps failing, only the most recent `maxUnsavedCheckpoints` sessions are
    /// kept for a retry. Mutation: drop the trimming loop in `commitProgress` (the oldest
    /// lecture is saved too).
    @Test func failedCheckpointsAreCapped() async throws {
        defer { cleanUp() }
        let controller = await listedController()
        let count = RecordingsController.maxUnsavedCheckpoints + 1
        fault.isFailing = true
        for index in 1...count {
            await play("r\(index)", on: controller)
            world.player.tick(at: 600)
            world.player.close()
            await controller.settleWatchProgress()
        }
        fault.isFailing = false
        await play("b", on: controller)
        world.player.pause(at: 600)
        await controller.settleWatchProgress()
        #expect(try storedEntry("r1") == nil, "the oldest one was dropped")
        #expect(try storedEntry("r2") != nil)
        #expect(try storedEntry("r\(count)") != nil)
        controller.turnOff()
    }
}
