import Foundation
import Testing
@testable import BeepbarCore

/// The rules for per-recording watch progress. What they guard: progress that goes backwards, a
/// lecture completed by a pause, a failure or a re-play of the same lecture, an un-tick undone by
/// the next close, a done lecture reopened as not done, a wrong hours-left estimate, and a menu
/// line that doesn't follow the language. Language is asserted through `BilingualText`, never by
/// switching `AppLanguage.current` (tests run in parallel).
struct RecordingWatchProgressTests {
    typealias Progress = RecordingWatchProgress
    typealias Entry = RecordingWatchEntry

    /// A session that started at `start` and then saw each of `fractions`.
    private func session(start: Double?, _ fractions: Double...) -> RecordingWatchSession {
        var session = RecordingWatchSession(start: start)
        fractions.forEach { session.observe($0) }
        return session
    }

    // MARK: Fractions

    /// The player's duration wins; Recman's minutes are the fallback; an unknown length, a bad
    /// position or a bad duration is nil, and the result never exceeds 1. Guards against an
    /// unknown length reading as 0 % or 100 %. Mutation: drop the archive fallback and the
    /// `archiveMinutes` expectations fail; drop `min(1, …)` and the overshoot one fails.
    @Test func fractionPrefersPlayerDurationAndFallsBackToArchive() {
        #expect(Progress.fraction(position: 1_800, playerDuration: 3_600, archiveMinutes: 90) == 0.5)
        #expect(Progress.fraction(position: 1_800, playerDuration: nil, archiveMinutes: 60) == 0.5)
        #expect(Progress.fraction(position: 1_800, playerDuration: 0, archiveMinutes: 60) == 0.5)
        #expect(Progress.fraction(position: 1_800, playerDuration: .nan, archiveMinutes: 60) == 0.5)
        #expect(Progress.fraction(position: 1_800, playerDuration: .infinity, archiveMinutes: 60) == 0.5)
        #expect(Progress.fraction(position: 1_800, playerDuration: nil, archiveMinutes: nil) == nil)
        #expect(Progress.fraction(position: 1_800, playerDuration: nil, archiveMinutes: 0) == nil, "\"0 min\" is not a usable length")
        #expect(Progress.fraction(position: -1, playerDuration: 3_600, archiveMinutes: 60) == nil)
        #expect(Progress.fraction(position: .nan, playerDuration: 3_600, archiveMinutes: 60) == nil)
        #expect(Progress.fraction(position: 4_000, playerDuration: 3_600, archiveMinutes: nil) == 1, "past the end is 100 %, not more")
        #expect(Progress.fraction(position: 0, playerDuration: 3_600, archiveMinutes: nil) == 0)
    }

    // MARK: Furthest point

    /// Progress is the furthest point reached: going back, or a later session that stops earlier,
    /// never lowers it; seeking ahead raises it. Mutation: store the session's maximum instead of
    /// `max(old, session)` and the "earlier session" expectation fails; record the last
    /// observation instead of the maximum and the seek-back one fails.
    @Test func furthestIsMonotonic() throws {
        let first = try #require(Progress.applyCheckpoint(nil, session: session(start: 0, 0.2, 0.6, 0.3), closes: false))
        #expect(first.furthest == 0.6, "seeking back to 30 % keeps 60 %")
        #expect(first.completed == nil)

        #expect(Progress.applyCheckpoint(first, session: session(start: 0, 0.4), closes: false) == nil,
                "a later session that stops earlier changes nothing, so nothing is written")
        let ahead = try #require(Progress.applyCheckpoint(first, session: session(start: 0.6, 0.85), closes: false))
        #expect(ahead.furthest == 0.85, "seeking ahead raises it")
    }

    /// Observations that aren't finite are ignored and the rest are clamped, so a bad report can't
    /// set progress above 100 % or erase it. Also: a session that saw nothing usable and a stored
    /// value out of range. Guards against NaN poisoning `max`.
    @Test func badObservationsAreIgnoredOrClamped() {
        var s = RecordingWatchSession(start: nil)
        #expect(s.maxFraction == nil)
        s.observe(.nan)
        s.observe(.infinity)
        #expect(s.maxFraction == nil)
        s.observe(1.7)
        #expect(s.maxFraction == 1)
        s.observe(-3)
        #expect(s.maxFraction == 1)

        #expect(Progress.applyCheckpoint(nil, session: RecordingWatchSession(start: nil), closes: true) == nil,
                "nothing observed and nothing stored: nothing to write, even at close")
        #expect(Entry(furthest: 4).furthest == 1)
        #expect(Entry(furthest: .nan).furthest == 0)
        #expect(Entry(furthest: -0.5).furthest == 0)
    }

    // MARK: Completion by playback

    /// Only a close completes, and 0.9 is inclusive: a pause at 95 % doesn't complete, a close at
    /// exactly 90 % does, a close at 89.9 % doesn't. Mutation: `>=` → `>` in `applyCheckpoint`
    /// turns the exact-threshold case red; ignoring `closes` turns the pause case red.
    @Test func onlyACloseAtOrPastTheThresholdCompletes() throws {
        let paused = try #require(Progress.applyCheckpoint(nil, session: session(start: 0, 0.95), closes: false))
        #expect(paused.furthest == 0.95)
        #expect(paused.completed == nil, "pausing never completes")

        let exact = try #require(Progress.applyCheckpoint(nil, session: session(start: 0, 0.9), closes: true))
        #expect(exact.completed == .playback, "0.9 is inclusive")

        let short = try #require(Progress.applyCheckpoint(nil, session: session(start: 0, 0.899), closes: true))
        #expect(short.completed == nil)

        // A pause at 95 %, then a later close without going further: furthest is what counts.
        let later = try #require(Progress.applyCheckpoint(paused, session: session(start: 0.95), closes: true))
        #expect(later.completed == .playback)
    }

    /// Completion by playback reads the stored furthest point, not just this session: a lecture
    /// paused at 95 % earlier, reopened from the start and closed at 10 % is done. Guards against
    /// a student who watched almost all of it across sessions never seeing it done. Mutation:
    /// test `(session.maxFraction ?? 0) >= completionThreshold` instead of `furthest` and this fails.
    @Test func completionUsesTheStoredFurthestPoint() throws {
        let reopened = try #require(Progress.applyCheckpoint(Entry(furthest: 0.95), session: session(start: 0, 0.1), closes: true))
        #expect(reopened == Entry(furthest: 0.95, completed: .playback))
    }

    /// Which checkpoints are closes: a close is; a replacement by a different lecture is (or by
    /// an unknown one); a replacement by the same lecture (recovery or Play again) is not; pause
    /// and failure are not. Mutation: return true for `.replaced` unconditionally and the same-id
    /// case fails; return true for `.failed` and that case fails.
    @Test func whichCheckpointsClose() {
        #expect(Progress.checkpointCloses(reason: .closed, reportedID: "a", nextID: nil))
        #expect(Progress.checkpointCloses(reason: .replaced, reportedID: "a", nextID: "b"))
        #expect(Progress.checkpointCloses(reason: .replaced, reportedID: "a", nextID: nil))
        #expect(!Progress.checkpointCloses(reason: .replaced, reportedID: "a", nextID: "a"), "re-playing the same lecture is not a close")
        #expect(!Progress.checkpointCloses(reason: .paused, reportedID: "a", nextID: nil))
        #expect(!Progress.checkpointCloses(reason: .failed, reportedID: "a", nextID: "b"))
        #expect(!Progress.checkpointCloses(reason: .paused, reportedID: "a", nextID: "b"))
    }

    /// Watching a done lecture again keeps it done, and furthest may still rise. Guards against a
    /// rewatch that stops early "un-completing" a lecture. Mutation: recompute `completed` from
    /// this close only and the short-rewatch expectation fails.
    @Test func rewatchKeepsCompleted() throws {
        let done = Entry(furthest: 0.5, completed: .manual)
        #expect(Progress.applyCheckpoint(done, session: session(start: 0, 0.3), closes: true) == nil)
        let further = try #require(Progress.applyCheckpoint(done, session: session(start: 0, 0.7), closes: true))
        #expect(further == Entry(furthest: 0.7, completed: .manual), "still ticked, not turned into playback")
        let byPlayback = Entry(furthest: 0.95, completed: .playback)
        #expect(Progress.applyCheckpoint(byPlayback, session: session(start: 0, 0.1), closes: false) == nil)
    }

    // MARK: Manual ticks

    /// Ticking an untouched lecture makes it done at 0 %; ticking keeps furthest; ticking again or
    /// un-ticking something not done changes nothing. Mutation: reset furthest when ticking and
    /// the 0.4 expectation fails; drop the "already done" guard, or narrow it to
    /// `old.completed != .manual`, and ticking an already done lecture returns non-nil.
    @Test func tickingAndUntickingAreIdempotent() throws {
        let ticked = try #require(Progress.setManual(nil, done: true))
        #expect(ticked == Entry(furthest: 0, completed: .manual, autoCompletionBlocked: false))
        #expect(Progress.setManual(ticked, done: true) == nil)
        #expect(Progress.setManual(nil, done: false) == nil, "nothing to un-tick")
        #expect(Progress.setManual(Entry(furthest: 0.4), done: false) == nil)

        let partly = try #require(Progress.setManual(Entry(furthest: 0.4), done: true))
        #expect(partly.furthest == 0.4)

        #expect(Progress.setManual(Entry(furthest: 0.95, completed: .playback), done: true) == nil,
                "already done by playback: ticking writes nothing and keeps .playback")

        let unticked = try #require(Progress.setManual(Entry(furthest: 0.95, completed: .playback), done: false))
        #expect(unticked == Entry(furthest: 0.95, completed: nil, autoCompletionBlocked: true), "keeps furthest, blocks auto-completion")

        let reticked = try #require(Progress.setManual(unticked, done: true))
        #expect(reticked == Entry(furthest: 0.95, completed: .manual, autoCompletionBlocked: false), "ticking again clears the block")
    }

    /// After an un-tick, reopening a lecture that resumes at 92 % and closing it doesn't complete
    /// it again, and neither does above-then-seek-back-below; only below-then-at-or-past-then-close
    /// in one session does, and that clears the block. Without a block, the same 92 % reopen does
    /// complete (furthest rule). Mutation: ignore `autoCompletionBlocked` and the 92 % reopen case
    /// fails; set `crossedAfterBelow` for any observation at or past the threshold and the
    /// seek-back case fails.
    @Test func untickBlocksAutomaticCompletionUntilAFreshCrossing() throws {
        let blocked = Entry(furthest: 0.92, completed: nil, autoCompletionBlocked: true)

        #expect(Progress.applyCheckpoint(blocked, session: session(start: 0.92), closes: true) == nil,
                "resumed at 92 % and closed: still not done")
        #expect(Progress.applyCheckpoint(blocked, session: session(start: 0.92, 0.95, 0.5), closes: true)
                == Entry(furthest: 0.95, completed: nil, autoCompletionBlocked: true), "above, then back below: no crossing")

        let crossed = try #require(Progress.applyCheckpoint(blocked, session: session(start: 0.5, 0.91), closes: true))
        #expect(crossed == Entry(furthest: 0.92, completed: .playback, autoCompletionBlocked: false))

        #expect(Progress.applyCheckpoint(blocked, session: session(start: 0.5, 0.91), closes: false) == nil,
                "a crossing still needs the close")

        let unblocked = Entry(furthest: 0.92)
        #expect(Progress.applyCheckpoint(unblocked, session: session(start: 0.92), closes: true)?.completed == .playback)
    }

    /// Un-ticking while the lecture plays resets the crossing: a crossing seen before the un-tick
    /// must not complete it at close, but a new one afterwards does. Mutation: make
    /// `resetCrossing` a no-op and the first expectation fails.
    @Test func resetCrossingForgetsAnEarlierCrossing() throws {
        var s = session(start: 0.1, 0.95)
        #expect(s.crossedAfterBelow)
        s.resetCrossing()
        #expect(!s.crossedAfterBelow && !s.sawBelowThreshold)
        #expect(s.maxFraction == 0.95, "the furthest point stays")

        let blocked = Entry(furthest: 0.95, autoCompletionBlocked: true)
        #expect(Progress.applyCheckpoint(blocked, session: s, closes: true) == nil, "un-ticked at 95 %, then closed: not done")

        s.observe(0.4)
        s.observe(0.9)
        #expect(Progress.applyCheckpoint(blocked, session: s, closes: true)?.completed == .playback)
    }

    // MARK: Course summary

    /// Done and total count every row, including "0 min" and unknown-length ones; remaining is
    /// the minutes left of the rows not done, taking the larger of stored and live progress, and
    /// rounded once at the end. Mutation: round per row and the 3 × 0.5 min case gives 3 instead
    /// of 2; ignore `live` and the 60-minute row adds 60 instead of 15; skip unknown rows in
    /// `total` and the total fails; stop clamping live values and the 170 % one subtracts minutes.
    @Test func courseSummaryAddsUpTheArchive() {
        let rows: [(id: String, minutes: Int?)] = [
            ("done", 90), ("half", 100), ("live", 60), ("zero", 0), ("unknown", nil), ("fresh", 30),
        ]
        let entries: [String: Entry] = [
            "done": Entry(furthest: 0.1, completed: .manual),
            "half": Entry(furthest: 0.5),
            "live": Entry(furthest: 0.5),
        ]
        let summary = Progress.courseSummary(rows, entries: entries, live: ["live": 0.75, "half": 0.2])
        // half: 100 × 0.5 = 50 (live 0.2 is behind the stored 0.5); live: 60 × 0.25 = 15; fresh 30.
        #expect(summary == CourseWatchSummary(done: 1, total: 6, remainingMinutes: 95, unknownDurationCount: 1))

        let thirds: [(id: String, minutes: Int?)] = [("a", 1), ("b", 1), ("c", 1)]
        let halves = Progress.courseSummary(thirds, entries: [:], live: ["a": 0.5, "b": 0.5, "c": 0.5])
        #expect(halves.remainingMinutes == 2, "1.5 rounded once, not 0.5 rounded three times")

        // Typed: a bare `[]` is ambiguous between the rows and the recordings overloads.
        let noRows: [(id: String, minutes: Int?)] = []
        #expect(Progress.courseSummary(noRows, entries: [:], live: [:]) == CourseWatchSummary(done: 0, total: 0, remainingMinutes: 0, unknownDurationCount: 0))
        let bad = Progress.courseSummary([("a", 60)], entries: [:], live: ["a": .nan])
        #expect(bad.remainingMinutes == 60, "a non-finite live value counts as nothing watched")
        let overshoot = Progress.courseSummary([("a", 60), ("b", 60)], entries: [:], live: ["a": 1.7])
        #expect(overshoot.remainingMinutes == 60, "a live value past the end is 100 %, never negative minutes")
        let doneUnknown = Progress.courseSummary([("a", nil)], entries: ["a": Entry(completed: .playback)], live: [:])
        #expect(doneUnknown.unknownDurationCount == 0, "a done lecture's length doesn't matter")
    }

    /// A damaged row with an absurd length ("9223372036854775807 min", which the parser accepts)
    /// or two huge rows that would overflow together never trap: lengths above 24 h count in
    /// `total` and `unknownDurationCount` and add no minutes; exactly 24 h is still a length.
    /// Guards against a crash on every listing and menu refresh. Mutation: drop the
    /// `maxPlausibleMinutes` bound in `courseSummary` and the run traps (or the counts fail).
    @Test func implausibleLengthsCountAsUnknownAndNeverTrap() {
        let huge = Int.max / 2 + 1
        let rows: [(id: String, minutes: Int?)] = [
            ("max", Int.max), ("big1", huge), ("big2", huge), ("day", 1_440), ("dayAndAMinute", 1_441), ("negative", -5),
        ]
        let summary = Progress.courseSummary(rows, entries: [:], live: [:])
        #expect(summary == CourseWatchSummary(done: 0, total: 6, remainingMinutes: 1_440, unknownDurationCount: 5))
        let line = Progress.menuLine(courseName: "C", summary)
        #expect(line.english == "C — 0/6 · ~24 h")
    }

    /// The summary is stored as numbers and round-trips, so the menu can show the last known one
    /// after a relaunch. Guards against a Codable change breaking the persisted value.
    @Test func summaryAndEntryRoundTrip() throws {
        let summary = CourseWatchSummary(done: 12, total: 30, remainingMinutes: 840, unknownDurationCount: 1)
        #expect(try JSONDecoder().decode(CourseWatchSummary.self, from: JSONEncoder().encode(summary)) == summary)
        let entry = Entry(furthest: 0.4, completed: .manual, autoCompletionBlocked: true)
        #expect(try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(entry)) == entry)
        let damaged = Data(#"{"furthest": 7, "autoCompletionBlocked": false}"#.utf8)
        #expect(try JSONDecoder().decode(Entry.self, from: damaged) == Entry(furthest: 1))
        #expect(Entry.Completion.playback.rawValue == 1 && Entry.Completion.manual.rawValue == 2, "persisted values never change")
    }

    // MARK: Menu line

    /// The menu line in both languages: hours rounded to the nearest, minutes under an hour, "all
    /// done" when every lecture is done, the bare count when nothing measurable is left, and never
    /// "0/0". Mutation: drop the under-an-hour branch and "~45 min" becomes "~1 h"; make it
    /// `<= 60` and exactly 60 min reads "~60 min"; round hours with `.toNearestOrEven` and 150 min
    /// reads "~2 h"; drop the `total == 0` branch and the empty course reads "0/0 · tutte fatte".
    @Test func menuLineInBothLanguages() {
        func line(_ done: Int, _ total: Int, _ minutes: Int) -> BilingualText {
            Progress.menuLine(courseName: "Analisi 2", CourseWatchSummary(done: done, total: total, remainingMinutes: minutes, unknownDurationCount: 0))
        }
        #expect(line(12, 30, 840) == BilingualText("Analisi 2 — 12/30 · ~14 h", "Analisi 2 — 12/30 · ~14 h"))
        #expect(line(12, 30, 59) == BilingualText("Analisi 2 — 12/30 · ~59 min", "Analisi 2 — 12/30 · ~59 min"))
        #expect(line(12, 30, 60) == BilingualText("Analisi 2 — 12/30 · ~1 h", "Analisi 2 — 12/30 · ~1 h"), "exactly an hour reads as hours")
        #expect(line(12, 30, 150) == BilingualText("Analisi 2 — 12/30 · ~3 h", "Analisi 2 — 12/30 · ~3 h"), "2.5 h rounds up, not to even")
        #expect(line(12, 30, 89) == BilingualText("Analisi 2 — 12/30 · ~1 h", "Analisi 2 — 12/30 · ~1 h"))
        #expect(line(12, 30, 90) == BilingualText("Analisi 2 — 12/30 · ~2 h", "Analisi 2 — 12/30 · ~2 h"))
        #expect(line(29, 30, 45) == BilingualText("Analisi 2 — 29/30 · ~45 min", "Analisi 2 — 29/30 · ~45 min"))
        #expect(line(30, 30, 0) == BilingualText("Analisi 2 — 30/30 · tutte fatte", "Analisi 2 — 30/30 · all done"))
        #expect(line(29, 30, 0) == BilingualText("Analisi 2 — 29/30", "Analisi 2 — 29/30"), "only a \"0 min\" lecture left")
        #expect(line(0, 0, 0) == BilingualText("Analisi 2 — nessuna registrazione", "Analisi 2 — no recordings"))
    }

    /// The time-left text shared by the menu bar and the window's course header: nothing when
    /// nothing is left (never "~0 min"), minutes under an hour, rounded hours after. Mutation:
    /// drop the `<= 0` guard and a finished course reads "~0 min" in the window header.
    @Test func remainingTimeTextIsSharedAndOmitsZero() {
        #expect(Progress.remainingTimeText(minutes: 0) == nil)
        #expect(Progress.remainingTimeText(minutes: -5) == nil)
        #expect(Progress.remainingTimeText(minutes: 1) == "~1 min")
        #expect(Progress.remainingTimeText(minutes: 59) == "~59 min")
        #expect(Progress.remainingTimeText(minutes: 60) == "~1 h")
        #expect(Progress.remainingTimeText(minutes: 150) == "~3 h")
    }

    // MARK: Duration

    /// The minutes in Recman's duration, shared by the row and the estimate: "0 min" is 0 (not
    /// unknown), anything without leading digits is nil, an overflowing number is nil rather than
    /// a crash, and a length above 24 h is nil (unknown), so the course header's sum in the window
    /// can't overflow either. Mutation: make `minutes` return nil for 0 and the "0 min" case fails;
    /// drop the `maxPlausibleMinutes` bound and the 1441 and `Int.max` cases fail.
    @Test func recordingMinutes() throws {
        #expect(RecmanRecording.minutes(inDuration: "1440 min") == 1_440)
        #expect(RecmanRecording.minutes(inDuration: "1441 min") == nil)
        #expect(RecmanRecording.minutes(inDuration: "9223372036854775807 min") == nil)
        #expect(RecmanRecording.minutes(inDuration: "97 min") == 97)
        #expect(RecmanRecording.minutes(inDuration: "97min") == 97)
        #expect(RecmanRecording.minutes(inDuration: "0 min") == 0)
        #expect(RecmanRecording.minutes(inDuration: "") == nil)
        #expect(RecmanRecording.minutes(inDuration: "min") == nil)
        #expect(RecmanRecording.minutes(inDuration: "99999999999999999999999 min") == nil)
        let url = try #require(URL(string: "https://onlineservices.polimi.it/x"))
        let row = RecmanRecording(id: "1", courseCode: "058167", academicYear: 2026, title: "T", recordedAt: Date(timeIntervalSince1970: 0), kind: "Lezione", duration: "45 min", size: nil, previewURL: url)
        #expect(row.minutes == 45)
    }
}
