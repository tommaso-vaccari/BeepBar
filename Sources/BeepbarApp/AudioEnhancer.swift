import AppKit
import CryptoKit
import BeepbarCore
import OSLog

/// What the player's enhanced-audio selector shows for the lecture on screen.
enum AudioEnhancementState: Equatable, Sendable {
    /// No ffmpeg where package managers install it: the selector is disabled and says how to get it.
    case needsFFmpeg
    /// The lecture plays Webex's own stream. `preferred` is the kind the student chose last
    /// (`RecordingsController.resolveEnhancedAudioKind`). The title-bar selector does not use it: each segment asks for its own mode.
    case off(preferred: AudioEnhancementKind)
    /// The lecture plays through the local filter (`LiveAudioSession`) of this kind.
    case on(AudioEnhancementKind)
    /// Enhanced audio stopped working for this lecture (ffmpeg failed, the stream isn't the
    /// layout it understands): the lecture went back to its own stream, and choosing a kind
    /// tries again (`preferred` as above). The message is already bilingual.
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

/// The enhanced-audio selector in the player's title bar, to the left of the speed menu: three
/// segments, icons only, exactly one selected. Pure, so tests check every state's selection,
/// tooltips and actions without a window.
struct AudioSelectorPresentation: Equatable {
    struct Segment: Equatable {
        /// The SF Symbol drawn in the segment.
        let symbol: String
        /// The mode's name: the segment's accessibility label.
        let label: String
        /// What hovering shows: the feature's name and the mode, plus the ffmpeg hint or the
        /// failure and that a click tries again, where they apply.
        let toolTip: String
        /// What a click on it asks for; nil: shown disabled (no ffmpeg).
        let action: PlayerAudioAction?
    }
    /// In order: Off, Levelled voice, Isolated voice.
    let segments: [Segment]
    /// The index of the selected segment: where the lecture is. Failed counts as Off, since the
    /// lecture went back to Webex's own audio.
    let selected: Int
    /// The control's own accessibility label.
    let label: String
}

extension RecordingPlayerPolicy {
    /// The selector for `state`, in the current language; nil hides it (no lecture, or no account
    /// the lecture's state could belong to). Built at use, never cached, so a language switch
    /// shows at once.
    ///
    /// What the click on a segment does is chosen here from the state at click time, never from
    /// how the control looked: a segment asks for its own mode (`.use(kind)`, `.use(nil)` for
    /// Off), and the selected one is not asked again by the controller.
    static func audioSelector(_ state: AudioEnhancementState?) -> AudioSelectorPresentation? {
        guard let state else { return nil }
        let feature = audioFeatureName()
        let selected: Int
        var enabled = true
        var note: String?
        switch state {
        case .needsFFmpeg:
            selected = 0
            enabled = false
            note = ffmpegHint()
        case .off:
            selected = 0
        case .on(let kind):
            selected = kind == .levelled ? 1 : 2
        case .failed(let message, _):
            // The reason is shown only here, on the kinds' tooltips (the speed menu has no Audio
            // section any more); choosing a kind tries again.
            selected = 0
            note = message.text
        }
        func segment(_ symbol: String, _ name: String, _ kind: AudioEnhancementKind?) -> AudioSelectorPresentation.Segment {
            var toolTip = "\(feature): \(name)"
            if let note {
                toolTip += "\n" + note
                if kind != nil, case .failed = state {
                    toolTip += " " + tr("Fai clic per riprovare.", "Click to try again.")
                }
            }
            return .init(symbol: symbol, label: name, toolTip: toolTip, action: enabled ? .use(kind) : nil)
        }
        return AudioSelectorPresentation(
            segments: [segment("waveform.slash", tr("Spento", "Off"), nil),
                       segment("waveform", AudioEnhancementKind.levelled.displayName, .levelled),
                       segment("person.wave.2", AudioEnhancementKind.isolated.displayName, .isolated)],
            selected: selected,
            label: feature)
    }

    /// The feature's name: the selector's accessibility label and the start of every tooltip.
    static func audioFeatureName() -> String { tr("Audio migliorato", "Enhanced audio") }

    /// How to get ffmpeg, on every segment's tooltip while it is missing.
    static func ffmpegHint() -> String {
        tr("Per l'audio migliorato installa ffmpeg (brew install ffmpeg)", "Enhanced audio needs ffmpeg (brew install ffmpeg)")
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
    /// Lectures whose filter failed, until a mode is chosen again.
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
