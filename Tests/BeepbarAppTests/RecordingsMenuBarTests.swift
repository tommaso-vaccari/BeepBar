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

    /// A fresh account controller on `defaults` (a relaunch), not signed in yet.
    private func makeController(defaults: UserDefaults, site: MoodleSite = .polimi, browser: FakeRecmanBrowser? = nil, language: AppLanguage = .italian) async throws -> WeBeepAuthenticationController {
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state-\(UUID().uuidString).sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: sync.path)
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

    private func lines(_ controller: WeBeepAuthenticationController) -> [String] { controller.menuBarSnapshot.recordingLines }

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
        let lines = WeBeepAuthenticationController.recordingMenuLines(courses: courses, enabledIDs: enabled, summaries: summaries)
        #expect(WeBeepAuthenticationController.maxRecordingMenuLines == 10)
        #expect(lines.map(\.italian) == [0, 2, 3, 4, 5, 6, 7, 8, 9, 10].map { String(format: "CORSO %02d — %d/20", $0, $0) })
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
        let lines = WeBeepAuthenticationController.recordingMenuLines(courses: courses, enabledIDs: [1, 2, 3, 4, 5], summaries: summaries)
        #expect(lines == [BilingualText("ANALISI 2 — 12/30 · ~14 h", "ANALISI 2 — 12/30 · ~14 h")])
        #expect(WeBeepAuthenticationController.recordingMenuLines(courses: courses, enabledIDs: [1, 2, 3, 4, 5], summaries: [:]).isEmpty)
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
            RecordingWatchProgress.menuLine(courseName: "Analisi 2", CourseWatchSummary(done: 30, total: 30, remainingMinutes: 0, unknownDurationCount: 0)),
            RecordingWatchProgress.menuLine(courseName: "Fisica", fisicaSummary),
        ]
        let italian = WeBeepAuthenticationController.recordingMenuSection(lines, language: .italian)
        let english = WeBeepAuthenticationController.recordingMenuSection(lines, language: .english)
        #expect(italian.title == "Registrazioni")
        #expect(italian.lines == ["Analisi 2 — 30/30 · tutte fatte", "Fisica — 3/10 · ~45 min"])
        #expect(english.title == "Recordings")
        #expect(english.lines == ["Analisi 2 — 30/30 · all done", "Fisica — 3/10 · ~45 min"])

        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        try storeSummaries([analisi: CourseWatchSummary(done: 30, total: 30, remainingMinutes: 0, unknownDurationCount: 0)], owner: 7, in: defaults)
        let controller = try await signedIn(defaults: defaults)
        select([11], on: controller)
        #expect(controller.recordingMenuLines == [BilingualText("ANALISI 2 — 30/30 · tutte fatte", "ANALISI 2 — 30/30 · all done")], "both languages kept, no resolved string cached")
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
        MenuBarSnapshot(title: "Sincronizzato", detail: "3 nuovi", actionTitle: "Sincronizza ora", openTitle: "Apri BeepBar…", quitTitle: "Esci da BeepBar", recordingsTitle: "Registrazioni", recordingLines: lines)
    }

    /// The recordings section alone: nothing when there are no lines, otherwise a separator, the
    /// "Registrazioni" section header and one line per course, all with no target or action (no
    /// new AppKit-to-main-actor path, issue #30), the lines disabled.
    /// Mutations: drop the empty guard (a lone separator and header appear); drop
    /// `isEnabled = false` (the lines look clickable and do nothing); a plain item as header.
    @Test func theMenuSectionIsDisabledTextAfterASeparator() {
        let empty = NSMenu()
        StatusItemController.addRecordingItems(from: snapshot([]), to: empty)
        #expect(empty.items.isEmpty)

        let menu = NSMenu()
        StatusItemController.addRecordingItems(from: snapshot(["Analisi 2 — 12/30 · ~14 h", "Fisica — 3/10 · ~45 min"]), to: menu)
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

    /// The whole menu `menuNeedsUpdate` draws, in order: status, detail, action, the recordings
    /// section, separator, Open, Quit; without lines, no recordings items at all. The three
    /// actions keep their selectors. Guards the section being wired into the real menu and not
    /// displacing the existing items.
    /// Mutation: delete the `addRecordingItems` call in `build`.
    @Test func theMenuShowsTheSectionBetweenTheActionAndOpen() {
        let menu = NSMenu()
        menu.addItem(withTitle: "left over from the last opening", action: nil, keyEquivalent: "")
        StatusItemController.build(from: snapshot(["Analisi 2 — 12/30 · ~14 h", "Fisica — 3/10 · ~45 min"]), into: menu, target: nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == [
            "Sincronizzato", "3 nuovi", "Sincronizza ora",
            "—", "Registrazioni", "Analisi 2 — 12/30 · ~14 h", "Fisica — 3/10 · ~45 min",
            "—", "Apri BeepBar…", "Esci da BeepBar",
        ])
        #expect(menu.items[2].action == NSSelectorFromString("performAction"))
        #expect(menu.items[8].action == NSSelectorFromString("openConfiguration"))
        #expect(menu.items[9].action == NSSelectorFromString("quit"))

        StatusItemController.build(from: snapshot([]), into: menu, target: nil)
        #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == ["Sincronizzato", "3 nuovi", "Sincronizza ora", "—", "Apri BeepBar…", "Esci da BeepBar"])
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
}
