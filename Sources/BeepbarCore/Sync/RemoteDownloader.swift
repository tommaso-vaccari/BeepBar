#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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

public final class RemoteDownloader: @unchecked Sendable {
    /// The largest file Beepbar downloads unless a caller asks for another limit.
    public static let defaultMaximumSize: Int64 = 1_073_741_824

    private let session: URLSession
    /// The largest file this downloader accepts before opening a stage.
    public let maximumSize: Int64
    private let policy: WeBeepServerPolicy
    private let ownsSession: Bool
    private let writeStage: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    private let afterStageOpened: (@Sendable () async -> Void)?

    public init(maximumSize: Int64 = RemoteDownloader.defaultMaximumSize, maximumConnections: Int = 3, policy: WeBeepServerPolicy = .production) {
        self.maximumSize = maximumSize
        self.policy = policy
        self.writeStage = posixWrite
        self.afterStageOpened = nil
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
        self.writeStage = posixWrite
        self.afterStageOpened = nil
        self.maximumSize = maximumSize
        self.policy = policy
        ownsSession = false
    }

    /// Injects only the stage write syscall, to exercise failures without modifying real files.
    init(session: URLSession, maximumSize: Int64 = RemoteDownloader.defaultMaximumSize, policy: WeBeepServerPolicy = .production, writeStage: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int, afterStageOpened: (@Sendable () async -> Void)? = nil) {
        self.session = session
        self.maximumSize = maximumSize
        self.policy = policy
        self.writeStage = writeStage
        self.afterStageOpened = afterStageOpened
        self.ownsSession = false
    }

    deinit {
        // A session started here retains its delegate until it is invalidated, so a downloader that
        // is simply dropped would leak the session, its delegate and its connections.
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    /// Downloads `file` straight into a stage of `store` and returns it as a `StagedArtifact` (#250).
    ///
    /// The stage is opened before the request so the body goes to its final volume in one pass,
    /// hashed as it is received, with no temporary file and no second copy. Any error, including
    /// cancellation, a rejected response or a short write, discards the stage, so a failed transfer
    /// leaves nothing in staging. The errors surfaced are `RemoteDownloadError`, `FileStoreError`
    /// (stage I/O, e.g. a full disk), `CocoaError` and `CancellationError`.
    public func download(_ file: RemoteFileCandidate, token: String, access: NetworkAccess, into store: FileStore) async throws -> StagedArtifact {
        guard file.isSupported else { throw RemoteDownloadError.unsupportedFile }
        guard let url = file.downloadURL else { throw RemoteDownloadError.missingURL }
        guard file.size >= 0 else { throw RemoteDownloadError.invalidSize }
        guard file.size <= maximumSize else { throw RemoteDownloadError.tooLarge }
        var request = try Self.request(url: url, token: token, policy: policy)
        request.allowsExpensiveNetworkAccess = access.allowsExpensiveNetworkAccess
        request.allowsConstrainedNetworkAccess = access.allowsConstrainedNetworkAccess
        let requestURL = request.url!
        try Task.checkCancellation()
        let (stage, fd) = try await store.openDownloadStage()
        let transfer = CappedDownload(limit: file.size, fd: fd, writeStage: writeStage) { http in
            guard http.statusCode == 200 else { return .transport(http.statusCode) }
            guard let finalURL = http.url, Self.matchesAuthorizedURL(finalURL, requestURL: requestURL) else { return .unexpectedRedirect }
            let length = http.expectedContentLength
            if length >= 0, length != file.size { return .invalidResponse }
            return nil
        }
        do {
            let hash: String
            do {
                await afterStageOpened?()
                try Task.checkCancellation()
                hash = try await transfer.run(request, in: session)
                guard fsync(fd) == 0 else { throw FileStoreError.ioFailure }
            } catch {
                close(fd)
                throw error
            }
            guard close(fd) == 0 else { throw FileStoreError.ioFailure }
            try Task.checkCancellation()
            let artifact = try await store.downloadedArtifact(stage, sha256: hash, size: file.size)
            try Task.checkCancellation()
            return artifact
        } catch {
            try? await store.discard(stage)
            if let error = error as? RemoteDownloadError { throw error }
            if let error = error as? FileStoreError { throw error }
            if let error = error as? CocoaError { throw error }
            if let error = error as? URLError {
                if error.code == .cancelled { throw CancellationError() }
                if error.code == .badServerResponse { throw RemoteDownloadError.unexpectedRedirect }
                throw RemoteDownloadError.network(NetworkFailure(error.code))
            }
            if error is CancellationError { throw CancellationError() }
            throw RemoteDownloadError.invalidResponse
        }
    }

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

/// Holds the completion under the download delegate's lock.
struct DownloadCompletion {
    private var receiver: (@Sendable (Result<String, Error>) -> Void)?
    private var parked: Result<String, Error>?
    private var finished = false

    mutating func register(_ receiver: @escaping @Sendable (Result<String, Error>) -> Void) -> Result<String, Error>? {
        if let parked { self.parked = nil; return parked }
        self.receiver = receiver
        return nil
    }

    mutating func finish(_ result: Result<String, Error>) -> (@Sendable (Result<String, Error>) -> Void)? {
        guard !finished else { return nil }
        finished = true
        guard let receiver else { parked = result; return nil }
        self.receiver = nil
        return receiver
    }
}

/// Receives one bounded response into its already-open stage descriptor, hashing the bytes it
/// writes. The response is validated before any byte is written and the body is cut off as soon
/// as it would pass the size Moodle reported. A write that stores fewer bytes than it was given
/// fails the transfer (`FileStoreError.ioFailure`): the digest must describe exactly what reached
/// the file, so a partial write can never be hashed as if complete. Delegate callbacks serialize
/// under the lock; writes and hashing need no hop to the FileStore actor.
private final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let fd: Int32
    private let limit: Int64
    private let writeStage: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    private let validate: @Sendable (HTTPURLResponse) -> RemoteDownloadError?
    private let lock = NSLock()
    private var receivedResponse = false
    private var written: Int64 = 0
    private var hasher = SHA256()
    private var rejection: Error?
    private var completion = DownloadCompletion()

    init(limit: Int64, fd: Int32, writeStage: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int, validate: @escaping @Sendable (HTTPURLResponse) -> RemoteDownloadError?) {
        self.limit = limit
        self.fd = fd
        self.writeStage = writeStage
        self.validate = validate
    }

    func run(_ request: URLRequest, in session: URLSession) async throws -> String {
        let task = session.dataTask(with: request)
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let parked = lock.withLock {
                    completion.register { continuation.resume(with: $0) }
                }
                if let parked { continuation.resume(with: parked) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let failure: RemoteDownloadError?
        if let http = response as? HTTPURLResponse { failure = validate(http) }
        else { failure = .invalidResponse }
        lock.withLock {
            receivedResponse = true
            if let failure { rejection = failure }
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop = lock.withLock { () -> Bool in
            guard rejection == nil, receivedResponse else { return true }
            guard Int64(data.count) <= limit - written else {
                rejection = RemoteDownloadError.invalidResponse
                return true
            }
            let result = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                var count: Int
                repeat { count = writeStage(fd, base, bytes.count) } while count < 0 && errno == EINTR
                return count
            }
            // A partial write is a failed transfer; the digest must describe exactly what was saved.
            guard result == data.count else { rejection = FileStoreError.ioFailure; return true }
            hasher.update(data: data)
            written += Int64(result)
            return false
        }
        if stop { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (receiver, result) = lock.withLock { () -> ((@Sendable (Result<String, Error>) -> Void)?, Result<String, Error>) in
            let outcome = rejection ?? error ?? (receivedResponse && written == limit ? nil : RemoteDownloadError.invalidResponse)
            let result: Result<String, Error> = outcome.map { .failure($0) } ?? .success(hexSHA256(hasher.finalize()))
            return (completion.finish(result), result)
        }
        receiver?(result)
    }
}

private final class DownloadRejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
