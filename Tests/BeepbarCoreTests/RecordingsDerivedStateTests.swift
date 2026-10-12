import Foundation
import Testing
@testable import BeepbarCore

/// The Recordings page derives its lists once per change of their inputs, not once per `body`
/// (#100). Each test here proves one half of that promise: equal inputs cost nothing, and every
/// input that can change what is shown invalidates the derivation. Each would pass with the
/// cache removed only if it recomputed on equal inputs, which the counters refuse.
struct RecordingsDerivedStateTests {
    private let rome = TimeZone(identifier: "Europe/Rome")!
    /// Same offset as Rome all year: only the identifier differs.
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func recording(_ id: String, _ date: String, title: String = "Lesson", kind: String = "Laboratorio", duration: String = "97 min") -> RecmanRecording {
        RecmanRecording(id: id, courseCode: "058167", academicYear: 2026, title: title,
                        recordedAt: ISO8601DateFormatter().date(from: date)!, kind: kind,
                        duration: duration, size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/")!)
    }

    private func inputs(_ recordings: [RecmanRecording], query: String = "", language: AppLanguage = .italian, timeZone: TimeZone? = nil, now: String = "2026-10-06T10:00:00Z") -> RecmanCourseListDerivation.Inputs {
        .init(recordings: recordings, query: query, language: language, timeZone: timeZone ?? rome, now: ISO8601DateFormatter().date(from: now)!)
    }

    // MARK: DerivedValueCache

    /// Guards against a cache that recomputes anyway: the counter must not move on equal inputs.
    @Test func equalInputsDoNotRecompute() {
        let cache = DerivedValueCache<[Int], Int>()
        #expect(cache.value(for: [1, 2], compute: { $0.reduce(0, +) }) == 3)
        #expect(cache.value(for: [1, 2], compute: { _ in Issue.record("recomputed for equal inputs"); return -1 }) == 3)
        #expect(cache.computations == 1)
    }

    /// Guards against a cache that compares identity or never invalidates: a changed input, and a
    /// return to an earlier one, both recompute, and `invalidate` forces the next one.
    @Test func changedInputsRecompute() {
        let cache = DerivedValueCache<[Int], Int>()
        _ = cache.value(for: [1], compute: { $0.count })
        #expect(cache.value(for: [1, 2], compute: { $0.count }) == 2)
        #expect(cache.computations == 2)
        #expect(cache.value(for: [1], compute: { $0.count }) == 1)
        #expect(cache.computations == 3)
        cache.invalidate()
        #expect(cache.value(for: [1], compute: { $0.count }) == 1)
        #expect(cache.computations == 4)
    }

    /// A hit adopts the caller's input (#100): a listing refetched with the same content is a new
    /// array, and the page compares against what it stored on every later `body`. Keeping the
    /// first input would compare element by element each time; adopting the new one lets the
    /// next comparison take the shared-storage fast path. `Shared` models that: equal storage is
    /// free, anything else is a counted deep comparison. Fails if a hit keeps the old input.
    @Test func aHitAdoptsTheNewInputSoLaterComparisonsAreCheap() {
        final class Storage {}
        struct Shared: Equatable {
            let storage: Storage
            let value: Int
            nonisolated(unsafe) static var deepComparisons = 0
            static func == (a: Shared, b: Shared) -> Bool {
                if a.storage === b.storage { return true }
                deepComparisons += 1
                return a.value == b.value
            }
        }
        let cache = DerivedValueCache<Shared, Int>()
        _ = cache.value(for: Shared(storage: Storage(), value: 1), compute: { $0.value })
        let refetched = Shared(storage: Storage(), value: 1)
        _ = cache.value(for: refetched, compute: { $0.value })
        #expect(Shared.deepComparisons == 1, "equal content in new storage is compared once")
        for _ in 0..<3 { _ = cache.value(for: refetched, compute: { $0.value }) }
        #expect(Shared.deepComparisons == 1, "later bodies compared against the stale input")
        #expect(cache.computations == 1)
    }

    // MARK: Course list inputs

    /// A controller publication for an unrelated reason republishes the same listing: the inputs
    /// compare equal and nothing is derived again, even later in the same day.
    @Test func sameListingLaterTheSameDayIsTheSameInput() {
        let list = [recording("a", "2026-10-05T10:00:00Z")]
        let cache = DerivedValueCache<RecmanCourseListDerivation.Inputs, RecmanCourseListDerivation>()
        _ = cache.value(for: inputs(list), compute: RecmanCourseListDerivation.init)
        _ = cache.value(for: inputs(list, now: "2026-10-06T21:59:00Z"), compute: RecmanCourseListDerivation.init)
        // A copy with the same content, in different storage, is still the same input.
        _ = cache.value(for: inputs(Array(list.map { $0 })), compute: RecmanCourseListDerivation.init)
        #expect(cache.computations == 1)
    }

    /// Each presentation input is part of the key: a list change, a search, a language switch, a
    /// time zone change (even to one with the same offset and day) and a new day each derive
    /// again. Every change is measured against the same base input, so an input left out of the
    /// key fails here on its own rather than being hidden by another field that also changed.
    @Test(arguments: ["list", "query", "language", "timeZone", "day"])
    func eachInputChangeRecomputes(_ input: String) {
        let list = [recording("a", "2026-10-05T10:00:00Z")]
        let base = inputs(list)
        let changed: RecmanCourseListDerivation.Inputs = switch input {
        case "list": inputs(list + [recording("b", "2026-10-06T10:00:00Z")])
        case "query": inputs(list, query: "les")
        case "language": inputs(list, language: .english)
        case "timeZone": inputs(list, timeZone: berlin)
        default: inputs(list, now: "2026-10-07T10:00:00Z")
        }
        if input == "timeZone" { #expect(changed.day == base.day, "the time zone must be keyed on its own, not only through the day") }
        let cache = DerivedValueCache<RecmanCourseListDerivation.Inputs, RecmanCourseListDerivation>()
        _ = cache.value(for: base, compute: RecmanCourseListDerivation.init)
        _ = cache.value(for: changed, compute: RecmanCourseListDerivation.init)
        #expect(cache.computations == 2, "a change of \(input) reused the stale derivation")
    }

    /// The day boundary belongs to the list's time zone, not UTC: 23:30 and 00:30 Rome time are
    /// different days there, and the same day in a zone where both are the same date.
    @Test func dayIsQuantizedInTheListsTimeZone() {
        let list = [recording("a", "2026-10-05T10:00:00Z")]
        let before = inputs(list, now: "2026-10-05T21:30:00Z")  // 23:30 Rome, 06:30 Tokyo next day
        let after = inputs(list, now: "2026-10-05T22:30:00Z")   // 00:30 Rome, 07:30 Tokyo
        #expect(before != after)
        #expect(inputs(list, timeZone: tokyo, now: "2026-10-05T21:30:00Z") == inputs(list, timeZone: tokyo, now: "2026-10-05T22:30:00Z"))
    }

    // MARK: Course list derivation

    /// What the pane shows comes from the derivation: search filters the rows, sections follow
    /// Rome weeks; the summary (lesson numbers, the header's minutes) covers the whole list.
    @Test func derivationMatchesThePresentationFunctions() {
        let mon = recording("mon", "2026-10-05T10:00:00Z", title: "Krylov methods")
        let sun = recording("sun", "2026-10-04T10:00:00Z", title: "Sparse matrices", duration: "30 min")
        let old = recording("old", "2026-09-21T10:00:00Z", title: "Intro", duration: "x")
        let summary = RecmanCourseListSummary([mon, sun, old])
        #expect(summary.totalMinutes == 127)
        #expect(summary.numbers == ["old": 1, "sun": 2, "mon": 3])
        let derived = RecmanCourseListDerivation(inputs([mon, sun, old]))
        #expect(derived.shown.map(\.id) == ["mon", "sun", "old"])
        #expect(derived.sections.map { $0.recordings.map(\.id) } == [["mon"], ["sun"], ["old"]])
        #expect(derived.sections[0].title == RecmanPresentation.weekSections([mon], now: mon.recordedAt, calendar: RecmanPresentation.calendar(timeZone: rome), locale: AppLanguage.italian.locale)[0].title)
        #expect(derived.byID["sun"] == sun)
        let searched = RecmanCourseListDerivation(inputs([mon, sun, old], query: "sparse"))
        #expect(searched.shown.map(\.id) == ["sun"])
        #expect(searched.sections.count == 1)
        #expect(searched.byID.keys.sorted() == ["sun"])
        #expect(RecmanCourseListDerivation(inputs([])).sections.isEmpty)
    }

    /// The header's total reads lengths through the bounded Core parser
    /// (`RecmanRecording.minutes(inDuration:)`), like the rows and the hours-left estimate: a
    /// damaged length longer than a day counts as unknown. Guards against summing the raw digits,
    /// which reported a nonsense total and trapped on `Int` overflow with two huge lengths.
    @Test func theHeaderTotalIgnoresImplausibleLengths() {
        let real = recording("real", "2026-10-05T10:00:00Z", duration: "90 min")
        let huge = recording("huge", "2026-10-04T10:00:00Z", duration: "\(Int.max / 2 + 1) min")
        let alsoHuge = recording("alsoHuge", "2026-10-03T10:00:00Z", duration: "\(Int.max / 2 + 1) min")
        let dayPlusOne = recording("day", "2026-10-02T10:00:00Z", duration: "1441 min")
        #expect(RecmanCourseListSummary([real, huge, alsoHuge, dayPlusOne]).totalMinutes == 90)
        #expect(RecmanPresentation.minutes("1440 min") == 1_440)
        #expect(RecmanPresentation.minutes("1441 min") == nil)
    }

    /// The derivation uses the time zone it is given, not the Mac's: 20:00 UTC on Sunday 4 October
    /// is still Sunday in Rome (last week) but already Monday in Tokyo (this week). Fails if the
    /// calendar falls back to `TimeZone.current`, whatever zone the test machine runs in.
    @Test func weeksFollowTheGivenTimeZone() {
        let late = recording("late", "2026-10-04T20:00:00Z")
        let monday = recording("mon", "2026-10-05T10:00:00Z")
        let inRome = RecmanCourseListDerivation(inputs([late, monday], timeZone: rome))
        let inTokyo = RecmanCourseListDerivation(inputs([late, monday], timeZone: tokyo))
        #expect(inRome.sections.map { $0.recordings.map(\.id) } == [["mon"], ["late"]])
        #expect(inTokyo.sections.map { $0.recordings.map(\.id) } == [["mon", "late"]])
    }

    /// Older weeks are dated in the language given, not the Mac's: "set" in Italian, "Sep" in
    /// English. ("Questa settimana" comes from `tr` and the global language, see `Inputs`.)
    @Test func olderWeeksAreDatedInTheGivenLanguage() {
        let old = [recording("old", "2026-09-21T10:00:00Z")]
        let italian = RecmanCourseListDerivation(inputs(old, language: .italian))
        let english = RecmanCourseListDerivation(inputs(old, language: .english))
        #expect(italian.sections.first?.title.contains("set") == true)
        #expect(english.sections.first?.title.contains("Sep") == true)
    }

    /// The summary depends on the listing only: a search re-derives the rows but not the numbers
    /// and minutes, which the view keys on the listing alone.
    @Test func theSummaryIgnoresTheSearch() {
        let list = [recording("a", "2026-10-05T10:00:00Z"), recording("b", "2026-10-06T10:00:00Z", duration: "30 min")]
        let cache = DerivedValueCache<[RecmanRecording], RecmanCourseListSummary>()
        _ = cache.value(for: list, compute: RecmanCourseListSummary.init)
        _ = cache.value(for: list, compute: RecmanCourseListSummary.init)
        #expect(cache.computations == 1)
        #expect(cache.value(for: list, compute: RecmanCourseListSummary.init) == RecmanCourseListSummary(list))
        _ = cache.value(for: Array(list.prefix(1)), compute: RecmanCourseListSummary.init)
        #expect(cache.computations == 2)
    }

    // MARK: Sidebar

    /// Disabled courses are left out, and the searchable ones keep their order and lose only the
    /// archive identifiers from their names.
    @Test func sidebarSplitsSearchableCoursesAndNamesThem() {
        func course(_ id: Int64, _ name: String) -> RemoteCourseSummary {
            RemoteCourseSummary(id: id, shortName: name, displayName: name, isVisible: true, startDate: nil, endDate: nil)
        }
        let courses = [course(1, "058167 - NUMERICAL LINEAR ALGEBRA [2026-27]"), course(2, "No code"), course(3, "052499 - HPC (2026-2027)"), course(4, "Off")]
        let sidebar = RecmanCourseSidebar(.init(courses: courses, enabledIDs: [1, 2, 3]))
        #expect(sidebar.courses.map(\.id) == [1, 2, 3])
        #expect(sidebar.searchable.map(\.name) == ["NUMERICAL LINEAR ALGEBRA", "HPC"])
        #expect(sidebar.keys == [RecmanCourseKey(courseCode: "058167", academicYear: 2026)!, RecmanCourseKey(courseCode: "052499", academicYear: 2026)!])
        #expect(sidebar.unsearchable.map(\.name) == ["No code"])
        #expect(sidebar.selectedCourse(id: 2)?.id == 2)
        #expect(sidebar.selectedCourse(id: nil)?.id == 1)
        #expect(sidebar.selectedCourse(id: 99)?.id == 1)
        #expect(RecmanCourseSidebar(.init(courses: [courses[1]], enabledIDs: [2])).selectedCourse(id: nil)?.id == 2)
        #expect(RecmanCourseSidebar(.init(courses: courses, enabledIDs: [])).selectedCourse(id: nil) == nil)
        // The same courses published again derive nothing.
        let cache = DerivedValueCache<RecmanCourseSidebar.Inputs, RecmanCourseSidebar>()
        _ = cache.value(for: .init(courses: courses, enabledIDs: [1, 2, 3]), compute: RecmanCourseSidebar.init)
        _ = cache.value(for: .init(courses: courses, enabledIDs: [1, 2, 3]), compute: RecmanCourseSidebar.init)
        #expect(cache.computations == 1)
        _ = cache.value(for: .init(courses: courses, enabledIDs: [1, 2]), compute: RecmanCourseSidebar.init)
        #expect(cache.computations == 2)
    }

    // MARK: BoundedCache

    /// Guards against unbounded growth: past the capacity the least recently written entry goes,
    /// and against evicting what is on screen: pinned keys and the newest entry stay.
    @Test func boundedCacheEvictsTheOldestUnpinnedEntry() {
        var cache = BoundedCache<String, Int>(capacity: 3)
        cache["a"] = 1
        cache["b"] = 2
        cache["c"] = 3
        cache.pin(["a"])
        cache["d"] = 4
        #expect(cache.count == 3)
        #expect(cache["a"] == 1, "pinned entries are never evicted")
        #expect(cache["b"] == nil, "the oldest unpinned entry is forgotten")
        #expect(cache["c"] == 3)
        #expect(cache["d"] == 4, "the entry just written is kept")
        // Writing an existing key makes it recent again.
        cache["c"] = 30
        cache["e"] = 5
        #expect(cache["c"] == 30)
        #expect(cache["d"] == nil)
        #expect(Set(cache.keys) == ["a", "c", "e"])
    }

    /// Pins describe the page: when every entry is pinned nothing is evicted, replacing the pins
    /// frees the old ones, and `removeAll` empties the data but keeps the pins.
    @Test func boundedCachePinsOutliveCapacityAndClearing() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.pin(["a", "b", "c"])
        cache["a"] = 1
        cache["b"] = 2
        cache["c"] = 3
        #expect(cache.count == 3, "pinned entries exceed the capacity rather than vanish")
        cache.pin(["c"])
        cache["d"] = 4
        // Releasing two pins left the cache two over: one insertion brings it back within bounds.
        #expect(cache["a"] == nil)
        #expect(cache["b"] == nil)
        #expect(cache["c"] == 3)
        #expect(cache["d"] == 4)
        #expect(cache.count == 2)
        cache.removeAll()
        #expect(cache.isEmpty)
        #expect(cache.pinnedKeys == ["c"])
        cache["x"] = 1
        cache["c"] = 3
        cache["y"] = 2
        #expect(cache["x"] == nil)
        #expect(cache["c"] == 3)
        #expect(cache["y"] == 2)
        // Dictionary-style default subscript writes through, and nil removes.
        cache["c", default: 0] += 1
        #expect(cache["c"] == 4)
        cache["c"] = nil
        #expect(cache["c"] == nil)
        #expect(cache.count == 1)
    }
}
