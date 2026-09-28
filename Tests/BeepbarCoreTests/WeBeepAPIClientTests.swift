import Foundation
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

    private func testSession(handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) -> URLSession {
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
