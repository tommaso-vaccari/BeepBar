import AppKit
import CryptoKit
import BeepbarCore
import OSLog

/// What the player's Audio menu shows for the lecture on screen.
enum AudioEnhancementState: Equatable, Sendable {
    /// No ffmpeg where package managers install it: the menu says how to get it.
    case needsFFmpeg
    /// The lecture plays Webex's own stream; the switch turns enhanced audio on.
    case off
    /// The lecture plays through the local filter (`LiveAudioSession`).
    case on
    /// Enhanced audio stopped working for this lecture (ffmpeg failed, the stream isn't the
    /// layout it understands): the lecture went back to its own stream, and the switch tries
    /// again. The message is already bilingual.
    case failed(BilingualText)
}

/// What the player's Audio menu shows for one state: pure, so tests check every state's text
/// and action without a window.
struct AudioMenuPresentation: Equatable {
    struct Item: Equatable {
        let title: String
        /// nil: shown disabled.
        let action: PlayerAudioAction?
        var checked = false
    }
    let main: Item
    /// A second line, disabled: why the last attempt failed; nil for none.
    let detail: Item?
}

extension RecordingPlayerPolicy {
    /// The Audio menu for `state`, in the current language; nil hides the section.
    static func audioMenu(_ state: AudioEnhancementState?) -> AudioMenuPresentation? {
        guard let state else { return nil }
        let title = tr("Audio migliorato", "Enhanced audio")
        switch state {
        case .needsFFmpeg:
            return AudioMenuPresentation(main: .init(title: tr("Audio migliorato: installa ffmpeg (brew install ffmpeg)", "Enhanced audio: install ffmpeg (brew install ffmpeg)"), action: nil), detail: nil)
        case .off:
            return AudioMenuPresentation(main: .init(title: title, action: .useEnhanced(true)), detail: nil)
        case .on:
            return AudioMenuPresentation(main: .init(title: title, action: .useEnhanced(false), checked: true), detail: nil)
        case .failed(let message):
            return AudioMenuPresentation(main: .init(title: title, action: .useEnhanced(true)), detail: .init(title: message.text, action: nil))
        }
    }
}

/// The enhanced-audio switch in the player's title bar, next to the speed menu: the same choice
/// as the Audio menu's main item, always in sight. Pure, like `AudioMenuPresentation`.
struct AudioButtonPresentation: Equatable {
    /// Lit: the lecture plays through the filter.
    let isOn: Bool
    /// What a click asks for; nil: shown disabled (no ffmpeg).
    let action: PlayerAudioAction?
    /// What hovering shows: the switch's name and state, how to get ffmpeg, or why it failed.
    let toolTip: String
}

extension RecordingPlayerPolicy {
    /// The title-bar switch for `state`, in the current language; nil hides it (no lecture, or
    /// no account the lecture's state could belong to).
    static func audioButton(_ state: AudioEnhancementState?) -> AudioButtonPresentation? {
        guard let state, let menu = audioMenu(state) else { return nil }
        let toolTip: String
        switch state {
        case .needsFFmpeg: toolTip = menu.main.title
        case .off: toolTip = tr("Audio migliorato: spento. Fai clic per ridurre il rumore dell'aula e far risaltare la voce.", "Enhanced audio: off. Click to reduce classroom noise and bring the voice forward.")
        case .on: toolTip = tr("Audio migliorato: acceso. Fai clic per tornare all'audio originale.", "Enhanced audio: on. Click to go back to the original audio.")
        case .failed(let message): toolTip = message.text
        }
        return AudioButtonPresentation(isOn: menu.main.checked, action: menu.main.action, toolTip: toolTip)
    }
}

/// Why a live session stopped serving, as it reports it before answering the player with an
/// error (`LiveAudioPipeline`), so the controller knows what the player's failure means.
enum LiveAudioFailure: Equatable, Sendable {
    /// Webex refused the lecture's address (401/403/404/410): it expired. A fresh stream from the
    /// archive fixes it, so the usual recovery runs and the filter is rebuilt from the new address.
    case streamRefused
    /// Webex or the connection failed for now (offline, a timeout, a 5xx): not the filter's
    /// fault. The usual recovery runs, as it would without the filter, and the filter is
    /// rebuilt from the fresh stream; enhanced audio isn't turned off.
    case network
    /// Anything else: not the Webex layout, ffmpeg failing, a range not honoured, the disk. The
    /// lecture goes back to its own stream; retrying would fail the same way.
    case unavailable
}

/// One lecture being filtered while it plays: a local playlist address for AVPlayer, until
/// `stop`. The real one is `LiveAudioSession`; tests use a stand-in.
@MainActor protocol LiveAudioStreaming: AnyObject {
    /// `http://127.0.0.1:<port>/<token>/index.m3u8`. Carries the session's secret: never logged.
    var playlistURL: URL { get }
    /// Stops serving, ends every fetch and ffmpeg run, deletes the session's files. Idempotent.
    func stop()
}

/// Turns enhanced audio on and off for the lecture on screen: finds the student's ffmpeg,
/// starts and stops the one live session (`LiveAudioStreaming`), and remembers per lecture
/// that the filter failed, so a recovery or a later Play doesn't try it again in a loop.
///
/// Lifetime: created on first use (a lecture opening in the player), never at launch; costs
/// nothing while enhanced audio is off: no server, no process, no files.
///
/// Identity: a session filters one stream, fetched with that stream's own short-lived address;
/// nothing outlives it on disk. Failures are kept in memory by lecture key (`copyKey`), hashed
/// with the account, and dropped by `removeAll` ("forget study data", an account change).
@MainActor final class AudioEnhancer {
    private static let log = Logger(subsystem: "io.github.tvaccari.beepbar", category: "AudioEnhancer")

    /// Called on the main actor whenever a lecture's state changes, with its key (`copyKey`).
    var onChange: ((String) -> Void)?

    typealias MakeSession = @MainActor (_ stream: URL, _ ffmpeg: URL, _ onFailure: @escaping @MainActor (LiveAudioFailure) -> Void) throws -> LiveAudioStreaming

    private let locateFFmpeg: () -> URL?
    private let makeSession: MakeSession
    private var session: (key: String, id: Int, streaming: LiveAudioStreaming)?
    private var sessionCount = 0
    /// What the running session reported last before failing the player, if anything. A
    /// refusal stays once heard: an expired address never works again, whatever fails after.
    private(set) var reportedFailure: LiveAudioFailure?
    /// Lectures whose filter failed, until the student turns it on again.
    private var failures: [String: BilingualText] = [:]

    init(locateFFmpeg: @escaping () -> URL? = { AudioEnhancement.locateFFmpeg() },
         makeSession: @escaping MakeSession = { try LiveAudioSession(stream: $0, ffmpeg: $1, onFailure: $2) },
         legacyCopies: URL? = AudioEnhancer.legacyCopiesFolder()) {
        self.locateFFmpeg = locateFFmpeg
        self.makeSession = makeSession
        // The first version kept whole enhanced copies of lectures (up to ~3 GB) in Caches; this
        // one keeps none. Removed off the main thread when the enhancer is first needed, not at
        // launch, and only ever this folder.
        if let legacyCopies {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: legacyCopies) }
        }
    }

    /// `~/Library/Caches/<bundle id>/EnhancedAudio`, the first version's copies; nil for an
    /// unbundled process (a test runner), which must never touch the installed app's caches.
    nonisolated static func legacyCopiesFolder() -> URL? {
        guard let id = Bundle.main.bundleIdentifier, id == "io.github.tvaccari.beepbar" else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(id, isDirectory: true).appendingPathComponent("EnhancedAudio", isDirectory: true)
    }

    /// The key a lecture's state goes under, for `owner`'s account: a hash, so nothing kept
    /// says which lecture it is, and another account's lecture never matches.
    nonisolated static func copyKey(owner: Int, identity: String) -> String {
        let digest = SHA256.hash(data: Data("\(owner)\u{0}\(identity)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// What the menu shows for `key`; `inUse` is the caller's (it knows what the player plays).
    func state(for key: String, inUse: Bool) -> AudioEnhancementState {
        if inUse { return .on }
        if locateFFmpeg() == nil { return .needsFFmpeg }
        if let failure = failures[key] { return .failed(failure) }
        return .off
    }

    /// Whether a Play of `key` may start on the filter: ffmpeg is there and it hasn't failed.
    func canStart(_ key: String) -> Bool { failures[key] == nil && locateFFmpeg() != nil }

    /// Starts filtering `stream` for `key`, replacing any session, and returns the address the
    /// player plays; nil without ffmpeg or when the session can't start (no local port).
    func start(key: String, stream: URL) -> URL? {
        stop()
        failures[key] = nil
        guard let ffmpeg = locateFFmpeg() else {
            onChange?(key)
            return nil
        }
        sessionCount += 1
        let id = sessionCount
        do {
            let streaming = try makeSession(stream, ffmpeg) { [weak self] failure in
                guard let self, self.session?.id == id, self.reportedFailure != .streamRefused else { return }
                self.reportedFailure = failure
            }
            session = (key, id, streaming)
            Self.log.notice("Enhanced audio on")
            return streaming.playlistURL
        } catch {
            Self.log.error("Enhanced audio couldn't start")
            markFailed(key)
            return nil
        }
    }

    /// Stops the running session, if any.
    func stop() {
        guard let current = session else { return }
        session = nil
        reportedFailure = nil
        current.streaming.stop()
        Self.log.notice("Enhanced audio off")
    }

    var isRunning: Bool { session != nil }

    /// The filter failed for `key`: the menu says so until the student tries again.
    func markFailed(_ key: String) {
        failures[key] = BilingualText("L'audio migliorato non ha funzionato per questa lezione: ora senti l'audio originale.",
                                      "Enhanced audio didn't work for this lecture: you're hearing the original audio.")
        onChange?(key)
    }

    /// Stops the session and forgets every failure: "Forget this account's study data", the
    /// feature turned off, or the account going away (disconnect, university or account change).
    /// Called only on an enhancer that exists: one never needed has nothing to forget.
    func removeAll() {
        stop()
        failures.removeAll()
    }
}
