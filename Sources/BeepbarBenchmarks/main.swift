import BeepbarBenchmarkKit
import Foundation

// `beepbar-bench`: BeepBar's on-demand benchmarks (docs/benchmarks.md). Run through
// `scripts/benchmark.sh`, which builds it in release mode and passes the commit. Everything runs
// on a synthetic corpus in a temporary folder against an in-process mock Moodle: never the user's
// account, database, keychain, preferences or sync folder.

let usage = """
usage: beepbar-bench <command> [options]

commands:
  unchanged      a run with nothing new        --files N (1000) --courses N
  large-update   one large file changes        --size-mb N (256)
  cancel         cancel during a large update  --size-mb N (256) --fraction F (0.5) --rate-mbps N (100)
  baseline       every scenario, each in its own process   --out DIR (PerformanceReports/baseline-<date>)
  idle           watch a running process passively         --pid N --minutes N (30) --interval-seconds N (60)

common options:
  --runs N (5)  --warmup N (1, 0 allowed)  --json PATH  --commit SHA  --dirty
"""

enum CLIError: Error {
    case usage(String)
}

struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { throw CLIError.usage("unexpected argument \(argument)") }
            let name = String(argument.dropFirst(2))
            if name == "dirty" { flags.insert(name); continue }
            guard let value = iterator.next() else { throw CLIError.usage("missing value for \(argument)") }
            values[name] = value
        }
    }

    func int(_ name: String, _ fallback: Int, allowZero: Bool = false) throws -> Int {
        guard let text = values[name] else { return fallback }
        guard let value = Int(text), value > 0 || (allowZero && value == 0) else { throw CLIError.usage("--\(name) needs a \(allowZero ? "non-negative" : "positive") integer") }
        return value
    }

    func double(_ name: String, _ fallback: Double) throws -> Double {
        guard let text = values[name] else { return fallback }
        guard let value = Double(text), value > 0, value.isFinite else { throw CLIError.usage("--\(name) needs a positive number") }
        return value
    }
}

func environment(_ options: Options) -> BenchmarkEnvironment {
    BenchmarkEnvironment.current(commit: options.values["commit"] ?? ProcessInfo.processInfo.environment["BEEPBAR_BENCH_COMMIT"] ?? "unknown", dirty: options.flags.contains("dirty"))
}

func emit(_ report: BenchmarkReport, json path: String?) throws {
    print(report.table())
    if let path {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.json().write(to: url, options: .atomic)
        print("\nJSON: \(url.path)")
    }
}

func runScenario(_ command: String, _ options: Options) async throws -> ScenarioResult {
    let runs = try options.int("runs", 5)
    let warmup = try options.int("warmup", 1, allowZero: true)
    let megabyte: Int64 = 1_048_576
    switch command {
    case "unchanged":
        let courses = options.values["courses"] == nil ? nil : try options.int("courses", 10)
        return try await Scenarios.unchanged(files: try options.int("files", 1000), courses: courses, runs: runs, warmup: warmup)
    case "large-update":
        return try await Scenarios.largeUpdate(size: Int64(try options.int("size-mb", 256)) * megabyte, runs: runs, warmup: warmup)
    case "cancel":
        let fraction = try options.double("fraction", 0.5)
        guard fraction <= 1 else { throw CLIError.usage("--fraction must be at most 1") }
        return try await Scenarios.cancel(size: Int64(try options.int("size-mb", 256)) * megabyte, fraction: fraction, bytesPerSecond: Int64(try options.int("rate-mbps", 100)) * megabyte, runs: runs, warmup: warmup)
    default:
        throw CLIError.usage("unknown command \(command)")
    }
}

/// Runs each scenario in a fresh process, so one scenario's memory high-water mark, caches and
/// leftover threads never colour the next one, then merges their JSON into one report.
func baseline(_ options: Options) throws -> Bool {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let directory = URL(fileURLWithPath: options.values["out"] ?? "PerformanceReports/baseline-\(stamp)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let common = ["--runs", "\(try options.int("runs", 5))", "--warmup", "\(try options.int("warmup", 1, allowZero: true))"]
        + (options.values["commit"].map { ["--commit", $0] } ?? []) + (options.flags.contains("dirty") ? ["--dirty"] : [])
    let plan: [(String, [String])] = [
        ("unchanged-1k", ["unchanged", "--files", "1000"]),
        ("unchanged-15k", ["unchanged", "--files", "15000"]),
        ("large-update-64mb", ["large-update", "--size-mb", "64"]),
        ("large-update-256mb", ["large-update", "--size-mb", "256"]),
        ("cancel-mid", ["cancel", "--size-mb", "256", "--fraction", "0.5"]),
    ]
    // The running binary itself, wherever it was started from (`argv[0]` may be a bare name found
    // through PATH).
    guard let executable = Bundle.main.executableURL else { throw BenchmarkError.setup("can't locate the beepbar-bench executable") }
    var scenarios: [ScenarioResult] = []
    var complete = true
    for (name, arguments) in plan {
        let output = directory.appending(path: "\(name).json")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + common + ["--json", output.path]
        process.standardOutput = FileHandle.nullDevice
        FileHandle.standardError.write(Data("running \(name)…\n".utf8))
        try process.run()
        process.waitUntilExit()
        // A scenario whose checks failed still writes its report (exit 1); one that crashed or
        // threw writes none and is reported as missing.
        guard let data = try? Data(contentsOf: output), let report = try? BenchmarkReport.decode(data) else {
            FileHandle.standardError.write(Data("\(name) produced no report (exit \(process.terminationStatus))\n".utf8))
            complete = false
            continue
        }
        scenarios.append(contentsOf: report.scenarios)
    }
    let report = BenchmarkReport(environment: environment(options), scenarios: scenarios)
    try emit(report, json: directory.appending(path: "baseline.json").path)
    try Data(report.table().utf8).write(to: directory.appending(path: "baseline.txt"))
    return complete && report.passed
}

func idle(_ options: Options) throws -> Bool {
    guard let pidText = options.values["pid"], let pid = Int32(pidText), pid > 0 else { throw CLIError.usage("idle needs --pid") }
    let minutes = try options.double("minutes", 30)
    let interval = try options.double("interval-seconds", 60)
    FileHandle.standardError.write(Data("observing pid \(pid) for \(minutes) min, passively\n".utf8))
    guard let observation = IdleObserver.observe(pid: pid, duration: minutes * 60, interval: interval, onSample: { sample in
        FileHandle.standardError.write(Data(String(format: "  %6.0f s  cpu %8.1f ms total  footprint %6.1f MiB\n", sample.secondsFromStart, Double(sample.usage.cpuNanoseconds) / 1e6, Double(sample.usage.physFootprint) / 1_048_576).utf8))
    }) else {
        FileHandle.standardError.write(Data("pid \(pid) can't be read (gone, or another user's process)\n".utf8))
        return false
    }
    print(observation.summary())
    if let path = options.values["json"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(observation).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    return observation.completed
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first, command != "--help", command != "-h" else {
    print(usage)
    exit(arguments.isEmpty ? 64 : 0)
}
do {
    let options = try Options(arguments.dropFirst())
    let passed: Bool
    switch command {
    case "baseline":
        passed = try baseline(options)
    case "idle":
        passed = try idle(options)
    default:
        if BenchmarkEnvironment.isDebugBuild { FileHandle.standardError.write(Data("warning: debug build; use scripts/benchmark.sh for comparable numbers\n".utf8)) }
        let scenario = try await runScenario(command, options)
        let report = BenchmarkReport(environment: environment(options), scenarios: [scenario])
        try emit(report, json: options.values["json"])
        passed = report.passed
    }
    exit(passed ? 0 : 1)
} catch CLIError.usage(let message) {
    FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
