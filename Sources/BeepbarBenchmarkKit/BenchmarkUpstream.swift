import BeepbarCore
import Foundation
import os

/// The shape of a synthetic Moodle account. Never real WeBeep data: names, sizes and bytes are
/// generated, and the same spec always produces the same corpus.
package struct CorpusSpec: Sendable, Codable, Equatable {
    package var courses: Int
    package var filesPerCourse: Int
    /// Each module is a folder in its own section; files are spread over them round-robin.
    package var modulesPerCourse: Int
    /// Bytes per ordinary file. Small by default: a run with nothing new never reads file contents,
    /// and the first sync of 15,000 files stays quick to set up.
    package var fileSize: Int64

    package init(courses: Int, filesPerCourse: Int, modulesPerCourse: Int = 5, fileSize: Int64 = 4_096) {
        precondition(courses > 0 && filesPerCourse >= 0 && modulesPerCourse > 0 && fileSize >= 0)
        self.courses = courses
        self.filesPerCourse = filesPerCourse
        self.modulesPerCourse = modulesPerCourse
        self.fileSize = fileSize
    }

    /// About `totalFiles` files over `courses` courses (rounded up to a whole number per course).
    package init(totalFiles: Int, courses: Int, modulesPerCourse: Int = 5, fileSize: Int64 = 4_096) {
        self.init(courses: courses, filesPerCourse: (totalFiles + courses - 1) / courses, modulesPerCourse: modulesPerCourse, fileSize: fileSize)
    }

    package var totalFiles: Int { courses * filesPerCourse }
}

/// Requests and bytes the mock Moodle served. The categories are the three web-service functions
/// BeepBar calls plus file downloads; anything else lands in `otherRequests`, which a correct run
/// keeps at zero.
package struct UpstreamCounters: Sendable, Codable, Equatable {
    package var siteInfoRequests = 0
    package var courseListRequests = 0
    package var contentsRequests = 0
    /// Downloads started, whether or not they finished.
    package var downloads = 0
    package var otherRequests = 0
    /// Body bytes of the web-service answers.
    package var metadataBytes: Int64 = 0
    /// Body bytes of file downloads actually handed to the client (a cancelled download counts what
    /// was sent before it stopped).
    package var downloadBytes: Int64 = 0

    package init() {}

    package var requests: Int { siteInfoRequests + courseListRequests + contentsRequests + downloads + otherRequests }

    package func since(_ earlier: UpstreamCounters) -> UpstreamCounters {
        var delta = UpstreamCounters()
        delta.siteInfoRequests = siteInfoRequests - earlier.siteInfoRequests
        delta.courseListRequests = courseListRequests - earlier.courseListRequests
        delta.contentsRequests = contentsRequests - earlier.contentsRequests
        delta.downloads = downloads - earlier.downloads
        delta.otherRequests = otherRequests - earlier.otherRequests
        delta.metadataBytes = metadataBytes - earlier.metadataBytes
        delta.downloadBytes = downloadBytes - earlier.downloadBytes
        return delta
    }
}

/// One file of the synthetic Moodle, addressed the way BeepBar identifies it: course, module, name.
package struct SyntheticFileKey: Hashable, Sendable, Codable {
    package let course: Int64
    package let module: Int64
    package let name: String

    package init(course: Int64, module: Int64, name: String) {
        self.course = course
        self.module = module
        self.name = name
    }
}

/// A Moodle web service and file server that lives in the process, behind a `URLProtocol`.
///
/// Each instance answers on its own host (`<uuid>.bench.beepbar.test`), so parallel tests and
/// benchmarks never share counters or files. It serves exactly what `WeBeepAPIClient` and
/// `RemoteDownloader` ask for: `core_webservice_get_site_info`, `core_enrol_get_users_courses`,
/// `core_course_get_contents` and `pluginfile.php` downloads.
///
/// Its own work stays out of the measurements as far as possible: course listings are rendered
/// once per change and cached, file bytes are copied from a small pre-generated block
/// (`SyntheticContent`), and delivered chunks don't stay resident (see `startLoading`). What remains on the client side (URL loading, JSON parsing, hashing,
/// writing) is the app's real work. Downloads stream in chunks, optionally throttled, so a large
/// file never sits in memory here and a cancel can land midway.
package final class BenchmarkUpstream: @unchecked Sendable {
    package static let userID = 7

    /// How far a download may run ahead of the client, in bytes: the order of a TCP receive
    /// window on a fast link. Large enough not to slow the transfer, small enough that no backlog
    /// shows up in the memory numbers (see `BenchmarkURLProtocol.startLoading`).
    package static let downloadWindow: Int64 = 2 << 20

    package let host: String
    package let policy: WeBeepServerPolicy
    /// The session to give `WeBeepAPIClient` and `RemoteDownloader`: it routes this host to the mock.
    package let session: URLSession

    private struct FileEntry {
        var size: Int64
        var revision: Int
    }

    private struct State {
        var courseIDs: [Int64] = []
        var files: [SyntheticFileKey: FileEntry] = [:]
        var renderedContents: [Int64: Data] = [:]
        var counters = UpstreamCounters()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let settings = OSAllocatedUnfairLock(initialState: DownloadSettings())

    private struct DownloadSettings {
        var chunkSize = 256 * 1024
        var bytesPerSecond: Int64?
        var progress: (@Sendable (SyntheticFileKey, Int64, Int64) -> Void)?
    }

    package init() {
        host = "\(UUID().uuidString.lowercased()).bench.beepbar.test"
        policy = WeBeepServerPolicy(
            endpoint: URL(string: "https://\(host)/webservice/rest/server.php")!,
            siteURL: URL(string: "https://\(host)")!,
            scheme: "https", host: host, port: 443
        )
        // As close as the mock allows to the app's own sessions: ephemeral, no cache, the
        // downloader's three connections per host.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BenchmarkURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: configuration)
        BenchmarkURLProtocol.register(self)
    }

    deinit {
        session.invalidateAndCancel()
        BenchmarkURLProtocol.unregister(host: host)
    }

    // MARK: Corpus

    /// Adds every course and file of `spec`; file names are unique within a module.
    package func populate(_ spec: CorpusSpec) {
        state.withLock { state in
            for course in 1...Int64(spec.courses) {
                if !state.courseIDs.contains(course) { state.courseIDs.append(course) }
                for index in 0..<spec.filesPerCourse {
                    let module = Self.moduleID(course: course, ordinal: Int64(index % spec.modulesPerCourse))
                    let key = SyntheticFileKey(course: course, module: module, name: String(format: "lezione-%05d.pdf", index))
                    state.files[key] = FileEntry(size: spec.fileSize, revision: 1)
                }
                state.renderedContents[course] = nil
            }
        }
    }

    /// Adds one file, e.g. a large recording, and returns its key.
    @discardableResult
    package func addFile(course: Int64, moduleOrdinal: Int64 = 0, name: String, size: Int64) -> SyntheticFileKey {
        let key = SyntheticFileKey(course: course, module: Self.moduleID(course: course, ordinal: moduleOrdinal), name: name)
        state.withLock { state in
            if !state.courseIDs.contains(course) { state.courseIDs.append(course) }
            state.files[key] = FileEntry(size: size, revision: 1)
            state.renderedContents[course] = nil
        }
        return key
    }

    /// Replaces the file with a new revision, as a teacher uploading a new version does: new
    /// bytes, new `contenthash`, new `timemodified`. Returns the new revision.
    @discardableResult
    package func updateFile(_ key: SyntheticFileKey) -> Int {
        state.withLock { state in
            guard var entry = state.files[key] else { preconditionFailure("unknown file \(key)") }
            entry.revision += 1
            state.files[key] = entry
            state.renderedContents[key.course] = nil
            return entry.revision
        }
    }

    package func revision(of key: SyntheticFileKey) -> Int? { state.withLock { $0.files[key]?.revision } }

    /// The bytes of `key` at `revision` (the current one by default).
    package func content(of key: SyntheticFileKey, revision: Int? = nil) -> SyntheticContent {
        let entry = state.withLock { $0.files[key] }!
        return SyntheticContent(seed: Self.seed(key, revision: revision ?? entry.revision), size: entry.size)
    }

    package var courseIDs: [Int64] { state.withLock { $0.courseIDs.sorted() } }

    /// Where the app installs `key` under the sync root, given the course's local folder: the
    /// module's section and name, as `LocalPathPolicy` lays them out.
    package static func moduleID(course: Int64, ordinal: Int64) -> Int64 { course * 1_000 + ordinal + 1 }

    // MARK: Downloads

    /// Bytes per chunk handed to the client, and an optional throughput cap. A cap makes a large
    /// download last long enough for a cancel to land midway, like a real network.
    package func configureDownloads(chunkSize: Int = 256 * 1024, bytesPerSecond: Int64? = nil) {
        precondition(chunkSize > 0)
        settings.withLock { $0.chunkSize = chunkSize; $0.bytesPerSecond = bytesPerSecond }
    }

    /// Called on the server's thread after each chunk with the bytes sent so far and the file size.
    package func onDownloadProgress(_ observer: (@Sendable (SyntheticFileKey, Int64, Int64) -> Void)?) {
        settings.withLock { $0.progress = observer }
    }

    package var counters: UpstreamCounters { state.withLock { $0.counters } }

    // MARK: Serving (used by BenchmarkURLProtocol)

    enum Reply {
        case data(status: Int, contentType: String, body: Data)
        case stream(key: SyntheticFileKey, content: SyntheticContent)
    }

    var downloadSettings: (chunkSize: Int, bytesPerSecond: Int64?, progress: (@Sendable (SyntheticFileKey, Int64, Int64) -> Void)?) {
        settings.withLock { ($0.chunkSize, $0.bytesPerSecond, $0.progress) }
    }

    func recordDownloadBytes(_ count: Int) {
        state.withLock { $0.counters.downloadBytes += Int64(count) }
    }

    func reply(to request: URLRequest) -> Reply {
        guard let url = request.url else { return notFound() }
        if request.httpMethod == "POST", url.path == "/webservice/rest/server.php" {
            let body = String(data: request.httpBody ?? Self.read(request.httpBodyStream), encoding: .utf8) ?? ""
            let fields = Self.form(body)
            guard fields["wstoken"] == BenchmarkFixture.token else {
                return json(Data(#"{"exception":"moodle_exception","errorcode":"invalidtoken","message":"Invalid token"}"#.utf8))
            }
            switch fields["wsfunction"] {
            case "core_webservice_get_site_info":
                state.withLock { $0.counters.siteInfoRequests += 1 }
                let functions = #"[{"name":"core_enrol_get_users_courses"},{"name":"core_course_get_contents"}]"#
                return json(Data(#"{"userid":\#(Self.userID),"siteurl":"https://\#(host)","functions":\#(functions)}"#.utf8))
            case "core_enrol_get_users_courses":
                let courses = state.withLock { state -> [Int64] in state.counters.courseListRequests += 1; return state.courseIDs.sorted() }
                let list = courses.map { ["id": $0, "shortname": "BENCH\($0)", "fullname": "Corso di prova \($0)", "displayname": "Corso di prova \($0)", "visible": 1] as [String: Any] }
                return json(try! JSONSerialization.data(withJSONObject: list))
            case "core_course_get_contents":
                guard let course = fields["courseid"].flatMap(Int64.init) else { return notFound() }
                state.withLock { $0.counters.contentsRequests += 1 }
                return json(renderedContents(course: course))
            default:
                return notFound()
            }
        }
        // /webservice/pluginfile.php/<course>/mod_folder/content/<module>/<name>
        let parts = url.path.split(separator: "/").map(String.init)
        guard request.httpMethod == "GET", parts.count == 7, parts[0] == "webservice", parts[1] == "pluginfile.php",
              let course = Int64(parts[2]), let module = Int64(parts[5]) else { return notFound() }
        let key = SyntheticFileKey(course: course, module: module, name: parts[6])
        let entry: FileEntry? = state.withLock { state in
            guard let entry = state.files[key] else { return nil }
            state.counters.downloads += 1
            return entry
        }
        guard let entry else { return notFound() }
        return .stream(key: key, content: SyntheticContent(seed: Self.seed(key, revision: entry.revision), size: entry.size))
    }

    private func json(_ body: Data) -> Reply {
        state.withLock { $0.counters.metadataBytes += Int64(body.count) }
        return .data(status: 200, contentType: "application/json", body: body)
    }

    private func notFound() -> Reply {
        state.withLock { $0.counters.otherRequests += 1 }
        return .data(status: 404, contentType: "text/plain", body: Data())
    }

    /// The course's `core_course_get_contents` answer, rendered once per change to the course.
    private func renderedContents(course: Int64) -> Data {
        if let cached = state.withLock({ $0.renderedContents[course] }) { return cached }
        let (files, known) = state.withLock { state in (state.files.filter { $0.key.course == course }, state.courseIDs.contains(course)) }
        guard known else { return Data(#"{"exception":"moodle_exception","errorcode":"invalidrecord","message":"Unknown course"}"#.utf8) }
        let byModule = Dictionary(grouping: files, by: { $0.key.module })
        let sections: [[String: Any]] = byModule.keys.sorted().map { module in
            let ordinal = module - course * 1_000
            let entries: [[String: Any]] = byModule[module]!.sorted { $0.key.name < $1.key.name }.map { key, entry in
                [
                    "type": "file",
                    "filename": key.name,
                    "filepath": "/",
                    "filesize": entry.size,
                    "timemodified": 1_700_000_000 + entry.revision,
                    "contenthash": Self.contentHash(key, revision: entry.revision),
                    "fileurl": "https://\(host)/webservice/pluginfile.php/\(course)/mod_folder/content/\(module)/\(key.name)",
                ]
            }
            return [
                "id": module,
                "name": "Settimana \(ordinal)",
                "modules": [["id": module, "name": "Materiali \(ordinal)", "modname": "folder", "contents": entries]],
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: sections)
        state.withLock { $0.renderedContents[course] = data }
        return data
    }

    private static func seed(_ key: SyntheticFileKey, revision: Int) -> UInt64 {
        SyntheticContent.mix(SyntheticContent.stableHash("\(key.course)/\(key.module)/\(key.name)") ^ SyntheticContent.mix(UInt64(revision)))
    }

    /// A 40-hex `contenthash`, as Moodle sends (SHA-1 sized), that changes with every revision.
    private static func contentHash(_ key: SyntheticFileKey, revision: Int) -> String {
        let seed = seed(key, revision: revision)
        return String(format: "%016llx%016llx%08x", SyntheticContent.mix(seed), SyntheticContent.mix(seed &+ 1), UInt32(truncatingIfNeeded: SyntheticContent.mix(seed &+ 2)))
    }

    private static func form(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

/// Routes requests for a registered `BenchmarkUpstream` host to it. Registered per session (never
/// globally with `URLProtocol.registerClass`), so nothing else in the process is intercepted.
final class BenchmarkURLProtocol: URLProtocol, @unchecked Sendable {
    private struct WeakUpstream { weak var value: BenchmarkUpstream? }
    private static let registry = OSAllocatedUnfairLock(initialState: [String: WeakUpstream]())

    static func register(_ upstream: BenchmarkUpstream) {
        registry.withLock { $0[upstream.host] = WeakUpstream(value: upstream) }
    }

    static func unregister(host: String) {
        registry.withLock { _ = $0.removeValue(forKey: host) }
    }

    private static func upstream(for request: URLRequest) -> BenchmarkUpstream? {
        guard let host = request.url?.host?.lowercased() else { return nil }
        return registry.withLock { $0[host]?.value }
    }

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    /// Claims every request of the sessions it is installed on, known host or not: declining one
    /// would hand it to the real HTTP stack (and a DNS lookup), breaking "no real network". An
    /// unknown host fails in `startLoading` with `.resourceUnavailable`, an error the real stack
    /// wouldn't give for an unresolvable host, so a test can tell the two apart.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let upstream = Self.upstream(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch upstream.reply(to: request) {
        case .data(let status, let contentType, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType, "Content-Length": "\(body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .stream(let key, let content):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream", "Content-Length": "\(content.size)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let settings = upstream.downloadSettings
            // GCD, not a Swift task: the throttle sleeps, and a sleeping cooperative thread would
            // starve the app code being measured.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let clock = ContinuousClock()
                let start = clock.now
                var sent: Int64 = 0
                while sent < content.size {
                    // Flow control, as TCP gives a real download: never more than `window` bytes
                    // ahead of what the client has taken in. Without it an unthrottled mock runs
                    // hundreds of MiB ahead of a busy client, the URL loading system queues all of
                    // it, and `memory.peak` measures that queue instead of the app (measured:
                    // a 256 MiB stream grew the footprint by ~700 MiB when other work competed).
                    // Guarded by `streamingThroughTheMockKeepsMemoryFlat`.
                    while let task, sent - task.countOfBytesReceived > BenchmarkUpstream.downloadWindow {
                        if stopped.withLock({ $0 }) { return }
                        Thread.sleep(forTimeInterval: 0.0002)
                    }
                    if stopped.withLock({ $0 }) { return }
                    let chunk = content.bytes(at: sent, count: settings.chunkSize)
                    client?.urlProtocol(self, didLoad: chunk)
                    sent += Int64(chunk.count)
                    upstream.recordDownloadBytes(chunk.count)
                    settings.progress?(key, sent, content.size)
                    if let rate = settings.bytesPerSecond, rate > 0 {
                        let due = start + .nanoseconds(Int64(Double(sent) / Double(rate) * 1_000_000_000))
                        let wait = due - clock.now
                        if wait > .zero { Thread.sleep(forTimeInterval: Double(wait.components.attoseconds) / 1e18 + Double(wait.components.seconds)) }
                    }
                }
                if stopped.withLock({ $0 }) { return }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}
