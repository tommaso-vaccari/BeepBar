import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BeepbarCore

/// The course picture shown as the artwork of the lecture playing in macOS's Now Playing
/// (issue #148 follow-up): which image Moodle's course list offers is kept, how it is fetched
/// with the token, and how it is stored with the saved course list without breaking users who
/// skip releases.
@Suite(.serialized) struct CourseImageTests {
    private let policy = WeBeepServerPolicy.production
    private static let host = WeBeepServerPolicy.production.host
    private static let image = "https://\(host)/webservice/pluginfile.php/123/course/overviewfiles/card.jpg"

    // MARK: Choosing the picture

    /// The teacher's uploaded picture (`overviewfiles`) wins over `courseimage`, and is kept as
    /// it is. Guards against picking the generated pattern when a real picture exists.
    @Test func theUploadedPictureWins() {
        let chosen = WeBeepCourseImage.select(
            overviewFiles: [.init(fileURL: Self.image, mimeType: "image/jpeg")],
            courseImage: "https://\(Self.host)/pluginfile.php/123/course/overviewfiles/other.png", policy: policy)
        #expect(chosen == URL(string: Self.image))
    }

    /// A browser address (`/pluginfile.php/`) becomes the web-service one, the only one that
    /// accepts the token. Guards against an artwork request that always fails with a login page.
    @Test func aBrowserAddressBecomesTheWebServiceOne() {
        let chosen = WeBeepCourseImage.select(overviewFiles: [], courseImage: "https://\(Self.host)/pluginfile.php/123/course/overviewfiles/card.png", policy: policy)
        #expect(chosen == URL(string: "https://\(Self.host)/webservice/pluginfile.php/123/course/overviewfiles/card.png"))
    }

    /// Everything that is not a credential-free HTTPS picture on WeBeep's own host is dropped:
    /// the generated `data:` pattern, plain HTTP, another host, a `file:` URL, an address already
    /// carrying a token, an SVG, a non-picture file, a path outside `pluginfile.php`. Guards
    /// against the student's token ever being sent anywhere but WeBeep, and against fetching
    /// something ImageIO cannot draw.
    @Test(arguments: [
        "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=",
        "http://\(host)/webservice/pluginfile.php/1/course/overviewfiles/a.jpg",
        "https://evil.example/webservice/pluginfile.php/1/course/overviewfiles/a.jpg",
        "https://\(host).evil.example/webservice/pluginfile.php/1/course/overviewfiles/a.jpg",
        "file:///etc/passwd",
        "https://\(host)/webservice/pluginfile.php/1/course/overviewfiles/a.jpg?token=abc",
        "https://\(host)/webservice/pluginfile.php/1/course/overviewfiles/a.jpg?wstoken=abc",
        "https://\(host)/webservice/pluginfile.php/../login/index.php",
        "https://\(host)/webservice/pluginfile.php/%2e%2e/login/index.php",
        "https://\(host)/webservice/pluginfile.php/1/%2E./%2e%2E/admin/a.jpg",
        "https://\(host)/webservice/pluginfile.php/./1/a.jpg",
        "https://\(host)/webservice/pluginfile.php/1/course/overviewfiles/a.svg",
        "https://user:pw@\(host)/webservice/pluginfile.php/1/course/overviewfiles/a.jpg",
        "https://\(host):8443/webservice/pluginfile.php/1/course/overviewfiles/a.jpg",
        "https://\(host)/course/view.php?id=1",
        "",
    ])
    func unacceptableAddressesAreDropped(_ address: String) {
        #expect(WeBeepCourseImage.select(overviewFiles: [.init(fileURL: address, mimeType: "image/jpeg")], courseImage: address, policy: policy) == nil)
    }

    /// An overview file that is not a picture (or is an SVG) is skipped for the next candidate.
    /// Guards against fetching a PDF a teacher attached as the course "image".
    @Test func nonPictureOverviewFilesAreSkipped() {
        let chosen = WeBeepCourseImage.select(overviewFiles: [
            .init(fileURL: "https://\(Self.host)/webservice/pluginfile.php/1/course/overviewfiles/syllabus.pdf", mimeType: "application/pdf"),
            .init(fileURL: "https://\(Self.host)/webservice/pluginfile.php/1/course/overviewfiles/logo.svg", mimeType: "image/svg+xml"),
            .init(fileURL: Self.image, mimeType: "image/jpeg"),
        ], courseImage: nil, policy: policy)
        #expect(chosen == URL(string: Self.image))
    }

    // MARK: The course list

    /// `core_enrol_get_users_courses` with an uploaded picture fills `imageURL`; one without
    /// leaves it nil. Guards against the artwork never reaching the app.
    @Test func theCourseListCarriesThePicture() async throws {
        let session = stubSession { _ in
            Self.json(#"[{"id":9,"shortname":"HPC","fullname":"High Performance Computing","overviewfiles":[{"filename":"card.jpg","fileurl":"\#(Self.image)","mimetype":"image/jpeg"}]},{"id":10,"shortname":"ML","fullname":"Machine Learning","courseimage":"data:image/svg+xml;base64,AAAA"}]"#)
        }
        let courses = try await WeBeepAPIClient(session: session).fetchCourses(userID: 7, token: "token")
        #expect(courses.map(\.imageURL) == [URL(string: Self.image), nil])
    }

    /// A picture field of an unexpected shape costs the course its picture, never the course
    /// list: Moodle versions differ, and the list is what sync depends on. Guards against a
    /// strict decoder turning a cosmetic field into "malformed payload" for every sync.
    @Test func anOddPictureFieldNeverBreaksTheList() async throws {
        let session = stubSession { _ in
            Self.json(#"[{"id":9,"shortname":"HPC","fullname":"HPC","overviewfiles":"nope","courseimage":42},{"id":10,"shortname":"ML","fullname":"ML","overviewfiles":[{"fileurl":7},{"fileurl":"\#(Self.image)","mimetype":"image/png"}]}]"#)
        }
        let courses = try await WeBeepAPIClient(session: session).fetchCourses(userID: 7, token: "token")
        #expect(courses.map(\.id) == [9, 10])
        #expect(courses.map(\.imageURL) == [nil, URL(string: Self.image)])
    }

    // MARK: Fetching the picture

    /// The picture is requested with GET at its address plus the token as `token=` (the
    /// web-service file convention), asking for an image, and its bytes are returned.
    @Test func thePictureIsFetchedWithTheToken() async throws {
        let seen = Seen()
        let session = stubSession { request in
            seen.request = request
            return Self.reply(request.url!, status: 200, contentType: "image/png", body: Data([1, 2, 3]))
        }
        let data = try await WeBeepAPIClient(session: session).fetchCourseImage(URL(string: Self.image)!, token: "s3cret")
        #expect(data == Data([1, 2, 3]))
        let request = try #require(seen.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == Self.image + "?token=s3cret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/*")
        #expect(request.timeoutInterval == WeBeepAPIClient.courseImageTimeout)
    }

    /// An address the policy refuses is never requested at all: the token must not reach
    /// another host, plain HTTP, or an address that is not in canonical web-service form.
    @Test(arguments: [
        "http://\(host)/webservice/pluginfile.php/1/a.jpg",
        "https://evil.example/webservice/pluginfile.php/1/a.jpg",
        "https://\(host)/pluginfile.php/1/a.jpg",
        "https://\(host)/webservice/pluginfile.php/1/a.jpg?token=x",
    ])
    func refusedAddressesAreNeverRequested(_ address: String) async {
        let seen = Seen()
        let session = stubSession { request in
            seen.request = request
            return Self.reply(request.url!, status: 200, contentType: "image/png", body: Data([1]))
        }
        await #expect(throws: WeBeepAPIError.unexpectedSite) {
            try await WeBeepAPIClient(session: session).fetchCourseImage(URL(string: address)!, token: "s3cret")
        }
        #expect(seen.request == nil)
    }

    /// Not a picture (a login page), an HTTP error, a redirect refused by the session, or an
    /// answer over the 2 MB cap: each is an error, never bytes. Guards against decoding an HTML
    /// login page, buffering an unbounded answer, or following a redirect elsewhere.
    @Test func badAnswersAreErrors() async {
        let url = URL(string: Self.image)!
        let html = stubSession { request in Self.reply(request.url!, status: 200, contentType: "text/html", body: Data("<html>".utf8)) }
        await #expect(throws: WeBeepAPIError.invalidResponse) { try await WeBeepAPIClient(session: html).fetchCourseImage(url, token: "t") }
        let missing = stubSession { request in Self.reply(request.url!, status: 404, contentType: "image/png", body: Data()) }
        await #expect(throws: WeBeepAPIError.transport(404)) { try await WeBeepAPIClient(session: missing).fetchCourseImage(url, token: "t") }
        let redirect = stubSession { request in Self.reply(request.url!, status: 302, contentType: "image/png", body: Data(), location: "https://evil.example/a.png") }
        await #expect(throws: WeBeepAPIError.transport(302)) { try await WeBeepAPIClient(session: redirect).fetchCourseImage(url, token: "t") }
        let huge = stubSession { request in Self.reply(request.url!, status: 200, contentType: "image/png", body: Data(count: WeBeepAPIClient.courseImageByteLimit + 1)) }
        await #expect(throws: WeBeepAPIError.responseTooLarge) { try await WeBeepAPIClient(session: huge).fetchCourseImage(url, token: "t") }
    }

    // MARK: The saved course list

    private static let rootID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let identity = CourseListSnapshot.Identity(siteID: "polimi", rootID: Self.rootID, token: "token-a")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A file written by a BeepBar from before the picture existed (no `imageURL` key) still
    /// loads, with no picture. Guards against users who skip releases losing their saved list
    /// (and seeing "Caricamento corsi…" again) after updating.
    @Test func aListSavedBeforeThePictureExistedStillLoads() throws {
        let old = #"{"courses":[{"displayName":"Course 1","id":1,"isVisible":true,"shortName":"C1"}],"identity":{"credential":"\#(identity.credential)","rootID":"\#(Self.rootID.uuidString)","siteID":"polimi"},"savedAt":1800000000,"version":1}"#
        let decoded = try CourseListSnapshotCodec.decode(Data(old.utf8), expecting: identity, now: now)
        #expect(decoded.summaries == [RemoteCourseSummary(id: 1, shortName: "C1", displayName: "Course 1", isVisible: true, startDate: nil, endDate: nil)])
        #expect(decoded.summaries.first?.imageURL == nil)
    }

    /// The picture's address round-trips, and a list without pictures is written without the
    /// key, as before (so an older BeepBar reads both, and an unchanged list is no new write).
    /// The address stored never carries the token.
    @Test func thePictureRoundTripsAndIsOmittedWhenAbsent() throws {
        let withImage = RemoteCourseSummary(id: 1, shortName: "C1", displayName: "Course 1", isVisible: true, startDate: nil, endDate: nil, imageURL: URL(string: Self.image))
        let data = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: [withImage]))
        #expect(try CourseListSnapshotCodec.decode(data, expecting: identity, now: now).summaries == [withImage])
        #expect(!String(decoding: data, as: UTF8.self).contains("token"))
        let without = RemoteCourseSummary(id: 1, shortName: "C1", displayName: "Course 1", isVisible: true, startDate: nil, endDate: nil)
        let plain = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: [without]))
        #expect(!String(decoding: plain, as: UTF8.self).contains("imageURL"))
    }

    // MARK: Helpers

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var request: URLRequest? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func stubSession(_ handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) -> URLSession {
        CourseImageStubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CourseImageStubProtocol.self]
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    private static func json(_ body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: WeBeepAPIClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
    }

    private static func reply(_ url: URL, status: Int, contentType: String, body: Data, location: String? = nil) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": contentType]
        if let location { headers["Location"] = location }
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, body)
    }
}

/// The session delegate `WeBeepAPIClient` uses, so a redirect reaches the client as the 3xx.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class CourseImageStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (response, data) = Self.handler(request)
        if (300...399).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
