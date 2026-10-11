#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The course list BeepBar last confirmed from Moodle for one account, as kept on disk (#98).
///
/// Why it exists: the controller is born with an empty list and fills it only when the network
/// answers, so every window opening showed "Caricamento corsi…" even to a user whose courses have
/// not changed in months. The snapshot lets the window show the known courses immediately and
/// refresh them in the background, offline included.
///
/// What it is not: an authorization. Saved enrollments never decide what is synced (every sync
/// asks Moodle for the current list first) and never replace the sync metadata of a course. It
/// carries no token, no folder names (those belong to the sync database, which stays
/// authoritative), no selection (the defaults and the database) and no Moodle user id: the
/// credential fingerprint already ties it to one account, so the id would be personal data kept
/// for nothing.
public struct CourseListSnapshot: Codable, Equatable, Sendable {
    /// Who the list belongs to. A snapshot saved for another identity is discarded on load, so
    /// account A's courses can never appear after account B signs in, on another university, or
    /// for another sync folder, even if the deletion at sign-out did not happen (a crash, or an
    /// older BeepBar that signs out without knowing the file exists).
    ///
    /// The account is identified by a fingerprint of the stored credential, not by the Moodle
    /// user id: the id is only known once the network has validated the token, and the whole
    /// point is to show the list before that. A new sign-in stores a new token, so a list saved
    /// under any earlier sign-in never matches it.
    public struct Identity: Codable, Equatable, Sendable {
        public let siteID: String
        /// The sync folder's id (`rootID`). The list itself is the account's, but the folders and
        /// the selection shown beside it come from that folder's database records.
        public let rootID: String
        /// `CourseListSnapshot.credentialFingerprint(token:siteID:)` of the token in use.
        public let credential: String

        public init(siteID: String, rootID: UUID, credential: String) {
            self.siteID = siteID
            self.rootID = rootID.uuidString
            self.credential = credential
        }

        /// The identity for `token` on `siteID` in the folder `rootID`.
        public init(siteID: String, rootID: UUID, token: String) {
            self.init(siteID: siteID, rootID: rootID, credential: CourseListSnapshot.credentialFingerprint(token: token, siteID: siteID))
        }
    }

    /// A stored course: the fields of `RemoteCourseSummary`, spelled out so the file format is
    /// pinned here and not by whatever the wire type becomes.
    public struct Course: Codable, Equatable, Sendable {
        public let id: Int64
        public let shortName: String
        public let displayName: String
        public let isVisible: Bool?
        public let startDate: Date?
        public let endDate: Date?

        public init(_ course: RemoteCourseSummary) {
            id = course.id
            shortName = course.shortName
            displayName = course.displayName
            isVisible = course.isVisible
            startDate = course.startDate
            endDate = course.endDate
        }

        public var summary: RemoteCourseSummary {
            RemoteCourseSummary(id: id, shortName: shortName, displayName: displayName, isVisible: isVisible, startDate: startDate, endDate: endDate)
        }
    }

    public let version: Int
    public let identity: Identity
    /// When the list was confirmed by Moodle. Shown to the user while the list is not yet
    /// refreshed, and the basis of the age limit.
    public let savedAt: Date
    /// Sorted by course id, whatever order Moodle answered in: a reordered response is the same
    /// list and must not cost a rewrite (`CourseListSnapshotCodec.shouldSave`).
    public let courses: [Course]

    public init(identity: Identity, savedAt: Date, courses: [RemoteCourseSummary]) {
        version = CourseListSnapshotCodec.currentVersion
        self.identity = identity
        self.savedAt = savedAt
        self.courses = Self.canonical(courses)
    }

    public var summaries: [RemoteCourseSummary] { courses.map(\.summary) }

    static func canonical(_ courses: [RemoteCourseSummary]) -> [Course] {
        courses.sorted { $0.id < $1.id }.map(Course.init)
    }

    /// A one-way, domain-separated SHA-256 of the token, hex encoded. It only answers "is this
    /// the same sign-in?": Moodle tokens are long random strings, so the digest cannot be turned
    /// back into a token, and it is never sent anywhere. The site is part of the input so the
    /// same token string on two sites still gives two identities.
    public static func credentialFingerprint(token: String, siteID: String) -> String {
        let input = Data("beepbar.course-list.credential.v1\u{0}\(siteID)\u{0}\(token)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the window knows about the course list it is showing (#98). Published by the controller;
/// a sync started while it is not `.current` asks Moodle for the list first, so a saved list can
/// never stand in for the live one when a sync starts.
public enum CourseListFreshness: Equatable, Sendable {
    /// Nothing shown yet, or the list was cleared (sign-out, site change, new sign-in): the
    /// window shows its loading or empty state.
    case unknown
    /// The saved list from `savedAt` is on screen and Moodle has not confirmed it in this session.
    case saved(Date)
    /// Moodle confirmed the list in this session.
    case current
}

/// Encoding, limits and acceptance rules for `CourseListSnapshot`, kept pure so every rule is
/// tested without a controller (#98). The store applies them; the controller only reads results.
public enum CourseListSnapshotCodec {
    /// Bumped on any incompatible change. An unknown version is discarded, never guessed at: the
    /// user sees the loading state once, as before the feature existed.
    public static let currentVersion = 1
    /// More courses than this are not saved: a truncated list would mislead ("x of y synced"), and
    /// no real enrollment comes close. A file claiming more is corrupt or foreign and is discarded.
    public static let maximumCourses = 500
    /// Files above this size are discarded before decoding, so a damaged or hostile file cannot
    /// cost memory or time when the window opens. 500 courses with long names fit in a small
    /// fraction of it.
    public static let maximumBytes = 1_048_576
    /// A list older than this is discarded on load. Enrollments do change between semesters; a
    /// list not confirmed for a month is more likely to mislead than to help.
    public static let maximumAge: TimeInterval = 30 * 86_400
    /// How often an unchanged list is rewritten, so `savedAt` stays meaningful without a disk
    /// write on every refresh (an identical list every few hours would otherwise be written each time).
    public static let saveRefreshInterval: TimeInterval = 86_400

    public enum DecodeError: Error, Equatable, Sendable {
        case tooLarge
        case unreadable
        case unsupportedVersion(Int)
        case wrongIdentity
        case expired
        case tooManyCourses
    }

    public enum EncodeError: Error, Equatable, Sendable {
        case tooManyCourses
    }

    /// Dates as seconds since 1970 and sorted keys: stable bytes for equal lists, no locale.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public static func encode(_ snapshot: CourseListSnapshot) throws -> Data {
        guard snapshot.courses.count <= maximumCourses else { throw EncodeError.tooManyCourses }
        return try makeEncoder().encode(snapshot)
    }

    /// The version alone, read first so a newer file fails as "unsupported" rather than
    /// "unreadable" when its other fields changed shape.
    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// Accepts only a readable, current-version snapshot of exactly `identity`, within the size,
    /// count and age limits. Everything else is an error the caller turns into "no snapshot".
    public static func decode(_ data: Data, expecting identity: CourseListSnapshot.Identity, now: Date) throws -> CourseListSnapshot {
        guard data.count <= maximumBytes else { throw DecodeError.tooLarge }
        let decoder = makeDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { throw DecodeError.unreadable }
        guard probe.version == currentVersion else { throw DecodeError.unsupportedVersion(probe.version) }
        guard let snapshot = try? decoder.decode(CourseListSnapshot.self, from: data) else { throw DecodeError.unreadable }
        guard snapshot.identity == identity else { throw DecodeError.wrongIdentity }
        guard snapshot.courses.count <= maximumCourses else { throw DecodeError.tooManyCourses }
        guard !isExpired(savedAt: snapshot.savedAt, now: now) else { throw DecodeError.expired }
        return snapshot
    }

    /// Older than `maximumAge`. A date in the future (clock moved back) is not expired: the list
    /// is still the last one Moodle confirmed, and the next refresh rewrites the date.
    public static func isExpired(savedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(savedAt) > maximumAge
    }

    /// Whether a confirmed list is worth a write: always when nothing was written for this
    /// identity yet or the list differs, otherwise only once `saveRefreshInterval` has passed, so
    /// an unchanged list costs no disk write per refresh (cost proportional to what changed).
    /// Order does not count: Moodle may answer the same enrollments in another order.
    public static func shouldSave(_ courses: [RemoteCourseSummary], identity: CourseListSnapshot.Identity, after previous: CourseListSnapshot?, now: Date) -> Bool {
        guard let previous, previous.identity == identity else { return true }
        guard previous.courses == CourseListSnapshot.canonical(courses) else { return true }
        return now.timeIntervalSince(previous.savedAt) >= saveRefreshInterval
    }
}
