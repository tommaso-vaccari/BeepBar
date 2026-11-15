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

    /// Not for Unipd, and not with the feature off.
    /// Mutation: drop `isEnabled, isAvailable()` from `offerSessionCandidate`.
    @Test func notOfferedOutsidePolimiOrWithTheFeatureOff() async throws {
        defer { cleanUp() }
        world.polimi = false
        let unipd = try launched()
        unipd.offerSessionCandidate(login(), owner: 42)
        world.polimi = true
        // The same controller later on Polimi would use a candidate kept from before: none is.
        #expect(await unipd.refreshForSync([course], force: false) == .skipped(.switchedOff))
        let later = await unipd.refreshForSync([course], force: false)
        #expect(later != .refreshed(newlyPublished: 0, failedKeys: 0), "nothing was kept for the account")
        #expect(world.browsersMade == 0)

        // Switched off, offered, then switched on again behind the controller's back (no
        // `turnOff`, which would discard it anyway): still nothing to use.
        defaults.set(false, forKey: RecordingsController.enabledKey)
        let off = makeController()
        off.offerSessionCandidate(login(), owner: 42)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        let afterwards = await off.refreshForSync([course], force: false)
        #expect(afterwards != .refreshed(newlyPublished: 0, failedKeys: 0))
        #expect(world.browsersMade == 0)
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

    /// Signing in as another account: the previous candidate goes with the account change and the
    /// new login's candidate, delivered after it, is the one used. Guards the order in
    /// `completeLogin`: delivering before `siteInfo` changes would have the cleanup throw the
    /// new candidate away (or keep a foreign one). Mutation: move the delivery above
    /// `self.siteInfo = siteInfo`.
    @Test func theNewAccountsCandidateSurvivesTheAccountChange() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 7)
        let second = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 8)
        let browser = FakeRecmanBrowser()
        browser.listResults[course.courseCode] = .success([])
        let controller = makeController(token: first, browser: browser)
        await controller.completeLoginForTesting(moodleLoginCallback(token: first), polimiCookies: cookie("SSO_ACCOUNT_7"))
        await controller.completeLoginForTesting(moodleLoginCallback(token: second), polimiCookies: cookie("SSO_ACCOUNT_8"))
        _ = await controller.recordings.refreshForSync([course], force: false)
        #expect(browser.openedWith == [["SSO_ACCOUNT_8"]])
        await controller.recordings.settleSessionFile()
        let saved = try #require(try store.load())
        #expect(try RecmanSessionCodec.decode(saved, now: Date()).ownerUserID == 8)
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
