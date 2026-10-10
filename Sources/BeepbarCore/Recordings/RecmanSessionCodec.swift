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
/// Only Polimi cookies are kept, and expired ones are dropped on both sides.
public enum RecmanSessionCodec {
    /// Bumped on any incompatible change; an unknown version is dropped (the user signs in to
    /// Polimi again), never guessed at.
    public static let currentVersion = 1

    public enum DecodeError: Error, Equatable {
        case unreadable
        case unsupportedVersion
    }

    public struct Snapshot {
        /// The WeBeep user id of the account that signed in to Polimi.
        public let ownerUserID: Int
        public let cookies: [HTTPCookie]
    }

    public static func encode(_ cookies: [HTTPCookie], ownerUserID: Int, now: Date = Date()) throws -> Data {
        let kept: [[String: Any]] = cookies.filter { keeps($0, now: now) }.compactMap { cookie in
            cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        let snapshot: [String: Any] = ["version": currentVersion, "owner": ownerUserID, "cookies": kept]
        return try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> Snapshot {
        guard let snapshot = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = snapshot["version"] as? Int else { throw DecodeError.unreadable }
        guard version == currentVersion else { throw DecodeError.unsupportedVersion }
        guard let owner = snapshot["owner"] as? Int, let values = snapshot["cookies"] as? [[String: Any]] else { throw DecodeError.unreadable }
        let cookies = values.compactMap { value in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: value.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
        return Snapshot(ownerUserID: owner, cookies: cookies.filter { keeps($0, now: now) })
    }

    /// A cookie of polimi.it or one of its subdomains that hasn't expired. Session cookies (no
    /// expiry) are kept: they are the single sign-on session itself.
    public static func keeps(_ cookie: HTTPCookie, now: Date) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard PolimiPage.isPolimiHost(domain) else { return false }
        return cookie.expiresDate.map { $0 > now } ?? true
    }
}
