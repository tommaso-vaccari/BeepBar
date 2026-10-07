import BeepbarBenchmarkKit
@testable import BeepbarCore
import Foundation
import os
import Testing

/// Tests that read the process footprint. Serialized so that one's allocations never land in the
/// other's window: the footprint is process-wide, and the sampler test alone maps 64 MiB. Suites
/// elsewhere still run alongside, hence the margins.
@Suite(.serialized)
struct MemoryMeasurementTests {
    // The large-file tests (this one, and hashing and copying below) guard the "peak memory
    // independent of file size" budget (AGENTS.md) against FileStore keeping every chunk it reads
    // alive until the call returns, which made a 256 MiB update peak at about 1 GiB. Each uses a
    // file large enough that holding it would blow far past the margin, which itself leaves room
    // for the suites sharing this process.

    /// A whole automatic run that downloads and installs a new version of a large file stays
    /// flat end to end: download, staging, the five reads of the file and the install. Guards
    /// against a path outside FileStore's chunk loop holding the file again.
    ///
    /// A failing large-file test leaves its chunks alive, which raises the next one's `before`:
    /// later tests in this suite may then pass by reusing that memory. Only the first failure is
    /// meaningful, and the suite as a whole still fails. Any single regression is caught: the
    /// hash loop by this test, the copy loop (which this scenario never runs) by its own test.
    @Test func updatingALargeFileKeepsMemoryFlat() async throws {
        let before = PeakFootprintSampler.footprint()

        let result = try await Scenarios.largeUpdate(size: Self.largeFileSize, runs: 1, warmup: 0)

        #expect(result.checks.values.allSatisfy { $0 }, "\(result.checks)")
        let peak = try #require(result.samples.first?.peakFootprint)
        #expect(Int64(peak) - Int64(before) < Self.margin, "peak grew by \((Int64(peak) - Int64(before)) >> 20) MiB updating a \(Self.largeFileSize >> 20) MiB file")
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

    /// Hashing a large file holds one chunk at a time. Guards the chunk loop in
    /// `FileStore.hashContents`: without a pool per chunk, the 192 MiB read stays in memory.
    @Test func hashingALargeFileKeepsMemoryFlat() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeSparseFile(at: root.appending(path: "Analisi/registrazione.mp4"), size: Self.largeFileSize)
        let store = try FileStore(root: root) { _ in }
        let before = PeakFootprintSampler.footprint()
        let sampler = PeakFootprintSampler()

        _ = try await store.inspect(try RelativePath("Analisi/registrazione.mp4"))

        let peak = sampler.stop()
        #expect(await store.counters().bytesHashed == Self.largeFileSize)
        #expect(Int64(peak) - Int64(before) < Self.margin, "peak grew by \((Int64(peak) - Int64(before)) >> 20) MiB hashing a \(Self.largeFileSize >> 20) MiB file")
    }

    /// Restoring a large conflict copy holds one chunk at a time. Guards the copy loop in
    /// `FileStore.copyConflictArtifactToStage`, which reads the file outside `hashContents`.
    @Test func copyingALargeConflictArtifactKeepsMemoryFlat() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeSparseFile(at: root.appending(path: ".beepbar/conflicts/c1/registrazione.mp4"), size: Self.largeFileSize)
        let store = try FileStore(root: root) { _ in }
        let path = try RelativePath(internal: ".beepbar/conflicts/c1/registrazione.mp4")
        let artifact = try #require(try await store.conflictArtifact(at: path))
        let before = PeakFootprintSampler.footprint()
        let sampler = PeakFootprintSampler()

        let staged = try await store.copyConflictArtifactToStage(at: path, expectedSHA256: artifact.sha256)

        let peak = sampler.stop()
        #expect(staged.size == Self.largeFileSize)
        try await store.discard(staged)
        #expect(Int64(peak) - Int64(before) < Self.margin, "peak grew by \((Int64(peak) - Int64(before)) >> 20) MiB copying a \(Self.largeFileSize >> 20) MiB file")
    }

    private static let largeFileSize: Int64 = 192 << 20
    private static let margin: Int64 = 64 << 20

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A sparse file reads back as zeros without the test itself ever holding its bytes, so the
    /// footprint before the measurement doesn't depend on how the allocator recycles a buffer.
    private static func makeSparseFile(at url: URL, size: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
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
