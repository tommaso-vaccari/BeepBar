import BeepbarBenchmarkKit
import Foundation
import Testing

/// The measuring side of the harness: statistics, resource readings, reports and a small run of
/// every scenario. Each scenario run is tiny, so these stay in the regular `swift test`.
struct BenchmarkKitTests {
    /// Median and nearest-rank p95 on known samples, odd and even counts. Guards the two numbers
    /// AGENTS.md asks every performance PR to report.
    @Test func distributionReportsMedianAndNearestRankP95() throws {
        let five = try #require(Distribution([5, 1, 4, 2, 3]))
        #expect(five.median == 3 && five.p95 == 5 && five.min == 1 && five.max == 5 && five.count == 5)
        let four = try #require(Distribution([10, 40, 20, 30]))
        #expect(four.median == 25 && four.p95 == 40)
        let twenty = try #require(Distribution((1...20).map(Double.init)))
        #expect(twenty.p95 == 19)
        let single = try #require(Distribution([7]))
        #expect(single.median == 7 && single.p95 == 7)
        #expect(Distribution([]) == nil)
    }

    /// CPU time comes back in nanoseconds. `rusage_info` reports Mach ticks (125/3 ns each on
    /// Apple silicon); reading them raw would report a busy loop of ~200 ms as ~5 ms. Compared with
    /// this thread's own CPU clock rather than a fixed range, because the reading covers the whole
    /// process and other suites run in parallel: the process total can't be below this thread's
    /// share, nor above every core busy for the whole loop.
    @Test func cpuTimeIsReportedInNanoseconds() throws {
        let before = try #require(ResourceUsage.current())
        let threadBefore = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let clock = ContinuousClock()
        let start = clock.now
        var value: UInt64 = 1
        // Until this thread has had 200 ms of CPU, not 200 ms of wall time: on a crowded runner
        // the thread may get far less CPU than wall time.
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - threadBefore < 200_000_000, clock.now - start < .seconds(10) {
            for _ in 0..<1_000 { value = value &* 6_364_136_223_846_793_005 &+ 1 }
        }
        #expect(value != 0)
        let thread = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - threadBefore)
        let wall = clock.now - start
        let elapsed = Double(wall.components.seconds) * 1e9 + Double(wall.components.attoseconds) / 1e9
        let process = Double(try #require(ResourceUsage.current()).since(before).cpuNanoseconds)
        try #require(thread >= 200e6, "the busy loop only got \(thread / 1e6) ms of CPU in 10 s")
        #expect(process >= thread * 0.95, "process \(process / 1e6) ms < thread \(thread / 1e6) ms")
        #expect(process <= elapsed * Double(ProcessInfo.processInfo.activeProcessorCount) * 1.2 + 50e6, "process \(process / 1e6) ms in \(elapsed / 1e6) ms of wall time")
    }

    /// Observing a live process returns samples and totals; a process that can't be read returns
    /// nil instead of zeros that would look like a perfect idle result.
    @Test func idleObserverReadsALiveProcessAndRejectsAMissingOne() throws {
        let observation = try #require(IdleObserver.observe(pid: getpid(), duration: 0.3, interval: 0.1))
        #expect(observation.samples.count >= 3)
        #expect(observation.completed)
        #expect(observation.durationSeconds >= 0.3)
        #expect(observation.total.cpuNanoseconds > 0)
        #expect(observation.summary().contains("pid \(getpid())"))
        #expect(IdleObserver.observe(pid: 999_999, duration: 0.1, interval: 0.05) == nil)
    }

    /// A process that exits during the observation is reported as incomplete, so a short window
    /// is never mistaken for the requested 30 minutes.
    @Test func idleObserverReportsAProcessThatExits() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.3"]
        try process.run()
        let observation = try #require(IdleObserver.observe(pid: process.processIdentifier, duration: 5, interval: 0.1))
        process.waitUntilExit()
        #expect(!observation.completed)
        #expect(observation.durationSeconds < 5)
    }

    /// A report survives the JSON round trip and its table shows the environment, every check and
    /// the metrics; the `baseline` command merges per-scenario JSON through this decoder.
    @Test func reportRoundTripsAndPrintsChecks() throws {
        let sample = RunSample(wallMilliseconds: 12.5, resources: ResourceUsage(cpuNanoseconds: 3_000_000), peakFootprintGrowth: 1_048_576, database: .init(commits: 1), fileStore: .init(pathLookups: 4), upstream: UpstreamCounters(), installed: 0, conflicts: 0, failures: 0)
        let scenario = ScenarioResult(name: "unchanged", parameters: ["files": "4"], warmupRuns: 1, samples: [sample, sample], checks: ["nothing installed": true, "same work every run": false], notes: ["a note"])
        let report = BenchmarkReport(environment: .current(commit: "abc123", dirty: true), scenarios: [scenario])

        let decoded = try BenchmarkReport.decode(try report.json())

        #expect(decoded.environment == report.environment)
        #expect(decoded.scenarios.first?.summary["db.commits"]?.median == 1)
        #expect(decoded.scenarios.first?.summary["cpu"]?.median == 3)
        #expect(decoded.scenarios.first?.summary["cancel.latency"] == nil)
        #expect(!decoded.passed)
        let table = report.table()
        #expect(table.contains("abc123 (uncommitted changes)"))
        #expect(table.contains("[FAILED] same work every run"))
        #expect(table.contains("[ok] nothing installed"))
        #expect(table.contains("db.commits"))
        #expect(table.contains("a note"))
    }

    /// A reused output directory must not turn a failed subprocess into an old successful run.
    @Test func subprocessRemovesAnOldReportBeforeFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "scenario.json")
        let report = BenchmarkReport(environment: .current(commit: "old", dirty: false), scenarios: [])
        try report.json().write(to: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")

        let result = try BenchmarkSubprocess.run(process, output: output)

        #expect(result.report == nil)
        #expect(!result.completed)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// A fresh valid report completes the run only after a normal zero exit, even if its checks
    /// passed before the subprocess exited with an error or was killed.
    @Test(arguments: ["exit 0", "exit 1", "kill -TERM $$"])
    func subprocessRequiresSuccessfulExitWithAFreshReport(termination: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appending(path: "fixture.json")
        let output = directory.appending(path: "scenario.json")
        let scenario = ScenarioResult(name: "fresh", parameters: [:], warmupRuns: 0, samples: [], checks: ["passed": true], notes: [])
        let report = BenchmarkReport(environment: .current(commit: "fresh", dirty: false), scenarios: [scenario])
        try report.json().write(to: fixture)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cp \"$1\" \"$2\"; \(termination)", "benchmark", fixture.path, output.path]

        let result = try BenchmarkSubprocess.run(process, output: output)

        #expect(result.report?.environment.commit == "fresh")
        #expect(result.report?.passed == true)
        #expect(result.completed == (termination == "exit 0"))
    }

    /// The environment names the machine and build, which AGENTS.md requires next to every number.
    @Test func environmentDescribesThisMachine() {
        let environment = BenchmarkEnvironment.current(commit: "c", dirty: false)
        #expect(environment.model != "unknown")
        #expect(environment.cpu != "unknown")
        #expect(environment.memoryBytes > 0)
        #expect(environment.buildConfiguration == (BenchmarkEnvironment.isDebugBuild ? "debug" : "release"))
        #expect(["AC Power", "Battery Power", "UPS Power", "unknown"].contains(environment.powerSource))
    }

    /// A cancel that arrived after the whole file was sent, a run that wasn't cancelled, or a
    /// local file that changed each invalidate a cancel run; at `--fraction 1` the whole file is
    /// expected. Guards the checks the `cancel` scenario's numbers depend on, including failures a
    /// real run can't be made to produce on demand.
    @Test func cancelChecksRejectLateCancelsAndChangedFiles() {
        func sample(sent: Int64, outcome: String = "cancelled", preserved: Bool = true) -> RunSample {
            var upstream = UpstreamCounters()
            upstream.downloadBytes = sent
            return RunSample(wallMilliseconds: 1, resources: ResourceUsage(), peakFootprintGrowth: 0, database: .init(), fileStore: .init(), upstream: upstream, installed: 0, conflicts: 0, failures: 0, outcome: outcome, localFilePreserved: preserved)
        }
        let good = Scenarios.cancelChecks([sample(sent: 50), sample(sent: 60)], size: 100, fraction: 0.5)
        #expect(good.count == 3 && good.values.allSatisfy { $0 })
        #expect(Scenarios.cancelChecks([sample(sent: 50), sample(sent: 100)], size: 100, fraction: 0.5)["cancelled before the download finished"] == false)
        #expect(Scenarios.cancelChecks([sample(sent: 50, outcome: "completed")], size: 100, fraction: 0.5)["every run cancelled"] == false)
        #expect(Scenarios.cancelChecks([sample(sent: 50, preserved: false)], size: 100, fraction: 0.5)["local file preserved"] == false)
        let whole = Scenarios.cancelChecks([sample(sent: 100)], size: 100, fraction: 1)
        #expect(whole["cancelled before the download finished"] == nil && whole.values.allSatisfy { $0 })
    }

    // MARK: Scenario smoke runs

    /// A tiny "nothing new" run passes its checks and reports no downloads or hashing: the
    /// numbers a performance PR compares come from exactly this path.
    @Test func unchangedScenarioPassesItsChecks() async throws {
        let result = try await Scenarios.unchanged(files: 30, courses: 3, runs: 2, warmup: 1)
        #expect(result.passed, "\(result.checks)")
        #expect(result.samples.count == 2)
        #expect(result.samples.allSatisfy { $0.fileStore.filesHashed == 0 && $0.upstream.downloads == 0 })
        #expect(result.samples.allSatisfy { $0.upstream.contentsRequests == 3 && $0.upstream.courseListRequests == 1 })
        // One lookup per tracked file is today's cost, not a requirement: a PR that makes the
        // check cheaper updates this number.
        #expect(result.summary["wall"] != nil && result.summary["fs.pathLookups"]?.median == 30)
        #expect(result.notes.contains("budget, no file hashing: met"))
    }

    /// A small "large update" downloads and installs the new revision every run and counts its
    /// bytes hashed.
    @Test func largeUpdateScenarioPassesItsChecks() async throws {
        let size: Int64 = 3 << 20
        let result = try await Scenarios.largeUpdate(size: size, runs: 2, warmup: 0)
        #expect(result.passed, "\(result.checks)")
        #expect(result.samples.allSatisfy { $0.upstream.downloadBytes == size && $0.fileStore.bytesHashed >= size })
    }

    /// A throttled download is cancelled halfway, the run stops, and the local file keeps the
    /// previous revision. The latency is measured from the cancel, not from the run's start.
    @Test func cancelScenarioCancelsMidTransferAndKeepsTheLocalFile() async throws {
        let size: Int64 = 8 << 20
        let result = try await Scenarios.cancel(size: size, fraction: 0.5, bytesPerSecond: 16 << 20, runs: 2, warmup: 0)
        #expect(result.passed, "\(result.checks) \(result.samples.map(\.outcome))")
        #expect(result.checks["cancelled before the download finished"] == true)
        for sample in result.samples {
            #expect(sample.upstream.downloadBytes < size)
            let latency = try #require(sample.cancelLatencyMilliseconds)
            #expect(latency >= 0 && latency < sample.wallMilliseconds)
        }
    }
}

/// Invalid CLI input must fail before creating a corpus, report directory or idle observer.
struct BenchmarkOptionsTests {
    @Test(arguments: [
        ("baseline", ["--output", "report"]),
        ("unchanged", ["--out", "report"]),
        ("baseline", ["--json", "report.json"]),
        ("idle", ["--files", "1"]),
        ("large-update", ["--fraction", "0.5"]),
        ("cancel", ["--files", "1"]),
        ("unknown", []),
        ("baseline", ["--out"]),
        ("baseline", ["--out", "--runs", "1"]),
        ("baseline", ["--out", ""]),
        ("baseline", ["--runs", "1", "--runs", "2"]),
        ("baseline", ["--dirty", "--dirty"]),
        ("baseline", ["--runs", "0"]),
        ("unchanged", ["--files", "-1"]),
        ("unchanged", ["--courses", "0"]),
        ("cancel", ["--fraction", "1.1"]),
        ("cancel", ["--fraction", "nan"]),
        ("large-update", ["--size-mb", String(Int.max)]),
        ("cancel", ["--rate-mbps", String(Int.max)]),
        ("baseline", ["--runs", String(Int.max)]),
        ("unchanged", ["--warmup", String(Int.max)]),
        ("unchanged", ["--files", String(Int.max)]),
        ("unchanged", ["--files", "1", "--courses", String(Int.max)]),
        ("unchanged", ["--files", String(Int.max - 1000), "--courses", "2000"]),
        ("idle", []),
        ("idle", ["--pid", "2147483648"]),
        ("idle", ["--pid", "1", "--minutes", "inf"]),
    ])
    func rejectsBeforeWork(command: String, arguments: [String]) {
        #expect(throws: CLIError.self) {
            try BenchmarkOptions(arguments[...], command: command)
        }
    }

    /// Defaults, zero warmup, each command's options and literal paths remain usable.
    @Test(arguments: ["unchanged", "large-update", "cancel", "baseline"])
    func defaultsAndCommonMetadata(command: String) throws {
        let defaults = try BenchmarkOptions([][...], command: command)
        #expect(try defaults.int("runs", 5) == 5)
        #expect(try defaults.int("warmup", 1, allowZero: true) == 1)
        let options = try BenchmarkOptions(["--runs", "2", "--warmup", "0", "--commit", "sha", "--dirty"][...], command: command)
        #expect(try options.int("runs", 5) == 2)
        #expect(try options.int("warmup", 1, allowZero: true) == 0)
        #expect(options.values["commit"] == "sha" && options.flags.contains("dirty"))
    }

    @Test(arguments: [
        ("unchanged", ["--files", "1", "--courses", "1", "--json", "a b.json"]),
        ("large-update", ["--size-mb", "1"]),
        ("cancel", ["--size-mb", "1", "--fraction", "1", "--rate-mbps", "1"]),
        ("baseline", ["--out", "a b"]),
        ("baseline", ["--runs", String(Int.max), "--warmup", "0"]),
        ("idle", ["--pid", "1", "--minutes", "0.01", "--interval-seconds", "0.1", "--json", "idle.json", "--commit", "sha", "--dirty"]),
    ])
    func acceptsCommandOptions(command: String, arguments: [String]) throws {
        let options = try BenchmarkOptions(arguments[...], command: command)
        #expect(!options.values.isEmpty)
    }
}
