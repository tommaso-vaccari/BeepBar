import AppKit
@preconcurrency import AVFoundation
import BeepbarCore
import Foundation
import os
import Testing
@testable import BeepbarApp

/// macOS's Now Playing for a lecture playing in BeepBar (issue #148 follow-up): it used to say
/// only "BeepBar". It must show the lecture's title, the course's name and the course's picture
/// from WeBeep, without delaying playback, without ever showing another lecture's picture, and
/// without keeping anything once the player closes. Every player here gets a fake publisher (so
/// nothing reaches the real Now Playing unless a test says so) and a fake loader (so nothing
/// reaches the network).
@MainActor
@Suite(.serialized)
struct RecordingNowPlayingTests {
    nonisolated private static let host = WeBeepServerPolicy.production.host
    nonisolated private static let courseA = URL(string: "https://\(host)/webservice/pluginfile.php/11/course/overviewfiles/a.png")!
    nonisolated private static let courseB = URL(string: "https://\(host)/webservice/pluginfile.php/22/course/overviewfiles/b.png")!

    // MARK: Fakes

    /// Records what the player publishes; `available` false simulates MediaPlayer failing to load.
    @MainActor final class FakePublisher: NowPlayingPublishing {
        var available = true
        private(set) var activations = 0
        private(set) var deactivations = 0
        private(set) var published: [NowPlayingState] = []
        private(set) var onCommand: (@MainActor (NowPlayingCommand) -> Void)?
        var isActive = false

        func activate(onCommand: @escaping @MainActor (NowPlayingCommand) -> Void) -> Bool {
            activations += 1
            guard available else { return false }
            self.onCommand = onCommand
            isActive = true
            return true
        }
        func publish(_ state: NowPlayingState) {
            #expect(isActive, "Published outside activate/deactivate")
            published.append(state)
        }
        /// Drops the recorded history, which holds the pictures it saw.
        func forget() { published = [] }
        func deactivate() {
            deactivations += 1
            isActive = false
            onCommand = nil
        }
    }

    /// A loader whose fetches wait until the test answers them, one per address, and that sees
    /// cancellation. Counts every fetch.
    final class GatedLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [URL: CheckedContinuation<Data, Error>] = [:]
        private var early: [URL: Result<Data, Error>] = [:]
        private(set) var fetches: [URL] = []
        private(set) var cancelled: [URL] = []

        var loader: RecordingArtwork.Loader {
            { [self] url in
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let ready = lock.withLock { () -> Result<Data, Error>? in
                            fetches.append(url)
                            if let result = early.removeValue(forKey: url) { return result }
                            waiting[url] = continuation
                            return nil
                        }
                        if let ready { continuation.resume(with: ready) }
                    }
                } onCancel: {
                    let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
                        cancelled.append(url)
                        return waiting.removeValue(forKey: url)
                    }
                    continuation?.resume(throwing: CancellationError())
                }
            }
        }

        var fetchCount: Int { lock.withLock { fetches.count } }
        var cancelledURLs: [URL] { lock.withLock { cancelled } }
        func isWaiting(_ url: URL) -> Bool { lock.withLock { waiting[url] != nil } }

        /// Answers the fetch of `url` (now, or as soon as it starts).
        func answer(_ url: URL, with result: Result<Data, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
                guard let waiting = waiting.removeValue(forKey: url) else { early[url] = result; return nil }
                return waiting
            }
            continuation?.resume(with: result)
        }
    }

    /// A player whose `timeControlStatus` a test can force, to stand for buffering, which a
    /// local file never does on demand.
    final class StatusPlayer: AVPlayer, @unchecked Sendable {
        /// Read by the nonisolated `timeControlStatus` override and written only by the test on the
        /// main actor before the player runs: `nonisolated(unsafe)` says so to the compiler.
        nonisolated(unsafe) var forcedStatus: AVPlayer.TimeControlStatus?
        override var timeControlStatus: AVPlayer.TimeControlStatus { forcedStatus ?? super.timeControlStatus }
    }

    private func makeController(publisher: FakePublisher, loader: RecordingArtwork.Loader? = nil,
                                makePlayerView: @escaping @MainActor () -> NSView? = AVKitLoader.makePlayerView,
                                makePlayer: @escaping @MainActor () -> AVPlayer = { AVPlayer() }) -> RecordingPlayerController {
        RecordingPlayerController(present: { _ in }, makePlayerView: makePlayerView, makePlayer: makePlayer,
                                  activationPolicy: ActivationPolicyControl(current: { .regular }, set: { _ in }),
                                  frameAutosaveName: nil, defaults: PlayerTestDefaults.throwaway(),
                                  nowPlaying: publisher, artworkLoader: loader)
    }

    private static func metadata(_ title: String = "Lezione 3 - Integrali", course: String = "Analisi matematica 1", artwork: URL? = courseA) -> RecordingPlaybackMetadata {
        RecordingPlaybackMetadata(title: title, courseName: course, artworkURL: artwork)
    }

    /// A small PNG of `size` pixels.
    nonisolated private static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func waitUntil(seconds: Double = 10, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { Issue.record("Condition not met in time"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: What the record says

    /// The title is the lecture's own (the archive's title, else the stream's, else the row's
    /// kind as the Recordings page shows it) and the course is named as in the sidebar, without
    /// the code and the year. Guards against "BeepBar", the raw "058167 - … [2026-27]" name, or
    /// an empty title in Now Playing.
    @Test func theMetadataNamesTheLectureAndTheCourse() {
        let course = RemoteCourseSummary(id: 5, shortName: "058167 - NUMERICAL LINEAR ALGEBRA [2026-27]", displayName: "058167 - NUMERICAL LINEAR ALGEBRA [2026-27]",
                                         isVisible: true, startDate: nil, endDate: nil, imageURL: Self.courseA)
        let recording = RecmanRecording(id: "1", courseCode: "058167", academicYear: 2026, title: "Krylov methods", recordedAt: Date(), kind: "Lezione", duration: "90 min", size: nil, previewURL: URL(string: "https://example.com/r")!)
        #expect(RecordingPlaybackMetadata.course(of: recording, in: [course]) == course)
        let metadata = RecordingPlaybackMetadata(recording: recording, course: course, streamTitle: "webex title")
        #expect(metadata == RecordingPlaybackMetadata(title: "Krylov methods", courseName: "NUMERICAL LINEAR ALGEBRA", artworkURL: Self.courseA))

        let untitled = RecmanRecording(id: "2", courseCode: "058167", academicYear: 2026, title: "", recordedAt: Date(), kind: "Esercitazione", duration: "90 min", size: nil, previewURL: URL(string: "https://example.com/r")!)
        #expect(RecordingPlaybackMetadata(recording: untitled, course: nil, streamTitle: "Webex 12/10").title == "Webex 12/10")
        #expect(RecordingPlaybackMetadata(recording: untitled, course: nil).title == "Esercitazione")
        #expect(RecordingPlaybackMetadata(recording: untitled, course: nil).courseName == "")
        #expect(RecordingPlaybackMetadata(recording: untitled, course: nil).artworkURL == nil)
        // Another year's course is not this lecture's course.
        let otherYear = RemoteCourseSummary(id: 6, shortName: "058167 - NUMERICAL LINEAR ALGEBRA [2025-26]", displayName: "058167 - NUMERICAL LINEAR ALGEBRA [2025-26]", isVisible: true, startDate: nil, endDate: nil)
        #expect(RecordingPlaybackMetadata.course(of: recording, in: [otherYear]) == nil)
    }

    /// Text is shown on one line, trimmed; without a title the window title stands in, and
    /// without either a neutral title. Guards against a blank or multi-line Now Playing entry.
    @Test func theTextIsCleanedAndNeverEmpty() {
        let resolved = RecordingNowPlayingPolicy.resolved(Self.metadata("  Lezione\n 3  ", course: " Analisi\t1 "), fallbackTitle: "fallback")
        #expect(resolved.title == "Lezione 3")
        #expect(resolved.courseName == "Analisi 1")
        #expect(RecordingNowPlayingPolicy.resolved(Self.metadata(" "), fallbackTitle: " Finestra ").title == "Finestra")
        #expect(RecordingNowPlayingPolicy.resolved(nil, fallbackTitle: "").title == "Lezione registrata")
        #expect(RecordingNowPlayingPolicy.resolved(nil, fallbackTitle: "Lezione").courseName == "")
        #expect(RecordingNowPlayingPolicy.cleaned(String(repeating: "a", count: 500)).count == RecordingNowPlayingPolicy.maximumTextLength)
    }

    /// Only an HTTPS web-service address on WeBeep's host may be fetched; `http`, another host,
    /// `file:`, `data:`, an address with its own token or a browser path never are, and the
    /// record then has no picture. Guards against sending the student's token anywhere else.
    @Test(arguments: [
        "http://\(host)/webservice/pluginfile.php/1/course/overviewfiles/a.png",
        "https://evil.example/webservice/pluginfile.php/1/course/overviewfiles/a.png",
        "file:///Users/someone/a.png",
        "data:image/png;base64,AAAA",
        "ftp://\(host)/webservice/pluginfile.php/1/a.png",
        "https://\(host)/webservice/pluginfile.php/1/a.png?token=abc",
        "https://\(host)/pluginfile.php/1/course/overviewfiles/a.png",
    ])
    func artworkAddressesOutsideWeBeepAreRefused(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(!RecordingNowPlayingPolicy.acceptsArtworkURL(url))
        #expect(RecordingNowPlayingPolicy.resolved(Self.metadata(artwork: url), fallbackTitle: "").artworkURL == nil)
        #expect(RecordingNowPlayingPolicy.acceptsArtworkURL(Self.courseA))
    }

    /// The record carries title, course, times, rates and the video type; no course means no
    /// artist key, an unknown duration no duration key. Guards against a record Control Center
    /// shows as music, or with a 0:00 duration while the stream loads.
    @Test func theRecordCarriesTheLectureAndItsTiming() {
        let state = NowPlayingState(title: "Lezione", artist: "Corso", duration: 5_400, elapsed: 60, rate: 1.5, defaultRate: 1.5, isPlaying: true, artwork: nil)
        let info = RecordingNowPlayingPolicy.info(state)
        typealias Key = RecordingNowPlayingPolicy.Key
        #expect(info[Key.title] as? String == "Lezione")
        #expect(info[Key.artist] as? String == "Corso")
        #expect(info[Key.duration] as? Double == 5_400)
        #expect(info[Key.elapsed] as? Double == 60)
        #expect(info[Key.rate] as? Double == 1.5)
        #expect(info[Key.defaultRate] as? Double == 1.5)
        #expect(info[Key.mediaType] as? Int == RecordingNowPlayingPolicy.videoMediaType)
        let bare = RecordingNowPlayingPolicy.info(NowPlayingState(title: "L", artist: "", duration: nil, elapsed: .nan, rate: 0, defaultRate: 1, isPlaying: false, artwork: nil))
        #expect(bare[Key.artist] == nil)
        #expect(bare[Key.duration] == nil)
        #expect(bare[Key.elapsed] as? Double == 0)
    }

    /// The keys spelled out in `RecordingNowPlayingPolicy.Key` are MediaPlayer's own constants,
    /// read from the framework with `dlsym`. Guards against a typo that makes macOS ignore the
    /// title or the artwork while every other test still passes.
    @Test func theKeysAreMediaPlayersOwn() throws {
        #expect(MediaPlayerLoader.load())
        let handle = try #require(dlopen(MediaPlayerLoader.frameworkPath, RTLD_LAZY | RTLD_NOLOAD))
        typealias Key = RecordingNowPlayingPolicy.Key
        let expected = [
            "MPMediaItemPropertyTitle": Key.title, "MPMediaItemPropertyArtist": Key.artist,
            "MPMediaItemPropertyPlaybackDuration": Key.duration, "MPMediaItemPropertyArtwork": Key.artwork,
            "MPNowPlayingInfoPropertyElapsedPlaybackTime": Key.elapsed, "MPNowPlayingInfoPropertyPlaybackRate": Key.rate,
            "MPNowPlayingInfoPropertyDefaultPlaybackRate": Key.defaultRate, "MPNowPlayingInfoPropertyMediaType": Key.mediaType,
        ]
        for (symbol, key) in expected {
            let pointer = try #require(dlsym(handle, symbol), "\(symbol) missing")
            #expect(pointer.assumingMemoryBound(to: NSString.self).pointee as String == key, "\(symbol)")
        }
    }

    // MARK: The picture

    /// A picture is decoded to a thumbnail no larger than 512 px; garbage is not a picture; a
    /// source claiming more pixels than allowed is refused before decoding. Guards against a
    /// course picture costing tens of megabytes, or a decompression bomb.
    @Test func picturesAreDownscaledAndBounded() throws {
        let big = try #require(RecordingArtwork.decode(Self.png(width: 1600, height: 800)))
        #expect(max(big.width, big.height) <= RecordingArtwork.maximumPixelSize)
        #expect(big.width == 512)
        #expect(RecordingArtwork.decode(Data("<html>login</html>".utf8)) == nil)
        #expect(RecordingArtwork.decode(Self.png(width: 100, height: 100), maximumSourcePixels: 5_000) == nil)
        #expect(RecordingArtwork.decode(Self.png(width: 100, height: 100), maximumSourcePixels: 10_000) != nil)
    }

    /// A loader that never answers stops at the timeout, an answer over the cap is refused, and
    /// an answer that is not a picture fails: each is an error, never a hang or a crash.
    @Test func slowOversizedOrBrokenAnswersFail() async {
        let slow: RecordingArtwork.Loader = { _ in try await Task.sleep(for: .seconds(30)); return Data() }
        let started = Date()
        await #expect(throws: RecordingArtwork.Failure.timedOut) { try await RecordingArtwork.load(Self.courseA, loader: slow, timeout: .milliseconds(100)) }
        #expect(Date().timeIntervalSince(started) < 5)
        let huge: RecordingArtwork.Loader = { _ in Data(count: 101) }
        await #expect(throws: RecordingArtwork.Failure.tooLarge) { try await RecordingArtwork.load(Self.courseA, loader: huge, maximumBytes: 100) }
        let html: RecordingArtwork.Loader = { _ in Data("<html>".utf8) }
        await #expect(throws: RecordingArtwork.Failure.undecodable) { try await RecordingArtwork.load(Self.courseA, loader: html) }
    }

    /// What the log says about a failed fetch never contains the address or the token, even
    /// when the error carries them (a `URLError`'s user info does). Guards against the token
    /// reaching the unified log.
    @Test func theLogNeverCarriesTheToken() {
        let tokenized = URL(string: Self.courseA.absoluteString + "?token=SECRET-TOKEN")!
        let errors: [Error] = [
            URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: tokenized, NSURLErrorFailingURLStringErrorKey: tokenized.absoluteString, NSLocalizedDescriptionKey: "failed \(tokenized)"]),
            NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: "y", code: 2, userInfo: [NSURLErrorFailingURLErrorKey: tokenized])]),
            WeBeepAPIError.transport(403), WeBeepAPIError.network(.offline), RecordingArtwork.Failure.timedOut,
        ]
        for error in errors {
            let line = RecordingArtwork.logDescription(error)
            #expect(!line.contains("SECRET"))
            #expect(!line.contains(Self.host))
            #expect(!line.isEmpty)
        }
    }

    // MARK: The player

    /// Play publishes the title and course at once and plays, while the picture is still being
    /// fetched; the picture joins the record when it lands. Guards against playback (or the
    /// title) waiting on WeBeep.
    @Test(.timeLimit(.minutes(1))) func playbackAndTitleNeverWaitForThePicture() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let gate = GatedLoader()
        let controller = makeController(publisher: publisher, loader: gate.loader)
        controller.play(media, title: "window", cookies: [], startAt: nil, recordingID: "a", metadata: Self.metadata())
        // Synchronously, inside `play`: the record and the started player, with no picture yet.
        let first = try #require(publisher.published.first)
        #expect(first.title == "Lezione 3 - Integrali")
        #expect(first.artist == "Analisi matematica 1")
        #expect(first.artwork == nil)
        #expect(controller.player?.rate != 0)
        #expect(controller.window?.title == "Lezione 3 - Integrali")
        #expect(controller.window?.subtitle == "Analisi matematica 1")
        await Self.waitUntil { gate.isWaiting(Self.courseA) }
        #expect(publisher.published.allSatisfy { $0.artwork == nil })

        gate.answer(Self.courseA, with: .success(Self.png(width: 64, height: 64)))
        await Self.waitUntil { publisher.published.last?.artwork != nil }
        #expect(publisher.published.last?.title == "Lezione 3 - Integrali")
        #expect(controller.artwork != nil)
        #expect(gate.fetchCount == 1)
        controller.close()
    }

    /// A picture that arrives after another course's lecture replaced its own is dropped: the
    /// new lecture shows its own picture (or the app icon), never the old one, and the old fetch
    /// was cancelled. Also a result delivered by hand with an old serial. Guards against the
    /// previous course's picture appearing on the next lecture.
    @Test(.timeLimit(.minutes(1))) func aLatePictureOfAReplacedLectureIsDropped() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let gate = GatedLoader()
        let controller = makeController(publisher: publisher, loader: gate.loader)
        controller.play(media, title: "A", cookies: [], startAt: nil, recordingID: "a", metadata: Self.metadata("A", course: "Corso A", artwork: Self.courseA))
        await Self.waitUntil { gate.isWaiting(Self.courseA) }
        let oldSerial = controller.artworkSerial
        controller.play(media, title: "B", cookies: [], startAt: nil, recordingID: "b", metadata: Self.metadata("B", course: "Corso B", artwork: Self.courseB))
        await Self.waitUntil { gate.cancelledURLs.contains(Self.courseA) }
        // Even if the old fetch's answer made it through, it lands nowhere.
        controller.artworkLoaded(.success(RecordingArtworkImage(RecordingArtwork.decode(Self.png(width: 8, height: 8))!)), serial: oldSerial)
        #expect(controller.artwork == nil)
        #expect(publisher.published.last?.title == "B")
        #expect(publisher.published.last?.artwork == nil)

        gate.answer(Self.courseB, with: .success(Self.png(width: 32, height: 32)))
        await Self.waitUntil { publisher.published.last?.artwork != nil }
        let shown = try #require(publisher.published.last)
        #expect(shown.title == "B" && shown.artist == "Corso B")
        #expect(shown.artwork?.image.width == 32)
        // No record after the replacement ever carried a picture other than B's.
        let afterB = publisher.published.drop { $0.title != "B" }
        #expect(afterB.allSatisfy { $0.artwork == nil || $0.artwork?.image.width == 32 })
        controller.close()
    }

    /// Another lecture of the same course reuses the picture: one fetch only, and the picture
    /// shows at once. Guards against a request (and a flash of the app icon) for every lecture.
    @Test(.timeLimit(.minutes(1))) func theSameCoursesPictureIsFetchedOnce() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let gate = GatedLoader()
        gate.answer(Self.courseA, with: .success(Self.png(width: 16, height: 16)))
        let controller = makeController(publisher: publisher, loader: gate.loader)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: Self.metadata("Uno"))
        await Self.waitUntil { controller.artwork != nil }
        let picture = controller.artwork
        controller.play(media, title: "2", cookies: [], startAt: nil, recordingID: "2", metadata: Self.metadata("Due"))
        #expect(controller.artwork === picture)
        #expect(publisher.published.last?.title == "Due")
        #expect(publisher.published.last?.artwork === picture)
        await Self.settle()
        #expect(gate.fetchCount == 1)
        #expect(controller.artworkFetches == 1)
        controller.close()
    }

    /// Closing cancels the fetch, releases the picture, clears the record and the commands, and
    /// a result landing afterwards changes nothing. Guards against memory (or a remote command
    /// target) outliving the window, and a picture appearing after close.
    @Test(.timeLimit(.minutes(1))) func closingReleasesThePictureAndTheRecord() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let gate = GatedLoader()
        gate.answer(Self.courseA, with: .success(Self.png(width: 16, height: 16)))
        let controller = makeController(publisher: publisher, loader: gate.loader)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: Self.metadata())
        await Self.waitUntil { controller.artwork != nil }
        weak let weakPicture = controller.artwork
        controller.close()
        #expect(controller.artwork == nil)
        #expect(controller.artworkURL == nil)
        #expect(publisher.deactivations == 1)
        #expect(publisher.isActive == false)
        publisher.forget()
        await Self.settle()
        #expect(weakPicture == nil)

        // A fetch still running at close is cancelled, and its late answer is dropped.
        let second = GatedLoader()
        let other = makeController(publisher: FakePublisher(), loader: second.loader)
        other.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: Self.metadata())
        await Self.waitUntil { second.isWaiting(Self.courseA) }
        let serial = other.artworkSerial
        other.close()
        await Self.waitUntil { second.cancelledURLs == [Self.courseA] }
        other.artworkLoaded(.success(RecordingArtworkImage(RecordingArtwork.decode(Self.png(width: 8, height: 8))!)), serial: serial)
        #expect(other.artwork == nil)
    }

    /// A fetch that fails leaves the title and course in place, with the app icon, and playback
    /// goes on. Guards against an error dialog, a crash, or a record wiped by a failed picture.
    @Test(.timeLimit(.minutes(1))) func aFailedPictureKeepsTheTitleAndCourse() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let gate = GatedLoader()
        gate.answer(Self.courseA, with: .failure(URLError(.notConnectedToInternet)))
        let controller = makeController(publisher: publisher, loader: gate.loader)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: Self.metadata())
        await Self.waitUntil { gate.fetchCount == 1 }
        await Self.settle()
        #expect(controller.artwork == nil)
        #expect(controller.isOpen)
        #expect(publisher.published.last?.title == "Lezione 3 - Integrali")
        #expect(publisher.published.last?.artist == "Analisi matematica 1")
        #expect(publisher.published.allSatisfy { $0.artwork == nil })
        controller.close()
    }

    /// Without metadata (today's call site) or without a loader, nothing is fetched, the window
    /// title is the caller's, and Now Playing still shows that title instead of "BeepBar".
    @Test(.timeLimit(.minutes(1))) func withoutMetadataTheTitleStillShows() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let gate = GatedLoader()
        let controller = makeController(publisher: publisher, loader: gate.loader)
        controller.play(media, title: "Lezione 7", cookies: [], startAt: nil, recordingID: "7", metadata: nil)
        #expect(controller.window?.title == "Lezione 7")
        #expect(publisher.published.last?.title == "Lezione 7")
        #expect(publisher.published.last?.artist == "")
        let noLoader = makeController(publisher: FakePublisher())
        noLoader.play(media, title: "x", cookies: [], startAt: nil, recordingID: "x", metadata: Self.metadata())
        #expect(noLoader.artworkFetches == 0)
        await Self.settle()
        #expect(gate.fetchCount == 0)
        controller.close()
        noLoader.close()
    }

    /// The player takes Now Playing over from AVKit (whose record has no lecture on macOS) only
    /// when its publisher could start; otherwise AVKit keeps publishing, as before. Nothing is
    /// activated before the first Play. Guards against two publishers overwriting each other,
    /// and against losing Now Playing and the media keys when MediaPlayer is missing.
    @Test(.timeLimit(.minutes(1))) func thePlayerTakesOverFromAVKitOnlyWhenItCan() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let controller = makeController(publisher: publisher)
        #expect(publisher.activations == 0)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: nil)
        let view = try #require(controller.playerView)
        #expect(view.value(forKey: "updatesNowPlayingInfoCenter") as? Bool == false)
        #expect(controller.isPublishingNowPlaying)
        controller.close()

        let missing = FakePublisher()
        missing.available = false
        let fallback = makeController(publisher: missing)
        fallback.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: nil)
        let avkitView = try #require(fallback.playerView)
        #expect(avkitView.value(forKey: "updatesNowPlayingInfoCenter") as? Bool == true)
        #expect(fallback.isPublishingNowPlaying == false)
        #expect(missing.published.isEmpty)
        fallback.close()
        #expect(missing.deactivations == 0)
    }

    /// The record follows the player: paused after a pause, with the duration once known.
    /// Guards against Control Center showing "playing" for a paused lecture, or no timeline.
    @Test(.timeLimit(.minutes(1))) func theRecordFollowsPauseAndDuration() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let controller = makeController(publisher: publisher)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: nil)
        await Self.waitUntil { publisher.published.last?.duration != nil && publisher.published.last?.isPlaying == true }
        #expect(abs((publisher.published.last?.duration ?? 0) - TestMedia.duration) < 1)
        controller.pause()
        await Self.waitUntil { publisher.published.last?.isPlaying == false }
        #expect(publisher.published.last?.rate == 0)
        controller.close()
    }

    /// Remote commands do what the window's controls do: pause, play, skip and scrub. Guards
    /// against media keys and Control Center doing nothing once AVKit no longer handles them.
    @Test(.timeLimit(.minutes(1))) func remoteCommandsDriveThePlayer() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let controller = makeController(publisher: publisher)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: nil)
        await Self.waitUntil { controller.isCurrentItemReady }
        let send = try #require(publisher.onCommand)
        send(.pause)
        #expect(controller.player?.rate == 0)
        send(.play)
        #expect(controller.player?.rate != 0)
        send(.togglePlayPause)
        #expect(controller.player?.rate == 0)
        send(.seek(40))
        #expect(controller.pendingSeekTarget == 40)
        await Self.waitUntil { controller.pendingSeekTarget == nil }
        send(.skip(-10))
        #expect(abs((controller.pendingSeekTarget ?? 0) - 30) < 1.5)
        send(.seek(10_000))
        #expect(controller.pendingSeekTarget ?? 0 <= TestMedia.duration)
        controller.close()
        #expect(publisher.onCommand == nil)
    }

    @Test(.timeLimit(.minutes(1))) func anOldRemoteCommandCannotControlAReopenedWindow() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let controller = makeController(publisher: publisher)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: nil)
        let oldCommand = try #require(publisher.onCommand)
        controller.close()
        controller.play(media, title: "2", cookies: [], startAt: nil, recordingID: "2", metadata: nil)
        await Self.waitUntil { controller.isCurrentItemReady }

        oldCommand(.seek(40))
        #expect(controller.pendingSeekTarget == nil)
        oldCommand(.pause)
        #expect(controller.player?.rate != 0)
        publisher.onCommand?(.pause)
        #expect(controller.player?.rate == 0)
        controller.close()
    }

    /// The real publisher works in this process: MediaPlayer loads on demand, takes over and
    /// gives everything back. Guards against the runtime calls (class names, selectors, the
    /// artwork initializer) silently failing, which would leave AVKit's "BeepBar" in place.
    @Test func theSystemPublisherLoadsAndClears() throws {
        let system = SystemNowPlaying()
        let first = system.activate(onCommand: { _ in })
        let again = system.activate(onCommand: { _ in })
        #expect(first && again)
        // Every command has exactly one target, ours: a second activate adds none.
        for name in Self.commandNames { #expect(try Self.targetCount(name) == 1, "\(name)") }
        let picture = RecordingArtworkImage(try #require(RecordingArtwork.decode(Self.png(width: 32, height: 32))))
        system.publish(NowPlayingState(title: "Lezione", artist: "Corso", duration: 60, elapsed: 1, rate: 1, defaultRate: 1, isPlaying: true, artwork: picture))
        let center = try #require((NSClassFromString("MPNowPlayingInfoCenter") as? NSObject.Type)?.perform(NSSelectorFromString("defaultCenter"))?.takeUnretainedValue() as? NSObject)
        let info = try #require(center.value(forKey: "nowPlayingInfo") as? [String: Any])
        let title = info[RecordingNowPlayingPolicy.Key.title] as? String
        let artist = info[RecordingNowPlayingPolicy.Key.artist] as? String
        #expect(title == "Lezione")
        #expect(artist == "Corso")
        let artwork = try #require(info[RecordingNowPlayingPolicy.Key.artwork] as? NSObject)
        #expect(NSStringFromClass(type(of: artwork)).contains("MPMediaItemArtwork"))
        // The numbers MediaPlayer reads: video, playing; then paused.
        let mediaType = info[RecordingNowPlayingPolicy.Key.mediaType] as? Int
        #expect(mediaType == 2)
        let playing = center.value(forKey: "playbackState") as? Int
        #expect(playing == 1)
        system.publish(NowPlayingState(title: "Lezione", artist: "Corso", duration: 60, elapsed: 1, rate: 0, defaultRate: 1, isPlaying: false, artwork: picture))
        let paused = center.value(forKey: "playbackState") as? Int
        #expect(paused == 2)
        system.deactivate()
        #expect(center.value(forKey: "nowPlayingInfo") == nil)
        let stopped = center.value(forKey: "playbackState") as? Int
        #expect(stopped == 4)
        for name in Self.commandNames { #expect(try Self.targetCount(name) == 0, "\(name) still has a target") }
        system.deactivate()
        // Activated again (the next lecture window): one target each, not two.
        let reactivated = system.activate(onCommand: { _ in })
        #expect(reactivated)
        for name in Self.commandNames { #expect(try Self.targetCount(name) == 1, "\(name)") }
        system.deactivate()
    }

    private static let commandNames = ["playCommand", "pauseCommand", "togglePlayPauseCommand", "skipForwardCommand", "skipBackwardCommand", "changePlaybackPositionCommand"]

    /// How many targets a real `MPRemoteCommand` holds: its `_handlers` dictionary when the
    /// class has one (read through the runtime, never key-value coding on a missing key), else
    /// 1 or 0 from its `hasTargets`.
    private static func targetCount(_ name: String) throws -> Int {
        let center = try #require((NSClassFromString("MPRemoteCommandCenter") as? NSObject.Type)?.perform(NSSelectorFromString("sharedCommandCenter"))?.takeUnretainedValue() as? NSObject)
        let command = try #require(center.value(forKey: name) as? NSObject)
        if let ivar = class_getInstanceVariable(type(of: command), "_handlers"), let handlers = object_getIvar(command, ivar) as? NSDictionary {
            return handlers.count
        }
        // A weaker check from here on (it cannot see two targets): make that visible rather than
        // let "one target each after a re-activate" pass silently.
        withKnownIssue("MPRemoteCommand._handlers is gone on this macOS: counting targets with hasTargets, which cannot see a doubled target", isIntermittent: true) {
            Issue.record("\(name): target count read from hasTargets")
        }
        try #require(command.responds(to: NSSelectorFromString("hasTargets")))
        return (command.value(forKey: "hasTargets") as? Bool) == true ? 1 : 0
    }

    // MARK: Publication events

    /// While the player buffers, the record says rate 0, so Control Center does not run the
    /// clock ahead of a lecture that is not moving. Guards against publishing `player.rate`
    /// (the requested rate) during `waitingToPlay…`.
    @Test(.timeLimit(.minutes(1))) func bufferingPublishesNoMovingClock() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        var made: StatusPlayer?
        let controller = makeController(publisher: publisher, makePlayer: { let player = StatusPlayer(); made = player; return player })
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: nil)
        await Self.waitUntil { controller.isCurrentItemReady && publisher.published.last?.rate == 1 }
        made?.forcedStatus = .waitingToPlayAtSpecifiedRate
        controller.selectSpeed(1.5)
        #expect(controller.player?.rate == 1.5)
        #expect(publisher.published.last?.rate == 0)
        #expect(publisher.published.last?.defaultRate == 1.5)
        made?.forcedStatus = nil
        controller.close()
    }

    /// Without a record (MediaPlayer missing, AVKit publishing) no picture is fetched: nothing
    /// would show it. Guards against network use for nothing.
    @Test(.timeLimit(.minutes(1))) func noPictureIsFetchedWithoutARecord() async throws {
        let media = try await TestMedia.shared.url()
        let missing = FakePublisher()
        missing.available = false
        let gate = GatedLoader()
        let controller = makeController(publisher: missing, loader: gate.loader)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: Self.metadata())
        await Self.settle()
        #expect(gate.fetchCount == 0)
        #expect(controller.artworkFetches == 0)
        controller.close()
    }

    /// A failed fetch is tried again by the next lecture of the same course (once per play).
    /// Guards against a network blip leaving the course without its picture until relaunch.
    @Test(.timeLimit(.minutes(1))) func aFailedPictureIsRetriedByTheNextPlay() async throws {
        let media = try await TestMedia.shared.url()
        let gate = GatedLoader()
        gate.answer(Self.courseA, with: .failure(URLError(.timedOut)))
        let controller = makeController(publisher: FakePublisher(), loader: gate.loader)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: Self.metadata("Uno"))
        await Self.waitUntil { gate.fetchCount == 1 && controller.artworkURL == nil }
        gate.answer(Self.courseA, with: .success(Self.png(width: 16, height: 16)))
        controller.play(media, title: "2", cookies: [], startAt: nil, recordingID: "2", metadata: Self.metadata("Due"))
        await Self.waitUntil { controller.artwork != nil }
        #expect(gate.fetchCount == 2)
        controller.close()
    }

    /// An identical record is not published twice; a seek that lands and a speed change are.
    /// Guards against redundant work on every event (R4), a Control Center timeline left at the
    /// old position after scrubbing (R6), and a stale speed (R7).
    @Test(.timeLimit(.minutes(1))) func theRecordIsRepublishedOnlyWhenItChanges() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let controller = makeController(publisher: publisher)
        controller.play(media, title: "1", cookies: [], startAt: nil, recordingID: "1", metadata: nil)
        await Self.waitUntil { controller.isCurrentItemReady }
        controller.pause()
        await Self.waitUntil { publisher.published.last?.isPlaying == false }
        await Self.settle()
        let count = publisher.published.count
        controller.selectSpeed(1)  // the speed it already has: the same record
        #expect(publisher.published.count == count)

        // The seek lands while playing: the record then says 20 s, not the old position.
        publisher.onCommand?(.play)
        await Self.waitUntil { publisher.published.last?.isPlaying == true }
        publisher.onCommand?(.seek(20))
        await Self.waitUntil { controller.pendingSeekTarget == nil && ((publisher.published.last?.elapsed ?? 0) >= 19) }
        controller.selectSpeed(2)
        #expect(publisher.published.last?.defaultRate == 2)
        controller.close()
    }

    /// A remote Play while the resume seek is under way does not start the lecture at 0: it
    /// only asks for playback once the resume lands. Guards against Control Center's play
    /// button bypassing the resume (R5).
    @Test(.timeLimit(.minutes(1))) func aRemotePlayDuringTheResumeWaitsForIt() async throws {
        let media = try await TestMedia.shared.url()
        let publisher = FakePublisher()
        let controller = makeController(publisher: publisher)
        controller.play(media, title: "1", cookies: [], startAt: 30, recordingID: "1", metadata: nil)
        #expect(controller.isResuming)
        controller.pause()
        publisher.onCommand?(.play)
        #expect(controller.player?.rate == 0)
        #expect(controller.playWhenSettled)
        await Self.waitUntil { !controller.isResuming && controller.player?.rate != 0 }
        let position = controller.player?.currentTime().seconds ?? 0
        #expect(position >= 28)
        controller.close()
    }

    /// The app never links MediaPlayer: no source imports it and neither build system links it.
    /// It is loaded with `dlopen` on the first Play (`MediaPlayerLoader`), like AVKit.
    @Test func theAppDoesNotLinkMediaPlayer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/BeepbarApp")
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let imports = text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).range(of: #"^(@\w+\s+)*import\s+(\w+\s+)?MediaPlayer\b"#, options: .regularExpression) != nil }
            #expect(!imports, "\(file.lastPathComponent) imports MediaPlayer")
        }
        #expect(!(try String(contentsOf: root.appendingPathComponent("Beepbar.xcodeproj/project.pbxproj"), encoding: .utf8)).contains("MediaPlayer"))
        #expect(!(try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)).contains("MediaPlayer"))
    }
}
