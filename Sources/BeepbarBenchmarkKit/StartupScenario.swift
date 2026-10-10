import BeepbarCore
import Foundation

/// Which launch the `startup` scenario measures (R02, issue #110).
package enum StartupPhase: String, Sendable, CaseIterable {
    /// The first launch after updating from an older release: the migration repairs a degraded
    /// database (missing tables and index, half-attributed rows, no recorded versions).
    case first
    /// Every launch after that, on the database the first launch left: what each app start costs.
    case later
}

extension Scenarios {
    /// One launch's database work as `BootstrapService.prepare` runs it in the app (open, which
    /// migrates; `registerRoot`; recovery), on a `files`-row database an older release could have
    /// left behind (`LegacyDatabaseFixture`). In the app this runs on `BootstrapService`'s own
    /// actor while the menu shows "starting", never on the main actor.
    ///
    /// `.first` builds a fresh degraded fixture for every run, warm-up included, so each sample is
    /// a real repair: a single fixture would be repaired by the warm-up and measure `.later`
    /// instead. `.later` repairs one fixture in setup, unmeasured, then measures cold reopens.
    ///
    /// The samples are ordinary `RunSample`s (`wall` is the whole launch, `db.*` the launch's
    /// connection, `upstream` zero) on purpose: `benchmark_compare.py` validates every scenario
    /// against the same metric set, so a startup-only metric would invalidate every comparison.
    /// The open/total split goes in `notes`.
    package static func startup(files: Int, phase: StartupPhase, runs: Int, warmup: Int) async throws -> ScenarioResult {
        var samples: [RunSample] = []
        var opens: [Double] = []
        var checks: [String: Bool]
        switch phase {
        case .first:
            var repaired = true
            var restored = true
            var kept = true
            var exactRepair = true
            var nothingToRecover = true
            for index in 0..<(warmup + runs) {
                let fixture = try await LegacyDatabaseFixture(files: files)
                defer { fixture.remove() }
                guard try fixture.halfAttributedRows() == fixture.partialRows else { throw BenchmarkError.setup("fixture has \(try fixture.halfAttributedRows()) half-attributed rows, expected \(fixture.partialRows)") }
                let (sample, open, launch) = try await measuredLaunch(fixture)
                guard index >= warmup else { continue }
                samples.append(sample)
                opens.append(open)
                let halfAttributed = try fixture.halfAttributedRows()
                let objects = try fixture.laterReleaseObjects()
                let tracked = try fixture.trackedRows()
                repaired = repaired && halfAttributed == 0
                restored = restored && objects.tables == 4 && objects.versions == 7
                kept = kept && tracked == files
                // The repair's UPDATE is the only statement that changes rows besides the 7
                // re-recorded versions; DDL is not counted by `total_changes`.
                exactRepair = exactRepair && launch.written.rowChanges == fixture.partialRows + 7
                nothingToRecover = nothingToRecover && launch.report == RecoveryReport()
            }
            checks = [
                "half-attributed rows repaired": repaired,
                "later-release tables, index and versions restored": restored,
                "tracked files kept": kept,
                "only the half-attributed rows and versions changed": exactRepair,
                "recovery found nothing": nothingToRecover,
            ]
        case .later:
            let fixture = try await LegacyDatabaseFixture(files: files)
            defer { fixture.remove() }
            let setup = try await fixture.launch()
            guard try fixture.halfAttributedRows() == 0, setup.report == RecoveryReport() else { throw BenchmarkError.setup("the first launch did not repair the fixture") }
            var writes: [SyncDatabaseWriteCounters] = []
            var nothingToRecover = true
            for index in 0..<(warmup + runs) {
                let (sample, open, launch) = try await measuredLaunch(fixture)
                guard index >= warmup else { continue }
                samples.append(sample)
                opens.append(open)
                writes.append(launch.written)
                nothingToRecover = nothingToRecover && launch.report == RecoveryReport()
            }
            let tracked = try fixture.trackedRows()
            checks = [
                // Budget: an app start with nothing to repair writes nothing. The commits are the
                // migration's and `registerRoot`'s empty transactions (`LaunchWritesTests`).
                "no rows or pages written": writes.allSatisfy { $0.rowChanges == 0 && $0.pagesWritten == 0 },
                "same work every run": writes.allSatisfy { $0 == writes.first },
                "tracked files kept": tracked == files,
                "recovery found nothing": nothingToRecover,
            ]
        }
        let open = Distribution(opens)
        let total = Distribution(samples.map(\.wallMilliseconds))
        func format(_ value: Double?) -> String { String(format: "%.2f", value ?? 0) }
        return ScenarioResult(
            name: "startup-\(phase.rawValue)", parameters: ["files": "\(files)", "phase": phase.rawValue],
            warmupRuns: warmup, samples: samples, checks: checks,
            notes: [
                "open+migrate median \(format(open?.median)) ms, p95 \(format(open?.p95)) ms; whole launch median \(format(total?.median)) ms, p95 \(format(total?.p95)) ms",
                "whole launch per 1000 tracked files (median): \(format(files > 0 ? (total?.median ?? 0) / Double(files) * 1000 : nil)) ms",
                "runs off the main actor in the app (BootstrapService); the menu shows the starting state meanwhile",
            ]
        )
    }

    /// One launch with the process counters around it. Returns the sample, the open-and-migrate
    /// part in milliseconds, and the launch's own result for the checks.
    private static func measuredLaunch(_ fixture: LegacyDatabaseFixture) async throws -> (RunSample, Double, (open: Duration, total: Duration, written: SyncDatabaseWriteCounters, fileStore: FileStoreCounters, report: RecoveryReport)) {
        let footprint = PeakFootprintSampler.footprint()
        guard let resources = ResourceUsage.current() else { throw BenchmarkError.setup("proc_pid_rusage failed") }
        let sampler = PeakFootprintSampler()
        let launch = try await fixture.launch()
        let peak = sampler.stop()
        let resourcesAfter = ResourceUsage.current() ?? resources
        let sample = RunSample(
            wallMilliseconds: milliseconds(launch.total),
            resources: resourcesAfter.since(resources),
            peakFootprintGrowth: Int64(peak) - Int64(footprint),
            peakFootprint: peak,
            database: launch.written,
            fileStore: launch.fileStore,
            upstream: UpstreamCounters(),
            installed: 0, conflicts: 0, failures: 0
        )
        return (sample, milliseconds(launch.open), launch)
    }
}
