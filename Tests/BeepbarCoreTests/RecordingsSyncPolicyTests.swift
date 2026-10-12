import Foundation
import Testing
@testable import BeepbarCore

/// The decisions behind refreshing the Recordings listings at every sync (`RecordingsSyncPolicy`),
/// the count behind "N nuove registrazioni", and the summary's optional `newCount` with its
/// " · N nuove" menu suffix. What they guard: a follow-up that runs when it must not (no network,
/// cancelled, Data Saver on a hotspot, a dead Polimi session — each would cost network or open a
/// window unasked), one that doesn't run when it should (a WeBeep outage blocking another
/// service), a notification about a whole archive or about lectures already seen, and a summary
/// format that an older or newer build can no longer read (the app deletes unreadable saved data).
struct RecordingsSyncPolicyTests {
    typealias Policy = RecordingsSyncPolicy

    private static let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!

    /// One set of inputs to `decision`, starting from a combination that refreshes, so each row of
    /// the matrix changes exactly the input it is about.
    struct Inputs {
        var switchedOn = true
        var university: MoodleUniversity? = .polimi
        var ownerKnown = true
        var courseKeys: Set<RecmanCourseKey> = [RecordingsSyncPolicyTests.key]
        var outcome: RecordingsMaterialsOutcome = .synced
        var trigger: RecordingsSyncTrigger = .automatic
        var dataSaverEnabled = false
        var currentNetwork: NetworkPathConditions? = .unrestricted
        var access: RecordingsSyncAccess = .ready

        func decide() -> RecordingsSyncDecision {
            Policy.decision(switchedOn: switchedOn, university: university, ownerKnown: ownerKnown, courseKeys: courseKeys,
                            outcome: outcome, trigger: trigger, dataSaverEnabled: dataSaverEnabled,
                            currentNetwork: currentNetwork, access: access)
        }
    }

    private static func with(_ change: (inout Inputs) -> Void) -> Inputs {
        var inputs = Inputs()
        change(&inputs)
        return inputs
    }

    // MARK: Decision matrix

    /// Every standing reason not to touch Recman skips: switch off, another university, no known
    /// owner, no course to list, the controller reporting `.off`, a sign-in running, a dead
    /// session. Guards against the follow-up creating the controller or opening the browser (and
    /// for a dead session, the sign-in window) when nobody asked. Mutation: drop any one guard
    /// (e.g. the `ownerKnown` check, or the `.needsSignIn` case falling through to refresh) and its
    /// row reads `.refresh` instead of its skip.
    @Test(arguments: [
        ("switch off", with { $0.switchedOn = false }, RecordingsSyncSkipReason.switchedOff),
        ("unipd", with { $0.university = .unipd }, .notPolimi),
        ("no site", with { $0.university = nil }, .notPolimi),
        ("owner unknown", with { $0.ownerKnown = false }, .ownerUnknown),
        ("no keys", with { $0.courseKeys = [] }, .noCourses),
        ("access off", with { $0.access = .off }, .switchedOff),
        ("signing in", with { $0.access = .signingIn }, .signingIn),
        ("needs sign-in", with { $0.access = .needsSignIn }, .needsSignIn),
        ("needs sign-in, manual", with { $0.access = .needsSignIn; $0.trigger = .manual }, .needsSignIn),
    ])
    func standingReasonsSkip(_ name: String, _ inputs: Inputs, _ reason: RecordingsSyncSkipReason) {
        #expect(inputs.decide() == .skip(reason), "\(name)")
    }

    /// A materials run that couldn't reach the network, was cancelled, deferred, paused by Data
    /// Saver (at the start or midway), had nothing configured, or lost WeBeep's sign-in skips the
    /// follow-up, for both triggers. Guards against listing Recman after the student pressed
    /// "Annulla", on a network Data Saver protects, or with no connection (a pointless timeout per
    /// course). Mutation: make `.connectivity` return nil in `skipReason` and the "connectivity"
    /// rows refresh; same for any other case.
    @Test(arguments: [
        ("connectivity", RecordingsMaterialsOutcome.failed(.connectivity), RecordingsSyncSkipReason.connectivity),
        ("cancelled", .cancelled, .materialsCancelled),
        ("low power", .notRun(.deferForLowPowerMode), .materialsDeferred),
        ("busy", .notRun(.deferWhileBusy), .materialsDeferred),
        ("contradictory run", .notRun(.run), .materialsDeferred),
        ("unconfigured", .notRun(.skipUnconfigured), .unconfigured),
        ("paused at start", .notRun(.pause(.hotspot)), .materialsPaused(.hotspot)),
        ("paused midway", .pausedByDataSaver(.lowDataMode), .materialsPaused(.lowDataMode)),
        ("auth expired", .failed(.authenticationExpired), .authenticationExpired),
    ])
    func materialsOutcomesThatSkip(_ name: String, _ outcome: RecordingsMaterialsOutcome, _ reason: RecordingsSyncSkipReason) {
        for trigger in [RecordingsSyncTrigger.automatic, .manual] {
            let inputs = Self.with { $0.outcome = outcome; $0.trigger = trigger }
            #expect(inputs.decide() == .skip(reason), "\(name), \(trigger)")
        }
    }

    /// A materials run that completed in any way, or failed because of WeBeep's own service, still
    /// refreshes: Recman is a different service, so a WeBeep outage must not hide new lectures.
    /// Manual forces the freshness window, automatic respects it. Guards against coupling the two
    /// services and against an automatic run re-listing every course at every interval (or a
    /// manual one serving a 5-minute-old listing). Mutation: return `.serviceUnavailable` as a
    /// skip and its row fails; return `force: true` for automatic and every automatic row fails.
    @Test(arguments: [
        RecordingsMaterialsOutcome.synced, .conflicts, .partial, .failed(.serviceUnavailable), .failed(.incompatibleResponse),
    ], [RecordingsSyncTrigger.automatic, .manual])
    func completedOrServiceFailedRunsRefresh(_ outcome: RecordingsMaterialsOutcome, trigger: RecordingsSyncTrigger) {
        let inputs = Self.with { $0.outcome = outcome; $0.trigger = trigger }
        #expect(inputs.decide() == .refresh(force: trigger == .manual), "\(outcome), \(trigger)")
    }

    /// Data Saver on with a hotspot or Low Data Mode network NOW (re-read at follow-up time) skips
    /// an automatic follow-up silently, even when the run itself started on Wi-Fi; an unknown or
    /// offline network never pauses, as for materials; Data Saver off ignores the network; a
    /// manual sync ignores Data Saver ("Sincronizza ora" always downloads). Guards against spending
    /// a hotspot's data on the archive after the Mac moved to it during the materials run.
    /// Mutation: drop the Data Saver check in the `.automatic` branch and the first two rows
    /// refresh; apply it to manual too and the manual row skips.
    @Test func dataSaverIsReadOnTheCurrentNetworkForAutomaticRunsOnly() {
        func decide(_ dataSaver: Bool, _ network: NetworkPathConditions?, _ trigger: RecordingsSyncTrigger = .automatic) -> RecordingsSyncDecision {
            Self.with { $0.dataSaverEnabled = dataSaver; $0.currentNetwork = network; $0.trigger = trigger }.decide()
        }
        #expect(decide(true, .hotspot) == .skip(.dataSaver(.hotspot)))
        #expect(decide(true, .lowDataMode) == .skip(.dataSaver(.lowDataMode)))
        #expect(decide(true, .unrestricted) == .refresh(force: false))
        #expect(decide(true, nil) == .refresh(force: false), "an unknown network never pauses")
        #expect(decide(true, .offline) == .refresh(force: false), "an outage is not a Data Saver pause")
        #expect(decide(false, .hotspot) == .refresh(force: false), "Data Saver off")
        #expect(decide(true, .hotspot, .manual) == .refresh(force: true), "Sincronizza ora always downloads")
    }

    // MARK: Newly published count

    /// A baseline listing (the course's first complete one) is never news, however many lectures
    /// it has and whatever else is known. Guards against a "40 nuove registrazioni" notification
    /// the first time a course is listed. Mutation: drop the `isBaseline` early return and this
    /// reads the unseen count (2 or 3).
    @Test func baselineCountsNothing() {
        let current: Set<String> = ["a", "b", "c"]
        #expect(Policy.newlyPublishedCount(previousIDs: nil, currentIDs: current, seenIDs: ["a"], isBaseline: true, storedTotal: nil) == 0)
        #expect(Policy.newlyPublishedCount(previousIDs: ["a"], currentIDs: current, seenIDs: [], isBaseline: true, storedTotal: 1) == 0)
    }

    /// With the previous listing in memory, only lectures absent from it AND still unseen count: a
    /// lecture already in the list isn't new (it may just be unseen for weeks), and one the student
    /// already opened isn't news. Guards against re-notifying the same unseen lectures at every
    /// sync. Mutation: count `unseen` without subtracting `previousIDs` and the first case reads 3;
    /// count `currentIDs - previousIDs` without the unseen filter and the second reads 2.
    @Test func onlyUnseenLecturesAbsentBeforeCount() {
        #expect(Policy.newlyPublishedCount(previousIDs: ["a", "b"], currentIDs: ["a", "b", "c"], seenIDs: [], isBaseline: false, storedTotal: nil) == 1)
        #expect(Policy.newlyPublishedCount(previousIDs: ["a"], currentIDs: ["a", "b", "c"], seenIDs: ["a", "b"], isBaseline: false, storedTotal: nil) == 1)
        #expect(Policy.newlyPublishedCount(previousIDs: ["a", "b"], currentIDs: ["a", "b"], seenIDs: [], isBaseline: false, storedTotal: 5) == 0,
                "nothing added: the stored total is ignored when the listing is known")
        #expect(Policy.newlyPublishedCount(previousIDs: ["a", "b", "c"], currentIDs: ["a"], seenIDs: [], isBaseline: false, storedTotal: nil) == 0,
                "removals never count")
    }

    /// After a relaunch (no listing in memory) the growth in `total` against the stored summary
    /// counts, capped by the unseen lectures, never below zero; with no stored summary either,
    /// nothing is claimed. Guards against notifying a whole unseen backlog after every relaunch,
    /// and against a damaged stored total trapping or producing a negative count. Mutation: drop
    /// the `min(…, unseen.count)` cap and the capped case reads 3; drop the outer `max(0, …)` and
    /// the shrinking case reads -2; drop the `max(0, storedTotal)` clamp and `Int.min` traps.
    @Test func relaunchUsesTheStoredTotalCappedByUnseen() {
        let current: Set<String> = ["a", "b", "c", "d", "e"]
        #expect(Policy.newlyPublishedCount(previousIDs: nil, currentIDs: current, seenIDs: ["a", "b", "c"], isBaseline: false, storedTotal: 3) == 2)
        #expect(Policy.newlyPublishedCount(previousIDs: nil, currentIDs: current, seenIDs: ["a", "b", "c", "d"], isBaseline: false, storedTotal: 2) == 1,
                "growth 3, but only one lecture is unseen")
        #expect(Policy.newlyPublishedCount(previousIDs: nil, currentIDs: ["a", "b", "c"], seenIDs: [], isBaseline: false, storedTotal: 5) == 0,
                "a shrinking archive is never negative")
        #expect(Policy.newlyPublishedCount(previousIDs: nil, currentIDs: current, seenIDs: [], isBaseline: false, storedTotal: nil) == 0,
                "nothing to compare with: nothing is new")
        #expect(Policy.newlyPublishedCount(previousIDs: nil, currentIDs: current, seenIDs: ["a"], isBaseline: false, storedTotal: Int.min) == 4,
                "a damaged total is clamped, never traps, and is capped by the unseen count")
        #expect(Policy.newlyPublishedCount(previousIDs: nil, currentIDs: current, seenIDs: [], isBaseline: false, storedTotal: Int.max) == 0)
    }

    // MARK: Summary newCount: persistence

    /// The summary the previous build saved (with `next`, without `newCount`), as synthesized
    /// `Codable` reads and writes it: stands in for an older build.
    private struct PreviousSummary: Codable, Equatable {
        let done: Int
        let total: Int
        let remainingMinutes: Int
        let unknownDurationCount: Int
        let next: RecmanRecording?
    }

    private static let lecture = RecmanRecording(
        id: "t1", courseCode: "058167", academicYear: 2026, title: "Lecture",
        recordedAt: Date(timeIntervalSince1970: 1_790_000_000), kind: "Lezione", duration: "90 min", size: nil,
        previewURL: URL(string: "https://onlineservices.polimi.it/x?transfer_id=t1")!)

    /// Data written by the previous build decodes with `newCount` nil, in both encoders (the app
    /// stores a property list). Guards against a new build failing to read, and so deleting, every
    /// saved summary on its first launch after updating. Mutation: decode `newCount` with plain
    /// `decode` and these throw.
    @Test func previousDataDecodesWithoutNewCount() throws {
        let old = PreviousSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1, next: Self.lecture)
        let expected = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1, next: Self.lecture)
        #expect(try PropertyListDecoder().decode(CourseWatchSummary.self, from: PropertyListEncoder().encode(old)) == expected)
        #expect(try JSONDecoder().decode(CourseWatchSummary.self, from: JSONEncoder().encode(old)) == expected)
    }

    /// A build before `newCount` reads data written with it, keeping counts and `next`: a rollback
    /// only loses the " · N nuove" suffix. Guards against a format change that would make the old
    /// build delete the saved summaries.
    @Test func previousBuildReadsNewData() throws {
        let summary = CourseWatchSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1, next: Self.lecture, newCount: 2)
        let old = PreviousSummary(done: 3, total: 10, remainingMinutes: 120, unknownDurationCount: 1, next: Self.lecture)
        #expect(try PropertyListDecoder().decode(PreviousSummary.self, from: PropertyListEncoder().encode(summary)) == old)
        #expect(try JSONDecoder().decode(PreviousSummary.self, from: JSONEncoder().encode(summary)) == old)
    }

    /// `newCount` round-trips, and is written only when above zero, so a summary with nothing new
    /// is exactly what the previous build wrote (no extra rewrite, nothing new to read). Guards
    /// against the suffix vanishing after a relaunch and against the key being written always.
    /// Mutation: drop `newCount` from `encode` and the round trip fails; `encode` it always (not
    /// `encodeIfPresent`) and the key list gains "newCount".
    @Test func newCountRoundTripsAndIsWrittenOnlyWhenPresent() throws {
        let summary = CourseWatchSummary(done: 1, total: 4, remainingMinutes: 45, unknownDurationCount: 0, newCount: 2)
        #expect(try PropertyListDecoder().decode(CourseWatchSummary.self, from: PropertyListEncoder().encode(summary)) == summary)
        #expect(try JSONDecoder().decode(CourseWatchSummary.self, from: JSONEncoder().encode(summary)) == summary)
        #expect(summary.newCount == 2)
        for nothingNew in [CourseWatchSummary(done: 1, total: 4, remainingMinutes: 45, unknownDurationCount: 0),
                           CourseWatchSummary(done: 1, total: 4, remainingMinutes: 45, unknownDurationCount: 0, newCount: 0)] {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nothingNew)) as? [String: Any]
            #expect(object?.keys.sorted() == ["done", "remainingMinutes", "total", "unknownDurationCount"])
        }
    }

    /// Zero and negative counts mean "nothing new" and equal nil, so the app doesn't rewrite a
    /// saved summary over a 0 vs nil difference; a different positive count is a change (the menu
    /// must be rewritten). A malformed stored value costs only the suffix. Mutation: drop the
    /// normalisation in `init` and `newCount: 0` differs from nil; exclude `newCount` from `==` and
    /// the 2 vs 3 case is equal; remove the `try?` and the malformed rows throw.
    @Test func newCountIsNormalisedComparedAndLenient() throws {
        let plain = CourseWatchSummary(done: 1, total: 4, remainingMinutes: 45, unknownDurationCount: 0)
        #expect(plain.withNewCount(0) == plain)
        #expect(plain.withNewCount(-3) == plain)
        #expect(plain.withNewCount(-3).newCount == nil)
        #expect(plain.withNewCount(2) != plain)
        #expect(plain.withNewCount(2) != plain.withNewCount(3))
        #expect(plain.withNewCount(2).withNewCount(nil) == plain)
        for value in [#""two""#, "[1]", "2.5", "null", "0", "-1"] {
            let data = Data(#"{"done":1,"total":4,"remainingMinutes":45,"unknownDurationCount":0,"newCount":\#(value)}"#.utf8)
            #expect(try JSONDecoder().decode(CourseWatchSummary.self, from: data) == plain, "newCount = \(value)")
        }
    }

    // MARK: Summary newCount: menu line

    /// The menu line gains " · N nuove" / " · N new" after whatever it showed, " · 1 nuova" in the
    /// singular, through `BilingualText` (never switching `AppLanguage.current`). Guards against
    /// the suffix being lost or ungrammatical in either language. Mutation: drop the suffix and
    /// every line loses it; always use "nuove" and the singular reads "1 nuove".
    @Test func menuLineEndsWithTheNewCount() {
        func line(_ done: Int, _ total: Int, _ minutes: Int, new: Int?) -> BilingualText {
            RecordingWatchProgress.menuLine(courseName: "Analisi 2", CourseWatchSummary(done: done, total: total, remainingMinutes: minutes, unknownDurationCount: 0, newCount: new))
        }
        #expect(line(12, 30, 840, new: 2) == BilingualText("Analisi 2 — 12/30 · ~14 h · 2 nuove", "Analisi 2 — 12/30 · ~14 h · 2 new"))
        #expect(line(12, 30, 840, new: 1) == BilingualText("Analisi 2 — 12/30 · ~14 h · 1 nuova", "Analisi 2 — 12/30 · ~14 h · 1 new"))
        #expect(line(29, 30, 0, new: 1) == BilingualText("Analisi 2 — 29/30 · 1 nuova", "Analisi 2 — 29/30 · 1 new"))
        #expect(line(30, 30, 0, new: 3) == BilingualText("Analisi 2 — 30/30 · tutte fatte · 3 nuove", "Analisi 2 — 30/30 · all done · 3 new"))
    }

    /// With nothing new (nil, zero, negative) the line is exactly the line before `newCount`
    /// existed, and an empty course never gets a suffix. Guards against " · 0 nuove" in the menu
    /// and against changing every existing line. Mutation: drop the `newCount > 0` guard in
    /// `newSuffix` and the 0 row reads " · 0 nuove"; drop the empty-course early return and the
    /// last row gains a suffix.
    @Test func menuLineWithoutNewIsUnchanged() {
        let summary = CourseWatchSummary(done: 12, total: 30, remainingMinutes: 840, unknownDurationCount: 0)
        let expected = BilingualText("Analisi 2 — 12/30 · ~14 h", "Analisi 2 — 12/30 · ~14 h")
        #expect(RecordingWatchProgress.menuLine(courseName: "Analisi 2", summary) == expected)
        #expect(RecordingWatchProgress.newSuffix(0) == nil)
        #expect(RecordingWatchProgress.newSuffix(-1) == nil)
        #expect(RecordingWatchProgress.newSuffix(nil) == nil)
        #expect(RecordingWatchProgress.menuLine(courseName: "Analisi 2", summary.withNewCount(0)) == expected)
        let empty = CourseWatchSummary(done: 0, total: 0, remainingMinutes: 0, unknownDurationCount: 0, newCount: 2)
        #expect(RecordingWatchProgress.menuLine(courseName: "Analisi 2", empty) == BilingualText("Analisi 2 — nessuna registrazione", "Analisi 2 — no recordings"))
    }
}
