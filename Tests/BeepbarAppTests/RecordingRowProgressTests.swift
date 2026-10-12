import AppKit
import Foundation
import SwiftUI
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The Recordings window's watch progress on each row and in the course header (package E of
/// "recording view tracking"): what a row shows in every state, the percent and VoiceOver text,
/// the header line, and that a playing lecture's tick re-renders only its own row. Text is checked
/// through `BilingualText`, never by switching `AppLanguage.current`.
@MainActor struct RecordingRowProgressTests {
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

        let unknown = RecordingsPresentation.WatchValues(model).row(for: item, canEdit: true)
        #expect(unknown == .unknown)
        #expect(unknown.barValue == nil)
        #expect(!unknown.acceptsToggle)
        #expect(!unknown.known)

        model.setLive(nil, for: identity)
        model.setEntries([:], for: [identity])
        let untouched = RecordingsPresentation.WatchValues(model).row(for: item, canEdit: true)
        #expect(untouched.known)
        #expect(untouched.barValue == 0, "a known lecture nobody watched shows an empty bar, not no bar")
        #expect(untouched.percent == 0)
        #expect(!untouched.completed)
        #expect(untouched.acceptsToggle)
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
        #expect(RecordingsPresentation.WatchValues(model).row(for: item, canEdit: true).barValue == 0.42)

        model.setEntry(RecordingWatchEntry(furthest: 0.6), for: identity)
        let stored = RecordingsPresentation.WatchValues(model).row(for: item, canEdit: true)
        #expect(stored.barValue == 0.6)
        #expect(stored.percent == 60)
        #expect(!stored.completed)

        model.setLive(nil, for: identity)
        model.setEntry(RecordingWatchEntry(furthest: 0, completed: .manual), for: identity)
        let ticked = RecordingsPresentation.WatchValues(model).row(for: item, canEdit: true)
        #expect(ticked.completed)
        #expect(ticked.barValue == 1, "attended in person: done at 0 % still fills the bar")
    }

    /// The checkbox refuses clicks while its save is in flight and while ticking isn't possible
    /// (Recordings off, account unknown), and works otherwise. Mutation: drop `!pending` from
    /// `acceptsToggle` and a second click could queue an opposite write behind the first; drop
    /// `canEdit` and a tick with no account would be silently ignored by the controller.
    @Test func checkboxIsDisabledWhilePendingOrNotEditable() {
        let model = RecordingsWatchProgressModel()
        let item = recording("c")
        let identity = RecordingsStudyState.identity(item)
        model.setEntries([identity: RecordingWatchEntry(furthest: 0.3)], for: [identity])
        #expect(RecordingsPresentation.WatchValues(model).row(for: item, canEdit: true).acceptsToggle)
        #expect(!RecordingsPresentation.WatchValues(model).row(for: item, canEdit: false).acceptsToggle)

        model.setPending(true, for: identity)
        let pending = RecordingsPresentation.WatchValues(model).row(for: item, canEdit: true)
        #expect(pending.pending)
        #expect(!pending.acceptsToggle)
        #expect(!pending.completed, "the box keeps the committed value while the tick is saved")
        #expect(pending.barValue == 0.3)
    }

    /// The percent is rounded down and capped at 99 until the lecture is done, so a row never
    /// says 100 % for a lecture that isn't done (played to the very end but still open, or
    /// un-ticked after watching it), and a damaged value can't read as more than 100 % or NaN.
    /// Mutation: round to nearest and 0.996 reads 100 %, 0.005 reads 1 %; drop the cap and 1.0
    /// reads 100 %.
    @Test func percentIsFlooredAndNeverClaimsAHundredBeforeDone() {
        func percent(_ fraction: Double) -> Int { WatchRow(known: true, fraction: fraction, completed: false, pending: false, canEdit: true).percent }
        #expect(percent(0) == 0)
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

    /// Rows compare equal regardless of their actions, and differ when any shown value differs:
    /// what lets SwiftUI skip a row's body. Mutation: make `==` ignore `watch` and a tick never
    /// moves the bar; make it compare nothing and every row is stale.
    @Test func rowEqualityIgnoresActionsButNotShownValues() {
        func row(_ watch: WatchRow, isNew: Bool = false, action: @escaping () -> Void = {}) -> RecordingRow {
            RecordingRow(recording: recording("e"), number: 3, isNew: isNew, isOpening: false, isWatchlisted: false,
                         canEdit: true, canPlay: true, watchlistCourseName: "Analisi",
                         watch: watch, actions: .init(toggleWatchlist: action, play: action, setDone: { _ in }))
        }
        let half = WatchRow(known: true, fraction: 0.5, completed: false, pending: false, canEdit: true)
        #expect(row(half) == row(half, action: { print("other") }))
        #expect(row(half) != row(WatchRow(known: true, fraction: 0.51, completed: false, pending: false, canEdit: true)))
        #expect(row(half) != row(WatchRow(known: true, fraction: 0.5, completed: false, pending: true, canEdit: true)))
        #expect(row(half) != row(half, isNew: true))
    }

    /// The performance property of principle 6, on the real Recordings page with the isolated
    /// 1,000-recording fixture (synthetic account, mocked network, fresh folder): a tick of the
    /// playing lecture (`live` changes) runs the body of that lecture's row and of no other row.
    /// Mutation: make `==` return false and every visible row's body runs again; hand the
    /// content the model instead of `WatchValues` (a reference the row closure captures, as the
    /// first draft did) or stop observing in `WatchProgressReader`, and the playing row's bar
    /// never moves.
    @Test(.timeLimit(.minutes(1))) func aTickReRendersOnlyThePlayingRow() async throws {
        let scenario = try UIFixtureScenario(arguments: ["--scenario", "recordings-1000", "--report", "/tmp/ui-fixture-unused-\(UUID().uuidString).json"])
        let fixture = try await UIFixture.make(scenario)
        defer { fixture.dispose() }
        let recordings = fixture.controller.recordings
        let key = try #require(RecmanCourseKey(course: fixture.controller.courses[0]))

        var bodies: [String: Int] = [:]
        RecordingRow.bodyProbe = { bodies[$0, default: 0] += 1 }
        defer { RecordingRow.bodyProbe = nil }

        let host = NSHostingView(rootView: RecordingsPage(authentication: fixture.controller, recordings: recordings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.close() }

        let playing = try #require(await firstListing(recordings, key: key))
        let identity = RecordingsStudyState.identity(playing)
        try await settle(host) { bodies[playing.id] != nil && recordings.watchProgress.known.contains(identity) }
        #expect(recordings.watchProgress.isKnown(playing))
        let visible = bodies.keys.count
        #expect(visible > 1, "several rows are on screen, so a broad re-render would show")

        bodies = [:]
        recordings.watchProgress.setLive(0.37, for: identity)
        try await settle(host) { bodies[playing.id] != nil }
        #expect(bodies[playing.id] != nil, "the playing row shows its new position")
        #expect(bodies.keys.sorted() == [playing.id], "a tick re-rendered \(bodies.count - 1) other row(s)")

        // A second tick on another lecture's identity: the first row stays as it is.
        let other = try #require(recordings.listings[key]?.recordings?.first { $0.id != playing.id && bodies[$0.id] == nil })
        bodies = [:]
        recordings.watchProgress.setLive(0.5, for: "2026:000000:not-on-screen-\(other.id)")
        try await settle(host)
        #expect(bodies.isEmpty, "a tick of a lecture not in the list re-rendered \(bodies.count) row(s)")
    }

    private func firstListing(_ recordings: RecordingsController, key: RecmanCourseKey) async -> RecmanRecording? {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let list = recordings.listings[key]?.recordings, !list.isEmpty {
                return list.max { $0.recordedAt < $1.recordedAt }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Lets SwiftUI lay out until `condition` holds (or 10 s pass), then a little more so late
    /// body evaluations land in the count.
    private func settle(_ host: NSView, until condition: () -> Bool = { true }) async throws {
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
}
