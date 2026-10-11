import AppKit
import BeepbarCore

/// A keyboard shortcut of the recordings player window (issue #148, package G).
///
/// The bindings follow QuickTime and YouTube, the two players students already know:
///
/// | Key | Action |
/// |---|---|
/// | Space | play / pause |
/// | K | pause |
/// | J / L, ← / → | back / forward 10 s |
/// | Shift ← / Shift → | back / forward 30 s |
/// | `<` / `>` | slower / faster, through `RecordingPlayerPolicy.speeds` |
/// | F | full screen |
/// | M | mute |
/// | 0–9 | jump to 0 %–90 % of the lecture |
///
/// `AVPlayerView` handles some of these keys itself, differently (verified on macOS 27): space
/// toggles playback, ← / → pause and step one frame, and J / K / L shuttle (J plays backwards).
/// Frame stepping and reverse play are useless for a lecture, and reverse play of a network
/// stream is costly, so the window takes these keys before the view sees them
/// (`RecordingPlayerWindow`): exactly one handler acts on each key, never both.
enum PlayerShortcut: Equatable, Sendable {
    case togglePlayPause
    case pause
    /// Relative seek, in seconds (negative goes back).
    case skip(TimeInterval)
    case slower
    case faster
    case toggleFullScreen
    case toggleMute
    /// Jump to this fraction of the duration (0.0–0.9).
    case jump(Double)

    /// Whether holding the key down should repeat the action. Toggles do not: a held Space or F
    /// would otherwise flicker between states.
    var repeats: Bool {
        switch self {
        case .skip, .slower, .faster: true
        default: false
        }
    }
}

/// The player's pure decisions: speeds, seek targets, the resume position and the key map.
/// Kept apart from `RecordingPlayerController` so Swift Testing covers every boundary without
/// AVFoundation.
enum RecordingPlayerPolicy {
    /// The speeds offered to the student, slowest first. Lectures are mostly speech, which stays
    /// intelligible well past 2x with pitch correction; 0.75x helps with a fast speaker or a
    /// foreign language.
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// AVFoundation guarantees rates from 1.0 to 2.0 for every ready item (AVPlayerItem.h);
    /// above 2.0 only when `canPlayFastForward` is true, below 1.0 only when
    /// `canPlaySlowForward` is. A single-level HLS stream without an I-frame playlist, like
    /// Webex's, may not qualify, so those speeds are offered only once the item says it can
    /// (`RateSupport`).
    static let maximumSpeedWithoutFastForward: Float = 2
    static let minimumSpeedWithoutSlowForward: Float = 1

    /// The UserDefaults key holding the last speed the student chose. Written only when the
    /// student changes speed, never at launch or when a play applies it.
    static let speedDefaultsKey = "recordingPlayerSpeed"

    /// Short skips (J / L, arrows) and long skips (Shift + arrows).
    static let shortSkip: TimeInterval = 10
    static let longSkip: TimeInterval = 30

    /// A resume position closer than this to either end is ignored: near the start there is
    /// nothing worth resuming, near the end the student has finished and should start over.
    static let resumeMargin: TimeInterval = 5

    /// The speeds an item with `support` can play at.
    nonisolated static func availableSpeeds(_ support: RateSupport) -> [Float] {
        speeds.filter { $0 == effectiveSpeed(preferred: $0, support: support) }
    }

    /// The listed speed equal to `rate` (within float rounding), or nil.
    nonisolated static func speed(matching rate: Double) -> Float? {
        guard rate.isFinite else { return nil }
        return speeds.first { abs(Double($0) - rate) < 0.001 }
    }

    /// The stored preference as a listed speed: anything missing, malformed or no longer offered
    /// falls back to 1x, so a bad value can never make lectures play at an odd rate.
    nonisolated static func storedSpeed(_ value: Any?) -> Float {
        guard let number = value as? NSNumber, let speed = speed(matching: number.doubleValue) else { return 1 }
        return speed
    }

    /// The rate actually applied: the preference, brought within what the item supports.
    nonisolated static func effectiveSpeed(preferred: Float, support: RateSupport) -> Float {
        var speed = preferred
        if !support.fastForward { speed = min(speed, maximumSpeedWithoutFastForward) }
        if !support.slowForward { speed = max(speed, minimumSpeedWithoutSlowForward) }
        return speed
    }

    /// The next speed in `available` above (`faster`) or below `current`, or nil at either end:
    /// stepping stops at the extremes instead of wrapping, so holding `>` never jumps to 0.5x.
    /// A current rate between two listed speeds steps to the nearest one in that direction.
    nonisolated static func steppedSpeed(from current: Float, faster: Bool, available: [Float]) -> Float? {
        faster ? available.first { $0 > current + 0.001 } : available.last { $0 < current - 0.001 }
    }

    /// Where a relative skip lands: clamped to the lecture, `[0, duration]`, or only to 0 when
    /// the duration is not known.
    nonisolated static func skipTarget(from current: TimeInterval, by delta: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let base = current.isFinite ? current : 0
        let target = max(0, base + delta)
        guard let duration, duration.isFinite, duration > 0 else { return target }
        return min(target, duration)
    }

    /// Where a digit jump lands, or nil when the duration is unknown (there is nothing to take a
    /// fraction of).
    nonisolated static func jumpTarget(fraction: Double, duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0, fraction.isFinite else { return nil }
        return min(max(0, fraction), 1) * duration
    }

    /// Whether a requested resume position is worth waiting for before playback starts. The end
    /// of the lecture is checked later, once the duration is known (`resumePosition`).
    nonisolated static func acceptsStartAt(_ startAt: TimeInterval?) -> Bool {
        guard let startAt, startAt.isFinite else { return false }
        return startAt >= resumeMargin
    }

    /// The position to resume from, or nil to start from the beginning: nil, non-finite, within
    /// `resumeMargin` of the start, or within `resumeMargin` of (or past) the end. An unknown
    /// duration accepts any position past the start margin.
    nonisolated static func resumePosition(startAt: TimeInterval?, duration: TimeInterval?) -> TimeInterval? {
        guard acceptsStartAt(startAt), let startAt else { return nil }
        if let duration, duration.isFinite, duration > 0, startAt > duration - resumeMargin { return nil }
        return startAt
    }

    /// The shortcut a key-down event means, or nil to let it through (to `AVPlayerView`, the
    /// window or the main menu).
    ///
    /// - Command, Control and Option chords are never taken, so ⌘W, ⌘Q, ⌃⌘F and menu equivalents
    ///   keep working.
    /// - Letters ignore Shift and Caps Lock. `<`, `>` and digits are read from the produced
    ///   character, so they follow the keyboard layout: on a US layout `<` is Shift + `,`, on an
    ///   Italian one it has its own key, and on AZERTY digits need Shift.
    /// - Letters follow the layout too (AZERTY's M is where QWERTY has `;`), except when the key
    ///   types a letter outside ASCII (Cyrillic, Greek, Hebrew…, or an accented letter): then
    ///   the physical key decides (`letterKeyCodes`), so J / K / L / F / M work on the ANSI J / K /
    ///   L / F / M keys without switching input source.
    nonisolated static func shortcut(characters: String?, charactersIgnoringModifiers: String?,
                                     specialKey: NSEvent.SpecialKey?, modifiers: NSEvent.ModifierFlags,
                                     keyCode: UInt16? = nil) -> PlayerShortcut? {
        let chords: NSEvent.ModifierFlags = [.command, .control, .option]
        guard modifiers.intersection(chords).isEmpty else { return nil }
        let shift = modifiers.contains(.shift)
        if let specialKey {
            switch specialKey {
            case .leftArrow: return .skip(-(shift ? longSkip : shortSkip))
            case .rightArrow: return .skip(shift ? longSkip : shortSkip)
            default: return nil
            }
        }
        switch characters {
        case " ": return .togglePlayPause
        case "<": return .slower
        case ">": return .faster
        case let digit? where digit.count == 1 && ("0"..."9").contains(digit):
            return .jump(Double(Int(digit) ?? 0) / 10)
        default: break
        }
        var letter = charactersIgnoringModifiers?.lowercased()
        if let typed = letter, typed.unicodeScalars.count == 1, let scalar = typed.unicodeScalars.first,
           !scalar.isASCII, CharacterSet.letters.contains(scalar), let keyCode {
            letter = letterKeyCodes[keyCode]
        }
        switch letter {
        case "k": return .pause
        case "j": return .skip(-shortSkip)
        case "l": return .skip(shortSkip)
        case "f": return .toggleFullScreen
        case "m": return .toggleMute
        default: return nil
        }
    }

    /// The physical ANSI positions of the letter shortcuts (`kVK_ANSI_*` in Carbon's Events.h),
    /// for layouts that type no Latin letters.
    static let letterKeyCodes: [UInt16: String] = [38: "j", 40: "k", 37: "l", 3: "f", 46: "m"]

    /// What the player window does with a key-down, decided from the event alone so the window
    /// answers AppKit without touching main-actor state: nil lets the event through; otherwise
    /// the key is taken, and its shortcut runs unless it is the repeat of a key that must not
    /// repeat (a held toggle is swallowed, so `AVPlayerView` does not run its own binding for it
    /// either).
    nonisolated static func keyDecision(for event: NSEvent) -> (shortcut: PlayerShortcut, perform: Bool)? {
        guard event.type == .keyDown,
              let shortcut = shortcut(characters: event.characters, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                      specialKey: event.specialKey, modifiers: event.modifierFlags, keyCode: event.keyCode) else { return nil }
        return (shortcut, !event.isARepeat || shortcut.repeats)
    }

    /// How a speed is shown: "1,25×" in Italian, "1.25×" in English, without trailing zeros.
    nonisolated static func speedLabel(_ speed: Float) -> String {
        var text = String(format: "%.2f", Double(speed))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return tr(text.replacingOccurrences(of: ".", with: ","), text) + "×"
    }

    /// The shortcuts as shown in the speed menu and its tooltip, in the current language.
    nonisolated static func shortcutHelp() -> [(keys: String, action: String)] {
        [
            (tr("Spazio", "Space"), tr("Riproduci o metti in pausa", "Play or pause")),
            ("K", tr("Pausa", "Pause")),
            ("J  L", tr("Indietro / avanti di 10 s", "Back / forward 10 s")),
            ("←  →", tr("Indietro / avanti di 10 s", "Back / forward 10 s")),
            ("⇧←  ⇧→", tr("Indietro / avanti di 30 s", "Back / forward 30 s")),
            ("<  >", tr("Più lento / più veloce", "Slower / faster")),
            ("0–9", tr("Vai allo 0–90% della lezione", "Jump to 0–90% of the lecture")),
            ("F", tr("Schermo intero", "Full screen")),
            ("M", tr("Silenzia", "Mute")),
        ]
    }
}

/// Which rates an item supports beyond the 1x–2x every ready item plays (AVPlayerItem.h):
/// `unknown` (nothing beyond) until the item is ready and says otherwise.
struct RateSupport: Equatable, Sendable {
    var fastForward: Bool
    var slowForward: Bool
    static let unknown = RateSupport(fastForward: false, slowForward: false)
    static let all = RateSupport(fastForward: true, slowForward: true)
}

/// The player window: takes the player's shortcut keys before the normal dispatch, so they work
/// whichever view is first responder and take precedence over `AVPlayerView`'s own bindings (see
/// `PlayerShortcut`). Other keys go through unchanged. Scoped to this window: no global or local
/// event monitor, nothing at rest.
///
/// AppKit callbacks never touch main-actor state synchronously (AGENTS.md, issue #30):
/// `sendEvent` decides from the event alone, with the pure `RecordingPlayerPolicy.keyDecision`,
/// whether to take the key, and the action runs in a `Task { @MainActor in … }` hop. Hops run in
/// order, so a held key's repeats still add up (`RecordingPlayerController.skip(by:)` starts
/// from the pending seek target).
final class RecordingPlayerWindow: NSWindow {
    /// Runs a shortcut; called only from the main-actor hop, never inside `sendEvent`.
    var shortcutHandler: (@MainActor @Sendable (PlayerShortcut) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if let handler = shortcutHandler, let decision = RecordingPlayerPolicy.keyDecision(for: event) {
            if decision.perform {
                let shortcut = decision.shortcut
                Task { @MainActor in handler(shortcut) }
            }
            return
        }
        super.sendEvent(event)
    }
}

/// The target of one menu item in the player's speed menu. Like `StatusItemController`'s actions
/// (issue #30), the Objective-C entry point is nonisolated and hops to the main actor with a
/// `Task`, so AppKit never calls into main-actor code synchronously from a menu.
final class PlayerMenuAction: NSObject {
    private let perform: @MainActor @Sendable () -> Void

    init(_ perform: @escaping @MainActor @Sendable () -> Void) {
        self.perform = perform
    }

    @objc nonisolated func invoke(_ sender: Any?) {
        let perform = perform
        Task { @MainActor in perform() }
    }
}
