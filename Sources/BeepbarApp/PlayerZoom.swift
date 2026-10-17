import AppKit
@preconcurrency import AVFoundation
// No `import AVKit`, on purpose: see `AVKitLoader`.

/// Zoom of the lecture video in the player window (pinch, ⌘+ / ⌘− / ⌘0): what part of the video
/// is on screen, and how large.
///
/// Coordinates are the player view's own, unzoomed (points, y up, origin at the bottom left):
/// the same space as the video document inside `AVPlayerView`, whose size equals the view's
/// bounds (verified on macOS 27). At 1x the whole view is visible; at scale `s` the visible part is
/// the rectangle at `origin` with the viewport's size divided by `s`.
///
/// Never persisted: the zoom lives as long as the lecture on screen (`RecordingPlayerController`).
struct PlayerZoomState: Equatable, Sendable {
    /// 1 is fit (the whole video, as without zoom), up to `PlayerZoomModel.maximumScale`.
    var scale: CGFloat
    /// The bottom-left corner of the visible part, in unzoomed view coordinates. Always zero at 1x.
    var origin: CGPoint
    /// The player view's size the state was computed for. A different current size means the
    /// window was resized meanwhile: every operation first adapts the state (`PlayerZoomModel.adapted`).
    var viewport: CGSize

    /// Whether the video is magnified, i.e. whether drags and scrolls over it pan.
    var isZoomed: Bool { scale > PlayerZoomModel.minimumScale }

    /// Fit, for no particular viewport: the state of a new or closed player.
    static let fit = PlayerZoomState(scale: 1, origin: .zero, viewport: .zero)

    /// Whether the two states show the same thing, whatever viewport they were computed for at
    /// 1x: lets the player skip touching `AVPlayerView` when nothing visible changes.
    func showsSameView(as other: PlayerZoomState) -> Bool {
        scale == other.scale && (scale == PlayerZoomModel.minimumScale || origin == other.origin)
    }
}

/// The zoom's pure decisions: clamping the scale, the anchor-preserving pinch, pan limits,
/// keyboard steps and window resizes. Kept apart from AppKit and AVKit so Swift Testing covers
/// every boundary without a window.
///
/// Invariants every function returning a state keeps (`clamped`):
/// - the scale is finite and within `minimumScale...maximumScale`;
/// - on each axis where the visible part is not longer than the video, the visible part lies
///   inside the video: no empty border is ever panned into view;
/// - on an axis where the video is shorter than the visible part (a letterboxed video at a low
///   zoom), the visible part is centred on the video, so the borders stay symmetric as at 1x;
/// - at 1x the origin is zero.
enum PlayerZoomModel {
    /// Fit: zooming out never goes below the whole video.
    static let minimumScale: CGFloat = 1
    /// Four times is enough to read a slide's small print or a blackboard corner on a 1080p
    /// lecture; beyond it the 1080p source turns to blur, and AVKit switches to nearest-neighbour
    /// sampling at high factors anyway.
    static let maximumScale: CGFloat = 4
    /// ⌘+ / ⌘− move between multiples of this: 1, 1.5, 2 … 4 (six presses from fit to the maximum).
    static let step: CGFloat = 0.5
    /// Points one line of a classic (non-precise) scroll wheel pans; trackpads report points.
    static let wheelLine: CGFloat = 16

    /// `scale` within the allowed range; not a number means fit.
    nonisolated static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard !scale.isNaN else { return minimumScale }
        return min(max(scale, minimumScale), maximumScale)
    }

    /// Whether `size` can be zoomed into: finite and not empty (a window being built, or a
    /// minimised one, reports zero).
    nonisolated static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    /// The fit state for `viewport`.
    nonisolated static func fit(_ viewport: CGSize) -> PlayerZoomState {
        PlayerZoomState(scale: minimumScale, origin: .zero, viewport: viewport)
    }

    /// Where the video sits in the unzoomed view: `presentationSize` fitted inside `viewport` and
    /// centred, as `AVPlayerView` shows it (aspect fit, its default gravity). The whole viewport
    /// when the size is unknown (the item is still loading): panning is then limited only by the
    /// view, and tightened when the item is ready.
    nonisolated static func videoRect(presentationSize: CGSize, in viewport: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: viewport)
        guard isUsable(viewport), isUsable(presentationSize) else { return bounds }
        let fit = min(viewport.width / presentationSize.width, viewport.height / presentationSize.height)
        let size = CGSize(width: presentationSize.width * fit, height: presentationSize.height * fit)
        return CGRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The part of the unzoomed view on screen.
    nonisolated static func visibleRect(_ state: PlayerZoomState) -> CGRect {
        CGRect(x: state.origin.x, y: state.origin.y,
               width: state.viewport.width / state.scale, height: state.viewport.height / state.scale)
    }

    /// The unzoomed view point shown at `viewportPoint` on screen.
    nonisolated static func contentPoint(_ viewportPoint: CGPoint, in state: PlayerZoomState) -> CGPoint {
        CGPoint(x: state.origin.x + viewportPoint.x / state.scale, y: state.origin.y + viewportPoint.y / state.scale)
    }

    /// Where on screen the unzoomed view point `contentPoint` is shown.
    nonisolated static func viewportPoint(_ contentPoint: CGPoint, in state: PlayerZoomState) -> CGPoint {
        CGPoint(x: (contentPoint.x - state.origin.x) * state.scale, y: (contentPoint.y - state.origin.y) * state.scale)
    }

    /// `state` brought within the invariants above for its own viewport and `video`. A video rect
    /// that is not finite, or not inside the view, is replaced by the whole view.
    nonisolated static func clamped(_ state: PlayerZoomState, video: CGRect) -> PlayerZoomState {
        let viewport = state.viewport
        guard isUsable(viewport) else { return fit(viewport) }
        let scale = clampedScale(state.scale)
        guard scale > minimumScale else { return fit(viewport) }
        let bounds = CGRect(origin: .zero, size: viewport)
        let finite = [video.minX, video.minY, video.width, video.height].allSatisfy(\.isFinite)
        let limits = finite && !video.isEmpty ? video.standardized.intersection(bounds) : bounds
        let area = limits.isNull || limits.isEmpty ? bounds : limits
        let width = viewport.width / scale
        let height = viewport.height / scale
        let x = axis(state.origin.x, length: width, low: area.minX, high: area.maxX)
        let y = axis(state.origin.y, length: height, low: area.minY, high: area.maxY)
        return PlayerZoomState(scale: scale, origin: CGPoint(x: x, y: y), viewport: viewport)
    }

    /// One axis of `clamped`: inside `low...high` when the visible length fits, centred
    /// otherwise; a non-finite origin is centred too.
    private nonisolated static func axis(_ origin: CGFloat, length: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        let centred = (low + high - length) / 2
        // A hair of tolerance: a video exactly as long as the visible part must not flip to the
        // centring branch over a rounding error, nor be clamped against a negative range.
        guard length <= high - low + 1e-9, origin.isFinite else { return centred }
        return min(max(origin, low), max(low, high - length))
    }

    /// `state` moved to `viewport` (the window was resized, or entered or left full screen): same
    /// scale, the same point of the video kept at the centre of the screen, in proportion to the
    /// view's size, then clamped. A state for an unusable viewport starts from fit.
    nonisolated static func adapted(_ state: PlayerZoomState, to viewport: CGSize, video: CGRect) -> PlayerZoomState {
        guard isUsable(viewport) else { return fit(viewport) }
        guard state.viewport != viewport else { return clamped(state, video: video) }
        guard isUsable(state.viewport), state.scale.isFinite, state.scale > minimumScale else { return fit(viewport) }
        let visible = visibleRect(state)
        let relativeX = visible.midX / state.viewport.width
        let relativeY = visible.midY / state.viewport.height
        let scale = clampedScale(state.scale)
        let origin = CGPoint(x: relativeX * viewport.width - viewport.width / scale / 2,
                             y: relativeY * viewport.height - viewport.height / scale / 2)
        return clamped(PlayerZoomState(scale: scale, origin: origin, viewport: viewport), video: video)
    }

    /// Zooms to `scale` keeping the video point under `anchor` (a point on screen, in the view's
    /// coordinates) where it is, as far as the pan limits allow. An anchor that is not finite
    /// zooms around the centre; one outside the view is brought to its edge.
    nonisolated static func zoomed(_ state: PlayerZoomState, to scale: CGFloat, at anchor: CGPoint,
                                   viewport: CGSize, video: CGRect) -> PlayerZoomState {
        let current = adapted(state, to: viewport, video: video)
        guard isUsable(viewport) else { return current }
        let target = clampedScale(scale)
        let point: CGPoint
        if anchor.x.isFinite, anchor.y.isFinite {
            point = CGPoint(x: min(max(anchor.x, 0), viewport.width), y: min(max(anchor.y, 0), viewport.height))
        } else {
            point = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        }
        let content = contentPoint(point, in: current)
        let origin = CGPoint(x: content.x - point.x / target, y: content.y - point.y / target)
        return clamped(PlayerZoomState(scale: target, origin: origin, viewport: viewport), video: video)
    }

    /// One step of a pinch: AppKit reports each magnify event as a relative change, the new scale
    /// being the old times `1 + magnification` (as `NSScrollView` applies it). A change that is
    /// not finite is ignored; one that would invert the image goes to fit.
    nonisolated static func magnified(_ state: PlayerZoomState, by magnification: CGFloat, at anchor: CGPoint,
                                      viewport: CGSize, video: CGRect) -> PlayerZoomState {
        let current = adapted(state, to: viewport, video: video)
        guard magnification.isFinite else { return current }
        return zoomed(current, to: current.scale * max(0, 1 + magnification), at: anchor, viewport: viewport, video: video)
    }

    /// The next keyboard step from `scale`: the next multiple of `step` above (`zoomIn`) or below,
    /// within the range. A scale between two steps (left by a pinch) goes to the nearest one in
    /// that direction, so ⌘+ never zooms out and ⌘− never in.
    nonisolated static func steppedScale(from scale: CGFloat, zoomIn: Bool) -> CGFloat {
        let current = clampedScale(scale)
        let index = current / step
        let next = zoomIn ? (index + 1e-6).rounded(.down) + 1 : (index - 1e-6).rounded(.up) - 1
        return clampedScale(next * step)
    }

    /// ⌘+ / ⌘−: one step, around the centre of the screen (a key has no pointer to zoom at).
    nonisolated static func stepped(_ state: PlayerZoomState, zoomIn: Bool, viewport: CGSize, video: CGRect) -> PlayerZoomState {
        let current = adapted(state, to: viewport, video: video)
        return zoomed(current, to: steppedScale(from: current.scale, zoomIn: zoomIn),
                      at: CGPoint(x: viewport.width / 2, y: viewport.height / 2), viewport: viewport, video: video)
    }

    /// Pans by `movement`: how far the video should move on screen, in points, y up (a drag's
    /// movement, or a scroll's), so the video follows the finger. Nothing moves at 1x.
    nonisolated static func panned(_ state: PlayerZoomState, by movement: CGVector, viewport: CGSize, video: CGRect) -> PlayerZoomState {
        let current = adapted(state, to: viewport, video: video)
        guard current.isZoomed, movement.dx.isFinite, movement.dy.isFinite else { return current }
        let origin = CGPoint(x: current.origin.x - movement.dx / current.scale, y: current.origin.y - movement.dy / current.scale)
        return clamped(PlayerZoomState(scale: current.scale, origin: origin, viewport: viewport), video: video)
    }

    /// The video point that stays put on screen when going from `old` to `new` (both for the same
    /// viewport): what `-[AVPlayerView setMagnification:centeredAtPoint:]` takes, since it keeps
    /// the given point where it is, as `NSScrollView` does (verified on macOS 27). Nil when the
    /// scale does not change (a pure pan has no fixed point). Used so that, even where the
    /// player cannot reach AVKit's internal scroll view to place the origin itself, AVKit's own
    /// result matches the model.
    nonisolated static func fixedPoint(from old: PlayerZoomState, to new: PlayerZoomState) -> CGPoint? {
        guard old.scale.isFinite, new.scale.isFinite, new.scale > 0 else { return nil }
        let ratio = old.scale / new.scale
        guard abs(1 - ratio) > 1e-9 else { return nil }
        return CGPoint(x: (new.origin.x - old.origin.x * ratio) / (1 - ratio),
                       y: (new.origin.y - old.origin.y * ratio) / (1 - ratio))
    }
}

/// A zoom request the window hands to the controller, through a main-actor hop.
enum PlayerZoomInput: Equatable, Sendable {
    /// A pinch step: `1 + magnification` times the current scale, around `location` (window
    /// coordinates).
    case magnify(CGFloat, at: CGPoint)
    /// Move the video on screen by this much (points, y up).
    case pan(CGVector)
}

/// The parts of a pointer event the zoom cares about, read from the `NSEvent` synchronously in
/// `sendEvent` so that the decision (`PlayerGestureTracker`) is pure and can be tested with
/// events AppKit cannot synthesise (there is no public way to build a magnify event).
struct PlayerPointerEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A pinch step, with `NSEvent.magnification`.
        case magnify(CGFloat)
        /// Scrolling: the deltas as AppKit reports them (positive y scrolls up, i.e. moves the
        /// content down), and whether they are points (trackpad) or lines (wheel).
        case scroll(dx: CGFloat, dy: CGFloat, precise: Bool)
        case mouseDown(clickCount: Int)
        case mouseDragged
        case mouseUp
    }
    enum Phase: Equatable, Sendable { case began, changed, ended, none }

    var kind: Kind
    var phase: Phase
    /// In window coordinates.
    var location: CGPoint

    /// Nil for every event the zoom ignores (keys, other buttons, moves…). Reads each property
    /// only on the event types that have it: `NSEvent.phase` or `magnification` on a mouse or
    /// key event raises an Objective-C exception, which Swift cannot catch.
    init?(_ event: NSEvent) {
        switch event.type {
        case .magnify:
            self.init(kind: .magnify(event.magnification), phase: Self.phase(of: event), location: event.locationInWindow)
        case .scrollWheel:
            // A momentum scroll (the glide after the fingers lift) has no gesture phase; it is
            // decided event by event like a wheel, which is all a scroll needs.
            self.init(kind: .scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas),
                      phase: Self.phase(of: event), location: event.locationInWindow)
        case .leftMouseDown: self.init(kind: .mouseDown(clickCount: event.clickCount), phase: .none, location: event.locationInWindow)
        case .leftMouseDragged: self.init(kind: .mouseDragged, phase: .none, location: event.locationInWindow)
        case .leftMouseUp: self.init(kind: .mouseUp, phase: .none, location: event.locationInWindow)
        default: return nil
        }
    }

    init(kind: Kind, phase: Phase = .none, location: CGPoint) {
        self.kind = kind
        self.phase = phase
        self.location = location
    }

    /// The gesture phase of a magnify or scroll event (only those may be asked).
    private static func phase(of event: NSEvent) -> Phase {
        let phase = event.phase
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        return .none
    }
}

/// Decides, event by event, whether the player window takes a pointer event for the zoom or lets
/// it through to `AVPlayerView`. Pure: what the window knows of the view (zoomed, and whether a
/// point is over the video rather than the controls) comes in as arguments.
///
/// - A pinch belongs to whoever is under the fingers when it begins: over the video it zooms,
///   for every step until it ends; begun over the controls it is let through, every step,
///   even if the fingers drift onto the video (AVKit ignores it: its own magnification is off).
/// - Scrolling over the video pans only while zoomed; at 1x, and over the controls (the volume
///   slider scrolls), it goes through as before.
/// - A single-click press over the zoomed video is a pan drag: down, drags and up are all taken,
///   so AVKit sees neither half of the click. A double click goes through whole, so
///   `AVPlayerView`'s own double-click behaviour is unchanged; at 1x nothing is taken.
struct PlayerGestureTracker: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case passThrough
        /// Taken: the window does not forward the event; the input, if any, goes to the
        /// controller through a hop.
        case take(PlayerZoomInput?)
    }

    /// The pinch under way: true when it zooms, false when it was let through, nil when none.
    private(set) var pinchIsOurs: Bool?
    /// Where the pan drag under way last was, nil when none.
    private(set) var dragLocation: CGPoint?

    /// `isOverVideo` is evaluated only for the events that need it (a pinch beginning, a scroll or
    /// a press while zoomed), so the window hit-tests only then.
    mutating func handle(_ event: PlayerPointerEvent, isZoomed: Bool, isOverVideo: () -> Bool) -> Action {
        switch event.kind {
        case .magnify(let magnification):
            let ours: Bool
            if event.phase == .began || pinchIsOurs == nil {
                ours = isOverVideo()
            } else {
                ours = pinchIsOurs ?? false
            }
            // A phase-less event (no gesture around it) is decided on its own and leaves nothing.
            pinchIsOurs = event.phase == .ended || event.phase == .none ? nil : ours
            guard ours else { return .passThrough }
            return .take(magnification == 0 ? nil : .magnify(magnification, at: event.location))
        case .scroll(let dx, let dy, let precise):
            guard isZoomed, isOverVideo() else { return .passThrough }
            let unit = precise ? 1 : PlayerZoomModel.wheelLine
            // AppKit's positive y scrolls up, which moves the content down: y up is the opposite.
            return .take(.pan(CGVector(dx: dx * unit, dy: -dy * unit)))
        case .mouseDown(let clickCount):
            dragLocation = nil
            guard isZoomed, clickCount == 1, isOverVideo() else { return .passThrough }
            dragLocation = event.location
            return .take(nil)
        case .mouseDragged:
            guard let last = dragLocation else { return .passThrough }
            dragLocation = event.location
            return .take(.pan(CGVector(dx: event.location.x - last.x, dy: event.location.y - last.y)))
        case .mouseUp:
            guard dragLocation != nil else { return .passThrough }
            dragLocation = nil
            return .take(nil)
        }
    }
}

/// Finds the video inside `AVPlayerView` with public API only, for the window's "is this point
/// over the video or over the controls" and for the controller's pan.
///
/// `AVPlayerView` is loaded at runtime (`AVKitLoader`) and its subviews are private, so nothing
/// here names an AVKit class. The video is recognised by what it displays: the view whose layer
/// holds the `AVPlayerLayer` (an AVFoundation class, linked normally). The controls live on a
/// different branch of the view tree, so a point is over the video when the view
/// AppKit would hand the event to is that view, one of its descendants (Live Text overlays), or
/// one of its ancestors (containers hit only where nothing else is). Verified on macOS 27: the
/// play button, scrubber, volume slider and the panel's background are all on the other branch,
/// with the floating panel and with the inline bar the player uses now (its bottom bar and its
/// two top-corner pills sit in the same sibling container as the floating panel did).
enum PlayerVideoViews {
    /// The view displaying the video in `playerView`, nil when there is none (no player yet, or a
    /// test view without one).
    ///
    /// Walks the views, and for each the layers it owns (its layer and their sublayers, stopping at
    /// another view's layer), rather than the layer tree from the top: AppKit assembles a parent's
    /// layer tree lazily, so a view's player layer can exist before the parent lists it. A few
    /// hundred views and layers, and only when the cached view is gone.
    @MainActor static func videoHost(in playerView: NSView) -> NSView? {
        if let layer = playerView.layer, holdsPlayerLayer(layer, owner: playerView) { return playerView }
        for subview in playerView.subviews {
            if let found = videoHost(in: subview) { return found }
        }
        return nil
    }

    @MainActor private static func holdsPlayerLayer(_ layer: CALayer, owner: NSView) -> Bool {
        if layer is AVPlayerLayer { return true }
        for sublayer in layer.sublayers ?? [] {
            // Another view's layer belongs to that view, which `videoHost` visits on its own.
            if let view = sublayer.delegate as? NSView, view !== owner { continue }
            if holdsPlayerLayer(sublayer, owner: owner) { return true }
        }
        return false
    }

    /// Whether `hit` (the view `hitTest` returns at a point) means the point is over the video.
    /// The player view itself counts (nothing above it there: a plain test view, or AVKit before
    /// its subviews exist). Without a video host only that holds, so on an AVKit whose layout
    /// this does not recognise the zoom stays off rather than stealing the controls' gestures.
    @MainActor static func isVideo(_ hit: NSView?, in playerView: NSView, videoHost: NSView?) -> Bool {
        guard let hit, hit.isDescendant(of: playerView) else { return false }
        if hit === playerView { return true }
        guard let videoHost else { return false }
        return hit.isDescendant(of: videoHost) || videoHost.isDescendant(of: hit)
    }

    /// The clip view of the scroll view `AVPlayerView` magnifies the video in (it builds one on
    /// the first magnification, its documented behaviour "matches NSScrollView"), or nil. Its
    /// bounds origin is the visible part's origin, which is how the player pans: AVKit has no
    /// public pan API.
    @MainActor static func videoClipView(in playerView: NSView, videoHost: NSView?) -> NSClipView? {
        var view = videoHost?.superview
        while let current = view, current !== playerView {
            if let scrollView = current as? NSScrollView { return scrollView.contentView }
            view = current.superview
        }
        return nil
    }
}
