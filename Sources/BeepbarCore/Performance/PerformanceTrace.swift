import Foundation
#if canImport(os)
import os
#endif

public enum PerformanceCategory: String, Sendable {
    case bootstrap
    case ui
    case scheduler
    case sync
    case database
    case filesystem
}

#if canImport(os)
public final class PerformanceTrace: @unchecked Sendable {
    public static let shared = PerformanceTrace()

    private let signposters: [PerformanceCategory: OSSignposter]

    private init() {
        signposters = Dictionary(uniqueKeysWithValues: PerformanceCategory.allCases.map {
            ($0, OSSignposter(subsystem: "io.github.tvaccari.beepbar.performance", category: $0.rawValue))
        })
    }

    public func begin(_ name: StaticString, category: PerformanceCategory) -> OSSignpostIntervalState {
        signposters[category]!.beginInterval(name)
    }

    public func end(_ name: StaticString, category: PerformanceCategory, state: OSSignpostIntervalState) {
        signposters[category]!.endInterval(name, state)
    }

    public func event(_ name: StaticString, category: PerformanceCategory) {
        signposters[category]!.emitEvent(name)
    }

}
#else
/// Stand-in for the `os` interval state on Linux, where signposts do not exist (Core tests only).
public struct OSSignpostIntervalState: Sendable {}

/// Same interface as the macOS tracer above, emitting nothing: Linux runs only the Core tests
/// and has no Instruments to read signposts.
public final class PerformanceTrace: Sendable {
    public static let shared = PerformanceTrace()

    private init() {}

    public func begin(_ name: StaticString, category: PerformanceCategory) -> OSSignpostIntervalState { OSSignpostIntervalState() }

    public func end(_ name: StaticString, category: PerformanceCategory, state: OSSignpostIntervalState) {}

    public func event(_ name: StaticString, category: PerformanceCategory) {}
}
#endif

extension PerformanceCategory: CaseIterable {}
