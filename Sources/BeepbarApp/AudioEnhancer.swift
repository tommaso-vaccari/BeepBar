import AppKit
import CryptoKit
import BeepbarCore
import OSLog

/// What the player's Audio menu shows for the lecture on screen.
enum AudioEnhancementState: Equatable, Sendable {
    /// No ffmpeg where package managers install it: the menu says how to get it.
    case needsFFmpeg
    /// The lecture plays Webex's own stream. `preferred` is the kind the student chose last
    /// (`RecordingsController.resolveEnhancedAudioKind`): the one the title-bar switch turns on.
    case off(preferred: AudioEnhancementKind)
    /// The lecture plays through the local filter (`LiveAudioSession`) of this kind.
    case on(AudioEnhancementKind)
    /// Enhanced audio stopped working for this lecture (ffmpeg failed, the stream isn't the
    /// layout it understands): the lecture went back to its own stream, and choosing a kind
    /// tries again; `preferred` is the one the title-bar switch tries. The message is already
    /// bilingual.
    case failed(BilingualText, preferred: AudioEnhancementKind)
}

extension AudioEnhancementKind {
    /// The name the student sees for this kind, in the current language: built at use, never
    /// cached, so a language switch shows at once.
    var displayName: String {
        switch self {
        case .levelled: tr("Voce livellata", "Levelled voice")
        case .isolated: tr("Voce isolata", "Isolated voice")
        }
    }
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
    /// The three single-choice items, in order: Off, Levelled voice, Isolated voice. Exactly one
    /// is checked.
    let items: [Item]
    /// A second line, disabled: why the last attempt failed or how to get ffmpeg; nil for none.
    let detail: Item?
}

extension RecordingPlayerPolicy {
    /// The Audio menu for `state`, in the current language; nil hides the section.
    ///
    /// A bare "Audio" header above "Spento" would read as "audio muted", so the section is
    /// titled by the feature (`audioMenuHeader`), and the failed state checks "Spento": the
    /// lecture is on its own audio, and choosing a kind tries again.
    static func audioMenu(_ state: AudioEnhancementState?) -> AudioMenuPresentation? {
        guard let state else { return nil }
        let playing: AudioEnhancementKind?
        var enabled = true
        var detail: AudioMenuPresentation.Item?
        switch state {
        case .needsFFmpeg:
            playing = nil
            enabled = false
            detail = .init(title: ffmpegHint(), action: nil)
        case .off: playing = nil
        case .on(let kind): playing = kind
        case .failed(let message, _):
            playing = nil
            detail = .init(title: message.text, action: nil)
        }
        func item(_ title: String, _ kind: AudioEnhancementKind?) -> AudioMenuPresentation.Item {
            .init(title: title, action: kind == nil || enabled ? .use(kind) : nil, checked: kind == playing)
        }
        return AudioMenuPresentation(items: [item(tr("Spento", "Off"), nil),
                                             item(AudioEnhancementKind.levelled.displayName, .levelled),
                                             item(AudioEnhancementKind.isolated.displayName, .isolated)],
                                     detail: detail)
    }

    /// The header of the Audio section.
    static func audioMenuHeader() -> String { tr("Audio migliorato", "Enhanced audio") }

    /// How to get ffmpeg: the menu's detail line and the switch's tooltip without it.
    static func ffmpegHint() -> String {
        tr("Per l'audio migliorato installa ffmpeg (brew install ffmpeg)", "Enhanced audio needs ffmpeg (brew install ffmpeg)")
    }
}

/// The enhanced-audio switch in the player's title bar, next to the speed menu: a two-state
/// toggle between Off and the kind the student used last, always in sight. Pure, like
/// `AudioMenuPresentation`.
struct AudioButtonPresentation: Equatable {
    /// Lit: the lecture plays through the filter.
    let isOn: Bool
    /// What a click asks for; nil: shown disabled (no ffmpeg).
    let action: PlayerAudioAction?
    /// What hovering shows: the switch's name, state and mode, how to get ffmpeg, or why it failed.
    let toolTip: String
}

extension RecordingPlayerPolicy {
    /// The title-bar switch for `state`, in the current language; nil hides it (no lecture, or
    /// no account the lecture's state could belong to).
    static func audioButton(_ state: AudioEnhancementState?) -> AudioButtonPresentation? {
        guard let state else { return nil }
        switch state {
        case .needsFFmpeg:
            return AudioButtonPresentation(isOn: false, action: nil, toolTip: ffmpegHint())
        case .off(let preferred):
            return AudioButtonPresentation(isOn: false, action: .use(preferred), toolTip: tr(
                "Audio migliorato: spento. Fai clic per attivare «\(preferred.displayName)».",
                "Enhanced audio: off. Click to turn on \u{201C}\(preferred.displayName)\u{201D}."))
        case .on(let kind):
            return AudioButtonPresentation(isOn: true, action: .use(nil), toolTip: tr(
                "Audio migliorato: \(kind.displayName). Fai clic per tornare all'audio originale.",
                "Enhanced audio: \(kind.displayName). Click to go back to the original audio."))
        case .failed(let message, let preferred):
            return AudioButtonPresentation(isOn: false, action: .use(preferred), toolTip: message.text)
        }
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

    typealias MakeSession = @MainActor (_ stream: URL, _ ffmpeg: URL, _ kind: AudioEnhancementKind, _ onFailure: @escaping @MainActor (LiveAudioFailure?) -> Void) throws -> LiveAudioStreaming

    private let locateFFmpeg: () -> URL?
    private let makeSession: MakeSession
    private var session: (key: String, id: Int, streaming: LiveAudioStreaming)?
    private var sessionCount = 0
    /// The running session's current failure: the last one reported, nil when none was or a
    /// request has succeeded since (the failure passed). A refusal stays over later failures,
    /// whatever fails after an expired address; only a success clears it.
    private(set) var reportedFailure: LiveAudioFailure?
    /// Lectures whose filter failed, until the student turns it on again.
    private var failures: [String: BilingualText] = [:]

    init(locateFFmpeg: @escaping () -> URL? = { AudioEnhancement.locateFFmpeg() },
         makeSession: @escaping MakeSession = { try LiveAudioSession(stream: $0, ffmpeg: $1, onFailure: $3, kind: $2) },
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

    /// What the menu shows for `key`; `inUse` (the kind playing, nil for Webex's stream) and
    /// `preferred` (the kind chosen last) are the caller's: it knows what the player plays and
    /// what the student chose.
    func state(for key: String, inUse: AudioEnhancementKind?, preferred: AudioEnhancementKind) -> AudioEnhancementState {
        if let inUse { return .on(inUse) }
        if locateFFmpeg() == nil { return .needsFFmpeg }
        if let failure = failures[key] { return .failed(failure, preferred: preferred) }
        return .off(preferred: preferred)
    }

    /// Whether a Play of `key` may start on the filter: ffmpeg is there and it hasn't failed.
    func canStart(_ key: String) -> Bool { failures[key] == nil && locateFFmpeg() != nil }

    /// Starts filtering `stream` for `key` with the filter of `kind`, replacing any session
    /// (which is stopped first, so a start that fails leaves none running), and returns the
    /// address the player plays; nil without ffmpeg or when the session can't start (no local
    /// port).
    func start(key: String, stream: URL, kind: AudioEnhancementKind) -> URL? {
        stop()
        failures[key] = nil
        guard let ffmpeg = locateFFmpeg() else {
            onChange?(key)
            return nil
        }
        sessionCount += 1
        let id = sessionCount
        do {
            let streaming = try makeSession(stream, ffmpeg, kind) { [weak self] failure in
                guard let self, self.session?.id == id, failure == nil || self.reportedFailure != .streamRefused else { return }
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
