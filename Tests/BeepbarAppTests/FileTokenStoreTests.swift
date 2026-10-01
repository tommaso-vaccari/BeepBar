import Foundation
import XCTest
import Testing
import os
@testable import BeepbarApp
import BeepbarCore

/// Exercises the real file system, but pointed at a unique, throwaway subdirectory of
/// Application Support so a test run can never read or clobber the developer's own stored
/// WeBeep token.
final class FileTokenStoreTests: XCTestCase {
    private let originalDirectoryName = FileTokenStore.directoryName
    private var testDirectoryName = ""

    override func setUp() {
        super.setUp()
        testDirectoryName = "BeepbarTests-\(UUID().uuidString)"
        FileTokenStore.directoryName = testDirectoryName
    }

    override func tearDown() {
        try? FileTokenStore.delete()
        if let directory = try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(testDirectoryName, isDirectory: true) {
            try? FileManager.default.removeItem(at: directory)
        }
        FileTokenStore.directoryName = originalDirectoryName
        super.tearDown()
    }

    /// The token store's default folder is the frozen Application Support folder (#56), the same
    /// one the sync database uses. `originalDirectoryName` is captured before `setUp` redirects the
    /// store, so it is the value real installs use. Guards against `directoryName` being given
    /// its own literal, e.g. the new `BeepBar` spelling, which would sign every install out on a
    /// case-sensitive volume while still passing on the default case-insensitive one.
    func testDefaultDirectoryIsTheFrozenApplicationSupportFolder() {
        XCTAssertEqual(originalDirectoryName, FileTokenStore.applicationSupportDirectoryName)
        XCTAssertEqual(originalDirectoryName, "Beepbar")
    }

    func testContainsCredentialIsFalseBeforeAnySave() throws {
        XCTAssertFalse(try FileTokenStore.containsCredential())
    }

    func testSaveThenLoadRoundTrips() throws {
        try FileTokenStore.save("a-token")

        XCTAssertTrue(try FileTokenStore.containsCredential())
        XCTAssertEqual(try FileTokenStore.load(.interactive), "a-token")
        XCTAssertEqual(try FileTokenStore.load(.nonInteractive), "a-token")
    }

    func testSaveOverwritesPreviousToken() throws {
        try FileTokenStore.save("first")
        try FileTokenStore.save("second")

        XCTAssertEqual(try FileTokenStore.load(.interactive), "second")
    }

    func testLoadWithoutSaveThrowsAbsent() {
        XCTAssertThrowsError(try FileTokenStore.load(.interactive)) { error in
            XCTAssertEqual(error as? CredentialStorageError, .absent)
        }
    }

    func testDeleteRemovesStoredCredential() throws {
        try FileTokenStore.save("a-token")
        try FileTokenStore.delete()

        XCTAssertFalse(try FileTokenStore.containsCredential())
        XCTAssertThrowsError(try FileTokenStore.load(.interactive))
    }

    func testDeleteRemovesOrphanedCredentialTempFile() throws {
        try FileTokenStore.save("a-token")
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(testDirectoryName, isDirectory: true)
        let tempURL = directory.appendingPathComponent(".credential-\(UUID().uuidString).tmp")
        try Data("a-token".utf8).write(to: tempURL)

        try FileTokenStore.delete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertFalse(try FileTokenStore.containsCredential())
    }

    func testDeleteReportsFailureAndKeepsStoredCredential() throws {
        try FileTokenStore.save("a-token")

        XCTAssertThrowsError(try FileTokenStore.delete(removeFile: { _ in throw CocoaError(.fileWriteNoPermission) }))

        XCTAssertEqual(try FileTokenStore.load(.interactive), "a-token")
    }

    func testSignOutFailureKeepsAccountConnected() async throws {
        try FileTokenStore.save("a-token")

        await MainActor.run {
            let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory)
            controller.signOut(removeFile: { _ in throw CocoaError(.fileWriteNoPermission) })

            XCTAssertTrue(controller.hasStoredCredential)
            XCTAssertEqual(controller.accountState, .connected)
            if case .failed(.local) = controller.syncState {} else { XCTFail("Sign-out failure should be visible") }
        }
        XCTAssertEqual(try FileTokenStore.load(.interactive), "a-token")
    }

    func testSavedFileHasOwnerOnlyPermissions() throws {
        try FileTokenStore.save("a-token")
        XCTAssertEqual(try filePermissions(), 0o600)
    }

    func testOverwrittenFileKeepsOwnerOnlyPermissions() throws {
        try FileTokenStore.save("first")
        try FileTokenStore.save("second")
        XCTAssertEqual(try filePermissions(), 0o600)
    }

    func testDirectoryIsCreatedWithOwnerOnlyPermissions() throws {
        try FileTokenStore.save("a-token")
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(testDirectoryName, isDirectory: true)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

        XCTAssertEqual(permissions, 0o700)
    }

    func testDirectoryPermissionsAreReassertedEvenIfCreatedByAnotherComponentFirst() throws {
        // Mirrors what actually happens at boot: BootstrapService creates the shared "Beepbar"
        // Application Support directory (for the sync database) with default permissions before
        // FileTokenStore ever touches it.
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(testDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try FileTokenStore.save("a-token")

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o700)
    }

    func testEmptyFileContentsAreNotReportedAsAStoredCredential() throws {
        let fileURL = try makeFile(contents: Data())
        _ = fileURL

        XCTAssertFalse(try FileTokenStore.containsCredential())
        XCTAssertThrowsError(try FileTokenStore.load(.interactive)) { error in
            XCTAssertEqual(error as? CredentialStorageError, .corrupt)
        }
    }

    private func filePermissions() throws -> Int? {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(testDirectoryName, isDirectory: true)
        let fileURL = directory.appendingPathComponent("credential.token")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    @discardableResult
    private func makeFile(contents: Data) throws -> URL {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(testDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("credential.token")
        FileManager.default.createFile(atPath: fileURL.path, contents: contents)
        return fileURL
    }
}

/// Real callback decoding and API validation use a local URLProtocol and an in-memory vault.
/// These failures must never read or write the installed application's token.
struct LoginFeedbackTests {
    @Test(arguments: ["invalid", "network", "save"]) @MainActor
    func rejectedLoginShowsReasonAndRetryClearsIt(_ mode: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoginFeedbackProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let storage = LoginTokenMemory()
        let vault = CredentialVault(read: { _ in throw CredentialStorageError.absent }, write: { token in
            if token == "save" { throw CredentialStorageError.write }
            storage.record(token)
        })
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory, apiClient: WeBeepAPIClient(session: session), credentialVault: vault)
        controller.setDisconnectedForTesting()
        await controller.completeLoginForTesting(callback(mode))
        let feedback = try #require(controller.authenticationFeedback)
        #expect(feedback.english.contains(mode == "invalid" ? "isn't valid" : "wasn't saved"))
        #expect(!feedback.italian.isEmpty)
        #expect(!controller.hasStoredCredential)
        #expect(!controller.isAuthenticating)
        #expect(storage.saved == nil)
        await controller.completeLoginForTesting(callback("good"))
        #expect(controller.authenticationFeedback == nil)
        #expect(controller.hasStoredCredential)
        #expect(storage.saved == "good")
        #expect(!controller.isAuthenticating)
    }

    @Test @MainActor func disconnectClearsAuthenticationFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoginFeedbackProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let vault = CredentialVault(read: { _ in "previous" }, write: { _ in })
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory, apiClient: WeBeepAPIClient(session: session), credentialVault: vault)
        // A rejected replacement token leaves the existing account connected.
        await controller.completeLoginForTesting(callback("invalid"))
        #expect(controller.authenticationFeedback != nil)
        #expect(controller.hasStoredCredential)
        controller.setDisconnectedForTesting()
        #expect(controller.authenticationFeedback == nil)
    }

    @Test(arguments: ["validation", "storage"]) @MainActor
    func siteSelectionWaitsForAuthenticationToFinish(_ phase: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoginFeedbackProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let gate = LoginSuspension()
        let token = UUID().uuidString
        if phase == "validation" { LoginFeedbackProtocol.suspensions.withLock { $0[token] = gate } }
        defer { LoginFeedbackProtocol.suspensions.withLock { $0.removeValue(forKey: token) } }
        let vault = CredentialVault(read: { _ in throw CredentialStorageError.absent }, write: { _ in
            gate.pause()
            throw CredentialStorageError.write
        })
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory, apiClient: WeBeepAPIClient(session: session), credentialVault: vault)
        controller.setDisconnectedForTesting()
        let login = Task { await controller.completeLoginForTesting(callback(token)) }
        var started = gate.started.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(controller.isAuthenticating)
        #expect(controller.validateConnection() == nil)
        controller.selectUniversity(.unipd)
        #expect(controller.selectedSite == .polimi)
        controller.selectSite(MoodleSite.unipd[1])
        #expect(controller.selectedSite == .polimi)
        #expect(controller.apiHostForTesting == MoodleSite.polimi.serverPolicy.host)
        gate.release.signal()
        await login.value
        #expect(!controller.isAuthenticating)
        #expect(!controller.hasStoredCredential)
        #expect(controller.authenticationFeedback != nil)
        controller.selectUniversity(.unipd)
        #expect(controller.selectedSite == MoodleSite.unipd[0])
        controller.selectSite(MoodleSite.unipd[1])
        #expect(controller.selectedSite == MoodleSite.unipd[1])
        #expect(controller.apiHostForTesting == MoodleSite.unipd[1].serverPolicy.host)
    }

    @Test(arguments: ["success", "invalid"]) @MainActor
    func verificationSerializesAccountActions(_ outcome: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoginFeedbackProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let gate = LoginSuspension(outcome: outcome)
        let token = UUID().uuidString
        LoginFeedbackProtocol.suspensions.withLock { $0[token] = gate }
        defer { LoginFeedbackProtocol.suspensions.withLock { $0.removeValue(forKey: token) } }
        let vault = CredentialVault(read: { _ in token }, write: { _ in Issue.record("Verification must not replace the token") })
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory, apiClient: WeBeepAPIClient(session: session), credentialVault: vault)
        let verification = try #require(controller.validateConnection())
        var started = gate.started.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(controller.isVerifying)
        var deletionAttempted = false
        controller.signOut(removeFile: { _ in deletionAttempted = true; throw CredentialStorageError.write })
        #expect(!deletionAttempted)
        #expect(controller.hasStoredCredential)
        controller.startLogin()
        #expect(!controller.isAuthenticating)
        #expect(controller.validateConnection() == nil)
        controller.selectUniversity(.unipd)
        controller.selectSite(MoodleSite.unipd[1])
        #expect(controller.selectedSite == .polimi)
        #expect(controller.apiHostForTesting == MoodleSite.polimi.serverPolicy.host)
        gate.release.signal()
        await verification.value
        #expect(!controller.isVerifying)
        #expect(controller.hasStoredCredential)
        #expect(controller.accountState == (outcome == "success" ? .connected : .expired))
        #expect(controller.selectedSite == .polimi)
        // After the terminal result a disconnect reaches the injected deletion hook.
        controller.signOut(removeFile: { _ in deletionAttempted = true; throw CredentialStorageError.write })
        #expect(deletionAttempted)
    }

    private func callback(_ token: String) -> URL {
        let payload = Data("site:::\(token)".utf8).base64EncodedString()
        return URL(string: "moodlemobile://token=\(payload)")!
    }
}

private final class LoginTokenMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var saved: String? { lock.withLock { value } }
    func record(_ token: String) { lock.withLock { value = token } }
}

private final class LoginSuspension: @unchecked Sendable {
    let outcome: String
    init(outcome: String = "network") { self.outcome = outcome }
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    func pause() {
        started.continuation.yield()
        release.wait()
    }
}

private final class LoginFeedbackProtocol: URLProtocol, @unchecked Sendable {
    static let suspensions = OSAllocatedUnfairLock(initialState: [String: LoginSuspension]())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
        let token = body.split(separator: "&").first { $0.hasPrefix("wstoken=") }.map { String($0.dropFirst(8)) } ?? ""
        let suspension = Self.suspensions.withLock { $0[token] }
        if let suspension {
            suspension.pause()
            if suspension.outcome == "network" {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
        }
        if body.contains("wstoken=network") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let json: String
        if body.contains("wstoken=invalid") || suspension?.outcome == "invalid" { json = #"{"exception":"invalidtoken","errorcode":"invalidtoken"}"# }
        else if body.contains("core_enrol_get_users_courses") { json = "[]" }
        else { json = #"{"userid":7,"siteurl":"https://webeep.polimi.it","functions":[{"name":"core_enrol_get_users_courses"},{"name":"core_course_get_contents"}]}"# }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
