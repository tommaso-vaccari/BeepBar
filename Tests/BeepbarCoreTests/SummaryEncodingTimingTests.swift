import Foundation
import Testing
@testable import BeepbarCore

/// Indicative timing of the Core part of a new sync summary (R01, #109): JSON encoding of 15,000
/// `CourseSyncCount` details, the payload `SyncCompletionSummary` in the app wraps with seven
/// scalars, and an atomic write of those bytes. Opt-in with `BEEPBAR_SUMMARY_ENCODE_REPORT=1`,
/// so the regular suite stays fast. Runs wherever Core builds, including Linux, which is not
/// the Release arm64 baseline: its numbers only show the order of magnitude and the trend.
struct SummaryEncodingTimingTests {
    @Test func reportsEncodeAndAtomicWriteTiming() throws {
        guard ProcessInfo.processInfo.environment["BEEPBAR_SUMMARY_ENCODE_REPORT"] != nil else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "beepbar-summary-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "summary.json")
        for details in [1000, 15000] {
            // Same shape as the harness probe: ids of the coordinator's `course:module:/folder:name`
            // form, one item per detail, spread over ten courses.
            let perCourse = (1...Int64(10)).map { course -> CourseSyncCount in
                let items = stride(from: Int(course) - 1, to: details, by: 10).map { SyncedItem(id: "\(course):100:/:file-\($0).pdf", name: "file-\($0).pdf", kind: .added) }
                return CourseSyncCount(courseID: course, courseFolder: "Corso \(course)", added: items.count, updated: 0, items: items)
            }
            for run in 0..<8 {
                let start = ContinuousClock.now
                let data = try JSONEncoder().encode(perCourse)
                let encoded = ContinuousClock.now
                try data.write(to: destination, options: .atomic)
                let written = ContinuousClock.now
                #expect(try JSONDecoder().decode([CourseSyncCount].self, from: data) == perCourse)
                if run > 0 { print("SUMMARY_ENCODE details=\(details) bytes=\(data.count) encode_ms=\(milliseconds(encoded - start)) write_ms=\(milliseconds(written - encoded))") }
            }
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
