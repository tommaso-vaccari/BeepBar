import BeepbarCore
import CryptoKit
import Foundation

/// What one measured run cost. Every counter is the change during that run only.
package struct RunSample: Sendable, Codable {
    package var wallMilliseconds: Double
    /// CPU, disk and wakeups of the whole benchmark process: the sync plus the mock server, whose
    /// own share is kept small by pre-rendered answers (see `BenchmarkUpstream`).
    package var resources: ResourceUsage
    /// Highest footprint during the run minus the footprint just before it. Misleading after a
    /// warm-up: the allocator keeps what earlier runs freed, so a run that needs as much memory as
    /// the previous one reads near zero. Compare `peakFootprint` instead.
    package var peakFootprintGrowth: Int64
    /// Highest footprint of the whole process during the run: the number to compare across file
    /// sizes when checking that memory doesn't grow with the file.
    package var peakFootprint: UInt64
    package var database: SyncDatabaseWriteCounters
    package var fileStore: FileStoreCounters
    package var upstream: UpstreamCounters
    package var installed: Int
    package var conflicts: Int
    package var failures: Int
    /// Cancel scenario only: "cancelled", "completed" (the run finished before the cancel landed),
    /// "not-reached" (the download never got that far) or "failed: …".
    package var outcome: String?
    /// Cancel scenario only: from `Task.cancel()` until the run returned.
    package var cancelLatencyMilliseconds: Double?
    /// Cancel scenario only: the local file still holds the last installed revision's bytes.
    package var localFilePreserved: Bool?

    package init(wallMilliseconds: Double, resources: ResourceUsage, peakFootprintGrowth: Int64, peakFootprint: UInt64 = 0, database: SyncDatabaseWriteCounters, fileStore: FileStoreCounters, upstream: UpstreamCounters, installed: Int, conflicts: Int, failures: Int, outcome: String? = nil, cancelLatencyMilliseconds: Double? = nil, localFilePreserved: Bool? = nil) {
        self.wallMilliseconds = wallMilliseconds
        self.resources = resources
        self.peakFootprintGrowth = peakFootprintGrowth
        self.peakFootprint = peakFootprint
        self.database = database
        self.fileStore = fileStore
        self.upstream = upstream
        self.installed = installed
        self.conflicts = conflicts
        self.failures = failures
        self.outcome = outcome
        self.cancelLatencyMilliseconds = cancelLatencyMilliseconds
        self.localFilePreserved = localFilePreserved
    }
}

/// One scenario's samples, their summaries and the sanity checks that make the numbers mean
/// what they claim (a "run with nothing new" that installed files would measure something else).
package struct ScenarioResult: Sendable, Codable {
    package let name: String
    package let parameters: [String: String]
    package let warmupRuns: Int
    package let samples: [RunSample]
    package let summary: [String: Distribution]
    /// Every check must hold for the numbers to be valid; a failed check is printed and makes the
    /// command exit non-zero.
    package let checks: [String: Bool]
    package let notes: [String]

    package init(name: String, parameters: [String: String], warmupRuns: Int, samples: [RunSample], checks: [String: Bool], notes: [String] = []) {
        self.name = name
        self.parameters = parameters
        self.warmupRuns = warmupRuns
        self.samples = samples
        self.checks = checks
        self.notes = notes
        var summary: [String: Distribution] = [:]
        for metric in Metric.all {
            let values = samples.compactMap(metric.value)
            if let distribution = Distribution(values) { summary[metric.name] = distribution }
        }
        self.summary = summary
    }

    package var passed: Bool { checks.values.allSatisfy { $0 } }
}

/// A number reported for every scenario, named as it appears in the JSON and the table.
package struct Metric: Sendable {
    package let name: String
    package let unit: String
    package let value: @Sendable (RunSample) -> Double?

    package static let all: [Metric] = [
        Metric(name: "wall", unit: "ms") { $0.wallMilliseconds },
        Metric(name: "cpu", unit: "ms") { Double($0.resources.cpuNanoseconds) / 1e6 },
        Metric(name: "instructions", unit: "M") { Double($0.resources.instructions) / 1e6 },
        Metric(name: "disk.written", unit: "KiB") { Double($0.resources.diskBytesWritten) / 1024 },
        Metric(name: "disk.logicalWritten", unit: "KiB") { Double($0.resources.logicalBytesWritten) / 1024 },
        Metric(name: "memory.peak", unit: "MiB") { Double($0.peakFootprint) / 1_048_576 },
        Metric(name: "memory.peakGrowth", unit: "MiB") { Double($0.peakFootprintGrowth) / 1_048_576 },
        Metric(name: "db.commits", unit: "") { Double($0.database.commits) },
        Metric(name: "db.rowChanges", unit: "") { Double($0.database.rowChanges) },
        Metric(name: "db.pagesWritten", unit: "") { Double($0.database.pagesWritten) },
        Metric(name: "fs.filesHashed", unit: "") { Double($0.fileStore.filesHashed) },
        Metric(name: "fs.bytesHashed", unit: "MiB") { Double($0.fileStore.bytesHashed) / 1_048_576 },
        Metric(name: "fs.pathLookups", unit: "") { Double($0.fileStore.pathLookups) },
        Metric(name: "net.requests", unit: "") { Double($0.upstream.requests) },
        Metric(name: "net.metadata", unit: "KiB") { Double($0.upstream.metadataBytes) / 1024 },
        Metric(name: "net.downloaded", unit: "MiB") { Double($0.upstream.downloadBytes) / 1_048_576 },
        Metric(name: "cancel.latency", unit: "ms") { $0.cancelLatencyMilliseconds },
    ]
}

package enum BenchmarkError: Error, CustomStringConvertible {
    case setup(String)

    package var description: String {
        switch self { case .setup(let reason): "setup failed: \(reason)" }
    }
}

/// The benchmark scenarios. Each builds its own fixture, does an unmeasured setup sync, runs
/// `warmup` unmeasured runs and then `runs` measured ones, and deletes the fixture.
package enum Scenarios {
    /// A run with nothing new: the cost of every automatic check while Moodle has no changes,
    /// which is what BeepBar does most of the time. Budget: ≤ 50 ms of local work per 1,000
    /// tracked files, no file hashing, no database or disk writes, minimal requests.
    package static func unchanged(files: Int, courses: Int? = nil, runs: Int, warmup: Int) async throws -> ScenarioResult {
        let courseCount = courses ?? max(10, (files + 999) / 1000)
        let corpus = CorpusSpec(totalFiles: files, courses: courseCount)
        let fixture = try await BenchmarkFixture(corpus: corpus)
        defer { fixture.remove() }
        let setup = try await fixture.automaticRun()
        guard setup.summary.added == corpus.totalFiles, setup.summary.failures == 0 else {
            throw BenchmarkError.setup("first sync installed \(setup.summary.added) of \(corpus.totalFiles) files, \(setup.summary.failures) failures")
        }
        var samples: [RunSample] = []
        for index in 0..<(warmup + runs) {
            let sample = try await measuredRun(fixture)
            if index >= warmup { samples.append(sample) }
        }
        let first = samples.first
        let checks = [
            "nothing installed": samples.allSatisfy { $0.installed == 0 },
            "no failures or conflicts": samples.allSatisfy { $0.failures == 0 && $0.conflicts == 0 },
            "no downloads": samples.allSatisfy { $0.upstream.downloads == 0 },
            "same work every run": samples.allSatisfy { $0.database == first?.database && $0.fileStore == first?.fileStore && $0.upstream == first?.upstream },
        ]
        // The budget's own lines are notes, not checks: a run that hashes or writes is still a
        // valid measurement, and the number is what a performance PR quotes and improves.
        let cpu = Distribution(samples.map { Double($0.resources.cpuNanoseconds) / 1e6 })?.median ?? 0
        let hashed = samples.contains { $0.fileStore.filesHashed > 0 }
        let wrote = samples.contains { $0.database.pagesWritten > 0 || $0.database.rowChanges > 0 || $0.resources.logicalBytesWritten > 0 }
        let emptyCommits = samples.map(\.database.commits).max() ?? 0
        return ScenarioResult(
            name: "unchanged", parameters: ["files": "\(corpus.totalFiles)", "courses": "\(corpus.courses)", "modulesPerCourse": "\(corpus.modulesPerCourse)"],
            warmupRuns: warmup, samples: samples, checks: checks,
            notes: [
                "cpu per 1000 files (median): \(String(format: "%.1f", cpu / Double(corpus.totalFiles) * 1000)) ms (budget ≤ 50 ms)",
                "budget, no file hashing: \(hashed ? "NOT MET" : "met")",
                "budget, no database or disk writes: \(wrote ? "NOT MET" : "met")\(!wrote && emptyCommits > 0 ? " (\(emptyCommits) empty commit per run)" : "")",
            ]
        )
    }

    /// One large file changes on Moodle on every run (a new lecture recording). Measures that
    /// memory stays flat whatever the size, that throughput is bound by the network, and that the
    /// file is read no more than needed (`fs.bytesHashed` against the size).
    package static func largeUpdate(size: Int64, runs: Int, warmup: Int) async throws -> ScenarioResult {
        let fixture = try await BenchmarkFixture(corpus: CorpusSpec(courses: 1, filesPerCourse: 0))
        defer { fixture.remove() }
        let key = fixture.upstream.addFile(course: 1, name: "registrazione.mp4", size: size)
        let setup = try await fixture.automaticRun()
        guard setup.summary.added == 1 else { throw BenchmarkError.setup("first sync installed \(setup.summary.added) of 1 file") }
        var samples: [RunSample] = []
        var contentMatches = true
        for index in 0..<(warmup + runs) {
            fixture.upstream.updateFile(key)
            let sample = try await measuredRun(fixture)
            if index >= warmup {
                samples.append(sample)
                let url = try await fixture.installedURL(for: key)
                let installed = try url.map(sha256)
                contentMatches = contentMatches && installed == fixture.upstream.content(of: key).sha256()
            }
        }
        let checks = [
            "file updated every run": samples.allSatisfy { $0.installed == 1 && $0.failures == 0 && $0.conflicts == 0 },
            "whole file downloaded once": samples.allSatisfy { $0.upstream.downloads == 1 && $0.upstream.downloadBytes == size },
            "installed bytes match": contentMatches,
        ]
        let medianWall = Distribution(samples.map(\.wallMilliseconds))?.median ?? 0
        let medianHashed = Distribution(samples.map { Double($0.fileStore.bytesHashed) })?.median ?? 0
        return ScenarioResult(
            name: "large-update", parameters: ["size": "\(size)"], warmupRuns: warmup, samples: samples, checks: checks,
            notes: [
                "throughput (median): \(String(format: "%.0f", Double(size) / 1_048_576 / (medianWall / 1000))) MiB/s, unthrottled mock",
                "bytes hashed / file size (median): \(String(format: "%.2f", medianHashed / Double(max(size, 1))))",
            ]
        )
    }

    /// Cancels an automatic run while a large update downloads, once `fraction` of it has been
    /// sent, and measures how long the run takes to stop. The mock is throttled to
    /// `bytesPerSecond` so the cancel lands mid-transfer as on a real network. Every run checks
    /// that the previous local file is untouched unless the run finished first.
    package static func cancel(size: Int64, fraction: Double, bytesPerSecond: Int64, runs: Int, warmup: Int) async throws -> ScenarioResult {
        precondition(fraction > 0 && fraction <= 1)
        let fixture = try await BenchmarkFixture(corpus: CorpusSpec(courses: 1, filesPerCourse: 0))
        defer { fixture.remove() }
        let key = fixture.upstream.addFile(course: 1, name: "registrazione.mp4", size: size)
        let setup = try await fixture.automaticRun()
        guard setup.summary.added == 1 else { throw BenchmarkError.setup("first sync installed \(setup.summary.added) of 1 file") }
        var installedRevision = 1
        fixture.upstream.configureDownloads(bytesPerSecond: bytesPerSecond)
        let threshold = max(1, Int64((Double(size) * fraction).rounded(.up)))
        var samples: [RunSample] = []
        for index in 0..<(warmup + runs) {
            let revision = fixture.upstream.updateFile(key)
            let trigger = CancelTrigger()
            fixture.upstream.onDownloadProgress { downloaded, sent, _ in
                if downloaded == key, sent >= threshold { trigger.fire() }
            }
            var completedRun: BenchmarkFixture.RunResult?
            var sample = try await measure(fixture) { fileStore in
                let task = Task { try await fixture.automaticRun(fileStore: fileStore) }
                trigger.arm(task)
                let result = await task.result
                let stopped = ContinuousClock.now
                switch result {
                case .success(let run):
                    completedRun = run
                    return (run, trigger.firedAt == nil ? "not-reached" : "completed", trigger.firedAt.map { stopped - $0 })
                case .failure(let error):
                    return (nil, error is CancellationError ? "cancelled" : "failed: \(error)", trigger.firedAt.map { stopped - $0 })
                }
            }
            fixture.upstream.onDownloadProgress(nil)
            if completedRun?.summary.installed == 1 { installedRevision = revision }
            if let url = try await fixture.installedURL(for: key) {
                sample.localFilePreserved = try sha256(url) == fixture.upstream.content(of: key, revision: installedRevision).sha256()
            } else {
                sample.localFilePreserved = false
            }
            if index >= warmup { samples.append(sample) }
        }
        let checks = cancelChecks(samples, size: size, fraction: fraction)
        return ScenarioResult(
            name: "cancel", parameters: ["size": "\(size)", "fraction": "\(fraction)", "bytesPerSecond": "\(bytesPerSecond)"],
            warmupRuns: warmup, samples: samples, checks: checks,
            notes: ["cancelled once \(threshold) of \(size) bytes had been sent by the mock"]
        )
    }

    /// What makes a cancel run valid: every run ended cancelled, the installed file kept its exact
    /// bytes, and, when the cancel was meant to land midway (`fraction < 1`), the mock had not sent
    /// the whole file yet; otherwise the latency would measure a cancel after the download.
    package static func cancelChecks(_ samples: [RunSample], size: Int64, fraction: Double) -> [String: Bool] {
        var checks = [
            "every run cancelled": samples.allSatisfy { $0.outcome == "cancelled" },
            "local file preserved": samples.allSatisfy { $0.localFilePreserved == true },
        ]
        if fraction < 1 { checks["cancelled before the download finished"] = samples.allSatisfy { $0.upstream.downloadBytes < size } }
        return checks
    }

    // MARK: Measurement

    private static func measuredRun(_ fixture: BenchmarkFixture) async throws -> RunSample {
        try await measure(fixture) { fileStore in
            let run = try await fixture.automaticRun(fileStore: fileStore)
            return (run, nil, nil)
        }
    }

    /// Runs `body` with a fresh `FileStore` and returns every counter's change during it.
    private static func measure(_ fixture: BenchmarkFixture, _ body: (FileStore) async throws -> (BenchmarkFixture.RunResult?, String?, Duration?)) async throws -> RunSample {
        let fileStore = try fixture.makeFileStore()
        let database = await fixture.database.writeCounters()
        let upstream = fixture.upstream.counters
        let footprint = PeakFootprintSampler.footprint()
        guard let resources = ResourceUsage.current() else { throw BenchmarkError.setup("proc_pid_rusage failed") }
        let sampler = PeakFootprintSampler()
        let clock = ContinuousClock()
        let start = clock.now
        let (run, outcome, latency) = try await body(fileStore)
        let wall = clock.now - start
        let peak = sampler.stop()
        let resourcesAfter = ResourceUsage.current() ?? resources
        return RunSample(
            wallMilliseconds: milliseconds(wall),
            resources: resourcesAfter.since(resources),
            peakFootprintGrowth: Int64(peak) - Int64(footprint),
            peakFootprint: peak,
            database: await fixture.database.writeCounters().since(database),
            fileStore: await fileStore.counters(),
            upstream: fixture.upstream.counters.since(upstream),
            installed: run?.summary.installed ?? 0,
            conflicts: run?.summary.conflicts ?? 0,
            failures: run?.summary.failures ?? 0,
            outcome: outcome,
            cancelLatencyMilliseconds: latency.map(milliseconds)
        )
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        // One pool per chunk: `FileHandle.read` returns autoreleased buffers, and this check runs
        // between measured runs, so without a pool a whole file stays resident and inflates the
        // next run's starting footprint.
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hash.update(data: chunk)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Cancels a run's task the first time the mock reports the threshold reached, from the mock's
/// thread, and remembers when. Either side may come first: if the threshold is reached before the
/// task is armed, arming cancels at once.
private final class CancelTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<BenchmarkFixture.RunResult, Error>?
    private var fired: ContinuousClock.Instant?

    var firedAt: ContinuousClock.Instant? { lock.withLock { fired } }

    func arm(_ task: Task<BenchmarkFixture.RunResult, Error>) {
        let cancelNow = lock.withLock { () -> Bool in
            self.task = task
            return fired != nil
        }
        if cancelNow { task.cancel() }
    }

    func fire() {
        let task = lock.withLock { () -> Task<BenchmarkFixture.RunResult, Error>? in
            guard fired == nil else { return nil }
            fired = .now
            return self.task
        }
        task?.cancel()
    }
}
