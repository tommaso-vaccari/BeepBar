import AppKit
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// `RecordingsController.refreshForSync`: the listings refresh a sync run asks for, against the
/// real controller, the real SQLite history in a throwaway folder and a scripted browser. Every
/// test says what it proves and the mutation that turns it red.
@MainActor
struct RecordingsSyncRefreshTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-sync-refresh-\(UUID().uuidString)", isDirectory: true)
    private let defaults = MemoryCountingDefaults.isolated()
    private let browser = FakeRecmanBrowser()
    private let world = RecordingsWorld()
    private let course = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private let other = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!
    private let third = RecmanCourseKey(courseCode: "099999", academicYear: 2026)!
    private var store: RecordingsSessionStore {
        let folder = folder
        return RecordingsSessionStore { folder }
    }
    private var sessionFile: URL { folder.appendingPathComponent(RecordingsSessionStore.fileName) }

    private func makeController() -> RecordingsController {
        let world = world
        let browser = browser
        let folder = folder
        return RecordingsController(
            makeBrowser: { world.browsersMade += 1; return browser },
            store: RecordingsSessionStore { folder },
            defaults: defaults,
            makeSeenHistory: { namespace in
                let history = RecordingsSeenHistory(store: RecordingsSeenStore(directory: { folder }, namespace: namespace))
                world.historyActors.append(history)
                return history
            },
            ownerUserID: { world.owner },
            isAvailable: { world.polimi },
            openURL: { world.opened.append($0) },
            copy: { world.copied.append($0) },
            now: { MainActor.assumeIsolated { world.now } },
            makePlayer: { world.playersMade += 1; return world.player },
            courses: { world.courses },
            bringPlayerForward: {}
        )
    }

    /// A launch with the feature on and a saved Polimi session, nothing checked or opened yet:
    /// the state a sync finds in a window-less launch.
    private func launched(withSession: Bool = true) throws -> RecordingsController {
        defaults.set(true, forKey: RecordingsController.enabledKey)
        if withSession {
            try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN", value: "saved")], ownerUserID: 42, now: world.now))
        }
        defaults.resetWrites()
        return makeController()
    }

    private func recording(_ id: String, _ key: RecmanCourseKey? = nil) -> RecmanRecording {
        let key = key ?? course
        return RecmanRecording(id: id, courseCode: key.courseCode, academicYear: key.academicYear, title: "Lezione \(id)", recordedAt: world.now.addingTimeInterval(-86_400), kind: "Lezione", duration: "90 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=1&transfer_id=\(id)")!)
    }

    private func list(_ ids: [String], for key: RecmanCourseKey? = nil) {
        let key = key ?? course
        browser.listResults[key.courseCode] = .success(ids.map { recording($0, key) })
    }

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

    private var summaryWrites: Int { defaults.writes.filter { $0 == RecordingsController.watchSummaryKey }.count }
    private func savedSummary(_ key: RecmanCourseKey? = nil) -> CourseWatchSummary? {
        RecordingsController.storedWatchSummaries(in: defaults, owner: 42)?[key ?? course]
    }
    private func sessionFileNumber() -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: sessionFile.path))?[.systemFileNumber] as? Int
    }

    private func cleanUp() {
        let actors = world.historyActors
        actors.forEach { $0.invalidate() }
        let folder = folder
        Task {
            for history in actors { try? await history.invalidateAndDelete() }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: The refresh itself

    /// A refresh with no Recordings page lists the course, publishes the listing with its seen
    /// state (the #106 baseline), then closes and releases the browser.
    /// Guards a sync refresh that needs the page to be shown, publishes nothing, or leaves the
    /// hidden browser open at rest. Mutations: drop `enqueueBackground`'s append (no list call,
    /// no listing); drop `closesBrowserWhenIdle = true` in `refreshForSync` (browser stays open).
    @Test func listsWithNoPagePublishesAndReleasesTheBrowser() async throws {
        defer { cleanUp() }
        let controller = try launched()
        list(["a", "b"])
        let outcome = await controller.refreshForSync([course], force: false)
        #expect(outcome == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(controller.listing(for: course)?.recordings?.map(\.id) == ["a", "b"])
        #expect(controller.listing(for: course)?.seenIDs == ["a", "b"], "the first complete listing is the baseline")
        #expect(browser.calls == ["open", "list 058167", "close"])
        #expect(!browser.isOpen)
        #expect(world.browsersMade == 1)
        #expect(controller.listing(for: course)?.isLoading == false)
    }

    /// Nothing to do costs nothing: switched off, no owner, no courses, a sign-in running or
    /// needed. Guards a refresh that reads the session file or creates a browser for nothing.
    /// Mutation: drop any one of the guards at the top of `refreshForSync` (that case reaches the
    /// file or the browser).
    @Test func zeroCostSkips() async throws {
        defer { cleanUp() }
        defaults.set(false, forKey: RecordingsController.enabledKey)
        let off = makeController()
        #expect(await off.refreshForSync([course], force: true) == .skipped(.switchedOff))

        let controller = try launched()
        #expect(await controller.refreshForSync([], force: true) == .skipped(.noCourses))
        world.owner = nil
        #expect(await controller.refreshForSync([course], force: true) == .skipped(.ownerUnknown))
        world.owner = 42
        controller.signIn()
        #expect(await controller.refreshForSync([course], force: true) == .skipped(.signingIn))
        controller.turnOff()
        await drainTasks()
        #expect(world.browsersMade <= 1, "only the sign-in itself may have made one")
        #expect(browser.listCalls.isEmpty)
    }

    /// No saved session: the answer is `.needsSignIn` and the browser is never created or
    /// opened; later calls skip at once. Guards a background run opening a sign-in window or
    /// WebKit with nothing to show.
    /// Mutation: in `answerInitialSessionCheck` ignore `cookies.isEmpty` (the browser opens).
    @Test func noSessionOpensNothing() async throws {
        defer { cleanUp() }
        let controller = try launched(withSession: false)
        #expect(await controller.refreshForSync([course], force: false) == .needsSignIn)
        #expect(world.browsersMade == 0)
        #expect(browser.calls.isEmpty)
        #expect(controller.access == .needsSignIn(nil))
        #expect(await controller.refreshForSync([course], force: false) == .skipped(.needsSignIn))
        #expect(browser.calls.isEmpty)
    }

    /// A session that lapsed: `.needsSignIn`, no sign-in, the browser closed, the previous list
    /// kept, and the next call does not touch the browser.
    /// Guards a retry storm every sync interval, or a window appearing from the background.
    /// Mutation: `clearQueue(background: .needsSignIn)` in `handle` -> `.cancelled` (wrong
    /// outcome); drop `access = .needsSignIn(nil)` there (the next call opens the browser again).
    @Test func anExpiredSessionEndsQuietlyAndIsNotRetried() async throws {
        defer { cleanUp() }
        let controller = try launched()
        list(["a"])
        #expect(await controller.refreshForSync([course], force: false) == .refreshed(newlyPublished: 0, failedKeys: 0))
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        var seen = browser.calls.count
        #expect(await controller.refreshForSync([course], force: true) == .needsSignIn)
        #expect(!browser.calls.dropFirst(seen).contains("signIn"), "no sign-in, so no window")
        #expect(!browser.isOpen)
        #expect(controller.access == .needsSignIn(nil))
        #expect(controller.listing(for: course)?.recordings?.map(\.id) == ["a"], "the last list stays")
        seen = browser.calls.count
        #expect(await controller.refreshForSync([course], force: true) == .skipped(.needsSignIn))
        #expect(browser.calls.count == seen)
    }

    /// A failed listing keeps the previous list and seen state and is counted; the first success
    /// after a failure creates the baseline (nothing is "new"); a later success reports what is.
    /// Guards a baseline from a partial listing (#106) and losing the list on failure.
    /// Mutations: publish in a failure path (list erased); mark `newlyPublished` of a baseline
    /// non-zero (first success reports its whole archive).
    @Test func failureKeepsTheListAndBaselineComesOnlyFromACompleteListing() async throws {
        defer { cleanUp() }
        let controller = try launched()
        browser.listResults[other.courseCode] = .failure(RecmanBrowserError.incomplete)
        #expect(await controller.refreshForSync([other], force: true) == .refreshed(newlyPublished: 0, failedKeys: 1))
        #expect(controller.listing(for: other)?.recordings == nil)
        #expect(controller.listing(for: other)?.seenIDs == nil, "no baseline from a failure")
        list(["x", "y"], for: other)
        #expect(await controller.refreshForSync([other], force: true) == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(controller.listing(for: other)?.seenIDs == ["x", "y"], "the first success is the baseline")

        list(["a"])
        _ = await controller.refreshForSync([course], force: true)
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unrecognized)
        #expect(await controller.refreshForSync([course], force: true) == .refreshed(newlyPublished: 0, failedKeys: 1))
        #expect(controller.listing(for: course)?.recordings?.map(\.id) == ["a"])
        #expect(controller.listing(for: course)?.seenIDs == ["a"])
        list(["a", "b"])
        #expect(await controller.refreshForSync([course], force: true) == .refreshed(newlyPublished: 1, failedKeys: 0))
        #expect(controller.listing(for: course)?.seenIDs == ["a"], "the new lecture keeps its dot")
    }

    /// Polimi not answering stops the batch: `.unavailable`, the second course is never asked.
    /// Guards N timeouts of 30 s in a row. Mutation: `clearQueue(background: .unavailable)` ->
    /// `.cancelled` in `handle` (wrong outcome), or `.next` instead of `.stop` for unavailable.
    @Test func unavailableStopsTheBatch() async throws {
        defer { cleanUp() }
        let controller = try launched()
        // Listed in key order: `other` (052499) first.
        browser.listResults[other.courseCode] = .failure(RecmanBrowserError.unavailable)
        list(["x"])
        #expect(await controller.refreshForSync([course, other], force: true) == .unavailable)
        #expect(browser.listCalls == ["052499"])
    }

    // MARK: Identity changes while a listing is in flight

    enum IdentityChange: CaseIterable { case turnOff, accountChange, signIn }

    /// Turn-off, an account change or a sign-in while the listing is in flight: the late answer
    /// publishes nothing, writes no summary, and the caller gets `.cancelled` once.
    /// Guards another identity's listing landing in the new one. Mutation: drop
    /// `clearQueue(background: .cancelled)` from `invalidate` (the caller hangs).
    @Test(arguments: IdentityChange.allCases) func identityChangesPublishNothing(_ change: IdentityChange) async throws {
        defer { cleanUp() }
        let controller = try launched()
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        list(["a"])
        let task = Task { await controller.refreshForSync([course], force: true) }
        await settle("listing in flight") { gate.isWaiting }
        defaults.resetWrites()
        switch change {
        case .turnOff: controller.turnOff()
        case .accountChange:
            world.owner = 7
            controller.webBeepAccountChanged(to: 7)
        case .signIn: controller.signIn()
        }
        #expect(await task.value == .cancelled)
        gate.release()
        await drainTasks()
        #expect(controller.listing(for: course)?.recordings == nil)
        #expect(summaryWrites == 0)
        if change == .signIn { controller.turnOff() }
    }

    // MARK: Next to the page

    /// Closing the page while a sync refresh is in flight does not cancel it.
    /// Guards `suspend` calling `invalidate` for work that was never the page's.
    /// Mutation: drop `|| hasBackgroundRequest` in `suspend` (outcome `.cancelled`).
    @Test func closingThePageDoesNotCancelTheBackgroundRefresh() async throws {
        defer { cleanUp() }
        let controller = try launched()
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        list(["a"])
        controller.pageAppeared()
        let task = Task { await controller.refreshForSync([course], force: false) }
        await settle("listing in flight") { gate.isWaiting }
        controller.windowClosed()
        gate.release()
        #expect(await task.value == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(controller.listing(for: course)?.recordings?.map(\.id) == ["a"])
        #expect(!browser.isOpen, "no page: the browser goes when the refresh ends")
    }

    /// Closing the page drops the listings only the page wanted but keeps those a sync refresh
    /// is queued for, while the one in flight finishes.
    /// Guards `dropQueuedListings` emptying the queue of a refresh that is still waiting (it would
    /// resolve with failures) or, the other way round, working for a closed window.
    /// Mutations: `dropped` always true for `.list` (the refresh's queued course is lost);
    /// `dropped` always false (the page's queued course is still listed).
    @Test func closingThePageKeepsQueuedBackgroundCoursesAndDropsThePagesOwn() async throws {
        defer { cleanUp() }
        let controller = try launched()
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        list(["a"]); list(["b"], for: other); list(["c"], for: third)
        controller.pageAppeared()
        controller.refresh([course, other], selected: course)
        await settle("first listing in flight") { gate.isWaiting }
        let task = Task { await controller.refreshForSync([third], force: false) }
        await drainTasks()
        controller.windowClosed()
        gate.release()
        #expect(await task.value == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.listCalls == ["058167", "099999"], "the page's own queued course was dropped, the refresh's was kept")
        #expect(controller.listing(for: third)?.recordings?.map(\.id) == ["c"])
        #expect(!browser.isOpen)
    }

    /// A background request goes after the page's queue, in order, and a later page refresh
    /// that replaces its own queue does not remove the background course.
    /// Guards `enqueue` replacing (or `enqueueBackground` jumping) the queue.
    /// Mutations: `queue = opens + wanted.map(Job.list)` without `+ kept` (third never listed);
    /// `queue.insert(at: 0)` in `enqueueBackground` (order changes).
    @Test func aBackgroundRequestKeepsThePagesQueueAndOrder() async throws {
        defer { cleanUp() }
        let controller = try launched()
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        list(["a"]); list(["b"], for: other); list(["c"], for: third)
        controller.pageAppeared()
        controller.refresh([course, other], selected: course)
        await settle("first listing in flight") { gate.isWaiting }
        let task = Task { await controller.refreshForSync([third], force: false) }
        await drainTasks()
        // The page now wants only `course` (running): its queued `other` goes, `third` stays.
        controller.refresh([course], selected: course)
        gate.release()
        #expect(await task.value == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.listCalls == ["058167", "099999"])
        #expect(controller.listing(for: third)?.recordings?.map(\.id) == ["c"])
        controller.turnOff()
    }

    /// The order of that queue with nothing replaced: the page's courses, then the background
    /// one. Mutation: `queue.insert(at: 0)` in `enqueueBackground` (third lists first or second).
    @Test func theBackgroundRequestComesAfterThePagesCourses() async throws {
        defer { cleanUp() }
        let controller = try launched()
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        list(["a"]); list(["b"], for: other); list(["c"], for: third)
        controller.pageAppeared()
        controller.refresh([course, other], selected: course)
        await settle("first listing in flight") { gate.isWaiting }
        let task = Task { await controller.refreshForSync([third], force: false) }
        await drainTasks()
        gate.release()
        #expect(await task.value == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.listCalls == ["058167", "052499", "099999"])
        controller.turnOff()
    }

    /// A menu Play queued while a refresh is in flight keeps both: the refresh is answered and
    /// the lecture reaches the player.
    /// Guards one of the two dropping the other. Mutation: `enqueueBackground` clearing opens
    /// (no Play) or `playFromMenu` clearing the queue (outcome `.cancelled`).
    @Test func aMenuPlayAndABackgroundRefreshKeepEachOther() async throws {
        defer { cleanUp() }
        let controller = try launched()
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[other.courseCode] = gate
        list(["b"], for: other); list(["a"])
        browser.streamResults["a"] = [.success(RecordingStream(url: URL(string: "https://nfg1wss.webex.com/nbr/a/hls.m3u8")!, title: nil, duration: 6_000))]
        let task = Task { await controller.refreshForSync([other], force: false) }
        await settle("listing in flight") { gate.isWaiting }
        #expect(controller.playFromMenu(recording("a"), owner: 42))
        gate.release()
        #expect(await task.value == .refreshed(newlyPublished: 0, failedKeys: 0))
        await settle("playing") { world.player.plays.count == 1 }
        #expect(controller.listing(for: other)?.recordings?.map(\.id) == ["b"])
        controller.turnOff()
    }

    // MARK: Cancellation

    /// Cancelling the caller with no page on screen answers `.cancelled` well within a second,
    /// stops the worker, closes the browser and publishes nothing; the late answer is ignored
    /// and nothing resumes twice (a second resume would trap).
    /// Guards a cancelled sync leaving WebKit working for a minute. Mutations: drop the
    /// `onCancel` handler (the await hangs until the gate opens); drop `closeBrowser()` in
    /// `backgroundCancelled` (the browser stays open).
    @Test func cancellationIsPromptAndReleasesEverything() async throws {
        defer { cleanUp() }
        let controller = try launched()
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        list(["a"])
        let task = Task { await controller.refreshForSync([course], force: false) }
        await settle("listing in flight") { gate.isWaiting }
        let started = ContinuousClock.now
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!browser.isOpen)
        gate.release()
        await drainTasks()
        #expect(controller.listing(for: course)?.recordings == nil)
        #expect(controller.listing(for: course)?.isLoading == false)
        // Usable again afterwards.
        browser.listGates[course.courseCode] = nil
        #expect(await controller.refreshForSync([course], force: true) == .refreshed(newlyPublished: 0, failedKeys: 0))
    }

    /// A cancellation with a page on screen only stops waiting and drops the courses the page
    /// doesn't want; the page's own work goes on.
    /// Guards `invalidate` killing the window's listings. Mutation: always `invalidate()` in
    /// `backgroundCancelled` (the page's course never lists).
    @Test func cancellationWithAPageKeepsThePagesWork() async throws {
        defer { cleanUp() }
        let controller = try launched()
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        list(["a"]); list(["b"], for: other)
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("page listing in flight") { gate.isWaiting }
        let task = Task { await controller.refreshForSync([other], force: false) }
        await drainTasks()
        task.cancel()
        #expect(await task.value == .cancelled)
        gate.release()
        await settle("page course listed") { controller.listing(for: course)?.recordings != nil }
        await drainTasks()
        #expect(browser.listCalls == ["058167"], "the dropped course was never asked")
        #expect(browser.isOpen, "the page is still there")
        controller.turnOff()
    }

    // MARK: Writes and freshness

    /// A second identical refresh writes nothing: no summary, no settings key, the session file
    /// untouched. Guards a write every sync interval (principle 3).
    /// Mutation: drop the `guard watchSummaries[key] != summary` in `storeWatchSummary`.
    @Test func aSecondIdenticalRefreshWritesNothing() async throws {
        defer { cleanUp() }
        let controller = try launched()
        list(["a", "b"])
        _ = await controller.refreshForSync([course], force: true)
        await controller.settleSessionFile()
        let file = sessionFileNumber()
        defaults.resetWrites()
        #expect(await controller.refreshForSync([course], force: true) == .refreshed(newlyPublished: 0, failedKeys: 0))
        await controller.settleSessionFile()
        #expect(defaults.writes.isEmpty, "wrote \(defaults.writes)")
        #expect(sessionFileNumber() == file)
    }

    /// Non-force respects the 300 s freshness (zero browser calls); force and an expired
    /// window list again. Guards "Sincronizza ora" being ignored, or automatic runs relisting
    /// every time. Mutations: `force` ignored in `refreshForSync`'s `needsLoad`; `true` for it.
    @Test func forceBypassesFreshnessAndAutomaticRespectsIt() async throws {
        defer { cleanUp() }
        let controller = try launched()
        list(["a"])
        _ = await controller.refreshForSync([course], force: false)
        #expect(browser.listCalls.count == 1)
        let seen = browser.calls.count
        #expect(await controller.refreshForSync([course], force: false) == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.calls.count == seen, "fresh: nothing asked")
        _ = await controller.refreshForSync([course], force: true)
        #expect(browser.listCalls.count == 2, "force relists inside the window")
        world.now = world.now.addingTimeInterval(RecordingsController.freshness + 1)
        _ = await controller.refreshForSync([course], force: false)
        #expect(browser.listCalls.count == 3, "an expired window relists without force")
    }

    // MARK: The new count

    /// The saved `newCount` is the unseen, not completed lectures of the listing: 0 for a
    /// baseline, the new ones afterwards, fewer once one is completed, and written only when it
    /// changes.
    /// Guards a menu line that shows the whole archive as new, or counts finished lectures.
    /// Mutations: drop the `entries[...]?.isCompleted != true` term (completed lecture counted);
    /// count all `recordings` (baseline non-zero); `refreshWatchSummary` after acknowledgement
    /// removed (count stays 2 after the dot clears).
    @Test func newCountIsUnseenAndNotCompleted() async throws {
        defer { cleanUp() }
        let controller = try launched()
        list(["a", "b"])
        _ = await controller.refreshForSync([course], force: true)
        #expect(savedSummary()?.newCount == nil, "baseline: nothing is new (zero is stored as nil)")
        list(["a", "b", "c", "d"])
        #expect(await controller.refreshForSync([course], force: true) == .refreshed(newlyPublished: 2, failedKeys: 0))
        #expect(savedSummary()?.newCount == 2)
        controller.setDone(recording("d"), true)
        await controller.settleWatchProgress()
        await drainTasks()
        #expect(savedSummary()?.newCount == 1, "a completed lecture is not new")
        defaults.resetWrites()
        #expect(await controller.refreshForSync([course], force: true) == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(summaryWrites == 0, "an unchanged count writes nothing")
        #expect(savedSummary()?.newCount == 1)
        controller.markSeen(course)
        await drainTasks()
        #expect(savedSummary()?.newCount == nil, "opening clears the dots and the count")
    }
}
