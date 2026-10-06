import Foundation

/// Decides, page after page, how an entry into the Recman archive is going: the pure half of
/// `RecmanWebSession.enter(mode:)`, which feeds it what the web view reports and carries out the
/// commands it returns. Kept free of WebKit so every sequence of pages can be tested.
///
/// Two modes:
/// - `background`: nobody is looking (opening the Recordings page, a refresh). It ends at the
///   archive, or as soon as the user would be needed, or after `deadline`. It never shows a window.
/// - `interactive`: the user asked to sign in. It starts hidden, so a live session gets through
///   without a window flashing; it shows the window only when the user is needed (or when the way
///   in looks unfamiliar, so the user can still get there by hand), then waits without a deadline
///   until the archive is reached or the window is closed.
///
/// Every load gets a number from the web view side. Events about an older load are ignored, so a
/// probe result or a timer that arrives after the page already moved on can't end the entry.
public struct RecmanEntryNavigator: Sendable {
    public enum Mode: Sendable, Equatable { case background, interactive }

    public enum Outcome: Sendable, Equatable {
        /// The archive's search form is on screen.
        case archive
        /// Background only: the Polimi session is gone and the user has to sign in again.
        case needsUser
        /// Background only: the way in led somewhere BeepBar doesn't recognize.
        case unrecognized
        /// Background only: no verdict within `deadline`.
        case timedOut
        /// A page failed to load (offline, server error) before the window was shown.
        case failed
        /// Cancelled, or the user closed the sign-in window.
        case cancelled
    }

    public enum Event: Sendable, Equatable {
        /// A main-frame load started, or was redirected: it is now load `id`.
        case loadStarted(id: Int)
        /// Load `id` finished on `url`, and the page probe found `facts`.
        case loadFinished(id: Int, url: URL?, facts: PolimiPageFacts)
        /// Load `id` failed (not a cancellation: those are a new load taking over).
        case loadFailed(id: Int)
        /// The patience timer scheduled for load `id` ran out.
        case patienceElapsed(id: Int)
        /// The overall deadline scheduled when the entry started ran out.
        case deadlineElapsed
        /// The user closed the sign-in window.
        case windowClosed
        case cancelled
    }

    public enum Command: Sendable, Equatable {
        /// Report `patienceElapsed(id:)` after `delay`, unless the entry ended.
        case schedulePatience(id: Int, delay: Duration)
        case showWindow
        /// The entry is over: cancel the timers, hide the window, return `Outcome`.
        case finish(Outcome)
    }

    /// The most a background entry may take. A live session gets through in a few seconds; the
    /// rest is room for a slow network, not for waiting on anyone.
    public static let deadline: Duration = .seconds(30)

    private enum Phase: Sendable { case entering, waitingForUser, finished }

    public let mode: Mode
    private var phase = Phase.entering
    private var currentLoad: Int?
    /// What load `currentLoad` turns into if it stays still for its patience.
    private var ifStill: PolimiPage.StillOutcome?

    public init(mode: Mode) {
        self.mode = mode
    }

    public var isFinished: Bool { phase == .finished }
    /// Whether the window is on screen, waiting for the user.
    public var isWaitingForUser: Bool { phase == .waitingForUser }

    public mutating func handle(_ event: Event) -> [Command] {
        guard phase != .finished else { return [] }
        switch event {
        case .loadStarted(let id):
            currentLoad = id
            ifStill = nil
            return []
        case .loadFinished(let id, let url, let facts):
            guard id == currentLoad else { return [] }
            switch PolimiPage.classify(url, facts: facts) {
            case .archive:
                return finish(.archive)
            case .needsUser:
                return reachedDeadEnd(.needsUser)
            case .unrecognized:
                return reachedDeadEnd(.unrecognized)
            case .transit(let patience, let outcome):
                // With the window up the user is driving: only the archive matters.
                guard phase == .entering else { return [] }
                ifStill = outcome
                return [.schedulePatience(id: id, delay: patience)]
            }
        case .loadFailed(let id):
            // Once the window is up, a failed load is the user's to retry, like in a browser.
            guard id == currentLoad, phase == .entering else { return [] }
            return finish(.failed)
        case .patienceElapsed(let id):
            guard id == currentLoad, phase == .entering, let outcome = ifStill else { return [] }
            return reachedDeadEnd(outcome == .needsUser ? .needsUser : .unrecognized)
        case .deadlineElapsed:
            guard phase == .entering else { return [] }
            return mode == .background ? finish(.timedOut) : showWindow()
        case .windowClosed:
            return finish(.cancelled)
        case .cancelled:
            return finish(.cancelled)
        }
    }

    /// The way in stopped short of the archive: background gives up with `outcome`, interactive
    /// hands over to the user.
    private mutating func reachedDeadEnd(_ outcome: Outcome) -> [Command] {
        switch mode {
        case .background: return finish(outcome)
        case .interactive: return phase == .entering ? showWindow() : []
        }
    }

    private mutating func showWindow() -> [Command] {
        phase = .waitingForUser
        ifStill = nil
        return [.showWindow]
    }

    private mutating func finish(_ outcome: Outcome) -> [Command] {
        phase = .finished
        return [.finish(outcome)]
    }
}

/// Which loads the Recman browser lets through. Everything else is cancelled before it starts.
public enum RecmanNavigationPolicy {
    /// - Parameters:
    ///   - mainFrame: the page itself, rather than a frame embedded in it.
    ///   - userDriven: a sign-in the user asked for is running, so they may be sent to sites
    ///     Polimi's login uses (SPID, CIE, a 2FA provider) and drive them as in a browser.
    public static func allows(_ url: URL, mainFrame: Bool, userDriven: Bool) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else { return false }
        switch scheme {
        case "about":
            return true
        case "http":
            // Recman's own ticket hop: onlineservices answers the https ticket URL with a
            // redirect to http, then back to https. Blocking it breaks every entry at the last
            // step, so it is the one plain-http load allowed, and only there.
            return mainFrame && components.host?.lowercased() == RecmanURLPolicy.archiveHost
                && components.path.hasPrefix("/recman_frontend") && components.user == nil && components.password == nil
        case "https":
            guard components.user == nil, components.password == nil else { return false }
            // Embedded frames (a captcha, a 2FA widget) and, during a sign-in the user asked
            // for, any site the login sends them to (SPID, CIE, a 2FA provider).
            if !mainFrame || userDriven { return true }
            // Alone, BeepBar only ever goes through Polimi's own pages.
            return components.host.map(PolimiPage.isPolimiHost) ?? false
        default:
            return false
        }
    }
}
