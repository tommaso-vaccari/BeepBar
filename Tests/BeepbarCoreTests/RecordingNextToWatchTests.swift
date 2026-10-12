import Foundation
import Testing
@testable import BeepbarCore

/// The lecture a click on a course's menu line plays (`RecordingWatchProgress.nextToWatch`) and its
/// place in the saved `CourseWatchSummary`. What they guard: a click that plays a lecture already
/// done, skips the one the student is in the middle of, depends on the archive's row order, or
/// moves on every progress tick; and saved summaries that a build with or without `next` can no
/// longer read (the app deletes unreadable saved data at launch, so that would blank the menu).
struct RecordingNextToWatchTests {
    typealias Progress = RecordingWatchProgress
    typealias Entry = RecordingWatchEntry

    /// A recording `day` days after a fixed date, with the given id and duration text.
    private func recording(_ id: String, day: Int, duration: String = "90 min") -> RecmanRecording {
        RecmanRecording(id: id, courseCode: "058167", academicYear: 2026, title: "Lecture \(id)",
                        recordedAt: Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + day * 86_400)),
                        kind: "Lezione", duration: duration, size: nil,
                        previewURL: URL(string: "https://onlineservices.polimi.it/x?transfer_id=\(id)")!)
    }

    // MARK: Choice

    /// With nothing partly watched, the oldest lecture not done is picked, whatever the input
    /// order. Guards against playing the newest lecture first. Mutation: swap `<` for `>` in
    /// `precedes` and the newest ("c") is returned.
    @Test func oldestUntouchedWhenNothingIsPartial() {
        let rows = [recording("c", day: 3), recording("a", day: 1), recording("b", day: 2)]
        #expect(Progress.nextToWatch(rows, entries: [:])?.id == "a")
    }

    /// A partly watched lecture wins over an older untouched one. Guards against sending the
    /// student back to the start of the course while they are in the middle of a lecture.
    /// Mutation: drop the partial priority (one candidate list) and "a" is returned; treat a
    /// partial lecture as done and "a" is returned too.
    @Test func partialLectureWinsOverOlderUntouched() {
        let rows = [recording("a", day: 1), recording("b", day: 2), recording("c", day: 3)]
        #expect(Progress.nextToWatch(rows, entries: ["b": Entry(furthest: 0.3)])?.id == "b")
        #expect(Progress.nextToWatch(rows, entries: ["c": Entry(furthest: 0.001)])?.id == "c",
                "any stored progress makes it partial")
    }

    /// Among several partly watched lectures the oldest wins, not the furthest along or the most
    /// recent. Guards against the choice depending on how far in the student is. Mutation: swap
    /// `<` for `>` and the newest partial one ("d") is returned.
    @Test func oldestPartialWins() {
        let rows = [recording("c", day: 3), recording("b", day: 2), recording("a", day: 1), recording("d", day: 4)]
        let entries: [String: Entry] = ["b": Entry(furthest: 0.1), "c": Entry(furthest: 0.8), "d": Entry(furthest: 0.5)]
        #expect(Progress.nextToWatch(rows, entries: entries)?.id == "b")
    }

    /// Done lectures are never picked, whether done by playback or ticked, even when they are
    /// older or have progress. A lecture un-ticked (blocked, not done) is missing again. Guards
    /// against a click replaying a finished lecture. Mutation: stop skipping completed entries and
    /// "a" (done, with progress) is returned.
    @Test func completedLecturesAreSkipped() {
        let rows = [recording("a", day: 1), recording("b", day: 2), recording("c", day: 3), recording("d", day: 4)]
        let entries: [String: Entry] = [
            "a": Entry(furthest: 0.95, completed: .playback),
            "b": Entry(furthest: 0, completed: .manual),
            "c": Entry(furthest: 0.4, completed: .manual),
        ]
        #expect(Progress.nextToWatch(rows, entries: entries)?.id == "d")
        let unticked = entries.merging(["b": Entry(furthest: 0, autoCompletionBlocked: true)]) { $1 }
        #expect(Progress.nextToWatch(rows, entries: unticked)?.id == "b", "un-ticked at 0 %: untouched again, and oldest")
    }

    /// Lectures recorded at the same moment are ordered by id, so every input order gives the same
    /// answer, for untouched and for partial lectures. Guards against the menu playing a different
    /// lecture after the archive lists rows in another order. Mutation: drop the id tiebreak
    /// (compare dates only) and the first of the equal rows in input order wins, so the reversed
    /// orders fail.
    @Test func tiesAreBrokenByIdWhateverTheOrder() {
        let rows = [recording("x2", day: 5), recording("x1", day: 5), recording("x3", day: 5)]
        for order in [rows, rows.reversed(), [rows[2], rows[0], rows[1]]] {
            #expect(Progress.nextToWatch(order, entries: [:])?.id == "x1")
            #expect(Progress.nextToWatch(order, entries: ["x3": Entry(furthest: 0.2), "x2": Entry(furthest: 0.7)])?.id == "x2")
        }
    }

    /// Lectures whose length is "0 min" or unreadable are still candidates: they are playable.
    /// Guards against skipping a lecture just because Recman didn't say how long it is.
    /// Mutation: skip rows whose `minutes` is nil or 0 and "a" or "b" is not returned.
    @Test func zeroAndUnknownLengthLecturesAreKept() {
        let rows = [recording("a", day: 1, duration: "0 min"), recording("b", day: 2, duration: "n/d"), recording("c", day: 3)]
        #expect(Progress.nextToWatch(rows, entries: [:])?.id == "a")
        #expect(Progress.nextToWatch(rows, entries: ["a": Entry(completed: .manual)])?.id == "b")
    }

    /// Nil when every lecture is done or the course has none, so the menu line has nothing to
    /// play rather than replaying a finished lecture. Mutation: include completed lectures and
    /// the all-done case returns one.
    @Test func allDoneOrEmptyIsNil() {
        let rows = [recording("a", day: 1), recording("b", day: 2)]
        #expect(Progress.nextToWatch(rows, entries: ["a": Entry(completed: .manual), "b": Entry(furthest: 1, completed: .playback)]) == nil)
        #expect(Progress.nextToWatch([], entries: [:]) == nil)
    }

    // MARK: Course summary overload

    /// The recordings overload gives the same counts as the rows one, plus `next`. Guards against
    /// the window and the saved summary disagreeing, since both go through it. Mutation: build
    /// the counts any other way (e.g. drop `live`) and the comparison fails; drop `next` and the
    /// last expectation fails.
    @Test func overloadMatchesRowsSummaryAndAddsNext() {
        let rows = [recording("a", day: 1), recording("b", day: 2, duration: "60 min"), recording("c", day: 3, duration: "n/d"), recording("d", day: 4)]
        let entries: [String: Entry] = ["a": Entry(furthest: 0.2, completed: .manual), "b": Entry(furthest: 0.5)]
        let live = ["b": 0.75, "d": 0.5]
        let summary = Progress.courseSummary(rows, entries: entries, live: live)
        let counts = Progress.courseSummary(rows.map { (id: $0.id, minutes: $0.minutes) }, entries: entries, live: live)
        #expect(summary.done == counts.done && summary.total == counts.total)
        #expect(summary.remainingMinutes == counts.remainingMinutes && summary.unknownDurationCount == counts.unknownDurationCount)
        #expect(summary == CourseWatchSummary(done: 1, total: 4, remainingMinutes: 60, unknownDurationCount: 1, next: rows[1]))
    }

    /// The player's in-memory fractions (`live`) never change `next`: a lecture playing for the
    /// first time stays untouched until a checkpoint stores its progress, so the choice (and the
    /// saved summary) doesn't move on a ~30 s tick. Only the stored entry makes it partial.
    /// Mutation: let `live` count as progress when choosing and "d" is returned instead of "a".
    @Test func liveFractionsDoNotChangeNext() {
        let rows = [recording("a", day: 1), recording("d", day: 4)]
        let withLive = Progress.courseSummary(rows, entries: [:], live: ["d": 0.5])
        let withoutLive = Progress.courseSummary(rows, entries: [:], live: [:])
        #expect(withLive.next?.id == "a")
        #expect(withLive.next == withoutLive.next)
        #expect(withLive.remainingMinutes != withoutLive.remainingMinutes, "live still counts in the time left")
        #expect(Progress.courseSummary(rows, entries: ["d": Entry(furthest: 0.5)], live: [:]).next?.id == "d",
                "once the checkpoint stores it, it is partial and wins")
    }

    // MARK: Persistence

    /// The four-field summary the app saved before `next` existed, as synthesized `Codable` wrote
    /// and read it: stands in for an older build.
    private struct OldSummary: Codable, Equatable {
        let done: Int
        let total: Int
        let remainingMinutes: Int
        let unknownDurationCount: Int
    }

    /// Data written before `next` existed decodes with `next` nil, in both encoders (the app uses
    /// a property list). Guards against a new build failing to read, and so deleting, every saved
    /// summary on its first launch. Mutation: decode `next` with plain `decode` and these fail.
    @Test func oldDataDecodesWithoutNext() throws {
        let old = OldSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1)
        let expected = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1)
        #expect(try PropertyListDecoder().decode(CourseWatchSummary.self, from: PropertyListEncoder().encode(old)) == expected)
        #expect(try JSONDecoder().decode(CourseWatchSummary.self, from: JSONEncoder().encode(old)) == expected)
        let explicitNull = Data(#"{"done":3,"total":10,"remainingMinutes":120,"unknownDurationCount":1,"next":null}"#.utf8)
        #expect(try JSONDecoder().decode(CourseWatchSummary.self, from: explicitNull) == expected)
    }

    /// A summary with `next` round-trips with it; without `next` nothing is written for it, so the
    /// data is what the old version wrote. Guards against `next` being lost on relaunch (the menu
    /// line would have nothing to play). Mutation: drop `next` from `encode` and the round trip fails.
    @Test func roundTripKeepsNext() throws {
        let summary = CourseWatchSummary(done: 1, total: 2, remainingMinutes: 45, unknownDurationCount: 0, next: recording("b", day: 2))
        #expect(try PropertyListDecoder().decode(CourseWatchSummary.self, from: PropertyListEncoder().encode(summary)) == summary)
        #expect(try JSONDecoder().decode(CourseWatchSummary.self, from: JSONEncoder().encode(summary)) == summary)
        let withoutNext = CourseWatchSummary(done: 1, total: 2, remainingMinutes: 45, unknownDurationCount: 0)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutNext)) as? [String: Any]
        #expect(object?.keys.sorted() == ["done", "remainingMinutes", "total", "unknownDurationCount"])
    }

    /// A damaged or differently shaped `next` costs only the shortcut: the summary still decodes,
    /// with `next` nil, while a damaged count still fails. Guards against one bad row deleting
    /// every saved course line at launch. Mutation: remove the `try?` around decoding `next` and
    /// these throw.
    @Test func malformedNextYieldsSummaryWithoutNext() throws {
        let expected = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1)
        for next in [#""garbage""#, #"{"id": 5}"#, #"{"id":"a","title":"x"}"#, "[1, 2]", "42"] {
            let data = Data(#"{"done":3,"total":10,"remainingMinutes":120,"unknownDurationCount":1,"next":\#(next)}"#.utf8)
            #expect(try JSONDecoder().decode(CourseWatchSummary.self, from: data) == expected, "next = \(next)")
        }
        let badCount = Data(#"{"done":"three","total":10,"remainingMinutes":120,"unknownDurationCount":1}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CourseWatchSummary.self, from: badCount) }
    }

    /// An older build (the four-field struct) reads data written with `next`, ignoring the extra
    /// key, so a rollback keeps the counts and only loses the shortcut. Guards against a format
    /// change (e.g. nesting the counts) that would make the old build delete the saved summaries.
    @Test func oldBuildReadsNewData() throws {
        let summary = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1, next: recording("a", day: 1))
        let old = OldSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1)
        #expect(try PropertyListDecoder().decode(OldSummary.self, from: PropertyListEncoder().encode(summary)) == old)
        #expect(try JSONDecoder().decode(OldSummary.self, from: JSONEncoder().encode(summary)) == old)
    }

    /// Equality includes `next`, so the app rewrites the saved summary when only the next lecture
    /// changes (it skips the write when the summary is equal). Guards against a stale shortcut.
    /// Mutation: exclude `next` from `==` and the first expectation fails.
    @Test func equalityIncludesNext() {
        let base = CourseWatchSummary(done: 1, total: 3, remainingMinutes: 90, unknownDurationCount: 0, next: recording("b", day: 2))
        #expect(base != CourseWatchSummary(done: 1, total: 3, remainingMinutes: 90, unknownDurationCount: 0, next: recording("c", day: 3)))
        #expect(base != CourseWatchSummary(done: 1, total: 3, remainingMinutes: 90, unknownDurationCount: 0))
        #expect(base == CourseWatchSummary(done: 1, total: 3, remainingMinutes: 90, unknownDurationCount: 0, next: recording("b", day: 2)))
    }
}
