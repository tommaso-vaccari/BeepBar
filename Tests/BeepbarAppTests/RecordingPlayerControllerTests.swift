import AppKit
@preconcurrency import AVFoundation
import AVKit
import Foundation
import Testing
@testable import BeepbarApp

/// The native recordings player (issue #148, package C). The player must exist only while it is
/// used (quiet at rest), keep a single window, and report a failed stream exactly once so the
/// Recordings flow can fall back to the browser. Every test injects a `present` that does
/// nothing, so no window reaches the screen and the test process is never activated.
@MainActor
@Suite(.serialized)
struct RecordingPlayerControllerTests {
    private func makeController() -> RecordingPlayerController {
        RecordingPlayerController(present: { _ in })
    }

    /// `init` creates nothing: no window, view or AVPlayer until the first Play. Guards against
    /// building the player eagerly, which would cost memory for every user at launch.
    @Test func initCreatesNothing() {
        let controller = makeController()
        #expect(controller.isOpen == false)
        #expect(controller.window == nil)
        #expect(controller.playerView == nil)
        #expect(controller.player == nil)
    }

    /// Play opens one window titled after the recording, with the player attached to its view; a
    /// second Play reuses that window and player and only replaces the item and the title. Guards
    /// against a second window (two lectures playing at once) or a leaked first player.
    @Test func aSecondPlayReusesTheWindowAndReplacesTheItem() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        controller.play(media, title: "Lezione 1", cookies: [])
        let window = try #require(controller.window)
        let player = try #require(controller.player)
        let firstItem = try #require(player.currentItem)
        #expect(controller.isOpen)
        #expect(window.title == "Lezione 1")
        #expect(window.contentView === controller.playerView)
        #expect(controller.playerView?.player === player)
        #expect(firstItem.preferredForwardBufferDuration == RecordingPlayerController.forwardBufferDuration)

        controller.play(media, title: "Lezione 2", cookies: [])
        #expect(controller.window === window)
        #expect(controller.player === player)
        #expect(player.currentItem !== firstItem)
        #expect(player.currentItem != nil)
        #expect(window.title == "Lezione 2")
        controller.close()
    }

    /// `close()` releases the AVPlayer, its view and the window, and is idempotent. Guards against
    /// a closed player keeping AVFoundation (and its buffers) alive at rest.
    @Test func closeReleasesEverythingAndIsIdempotent() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        weak var weakPlayer: AVPlayer?
        weak var weakView: AVPlayerView?
        weak var weakWindow: NSWindow?
        weak var weakItem: AVPlayerItem?
        autoreleasepool {
            controller.play(media, title: "Lezione", cookies: [])
            weakPlayer = controller.player
            weakView = controller.playerView
            weakWindow = controller.window
            weakItem = controller.player?.currentItem
            controller.close()
        }
        #expect(controller.isOpen == false)
        controller.close()
        #expect(controller.isOpen == false)
        try await Self.expectReleased { weakPlayer == nil && weakView == nil && weakWindow == nil && weakItem == nil }
    }

    /// The user closing the window (its close button ends in `windowWillClose`) releases exactly
    /// what `close()` does, and a later `close()` is harmless. Guards against the common path,
    /// closing with the red button, leaving the player playing or retained.
    @Test func closingTheWindowReleasesEverything() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        weak var weakPlayer: AVPlayer?
        weak var weakView: AVPlayerView?
        weak var weakWindow: NSWindow?
        autoreleasepool {
            controller.play(media, title: "Lezione", cookies: [])
            weakPlayer = controller.player
            weakView = controller.playerView
            weakWindow = controller.window
            controller.window?.close()
        }
        #expect(controller.isOpen == false)
        #expect(controller.player == nil)
        controller.close()
        try await Self.expectReleased { weakPlayer == nil && weakView == nil && weakWindow == nil }
    }

    /// Closing detaches the player from the view and the view from the window, so AVFoundation is
    /// released even while something else (AppKit's window list, a close animation) still holds
    /// the window or the view. Guards against the player's lifetime silently depending on when
    /// AppKit lets go of its views.
    @Test func closingDetachesThePlayerFromAWindowStillHeld() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        weak var weakPlayer: AVPlayer?
        var heldWindow: NSWindow?
        var heldView: AVPlayerView?
        autoreleasepool {
            controller.play(media, title: "Lezione", cookies: [])
            weakPlayer = controller.player
            heldWindow = controller.window
            heldView = controller.playerView
            controller.close()
        }
        #expect(heldView?.player == nil)
        #expect(heldWindow?.contentView == nil)
        #expect(heldWindow?.delegate == nil)
        try await Self.expectReleased { weakPlayer == nil }
        withExtendedLifetime((heldWindow, heldView)) {}
    }

    /// After closing, Play starts over with a new window and player. Guards against teardown
    /// leaving the controller unable to play again.
    @Test func playAfterCloseStartsOver() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        controller.play(media, title: "Uno", cookies: [])
        let first = controller.window
        controller.close()
        controller.play(media, title: "Due", cookies: [])
        #expect(controller.isOpen)
        #expect(controller.window != nil && controller.window !== first)
        #expect(controller.player?.currentItem != nil)
        controller.close()
    }

    /// A stream that cannot load calls `onFailure` exactly once, on the main actor. Guards
    /// against the fallback to the browser never happening, or opening twice.
    @Test(.timeLimit(.minutes(1))) func aFailingStreamReportsOnce() async throws {
        let controller = makeController()
        var failures: [Error?] = []
        controller.onFailure = { error in
            MainActor.preconditionIsolated()
            failures.append(error)
        }
        controller.play(TestMedia.missing, title: "Mancante", cookies: [])
        let item = try #require(controller.player?.currentItem)
        try await Self.waitUntil { !failures.isEmpty }
        #expect(item.status == .failed)
        // Leave room for a duplicate report to arrive.
        await Self.settle()
        #expect(failures.count == 1)
        #expect(failures.first??.localizedDescription.isEmpty == false)
        controller.close()
    }

    /// A playable file never reports a failure: the fallback opens only when needed.
    @Test(.timeLimit(.minutes(1))) func aPlayableFileDoesNotReportFailure() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        var failures = 0
        controller.onFailure = { _ in failures += 1 }
        controller.play(media, title: "Lezione", cookies: [])
        let item = try #require(controller.player?.currentItem)
        try await Self.waitUntil { item.status != .unknown }
        await Self.settle()
        #expect(item.status == .readyToPlay)
        #expect(failures == 0)
        controller.close()
    }

    /// A failure report that lands after the player was closed is dropped: closing must not open
    /// the browser behind the user's back. The report is delivered by hand, as the KVO hop would
    /// deliver it late, because a closed item stops loading and never fails on its own.
    @Test func noFailureIsReportedAfterClose() {
        let controller = makeController()
        var failures = 0
        controller.onFailure = { _ in failures += 1 }
        controller.play(TestMedia.missing, title: "Mancante", cookies: [])
        let observed = controller.generation
        controller.close()
        controller.itemFailed(generation: observed, error: nil)
        #expect(failures == 0)
    }

    /// The failure of an item that a newer Play replaced is dropped, and the current item still
    /// reports at most once: only the stream on screen may trigger the fallback, and only once.
    @Test func onlyTheCurrentItemReportsAndOnlyOnce() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        var failures = 0
        controller.onFailure = { _ in failures += 1 }
        controller.play(TestMedia.missing, title: "Mancante", cookies: [])
        let replaced = controller.generation
        controller.play(media, title: "Lezione", cookies: [])
        controller.itemFailed(generation: replaced, error: nil)
        #expect(failures == 0)
        controller.itemFailed(generation: controller.generation, error: nil)
        controller.itemFailed(generation: controller.generation, error: nil)
        #expect(failures == 1)
        controller.close()
    }

    /// Cookies reach the asset options only when there are some: a stream that needs none is
    /// requested as a plain URL, and one that needs them gets exactly the given cookies.
    @Test func cookiesGoInTheAssetOptionsOnlyWhenPresent() throws {
        #expect(RecordingPlayerController.assetOptions(cookies: []) == nil)
        let cookie = try #require(HTTPCookie(properties: [.name: "ticket", .value: "v", .domain: "example.webex.com", .path: "/"]))
        let options = try #require(RecordingPlayerController.assetOptions(cookies: [cookie]))
        #expect(options.count == 1)
        #expect((options[AVURLAssetHTTPCookiesKey] as? [HTTPCookie]) == [cookie])
    }

    // MARK: Helpers

    /// Polls `condition` on the main actor; the deadline turns a hang into a failure.
    private static func waitUntil(seconds: Double = 20, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { Issue.record("Condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Lets queued main-actor hops and KVO deliveries run, so a stray extra report would show.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<5 { await Task.yield() }
    }

    /// Releases can complete on a later run-loop turn (AVFoundation and AppKit autorelease), so
    /// let the main queue drain before deciding something leaked.
    private static func expectReleased(_ released: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !released() {
            if Date() > deadline { break }
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            await Task.yield()
        }
        #expect(released())
    }
}

/// A tiny playable MP4 written once at test time, so the tests need neither network nor a
/// checked-in binary fixture.
actor TestMedia {
    static let shared = TestMedia()
    /// A file URL that does not exist: AVFoundation fails it quickly and locally.
    static let missing = FileManager.default.temporaryDirectory.appendingPathComponent("beepbar-missing-\(UUID().uuidString).mp4")

    private var cached: URL?

    func url() async throws -> URL {
        if let cached { return cached }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("beepbar-player-\(UUID().uuidString).mp4")
        try await Self.write(to: url)
        cached = url
        return url
    }

    /// Writes ten 64×64 H.264 frames at 10 fps (one second).
    private static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 20), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
