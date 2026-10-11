import AppKit
@preconcurrency import AVFoundation
import OSLog
// No `import AVKit`, on purpose: see `AVKitLoader`.

/// What Recordings needs from a native player: play a lecture stream in BeepBar, close it, and
/// know whether it is showing. A protocol so the Recordings flow (issue #148, package F) can be
/// tested with a fake that never touches AVFoundation.
@MainActor protocol RecordingPlaying: AnyObject {
    /// Whether the player is open (between a `play` and the window closing).
    var isOpen: Bool { get }
    /// Plays `url` in the player window, creating it on first use and reusing it afterwards.
    /// `cookies` go with every request AVFoundation makes for the stream; empty means none.
    func play(_ url: URL, title: String, cookies: [HTTPCookie])
    /// Stops playback and releases the player and its window. Safe to call at any time.
    func close()
}

/// How a play failed, reported once per item through `RecordingPlayerController.onFailure`.
///
/// The error may carry the stream URL (and with it the stream token) in its user info: never log
/// it, at most its domain and code.
enum RecordingPlaybackFailure {
    /// The stream never became playable (bad URL, expired token, unsupported format, or AVKit
    /// could not be loaded). The player has already closed its window; the caller falls back to
    /// the browser.
    case beforeReady(Error?)
    /// The stream had started and then stopped (network lost, token expired mid-lecture). The
    /// window stays open and paused at `position` seconds, so the caller can fetch a fresh stream
    /// URL and resume there, or offer the browser.
    case duringPlayback(Error?, position: TimeInterval)
}

/// Errors the player raises itself, as opposed to those AVFoundation reports for the stream.
enum RecordingPlayerError: Error {
    /// AVKit or its `AVPlayerView` could not be loaded at runtime.
    case playerViewUnavailable
}

/// Reads and changes the app's activation policy. Injected so tests never turn the test process
/// into a regular app, and so the interaction with other code doing the same stays explicit.
@MainActor struct ActivationPolicyControl {
    var current: @MainActor () -> NSApplication.ActivationPolicy
    var set: @MainActor (NSApplication.ActivationPolicy) -> Void

    static var application: ActivationPolicyControl {
        ActivationPolicyControl(current: { NSApp.activationPolicy() }, set: { NSApp.setActivationPolicy($0) })
    }
}

/// The native recordings player (issue #148, package C): one window with an `AVPlayerView`, the
/// same engine and controls as QuickTime.
///
/// Quiet at rest: the feature exists in memory only while it is used. `init` creates nothing and
/// AVKit is not even loaded until the first `play` (`AVKitLoader`). The first `play` builds the
/// window, the view and the `AVPlayer`; closing the window (from its close button or through
/// `close()`) pauses, empties the player and drops every reference, so nothing of AVFoundation
/// stays retained by BeepBar afterwards. There is no timer and no polling: the only observers are
/// a KVO on the current item's status and its failed-to-play-to-end notification, both removed on
/// every replacement and on close.
///
/// Not part of the quit path: `prepareForTermination` must never reach this controller, since
/// AVFoundation teardown is exactly the kind of work the quit rules forbid there. Quitting simply
/// lets the process end with the window open.
///
/// Privacy: the stream URL carries a token, so it is never logged; at most its host.
@MainActor final class RecordingPlayerController: NSObject, RecordingPlaying, NSWindowDelegate {
    /// Called on the main actor, at most once per `play`, when that play fails; see
    /// `RecordingPlaybackFailure` for what the player has already done in each phase. Never
    /// called for an item that a newer `play` replaced, or after the player was closed.
    var onFailure: ((RecordingPlaybackFailure) -> Void)?

    // Internal rather than private so tests can hold weak references and prove the release.
    private(set) var window: NSWindow?
    /// The `AVPlayerView`, typed as `NSView` because AVKit is loaded at runtime.
    private(set) var playerView: NSView?
    private(set) var player: AVPlayer?
    /// Whether the current item reached `.readyToPlay`: decides which failure phase is reported.
    private(set) var isCurrentItemReady = false
    /// Bumped by every `play` and by every teardown. Observations hop to the main actor carrying
    /// the generation they were made in, and are dropped if it no longer matches: a report from a
    /// replaced item, or one that lands after close, never reaches `onFailure`.
    private(set) var generation = 0
    /// Whether `onFailure` already fired for the current generation: the status KVO and the
    /// failed-to-play-to-end notification can both report the same failure, and the fallback must
    /// run once.
    private var failureReported = false
    private var statusObservation: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?
    /// The policy BeepBar had before the player promoted it to `.regular`; nil when the player
    /// did not change it.
    private var policyToRestore: NSApplication.ActivationPolicy?

    private let present: @MainActor (NSWindow) -> Void
    private let makePlayerView: @MainActor () -> NSView?
    private let activationPolicy: ActivationPolicyControl
    private let frameAutosaveName: String?

    /// How far ahead AVFoundation may buffer. Lectures last hours: left at its default (0, meaning
    /// "let the system decide"), AVPlayer may buffer minutes of high-bitrate video ahead, which
    /// costs memory and university network for footage the student may skip. Thirty seconds
    /// still absorbs ordinary network hiccups and seeking within the buffer, while keeping memory
    /// and download proportional to what is actually watched.
    static let forwardBufferDuration: TimeInterval = 30
    static let defaultFrameAutosaveName = "BeepbarRecordingPlayerWindow"

    private static let log = Logger(subsystem: "io.github.tvaccari.beepbar", category: "player")

    /// - Parameters:
    ///   - present: brings the window on screen; tests pass a no-op so nothing is shown and the
    ///     test process is never activated.
    ///   - makePlayerView: builds the `AVPlayerView`; tests can simulate AVKit failing to load.
    ///   - activationPolicy: see `promoteToRegularApp()`.
    ///   - frameAutosaveName: where AppKit keeps the window's size and position; nil disables it.
    init(present: @escaping @MainActor (NSWindow) -> Void = RecordingPlayerController.bringToFront,
         makePlayerView: @escaping @MainActor () -> NSView? = AVKitLoader.makePlayerView,
         activationPolicy: ActivationPolicyControl = .application,
         frameAutosaveName: String? = RecordingPlayerController.defaultFrameAutosaveName) {
        self.present = present
        self.makePlayerView = makePlayerView
        self.activationPolicy = activationPolicy
        self.frameAutosaveName = frameAutosaveName
        super.init()
    }

    var isOpen: Bool { player != nil }

    func play(_ url: URL, title: String, cookies: [HTTPCookie]) {
        Self.log.notice("Playing a recording from \(url.host ?? "-", privacy: .public)")
        removeItemObservers()
        generation += 1
        failureReported = false
        isCurrentItemReady = false
        let observedGeneration = generation

        guard let player = self.player ?? makePlayerAndWindow() else {
            Self.log.error("AVKit could not be loaded")
            // Delivered on the next main-actor turn, like every other report, so the caller is
            // never re-entered from inside its own `play` call.
            Task { @MainActor [weak self] in
                self?.fail(generation: observedGeneration, error: RecordingPlayerError.playerViewUnavailable)
            }
            return
        }
        window?.title = title

        let asset = AVURLAsset(url: url, options: Self.assetOptions(cookies: cookies))
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Self.forwardBufferDuration
        // Both observers fire on whatever thread AVFoundation uses: read the values there, then
        // hop to the main actor, where the generation check rejects stale results.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor [weak self] in
                switch status {
                case .readyToPlay: self?.itemBecameReady(generation: observedGeneration)
                case .failed: self?.fail(generation: observedGeneration, error: error)
                default: break
                }
            }
        }
        // A stream that dies after it started (network lost, token expired) does not always move
        // the item to `.failed`; AVFoundation reports it with this notification instead.
        failedToEndObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                self?.fail(generation: observedGeneration, error: error)
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        if let window { present(window) }
    }

    func close() {
        let window = self.window
        stopPlayback()
        guard let window else { return }
        Self.release(window)
        if self.window === window {
            self.window = nil
            playerView = nil
        }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // The user closed the window. Playback stops now: no sound may outlive the window.
        stopPlayback()
        // Synchronously, so a Play in the meantime can give the name to its new window: AppKit
        // refuses a name another live window still holds. The frame was saved on the last move
        // or resize, so nothing is lost.
        closing.setFrameAutosaveName("")
        // The view and the window are released on the next main-actor turn, as
        // `ConfigurationWindowController.windowWillClose` does: AppKit (and `AVPlayerView`, which
        // watches its window to leave full screen or picture in picture) is still closing this
        // window when the notification arrives, and pulling its content view out from under it
        // mid-close is not something AppKit promises to survive. A Play in between builds a new
        // window, so only this one is released.
        Task { @MainActor [weak self] in
            Self.release(closing)
            if let self, self.window === closing {
                self.window = nil
                self.playerView = nil
            }
        }
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

    /// Where a failure lands once on the main actor, from the status KVO or the
    /// failed-to-play-to-end notification. Internal so tests can deliver a report late, after a
    /// replacement or a close: a replaced or closed item stops loading, so AVFoundation never
    /// produces that late report on demand.
    func fail(generation observed: Int, error: Error?) {
        guard observed == generation, !failureReported else { return }
        failureReported = true
        if isCurrentItemReady, let player {
            // The lecture was playing: keep the window and the position, and let the caller
            // decide between a fresh stream URL and the browser.
            player.pause()
            let seconds = player.currentTime().seconds
            Self.log.error("Recording playback stopped while playing")
            onFailure?(.duringPlayback(error, position: seconds.isFinite ? seconds : 0))
        } else {
            // Nothing ever played: an empty player window is no use, so close it before the
            // caller opens the browser.
            Self.log.error("Recording playback failed before starting")
            close()
            onFailure?(.beforeReady(error))
        }
    }

    // MARK: Private

    private func itemBecameReady(generation observed: Int) {
        guard observed == generation else { return }
        isCurrentItemReady = true
    }

    private func makePlayerAndWindow() -> AVPlayer? {
        guard let view = makePlayerView() else { return nil }
        // `automaticallyWaitsToMinimizeStalling` keeps its default (true): AVPlayer waits for
        // enough data before starting or resuming, which suits network streams and works with the
        // bounded forward buffer.
        let player = AVPlayer()
        view.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        view.setValue(player, forKey: "player")
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        // We own the window's lifetime: AppKit releasing it on close as well would double-release.
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = view
        window.delegate = self
        if let frameAutosaveName {
            if !window.setFrameUsingName(frameAutosaveName) { window.center() }
            window.setFrameAutosaveName(frameAutosaveName)
        } else {
            window.center()
        }
        self.player = player
        self.playerView = view
        self.window = window
        promoteToRegularApp()
        return player
    }

    /// BeepBar is a menu-bar app (`LSUIElement`), so its windows have no Dock icon and no entry
    /// in Cmd-Tab. A lecture window the student switches away from must be easy to find again, so
    /// while it is open BeepBar runs as a regular app, as `WeBeepAuthenticationController.chooseRoot`
    /// does around its folder panel.
    ///
    /// Interaction with other code switching the policy: the player only remembers a policy it
    /// changed itself (nothing when BeepBar was already regular), and only restores it if BeepBar
    /// is still regular at close, so it never undoes a change someone else made in between.
    /// `chooseRoot` runs a modal panel that restores its own policy before returning, so the two
    /// never interleave: if the player is open, `chooseRoot` finds `.regular` and leaves it alone.
    private func promoteToRegularApp() {
        let current = activationPolicy.current()
        guard current != .regular, policyToRestore == nil else { return }
        policyToRestore = current
        activationPolicy.set(.regular)
    }

    private func restoreActivationPolicy() {
        guard let previous = policyToRestore else { return }
        policyToRestore = nil
        if activationPolicy.current() == .regular { activationPolicy.set(previous) }
    }

    private func removeItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let failedToEndObserver { NotificationCenter.default.removeObserver(failedToEndObserver) }
        failedToEndObserver = nil
    }

    /// Stops and releases the player. Idempotent: a second call finds nothing to stop. The window
    /// and view are released by the caller (`close()` now, `windowWillClose` on the next turn).
    private func stopPlayback() {
        generation += 1
        isCurrentItemReady = false
        removeItemObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView?.setValue(nil, forKey: "player")
        player = nil
        restoreActivationPolicy()
    }

    /// Detaches the view from a closing window, so nothing AVKit holds survives through it.
    private static func release(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        window.contentView = nil
        window.delegate = nil
    }
}

/// Loads AVKit only when the first recording is played.
///
/// Linking AVKit makes dyld load it, and everything it depends on, at every launch. Measured in
/// the review of issue #148 (macOS 27, arm64): BeepBar's Release binary loads 586 images at
/// launch, AVFoundation already among them (a probe linking the same system frameworks shows it
/// arrives with them), so using AVFoundation costs nothing at launch; linking AVKit raised it to 921 (CallKit, Contacts, CloudKit, MediaRemote, picture in picture,
/// Siri…), about +3.5 ms of warm launch and +0.25 MB, for every user, including those who never
/// press Play. Loaded on demand, the cost moves to the first Play: a probe with the same links
/// went from 657 images to 920 after `dlopen` and 1151 once an `AVPlayerView` existed.
/// An Objective-C framework cannot be unloaded, so after the first Play it stays mapped until
/// quit; the player's own objects are still released on close.
///
/// The view is built through the Objective-C runtime and configured with key-value coding, the
/// only way to reach a class from a framework the binary does not link.
@MainActor enum AVKitLoader {
    static let frameworkPath = "/System/Library/Frameworks/AVKit.framework/AVKit"
    /// `AVPlayerViewControlsStyleFloating`: QuickTime-like controls over the video.
    static let floatingControlsStyle = 2

    private static var attempted = false
    private static var playerViewClass: NSView.Type?

    /// A new `AVPlayerView` with floating controls, or nil if AVKit cannot be loaded. The load is
    /// attempted once per process.
    static func makePlayerView() -> NSView? {
        if !attempted {
            attempted = true
            if dlopen(frameworkPath, RTLD_LAZY) != nil {
                playerViewClass = NSClassFromString("AVPlayerView") as? NSView.Type
            }
        }
        guard let playerViewClass else { return nil }
        let view = (playerViewClass as NSObject.Type).init()
        // Key-value coding on a key the object lacks raises an Objective-C exception, which Swift
        // cannot catch: check both setters exist before using them.
        guard let view = view as? NSView,
              view.responds(to: NSSelectorFromString("setPlayer:")),
              view.responds(to: NSSelectorFromString("setControlsStyle:")) else { return nil }
        view.setValue(floatingControlsStyle, forKey: "controlsStyle")
        return view
    }
}
