import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Polimi session BeepBar keeps on disk (`RecordingsSessionStore` in the app), so the archive
/// opens on its own after a relaunch instead of asking for a Polimi sign-in every time.
///
/// Why a file of cookies: the Recman browser uses a non-persistent WebKit store, so nothing the
/// login leaves behind outlives the process and nothing reaches BeepBar's other web views (the
/// WeBeep login keeps its own throwaway store). The single sign-on cookies are session cookies,
/// which WebKit would drop at quit even from a persistent store; this file is what carries them
/// to the next launch. It is written only after an entry or a refresh succeeded, never at quit.
///
/// The snapshot names the WeBeep account it was made for, so a session never outlives the account
/// that created it: another account signing in finds a snapshot that isn't theirs and drops it.
/// Only Polimi and Webex cookies are kept (see `keeps`), and expired ones are dropped on both sides.
///
/// Format history (issue #148):
/// - v1: `version`, `owner`, `cookies` (Polimi cookies only).
/// - v2: adds an optional `email` (the Polimi address the user confirmed for the Webex login;
///   the key is absent when there is none) and also keeps Webex cookies, so native playback
///   doesn't sign in to Webex again after every relaunch. The other keys are unchanged.
///
/// Migration and rollback, for users who skip releases:
/// - A v1 file decodes with `email == nil` and needs no user action; the next successful save
///   (`RecordingsController.saveSession`) rewrites it as v2.
/// - An app older than v2 accepts only `version == 1`, so it refuses a v2 file with
///   `unsupportedVersion`. Its `RecordingsController.savedCookies` treats every decode error as
///   an unreadable session and deletes the file: the user signs in to Polimi again, and no course
///   file is touched. The Webex cookies and the confirmed email go with the file, which is the
///   intent: a session the app can't read must not linger on disk.
public enum RecmanSessionCodec {
    /// Bumped on any incompatible change; an unknown version is dropped (the user signs in to
    /// Polimi again), never guessed at. Every older version this build still reads is accepted
    /// in `decode`: dropping one signs out the users who skipped the release that rewrote it.
    public static let currentVersion = 2

    public enum DecodeError: Error, Equatable {
        case unreadable
        case unsupportedVersion
    }

    public struct Snapshot {
        /// The WeBeep user id of the account that signed in to Polimi.
        public let ownerUserID: Int
        public let cookies: [HTTPCookie]
        /// The Polimi address the user confirmed for the Webex login, or nil when none was
        /// confirmed yet (always nil for a v1 file, which predates it). Stored as given: the
        /// caller validates it before saving.
        public let email: String?
    }

    /// Writes a v2 snapshot. `email` defaults to nil so callers that predate it compile
    /// unchanged; a nil email leaves the key out rather than writing an empty value.
    public static func encode(_ cookies: [HTTPCookie], ownerUserID: Int, email: String? = nil, now: Date = Date()) throws -> Data {
        let kept: [[String: Any]] = cookies.filter { keeps($0, now: now) }.compactMap { cookie in
            cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        var snapshot: [String: Any] = ["version": currentVersion, "owner": ownerUserID, "cookies": kept]
        if let email { snapshot["email"] = email }
        return try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
    }

    /// Reads v1 and v2. A newer version is `unsupportedVersion`; anything malformed is
    /// `unreadable`, including a v2 `email` that is present but not a string. No BeepBar writes
    /// that, so the file is corrupt or foreign and none of its fields can be trusted: it is refused
    /// whole, like any other malformed file, rather than half-used with the email read as "none".
    /// The cost is one Polimi sign-in.
    public static func decode(_ data: Data, now: Date = Date()) throws -> Snapshot {
        guard let snapshot = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = snapshot["version"] as? Int else { throw DecodeError.unreadable }
        guard version == 1 || version == currentVersion else { throw DecodeError.unsupportedVersion }
        guard let owner = snapshot["owner"] as? Int, let values = snapshot["cookies"] as? [[String: Any]] else { throw DecodeError.unreadable }
        var email: String?
        // v1 never wrote an email, so whatever a v1 file holds under that key is ignored.
        if version >= 2, let value = snapshot["email"] {
            guard let string = value as? String else { throw DecodeError.unreadable }
            email = string
        }
        let cookies = values.compactMap { value in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: value.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
        return Snapshot(ownerUserID: owner, cookies: cookies.filter { keeps($0, now: now) }, email: email)
    }

    /// A cookie that hasn't expired, from a host family the Recordings feature needs across
    /// launches. Session cookies (no expiry) are kept: they are the single sign-on session itself.
    /// - polimi.it and its subdomains: the Polimi single sign-on and the Recman archive.
    /// - webex.com and its subdomains (v2): the Webex login made in the same hidden web view for
    ///   native playback, so it isn't repeated after a relaunch.
    /// Every other site's cookies (trackers, CDNs, lookalikes) never reach the file.
    public static func keeps(_ cookie: HTTPCookie, now: Date) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard PolimiPage.isPolimiHost(domain) || isWebexHost(domain) else { return false }
        return cookie.expiresDate.map { $0 > now } ?? true
    }

    /// `webex.com` itself or a subdomain of it, matched on a label boundary: `x.webex.com` is
    /// Webex, while `evilwebex.com` and `webex.com.evil.com` are not, so a lookalike site's
    /// cookies are never written next to the Polimi session.
    public static func isWebexHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "webex.com" || host.hasSuffix(".webex.com")
    }
}
