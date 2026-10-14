import AppKit
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The recordings lines of the menu bar (package F of "recording view tracking"): what the menu
/// shows of each synced course's watch summary, read from the snapshot only. The account tests run
/// the real account controller against the local Moodle (`MoodleRecordingProtocol`, user id 7)
/// and never switch `AppLanguage.current`: the language is checked through the explicit
/// `recordingMenuSection(_:language:)`. Each test says what it proves and which mutation turns it
/// red.
@MainActor
struct RecordingsMenuBarTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-menu-\(UUID().uuidString)", isDirectory: true)
    private let analisi = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private let fisica = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!
    /// Sidebar order as WeBeep lists them: Fisica first, then Analisi, then a course with no
    /// archive key (no code), which never has recordings.
    private let accountCourses: [(id: Int64, name: String)] = [
        (12, "052499 - FISICA [2026-27]"),
        (11, "058167 - ANALISI 2 [2026-27]"),
        (13, "Seminario senza codice"),
    ]
    private let analisiSummary = CourseWatchSummary(done: 12, total: 30, remainingMinutes: 840, unknownDurationCount: 0)
    private let fisicaSummary = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 45, unknownDurationCount: 0)

    private var store: RecordingsSessionStore {
        let folder = root.appendingPathComponent("support", isDirectory: true)
        return RecordingsSessionStore { folder }
    }

    /// Saves summaries for `owner` the way an earlier launch's controller did.
    private func storeSummaries(_ courses: [RecmanCourseKey: CourseWatchSummary], owner: Int, in defaults: UserDefaults) throws {
        let stored = RecordingsController.StoredWatchSummaries(owner: owner, courses: Dictionary(uniqueKeysWithValues: courses.map { ("\($0.key.courseCode)-\($0.key.academicYear)", $0.value) }))
        defaults.set(try PropertyListEncoder().encode(stored), forKey: RecordingsController.watchSummaryKey)
    }

    /// A relaunch: a fresh account controller on `defaults`, signed in to the local Moodle as user 7
    /// with `accountCourses`, Recordings never touched. `deleteCredential` is inert so a sign-out
    /// never reaches the real token file.
    private func signedIn(defaults: UserDefaults, site: MoodleSite = .polimi, browser: FakeRecmanBrowser? = nil, language: AppLanguage = .italian) async throws -> WeBeepAuthenticationController {
        let controller = try await makeController(defaults: defaults, site: site, browser: browser, language: language)
        await signIn(controller, as: 7)
        return controller
    }

    /// The token the vault hands out: the last account signed in, as the real vault saves it.
    private final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var token = ""
        var value: String {
            get { lock.withLock { token } }
            set { lock.withLock { token = newValue } }
        }
    }
    private let tokens = TokenBox()
    /// The database and root of the last controller `makeController` built, so a test can seed
    /// scopes the way an earlier launch left them.
    private final class SeedBox: @unchecked Sendable {
        var database: SyncDatabase?
        var rootID: UUID?
    }
    private let seeds = SeedBox()

    /// A fresh account controller on `defaults` (a relaunch), not signed in yet.
    private func makeController(defaults: UserDefaults, site: MoodleSite = .polimi, browser: FakeRecmanBrowser? = nil, language: AppLanguage = .italian) async throws -> WeBeepAuthenticationController {
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state-\(UUID().uuidString).sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: sync.path)
        seeds.database = database
        seeds.rootID = rootID
        let tokens = tokens
        let vault = CredentialVault(read: { _ in tokens.value }, write: { tokens.value = $0 })
        var makeBrowser: (@MainActor () -> RecmanBrowsing)?
        if let browser { makeBrowser = { browser } }
        return WeBeepAuthenticationController(testRootURL: sync, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault, deleteCredential: {}, defaults: defaults, recordingsStore: store, recordingsBrowser: makeBrowser, site: site, language: language)
    }

    /// Signs `controller` in to the local Moodle as WeBeep user `userID` with `accountCourses`,
    /// through the real login path (`siteInfo` changes directly, without passing through nil).
    private func signIn(_ controller: WeBeepAuthenticationController, as userID: Int) async {
        let token = MoodleRecordingProtocol.register(courses: accountCourses, userID: userID)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        #expect(controller.courseLoadError == nil)
        #expect(controller.courses.count == accountCourses.count)
    }

    /// Selects exactly `ids` for sync, as the Corsi page does.
    private func select(_ ids: Set<Int64>, on controller: WeBeepAuthenticationController) {
        for course in controller.courses {
            controller.setCourse(course, enabled: ids.contains(course.id))
        }
        #expect(controller.enabledCourseIDs == ids)
    }

    private func course(_ id: Int64, _ name: String) -> RemoteCourseSummary {
        RemoteCourseSummary(id: id, shortName: name, displayName: name, isVisible: true, startDate: nil, endDate: nil)
    }

    private func lines(_ controller: WeBeepAuthenticationController) -> [String] { controller.menuBarSnapshot.recordingLines.map(\.title) }

    // MARK: Selection

    /// The menu shows a line only for courses synced right now, in the sidebar's order; a
    /// deselected course's line goes at once, its summary is kept, and selecting it again brings
    /// the line back without a request. Guards against a menu that keeps a course the student just
    /// removed (or lags a selection change until some unrelated refresh).
    /// Mutations: drop `recordingMenuInputsChanged()` from `enabledCourseIDs.didSet` (the line
    /// survives the deselection); drop the `enabledIDs.contains` filter in `recordingMenuLines`.
    @Test func linesFollowTheCourseSelection() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary, fisica: fisicaSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)

        select([11], on: controller)
        #expect(lines(controller) == ["ANALISI 2 — 12/30 · ~14 h"])
        #expect(controller.menuBarSnapshot.recordingsTitle == "Registrazioni")

        select([11, 12], on: controller)
        #expect(lines(controller) == ["FISICA — 3/10 · ~45 min", "ANALISI 2 — 12/30 · ~14 h"], "sidebar order")

        select([12], on: controller)
        #expect(lines(controller) == ["FISICA — 3/10 · ~45 min"])
        #expect(controller.watchSummaries[analisi] == analisiSummary, "hidden, not forgotten")

        select([], on: controller)
        #expect(lines(controller).isEmpty)

        select([11], on: controller)
        #expect(lines(controller) == ["ANALISI 2 — 12/30 · ~14 h"])
        #expect(controller.recordingsIfCreated == nil, "nothing here needs the Recordings controller")
    }

    /// A new course list from WeBeep (a reload, a renamed or removed course) redraws the lines
    /// with the selection unchanged. Guards against a menu naming a course that is no longer in
    /// the list, or keeping its old name.
    /// Mutation: drop `recordingMenuInputsChanged()` from `courses.didSet`.
    @Test func aNewCourseListRedrawsTheLines() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11], on: controller)
        #expect(lines(controller) == ["ANALISI 2 — 12/30 · ~14 h"])

        controller.setCoursesForTesting([course(11, "058167 - ANALISI MATEMATICA 2 [2026-27]")])
        #expect(lines(controller) == ["ANALISI MATEMATICA 2 — 12/30 · ~14 h"], "renamed on WeBeep")
        controller.setCoursesForTesting([])
        #expect(lines(controller).isEmpty, "no longer in the list")
        #expect(controller.enabledCourseIDs == [11])
    }

    /// At most ten lines, taken in the given (sidebar) order, skipping courses that aren't synced.
    /// Guards against a menu that grows with every course or reorders them.
    /// Mutations: drop the `maxRecordingMenuLines` break (12 lines); drop the `enabledIDs`
    /// filter (course 01 appears).
    @Test func linesKeepTheSidebarOrderAndStopAtTen() {
        let courses = (0..<13).map { course(Int64(100 + $0), String(format: "%06d - CORSO %02d [2026-27]", 100_000 + $0, $0)) }
        var summaries: [RecmanCourseKey: CourseWatchSummary] = [:]
        for index in 0..<13 {
            summaries[RecmanCourseKey(courseCode: String(100_000 + index), academicYear: 2026)!] = CourseWatchSummary(done: index, total: 20, remainingMinutes: 0, unknownDurationCount: 0)
        }
        let enabled = Set(courses.map(\.id)).subtracting([101])
        let lines = WeBeepAuthenticationController.recordingMenuLines(courses: courses, enabledIDs: enabled, summaries: summaries, owner: 7)
        #expect(WeBeepAuthenticationController.maxRecordingMenuLines == 10)
        #expect(lines.map(\.text.italian) == [0, 2, 3, 4, 5, 6, 7, 8, 9, 10].map { String(format: "CORSO %02d — %d/20", $0, $0) })
    }

    /// A course with no known summary, an empty archive (`total == 0`), no archive key, or the
    /// same key as a course already shown gets no line: the menu never reads "0/0" or shows a
    /// course twice. Guards the plan's "a course with no known summary is omitted (never 0/0)".
    /// Mutations: drop `summary.total > 0` ("no recordings" line appears); drop the `shown`
    /// de-duplication (the second Analisi appears).
    @Test func unknownEmptyAndDuplicateCoursesHaveNoLine() {
        let courses = [
            course(1, "058167 - ANALISI 2 [2026-27]"),
            course(2, "052499 - FISICA [2026-27]"),
            course(3, "Seminario senza codice"),
            course(4, "054321 - CHIMICA [2026-27]"),
            course(5, "058167 - ANALISI 2 (sezione B) [2026-27]"),
        ]
        let summaries = [
            analisi: analisiSummary,
            fisica: CourseWatchSummary(done: 0, total: 0, remainingMinutes: 0, unknownDurationCount: 0),
        ]
        let lines = WeBeepAuthenticationController.recordingMenuLines(courses: courses, enabledIDs: [1, 2, 3, 4, 5], summaries: summaries, owner: 7)
        #expect(lines.map(\.text) == [BilingualText("ANALISI 2 — 12/30 · ~14 h", "ANALISI 2 — 12/30 · ~14 h")])
        #expect(WeBeepAuthenticationController.recordingMenuLines(courses: courses, enabledIDs: [1, 2, 3, 4, 5], summaries: [:], owner: 7).isEmpty)
    }

    // MARK: Account and launch

    /// After a relaunch the menu shows the account's saved numbers as soon as WeBeep names the
    /// account, without creating the Recordings controller (no WebKit, no request); another
    /// account's saved numbers are deleted, never shown. Guards the lazy guarantee and account
    /// isolation of the menu bar.
    /// Mutations: drop `forgetWatchSummary(in:notOwnedBy:)` from `siteInfo.didSet` (owner 9's
    /// copy stays in the settings); drop the seeding from `storedWatchSummaries` (owner 7 sees
    /// nothing); seed through `recordings` instead of the static helper (a controller exists).
    @Test(arguments: [9, 7])
    func theSavedSummaryIsShownOnlyToItsAccountWithoutAController(storedOwner: Int) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: storedOwner, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        #expect(controller.recordingsIfCreated == nil)
        select([11], on: controller)

        if storedOwner == 7 {
            #expect(lines(controller) == ["ANALISI 2 — 12/30 · ~14 h"])
            #expect(defaults.data(forKey: RecordingsController.watchSummaryKey) != nil)
        } else {
            #expect(lines(controller).isEmpty)
            #expect(controller.watchSummaries.isEmpty)
            #expect(defaults.data(forKey: RecordingsController.watchSummaryKey) == nil, "another account's numbers are deleted")
        }
        #expect(controller.recordingsIfCreated == nil, "the owner becoming known creates no Recordings controller")
    }

    /// With Recordings switched off, or on another university, saved numbers are not shown.
    /// Guards against a menu advertising a feature the student turned off or can't use.
    /// Mutations: drop `RecordingsController.isSwitchedOn(in:)` from the seed condition (off
    /// shows the line); drop `selectedSite.university == .polimi` (Padova shows it).
    @Test(arguments: [false, true])
    func recordingsOffOrAnotherUniversityShowNoLines(otherUniversity: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        if !otherUniversity { defaults.set(false, forKey: RecordingsController.enabledKey) }
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults, site: otherUniversity ? MoodleSite.unipd[0] : .polimi)
        select([11], on: controller)
        #expect(controller.watchSummaries.isEmpty)
        #expect(lines(controller).isEmpty)
        #expect(controller.recordingsIfCreated == nil)
    }

    /// Signing out removes the lines in the same main-actor turn. Guards against the previous
    /// account's numbers staying in the menu after disconnecting.
    /// Mutation: drop `watchSummaries = [:]` from the no-account branch of `siteInfo.didSet`
    /// together with the reset push in `forgetSeen` (sign-out also turns Recordings off).
    @Test func signingOutClearsTheLines() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11], on: controller)
        #expect(lines(controller).count == 1)
        controller.signOut()
        #expect(lines(controller).isEmpty)
        #expect(controller.watchSummaries.isEmpty)
        await controller.recordings.settleSessionFile()
    }

    // MARK: Pushes from the Recordings controller

    /// A listing loaded by the Recordings page reaches the menu through `onWatchSummaryChange`;
    /// switching Recordings off in Settings pushes the reset and the lines go. Guards the wiring
    /// between the two controllers (the menu never asks Recordings from an AppKit callback).
    /// Mutation: drop the `onWatchSummaryChange` assignment in `makeRecordings` (no line appears).
    @Test func aLoadedListingReachesTheMenuAndTurningOffClearsIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN")], ownerUserID: 7))
        let browser = FakeRecmanBrowser()
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        browser.listResults[analisi.courseCode] = .success(["a", "b"].map {
            RecmanRecording(id: $0, courseCode: analisi.courseCode, academicYear: analisi.academicYear, title: "Lezione \($0)", recordedAt: when, kind: "Lezione", duration: "90 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/x?transfer_id=\($0)")!)
        })
        let controller = try await signedIn(defaults: defaults, browser: browser)
        select([11], on: controller)
        #expect(lines(controller).isEmpty, "nothing before a page has loaded")

        let recordings = controller.recordings
        recordings.pageAppeared()
        recordings.refresh([analisi], selected: analisi)
        for _ in 0..<2_000 where lines(controller).isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(lines(controller) == ["ANALISI 2 — 0/2 · ~3 h"])

        recordings.setEnabled(false)
        #expect(lines(controller).isEmpty)
        #expect(controller.watchSummaries.isEmpty)
        await recordings.settleSessionFile()
    }

    /// Numbers seeded from the saved copy go when Recordings is switched off, even though the
    /// Recordings controller never loaded them itself. Guards the reset push in `forgetSeen`,
    /// which must be sent even when the controller's own summaries are already empty.
    /// Mutation: make `forgetSeen` assign `watchSummaries = [:]` only (its `didSet` is silent for
    /// `[:]` → `[:]`, and the seeded line stays).
    @Test func turningOffClearsSeededLinesTheControllerNeverLoaded() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11], on: controller)
        #expect(lines(controller).count == 1)

        controller.recordings.setEnabled(false)
        #expect(lines(controller).isEmpty)
        #expect(defaults.data(forKey: RecordingsController.watchSummaryKey) == nil)
        await controller.recordings.settleSessionFile()
    }

    // MARK: Language

    /// `recordingMenuSection` resolves the header and the lines in the language it is given, and
    /// the controller keeps the lines in both languages (no resolved string cached), with the
    /// snapshot built from them. It does not exercise `setLanguage` itself (that would switch the
    /// process-global language); `theSnapshotUsesTheControllersLanguage` covers the wiring.
    /// Mutations: resolve with `.italian` always in `recordingMenuSection`; build the snapshot's
    /// lines from something other than `recordingMenuLines`.
    @Test func theSectionFollowsTheLanguage() async throws {
        let lines = [
            RecordingMenuEntry(text: RecordingWatchProgress.menuLine(courseName: "Analisi 2", CourseWatchSummary(done: 30, total: 30, remainingMinutes: 0, unknownDurationCount: 0)), hint: nil, target: nil),
            RecordingMenuEntry(text: RecordingWatchProgress.menuLine(courseName: "Fisica", fisicaSummary), hint: nil, target: nil),
        ]
        let italian = WeBeepAuthenticationController.recordingMenuSection(lines, language: .italian)
        let english = WeBeepAuthenticationController.recordingMenuSection(lines, language: .english)
        #expect(italian.title == "Registrazioni")
        #expect(italian.lines.map(\.title) == ["Analisi 2 — 30/30 · tutte fatte", "Fisica — 3/10 · ~45 min"])
        #expect(english.title == "Recordings")
        #expect(english.lines.map(\.title) == ["Analisi 2 — 30/30 · all done", "Fisica — 3/10 · ~45 min"])

        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: CourseWatchSummary(done: 30, total: 30, remainingMinutes: 0, unknownDurationCount: 0)], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11], on: controller)
        #expect(controller.recordingMenuLines.map(\.text) == [BilingualText("ANALISI 2 — 30/30 · tutte fatte", "ANALISI 2 — 30/30 · all done")], "both languages kept, no resolved string cached")
        #expect(controller.menuBarSnapshot.recordingLines == WeBeepAuthenticationController.recordingMenuSection(controller.recordingMenuLines, language: .italian).lines)
    }

    /// The snapshot's header and lines are resolved in the controller's language (which mirrors
    /// `AppLanguage.current` and changes with `setLanguage`), here English through the test
    /// init's `language:`, which leaves the process-global language untouched. Guards against an
    /// English menu with an Italian recordings section.
    /// Mutations: pass `.italian` (or `AppLanguage.current`, Italian in tests) instead of
    /// `language` in `refreshMenuBarSnapshot`; hardcode `recordingsTitle` there.
    @Test func theSnapshotUsesTheControllersLanguage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: CourseWatchSummary(done: 30, total: 30, remainingMinutes: 0, unknownDurationCount: 0)], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults, language: .english)
        select([11], on: controller)
        #expect(controller.menuBarSnapshot.recordingsTitle == "Recordings")
        #expect(lines(controller) == ["ANALISI 2 — 30/30 · all done"])
    }

    // MARK: Menu items

    private func snapshot(_ lines: [String]) -> MenuBarSnapshot {
        snapshot(lines.map { RecordingMenuLine(title: $0, toolTip: nil, target: nil) })
    }

    private func snapshot(_ lines: [RecordingMenuLine]) -> MenuBarSnapshot {
        MenuBarSnapshot(title: "Sincronizzato", detail: "3 nuovi", actionTitle: "Sincronizza ora", openTitle: "Apri BeepBar", quitTitle: "Esci da BeepBar", recordingsTitle: "Registrazioni", recordingLines: lines)
    }

    /// The recordings section alone: nothing when there are no lines, otherwise a separator, the
    /// "Registrazioni" section header and one line per course. Lines without a click target
    /// (nothing to play) have no target or action and are disabled; the clickable kind is
    /// covered by `aClickableLineIsWiredToThePlayAction`.
    /// Mutations: drop the empty guard (a lone separator and header appear); drop
    /// `isEnabled = false` (the lines look clickable and do nothing); a plain item as header.
    @Test func theMenuSectionIsDisabledTextAfterASeparator() {
        let empty = NSMenu()
        StatusItemController.addRecordingItems(from: snapshot([String]()), to: empty, target: nil)
        #expect(empty.items.isEmpty)

        let menu = NSMenu()
        StatusItemController.addRecordingItems(from: snapshot(["Analisi 2 — 12/30 · ~14 h", "Fisica — 3/10 · ~45 min"]), to: menu, target: nil)
        #expect(menu.items.count == 4)
        #expect(menu.items.first?.isSeparatorItem == true)
        #expect(menu.items.dropFirst().map(\.title) == ["Registrazioni", "Analisi 2 — 12/30 · ~14 h", "Fisica — 3/10 · ~45 min"])
        #expect(menu.items[1].isSectionHeader)
        for item in menu.items.dropFirst() {
            #expect(item.action == nil)
            #expect(item.target == nil)
        }
        for item in menu.items.dropFirst(2) { #expect(!item.isEnabled) }
    }

    /// The whole menu `menuNeedsUpdate` draws, in order: status, detail, action, Open (right under
    /// Sync now), the recordings section, separator, Quit; without lines, no recordings items at all. The three
    /// actions keep their selectors. Guards the section being wired into the real menu and not
    /// displacing the existing items.
    /// Mutation: delete the `addRecordingItems` call in `build`.
    @Test func theMenuShowsTheSectionBetweenTheActionAndOpen() {
        let menu = NSMenu()
        menu.addItem(withTitle: "left over from the last opening", action: nil, keyEquivalent: "")
        StatusItemController.build(from: snapshot(["Analisi 2 — 12/30 · ~14 h", "Fisica — 3/10 · ~45 min"]), into: menu, target: nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == [
            "Sincronizzato", "3 nuovi", "Sincronizza ora", "Apri BeepBar",
            "—", "Registrazioni", "Analisi 2 — 12/30 · ~14 h", "Fisica — 3/10 · ~45 min",
            "—", "Esci da BeepBar",
        ])
        #expect(menu.items[2].action == NSSelectorFromString("performAction"))
        #expect(menu.items[3].action == NSSelectorFromString("openConfiguration"))
        #expect(menu.items[9].action == NSSelectorFromString("quit"))

        StatusItemController.build(from: snapshot([String]()), into: menu, target: nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == ["Sincronizzato", "3 nuovi", "Sincronizza ora", "Apri BeepBar", "—", "Esci da BeepBar"])
    }

    // MARK: Account changes around the seed

    /// A Recordings controller that already exists (the window was opened before WeBeep named the
    /// account) doesn't stop the menu from showing the account's saved numbers when it becomes
    /// known (nil → 7). Mutation: seed only when no controller exists.
    @Test func anExistingControllerStillGetsTheSeededLines() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await makeController(defaults: defaults)
        let recordings = controller.recordings
        #expect(recordings.isEnabled)
        await signIn(controller, as: 7)
        select([11], on: controller)
        #expect(lines(controller) == ["ANALISI 2 — 12/30 · ~14 h"])
        await recordings.settleSessionFile()
    }

    /// Another account signing in directly (7 → 9, without a sign-out in between) never shows
    /// 7's numbers, with or without a Recordings controller, and 7's saved copy goes.
    /// Mutation: seed with `stored ?? watchSummaries` (9 keeps 7's lines).
    @Test(arguments: [false, true])
    func aDirectAccountSwitchNeverShowsThePreviousAccountsLines(withController: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11], on: controller)
        #expect(lines(controller).count == 1)
        if withController { _ = controller.recordings }

        await signIn(controller, as: 9)
        select([11], on: controller)
        #expect(lines(controller).isEmpty)
        #expect(controller.watchSummaries.isEmpty)
        #expect(defaults.data(forKey: RecordingsController.watchSummaryKey) == nil)
        if withController { await controller.recordings.settleSessionFile() }
    }

    /// Reloading the course list for the same account (WeBeep answers the same user again)
    /// doesn't re-read the saved numbers: the seed happens once per account, and the controller's
    /// pushes stay authoritative afterwards. Mutation: drop the same-user guard at the top of
    /// `siteInfo.didSet` (the reload reads the changed copy and the line changes).
    @Test func reloadingTheSameAccountDoesNotReseed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11], on: controller)
        #expect(lines(controller) == ["ANALISI 2 — 12/30 · ~14 h"])

        try storeSummaries([analisi: fisicaSummary], owner: 7, in: defaults)
        controller.loadCourses()
        await controller.waitForCourseLoadForTesting()
        #expect(controller.courseLoadError == nil)
        #expect(lines(controller) == ["ANALISI 2 — 12/30 · ~14 h"], "not read again for the same account")
    }

    /// A controller that exists but never had a Polimi session (`sessionOwner` nil, so its own
    /// `webBeepAccountChanged` forgets nothing) still lets the previous account's saved numbers
    /// go when another account signs in. Guards retention of another account's data on disk.
    /// Mutation: call `forgetWatchSummary(in:notOwnedBy:)` only when no controller exists.
    @Test func anotherAccountsSavedNumbersGoEvenWithAControllerWithoutSession() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await makeController(defaults: defaults)
        let recordings = controller.recordings
        await signIn(controller, as: 9)
        #expect(defaults.data(forKey: RecordingsController.watchSummaryKey) == nil)
        #expect(lines(controller).isEmpty)
        await recordings.settleSessionFile()
    }

    /// Opening the Recordings page seeds the saved summaries when the account's seed was empty
    /// (Recordings switched on after sign-in), without creating the Recordings controller, and
    /// does not overwrite summaries already in memory. Guards the sidebar's orange markers
    /// missing until a listing loads.
    /// Mutation: make `seedWatchSummariesIfNeeded` a no-op, or drop its `isEmpty` guard.
    @Test func openingThePageSeedsSavedSummariesOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        let controller = try await signedIn(defaults: defaults)
        #expect(controller.watchSummaries.isEmpty)
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        controller.seedWatchSummariesIfNeeded()
        #expect(controller.watchSummaries == [analisi: analisiSummary])
        #expect(controller.recordingsIfCreated == nil)
        try storeSummaries([analisi: fisicaSummary], owner: 7, in: defaults)
        controller.seedWatchSummariesIfNeeded()
        #expect(controller.watchSummaries == [analisi: analisiSummary], "not read again over what is in memory")
    }

    /// With Recordings switched off the page seed leaves the summaries empty: saved numbers are
    /// not read for a feature the student turned off. Mutation: drop the switch check from
    /// `seedWatchSummariesIfNeeded`.
    @Test func theSeedDoesNothingWithRecordingsOff() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        let controller = try await signedIn(defaults: defaults)
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        defaults.set(false, forKey: RecordingsController.enabledKey)
        controller.seedWatchSummariesIfNeeded()
        #expect(controller.watchSummaries.isEmpty)
    }

    /// The real restore path (`restoreScopes`, run at launch) is where `courseFolders` is filled,
    /// and nothing else rebuilds the menu afterwards: with saved summaries and renamed folders the
    /// lines must show the folder names once the restore ends, and be rebuilt ONCE for the whole
    /// restore, not once per course (quadratic at launch).
    /// Mutations: drop the flush in `restoreScopes`' `defer` (the lines keep the WeBeep names);
    /// drop the hold (`menuRebuildHolds += 1`: one rebuild per course).
    @Test func restoringRenamedFoldersRebuildsTheMenuOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary, fisica: fisicaSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11, 12], on: controller)
        #expect(lines(controller) == ["FISICA — 3/10 · ~45 min", "ANALISI 2 — 12/30 · ~14 h"])

        // Selecting queued scope writes; a first restore waits for them, so they can't land
        // over the scopes seeded below.
        try await controller.restoreScopesForTesting(controller.courses)
        let database = try #require(seeds.database), rootID = try #require(seeds.rootID)
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 11, displayName: "058167 - ANALISI 2 [2026-27]", localFolder: "MAT Due", enabled: true))
        try await database.upsertScope(SyncScope(rootID: rootID, courseID: 12, displayName: "052499 - FISICA [2026-27]", localFolder: "FIS", enabled: true))
        let before = controller.menuRebuildCountForTesting
        try await controller.restoreScopesForTesting(controller.courses)
        #expect(controller.courseFolders[11] == "MAT Due" && controller.courseFolders[12] == "FIS")
        #expect(lines(controller) == ["FIS — 3/10 · ~45 min", "MAT Due — 12/30 · ~14 h"])
        #expect(controller.menuRebuildCountForTesting - before == 1, "one rebuild for the whole restore")
    }

    /// Renaming a course's local folder redraws its menu line with the folder name alone, and
    /// the line keeps its numbers. Guards against a menu that keeps the WeBeep name until
    /// something else changes, because `courseFolders` was not an input of the lines.
    /// Mutation: drop `recordingMenuInputsChanged()` from `courseFolders.didSet`.
    @Test func renamingAFolderRedrawsTheLine() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: analisiSummary], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11], on: controller)
        #expect(lines(controller) == ["ANALISI 2 — 12/30 · ~14 h"])
        let analisiCourse = try #require(controller.courses.first { $0.id == 11 })
        controller.renameFolder(for: analisiCourse, to: "AN2")
        for _ in 0..<400 where controller.renamingCourseID != nil || controller.courseFolders[11] == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.courseFolders[11] == "AN2")
        #expect(lines(controller) == ["AN2 — 12/30 · ~14 h"])
    }

    // MARK: Click to play (package P3)

    /// An Analisi lecture with an archive preview link that passes `RecmanURLPolicy` (what the
    /// parser produces), or one on `host` (a forged stored `next`).
    private func lecture(_ id: String, host: String = "onlineservices.polimi.it", in key: RecmanCourseKey? = nil) -> RecmanRecording {
        let key = key ?? analisi
        return RecmanRecording(id: id, courseCode: key.courseCode, academicYear: key.academicYear, title: "Lezione \(id)",
                        recordedAt: Date(timeIntervalSince1970: 1_790_000_000), kind: "Lezione", duration: "90 min", size: nil,
                        previewURL: URL(string: "https://\(host)/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=1&transfer_id=\(id)")!)
    }

    private func summary(next: RecmanRecording?) -> CourseWatchSummary {
        CourseWatchSummary(done: 12, total: 30, remainingMinutes: 840, unknownDurationCount: 0, next: next)
    }

    private func stream(_ id: String) -> RecordingStream {
        RecordingStream(url: URL(string: "https://nfg1wss.webex.com/nbr/\(id)/hls.m3u8")!, title: nil, duration: 6_000)
    }

    /// What the window-opening seam (`showRecordingsPageForTesting`) was asked for.
    @MainActor final class PageRequests { var courses: [Int64?] = [] }

    /// A relaunch with Analisi's summary saved for user 7 (next lecture `next`, default "a"),
    /// Recordings on with a saved Polimi session, a fake browser and player, Analisi synced; no
    /// Recordings controller.
    private func clickSetup(next: RecmanRecording? = nil, extra: [RecmanCourseKey: CourseWatchSummary] = [:], language: AppLanguage = .italian) async throws
        -> (WeBeepAuthenticationController, FakeRecmanBrowser, FakeRecordingPlayer, PageRequests, UserDefaults) {
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN")], ownerUserID: 7))
        try storeSummaries(extra.merging([analisi: summary(next: next ?? lecture("a"))]) { $1 }, owner: 7, in: defaults)
        let browser = FakeRecmanBrowser()
        let player = FakeRecordingPlayer()
        let pages = PageRequests()
        let controller = try await signedIn(defaults: defaults, browser: browser, language: language)
        controller.recordingsPlayerForTesting = { player }
        controller.showRecordingsPageForTesting = { pages.courses.append($0) }
        select([11], on: controller)
        return (controller, browser, player, pages, defaults)
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

    private func target(_ controller: WeBeepAuthenticationController) -> RecordingMenuTarget? {
        controller.menuBarSnapshot.recordingLines.first?.target
    }

    /// A line is clickable (target and "Riproduci" hint, in both languages) only when its summary
    /// has a valid next lecture and the account is known; an all-done course, one with no known
    /// next, one whose stored next is forged, or an unknown account give a grey line.
    /// Guards the owner decision "enabled only with a next" and a click target that plays nothing.
    /// Mutations: give every line a target (the all-done line gets one); drop `validatedNext` from
    /// the builder (the forged line gets one); drop the `owner` condition (no account, a target).
    @Test func aLineIsClickableOnlyWithAPlayableNext() {
        let courses = [course(1, "058167 - ANALISI 2 [2026-27]"), course(2, "052499 - FISICA [2026-27]")]
        let forged = RecmanRecording(id: "f", courseCode: fisica.courseCode, academicYear: fisica.academicYear, title: "x", recordedAt: Date(), kind: "Lezione", duration: "90 min", size: nil, previewURL: URL(string: "https://example.com/?transfer_id=f")!)
        let built = { (summaries: [RecmanCourseKey: CourseWatchSummary], owner: Int?) in
            WeBeepAuthenticationController.recordingMenuLines(courses: courses, enabledIDs: [1, 2], summaries: summaries, owner: owner)
        }
        let lines = built([analisi: summary(next: lecture("a")), fisica: CourseWatchSummary(done: 10, total: 10, remainingMinutes: 0, unknownDurationCount: 0)], 7)
        #expect(lines.map(\.target) == [RecordingMenuTarget(owner: 7, courseID: 1, key: analisi), nil])
        #expect(lines.map(\.hint) == [BilingualText("Riproduci: «Lezione a»", "Play: “Lezione a”"), nil])

        #expect(built([analisi: summary(next: nil)], 7).map(\.target) == [nil], "no known next")
        #expect(built([fisica: CourseWatchSummary(done: 1, total: 10, remainingMinutes: 0, unknownDurationCount: 0, next: forged)], 7).map(\.target) == [nil], "forged next")
        #expect(built([analisi: summary(next: lecture("a"))], nil).map(\.target) == [nil], "no account")
        #expect(built([analisi: summary(next: lecture("a"))], nil).map(\.hint) == [nil])
    }

    /// The section resolves each line's tooltip in the language it is given, next to the title,
    /// and keeps the target; the controller's snapshot uses its own language. Guards an English
    /// menu with an Italian tooltip. Mutations: pick the Italian hint always in
    /// `recordingMenuSection`; drop `target` there.
    @Test func theTooltipFollowsTheLanguage() async throws {
        let target = RecordingMenuTarget(owner: 7, courseID: 1, key: analisi)
        let entries = [RecordingMenuEntry(text: BilingualText("A — 1/2", "A — 1/2"), hint: BilingualText("Riproduci: «L»", "Play: “L”"), target: target)]
        #expect(WeBeepAuthenticationController.recordingMenuSection(entries, language: .italian).lines == [RecordingMenuLine(title: "A — 1/2", toolTip: "Riproduci: «L»", target: target)])
        #expect(WeBeepAuthenticationController.recordingMenuSection(entries, language: .english).lines == [RecordingMenuLine(title: "A — 1/2", toolTip: "Play: “L”", target: target)])

        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, _, _, _, _) = try await clickSetup(language: .english)
        #expect(controller.menuBarSnapshot.recordingLines.first?.toolTip == "Play: “Lezione a”")
    }

    /// Item shape: a line with a target points at the `StatusItemController` passed to `build`
    /// (never NSApp or the account controller), with `playRecording:`, the payload as
    /// `representedObject` and the tooltip, and NSMenu's autoenabling enables it; a line without
    /// one has none of these and stays disabled; the header stays a section header.
    /// Guards a clickable-looking line that does nothing, a grey line that does something, and a
    /// target that crosses into the main actor. Mutations: `item.target = nil` (target missing,
    /// the item is not enabled); give every line the action (the grey line is enabled).
    @Test func aClickableLineIsWiredToThePlayAction() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, _, _, _, _) = try await clickSetup()
        let status = StatusItemController(authentication: controller)
        let payload = RecordingMenuTarget(owner: 7, courseID: 11, key: analisi)
        let menu = NSMenu()
        StatusItemController.build(from: snapshot([
            RecordingMenuLine(title: "ANALISI 2 — 12/30 · ~14 h", toolTip: "Riproduci: «Lezione a»", target: payload),
            RecordingMenuLine(title: "FISICA — 10/10 · tutte fatte", toolTip: nil, target: nil),
        ]), into: menu, target: status)
        menu.update()
        #expect(menu.items[4].isSectionHeader)
        let clickable = menu.items[5]
        let grey = menu.items[6]
        #expect(clickable.target === status)
        #expect(clickable.action == NSSelectorFromString("playRecording:"))
        #expect(clickable.representedObject as? RecordingMenuTarget == payload)
        #expect(clickable.toolTip == "Riproduci: «Lezione a»")
        #expect(clickable.isEnabled)
        #expect(grey.target == nil)
        #expect(grey.action == nil)
        #expect(grey.representedObject == nil)
        #expect(grey.toolTip == nil)
        #expect(!grey.isEnabled)
        #expect(controller.recordingsIfCreated == nil, "drawing the menu creates nothing")
    }

    /// The whole click path, from AppKit's own dispatch of the item's action: nothing happens
    /// synchronously (no Recordings controller, nothing played, right after the call), and after
    /// the main actor runs its queued work the course's next lecture plays in the player, without
    /// opening the window. The line was enabled from the saved summary after a relaunch without a
    /// controller. Guards the issue #30 hop being replaced by a synchronous call, and the click
    /// doing nothing. Mutations: call `authentication.playNextRecording` synchronously in
    /// `dispatchRecordingClick` (with `MainActor.assumeIsolated`: a controller exists at once);
    /// drop the `Task` body (nothing plays). Two clickable courses (Fisica, then Analisi) and the
    /// click on the SECOND: guards the action dispatching something other than the clicked
    /// item's own payload. Mutation: dispatch `menuBarSnapshot.recordingLines.first?.target`
    /// instead of `sender.representedObject` (Fisica's "f1" would be asked for, not "a").
    @Test func aClickHopsToTheMainActorAndPlaysTheNextLecture() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, browser, player, pages, _) = try await clickSetup(extra: [fisica: CourseWatchSummary(done: 3, total: 10, remainingMinutes: 45, unknownDurationCount: 0, next: lecture("f1", in: fisica))])
        select([11, 12], on: controller)
        browser.streamResults["a"] = [.success(stream("a"))]
        browser.streamResults["f1"] = [.success(stream("f1"))]
        #expect(controller.menuBarSnapshot.recordingLines.map(\.target) == [
            RecordingMenuTarget(owner: 7, courseID: 12, key: fisica),
            RecordingMenuTarget(owner: 7, courseID: 11, key: analisi),
        ], "both enabled from the saved summaries, in sidebar order")
        #expect(controller.recordingsIfCreated == nil, "seeding created no controller")

        let status = StatusItemController(authentication: controller)
        let menu = NSMenu()
        StatusItemController.build(from: controller.menuBarSnapshot, into: menu, target: status)
        let clickable = menu.items.indices.filter { menu.items[$0].representedObject is RecordingMenuTarget }
        #expect(clickable.count == 2)
        let index = try #require(clickable.last)
        #expect(menu.items[index].title.hasPrefix("ANALISI 2"))
        menu.performActionForItem(at: index)
        #expect(controller.recordingsIfCreated == nil, "nothing ran before the hop")
        #expect(player.plays.isEmpty)

        await settle("a playing") { player.plays.count == 1 }
        #expect(player.plays.first?.recordingID == "a")
        #expect(!browser.streamCalls.contains("stream f1"), "the other line's lecture is never asked for")
        #expect(pages.courses.isEmpty, "no window for a Play that works")
        controller.recordings.turnOff()
    }

    /// `dispatchRecordingClick` ignores anything that isn't a `RecordingMenuTarget`: another
    /// type, a line value, nil. Guards a play from a foreign `representedObject`.
    @Test func aForeignPayloadIsIgnored() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, browser, player, pages, _) = try await clickSetup()
        browser.streamResults["a"] = [.success(stream("a"))]
        let payloads: [Any?] = ["a", 11, controller.menuBarSnapshot.recordingLines.first, nil]
        for payload in payloads {
            StatusItemController.dispatchRecordingClick(payload, to: controller)
        }
        await drainTasks()
        #expect(controller.recordingsIfCreated == nil)
        #expect(player.plays.isEmpty)
        #expect(pages.courses.isEmpty)
    }

    /// `menuPlayRecording` accepts only a click that still applies: same account, Polimi,
    /// Recordings on, course still synced, a known next lecture that `validatedNext` accepts.
    /// Mutations: drop any one clause (its case returns a lecture).
    @Test func menuPlayRecordingRejectsEveryStaleClick() {
        let target = RecordingMenuTarget(owner: 7, courseID: 11, key: analisi)
        let good = [analisi: summary(next: lecture("a"))]
        func play(owner: Int? = 7, polimi: Bool = true, on: Bool = true, enabled: Set<Int64> = [11], summaries: [RecmanCourseKey: CourseWatchSummary]? = nil) -> RecmanRecording? {
            WeBeepAuthenticationController.menuPlayRecording(target: target, owner: owner, isPolimi: polimi, switchOn: on, enabledIDs: enabled, summaries: summaries ?? good)
        }
        #expect(play() == lecture("a"))
        #expect(play(owner: 9) == nil, "another account")
        #expect(play(owner: nil) == nil, "no account")
        #expect(play(polimi: false) == nil, "another university")
        #expect(play(on: false) == nil, "Recordings off")
        #expect(play(enabled: [12]) == nil, "course deselected")
        #expect(play(summaries: [analisi: summary(next: nil)]) == nil, "no next")
        #expect(play(summaries: [:]) == nil, "no summary")
        #expect(play(summaries: [analisi: summary(next: lecture("a", host: "example.com"))]) == nil, "forged next")
    }

    enum Staleness: CaseIterable { case owner, off, deselected, noNext, invalidNext }

    /// A click that no longer applies, through the real controller: nothing plays, the window
    /// doesn't open, and no Recordings controller is created (no WebKit for a click that does
    /// nothing). The target is the one a line would have carried; `noNext` and `invalidNext`
    /// also check that such a line is drawn grey. Guards a stale menu acting for another
    /// account, a turned-off feature, a removed course or a forged lecture.
    /// Mutations: drop the owner guard; drop `switchOn`; drop the `enabledIDs` check; drop the
    /// `next` / `validatedNext` checks from `menuPlayRecording`; create `recordings` before the
    /// checks (every case).
    @Test(arguments: Staleness.allCases)
    func aStaleClickDoesNothing(_ staleness: Staleness) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let next: RecmanRecording? = switch staleness {
        case .invalidNext: lecture("a", host: "example.com")
        default: nil
        }
        let (controller, browser, player, pages, defaults) = try await clickSetup(next: next)
        browser.streamResults["a"] = [.success(stream("a"))]
        var target = RecordingMenuTarget(owner: 7, courseID: 11, key: analisi)
        switch staleness {
        case .owner: target = RecordingMenuTarget(owner: 9, courseID: 11, key: analisi)
        case .off: defaults.set(false, forKey: RecordingsController.enabledKey)
        case .deselected: select([], on: controller)
        case .noNext:
            // A relaunch whose saved summary has no next lecture (every lecture done since).
            try storeSummaries([analisi: summary(next: nil)], owner: 7, in: defaults)
            await signIn(controller, as: 8)
            try storeSummaries([analisi: summary(next: nil)], owner: 7, in: defaults)
            await signIn(controller, as: 7)
            select([11], on: controller)
            #expect(controller.watchSummaries[analisi] == summary(next: nil))
            #expect(self.target(controller) == nil, "no next: a grey line")
        case .invalidNext:
            #expect(self.target(controller) == nil, "a forged next: a grey line")
        }
        StatusItemController.dispatchRecordingClick(target, to: controller)
        await drainTasks()
        #expect(controller.recordingsIfCreated == nil)
        #expect(player.plays.isEmpty)
        #expect(browser.calls.isEmpty)
        #expect(pages.courses.isEmpty)
    }

    /// The account changes between drawing the menu and the click (7 → 9), here through a
    /// connection check (`validateConnection`) that finds the stored token now belongs to 9:
    /// the course list isn't reassigned and 9 has equal saved numbers, so neither `courses` nor
    /// `watchSummaries` changes and only `siteInfo` can rebuild the lines. The old line's click
    /// is ignored, and the lines carry the new account. Guards a menu drawn for one account
    /// playing for another. Mutations: drop the `recordingMenuInputsChanged()` defer in
    /// `siteInfo.didSet` (the line keeps owner 7); drop the owner guard (the old click creates a
    /// controller).
    @Test func anAccountChangeBetweenDrawingAndClickingIsIgnored() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, _, player, pages, defaults) = try await clickSetup()
        let old = try #require(target(controller))
        #expect(old.owner == 7)
        try storeSummaries([analisi: summary(next: lecture("a"))], owner: 9, in: defaults)
        MoodleRecordingProtocol.setUserID(token: tokens.value, 9)
        await controller.validateConnection()?.value
        #expect(controller.recordingsOwnerUserID == 9)
        #expect(controller.courses.count == accountCourses.count, "the course list wasn't touched")
        #expect(controller.watchSummaries[analisi] == summary(next: lecture("a")))
        #expect(target(controller)?.owner == 9, "lines rebuilt for the new account")

        StatusItemController.dispatchRecordingClick(old, to: controller)
        await drainTasks()
        #expect(controller.recordingsIfCreated == nil)
        #expect(player.plays.isEmpty)
        #expect(pages.courses.isEmpty)
    }

    /// When the Play can't go on without the window, the course's Recordings page opens: first
    /// the Polimi session lapses during a menu Play (the controller asks, `onMenuPlayNeedsPage`),
    /// then a second click finds the session needing a sign-in (`playFromMenu` answers false).
    /// Both select the course's page. Guards a click that silently does nothing.
    /// Mutations: don't wire `onMenuPlayNeedsPage` in `makeRecordings` (first request missing);
    /// ignore `startMenuPlay`'s false (second missing); drop `selectDestination` (another page).
    @Test func aPlayThatNeedsTheWindowOpensTheCoursePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, browser, player, pages, _) = try await clickSetup()
        browser.streamResults["a"] = [.failure(RecmanBrowserError.needsSignIn)]
        let target = try #require(target(controller))

        StatusItemController.dispatchRecordingClick(target, to: controller)
        await settle("asked for the page") { pages.courses.count == 1 }
        #expect(pages.courses == [11])
        #expect(controller.recordings.study.destination == .course(11))
        #expect(player.plays.isEmpty)

        controller.recordings.selectDestination(.watchlist)
        StatusItemController.dispatchRecordingClick(target, to: controller)
        await settle("asked again") { pages.courses.count == 2 }
        #expect(pages.courses == [11, 11])
        #expect(controller.recordings.study.destination == .course(11))
        controller.recordings.turnOff()
    }

    /// Three WeBeep courses share Analisi's archive key (sections of one course); the first is
    /// not synced. When a menu Play fails, `onMenuPlayNeedsPage` hands over only the key, and the
    /// page opened is the first synced one in sidebar order: the line the menu showed
    /// (`recordingMenuLines` picks it the same way). Guards the window opening on a course the
    /// student doesn't sync, or on another section than the one clicked.
    /// Mutations: `last(where:)` in `showRecordingsCourse(for:)` (22); drop the
    /// `enabledCourseIDs` preference there (20).
    @Test func aSharedArchiveKeyOpensTheFirstSyncedCourse() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, browser, _, pages, _) = try await clickSetup()
        select([], on: controller)
        controller.setCoursesForTesting([
            course(20, "058167 - ANALISI 2 [2026-27]"),
            course(21, "058167 - ANALISI 2 (sezione B) [2026-27]"),
            course(22, "058167 - ANALISI 2 (sezione C) [2026-27]"),
        ])
        select([21, 22], on: controller)
        let target = try #require(target(controller))
        #expect(target.courseID == 21, "the menu shows the first synced section")
        browser.streamResults["a"] = [.failure(RecmanBrowserError.needsSignIn)]

        StatusItemController.dispatchRecordingClick(target, to: controller)
        await settle("asked for the page") { pages.courses.count == 1 }
        #expect(pages.courses == [21])
        #expect(controller.recordings.study.destination == .course(21))
        controller.recordings.turnOff()
    }

    /// The tooltip collapses every run of whitespace and line breaks in the archive's title into
    /// one space, and an empty (or blank) title gives a hint without quotes, in both languages.
    /// Guards tooltips with gaps, extra lines or "«»". Mutations: use the raw title (first case);
    /// drop the empty fallback (the blank case reads "Riproduci: «»").
    @Test func theHintCleansTheTitle() {
        #expect(WeBeepAuthenticationController.recordingMenuHint(title: "Lezione 3") == BilingualText("Riproduci: «Lezione 3»", "Play: “Lezione 3”"))
        #expect(WeBeepAuthenticationController.recordingMenuHint(title: "  Lezione\n\n 3 \t parte  2\r\n") == BilingualText("Riproduci: «Lezione 3 parte 2»", "Play: “Lezione 3 parte 2”"))
        #expect(WeBeepAuthenticationController.recordingMenuHint(title: "") == BilingualText("Riproduci", "Play"))
        #expect(WeBeepAuthenticationController.recordingMenuHint(title: " \n\t ") == BilingualText("Riproduci", "Play"))
    }

    /// Source guard for the hard rule on `StatusItemController` (AGENTS.md, issues #30/#31):
    /// outside comments, the class's code contains no `DispatchQueue.main`, `assumeIsolated` or
    /// `RunLoop.main.perform`. Behaviour tests can't see these: a `DispatchQueue.main.async`
    /// hop also defers the work, so "nothing ran before the hop" still holds in a test, and the
    /// crash or quit hang they bring back only shows on a real Mac after wake or on a menu quit.
    /// The file is found relative to this test file (`#filePath`); if it isn't there the test
    /// fails with a message instead of passing on nothing.
    /// Mutations: wrap the `playNextRecording` call in `DispatchQueue.main.async`; use
    /// `MainActor.assumeIsolated` in `dispatchRecordingClick`.
    @Test func statusItemControllerHasNoForbiddenMainThreadHops() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BeepbarApp/BeepbarApp.swift")
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            Issue.record("BeepbarApp.swift not found at \(file.path): the source guard can't run")
            return
        }
        let start = try #require(source.range(of: "final class StatusItemController"), "StatusItemController not found in BeepbarApp.swift")
        let end = try #require(source.range(of: "final class ConfigurationWindowController", range: start.upperBound..<source.endIndex), "the class's end marker moved")
        let code = source[start.lowerBound..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
        #expect(code.contains("Task { @MainActor in"), "the scan sees the class's code")
        for forbidden in ["DispatchQueue.main", "assumeIsolated", "RunLoop.main.perform"] {
            #expect(!code.contains(forbidden), "StatusItemController must not use \(forbidden) (issue #30)")
        }
    }

    /// Compile-time guard, never run: the menu action and the dispatcher are callable from a
    /// nonisolated synchronous context, as AppKit calls them. Marking `playRecording(_:)` or
    /// `dispatchRecordingClick` `@MainActor` (the issue #30 crash: AppKit's Objective-C call
    /// would make the runtime verify the executor) makes this fail to compile.
    nonisolated private static func menuActionsAreNonisolated(_ status: StatusItemController, _ item: NSMenuItem, _ auth: WeBeepAuthenticationController) {
        status.playRecording(item)
        StatusItemController.dispatchRecordingClick(item.representedObject, to: auth)
    }
}
