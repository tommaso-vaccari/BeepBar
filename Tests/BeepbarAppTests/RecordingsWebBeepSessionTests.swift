import AppKit
import Foundation
import os
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The Polimi session that comes with the WeBeep sign-in (#234): `RecordingsController`'s
/// session candidate, offered after a validated login and used once for the first entry into the
/// archive. Real controller, real session file in a throwaway folder, scripted browser. Every
/// test says what it proves and the guard whose removal turns it red.
@MainActor
struct RecordingsWebBeepSessionTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-webbeep-\(UUID().uuidString)", isDirectory: true)
    private let defaults = MemoryCountingDefaults.isolated()
    private let browser = FakeRecmanBrowser()
    private let world = RecordingsWorld()
    /// Test hook run once at the next owner read after a browser was made (`onOwnerRead`).
    private final class Hooks { var onOwnerRead: (() -> Void)? }
    private let hooks = Hooks()
    private let course = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private var store: RecordingsSessionStore {
        let folder = folder
        return RecordingsSessionStore { folder }
    }
    private var sessionFile: URL { folder.appendingPathComponent(RecordingsSessionStore.fileName) }

    private func makeController() -> RecordingsController {
        let world = world
        let browser = browser
        let folder = folder
        let hooks = hooks
        return RecordingsController(
            makeBrowser: { world.browsersMade += 1; return browser },
            store: RecordingsSessionStore { folder },
            defaults: defaults,
            makeSeenHistory: { namespace in
                let history = RecordingsSeenHistory(store: RecordingsSeenStore(directory: { folder }, namespace: namespace))
                world.historyActors.append(history)
                return history
            },
            ownerUserID: {
                // Runs inside the drain's look at the candidate, after its browser was made.
                if world.browsersMade == 1, let hook = hooks.onOwnerRead { hooks.onOwnerRead = nil; hook() }
                return world.owner
            },
            isAvailable: { world.polimi },
            openURL: { world.opened.append($0) },
            copy: { world.copied.append($0) },
            now: { MainActor.assumeIsolated { world.now } },
            makePlayer: { world.playersMade += 1; return world.player },
            courses: { world.courses }
        )
    }

    /// The feature on, optionally with a saved session of account 42 holding the cookie `saved`.
    private func launched(savedFile: Bool = false) throws -> RecordingsController {
        defaults.set(true, forKey: RecordingsController.enabledKey)
        if savedFile {
            try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_SAVED")], ownerUserID: 42, now: world.now))
        }
        return makeController()
    }

    private func login(_ name: String = "SSO_LOGIN") -> [HTTPCookie] { [FakeRecmanBrowser.cookie(name)] }

    private func recording(_ id: String) -> RecmanRecording {
        RecmanRecording(id: id, courseCode: course.courseCode, academicYear: course.academicYear, title: "Lezione \(id)", recordedAt: world.now.addingTimeInterval(-86_400), kind: "Lezione", duration: "90 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=1&transfer_id=\(id)")!)
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

    private func savedOwner() throws -> Int? {
        guard let data = try store.load() else { return nil }
        return try RecmanSessionCodec.decode(data, now: world.now).ownerUserID
    }

    private func waitUntil(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("never happened: \(comment)", sourceLocation: sourceLocation)
    }

    // MARK: Use

    /// A new user has no saved session: the candidate from the WeBeep sign-in opens the archive in
    /// the background, with no Polimi sign-in window, and only then is the file written.
    /// Guards a second Polimi login after WeBeep's, a session file written before the entry
    /// worked, and a session saved for no account. Mutations: make `savedCookies` ignore the
    /// candidate (the browser opens with no cookies and the refresh is skipped as needing a
    /// sign-in); write the file in `offerSessionCandidate`.
    @Test func theCandidateEntersTheArchiveWithoutSignInAndIsThenSaved() async throws {
        defer { cleanUp() }
        let controller = try launched()
        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.offerSessionCandidate(login(), owner: 42)
        #expect(!FileManager.default.fileExists(atPath: sessionFile.path), "offering writes nothing")

        let outcome = await controller.refreshForSync([course], force: false)
        #expect(outcome == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(!browser.calls.contains("signIn"), "no sign-in window was needed")
        #expect(controller.access == .ready)
        await controller.settleSessionFile()
        #expect(try savedOwner() == 42, "saved after the entry worked, under the verified account")
    }

    /// The Recordings page's first visit uses the candidate too, not only a sync's refresh.
    /// Mutation: take the candidate in the refresh path only.
    @Test func thePageUsesTheCandidateToo() async throws {
        defer { cleanUp() }
        let controller = try launched()
        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.offerSessionCandidate(login(), owner: 42)
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await waitUntil("the listing") { controller.listing(for: course)?.recordings != nil }
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(controller.access == .ready)
        controller.pageDisappeared()
    }

    /// With a saved file of the same account, the fresh candidate is the one the browser opens with.
    /// Guards reusing an older session when the user has just signed in. Mutation: return the
    /// file's cookies in `savedCookies` when a candidate exists.
    @Test func theCandidateIsPreferredToTheSavedFileOfTheSameAccount() async throws {
        defer { cleanUp() }
        let controller = try launched(savedFile: true)
        browser.listResults[course.courseCode] = .success([])
        controller.offerSessionCandidate(login("SSO_FRESH"), owner: 42)
        _ = await controller.refreshForSync([course], force: false)
        #expect(browser.openedWith == [["SSO_FRESH"]])
    }

    /// An entry that fails leaves the user where they are today: needs a sign-in, nothing written,
    /// and the candidate is not tried again. Guards a candidate that keeps failing the same way
    /// on every sync, and a session file written for cookies that did not work. Mutation: drop
    /// `sessionCandidate = nil` after the opening in `drain`: the second open reuses it.
    @Test func aFailedEntryWritesNothingAndTheCandidateIsNotReused() async throws {
        defer { cleanUp() }
        let controller = try launched()
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        controller.offerSessionCandidate(login(), owner: 42)
        _ = await controller.refreshForSync([course], force: false)
        #expect(controller.access == .needsSignIn(nil))
        await controller.settleSessionFile()
        #expect(!FileManager.default.fileExists(atPath: sessionFile.path), "no file for cookies that did not open the archive")

        // A later opening (here a sign-in the student asks for, which starts a browser) has no
        // candidate to use.
        controller.signIn()
        await waitUntil("the sign-in opened a browser") { browser.openedWith.count == 2 }
        #expect(browser.openedWith == [["SSO_LOGIN"], []])
    }

    /// A listing error that is not "sign in again" also ends the use of the candidate: one use,
    /// whatever the outcome. Mutation: consume it only on `needsSignIn`.
    @Test func theCandidateIsUsedOnceEvenWhenTheListingFailsOtherwise() async throws {
        defer { cleanUp() }
        let controller = try launched()
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unrecognized)
        controller.offerSessionCandidate(login(), owner: 42)
        _ = await controller.refreshForSync([course], force: false)
        browser.listResults[course.courseCode] = .success([])
        _ = await controller.refreshForSync([course], force: true)
        #expect(browser.openedWith == [["SSO_LOGIN"], []])
    }

    /// A saved file left by another account (the normal state after a sign-in as someone else on
    /// a Mac where Recordings was used) is deleted when read, which bumps the session epoch; the
    /// new account's own candidate must survive that and enter the archive, on the sync's first
    /// opening. Guards a candidate thrown away by the discard of a file that was never its own.
    /// Mutation: make `discardUnusableFile` call `discardSessionFile` alone (no epoch follow).
    @Test func aForeignSavedFileDoesNotCostTheCandidate() async throws {
        defer { cleanUp() }
        let controller = try launched(savedFile: true)   // the file belongs to account 42
        world.owner = 43
        browser.listResults[course.courseCode] = .success([])
        controller.offerSessionCandidate(login("SSO_FOR_43"), owner: 43)
        _ = await controller.refreshForSync([course], force: false)
        #expect(browser.openedWith == [["SSO_FOR_43"]])
        await controller.settleSessionFile()
        #expect(try savedOwner() == 43)
    }

    // MARK: Identity

    /// A candidate made for another account is never kept, and one that was kept stops counting
    /// when the connected account is not its owner any more. Guards using account A's Polimi
    /// login for account B. Mutations: drop the `ownerUserID() == owner` check in
    /// `offerSessionCandidate`; drop it in `usableCandidate` and `savedCookies`.
    @Test func aCandidateOfAnotherOwnerIsIgnored() async throws {
        defer { cleanUp() }
        let controller = try launched()
        controller.offerSessionCandidate(login(), owner: 43)
        let outcome = await controller.refreshForSync([course], force: false)
        #expect(outcome == .needsSignIn(newlyPublished: 0))
        #expect(world.browsersMade == 0)

        // Offered for 43 while 42 is connected, then 43 connects: the offer-time check alone keeps
        // it out (the use-time check would now agree), so the two guards are tested separately.
        let early = try launched()
        early.offerSessionCandidate(login(), owner: 43)
        world.owner = 43
        #expect(await early.refreshForSync([course], force: false) == .needsSignIn(newlyPublished: 0))
        #expect(world.browsersMade == 0)
        world.owner = 42

        // Kept for 42, then the connected account is another one before the first use.
        let second = try launched()
        second.offerSessionCandidate(login(), owner: 42)
        world.owner = 43
        let again = await second.refreshForSync([course], force: false)
        #expect(again == .needsSignIn(newlyPublished: 0))
        #expect(world.browsersMade == 0)
    }

    /// Cookies that are not Polimi's, or have expired, never become a candidate. Guards another
    /// site's cookies (a tracker, a lookalike domain) entering the browser and then the file.
    /// Mutation: skip the filter in `sessionCookies`.
    @Test func onlyLivePolimiCookiesAreKept() {
        let live = FakeRecmanBrowser.cookie("LIVE", domain: "shibidp.polimi.it")
        let expired = HTTPCookie(properties: [.name: "OLD", .value: "v", .domain: "webeep.polimi.it", .path: "/", .expires: world.now.addingTimeInterval(-60)])!
        let notPolimi = FakeRecmanBrowser.cookie("TRACKER", domain: "example.com")
        let lookalike = FakeRecmanBrowser.cookie("LOOK", domain: "evilpolimi.it")
        let kept = RecordingsController.sessionCookies(from: [live, expired, notPolimi, lookalike], now: world.now)
        #expect(kept.map(\.name) == ["LIVE"])
    }

    /// With nothing Polimi in the sign-in window's store there is no candidate: the browser is
    /// not made, as today. Mutation: store an empty candidate.
    @Test func noPolimiCookiesNoCandidate() async throws {
        defer { cleanUp() }
        let controller = try launched()
        controller.offerSessionCandidate([FakeRecmanBrowser.cookie("TRACKER", domain: "example.com")], owner: 42)
        #expect(await controller.refreshForSync([course], force: false) == .needsSignIn(newlyPublished: 0))
        #expect(world.browsersMade == 0)
    }

    /// Not for Unipd, and not with the feature off: a candidate offered then is not kept, so it
    /// is not there when the controller becomes usable (switch turned on, or Polimi selected).
    /// The sign-in that the switch starts shows it: it opens with the candidate's cookies if one
    /// was kept, with none otherwise. Mutation: drop `isEnabled, isAvailable()` from
    /// `offerSessionCandidate`.
    @Test(arguments: ["unipd", "off"]) func notOfferedOutsidePolimiOrWithTheFeatureOff(case name: String) async throws {
        defer { cleanUp() }
        if name == "unipd" { world.polimi = false } else { defaults.set(false, forKey: RecordingsController.enabledKey) }
        let controller = makeController()
        controller.offerSessionCandidate(login(), owner: 42)
        world.polimi = true
        controller.setEnabled(true)
        await waitUntil("the sign-in opened a browser") { browser.openedWith.count == 1 }
        #expect(browser.openedWith == [[]], "no candidate was kept")
        controller.turnOff()
    }

    // MARK: Clean-up

    /// The candidate goes with the account, the switch and the connection: turning Recordings
    /// off (the switch, logout and a university change all end in `turnOff`) leaves nothing to
    /// reuse when it is turned on again. Mutation: remove `sessionCandidate = nil` from
    /// `turnOff` together with the epoch check in `usableCandidate` (the discard in `turnOff`
    /// bumps the epoch, which alone also ends it).
    @Test(arguments: [true, false]) func turningRecordingsOffDropsTheCandidate(viaSwitch: Bool) async throws {
        defer { cleanUp() }
        let controller = try launched()
        controller.offerSessionCandidate(login(), owner: 42)
        if viaSwitch { controller.setEnabled(false) } else { controller.turnOff() }
        controller.setEnabled(true)
        await waitUntil("the sign-in opened a browser") { browser.openedWith.count == 1 }
        #expect(browser.openedWith == [[]], "signing in again starts with the cookies of no candidate")
        controller.turnOff()
    }

    /// An account change drops the candidate made for the previous account, and a candidate
    /// delivered after the change survives it (the order `completeLogin` relies on).
    /// Mutations: remove the owner check in `webBeepAccountChanged` (a candidate comes back when
    /// its account does); have it clear every candidate (one for the new account would not survive).
    @Test func anAccountChangeDropsTheOldCandidateAndKeepsTheNewOne() async throws {
        defer { cleanUp() }
        let controller = try launched()
        browser.listResults[course.courseCode] = .success([])
        controller.offerSessionCandidate(login("SSO_OLD"), owner: 42)
        world.owner = 43
        controller.webBeepAccountChanged(to: 43)
        #expect(await controller.refreshForSync([course], force: false) == .needsSignIn(newlyPublished: 0))
        #expect(world.browsersMade == 0, "account 42's login is not used for account 43")

        // 42 -> 43 -> 42: the use-time owner check would accept the old candidate again, so only
        // the clear in `webBeepAccountChanged` keeps it out.
        world.owner = 42
        let back = try launched()
        back.offerSessionCandidate(login("SSO_OLD"), owner: 42)
        world.owner = 43
        back.webBeepAccountChanged(to: 43)
        world.owner = 42
        #expect(await back.refreshForSync([course], force: false) == .needsSignIn(newlyPublished: 0))
        #expect(world.browsersMade == 0, "a candidate does not come back when its account does")

        // A change to the candidate's own account does not drop it, whatever the order.
        let same = try launched()
        same.offerSessionCandidate(login("SSO_SAME"), owner: 42)
        same.webBeepAccountChanged(to: 42)
        _ = await same.refreshForSync([course], force: false)
        #expect(browser.openedWith == [["SSO_SAME"]])

        world.owner = 43
        let next = try launched()
        next.offerSessionCandidate(login("SSO_OLD"), owner: 43)
        next.webBeepAccountChanged(to: 43)
        next.offerSessionCandidate(login("SSO_NEW"), owner: 43)
        _ = await next.refreshForSync([course], force: false)
        #expect(browser.openedWith.last == ["SSO_NEW"])
        #expect(browser.openedWith.first == ["SSO_SAME"])
    }

    // MARK: A sign-in already asked for

    /// An account change with the previous account's session in memory ends in `.needsSignIn`,
    /// and the new account's candidate arrives right after: it must be used, not consumed by a
    /// sign-in that opens with no cookies. Guards a new WeBeep login that is followed by a second
    /// Polimi login. Mutations: `offerSessionCandidate` not going back to `.ready`; `runSignIn`
    /// dropping the candidate when `freshSession`.
    @Test func aCandidateAfterAnAccountChangeWithASessionInMemoryEnters() async throws {
        defer { cleanUp() }
        let controller = try launched(savedFile: true)
        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await waitUntil("the listing") { controller.listing(for: course)?.recordings != nil }
        #expect(browser.openedWith == [["SSO_SAVED"]])

        world.owner = 43
        controller.webBeepAccountChanged(to: 43)
        #expect(controller.access == .needsSignIn(nil))
        controller.offerSessionCandidate(login("SSO_43"), owner: 43)
        #expect(controller.access == .ready, "the candidate gives the sign-in something to try")
        let outcome = await controller.refreshForSync([course], force: true)
        #expect(outcome == .refreshed(newlyPublished: 0, failedKeys: 0), "\(outcome) \(controller.access)")
        #expect(browser.openedWith == [["SSO_SAVED"], ["SSO_43"]])
        #expect(!browser.calls.contains("signIn"))
        controller.pageDisappeared()
    }

    /// The first check found no file and the student sits in `.needsSignIn`; a WeBeep login then
    /// delivers a candidate: the next sync enters with it without anyone pressing anything.
    /// Mutation: `offerSessionCandidate` without the return to `.ready` and the re-armed check.
    @Test func aCandidateAfterAnEmptyFirstCheckIsUsedByTheNextSync() async throws {
        defer { cleanUp() }
        let controller = try launched()
        browser.listResults[course.courseCode] = .success([])
        #expect(await controller.refreshForSync([course], force: false) == .needsSignIn(newlyPublished: 0))
        controller.offerSessionCandidate(login(), owner: 42)
        #expect(await controller.refreshForSync([course], force: true) == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.openedWith == [["SSO_LOGIN"]])
    }

    /// "Accedi con Polimi" with a candidate and a lapsed session (so `freshSession`) opens with
    /// the candidate, not with no cookies. Reached with a page on screen: its browser stays open
    /// after a cancelled sign-in, so an offer then leaves `.needsSignIn` alone.
    /// Mutation: `runSignIn` opening with `[]` whenever `freshSession`.
    @Test func signInOpensWithTheCandidateEvenAfterALapsedSession() async throws {
        defer { cleanUp() }
        let controller = try launched()
        controller.pageAppeared()
        browser.signInError = CancellationError()
        controller.signIn()
        await waitUntil("the first sign-in ended") { controller.access == .needsSignIn(nil) }
        #expect(browser.isOpen, "the page keeps the browser")
        controller.offerSessionCandidate(login(), owner: 42)
        #expect(controller.access == .needsSignIn(nil), "a browser is open: its sign-in is the student's")
        browser.signInError = nil
        controller.signIn()
        await waitUntil("the second sign-in opened a browser") { browser.openedWith.count == 2 }
        #expect(browser.openedWith == [[], ["SSO_LOGIN"]])
        controller.pageDisappeared()
    }

    /// The sign-in takes the candidate: a second one after a cancelled first starts with nothing.
    /// Mutation: drop `consumeCandidate` in `runSignIn`.
    @Test func theSignInConsumesTheCandidate() async throws {
        defer { cleanUp() }
        let controller = try launched()
        controller.offerSessionCandidate(login(), owner: 42)
        browser.signInError = CancellationError()
        controller.signIn()
        await waitUntil("the first sign-in ended") { controller.access == .needsSignIn(nil) }
        controller.signIn()
        await waitUntil("the second sign-in opened a browser") { browser.openedWith.count == 2 }
        #expect(browser.openedWith == [["SSO_LOGIN"], []])
    }

    // MARK: One use, exactly

    /// A candidate that arrives while the file is being read, and is not the one the browser was
    /// opened with, is not consumed by that opening. The hook offers a second candidate at the
    /// moment the first is looked at. Guards a login lost to an unrelated opening.
    /// Mutation: clear the candidate after the opening whatever its serial.
    @Test func aCandidateThatArrivedDuringTheReadIsNotConsumedByTheOpening() async throws {
        defer { cleanUp() }
        let controller = try launched(savedFile: true)
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        controller.offerSessionCandidate(login("SSO_FIRST"), owner: 42)
        hooks.onOwnerRead = { controller.offerSessionCandidate(self.login("SSO_SECOND"), owner: 42) }
        _ = await controller.refreshForSync([course], force: false)
        #expect(hooks.onOwnerRead == nil, "the hook ran")
        #expect(browser.openedWith == [["SSO_SAVED"]], "the first opening did not use the newer candidate")
        controller.signIn()
        await waitUntil("the sign-in opened a browser") { browser.openedWith.count == 2 }
        #expect(browser.openedWith == [["SSO_SAVED"], ["SSO_SECOND"]])
    }

    /// A candidate that arrives with the browser already open is not for a later opening once the
    /// session it stands beside was saved: the file then holds a session at least as new.
    /// Both ways the save ends (`.saved`, cookies changed; `.unchanged`, same ones).
    /// Mutations: drop `sessionCandidate = nil` from the `.saved` case, or from `.unchanged`.
    @Test(arguments: [true, false]) func aSavedSessionRetiresALateCandidate(changed: Bool) async throws {
        defer { cleanUp() }
        let controller = try launched(savedFile: true)
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([])
        if changed { browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_RENEWED")] }
        let outcome = Task { await controller.refreshForSync([course], force: false) }
        await waitUntil("the listing is held") { gate.isWaiting }
        controller.offerSessionCandidate(login("SSO_LATE"), owner: 42)
        gate.release()
        _ = await outcome.value
        await controller.settleSessionFile()
        browser.listGates[course.courseCode] = nil
        _ = await controller.refreshForSync([course], force: true)
        #expect(browser.openedWith.count == 2)
        #expect(browser.openedWith.last != ["SSO_LATE"], "the late candidate was not kept")
    }

    // MARK: The saved file as a way back

    /// A candidate that Polimi refuses falls back, once, on the same account's saved cookies: the
    /// entry works and the session is not lost. Mutation: no fallback in `drain`.
    @Test func aRefusedCandidateFallsBackOnTheSavedFile() async throws {
        defer { cleanUp() }
        let controller = try launched(savedFile: true)
        browser.rejectedCookieNames = ["SSO_LOGIN"]
        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.offerSessionCandidate(login(), owner: 42)
        #expect(await controller.refreshForSync([course], force: false) == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.openedWith == [["SSO_LOGIN"], ["SSO_SAVED"]])
        #expect(controller.access == .ready)
        await controller.settleSessionFile()
        #expect(try savedOwner() == 42, "the session file is still there")
    }

    /// With no file, or one of another account, there is nothing to fall back on: one entry,
    /// `.needsSignIn`, nothing written. Mutation: a second attempt with no cookies, or with
    /// another account's.
    @Test(arguments: [false, true]) func aRefusedCandidateWithoutAUsableFileGoesToSignIn(foreignFile: Bool) async throws {
        defer { cleanUp() }
        let controller = try launched(savedFile: foreignFile)
        if foreignFile { world.owner = 43 }
        browser.rejectedCookieNames = ["SSO_LOGIN"]
        browser.listResults[course.courseCode] = .success([])
        controller.offerSessionCandidate(login(), owner: world.owner ?? 42)
        #expect(await controller.refreshForSync([course], force: false) == .needsSignIn(newlyPublished: 0))
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        await controller.settleSessionFile()
        #expect(try savedOwner() == nil, "nothing written (the foreign file was deleted, not replaced)")
    }
}

/// The login completion hands Recordings the candidate, in the right order and only for a login
/// that was validated and stored. The local Moodle answers `MoodleRecordingProtocol`.
@MainActor
struct WebBeepLoginSessionHandoverTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-handover-\(UUID().uuidString)", isDirectory: true)
    private let course = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private var store: RecordingsSessionStore {
        let folder = root.appendingPathComponent("support", isDirectory: true)
        return RecordingsSessionStore { folder }
    }

    private func makeController(token: String, browser: FakeRecmanBrowser, site: MoodleSite = .polimi, failSave: Bool = false) -> WeBeepAuthenticationController {
        let current = OSAllocatedUnfairLock(initialState: token)
        let vault = CredentialVault(read: { _ in current.withLock { $0 } }, write: { new in
            if failSave { throw CredentialStorageError.write }
            current.withLock { $0 = new }
        })
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        return WeBeepAuthenticationController(testRootURL: root.appendingPathComponent("sync"), apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault, defaults: defaults, recordingsStore: store, recordingsBrowser: { browser }, site: site)
    }

    private func cookie(_ name: String) -> [HTTPCookie] { [FakeRecmanBrowser.cookie(name)] }

    /// A validated and stored login delivers its Polimi cookies: Recordings enters the archive
    /// with them and no sign-in, for the verified account. Mutation: drop the delivery in
    /// `completeLogin`.
    @Test func aValidatedLoginHandsOverItsCookies() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let browser = FakeRecmanBrowser()
        browser.listResults[course.courseCode] = .success([])
        let controller = makeController(token: token, browser: browser)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token), polimiCookies: cookie("SSO_LOGIN"))
        #expect(await controller.recordings.refreshForSync([course], force: false) == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(!browser.calls.contains("signIn"))
        await controller.recordings.settleSessionFile()
        let saved = try #require(try store.load())
        #expect(try RecmanSessionCodec.decode(saved, now: Date()).ownerUserID == 7)
    }

    /// A token that WeBeep rejects, or that cannot be stored, hands over nothing: not even the
    /// controller is created for it. Guards a session candidate for a login that did not
    /// succeed. Mutation: deliver before `validateToken`, or before `credentialVault.save`.
    @Test(arguments: ["invalid", "save"]) func aLoginThatFailsHandsOverNothing(mode: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let browser = FakeRecmanBrowser()
        let controller = makeController(token: token, browser: browser, failSave: mode == "save")
        let used = mode == "invalid" ? "not-a-token" : token
        await controller.completeLoginForTesting(moodleLoginCallback(token: used), polimiCookies: cookie("SSO_LOGIN"))
        #expect(controller.authenticationFeedback != nil)
        #expect(controller.recordingsIfCreated == nil)
        #expect(browser.openedWith.isEmpty)
    }

    /// A cancelled login (no callback) hands over nothing either.
    @Test func aCancelledLoginHandsOverNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let controller = makeController(token: token, browser: FakeRecmanBrowser())
        await controller.completeLoginForTesting(URL(string: "moodlemobile://nothing")!, polimiCookies: cookie("SSO_LOGIN"))
        #expect(controller.recordingsIfCreated == nil)
    }

    /// Unipd has no Recordings: its login hands nothing to a controller that is not created.
    /// Mutation: drop the `university == .polimi` check in `completeLogin`.
    @Test func unipdHandsOverNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let controller = makeController(token: token, browser: FakeRecmanBrowser(), site: MoodleSite.unipd[0])
        await controller.completeLoginForTesting(moodleLoginCallback(token: token), polimiCookies: cookie("SSO_LOGIN"))
        #expect(controller.recordingsIfCreated == nil)
    }

    /// Signing in as another account: the first account really enters (its session is in the
    /// file and was in use), then the new login's candidate, delivered after the account-change
    /// cleanup, is the one used. Guards the order in `completeLogin` and the way back from the
    /// `.needsSignIn` that the account change leaves. Mutations: move the delivery above
    /// `self.siteInfo = siteInfo`; `offerSessionCandidate` not returning to `.ready`.
    @Test func theNewAccountsCandidateSurvivesTheAccountChange() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let second = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 8)
        let browser = FakeRecmanBrowser()
        browser.listResults[course.courseCode] = .success([])
        let controller = makeController(token: first, browser: browser)
        await controller.completeLoginForTesting(moodleLoginCallback(token: first), polimiCookies: cookie("SSO_ACCOUNT_7"))
        #expect(await controller.recordings.refreshForSync([course], force: false) == .refreshed(newlyPublished: 0, failedKeys: 0))
        await controller.recordings.settleSessionFile()
        #expect(try RecmanSessionCodec.decode(try #require(try store.load()), now: Date()).ownerUserID == 7)

        await controller.completeLoginForTesting(moodleLoginCallback(token: second), polimiCookies: cookie("SSO_ACCOUNT_8"))
        _ = await controller.recordings.refreshForSync([course], force: false)
        #expect(browser.openedWith == [["SSO_ACCOUNT_7"], ["SSO_ACCOUNT_8"]])
        await controller.recordings.settleSessionFile()
        let saved = try #require(try store.load())
        #expect(try RecmanSessionCodec.decode(saved, now: Date()).ownerUserID == 8)
    }

    /// Logout turns Recordings off for the rest of the launch (`turnOff`), although the stored
    /// choice (absent: on) says on. A validated Polimi login brings it back as at a normal start,
    /// then hands over the candidate, which is used with no window. Mutation: drop
    /// `resumeIfSwitchedOn()` in `completeLogin`.
    @Test func aNewLoginAfterLogoutTurnsRecordingsBackOnAndEnters() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let browser = FakeRecmanBrowser()
        browser.listResults[course.courseCode] = .success([])
        let controller = makeController(token: token, browser: browser)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token), polimiCookies: cookie("SSO_FIRST"))
        controller.signOut(removeFile: { _ in })
        #expect(controller.recordings.isEnabled == false)

        await controller.completeLoginForTesting(moodleLoginCallback(token: token), polimiCookies: cookie("SSO_AGAIN"))
        #expect(controller.recordings.isEnabled)
        #expect(controller.recordings.access == .ready, "back on, no sign-in started")
        #expect(browser.openedWith.isEmpty)
        #expect(await controller.recordings.refreshForSync([course], force: false) == .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(browser.openedWith == [["SSO_AGAIN"]])
        #expect(!browser.calls.contains("signIn"))
    }

    /// A switch the user turned off stays off through a new login: no candidate is kept either.
    /// Mutation: have `resumeIfSwitchedOn` ignore the stored choice.
    @Test func aSwitchTurnedOffStaysOffAfterANewLogin() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let browser = FakeRecmanBrowser()
        let controller = makeController(token: token, browser: browser)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token), polimiCookies: cookie("SSO_FIRST"))
        controller.recordings.setEnabled(false)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token), polimiCookies: cookie("SSO_AGAIN"))
        #expect(controller.recordings.isEnabled == false)
        #expect(await controller.recordings.refreshForSync([course], force: false) == .skipped(.switchedOff))
        #expect(browser.openedWith.isEmpty)
    }

    /// The sign-in window closed while its cookies are read: the token has arrived, so the login
    /// completes (with no cookies) instead of ending as cancelled; and "Ricarica" in that moment
    /// is ignored. Mutation: `windowClosed` finishing with `.cancelled` in every phase; `retry()`
    /// without its `.collecting` guard.
    @Test func aWindowClosedWhileTheCookiesAreReadCompletesTheLogin() {
        let results = OSAllocatedUnfairLock<[String]>(initialState: [])
        let window = LoginWindowController(site: .polimi) { result, cookies in
            switch result {
            case .success: results.withLock { $0.append("success \(cookies.count)") }
            case .failure: results.withLock { $0.append("failure") }
            }
        }
        window.beginCollectingForTesting(URL(string: "moodlemobile://token=x")!)
        window.reloadForTesting()
        #expect(window.isCollectingForTesting, "a reload does not undo a finished login")
        window.closeWindowForTesting()
        #expect(results.withLock { $0 } == ["success 0"])
    }

    /// A second account whose own login carries no Polimi cookies must not inherit the first
    /// one's. Mutation: remove the owner check in `webBeepAccountChanged`.
    @Test func theOldAccountsCandidateIsGoneAfterAnAccountChange() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let second = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 8)
        let browser = FakeRecmanBrowser()
        let controller = makeController(token: first, browser: browser)
        await controller.completeLoginForTesting(moodleLoginCallback(token: first), polimiCookies: cookie("SSO_ACCOUNT_7"))
        await controller.completeLoginForTesting(moodleLoginCallback(token: second))
        #expect(await controller.recordings.refreshForSync([course], force: false) == .needsSignIn(newlyPublished: 0))
        #expect(browser.openedWith.isEmpty)
    }

    /// The WeBeep sign-in window edits like a Mac text field: ⌘V pastes a password. The app has
    /// no Edit menu, so the window's web view must be the one that handles the shortcuts itself
    /// (`RecmanSignInWebView.editingAction`, tested in `RecmanWebSessionTests`). What the keys
    /// really do in a live window can't be checked here. Mutation: back to a plain `WKWebView`.
    @Test func theLoginWindowUsesTheWebViewWithEditingShortcuts() {
        let window = LoginWindowController(site: .polimi) { _, _ in }
        #expect(window.webViewHandlesEditingShortcutsForTesting)
    }
}
