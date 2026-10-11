import AppKit
@preconcurrency import AVFoundation
import AVKit
import OSLog

/// What Recordings needs from a native player: play a lecture stream in BeepBar, close it, and
/// know whether it is showing. A protocol so the Recordings flow (issue #148, package F) can be
/// tested with a fake that never touches AVFoundation.
@MainActor protocol RecordingPlaying: AnyObject {
    /// Whether the player window currently exists.
    var isOpen: Bool { get }
    /// Plays `url` in the player window, creating it on first use and reusing it afterwards.
    /// `cookies` go with every request AVFoundation makes for the stream; empty means none.
    func play(_ url: URL, title: String, cookies: [HTTPCookie])
    /// Stops playback and releases the player and its window. Safe to call at any time.
    func close()
}

/// The native recordings player (issue #148, package C): one window with an `AVPlayerView`, the
/// same engine and controls as QuickTime.
///
/// Quiet at rest: the feature exists in memory only while it is used. `init` creates nothing;
/// the first `play` builds the window, the view and the `AVPlayer`; closing the window (from its
/// close button or through `close()`) pauses, empties the player and drops every reference, so
/// nothing of AVFoundation stays retained by BeepBar afterwards. There is no timer and no polling:
/// the only observer is a KVO on the current item's status, invalidated on every replacement
/// and on close.
///
/// Not part of the quit path: `prepareForTermination` must never reach this controller, since
/// AVFoundation teardown is exactly the kind of work the quit rules forbid there. Quitting simply
/// lets the process end with the window open.
///
/// Privacy: the stream URL carries a token, so it is never logged; at most its host.
@MainActor final class RecordingPlayerController: NSObject, RecordingPlaying, NSWindowDelegate {
    /// Called on the main actor, at most once per `play`, when that play's item fails to load
    /// (`AVPlayerItem.Status.failed`). Package F uses it to fall back to the browser. Never called
    /// for an item that has been replaced, or after the player was closed. The error may carry
    /// the stream URL in its user info: callers must not log it.
    var onFailure: ((Error?) -> Void)?

    // Internal rather than private so tests can hold weak references and prove the release.
    private(set) var window: NSWindow?
    private(set) var playerView: AVPlayerView?
    private(set) var player: AVPlayer?
    /// Observes the current item's status; replaced with the item, invalidated on close.
    private var statusObservation: NSKeyValueObservation?
    /// Bumped by every `play` and by every teardown. A status change hops to the main actor
    /// carrying the generation it was observed in, and is dropped if it no longer matches: a
    /// failure from a replaced item, or one that lands after close, never reaches `onFailure`.
    private(set) var generation = 0
    /// Whether `onFailure` already fired for the current generation; KVO may report `.failed`
    /// more than once, and the fallback must open the browser only once.
    private var failureReported = false
    /// How the window is brought on screen. Injected so tests never activate the test process or
    /// show windows; the app uses `bringToFront`.
    private let present: @MainActor (NSWindow) -> Void

    /// How far ahead AVFoundation may buffer. Lectures last hours: left at its default (0, meaning
    /// "let the system decide"), AVPlayer may buffer minutes of high-bitrate video ahead, which
    /// costs memory and university network for footage the student may skip. Thirty seconds
    /// still absorbs ordinary network hiccups and seeking within the buffer, while keeping memory
    /// and download proportional to what is actually watched.
    static let forwardBufferDuration: TimeInterval = 30

    private static let log = Logger(subsystem: "io.github.tvaccari.beepbar", category: "player")

    init(present: @escaping @MainActor (NSWindow) -> Void = RecordingPlayerController.bringToFront) {
        self.present = present
        super.init()
    }

    var isOpen: Bool { window != nil }

    func play(_ url: URL, title: String, cookies: [HTTPCookie]) {
        Self.log.notice("Playing a recording from \(url.host ?? "-", privacy: .public)")
        let player = self.player ?? makePlayerAndWindow()
        window?.title = title

        statusObservation?.invalidate()
        statusObservation = nil
        generation += 1
        failureReported = false

        let asset = AVURLAsset(url: url, options: Self.assetOptions(cookies: cookies))
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Self.forwardBufferDuration
        let observedGeneration = generation
        // KVO delivers on whatever thread AVFoundation changes the status on: read the values
        // there, then hop to the main actor, where the generation check rejects stale results.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            Task { @MainActor [weak self] in
                self?.itemFailed(generation: observedGeneration, error: error)
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        if let window { present(window) }
    }

    func close() {
        guard let window else { return }
        // Tear down first, so the `windowWillClose` that `close()` triggers finds nothing left.
        teardown()
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        // The user closed the window: same release as `close()`. AppKit keeps the window alive
        // until the close completes, so dropping our reference here is safe.
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        teardown()
    }

    /// Activates the app and orders the window front. A menu-bar app has to activate itself first,
    /// or the window shows without focus (see `ConfigurationWindowController.show`).
    static func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The options for the stream's `AVURLAsset`: the cookies only when there are some, so a
    /// stream that needs none is requested exactly as a plain URL would be.
    nonisolated static func assetOptions(cookies: [HTTPCookie]) -> [String: Any]? {
        cookies.isEmpty ? nil : [AVURLAssetHTTPCookiesKey: cookies]
    }

    // MARK: Private

    private func makePlayerAndWindow() -> AVPlayer {
        let player = AVPlayer()
        // Left at its default (true): AVPlayer waits for enough data before starting or resuming,
        // which suits network streams; it works together with the bounded forward buffer.
        player.automaticallyWaitsToMinimizeStalling = true
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.controlsStyle = .floating
        view.player = player
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        // We own the window's lifetime: AppKit releasing it on close as well would double-release.
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = view
        window.delegate = self
        window.center()
        self.player = player
        self.playerView = view
        self.window = window
        return player
    }

    /// Releases everything `play` created. Idempotent: a second call finds nothing to release.
    private func teardown() {
        generation += 1
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView?.player = nil
        window?.contentView = nil
        window?.delegate = nil
        player = nil
        playerView = nil
        window = nil
    }

    /// Where a `.failed` status lands once on the main actor. Internal so tests can deliver a
    /// report late, after a replacement or a close: a replaced or closed item stops loading, so
    /// AVFoundation never produces that late report on demand.
    func itemFailed(generation observed: Int, error: Error?) {
        guard observed == generation, !failureReported else { return }
        failureReported = true
        Self.log.error("Recording playback failed")
        onFailure?(error)
    }
}
