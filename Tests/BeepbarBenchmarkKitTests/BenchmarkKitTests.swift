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
    /// Apple silicon); reading them raw would report a busy loop of ~200 ms as ~5 ms.
    @Test func cpuTimeIsReportedInNanoseconds() throws {
        let before = try #require(ResourceUsage.current())
        let clock = ContinuousClock()
        let start = clock.now
        var value: UInt64 = 1
        while clock.now - start < .milliseconds(200) { value = value &* 6_364_136_223_846_793_005 &+ 1 }
        #expect(value != 0)
        let cpu = Double(try #require(ResourceUsage.current()).since(before).cpuNanoseconds) / 1e6
        #expect(cpu > 150 && cpu < 2_000, "cpu \(cpu) ms for a 200 ms busy loop")
    }

    /// The sampler catches a peak that is gone by the time it stops: a before/after reading would
    /// report zero growth for a download that briefly held the whole file in memory. The buffer is
    /// mapped and unmapped directly so its pages leave the footprint at once; with `malloc` the
    /// allocator may keep them, and the final reading in `stop()` alone would pass the test.
    @Test func peakSamplerCatchesATransientAllocation() throws {
        let size = 64 << 20
        let before = PeakFootprintSampler.footprint()
        let sampler = PeakFootprintSampler()
        let buffer = try #require(mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
        try #require(buffer != MAP_FAILED)
        buffer.initializeMemory(as: UInt8.self, repeating: 1, count: size)
        Thread.sleep(forTimeInterval: 0.05)
        let mapped = PeakFootprintSampler.footprint()
        munmap(buffer, size)
        // Precondition: the allocation is really gone, so only a sample taken while it was mapped
        // can report it. Compared with the reading just before, not with `before`, because tests
        // running in parallel share the process footprint.
        try #require(PeakFootprintSampler.footprint() + (32 << 20) < mapped, "footprint still includes the buffer")
        let peak = sampler.stop()
        #expect(peak >= before + (48 << 20), "peak \(peak) vs before \(before)")
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

    /// The environment names the machine and build, which AGENTS.md requires next to every number.
    @Test func environmentDescribesThisMachine() {
        let environment = BenchmarkEnvironment.current(commit: "c", dirty: false)
        #expect(environment.model != "unknown")
        #expect(environment.cpu != "unknown")
        #expect(environment.memoryBytes > 0)
        #expect(environment.buildConfiguration == (BenchmarkEnvironment.isDebugBuild ? "debug" : "release"))
        #expect(["AC Power", "Battery Power", "UPS Power", "unknown"].contains(environment.powerSource))
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
        #expect(result.summary["wall"] != nil && result.summary["fs.pathLookups"]?.median == 30)
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
        for sample in result.samples {
            #expect(sample.upstream.downloadBytes < size)
            let latency = try #require(sample.cancelLatencyMilliseconds)
            #expect(latency >= 0 && latency < sample.wallMilliseconds)
        }
    }
}
