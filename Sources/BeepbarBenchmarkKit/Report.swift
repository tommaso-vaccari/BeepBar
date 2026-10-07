import Foundation
import IOKit.ps

/// Runs a scenario without reusing a report from an earlier baseline in the same directory.
package enum BenchmarkSubprocess {
    package static func run(_ process: Process, output: URL) throws -> (report: BenchmarkReport?, completed: Bool) {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try process.run()
        process.waitUntilExit()
        let report = (try? Data(contentsOf: output)).flatMap { try? BenchmarkReport.decode($0) }
        return (report, process.terminationReason == .exit && process.terminationStatus == 0 && report != nil)
    }
}

/// Where and how a report was produced. AGENTS.md compares numbers only across the same machine,
/// power source and build, so every report carries them.
package struct BenchmarkEnvironment: Sendable, Codable, Equatable {
    package var commit: String
    /// Uncommitted changes were present: the numbers don't belong to `commit` alone.
    package var dirty: Bool
    package var model: String
    package var cpu: String
    package var memoryBytes: UInt64
    package var operatingSystem: String
    /// "AC Power", "Battery Power" or "unknown".
    package var powerSource: String
    package var lowPowerMode: Bool
    package var thermalState: String
    /// "release" or "debug". Budgets apply to release builds only.
    package var buildConfiguration: String
    package var architecture: String
    package var date: Date

    package init(commit: String, dirty: Bool, model: String, cpu: String, memoryBytes: UInt64, operatingSystem: String, powerSource: String, lowPowerMode: Bool, thermalState: String, buildConfiguration: String, architecture: String, date: Date) {
        self.commit = commit
        self.dirty = dirty
        self.model = model
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.operatingSystem = operatingSystem
        self.powerSource = powerSource
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.buildConfiguration = buildConfiguration
        self.architecture = architecture
        self.date = date
    }

    /// The current machine. `commit` and `dirty` come from the caller (`scripts/benchmark.sh`
    /// passes them), because the binary doesn't know which checkout built it.
    package static func current(commit: String, dirty: Bool) -> BenchmarkEnvironment {
        BenchmarkEnvironment(
            commit: commit,
            dirty: dirty,
            model: sysctlString("hw.model") ?? "unknown",
            cpu: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            powerSource: powerSourceName(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState),
            buildConfiguration: isDebugBuild ? "debug" : "release",
            architecture: architectureName,
            // Whole seconds: the JSON stores ISO 8601 without fractions, and a report must read
            // back equal to what was written.
            date: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
    }

    package static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    private static var architectureName: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "other"
#endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func powerSourceName() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return "unknown" }
        return type as String
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// A complete report: the environment and one or more scenario results. Written as JSON to
/// `PerformanceReports/` (git-ignored) and printed as a table.
package struct BenchmarkReport: Sendable, Codable {
    package var environment: BenchmarkEnvironment
    package var scenarios: [ScenarioResult]

    package init(environment: BenchmarkEnvironment, scenarios: [ScenarioResult]) {
        self.environment = environment
        self.scenarios = scenarios
    }

    package var passed: Bool { scenarios.allSatisfy(\.passed) }

    package func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    package static func decode(_ data: Data) throws -> BenchmarkReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BenchmarkReport.self, from: data)
    }

    /// A plain-text table: the environment, then per scenario its parameters, checks, notes and
    /// the median, p95, min and max of every metric that was measured.
    package func table() -> String {
        let env = environment
        var lines = [
            "Commit \(env.commit)\(env.dirty ? " (uncommitted changes)" : "") · \(env.buildConfiguration) \(env.architecture)",
            "\(env.model) · \(env.cpu) · \(env.memoryBytes / 1_073_741_824) GB · \(env.operatingSystem)",
            "Power: \(env.powerSource)\(env.lowPowerMode ? " · Low Power Mode" : "") · thermal \(env.thermalState)",
        ]
        if env.buildConfiguration != "release" { lines.append("WARNING: debug build, numbers are not comparable with the budgets") }
        for scenario in scenarios {
            lines.append("")
            let parameters = scenario.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            lines.append("== \(scenario.name) \(parameters) · \(scenario.samples.count) runs after \(scenario.warmupRuns) warm-up")
            for (check, passed) in scenario.checks.sorted(by: { $0.key < $1.key }) {
                lines.append("   [\(passed ? "ok" : "FAILED")] \(check)")
            }
            for note in scenario.notes { lines.append("   \(note)") }
            lines.append(pad("metric", 28) + pad("median", 12) + pad("p95", 12) + pad("min", 12) + pad("max", 12))
            for metric in Metric.all {
                guard let distribution = scenario.summary[metric.name] else { continue }
                let label = metric.unit.isEmpty ? metric.name : "\(metric.name) (\(metric.unit))"
                lines.append(pad(label, 28) + [distribution.median, distribution.p95, distribution.min, distribution.max].map { pad(Self.format($0), 12) }.joined())
            }
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int64(value)) }
        return String(format: abs(value) >= 100 ? "%.0f" : abs(value) >= 1 ? "%.1f" : "%.3f", value)
    }
}
