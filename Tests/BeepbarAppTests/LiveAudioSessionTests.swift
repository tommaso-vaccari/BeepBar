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

/// An isolation that always fails, recording the format of the audio it was given.
private final class FailingIsolator: LiveAudioVoiceIsolating, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [AVAudioFormat] = []
    var formats: [AVAudioFormat] { lock.withLock { seen } }
    struct Failure: Error {}
    func isolate(_ input: URL, from first: Int, count: Int?, to output: URL) async throws {
        let format = try AVAudioFile(forReading: input).fileFormat
        lock.withLock { seen.append(format) }
        throw Failure()
    }
}

/// An isolation that passes the audio through unchanged, as `AppleVoiceIsolator` writes it
/// (raw 16-bit, the samples asked for), and records each call: the decoded file's name (which
/// says the fragment), its length, and the stretch kept. Lets the pipeline's bookkeeping be
/// tested on any Mac, quickly.
private final class RecordingIsolator: LiveAudioVoiceIsolating, @unchecked Sendable {
    struct Call { let name: String; let length: Int; let first: Int; let count: Int? }
    private let lock = NSLock()
    private var made: [Call] = []
    var calls: [Call] { lock.withLock { made } }
    func isolate(_ input: URL, from first: Int, count: Int?, to output: URL) async throws {
        let samples = try AudioTestSignals.samples(input)
        lock.withLock { made.append(Call(name: input.lastPathComponent, length: samples.count, first: first, count: count)) }
        let kept = samples[first..<min(samples.count, first + (count ?? samples.count))]
        let raw = kept.map { Int16((max(-1, min(1, $0)) * 32767).rounded()).littleEndian }
        try raw.withUnsafeBytes { try Data($0).write(to: output) }
    }
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

    /// Makes the synthetic lecture: 3 segments of 4 s, a test picture, and a tone or, with
    /// `speaking`, a synthetic teacher (`AudioTestSignals.speech`).
    /// `audioFormat` and `startingAt` vary what Webex's file may hold: audio at 44.1 kHz in
    /// stereo, and a clock that doesn't start at zero.
    /// `seconds` and `segment` make a longer lecture for the tests that move around in it.
    private func makeLecture(speaking: Bool = false, audioFormat: [String] = ["-ar", "48000"], startingAt: Int = 0,
                             seconds: Int = 12, segment: Int = 4) throws -> DiskFetcher {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ffmpeg = try #require(AudioEnhancement.locateFFmpeg())
        let audio: [String] = speaking
            ? ["-i", try AudioTestSignals.speech(seconds: seconds, in: folder, ffmpeg: ffmpeg).path, "-t", "\(seconds)"]
            : ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "\(seconds)"]
        let process = Process()
        process.executableURL = ffmpeg
        process.currentDirectoryURL = folder
        process.arguments = ["-nostdin", "-loglevel", "error", "-y",
                             "-f", "lavfi", "-i", "testsrc=size=160x90:rate=25"] + audio + [
                             "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-c:a", "aac"] + audioFormat + [
                             "-output_ts_offset", "\(startingAt)", "-f", "hls", "-hls_time", "\(segment)", "-hls_segment_type", "fmp4", "-hls_flags", "single_file",
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
                                           onFailure: { if let failure = $0 { failures.append(failure) } }, fetcher: fetcher, parent: folder.appendingPathComponent("sessions"))
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
                                           onFailure: { if let failure = $0 { failures.append(failure) } }, fetcher: fetcher, parent: folder.appendingPathComponent("sessions"))
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
                                           onFailure: { if let failure = $0 { failures.append(failure) } }, fetcher: lecture, parent: folder.appendingPathComponent("sessions"))
        defer { session.stop() }
        #expect(try await get(session.playlistURL).1 == 502)
        #expect(failures == [.unavailable])
    }

    /// The whole path with Apple's isolation on a speaking teacher: the voice in the second
    /// segment, served after isolation, sits on the same samples of the lecture's clock as in
    /// Webex's own file (within 2 ms), and isn't lost. Guards against the isolation's hidden
    /// delay left in, and against the decoded WAV or the encoded segment misplaced on the
    /// clock (`first_pts`, `-itsoffset`), any of which would put the voice behind the picture
    /// and repeat or cut words at the joins, and the limiter's 5 ms look-ahead (240 samples).
    /// Also on a lecture recorded at 44.1 kHz in stereo whose clock starts at 10 minutes: there
    /// the decode once placed the first sample by 44.1 kHz timestamps, trimmed the whole context
    /// and served segments with no audio at all (heard as silence, 2026-11-09).
    @Test(.enabled(if: AppleVoiceIsolator.preferred() != nil && AudioTestSignals.canSpeak, "needs voice isolation and say"),
          arguments: [(["-ar", "48000"], 60), (["-ar", "44100", "-ac", "2"], 600)])
    func anIsolatedSegmentKeepsTheLecturesClock(audioFormat: [String], startingAt: Int) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = try makeLecture(speaking: true, audioFormat: audioFormat, startingAt: startingAt)
        let ffmpeg = try #require(AudioEnhancement.locateFFmpeg())
        var failures: [LiveAudioFailure] = []
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: ffmpeg, onFailure: { if let failure = $0 { failures.append(failure) } }, fetcher: fetcher,
                                           isolator: try #require(AppleVoiceIsolator.preferred()), parent: folder.appendingPathComponent("sessions"))
        defer { session.stop() }
        _ = try await get(session.playlistURL)
        let lecture = try AudioTestSignals.samples(folder.appendingPathComponent("speech.wav"))
        // Each shape a segment is made from: the first (no piece before it), the middle (pieces
        // on both sides), the last (none after it).
        for index in 0..<3 {
        let (segment, status) = try await get(session.playlistURL.deletingLastPathComponent().appendingPathComponent(AudioEnhancement.segmentName(index)))
        try #require(status == 200, "segment \(index): \(String(decoding: segment.prefix(200), as: UTF8.self)), failures \(failures)")
        let served = folder.appendingPathComponent("served\(index).ts")
        try segment.write(to: served)
        // The reference is the synthetic teacher before Webex's encoding (its sample 0 is the
        // lecture's start), not a decode of the lecture: a plain decode keeps the encoder's
        // priming and lands one AAC frame late. Both lectures start after zero because at zero
        // ffmpeg moves the priming frame to 0 and the voice itself one frame later. The served segment (48 kHz, its timestamps on
        // the lecture's clock) is placed on the same samples, silence before it.
        let placed = folder.appendingPathComponent("served\(index).wav")
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-copyts", "-i", served.path, "-map", "0:a:0", "-ac", "1",
                                          "-af", "aresample=async=1:first_pts=\(startingAt * 48000)", "-c:a", "pcm_f32le", placed.path], in: folder)
        let isolated = try AudioTestSignals.samples(placed)
        // The segment's middle, away from its edges: 0.5–3.5 s into it.
        let span = (index * 192000 + 24000)..<(index * 192000 + 168000)
        try #require(lecture.count >= span.upperBound && isolated.count >= span.upperBound)
        let delay = AudioTestSignals.delay(of: Array(isolated[span]), against: Array(lecture[span]), limit: 9600)
        #expect(abs(delay) <= 96, "segment \(index): the voice moved by \(delay) samples")
        #expect(AudioTestSignals.level(isolated[span]) > AudioTestSignals.level(lecture[span]) - 12, "segment \(index): the voice was lost")
        }
        #expect(failures.isEmpty)
    }

    /// Without isolation (a Mac without the unit) ffmpeg filters alone, as before; an isolation
    /// that fails is reported as `.unavailable`, so the lecture goes back to its own stream,
    /// and gets the decoded audio as the isolator expects it (mono, 48 kHz). Guards against a
    /// Mac without the unit losing enhanced audio, and a failing isolator playing silence.
    @Test func withoutOrWithAFailingIsolation() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = try makeLecture()
        let ffmpeg = try #require(AudioEnhancement.locateFFmpeg())
        let plain = try LiveAudioSession(stream: Self.address, ffmpeg: ffmpeg, onFailure: { _ in }, fetcher: fetcher,
                                         isolator: nil, parent: folder.appendingPathComponent("plain"))
        let (segment, status) = try await get(plain.playlistURL.deletingLastPathComponent().appendingPathComponent(AudioEnhancement.segmentName(0)))
        plain.stop()
        #expect(status == 200)
        #expect(segment.first == 0x47)

        let failing = FailingIsolator()
        var failures: [LiveAudioFailure] = []
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: ffmpeg, onFailure: { if let failure = $0 { failures.append(failure) } }, fetcher: fetcher,
                                           isolator: failing, parent: folder.appendingPathComponent("failing"))
        defer { session.stop() }
        #expect(try await get(session.playlistURL.deletingLastPathComponent().appendingPathComponent(AudioEnhancement.segmentName(0))).1 == 502)
        #expect(failures == [.unavailable])
        let format = try #require(failing.formats.first)
        #expect(format.channelCount == 1 && format.sampleRate == 48000)
    }

    /// Played through in order, each fragment of the lecture goes through isolation once, with
    /// the previous fragment's last 4 s before it and the next one's first 0.5 s after (so its
    /// joins match the whole lecture isolated at once), plus once more for the fragment after
    /// the first, which the first segment asks for urgently without what follows it. Before the
    /// pieces, each segment isolated its whole 2–3 fragment context: about 2.5 times the
    /// lecture. Guards against that cost coming back and against pieces isolated without their
    /// surroundings.
    @Test func playedInOrderEachFragmentIsIsolatedOnce() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = try makeLecture(seconds: 48, segment: 8)
        let isolator = RecordingIsolator()
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: try #require(AudioEnhancement.locateFFmpeg()), onFailure: { _ in },
                                           fetcher: fetcher, isolator: isolator, parent: folder.appendingPathComponent("sessions"))
        defer { session.stop() }
        _ = try await get(session.playlistURL)
        for index in 0..<6 {
            #expect(try await get(session.playlistURL.deletingLastPathComponent().appendingPathComponent(AudioEnhancement.segmentName(index))).1 == 200)
        }
        let calls = isolator.calls
        let lectureSamples = 48 * 48000
        let isolated = calls.reduce(0) { $0 + $1.length }
        #expect(isolated <= lectureSamples + 6 * (AudioEnhancement.isolationLead + AudioEnhancement.isolationTail) + 8 * 48000,
                "\(isolated) samples isolated for a \(lectureSamples)-sample lecture")
        // Every fragment's complete piece: with its surroundings, cut where the next starts.
        for k in 0..<6 {
            let complete = calls.filter { $0.name.hasPrefix("decoded\(k)") && ($0.name.contains("t") || k == 5) }
            #expect(complete.count == 1, "fragment \(k) isolated completely \(complete.count) times")
            guard let call = complete.first else { continue }
            #expect(call.first == (k == 0 ? 0 : AudioEnhancement.isolationLead), "fragment \(k) had \(call.first) samples before it")
            if k < 5 { #expect(call.length - call.first - (call.count ?? 0) == AudioEnhancement.isolationTail, "fragment \(k): wrong tail") }
        }
    }

    /// Going back to a part already heard, after a seek far away dropped its segments, makes
    /// them again from the pieces kept on disk without isolating anything again; stopping
    /// removes the pieces. Guards against the cache being dropped with the segments (each seek
    /// back would cost a second of isolation again) and against pieces left behind.
    @Test func goingBackToAPartHeardDoesNotIsolateItAgain() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = try makeLecture(seconds: 48, segment: 8)
        let isolator = RecordingIsolator()
        let sessions = folder.appendingPathComponent("sessions")
        let session = try LiveAudioSession(stream: Self.address, ffmpeg: try #require(AudioEnhancement.locateFFmpeg()), onFailure: { _ in },
                                           fetcher: fetcher, isolator: isolator, parent: sessions)
        _ = try await get(session.playlistURL)
        func segment(_ index: Int) async throws -> Data {
            let (data, status) = try await get(session.playlistURL.deletingLastPathComponent().appendingPathComponent(AudioEnhancement.segmentName(index)))
            #expect(status == 200 && data.first == 0x47, "segment \(index)")
            return data
        }
        let first = try await segment(0)
        _ = try await segment(1)
        // The prefetched segment 2 too, so nothing for 0–2 is still underway.
        _ = try await segment(2)
        _ = try await segment(5)
        let before = isolator.calls.count
        let again = try await segment(0)
        #expect(isolator.calls.count == before, "isolated again: \(isolator.calls.dropFirst(before).map(\.name))")
        #expect(again == first, "made again from the same pieces, the segment should be the same")
        session.stop()
        // The pipeline stops on its own actor: its folder goes a moment later.
        var left: [String] = []
        for _ in 0..<40 {
            left = ((try? FileManager.default.subpathsOfDirectory(atPath: sessions.path)) ?? []).filter { $0.hasSuffix(".raw") }
            if left.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(left.isEmpty, "pieces left after stop: \(left)")
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
