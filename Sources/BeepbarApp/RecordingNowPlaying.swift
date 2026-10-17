import AppKit
import BeepbarCore
import OSLog
// No `import MediaPlayer`, on purpose: see `MediaPlayerLoader`.

// What macOS shows for the lecture playing in BeepBar's player: Control Center's Now Playing,
// the menu bar's Now Playing item, the media keys and AirPods controls (issue #148 follow-up,
// "Now Playing shows only BeepBar").
//
// Why BeepBar publishes this itself. `AVPlayerView` publishes Now Playing on its own
// (`updatesNowPlayingInfoCenter`, on by default), but on macOS it takes the title, artist and
// artwork only from the stream's own metadata. A Webex lecture stream has none, so the system
// fell back to the app's name: "BeepBar", with no lecture and no course. Measured with a probe
// reading MediaRemote's now-playing record (macOS 27): AVKit's record had duration, rate and
// elapsed time and no title, artist or artwork. The iOS ways to supply them do not exist on
// macOS: `AVPlayerItem.externalMetadata` and `AVPlayerItem.nowPlayingInfo` are iOS/tvOS only
// (neither selector exists at runtime on macOS, with or without AVKit loaded), and
// `MPNowPlayingSession` is unavailable. Writing `MPNowPlayingInfoCenter` while AVKit also
// publishes does not work either: the probe saw AVKit replace the title at its next update (a
// pause). So the player turns AVKit's publication off and publishes the whole record, and the
// remote commands (play, pause, skips, scrubbing) that go with it, through MediaPlayer.

/// What the Now Playing record says about a lecture: its title, the course it belongs to, and the
/// course's picture on WeBeep. Handed to `RecordingPlaying.play`; nil there keeps the plain
/// window title as the only text, with no course and no picture.
///
/// No credential in here: `artworkURL` is the bare `RemoteCourseSummary.imageURL`; the token is
/// added by the loader the player was given (`RecordingArtwork.Loader`).
struct RecordingPlaybackMetadata: Equatable, Sendable {
    var title: String
    var courseName: String
    var artworkURL: URL?

    init(title: String, courseName: String, artworkURL: URL?) {
        self.title = title
        self.courseName = courseName
        self.artworkURL = artworkURL
    }

    /// The metadata of `recording` playing from a stream titled `streamTitle`, in `course`: the
    /// row's own title (`RecordingsPresentation.title`, the archive's, or the stream's when the
    /// archive has none), the course as the Recordings sidebar names it, and its picture.
    init(recording: RecmanRecording, course: RemoteCourseSummary?, streamTitle: String? = nil) {
        let title = recording.title.isEmpty ? (streamTitle ?? "") : recording.title
        self.init(title: title.isEmpty ? RecordingsPresentation.title(recording) : title,
                  courseName: course.map(RecordingsPresentation.courseName) ?? "",
                  artworkURL: course?.imageURL)
    }

    /// The WeBeep course `recording` belongs to among `courses`, matched as the Recordings page
    /// matches them (`RecmanCourseKey`): nil when none, or more than one, has its code and year.
    static func course(of recording: RecmanRecording, in courses: [RemoteCourseSummary]) -> RemoteCourseSummary? {
        guard let key = RecmanCourseKey(courseCode: recording.courseCode, academicYear: recording.academicYear) else { return nil }
        let matches = courses.filter { RecmanCourseKey(course: $0) == key }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// The Now Playing record as the player last described it. Equatable so an identical record is
/// never published twice (cost proportional to what changed).
struct NowPlayingState: Equatable {
    var title: String
    /// The course; empty for none.
    var artist: String
    /// Seconds, nil while unknown.
    var duration: TimeInterval?
    /// Seconds from the start: where the student is, or is going (an in-flight seek).
    var elapsed: TimeInterval
    /// The player's current rate: 0 while paused.
    var rate: Float
    /// The speed play resumes at (the student's chosen speed).
    var defaultRate: Float
    var isPlaying: Bool
    /// The course picture, nil until it arrives or when there is none (the publisher then shows
    /// the app's icon).
    var artwork: RecordingArtworkImage?
}

/// A remote command the system sent (Control Center, media keys, headphones, the Touch Bar).
enum NowPlayingCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    /// Seconds to move, negative backwards.
    case skip(TimeInterval)
    /// Seconds from the start to go to (scrubbing in Control Center).
    case seek(TimeInterval)
}

/// Publishes the Now Playing record and receives the remote commands. A protocol so the player is
/// tested with a fake that records every publication and never touches MediaPlayer.
@MainActor protocol NowPlayingPublishing: AnyObject {
    /// Takes over Now Playing for a player window: registers the remote commands, which arrive
    /// on the main actor through `onCommand`. Returns false when it cannot (MediaPlayer did not
    /// load); the player then leaves AVKit's own publication on, as before. Idempotent.
    func activate(onCommand: @escaping @MainActor (NowPlayingCommand) -> Void) -> Bool
    /// Replaces the record. Only called between `activate` and `deactivate`.
    func publish(_ state: NowPlayingState)
    /// Clears the record (state Stopped) and removes and disables the commands. Idempotent; safe
    /// without `activate`.
    func deactivate()
}

/// The rules of the Now Playing record, pure so tests pin them without MediaPlayer.
enum RecordingNowPlayingPolicy {
    /// MediaPlayer's keys, as the strings its constants hold (`MPMediaItemPropertyTitle` is
    /// "title", and so on). Spelled out because MediaPlayer is not linked; a test reads the real
    /// constants with `dlsym` and checks every one.
    enum Key {
        static let title = "title"
        static let artist = "artist"
        static let duration = "playbackDuration"
        static let artwork = "artwork"
        static let elapsed = "MPNowPlayingInfoPropertyElapsedPlaybackTime"
        static let rate = "MPNowPlayingInfoPropertyPlaybackRate"
        static let defaultRate = "MPNowPlayingInfoPropertyDefaultPlaybackRate"
        static let mediaType = "MPNowPlayingInfoPropertyMediaType"
    }
    /// `MPNowPlayingInfoMediaTypeVideo`.
    static let videoMediaType = 2
    /// `MPNowPlayingPlaybackState`: playing, paused, stopped. The header's order is Unknown 0,
    /// Playing 1, Paused 2, Stopped 3, Interrupted 4; a test checks each against the real enum.
    /// Closing the player must say Stopped: Interrupted (4, the value written before issue #192)
    /// tells the system playback will resume, so it may keep BeepBar as a paused Now Playing app.
    static let playingState = 1
    static let pausedState = 2
    static let stoppedState = 3
    /// `MPRemoteCommandHandlerStatus.success`, the only status returned: the handler answers at
    /// once and hands the command to the main actor, where one that cannot apply (a seek before
    /// the lecture has a timeline) simply does nothing.
    static let commandSucceeded = 0
    /// The skip the remote commands offer, as the player's own ±10 s (`PlayerShortcut`).
    static let skipInterval: TimeInterval = 10
    /// Longest title or course name published; Recman titles are short, this only bounds a
    /// pathological one.
    static let maximumTextLength = 200

    /// The metadata to show: `metadata` cleaned, with `fallbackTitle` (the window title the
    /// caller gave) when it has no title, and a neutral title when neither has one. The artwork
    /// address is dropped unless `acceptsArtworkURL` accepts it.
    nonisolated static func resolved(_ metadata: RecordingPlaybackMetadata?, fallbackTitle: String, policy: WeBeepServerPolicy = .production) -> RecordingPlaybackMetadata {
        let title = cleaned(metadata?.title ?? "").nonEmpty ?? cleaned(fallbackTitle).nonEmpty ?? tr("Lezione registrata", "Recorded lecture")
        let artwork = metadata?.artworkURL.flatMap { acceptsArtworkURL($0, policy: policy) ? $0 : nil }
        return RecordingPlaybackMetadata(title: title, courseName: cleaned(metadata?.courseName ?? ""), artworkURL: artwork)
    }

    /// `text` on one line, without surrounding spaces, at most `maximumTextLength` characters.
    nonisolated static func cleaned(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let line = words.joined(separator: " ")
        return line.count > maximumTextLength ? String(line.prefix(maximumTextLength - 1)) + "…" : line
    }

    /// Whether the player may fetch `url` as artwork: an HTTPS web-service `pluginfile.php`
    /// address on WeBeep's own host, with no credential of its own and no user, password,
    /// fragment or odd port (`WeBeepCourseImage.acceptable`, which `RemoteCourseSummary.imageURL`
    /// already passed). Everything else (`http`, `file`, `data`, another host) is never fetched:
    /// the loader adds the student's token, which must only ever go to WeBeep.
    nonisolated static func acceptsArtworkURL(_ url: URL, policy: WeBeepServerPolicy = .production) -> Bool {
        WeBeepCourseImage.acceptable(url.absoluteString, policy: policy) == url
    }

    /// The record for `state`, without the artwork (an object only the publisher can make).
    nonisolated static func info(_ state: NowPlayingState) -> [String: Any] {
        var info: [String: Any] = [
            Key.title: state.title,
            Key.elapsed: max(0, state.elapsed.isFinite ? state.elapsed : 0),
            Key.rate: Double(state.rate),
            Key.defaultRate: Double(state.defaultRate),
            Key.mediaType: videoMediaType,
        ]
        if !state.artist.isEmpty { info[Key.artist] = state.artist }
        if let duration = state.duration { info[Key.duration] = duration }
        return info
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A decoded course picture, shared by reference so publishing the same record twice costs no
/// copy and equality is identity.
final class RecordingArtworkImage: Equatable, @unchecked Sendable {
    // `@unchecked`: a `CGImage` is immutable once made.
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
    static func == (lhs: RecordingArtworkImage, rhs: RecordingArtworkImage) -> Bool { lhs === rhs }
}

/// Fetching and decoding a course picture for Now Playing, bounded in every direction: one
/// request at a time per player (the player cancels the previous one), `timeout` in all,
/// `maximumBytes` of answer, a source of at most `maximumSourcePixels`, decoded off the main
/// actor straight to a thumbnail of at most `maximumPixelSize` on its longer side.
enum RecordingArtwork {
    /// Fetches the bytes at an address `RecordingNowPlayingPolicy.acceptsArtworkURL` accepted.
    /// Injected into the player, so tests never reach the network and the token stays with the
    /// code that owns it (`WeBeepAuthenticationController.courseImage`).
    typealias Loader = @Sendable (URL) async throws -> Data

    static let maximumBytes = WeBeepAPIClient.courseImageByteLimit
    static let timeout: Duration = .seconds(WeBeepAPIClient.courseImageTimeout)
    /// Control Center draws the artwork at well under 100 points; 512 px covers every Retina size
    /// at a fraction of a full picture's memory (512×512×4 bytes = 1 MiB at most).
    static let maximumPixelSize = 512
    /// A small file can claim a huge picture (a 2 MB PNG of 20000×20000 pixels); making a
    /// thumbnail of it would decode it whole. Such a source is refused before decoding.
    static let maximumSourcePixels = 40_000_000

    enum Failure: Error, Equatable {
        case timedOut
        case tooLarge
        case undecodable
    }

    /// Fetches and decodes `url`. Runs off the main actor (`@concurrent`), so neither the wait nor
    /// the decoding ever touches the main thread. Throws `CancellationError` when cancelled.
    @concurrent
    static func load(_ url: URL, loader: @escaping Loader, timeout: Duration = timeout, maximumBytes: Int = maximumBytes) async throws -> RecordingArtworkImage {
        let data = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await loader(url) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timedOut }
            guard let data = first else { throw Failure.timedOut }
            return data
        }
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard let image = decode(data) else { throw Failure.undecodable }
        return RecordingArtworkImage(image)
    }

    /// A thumbnail of at most `maximumPixelSize` on its longer side, or nil when `data` is not a
    /// picture ImageIO reads, or claims more than `maximumSourcePixels`.
    nonisolated static func decode(_ data: Data, maximumPixelSize: Int = maximumPixelSize, maximumSourcePixels: Int = maximumSourcePixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width.multipliedReportingOverflow(by: height).partialValue <= maximumSourcePixels,
              !width.multipliedReportingOverflow(by: height).overflow else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// What the log may say about a failed fetch: the failure's name, or the error's domain and
    /// code (`PlaybackDiagnostics.errorName`). Never a description or a `userInfo` value: a
    /// `URLError` carries the failing address, and with it the student's token.
    nonisolated static func logDescription(_ error: Error) -> String {
        if let failure = error as? Failure { return "\(failure)" }
        if let error = error as? WeBeepAPIError {
            switch error {
            case .transport(let status): return "transport(\(status))"
            case .network(let failure): return "network(\(failure))"
            default: return "\(error)"
            }
        }
        return PlaybackDiagnostics.errorName(error)
    }
}

/// Loads MediaPlayer only when the first lecture plays, as `AVKitLoader` does for AVKit.
///
/// Measured (macOS 27, arm64, a probe with `NSApplication` up): with AVKit loaded and an
/// `AVPlayerView` built, which is the state of the first Play, 1151 images; `dlopen` of
/// MediaPlayer then adds 2 (MediaPlayer itself and MusicLibrary). Linking it instead would load it
/// and its dependencies at every launch, for users who never press Play. The framework cannot be
/// unloaded, so it stays mapped until quit after the first Play.
@MainActor enum MediaPlayerLoader {
    static let frameworkPath = "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer"
    private static var attempted = false
    private static var loaded = false

    /// Whether MediaPlayer is available, loading it on the first call.
    static func load() -> Bool {
        if !attempted {
            attempted = true
            loaded = dlopen(frameworkPath, RTLD_LAZY) != nil
                && NSClassFromString("MPNowPlayingInfoCenter") != nil
                && NSClassFromString("MPRemoteCommandCenter") != nil
        }
        return loaded
    }
}

/// The real Now Playing publisher: `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, reached
/// through the Objective-C runtime because MediaPlayer is loaded at runtime (`MediaPlayerLoader`).
///
/// Costs nothing until `activate`: creating it loads nothing. Each key-value call is preceded by a
/// check that the object responds to it, since key-value coding on a missing key raises an
/// Objective-C exception Swift cannot catch.
@MainActor final class SystemNowPlaying: NowPlayingPublishing {
    /// Each registered command with the target MediaPlayer returned for it, kept to remove it.
    private var targets: [(command: NSObject, target: AnyObject)] = []
    private var center: NSObject?
    /// The artwork object last made, with the picture it shows (nil: the app icon), so publishing
    /// the same picture again reuses it.
    private var artworkObject: (image: RecordingArtworkImage?, object: NSObject)?

    func activate(onCommand: @escaping @MainActor (NowPlayingCommand) -> Void) -> Bool {
        if center != nil { return true }
        guard MediaPlayerLoader.load(),
              let center = Self.classObject("MPNowPlayingInfoCenter", "defaultCenter"),
              let commands = Self.classObject("MPRemoteCommandCenter", "sharedCommandCenter") else { return false }
        self.center = center
        let succeeded = RecordingNowPlayingPolicy.commandSucceeded
        // The handler runs on whatever thread MediaPlayer calls it on: it reads the event there,
        // answers at once, and hands the command to the main actor (the same hop as every AppKit
        // callback in BeepBar, never `assumeIsolated`).
        func register(_ name: String, _ command: @escaping @Sendable (NSObject) -> NowPlayingCommand?) {
            guard commands.responds(to: NSSelectorFromString(name)), let remote = commands.value(forKey: name) as? NSObject,
                  remote.responds(to: NSSelectorFromString("addTargetWithHandler:")) else { return }
            if remote.responds(to: NSSelectorFromString("setPreferredIntervals:")) {
                remote.setValue([NSNumber(value: RecordingNowPlayingPolicy.skipInterval)], forKey: "preferredIntervals")
            }
            if remote.responds(to: NSSelectorFromString("setEnabled:")) { remote.setValue(true, forKey: "enabled") }
            let handler: @convention(block) (NSObject) -> Int = { event in
                if let received = command(event) {
                    Task { @MainActor in onCommand(received) }
                }
                return succeeded
            }
            guard let target = remote.perform(NSSelectorFromString("addTargetWithHandler:"), with: handler)?.takeUnretainedValue() else { return }
            targets.append((remote, target))
        }
        register("playCommand") { _ in .play }
        register("pauseCommand") { _ in .pause }
        register("togglePlayPauseCommand") { _ in .togglePlayPause }
        register("skipForwardCommand") { event in .skip(Self.double(event, "interval") ?? RecordingNowPlayingPolicy.skipInterval) }
        register("skipBackwardCommand") { event in .skip(-(Self.double(event, "interval") ?? RecordingNowPlayingPolicy.skipInterval)) }
        register("changePlaybackPositionCommand") { event in Self.double(event, "positionTime").map { .seek($0) } }
        return true
    }

    func publish(_ state: NowPlayingState) {
        guard let center else { return }
        var info = RecordingNowPlayingPolicy.info(state)
        if let artwork = artwork(for: state.artwork) { info[RecordingNowPlayingPolicy.Key.artwork] = artwork }
        Self.setInfo(info, on: center)
        if center.responds(to: NSSelectorFromString("setPlaybackState:")) {
            let playback = state.isPlaying ? RecordingNowPlayingPolicy.playingState : RecordingNowPlayingPolicy.pausedState
            center.setValue(playback, forKey: "playbackState")
        }
    }

    /// Gives Now Playing back when the player window closes. The commands are app-wide
    /// singletons that `activate` enabled, so each is also disabled (issue #199): removing the
    /// target alone left them enabled with nothing behind them, which can keep BeepBar a
    /// candidate for the media keys after the lecture closed. Safe because nothing else in the
    /// app uses them once the window is gone (AVKit's publication was off for that window, and
    /// the next `activate` enables them again).
    func deactivate() {
        for (command, target) in targets {
            _ = command.perform(NSSelectorFromString("removeTarget:"), with: target)
            if command.responds(to: NSSelectorFromString("setEnabled:")) { command.setValue(false, forKey: "enabled") }
        }
        targets = []
        artworkObject = nil
        guard let center else { return }
        self.center = nil
        Self.setInfo(nil, on: center)
        if center.responds(to: NSSelectorFromString("setPlaybackState:")) {
            center.setValue(RecordingNowPlayingPolicy.stoppedState, forKey: "playbackState")
        }
    }

    /// The `MPMediaItemArtwork` for `image`, or for the app's icon when there is none: macOS
    /// shows the app's icon anyway when a record has no artwork, and publishing it explicitly
    /// keeps the record the same on every macOS version.
    private func artwork(for image: RecordingArtworkImage?) -> NSObject? {
        if let artworkObject, artworkObject.image == image { return artworkObject.object }
        let picture: NSImage
        if let image {
            picture = NSImage(cgImage: image.image, size: NSSize(width: image.image.width, height: image.image.height))
        } else {
            picture = NSApplication.shared.applicationIconImage
        }
        guard let object = Self.makeArtwork(picture) else { return nil }
        artworkObject = (image, object)
        return object
    }

    /// `-[MPMediaItemArtwork initWithBoundsSize:requestHandler:]`, called through its
    /// implementation pointer because it takes a `CGSize`, with Objective-C's ownership for
    /// `alloc` and `init` (as `AVKitLoader.makePlaybackSpeeds`). The handler may run on any
    /// thread: it only returns the immutable picture.
    private static func makeArtwork(_ picture: NSImage) -> NSObject? {
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithBoundsSize:requestHandler:")
        guard let artworkClass = NSClassFromString("MPMediaItemArtwork"), artworkClass.instancesRespond(to: initSelector),
              let allocMethod = class_getClassMethod(artworkClass, allocSelector),
              let initMethod = class_getInstanceMethod(artworkClass, initSelector) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, CGSize, AnyObject) -> UnsafeMutableRawPointer?
        let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initialize.self)
        let box = PictureBox(picture)
        let handler: @convention(block) (CGSize) -> NSImage = { _ in box.picture }
        guard let allocated = alloc(artworkClass, allocSelector),
              let initialized = initialize(allocated, initSelector, picture.size, handler as AnyObject) else { return nil }
        return Unmanaged<NSObject>.fromOpaque(initialized).takeRetainedValue()
    }

    /// Sets `nowPlayingInfo`, only if the center has the setter (see the type's comment).
    private static func setInfo(_ info: [String: Any]?, on center: NSObject) {
        guard center.responds(to: NSSelectorFromString("setNowPlayingInfo:")) else { return }
        center.setValue(info, forKey: "nowPlayingInfo")
    }

    /// `[Class sharedThing]` for a class loaded at runtime, or nil.
    private static func classObject(_ className: String, _ selector: String) -> NSObject? {
        guard let type = NSClassFromString(className) as? NSObject.Type, type.responds(to: NSSelectorFromString(selector)) else { return nil }
        return type.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? NSObject
    }

    /// A finite number property of a command event, or nil.
    nonisolated private static func double(_ event: NSObject, _ key: String) -> TimeInterval? {
        guard event.responds(to: NSSelectorFromString(key)), let value = (event.value(forKey: key) as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }
}

/// Carries the artwork picture into MediaPlayer's request handler, which may run on any thread.
/// `@unchecked`: the picture is never changed after it is made.
private final class PictureBox: @unchecked Sendable {
    let picture: NSImage
    init(_ picture: NSImage) { self.picture = picture }
}
