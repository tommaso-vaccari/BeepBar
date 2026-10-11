import Foundation

// How much of each lecture recording the student has watched in BeepBar's own player, and when a
// lecture counts as done. Everything here is a pure value or a pure static function: the app owns
// the storage (`RecordingsSeenStore`'s `progress` table), the player reports and the UI, and asks
// these rules what every report means. Foundation-only and free of app types, so the decisions are
// covered by Core tests and `scripts/recman-probe` keeps compiling this folder on its own.
//
// Product rules (approved 2026-10-11):
// - Every lecture starts at 0 %. Progress is the furthest point reached; it never goes down, and
//   seeking ahead raises it.
// - A lecture is completed by playback only when the player is closed (window closed, `close()`,
//   or replaced by a different lecture) with progress at or past `completionThreshold`, or by the
//   student ticking it ("done / attended in person"). Pausing, a playback failure and quitting
//   never complete it.
// - Un-ticking keeps the progress but blocks automatic completion: from then on only a crossing
//   seen in one session (below the threshold, then at or past it, then a close) completes it, so
//   reopening a lecture that resumes at 92 % and closing it doesn't undo the student's choice.
// - Watching a completed lecture again keeps it completed.

/// What is stored for one recording of one account: the furthest point reached and whether the
/// lecture is done. A recording without an entry is untouched (0 %, not done).
public struct RecordingWatchEntry: Codable, Equatable, Sendable {
    /// How a lecture became done. The raw values are persisted (`progress.completed`) and must
    /// never change: an older or newer build reads the same numbers.
    ///
    /// A reader that meets a non-null value it doesn't know (written by a newer build that added
    /// another way of completing) must treat the lecture as done, never as not done, and must not
    /// rewrite that row: turning it into nil or a known case would silently undo the student's
    /// completion once they go back to the newer build.
    public enum Completion: Int, Codable, Sendable {
        /// Closed the player at or past `RecordingWatchProgress.completionThreshold`.
        case playback = 1
        /// Ticked by the student (watched elsewhere or attended in person).
        case manual = 2
    }

    /// The furthest point reached, as a fraction of the lecture in 0...1. Never decreases.
    public let furthest: Double
    /// Nil while the lecture is not done.
    public let completed: Completion?
    /// Set when the student un-ticks a done lecture, cleared when it becomes done again. While set,
    /// automatic completion needs an ordered crossing in one session (see `RecordingWatchSession`).
    public let autoCompletionBlocked: Bool

    /// `furthest` is clamped to 0...1 (NaN becomes 0), so a damaged stored value can't show more
    /// than 100 % or poison the remaining-hours sum.
    public init(furthest: Double = 0, completed: Completion? = nil, autoCompletionBlocked: Bool = false) {
        self.furthest = RecordingWatchProgress.clampedFraction(furthest) ?? 0
        self.completed = completed
        self.autoCompletionBlocked = autoCompletionBlocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(furthest: try container.decode(Double.self, forKey: .furthest),
                  completed: try container.decodeIfPresent(Completion.self, forKey: .completed),
                  autoCompletionBlocked: try container.decode(Bool.self, forKey: .autoCompletionBlocked))
    }

    /// The state of a recording nobody has watched or ticked: what a missing entry means.
    public static let untouched = RecordingWatchEntry()

    public var isCompleted: Bool { completed != nil }
}

/// What one playback session of one lecture has seen, from the moment the player opens it until it
/// is closed or replaced. Lives in memory only (the app keeps one per playing recording); the
/// stored entry changes only at checkpoints, through `RecordingWatchProgress.applyCheckpoint`.
///
/// The crossing flags exist for the un-tick rule: a lecture resumed at 92 % has never been below
/// the threshold in this session, so closing it is not a fresh "watched to the end".
public struct RecordingWatchSession: Equatable, Sendable {
    /// The furthest fraction observed in this session, nil before any usable observation.
    public private(set) var maxFraction: Double?
    /// An observation below `completionThreshold` happened (since the start or the last reset).
    public private(set) var sawBelowThreshold = false
    /// After such an observation, one at or past the threshold followed.
    public private(set) var crossedAfterBelow = false

    /// `start` is the fraction where playback begins (0 from the beginning, the resume position
    /// otherwise), or nil when the length is unknown; a known start counts as an observation.
    public init(start: Double?) {
        if let start { observe(start) }
    }

    /// One position report (periodic tick, seek or checkpoint), as a fraction. Values that are not
    /// finite are ignored; others are clamped to 0...1.
    public mutating func observe(_ fraction: Double) {
        guard let value = RecordingWatchProgress.clampedFraction(fraction) else { return }
        maxFraction = max(maxFraction ?? 0, value)
        if value < RecordingWatchProgress.completionThreshold {
            sawBelowThreshold = true
        } else if sawBelowThreshold {
            crossedAfterBelow = true
        }
    }

    /// Forget any crossing seen so far: called when the student un-ticks the lecture while it is
    /// playing, so a crossing that happened before the un-tick can't complete it at close. The
    /// furthest point stays.
    public mutating func resetCrossing() {
        sawBelowThreshold = false
        crossedAfterBelow = false
    }
}

/// Why the player reported its position. Mirrors the player's checkpoints (#148): only `.closed`,
/// and `.replaced` by a different lecture, can complete a lecture.
public enum RecordingCheckpointReason: String, Sendable, CaseIterable {
    case paused
    case closed
    case replaced
    case failed
}

/// What a course's recordings add up to: shown as "12/30 · ~14 h" in the window and the menu bar.
/// Stored as numbers (never as text), so it follows a language switch.
public struct CourseWatchSummary: Codable, Equatable, Sendable {
    /// Recordings that are done (by playback or ticked).
    public let done: Int
    /// Every recording of the course in the archive, including those of unknown length.
    public let total: Int
    /// Minutes left to watch over the recordings that are not done, rounded once at the end.
    public let remainingMinutes: Int
    /// Recordings not done whose length is unknown: they add nothing to `remainingMinutes`, so it
    /// is an underestimate when this is above zero.
    public let unknownDurationCount: Int

    public init(done: Int, total: Int, remainingMinutes: Int, unknownDurationCount: Int) {
        self.done = done
        self.total = total
        self.remainingMinutes = remainingMinutes
        self.unknownDurationCount = unknownDurationCount
    }
}

/// The rules that turn player reports and the student's ticks into stored progress.
public enum RecordingWatchProgress {
    /// At or past this fraction (inclusive) a closed lecture counts as watched: the last minutes
    /// of a recording are often questions, greetings or an empty room.
    public static let completionThreshold = 0.9

    /// Where `position` is in the lecture, as a fraction in 0...1, or nil when it can't be told.
    /// The player's own duration is preferred (it is the real stream length); Recman's minutes are
    /// the fallback while the player doesn't know it yet. Nil for a negative or non-finite
    /// position, and when neither length is usable, so an unknown length never reads as 0 % or 100 %.
    public static func fraction(position: TimeInterval, playerDuration: TimeInterval?, archiveMinutes: Int?) -> Double? {
        guard position.isFinite, position >= 0 else { return nil }
        let length: TimeInterval
        if let playerDuration, playerDuration.isFinite, playerDuration > 0 {
            length = playerDuration
        } else if let archiveMinutes, archiveMinutes > 0 {
            length = TimeInterval(archiveMinutes) * 60
        } else {
            return nil
        }
        return min(1, position / length)
    }

    /// The new entry after a player checkpoint, or nil when nothing changed (the caller then
    /// writes nothing). `session` must already include the checkpoint's own position.
    ///
    /// - Furthest becomes the larger of the stored one and the session's maximum.
    /// - A done lecture stays done, whatever this session saw.
    /// - Otherwise only a close (`closes`) can complete it: when not blocked, with furthest at or
    ///   past the threshold; when blocked by an un-tick, only with a crossing in this session.
    ///   Completing clears the block.
    public static func applyCheckpoint(_ entry: RecordingWatchEntry?, session: RecordingWatchSession, closes: Bool) -> RecordingWatchEntry? {
        let old = entry ?? .untouched
        let furthest = max(old.furthest, session.maxFraction ?? 0)
        var completed = old.completed
        var blocked = old.autoCompletionBlocked
        if completed == nil, closes {
            let qualifies = blocked ? session.crossedAfterBelow : furthest >= completionThreshold
            if qualifies {
                completed = .playback
                blocked = false
            }
        }
        let new = RecordingWatchEntry(furthest: furthest, completed: completed, autoCompletionBlocked: blocked)
        return new == old ? nil : new
    }

    /// The new entry after the student ticks (`done`) or un-ticks the lecture, or nil when nothing
    /// changed. Ticking keeps the furthest point (an untouched lecture is done at 0 %); un-ticking
    /// keeps it too and blocks automatic completion, so the next close doesn't immediately undo it.
    public static func setManual(_ entry: RecordingWatchEntry?, done: Bool) -> RecordingWatchEntry? {
        let old = entry ?? .untouched
        let new: RecordingWatchEntry
        if done {
            guard old.completed == nil else { return nil }
            new = RecordingWatchEntry(furthest: old.furthest, completed: .manual, autoCompletionBlocked: false)
        } else {
            guard old.completed != nil else { return nil }
            new = RecordingWatchEntry(furthest: old.furthest, completed: nil, autoCompletionBlocked: true)
        }
        return new
    }

    /// Whether a checkpoint closes the session, which is the only moment a lecture can be completed
    /// by playback. A replacement closes only when a different lecture takes its place: recovery
    /// that re-plays the same recording, or Play pressed again on it, is not a close. A replacement
    /// whose successor is unknown (`nextID` nil) is treated as a different lecture.
    public static func checkpointCloses(reason: RecordingCheckpointReason, reportedID: String, nextID: String?) -> Bool {
        switch reason {
        case .closed: true
        case .replaced: nextID != reportedID
        case .paused, .failed: false
        }
    }

    /// The summary of one course's archive rows. `entries` are the stored entries by recording id,
    /// `live` the in-memory fractions of lectures playing now (they may be ahead of the stored
    /// furthest). Every row counts in `total`; a row of unknown length adds no minutes and, when
    /// not done, counts in `unknownDurationCount`. A length outside
    /// `0...RecmanRecording.maxPlausibleMinutes` is treated as unknown, whatever the caller passed,
    /// so a damaged row can't make the sum overflow (see `maxPlausibleMinutes`). Rows are expected
    /// to have distinct ids, as the parser guarantees.
    public static func courseSummary(_ rows: [(id: String, minutes: Int?)], entries: [String: RecordingWatchEntry], live: [String: Double]) -> CourseWatchSummary {
        var done = 0
        var unknown = 0
        var remaining = 0.0
        for row in rows {
            let entry = entries[row.id] ?? .untouched
            if entry.isCompleted {
                done += 1
                continue
            }
            guard let minutes = row.minutes, (0...RecmanRecording.maxPlausibleMinutes).contains(minutes) else {
                unknown += 1
                continue
            }
            let watched = max(entry.furthest, live[row.id].flatMap(clampedFraction) ?? 0)
            remaining += Double(minutes) * (1 - watched)
        }
        // Rounded once over the whole course, so many partly watched lectures don't each lose
        // half a minute. With every row capped the sum can't reach `Int.max` in practice; the
        // saturating conversion is a second guard, because `Int(_:)` traps on an out-of-range
        // Double and this runs on every listing and menu refresh.
        let rounded = remaining.rounded()
        let remainingMinutes = rounded < Double(Int.max) ? Int(rounded) : Int.max
        return CourseWatchSummary(done: done, total: rows.count, remainingMinutes: remainingMinutes, unknownDurationCount: unknown)
    }

    /// One menu bar line, e.g. "Analisi 2 — 12/30 · ~14 h", in both languages so the caller can
    /// rebuild the menu after a language switch without recomputing anything. Under an hour the
    /// time left reads "~45 min"; from 60 minutes on it reads whole hours, rounded half away from
    /// zero (150 min → "~3 h"); with nothing left to watch only the count is shown; a course with
    /// every lecture done says so; a course with no recordings never reads "0/0".
    ///
    /// - Lectures of unknown length (`unknownDurationCount`) add nothing to "~N h", so the
    ///   estimate can understate the time left; the "~" is the only hint.
    /// - The empty-course text exists so this function is total, but the menu bar (package F)
    ///   omits courses with `total == 0` instead of showing it.
    public static func menuLine(courseName: String, _ summary: CourseWatchSummary) -> BilingualText {
        let head = "\(courseName) — "
        if summary.total == 0 {
            return BilingualText(head + "nessuna registrazione", head + "no recordings")
        }
        let count = "\(summary.done)/\(summary.total)"
        if summary.done >= summary.total {
            return BilingualText(head + count + " · tutte fatte", head + count + " · all done")
        }
        let left: String
        if summary.remainingMinutes <= 0 {
            return BilingualText(head + count, head + count)
        } else if summary.remainingMinutes < 60 {
            left = "~\(summary.remainingMinutes) min"
        } else {
            left = "~\(Int((Double(summary.remainingMinutes) / 60).rounded())) h"
        }
        return BilingualText(head + count + " · " + left, head + count + " · " + left)
    }

    /// `value` clamped to 0...1, or nil when it is not finite.
    static func clampedFraction(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}
