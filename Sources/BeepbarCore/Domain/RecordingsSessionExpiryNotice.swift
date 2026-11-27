import Foundation

/// The "Polimi sign-in expired" notification of a sync's Recordings follow-up (#295): when it is
/// sent, and the small per-account record that makes it fire once per expiry.
///
/// Why it exists: an expired Polimi session makes every later follow-up skip silently, which to
/// a student who relies on "N nuove registrazioni" looks like "nothing new". ONE notification
/// invites them to sign in again; it is separate from the new-recordings one (#190: lectures
/// found before a midway expiry are still announced, so both may be delivered).
///
/// The record (`Record`, persisted by the app in UserDefaults) says, for one WeBeep account,
/// whether a working Polimi session was seen and whether this expiry was already dealt with:
/// - no record (or another account's): never signed in, or updated while already expired. Silent:
///   the student never had a session to lose, and nothing can tell them apart from someone who
///   turned Recordings on and ignored the sign-in. The next successful sign-in arms it.
/// - `.armed`: a session worked (a sign-in succeeded, or a saved session was found alive).
///   The next expiry met by a follow-up is notified.
/// - `.spent`: this expiry was notified, or the student started a sign-in themselves (they know).
///   Silent until a successful sign-in arms it again, also after a relaunch.
/// All transitions are pure functions here, so the rules are covered without UI.
public enum RecordingsSessionExpiryNotice {
    public enum Phase: String, Codable, Sendable, Equatable {
        case armed
        case spent
    }

    /// What is persisted: the WeBeep account (numeric user id) it belongs to and its phase. Holds
    /// nothing else (no name, address or course). Removed on logout, account change and when
    /// Recordings is turned off; an older build ignores the unknown key.
    public struct Record: Codable, Sendable, Equatable {
        public var owner: Int
        public var phase: Phase
        public init(owner: Int, phase: Phase) {
            self.owner = owner
            self.phase = phase
        }
    }

    /// Whether a follow-up outcome says the Polimi session is expired: the refresh ended midway
    /// (`.needsSignIn`) or was skipped because access already was `.needsSignIn`. Every other
    /// ending (a refresh, an outage, a cancellation, any other skip) is not an expiry.
    public static func isExpiry(_ outcome: RecordingsSyncOutcome) -> Bool {
        switch outcome {
        case .needsSignIn, .skipped(.needsSignIn): return true
        case .skipped, .refreshed, .unavailable, .cancelled: return false
        }
    }

    /// Whether to send the notification: the outcome is an expiry, `owner` (the account the follow-up
    /// ran for) has an armed record, and the "Notifiche" switch is on. macOS's permission and the
    /// result still being current are checked by the coordinator at send time.
    public static func shouldNotify(for outcome: RecordingsSyncOutcome, record: Record?, owner: Int?, notificationsEnabled: Bool) -> Bool {
        guard notificationsEnabled, isExpiry(outcome), let owner, let record else { return false }
        return record.owner == owner && record.phase == .armed
    }

    /// The record once the notification was sent: this expiry is dealt with.
    public static func afterNotified(_ record: Record?, owner: Int) -> Record? {
        guard let record, record.owner == owner else { return record }
        return Record(owner: owner, phase: .spent)
    }

    /// A Polimi sign-in succeeded: the next expiry is notified, whatever the previous phase.
    public static func afterSignIn(owner: Int) -> Record {
        Record(owner: owner, phase: .armed)
    }

    /// A saved session was found alive (a launch with a valid session, e.g. the first one after
    /// updating to a build with this notification): arms an account with no record. A `.spent`
    /// record stays spent: only a sign-in can have made the session alive again.
    public static func afterSessionFound(_ record: Record?, owner: Int) -> Record {
        if let record, record.owner == owner { return record }
        return Record(owner: owner, phase: .armed)
    }

    /// The student started a Polimi sign-in while the session was expired: they already know, so
    /// this expiry is not notified, even if the sign-in is then abandoned. An unarmed account
    /// stays unarmed.
    public static func afterUserStartedSignIn(_ record: Record?, owner: Int) -> Record? {
        guard let record, record.owner == owner, record.phase == .armed else { return record }
        return Record(owner: owner, phase: .spent)
    }

    /// The text of the notification: no course, lecture or account detail.
    public static func text() -> NotificationText {
        NotificationText(title: BilingualText("Accesso al Politecnico scaduto", "Polimi sign-in expired"),
                         body: BilingualText("Accedi di nuovo in Registrazioni per continuare a ricevere le nuove lezioni.",
                                             "Sign in again in Recordings to keep getting new lectures."))
    }
}
