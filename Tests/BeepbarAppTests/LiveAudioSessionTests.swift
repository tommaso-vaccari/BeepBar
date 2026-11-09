import AVFoundation
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// Reads a synthetic lecture from disk as Webex would serve it: the playlist whole, the file by
/// byte range; `refuse` answers every request as an expired address does. Never the network.
private final class DiskFetcher: LiveAudioFetching, @unchecked Sendable {
    let playlist: URL
    let media: URL
    let refuse: Bool
    private let lock = NSLock()
    private var ranges: [AudioEnhancement.ByteRangeLecture.Span] = []
    init(playlist: URL, media: URL, refuse: Bool = false) {
        self.playlist = playlist
        self.media = media
        self.refuse = refuse
    }
    var fetchedRanges: [AudioEnhancement.ByteRangeLecture.Span] { lock.withLock { ranges } }
    func fetch(_ url: URL, range: AudioEnhancement.ByteRangeLecture.Span?) async throws -> (data: Data, url: URL) {
        if refuse { throw LiveAudioFetchError.refused(403) }
        guard let range else { return (try Data(contentsOf: playlist), url) }
        lock.withLock { ranges.append(range) }
        let handle = try FileHandle(forReadingFrom: media)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.offset))
        return (try handle.read(upToCount: Int(range.length)) ?? Data(), url)
    }
    func close() {}
}

/// The live filter end to end, with the student's real ffmpeg on a 12-second synthetic lecture
/// laid out as Webex's (one fragmented MP4 sliced by byte ranges): skipped where no ffmpeg is
/// installed. Proves what the unit tests can't: that ffmpeg accepts the arguments, the local
/// server answers AVFoundation, and the filtered segments line up into the lecture's length.
/// Each test keeps its sessions in its own throwaway folder, never the installed app's.
@MainActor
@Suite(.enabled(if: AudioEnhancement.locateFFmpeg() != nil, "needs ffmpeg"))
struct LiveAudioSessionTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-audio-\(UUID().uuidString)", isDirectory: true)
    private static let address = URL(string: "https://media.example.test/rec/out.m3u8")!

    /// Makes the synthetic lecture: 3 segments of 4 s, a tone and a test picture.
    private func makeLecture() throws -> DiskFetcher {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = AudioEnhancement.locateFFmpeg()
        process.currentDirectoryURL = folder
        process.arguments = ["-nostdin", "-loglevel", "error", "-y",
                             "-f", "lavfi", "-i", "testsrc=size=160x90:rate=25",
                             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "12",
                             "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-c:a", "aac", "-ar", "48000",
                             "-f", "hls", "-hls_time", "4", "-hls_segment_type", "fmp4", "-hls_flags", "single_file",
                             "-hls_playlist_type", "vod", "out.m3u8"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return DiskFetcher(playlist: folder.appendingPathComponent("out.m3u8"), media: folder.appendingPathComponent("out.m4s"))
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The main path: the local playlist lists the lecture's 3 segments; each one is MPEG-TS,
    /// fetched by its own byte range; AVFoundation reads the whole thing as a 12-second lecture
    /// with audio and video. A path without the session's secret is refused. Guards against
    /// arguments ffmpeg rejects, segments that don't line up, and a server open to any path.
    @Test func aLectureIsServedFilteredToAVFoundation() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = try makeLecture()
        var failures: [LiveAudioFailure] = []
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: try #require(AudioEnhancement.locateFFmpeg()),
                                           onFailure: { failures.append($0) }, fetcher: fetcher, parent: folder.appendingPathComponent("sessions"))
        defer { session.stop() }
        #expect(session.playlistURL.host == "127.0.0.1")

        let (playlist, status) = try await get(session.playlistURL)
        #expect(status == 200)
        let text = String(decoding: playlist, as: UTF8.self)
        #expect(text.components(separatedBy: ".ts").count - 1 == 3)
        #expect(!text.contains("example.test"))

        var total = 0
        for index in 0..<3 {
            let (segment, status) = try await get(session.playlistURL.deletingLastPathComponent().appendingPathComponent(AudioEnhancement.segmentName(index)))
            #expect(status == 200)
            #expect(segment.first == 0x47, "segment \(index) is not MPEG-TS")
            total += segment.count
        }
        #expect(total > 0)
        #expect(fetcher.fetchedRanges.allSatisfy { $0.length < 200_000 }, "the whole file was fetched")

        var wrong = URLComponents(url: session.playlistURL, resolvingAgainstBaseURL: false)!
        wrong.path = "/not-the-token/index.m3u8"
        #expect(try await get(wrong.url!).1 == 404)
        #expect(try await get(session.playlistURL.deletingLastPathComponent().appendingPathComponent("seg9.ts")).1 == 404)

        let asset = AVURLAsset(url: session.playlistURL)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 12) < 0.5, "length \(duration)")
        #expect(failures.isEmpty)
    }

    /// AVPlayer itself plays the filtered lecture: after a seek to 3 s, at 2x, it crosses the
    /// joins between segments (4 s and 8 s) without failing or stalling. Guards against segments
    /// AVPlayer refuses or stops at, which the length check above can't see.
    @Test func avPlayerPlaysAcrossSegmentJoins() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = try makeLecture()
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: try #require(AudioEnhancement.locateFFmpeg()),
                                           onFailure: { _ in }, fetcher: fetcher, parent: folder.appendingPathComponent("sessions"))
        defer { session.stop() }
        let item = AVPlayerItem(url: session.playlistURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause() }
        let deadline = Date().addingTimeInterval(10)
        while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(item.status == .readyToPlay, "item: \(String(describing: item.error))")
        await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = 2
        let end = Date().addingTimeInterval(8)
        while player.currentTime().seconds < 9, Date() < end, item.status != .failed { try await Task.sleep(for: .milliseconds(100)) }
        #expect(item.status != .failed, "\(String(describing: item.error))")
        #expect(player.currentTime().seconds >= 9, "stalled at \(player.currentTime().seconds) s")
    }

    /// An expired address: the player gets an error and the controller hears `.streamRefused`
    /// first, so it runs the usual recovery instead of turning the filter off.
    @Test func anExpiredAddressIsReportedAsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let lecture = try makeLecture()
        let fetcher = DiskFetcher(playlist: lecture.playlist, media: lecture.media, refuse: true)
        var failures: [LiveAudioFailure] = []
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: try #require(AudioEnhancement.locateFFmpeg()),
                                           onFailure: { failures.append($0) }, fetcher: fetcher, parent: folder.appendingPathComponent("sessions"))
        defer { session.stop() }
        #expect(try await get(session.playlistURL).1 == 502)
        #expect(failures == [.streamRefused])
    }

    /// Something that isn't Webex's layout: reported as `.unavailable`, so the lecture goes back
    /// to its own stream rather than a recovery that would fail the same way.
    @Test func anotherLayoutIsReportedAsUnavailable() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let lecture = try makeLecture()
        try "#EXTM3U\n#EXTINF:4,\nseg1.ts\n#EXT-X-ENDLIST\n".write(to: lecture.playlist, atomically: true, encoding: .utf8)
        var failures: [LiveAudioFailure] = []
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: try #require(AudioEnhancement.locateFFmpeg()),
                                           onFailure: { failures.append($0) }, fetcher: lecture, parent: folder.appendingPathComponent("sessions"))
        defer { session.stop() }
        #expect(try await get(session.playlistURL).1 == 502)
        #expect(failures == [.unavailable])
    }

    /// After `stop` nothing answers: the port is closed.
    @Test func aStoppedSessionServesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = try makeLecture()
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: try #require(AudioEnhancement.locateFFmpeg()),
                                           onFailure: { _ in }, fetcher: fetcher, parent: folder.appendingPathComponent("sessions"))
        session.stop()
        session.stop()
        await #expect(throws: (any Error).self) { _ = try await get(session.playlistURL) }
    }
}
