import Foundation
import os
import BeepbarCore

/// A local Moodle for app tests: answers site info, the enrolled courses and empty course contents,
/// and records every request with the network restrictions it carried. Everything is keyed by the
/// request's token, so tests running in parallel never see each other's courses or requests; each
/// test registers its own token and must never use the installed app's.
final class MoodleRecordingProtocol: URLProtocol, @unchecked Sendable {
    struct RecordedRequest: Hashable, Sendable {
        let function: String
        let allowsExpensiveNetworkAccess: Bool
        let allowsConstrainedNetworkAccess: Bool
    }

    private struct Account {
        var courses: [(id: Int64, name: String)]
        var requests: [RecordedRequest] = []
    }

    private static let accounts = OSAllocatedUnfairLock(initialState: [String: Account]())

    /// A fresh token whose account lists `courses`, in this order, as its enrolled courses.
    static func register(courses: [(id: Int64, name: String)]) -> String {
        let token = UUID().uuidString
        accounts.withLock { $0[token] = Account(courses: courses) }
        return token
    }

    static func requests(token: String) -> [RecordedRequest] {
        accounts.withLock { $0[token]?.requests ?? [] }
    }

    static func makeClient() -> WeBeepAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoodleRecordingProtocol.self]
        return WeBeepAPIClient(session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fields = Self.formFields(request)
        let token = fields["wstoken"] ?? ""
        let function = fields["wsfunction"] ?? ""
        let recorded = RecordedRequest(function: function, allowsExpensiveNetworkAccess: request.allowsExpensiveNetworkAccess, allowsConstrainedNetworkAccess: request.allowsConstrainedNetworkAccess)
        let courses: [(id: Int64, name: String)]? = Self.accounts.withLock { accounts in
            accounts[token]?.requests.append(recorded)
            return accounts[token]?.courses
        }
        let json: String
        switch (courses, function) {
        case (nil, _):
            json = #"{"exception":"invalidtoken","errorcode":"invalidtoken"}"#
        case (_, "core_webservice_get_site_info"):
            json = #"{"userid":7,"siteurl":"https://webeep.polimi.it","functions":[{"name":"core_enrol_get_users_courses"},{"name":"core_course_get_contents"}]}"#
        case (let courses?, "core_enrol_get_users_courses"):
            json = "[" + courses.map { #"{"id":\#($0.id),"shortname":"\#($0.name)","fullname":"\#($0.name)","visible":1}"# }.joined(separator: ",") + "]"
        default:
            json = "[]"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
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
