import BeepbarBenchmarkKit
import Foundation
import os
import Testing

/// Tests that read the process footprint. Serialized so that one's allocations never land in the
/// other's window: the footprint is process-wide, and the sampler test alone maps 64 MiB. Suites
/// elsewhere still run alongside, hence the margins.
@Suite(.serialized)
struct MemoryMeasurementTests {
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

    /// A slow client holds the mock back, as TCP holds back a real server: the mock never runs
    /// more than its window ahead of what the client took in, and the footprint stays flat. Without
    /// flow control the mock streams the whole file into the URL loading system's queue, and
    /// `memory.peak` charges that queue to the app. The client sleeps on every chunk so the mock is
    /// always the faster side. The lead bound is the exact check; the memory bound (80 MiB, against
    /// 125–157 MiB measured without flow control) leaves room for the other suites sharing this
    /// process.
    @Test func streamingThroughTheMockKeepsMemoryFlat() async throws {
        let upstream = BenchmarkUpstream()
        let size: Int64 = 64 << 20
        let key = upstream.addFile(course: 1, name: "grande.bin", size: size)
        let produced = OSAllocatedUnfairLock(initialState: Int64(0))
        upstream.onDownloadProgress { _, sent, _ in produced.withLock { $0 = sent } }
        let url = URL(string: "https://\(upstream.host)/webservice/pluginfile.php/1/mod_folder/content/\(key.module)/\(key.name)")!
        let before = PeakFootprintSampler.footprint()
        let sampler = PeakFootprintSampler()

        let download = try await SlowDownload.run(url, session: upstream.session, produced: produced)

        let peak = sampler.stop()
        #expect(download.received == size)
        // A chunk can be in flight on top of the window when the client samples.
        #expect(download.maximumLead <= BenchmarkUpstream.downloadWindow + 2 * (256 << 10), "mock ran \(download.maximumLead >> 10) KiB ahead")
        #expect(Int64(peak) - Int64(before) < 80 << 20, "peak grew by \((Int64(peak) - Int64(before)) >> 20) MiB for a \(size >> 20) MiB stream")
    }
}

/// Takes a download's bytes slowly and drops them, recording how far the mock got ahead, so any
/// memory the download holds belongs to the mock or to the URL loading system.
private final class SlowDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { var received: Int64; var maximumLead: Int64 }

    private let lock = NSLock()
    private let produced: OSAllocatedUnfairLock<Int64>
    private var result = Result(received: 0, maximumLead: 0)
    private var continuation: CheckedContinuation<Result, Error>?

    private init(produced: OSAllocatedUnfairLock<Int64>) { self.produced = produced }

    static func run(_ url: URL, session: URLSession, produced: OSAllocatedUnfairLock<Int64>) async throws -> Result {
        let delegate = SlowDownload(produced: produced)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let task = session.dataTask(with: url)
            task.delegate = delegate
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let sent = produced.withLock { $0 }
        lock.withLock {
            result.received += Int64(data.count)
            result.maximumLead = max(result.maximumLead, sent - result.received)
        }
        Thread.sleep(forTimeInterval: 0.001)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = lock.withLock { self.result }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: result) }
        continuation = nil
    }
}
