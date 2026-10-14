import Foundation

/// Keeps the display (and with it the Mac) awake while a lecture is actually playing, and not a
/// moment longer.
///
/// Why: the native player plays video with no user input, so macOS counts the user as idle and
/// dims the display or sleeps the Mac in the middle of a lecture. A power assertion held for
/// exactly the playing stretch fixes that without costing anything at rest.
///
/// Mechanism: `ProcessInfo.beginActivity` with `.idleDisplaySleepDisabled` and
/// `.idleSystemSleepDisabled` (Foundation only: no framework is linked for it, so launch is
/// unchanged). `.userInitiated` is deliberately not used: it also contains
/// `.suddenTerminationDisabled`, which changes how the app is ended at logout and shutdown, and
/// nothing here may touch the quit path.
///
/// Contract: `update(isPlaying:)` is idempotent and cheap, so the player can call it from every
/// state report. It begins exactly one assertion when playback starts and ends it when playback
/// stops; it never holds two, and it never outlives its owner (`deinit` ends it). No timer, no
/// observer, no polling: it holds one token or nothing. Called on the main actor only (the
/// player's), by convention rather than isolation, so that `deinit` can end the token.
final class PlaybackSleepGuard {
    /// The seam: tests inject a fake and never touch the real power assertions. `begin` returns
    /// an opaque token that `end` receives back exactly once.
    struct Assertion: Sendable {
        let begin: @Sendable (_ reason: String) -> Any
        let end: @Sendable (Any) -> Void

        /// The real power assertion. The reason is for `pmset -g assertions`, not for the user.
        static let system = Assertion(
            begin: { reason in
                ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: reason)
            },
            end: { token in
                if let token = token as? NSObjectProtocol { ProcessInfo.processInfo.endActivity(token) }
            })
    }

    private let assertion: Assertion
    private var token: Any?

    /// Whether an assertion is held right now.
    var isHolding: Bool { token != nil }

    init(assertion: Assertion = .system) {
        self.assertion = assertion
    }

    deinit {
        // The assertion must never outlive the player that asked for it.
        if let token { assertion.end(token) }
    }

    /// Holds the assertion while `isPlaying`, releases it otherwise. Safe to call repeatedly.
    func update(isPlaying: Bool) {
        if isPlaying {
            guard token == nil else { return }
            token = assertion.begin("BeepBar is playing a lecture recording")
        } else if let held = token {
            token = nil
            assertion.end(held)
        }
    }
}
