import AppKit
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The controller side of "click a course's menu bar line to play its next lecture" (package P2):
/// the saved summary's `next`, `playFromMenu`, `onMenuPlayNeedsPage`, closing the window during a
/// Play, and `validatedNext`. Each test runs the real controller against the real SQLite history
/// in a throwaway folder, a fake browser and a fake player (`FakeRecordingPlayer`: 6000 s
/// lectures), and says what it proves and which mutation turns it red. The menu itself (items,
/// the nonisolated action, the owner check) is package P3's and tested there.
@MainActor
struct RecordingsMenuPlayTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-menu-play-\(UUID().uuidString)", isDirectory: true)
    private let defaults = MemoryCountingDefaults.isolated()
    private let browser = FakeRecmanBrowser()
    private let world = RecordingsWorld()
    private let course = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private let other = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!
    private let third = RecmanCourseKey(courseCode: "099999", academicYear: 2026)!
    /// What the controller asked the page for (`onMenuPlayNeedsPage`) and how often it brought the
    /// player forward; a class so the controller's closures and the test see the same values.
    @MainActor final class Calls {
        var needsPage: [RecmanCourseKey] = []
        var accessWhenAsked: [RecordingsAccess] = []
        var broughtForward = 0
    }
    private let calls = Calls()

    private func makeController() -> RecordingsController {
        if defaults.object(forKey: RecordingsController.enabledKey) == nil {
            defaults.set(false, forKey: RecordingsController.enabledKey)
            defaults.resetWrites()
        }
        let world = world
        let browser = browser
        let folder = folder
        let calls = calls
        let controller = RecordingsController(
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
            bringPlayerForward: { calls.broughtForward += 1 }
        )
        controller.onMenuPlayNeedsPage = { [weak controller] key in
            calls.needsPage.append(key)
            if let controller { calls.accessWhenAsked.append(controller.access) }
        }
        return controller
    }

    /// A 90-minute lecture of `key` (default `course`) with a preview link that passes
    /// `RecmanURLPolicy`, as the parser only ever produces: `playFromMenu` refuses anything else.
    private func recording(_ id: String, daysAgo: Double = 1, in key: RecmanCourseKey? = nil) -> RecmanRecording {
        let key = key ?? course
        return RecmanRecording(id: id, courseCode: key.courseCode, academicYear: key.academicYear, title: "Lezione \(id)", recordedAt: world.now.addingTimeInterval(-daysAgo * 86_400), kind: "Lezione", duration: "90 min", size: nil, previewURL: Self.previewURL(id))
    }

    private static func previewURL(_ id: String, host: String = "onlineservices.polimi.it", scheme: String = "https") -> URL {
        URL(string: "\(scheme)://\(host)/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=1&transfer_id=\(id)")!
    }

    private func stream(_ id: String) -> RecordingStream {
        RecordingStream(url: URL(string: "https://nfg1wss.webex.com/nbr/\(id)/hls.m3u8")!, title: nil, duration: 6_000)
    }

    private func settle(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("never happened: \(comment)", sourceLocation: sourceLocation)
    }

    /// Lets every pending main-actor task run, before checking that something did *not* happen.
    private func drainTasks() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<50 { await Task.yield() }
    }

    private var summaryWrites: Int { defaults.writes.filter { $0 == RecordingsController.watchSummaryKey }.count }

    private func savedNext(_ key: RecmanCourseKey? = nil) -> RecmanRecording? {
        RecordingsController.storedWatchSummaries(in: defaults, owner: 42)?[key ?? course]?.next
    }

    /// Turned on and signed in (session saved, browser closed): no page has been shown.
    private func signedInController() async -> RecordingsController {
        let controller = makeController()
        controller.setEnabled(true)
        await settle("sign-in finished") { controller.access == .ready && !browser.isOpen }
        await controller.settleSessionFile()
        return controller
    }

    /// Signed in, page shown, `recordings` listed for `course`.
    private func listedController(_ recordings: [RecmanRecording]) async -> RecordingsController {
        let controller = await signedInController()
        controller.pageAppeared()
        browser.listResults[course.courseCode] = .success(recordings)
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        return controller
    }

    /// Stores a resume position for `id` as an earlier Play would have.
    private func storeResumePoint(_ id: String, at position: TimeInterval) throws {
        var points = RecordingResumePoints(owner: 42)
        points.apply(.remember(position), for: RecordingsStudyState.identity(recording(id)))
        defaults.set(try PropertyListEncoder().encode(points), forKey: RecordingsController.resumePointsKey)
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

    // MARK: The saved next lecture

    /// A listing saves the course's next lecture with its counts, so the menu has something to
    /// play without a controller after a relaunch: here the oldest untouched lecture.
    /// Guards the saved summary losing `next` (the menu line would never be clickable).
    /// Mutation: the rows overload of `courseSummary` for the saved summary in
    /// `refreshWatchSummary` (`next` is nil).
    @Test func aListingSavesTheNextLecture() async throws {
        defer { cleanUp() }
        let controller = await listedController([recording("b", daysAgo: 1), recording("a", daysAgo: 2)])
        #expect(controller.watchSummaries[course]?.next == recording("a", daysAgo: 2))
        #expect(savedNext() == recording("a", daysAgo: 2), "stored for the menu bar at the next launch")
        #expect(controller.watchProgress.summaries[course]?.next == recording("a", daysAgo: 2), "the window agrees")
        controller.turnOff()
    }

    /// Until the sync controller computes it, a stored `newCount` survives the recomputation of
    /// its course's summary (a listing, a checkpoint): recomputing counts and `next` must not
    /// erase the menu's "· 3 nuove". Mutation: pass `newCount: nil` in `refreshWatchSummary`
    /// (the saved count is dropped).
    @Test func aStoredNewCountIsCarriedOver() async throws {
        defer { cleanUp() }
        let stored = RecordingsController.StoredWatchSummaries(owner: 42, courses: ["058167-2026": CourseWatchSummary(done: 0, total: 1, remainingMinutes: 90, unknownDurationCount: 0, newCount: 3)])
        defaults.set(try PropertyListEncoder().encode(stored), forKey: RecordingsController.watchSummaryKey)
        let controller = await listedController([recording("a", daysAgo: 2), recording("b", daysAgo: 1)])
        let saved = try #require(RecordingsController.storedWatchSummaries(in: defaults, owner: 42)?[course])
        #expect(saved.total == 2 && saved.next == recording("a", daysAgo: 2), "recomputed")
        #expect(saved.newCount == 3, "but the new-recordings count is kept")
        #expect(controller.watchProgress.summaries[course]?.newCount == 3, "the window agrees")
        controller.turnOff()
    }

    /// A periodic tick of the playing lecture writes nothing and doesn't move `next`, even when
    /// it takes an untouched lecture past 0 %: only committed entries choose it.
    /// Guards the saved summary being rewritten every ~30 s (principle 3) or the menu line
    /// changing on a tick. Mutation: pass `live` into the saved summary in
    /// `refreshWatchSummary` and persist it from `publishLive` (the tick writes the summary).
    /// Persisting from `publishLive` alone writes nothing, because the saved summary ignores
    /// live positions: that is the property under test.
    @Test func aTickWritesNothingAndKeepsTheNextLecture() async throws {
        defer { cleanUp() }
        let controller = await listedController([recording("a", daysAgo: 2), recording("b", daysAgo: 1)])
        browser.streamResults["b"] = [.success(stream("b"))]
        controller.play(recording("b"))
        await settle("b playing") { world.player.plays.count == 1 }
        await controller.settleWatchProgress()
        defaults.resetWrites()

        world.player.tick(at: 1_200)
        world.player.tick(at: 2_400)
        await drainTasks()
        await controller.settleWatchProgress()

        #expect(summaryWrites == 0, "a tick writes no summary")
        #expect(controller.watchSummaries[course]?.next == recording("a", daysAgo: 2))
        #expect(controller.watchProgress.summaries[course]?.next == recording("a", daysAgo: 2), "the window's next ignores live positions too")
        #expect(controller.watchProgress.summaries[course]?.remainingMinutes == 144, "while its time left does follow the tick")
        controller.turnOff()
    }

    /// The first checkpoint of an untouched lecture makes it partial, and a partial lecture is
    /// next (product rule): `next` moves and is saved once. Completing it moves `next` back to
    /// the oldest one still missing. Guards a stale menu line after watching.
    /// Mutation: the rows overload of `courseSummary` in `refreshWatchSummary` (next stays nil).
    @Test func aCheckpointOrACompletionMovesTheNextLecture() async throws {
        defer { cleanUp() }
        let controller = await listedController([recording("a", daysAgo: 2), recording("b", daysAgo: 1)])
        #expect(savedNext() == recording("a", daysAgo: 2))
        browser.streamResults["b"] = [.success(stream("b"))]
        controller.play(recording("b"))
        await settle("b playing") { world.player.plays.count == 1 }
        await controller.settleWatchProgress()
        defaults.resetWrites()

        world.player.pause(at: 600)
        await controller.settleWatchProgress()
        #expect(savedNext() == recording("b"), "a partly watched lecture comes first")
        #expect(summaryWrites == 1)

        world.player.move(to: 5_700)
        world.player.close()
        await controller.settleWatchProgress()
        #expect(savedNext() == recording("a", daysAgo: 2), "done lectures are never next")
        #expect(controller.watchSummaries[course]?.done == 1)
        controller.turnOff()
    }

    /// A lecture completed while its course's listing isn't in memory (here a menu Play whose
    /// listing failed) can't be recomputed, so the saved `next`, which is that lecture, is
    /// dropped instead of being offered again; the counts are left as they were. Completing a
    /// lecture that isn't the saved next writes nothing.
    /// Guards the menu offering a lecture that was just finished. Mutation: drop the
    /// `clearSavedNextIfCompleted` call in `commitProgress` (next stays "a").
    @Test func completingTheSavedNextWithoutAListingClearsIt() async throws {
        defer { cleanUp() }
        let first = await listedController([recording("a", daysAgo: 2), recording("b", daysAgo: 1)])
        first.windowClosed()
        let saved = try #require(RecordingsController.storedWatchSummaries(in: defaults, owner: 42)?[course])
        #expect(saved.next == recording("a", daysAgo: 2))

        // A relaunch: nothing in memory; the archive now fails to list the course.
        let controller = makeController()
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unrecognized)
        browser.streamResults["a"] = [.success(stream("a"))]
        #expect(controller.playFromMenu(recording("a", daysAgo: 2), owner: 42))
        await settle("a playing") { world.player.plays.count == 1 }
        await settle("listing tried") { browser.listCalls.contains(course.courseCode) && controller.listing(for: course)?.isLoading == false }
        #expect(controller.listing(for: course)?.recordings == nil)

        defaults.resetWrites()
        controller.setDone(recording("b"), true)
        await controller.settleWatchProgress()
        #expect(summaryWrites == 0, "another lecture's completion leaves the saved next alone")

        world.player.move(to: 5_700)
        world.player.close()
        await controller.settleWatchProgress()
        let after = try #require(RecordingsController.storedWatchSummaries(in: defaults, owner: 42)?[course])
        #expect(after.next == nil, "the finished lecture is no longer offered")
        #expect(after.done == saved.done && after.total == saved.total && after.remainingMinutes == saved.remainingMinutes)
        controller.turnOff()
    }

    // MARK: Menu Play

    /// A menu Play with no page on screen plays through the Play button's path: the stored
    /// resume position, the player; then lists the course (so a completion updates the count
    /// and next), then closes the browser it opened. The window is never asked for.
    /// Guards the menu Play skipping the resume point, never loading the listing, or leaving the
    /// hidden browser open at rest. Mutations: drop the `.list` append in `playFromMenu` (no list
    /// call); drop `closesBrowserWhenIdle = true` there (the browser stays open).
    @Test func aMenuPlayWithNoPageResumesListsAndClosesTheBrowser() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        try storeResumePoint("a", at: 1_200)
        browser.listResults[course.courseCode] = .success([recording("a", daysAgo: 2), recording("b")])
        browser.streamResults["a"] = [.success(stream("a"))]

        #expect(controller.playFromMenu(recording("a"), owner: 42))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(try world.player.play(0).startAt == 1_200, "where the student stopped")
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        await settle("browser closed") { !browser.isOpen }
        #expect(browser.calls.filter { $0.hasPrefix("stream ") || $0.hasPrefix("list ") } == ["stream a", "list \(course.courseCode)"], "the Play first, then the listing")
        #expect(calls.needsPage.isEmpty)
        #expect(world.opened.isEmpty)
        controller.turnOff()
    }

    /// The menu Play's listing is appended to what the page queued, never in its place: the
    /// page's other courses still load. Guards the badges of the page's courses silently never
    /// loading. Mutation: `enqueue([key], selected: nil, force: false)` instead of the append
    /// (the queued "099999" is dropped).
    @Test func aMenuPlayKeepsThePagesQueuedListings() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        controller.pageAppeared()
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.listGates[course.courseCode] = gate
        for key in [course, other, third] { browser.listResults[key.courseCode] = .success([recording("x\(key.courseCode)", in: key)]) }
        controller.refresh([course, third], selected: course)
        await settle("first listing running") { gate.isWaiting }
        browser.streamResults["o"] = [.success(stream("o"))]

        #expect(controller.playFromMenu(recording("o", in: other), owner: 42))
        gate.release()
        await settle("all listed") { [course, other, third].allSatisfy { controller.listing(for: $0)?.recordings != nil } }
        #expect(world.player.plays.map(\.recordingID) == ["o"])
        #expect(browser.listCalls.sorted() == [course, other, third].map(\.courseCode).sorted(), "each course listed once")
        controller.turnOff()
    }

    /// The lecture already in the player is brought forward, not played again (which would
    /// restart it at its stored point and ask Webex for a new stream). Mutation: drop the
    /// `stillShowing` branch in `playFromMenu` (a second play and stream call).
    @Test func theLectureAlreadyOpenIsBroughtForwardNotReplayed() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        #expect(controller.playFromMenu(recording("a"), owner: 42))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(controller.playFromMenu(recording("a"), owner: 42))
        await drainTasks()
        #expect(world.player.plays.count == 1)
        #expect(browser.streamCalls == ["stream a"])
        #expect(calls.broughtForward == 1)
        controller.turnOff()
    }

    /// Only the window can help when the feature is off, a sign-in is running or the Polimi
    /// session needs one: the menu Play says so (false) and does nothing.
    /// Guards the menu click silently doing nothing instead of showing "Accedi con Polimi".
    /// Mutation: drop the `isEnabled` guard and the `access` switch in `playFromMenu` (true;
    /// either alone is enough, since `access` is `.off` whenever the feature is off).
    @Test func aMenuPlayNeedsTheWindowWhenOffOrSignedOut() async throws {
        defer { cleanUp() }
        let off = makeController()
        #expect(off.playFromMenu(recording("a"), owner: 42) == false, "off")

        let gate = FakeRecmanBrowser.Gate()
        browser.signInGate = gate
        let controller = makeController()
        controller.setEnabled(true)
        await settle("signing in") { gate.isWaiting }
        #expect(controller.access == .signingIn)
        #expect(controller.playFromMenu(recording("a"), owner: 42) == false, "signing in")

        browser.signInError = RecmanBrowserError.unrecognized
        gate.release()
        await settle("sign-in failed") { controller.access == .needsSignIn(.unrecognized) }
        #expect(controller.playFromMenu(recording("a"), owner: 42) == false, "needs a sign-in")
        await drainTasks()
        #expect(browser.streamCalls.isEmpty)
        #expect(world.player.plays.isEmpty)
        controller.turnOff()
    }

    /// A stored next lecture that fails validation is never opened, even by a direct call, and
    /// the click isn't silent: false, so the caller shows the course's page with its real list.
    /// Guards an edited settings file making the hidden browser follow a foreign link, and a
    /// click that does nothing at all. Mutations: drop the `validatedNext` guard in
    /// `playFromMenu` (the stream is asked for); return true from it (no page).
    @Test func anInvalidNextIsNeverOpenedAndAsksForThePage() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        let forged = RecmanRecording(id: "a", courseCode: course.courseCode, academicYear: course.academicYear, title: "x", recordedAt: world.now, kind: "Lezione", duration: "90 min", size: nil, previewURL: Self.previewURL("a", host: "example.com"))
        browser.streamResults["a"] = [.success(stream("a"))]
        #expect(controller.playFromMenu(forged, owner: 42) == false)
        await drainTasks()
        #expect(browser.streamCalls.isEmpty)
        #expect(world.player.plays.isEmpty)
        #expect(!browser.isOpen, "not even the hidden browser")
        controller.turnOff()
    }

    /// A click on a line built for another WeBeep account (the account changed while the menu
    /// was open) is ignored at the point of action: true, nothing played, no browser, no page.
    /// Guards a stale menu playing the previous student's lecture under the new account.
    /// Mutation: drop the `resumeOwner() == owner` guard in `playFromMenu` (the stream is asked).
    @Test func aClickForAnotherAccountIsIgnored() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        browser.streamResults["a"] = [.success(stream("a"))]
        #expect(controller.playFromMenu(recording("a"), owner: 7))
        await drainTasks()
        #expect(browser.streamCalls.isEmpty)
        #expect(world.player.plays.isEmpty)
        #expect(!browser.isOpen)
        #expect(calls.needsPage.isEmpty)
        controller.turnOff()
    }

    // MARK: Failures without a window

    /// The Polimi session lapsed during a menu Play with no page on screen: the owner is asked
    /// to show the course's page, after `access` already says a sign-in is needed (so the page
    /// shows "Accedi con Polimi" at once). Mutation: don't call `onMenuPlayNeedsPage` in
    /// `handle`'s needsSignIn branch (never asked); call it before setting `access` (it reads
    /// `.ready`).
    @Test func aLapsedSessionAsksForTheCoursePage() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        browser.streamResults["a"] = [.failure(RecmanBrowserError.needsSignIn)]
        #expect(controller.playFromMenu(recording("a"), owner: 42))
        await settle("asked for the page") { !calls.needsPage.isEmpty }
        #expect(calls.needsPage == [course])
        #expect(calls.accessWhenAsked == [.needsSignIn(nil)])
        #expect(world.player.plays.isEmpty)
        controller.turnOff()
    }

    /// A lecture that can't be opened at all (no stream, no player link either) asks for the
    /// course's page too, where "Couldn't open this recording" is shown.
    /// Mutation: don't take the menu Play in `handle`'s `.open` case (never asked).
    @Test func aLectureThatCantBeOpenedAsksForTheCoursePage() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        #expect(controller.playFromMenu(recording("a"), owner: 42))
        await settle("asked for the page") { !calls.needsPage.isEmpty }
        #expect(calls.needsPage == [course])
        #expect(controller.openingProblem == .playbackUnavailable, "the message the page will show")
        controller.turnOff()
    }

    /// With a Recordings page on screen, a failed menu Play is not reported through the
    /// callback: the page already shows the message, and opening it again would steal focus.
    /// Mutation: make `takeMenuPlayNeedingPage` return `menuPlay.key` whatever `visiblePages`
    /// is (asked).
    @Test func aFailedMenuPlayWithAPageOnScreenDoesNotAskAgain() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        controller.pageAppeared()
        #expect(controller.playFromMenu(recording("a"), owner: 42))
        await settle("a failed") { controller.openingProblem == .playbackUnavailable }
        await drainTasks()
        #expect(calls.needsPage.isEmpty)
        controller.turnOff()
    }

    /// Polimi unreachable: a listing ahead of a menu Play fails with `.unavailable`, which drops
    /// the whole queue (every request would wait for the same timeout). The dropped menu Play
    /// asks for its course's page, where "Polimi isn't responding" is shown, instead of
    /// vanishing. The listing ahead is the one an earlier menu Play queued, so no page is open.
    /// Mutation: drop the `takeMenuPlayNeedingPage(failing: nil, queued: true)` call after the
    /// `.unavailable` guard in `handle` (never asked).
    @Test func aMenuPlayDroppedBecausePolimiIsUnreachableAsksForThePage() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.listGates[other.courseCode] = gate
        browser.listResults[other.courseCode] = .failure(RecmanBrowserError.unavailable)
        browser.streamResults["o"] = [.success(stream("o"))]
        #expect(controller.playFromMenu(recording("o", in: other), owner: 42))
        await settle("o playing, its listing running") { world.player.plays.count == 1 && gate.isWaiting }
        browser.streamResults["a"] = [.success(stream("a"))]
        #expect(controller.playFromMenu(recording("a"), owner: 42))
        gate.release()
        await settle("asked for the page") { !calls.needsPage.isEmpty }
        #expect(calls.needsPage == [course])
        #expect(controller.openingProblem == .unavailable)
        #expect(!browser.streamCalls.contains("stream a"))
        controller.turnOff()
    }

    /// A menu Play waiting behind a listing that finds the session gone is dropped with the
    /// queue: it asks for the page too, instead of vanishing. Here the window was closed while
    /// the listing ran, which keeps the listing in flight because a Play is queued.
    /// Mutations: `queued: false` in `handle`'s needsSignIn branch (never asked); drop the
    /// queued Play from `hasPlayOrRecovery`, or let `dropQueuedOpenings` drop Plays (the Play
    /// is dropped when the window closes, before the listing fails).
    @Test func aMenuPlayDroppedBehindALapsedListingAsksForThePage() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        controller.pageAppeared()
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        controller.refresh([course], selected: course)
        await settle("listing running") { gate.isWaiting }
        #expect(controller.playFromMenu(recording("o", in: other), owner: 42))
        controller.windowClosed()
        gate.release()
        await settle("asked for the page") { !calls.needsPage.isEmpty }
        #expect(calls.needsPage == [other])
        #expect(browser.streamCalls.isEmpty)
        controller.turnOff()
    }

    /// A window Play's failure never opens anything, even with the window closed meanwhile, and
    /// neither does a window Play that replaced a pending menu Play: only the menu's own request
    /// counts. Guards the window popping up on its own for a click made in it.
    /// Mutations: report every failed Play with no page on screen in `handle`'s `.open` case
    /// (the first case asks); keep `menuPlay` across a newer `open` and match any Play in
    /// `takeMenuPlayNeedingPage` (the second case asks; the two layers are redundant on
    /// purpose, so only both together break it).
    @Test func aWindowPlaysFailureNeverAsksForThePage() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        controller.pageAppeared()
        controller.play(recording("a"))
        controller.windowClosed()
        await settle("a failed") { controller.openingProblem == .playbackUnavailable }
        await drainTasks()
        #expect(calls.needsPage.isEmpty, "a window Play")

        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.streamGates["m"] = gate
        #expect(controller.playFromMenu(recording("m"), owner: 42))
        await settle("menu Play running") { gate.isWaiting }
        controller.pageAppeared()
        controller.play(recording("b"))
        controller.windowClosed()
        gate.release()
        await settle("b failed") { browser.calls.contains("play b") && controller.openingProblem == .playbackUnavailable }
        await drainTasks()
        #expect(calls.needsPage.isEmpty, "a window Play that replaced a menu Play")
        controller.turnOff()
    }

    // MARK: Closing the window

    /// Closing the window while a Play is finding its stream doesn't cancel it, for a window
    /// Play and for a menu Play made while the window was open; the browser still closes when
    /// it is done. Guards the lecture the student asked for never starting.
    /// Mutation: drop `runningPlay` from `hasPlayOrRecovery` (the worker is cancelled, nothing
    /// plays).
    @Test func closingTheWindowMidPlayDoesNotCancelIt() async throws {
        defer { cleanUp() }
        let controller = await signedInController()
        for (id, fromMenu) in [("a", false), ("b", true)] {
            controller.pageAppeared()
            let gate = FakeRecmanBrowser.Gate()
            defer { gate.release() }
            browser.streamGates[id] = gate
            browser.streamResults[id] = [.success(stream(id))]
            let plays = world.player.plays.count
            if fromMenu { #expect(controller.playFromMenu(recording(id), owner: 42)) } else { controller.play(recording(id)) }
            await settle("\(id) finding its stream") { gate.isWaiting }
            controller.windowClosed()
            gate.release()
            await settle("\(id) playing") { world.player.plays.count == plays + 1 }
            await settle("browser closed") { !browser.isOpen }
            #expect(world.player.plays.last?.recordingID == id)
        }
        #expect(calls.needsPage.isEmpty)
        controller.turnOff()
    }

    // MARK: Validation

    /// `validatedNext` accepts only a lecture of the key's course and year whose preview link is
    /// an https archive preview link for its own id. Guards an edited or foreign stored `next`
    /// being opened. Mutations: drop any one clause of `validatedNext` (the matching case
    /// passes).
    @Test func validatedNextChecksCourseYearAndLink() {
        let good = recording("a")
        func with(code: String = "058167", year: Int = 2026, url: URL = Self.previewURL("a")) -> RecmanRecording {
            RecmanRecording(id: "a", courseCode: code, academicYear: year, title: "t", recordedAt: good.recordedAt, kind: "Lezione", duration: "90 min", size: nil, previewURL: url)
        }
        #expect(RecordingsController.validatedNext(good, for: course))
        #expect(!RecordingsController.validatedNext(with(code: other.courseCode), for: course), "another course")
        #expect(!RecordingsController.validatedNext(with(year: 2025), for: course), "another year")
        #expect(!RecordingsController.validatedNext(with(url: Self.previewURL("a", host: "example.com")), for: course), "another host")
        #expect(!RecordingsController.validatedNext(with(url: Self.previewURL("a", scheme: "http")), for: course), "not https")
        #expect(!RecordingsController.validatedNext(with(url: Self.previewURL("b")), for: course), "a link to another recording")
        #expect(!RecordingsController.validatedNext(with(url: URL(string: "https://onlineservices.polimi.it/x?transfer_id=a")!), for: course), "not the archive's preview link")
    }
}
