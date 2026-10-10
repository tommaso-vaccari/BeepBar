import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// A Recman browser that answers from a script. An operation can be held at a gate, so a test can
/// act while it is in flight (turn the feature off, close the window) and then let the answer
/// arrive late, as a slow Polimi page would.
@MainActor final class FakeRecmanBrowser: RecmanBrowsing {
    /// Holds an operation until `release()`. Closing the browser doesn't release it: the late
    /// answer is exactly what the stale-answer tests want to deliver.
    @MainActor final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private(set) var isWaiting = false

        func wait() async {
            if released { return }
            isWaiting = true
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            isWaiting = false
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private(set) var isOpen = false
    private(set) var calls: [String] = []
    /// The cookie names each `open(cookies:)` received.
    private(set) var openedWith: [[String]] = []
    private var jar: [HTTPCookie] = []
    /// What the jar holds after a successful sign-in.
    var signedInCookies = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "fresh")]
    var signInError: Error?
    var signInGate: Gate?
    var listResults: [String: Result<[RecmanRecording], Error>] = [:]
    var listGates: [String: Gate] = [:]
    /// When set, a successful listing leaves these cookies in the jar, as Polimi renewing one.
    var cookiesAfterListing: [HTTPCookie]?
    var playbackResults: [String: Result<URL, Error>] = [:]
    var playbackGates: [String: Gate] = [:]

    static func cookie(_ name: String, value: String = "v", domain: String = "aunicalogin.polimi.it") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"])!
    }

    var listCalls: [String] { calls.filter { $0.hasPrefix("list ") }.map { String($0.dropFirst(5)) } }
    var playCalls: [String] { calls.filter { $0.hasPrefix("play ") } }

    func open(cookies: [HTTPCookie]) async {
        calls.append("open")
        isOpen = true
        jar = cookies
        openedWith.append(cookies.map(\.name).sorted())
    }

    func cookies() async -> [HTTPCookie] { jar }

    func signIn() async throws {
        calls.append("signIn")
        await signInGate?.wait()
        if let signInError { throw signInError }
        jar = signedInCookies
    }

    func recordings(for key: RecmanCourseKey) async throws -> [RecmanRecording] {
        calls.append("list \(key.courseCode)")
        await listGates[key.courseCode]?.wait()
        guard let result = listResults[key.courseCode] else { throw RecmanBrowserError.unrecognized }
        let recordings = try result.get()
        if let cookiesAfterListing { jar = cookiesAfterListing }
        return recordings
    }

    func playbackURL(for recording: RecmanRecording) async throws -> URL {
        calls.append("play \(recording.id)")
        await playbackGates[recording.id]?.wait()
        guard let result = playbackResults[recording.id] else { throw RecmanBrowserError.playbackUnavailable }
        return try result.get()
    }

    func close() {
        calls.append("close")
        isOpen = false
        jar = []
    }
}

/// Settings that record every write, to prove that a visit with nothing new writes nothing.
final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String] = []

    static func throwaway() -> CountingDefaults {
        CountingDefaults(suiteName: WeBeepAuthenticationController.throwawayDefaultsSuite())!
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        writes.append(defaultName)
        super.removeObject(forKey: defaultName)
    }

    func resetWrites() { writes = [] }
}

/// Mutable from a test: the WeBeep account, Polimi or not, the clock, and what was opened.
@MainActor final class RecordingsWorld {
    var owner: Int? = 42
    var polimi = true
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var opened: [URL] = []
    var copied: [URL] = []
    var storeAccesses = 0
    var browsersMade = 0
}

/// The Recordings controller against a scripted browser, a throwaway session folder and throwaway
/// settings. Each test names the promise of `RecordingsController` it guards.
@MainActor
struct RecordingsControllerTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-controller-\(UUID().uuidString)", isDirectory: true)
    private let defaults = CountingDefaults.throwaway()
    private let browser = FakeRecmanBrowser()
    private let world = RecordingsWorld()
    private let course = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private let other = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!
    private let third = RecmanCourseKey(courseCode: "099999", academicYear: 2026)!

    private var store: RecordingsSessionStore {
        let folder = folder
        let world = world
        return RecordingsSessionStore {
            MainActor.assumeIsolated { world.storeAccesses += 1 }
            return folder
        }
    }
    private var sessionFile: URL { folder.appendingPathComponent(RecordingsSessionStore.fileName) }

    private func makeController(useDefault: Bool = false) -> RecordingsController {
        if !useDefault && defaults.object(forKey: RecordingsController.enabledKey) == nil {
            defaults.set(false, forKey: RecordingsController.enabledKey)
            defaults.resetWrites()
        }
        let world = world
        let browser = browser
        return RecordingsController(
            makeBrowser: { world.browsersMade += 1; return browser },
            store: store,
            defaults: defaults,
            ownerUserID: { world.owner },
            isAvailable: { world.polimi },
            openURL: { world.opened.append($0) },
            copy: { world.copied.append($0) },
            now: { MainActor.assumeIsolated { world.now } }
        )
    }

    private func recording(_ id: String, _ key: RecmanCourseKey? = nil, daysAgo: Double = 1) -> RecmanRecording {
        let key = key ?? course
        return RecmanRecording(id: id, courseCode: key.courseCode, academicYear: key.academicYear, title: "Lezione \(id)", recordedAt: world.now.addingTimeInterval(-daysAgo * 86_400), kind: "Lezione", duration: "90 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/x?transfer_id=\(id)")!)
    }

    private func saveSession(owner: Int, cookies: [HTTPCookie] = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "saved")]) throws {
        try store.save(RecmanSessionCodec.encode(cookies, ownerUserID: owner, now: world.now))
    }

    private func savedSession() throws -> RecmanSessionCodec.Snapshot? {
        guard let data = try store.load() else { return nil }
        return try RecmanSessionCodec.decode(data, now: world.now)
    }

    /// The session file's inode: a save replaces the file, so a changed number means it was written.
    private func sessionFileNumber() -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: sessionFile.path))?[.systemFileNumber] as? Int
    }

    /// Waits for the controller's tasks; records a failure instead of hanging.
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

    /// Turned on, signed in, session saved, browser closed again, then the page shown: the state
    /// after enabling the switch and opening Registrazioni.
    private func readyController() async -> RecordingsController {
        let controller = makeController()
        controller.setEnabled(true)
        await settle("sign-in finished and browser closed") { controller.access == .ready && !browser.isOpen }
        controller.pageAppeared()
        return controller
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Switch

    /// An explicitly disabled feature stays quiet.
    @Test func disabledCreationTouchesNothing() async {
        defer { cleanUp() }
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        controller.play(recording("a"))
        await drainTasks()
        #expect(!controller.isEnabled)
        #expect(controller.access == .off)
        #expect(world.storeAccesses == 0)
        #expect(world.browsersMade == 0)
        #expect(defaults.writes.isEmpty)
    }

    @Test func enabledByDefaultWithoutStartingWorkAndExplicitOptOutPersists() async {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        #expect(controller.isEnabled)
        await drainTasks()
        #expect(world.storeAccesses == 0)
        #expect(world.browsersMade == 0)
        #expect(defaults.writes.isEmpty)
        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(!makeController(useDefault: true).isEnabled)
        defaults.removeObject(forKey: RecordingsController.enabledKey)
        world.polimi = false
        #expect(!makeController(useDefault: true).isEnabled)
    }

    /// The switch only turns on for Polimi with a known WeBeep account, since the session is saved
    /// under that account. Turning on signs in at once and saves the session for that account.
    @Test func turningOnNeedsPolimiAndAKnownAccount() async throws {
        defer { cleanUp() }
        world.polimi = false
        let controller = makeController()
        #expect(!controller.canTurnOn)
        controller.setEnabled(true)
        #expect(!controller.isEnabled)
        world.polimi = true
        world.owner = nil
        #expect(!controller.canTurnOn)
        controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(browser.calls.isEmpty)
        #expect(defaults.writes.isEmpty)

        world.owner = 42
        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(controller.access == .signingIn)
        #expect(defaults.bool(forKey: RecordingsController.enabledKey))
        // The page isn't shown, so the browser goes once the session is saved.
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        #expect(browser.calls == ["open", "signIn", "close"])
        #expect(try savedSession()?.ownerUserID == 42)
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"])
    }

    /// A switch saved on comes back on after a relaunch, ready, with no sign-in until the page
    /// asks for something. Another university never shows Polimi's feature.
    @Test func theSwitchSurvivesARelaunch() async {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        let controller = makeController()
        #expect(controller.isEnabled)
        #expect(controller.access == .ready)
        await drainTasks()
        #expect(browser.calls.isEmpty)
        world.polimi = false
        #expect(!makeController().isEnabled)
    }

    /// Closing the Polimi window leaves the switch on with the sign-in still to do, and no message;
    /// a real failure says why; a later success saves the session.
    @Test func anUnfinishedSignInKeepsTheSwitchOnAndSaysWhy() async throws {
        defer { cleanUp() }
        browser.signInError = CancellationError()
        let controller = makeController()
        controller.setEnabled(true)
        await settle("cancelled") { controller.access == .needsSignIn(nil) }
        #expect(controller.isEnabled)
        #expect(try store.load() == nil)
        #expect(!browser.isOpen)

        browser.signInError = RecmanBrowserError.unavailable
        controller.signIn()
        await settle("failed with a reason") { controller.access == .needsSignIn(.unavailable) }
        browser.signInError = nil
        controller.signIn()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"])
    }

    /// Off means forgotten: browser closed, session file deleted, every setting removed, lists gone.
    /// Guards against a Polimi session lingering after the user turned the feature off.
    @Test func turningOffForgetsEverything() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(try store.load() != nil)
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) != nil)
        #expect(defaults.object(forKey: RecordingsController.baselinedKey) != nil)

        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(controller.access == .off)
        #expect(!browser.isOpen)
        #expect(controller.listings.isEmpty)
        #expect(try store.load() == nil)
        #expect(defaults.object(forKey: RecordingsController.enabledKey) as? Bool == false)
        for key in [RecordingsController.acknowledgedKey, RecordingsController.baselinedKey] {
           #expect(defaults.object(forKey: key) == nil, "\(key) left behind")
        }
        // Nothing to do while off: the page asking again starts nothing.
        controller.refresh([course], selected: course, force: true)
        await drainTasks()
        #expect(!browser.isOpen)
    }

    // MARK: Session file and account

    /// First use shows the explanation before any archive request, even with no synced courses.
    /// Rebuilding or reopening the page keeps the introduction without rereading the session.
    @Test func firstVisitWithoutASessionShowsSignInWithoutOpeningABrowser() async {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        #expect(world.storeAccesses == 0)
        controller.pageAppeared()
        #expect(controller.access == .needsSignIn(nil))
        #expect(world.storeAccesses == 1)
        controller.refresh([course], selected: course)
        controller.pageDisappeared()
        controller.pageAppeared()
        controller.windowClosed()
        controller.pageAppeared()
        await drainTasks()
        #expect(controller.access == .needsSignIn(nil))
        #expect(controller.listings.isEmpty)
        #expect(world.storeAccesses == 1)
        #expect(world.browsersMade == 0)
        #expect(browser.calls.isEmpty)
        #expect(defaults.writes.isEmpty)
    }

    /// A matching saved session still loads automatically; page reconstruction keeps its browser.
    @Test func firstVisitReusesASavedSession() async throws {
        defer { cleanUp() }
        try saveSession(owner: 42)
        world.storeAccesses = 0
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = makeController(useDefault: true)
        #expect(world.storeAccesses == 0)
        controller.pageAppeared()
        #expect(controller.access == .ready)
        #expect(world.storeAccesses == 1)
        #expect(world.browsersMade == 0)
        controller.refresh([course], selected: course)
        await settle("saved session loaded") { controller.listing(for: course)?.recordings != nil }
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(!browser.calls.contains("signIn"))
        let accesses = world.storeAccesses
        controller.pageDisappeared()
        controller.pageAppeared()
        await drainTasks()
        #expect(world.storeAccesses == accesses)
        #expect(browser.isOpen)
    }

    /// A completed explicit sign-in stays usable even when an unknown owner prevented saving it.
    @Test func signInBeforeFirstVisitDoesNotRequireASavedSession() async {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        world.owner = nil
        controller.signIn()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        let accesses = world.storeAccesses
        controller.pageAppeared()
        #expect(controller.access == .ready)
        #expect(world.storeAccesses == accesses)
    }

    /// A saved file containing no reusable cookies asks for sign-in without probing Polimi.
    @Test(arguments: [false, true])
    func anEmptyOrExpiredSessionShowsSignIn(expired: Bool) async throws {
        defer { cleanUp() }
        let cookie = HTTPCookie(properties: [.name: "SSO_LOGIN", .value: "saved", .domain: "aunicalogin.polimi.it", .path: "/", .expires: world.now.addingTimeInterval(60)])!
        try saveSession(owner: 42, cookies: expired ? [cookie] : [])
        if expired { world.now = world.now.addingTimeInterval(120) }
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        #expect(controller.access == .needsSignIn(nil))
        controller.refresh([course], selected: course)
        await drainTasks()
        #expect(world.browsersMade == 0)
        #expect(browser.calls.isEmpty)
        #expect(controller.listings.isEmpty)
    }

    /// A session saved for another WeBeep account is deleted unused, with what that account had
    /// seen: a shared Mac must not show one student's archive to the next.
    @Test func anotherAccountsSessionIsDroppedUnused() async throws {
        defer { cleanUp() }
        try saveSession(owner: 7)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        defaults.set(["old"], forKey: RecordingsController.acknowledgedKey)
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("asks for the sign-in") { controller.access == .needsSignIn(nil) }
        #expect(browser.calls.isEmpty)
        #expect(world.browsersMade == 0)
        #expect(try store.load() == nil)
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) == nil)
    }

    /// Before WeBeep answers (an offline launch) the account is unknown: the saved session is used,
    /// and a renewed cookie is saved under the file's owner, never under "nobody".
    @Test func anUnknownAccountUsesTheSavedSessionAndKeepsItsOwner() async throws {
        defer { cleanUp() }
        try saveSession(owner: 7)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        world.owner = nil
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "renewed")]
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("renewed session saved") { (try? savedSession())?.cookies.map(\.value) == ["renewed"] }
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(try savedSession()?.ownerUserID == 7)
    }

    /// When the WeBeep account turns out to be someone else's while the page is open, the live
    /// session, the lists and the seen recordings go too; the same account changes nothing.
    @Test func aDifferentAccountAppearingDropsTheLiveSession() async throws {
        defer { cleanUp() }
        try saveSession(owner: 7)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        world.owner = nil
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings?.count == 1 }

        controller.webBeepAccountChanged(to: 7)
        #expect(try store.load() != nil)
        #expect(controller.listing(for: course) != nil)
        controller.webBeepAccountChanged(to: 8)
        #expect(try store.load() == nil)
        #expect(!browser.isOpen)
        #expect(controller.listings.isEmpty)
        #expect(controller.access == .needsSignIn(nil))
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) == nil)
    }

    /// A file that can't be decoded (damage, a future version) is deleted and the user signs in
    /// again; one that can't be read right now (a disk error) is kept for the next try.
    @Test func anUndecodableSessionIsDeletedButAnUnreadableOneIsKept() async throws {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(Data("garbage".utf8))
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("asks for the sign-in") { controller.access == .needsSignIn(nil) }
        #expect(browser.calls.isEmpty)
        #expect(world.browsersMade == 0)
        #expect(try store.load() == nil)

        // A folder where the file should be: reading fails, and nothing is deleted.
        try FileManager.default.createDirectory(at: sessionFile, withIntermediateDirectories: true)
        let second = makeController()
        second.pageAppeared()
        second.refresh([course], selected: course)
        await settle("asks for the sign-in") { second.access == .needsSignIn(nil) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: sessionFile.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// Without a known account a session is never written: nothing could tell later whose it is.
    @Test func noSessionIsSavedWithoutAnOwner() async throws {
        defer { cleanUp() }
        let controller = makeController()
        controller.setEnabled(true)
        // The account becomes unknown before the sign-in task runs.
        world.owner = nil
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        #expect(try store.load() == nil)
    }

    /// A visit with nothing new writes nothing: neither the session (same cookies) nor the
    /// settings (no recording seen for the first time). A renewed cookie is saved.
    @Test func aVisitWithNothingNewWritesNothing() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("first listing") { controller.listing(for: course)?.recordings != nil }
        await drainTasks()
        let fileBefore = try #require(sessionFileNumber())
        defaults.resetWrites()

        controller.refresh([course], selected: course, force: true)
        await settle("second listing") { browser.listCalls.count == 2 && controller.listing(for: course)?.isLoading == false }
        await drainTasks()
        #expect(sessionFileNumber() == fileBefore, "the same session was written again")
        #expect(defaults.writes.isEmpty)

        browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "fresh"), FakeRecmanBrowser.cookie("JSESSIONID", value: "next", domain: "onlineservices.polimi.it")]
        controller.refresh([course], selected: course, force: true)
        await settle("renewed session saved") { sessionFileNumber() != fileBefore }
        #expect(try savedSession()?.cookies.map(\.name).sorted() == ["JSESSIONID", "SSO_LOGIN"])
    }

    // MARK: Loading

    /// The selected course goes first, then the others for their badges. A course loaded a moment
    /// ago isn't asked for again unless the user refreshes or it has grown old.
    @Test func selectedFirstThenOthersAndRecentOnesAreSkipped() async throws {
        defer { cleanUp() }
        for key in [course, other, third] { browser.listResults[key.courseCode] = .success([recording("r\(key.courseCode)", key)]) }
        let controller = await readyController()
        controller.refresh([course, other, third], selected: third)
        await settle("all listed") { [course, other, third].allSatisfy { controller.listing(for: $0)?.recordings != nil } }
        #expect(browser.listCalls == ["099999", "058167", "052499"])

        controller.refresh([course, other, third], selected: course)
        await drainTasks()
        #expect(browser.listCalls.count == 3)

        controller.refresh([course, other, third], selected: course, force: true)
        await settle("refreshed") { browser.listCalls.count == 6 }
        #expect(Array(browser.listCalls.suffix(3)) == ["058167", "052499", "099999"])
        world.now.addTimeInterval(RecordingsController.freshness + 1)
        controller.refresh([course], selected: course)
        await settle("stale course asked again") { browser.listCalls.count == 7 }
    }

    /// A lapsed Polimi session stops the batch and asks for the sign-in, without saving; signing
    /// in again reloads the page's courses.
    @Test func aLapsedSessionAsksForSignInThenReloads() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        browser.listResults[other.courseCode] = .success([recording("b", other)])
        let controller = await readyController()
        controller.refresh([course, other], selected: course)
        await settle("asks for the sign-in") { controller.access == .needsSignIn(nil) }
        #expect(browser.listCalls == ["058167"])
        #expect(controller.listing(for: other)?.isLoading == false)
        #expect(!browser.isOpen)

        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.signIn()
        await settle("both reloaded") { controller.listing(for: other)?.recordings != nil && controller.listing(for: course)?.recordings != nil }
        #expect(controller.access == .ready)
    }

    /// Offline: the first timeout ends the batch, and every waiting course says why instead of each
    /// waiting for its own timeout.
    @Test func beingOfflineStopsTheBatch() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unavailable)
        browser.listResults[other.courseCode] = .success([recording("b", other)])
        let controller = await readyController()
        controller.refresh([course, other], selected: course)
        await settle("both marked") { controller.listing(for: other)?.problem == .unavailable }
        #expect(browser.listCalls == ["058167"])
        #expect(controller.listing(for: course)?.problem == .unavailable)
        #expect(controller.listing(for: other)?.isLoading == false)
        #expect(controller.access == .ready)
    }

    /// Any other failure stays with its course: the rest still load, and an earlier list stays on
    /// screen under the warning.
    @Test func otherFailuresStayWithTheirCourse() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.listResults[other.courseCode] = .success([recording("b", other)])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }

        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.yearUnavailable)
        controller.refresh([course, other], selected: course, force: true)
        await settle("other listed") { controller.listing(for: other)?.recordings != nil }
        #expect(controller.listing(for: course)?.problem == .yearUnavailable)
        #expect(controller.listing(for: course)?.recordings?.map(\.id) == ["a"])
        #expect(controller.listing(for: course)?.isLoading == false)
    }

    /// Trying again clears the last failure while the new attempt runs. Guards against the
    /// warning staying next to the spinner, which reads as the new attempt having failed already
    /// (seen live on 2026-10-06: every course "Loading…" under "Polimi isn't responding").
    @Test func aNewAttemptReplacesTheLastFailure() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unavailable)
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("failed") { controller.listing(for: course)?.problem == .unavailable }

        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.refresh([course], selected: course)
        #expect(controller.listing(for: course)?.isLoading == true)
        #expect(controller.listing(for: course)?.problem == nil)
        await settle("second request in flight") { gate.isWaiting }
        gate.release()
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(controller.listing(for: course)?.problem == nil)
    }

    /// Removing a queued course must stop its request and spinner without cancelling an
    /// explicit playback action or the currently running listing; reselecting loads it once.
    @Test(arguments: [false, true], [false, true])
    func removedQueuedCourseDoesNotLoad(copy: Bool, staleSelection: Bool) async {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([])
        browser.listResults[other.courseCode] = .success([])
        let player = URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=x")!
        browser.playbackResults["x"] = .success(player)
        let controller = await readyController()
        defer { controller.windowClosed() }
        controller.refresh([course, other], selected: course)
        await settle("first listing blocked") { gate.isWaiting }
        if copy { controller.copyLink(recording("x")) }
        else { controller.play(recording("x")) }
        controller.refresh([course], selected: staleSelection ? other : course)
        #expect(controller.listing(for: other)?.isLoading == false)
        #expect(controller.listing(for: course)?.isLoading == true)
        gate.release()
        await settle("explicit action completed") { controller.openingRecordingID == nil }
        await drainTasks()
        #expect(browser.listCalls == [course.courseCode])
        #expect(copy ? world.copied == [player] : world.opened == [player])
        controller.refresh([course, other], selected: other)
        controller.refresh([other, course], selected: other)
        await settle("reselected course loaded") { controller.listing(for: other)?.recordings != nil }
        await drainTasks()
        #expect(browser.listCalls == [course.courseCode, other.courseCode])
    }

    /// A Play clicked while a course is loading waits behind it; when that load finds Polimi
    /// unreachable, the Play is dropped with the rest of the batch and says why. Guards against
    /// the click doing nothing at all, as in the live check of 2026-10-06.
    @Test func aPlayDroppedWithTheBatchSaysWhy() async {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unavailable)
        browser.playbackResults["x"] = .success(URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=x")!)
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("request in flight") { gate.isWaiting }
        controller.play(recording("x"))
        #expect(controller.openingRecordingID == "x")
        #expect(controller.openingProblem == nil)
        gate.release()
        await settle("play dropped") { controller.openingRecordingID == nil }
        #expect(controller.openingProblem == .unavailable)
        #expect(browser.playCalls.isEmpty)
        #expect(world.opened.isEmpty)
    }

    // MARK: Stale answers

    /// An answer that arrives after the feature was turned off changes nothing and writes nothing:
    /// the switch and the deleted session stay as the user left them.
    @Test func aLateAnswerAfterTurningOffIsIgnored() async throws {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "late")]
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("request in flight") { gate.isWaiting }
        controller.setEnabled(false)
        gate.release()
        await drainTasks()
        #expect(controller.listings.isEmpty)
        #expect(try store.load() == nil)
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) == nil)
        #expect(defaults.object(forKey: RecordingsController.baselinedKey) == nil)
        #expect(!controller.isEnabled)
    }

    /// Closing the window stops the work and drops the browser at once; what was loading no longer
    /// spins, and a late answer isn't applied.
    @Test func closingTheWindowStopsWorkAndDropsTheBrowser() async {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("request in flight") { gate.isWaiting }
        controller.windowClosed()
        #expect(!browser.isOpen)
        #expect(controller.listing(for: course)?.isLoading == false)
        gate.release()
        await drainTasks()
        #expect(controller.listing(for: course)?.recordings == nil)
        #expect(controller.access == .ready)
        #expect(!browser.isOpen)
    }

    /// A language switch rebuilds the page (it disappears and appears in the same turn): the browser
    /// and its live session survive it. Leaving the page for real drops them.
    @Test func aRebuiltPageKeepsTheBrowserButLeavingDropsIt() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        await drainTasks()
        #expect(browser.isOpen)
        controller.pageDisappeared()
        controller.pageAppeared()
        await drainTasks()
        #expect(browser.isOpen)
        controller.pageDisappeared()
        await settle("browser dropped") { !browser.isOpen }
        // The lists stay, so the page shows them at once next time.
        #expect(controller.listing(for: course)?.recordings != nil)
    }

    /// A sign-in on screen survives the BeepBar window closing (the user may be typing in Polimi's
    /// window), and the browser goes once it ends.
    @Test func aSignInSurvivesTheWindowClosing() async throws {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        browser.signInGate = gate
        let controller = makeController()
        controller.pageAppeared()
        controller.setEnabled(true)
        await settle("sign-in on screen") { gate.isWaiting }
        controller.windowClosed()
        #expect(browser.isOpen)
        #expect(controller.access == .signingIn)
        gate.release()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        #expect(try savedSession()?.ownerUserID == 42)
    }

    // MARK: Opening

    /// Play opens the player in the browser and copy puts its link on the clipboard; the player is
    /// looked up once per recording, and opening clears the "new" dot.
    @Test func playAndCopyOpenTheRightPlayerOnce() async throws {
        defer { cleanUp() }
        let player = URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc")!
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.playbackResults["b"] = .success(player)
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        let fresh = recording("b", daysAgo: 0)
        browser.listResults[course.courseCode] = .success([fresh, recording("a")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }

        controller.play(fresh)
        #expect(controller.openingRecordingID == "b")
        await settle("opened") { world.opened == [player] }
        #expect(controller.openingRecordingID == nil)
        #expect(controller.newCount(for: course) == 0)
        controller.copyLink(fresh)
        #expect(world.copied == [player])
        #expect(browser.playCalls == ["play b"])
    }

    /// A player that can't be found says so, and the row stops spinning; nothing is opened.
    @Test func aMissingPlayerSaysSo() async {
        defer { cleanUp() }
        let controller = await readyController()
        controller.play(recording("x"))
        await settle("problem shown") { controller.openingProblem == .playbackUnavailable }
        #expect(controller.openingRecordingID == nil)
        #expect(world.opened.isEmpty)
        #expect(world.copied.isEmpty)
    }

    /// A slow old lookup must not overwrite a newer cached copy, or show its error after the
    /// newer choice succeeded. Both Play and Copy share this request ordering.
    @Test(arguments: [false, true])
    func aSlowOpeningCannotReplaceANewerCachedChoice(fails: Bool) async throws {
        defer { cleanUp() }
        let first = URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a")!
        let latest = URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=b")!
        browser.playbackResults["a"] = fails ? .failure(RecmanBrowserError.playbackUnavailable) : .success(first)
        browser.playbackResults["b"] = .success(latest)
        let controller = await readyController()
        controller.copyLink(recording("b"))
        await settle("latest player cached") { world.copied == [latest] }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.playbackGates["a"] = gate
        controller.copyLink(recording("a"))
        await settle("old lookup held") { gate.isWaiting }
        controller.copyLink(recording("b"))
        #expect(world.copied == [latest, latest])
        gate.release()
        // A subsequent list is a barrier: it runs only after the old opening finishes.
        browser.listResults[course.courseCode] = .success([])
        controller.refresh([course], selected: course)
        await settle("old lookup finished") { controller.listing(for: course)?.recordings != nil }
        #expect(world.copied == [latest, latest])
        #expect(controller.openingRecordingID == nil)
        #expect(controller.openingProblem == nil)
        #expect(!controller.acknowledged.contains("a"))
    }

    /// A second Play while lookup is held opens only the last choice, including a repeated Play
    /// of the same recording. The held request may cache its URL, but never opens a stale tab.
    @Test(arguments: ["a", "b"])
    func onlyTheLatestPlayOpensWhileALookupIsRunning(latestID: String) async {
        defer { cleanUp() }
        let first = URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a")!
        let other = URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=b")!
        browser.playbackResults["a"] = .success(first)
        browser.playbackResults["b"] = .success(other)
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.playbackGates["a"] = gate
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("first lookup held") { gate.isWaiting }
        controller.play(recording(latestID))
        gate.release()
        browser.listResults[course.courseCode] = .success([])
        controller.refresh([course], selected: course)
        await settle("openings finished") { controller.listing(for: course)?.recordings != nil }
        #expect(world.opened == [latestID == "a" ? first : other])
        #expect(browser.playCalls == (latestID == "a" ? ["play a"] : ["play a", "play b"]))
        #expect(controller.openingRecordingID == nil)
    }

    // MARK: New recordings

    /// The first listing of a course marks everything as seen; later arrivals are new until opened
    /// or marked seen, and stay new after a relaunch.
    @Test func onlyRecordingsPublishedLaterAreNew() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a"), recording("b")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(controller.newCount(for: course) == 0)
        let seen = defaults.stringArray(forKey: RecordingsController.acknowledgedKey)
        #expect(Set(seen ?? []) == ["a", "b"])

        browser.listResults[course.courseCode] = .success([recording("c", daysAgo: 0), recording("a"), recording("b")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }
        #expect(controller.isNew(recording("c")))
        #expect(defaults.stringArray(forKey: RecordingsController.acknowledgedKey) == seen, "a new recording was marked seen without being opened")

        let relaunched = makeController()
        #expect(relaunched.isNew(recording("c")))
        #expect(!relaunched.isNew(recording("a")))
        // A course never listed has no baseline, so nothing in it counts as new.
        #expect(!relaunched.isNew(recording("z", other)))

        controller.markSeen(course)
        #expect(controller.newCount(for: course) == 0)
        #expect(!makeController().isNew(recording("c")))
    }

    /// The seen list is capped, oldest first, so it can't grow without end over the years.
    @Test func theSeenListIsCapped() async {
        defer { cleanUp() }
        let many = (0..<(RecordingsController.acknowledgedLimit + 10)).map { recording("id\($0)") }
        browser.listResults[course.courseCode] = .success(many)
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        let seen = defaults.stringArray(forKey: RecordingsController.acknowledgedKey) ?? []
        #expect(seen.count == RecordingsController.acknowledgedLimit)
        #expect(seen.first == "id10")
        #expect(seen.last == "id\(RecordingsController.acknowledgedLimit + 9)")
    }

    /// Every Recman failure maps to a message; a lapsed session or an unknown error reads as an
    /// unrecognized archive, never as an empty list.
    @Test func everyFailureHasAMessage() {
        #expect(RecordingsProblem(RecmanBrowserError.needsSignIn) == .unrecognized)
        #expect(RecordingsProblem(CocoaError(.fileReadUnknown)) == .unrecognized)
        #expect(RecordingsProblem(RecmanBrowserError.incomplete) == .incomplete)
        for problem in [RecordingsProblem.unavailable, .unrecognized, .incomplete, .yearUnavailable, .playbackUnavailable] {
            #expect(!problem.message.isEmpty)
        }
    }
    /// Explicit study choices survive a restart without waiting for any course listing.
    @Test func watchlistRestoresMetadataAndNavigationWithoutNetwork() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("lesson", course)
        let b = recording("other", other)
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.toggleWatchlist(b, courseName: "HPC")
        controller.selectDestination(.watchlist)
        let restored = makeController(useDefault: true)
        let calls = browser.calls
        restored.pageAppeared()
        #expect(restored.study.bookmarks.map(\.courseName) == ["NLA", "HPC"])
        #expect(restored.study.bookmarks.first?.recording == a)
        #expect(Set(restored.study.visibleBookmarks(query: "").map(\.recording.id)) == ["lesson", "other"])
        #expect(restored.study.destination == .watchlist)
        #expect(restored.listings.isEmpty)
        #expect(browser.calls == calls)
        restored.turnOff()
    }

    /// Reused recording IDs in another course or year never share bookmarked state.
    @Test func studyIdentitySeparatesCoursesYearsAndSupportsReversibleActions() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("shared", course)
        let b = recording("shared", other)
        let c = recording("shared", RecmanCourseKey(courseCode: course.courseCode, academicYear: 2025)!)
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.toggleWatchlist(b, courseName: "HPC")
        #expect(controller.study.contains(a) && controller.study.contains(b))
        #expect(!controller.study.contains(c))
        controller.toggleWatchlist(a, courseName: "NLA")
        #expect(!controller.study.contains(a) && controller.study.contains(b))
        controller.toggleWatchlist(a, courseName: "NLA")
        #expect(controller.study.bookmarks.count == 2)
        controller.turnOff()
    }

    /// Reading novelties, copying and playing never add or remove personal bookmarks.
    @Test func playbackCopyAndBaselineNeverChangeBookmarks() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("lecture")
        browser.listResults[course.courseCode] = .success([a])
        browser.playbackResults[a.id] = .success(URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=lecture")!)
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("course loaded") { controller.listing(for: course)?.recordings != nil }
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.markSeen(course)
        controller.copyLink(a)
        await settle("copied") { !world.copied.isEmpty }
        controller.play(a)
        await settle("played") { !world.opened.isEmpty }
        #expect(controller.study.contains(a))
        #expect(controller.study.bookmarks.count == 1)
        controller.turnOff()
    }

    /// A different account loads its own choices even if there is no saved browser-session owner.
    @Test func studyAccountChangesNeverLeakAndReturnRestoresChoices() async {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        let a = recording("private")
        controller.toggleWatchlist(a, courseName: "NLA")
        let b = recording("other-account")
        world.owner = 99
        controller.webBeepAccountChanged(to: 99)
        #expect(controller.study.bookmarks.isEmpty)
        controller.toggleWatchlist(b, courseName: "HPC")
        world.owner = 42
        controller.webBeepAccountChanged(to: 42)
        #expect(controller.study.contains(a))
        #expect(!controller.study.contains(b))
        world.owner = 99
        controller.webBeepAccountChanged(to: 99)
        #expect(controller.study.contains(b))
        #expect(!controller.study.contains(a))
        controller.turnOff()
    }

    /// Disabling or renewing browser credentials must not erase the personal study queue.
    @Test func disablingAndFailedSignInPreserveStudyChoices() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("keep")
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.turnOff()
        #expect(controller.study.bookmarks.isEmpty)
        browser.signInError = RecmanBrowserError.unavailable
        controller.setEnabled(true)
        await settle("sign-in failed") { controller.access == .needsSignIn(.unavailable) }
        controller.pageAppeared()
        #expect(controller.study.contains(a))
        #expect(controller.studyProblem == nil)
        controller.turnOff()
    }

    /// Bad saved data is reported and preserved rather than overwritten by an empty watchlist.
    @Test func unreadableStudyPreservesOriginalAndRejectsEdits() {
        defer { cleanUp() }
        let key = RecordingsController.studyKey(owner: 42)
        let original = Data("not a plist".utf8)
        defaults.set(original, forKey: key)
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        #expect(controller.studyProblem != nil)
        #expect(!controller.canEditStudy)
        controller.toggleWatchlist(recording("lost"), courseName: "NLA")
        controller.selectDestination(.course(17))
        #expect(controller.study.destination == .course(17))
        #expect(defaults.data(forKey: key) == original)
        controller.turnOff()
    }

    /// Only successful listings update snapshots or availability; failures/cancellation cannot drop a bookmark.
    @Test func refreshUpdatesBookmarksAndMarksMissingWithoutDeleting() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("keep")
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.pageAppeared()
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unavailable)
        controller.refresh([course], selected: course, force: true)
        await settle("failed") { controller.listing(for: course)?.problem == .unavailable }
        #expect(controller.study.bookmarks.first?.unavailable == false)
        browser.listResults[course.courseCode] = .success([])
        controller.refresh([course], selected: course, force: true)
        await settle("missing") { controller.study.bookmarks.first?.unavailable == true }
        #expect(controller.study.contains(a))
        let updated = RecmanRecording(id: a.id, courseCode: a.courseCode, academicYear: a.academicYear, title: "Renamed", recordedAt: a.recordedAt, kind: a.kind, duration: "70 min", size: a.size, previewURL: a.previewURL)
        browser.listResults[course.courseCode] = .success([updated])
        controller.refresh([course], selected: course, force: true)
        await settle("returned") { controller.study.bookmarks.first?.recording.title == "Renamed" }
        #expect(controller.study.bookmarks.first?.unavailable == false)
        controller.turnOff()
    }

    /// No valid account means no personal state can be written or borrowed from another account.
    @Test func unknownOwnerCannotEditStudy() {
        defer { cleanUp() }
        world.owner = nil
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        defaults.resetWrites()
        controller.toggleWatchlist(recording("a"), courseName: "NLA")
        #expect(controller.study.bookmarks.isEmpty)
        #expect(defaults.writes.isEmpty)
        controller.turnOff()
    }

}

/// Recordings through the real account controller: disconnecting, switching university and a
/// different WeBeep account all delete the Polimi session, even one saved in an earlier launch.
@MainActor
struct RecordingsAccountTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-account-\(UUID().uuidString)", isDirectory: true)

    private var store: RecordingsSessionStore {
        let folder = root.appendingPathComponent("support", isDirectory: true)
        return RecordingsSessionStore { folder }
    }

    private func session(owner: Int) throws -> Data {
        try RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN")], ownerUserID: owner)
    }

    @Test func disconnectingOrSwitchingUniversityDeletesThePolimiSession() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(session(owner: 1))
        let controller = WeBeepAuthenticationController(testRootURL: root.appendingPathComponent("sync"), deleteCredential: {}, defaults: defaults, recordingsStore: store)
        // Not touched in this launch: the sign-out must still find and delete the session.
        #expect(controller.recordingsIfCreated == nil)

        controller.signOut()
        #expect(!controller.hasStoredCredential)
        #expect(try store.load() == nil)
        #expect(defaults.object(forKey: RecordingsController.enabledKey) == nil)
        #expect(!controller.recordings.isEnabled)

        // Switching university, with nothing connected, drops whatever is saved too.
        try store.save(session(owner: 1))
        controller.selectSite(MoodleSite.unipd[0])
        #expect(try store.load() == nil)
    }

    /// A failed disconnect keeps the account, and with it the Recordings switch and session.
    @Test func aFailedDisconnectKeepsTheSession() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        let saved = try session(owner: 1)
        try store.save(saved)
        let controller = WeBeepAuthenticationController(testRootURL: root.appendingPathComponent("sync"), deleteCredential: { throw CredentialStorageError.write }, defaults: defaults, recordingsStore: store)
        controller.signOut()
        #expect(controller.hasStoredCredential)
        #expect(try store.load() == saved)
        #expect(defaults.bool(forKey: RecordingsController.enabledKey))
    }

    /// The account controller tells Recordings who is signed in to WeBeep: a session saved for
    /// another account (used while the account was unknown) is dropped once WeBeep answers.
    /// The local Moodle answers user id 7 (`MoodleRecordingProtocol`).
    @Test func signingInToAnotherWeBeepAccountDropsTheSession() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: sync.path)
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")])
        let vault = CredentialVault(read: { _ in token }, write: { _ in })
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(session(owner: 9))
        let browser = FakeRecmanBrowser()
        let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
        browser.listResults[key.courseCode] = .success([])
        let controller = WeBeepAuthenticationController(testRootURL: sync, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault, defaults: defaults, recordingsStore: store, recordingsBrowser: { browser })

        let recordings = controller.recordings
        recordings.pageAppeared()
        recordings.refresh([key], selected: key)
        for _ in 0..<2_000 where recordings.listing(for: key)?.recordings == nil { try await Task.sleep(for: .milliseconds(1)) }
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(try store.load() != nil)

        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        #expect(controller.courseLoadError == nil)
        #expect(try store.load() == nil)
        #expect(recordings.access == .needsSignIn(nil))
        #expect(!browser.isOpen)
    }

}
