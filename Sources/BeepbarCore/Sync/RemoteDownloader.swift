import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RemoteDownloadError: Error, Sendable, Equatable {
    case unsupportedFile
    case missingURL
    case invalidSize
    case unsafeURL
    case unexpectedRedirect
    case transport(Int)
    case network(NetworkFailure)
    case invalidResponse
    case tooLarge
}

/// Which networks a download may use. Set per request, not per session, so one shared downloader
/// can still hold a scheduled run to the same limits its own session used to impose.
public struct NetworkAccess: Sendable, Equatable {
    public let allowsExpensiveNetworkAccess: Bool
    public let allowsConstrainedNetworkAccess: Bool

    public init(allowsExpensiveNetworkAccess: Bool, allowsConstrainedNetworkAccess: Bool) {
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
    }

    /// Any network will do: every manual run, and automatic runs while "Risparmio dati" is off.
    public static let unrestricted = NetworkAccess(allowsExpensiveNetworkAccess: true, allowsConstrainedNetworkAccess: true)
    /// An automatic run with "Risparmio dati" on: no phone hotspot, no Low Data Mode network. The
    /// app already pauses such a run before it starts (`AutomaticSyncPolicy`); this catches a
    /// network change midway, where macOS refuses the request as if the Mac were offline
    /// (`URLError.notConnectedToInternet`) and the app shows the pause instead of an outage.
    public static let dataSaver = NetworkAccess(allowsExpensiveNetworkAccess: false, allowsConstrainedNetworkAccess: false)
}

public struct DownloadedRemoteFile: Sendable {
    public let temporaryURL: URL
    public let expectedSize: Int64
}

public final class RemoteDownloader: @unchecked Sendable {
    /// The largest file Beepbar downloads unless a caller asks for another limit.
    public static let defaultMaximumSize: Int64 = 1_073_741_824

    private let session: URLSession
    /// The largest file this downloader accepts. The import that copies a download into the
    /// sync root reads it from here, so the two checks can never disagree.
    public let maximumSize: Int64
    private let policy: WeBeepServerPolicy
    private let ownsSession: Bool

    public init(maximumSize: Int64 = RemoteDownloader.defaultMaximumSize, maximumConnections: Int = 3, policy: WeBeepServerPolicy = .production) {
        self.maximumSize = maximumSize
        self.policy = policy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = maximumConnections
        session = URLSession(configuration: configuration, delegate: DownloadRejectRedirects(), delegateQueue: nil)
        ownsSession = true
    }

    public init(session: URLSession, maximumSize: Int64 = RemoteDownloader.defaultMaximumSize, policy: WeBeepServerPolicy = .production) {
        self.session = session
        self.maximumSize = maximumSize
        self.policy = policy
        ownsSession = false
    }

    deinit {
        // A session started here retains its delegate until it is invalidated, so a downloader that
        // is simply dropped would leak the session, its delegate and its connections.
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    public func download(_ file: RemoteFileCandidate, token: String, access: NetworkAccess) async throws -> DownloadedRemoteFile {
        guard file.isSupported else { throw RemoteDownloadError.unsupportedFile }
        guard let url = file.downloadURL else { throw RemoteDownloadError.missingURL }
        guard file.size >= 0 else { throw RemoteDownloadError.invalidSize }
        guard file.size <= maximumSize else { throw RemoteDownloadError.tooLarge }
        var request = try Self.request(url: url, token: token, policy: policy)
        request.allowsExpensiveNetworkAccess = access.allowsExpensiveNetworkAccess
        request.allowsConstrainedNetworkAccess = access.allowsConstrainedNetworkAccess
        let requestURL = request.url!
        let transfer = CappedDownload(
            limit: file.size,
            destination: FileManager.default.temporaryDirectory.appending(path: "\(Self.temporaryFilePrefix)\(UUID().uuidString)")
        ) { http in
            guard http.statusCode == 200 else { return .transport(http.statusCode) }
            guard let finalURL = http.url, Self.matchesAuthorizedURL(finalURL, requestURL: requestURL) else { return .unexpectedRedirect }
            let length = http.expectedContentLength
            if length >= 0, length != file.size { return .invalidResponse }
            return nil
        }
        do { try await transfer.run(request, in: session) }
        catch let error as RemoteDownloadError { throw error }
        catch let error as CocoaError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .badServerResponse { throw RemoteDownloadError.unexpectedRedirect }
        catch let error as URLError { throw RemoteDownloadError.network(NetworkFailure(error.code)) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RemoteDownloadError.invalidResponse }
        return DownloadedRemoteFile(temporaryURL: transfer.destination, expectedSize: file.size)
    }

    /// Names every body this downloader writes, so a leak is recognisable in the temporary directory.
    static let temporaryFilePrefix = "Beepbar-download-"

    public static func request(url: URL, token: String) throws -> URLRequest {
        try request(url: url, token: token, policy: .production)
    }

    public static func request(url: URL, token: String, policy: WeBeepServerPolicy) throws -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), policy.acceptsPluginURL(url) else {
            throw RemoteDownloadError.unsafeURL
        }
        guard !(components.queryItems ?? []).contains(where: { $0.name.caseInsensitiveCompare("token") == .orderedSame || $0.name.caseInsensitiveCompare("wstoken") == .orderedSame }) else {
            throw RemoteDownloadError.unsafeURL
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        guard let requestURL = components.url else { throw RemoteDownloadError.unsafeURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }

    private static func matchesAuthorizedURL(_ finalURL: URL, requestURL: URL) -> Bool {
        guard let final = URLComponents(url: finalURL, resolvingAgainstBaseURL: false), let request = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else { return false }
        return final.scheme == request.scheme && final.host?.lowercased() == request.host?.lowercased() && final.port == request.port && final.percentEncodedPath == request.percentEncodedPath && final.percentEncodedQuery == request.percentEncodedQuery
    }
}

/// One download written by Beepbar itself, so the response is checked before any byte lands
/// on disk and the body is cut off the moment it grows past the size Moodle reported.
///
/// A download task only reports the response once the whole body is on disk, and a response
/// without a Content-Length skipped that check entirely: a file replaced by a much larger one
/// between listing and download, or a misbehaving server, filled the temporary directory
/// before being rejected (ultrareview finding). Cancelling a download task instead leaves its
/// partial file behind, in a place only CFNetwork knows. Here the file is ours: every failure
/// removes it, and the import refuses any size but the reported one, so nothing valid is lost.
///
/// The delegate is per task, so an injected session needs no delegate of its own; methods not
/// implemented here, such as the redirect refusal, still go to the session's delegate.
private final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let destination: URL
    private let limit: Int64
    private let validate: @Sendable (HTTPURLResponse) -> RemoteDownloadError?
    private let lock = NSLock()
    private var handle: FileHandle?
    private var receivedResponse = false
    private var written: Int64 = 0
    private var rejection: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(limit: Int64, destination: URL, validate: @escaping @Sendable (HTTPURLResponse) -> RemoteDownloadError?) {
        self.limit = limit
        self.destination = destination
        self.validate = validate
    }

    /// Returns once the body is complete at `destination`; on any error the file is gone.
    func run(_ request: URLRequest, in session: URLSession) async throws {
        let task = session.dataTask(with: request)
        task.delegate = self
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock { self.continuation = continuation }
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let failure: Error?
        if let http = response as? HTTPURLResponse {
            if let rejected = validate(http) {
                failure = rejected
            } else {
                do {
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    let handle = try FileHandle(forWritingTo: destination)
                    lock.withLock { self.handle = handle }
                    failure = nil
                } catch {
                    failure = error
                }
            }
        } else {
            failure = RemoteDownloadError.invalidResponse
        }
        lock.withLock {
            receivedResponse = true
            if let failure { rejection = failure }
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop = lock.withLock { () -> Bool in
            guard rejection == nil, let handle else { return true }
            written += Int64(data.count)
            guard written <= limit else {
                rejection = RemoteDownloadError.invalidResponse
                return true
            }
            do { try handle.write(contentsOf: data) } catch { rejection = error; return true }
            return false
        }
        if stop { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            try? handle?.close()
            handle = nil
            let pending = self.continuation
            self.continuation = nil
            // The session's own error only when nothing here stopped the task first: the
            // cancellation that follows a rejection must not read as the user cancelling.
            let outcome = rejection ?? error ?? (receivedResponse ? nil : RemoteDownloadError.invalidResponse)
            return (pending, outcome)
        }
        if let outcome { continuation?.resume(throwing: outcome) } else { continuation?.resume() }
    }
}

private final class DownloadRejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
