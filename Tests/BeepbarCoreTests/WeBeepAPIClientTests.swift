import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct WeBeepAPIClientTests {
    @Test func validatesSiteInfoAndKeepsTokenOutOfURL() async throws {
        let built = WeBeepAPIClient.validationRequest(token: "secret+token")
        #expect(built.url == WeBeepAPIClient.endpoint)
        #expect(built.httpMethod == "POST")
        #expect(built.url?.query == nil)
        let body = String(data: built.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("wstoken=secret%2Btoken"))
        #expect(body.contains("moodlewssettingfilter=true"))
        #expect(body.contains("moodlewssettinglang=it"))
        let session = testSession { request in
            #expect(request.url == WeBeepAPIClient.endpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.query == nil)
            return response(status: 200, body: #"{"userid":7,"siteurl":"https://webeep.polimi.it","functions":[{"name":"core_enrol_get_users_courses"},{"name":"core_course_get_contents"}]}"#)
        }
        let info = try await WeBeepAPIClient(session: session).validateToken("secret+token")
        #expect(info.userID == 7)
    }

    @Test(arguments: [
        #"{"exception":"invalidtoken","errorcode":"invalidtoken"}"#,
        #"{"userid":7,"siteurl":"https://evil.example","functions":[]}"#,
        #"{"userid":7,"siteurl":"https://webeep.polimi.it","functions":[]}"#,
        "not json"
    ])
    func rejectsInvalidSiteInfo(_ body: String) async {
        let session = testSession { _ in response(status: 200, body: body) }
        await #expect(throws: WeBeepAPIError.self) { try await WeBeepAPIClient(session: session).validateToken("token") }
    }

    @Test func rejectsNonJSONAndHTTPFailures() async {
        let html = testSession { _ in response(status: 200, body: "{}", contentType: "text/html") }
        await #expect(throws: WeBeepAPIError.invalidResponse) { try await WeBeepAPIClient(session: html).validateToken("token") }
        let unavailable = testSession { _ in response(status: 503, body: "{}") }
        await #expect(throws: WeBeepAPIError.transport(503)) { try await WeBeepAPIClient(session: unavailable).validateToken("token") }
    }

    @Test func classifiesFailuresForUserFacingRecovery() {
        #expect(SyncServiceFailure(.invalidToken) == .authenticationExpired)
        #expect(SyncServiceFailure(.network(.offline)) == .connectivity)
        #expect(SyncServiceFailure(.transport(503)) == .serviceUnavailable)
        #expect(SyncServiceFailure(.transport(403)) == .incompatibleResponse)
        #expect(SyncServiceFailure(.malformedPayload) == .incompatibleResponse)
    }

    @Test func decodesMinimalCoursesAndEncodesUserIDInBody() async throws {
        let built = WeBeepAPIClient.coursesRequest(userID: 7, token: "secret+token")
        #expect(built.url == WeBeepAPIClient.endpoint)
        #expect(built.url?.query == nil)
        let body = String(data: built.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("userid=7"))
        #expect(body.contains("moodlewssettingfilter=true"))
        #expect(body.contains("moodlewssettinglang=it"))
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":9,"shortname":"HPC","fullname":"High Performance Computing","visible":1,"startdate":0,"ignored":"field"}]"#)
        }
        let courses = try await WeBeepAPIClient(session: session).fetchCourses(userID: 7, token: "token")
        #expect(courses == [RemoteCourseSummary(id: 9, shortName: "HPC", displayName: "High Performance Computing", isVisible: true, startDate: Date(timeIntervalSince1970: 0), endDate: nil)])
    }

    @Test func decodesHTMLEntitiesInCourseNames() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":9,"shortname":"GPUS &amp; HETEROGENEOUS SYSTEMS","fullname":"GPUS &amp; HETEROGENEOUS SYSTEMS","visible":1}]"#)
        }
        let courses = try await WeBeepAPIClient(session: session).fetchCourses(userID: 7, token: "token")
        #expect(courses.first?.shortName == "GPUS & HETEROGENEOUS SYSTEMS")
        #expect(courses.first?.displayName == "GPUS & HETEROGENEOUS SYSTEMS")
    }

    @Test func decodesRepeatedHTMLEntitiesInCourseNames() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":9,"shortname":"GPUS &amp;amp; HETEROGENEOUS SYSTEMS","fullname":"GPUS &amp;amp; HETEROGENEOUS SYSTEMS","visible":1}]"#)
        }
        let courses = try await WeBeepAPIClient(session: session).fetchCourses(userID: 1, token: "token")

        #expect(courses.first?.displayName == "GPUS & HETEROGENEOUS SYSTEMS")
        #expect(courses.first?.shortName == "GPUS & HETEROGENEOUS SYSTEMS")
    }

    @Test(arguments: [
        #"[{"id":0,"shortname":"HPC"}]"#,
        #"[{"id":9,"shortname":"HPC"},{"id":9,"shortname":"Other"}]"#,
        #"{"exception":"invalidparameter","errorcode":"invalidparameter"}"#,
        "not json"
    ])
    func rejectsInvalidCourses(_ body: String) async {
        let session = testSession { _ in response(status: 200, body: body) }
        await #expect(throws: WeBeepAPIError.self) { try await WeBeepAPIClient(session: session).fetchCourses(userID: 7, token: "token") }
    }

    @Test func distinguishesExpiredTokenFromOtherMoodleErrors() async {
        let expired = testSession { _ in response(status: 200, body: #"{"exception":"invalidtoken","errorcode":"invalidtoken"}"#) }
        await #expect(throws: WeBeepAPIError.invalidToken) {
            try await WeBeepAPIClient(session: expired).fetchCourses(userID: 7, token: "token")
        }

        let invalidParameter = testSession { _ in response(status: 200, body: #"{"exception":"invalidparameter","errorcode":"invalidparameter"}"#) }
        await #expect(throws: WeBeepAPIError.malformedPayload) {
            try await WeBeepAPIClient(session: invalidParameter).fetchCourses(userID: 7, token: "token")
        }
    }

    @Test func decodesSupportedFileMetadataWithoutDownloading() async throws {
        let built = WeBeepAPIClient.contentsRequest(courseID: 9, token: "secret")
        #expect(built.url?.query == nil)
        let body = String(data: built.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("courseid=9"))
        #expect(body.contains("moodlewssettingfilter=true"))
        #expect(body.contains("moodlewssettinglang=it"))
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"name":"Week 1","modules":[{"id":4,"name":"Slides","contents":[{"type":"file","filename":"intro.pdf","filepath":"/","filesize":42,"timemodified":1,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")
        #expect(contents.issueCount == 0)
        #expect(contents.sections[0].modules[0].files[0].isSupported)
    }

    @Test func keepsFileIdentityWhenMoodleReissuesItsPluginURL() async throws {
        func file(from url: String) async throws -> RemoteFileCandidate {
            let session = testSession { _ in
                response(status: 200, body: """
                [{"id":1,"modules":[{"id":4,"name":"Slides","contents":[{"type":"file","filename":"intro.pdf","filepath":"/notes/","filesize":42,"timemodified":1,"fileurl":"\(url)"}]}]}]
                """)
            }
            return try #require(try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token").sections.first?.modules.first?.files.first)
        }

        let first = try await file(from: "https://webeep.polimi.it/webservice/pluginfile.php/9/mod_folder/content/2/notes/intro.pdf")
        let reissued = try await file(from: "https://webeep.polimi.it/webservice/pluginfile.php/9/mod_folder/content/3/notes/intro.pdf")

        #expect(first.id == "9:4:/notes/:intro.pdf")
        #expect(first.id == reissued.id)
        #expect(first.canonicalPluginPath != reissued.canonicalPluginPath)
    }

    @Test func keepsValidEntriesBesideMalformedModulesAndContents() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"modules":[{"id":"bad"},{"id":4,"name":"Slides","contents":[{"type":"file","filename":7},{"type":"file","filename":"intro.pdf","filepath":"/","filesize":42,"timemodified":1,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"}]}]}]"#)
        }

        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.issueCount == 2)
        #expect(!contents.isComplete)
        #expect(contents.modulesWithDroppedEntries == [4])
        #expect(contents.sections[0].modules.map(\.id) == [4])
        #expect(contents.sections[0].modules[0].files.map(\.filename) == ["intro.pdf"])
    }

    @Test func missingModuleContentsCannotProveTrackedFilesWereRemoved() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"modules":[{"id":4,"name":"Slides","modname":"folder"}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.sections[0].modules[0].files.isEmpty)
        #expect(contents.modulesWithDroppedEntries == [4])
    }

    @Test func missingSectionModulesCannotProveTrackedFilesWereRemoved() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"name":"Week 1"}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.sections[0].modules.isEmpty)
        #expect(!contents.isComplete)
    }

    @Test func contentWithMissingTypeCannotProveTrackedFilesWereRemoved() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"modules":[{"id":4,"name":"Slides","contents":[{"filename":"intro.pdf","filepath":"/","filesize":42,"timemodified":1,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.sections[0].modules[0].files.isEmpty)
        #expect(contents.modulesWithDroppedEntries == [4])
    }

    @Test func normalizesMoodleSectionAndModuleNames() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"name":"","modules":[{"id":4,"name":"{mlang en}LECTURES{mlang}","modname":"folder","contents":[{"type":"file","filename":"intro.pdf","filepath":"/","filesize":42,"timemodified":1,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.sections[0].name.isEmpty)
        #expect(contents.sections[0].modules[0].name == "LECTURES")
        #expect(contents.sections[0].modules[0].files[0].sectionName.isEmpty)
        #expect(contents.sections[0].modules[0].files[0].moduleName == "LECTURES")
    }

    @Test func moduleWithoutANameIsKeptWithFallbackName() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"name":"Materiali","modules":[{"id":4,"name":"","modname":"folder","contents":[{"type":"file","filename":"p0.pdf","filepath":"/","filesize":42,"timemodified":1,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.issueCount == 0)
        #expect(contents.sections[0].modules.count == 1)
        #expect(contents.sections[0].modules[0].files[0].isSupported)
    }

    @Test func singleFileResourceRequiresExactlyOneContentEntry() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"name":"Esami","modules":[{"id":4,"name":"Regole","modname":"resource","contents":[{"type":"file","filename":"rules.pdf","filepath":"/","filesize":42,"timemodified":1,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"},{"type":"description","filename":"note"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.sections[0].modules[0].files[0].isSingleFileResource == false)
    }

    @Test func recognizesResourceWithExactlyOneFileEntry() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"name":"Esami","modules":[{"id":4,"name":"Regole","modname":"resource","contents":[{"type":"file","filename":"rules.pdf","filepath":"/","filesize":42,"timemodified":1,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.sections[0].modules[0].files[0].isSingleFileResource)
    }

    @Test func marksSuspiciousFileURLsUnsupported() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"modules":[{"id":4,"name":"Slides","contents":[{"type":"file","filename":"intro.pdf","filepath":"/","filesize":42,"timemodified":1,"fileurl":"https://webeep.polimi.it/pluginfile.php/a.pdf?token=secret"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")
        #expect(contents.issueCount == 1)
        #expect(!contents.sections[0].modules[0].files[0].isSupported)
    }

    @Test func outOfRangeTimeModifiedIsReportedAsMalformedEntry() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"name":"Week 1","modules":[{"id":4,"name":"Slides","contents":[{"type":"file","filename":"intro.pdf","filepath":"/","filesize":42,"timemodified":1e30,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")

        #expect(contents.issueCount == 1)
        #expect(contents.sections[0].modules[0].files.isEmpty)
    }

    @Test func revisionFallsBackToTimeModifiedAndSizeWithoutAContentHash() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":1,"name":"Week 1","modules":[{"id":4,"name":"Slides","contents":[{"type":"file","filename":"intro.pdf","filepath":"/","filesize":42,"timemodified":1700000000.75,"fileurl":"https://webeep.polimi.it/webservice/pluginfile.php/1/a.pdf"}]}]}]"#)
        }
        let contents = try await WeBeepAPIClient(session: session).fetchContents(courseID: 9, token: "token")
        let file = try #require(contents.sections[0].modules[0].files.first)

        #expect(file.observedRevision == "1700000000:42")
        #expect(file.modifiedAt == Date(timeIntervalSince1970: 1700000000.75))
        #expect(file.size == 42)
    }

    // MARK: fetchOwnEmail (#148)

    /// Proves the call is `core_user_get_users_by_field` with `field=id` and `values[0]=<id>`,
    /// sent as a POST body with the token (never in the URL), and that the public constant callers
    /// check against `availableFunctions` names the same function.
    @Test func ownEmailRequestUsesUsersByFieldWithTheUserID() async throws {
        #expect(WeBeepAPIClient.ownEmailFunction == "core_user_get_users_by_field")
        let built = WeBeepAPIClient.ownEmailRequest(userID: 7, token: "secret+token")
        #expect(built.url == WeBeepAPIClient.endpoint)
        #expect(built.httpMethod == "POST")
        #expect(built.url?.query == nil)
        let fields = formFields(built.httpBody ?? Data())
        #expect(fields["wsfunction"] == "core_user_get_users_by_field")
        #expect(fields["field"] == "id")
        #expect(fields["values[0]"] == "7")
        #expect(fields["wstoken"] == "secret+token")
        #expect(fields["moodlewsrestformat"] == "json")

        // The request actually sent by fetchOwnEmail carries the same fields.
        let sent = SentBody()
        let session = testSession { request in
            sent.value = formFields(bodyData(of: request))
            #expect(request.url?.query == nil)
            return response(status: 200, body: #"[{"id":42,"email":"a@mail.polimi.it"}]"#)
        }
        _ = try await WeBeepAPIClient(session: session).fetchOwnEmail(userID: 42, token: "tok")
        #expect(sent.value["wsfunction"] == WeBeepAPIClient.ownEmailFunction)
        #expect(sent.value["field"] == "id")
        #expect(sent.value["values[0]"] == "42")
        #expect(sent.value["wstoken"] == "tok")
    }

    /// Proves the address of the matching user is returned raw: not trimmed, lowercased or
    /// validated, since `PolimiEmail` is the caller's job.
    @Test func ownEmailReturnsTheMatchingUsersRawAddress() async throws {
        let session = testSession { _ in
            response(status: 200, body: #"[{"id":7,"username":"10712345","email":" Mario.Rossi@Mail.Polimi.it ","customfields":[]}]"#)
        }
        let email = try await WeBeepAPIClient(session: session).fetchOwnEmail(userID: 7, token: "token")
        #expect(email == " Mario.Rossi@Mail.Polimi.it ")
    }

    /// Guards against offering another person's address: only the user whose id matches counts,
    /// even when it is not first, and a response with only other users yields nil.
    @Test func ownEmailIgnoresOtherUsers() async throws {
        let both = testSession { _ in
            response(status: 200, body: #"[{"id":8,"email":"other@mail.polimi.it"},{"id":7,"email":"me@mail.polimi.it"}]"#)
        }
        #expect(try await WeBeepAPIClient(session: both).fetchOwnEmail(userID: 7, token: "token") == "me@mail.polimi.it")

        let onlyOther = testSession { _ in response(status: 200, body: #"[{"id":8,"email":"other@mail.polimi.it"}]"#) }
        #expect(try await WeBeepAPIClient(session: onlyOther).fetchOwnEmail(userID: 7, token: "token") == nil)
    }

    /// Proves "the account has no address" is nil, not an error: an empty array, a missing,
    /// null, empty or blank `email` all leave playback to ask the user.
    @Test(arguments: [
        "[]",
        #"[{"id":7}]"#,
        #"[{"id":7,"email":null}]"#,
        #"[{"id":7,"email":""}]"#,
        #"[{"id":7,"email":"  \n"}]"#
    ])
    func ownEmailIsNilWhenTheAccountHasNoAddress(_ body: String) async throws {
        let session = testSession { _ in response(status: 200, body: body) }
        #expect(try await WeBeepAPIClient(session: session).fetchOwnEmail(userID: 7, token: "token") == nil)
    }

    /// Proves Moodle exceptions follow the existing mapping: an expired token is `.invalidToken`
    /// (so the app asks to sign in again), any other exception or a non-array is malformed.
    @Test func ownEmailMapsMoodleErrors() async {
        let expired = testSession { _ in response(status: 200, body: #"{"exception":"moodle_exception","errorcode":"invalidtoken"}"#) }
        await #expect(throws: WeBeepAPIError.invalidToken) {
            try await WeBeepAPIClient(session: expired).fetchOwnEmail(userID: 7, token: "token")
        }
        let denied = testSession { _ in response(status: 200, body: #"{"exception":"webservice_access_exception","errorcode":"accessexception"}"#) }
        await #expect(throws: WeBeepAPIError.malformedPayload) {
            try await WeBeepAPIClient(session: denied).fetchOwnEmail(userID: 7, token: "token")
        }
        let garbage = testSession { _ in response(status: 200, body: #"{"users":[]}"#) }
        await #expect(throws: WeBeepAPIError.malformedPayload) {
            try await WeBeepAPIClient(session: garbage).fetchOwnEmail(userID: 7, token: "token")
        }
        let unavailable = testSession { _ in response(status: 503, body: "{}") }
        await #expect(throws: WeBeepAPIError.transport(503)) {
            try await WeBeepAPIClient(session: unavailable).fetchOwnEmail(userID: 7, token: "token")
        }
    }

    /// Proves a non-positive id is refused before any request, like `fetchCourses`.
    @Test func ownEmailRejectsInvalidUserIDWithoutARequest() async {
        let requested = SentBody()
        let session = testSession { _ in requested.value = ["called": "yes"]; return response(status: 200, body: "[]") }
        await #expect(throws: WeBeepAPIError.malformedPayload) {
            try await WeBeepAPIClient(session: session).fetchOwnEmail(userID: 0, token: "token")
        }
        #expect(requested.value.isEmpty)
    }

    /// Guards the reception bound (#102): a body larger than the cap is refused as
    /// `.responseTooLarge`, while a body half the cap's size is still accepted.
    @Test func ownEmailResponseIsBounded() async throws {
        let padding = String(repeating: "x", count: WeBeepAPIClient.ownEmailResponseLimit)
        let oversized = testSession { _ in response(status: 200, body: #"[{"id":7,"email":"a@polimi.it","description":"\#(padding)"}]"#) }
        await #expect(throws: WeBeepAPIError.responseTooLarge) {
            try await WeBeepAPIClient(session: oversized).fetchOwnEmail(userID: 7, token: "token")
        }
        let small = String(repeating: "x", count: WeBeepAPIClient.ownEmailResponseLimit / 2)
        let fits = testSession { _ in response(status: 200, body: #"[{"id":7,"email":"a@polimi.it","description":"\#(small)"}]"#) }
        #expect(try await WeBeepAPIClient(session: fits).fetchOwnEmail(userID: 7, token: "token") == "a@polimi.it")
    }

    private func formFields(_ body: Data) -> [String: String] {
        let text = String(data: body, encoding: .utf8) ?? ""
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    /// URLSession moves a POST body into `httpBodyStream` before a URLProtocol sees it.
    private func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func testSession(handler:@escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) -> URLSession {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(status: Int, body: String, contentType: String = "application/json") -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: WeBeepAPIClient.endpoint, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!, Data(body.utf8))
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { let (response, data) = Self.handler(request); client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() {}
}

/// Captures what a stub handler saw, for assertions after the call returns.
private final class SentBody: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]
    var value: [String: String] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
