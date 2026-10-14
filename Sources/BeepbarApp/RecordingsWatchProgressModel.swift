import Foundation
import BeepbarCore

/// What the Recordings window shows of the student's watch progress: the stored entry of each
/// recording of the loaded listings, the in-memory position of the lecture playing now, the
/// ticks still being saved, and each loaded course's live summary.
///
/// Why a separate object from `RecordingsController`: a playing lecture reports its position about
/// every 30 s (`RecordingPlaying.onProgress`). If that changed a `@Published` property of the
/// controller, every view observing the controller (sidebar, toolbar, every course row) would be
/// re-evaluated on each tick (principle 6: no UI work proportional to every list element on each
/// event). Only the views that draw progress observe this model.
///
/// Written only by `RecordingsController`, on the main actor; views only read. Keys are
/// `RecordingsStudyState.identity` ("year:course:id"), so the same lecture shown in a course and in
/// the Watchlist reads one value, and a remote id reused by another course or year never shares one.
///
/// Invariants the controller keeps (see its "Watch progress" section):
/// - `entries` holds what the store committed, never an optimistic value: a tick in progress shows
///   the committed state plus `pending`, and a failed save leaves nothing to revert.
/// - A missing entry means untouched (0 %, not done) only for a `known` identity: one published
///   with a listing read (same main-actor turn as the listing) or with a committed write. For an
///   unknown one (a Watchlist row while offline, signed out or still loading) the store may well
///   say "done": rows must check `isKnown` and not show 0 % or an empty checkbox for it.
///
/// Note for the row UI: a tick changes `live` (and `summaries`) about every 30 s while a lecture
/// plays, which re-renders every view observing this model. Observe it once in the list and pass
/// plain values to `Equatable` rows, so only the playing row's body runs again. The list must
/// capture a copy of the values (`WatchProgressReader`, `RecordingsPresentation.WatchValues`), not
/// this object: `List` rebuilds its lazily built rows only when what their closure captured
/// changes, and a captured reference never does.
/// - Everything here belongs to one account and is emptied on turn-off, disconnect and account
///   change (`reset()`), before the next account's data can arrive.
@MainActor final class RecordingsWatchProgressModel: ObservableObject {
    /// Stored progress by identity. Absent: untouched.
    @Published private(set) var entries: [String: RecordingWatchEntry] = [:]
    /// The furthest fraction seen by the playing session, in memory only, by identity. May be
    /// ahead of `entries` until the next checkpoint saves it.
    @Published private(set) var live: [String: Double] = [:]
    /// Identities whose tick or un-tick is being saved: the checkbox is disabled until then.
    @Published private(set) var pending: Set<String> = []
    /// Courses with a bulk save in flight, including across a listing refresh.
    @Published private(set) var pendingCourses: Set<RecmanCourseKey> = []
    /// Each loaded course's summary including `live`, for the window. The menu bar and the
    /// persisted copy use `RecordingsController.watchSummaries`, which ignores ticks.
    @Published private(set) var summaries: [RecmanCourseKey: CourseWatchSummary] = [:]
    /// Identities whose stored state this model has read or committed, so a missing entry for
    /// them really means untouched. Grows with loaded listings; emptied by `reset()`.
    @Published private(set) var known: Set<String> = []

    /// Whether the stored state of `recording` is known (see `known`). When false, `entry(for:)`
    /// and `fraction(for:)` say nothing about the store: hide or disable the bar and checkbox.
    func isKnown(_ recording: RecmanRecording) -> Bool { known.contains(RecordingsStudyState.identity(recording)) }

    /// The stored entry of `recording`, untouched when there is none (meaningful only if
    /// `isKnown`).
    func entry(for recording: RecmanRecording) -> RecordingWatchEntry {
        entries[RecordingsStudyState.identity(recording)] ?? .untouched
    }

    /// What the progress bar shows, in 0...1: the stored furthest point, or the playing
    /// session's when it is further.
    func fraction(for recording: RecmanRecording) -> Double {
        let identity = RecordingsStudyState.identity(recording)
        return max(entries[identity]?.furthest ?? 0, live[identity] ?? 0)
    }

    func isCompleted(_ recording: RecmanRecording) -> Bool { entry(for: recording).isCompleted }

    func isPending(_ recording: RecmanRecording) -> Bool { pending.contains(RecordingsStudyState.identity(recording)) }

    // MARK: Written by RecordingsController only

    /// Publishes the committed entry (nil: no row) of one identity and marks it known. Returns
    /// whether anything visible changed.
    @discardableResult
    func setEntry(_ entry: RecordingWatchEntry?, for identity: String) -> Bool {
        var changed = false
        if entries[identity] != entry { entries[identity] = entry; changed = true }
        if !known.contains(identity) { known.insert(identity); changed = true }
        return changed
    }

    /// Publishes a listing's entries at once: every identity in `identities` gets its value from
    /// `entries`, absent ones become untouched, and all become known. Published only if changed.
    func setEntries(_ new: [String: RecordingWatchEntry], for identities: [String]) {
        var updated = entries
        for identity in identities { updated[identity] = new[identity] }
        if updated != entries { entries = updated }
        if !known.isSuperset(of: identities) { known.formUnion(identities) }
    }

    func setLive(_ fraction: Double?, for identity: String) {
        if live[identity] != fraction { live[identity] = fraction }
    }

    func setPending(_ isPending: Bool, for identity: String) {
        if isPending { if !pending.contains(identity) { pending.insert(identity) } }
        else if pending.contains(identity) { pending.remove(identity) }
    }

    func setPending(_ isPending: Bool, for identities: Set<String>, course: RecmanCourseKey) {
        if isPending { pending.formUnion(identities); pendingCourses.insert(course) }
        else { pending.subtract(identities); pendingCourses.remove(course) }
    }

    func setSummary(_ summary: CourseWatchSummary?, for key: RecmanCourseKey) {
        if summaries[key] != summary { summaries[key] = summary }
    }

    /// Forgets everything: the account it belonged to is gone.
    func reset() {
        if !entries.isEmpty { entries = [:] }
        if !live.isEmpty { live = [:] }
        if !pending.isEmpty { pending = [] }
        if !pendingCourses.isEmpty { pendingCourses = [] }
        if !summaries.isEmpty { summaries = [:] }
        if !known.isEmpty { known = [] }
    }
}
