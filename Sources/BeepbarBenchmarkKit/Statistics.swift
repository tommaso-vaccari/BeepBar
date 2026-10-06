import Foundation

/// The summary AGENTS.md asks for: median and p95 over the measured runs, plus the extremes so a
/// single outlier is visible.
package struct Distribution: Sendable, Codable, Equatable {
    package let count: Int
    package let median: Double
    /// Nearest-rank p95: the smallest sample with at least 95% of the samples at or below it. With
    /// five runs this is the maximum, which is the honest reading of five samples.
    package let p95: Double
    package let min: Double
    package let max: Double

    package init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        count = sorted.count
        let middle = sorted.count / 2
        median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        p95 = sorted[Int((0.95 * Double(sorted.count)).rounded(.up)) - 1]
        min = sorted[0]
        max = sorted[sorted.count - 1]
    }
}
