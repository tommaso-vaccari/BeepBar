import AppKit
@preconcurrency import AVFoundation
import BeepbarCore
import Foundation
import Testing
@testable import BeepbarApp

/// A player view laid out like `AVPlayerView` on macOS 27, without AVKit: the video view (which
/// holds an `AVPlayerLayer`) as the document of a scroll view that magnifies it, and a control
/// on a sibling branch above. `setMagnification:centeredAtPoint:` is the one AVKit method the
/// zoom calls; here it records the call and magnifies the scroll view, as AVKit does.
final class FakeZoomingPlayerView: NSView {
    @objc dynamic var player: AVPlayer?
    let scrollView = NSScrollView()
    let videoView = NSView()
    let control = NSButton(title: "Play", target: nil, action: nil)
    private(set) var magnifications: [(scale: CGFloat, point: CGPoint)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        videoView.wantsLayer = true
        videoView.layer?.addSublayer(AVPlayerLayer())
        scrollView.documentView = videoView
        scrollView.maxMagnification = 64
        addSubview(scrollView)
        addSubview(control)
        layoutParts()
    }

    required init?(coder: NSCoder) { nil }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 960, height: 540)) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    /// AVKit's document has the view's size, whatever the magnification.
    private func layoutParts() {
        scrollView.frame = bounds
        videoView.frame = bounds
        control.frame = NSRect(x: bounds.midX - 40, y: 20, width: 80, height: 30)
    }

    @objc(setMagnification:centeredAtPoint:) func setMagnification(_ magnification: CGFloat, centeredAt point: CGPoint) {
        magnifications.append((magnification, point))
        scrollView.setMagnification(magnification, centeredAt: point)
    }
}

/// The zoom in the real controller and window: shortcuts through the window's key handling, the
/// pinch and pans through its pointer handling, what reaches the video view, the zoom's lifetime
/// across pause, failure, recovery, another lecture and close, resizes, cost at rest, the menu,
/// and the real `AVPlayerView`. Nothing is shown, the activation policy is faked, defaults are
/// throwaway (the same rules as `RecordingPlayerMVPTests`).
@MainActor
@Suite(.serialized)
struct PlayerZoomControllerTests {
    @MainActor final class Recorder {
        var failures: [RecordingPlaybackFailure] = []
        var checkpoints: [RecordingCheckpoint] = []
    }

    private func makeController(defaults: UserDefaults = PlayerTestDefaults.throwaway(),
                                makePlayerView: @escaping @MainActor () -> NSView? = { FakeZoomingPlayerView() },
                                makePlayer: @escaping @MainActor () -> AVPlayer = { AVPlayer() },
                                notificationCenter: NotificationCenter = .default,
                                recorder: Recorder? = nil) -> RecordingPlayerController {
        let policy = ActivationPolicyControl(current: { .regular }, set: { _ in })
        let controller = RecordingPlayerController(present: { _ in }, makePlayerView: makePlayerView, makePlayer: makePlayer,
                                                   activationPolicy: policy, frameAutosaveName: nil, defaults: defaults,
                                                   notificationCenter: notificationCenter, toggleFullScreen: { _ in },
                                                   nowPlaying: SilentNowPlaying())
        if let recorder {
            controller.onFailure = { _, failure in recorder.failures.append(failure) }
            controller.onPositionCheckpoint = { recorder.checkpoints.append($0) }
        }
        return controller
    }

    private func playReady(_ controller: RecordingPlayerController, id: String = "Lezione", startAt: TimeInterval? = nil) async throws {
        let media = try await TestMedia.shared.url()
        controller.play(media, title: id, cookies: [], startAt: startAt, recordingID: id, metadata: nil)
        try await Self.waitUntil { controller.isStartSettled }
    }

    private func parts(_ controller: RecordingPlayerController) throws -> (RecordingPlayerWindow, FakeZoomingPlayerView) {
        (try #require(controller.window as? RecordingPlayerWindow), try #require(controller.playerView as? FakeZoomingPlayerView))
    }

    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16, window: NSWindow, repeated: Bool = false,
                     windowNumber: Int? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: windowNumber ?? window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: keyCode)!
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// The part of the video on screen is where the controller's zoom says: the scroll view's
    /// magnification and its clip origin.
    private func expectShown(_ controller: RecordingPlayerController, in view: FakeZoomingPlayerView,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(view.scrollView.magnification - controller.zoom.scale) < 1e-6, sourceLocation: sourceLocation)
        if controller.zoom.isZoomed {
            let origin = view.scrollView.contentView.bounds.origin
            #expect(abs(origin.x - controller.zoom.origin.x) < 1e-6 && abs(origin.y - controller.zoom.origin.y) < 1e-6,
                    "clip at \(origin), model at \(controller.zoom.origin)", sourceLocation: sourceLocation)
        }
    }

    /// ⌘= / ⌘- / ⌘0 reach the zoom through the window's key-equivalent path (where AppKit sends
    /// ⌘ chords first) and through `sendEvent`, only inside the main-actor hop (never in the
    /// AppKit callback), stepping by 0.5, repeating while held, and fitting again; each change
    /// reaches AVKit's magnification and the clip origin. A chord typed in another window (the
    /// Settings window, say) is not taken. Guards the shortcut wiring, the hop rule, and that
    /// ⌘W and other windows' chords stay untaken.
    @Test func zoomKeysStepThroughTheWindow() async throws {
        let controller = makeController()
        try await playReady(controller)
        let (window, view) = try parts(controller)

        #expect(window.performKeyEquivalent(with: key("=", [.command], keyCode: 24, window: window)))
        #expect(controller.zoom.scale == 1, "acted inside the AppKit callback")
        await Self.drainHops()
        #expect(controller.zoom.scale == 1.5)
        #expect(view.magnifications.last?.scale == 1.5)
        #expect(window.isVideoZoomed)
        expectShown(controller, in: view)

        window.sendEvent(key("=", [.command], keyCode: 24, window: window))
        await Self.drainHops()
        #expect(controller.zoom.scale == 2)
        window.sendEvent(key("=", [.command], keyCode: 24, window: window, repeated: true))
        await Self.drainHops()
        #expect(controller.zoom.scale == 2.5, "a held ⌘= keeps zooming")
        #expect(window.performKeyEquivalent(with: key("-", [.command], keyCode: 27, window: window)))
        await Self.drainHops()
        #expect(controller.zoom.scale == 2)
        expectShown(controller, in: view)

        #expect(window.performKeyEquivalent(with: key("0", [.command], keyCode: 29, window: window)))
        await Self.drainHops()
        #expect(controller.zoom.scale == 1 && controller.zoom.origin == .zero)
        #expect(view.magnifications.last?.scale == 1)
        #expect(!window.isVideoZoomed)
        expectShown(controller, in: view)
        #expect(RecordingPlayerPolicy.keyDecision(for: key("w", [.command], keyCode: 13, window: window)) == nil)
        #expect(!window.performKeyEquivalent(with: key("=", [.command], keyCode: 24, window: window, windowNumber: window.windowNumber + 4242)))
        await Self.drainHops()
        #expect(controller.zoom.scale == 1, "another window's ⌘= does not zoom the lecture")
        controller.close()
    }

    @Test func oldWindowInputsCannotControlAReopenedWindow() async throws {
        let controller = makeController()
        try await playReady(controller, id: "first")
        let (oldWindow, _) = try parts(controller)
        let oldShortcut = try #require(oldWindow.shortcutHandler)
        let oldZoom = try #require(oldWindow.zoomHandler)
        let oldSpeed = try #require(controller.speedPopUp?.menu?.items.first {
            ($0.representedObject as? NSNumber)?.floatValue == 1.5
        }?.target as? PlayerMenuAction)
        controller.close()
        try await playReady(controller, id: "second")

        oldShortcut(.zoomIn)
        oldZoom(.magnify(0.5, at: CGPoint(x: 480, y: 300)))
        #expect(controller.zoom == .fit)
        oldShortcut(.togglePlayPause)
        #expect(controller.player?.rate != 0)
        oldSpeed.invoke(nil)
        await Self.drainHops()
        #expect(controller.preferredSpeed == 1)
        let (newWindow, _) = try parts(controller)
        newWindow.shortcutHandler?(.zoomIn)
        #expect(controller.zoom.scale == 1.5)
        controller.close()
    }

    /// A pinch begun over a control does nothing, for its whole length, even when it moves onto
    /// the video; one begun over the video zooms around the fingers: the video point under them
    /// stays there, in the model and on screen. Guards "a pinch over the controls does nothing"
    /// against the real view hierarchy and hit testing, and the anchor through the window's
    /// coordinate conversion.
    @Test func aPinchZoomsAtTheFingersButNotOverAControl() async throws {
        let controller = makeController()
        try await playReady(controller)
        let (window, view) = try parts(controller)
        let overControl = view.convert(CGPoint(x: view.control.frame.midX, y: view.control.frame.midY), to: nil)
        let overVideo = CGPoint(x: 480, y: 300)
        #expect(!window.isOverVideo(overControl))
        #expect(window.isOverVideo(overVideo))
        #expect(!window.isOverVideo(CGPoint(x: 5000, y: 5000)))

        #expect(!window.handlePointer(PlayerPointerEvent(kind: .magnify(0.5), phase: .began, location: overControl)))
        #expect(!window.handlePointer(PlayerPointerEvent(kind: .magnify(0.5), phase: .changed, location: overVideo)))
        #expect(!window.handlePointer(PlayerPointerEvent(kind: .magnify(0.5), phase: .ended, location: overVideo)))
        await Self.drainHops()
        #expect(controller.zoom == .fit || !controller.zoom.isZoomed)
        #expect(view.magnifications.isEmpty)

        let content = PlayerZoomModel.contentPoint(overVideo, in: PlayerZoomModel.fit(view.bounds.size))
        #expect(window.handlePointer(PlayerPointerEvent(kind: .magnify(0.5), phase: .began, location: overVideo)))
        #expect(window.handlePointer(PlayerPointerEvent(kind: .magnify(0.2), phase: .changed, location: overVideo)))
        #expect(window.handlePointer(PlayerPointerEvent(kind: .magnify(0), phase: .ended, location: overVideo)))
        #expect(!controller.zoom.isZoomed, "applied in the hop only")
        await Self.drainHops()
        #expect(abs(controller.zoom.scale - 1.8) < 1e-9)
        let shown = PlayerZoomModel.viewportPoint(content, in: controller.zoom)
        #expect(abs(shown.x - overVideo.x) < 1e-6 && abs(shown.y - overVideo.y) < 1e-6, "kept under the fingers: \(shown)")
        expectShown(controller, in: view)
        controller.close()
    }

    /// While zoomed, a drag over the video (real mouse events through `sendEvent`) pans it with
    /// the pointer and a scroll pans it too, clamped to the picture (the square fixture is
    /// pillarboxed, so never into the side bars). Whether each press is taken or forwarded is
    /// read from the window's own decision, since a window never put on screen does not deliver
    /// mouse events to its views: at fit and for a double click nothing is taken, so
    /// `AVPlayerView`'s clicks and double-click are untouched; while zoomed a single press is
    /// taken whole. Guards the drag wiring, the click pass-through and the pan limits on screen.
    @Test func dragsAndScrollsPanTheZoomedVideo() async throws {
        let controller = makeController()
        try await playReady(controller)
        let (window, view) = try parts(controller)
        let point = CGPoint(x: 480, y: 300)
        func taken(_ event: NSEvent) throws -> Bool { window.handlePointer(try #require(PlayerPointerEvent(event))) }

        #expect(try !taken(mouse(.leftMouseDown, at: point, window: window)), "at fit a press goes to the video")
        #expect(try !taken(mouse(.leftMouseDragged, at: CGPoint(x: 400, y: 300), window: window)))
        #expect(try !taken(mouse(.leftMouseUp, at: point, window: window)))
        #expect(controller.zoom.scale == 1)

        controller.handleZoomInput(.magnify(1, at: point))
        #expect(controller.zoom.scale == 2)
        let start = controller.zoom.origin
        window.sendEvent(mouse(.leftMouseDown, at: point, window: window))
        window.sendEvent(mouse(.leftMouseDragged, at: CGPoint(x: 470, y: 310), window: window))
        window.sendEvent(mouse(.leftMouseUp, at: CGPoint(x: 470, y: 310), window: window))
        await Self.drainHops()
        #expect(abs(controller.zoom.origin.x - (start.x + 5)) < 1e-9 && abs(controller.zoom.origin.y - (start.y - 5)) < 1e-9,
                "follows the pointer: \(controller.zoom.origin) from \(start)")
        #expect(window.gestures.dragLocation == nil, "the up ended the drag")
        expectShown(controller, in: view)

        #expect(try taken(mouse(.leftMouseDown, at: point, window: window)), "zoomed: a press over the video is a drag")
        #expect(try taken(mouse(.leftMouseUp, at: point, window: window)))
        #expect(try !taken(mouse(.leftMouseDown, at: point, clicks: 2, window: window)), "a double click goes through while zoomed")
        #expect(try !taken(mouse(.leftMouseUp, at: point, clicks: 2, window: window)))
        let overControl = view.convert(CGPoint(x: view.control.frame.midX, y: view.control.frame.midY), to: nil)
        #expect(try !taken(mouse(.leftMouseDown, at: overControl, window: window)), "a control's press goes to the control")

        #expect(window.handlePointer(PlayerPointerEvent(kind: .scroll(dx: 5000, dy: 0, precise: true), phase: .changed, location: point)))
        #expect(!window.handlePointer(PlayerPointerEvent(kind: .scroll(dx: 5000, dy: 0, precise: true), phase: .changed, location: overControl)))
        await Self.drainHops()
        #expect(abs(controller.zoom.origin.x - 210) < 1e-9, "stops at the picture's left edge, not the view's")
        expectShown(controller, in: view)
        controller.close()
    }

    /// The zoom belongs to the lecture: a pause, a failure mid-lecture and its recovery (a new
    /// `play` with the same recording id, resuming where it stopped) keep it, on screen too;
    /// another lecture starts at fit, at once. Guards against a recovery or a failure losing
    /// the student's zoom, and against a new lecture opening zoomed into a corner.
    @Test func theZoomStaysWithItsLecture() async throws {
        let recorder = Recorder()
        let controller = makeController(recorder: recorder)
        try await playReady(controller)
        let (_, view) = try parts(controller)
        controller.performShortcut(.zoomIn)
        controller.performShortcut(.zoomIn)
        controller.handleZoomInput(.pan(CGVector(dx: -30, dy: 40)))
        let kept = controller.zoom
        #expect(kept.scale == 2)

        controller.pause()
        await Self.settle()
        #expect(controller.zoom == kept)

        let item = try #require(controller.player?.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
        try await Self.waitUntil { !recorder.failures.isEmpty }
        #expect(controller.zoom == kept, "a failure keeps the zoom")
        let calls = view.magnifications.count

        try await playReady(controller, id: "Lezione", startAt: 20)
        #expect(controller.zoom == kept, "the recovery keeps the zoom")
        #expect(view.magnifications.count == calls, "nothing reset on screen")
        expectShown(controller, in: view)
        #expect(controller.playerView === view, "same window and view")

        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Altra", cookies: [], startAt: nil, recordingID: "Altra", metadata: nil)
        #expect(controller.zoom.scale == 1 && controller.zoom.origin == .zero, "another lecture starts at fit")
        #expect(view.magnifications.last?.scale == 1)
        #expect(view.scrollView.magnification == 1)
        #expect((controller.window as? RecordingPlayerWindow)?.isVideoZoomed == false)
        controller.close()
    }

    /// Closing forgets the zoom: the next lecture, even the same one, opens a new window at fit,
    /// and the released window stops handling zoom events. Guards against a zoom surviving the
    /// window it was shown in.
    @Test func closingForgetsTheZoom() async throws {
        let controller = makeController()
        try await playReady(controller)
        let (window, _) = try parts(controller)
        controller.performShortcut(.zoomIn)
        #expect(controller.zoom.isZoomed)
        controller.close()
        #expect(controller.zoom == .fit)
        #expect(window.zoomHandler == nil && !window.isVideoZoomed)
        #expect(!window.handlePointer(PlayerPointerEvent(kind: .magnify(1), phase: .began, location: CGPoint(x: 480, y: 300))))

        try await playReady(controller)
        let (_, view) = try parts(controller)
        #expect(controller.zoom.scale == 1)
        #expect(view.magnifications.isEmpty, "a fresh view, never touched")
        controller.close()
    }

    /// Resizing the window (as full screen does) keeps the scale and re-clamps to the new view
    /// and picture, on screen too; and a zoom made while the item was loading (no video size
    /// yet, so only the view limits it) is tightened to the picture when the item is ready.
    /// Guards the "resizing re-clamps" requirement and the re-clamp at ready after a recovery.
    @Test func resizesAndANewItemReclamp() async throws {
        let controller = makeController()
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: nil, recordingID: "Lezione", metadata: nil)
        let (window, view) = try parts(controller)
        // Before the item is ready: the whole view limits the pan, so x 50 is allowed.
        controller.handleZoomInput(.magnify(1, at: CGPoint(x: 100, y: 270)))
        #expect(controller.zoom.scale == 2 && abs(controller.zoom.origin.x - 50) < 1e-9)
        try await Self.waitUntil { controller.isStartSettled }
        await Self.drainHops()
        #expect(abs(controller.zoom.origin.x - 210) < 1e-9, "tightened to the picture once its size is known")
        expectShown(controller, in: view)

        controller.handleZoomInput(.pan(CGVector(dx: -5000, dy: -5000)))
        window.setContentSize(NSSize(width: 640, height: 480))
        await Self.drainHops()
        #expect(controller.zoom.viewport == CGSize(width: 640, height: 480))
        #expect(controller.zoom.scale == 2)
        let video = PlayerZoomModel.videoRect(presentationSize: CGSize(width: 64, height: 64), in: CGSize(width: 640, height: 480))
        PlayerZoomModelTests.expectValid(controller.zoom, video: video)
        expectShown(controller, in: view)
        controller.close()
    }

    /// The zoom costs nothing unused and stores nothing: a play at fit and a resize at fit never
    /// touch AVKit's magnification; zooming, panning and fitting again add no time observer (the
    /// player is parked, so its own count is stable), no notification observer and no defaults
    /// write. Guards the "quiet at rest" budget and "not persisted across launches".
    @Test func theZoomCostsNothingAndStoresNothing() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        let center = CountingCenter()
        var created: CountingPlayer?
        let controller = makeController(defaults: defaults, makePlayer: { let player = CountingPlayer(); created = player; return player },
                                        notificationCenter: center)
        try await playReady(controller)
        let (window, view) = try parts(controller)
        let player = try #require(created)
        player.pause()
        try await Self.waitUntil { player.active == 0 }
        await Self.settle()
        #expect(view.magnifications.isEmpty, "a play at fit does not touch AVKit")
        window.setContentSize(NSSize(width: 800, height: 450))
        await Self.drainHops()
        #expect(view.magnifications.isEmpty, "a resize at fit does nothing")

        let counts = player.counts.withLock { ($0.periodicAdded, $0.boundaryAdded, $0.removed) }
        let observers = center.active
        let writes = defaults.writes
        controller.performShortcut(.zoomIn)
        controller.handleZoomInput(.magnify(0.7, at: CGPoint(x: 300, y: 200)))
        controller.handleZoomInput(.pan(CGVector(dx: 20, dy: -20)))
        window.setContentSize(NSSize(width: 700, height: 500))
        await Self.drainHops()
        controller.performShortcut(.zoomReset)
        await Self.settle()
        #expect(player.counts.withLock { ($0.periodicAdded, $0.boundaryAdded, $0.removed) } == counts)
        #expect(center.active == observers)
        #expect(defaults.writes == writes, "nothing persisted")
        controller.close()
    }

    /// The title-bar menu lists the zoom keys and the pinch, in the current (Italian) language,
    /// from the same entries the policy tests check in both languages. Guards against the
    /// shortcuts existing without being discoverable.
    @Test func theMenuListsTheZoom() async throws {
        let controller = makeController()
        try await playReady(controller)
        let titles = try #require(controller.speedPopUp?.menu).items.map(\.title)
        for entry in RecordingPlayerPolicy.shortcutHelpEntries where ["⌘+  ⌘−", "⌘0", "Pizzica"].contains(entry.keys.italian) {
            #expect(titles.contains("\(entry.keys.italian)\t\(entry.action.italian)"), "\(entry.keys.italian)")
        }
        #expect(titles.contains("⌘0\tAdatta il video alla finestra"))
        controller.close()
    }

    /// The real `AVPlayerView` (loaded at runtime): its own pinch stays off, the zoom drives its
    /// public magnification, the video is found by its player layer inside the scroll view AVKit
    /// magnifies in, the clip origin follows the model (pan included), a point in the picture is
    /// over the video at fit and zoomed, the magnification survives the item being replaced for
    /// the same lecture (a recovery), and fitting again restores 1x. Guards every assumption
    /// made about AVKit (verified on macOS 27) against a change in a future macOS.
    @Test func theRealPlayerViewZooms() async throws {
        let controller = makeController(makePlayerView: AVKitLoader.makePlayerView)
        try await playReady(controller)
        let view = try #require(controller.playerView)
        let window = try #require(controller.window as? RecordingPlayerWindow)
        #expect((view.value(forKey: "allowsMagnification") as? Bool) == false)
        #expect(window.isOverVideo(CGPoint(x: 480, y: 500)), "at fit, before AVKit built its scroll view")
        controller.performShortcut(.zoomIn)
        controller.performShortcut(.zoomIn)
        #expect((view.value(forKey: "magnification") as? CGFloat) == 2)
        let host = try #require(PlayerVideoViews.videoHost(in: view))
        let clip = try #require(PlayerVideoViews.videoClipView(in: view, videoHost: host))
        func expectClip(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(abs(clip.bounds.origin.x - controller.zoom.origin.x) < 0.5 && abs(clip.bounds.origin.y - controller.zoom.origin.y) < 0.5,
                    "clip \(clip.bounds.origin) model \(controller.zoom.origin)", sourceLocation: sourceLocation)
            #expect(abs(clip.bounds.width - view.bounds.width / controller.zoom.scale) < 0.5, sourceLocation: sourceLocation)
        }
        expectClip()
        controller.handleZoomInput(.pan(CGVector(dx: 5000, dy: -40)))
        #expect(abs(controller.zoom.origin.x - 210) < 1e-9)
        expectClip()
        #expect(window.isOverVideo(CGPoint(x: 480, y: 500)))
        let kept = controller.zoom
        try await playReady(controller, id: "Lezione", startAt: 20)
        #expect(controller.zoom == kept)
        #expect((view.value(forKey: "magnification") as? CGFloat) == 2, "AVKit keeps it across the new item")
        expectClip()
        controller.performShortcut(.zoomReset)
        #expect((view.value(forKey: "magnification") as? CGFloat) == 1)
        controller.close()
    }

    // MARK: Helpers

    private static func drainHops() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private static func waitUntil(seconds: Double = 20, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { Issue.record("Condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<5 { await Task.yield() }
    }
}
