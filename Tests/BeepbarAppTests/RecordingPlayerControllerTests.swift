import AppKit
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import BeepbarApp

/// The native recordings player (issue #148, package C). The player must exist only while it is
/// used (quiet at rest), keep a single window, stop and release everything on close, and report a
/// failed stream once, in the right phase, so the Recordings flow can resume or fall back to the
/// browser. Every test injects a `present` that does nothing and a fake activation policy, so no
/// window reaches the screen and the test process never becomes a regular, active app.
///
/// AVKit is deliberately not imported here either: the view is reached as `NSView` and through
/// key-value coding, exactly as the app does.
@MainActor
@Suite(.serialized)
struct RecordingPlayerControllerTests {
    /// Records activation-policy changes instead of applying them to the test process.
    @MainActor final class FakePolicy {
        var policy: NSApplication.ActivationPolicy
        var changes: [NSApplication.ActivationPolicy] = []
        init(_ policy: NSApplication.ActivationPolicy) { self.policy = policy }
        var control: ActivationPolicyControl {
            ActivationPolicyControl(current: { self.policy }, set: { self.policy = $0; self.changes.append($0) })
        }
    }

    /// Every controller gets throwaway defaults, so no test reads or writes the real speed
    /// preference.
    private func makeController(policy: FakePolicy = FakePolicy(.accessory),
                                makePlayerView: @escaping @MainActor () -> NSView? = AVKitLoader.makePlayerView,
                                makePlayer: @escaping @MainActor () -> AVPlayer = { AVPlayer() },
                                frameAutosaveName: String? = nil,
                                defaults: UserDefaults = PlayerTestDefaults.throwaway(),
                                notificationCenter: NotificationCenter = .default,
                                toggleFullScreen: @escaping @MainActor (NSWindow) -> Void = { _ in }) -> RecordingPlayerController {
        RecordingPlayerController(present: { _ in }, makePlayerView: makePlayerView, makePlayer: makePlayer, activationPolicy: policy.control,
                                  frameAutosaveName: frameAutosaveName, defaults: defaults, notificationCenter: notificationCenter,
                                  toggleFullScreen: toggleFullScreen, nowPlaying: SilentNowPlaying())
    }

    private static func player(of view: NSView?) -> AVPlayer? {
        view?.value(forKey: "player") as? AVPlayer
    }

    // MARK: Lifetime

    /// `init` creates nothing and changes no app state: no window, view or AVPlayer until the
    /// first Play. Guards against building the player eagerly, which would cost every user at
    /// launch.
    @Test func initCreatesNothing() {
        let policy = FakePolicy(.accessory)
        let controller = makeController(policy: policy)
        #expect(controller.isOpen == false)
        #expect(controller.window == nil)
        #expect(controller.playerView == nil)
        #expect(controller.player == nil)
        #expect(policy.changes.isEmpty)
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
        #expect(Self.player(of: controller.playerView) === player)
        #expect(firstItem.preferredForwardBufferDuration == RecordingPlayerController.forwardBufferDuration)

        controller.play(media, title: "Lezione 2", cookies: [])
        #expect(controller.window === window)
        #expect(controller.player === player)
        #expect(player.currentItem !== firstItem)
        #expect(player.currentItem != nil)
        #expect(window.title == "Lezione 2")
        controller.close()
    }

    /// macOS defaults sleep prevention off: every newly created player must opt in, including
    /// one opened after closing the previous lecture. AVFoundation owns the playback assertion.
    @Test func videoPlaybackPreventsIdleSleepAcrossReplacementAndReopen() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController(makePlayerView: { FakePlayerView() }, makePlayer: {
            let player = AVPlayer()
            player.preventsDisplaySleepDuringVideoPlayback = false
            return player
        })
        defer { controller.close() }
        controller.play(media, title: "Lezione 1", cookies: [])
        let first = try #require(controller.player)
        #expect(first.preventsDisplaySleepDuringVideoPlayback)
        controller.play(media, title: "Lezione 2", cookies: [])
        #expect(controller.player === first)
        #expect(first.preventsDisplaySleepDuringVideoPlayback)
        controller.close()
        #expect(first.rate == 0)
        #expect(first.currentItem == nil)
        controller.play(media, title: "Lezione 3", cookies: [])
        let reopened = try #require(controller.player)
        #expect(reopened !== first)
        #expect(reopened.preventsDisplaySleepDuringVideoPlayback)
    }

    /// `close()` releases the AVPlayer, its view, its item and the window, and is idempotent.
    /// Guards against a closed player keeping AVFoundation (and its buffers) alive at rest.
    @Test func closeReleasesEverythingAndIsIdempotent() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        weak var weakPlayer: AVPlayer?
        weak var weakView: NSView?
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
        weak var weakView: NSView?
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
        try await Self.expectReleased { weakPlayer == nil && weakView == nil && weakWindow == nil && controller.window == nil }
    }

    /// Closing stops playback even for a player someone else still holds: paused and emptied, so
    /// no sound or download can outlive the window. Covers both `close()` and the user closing
    /// the window. Guards against relying on deallocation alone to stop the stream.
    @Test(arguments: [false, true]) func closingStopsAPlayerStillHeld(byUser: Bool) async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        controller.play(media, title: "Lezione", cookies: [])
        let player = try #require(controller.player)
        #expect(player.rate != 0)
        if byUser { controller.window?.close() } else { controller.close() }
        #expect(player.rate == 0)
        #expect(player.currentItem == nil)
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
        var heldView: NSView?
        autoreleasepool {
            controller.play(media, title: "Lezione", cookies: [])
            weakPlayer = controller.player
            heldWindow = controller.window
            heldView = controller.playerView
            controller.close()
        }
        #expect(Self.player(of: heldView) == nil)
        #expect(heldWindow?.contentView == nil)
        #expect(heldWindow?.delegate == nil)
        try await Self.expectReleased { weakPlayer == nil }
        withExtendedLifetime((heldWindow, heldView)) {}
    }

    /// When the user closes the window, playback stops at once but the view leaves the window only
    /// on the next main-actor turn, after AppKit has finished closing it (as the configuration
    /// window does). Guards against tearing the content view out mid-close.
    @Test func aUserCloseDetachesTheViewOnTheNextTurn() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        controller.play(media, title: "Lezione", cookies: [])
        let window = try #require(controller.window)
        let view = try #require(controller.playerView)
        window.close()
        #expect(Self.player(of: view) == nil)
        #expect(window.contentView === view)
        try await Self.expectReleased { window.contentView == nil && window.delegate == nil && controller.window == nil }
    }

    /// After closing, Play starts over with a new window and player. Guards against teardown
    /// leaving the controller unable to play again.
    @Test(arguments: [false, true]) func playAfterCloseStartsOver(byUser: Bool) async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        controller.play(media, title: "Uno", cookies: [])
        let first = controller.window
        if byUser { first?.close() } else { controller.close() }
        controller.play(media, title: "Due", cookies: [])
        #expect(controller.isOpen)
        #expect(controller.window != nil && controller.window !== first)
        #expect(controller.player?.currentItem != nil)
        #expect(Self.player(of: controller.playerView) === controller.player)
        // The previous window's deferred release must not take the new one with it.
        let second = controller.window
        await Self.settle()
        #expect(controller.window != nil && controller.window === second)
        #expect(controller.playerView != nil && controller.window?.contentView === controller.playerView)
        #expect(controller.isOpen)
        controller.close()
    }

    /// The window keeps its size and position under an autosave name, and a window reopened
    /// right after the user closed the previous one still gets the name (AppKit refuses a name
    /// another live window holds). Guards against the player forgetting its frame every time.
    @Test func theWindowKeepsItsFrameAcrossOpens() async throws {
        let media = try await TestMedia.shared.url()
        let name = "BeepbarTestPlayer-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        let controller = makeController(frameAutosaveName: name)
        controller.play(media, title: "Uno", cookies: [])
        #expect(controller.window?.frameAutosaveName == name)
        controller.window?.setFrame(NSRect(x: 120, y: 140, width: 700, height: 420), display: false)
        controller.window?.close()
        controller.play(media, title: "Due", cookies: [])
        #expect(controller.window?.frameAutosaveName == name)
        #expect(controller.window?.frame.size == NSSize(width: 700, height: 420))
        controller.close()
        #expect(RecordingPlayerController.defaultFrameAutosaveName.isEmpty == false)
    }

    // MARK: Activation policy

    /// While the player is open BeepBar is a regular app (Dock icon, Cmd-Tab), and closing it,
    /// either way, returns to the menu bar. A second Play changes nothing. Guards against a lecture
    /// window that cannot be found again after switching apps, or a Dock icon left behind.
    @Test(arguments: [false, true]) func theAppIsRegularWhileThePlayerIsOpen(byUser: Bool) async throws {
        let media = try await TestMedia.shared.url()
        let policy = FakePolicy(.accessory)
        let controller = makeController(policy: policy)
        controller.play(media, title: "Uno", cookies: [])
        #expect(policy.policy == .regular)
        controller.play(media, title: "Due", cookies: [])
        #expect(policy.changes == [.regular])
        if byUser { controller.window?.close() } else { controller.close() }
        #expect(policy.policy == .accessory)
        #expect(policy.changes == [.regular, .accessory])
        controller.close()
        #expect(policy.changes == [.regular, .accessory])
    }

    /// The player restores only what it changed: an app that was already regular stays so, and a
    /// policy someone else changed in the meantime is not overwritten.
    @Test func thePlayerRestoresOnlyItsOwnPolicyChange() async throws {
        let media = try await TestMedia.shared.url()
        let alreadyRegular = FakePolicy(.regular)
        let first = makeController(policy: alreadyRegular)
        first.play(media, title: "Uno", cookies: [])
        first.close()
        #expect(alreadyRegular.changes.isEmpty)

        let changedElsewhere = FakePolicy(.accessory)
        let second = makeController(policy: changedElsewhere)
        second.play(media, title: "Uno", cookies: [])
        changedElsewhere.policy = .prohibited
        second.close()
        #expect(changedElsewhere.policy == .prohibited)
        #expect(changedElsewhere.changes == [.regular])
    }

    // MARK: Failures

    /// A stream that never becomes playable reports `.beforeReady` exactly once, on the main
    /// actor, after the player has closed its window and returned to the menu bar. Guards against
    /// the browser fallback never happening, happening twice, or leaving an empty player behind.
    @Test(.timeLimit(.minutes(1))) func aStreamThatNeverPlaysReportsBeforeReadyAndCloses() async throws {
        let policy = FakePolicy(.accessory)
        let controller = makeController(policy: policy)
        var failures: [RecordingPlaybackFailure] = []
        var openWhenReported: Bool?
        controller.onFailure = { _, failure in
            MainActor.preconditionIsolated()
            openWhenReported = controller.isOpen
            failures.append(failure)
        }
        controller.play(TestMedia.missing, title: "Mancante", cookies: [])
        try await Self.waitUntil { !failures.isEmpty }
        await Self.settle()
        #expect(failures.count == 1)
        guard case .beforeReady(let error)? = failures.first else {
            Issue.record("Expected beforeReady, got \(String(describing: failures.first))")
            return
        }
        #expect(error != nil)
        #expect(openWhenReported == false)
        #expect(controller.isOpen == false)
        #expect(controller.window == nil)
        #expect(policy.policy == .accessory)
    }

    /// AVKit failing to load is a before-ready failure: nothing is created and the browser
    /// fallback runs, once. Guards against a missing framework crashing or leaving Play silent.
    @Test(.timeLimit(.minutes(1))) func aPlayerViewThatCannotLoadReportsBeforeReady() async throws {
        let policy = FakePolicy(.accessory)
        let controller = makeController(policy: policy, makePlayerView: { nil })
        var failures: [RecordingPlaybackFailure] = []
        controller.onFailure = { failures.append($1) }
        controller.play(URL(fileURLWithPath: "/nonexistent.mp4"), title: "Lezione", cookies: [])
        #expect(failures.isEmpty, "Reported on a later turn, never from inside play")
        try await Self.waitUntil { !failures.isEmpty }
        await Self.settle()
        #expect(failures.count == 1)
        guard case .beforeReady(let error)? = failures.first else {
            Issue.record("Expected beforeReady")
            return
        }
        #expect(error is RecordingPlayerError)
        #expect(controller.isOpen == false)
        #expect(controller.window == nil)
        #expect(policy.changes.isEmpty)
    }

    /// A playable file becomes ready and never reports a failure: the fallback opens only when
    /// needed.
    @Test(.timeLimit(.minutes(1))) func aPlayableFileBecomesReadyWithoutFailure() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        var failures = 0
        controller.onFailure = { _, _ in failures += 1 }
        controller.play(media, title: "Lezione", cookies: [])
        try await Self.waitUntil { controller.isCurrentItemReady }
        await Self.settle()
        #expect(controller.player?.currentItem?.status == .readyToPlay)
        #expect(failures == 0)
        controller.close()
    }

    /// A stream that stops after it started (AVFoundation's failed-to-play-to-end notification)
    /// reports `.duringPlayback` once, with the position, and leaves the window open and paused so
    /// the caller can resume with a fresh stream URL. Guards against closing the lecture on a
    /// network blip, or missing mid-playback failures altogether.
    @Test(.timeLimit(.minutes(1))) func aFailureDuringPlaybackKeepsTheWindowPaused() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        var failures: [RecordingPlaybackFailure] = []
        controller.onFailure = { failures.append($1) }
        controller.play(media, title: "Lezione", cookies: [])
        try await Self.waitUntil { controller.isCurrentItemReady }
        let item = try #require(controller.player?.currentItem)
        let streamError = URLError(.networkConnectionLost)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: streamError])
        try await Self.waitUntil { !failures.isEmpty }
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: streamError])
        await Self.settle()
        #expect(failures.count == 1)
        guard case .duringPlayback(let error, let position)? = failures.first else {
            Issue.record("Expected duringPlayback, got \(String(describing: failures.first))")
            return
        }
        #expect((error as? URLError)?.code == .networkConnectionLost)
        #expect(position >= 0 && position.isFinite)
        #expect(controller.isOpen)
        #expect(controller.window != nil)
        #expect(controller.player?.rate == 0)
        controller.close()
    }

    /// The failed-to-play-to-end notification of an item a newer Play replaced, or of the item
    /// playing when the player was closed, is ignored: the observer belongs to the current item.
    @Test(.timeLimit(.minutes(1))) func notificationsForOldItemsAreIgnored() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        var failures = 0
        controller.onFailure = { _, _ in failures += 1 }
        controller.play(media, title: "Uno", cookies: [])
        let replaced = try #require(controller.player?.currentItem)
        controller.play(media, title: "Due", cookies: [])
        let current = try #require(controller.player?.currentItem)
        try await Self.waitUntil { controller.isCurrentItemReady }
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: replaced)
        await Self.settle()
        #expect(failures == 0)
        controller.close()
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: current)
        await Self.settle()
        #expect(failures == 0)
    }

    /// A failure report that lands after the player was closed is dropped: closing must not open
    /// the browser behind the user's back. The report is delivered by hand, as an observer hop
    /// would deliver it late, because a closed item stops loading and never fails on its own.
    @Test func noFailureIsReportedAfterClose() {
        let controller = makeController()
        var failures = 0
        controller.onFailure = { _, _ in failures += 1 }
        controller.play(TestMedia.missing, title: "Mancante", cookies: [])
        let observed = controller.generation
        controller.close()
        controller.fail(generation: observed, error: nil)
        #expect(failures == 0)
    }

    /// The failure of an item that a newer Play replaced is dropped, and the current item still
    /// reports at most once: only the stream on screen may trigger the fallback, and only once.
    @Test func onlyTheCurrentItemReportsAndOnlyOnce() async throws {
        let media = try await TestMedia.shared.url()
        let controller = makeController()
        var failures = 0
        controller.onFailure = { _, _ in failures += 1 }
        controller.play(TestMedia.missing, title: "Mancante", cookies: [])
        let replaced = controller.generation
        controller.play(media, title: "Lezione", cookies: [])
        controller.fail(generation: replaced, error: nil)
        #expect(failures == 0)
        controller.fail(generation: controller.generation, error: nil)
        controller.fail(generation: controller.generation, error: nil)
        #expect(failures == 1)
        controller.close()
    }

    // MARK: Stream options and AVKit

    /// Cookies reach the asset options only when there are some: a stream that needs none is
    /// requested as a plain URL, and one that needs them gets exactly the given cookies.
    @Test func cookiesGoInTheAssetOptionsOnlyWhenPresent() throws {
        #expect(RecordingPlayerController.assetOptions(cookies: []) == nil)
        let cookie = try #require(HTTPCookie(properties: [.name: "ticket", .value: "v", .domain: "example.webex.com", .path: "/"]))
        let options = try #require(RecordingPlayerController.assetOptions(cookies: [cookie]))
        #expect(options.count == 1)
        #expect((options[AVURLAssetHTTPCookiesKey] as? [HTTPCookie]) == [cookie])
    }

    /// The runtime loader really produces an `AVPlayerView` with floating (QuickTime-like)
    /// controls that accepts a player. Guards against a wrong path, class name or key silently
    /// turning every Play into a browser fallback.
    @Test func theRuntimeLoaderBuildsAFloatingPlayerView() throws {
        let view = try #require(AVKitLoader.makePlayerView())
        #expect(NSStringFromClass(type(of: view)) == "AVPlayerView")
        #expect(view.value(forKey: "controlsStyle") as? Int == AVKitLoader.floatingControlsStyle)
        let player = AVPlayer()
        view.setValue(player, forKey: "player")
        #expect(Self.player(of: view) === player)
        view.setValue(nil, forKey: "player")
    }

    /// The app never links AVKit: no source file imports it and neither build system links it.
    /// Linking it would make every launch load ~335 more images (see `AVKitLoader`) for users who
    /// never press Play. The Release binary was checked with `otool -L` as well.
    @Test func theAppDoesNotLinkAVKit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/BeepbarApp")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let importsAVKit = text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).range(of: #"^(@\w+\s+)*import\s+(\w+\s+)?AVKit\b"#, options: .regularExpression) != nil }
            #expect(!importsAVKit, "\(file.lastPathComponent) imports AVKit")
        }
        let project = try String(contentsOf: root.appendingPathComponent("Beepbar.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(!project.contains("AVKit"))
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!manifest.contains("AVKit"))
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

    /// Lets queued main-actor hops and observer deliveries run, so a stray extra report would
    /// show.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<5 { await Task.yield() }
    }

    /// Releases can complete on a later main-actor or run-loop turn (the deferred window release,
    /// AVFoundation and AppKit autorelease), so let the main queue drain before deciding
    /// something leaked.
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

/// A tiny playable MP4 written once per test process, so the tests need neither network nor a
/// checked-in binary fixture.
///
/// The file lives in a directory named after the test process and is deleted when the process
/// exits (`atexit`). A run that crashes leaves its directory behind, so the next run sweeps every
/// `beepbar-player-<pid>` directory whose process is gone, plus the loose
/// `beepbar-player-*.mp4` files earlier versions of this helper left in the temporary folder.
actor TestMedia {
    static let shared = TestMedia()
    /// The clip's length: long enough for ±30 s skips and resume positions to land inside it.
    static let duration: TimeInterval = 60
    /// A file URL that does not exist: AVFoundation fails it quickly and locally.
    static let missing = FileManager.default.temporaryDirectory.appendingPathComponent("beepbar-missing-\(UUID().uuidString).mp4")
    /// This process's fixture directory.
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(getpid())", isDirectory: true)
    private static let prefix = "beepbar-player-"

    /// The one write of this process. Shared rather than a cached URL: the actor is reentrant
    /// across the write's `await`, so two suites asking at once would otherwise both write the
    /// same file and the second would fail with "file name already in use".
    private var creation: Task<URL, Error>?

    func url() async throws -> URL {
        if let creation { return try await creation.value }
        let creation = Task {
            Self.sweepLeftovers()
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            atexit { try? FileManager.default.removeItem(at: TestMedia.directory) }
            let url = Self.directory.appendingPathComponent("clip.mp4")
            try? FileManager.default.removeItem(at: url)
            try await Self.write(to: url)
            return url
        }
        self.creation = creation
        return try await creation.value
    }

    /// Removes fixtures of test processes that no longer run, and legacy loose files.
    private static func sweepLeftovers() {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: temporary.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            if name.hasSuffix(".mp4") {
                try? fileManager.removeItem(at: temporary.appendingPathComponent(name))
            } else if let pid = Int32(suffix), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH {
                try? fileManager.removeItem(at: temporary.appendingPathComponent(name))
            }
        }
    }

    /// Writes sixty 64×64 H.264 frames at 1 fps: sixty seconds, so a test that checks playback
    /// was paused cannot pass because the clip simply ended, and seeks have room on both sides.
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
        for frame in 0..<Int(duration) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 4), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 1))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
