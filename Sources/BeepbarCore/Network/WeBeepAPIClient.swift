import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WeBeepSiteInfo: Sendable, Equatable {
    public let userID: Int
    public let siteURL: URL
    public let availableFunctions: Set<String>
}

public struct RemoteCourseSummary: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let shortName: String
    public let displayName: String
    public let isVisible: Bool?
    public let startDate: Date?
    public let endDate: Date?
    /// The course's image on WeBeep (the picture Moodle shows on the course card), as a
    /// `/webservice/pluginfile.php/` address on the site's own host, without any credential:
    /// fetching it takes the token (`WeBeepAPIClient.fetchCourseImage`). Nil when the course has
    /// none, or Moodle only offers its generated pattern. Shown as the artwork of the lecture
    /// playing in macOS's Now Playing (issue #148 follow-up). Chosen by `WeBeepCourseImage.select`.
    public let imageURL: URL?

    public init(id: Int64, shortName: String, displayName: String, isVisible: Bool?, startDate: Date?, endDate: Date?, imageURL: URL? = nil) {
        self.id = id
        self.shortName = shortName
        self.displayName = displayName
        self.isVisible = isVisible
        self.startDate = startDate
        self.endDate = endDate
        self.imageURL = imageURL
    }
}

/// Which of the images `core_enrol_get_users_courses` lists for a course BeepBar uses, and in
/// which form (issue #148 follow-up, "Now Playing artwork"). Pure, so every rule is tested.
///
/// Moodle offers two: `overviewfiles`, the files a teacher uploaded as the course image, already
/// as web-service addresses (`/webservice/pluginfile.php/…`), and, on newer versions,
/// `courseimage`, the same picture as a browser address (`/pluginfile.php/…`) or, when there is
/// none, a generated SVG pattern as a `data:` URI. Only a real picture is kept: a `data:` URI, an
/// SVG (ImageIO cannot draw it), another host, plain HTTP, an address already carrying a token,
/// or anything outside `pluginfile.php` is dropped, and the course simply has no image.
///
/// A `/pluginfile.php/` address is rewritten to `/webservice/pluginfile.php/`, as the Moodle app
/// does: only the web-service path accepts the token BeepBar has, the browser path wants a
/// session cookie. The address kept never contains a credential, so it can be stored with the
/// course list (`CourseListSnapshot`) and compared freely.
public enum WeBeepCourseImage {
    /// One entry of `overviewfiles`, as far as this choice needs it.
    public struct OverviewFile: Sendable, Equatable {
        public let fileURL: String?
        public let mimeType: String?
        public init(fileURL: String?, mimeType: String?) {
            self.fileURL = fileURL
            self.mimeType = mimeType
        }
    }

    /// The image to keep for a course, or nil. The first acceptable overview file wins (a teacher
    /// can upload several; Moodle shows the first), then `courseimage`.
    public static func select(overviewFiles: [OverviewFile], courseImage: String?, policy: WeBeepServerPolicy) -> URL? {
        for file in overviewFiles {
            if let mime = file.mimeType?.lowercased(), !mime.hasPrefix("image/") || mime.contains("svg") { continue }
            if let url = acceptable(file.fileURL, policy: policy) { return url }
        }
        return acceptable(courseImage, policy: policy)
    }

    /// `text` as a credential-free web-service address on the site's host, or nil.
    public static func acceptable(_ text: String?, policy: WeBeepServerPolicy) -> URL? {
        guard let text, text.utf8.count <= 2_048, let url = URL(string: text),
              url.scheme?.lowercased() == "https", policy.acceptsPluginURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if (components.queryItems ?? []).contains(where: { ["token", "wstoken"].contains($0.name.lowercased()) }) { return nil }
        if components.percentEncodedPath.lowercased().hasSuffix(".svg") { return nil }
        if components.percentEncodedPath.hasPrefix("/pluginfile.php/") {
            components.percentEncodedPath = "/webservice" + components.percentEncodedPath
        }
        guard let rewritten = components.url, policy.acceptsPluginURL(rewritten) else { return nil }
        return rewritten
    }
}

public struct RemoteCourseContents: Sendable, Equatable {
    public let sections: [RemoteContentSection]
    public let issueCount: Int
    /// Modules with an entry that was left out as unreadable (or a module type whose contents are
    /// never files). A file missing from one of them may still be on Moodle, so it is never
    /// reported as removed.
    public let modulesWithDroppedEntries: Set<Int64>
    /// False when a whole section or module was unreadable: then no file of the course can be
    /// reported as removed, since any of them could have been in it.
    public let isComplete: Bool

    public init(sections: [RemoteContentSection], issueCount: Int, modulesWithDroppedEntries: Set<Int64> = [], isComplete: Bool = true) {
        self.sections = sections
        self.issueCount = issueCount
        self.modulesWithDroppedEntries = modulesWithDroppedEntries
        self.isComplete = isComplete
    }
}

public struct RemoteContentSection: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let modules: [RemoteContentModule]
}

public struct RemoteContentModule: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let files: [RemoteFileCandidate]
}

public struct RemoteFileCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let courseID: Int64
    public let sectionID: Int64
    public let moduleID: Int64
    public let sectionName: String
    public let moduleName: String
    public let moduleType: String
    public let isSingleFileResource: Bool
    public let filename: String
    public let remoteFilePath: String
    public let canonicalPluginPath: String
    public let downloadURL: URL?
    public let size: Int64
    public let modifiedAt: Date?
    public let observedRevision: String
    public var isSupported: Bool
    public var ineligibilityReason: String?

    public init(id: String, courseID: Int64, sectionID: Int64, moduleID: Int64, sectionName: String, moduleName: String, moduleType: String = "unknown", isSingleFileResource: Bool = false, filename: String, remoteFilePath: String, canonicalPluginPath: String, downloadURL: URL?, size: Int64, modifiedAt: Date?, observedRevision: String, isSupported: Bool, ineligibilityReason: String? = nil) {
        self.id = id
        self.courseID = courseID
        self.sectionID = sectionID
        self.moduleID = moduleID
        self.sectionName = sectionName
        self.moduleName = moduleName
        self.moduleType = moduleType
        self.isSingleFileResource = isSingleFileResource
        self.filename = filename
        self.remoteFilePath = remoteFilePath
        self.canonicalPluginPath = canonicalPluginPath
        self.downloadURL = downloadURL
        self.size = size
        self.modifiedAt = modifiedAt
        self.observedRevision = observedRevision
        self.isSupported = isSupported
        self.ineligibilityReason = ineligibilityReason
    }
}

public enum WeBeepAPIError: Error, Sendable, Equatable {
    case invalidToken
    case invalidResponse
    case unexpectedRedirect
    case responseTooLarge
    case malformedPayload
    case unexpectedSite
    case missingRequiredFunction
    case transport(Int)
    case network(NetworkFailure)
}

public enum NetworkFailure: Error, Sendable, Equatable {
    case offline
    case timedOut
    case connectionLost
    case other(Int)

    public init(_ code: URLError.Code) {
        switch code {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            self = .offline
        case .networkConnectionLost:
            self = .connectionLost
        case .timedOut:
            self = .timedOut
        default:
            self = .other(code.rawValue)
        }
    }
}

public enum SyncServiceFailure: Sendable, Equatable {
    case authenticationExpired
    case connectivity
    case serviceUnavailable
    case incompatibleResponse

    public init(_ error: WeBeepAPIError) {
        switch error {
        case .invalidToken:
            self = .authenticationExpired
        case .network:
            self = .connectivity
        case .transport(let status) where status >= 500:
            self = .serviceUnavailable
        case .transport, .invalidResponse, .unexpectedRedirect, .responseTooLarge,
             .malformedPayload, .unexpectedSite, .missingRequiredFunction:
            self = .incompatibleResponse
        }
    }
}

public struct WeBeepServerPolicy: Sendable, Equatable {
    public let endpoint: URL
    public let siteURL: URL
    public let scheme: String
    public let host: String
    public let port: Int?

    public static let production = WeBeepServerPolicy(
        endpoint: MoodleSite.polimi.serverPolicy.endpoint,
        siteURL: MoodleSite.polimi.serverPolicy.siteURL,
        scheme: "https", host: MoodleSite.polimi.serverPolicy.host, port: 443
    )

    public init(endpoint: URL, siteURL: URL, scheme: String, host: String, port: Int?) {
        self.endpoint = endpoint
        self.siteURL = siteURL
        self.scheme = scheme
        self.host = host.lowercased()
        self.port = port
    }

    public func acceptsPluginURL(_ url: URL) -> Bool {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        let effectivePort = url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil)
        let expectedPort = port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        return url.scheme == scheme && url.host?.lowercased() == host && url.user == nil && url.password == nil && effectivePort == expectedPort && url.fragment == nil &&
            (path?.hasPrefix("/webservice/pluginfile.php/") == true || path?.hasPrefix("/pluginfile.php/") == true)
    }
}

public final class WeBeepAPIClient: @unchecked Sendable {
    public static let endpoint = WeBeepServerPolicy.production.endpoint
    private let session: URLSession
    public let policy: WeBeepServerPolicy

    public init() {
        self.session = Self.makeSession()
        self.policy = .production
    }

    public init(session: URLSession) {
        self.session = session
        self.policy = .production
    }

    public init(policy: WeBeepServerPolicy, session: URLSession? = nil) {
        self.policy = policy
        self.session = session ?? Self.makeSession()
    }

    public func validateToken(_ token: String) async throws -> WeBeepSiteInfo {
        let data = try await request(.siteInfo, token: token, fields: [:], limit: 1_048_576)
        let decoded: SiteInfoResponse
        do { decoded = try JSONDecoder().decode(SiteInfoResponse.self, from: data) }
        catch { throw WeBeepAPIError.malformedPayload }
        if decoded.errorcode == "invalidtoken" { throw WeBeepAPIError.invalidToken }
        if decoded.exception != nil || decoded.errorcode != nil { throw WeBeepAPIError.malformedPayload }
        guard let siteURL = URL(string: decoded.siteurl ?? ""), siteURL == policy.siteURL else {
            throw WeBeepAPIError.unexpectedSite
        }
        let functions = Set(decoded.functions?.map(\.name) ?? [])
        if decoded.functions != nil,
           (!functions.contains("core_enrol_get_users_courses") || !functions.contains("core_course_get_contents")) {
            throw WeBeepAPIError.missingRequiredFunction
        }
        guard let userID = decoded.userid else { throw WeBeepAPIError.malformedPayload }
        return WeBeepSiteInfo(userID: userID, siteURL: siteURL, availableFunctions: functions)
    }

    public func fetchCourses(userID: Int, token: String) async throws -> [RemoteCourseSummary] {
        guard userID > 0 else { throw WeBeepAPIError.malformedPayload }
        let data = try await request(.courses, token: token, fields: ["userid": String(userID)], limit: 2_097_152)
        if let error = try? JSONDecoder().decode(MoodleErrorResponse.self, from: data), error.exception != nil || error.errorcode != nil {
            throw error.errorcode == "invalidtoken" ? WeBeepAPIError.invalidToken : WeBeepAPIError.malformedPayload
        }
        let decoded: [CourseResponse]
        do { decoded = try JSONDecoder().decode([CourseResponse].self, from: data) }
        catch { throw WeBeepAPIError.malformedPayload }
        guard decoded.count <= 2_000 else { throw WeBeepAPIError.responseTooLarge }
        var identifiers = Set<Int64>()
        return try decoded.map { course in
            guard course.id > 0, identifiers.insert(course.id).inserted,
                  let name = [course.displayname, course.fullname, course.shortname]
                    .compactMap(MoodleText.normalized)
                    .first(where: { !$0.isEmpty && $0.utf8.count <= 512 }),
                  let shortName = MoodleText.normalized(course.shortname), !shortName.isEmpty, shortName.utf8.count <= 512 else {
                throw WeBeepAPIError.malformedPayload
            }
            let image = WeBeepCourseImage.select(overviewFiles: course.overviewfiles, courseImage: course.courseimage, policy: policy)
            return RemoteCourseSummary(id: course.id, shortName: shortName, displayName: name, isVisible: course.visible.map { $0 != 0 }, startDate: course.startdate.map(Date.init(timeIntervalSince1970:)), endDate: course.enddate.map(Date.init(timeIntervalSince1970:)), imageURL: image)
        }
    }

    /// Largest course image BeepBar accepts. A course card picture is a few hundred kilobytes;
    /// anything bigger is cut off during reception, never buffered whole.
    public static let courseImageByteLimit = 2_097_152
    /// The longest a course image may take to start answering or between two chunks. The
    /// artwork is a nicety: a slow WeBeep must never keep a request open for long.
    public static let courseImageTimeout: TimeInterval = 10

    /// The bytes of a course image (`RemoteCourseSummary.imageURL`), for the artwork of the
    /// lecture playing (issue #148 follow-up).
    ///
    /// Same guarantees as every WeBeep request: this client's ephemeral session (no cache, no
    /// cookies kept), redirects refused (a redirect fails the request rather than taking the token
    /// to another address), reception capped at `courseImageByteLimit`, and an `image/*` answer
    /// required. The address must be a web-service `pluginfile.php` address on the site's own
    /// host over HTTPS, without a credential of its own; the token is appended here, and neither
    /// it nor the address is ever logged. Cancellation cancels the request.
    public func fetchCourseImage(_ url: URL, token: String) async throws -> Data {
        guard url.scheme?.lowercased() == "https", WeBeepCourseImage.acceptable(url.absoluteString, policy: policy) == url else {
            throw WeBeepAPIError.unexpectedSite
        }
        var request: URLRequest
        do { request = try RemoteDownloader.request(url: url, token: token, policy: policy) }
        catch { throw WeBeepAPIError.unexpectedSite }
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.courseImageTimeout
        let receiver = BoundedMetadataResponse(limit: Self.courseImageByteLimit, acceptsContentType: { $0?.lowercased().hasPrefix("image/") == true })
        do { return try await receiver.run(request, in: session) }
        catch let error as WeBeepAPIError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError { throw WeBeepAPIError.network(NetworkFailure(error.code)) }
        catch { throw WeBeepAPIError.invalidResponse }
    }

    public func fetchContents(courseID: Int64, token: String) async throws -> RemoteCourseContents {
        guard courseID > 0 else { throw WeBeepAPIError.malformedPayload }
        let data = try await request(.contents, token: token, fields: ["courseid": String(courseID)], limit: 4_194_304)
        if let error = try? JSONDecoder().decode(MoodleErrorResponse.self, from: data), error.exception != nil || error.errorcode != nil {
            throw error.errorcode == "invalidtoken" ? WeBeepAPIError.invalidToken : WeBeepAPIError.malformedPayload
        }
        let sections: [SectionResponse]
        do { sections = try JSONDecoder().decode([SectionResponse].self, from: data) }
        catch { throw WeBeepAPIError.malformedPayload }
        guard sections.count <= 1_000 else { throw WeBeepAPIError.responseTooLarge }
        var issueCount = 0
        var identityCounts: [String: Int] = [:]
        var modulesWithDroppedEntries: Set<Int64> = []
        var isComplete = true
        let mapped = sections.compactMap { section -> RemoteContentSection? in
            guard section.id > 0 else { issueCount += 1; isComplete = false; return nil }
            let sectionName = MoodleText.normalized(section.name) ?? ""
            if section.modules == nil { isComplete = false }
            issueCount += section.modules?.discardedCount ?? 0
            if (section.modules?.discardedCount ?? 0) > 0 { isComplete = false }
            let modules = (section.modules?.elements ?? []).compactMap { module -> RemoteContentModule? in
                guard module.id > 0 else { issueCount += 1; isComplete = false; return nil }
                let name = MoodleText.normalized(module.name) ?? ""
                issueCount += module.contents?.discardedCount ?? 0
                if (module.contents?.discardedCount ?? 0) > 0 { modulesWithDroppedEntries.insert(module.id) }
                if module.contents == nil { modulesWithDroppedEntries.insert(module.id) }
                if let modname = module.modname?.lowercased(), ["forum", "url", "page", "label", "choice", "feedback", "lesson", "wooclap"].contains(modname) {
                    issueCount += module.contents?.elements.count ?? 0
                    modulesWithDroppedEntries.insert(module.id)
                    return nil
                }
                let moduleContents = module.contents?.elements ?? []
                let isSingleFileResource = module.modname?.lowercased() == "resource"
                    && moduleContents.count == 1
                    && moduleContents.first?.type == "file"
                let files = moduleContents.compactMap { content -> RemoteFileCandidate? in
                    guard content.type == "file" else {
                        if content.type != "directory" { issueCount += 1; modulesWithDroppedEntries.insert(module.id) }
                        return nil
                    }
                    guard let filename = bounded(content.filename), let remoteFilePath = bounded(content.filepath),
                          let filesize = content.filesize, filesize >= 0,
                          let timemodified = content.timemodified, timemodified >= 0,
                          // An out-of-range (or NaN) timestamp would trap when narrowed to Int64 for the
                          // revision fallback below, so it is treated as a malformed entry instead.
                          let modifiedSeconds = Int64(exactly: timemodified.rounded(.towardZero)),
                          let urlText = content.fileurl, let url = URL(string: urlText), let canonicalPath = canonicalPluginPath(url, policy: policy) else { issueCount += 1; modulesWithDroppedEntries.insert(module.id); return nil }
                    let identity = "\(courseID):\(module.id):\(remoteFilePath):\(filename)"
                    identityCounts[identity, default: 0] += 1
                    let hasCredentialQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name.caseInsensitiveCompare("token") == .orderedSame || $0.name.caseInsensitiveCompare("wstoken") == .orderedSame } == true
                    let reason: String?
                    if content.isexternalfile == true { reason = tr("file esterno", "external file") }
                    else if hasCredentialQuery { reason = tr("URL con credenziale", "URL with credential") }
                    else { reason = nil }
                    if reason != nil { issueCount += 1 }
                    let revision = validContentHash(content.contenthash) ?? "\(modifiedSeconds):\(filesize)"
                    return RemoteFileCandidate(
                        id: identity, courseID: courseID, sectionID: section.id, moduleID: module.id,
                        sectionName: sectionName, moduleName: name,
                        moduleType: module.modname?.lowercased() ?? "unknown", isSingleFileResource: isSingleFileResource,
                        filename: filename, remoteFilePath: remoteFilePath, canonicalPluginPath: canonicalPath,
                        downloadURL: reason == nil ? url : nil, size: filesize,
                        modifiedAt: Date(timeIntervalSince1970: timemodified), observedRevision: revision,
                        isSupported: reason == nil, ineligibilityReason: reason
                    )
                }
                return RemoteContentModule(id: module.id, name: name, files: files)
            }
            return RemoteContentSection(id: section.id, name: sectionName, modules: modules)
        }
        let duplicateIDs = Set(identityCounts.compactMap { $0.value > 1 ? $0.key : nil })
        if !duplicateIDs.isEmpty { issueCount += duplicateIDs.count }
        let resolved = mapped.map { section in
            RemoteContentSection(id: section.id, name: section.name, modules: section.modules.map { module in
                RemoteContentModule(id: module.id, name: module.name, files: module.files.map { file in
                    guard duplicateIDs.contains(file.id) else { return file }
                    var duplicate = file
                    duplicate.isSupported = false
                    duplicate.ineligibilityReason = tr("identificatore remoto duplicato", "duplicate remote identifier")
                    return duplicate
                })
            })
        }
        return RemoteCourseContents(sections: resolved, issueCount: issueCount, modulesWithDroppedEntries: modulesWithDroppedEntries, isComplete: isComplete)
    }

    /// Moodle web service that `fetchOwnEmail` calls. Callers check
    /// `WeBeepSiteInfo.availableFunctions.contains(ownEmailFunction)` first: a WeBeep token may not
    /// be allowed to call it, and its absence must not be treated as a failed sign-in.
    public static let ownEmailFunction = AllowedFunction.userByField.rawValue

    /// Response cap for `fetchOwnEmail`: one user record (profile fields and preferences) is a few
    /// kilobytes, so 1 MiB, as for site info, leaves headroom without unbounded reception (#102).
    static let ownEmailResponseLimit = 1_048_576

    /// The e-mail address on the signed-in user's WeBeep profile, used to pre-fill the Polimi
    /// address Webex asks for in native recordings playback (#148).
    ///
    /// Returns the raw string, untouched, for the user whose `id` equals `userID`; nil when Moodle
    /// returns no user, only other users, or a user without a non-blank `email`. It does not
    /// validate the address: `PolimiEmail` does that at the caller, so the network client stays
    /// independent of the playback policy. Moodle errors map as for `fetchCourses`
    /// (`invalidtoken` → `.invalidToken`, any other exception → `.malformedPayload`).
    /// The address is personal data and the token a credential: neither is ever logged.
    public func fetchOwnEmail(userID: Int, token: String) async throws -> String? {
        guard userID > 0 else { throw WeBeepAPIError.malformedPayload }
        let data = try await request(.userByField, token: token, fields: Self.ownEmailFields(userID: userID), limit: Self.ownEmailResponseLimit)
        if let error = try? JSONDecoder().decode(MoodleErrorResponse.self, from: data), error.exception != nil || error.errorcode != nil {
            throw error.errorcode == "invalidtoken" ? WeBeepAPIError.invalidToken : WeBeepAPIError.malformedPayload
        }
        let users: [UserResponse]
        do { users = try JSONDecoder().decode([UserResponse].self, from: data) }
        catch { throw WeBeepAPIError.malformedPayload }
        // Match the id rather than taking the first element: an address that belongs to someone
        // else must never be offered as the user's own, whatever order Moodle returns.
        guard let email = users.first(where: { $0.id == Int64(userID) })?.email,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return email
    }

    /// `core_user_get_users_by_field` takes a field name and an array of values; PHP reads the
    /// form key `values[0]` as the array's first element.
    private static func ownEmailFields(userID: Int) -> [String: String] {
        ["field": "id", "values[0]": String(userID)]
    }

    private func request(_ function: AllowedFunction, token: String, fields: [String: String], limit: Int) async throws -> Data {
        let request = Self.request(function: function, token: token, fields: fields, endpoint: policy.endpoint)
        do { return try await BoundedMetadataResponse(limit: limit).run(request, in: session) }
        catch let error as WeBeepAPIError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError { throw WeBeepAPIError.network(NetworkFailure(error.code)) }
        catch { throw WeBeepAPIError.invalidResponse }
    }

    static func validationRequest(token: String) -> URLRequest {
        request(function: .siteInfo, token: token, fields: [:], endpoint: endpoint)
    }

    static func coursesRequest(userID: Int, token: String) -> URLRequest {
        request(function: .courses, token: token, fields: ["userid": String(userID)], endpoint: endpoint)
    }

    static func contentsRequest(courseID: Int64, token: String) -> URLRequest {
        request(function: .contents, token: token, fields: ["courseid": String(courseID)], endpoint: endpoint)
    }

    static func ownEmailRequest(userID: Int, token: String) -> URLRequest {
        request(function: .userByField, token: token, fields: ownEmailFields(userID: userID), endpoint: endpoint)
    }

    private static func request(function: AllowedFunction, token: String, fields: [String: String], endpoint: URL) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form(fields.merging([
            "wstoken": token,
            "wsfunction": function.rawValue,
            "moodlewsrestformat": "json",
            "moodlewssettingfilter": "true",
            "moodlewssettinglang": "it"
        ]) { _, required in required })
        return request
    }

    private static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
}

/// Accumulates metadata only up to the caller's cap, cancelling reception at the first overrun (#102).
/// The task uses the original session, including injected URLProtocols and credentials. Redirect and
/// authentication methods remain on its session delegate, as with the bounded file downloader.
final class BoundedMetadataResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var body = Data()
    private var receivedResponse = false
    private var rejection: Error?
    private var continuation: CheckedContinuation<Data, Error>?
    private var completed = false
    private var consumerInstalled = false
    private var earlyResult: Result<Data, Error>?

    /// Which `Content-Type` an answer must have to be read: JSON for every web-service call, an
    /// image for `fetchCourseImage`. Anything else is refused before a byte is buffered.
    private let acceptsContentType: @Sendable (String?) -> Bool

    init(limit: Int, acceptsContentType: @escaping @Sendable (String?) -> Bool = { $0?.lowercased().contains("application/json") == true }) {
        self.limit = limit
        self.acceptsContentType = acceptsContentType
    }

    /// No async byte sequence or main-actor hop: URLSession supplies background chunk callbacks.
    func run(_ request: URLRequest, in session: URLSession) async throws -> Data {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await receive { task.resume() }
        } onCancel: {
            task.cancel()
        }
    }

    /// Install the consumer or deliver a terminal result received before installation (#127).
    /// Callback completion and installation share one lock; resume/start happen outside it.
    func receive(start: @Sendable () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<Data, Error>? in
                precondition(!consumerInstalled, "Metadata reception has one consumer")
                consumerInstalled = true
                if completed {
                    let result = earlyResult
                    earlyResult = nil
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
            else { start() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let failure: WeBeepAPIError?
        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) { failure = .transport(http.statusCode) }
            else if !acceptsContentType(http.value(forHTTPHeaderField: "Content-Type")) { failure = .invalidResponse }
            else if http.expectedContentLength > Int64(limit) { failure = .responseTooLarge }
            else { failure = nil }
        } else { failure = .invalidResponse }
        let allow = lock.withLock { () -> Bool in
            guard !completed else { return false }
            receivedResponse = true
            if let failure { rejection = failure }
            return failure == nil
        }
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop = lock.withLock { () -> Bool in
            guard !completed, rejection == nil else { return true }
            // Count the bytes URLSession delivers after decompression. Header lengths can be absent,
            // false, or compressed; they never replace this check or permit an oversized allocation.
            guard data.count <= limit - body.count else {
                rejection = WeBeepAPIError.responseTooLarge
                body = Data()
                return true
            }
            body.append(data)
            return false
        }
        if stop { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = lock.withLock { () -> (CheckedContinuation<Data, Error>, Result<Data, Error>)? in
            guard !completed else { return nil }
            completed = true
            // Retain a terminal result even when cancellation of a suspended task completes
            // before receive installs its continuation. No callback may complete twice.
            let failure = rejection ?? error ?? (receivedResponse ? nil : WeBeepAPIError.invalidResponse)
            let result: Result<Data, Error> = failure.map { .failure($0) } ?? .success(body)
            body = Data()
            guard let pending = continuation else {
                earlyResult = result
                return nil
            }
            continuation = nil
            return (pending, result)
        }
        if let (pending, result) = completion { pending.resume(with: result) }
    }
}

private func bounded(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.utf8.count <= 512 else { return nil }
    return value
}

public enum MoodleText {
    // Compiled once: `normalized` runs for every section and module name of every course on
    // every sync, and an `NSRegularExpression` is immutable, so one shared instance is safe.
    private static let multilangExpression = try? NSRegularExpression(
        pattern: #"\{mlang\s+([^}]+)\}([\s\S]*?)\{mlang\}"#,
        options: [.caseInsensitive]
    )

    public static func normalized(_ value: String?) -> String? {
        guard let value = bounded(value) else { return nil }
        let decoded = decodedHTMLEntities(value)
        guard let expression = multilangExpression else {
            return bounded(decoded)
        }
        let range = NSRange(decoded.startIndex..., in: decoded)
        let matches = expression.matches(in: decoded, range: range)
        guard !matches.isEmpty else { return bounded(decoded) }
        let language = Locale.current.language.languageCode?.identifier.lowercased()
        let candidates = matches.compactMap { match -> (String, String)? in
            guard let languageRange = Range(match.range(at: 1), in: decoded),
                  let textRange = Range(match.range(at: 2), in: decoded) else { return nil }
            return (String(decoded[languageRange]).lowercased(), String(decoded[textRange]))
        }
        let selected = candidates.first { language != nil && $0.0.split(separator: ",").map(String.init).contains(language!) }
            ?? candidates.first { $0.0.split(separator: ",").map(String.init).contains("en") }
            ?? candidates.first
        return bounded(selected?.1)
    }
}

private func decodedHTMLEntities(_ value: String) -> String {
    var decoded = value
    for _ in 0..<3 {
        let next = decodedHTMLEntitiesOnce(decoded)
        guard next != decoded else { break }
        decoded = next
    }
    return decoded
}

private func decodedHTMLEntitiesOnce(_ value: String) -> String {
    guard value.contains("&") else { return value }
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
        guard value[index] == "&", let end = value[index...].firstIndex(of: ";") else {
            result.append(value[index])
            index = value.index(after: index)
            continue
        }
        let entity = String(value[value.index(after: index)..<end])
        if let decoded = decodedHTMLEntity(entity) {
            result.append(decoded)
        } else {
            result.append(contentsOf: value[index...end])
        }
        index = value.index(after: end)
    }
    return result
}

private func decodedHTMLEntity(_ entity: String) -> Character? {
    switch entity {
    case "amp": return "&"
    case "lt": return "<"
    case "gt": return ">"
    case "quot": return "\""
    case "apos", "#39": return "'"
    case "nbsp": return " "
    default:
        let scalar: UInt32?
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            scalar = UInt32(entity.dropFirst(2), radix: 16)
        } else if entity.hasPrefix("#") {
            scalar = UInt32(entity.dropFirst())
        } else {
            scalar = nil
        }
        return scalar.flatMap(UnicodeScalar.init).map(Character.init)
    }
}

private func canonicalPluginPath(_ url: URL, policy: WeBeepServerPolicy) -> String? {
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
    guard policy.acceptsPluginURL(url),
          let path, path.hasPrefix("/webservice/pluginfile.php/") || path.hasPrefix("/pluginfile.php/") else { return nil }
    return path
}

private func validContentHash(_ value: String?) -> String? {
    let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    guard let value,
          (value.utf8.count == 40 || value.utf8.count == 64),
          value.unicodeScalars.allSatisfy({ hexadecimal.contains($0) }) else { return nil }
    return value.lowercased()
}

/// The only Moodle web services BeepBar calls. A new call is added here deliberately, never built
/// from a free-form string.
private enum AllowedFunction: String {
    case siteInfo = "core_webservice_get_site_info"
    case courses = "core_enrol_get_users_courses"
    case contents = "core_course_get_contents"
    case userByField = "core_user_get_users_by_field"
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct MoodleErrorResponse: Decodable { let exception: String?; let errorcode: String? }

private struct SiteInfoResponse: Decodable {
    let userid: Int?
    let siteurl: String?
    let functions: [Function]?
    let exception: String?
    let errorcode: String?
    struct Function: Decodable { let name: String }
}

/// One element of `core_user_get_users_by_field`. Only what `fetchOwnEmail` needs is decoded;
/// `email` is optional because Moodle omits it when the field is hidden or unset.
private struct UserResponse: Decodable { let id: Int64; let email: String? }

private struct CourseResponse: Decodable {
    let id: Int64
    let shortname: String?
    let fullname: String?
    let displayname: String?
    let visible: Int?
    let startdate: TimeInterval?
    let enddate: TimeInterval?
    /// The course image fields (`WeBeepCourseImage`). Decoded leniently: they are a nicety, and
    /// an unexpected shape must cost the course its picture, never the whole course list.
    let overviewfiles: [WeBeepCourseImage.OverviewFile]
    let courseimage: String?

    private enum CodingKeys: String, CodingKey {
        case id, shortname, fullname, displayname, visible, startdate, enddate, overviewfiles, courseimage
    }

    private struct OverviewFileResponse: Decodable {
        let fileurl: String?
        let mimetype: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        shortname = try container.decodeIfPresent(String.self, forKey: .shortname)
        fullname = try container.decodeIfPresent(String.self, forKey: .fullname)
        displayname = try container.decodeIfPresent(String.self, forKey: .displayname)
        visible = try container.decodeIfPresent(Int.self, forKey: .visible)
        startdate = try container.decodeIfPresent(TimeInterval.self, forKey: .startdate)
        enddate = try container.decodeIfPresent(TimeInterval.self, forKey: .enddate)
        let files = (try? container.decodeIfPresent(LossyArray<OverviewFileResponse>.self, forKey: .overviewfiles))??.elements ?? []
        overviewfiles = files.prefix(20).map { WeBeepCourseImage.OverviewFile(fileURL: $0.fileurl, mimeType: $0.mimetype) }
        courseimage = (try? container.decodeIfPresent(String.self, forKey: .courseimage)) ?? nil
    }
}

private struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let discardedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var discardedCount = 0
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            do { elements.append(try Element(from: elementDecoder)) }
            catch { discardedCount += 1 }
        }
        self.elements = elements
        self.discardedCount = discardedCount
    }
}

private struct SectionResponse: Decodable { let id: Int64; let name: String?; let modules: LossyArray<ModuleResponse>? }
private struct ModuleResponse: Decodable { let id: Int64; let name: String?; let modname: String?; let contents: LossyArray<ContentResponse>? }
private struct ContentResponse: Decodable {
    let type: String?
    let filename: String?
    let filepath: String?
    let filesize: Int64?
    let fileurl: String?
    let timemodified: TimeInterval?
    let contenthash: String?
    let isexternalfile: Bool?
}
