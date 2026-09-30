import Foundation
import XCTest
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
