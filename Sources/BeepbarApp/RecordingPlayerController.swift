import AppKit
@preconcurrency import AVFoundation
import BeepbarCore
import OSLog
// No `import AVKit`, on purpose: see `AVKitLoader`.

/// What Recordings needs from a native player: play a lecture stream in BeepBar, pause it, close
/// it, learn where the student stopped, and know whether it is showing. A protocol so the
/// Recordings flow (issue #148, package F) can be tested with a fake that never touches
/// AVFoundation.
@MainActor protocol RecordingPlaying: AnyObject {
    /// Whether the player is open (between a `play` and the window closing).
    var isOpen: Bool { get }
    /// Where the student stopped in a recording, and why it was reported; see
    /// `RecordingPlayerController.onPositionCheckpoint` for exactly when.
    var onPositionCheckpoint: ((RecordingCheckpoint) -> Void)? { get set }
    /// Where the student is while a lecture plays, as (recording id, position, duration) in
    /// seconds, about every 30 s of media time; memory only, never a checkpoint. See
    /// `RecordingPlayerController.onProgress`.
    var onProgress: ((String, TimeInterval, TimeInterval?) -> Void)? { get set }
    /// Called, with the `recordingID` of the play that failed, when a play fails; see
    /// `RecordingPlaybackFailure` for what the player has already done in each phase.
    var onFailure: ((String, RecordingPlaybackFailure) -> Void)? { get set }
    /// Plays `url` in the player window, creating it on first use and reusing it afterwards.
    /// `cookies` go with every request AVFoundation makes for the stream; empty means none.
    /// `startAt` resumes from that position once the stream is ready, unless it is within a few
    /// seconds of either end (`RecordingPlayerPolicy.resumePosition`). `recordingID` is the
    /// caller's key for the recording, handed back with every checkpoint and failure.
    /// `metadata` is what macOS's Now Playing shows (lecture, course, course picture); nil shows
    /// `title` alone. Playback never waits for it: the picture arrives later, if at all.
    func play(_ url: URL, title: String, cookies: [HTTPCookie], startAt: TimeInterval?, recordingID: String, metadata: RecordingPlaybackMetadata?)
    /// Pauses playback, keeping the window and the position.
    func pause()
    /// Stops playback and releases the player and its window. Safe to call at any time.
    func close()
    /// Makes the player restore `policy` when it closes, for code that raised BeepBar to a
    /// regular app and finds a lecture open when it is done; see
    /// `RecordingPlayerController.adoptPolicyToRestore`.
    func adoptPolicyToRestore(_ policy: NSApplication.ActivationPolicy)
}

/// One report of where the student stopped in a lecture (`RecordingPlaying.onPositionCheckpoint`).
///
/// The reason is part of the report because the caller treats the moments differently: a pause
/// or a failure keeps the lecture open, while a close or a replacement ends it (watch progress
/// may complete a lecture only when it ends, issue #148 follow-up "recording view tracking").
/// The player states what happened; whether a replacement by the *same* recording counts as an
/// end is the caller's decision, since only it knows what comes next.
struct RecordingCheckpoint: Equatable, Sendable {
    /// Why the position was reported: Core's `RecordingCheckpointReason`, so the controller hands
    /// it straight to `RecordingWatchProgress.checkpointCloses` with no app-side mapping to drift.
    /// - `paused`: the student's pause, `pause()`, or the end of the lecture.
    /// - `closed`: the player closed, by `close()` or the window's close button.
    /// - `replaced`: a newer `play` replaced this lecture; the report carries the old lecture's id.
    /// - `failed`: the stream stopped mid-lecture (`RecordingPlaybackFailure.duringPlayback`); the
    ///   window stays open, paused here.
    typealias Reason = RecordingCheckpointReason

    /// The `recordingID` of the `play` that loaded the lecture.
    let id: String
    /// Seconds from the start: `RecordingPlayerController.reportedPosition`.
    let position: TimeInterval
    /// The lecture's length in seconds, nil when unknown.
    let duration: TimeInterval?
    let reason: Reason
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

/// The native recordings player (issue #148, packages C and G): one window with an
/// `AVPlayerView`, the same engine and controls as QuickTime, plus speeds, skips and keyboard
/// shortcuts (`PlayerShortcut`), a zoom on the video (pinch, ⌘+ / ⌘− / ⌘0, see `zoom`), and
/// resume hooks for the Recordings flow.
///
/// Quiet at rest: the feature exists in memory only while it is used. `init` creates nothing and
/// AVKit is not even loaded until the first `play` (`AVKitLoader`). The first `play` builds the
/// window, the view and the `AVPlayer`; closing the window (from its close button or through
/// `close()`) pauses, empties the player and drops every reference, so nothing of AVFoundation
/// stays retained by BeepBar afterwards.
///
/// Event-driven, with one clock only while playing: no timer, no polling, no boundary time
/// observer. The observers are KVO on the current item's status, `canPlayFastForward` and
/// `canPlaySlowForward`, KVO on the player's `timeControlStatus` and `defaultRate`, and the item's
/// failed-to-play-to-end notification, all tied to the current item and removed on every
/// replacement and on close; plus one periodic time observer only while playing, memory only,
/// never a disk write (`onProgress`). It exists only while `timeControlStatus` is not `.paused`
/// and is removed on pause, replacement, failure and close, so a paused or closed player has no
/// clock at all. Its interval is media time: 30 s of lecture, which is 15 s of wall time at 2x
/// and 60 s at 0.5x; AVFoundation also fires it when playback starts or stops and when time
/// jumps (seeks). Where the student stopped is reported only at the moments that matter
/// (`onPositionCheckpoint`), never on that clock: ticks never produce a checkpoint.
///
/// Not part of the quit path: `prepareForTermination` must never reach this controller, since
/// AVFoundation teardown is exactly the kind of work the quit rules forbid there. Quitting simply
/// lets the process end with the window open (so quitting reports no checkpoint: the last pause
/// is what survives).
///
/// Privacy: the stream URL carries a token, so it is never logged; at most its host.
@MainActor final class RecordingPlayerController: NSObject, RecordingPlaying, NSWindowDelegate {
    /// Called on the main actor, at most once per `play`, when that play fails, with the
    /// `recordingID` of that play; see `RecordingPlaybackFailure` for what the player has already
    /// done in each phase. Never called for an item that a newer `play` replaced, or after the
    /// player was closed.
    var onFailure: ((String, RecordingPlaybackFailure) -> Void)?

    /// Where the student stopped (`RecordingCheckpoint`: id, position and duration in seconds,
    /// the duration nil when unknown, and the reason). The id is the `recordingID` of the `play`
    /// that loaded the lecture, so a report is self-describing even when it is about a lecture
    /// being replaced. Called on the main actor, and only:
    /// - `.paused`: when playback pauses: the student's pause (controls, Space, K, media keys,
    ///   Control Center), `pause()`, or the end of the lecture; once per pause;
    /// - `.closed`: when the player closes, by `close()` or the window's close button,
    ///   synchronously before anything is released;
    /// - `.replaced`: when a newer `play` replaces the item (the old lecture is closed),
    ///   synchronously at the start of that `play`, before anything changes, with the old
    ///   lecture's id (also when the newer `play` is for the same id: the caller decides);
    /// - `.failed`: on a `.duringPlayback` failure, just before `onFailure`, with the same
    ///   position. The pause the player makes for it is not reported a second time.
    ///
    /// Never periodically: `onProgress` ticks never lead here. Nothing is reported before the
    /// item is ready, so a lecture closed while loading never overwrites a saved position with 0.
    /// The position is `reportedPosition()`: where an in-flight seek (a skip, or the resume) is
    /// going, else the player's time. The callback must not call back into the player
    /// synchronously.
    var onPositionCheckpoint: ((RecordingCheckpoint) -> Void)?

    /// Where the student is while the lecture plays, as (recording id, position, duration) in
    /// seconds, the duration nil when unknown, so the window can follow progress live. Called on
    /// the main actor from the one periodic time observer (`progressInterval` of media time, plus
    /// AVFoundation's own fires when playback starts or stops and after a seek), which exists
    /// only while the player is not paused.
    ///
    /// Memory only: this is not a checkpoint, and a consumer must never write to disk on it (the
    /// "quiet at rest" and "disk only at pause/close" budgets). Nothing is reported before the
    /// start is settled (ready, and the resume seek landed), so a lecture resumed near its end
    /// never reports the 0 the player shows while the resume is under way; a tick from a replaced
    /// or closed item is dropped by the generation check. The position is the time AVFoundation
    /// handed the observer, read on its queue. The callback must not call back into the player
    /// synchronously.
    var onProgress: ((String, TimeInterval, TimeInterval?) -> Void)?

    // Internal rather than private so tests can hold weak references and prove the release.
    private(set) var window: NSWindow?
    /// The `AVPlayerView`, typed as `NSView` because AVKit is loaded at runtime.
    private(set) var playerView: NSView?
    private(set) var player: AVPlayer?
    /// The speed menu in the title bar; internal so tests can drive it.
    private(set) var speedPopUp: NSPopUpButton?
    /// Whether the current item reached `.readyToPlay`: decides which failure phase is reported.
    private(set) var isCurrentItemReady = false
    /// Whether the start of playback is settled: the item is ready and the `startAt` seek, if
    /// any, has landed.
    private(set) var isStartSettled = false
    /// Whether a `startAt` resume is under way (waiting for the item, or for its seek to land).
    /// Meanwhile the player is held paused, and play/pause requests only change
    /// `playWhenSettled`: driving the player directly would start the lecture at 0 and jump.
    private(set) var isResuming = false
    /// Whether playback starts once the resume settles: true unless the student paused (K,
    /// Space, `pause()`) or the stream failed while it was resuming.
    private(set) var playWhenSettled = true
    /// The caller's key for the lecture on screen, handed back in every report.
    private(set) var recordingID = ""
    /// Bumped by every `play` and by every teardown. Observations hop to the main actor carrying
    /// the generation they were made in, and are dropped if it no longer matches: a report from a
    /// replaced item, or one that lands after close, never reaches `onFailure`.
    private(set) var generation = 0
    /// The speed the student chose (`RecordingPlayerPolicy.speedDefaultsKey`).
    private(set) var preferredSpeed: Float = 1
    /// The rate last given to the player's `defaultRate`: the preference, capped while the item
    /// cannot fast-forward. A `defaultRate` that differs was set by `AVPlayerView`'s own speed
    /// menu, i.e. by the student.
    private(set) var appliedSpeed: Float = 1
    /// Which rates beyond 1x–2x the current item supports (`canPlayFastForward`,
    /// `canPlaySlowForward`); `.unknown` until it is ready, then followed by KVO, since
    /// AVFoundation may revise both while a stream loads.
    private(set) var rateSupport = RateSupport.unknown
    /// Whether `onFailure` already fired for the current generation: the status KVO and the
    /// failed-to-play-to-end notification can both report the same failure, and the fallback must
    /// run once.
    private var failureReported = false
    /// The resume position waiting for the item to become ready.
    private var pendingStartAt: TimeInterval?
    /// Where an in-flight seek is going. `currentTime()` still reports the old position until the
    /// seek lands, so repeated skips (a held L) accumulate from here, and a checkpoint taken
    /// meanwhile reports where the student is going.
    private(set) var pendingSeekTarget: TimeInterval?
    /// Whether this pause was already reported: the KVO for a pause the player made itself (a
    /// failure) must not report it a second time.
    private var checkpointedSincePlaying = false
    /// The speed list last given to the view's `speeds`, so it is replaced only when it changes.
    private var installedViewSpeeds: [Float]?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var rateSupportObservations: [NSKeyValueObservation] = []
    private var defaultRateObservation: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?
    /// The one periodic time observer (`onProgress`), with the player it was added to:
    /// AVFoundation requires removing a token from that same player. Non-nil only while the
    /// player is not paused. Invariant: every path that pauses, replaces, fails or closes ends in
    /// `removeProgressObserver()`, so a paused or closed player costs no wakeups at all.
    /// `serial` identifies this observer: its ticks carry it, and a tick whose observer is no
    /// longer the current one is dropped (see `settleStart`).
    private var progressObservation: (player: AVPlayer, token: Any, serial: Int)?
    /// The serial of the last periodic time observer added; only ever increases.
    private var lastProgressObserverSerial = 0
    /// The serial of the current periodic time observer, nil when none exists. Internal so tests
    /// can deliver a tick as the current observer, or as one that was replaced.
    var progressObserverSerial: Int? { progressObservation?.serial }
    /// How far the video is zoomed and which part is on screen (`PlayerZoomModel` decides,
    /// `applyZoom` shows it).
    ///
    /// How it is shown: through `AVPlayerView`'s own magnification (macOS 13+, public API, called
    /// at runtime like the rest of AVKit), not by scaling a view or layer of ours. The controls
    /// (the inline bar docked at the view's bottom edge, `AVKitLoader.controlsConfiguration`) are subviews of `AVPlayerView`, so scaling the view would scale and push them off
    /// screen, and a second `AVPlayerLayer` of our own would hide Live Text and the picture in
    /// picture placeholder and flash black while it loads. AVKit's magnification scales only the
    /// video, in a scroll view of its own, under the controls. AVKit has no public pan API, so the
    /// pan places that scroll view's clip origin (`PlayerVideoViews.videoClipView`).
    /// `AVPlayerView`'s own pinch handling stays off (`allowsMagnification`, its default): the
    /// window decides every pinch (`PlayerGestureTracker`), so exactly one handler acts on each and
    /// the 4x limit, the pan limits and "a pinch begun over the controls does nothing" hold.
    ///
    /// Lifetime: kept across pauses, failures and recoveries of the same lecture (a `play` with the
    /// same `recordingID`), back to fit when a different lecture plays or the player closes.
    /// Memory only, never written to defaults. Costs nothing unused: no observer, no timer; a
    /// resize at fit is a no-op.
    private(set) var zoom = PlayerZoomState.fit
    /// The view showing the video, cached for the pan (`PlayerVideoViews.videoHost`).
    private weak var videoHost: NSView?
    /// The menu items' targets: an item holds its target weakly.
    private var menuActions: [PlayerMenuAction] = []
    /// The policy BeepBar had before the player promoted it to `.regular`; nil when the player
    /// did not change it.
    private var policyToRestore: NSApplication.ActivationPolicy?

    // MARK: Now Playing state (see `RecordingNowPlaying.swift` for why the player publishes it)

    /// Whether `nowPlaying` took over Now Playing for the current window (AVKit's own
    /// publication is then off). False before the first play, after close, and when MediaPlayer
    /// could not load, in which case AVKit keeps publishing as before.
    private(set) var isPublishingNowPlaying = false
    /// The lecture's title, course and accepted artwork address (`RecordingNowPlayingPolicy.resolved`).
    private(set) var nowPlayingMetadata: RecordingPlaybackMetadata?
    /// The artwork address being shown or fetched, nil for none. The picture belongs to it.
    private(set) var artworkURL: URL?
    /// The course picture for `artworkURL`, once it arrived. Released on close and as soon as a
    /// lecture of another course plays: at most one picture is held.
    private(set) var artwork: RecordingArtworkImage?
    /// The one artwork fetch in flight, cancelled on close and when a lecture of another course
    /// plays.
    private var artworkTask: Task<Void, Never>?
    /// Bumped whenever `artworkURL` changes and on close. A fetch lands only if it still matches,
    /// so a late picture of a previous course never shows for the next lecture, nor after close.
    private(set) var artworkSerial = 0
    /// How many artwork fetches this player started; tests count them.
    private(set) var artworkFetches = 0
    /// The record last published, so an identical one is not published again.
    private var lastNowPlaying: NowPlayingState?

    private let present: @MainActor (NSWindow) -> Void
    private let makePlayerView: @MainActor () -> NSView?
    private let makePlayer: @MainActor () -> AVPlayer
    private let activationPolicy: ActivationPolicyControl
    private let frameAutosaveName: String?
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let toggleFullScreen: @MainActor (NSWindow) -> Void
    private let progressInterval: CMTime
    private let nowPlaying: NowPlayingPublishing
    private let artworkLoader: RecordingArtwork.Loader?

    /// How often, in media time, `onProgress` reports while playing. Thirty seconds of lecture
    /// keeps the window's progress bar moving visibly (a lecture lasts 1-2 hours, so a step is
    /// well under 1%) for about two wakeups a minute at 1x; finer would cost wakeups for nothing
    /// a student can see. Media time, not wall time: 15 s of wall time at 2x, 60 s at 0.5x.
    static let progressInterval: TimeInterval = 30
    /// Where the periodic time observer's block runs: off the main thread, so a tick only reads
    /// the time it is handed and hops; serial, as AVFoundation requires.
    private static let progressQueue = DispatchQueue(label: "io.github.tvaccari.beepbar.player-progress", qos: .utility)

    /// How far ahead AVFoundation may buffer. Lectures last hours: left at its default (0, meaning
    /// "let the system decide"), AVPlayer may buffer minutes of high-bitrate video ahead, which
    /// costs memory and university network for footage the student may skip. Thirty seconds
    /// still absorbs ordinary network hiccups and seeking within the buffer, while keeping memory
    /// and download proportional to what is actually watched.
    static let forwardBufferDuration: TimeInterval = 30
    static let defaultFrameAutosaveName = "BeepbarRecordingPlayerWindow"
    /// How far a seek may land from its target. An exact seek (zero tolerance) decodes from the
    /// previous keyframe up to the exact frame; an unlimited one may snap to a keyframe far away,
    /// which in a lecture with long keyframe intervals can make "+10 s" stay put or even go
    /// back. One second each way is invisible for a lecture, keeps every skip moving in its
    /// direction (it is well below the 10 s skip) and lets AVFoundation stop decoding early.
    static let seekTolerance = CMTime(seconds: 1, preferredTimescale: 600)

    private static let log = Logger(subsystem: "io.github.tvaccari.beepbar", category: "player")

    /// - Parameters:
    ///   - present: brings the window on screen; tests pass a no-op so nothing is shown and the
    ///     test process is never activated.
    ///   - makePlayerView: builds the `AVPlayerView`; tests can simulate AVKit failing to load,
    ///     or pass a plain view to observe the player without AVKit in between.
    ///   - makePlayer: builds the `AVPlayer`; tests pass a subclass that counts time observers.
    ///   - activationPolicy: see `promoteToRegularApp()`.
    ///   - frameAutosaveName: where AppKit keeps the window's size and position; nil disables it.
    ///   - defaults: where the chosen speed is remembered.
    ///   - notificationCenter: where AVFoundation's item notifications are observed.
    ///   - toggleFullScreen: what F does; tests record it instead of animating a window.
    ///   - progressInterval: seconds of media time between `onProgress` ticks; tests shorten it
    ///     to see real ticks within the 60 s fixture.
    ///   - nowPlaying: publishes the Now Playing record and receives the remote commands; tests
    ///     pass a fake.
    ///   - artworkLoader: fetches a course picture (`WeBeepAuthenticationController.courseImage`
    ///     holds the token);
    ///     nil fetches nothing and Now Playing shows the app's icon.
    init(present: @escaping @MainActor (NSWindow) -> Void = RecordingPlayerController.bringToFront,
         makePlayerView: @escaping @MainActor () -> NSView? = AVKitLoader.makePlayerView,
         makePlayer: @escaping @MainActor () -> AVPlayer = { AVPlayer() },
         activationPolicy: ActivationPolicyControl = .application,
         frameAutosaveName: String? = RecordingPlayerController.defaultFrameAutosaveName,
         defaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default,
         toggleFullScreen: @escaping @MainActor (NSWindow) -> Void = { $0.toggleFullScreen(nil) },
         progressInterval: TimeInterval = RecordingPlayerController.progressInterval,
         nowPlaying: NowPlayingPublishing = SystemNowPlaying(),
         artworkLoader: RecordingArtwork.Loader? = nil) {
        self.progressInterval = CMTime(seconds: progressInterval, preferredTimescale: 600)
        self.nowPlaying = nowPlaying
        self.artworkLoader = artworkLoader
        self.present = present
        self.makePlayerView = makePlayerView
        self.makePlayer = makePlayer
        self.activationPolicy = activationPolicy
        self.frameAutosaveName = frameAutosaveName
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.toggleFullScreen = toggleFullScreen
        super.init()
    }

    var isOpen: Bool { player != nil }

    /// `recordingID`: a `String` rather than `AnyHashable` or a generic, because the Recordings
    /// flow keys saved positions by recording in persisted storage, where a string round-trips
    /// as is, and a concrete type keeps the protocol usable as an existential with fakes.
    func play(_ url: URL, title: String, cookies: [HTTPCookie], startAt: TimeInterval?, recordingID: String, metadata: RecordingPlaybackMetadata?) {
        Self.log.notice("Playing a recording from \(url.host ?? "-", privacy: .public)")
        // A newer lecture closes the one on screen: report where the student left it, with its
        // own id, while the old item is still in place.
        checkpointIfMeaningful(.replaced)
        removeItemObservers()
        generation += 1
        // A different lecture starts at fit; the same one (a recovery, Play again) keeps the
        // student's zoom, like its position.
        if recordingID != self.recordingID { applyZoom(.fit) }
        self.recordingID = recordingID
        failureReported = false
        isCurrentItemReady = false
        isStartSettled = false
        rateSupport = .unknown
        pendingSeekTarget = nil
        checkpointedSincePlaying = false
        pendingStartAt = RecordingPlayerPolicy.acceptsStartAt(startAt) ? startAt : nil
        isResuming = pendingStartAt != nil
        playWhenSettled = true
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
        // A lecture already playing must not run on into the new item: with a resume position the
        // player stays paused until the seek lands. Paused before the new observers exist, so this
        // pause reports nothing (the old lecture was reported above).
        if isResuming { player.pause() }
        let shown = RecordingNowPlayingPolicy.resolved(metadata, fallbackTitle: title)
        nowPlayingMetadata = shown
        // The title bar names the lecture and, under it, the course. The app itself stays
        // "BeepBar" in the Dock and the app switcher: that is the app's name, not the lecture's.
        window?.title = metadata == nil ? title : shown.title
        window?.subtitle = shown.courseName
        // Never awaited: the picture is fetched while the stream loads and shows when it lands.
        updateArtwork(shown.artworkURL)
        preferredSpeed = RecordingPlayerPolicy.storedSpeed(defaults.object(forKey: RecordingPlayerPolicy.speedDefaultsKey))

        let asset = AVURLAsset(url: url, options: Self.assetOptions(cookies: cookies))
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Self.forwardBufferDuration
        // Pitch-corrected speech at every speed. `timeDomain` is AVFoundation's default for apps
        // built against macOS 12 or later, but a default can change and the choice matters here:
        // it is the algorithm meant for voice and the cheapest pitch-preserving one, while
        // `spectral` (the default before macOS 12, and for offline processing) costs more CPU
        // for a quality only music needs, and `varispeed` would turn 2x lectures into chipmunks.
        item.audioTimePitchAlgorithm = .timeDomain
        // Every observer fires on whatever thread AVFoundation uses: read the values there (or
        // nothing at all), then hop to the main actor, where the generation check rejects stale
        // results.
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
        // Pauses from anywhere (the controls, Space, media keys, Control Center, the end of the
        // lecture) show up here: this is how a pause reaches `onPositionCheckpoint` without
        // watching the clock.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.timeControlStatusChanged(generation: observedGeneration) }
        }
        // Which speeds the stream allows can change while it loads (an HLS stream may learn about
        // an I-frame playlist late): follow it, so 2.5x–4x or 0.5x/0.75x open up when allowed.
        // Nothing is read on AVFoundation's thread: two reports can hop in either order, and a
        // value carried by an older hop would overwrite a newer one. The hop reads the item's
        // current values itself (`rateSupportObserved`).
        rateSupportObservations = [\AVPlayerItem.canPlayFastForward, \AVPlayerItem.canPlaySlowForward].map { keyPath in
            item.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.rateSupportObserved(generation: observedGeneration) }
            }
        }
        // `AVPlayerView`'s own speed menu sets `defaultRate`: that is the student choosing a speed.
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.defaultRateChanged(generation: observedGeneration) }
        }
        // A stream that dies after it started (network lost, token expired) does not always move
        // the item to `.failed`; AVFoundation reports it with this notification instead.
        failedToEndObserver = notificationCenter.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                self?.fail(generation: observedGeneration, error: error)
            }
        }
        player.replaceCurrentItem(with: item)
        rebuildSpeedMenu()
        applySpeed()
        // With a resume position, playback starts only once the seek has landed
        // (`itemBecameReady`): starting now would play the first seconds of the lecture and then
        // jump. AVFoundation cannot seek an item before it is ready.
        if !isResuming { player.play() }
        // The new `timeControlStatus` observation reports changes only: if the player was
        // already moving and stays so across the replacement, no report would come to add the
        // progress observer for the new item, so it is added here from the current status.
        updateProgressObserver(generation: observedGeneration)
        // Title and course now, before the stream has loaded a byte.
        publishNowPlaying()
        if let window { present(window) }
    }

    func pause() {
        // While resuming, also record the intent: the landing must not start playback.
        if isResuming { playWhenSettled = false }
        // And pause the player itself, always. It is held paused during a resume, but the student
        // can still start it from the system controls (the view's play button, media keys,
        // Control Center) before the resume seek lands, and then K or `pause()` has to stop what
        // is audibly playing, not just change an intention. Pausing a paused player is a no-op.
        // The checkpoint follows through the `timeControlStatus` observation, like any pause.
        player?.pause()
    }

    func close() {
        checkpointIfMeaningful(.closed)
        let window = self.window
        stopPlayback()
        guard let window else { return }
        Self.release(window)
        if self.window === window {
            self.window = nil
            playerView = nil
            speedPopUp = nil
        }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // The student closed the window: report where they stopped before anything is released.
        checkpointIfMeaningful(.closed)
        // Playback stops now: no sound may outlive the window.
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
                self.speedPopUp = nil
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
        let id = recordingID
        if isCurrentItemReady, let player {
            // The lecture was playing: keep the window and the position, and let the caller
            // decide between a fresh stream URL and the browser. A resume still landing must not
            // start playback afterwards.
            player.pause()
            playWhenSettled = false
            // No clock on a failed stream, even before the pause's KVO lands.
            removeProgressObserver()
            let position = reportedPosition(of: player)
            checkpointIfMeaningful(.failed)
            // Domain and code only (`PlaybackDiagnostics.errorName`): the error's user info can
            // carry the stream address and its token.
            let name = PlaybackDiagnostics.errorName(error)
            Self.log.error("Recording playback stopped while playing error=\(name, privacy: .public)")
            onFailure?(id, .duringPlayback(error, position: position))
        } else {
            // Nothing ever played: an empty player window is no use, so close it before the
            // caller opens the browser.
            let name = PlaybackDiagnostics.errorName(error)
            Self.log.error("Recording playback failed before starting error=\(name, privacy: .public)")
            close()
            onFailure?(id, .beforeReady(error))
        }
    }

    /// Where the status KVO lands once the item is ready. Internal so tests can deliver a second
    /// report and prove the resume seek happens once.
    func itemBecameReady(generation observed: Int) {
        guard observed == generation, !isCurrentItemReady, let player, let item = player.currentItem else { return }
        isCurrentItemReady = true
        rateSupport = RateSupport(fastForward: item.canPlayFastForward, slowForward: item.canPlaySlowForward)
        applySpeed()
        // A zoom kept across a recovery was limited by the whole view while the new item had no
        // size yet: now the video's real frame is known.
        zoomGeometryChanged()
        // The duration is known now.
        publishNowPlaying()
        guard let startAt = pendingStartAt else {
            settleStart()
            return
        }
        pendingStartAt = nil
        if let target = RecordingPlayerPolicy.resumePosition(startAt: startAt, duration: Self.seconds(item.duration)) {
            seek(to: target, settlesStart: true)
        } else {
            settleStart()
        }
    }

    /// Where the item's rate-support KVO lands: reads the current item's two flags here, on the
    /// main actor, so the value applied is the latest one whatever order the hops arrive in.
    /// Internal so tests can deliver the notification after changing what the item reports.
    func rateSupportObserved(generation observed: Int) {
        guard observed == generation, let item = player?.currentItem else { return }
        rateSupportChanged(generation: observed, to: RateSupport(fastForward: item.canPlayFastForward, slowForward: item.canPlaySlowForward))
    }

    /// Where the item's rate-support change is applied. Internal so tests can deliver a change the
    /// local fixture never makes on its own.
    func rateSupportChanged(generation observed: Int, to support: RateSupport) {
        guard observed == generation, isCurrentItemReady, support != rateSupport else { return }
        rateSupport = support
        applySpeed()
    }

    /// Where a periodic time observer tick lands on the main actor, with the time AVFoundation
    /// handed the observer. Forwards it to `onProgress` and does nothing else: never a
    /// checkpoint, never a write. Dropped when:
    /// - it comes from a replaced or closed item (the generation moved on);
    /// - its observer is no longer the current one (`observer` is not `progressObserverSerial`):
    ///   removed on a pause, or replaced when the start settled. The hop is queued, so the start
    ///   may settle between AVFoundation reading the time and the tick landing here: checking
    ///   `isStartSettled` alone would let through a time read before the resume landed;
    /// - the start is not settled yet (see `onProgress`);
    /// - the position is not a finite, non-negative number.
    ///
    /// Internal so tests can deliver ticks AVFoundation never produces on demand.
    func progressTicked(generation observed: Int, observer: Int, position: TimeInterval) {
        guard observed == generation, observer == progressObserverSerial, isStartSettled,
              position.isFinite, position >= 0, let item = player?.currentItem else { return }
        onProgress?(recordingID, position, Self.seconds(item.duration))
    }

    // MARK: Controls

    /// Runs a shortcut; the window calls it from a main-actor hop (`RecordingPlayerWindow`).
    func performShortcut(_ shortcut: PlayerShortcut) {
        guard let player else { return }
        switch shortcut {
        case .togglePlayPause:
            if isResuming {
                // Playing already means the student started it from the system controls during
                // the resume: Space then pauses it, as everywhere else, instead of "arming" a
                // play that would double up.
                if player.rate != 0 { pause() } else { playWhenSettled.toggle() }
            } else if player.rate == 0 {
                player.play()
            } else {
                player.pause()
            }
        case .pause:
            pause()
        case .skip(let delta):
            skip(by: delta)
        case .slower, .faster:
            let available = RecordingPlayerPolicy.availableSpeeds(rateSupport)
            if let speed = RecordingPlayerPolicy.steppedSpeed(from: appliedSpeed, faster: shortcut == .faster, available: available) {
                selectSpeed(speed)
            }
        case .toggleFullScreen:
            if let window { toggleFullScreen(window) }
        case .toggleMute:
            player.isMuted.toggle()
        case .jump(let fraction):
            guard isCurrentItemReady, let item = player.currentItem,
                  let target = RecordingPlayerPolicy.jumpTarget(fraction: fraction, duration: Self.seconds(item.duration)) else { return }
            seek(to: target)
        case .zoomIn, .zoomOut:
            guard let geometry = zoomGeometry() else { return }
            applyZoom(PlayerZoomModel.stepped(zoom, zoomIn: shortcut == .zoomIn, viewport: geometry.viewport, video: geometry.video))
        case .zoomReset:
            applyZoom(.fit)
        }
    }

    // MARK: Zoom

    /// Applies a pinch step or a pan from the window (`RecordingPlayerWindow.zoomHandler`), on the
    /// main actor. Internal so tests can deliver inputs directly.
    func handleZoomInput(_ input: PlayerZoomInput) {
        guard player != nil, let playerView, let geometry = zoomGeometry() else { return }
        switch input {
        case .magnify(let magnification, let location):
            let anchor = playerView.convert(location, from: nil)
            applyZoom(PlayerZoomModel.magnified(zoom, by: magnification, at: anchor, viewport: geometry.viewport, video: geometry.video))
        case .pan(let movement):
            applyZoom(PlayerZoomModel.panned(zoom, by: movement, viewport: geometry.viewport, video: geometry.video))
        }
    }

    /// The window was resized (also into or out of full screen). Through a hop, like every other
    /// AppKit callback here: nothing is read from the notification. At fit there is nothing to
    /// redo, so a resize costs nothing unless the video is zoomed.
    func windowDidResize(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.zoomGeometryChanged() }
    }

    /// Re-clamps a zoom to the current view and video size (a resize, or a new item's frame).
    /// Internal so tests can run it without animating a real window.
    func zoomGeometryChanged() {
        guard zoom.isZoomed, let geometry = zoomGeometry() else { return }
        applyZoom(PlayerZoomModel.adapted(zoom, to: geometry.viewport, video: geometry.video))
    }

    /// The player view's size and where the video sits in it (`PlayerZoomModel.videoRect`), or
    /// nil without a view.
    private func zoomGeometry() -> (viewport: CGSize, video: CGRect)? {
        guard let playerView else { return nil }
        let viewport = playerView.bounds.size
        let presentation = player?.currentItem?.presentationSize ?? .zero
        return (viewport, PlayerZoomModel.videoRect(presentationSize: presentation, in: viewport))
    }

    /// Makes `state` the zoom and shows it: the magnification through AVKit's public
    /// `setMagnification:centeredAtPoint:`, then the visible part by placing the clip origin of
    /// AVKit's video scroll view, both within this main-actor turn so no frame shows the halfway
    /// state. A play at fit costs nothing. Also pushes `isVideoZoomed` to the window.
    ///
    /// The fixed point handed to AVKit (`PlayerZoomModel.fixedPoint`) already makes its result
    /// match the model; the clip origin is set as well, because a pan has no scale change to
    /// carry it, and a resize moves the video under a clip origin AVKit leaves where it was.
    private func applyZoom(_ state: PlayerZoomState) {
        let previous = zoom
        zoom = state
        (window as? RecordingPlayerWindow)?.isVideoZoomed = state.isZoomed
        guard let playerView else { return }
        if state.scale != previous.scale {
            let viewport = playerView.bounds.size
            let from = PlayerZoomModel.adapted(previous, to: viewport, video: CGRect(origin: .zero, size: viewport))
            let fixed = PlayerZoomModel.fixedPoint(from: from, to: state) ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            AVKitLoader.setMagnification(state.scale, centeredAt: fixed, of: playerView)
        }
        guard state.isZoomed else { return }
        // AVKit may defer magnification layout or rebuild its clip for a new item. Place the
        // origin after layout, even if readiness re-applies an unchanged model.
        playerView.layoutSubtreeIfNeeded()
        if videoHost.map({ !$0.isDescendant(of: playerView) }) ?? true {
            videoHost = PlayerVideoViews.videoHost(in: playerView)
        }
        if let clipView = PlayerVideoViews.videoClipView(in: playerView, videoHost: videoHost) {
            clipView.scroll(to: state.origin)
            (clipView.superview as? NSScrollView)?.reflectScrolledClipView(clipView)
        }
    }

    /// Moves `delta` seconds from where the student is (or is already going), within the
    /// lecture. Ignored until the item is ready: there is no timeline to move on yet.
    func skip(by delta: TimeInterval) {
        guard isCurrentItemReady, let player, let item = player.currentItem else { return }
        let current = pendingSeekTarget ?? player.currentTime().seconds
        seek(to: RecordingPlayerPolicy.skipTarget(from: current, by: delta, duration: Self.seconds(item.duration)))
    }

    /// The student chose a speed (menu, `<` / `>`, or `AVPlayerView`'s own menu): apply it now,
    /// for this lecture and the next ones, and remember it. The only place the preference is
    /// written, and only when it changes, so plays and launches never write.
    func selectSpeed(_ speed: Float) {
        guard RecordingPlayerPolicy.speeds.contains(speed) else { return }
        preferredSpeed = speed
        let key = RecordingPlayerPolicy.speedDefaultsKey
        if RecordingPlayerPolicy.storedSpeed(defaults.object(forKey: key)) != speed {
            defaults.set(Double(speed), forKey: key)
        }
        applySpeed()
    }

    // MARK: Private

    /// Gives the player the preferred speed, capped to what the item can play. `defaultRate` is
    /// what `play()` (the controls, Space, media keys) starts at, so resuming keeps the speed; a
    /// player already moving also changes `rate` at once.
    private func applySpeed() {
        guard let player else { return }
        let speed = RecordingPlayerPolicy.effectiveSpeed(preferred: preferredSpeed, support: rateSupport)
        appliedSpeed = speed
        if player.defaultRate != speed { player.defaultRate = speed }
        if player.rate != 0, player.rate != speed { player.rate = speed }
        updateSpeedControls()
        publishNowPlaying()
    }

    private func defaultRateChanged(generation observed: Int) {
        guard observed == generation, let player else { return }
        let rate = player.defaultRate
        // Our own `applySpeed` lands here too: only a different rate is the student's choice.
        guard abs(rate - appliedSpeed) > 0.001 else { return }
        if let speed = RecordingPlayerPolicy.speed(matching: Double(rate)) {
            selectSpeed(speed)
        } else {
            appliedSpeed = rate
            updateSpeedControls()
        }
    }

    private func timeControlStatusChanged(generation observed: Int) {
        guard observed == generation, let player else { return }
        // Read now rather than in the observer: if hops arrive late or out of order, only the
        // current state counts.
        if player.timeControlStatus == .paused {
            if !checkpointedSincePlaying { checkpointIfMeaningful(.paused) }
        } else {
            checkpointedSincePlaying = false
        }
        updateProgressObserver(generation: observed)
        publishNowPlaying()
    }

    /// Keeps the one periodic time observer in step with the player: present while it is not
    /// paused (playing, or waiting to play at a rate), absent otherwise. Idempotent, so the
    /// repeated `timeControlStatus` reports of one playing stretch (waiting, playing, waiting
    /// after a stall) never add a second observer.
    private func updateProgressObserver(generation observed: Int) {
        guard observed == generation, let player, player.timeControlStatus != .paused else {
            removeProgressObserver()
            return
        }
        guard progressObservation == nil else { return }
        lastProgressObserverSerial += 1
        let serial = lastProgressObserverSerial
        // The block runs on `progressQueue`: it reads only the time it is handed, then hops to
        // the main actor, where the generation and serial checks drop a tick from a replaced or
        // closed item, or from an observer that was removed meanwhile. It must never touch
        // main-actor state from there.
        let token = player.addPeriodicTimeObserver(forInterval: progressInterval, queue: Self.progressQueue) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in self?.progressTicked(generation: observed, observer: serial, position: seconds) }
        }
        progressObservation = (player, token, serial)
    }

    /// Removes the periodic time observer, from the player it was added to. Safe to call when
    /// there is none.
    private func removeProgressObserver() {
        guard let progressObservation else { return }
        self.progressObservation = nil
        progressObservation.player.removeTimeObserver(progressObservation.token)
    }

    /// Reports the position with `reason`, unless there is nothing meaningful to report yet (see
    /// `onPositionCheckpoint`).
    private func checkpointIfMeaningful(_ reason: RecordingCheckpoint.Reason) {
        guard isCurrentItemReady, let player, let item = player.currentItem else { return }
        checkpointedSincePlaying = true
        onPositionCheckpoint?(RecordingCheckpoint(id: recordingID, position: reportedPosition(of: player),
                                                  duration: Self.seconds(item.duration), reason: reason))
    }

    /// The one definition of "where the student is", shared by checkpoints and
    /// `.duringPlayback` failures so the two always agree: where an in-flight seek is going (a
    /// skip, or the resume seek, whose target also stands while the resume is unsettled), else
    /// the player's time. `currentTime()` alone would report the old position, or 0 during a
    /// resume, until the seek lands.
    private func reportedPosition(of player: AVPlayer) -> TimeInterval {
        if let pendingSeekTarget { return pendingSeekTarget }
        let current = player.currentTime().seconds
        return current.isFinite ? max(0, current) : 0
    }

    /// The resume is over (landed, or not needed): playback starts unless the student paused
    /// meanwhile or the stream failed.
    private func settleStart() {
        isStartSettled = true
        // An observer that already exists was added before the start settled: the student
        // started the held player from the system controls during the resume, or (without a
        // resume) playback began while the item loaded. Its ticks still in flight read the time
        // before the resume landed (~0 for a lecture resumed at 92%), and a stray "below 90%"
        // would let closing re-complete a lecture the student un-ticked. A fresh observer
        // gets a new serial, so every tick of the old one is dropped (`progressTicked`).
        if progressObservation != nil {
            removeProgressObserver()
            updateProgressObserver(generation: generation)
        }
        guard isResuming else { return }
        isResuming = false
        if playWhenSettled { player?.play() }
    }

    private func seek(to seconds: TimeInterval, settlesStart: Bool = false) {
        guard let player else { return }
        let observed = generation
        pendingSeekTarget = seconds
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance) { [weak self] _ in
            // Also when a newer seek interrupted this one (`finished` false): the resume still
            // counts as settled, and the newer seek clears its own target when it lands.
            Task { @MainActor [weak self] in
                guard let self, observed == self.generation else { return }
                if self.pendingSeekTarget == seconds { self.pendingSeekTarget = nil }
                if settlesStart { self.settleStart() }
                self.publishNowPlaying()
            }
        }
    }

    /// A finite, positive number of seconds, or nil (indefinite while loading, or a live stream).
    private static func seconds(_ time: CMTime) -> TimeInterval? {
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private func makePlayerAndWindow() -> AVPlayer? {
        // Key-value coding on a key the view lacks raises an Objective-C exception, which Swift
        // cannot catch: the injected view must prove it takes a player before it is used.
        guard let view = makePlayerView(), view.responds(to: NSSelectorFromString("setPlayer:")) else { return nil }
        // `automaticallyWaitsToMinimizeStalling` keeps its default (true): AVPlayer waits for
        // enough data before starting or resuming, which suits network streams and works with the
        // bounded forward buffer.
        let player = makePlayer()
        // macOS defaults this to false. Let AVFoundation prevent display and device idle sleep
        // during video playback and release its protection when playback stops (#157).
        player.preventsDisplaySleepDuringVideoPlayback = true
        // Here rather than in `AVKitLoader.makePlayerView`, so every view the window gets (also
        // after a close and a new Play) has the compact controls, whoever built it.
        AVKitLoader.configureControls(of: view)
        view.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        view.setValue(player, forKey: "player")
        let window = RecordingPlayerWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        // We own the window's lifetime: AppKit releasing it on close as well would double-release.
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = view
        window.delegate = self
        window.shortcutHandler = { [weak self, weak window] shortcut in
            guard let self, let window, self.window === window else { return }
            self.performShortcut(shortcut)
        }
        window.zoomHandler = { [weak self, weak window] input in
            guard let self, let window, self.window === window else { return }
            self.handleZoomInput(input)
        }
        window.addTitlebarAccessoryViewController(makeSpeedAccessory())
        if let frameAutosaveName {
            if !window.setFrameUsingName(frameAutosaveName) { window.center() }
            window.setFrameAutosaveName(frameAutosaveName)
        } else {
            window.center()
        }
        self.player = player
        self.playerView = view
        self.window = window
        installedViewSpeeds = nil
        takeOverNowPlaying(of: view, window: window)
        promoteToRegularApp()
        return player
    }

    // MARK: Now Playing

    /// Makes the player, not AVKit, publish Now Playing for this window: AVKit's record has no
    /// lecture, course or picture on macOS, so the system showed "BeepBar" (see
    /// `RecordingNowPlaying.swift`). Only when `nowPlaying` could take over and AVKit's own
    /// publication can be switched off (two publishers would overwrite each other); otherwise
    /// AVKit keeps publishing, and handling the media keys, as before.
    private func takeOverNowPlaying(of view: NSView, window: NSWindow) {
        let setter = NSSelectorFromString("setUpdatesNowPlayingInfoCenter:")
        let isAVKitView = NSStringFromClass(type(of: view)) == "AVPlayerView"
        guard !isAVKitView || view.responds(to: setter),
              nowPlaying.activate(onCommand: { [weak self, weak window] command in
                  guard let self, let window, self.window === window else { return }
                  self.handleRemoteCommand(command)
              }) else { return }
        if view.responds(to: setter) { view.setValue(false, forKey: "updatesNowPlayingInfoCenter") }
        isPublishingNowPlaying = true
        lastNowPlaying = nil
    }

    /// A command from Control Center, the media keys or headphones, on the main actor. Each one
    /// does what the same control in the window does, so the resume and checkpoint rules hold.
    /// Internal so tests can deliver commands MediaPlayer never sends to a test process.
    func handleRemoteCommand(_ command: NowPlayingCommand) {
        guard let player else { return }
        switch command {
        case .play:
            if isResuming { playWhenSettled = true } else { player.play() }
        case .pause:
            pause()
        case .togglePlayPause:
            performShortcut(.togglePlayPause)
        case .skip(let delta):
            skip(by: delta)
        case .seek(let position):
            guard isCurrentItemReady, position.isFinite, let item = player.currentItem else { return }
            let upper = Self.seconds(item.duration) ?? max(0, position)
            seek(to: min(max(0, position), upper))
        }
    }

    /// Publishes the record for the lecture on screen, unless it is identical to the last one.
    /// Called at the moments it changes (a play, the item ready, play/pause, a seek landing, a
    /// speed change, the picture arriving), never on a clock: the system extrapolates the time
    /// from the rate and the elapsed time.
    private func publishNowPlaying() {
        guard isPublishingNowPlaying, let player, let metadata = nowPlayingMetadata else { return }
        let state = NowPlayingState(
            title: metadata.title,
            artist: metadata.courseName,
            duration: player.currentItem.flatMap { Self.seconds($0.duration) },
            elapsed: reportedPosition(of: player),
            // Only a lecture actually playing advances: while it buffers (`waitingToPlay…`) the
            // system must not run the clock on from a rate the player has not reached.
            rate: player.timeControlStatus == .playing ? player.rate : 0,
            defaultRate: appliedSpeed,
            isPlaying: player.timeControlStatus != .paused,
            artwork: artwork)
        guard state != lastNowPlaying else { return }
        lastNowPlaying = state
        nowPlaying.publish(state)
    }

    /// Shows the picture at `url` (already accepted by `RecordingNowPlayingPolicy.resolved`):
    /// - the same address as now: nothing changes, the picture (or its fetch) is kept, so another
    ///   lecture of the same course costs no request;
    /// - another one, or none: the old fetch is cancelled and the old picture released at once,
    ///   so the next record shows the app's icon rather than another course's picture, and a new
    ///   fetch starts when there is an address and a loader.
    /// The fetch runs off the main actor (`RecordingArtwork.load`) and lands only while
    /// `artworkSerial` is unchanged.
    private func updateArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        cancelArtwork()
        // No record, no picture: when AVKit publishes (MediaPlayer missing) nothing would show
        // it, so nothing is fetched.
        guard isPublishingNowPlaying else {
            artworkURL = nil
            return
        }
        artworkURL = url
        guard let url, let artworkLoader else { return }
        let serial = artworkSerial
        artworkFetches += 1
        artworkTask = Task { [weak self] in
            let result: Result<RecordingArtworkImage, Error>
            do { result = .success(try await RecordingArtwork.load(url, loader: artworkLoader)) }
            catch { result = .failure(error) }
            self?.artworkLoaded(result, serial: serial)
        }
    }

    /// Where a fetch lands, on the main actor. Internal so tests can deliver a late result.
    func artworkLoaded(_ result: Result<RecordingArtworkImage, Error>, serial: Int) {
        guard serial == artworkSerial else { return }
        artworkTask = nil
        switch result {
        case .success(let image):
            artwork = image
            publishNowPlaying()
        case .failure(let error):
            // Forgotten, so the next lecture of this course tries again (once per play): a
            // network blip must not leave the course without its picture for the session.
            artworkURL = nil
            // The record keeps its title and course, with the app's icon. Never the address.
            if !(error is CancellationError) {
                Self.log.notice("Course artwork unavailable reason=\(RecordingArtwork.logDescription(error), privacy: .public)")
            }
        }
    }

    /// Cancels the fetch and releases the picture; a fetch still landing is dropped.
    private func cancelArtwork() {
        artworkSerial += 1
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
    }

    /// The speed menu at the trailing end of the title bar: always visible, it shows the current
    /// speed and lists the keyboard shortcuts, whether or not `AVPlayerView`'s own controls offer
    /// a speed menu in this macOS version.
    private func makeSpeedAccessory() -> NSTitlebarAccessoryViewController {
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 72, height: 22), pullsDown: true)
        popUp.bezelStyle = .accessoryBarAction
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // Clicking it must not steal the keyboard from the player (Space would press it).
        popUp.refusesFirstResponder = true
        popUp.autoenablesItems = false
        speedPopUp = popUp
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        popUp.frame.origin = NSPoint(x: 0, y: 0)
        container.addSubview(popUp)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = container
        return accessory
    }

    /// Rebuilds the speed menu's items in the current language (so a language switch shows at the
    /// next play), then `updateSpeedControls` sets their state. `AVPlayerView`'s speed objects
    /// carry labels too, so they are rebuilt at the next update as well.
    private func rebuildSpeedMenu() {
        installedViewSpeeds = nil
        guard let popUp = speedPopUp, let menu = popUp.menu else { return }
        menu.removeAllItems()
        menuActions = []
        // A pull-down button shows its first item as its title.
        menu.addItem(NSMenuItem())
        let header = NSMenuItem(title: tr("Velocità", "Speed"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for speed in RecordingPlayerPolicy.speeds {
            let window = self.window
            let action = PlayerMenuAction { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.selectSpeed(speed)
            }
            menuActions.append(action)
            let item = NSMenuItem(title: RecordingPlayerPolicy.speedLabel(speed), action: #selector(PlayerMenuAction.invoke(_:)), keyEquivalent: "")
            item.target = action
            item.representedObject = NSNumber(value: speed)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let shortcutsHeader = NSMenuItem(title: tr("Scorciatoie da tastiera", "Keyboard shortcuts"), action: nil, keyEquivalent: "")
        shortcutsHeader.isEnabled = false
        menu.addItem(shortcutsHeader)
        let help = RecordingPlayerPolicy.shortcutHelp()
        for entry in help {
            let item = NSMenuItem(title: "\(entry.keys)\t\(entry.action)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        popUp.toolTip = ([tr("Velocità di riproduzione", "Playback speed")] + help.map { "\($0.keys): \($0.action)" }).joined(separator: "\n")
        popUp.setAccessibilityLabel(tr("Velocità di riproduzione", "Playback speed"))
    }

    /// Shows the applied speed in the title-bar menu and gives `AVPlayerView` the speeds the item
    /// can play, so its own speed menu (where macOS shows one) offers the same list.
    private func updateSpeedControls() {
        let available = RecordingPlayerPolicy.availableSpeeds(rateSupport)
        if let menu = speedPopUp?.menu {
            menu.item(at: 0)?.title = RecordingPlayerPolicy.speedLabel(appliedSpeed)
            for item in menu.items {
                guard let speed = (item.representedObject as? NSNumber)?.floatValue else { continue }
                item.state = abs(speed - appliedSpeed) < 0.001 ? .on : .off
                item.isEnabled = available.contains(speed)
            }
        }
        if let playerView, installedViewSpeeds != available,
           playerView.responds(to: NSSelectorFromString("setSpeeds:")),
           let speeds = AVKitLoader.makePlaybackSpeeds(available) {
            installedViewSpeeds = available
            playerView.setValue(speeds, forKey: "speeds")
        }
    }

    /// BeepBar is a menu-bar app (`LSUIElement`), so its windows have no Dock icon and no entry
    /// in Cmd-Tab. A lecture window the student switches away from must be easy to find again, so
    /// while it is open BeepBar runs as a regular app, as `WeBeepAuthenticationController.chooseRoot`
    /// does around its folder panel.
    ///
    /// Interaction with other code switching the policy: the player only remembers a policy it
    /// changed itself (nothing when BeepBar was already regular), and only restores it if BeepBar
    /// is still regular at close, so it never undoes a change someone else made in between.
    /// `chooseRoot` is not that careful, and the two can interleave: its `runModal` folder panel
    /// keeps servicing main-actor jobs, so a Play can start while the panel is open. The player
    /// then finds `.regular` (set by `chooseRoot`) and records nothing to restore, and when the
    /// panel closes `chooseRoot` would put back `.accessory` unconditionally: the lecture keeps
    /// playing but its window loses the Dock icon and the Cmd-Tab entry until the next Play.
    /// `chooseRoot` now leaves the policy alone while the player is open and hands the policy to
    /// restore over with `adoptPolicyToRestore`, so the Dock icon goes when the lecture closes.
    private func promoteToRegularApp() {
        let current = activationPolicy.current()
        guard current != .regular, policyToRestore == nil else { return }
        policyToRestore = current
        activationPolicy.set(.regular)
    }

    /// Takes over restoring `policy` when the player closes, for code that raised BeepBar to
    /// `.regular` itself and finds a lecture open when it is done (`WeBeepAuthenticationController.chooseRoot`
    /// after its folder panel): putting `.accessory` back then would drop the Dock icon from under
    /// the lecture window. The player restores it at close instead. Nothing happens if the player
    /// already holds a policy to restore, or isn't open.
    func adoptPolicyToRestore(_ policy: NSApplication.ActivationPolicy) {
        guard isOpen, policyToRestore == nil, policy != .regular else { return }
        policyToRestore = policy
    }

    private func restoreActivationPolicy() {
        guard let previous = policyToRestore else { return }
        policyToRestore = nil
        if activationPolicy.current() == .regular { activationPolicy.set(previous) }
    }

    /// Removes every observer tied to the current item, the periodic time observer included: on
    /// every replacement and, through `stopPlayback`, on close.
    private func removeItemObservers() {
        removeProgressObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        rateSupportObservations.forEach { $0.invalidate() }
        rateSupportObservations = []
        defaultRateObservation?.invalidate()
        defaultRateObservation = nil
        if let failedToEndObserver { notificationCenter.removeObserver(failedToEndObserver) }
        failedToEndObserver = nil
    }

    /// Stops and releases the player. Idempotent: a second call finds nothing to stop. The window
    /// and view are released by the caller (`close()` now, `windowWillClose` on the next turn).
    /// The periodic time observer goes with the item observers, before `player` is dropped:
    /// its token can only be removed from the player that holds it.
    private func stopPlayback() {
        generation += 1
        isCurrentItemReady = false
        isStartSettled = false
        isResuming = false
        pendingStartAt = nil
        pendingSeekTarget = nil
        removeItemObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView?.setValue(nil, forKey: "player")
        player = nil
        menuActions = []
        // Nothing of the lecture survives the window: no fetch, no picture, no record, no
        // remote commands.
        cancelArtwork()
        artworkURL = nil
        nowPlayingMetadata = nil
        lastNowPlaying = nil
        if isPublishingNowPlaying {
            isPublishingNowPlaying = false
            nowPlaying.deactivate()
        }
        // The window goes with the lecture: the next one opens at fit. The view is not touched,
        // it is being released.
        zoom = .fit
        (window as? RecordingPlayerWindow)?.isVideoZoomed = false
        restoreActivationPolicy()
    }

    /// Detaches the view from a closing window, so nothing AVKit holds survives through it.
    private static func release(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        window.contentView = nil
        window.delegate = nil
        (window as? RecordingPlayerWindow)?.shortcutHandler = nil
        (window as? RecordingPlayerWindow)?.zoomHandler = nil
        while !window.titlebarAccessoryViewControllers.isEmpty { window.removeTitlebarAccessoryViewController(at: 0) }
    }
}

/// Loads AVKit only when the first recording is played.
///
/// Linking AVKit makes dyld load it, and everything it depends on, at every launch. Measured in
/// the review of issue #148 (macOS 27, arm64): BeepBar's Release binary loads 586 images at
/// launch, AVFoundation already among them (a probe linking the same system frameworks shows it
/// arrives with them), so using AVFoundation costs nothing at launch; linking AVKit raised it to
/// 921 (CallKit, Contacts, CloudKit, MediaRemote, picture in picture, Siri…), about +3.5 ms of
/// warm launch and +0.25 MB, for every user, including those who never press Play. Loaded on
/// demand, the cost moves to the first Play: a probe with the same system links (and
/// `NSApplication` up) went from 656 images to 920 after `dlopen` and 1151 once an
/// `AVPlayerView` with its `AVPlayer` existed.
/// An Objective-C framework cannot be unloaded, so after the first Play it stays mapped until
/// quit; the player's own objects are still released on close.
///
/// The view is built through the Objective-C runtime and configured with key-value coding, the
/// only way to reach a class from a framework the binary does not link.
@MainActor enum AVKitLoader {
    static let frameworkPath = "/System/Library/Frameworks/AVKit.framework/AVKit"
    /// `AVPlayerViewControlsStyle` raw values, checked against `AVKit/AVPlayerView.h` (macOS 27
    /// SDK): None 0, Inline 1, Floating 2, Minimal 3, Default = Inline. The enum cannot be named
    /// without importing AVKit, so the numbers are spelled out here.
    static let inlineControlsStyle = 1
    static let floatingControlsStyle = 2

    /// What every player view is configured with, in order: key, value. Each key is set only when
    /// the view has its setter (`configureControls`).
    ///
    /// - `controlsStyle` inline: a compact bar docked at the bottom edge of the view, instead of
    ///   the floating panel the lecture was covered by (product owner, 2026-10-14: "too high and
    ///   too big"). Measured on macOS 27 with a 960x540 view: the floating panel is 457x100 pt
    ///   with its bottom 86 pt above the edge (up to 186 pt); the inline bar is 750x36 pt, 6 pt
    ///   above the edge, with AirPlay and volume moved to two small pills in the top corners.
    ///   Both keep play/pause, the scrubber with elapsed and remaining time, volume, AirPlay and
    ///   AVKit's speed button. AVKit always uses the floating style in full screen (header,
    ///   macOS 11+), which BeepBar cannot change without hiding the system controls altogether.
    /// - Frame stepping, sharing, full-screen and timecode buttons stay off (AVKit's defaults,
    ///   set explicitly so a changed default cannot crowd the bar): frame stepping replaces the
    ///   skips with buttons nobody needs for a lecture, the share button would offer a stream
    ///   address that needs the Webex ticket, and full screen already has the window's green
    ///   button and F.
    /// - `allowsMagnification` off: AVKit's own pinch stays off so it cannot put two handlers on
    ///   one pinch; the player window handles every pinch itself, see
    ///   `RecordingPlayerController.zoom`.
    static let controlsConfiguration: [(key: String, value: Any)] = [
        ("controlsStyle", inlineControlsStyle),
        ("showsFrameSteppingButtons", false),
        ("showsSharingServiceButton", false),
        ("showsFullScreenToggleButton", false),
        ("showsTimecodes", false),
        ("allowsMagnification", false),
    ]

    private static var attempted = false
    private static var playerViewClass: NSView.Type?

    /// A new `AVPlayerView`, or nil if AVKit cannot be loaded. The load is attempted once per
    /// process. Its controls are configured by the controller (`configureControls`), for every
    /// view it builds, so an injected view is configured the same way.
    static func makePlayerView() -> NSView? {
        loadIfNeeded()
        guard let playerViewClass else { return nil }
        let view = (playerViewClass as NSObject.Type).init()
        // Key-value coding on a key the object lacks raises an Objective-C exception, which Swift
        // cannot catch: check both setters exist before using them.
        guard let view = view as? NSView,
              view.responds(to: NSSelectorFromString("setPlayer:")),
              view.responds(to: NSSelectorFromString("setControlsStyle:")) else { return nil }
        return view
    }

    /// Applies `controlsConfiguration` to `view`, skipping each key whose setter the view lacks
    /// (a test view, or a future AVKit without it): key-value coding on a missing key raises an
    /// Objective-C exception Swift cannot catch.
    static func configureControls(of view: NSView) {
        for (key, value) in controlsConfiguration {
            let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
            if view.responds(to: NSSelectorFromString(setter)) { view.setValue(value, forKey: key) }
        }
    }

    /// Calls `-[AVPlayerView setMagnification:centeredAtPoint:]` (macOS 13+): scales the video
    /// only, under the controls, keeping `point` (unzoomed view coordinates) where it is on
    /// screen. Returns false, doing nothing, on a view without it (a test view, or a future AVKit
    /// without the method). Called through its implementation pointer because it takes a
    /// `CGFloat` and a `CGPoint`, which key-value coding and `perform(_:with:)` cannot pass; AVKit
    /// clamps the factor to 1…64 itself, the player to 1…4 before (`PlayerZoomModel`).
    @discardableResult
    static func setMagnification(_ magnification: CGFloat, centeredAt point: CGPoint, of view: NSView) -> Bool {
        let selector = NSSelectorFromString("setMagnification:centeredAtPoint:")
        guard view.responds(to: selector), let method = class_getInstanceMethod(type(of: view), selector) else { return false }
        typealias SetMagnification = @convention(c) (NSView, Selector, CGFloat, CGPoint) -> Void
        let setMagnification = unsafeBitCast(method_getImplementation(method), to: SetMagnification.self)
        setMagnification(view, selector, magnification, point)
        return true
    }

    /// `AVPlaybackSpeed` objects for `rates` (macOS 13+), for `AVPlayerView.speeds`, or nil when
    /// the class or its initializer is missing.
    ///
    /// `-[AVPlaybackSpeed initWithRate:localizedName:]` takes a `float`, which neither key-value
    /// coding nor `perform(_:with:)` can pass, so it is called through its implementation
    /// pointer, with the ownership Objective-C defines for `alloc` and `init`: `alloc` returns a
    /// +1 object, `init` consumes it and returns a +1 result, taken here exactly once.
    static func makePlaybackSpeeds(_ rates: [Float]) -> [NSObject]? {
        loadIfNeeded()
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithRate:localizedName:")
        guard let speedClass = NSClassFromString("AVPlaybackSpeed"),
              speedClass.instancesRespond(to: initSelector),
              let allocMethod = class_getClassMethod(speedClass, allocSelector),
              let initMethod = class_getInstanceMethod(speedClass, initSelector) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, Float, NSString) -> UnsafeMutableRawPointer?
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initialize.self)
        var speeds: [NSObject] = []
        for rate in rates {
            guard let allocated = alloc(speedClass, allocSelector),
                  let initialized = initialize(allocated, initSelector, rate, RecordingPlayerPolicy.speedLabel(rate) as NSString) else { return nil }
            speeds.append(Unmanaged<NSObject>.fromOpaque(initialized).takeRetainedValue())
        }
        return speeds
    }

    private static func loadIfNeeded() {
        guard !attempted else { return }
        attempted = true
        if dlopen(frameworkPath, RTLD_LAZY) != nil {
            playerViewClass = NSClassFromString("AVPlayerView") as? NSView.Type
        }
    }
}
