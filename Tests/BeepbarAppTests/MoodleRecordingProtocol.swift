import Foundation
import os
import BeepbarCore

/// A local Moodle for app tests: answers site info, the enrolled courses and course contents,
/// serves file downloads, and records every request with the network restrictions it carried.
/// Everything is keyed by the request's token, so tests running in parallel never see each other's
/// courses or requests; each test registers its own token and must never use the installed app's.
///
/// Files are listed only when the test registers some, and they may only be downloaded through
/// `makeDownloader()`: a controller left on its default downloader would send the download to
/// the real WeBeep host.
final class MoodleRecordingProtocol: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Hashable, Sendable {
        let function: String
        let allowsExpensiveNetworkAccess: Bool
        let allowsConstrainedNetworkAccess: Bool
    }

    private struct Account {
        var courses: [(id: Int64, name: String)]
        var files: [Int64: [String]]
        var userID: Int
        var requests: [RecordedRequest] = []
        var onHotspot = false
        var offline = false
        /// Moodle stopped accepting the token but the account's held answers stay deliverable.
        var rejected = false
        var holdsCourseLists = false
        var malformedCourseLists = false
        var timesOut = false
        var heldCourseLists: [@Sendable () -> Void] = []
        /// The profile address `core_user_get_users_by_field` answers; site info lists that
        /// function only when `listsEmailFunction` is set.
        var email: String?
        var listsEmailFunction = false
        var holdsEmails = false
        var heldEmails: [@Sendable () -> Void] = []
        var holdsCourseImages = false
        var heldCourseImages: [@Sendable () -> Void] = []
    }

    /// What a download records as its `function`.
    static let downloadFunction = "download"

    private static let accounts = OSAllocatedUnfairLock(initialState: [String: Account]())

    /// A fresh token whose account lists `courses`, in this order, as its enrolled courses, and
    /// `files` (one-byte files, by course) in their contents. `userID` is the Moodle user id its
    /// site info reports; tests that tell two accounts apart give them different ones.
    static func register(courses: [(id: Int64, name: String)], files: [Int64: [String]] = [:], userID: Int = 7) -> String {
        let token = UUID().uuidString
        accounts.withLock { $0[token] = Account(courses: courses, files: files, userID: userID) }
        return token
    }

    /// Makes site info report `userID` for this token from now on: the stored token turning out
    /// to belong to another account at the next connection check, with nothing else changing
    /// (the controller caches its token, so a test can't swap the token itself).
    static func setUserID(token: String, _ userID: Int) {
        accounts.withLock { $0[token]?.userID = userID }
    }

    /// Gives this account a profile `email`; `listed` says whether site info lists the function
    /// that reads it (a WeBeep token may not be allowed to call it).
    static func setProfileEmail(token: String, _ email: String?, listed: Bool) {
        accounts.withLock {
            $0[token]?.email = email
            $0[token]?.listsEmailFunction = listed
        }
    }

    /// Holds every profile-address answer for this account until `releaseEmails(token:)`, like
    /// `holdCourseLists(token:)`: lets a test switch accounts while the address is on its way.
    static func holdEmails(token: String) {
        accounts.withLock { $0[token]?.holdsEmails = true }
    }

    static func heldEmailCount(token: String) -> Int {
        accounts.withLock { $0[token]?.heldEmails.count ?? 0 }
    }

    static func releaseEmails(token: String) {
        let held = accounts.withLock { accounts -> [@Sendable () -> Void] in
            let held = accounts[token]?.heldEmails ?? []
            accounts[token]?.holdsEmails = false
            accounts[token]?.heldEmails = []
            return held
        }
        held.forEach { $0() }
    }

    /// Holds every course-picture download (`/course/overviewfiles/`) for this account until
    /// `releaseCourseImages(token:)`: lets a test change the account while a picture is on its way.
    static func holdCourseImages(token: String) {
        accounts.withLock { $0[token]?.holdsCourseImages = true }
    }

    static func heldCourseImageCount(token: String) -> Int {
        accounts.withLock { $0[token]?.heldCourseImages.count ?? 0 }
    }

    static func releaseCourseImages(token: String) {
        let held = accounts.withLock { accounts -> [@Sendable () -> Void] in
            let held = accounts[token]?.heldCourseImages ?? []
            accounts[token]?.holdsCourseImages = false
            accounts[token]?.heldCourseImages = []
            return held
        }
        held.forEach { $0() }
    }

    /// Puts this account's Mac on a phone hotspot: a request that may not use an expensive network
    /// fails with `URLError.notConnectedToInternet`, as macOS fails it. Requests that may use any
    /// network still go through.
    static func setOnHotspot(token: String, _ onHotspot: Bool) {
        accounts.withLock { $0[token]?.onHotspot = onHotspot }
    }

    /// Moodle stops accepting `token`: every later call with it answers `invalidtoken`, as an
    /// expired sign-in does. Its recorded requests go with it.
    static func revoke(token: String) {
        accounts.withLock { $0[token] = nil }
    }

    /// Takes this account's Mac offline: every request fails with
    /// `URLError.notConnectedToInternet`, as macOS fails it without a network. Still recorded.
    static func setOffline(token: String, _ offline: Bool) {
        accounts.withLock { $0[token]?.offline = offline }
    }

    /// Moodle stops accepting `token` like `revoke(token:)`, but its held answers stay: once
    /// released they answer `invalidtoken`, as a request that reached Moodle after the token
    /// expired would.
    static func reject(token: String) {
        accounts.withLock { $0[token]?.rejected = true }
    }

    /// Holds every enrolled-courses answer for this account until
    /// `releaseCourseLists(token:)`: lets a test change the app's state while a refresh waits for
    /// Moodle and then deliver the answer late.
    static func holdCourseLists(token: String) {
        accounts.withLock { $0[token]?.holdsCourseLists = true }
    }

    static func heldCourseListCount(token: String) -> Int {
        accounts.withLock { $0[token]?.heldCourseLists.count ?? 0 }
    }

    /// Delivers every held enrolled-courses answer, worked out now, and stops holding new ones.
    static func releaseCourseLists(token: String) {
        let held = accounts.withLock { accounts -> [@Sendable () -> Void] in
            let held = accounts[token]?.heldCourseLists ?? []
            accounts[token]?.holdsCourseLists = false
            accounts[token]?.heldCourseLists = []
            return held
        }
        held.forEach { $0() }
    }

    static func setCourses(token: String, courses: [(id: Int64, name: String)]) {
        accounts.withLock { $0[token]?.courses = courses }
    }

    static func requests(token: String) -> [RecordedRequest] {
        accounts.withLock { $0[token]?.requests ?? [] }
    }

    static func makeClient() -> WeBeepAPIClient {
        WeBeepAPIClient(session: makeSession())
    }

    /// A downloader whose requests stay in this protocol, for the files `register(files:)` lists.
    static func makeDownloader() -> RemoteDownloader {
        RemoteDownloader(session: makeSession())
    }

    /// Moodle answers the enrolled-courses call with something that isn't a course list: a server
    /// failure that a network change cannot fix, unlike `setOffline(token:_:)`.
    static func setMalformedCourseLists(token: String, _ malformed: Bool) {
        accounts.withLock { $0[token]?.malformedCourseLists = malformed }
    }

    /// Every request fails with `URLError.timedOut`, as a server that never answers does.
    static func setTimingOut(token: String, _ timesOut: Bool) {
        accounts.withLock { $0[token]?.timesOut = timesOut }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoodleRecordingProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let isDownload = url.path.hasPrefix("/webservice/pluginfile.php/")
        let fields = Self.formFields(request)
        let token = isDownload ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value ?? "" : fields["wstoken"] ?? ""
        let function = isDownload ? Self.downloadFunction : fields["wsfunction"] ?? ""
        let recorded = RecordedRequest(function: function, allowsExpensiveNetworkAccess: request.allowsExpensiveNetworkAccess, allowsConstrainedNetworkAccess: request.allowsConstrainedNetworkAccess)
        let account: Account? = Self.accounts.withLock { accounts in
            accounts[token]?.requests.append(recorded)
            return accounts[token]
        }
        if let account, account.onHotspot, !request.allowsExpensiveNetworkAccess {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let account, account.timesOut {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if let account, account.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if isDownload, url.path.contains("/course/overviewfiles/") {
            // A course picture: three bytes are enough, the tests check what reaches the caller.
            let this = self
            let deliver: @Sendable () -> Void = {
                let found = MoodleRecordingProtocol.accounts.withLock { $0[token] } != nil
                let response = HTTPURLResponse(url: url, statusCode: found ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
                this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
                if found { this.client?.urlProtocol(this, didLoad: Data([1, 2, 3])) }
                this.client?.urlProtocolDidFinishLoading(this)
            }
            let held = Self.accounts.withLock { accounts in
                guard accounts[token]?.holdsCourseImages == true else { return false }
                accounts[token]?.heldCourseImages.append(deliver)
                return true
            }
            if !held { deliver() }
            return
        }
        if isDownload {
            let body = Data("x".utf8)
            let found = account != nil
            let response = HTTPURLResponse(url: url, statusCode: found ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": found ? "\(body.count)" : "0"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if found { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let this = self
        let deliver: @Sendable () -> Void = {
            // Worked out when delivered, so a held answer reflects a token rejected meanwhile.
            let json = MoodleRecordingProtocol.answer(function: function, fields: fields, account: MoodleRecordingProtocol.accounts.withLock { $0[token] })
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
            this.client?.urlProtocol(this, didLoad: Data(json.utf8))
            this.client?.urlProtocolDidFinishLoading(this)
        }
        let held = Self.accounts.withLock { accounts in
            if function == "core_enrol_get_users_courses", accounts[token]?.holdsCourseLists == true {
                accounts[token]?.heldCourseLists.append(deliver)
                return true
            }
            if function == WeBeepAPIClient.ownEmailFunction, accounts[token]?.holdsEmails == true {
                accounts[token]?.heldEmails.append(deliver)
                return true
            }
            return false
        }
        if !held { deliver() }
    }

    private static func answer(function: String, fields: [String: String], account: Account?) -> String {
        switch (account, function) {
        case (nil, _):
            return #"{"exception":"invalidtoken","errorcode":"invalidtoken"}"#
        case (let account?, _) where account.rejected:
            return #"{"exception":"invalidtoken","errorcode":"invalidtoken"}"#
        case (let account?, "core_webservice_get_site_info"):
            let email = account.listsEmailFunction ? #",{"name":"\#(WeBeepAPIClient.ownEmailFunction)"}"# : ""
            return #"{"userid":\#(account.userID),"siteurl":"https://webeep.polimi.it","functions":[{"name":"core_enrol_get_users_courses"},{"name":"core_course_get_contents"}\#(email)]}"#
        case (let account?, WeBeepAPIClient.ownEmailFunction):
            guard let email = account.email else { return "[]" }
            return #"[{"id":\#(account.userID),"email":"\#(email)"}]"#
        case (let account?, "core_enrol_get_users_courses") where account.malformedCourseLists:
            return "{"
        case (let account?, "core_enrol_get_users_courses"):
            return "[" + account.courses.map { #"{"id":\#($0.id),"shortname":"\#($0.name)","fullname":"\#($0.name)","visible":1}"# }.joined(separator: ",") + "]"
        case (let account?, "core_course_get_contents"):
            return contents(course: Int64(fields["courseid"] ?? "") ?? 0, files: account.files)
        default:
            return "[]"
        }
    }

    /// One section with one folder module listing the course's registered files; empty without any.
    private static func contents(course: Int64, files: [Int64: [String]]) -> String {
        guard let names = files[course], !names.isEmpty else { return "[]" }
        let entries = names.map { name in
            #"{"type":"file","filename":"\#(name)","filepath":"/","filesize":1,"timemodified":1,"contenthash":"\#(String(repeating: "a", count: 40))","fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/\#(course)/\#(name)"}"#
        }.joined(separator: ",")
        return #"[{"id":\#(course),"name":"Materiali","modules":[{"id":\#(course * 100),"name":"Lezioni","modname":"folder","contents":[\#(entries)]}]}]"#
    }

    override func stopLoading() {}

    private static func formFields(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return Dictionary(body.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1].removingPercentEncoding ?? parts[1])
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// The callback Moodle's mobile login hands back for `token`, as `completeLoginForTesting` expects.
func moodleLoginCallback(token: String) -> URL {
    URL(string: "moodlemobile://token=\(Data("site:::\(token)".utf8).base64EncodedString())")!
}
