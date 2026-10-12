import Foundation

/// Where the student stopped in each recording they watched in BeepBar's own player (#148), and
/// the rules that turn the player's reports into that memory.
///
/// Foundation-only and free of app types, so the decisions are covered by Core tests (also on
/// Linux). The app (`RecordingsController`) owns the storage: one value in the settings, tied to
/// one WeBeep account and deleted on turn-off, logout and account change.
///
/// What is stored is a number of seconds per key, nothing else: no title and no date. The key is
/// an opaque identity chosen by the caller; the app uses `year:course code:recording id`, so it
/// does name a course and a lecture (and is deleted with the session for that reason).
public struct RecordingResumePoints: Codable, Equatable, Sendable {
    /// The WeBeep account these positions belong to. A value stored for another account is
    /// treated as empty by the caller and replaced at the next write.
    public var owner: Int

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var position: TimeInterval
    }

    /// Oldest first: the entry written least recently is the first to go when `capacity` is
    /// exceeded. Lectures are watched a few at a time, so 200 spans a whole semester of
    /// unfinished ones, while the stored value stays a few kilobytes however long BeepBar is used.
    public private(set) var entries: [Entry]

    public static let capacity = 200

    public init(owner: Int, entries: [Entry] = []) {
        self.owner = owner
        self.entries = entries
    }

    public func position(for id: String) -> TimeInterval? {
        entries.first { $0.id == id }?.position
    }

    /// What the student's report means for the stored positions. Returns whether anything
    /// changed, so the caller writes only then: a pause at the position already stored writes
    /// nothing.
    @discardableResult
    public mutating func apply(_ update: RecordingPlaybackProgress.Update, for id: String) -> Bool {
        switch update {
        case .ignore:
            return false
        case .remember(let position):
            if let index = entries.firstIndex(where: { $0.id == id }) {
                if entries[index].position == position { return false }
                entries.remove(at: index)
            }
            entries.append(Entry(id: id, position: position))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
            return true
        case .finished, .startOver:
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries.remove(at: index)
            return true
        }
    }
}

/// The rules for "resume where you left off" (#148).
public enum RecordingPlaybackProgress {
    /// What a report from the player means.
    public enum Update: Equatable, Sendable {
        /// Not usable (a negative or non-finite position).
        case ignore
        /// The student stopped part-way through: resume here next time.
        case remember(TimeInterval)
        /// The student reached the end: the lecture counts as watched and starts from the
        /// beginning next time.
        case finished
        /// The student is back near the start: there is nothing worth resuming.
        case startOver
    }

    /// A position closer to the start than this is not worth resuming, and a resume position
    /// closer than this is ignored by the player (`RecordingPlayerPolicy.resumeMargin`, which has
    /// the same value: remembering a position the player would refuse is pointless).
    public static let startMargin: TimeInterval = 5

    /// The least that must be left for a lecture not to count as finished: 30 seconds, or 2 % of
    /// the lecture when that is more (about 2 minutes of a 100-minute lecture), so that stopping
    /// during the closing remarks or the empty tail of a recording, or leaving a moment before the
    /// very end, is "watched" and not "resume 40 seconds before the end".
    public static func finishedMargin(duration: TimeInterval) -> TimeInterval {
        max(30, duration * 0.02)
    }

    /// The decision for one report from the player's `onPositionCheckpoint`. Without a known
    /// duration the end can't be recognised, so only the start margin applies.
    public static func update(position: TimeInterval, duration: TimeInterval?) -> Update {
        guard position.isFinite, position >= 0 else { return .ignore }
        if let duration, duration.isFinite, duration > 0, position >= duration - finishedMargin(duration: duration) {
            return .finished
        }
        if position < startMargin { return .startOver }
        return .remember(position)
    }

    /// The position to hand to the player for a recording, from what is stored: nil to start
    /// from the beginning.
    public static func startAt(stored: TimeInterval?) -> TimeInterval? {
        guard let stored, stored.isFinite, stored >= startMargin else { return nil }
        return stored
    }
}
