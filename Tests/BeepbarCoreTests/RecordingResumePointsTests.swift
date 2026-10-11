import Foundation
import Testing
@testable import BeepbarCore

/// The rules for "resume where you left off" (#148). What they guard: a lecture reopened at the
/// wrong place (or at the last seconds, so it ends at once), a finished lecture offered for
/// resuming forever, positions that grow without bound, and writes when nothing changed.
struct RecordingResumePointsTests {
    /// Stopping part-way is remembered exactly; near the start it is not worth remembering; at or
    /// near the end the lecture counts as finished. Mutation: change `>=` to `>` in `update` and
    /// the boundary expectation fails; make `finishedMargin` return 0 and the near-end ones fail.
    @Test func reportsMeanWhatTheirPositionSays() {
        #expect(RecordingPlaybackProgress.update(position: 1_800, duration: 6_000) == .remember(1_800))
        #expect(RecordingPlaybackProgress.update(position: 2, duration: 6_000) == .startOver)
        #expect(RecordingPlaybackProgress.update(position: 5, duration: 6_000) == .remember(5))
        // 2 % of 6 000 s is 120 s: from 5 880 s on the lecture is finished.
        #expect(RecordingPlaybackProgress.update(position: 5_879, duration: 6_000) == .remember(5_879))
        #expect(RecordingPlaybackProgress.update(position: 5_880, duration: 6_000) == .finished)
        #expect(RecordingPlaybackProgress.update(position: 6_000, duration: 6_000) == .finished)
        // A short recording uses the 30 s floor.
        #expect(RecordingPlaybackProgress.finishedMargin(duration: 600) == 30)
        #expect(RecordingPlaybackProgress.update(position: 569, duration: 600) == .remember(569))
        #expect(RecordingPlaybackProgress.update(position: 570, duration: 600) == .finished)
    }

    /// Unusable positions are ignored, and without a duration the end can't be told: a position
    /// far into an unknown-length stream is remembered, never "finished".
    @Test func unusablePositionsAndUnknownDurations() {
        #expect(RecordingPlaybackProgress.update(position: -1, duration: 600) == .ignore)
        #expect(RecordingPlaybackProgress.update(position: .nan, duration: 600) == .ignore)
        #expect(RecordingPlaybackProgress.update(position: .infinity, duration: 600) == .ignore)
        #expect(RecordingPlaybackProgress.update(position: 9_000, duration: nil) == .remember(9_000))
        #expect(RecordingPlaybackProgress.update(position: 9_000, duration: 0) == .remember(9_000))
        #expect(RecordingPlaybackProgress.update(position: 3, duration: nil) == .startOver)
    }

    /// Only a stored position past the start margin is handed to the player.
    @Test func startAtIgnoresNothingWorthResuming() {
        #expect(RecordingPlaybackProgress.startAt(stored: nil) == nil)
        #expect(RecordingPlaybackProgress.startAt(stored: 4.9) == nil)
        #expect(RecordingPlaybackProgress.startAt(stored: .nan) == nil)
        #expect(RecordingPlaybackProgress.startAt(stored: 5) == 5)
        #expect(RecordingPlaybackProgress.startAt(stored: 1_800) == 1_800)
    }

    /// The memory follows the reports: remembered, moved, forgotten at the end and at the start,
    /// and a report that changes nothing says so (the caller then writes nothing). Mutation: make
    /// `.remember` always return true and the "no change" expectations fail.
    @Test func applyingReports() {
        var points = RecordingResumePoints(owner: 42)
        #expect(points.apply(.remember(100), for: "a"))
        #expect(points.position(for: "a") == 100)
        #expect(!points.apply(.remember(100), for: "a"), "same position: nothing to write")
        #expect(points.apply(.remember(250), for: "a"))
        #expect(points.position(for: "a") == 250)
        #expect(!points.apply(.ignore, for: "a"))
        #expect(!points.apply(.finished, for: "unknown"), "forgetting what isn't there changes nothing")

        #expect(points.apply(.finished, for: "a"))
        #expect(points.position(for: "a") == nil)
        #expect(points.apply(.remember(300), for: "a"))
        #expect(points.apply(.startOver, for: "a"))
        #expect(points.position(for: "a") == nil)
        #expect(points.entries.isEmpty)
    }

    /// Positions never grow past the capacity: the least recently written goes first, and writing
    /// an old lecture again makes it the newest. Mutation: remove the `removeFirst` and the count
    /// expectation fails; drop the `remove(at:)` of the existing entry and the order check fails.
    @Test func theMemoryIsBounded() {
        var points = RecordingResumePoints(owner: 1)
        for index in 0..<(RecordingResumePoints.capacity + 5) {
            points.apply(.remember(Double(index) + 10), for: "r\(index)")
        }
        #expect(points.entries.count == RecordingResumePoints.capacity)
        #expect(points.position(for: "r0") == nil)
        #expect(points.position(for: "r4") == nil)
        #expect(points.position(for: "r5") == 15)
        points.apply(.remember(999), for: "r5")
        #expect(points.entries.last?.id == "r5")
        points.apply(.remember(10), for: "extra")
        #expect(points.position(for: "r5") == 999, "a recently written entry outlives older ones")
        #expect(points.position(for: "r6") == nil)
    }

    /// The stored form round-trips, and carries only the owner and the (key, seconds) entries: no
    /// title, date or person. The key itself is the caller's identity (the app's names the course
    /// code, year and recording id).
    @Test func theStoredFormRoundTrips() throws {
        var points = RecordingResumePoints(owner: 7)
        points.apply(.remember(61), for: "2026:058167:abc")
        let data = try PropertyListEncoder().encode(points)
        #expect(try PropertyListDecoder().decode(RecordingResumePoints.self, from: data) == points)
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(Set(dictionary.keys) == ["owner", "entries"])
    }
}
