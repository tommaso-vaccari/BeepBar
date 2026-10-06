import Darwin
import Foundation

/// A reading of what a process has consumed since it started, from `proc_pid_rusage`. Works on
/// this process and, passively, on another process of the same user (the installed Beepbar for
/// the idle measurement): reading it changes nothing in that process.
package struct ResourceUsage: Sendable, Codable, Equatable {
    /// User plus system CPU time, in nanoseconds.
    package var cpuNanoseconds: UInt64
    package var instructions: UInt64
    package var cycles: UInt64
    /// Bytes the process caused to be read from and written to storage.
    package var diskBytesRead: UInt64
    package var diskBytesWritten: UInt64
    /// Bytes written including those still in the page cache (APFS "logical writes").
    package var logicalBytesWritten: UInt64
    /// Memory charged to the process (Activity Monitor's "Memory").
    package var physFootprint: UInt64
    /// Wakeups from idle: what keeps a laptop's CPU from staying asleep.
    package var idleWakeups: UInt64
    package var interruptWakeups: UInt64

    package init(cpuNanoseconds: UInt64 = 0, instructions: UInt64 = 0, cycles: UInt64 = 0, diskBytesRead: UInt64 = 0, diskBytesWritten: UInt64 = 0, logicalBytesWritten: UInt64 = 0, physFootprint: UInt64 = 0, idleWakeups: UInt64 = 0, interruptWakeups: UInt64 = 0) {
        self.cpuNanoseconds = cpuNanoseconds
        self.instructions = instructions
        self.cycles = cycles
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.logicalBytesWritten = logicalBytesWritten
        self.physFootprint = physFootprint
        self.idleWakeups = idleWakeups
        self.interruptWakeups = interruptWakeups
    }

    /// Reads `pid` (this process by default); `nil` when the process is gone or not readable.
    package static func current(pid: pid_t = getpid()) -> ResourceUsage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        return ResourceUsage(
            cpuNanoseconds: nanoseconds(fromMachTicks: info.ri_user_time &+ info.ri_system_time),
            instructions: info.ri_instructions,
            cycles: info.ri_cycles,
            diskBytesRead: info.ri_diskio_bytesread,
            diskBytesWritten: info.ri_diskio_byteswritten,
            logicalBytesWritten: info.ri_logical_writes,
            physFootprint: info.ri_phys_footprint,
            idleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups
        )
    }

    /// The change since `earlier`. The footprint is not cumulative, so it keeps the later value.
    package func since(_ earlier: ResourceUsage) -> ResourceUsage {
        ResourceUsage(
            cpuNanoseconds: cpuNanoseconds &- earlier.cpuNanoseconds,
            instructions: instructions &- earlier.instructions,
            cycles: cycles &- earlier.cycles,
            diskBytesRead: diskBytesRead &- earlier.diskBytesRead,
            diskBytesWritten: diskBytesWritten &- earlier.diskBytesWritten,
            logicalBytesWritten: logicalBytesWritten &- earlier.logicalBytesWritten,
            physFootprint: physFootprint,
            idleWakeups: idleWakeups &- earlier.idleWakeups,
            interruptWakeups: interruptWakeups &- earlier.interruptWakeups
        )
    }

    /// `rusage_info` CPU times are in Mach absolute-time ticks, not nanoseconds: on Apple silicon
    /// a tick is 125/3 ns, so reading them as nanoseconds would understate CPU time 41-fold. The
    /// timebase converts them (and is 1/1 on Intel).
    package static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        return UInt64((Double(ticks) * Double(numer) / Double(denom)).rounded())
    }

    private static let timebase: (UInt32, UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()
}

/// Samples this process's memory footprint on its own thread to catch the peak during an
/// operation; `ri_phys_footprint` read before and after would miss a peak in between.
///
/// A plain thread, not a Swift task: the sampler must keep running while the code being measured
/// keeps the cooperative pool busy, and must not take a thread from it.
package final class PeakFootprintSampler: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = true
    private let finished = DispatchSemaphore(value: 0)

    /// Starts sampling at once, every `interval` seconds (1 ms by default).
    package init(interval: TimeInterval = 0.001) {
        self.interval = interval
        peak = Self.footprint()
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let current = Self.footprint()
                lock.withLock { peak = max(peak, current) }
                Thread.sleep(forTimeInterval: interval)
            }
            finished.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops sampling and returns the highest footprint seen, including one last sample.
    package func stop() -> UInt64 {
        lock.withLock { running = false }
        finished.wait()
        let last = Self.footprint()
        return lock.withLock { max(peak, last) }
    }

    /// This process's footprint via `task_info`, cheaper than a full `proc_pid_rusage`.
    package static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
