import BeepbarCore
import Foundation

/// The bytes the app persists at the end of a successful sync, rebuilt here so the harness can
/// measure their cost without the app target (R01, issue #109).
///
/// Mirror of `SyncCompletionSummary` in `Sources/BeepbarApp/WeBeepAuthenticationController.swift`:
/// the same stored properties in the same order, so `JSONEncoder` produces byte-identical output
/// and `summary.bytes` below is the app's real payload size (the D05 calibration measured
/// 1,133,014 bytes for 15,000 details). `SyncFinalizationTests.harnessSummaryProbeMatchesTheAppType`
/// fails when the two drift apart: when adding a field to `SyncCompletionSummary`, add it here too,
/// in the same position.
package struct SyncSummaryProbe: Codable, Equatable, Sendable {
    package let completedAt: Date
    package let added: Int
    package let updated: Int
    package let unchanged: Int
    package let preservedLocal: Int
    package let conflicts: Int
    package let failures: Int
    package let perCourse: [CourseSyncCount]

    package init(completedAt: Date, added: Int, updated: Int, unchanged: Int, preservedLocal: Int, conflicts: Int, failures: Int, perCourse: [CourseSyncCount]) {
        self.completedAt = completedAt
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
        self.preservedLocal = preservedLocal
        self.conflicts = conflicts
        self.failures = failures
        self.perCourse = perCourse
    }

    /// A first sync that added `details` files spread over `courses` courses, the largest summary
    /// the app writes: every detail is a new `SyncedItem`. The ids follow the coordinator's
    /// `course:module:/folder:name` form, with the same lengths as the D05 calibration, so the
    /// payload size is comparable with it. Deterministic, so every run encodes the same bytes.
    package static func synthetic(details: Int, courses: Int, completedAt: Date = Date(timeIntervalSince1970: 123)) -> SyncSummaryProbe {
        precondition(details >= 0 && courses >= 1)
        let perCourse = (1...Int64(courses)).map { course -> CourseSyncCount in
            // Course `c` gets the details whose index is ≡ c-1 (mod courses): the sizes differ by
            // at most one and every detail lands in exactly one course.
            let indices = stride(from: Int(course) - 1, to: details, by: courses)
            let items = indices.map { SyncedItem(id: "\(course):100:/:file-\($0).pdf", name: "file-\($0).pdf", kind: .added) }
            return CourseSyncCount(courseID: course, courseFolder: "Corso \(course)", added: items.count, updated: 0, items: items)
        }
        return SyncSummaryProbe(completedAt: completedAt, added: details, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0, perCourse: perCourse)
    }

    package var detailCount: Int { perCourse.reduce(0) { $0 + $1.items.count } }
}

extension Scenarios {
    /// The cost of persisting a new sync result with many per-course details (R01, #109). The app
    /// does this on the main actor at the end of every sync (`setSyncState(.synced)`): encode the
    /// summary as JSON, then write it. Budget: the main thread is never blocked longer than 16 ms.
    ///
    /// `summary.encode` is the shared cost whatever the storage. `summary.write` is an atomic
    /// write of the bytes into the scenario's temporary folder: the storage the R01 design
    /// proposes as a later option, and a lower bound for today's `UserDefaults` write, which the
    /// harness never performs because a defaults suite lives in `~/Library/Preferences`, outside
    /// the synthetic fixture (docs/benchmarks.md, "Safety"). The exact `UserDefaults` path is the
    /// opt-in `SyncFinalizationTests/benchmarkSummaryPersist`.
    ///
    /// The measurement runs on a cooperative-pool thread, not the main thread; the numbers are the
    /// CPU work the main actor would do, not a main-thread trace (that remains D07).
    package static func summaryPersist(details: Int, courses: Int, runs: Int, warmup: Int) async throws -> ScenarioResult {
        let directory = FileManager.default.temporaryDirectory.appending(path: "beepbar-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "summary.json")
        let probe = SyncSummaryProbe.synthetic(details: details, courses: courses)
        var samples: [RunSample] = []
        var sizes: Set<Int> = []
        var roundTrips = true
        for index in 0..<(warmup + runs) {
            let footprint = PeakFootprintSampler.footprint()
            guard let resources = ResourceUsage.current() else { throw BenchmarkError.setup("proc_pid_rusage failed") }
            let sampler = PeakFootprintSampler()
            let clock = ContinuousClock()
            let start = clock.now
            let data = try JSONEncoder().encode(probe)
            let encoded = clock.now
            try data.write(to: destination, options: .atomic)
            let written = clock.now
            let peak = sampler.stop()
            let resourcesAfter = ResourceUsage.current() ?? resources
            // Validity, outside the measured window: the file holds the whole summary, so a
            // faster write that lost detail could not pass as an improvement.
            let decoded = try JSONDecoder().decode(SyncSummaryProbe.self, from: Data(contentsOf: destination))
            roundTrips = roundTrips && decoded == probe
            sizes.insert(data.count)
            var sample = RunSample(
                wallMilliseconds: milliseconds(written - start),
                resources: resourcesAfter.since(resources),
                peakFootprintGrowth: Int64(peak) - Int64(footprint),
                peakFootprint: peak,
                database: SyncDatabaseWriteCounters(), fileStore: FileStoreCounters(), upstream: UpstreamCounters(),
                installed: 0, conflicts: 0, failures: 0
            )
            sample.summaryEncodeMilliseconds = milliseconds(encoded - start)
            sample.summaryWriteMilliseconds = milliseconds(written - encoded)
            sample.summaryBytes = data.count
            if index >= warmup { samples.append(sample) }
        }
        let checks = [
            "every detail encoded": probe.detailCount == details,
            "same bytes every run": sizes.count == 1,
            "written summary decodes back equal": roundTrips,
        ]
        let encode = Distribution(samples.compactMap(\.summaryEncodeMilliseconds))?.median ?? 0
        let write = Distribution(samples.compactMap(\.summaryWriteMilliseconds))?.median ?? 0
        return ScenarioResult(
            name: "summary-persist", parameters: ["details": "\(details)", "courses": "\(courses)"],
            warmupRuns: warmup, samples: samples, checks: checks,
            notes: [
                "encode per 1000 details (median): \(String(format: "%.2f", details > 0 ? encode / Double(details) * 1000 : 0)) ms",
                "budget, encode + write on the main actor ≤ 16 ms: \(encode + write <= 16 ? "met" : "NOT MET") (median \(String(format: "%.1f", encode + write)) ms)",
                "summary.write is an atomic file write in the temporary folder, not today's UserDefaults write (see docs/benchmarks.md)",
            ]
        )
    }
}
