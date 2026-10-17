import AppKit
import Foundation
import SwiftUI
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The Recordings window's watch progress on each row and in the course header (package E of
/// "recording view tracking"): what a row shows in every state, the percent and VoiceOver text,
/// the header line, and that a playing lecture's tick re-renders only its own row. Text is checked
/// through `BilingualText`, never by switching `AppLanguage.current`. Serialized because the
/// hosting tests share the process-global `RecordingsPageProbes`.
@Suite(.serialized) @MainActor struct RecordingRowProgressTests {
    private typealias WatchRow = RecordingsPresentation.WatchRow

    private func recording(_ id: String) -> RecmanRecording {
        RecmanRecording(id: id, courseCode: "058167", academicYear: 2026, title: "Lesson \(id)",
                        recordedAt: Date(timeIntervalSince1970: 1_791_504_000), kind: "Lezione",
                        duration: "90 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/")!)
    }

    /// A row whose stored state isn't loaded (a Watchlist bookmark offline, signed out, still
    /// loading) shows no bar and accepts no tick, whatever the model holds in memory for it: the
    /// store may say "done", so neither 0 % nor an empty box may be claimed. Once known, an
    /// untouched lecture reads 0 % with a working checkbox. Mutation: drop the `known` guard in
    /// `WatchValues.row` and the unknown row gets a 50 % bar and an enabled box; make `barValue` ignore
    /// `known` and it gets a bar.
    @Test func unknownRowsShowNeitherBarNorCheckbox() {
        let model = RecordingsWatchProgressModel()
        let item = recording("a")
        let identity = RecordingsStudyState.identity(item)
        model.setLive(0.5, for: identity)
        model.setEntry(nil, for: "2026:058167:other")

        let unknown = RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item)
        #expect(unknown == .unknown)
        #expect(unknown.barValue == nil)
        #expect(!unknown.checkboxEnabled)
        #expect(!unknown.checkboxVisible, "an empty box would claim \"not done\"")
        #expect(unknown.checkboxAccessibilityHidden, "VoiceOver must not read a box that isn't shown")
        #expect(!unknown.known)

        // Unknown even when the model holds a done entry it hasn't confirmed as known.
        model.setEntry(RecordingWatchEntry(furthest: 1, completed: .manual), for: "2026:058167:unrelated")
        #expect(RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item) == .unknown)

        model.setLive(nil, for: identity)
        model.setEntries([:], for: [identity])
        let untouched = RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item)
        #expect(untouched.known)
        #expect(untouched.barValue == 0, "a known lecture nobody watched shows an empty bar, not no bar")
        #expect(untouched.percent == 0)
        #expect(!untouched.completed)
        #expect(!untouched.isOn)
        #expect(untouched.checkboxEnabled)
        #expect(untouched.checkboxVisible)
        #expect(!untouched.checkboxAccessibilityHidden)
    }

    /// The bar follows the further of the stored point and the playing session's, is full once
    /// done (a lecture ticked as attended at 0 % included), and the checkbox reflects the
    /// committed state only. Mutation: read only `entries` (not `live`) and the 0.42 tick is lost;
    /// take `live` over a further stored value and 0.6 drops to 0.42; drop the `completed` branch
    /// of `barValue` and a manual tick at 0 % shows an empty bar.
    @Test func barFollowsFurthestPointAndIsFullWhenDone() {
        let model = RecordingsWatchProgressModel()
        let item = recording("b")
        let identity = RecordingsStudyState.identity(item)
        model.setEntries([:], for: [identity])

        model.setLive(0.42, for: identity)
        #expect(RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item).barValue == 0.42)

        model.setEntry(RecordingWatchEntry(furthest: 0.6), for: identity)
        let stored = RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item)
        #expect(stored.barValue == 0.6)
        #expect(stored.percent == 60)
        #expect(!stored.completed)

        model.setLive(nil, for: identity)
        model.setEntry(RecordingWatchEntry(furthest: 0, completed: .manual), for: identity)
        let ticked = RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item)
        #expect(ticked.completed)
        #expect(ticked.barValue == 1, "attended in person: done at 0 % still fills the bar")
    }

    /// The checkbox refuses clicks while its save is in flight and while ticking isn't possible
    /// (Recordings off, account unknown), and works otherwise. Mutation: drop `!pending` from
    /// `checkboxEnabled` and a second click could queue an opposite write behind the first; drop
    /// `canEdit` and a tick with no account would be silently ignored by the controller.
    @Test func checkboxIsDisabledWhilePendingOrNotEditable() {
        let model = RecordingsWatchProgressModel()
        let item = recording("c")
        let identity = RecordingsStudyState.identity(item)
        model.setEntries([identity: RecordingWatchEntry(furthest: 0.3)], for: [identity])
        #expect(RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item).checkboxEnabled)
        #expect(!RecordingsPresentation.WatchValues(model, canEdit: false).row(for: item).checkboxEnabled)

        model.setPending(true, for: identity)
        let pending = RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item)
        #expect(pending.pending)
        #expect(!pending.checkboxEnabled)
        #expect(!pending.isOn, "the box keeps the committed value while the tick is saved")
        #expect(pending.barValue == 0.3)

        // Un-ticking a done lecture: still ticked while the un-tick is saved.
        model.setEntry(RecordingWatchEntry(furthest: 0.3, completed: .manual), for: identity)
        #expect(RecordingsPresentation.WatchValues(model, canEdit: true).row(for: item).isOn)
    }

    /// The checkbox's binding reads the committed value and forwards exactly what the student
    /// clicked. Mutations: an optimistic get (`completed != pending`) flips the box before the
    /// save commits; forwarding `!$0` ticks when the student un-ticks.
    @Test func doneBindingReadsCommittedValueAndForwardsTheClick() {
        var sent: [Bool] = []
        let pendingTick = WatchRow(known: true, fraction: 0.4, completed: false, pending: true, canEdit: true)
        let binding = RecordingRow.doneBinding(watch: pendingTick, setDone: { sent.append($0) })
        #expect(binding.wrappedValue == false, "a pending tick isn't shown before it commits")
        binding.wrappedValue = true
        binding.wrappedValue = false
        #expect(sent == [true, false])
        #expect(binding.wrappedValue == false, "setting doesn't change what the box shows")

        let pendingUntick = WatchRow(known: true, fraction: 0.4, completed: true, pending: true, canEdit: true)
        #expect(RecordingRow.doneBinding(watch: pendingUntick, setDone: { _ in }).wrappedValue == true)
    }

    /// The done styling (green bar, check mark) follows the committed completion only. Mutations:
    /// a tint that is never green, or a check mark on rows that aren't done.
    @Test func doneStylingFollowsCompletion() {
        let done = WatchRow(known: true, fraction: 0, completed: true, pending: false, canEdit: true)
        let partial = WatchRow(known: true, fraction: 0.95, completed: false, pending: false, canEdit: true)
        #expect(done.showsDoneStyle)
        #expect(done.barTint == .green)
        #expect(!partial.showsDoneStyle)
        #expect(partial.barTint == .accentColor)
        #expect(!WatchRow.unknown.showsDoneStyle)
    }

    /// The percent is rounded down and capped at 99 until the lecture is done, so a row never
    /// says 100 % for a lecture that isn't done (played to the very end but still open, or
    /// un-ticked after watching it), and a damaged value can't read as more than 100 % or NaN.
    /// Mutation: round to nearest and 0.996 reads 100 %, 0.005 reads 1 %; drop the cap and 1.0
    /// reads 100 %; drop the epsilon and 0.29 reads 28 % (0.29 × 100 < 29 in `Double`).
    @Test func percentIsFlooredAndNeverClaimsAHundredBeforeDone() {
        func percent(_ fraction: Double) -> Int { WatchRow(known: true, fraction: fraction, completed: false, pending: false, canEdit: true).percent }
        #expect(percent(0) == 0)
        #expect(percent(0.29) == 29)
        #expect(percent(0.57) == 57)
        #expect(percent(0.289_999) == 28)
        #expect(percent(0.005) == 0)
        #expect(percent(0.5) == 50)
        #expect(percent(0.899) == 89)
        #expect(percent(0.9) == 90)
        #expect(percent(0.996) == 99)
        #expect(percent(1) == 99)
        #expect(percent(.nan) == 0)
        #expect(percent(-0.2) == 0)
        #expect(percent(3) == 99)
        #expect(WatchRow(known: true, fraction: .nan, completed: false, pending: false, canEdit: true).barValue == 0)
    }

    /// VoiceOver reads "N% visto"/"N% watched", or "Fatta"/"Done" once done (whatever the
    /// percent), in both languages. Mutation: always read the percent and a lecture ticked at 0 %
    /// is announced as "0% watched".
    @Test func accessibilityValueInBothLanguages() {
        #expect(WatchRow(known: true, fraction: 0.42, completed: false, pending: false, canEdit: true).accessibilityValue
                == BilingualText("42% visto", "42% watched"))
        #expect(WatchRow(known: true, fraction: 0, completed: true, pending: false, canEdit: true).accessibilityValue
                == BilingualText("Fatta", "Done"))
        #expect(WatchRow(known: true, fraction: 1, completed: false, pending: false, canEdit: true).accessibilityValue
                == BilingualText("99% visto", "99% watched"))
    }

    /// The course header's line: "N/M fatte · ~X h rimanenti", only the count when nothing is
    /// left (all done, or only lectures of unknown or zero length), nothing at all for an unknown
    /// summary or an empty course (never "0/0"). Hours round like the menu bar (Core's
    /// `remainingTimeText`). Mutation: drop the `total > 0` guard and an empty course reads
    /// "0/0 fatte"; drop the `done < total` condition and a finished course with a stale minute
    /// count still shows time left.
    @Test func headerLineInBothLanguages() {
        func text(_ done: Int, _ total: Int, _ minutes: Int) -> BilingualText? {
            RecordingsPresentation.watchSummaryText(CourseWatchSummary(done: done, total: total, remainingMinutes: minutes, unknownDurationCount: 0))
        }
        #expect(RecordingsPresentation.watchSummaryText(nil) == nil)
        #expect(text(0, 0, 0) == nil)
        #expect(text(12, 30, 840) == BilingualText("12/30 fatte · ~14 h rimanenti", "12/30 done · ~14 h left"))
        #expect(text(12, 30, 150) == BilingualText("12/30 fatte · ~3 h rimanenti", "12/30 done · ~3 h left"))
        #expect(text(29, 30, 45) == BilingualText("29/30 fatte · ~45 min rimanenti", "29/30 done · ~45 min left"))
        #expect(text(0, 30, 0) == BilingualText("0/30 fatte", "0/30 done"))
        #expect(text(30, 30, 0) == BilingualText("30/30 fatte", "30/30 done"))
        #expect(text(30, 30, 10) == BilingualText("30/30 fatte", "30/30 done"))
    }

    /// Rows compare equal regardless of their actions, and differ when any shown or captured
    /// value differs: what lets SwiftUI skip a row's body safely. A row skipped as equal keeps its
    /// old actions, so a field missing from `==` would leave Play, the bookmark or the checkbox
    /// bound to another lecture (same id in another course or year) or to the old course name.
    /// Mutation: drop any single field from `RecordingRow.==` and its line here fails.
    @Test func rowEqualityIgnoresActionsButNotShownValues() {
        let half = WatchRow(known: true, fraction: 0.5, completed: false, pending: false, canEdit: true)
        struct Fields {
            var recording: RecmanRecording
            var number: Int? = 3
            var isNew = false
            var isOpening = false
            var isWatchlisted = false
            var canEdit = true
            var canPlay = true
            var courseName: String? = nil
            var unavailable = false
            var watchlistCourseName = "Analisi"
            var watch: WatchRow
        }
        func row(_ f: Fields, action: @escaping () -> Void = {}) -> RecordingRow {
            RecordingRow(recording: f.recording, number: f.number, isNew: f.isNew, isOpening: f.isOpening, isWatchlisted: f.isWatchlisted,
                         canEdit: f.canEdit, canPlay: f.canPlay, courseName: f.courseName, unavailable: f.unavailable,
                         watchlistCourseName: f.watchlistCourseName,
                         watch: f.watch, actions: .init(toggleWatchlist: action, play: action, setDone: { _ in }))
        }
        let base = Fields(recording: recording("e"), watch: half)
        #expect(row(base) == row(base, action: { print("other") }), "actions are not compared")

        func differs(_ comment: Comment, _ change: (inout Fields) -> Void) {
            var other = base
            change(&other)
            #expect(row(base) != row(other), comment)
        }
        let original = base.recording
        differs("same id, another course") {
            $0.recording = RecmanRecording(id: original.id, courseCode: "052499", academicYear: original.academicYear, title: original.title, recordedAt: original.recordedAt, kind: original.kind, duration: original.duration, size: original.size, previewURL: original.previewURL)
        }
        differs("same id, another year") {
            $0.recording = RecmanRecording(id: original.id, courseCode: original.courseCode, academicYear: original.academicYear + 1, title: original.title, recordedAt: original.recordedAt, kind: original.kind, duration: original.duration, size: original.size, previewURL: original.previewURL)
        }
        differs("number") { $0.number = 4 }
        differs("isNew") { $0.isNew = true }
        differs("isOpening") { $0.isOpening = true }
        differs("isWatchlisted") { $0.isWatchlisted = true }
        differs("canEdit") { $0.canEdit = false }
        differs("canPlay") { $0.canPlay = false }
        differs("courseName") { $0.courseName = "Analisi" }
        differs("unavailable") { $0.unavailable = true }
        differs("watchlistCourseName") { $0.watchlistCourseName = "Analisi II" }
        differs("watch fraction") { $0.watch = WatchRow(known: true, fraction: 0.51, completed: false, pending: false, canEdit: true) }
        differs("watch pending") { $0.watch = WatchRow(known: true, fraction: 0.5, completed: false, pending: true, canEdit: true) }
    }

    /// A hosted `RecordingsPage` on the isolated `recordings-1000` fixture (synthetic account,
    /// mocked network, fresh folder), with the page probes recording what reached the screen.
    @MainActor private final class HostedPage {
        let fixture: UIFixture
        let host: NSHostingView<RecordingsPage>
        let window: NSWindow
        var rows: [RecordingRow] = []
        var headers: [String] = []
        var recordings: RecordingsController { fixture.controller.recordings }

        @MainActor init() async throws {
            let scenario = try UIFixtureScenario(arguments: ["--scenario", "recordings-1000", "--report", "/tmp/ui-fixture-unused-\(UUID().uuidString).json"])
            fixture = try await UIFixture.make(scenario)
            host = NSHostingView(rootView: RecordingsPage(authentication: fixture.controller, recordings: fixture.controller.recordings))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.alphaValue = 0
            RecordingsPageProbes.row = { [unowned self] in rows.append($0) }
            RecordingsPageProbes.header = { [unowned self] in headers.append($0) }
            window.orderFront(nil)
        }

        @MainActor func close() {
            RecordingsPageProbes.row = nil
            RecordingsPageProbes.header = nil
            window.close()
            fixture.dispose()
        }

        /// Row bodies run since the last reset, by recording id.
        var bodies: [String: Int] { rows.reduce(into: [:]) { $0[$1.recording.id, default: 0] += 1 } }

        /// Lets SwiftUI lay out until `condition` holds (or 10 s pass), then a little more so
        /// late body evaluations land in the probes.
        @MainActor func settle(until condition: () -> Bool = { true }) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            } while !condition() && Date() < deadline
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// The fixture course's key and its newest lecture, once listed and known to the model.
        @MainActor func loadedCourse() async throws -> (key: RecmanCourseKey, newest: RecmanRecording) {
            let key = try #require(RecmanCourseKey(course: fixture.controller.courses[0]))
            try await settle { recordings.listings[key]?.recordings?.isEmpty == false && !recordings.watchProgress.known.isEmpty }
            let newest = try #require(recordings.listings[key]?.recordings?.max { $0.recordedAt < $1.recordedAt })
            try await settle { bodies[newest.id] != nil }
            return (key, newest)
        }

        /// The detail pane's list as AppKit sees it (SwiftUI's outline view), not the sidebar's:
        /// the one right of the 230-point sidebar, once it has at least `rows` rows.
        @MainActor func detailTable(rows: Int) async throws -> NSTableView {
            func tables(_ view: NSView) -> [NSTableView] { ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables) }
            func detail() -> NSTableView? { tables(host).first { $0.convert($0.bounds, to: nil).minX > 200 && $0.numberOfRows >= rows } }
            try await settle { detail() != nil }
            return try #require(detail())
        }

        /// A right click on `row` of `table`: the menu SwiftUI builds from `contextMenu`.
        @MainActor func contextMenu(_ table: NSTableView, row: Int) throws -> NSMenu {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            return try #require(table.menu(for: event), "no row menu reached the list")
        }

        /// Waits (at most 10 s) until the controller has finished the last opening: the fixture's
        /// browser refuses every link, so it ends with a problem and never reaches a real browser.
        @MainActor func untilOpeningEnds() async throws {
            try await settle { recordings.openingRecordingID == nil }
        }
    }

    /// The performance property of principle 6, on the real Recordings page: a tick of the
    /// playing lecture (`live` changes) runs the body of that lecture's row and of no other row,
    /// and a tick of a lecture that isn't listed runs none. Mutation: make `==` return false and
    /// every visible row's body runs again; hand the content the model instead of `WatchValues`
    /// (a reference the row closure captures, as the first draft did) or stop observing in
    /// `WatchProgressReader`, and the playing row's bar never moves.
    @Test(.timeLimit(.minutes(1))) func aTickReRendersOnlyThePlayingRow() async throws {
        let page = try await HostedPage()
        defer { page.close() }
        let (_, playing) = try await page.loadedCourse()
        let identity = RecordingsStudyState.identity(playing)
        #expect(page.recordings.watchProgress.isKnown(playing))
        #expect(page.bodies.keys.count > 1, "several rows are on screen, so a broad re-render would show")

        page.rows = []
        page.recordings.watchProgress.setLive(0.37, for: identity)
        try await page.settle { page.bodies[playing.id] != nil }
        #expect(page.bodies.keys.sorted() == [playing.id], "a tick re-rendered \(page.bodies.count - 1) other row(s), or not the playing one")
        #expect(page.rows.last?.watch.barValue == 0.37, "the playing row shows its new position")

        page.rows = []
        page.recordings.watchProgress.setLive(0.5, for: "2026:000000:not-listed")
        try await page.settle()
        #expect(page.bodies.isEmpty, "a tick of a lecture not in the list re-rendered \(page.bodies.count) row(s)")
    }

    /// The row menu and the primary action (double click, Return) of the course list reach the
    /// `List` through `WatchProgressReader`, which wraps it since the progress work (#198): the
    /// modifier sits on the reader, and SwiftUI must still hand it to the list inside. Driven
    /// through the real AppKit list: a right click builds the menu with the course list's items,
    /// its "Apri nel browser" opens the clicked lecture, and the double action and Return on the
    /// selected row play it (both start an opening of that lecture: `openingRecordingID`).
    /// Mutation: drop `primaryAction` (or the whole `contextMenu`) and the opening never starts
    /// or no menu is built; key `byID` wrongly and another lecture opens.
    @Test(.timeLimit(.minutes(1))) func courseListMenuAndPrimaryActionReachTheList() async throws {
        let page = try await HostedPage()
        defer { page.close() }
        let (key, _) = try await page.loadedCourse()
        let recordings = page.recordings
        // Row 0 is the newest week's header; row 2 is the week's second-newest lecture.
        let ordered = try #require(recordings.listings[key]?.recordings).sorted { $0.recordedAt > $1.recordedAt }
        let expected = ordered[1].id
        let table = try await page.detailTable(rows: 3)

        let menu = try page.contextMenu(table, row: 2)
        #expect(menu.items.map(\.title) == ["Apri nel browser", "Copia link", "Aggiungi alla watchlist"])
        menu.performActionForItem(at: 0)
        #expect(recordings.openingRecordingID == expected, "\"Apri nel browser\" opened \(recordings.openingRecordingID ?? "nothing")")
        try await page.untilOpeningEnds()

        table.selectRowIndexes([2], byExtendingSelection: false)
        try await page.settle()
        #expect(table.sendAction(table.doubleAction, to: table.target))
        #expect(recordings.openingRecordingID == expected, "a double click played \(recordings.openingRecordingID ?? "nothing")")
        try await page.untilOpeningEnds()

        page.window.makeFirstResponder(table)
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: page.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: returnKey)
        #expect(recordings.openingRecordingID == expected, "Return played \(recordings.openingRecordingID ?? "nothing")")
        try await page.untilOpeningEnds()
    }

    /// The same for the Watchlist, whose list is wrapped the same way: the menu has the
    /// Watchlist's items and the double action plays the bookmark. Mutation: drop the
    /// Watchlist's `primaryAction` or `contextMenu` and this fails.
    @Test(.timeLimit(.minutes(1))) func watchlistMenuAndPrimaryActionReachTheList() async throws {
        let page = try await HostedPage()
        defer { page.close() }
        let (_, newest) = try await page.loadedCourse()
        let recordings = page.recordings
        recordings.toggleWatchlist(newest, courseName: "Synthetic")
        recordings.selectDestination(.watchlist)
        try await page.settle { page.rows.contains { $0.courseName == "Synthetic" } }
        let table = try await page.detailTable(rows: 1)

        let menu = try page.contextMenu(table, row: 0)
        #expect(menu.items.map(\.title) == ["Rimuovi dalla watchlist", "Apri nel browser"])

        table.selectRowIndexes([0], byExtendingSelection: false)
        try await page.settle()
        #expect(table.sendAction(table.doubleAction, to: table.target))
        #expect(recordings.openingRecordingID == newest.id, "a double click played \(recordings.openingRecordingID ?? "nothing")")
        try await page.untilOpeningEnds()
    }

    /// The course header shows the model's live summary after the archive line, and nothing
    /// when the summary is unknown. Mutation: build the header line without the summary (or
    /// read it outside the reader) and the progress text never appears.
    @Test(.timeLimit(.minutes(1))) func headerShowsTheCourseSummary() async throws {
        let page = try await HostedPage()
        defer { page.close() }
        let (key, _) = try await page.loadedCourse()
        let summary = CourseWatchSummary(done: 3, total: 1_000, remainingMinutes: 600, unknownDurationCount: 0)
        let expected = try #require(RecordingsPresentation.watchSummaryText(summary)).text

        page.headers = []
        page.recordings.watchProgress.setSummary(summary, for: key)
        try await page.settle { page.headers.last?.hasSuffix(" · \(expected)") == true }
        #expect(page.headers.last?.hasSuffix(" · \(expected)") == true, "header was \(page.headers.last ?? "never drawn")")

        page.recordings.watchProgress.setSummary(nil, for: key)
        try await page.settle { page.headers.last?.contains(expected) == false }
        #expect(page.headers.last?.contains(expected) == false, "an unknown summary shows no progress")
    }

    /// Watchlist rows get their progress like course rows: a bookmark of a loaded course shows
    /// its stored state and the checkbox works; a bookmark whose course isn't loaded gets
    /// `.unknown` (no bar, no box). Mutation: give Watchlist rows `.unknown` (or another row's
    /// values) and the loaded bookmark loses its bar.
    @Test(.timeLimit(.minutes(1))) func watchlistRowsShowTheirProgress() async throws {
        let page = try await HostedPage()
        defer { page.close() }
        let (_, newest) = try await page.loadedCourse()
        let recordings = page.recordings
        recordings.watchProgress.setEntry(RecordingWatchEntry(furthest: 0.62), for: RecordingsStudyState.identity(newest))
        recordings.toggleWatchlist(newest, courseName: "Synthetic")
        let unloaded = RecmanRecording(id: "not-loaded", courseCode: "099999", academicYear: 2026, title: "Unloaded", recordedAt: newest.recordedAt, kind: "Lecture", duration: "60 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/")!)
        recordings.toggleWatchlist(unloaded, courseName: "Other course")
        #expect(recordings.study.contains(newest) && recordings.study.contains(unloaded))

        page.rows = []
        recordings.selectDestination(.watchlist)
        try await page.settle { page.rows.contains { $0.courseName == "Synthetic" } && page.rows.contains { $0.recording.id == "not-loaded" } }
        let loadedRow = try #require(page.rows.last { $0.recording.id == newest.id && $0.courseName == "Synthetic" })
        #expect(loadedRow.watch == WatchRow(known: true, fraction: 0.62, completed: false, pending: false, canEdit: recordings.canEditProgress))
        #expect(loadedRow.watch.checkboxEnabled)
        #expect(loadedRow.watchlistCourseName == "Synthetic")
        let unloadedRow = try #require(page.rows.last { $0.recording.id == "not-loaded" })
        #expect(unloadedRow.watch == .unknown)
    }

    /// The reader passes the controller's `canEditProgress` to every row: true while the
    /// account is known, false once Recordings is off. Mutation: replace it with `true` and the
    /// checkbox stays clickable with no account to save under.
    @Test(.timeLimit(.minutes(1))) func readerPassesCanEditProgress() async throws {
        let page = try await HostedPage()
        defer { page.close() }
        _ = try await page.loadedCourse()
        let recordings = page.recordings
        #expect(recordings.canEditProgress)
        #expect(WatchProgressReader(recordings: recordings) { _ in EmptyView() }.values.canEdit)
        recordings.turnOff()
        #expect(!recordings.canEditProgress)
        #expect(!WatchProgressReader(recordings: recordings) { _ in EmptyView() }.values.canEdit)
    }

    /// The sidebar row on the real page: it shows the sidebar name (renamed folder), shows the
    /// orange marker for a saved summary with lectures left (read from the account controller's
    /// committed summaries, not from the Recordings controller), redraws when the commit changes
    /// or the folder is renamed, and does NOT run its body on a playback tick.
    /// Mutations: show `entry.name` instead of `entry.sidebarName`; never pass the marker;
    /// drop `folders` from the sidebar cache key (the rename never arrives); read the window's
    /// live summaries or wrap the rows in the progress reader (the tick reaches the row).
    @Test(.timeLimit(.minutes(1))) func theSidebarRowShowsItsNameAndMarkerAndIgnoresTicks() async throws {
        let page = try await HostedPage()
        defer { RecordingsPageProbes.sidebarRow = nil; page.close() }
        let (key, playing) = try await page.loadedCourse()
        let course = try #require(page.fixture.controller.courses.first { RecmanCourseKey(course: $0) == key })
        var drawn: [(name: String, marker: Bool)] = []
        RecordingsPageProbes.sidebarRow = { drawn.append(($0, $1)) }
        let auth = page.fixture.controller

        auth.setWatchSummariesForTesting([key: CourseWatchSummary(done: 1, total: 4, remainingMinutes: 10, unknownDurationCount: 0)])
        try await page.settle { drawn.last?.marker == true }
        #expect(drawn.last?.marker == true, "a saved summary with lectures left shows the marker")

        let cleaned = RecordingsPresentation.courseName(course)
        auth.setCourseFoldersForTesting([course.id: "GAL"])
        let expected = RecordingsPresentation.sidebarName(courseName: cleaned, courseDisplayName: course.displayName, courseID: course.id, localFolderName: "GAL")
        #expect(expected != cleaned)
        try await page.settle { drawn.last?.name == expected }
        #expect(drawn.last?.name == expected, "the row follows the renamed folder, was \(drawn.last?.name ?? "never drawn")")

        auth.setWatchSummariesForTesting([key: CourseWatchSummary(done: 4, total: 4, remainingMinutes: 0, unknownDurationCount: 0)])
        try await page.settle { drawn.last?.marker == false }
        #expect(drawn.last?.marker == false, "all done: the marker goes")

        drawn = []
        page.recordings.watchProgress.setLive(0.4, for: RecordingsStudyState.identity(playing))
        try await page.settle()
        #expect(drawn.isEmpty, "a tick re-ran \(drawn.count) sidebar row bod(ies)")
    }
}
