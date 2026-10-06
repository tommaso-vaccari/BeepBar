import Darwin
import Foundation

/// Watches another process (the installed Beepbar) without touching it: it only reads the
/// kernel's accounting with `proc_pid_rusage`, which needs no permission for a process of the same
/// user and changes nothing in it. No signals, no debugger, no instrumentation, no shared state.
package struct IdleObservation: Sendable, Codable {
    package struct Sample: Sendable, Codable {
        package let secondsFromStart: Double
        package let usage: ResourceUsage
    }

    package let pid: Int32
    package let durationSeconds: Double
    package let samples: [Sample]
    /// Totals over the whole observation (footprint: the last value).
    package let total: ResourceUsage
    /// Footprint at the end minus at the start: memory growth while idle.
    package let footprintGrowth: Int64
    /// Highest footprint among the samples.
    package let peakFootprint: UInt64
    /// `false` when the process exited before the end; the totals then cover only the time it ran.
    package let completed: Bool

    /// Average CPU over the observation, as a share of one core (0.01 = 1%).
    package var averageCPU: Double { durationSeconds > 0 ? Double(total.cpuNanoseconds) / (durationSeconds * 1e9) : 0 }

    /// Wakeups per second, idle plus interrupt.
    package var wakeupsPerSecond: Double { durationSeconds > 0 ? Double(total.idleWakeups + total.interruptWakeups) / durationSeconds : 0 }

    /// The lines `beepbar-bench idle` prints, against the idle budget in AGENTS.md. Network bytes
    /// aren't in `proc_pid_rusage`; `scripts/measure-idle.sh` adds them from `nettop`.
    package func summary() -> String {
        [
            String(format: "pid %d · %.0f s%@", pid, durationSeconds, completed ? "" : " · process exited early"),
            String(format: "average CPU      %.3f%% of one core (%.1f ms total)", averageCPU * 100, Double(total.cpuNanoseconds) / 1e6),
            String(format: "wakeups          %llu idle, %llu interrupt (%.2f/s)", total.idleWakeups, total.interruptWakeups, wakeupsPerSecond),
            "disk written     \(total.diskBytesWritten) bytes (logical \(total.logicalBytesWritten))",
            String(format: "footprint        %+.1f MiB (peak %.1f MiB)", Double(footprintGrowth) / 1_048_576, Double(peakFootprint) / 1_048_576),
        ].joined(separator: "\n")
    }
}

package enum IdleObserver {
    /// Samples `pid` every `interval` seconds for `duration` seconds. Returns `nil` when the
    /// process can't be read at the start.
    package static func observe(pid: Int32, duration: TimeInterval, interval: TimeInterval, onSample: ((IdleObservation.Sample) -> Void)? = nil) -> IdleObservation? {
        guard let first = ResourceUsage.current(pid: pid) else { return nil }
        let start = Date()
        var samples = [IdleObservation.Sample(secondsFromStart: 0, usage: first)]
        var completed = true
        while true {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= duration { break }
            Thread.sleep(forTimeInterval: min(interval, duration - elapsed))
            guard let usage = ResourceUsage.current(pid: pid) else { completed = false; break }
            let sample = IdleObservation.Sample(secondsFromStart: Date().timeIntervalSince(start), usage: usage)
            samples.append(sample)
            onSample?(sample)
        }
        let last = samples[samples.count - 1]
        return IdleObservation(
            pid: pid,
            durationSeconds: last.secondsFromStart,
            samples: samples,
            total: last.usage.since(first),
            footprintGrowth: Int64(last.usage.physFootprint) - Int64(first.physFootprint),
            peakFootprint: samples.map(\.usage.physFootprint).max() ?? 0,
            completed: completed
        )
    }
}
