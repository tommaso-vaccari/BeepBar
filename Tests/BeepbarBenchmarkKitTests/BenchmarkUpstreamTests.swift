import BeepbarBenchmarkKit
import BeepbarCore
import CryptoKit
import Foundation
import Testing

/// The mock Moodle and the fixture must behave like the real thing as far as the sync can tell,
/// or every number the harness reports measures a different program. These tests run a real
/// `SyncCoordinator` against them.
struct BenchmarkUpstreamTests {
    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// A first sync installs every file with exactly the bytes the mock generated, and asks for
    /// each course's contents once and each file once. Guards against a mock that serves the
    /// wrong bytes, a metadata format the client silently drops (zero files installed would still
    /// "pass" a run), or a counter that misses a request category.
    @Test func firstSyncInstallsEveryFileWithTheGeneratedBytes() async throws {
        let corpus = CorpusSpec(courses: 3, filesPerCourse: 7, modulesPerCourse: 2, fileSize: 3_000)
        let fixture = try await BenchmarkFixture(corpus: corpus)
        defer { fixture.remove() }

        let result = try await fixture.automaticRun()

        #expect(result.summary.added == corpus.totalFiles)
        #expect(result.summary.failures == 0)
        #expect(result.openConflicts == 0 && result.pendingChanges == 0)
        let counters = fixture.upstream.counters
        #expect(counters.siteInfoRequests == 1)
        #expect(counters.courseListRequests == 1)
        #expect(counters.contentsRequests == corpus.courses)
        #expect(counters.downloads == corpus.totalFiles)
        #expect(counters.otherRequests == 0)
        #expect(counters.downloadBytes == Int64(corpus.totalFiles) * corpus.fileSize)
        let key = SyntheticFileKey(course: 2, module: BenchmarkUpstream.moduleID(course: 2, ordinal: 1), name: "lezione-00003.pdf")
        let installed = try #require(try await fixture.installedURL(for: key))
        #expect(try sha256(installed) == fixture.upstream.content(of: key).sha256())
    }

    /// With nothing new on Moodle, a second run lists courses and contents again but downloads
    /// nothing and never asks for the site info again (the app caches it), and its metadata bytes
    /// are counted the same every time. This is the request profile the "unchanged" benchmark
    /// measures; a `net.metadata` stuck at zero would hide a regression in response size.
    @Test func runWithNothingNewDownloadsNothing() async throws {
        let fixture = try await BenchmarkFixture(corpus: CorpusSpec(courses: 2, filesPerCourse: 5))
        defer { fixture.remove() }
        try await fixture.automaticRun()
        let before = fixture.upstream.counters

        let result = try await fixture.automaticRun()

        let delta = fixture.upstream.counters.since(before)
        #expect(result.summary.installed == 0 && result.summary.failures == 0)
        #expect(delta.siteInfoRequests == 0)
        #expect(delta.courseListRequests == 1)
        #expect(delta.contentsRequests == 2)
        #expect(delta.downloads == 0 && delta.downloadBytes == 0)
        // The metadata of a run with nothing new is exactly what the client receives: the course
        // list and each course's contents, re-rendered the same way every time.
        #expect(delta.metadataBytes > 0)
        let again = fixture.upstream.counters
        try await fixture.automaticRun()
        #expect(fixture.upstream.counters.since(again).metadataBytes == delta.metadataBytes)
    }

    /// A new revision changes the bytes and the `contenthash`, so the next run downloads and
    /// installs exactly that file. Guards the "large update" benchmark against measuring a run
    /// that silently skipped the update.
    @Test func updatedFileIsDownloadedAgainWithItsNewBytes() async throws {
        let fixture = try await BenchmarkFixture(corpus: CorpusSpec(courses: 1, filesPerCourse: 3, modulesPerCourse: 1, fileSize: 2_048))
        defer { fixture.remove() }
        try await fixture.automaticRun()
        let key = SyntheticFileKey(course: 1, module: BenchmarkUpstream.moduleID(course: 1, ordinal: 0), name: "lezione-00001.pdf")
        let original = fixture.upstream.content(of: key).sha256()
        fixture.upstream.updateFile(key)
        let updated = fixture.upstream.content(of: key).sha256()
        #expect(original != updated)
        let before = fixture.upstream.counters

        let result = try await fixture.automaticRun()

        #expect(result.summary.updated == 1 && result.summary.added == 0)
        #expect(fixture.upstream.counters.since(before).downloads == 1)
        #expect(try sha256(try #require(try await fixture.installedURL(for: key))) == updated)
    }

    /// Two mocks in the same process never see each other's requests: the harness's own tests
    /// run in parallel, and a shared registry would mix their counters.
    @Test func parallelUpstreamsAreIsolated() async throws {
        async let first = BenchmarkFixture(corpus: CorpusSpec(courses: 1, filesPerCourse: 2))
        async let second = BenchmarkFixture(corpus: CorpusSpec(courses: 2, filesPerCourse: 3))
        let (a, b) = try await (first, second)
        defer { a.remove(); b.remove() }
        async let runA = a.automaticRun()
        async let runB = b.automaticRun()
        _ = try await (runA, runB)
        #expect(a.upstream.counters.downloads == 2)
        #expect(b.upstream.counters.downloads == 6)
        #expect(a.upstream.host != b.upstream.host)
    }

    /// A request on the benchmark session to a host no mock serves is answered by the mock with
    /// its own error, never passed to the real HTTP stack. Guards "no real network": the real
    /// stack would fail this `.test` host with `.cannotFindHost`, after a DNS lookup.
    @Test func unknownHostNeverReachesTheRealNetwork() async throws {
        let upstream = BenchmarkUpstream()
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).bench.beepbar.test/webservice/rest/server.php")!
        do {
            _ = try await upstream.session.data(from: url)
            Issue.record("a request to an unknown host succeeded")
        } catch let error as URLError {
            #expect(error.code == .resourceUnavailable, "\(error.code)")
        }
        #expect(upstream.counters.requests == 0)
    }

    /// A client that stops taking data in without cancelling gets the download failed with
    /// `.timedOut` once the stall lasts `stallTimeout`, instead of leaving a mock thread polling
    /// (and keeping the mock alive) forever.
    @Test func stalledClientTimesOut() async throws {
        let upstream = BenchmarkUpstream()
        upstream.configureDownloads(stallTimeout: .milliseconds(300))
        let key = upstream.addFile(course: 1, name: "grande.bin", size: 32 << 20)
        let url = URL(string: "https://\(upstream.host)/webservice/pluginfile.php/1/mod_folder/content/\(key.module)/\(key.name)")!
        let stalled = StalledDownload()
        let clock = ContinuousClock()
        let start = clock.now

        let error = await stalled.run(url, session: upstream.session)

        #expect((error as? URLError)?.code == .timedOut, "\(String(describing: error))")
        #expect(clock.now - start < .seconds(10))
        #expect(upstream.counters.downloadBytes < 32 << 20)
    }

    /// The content is deterministic per seed, differs between seeds, and reads the same however
    /// it is chunked, across the 1 MiB block boundary too. The SHA the tests compare against is
    /// computed from these reads, so a chunking bug would make both sides wrong in the same way
    /// only if this property failed.
    @Test func syntheticContentIsDeterministicAndChunkIndependent() {
        let size = Int64(SyntheticContent.maximumBlockSize) * 2 + 12_345
        let content = SyntheticContent(seed: 42, size: size)
        #expect(SyntheticContent(seed: 42, size: size).sha256() == content.sha256())
        #expect(SyntheticContent(seed: 43, size: size).sha256() != content.sha256())
        var whole = Data()
        var offset: Int64 = 0
        while offset < size {
            let chunk = content.bytes(at: offset, count: 300_007)
            whole.append(chunk)
            offset += Int64(chunk.count)
        }
        #expect(Int64(whole.count) == size)
        #expect(SHA256.hash(data: whole).map { String(format: "%02x", $0) }.joined() == content.sha256())
        #expect(content.bytes(at: size, count: 10).isEmpty)
        #expect(content.bytes(at: size - 3, count: 10).count == 3)
    }
}

/// Takes the first chunk and then holds the delegate queue for a second, as a client stuck on a
/// slow disk would; returns the error the download ended with.
private final class StalledDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?
    private var stalled = false

    func run(_ url: URL, session: URLSession) async -> Error? {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            let task = session.dataTask(with: url)
            task.delegate = self
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let first = lock.withLock { () -> Bool in defer { stalled = true }; return !stalled }
        // Hold the queue once, well past the stall timeout. Without the timeout the download would
        // simply resume afterwards and finish without an error.
        if first { Thread.sleep(forTimeInterval: 1) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let pending = lock.withLock { () -> CheckedContinuation<Error?, Never>? in defer { continuation = nil }; return continuation }
        pending?.resume(returning: error)
    }
}
