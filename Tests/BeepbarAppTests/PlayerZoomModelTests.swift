import AppKit
@preconcurrency import AVFoundation
import Testing
@testable import BeepbarApp

/// The player zoom's pure decisions (`PlayerZoomModel`, `PlayerGestureTracker`,
/// `PlayerVideoViews`): limits, the anchor-preserving pinch, pan limits for every aspect ratio,
/// keyboard steps, resizes, bad inputs, and which events the window takes. No window, no AVKit.
private extension CGVector {
    func scaled(by factor: CGFloat) -> CGVector { CGVector(dx: dx * factor, dy: dy * factor) }
}

struct PlayerZoomModelTests {
    typealias Model = PlayerZoomModel

    static let wide = CGSize(width: 960, height: 540)
    /// A 16:9 video in a 16:9 view: it fills the view.
    static let fullVideo = Model.videoRect(presentationSize: CGSize(width: 1920, height: 1080), in: wide)

    /// Checks the invariants every state the model returns must keep (see `PlayerZoomModel`):
    /// a finite scale in 1…4, zero origin at fit, and on each axis the visible part inside the
    /// video when it fits, centred on it otherwise, and always inside the view.
    static func expectValid(_ state: PlayerZoomState, video: CGRect, _ comment: Comment? = nil,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let tolerance: CGFloat = 1e-6
        #expect(state.scale.isFinite && state.scale >= 1 && state.scale <= 4, comment, sourceLocation: sourceLocation)
        guard Model.isUsable(state.viewport) else {
            #expect(state.scale == 1 && state.origin == .zero, comment, sourceLocation: sourceLocation)
            return
        }
        if state.scale == 1 { #expect(state.origin == .zero, comment, sourceLocation: sourceLocation) }
        let visible = Model.visibleRect(state)
        let bounds = CGRect(origin: .zero, size: state.viewport)
        #expect(visible.minX >= -tolerance && visible.minY >= -tolerance, comment, sourceLocation: sourceLocation)
        #expect(visible.maxX <= bounds.maxX + tolerance && visible.maxY <= bounds.maxY + tolerance, comment, sourceLocation: sourceLocation)
        let limits = video.isEmpty || !video.width.isFinite ? bounds : video.intersection(bounds)
        for (low, high, start, length) in [(limits.minX, limits.maxX, visible.minX, visible.width),
                                          (limits.minY, limits.maxY, visible.minY, visible.height)] {
            if length <= high - low + tolerance {
                #expect(start >= low - tolerance && start + length <= high + tolerance,
                        "no empty border: \(start)+\(length) in \(low)…\(high) \(comment?.rawValue ?? "")", sourceLocation: sourceLocation)
            } else {
                #expect(abs(start + length / 2 - (low + high) / 2) < tolerance, "centred \(comment?.rawValue ?? "")", sourceLocation: sourceLocation)
            }
        }
    }

    /// The scale never leaves 1x…4x, whatever comes in, and not a number means fit. Guards
    /// against a pinch zooming out below the whole video or past the agreed 4x, and against a
    /// NaN from a bogus event poisoning the state.
    @Test func theScaleIsClampedToOneToFour() {
        #expect(Model.minimumScale == 1 && Model.maximumScale == 4)
        #expect(Model.clampedScale(0.2) == 1)
        #expect(Model.clampedScale(-3) == 1)
        #expect(Model.clampedScale(1) == 1)
        #expect(Model.clampedScale(2.5) == 2.5)
        #expect(Model.clampedScale(4) == 4)
        #expect(Model.clampedScale(4.0001) == 4)
        #expect(Model.clampedScale(.infinity) == 4)
        #expect(Model.clampedScale(-.infinity) == 1)
        #expect(Model.clampedScale(.nan) == 1)
        let start = Model.fit(Self.wide)
        let far = (0..<200).reduce(start) { state, _ in Model.magnified(state, by: 0.5, at: CGPoint(x: 100, y: 100), viewport: Self.wide, video: Self.fullVideo) }
        #expect(far.scale == 4)
        let back = (0..<200).reduce(far) { state, _ in Model.magnified(state, by: -0.5, at: CGPoint(x: 100, y: 100), viewport: Self.wide, video: Self.fullVideo) }
        #expect(back == Model.fit(Self.wide))
    }

    /// The video point under the fingers stays under the fingers while pinching, step after
    /// step, wherever the pinch is: zooming in always can (the new visible part lies inside the
    /// old one), zooming out can wherever the pan limits leave room, here around the middle of
    /// a centred zoom. Guards the core feel of the gesture: zooming toward the centre instead,
    /// or drifting, would fail.
    @Test(arguments: [CGPoint(x: 300, y: 200), CGPoint(x: 10, y: 530), CGPoint(x: 900, y: 40), CGPoint(x: 480, y: 270)])
    func aPinchKeepsThePointUnderTheFingers(anchor: CGPoint) {
        var state = Model.fit(Self.wide)
        let content = Model.contentPoint(anchor, in: state)
        for _ in 0..<15 {
            state = Model.magnified(state, by: 0.08, at: anchor, viewport: Self.wide, video: Self.fullVideo)
            let shown = Model.viewportPoint(content, in: state)
            #expect(abs(shown.x - anchor.x) < 1e-6 && abs(shown.y - anchor.y) < 1e-6, "zooming in: \(shown)")
            Self.expectValid(state, video: Self.fullVideo)
        }
        #expect(state.scale > 2.5)
        // A pinch out near the middle of a centred zoom keeps its point too.
        state = Model.zoomed(state, to: 3, at: CGPoint(x: 480, y: 270), viewport: Self.wide, video: Self.fullVideo)
        state = Model.panned(state, by: CGVector(dx: Model.visibleRect(state).midX - 480, dy: Model.visibleRect(state).midY - 270).scaled(by: state.scale),
                             viewport: Self.wide, video: Self.fullVideo)
        #expect(abs(Model.visibleRect(state).midX - 480) < 1e-6)
        let other = CGPoint(x: 520, y: 250)
        let otherContent = Model.contentPoint(other, in: state)
        for _ in 0..<5 {
            state = Model.magnified(state, by: -0.05, at: other, viewport: Self.wide, video: Self.fullVideo)
            let shown = Model.viewportPoint(otherContent, in: state)
            #expect(abs(shown.x - other.x) < 1e-6 && abs(shown.y - other.y) < 1e-6, "zooming out: \(shown)")
        }
    }

    /// Exhaustive sweep: for view shapes (wide, 4:3, portrait, tiny, extreme) and video shapes
    /// (16:9, square, 4:3, portrait, unknown), every scale (including out of range and not a
    /// number) and every pan, however far, the visible part stays inside the video where it can
    /// and is centred where it cannot. Guards the "no empty borders" rule, letterboxed and
    /// pillarboxed videos included.
    @Test func panningNeverRevealsAnEmptyBorder() {
        let viewports = [Self.wide, CGSize(width: 640, height: 480), CGSize(width: 500, height: 900),
                         CGSize(width: 1, height: 1), CGSize(width: 3000, height: 100)]
        let presentations = [CGSize(width: 1920, height: 1080), CGSize(width: 64, height: 64), CGSize(width: 1440, height: 1080),
                             CGSize(width: 1080, height: 1920), .zero]
        let scales: [CGFloat] = [1, 1.01, 1.5, 1.78, 2, 3.999, 4, 7, .nan, .infinity, -1, 0]
        let moves = [CGVector(dx: 1e6, dy: 1e6), CGVector(dx: -1e6, dy: -1e6), CGVector(dx: 1e6, dy: -1e6), CGVector(dx: 33, dy: -17),
                     CGVector(dx: CGFloat.nan, dy: 3), CGVector(dx: CGFloat.infinity, dy: 0)]
        for viewport in viewports {
            for presentation in presentations {
                let video = Model.videoRect(presentationSize: presentation, in: viewport)
                for scale in scales {
                    let zoomed = Model.zoomed(Model.fit(viewport), to: scale, at: CGPoint(x: viewport.width * 0.3, y: viewport.height * 0.8),
                                              viewport: viewport, video: video)
                    Self.expectValid(zoomed, video: video, "\(viewport) \(presentation) \(scale)")
                    for move in moves {
                        let panned = Model.panned(zoomed, by: move, viewport: viewport, video: video)
                        Self.expectValid(panned, video: video, "\(viewport) \(presentation) \(scale) \(move)")
                    }
                    for origin in [CGPoint(x: -1e6, y: 1e6), CGPoint(x: CGFloat.nan, y: 5), CGPoint(x: CGFloat.infinity, y: -CGFloat.infinity)] {
                        let forced = Model.clamped(PlayerZoomState(scale: scale, origin: origin, viewport: viewport), video: video)
                        Self.expectValid(forced, video: video, "forced \(viewport) \(presentation) \(scale) \(origin)")
                    }
                }
            }
        }
    }

    /// A square video in a wide view (pillarboxed) at 2x: horizontally the visible width (480)
    /// is shorter than the video (540), so panning is limited to the video's 210…750, never into
    /// the black side bars; at 1.5x the visible width (640) is longer, so it stays centred.
    /// Guards against clamping to the view instead of the video.
    @Test func aPillarboxedVideoPansWithinItsPicture() {
        let video = Model.videoRect(presentationSize: CGSize(width: 64, height: 64), in: Self.wide)
        #expect(video == CGRect(x: 210, y: 0, width: 540, height: 540))
        let zoomed = Model.zoomed(Model.fit(Self.wide), to: 2, at: CGPoint(x: 480, y: 270), viewport: Self.wide, video: video)
        let left = Model.panned(zoomed, by: CGVector(dx: 5000, dy: 0), viewport: Self.wide, video: video)
        #expect(abs(left.origin.x - 210) < 1e-9)
        let right = Model.panned(zoomed, by: CGVector(dx: -5000, dy: 0), viewport: Self.wide, video: video)
        #expect(abs(right.origin.x - (750 - 480)) < 1e-9)
        let low = Model.zoomed(Model.fit(Self.wide), to: 1.5, at: CGPoint(x: 0, y: 0), viewport: Self.wide, video: video)
        #expect(abs(low.origin.x - (480 - 320)) < 1e-9, "centred while the video is narrower than the screen")
        #expect(abs(Model.panned(low, by: CGVector(dx: 300, dy: 0), viewport: Self.wide, video: video).origin.x - (480 - 320)) < 1e-9)
    }

    /// Panning moves the video with the finger, divided by the scale (a drag of 100 points at 2x
    /// moves 50 points of the unzoomed view), and does nothing at fit. Guards the direction (an
    /// inverted pan would move the video away from the finger) and the scale division.
    @Test func panningFollowsTheFinger() {
        let zoomed = Model.zoomed(Model.fit(Self.wide), to: 2, at: CGPoint(x: 480, y: 270), viewport: Self.wide, video: Self.fullVideo)
        #expect(zoomed.origin == CGPoint(x: 240, y: 135))
        let moved = Model.panned(zoomed, by: CGVector(dx: 100, dy: -40), viewport: Self.wide, video: Self.fullVideo)
        #expect(moved.origin == CGPoint(x: 190, y: 155))
        let fit = Model.fit(Self.wide)
        #expect(Model.panned(fit, by: CGVector(dx: 100, dy: 100), viewport: Self.wide, video: Self.fullVideo) == fit)
    }

    /// ⌘+ / ⌘− step through multiples of 0.5 and stop at the ends; a scale left between steps by
    /// a pinch goes to the nearest step in the key's direction. Guards against ⌘+ zooming out
    /// (or ⌘− in) from an odd scale, and against stepping past 1x or 4x.
    @Test func keyboardStepsWalkHalvesAndStop() {
        let expectations: [(CGFloat, Bool, CGFloat)] = [
            (1, true, 1.5), (1.5, true, 2), (3.5, true, 4), (4, true, 4),
            (4, false, 3.5), (2, false, 1.5), (1.5, false, 1), (1, false, 1),
            (1.3, true, 1.5), (1.3, false, 1), (2.01, false, 2), (1.99, true, 2),
            (.nan, true, 1.5), (.infinity, false, 3.5), (0, false, 1),
        ]
        for (from, zoomIn, to) in expectations {
            #expect(Model.steppedScale(from: from, zoomIn: zoomIn) == to, "\(from) \(zoomIn ? "in" : "out")")
        }
        let stepped = Model.stepped(Model.fit(Self.wide), zoomIn: true, viewport: Self.wide, video: Self.fullVideo)
        #expect(stepped.scale == 1.5)
        let visible = Model.visibleRect(stepped)
        #expect(visible.midX == 480 && visible.midY == 270, "a key zooms around the centre")
        #expect(Model.stepped(stepped, zoomIn: false, viewport: Self.wide, video: Self.fullVideo) == Model.fit(Self.wide))
    }

    /// A resize (or full screen) keeps the scale and the same relative point of the video at the
    /// centre, then re-clamps to the new view and video frame; an unusable new size goes to fit,
    /// and so does a state that had no usable size. Guards against a smaller window showing
    /// empty borders, or a bigger one jumping to another part of the slide.
    @Test func aResizeKeepsTheCentreAndReclamps() {
        let zoomed = Model.zoomed(Model.fit(Self.wide), to: 2, at: CGPoint(x: 960, y: 540), viewport: Self.wide, video: Self.fullVideo)
        #expect(zoomed.origin == CGPoint(x: 480, y: 270))
        let smaller = CGSize(width: 640, height: 480)
        let video = Model.videoRect(presentationSize: CGSize(width: 1920, height: 1080), in: smaller)
        #expect(video == CGRect(x: 0, y: 60, width: 640, height: 360))
        let adapted = Model.adapted(zoomed, to: smaller, video: video)
        #expect(adapted.scale == 2 && adapted.viewport == smaller)
        #expect(adapted.origin == CGPoint(x: 320, y: 180), "x keeps the right edge; y clamped from 240 to the video's top")
        Self.expectValid(adapted, video: video)
        let centred = Model.zoomed(Model.fit(Self.wide), to: 3, at: CGPoint(x: 480, y: 270), viewport: Self.wide, video: Self.fullVideo)
        let bigger = CGSize(width: 1920, height: 1080)
        let grown = Model.adapted(centred, to: bigger, video: Model.videoRect(presentationSize: bigger, in: bigger))
        #expect(Model.visibleRect(grown).midX == 960 && Model.visibleRect(grown).midY == 540)
        #expect(Model.adapted(zoomed, to: .zero, video: .zero) == Model.fit(.zero))
        #expect(Model.adapted(zoomed, to: CGSize(width: CGFloat.nan, height: 10), video: .zero).scale == 1)
        #expect(Model.adapted(.fit, to: Self.wide, video: Self.fullVideo) == Model.fit(Self.wide))
        #expect(Model.adapted(zoomed, to: Self.wide, video: Self.fullVideo) == zoomed, "same size: unchanged")
    }

    /// Bad inputs never produce a bad state: a magnification that is not a number is ignored,
    /// one that would invert the picture goes to fit, an anchor that is not a number zooms at
    /// the centre and one outside the view is brought to its edge, a zero-size view stays at fit,
    /// and an unknown or bogus video size limits panning to the view. Guards against NaN or
    /// infinity from an event, or a window being built, reaching AVKit.
    @Test func badInputsAreHarmless() {
        let zoomed = Model.zoomed(Model.fit(Self.wide), to: 2, at: CGPoint(x: 100, y: 100), viewport: Self.wide, video: Self.fullVideo)
        #expect(Model.magnified(zoomed, by: .nan, at: CGPoint(x: 1, y: 1), viewport: Self.wide, video: Self.fullVideo) == zoomed)
        #expect(Model.magnified(zoomed, by: .infinity, at: CGPoint(x: 1, y: 1), viewport: Self.wide, video: Self.fullVideo) == zoomed)
        #expect(Model.magnified(zoomed, by: -2, at: CGPoint(x: 1, y: 1), viewport: Self.wide, video: Self.fullVideo) == Model.fit(Self.wide))
        let atNaN = Model.zoomed(Model.fit(Self.wide), to: 2, at: CGPoint(x: CGFloat.nan, y: 0), viewport: Self.wide, video: Self.fullVideo)
        #expect(Model.visibleRect(atNaN).midX == 480 && Model.visibleRect(atNaN).midY == 270)
        let outside = Model.zoomed(Model.fit(Self.wide), to: 2, at: CGPoint(x: 5000, y: -5000), viewport: Self.wide, video: Self.fullVideo)
        #expect(outside.origin == CGPoint(x: 480, y: 0))
        for size in [CGSize.zero, CGSize(width: 0, height: 500), CGSize(width: -10, height: 10), CGSize(width: CGFloat.infinity, height: 10)] {
            let state = Model.zoomed(Model.fit(size), to: 3, at: .zero, viewport: size, video: CGRect(origin: .zero, size: size))
            #expect(state.scale == 1 && state.origin == .zero, "\(size)")
        }
        let bounds = CGRect(origin: .zero, size: Self.wide)
        #expect(Model.videoRect(presentationSize: .zero, in: Self.wide) == bounds)
        #expect(Model.videoRect(presentationSize: CGSize(width: CGFloat.nan, height: 1), in: Self.wide) == bounds)
        #expect(Model.videoRect(presentationSize: CGSize(width: -4, height: 3), in: Self.wide) == bounds)
        let bogus = Model.clamped(PlayerZoomState(scale: 2, origin: CGPoint(x: 9999, y: 9999), viewport: Self.wide),
                                  video: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))
        #expect(bogus.origin == CGPoint(x: 480, y: 270))
        Self.expectValid(bogus, video: bounds)
    }

    /// The fixed point handed to AVKit's `setMagnification:centeredAtPoint:` is the video point
    /// shown at the same place before and after, so AVKit's own result equals the model even
    /// where the player cannot place the origin itself; no fixed point exists for a pure pan.
    /// Guards the formula against a sign or ratio slip.
    @Test func theFixedPointStaysPut() {
        let pairs: [(PlayerZoomState, PlayerZoomState)] = [
            (Model.fit(Self.wide), Model.zoomed(Model.fit(Self.wide), to: 2, at: CGPoint(x: 700, y: 400), viewport: Self.wide, video: Self.fullVideo)),
            (PlayerZoomState(scale: 2, origin: CGPoint(x: 100, y: 50), viewport: Self.wide), PlayerZoomState(scale: 3.5, origin: CGPoint(x: 300, y: 20), viewport: Self.wide)),
            (PlayerZoomState(scale: 4, origin: CGPoint(x: 600, y: 300), viewport: Self.wide), Model.fit(Self.wide)),
        ]
        for (old, new) in pairs {
            let fixed = try! #require(Model.fixedPoint(from: old, to: new))
            let before = Model.viewportPoint(fixed, in: old)
            let after = Model.viewportPoint(fixed, in: new)
            #expect(abs(before.x - after.x) < 1e-6 && abs(before.y - after.y) < 1e-6, "\(old) → \(new)")
        }
        let zoomed = PlayerZoomState(scale: 2, origin: CGPoint(x: 100, y: 50), viewport: Self.wide)
        #expect(Model.fixedPoint(from: zoomed, to: Model.panned(zoomed, by: CGVector(dx: 30, dy: 30), viewport: Self.wide, video: Self.fullVideo)) == nil)
    }

    /// At fit the viewport a state was computed for does not matter for what is shown, and
    /// otherwise scale and origin do. Guards the "touch AVKit only when something changes" check
    /// against skipping a real change or redoing a no-op.
    @Test func sameViewIgnoresTheViewportAtFitOnly() {
        #expect(PlayerZoomState.fit.showsSameView(as: Model.fit(Self.wide)))
        let zoomed = PlayerZoomState(scale: 2, origin: CGPoint(x: 10, y: 10), viewport: Self.wide)
        #expect(!zoomed.showsSameView(as: .fit))
        #expect(!zoomed.showsSameView(as: PlayerZoomState(scale: 2, origin: CGPoint(x: 11, y: 10), viewport: Self.wide)))
        #expect(!zoomed.showsSameView(as: PlayerZoomState(scale: 2.5, origin: CGPoint(x: 10, y: 10), viewport: Self.wide)))
        #expect(zoomed.showsSameView(as: zoomed))
        #expect(!PlayerZoomState.fit.isZoomed && zoomed.isZoomed)
    }

    // MARK: Event decisions

    /// Counts how often the window would have to hit-test.
    final class Probe {
        var answer: Bool
        var asked = 0
        init(_ answer: Bool) { self.answer = answer }
        func ask() -> Bool { asked += 1; return answer }
    }

    /// A pinch begun over the video is ours for every step until it ends, even if the fingers
    /// end up over the controls; one begun over the controls goes through for every step, even
    /// over the video; and the hit test runs only when the pinch begins. Guards "a pinch started
    /// over a control does nothing" and against a pinch changing owner half-way.
    @Test func aPinchBelongsToWhereItBegan() {
        var tracker = PlayerGestureTracker()
        let probe = Probe(true)
        let at = CGPoint(x: 10, y: 20)
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.1), phase: .began, location: at), isZoomed: false, isOverVideo: probe.ask) == .take(.magnify(0.1, at: at)))
        probe.answer = false
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.2), phase: .changed, location: at), isZoomed: true, isOverVideo: probe.ask) == .take(.magnify(0.2, at: at)))
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0), phase: .changed, location: at), isZoomed: true, isOverVideo: probe.ask) == .take(nil))
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.05), phase: .ended, location: at), isZoomed: true, isOverVideo: probe.ask) == .take(.magnify(0.05, at: at)))
        #expect(probe.asked == 1, "decided once, when the pinch began")
        #expect(tracker.pinchIsOurs == nil)

        // Begun over the controls: let through, step after step, even once over the video.
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.1), phase: .began, location: at), isZoomed: true, isOverVideo: probe.ask) == .passThrough)
        probe.answer = true
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.3), phase: .changed, location: at), isZoomed: true, isOverVideo: probe.ask) == .passThrough)
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.1), phase: .ended, location: at), isZoomed: true, isOverVideo: probe.ask) == .passThrough)
        #expect(probe.asked == 2)

        // A step whose beginning was missed is decided on its own; a phase-less one leaves nothing.
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.1), phase: .changed, location: at), isZoomed: true, isOverVideo: probe.ask) == .take(.magnify(0.1, at: at)))
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.1), phase: .ended, location: at), isZoomed: true, isOverVideo: probe.ask) == .take(.magnify(0.1, at: at)))
        #expect(tracker.handle(PlayerPointerEvent(kind: .magnify(0.1), location: at), isZoomed: true, isOverVideo: probe.ask) == .take(.magnify(0.1, at: at)))
        #expect(tracker.pinchIsOurs == nil)
    }

    /// Scrolling pans only while zoomed and over the video, with the y axis turned to "up" and
    /// wheel lines turned to points; at fit it goes through without even hit-testing (so the
    /// cost at rest is nothing), and over the controls (the volume slider scrolls) it goes
    /// through. Guards the pan direction and against scroll gestures being stolen at fit.
    @Test func scrollingPansOnlyWhileZoomedOverTheVideo() {
        var tracker = PlayerGestureTracker()
        let probe = Probe(true)
        let trackpad = PlayerPointerEvent(kind: .scroll(dx: 12, dy: 5, precise: true), phase: .changed, location: .zero)
        #expect(tracker.handle(trackpad, isZoomed: false, isOverVideo: probe.ask) == .passThrough)
        #expect(probe.asked == 0, "no hit test at fit")
        #expect(tracker.handle(trackpad, isZoomed: true, isOverVideo: probe.ask) == .take(.pan(CGVector(dx: 12, dy: -5))))
        let wheel = PlayerPointerEvent(kind: .scroll(dx: 0, dy: -2, precise: false), location: .zero)
        #expect(tracker.handle(wheel, isZoomed: true, isOverVideo: probe.ask) == .take(.pan(CGVector(dx: 0, dy: 2 * PlayerZoomModel.wheelLine))))
        probe.answer = false
        #expect(tracker.handle(trackpad, isZoomed: true, isOverVideo: probe.ask) == .passThrough)
    }

    /// A single-click press over the zoomed video is a pan drag: down, every drag (as the
    /// movement since the previous one, y up) and up are taken; after the up, drags go through
    /// again. A double click, a press at fit or over the controls go through whole, so
    /// `AVPlayerView`'s clicks and double-clicks are untouched. Guards against a stuck drag and
    /// against stealing the double click.
    @Test func aPressOverTheZoomedVideoDrags() {
        var tracker = PlayerGestureTracker()
        let probe = Probe(true)
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDown(clickCount: 1), location: CGPoint(x: 100, y: 100)), isZoomed: true, isOverVideo: probe.ask) == .take(nil))
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDragged, location: CGPoint(x: 110, y: 95)), isZoomed: true, isOverVideo: probe.ask) == .take(.pan(CGVector(dx: 10, dy: -5))))
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDragged, location: CGPoint(x: 111, y: 105)), isZoomed: true, isOverVideo: probe.ask) == .take(.pan(CGVector(dx: 1, dy: 10))))
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseUp, location: CGPoint(x: 111, y: 105)), isZoomed: true, isOverVideo: probe.ask) == .take(nil))
        #expect(tracker.dragLocation == nil)
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDragged, location: .zero), isZoomed: true, isOverVideo: probe.ask) == .passThrough)
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseUp, location: .zero), isZoomed: true, isOverVideo: probe.ask) == .passThrough)

        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDown(clickCount: 2), location: .zero), isZoomed: true, isOverVideo: probe.ask) == .passThrough)
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDragged, location: .zero), isZoomed: true, isOverVideo: probe.ask) == .passThrough)
        let asked = probe.asked
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDown(clickCount: 1), location: .zero), isZoomed: false, isOverVideo: probe.ask) == .passThrough)
        #expect(probe.asked == asked, "no hit test at fit")
        probe.answer = false
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDown(clickCount: 1), location: .zero), isZoomed: true, isOverVideo: probe.ask) == .passThrough)
        #expect(tracker.handle(PlayerPointerEvent(kind: .mouseDragged, location: CGPoint(x: 5, y: 5)), isZoomed: true, isOverVideo: probe.ask) == .passThrough)
    }

    /// Real `NSEvent`s map to what the tracker expects: a trackpad scroll's deltas (points,
    /// precise), clicks with their count, and nothing for other events. Guards against reading
    /// the wrong delta fields (`deltaX` is unscaled) or treating keys as pointer events.
    @Test func nsEventsMapToPointerEvents() throws {
        let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -50, wheel2: 30, wheel3: 0))
        let scrollEvent = try #require(NSEvent(cgEvent: scroll))
        let mapped = try #require(PlayerPointerEvent(scrollEvent))
        #expect(mapped.kind == .scroll(dx: 30, dy: -50, precise: true))
        let line = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        let lineEvent = try #require(NSEvent(cgEvent: line))
        if case .scroll(_, _, let precise)? = PlayerPointerEvent(lineEvent)?.kind {
            #expect(!precise)
        } else {
            Issue.record("a wheel line is a scroll")
        }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 3, y: 4), modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        #expect(PlayerPointerEvent(down) == PlayerPointerEvent(kind: .mouseDown(clickCount: 2), location: CGPoint(x: 3, y: 4)))
        let right = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(PlayerPointerEvent(right) == nil)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24))
        #expect(PlayerPointerEvent(key) == nil)
    }

    // MARK: Video views

    /// The video is found by its `AVPlayerLayer`, and a point counts as over the video when the
    /// hit view is the video view, inside it, one of its containers or the player view itself;
    /// never a control on another branch, nothing, or a view outside the player. Without a video
    /// view only the player view itself counts. Guards "a pinch over the controls does nothing"
    /// for a layout like `AVPlayerView`'s (video and controls on sibling branches).
    @Test @MainActor func theVideoIsTheBranchHoldingThePlayerLayer() throws {
        let player = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        player.wantsLayer = true
        let container = NSView(frame: player.bounds)
        let scrollView = NSScrollView(frame: player.bounds)
        let host = NSView(frame: player.bounds)
        host.wantsLayer = true
        host.layer?.addSublayer(AVPlayerLayer())
        let overlay = NSView(frame: host.bounds)
        host.addSubview(overlay)
        scrollView.documentView = host
        container.addSubview(scrollView)
        let controls = NSView(frame: NSRect(x: 100, y: 10, width: 200, height: 40))
        let button = NSButton(frame: NSRect(x: 10, y: 5, width: 30, height: 30))
        controls.addSubview(button)
        player.addSubview(container)
        player.addSubview(controls)

        let found = try #require(PlayerVideoViews.videoHost(in: player))
        #expect(found === host)
        for view in [host, overlay, container, scrollView, scrollView.contentView, player] {
            #expect(PlayerVideoViews.isVideo(view, in: player, videoHost: host), "\(view)")
        }
        for view in [controls, button, NSView()] {
            #expect(!PlayerVideoViews.isVideo(view, in: player, videoHost: host), "\(view)")
        }
        #expect(!PlayerVideoViews.isVideo(nil, in: player, videoHost: host))
        #expect(PlayerVideoViews.isVideo(player, in: player, videoHost: nil))
        #expect(!PlayerVideoViews.isVideo(overlay, in: player, videoHost: nil))
        #expect(PlayerVideoViews.videoClipView(in: player, videoHost: host) === scrollView.contentView)
        #expect(PlayerVideoViews.videoClipView(in: player, videoHost: nil) == nil)
        #expect(PlayerVideoViews.videoClipView(in: player, videoHost: overlay) === scrollView.contentView)
        let plain = NSView()
        plain.wantsLayer = true
        #expect(PlayerVideoViews.videoHost(in: plain) == nil)
        #expect(PlayerVideoViews.videoClipView(in: container, videoHost: container) == nil)
    }
}
