import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import BeepbarCore
@testable import BeepbarApp

/// What a controller publication costs the pages that observe it (#280, principles 6 and 9).
/// `WeBeepAuthenticationController` has ~40 `@Published` properties and every page observes it, so
/// any one change may re-evaluate a page body. The pages are hosted for real (the Courses page and
/// the Recordings page, on the isolated fixture: synthetic account, mocked network, owned folder)
/// in an invisible window, like `RecordingRowProgressTests`. Body evaluations are counted through
/// the DEBUG probes (`UIBodyProbe`, `RecordingsPageProbes`); main-thread stalls through a 1 ms
/// main-actor heartbeat whose lateness is the time something else held the main thread.
/// Serialized: the probes are process-global.
///
/// Limits, repeated in `docs/performance-plan.md`: this proves body evaluations and main-thread
/// occupancy of the hosted views on the fixture, not compositor frames, scrolling or Instruments
/// hitches (`docs/ui-benchmarks.md`).
@Suite(.serialized) @MainActor struct UIPublicationTests {
    enum PageKind: Sendable { case courses, recordings }

    /// A hosted page on the fixture, with every probe counting into `counts`.
    @MainActor final class Hosted {
        let kind: PageKind
        let fixture: UIFixture
        let host: NSHostingView<AnyView>
        let window: NSWindow
        /// Held apart from `Hosted` because `NSHostingView` runs the root body once while it is
        /// being created, before `self` is complete: the probes must already be counting then.
        private final class Counter { var values: [String: Int] = [:] }
        private let counter = Counter()
        var counts: [String: Int] {
            get { counter.values }
            set { counter.values = newValue }
        }
        var controller: WeBeepAuthenticationController { fixture.controller }

        init(_ kind: PageKind, scenario name: String) async throws {
            self.kind = kind
            let scenario = try UIFixtureScenario(arguments: ["--scenario", name, "--report", "/tmp/ui-fixture-unused-\(UUID().uuidString).json"])
            fixture = try await UIFixture.make(scenario)
            let counter = counter
            UIBodyProbe.hit = { counter.values[$0, default: 0] += 1 }
            RecordingsPageProbes.row = { _ in counter.values["RecordingRow", default: 0] += 1 }
            RecordingsPageProbes.sidebarRow = { _, _ in counter.values["SidebarCourseRow", default: 0] += 1 }
            let root: AnyView = switch kind {
            case .courses: AnyView(HomePage(authentication: fixture.controller, open: { _ in }))
            case .recordings: AnyView(RecordingsPage(authentication: fixture.controller, recordings: fixture.controller.recordings))
            }
            host = NSHostingView(rootView: root)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.alphaValue = 0
            _ = NSApplication.shared
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
        }

        func close() {
            UIBodyProbe.hit = nil
            RecordingsPageProbes.row = nil
            RecordingsPageProbes.sidebarRow = nil
            window.close()
            fixture.dispose()
        }

        /// Lays out until `condition` holds (10 s at most), then a little more so late body
        /// evaluations land in the counters.
        func settle(until condition: () -> Bool = { true }) async throws {
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

        /// The page on screen with its content: course rows, or the fixture course's recordings.
        func loaded() async throws {
            switch kind {
            case .recordings:
                let key = try #require(RecmanCourseKey(course: controller.courses[0]))
                let recordings = controller.recordings
                try await settle { recordings.listings[key]?.recordings?.isEmpty == false && !recordings.watchProgress.known.isEmpty && (self.counts["RecordingRow"] ?? 0) > 0 }
            case .courses:
                try await settle { (self.counts["HomeCourseRow"] ?? 0) > 0 }
            }
            #expect(counts[kind == .courses ? "HomeCourseRow" : "RecordingRow", default: 0] > 0, "the page shows no rows")
        }
    }

    /// Main-actor lateness of a 1 ms sleep: how long something else kept the main thread.
    @MainActor final class Heartbeat {
        private(set) var latenessMilliseconds: [Double] = []
        private var task: Task<Void, Never>?

        func start() {
            latenessMilliseconds = []
            windowStart = 0
            windowMaxima = []
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let start = DispatchTime.now().uptimeNanoseconds
                    try? await Task.sleep(for: .milliseconds(1))
                    let late = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 - 1
                    self?.latenessMilliseconds.append(max(0, late))
                }
            }
        }

        func stop() async {
            task?.cancel()
            await task?.value
            task = nil
        }

        /// The longest lateness since the last call: the worst main-thread stall of one event's window.
        func closeWindow() {
            windowMaxima.append(latenessMilliseconds[windowStart...].max() ?? 0)
            windowStart = latenessMilliseconds.count
        }
        private(set) var windowMaxima: [Double] = []
        private var windowStart = 0

        var maxMilliseconds: Double { latenessMilliseconds.max() ?? 0 }
        var over16: Int { latenessMilliseconds.filter { $0 > 16 }.count }
    }

    struct Sample {
        var bodies: [String: Int]
        var controllerPublications: Int
        var progressPublications: Int
        var maxStallMilliseconds: Double
        var stallsOver16: Int
        var wallMilliseconds: Double
        /// For events made of several publications: the worst stall inside each one's window.
        var eventStalls: [Double] = []
    }

    /// Runs `event` on a settled page and reports what it cost: body evaluations by view, the
    /// controller's and the progress store's publications, and main-thread stalls.
    static func measure(_ page: Hosted, _ event: (Heartbeat) async throws -> Void) async throws -> Sample {
        try await page.settle()
        page.counts = [:]
        var controllerPublications = 0, progressPublications = 0
        let controllerSink = page.controller.objectWillChange.sink { controllerPublications += 1 }
        let progressSink = page.controller.progressStore.objectWillChange.sink { progressPublications += 1 }
        defer { controllerSink.cancel(); progressSink.cancel() }
        let beat = Heartbeat()
        beat.start()
        let start = DispatchTime.now().uptimeNanoseconds
        var stalls: [Double] = []
        try await event(beat)
        stalls = beat.windowMaxima
        try await page.settle()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        await beat.stop()
        return Sample(bodies: page.counts, controllerPublications: controllerPublications, progressPublications: progressPublications,
                      maxStallMilliseconds: beat.maxMilliseconds, stallsOver16: beat.over16, wallMilliseconds: wall, eventStalls: stalls)
    }

    // MARK: Regression

    /// Principle 6 on the real Courses page: ten thousand progress events of a sync reach the page
    /// through the progress store (D08), which only the progress line observes. The controller,
    /// and so the page body, the status card and every course row, is published exactly as often
    /// as by the same run with no event at all (its own begin and end), and the page body is not
    /// evaluated more. Mutation: publish a controller property from `progressAccepted` (as a
    /// progress counter would if it lived on the controller) and the burst publishes more than
    /// the empty run.
    @Test(.timeLimit(.minutes(2))) func progressEventsDoNotRerenderTheCourseList() async throws {
        let page = try await Hosted(.courses, scenario: "courses-100")
        defer { page.close() }
        try await page.loaded()
        let empty = try await Self.measure(page) { _ in await UIFixtureProgressBurst.run(page.controller, events: 0) }
        let burst = try await Self.measure(page) { _ in await UIFixtureProgressBurst.run(page.controller) }
        #expect(page.controller.progressStore.mainActorEntries >= 1, "the burst never reached the progress path")
        #expect(empty.controllerPublications > 0, "the empty run published nothing: the baseline would prove nothing")
        #expect(burst.controllerPublications == empty.controllerPublications, "\(burst.controllerPublications) controller publications for the burst against \(empty.controllerPublications) for the same run without events")
        #expect(burst.bodies["HomePage", default: 0] <= empty.bodies["HomePage", default: 0] + 1, "HomePage body ran \(burst.bodies["HomePage", default: 0]) times against \(empty.bodies["HomePage", default: 0])")
        // The progress line's own store is what the burst moves.
        #expect(burst.progressPublications > empty.progressPublications)
    }

    // MARK: Opt-in benchmark

    nonisolated static var benchmarkEnabled: Bool { ProcessInfo.processInfo.environment["BEEPBAR_UI_PUBLICATION_BENCHMARK"] == "1" }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }

    enum Event: String, CaseIterable {
        /// Controls first: what the harness itself costs with nothing published.
        case idle = "control-20-idle-windows", emptyRun = "control-run-without-events"
        case progressBurst = "progress-burst", sync = "mock-sync", bareControllerPublications = "20-controller-publications"
    }

    /// `BEEPBAR_UI_PUBLICATION_BENCHMARK=1 swift test -c release --arch arm64 -Xswiftc -DDEBUG --filter UIPublicationTests/benchmark`
    /// For the Courses page (100 and 500 courses) and the Recordings page (1,000 recordings), one
    /// warm-up and five measured runs of each event, the page staying hosted: the progress burst
    /// of a sync, a genuine mocked sync, and twenty bare controller publications (the worst case:
    /// any one of the ~40 properties changing). Prints one `PUBLICATION_BENCH` line per run and
    /// `PUBLICATION_SUMMARY` lines with the median and the nearest-rank p95 (five runs: the
    /// maximum). Disabled in the regular suite: it is a measurement, and its timings depend on the
    /// machine.
    @Test(.enabled(if: benchmarkEnabled), .timeLimit(.minutes(20)), arguments: [
        ("courses", PageKind.courses, "courses-100"),
        ("courses", PageKind.courses, "courses-500"),
        ("recordings", PageKind.recordings, "recordings-1000"),
    ])
    func benchmark(label: String, kind: PageKind, scenario: String) async throws {
        let page = try await Hosted(kind, scenario: scenario)
        defer { page.close() }
        try await page.loaded()

        for event in Event.allCases {
            var samples: [Sample] = []
            for run in 0..<6 {
                let sample = try await Self.measure(page) { beat in
                    switch event {
                    case .idle:
                        for _ in 0..<20 {
                            try await Task.sleep(for: .milliseconds(50))
                            beat.closeWindow()
                        }
                    case .emptyRun:
                        await UIFixtureProgressBurst.run(page.controller, events: 0)
                    case .progressBurst:
                        await UIFixtureProgressBurst.run(page.controller)
                    case .sync:
                        UIFixtureProtocol.releaseContents(token: page.fixture.token)
                        page.controller.synchronizeNow()
                        await page.controller.waitForSyncForTesting()
                    case .bareControllerPublications:
                        for _ in 0..<20 {
                            page.controller.objectWillChange.send()
                            try await Task.sleep(for: .milliseconds(50))
                            beat.closeWindow()
                        }
                    }
                }
                let bodies = sample.bodies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                print("PUBLICATION_BENCH scenario=\(scenario) event=\(event.rawValue) run=\(run == 0 ? "warmup" : String(run)) controller_pubs=\(sample.controllerPublications) progress_pubs=\(sample.progressPublications) max_stall_ms=\(String(format: "%.2f", sample.maxStallMilliseconds)) stalls_over_16ms=\(sample.stallsOver16) event_stalls_ms=[\(sample.eventStalls.map { String(format: "%.1f", $0) }.joined(separator: ","))] wall_ms=\(String(format: "%.0f", sample.wallMilliseconds)) bodies{\(bodies)}")
                if run > 0 { samples.append(sample) }
            }
            let stall = samples.map(\.maxStallMilliseconds)
            let perEvent = samples.flatMap(\.eventStalls)
            let eventStallSummary = perEvent.isEmpty ? "n/a" : "\(String(format: "%.2f", Self.percentile(perEvent, 0.5)))/\(String(format: "%.2f", Self.percentile(perEvent, 0.95)))/\(String(format: "%.2f", perEvent.max() ?? 0))(n=\(perEvent.count))"
            let names = Set(samples.flatMap { $0.bodies.keys }).sorted()
            let bodies = names.map { name in
                let counts = samples.map { Double($0.bodies[name, default: 0]) }
                return "\(name)=\(Self.percentile(counts, 0.5))/\(Self.percentile(counts, 0.95))"
            }.joined(separator: ",")
            print("PUBLICATION_SUMMARY scenario=\(scenario) event=\(event.rawValue) controller_pubs_median=\(Self.percentile(samples.map { Double($0.controllerPublications) }, 0.5)) progress_pubs_median=\(Self.percentile(samples.map { Double($0.progressPublications) }, 0.5)) max_stall_ms_median=\(String(format: "%.2f", Self.percentile(stall, 0.5))) max_stall_ms_p95=\(String(format: "%.2f", Self.percentile(stall, 0.95))) stalls_over_16ms_total=\(samples.map(\.stallsOver16).reduce(0, +)) per_event_stall_ms_median/p95/max=\(eventStallSummary) bodies_median/p95{\(bodies)}")
        }
    }
}
