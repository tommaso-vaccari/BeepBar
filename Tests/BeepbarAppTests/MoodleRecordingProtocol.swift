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
        var requests: [RecordedRequest] = []
        var onHotspot = false
    }

    /// What a download records as its `function`.
    static let downloadFunction = "download"

    private static let accounts = OSAllocatedUnfairLock(initialState: [String: Account]())

    /// A fresh token whose account lists `courses`, in this order, as its enrolled courses, and
    /// `files` (one-byte files, by course) in their contents.
    static func register(courses: [(id: Int64, name: String)], files: [Int64: [String]] = [:]) -> String {
        let token = UUID().uuidString
        accounts.withLock { $0[token] = Account(courses: courses, files: files) }
        return token
    }

    /// Puts this account's Mac on a phone hotspot: a request that may not use an expensive network
    /// fails with `URLError.notConnectedToInternet`, as macOS fails it. Requests that may use any
    /// network still go through.
    static func setOnHotspot(token: String, _ onHotspot: Bool) {
        accounts.withLock { $0[token]?.onHotspot = onHotspot }
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
        if isDownload {
            let body = Data("x".utf8)
            let found = account != nil
            let response = HTTPURLResponse(url: url, statusCode: found ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": found ? "\(body.count)" : "0"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if found { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let json: String
        switch (account, function) {
        case (nil, _):
            json = #"{"exception":"invalidtoken","errorcode":"invalidtoken"}"#
        case (_, "core_webservice_get_site_info"):
            json = #"{"userid":7,"siteurl":"https://webeep.polimi.it","functions":[{"name":"core_enrol_get_users_courses"},{"name":"core_course_get_contents"}]}"#
        case (let account?, "core_enrol_get_users_courses"):
            json = "[" + account.courses.map { #"{"id":\#($0.id),"shortname":"\#($0.name)","fullname":"\#($0.name)","visible":1}"# }.joined(separator: ",") + "]"
        case (let account?, "core_course_get_contents"):
            json = Self.contents(course: Int64(fields["courseid"] ?? "") ?? 0, files: account.files)
        default:
            json = "[]"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
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
