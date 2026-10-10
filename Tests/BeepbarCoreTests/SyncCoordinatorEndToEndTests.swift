import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BeepbarCore

@Suite(.serialized) struct SyncCoordinatorEndToEndTests {
    /// An override keeps its destination, and unchanged metadata must issue no name UPDATE.
    @Test func unchangedModuleOverrideDoesNotWrite() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.database.commitModuleMove(PendingModuleMove(rootID: fixture.rootID, courseID: 1, moduleID: 100, action: .set, oldFolder: nil, newFolder: "Custom", lastKnownName: "Lezioni", files: []))
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let before = await fixture.database.moduleOverrideUpdateAttempts
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(await fixture.database.moduleOverrideUpdateAttempts == before)
        #expect(fixture.contents("Course 1/Custom/0.txt") == "x")
    }

    /// One renamed module with a hundred files updates its display name once, preserving edits.
    @Test func renamedModuleOverrideWritesOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.database.commitModuleMove(PendingModuleMove(rootID: fixture.rootID, courseID: 1, moduleID: 100, action: .set, oldFolder: nil, newFolder: "Custom", lastKnownName: "Lezioni", files: []))
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        try fixture.write("local edit", to: "Course 1/Custom/0.txt")
        fixture.upstream.setModuleName(course: 1, name: "Nuovo nome")
        let before = await fixture.database.moduleOverrideUpdateAttempts
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(await fixture.database.moduleOverrideUpdateAttempts - before == 1)
        let saved = try await fixture.database.modulePathOverride(rootID: fixture.rootID, courseID: 1, moduleID: 100)
        #expect(saved?.lastKnownName == "Nuovo nome")
        #expect(saved?.localFolder == "Custom")
        #expect(fixture.contents("Course 1/Custom/0.txt") == "local edit")
    }

    /// Planning needs the post-backfill snapshot only, even when a prior sync tracked files.
    @Test func readsBaselinesOncePerRun() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let before = await fixture.database.baselineReadAttempts
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(await fixture.database.baselineReadAttempts - before == 1)
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(await fixture.database.baselineReadAttempts - before == 2)
    }

    /// A corrupt baseline must fail planning after metadata without downloading or touching files.
    @Test func invalidBaselineFailsBeforeDownloads() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let raw = try RawSQLite(url: fixture.supportDirectory.appending(path: "state.sqlite"))
        try raw.execute("UPDATE items SET relative_path = '../unsafe.txt' WHERE remote_id = '\(fixture.remoteID(course: 1, file: 0))'")
        fixture.upstream.resetDownloadCount()
        do {
            _ = try await fixture.synchronize(targets: [fixture.targets[0]])
            Issue.record("An invalid baseline must not produce a successful sync")
        } catch is RelativePathError { }
        #expect(fixture.upstream.downloadCount == 0)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "x")
        #expect(try await fixture.database.pendingOperations().isEmpty)
    }

    @Test func installsThousandFilesAndSecondRunDoesNotDownloadAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let first = try await fixture.synchronize()
        #expect(first.total == 1_000)
        #expect(first.installed == 1_000)
        #expect(first.added == 1_000)
        #expect(first.updated == 0)
        #expect(fixture.upstream.downloadCount == 1_000)
        #expect(fixture.upstream.maximumActiveDownloads <= 3)

        fixture.upstream.resetDownloadCount()
        let second = try await fixture.synchronize()
        #expect(second.added == 0)
        #expect(second.updated == 0)
        #expect(second.total == 0)
        #expect(fixture.upstream.downloadCount == 0)
    }

    @Test func distinguishesNewDownloadsFromRemoteUpdates() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]

        let first = try await fixture.synchronize(targets: [target])
        #expect(first.added == 100)
        #expect(first.updated == 0)

        fixture.upstream.setFile(course: 1, file: 0, value: "remote update", revision: "2")
        let second = try await fixture.synchronize(targets: [target])
        #expect(second.added == 0)
        #expect(second.updated == 1)
    }

    @Test func migratesLegacyPluginURLBaselineAndUpdatesInPlace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let legacyID = fixture.legacyRemoteID(course: 1, file: 0)
        let destination = try RelativePath("Course 1/Lezioni/0.txt")
        let localURL = fixture.root.appending(path: destination.value)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: localURL)
        let store = try FileStore(root: fixture.root)
        guard case .present(let sha256) = try await store.inspect(destination) else { Issue.record("missing local file"); return }
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: legacyID, relativePath: destination, sha256: sha256, remoteRevision: String(repeating: "a", count: 40)))

        fixture.upstream.resetDownloadCount()
        let unchanged = try await fixture.synchronize(targets: [target])
        #expect(unchanged.added == 99)
        #expect(fixture.upstream.downloadCount == 99)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: legacyID) == nil)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID)?.relativePath == destination)

        fixture.upstream.setFile(course: 1, file: 0, value: "remote update", revision: "2")
        let updated = try await fixture.synchronize(targets: [target])
        #expect(updated.updated == 1)
        #expect(try Data(contentsOf: localURL) == Data("remote update".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni/0 (1).txt").path))
    }

    @Test func legacyPluginURLMigrationPreservesLocalEditsAsAConflict() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let destination = try RelativePath("Course 1/Lezioni/0.txt")
        let localURL = fixture.root.appending(path: destination.value)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("base".utf8).write(to: localURL)
        let store = try FileStore(root: fixture.root)
        guard case .present(let sha256) = try await store.inspect(destination) else { Issue.record("missing local file"); return }
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: fixture.legacyRemoteID(course: 1, file: 0), relativePath: destination, sha256: sha256, remoteRevision: "1"))
        try Data("local edit".utf8).write(to: localURL)
        fixture.upstream.setFile(course: 1, file: 0, value: "remote update", revision: "2")

        let result = try await fixture.synchronize(targets: [target])

        #expect(result.conflicts == 1)
        #expect(try Data(contentsOf: localURL) == Data("local edit".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni/0 (1).txt").path))
    }

    @Test func defersLegacyMigrationWithOpenConflictWithoutCreatingASuffix() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let destination = try RelativePath("Course 1/Lezioni/0.txt")
        let localURL = fixture.root.appending(path: destination.value)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("base".utf8).write(to: localURL)
        let store = try FileStore(root: fixture.root)
        guard case .present(let sha256) = try await store.inspect(destination) else { Issue.record("missing local file"); return }
        let legacyID = fixture.legacyRemoteID(course: 1, file: 0)
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: legacyID, relativePath: destination, sha256: sha256, remoteRevision: "1"))
        try await fixture.database.insertConflict(ConflictRecord(id: UUID(), rootID: fixture.rootID, remoteID: legacyID, relativePath: destination, incomingPath: try RelativePath(internal: ".beepbar/incoming/0.txt"), baseSHA256: sha256, localSHA256: sha256, remoteSHA256: String(repeating: "b", count: 64), remoteRevision: "2", detectedAt: Date(), status: .open))

        let result = try await fixture.synchronize(targets: [fixture.targets[0]])

        #expect(result.added == 99)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0)) == nil)
        #expect(FileManager.default.fileExists(atPath: localURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni/0 (1).txt").path))
    }

    @Test func aggregatesAddedAndUpdatedCountsPerCourse() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let courseA = fixture.targets[0]
        let courseB = fixture.targets[1]

        let first = try await fixture.synchronize(targets: [courseA, courseB])
        #expect(first.perCourse.count == 2)
        let firstA = try #require(first.perCourse.first { $0.courseID == courseA.courseID })
        let firstB = try #require(first.perCourse.first { $0.courseID == courseB.courseID })
        #expect(firstA.added == 100 && firstA.updated == 0)
        #expect(firstB.added == 100 && firstB.updated == 0)
        #expect(firstA.courseFolder == courseA.localFolder)

        fixture.upstream.setFile(course: courseA.courseID, file: 0, value: "remote update", revision: "2")
        let second = try await fixture.synchronize(targets: [courseA, courseB])
        #expect(second.perCourse.count == 1)
        let secondA = try #require(second.perCourse.first)
        #expect(secondA.courseID == courseA.courseID)
        #expect(secondA.added == 0 && secondA.updated == 1)
    }

    @Test func resolvesBothConflictChoicesWithoutReopeningTheConflict() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])

        let firstID = fixture.remoteID(course: 1, file: 0)
        let firstBaseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: firstID))
        try Data("local".utf8).write(to: fixture.root.appending(path: firstBaseline.relativePath.value))
        fixture.upstream.setFile(course: 1, file: 0, value: "remote", revision: "2")

        let conflictProgress = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(conflictProgress.conflicts == 1)
        let firstConflict = try #require(await fixture.database.conflicts(rootID: fixture.rootID).first)
        try await ConflictResolver(database: fixture.database, fileStore: try FileStore(root: fixture.root), gate: fixture.gate).keepLocal(id: firstConflict.id)
        #expect(try await fixture.synchronize(targets: [fixture.targets[0]]).conflicts == 0)
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).isEmpty)
        #expect(try Data(contentsOf: fixture.root.appending(path: firstBaseline.relativePath.value)) == Data("local".utf8))

        let secondID = fixture.remoteID(course: 1, file: 1)
        let secondBaseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: secondID))
        try Data("local-second".utf8).write(to: fixture.root.appending(path: secondBaseline.relativePath.value))
        fixture.upstream.setFile(course: 1, file: 1, value: "remote-second", revision: "2")
        #expect(try await fixture.synchronize(targets: [fixture.targets[0]]).conflicts == 1)
        let secondConflict = try #require(await fixture.database.conflicts(rootID: fixture.rootID).first)
        _ = try await ConflictResolver(database: fixture.database, fileStore: try FileStore(root: fixture.root), gate: fixture.gate).useRemote(id: secondConflict.id)
        #expect(try Data(contentsOf: fixture.root.appending(path: secondBaseline.relativePath.value)) == Data("remote-second".utf8))
        #expect(try await fixture.database.conflicts(rootID: fixture.rootID).isEmpty)
    }

    @Test func keepsFileAndBaselineOn404AndReinstallsDeletedFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))
        let destination = fixture.root.appending(path: baseline.relativePath.value)
        let original = try Data(contentsOf: destination)

        fixture.upstream.setFile(course: 1, file: 0, value: "changed", revision: "2")
        fixture.upstream.setStatus(course: 1, file: 0, status: 404)
        let failed = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(failed.failures == 1)
        #expect(try Data(contentsOf: destination) == original)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID) == baseline)

        fixture.upstream.setStatus(course: 1, file: 0, status: 200)
        try FileManager.default.removeItem(at: destination)
        let restored = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(restored.installed == 1)
        #expect(restored.added == 1)
        #expect(try Data(contentsOf: destination) == Data("changed".utf8))
    }

    @Test func oneServerFailureProducesAPartialResultWithTheFileName() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setStatus(course: 1, file: 0, status: 503)

        let result = try await fixture.synchronize(targets: [fixture.targets[0]])

        #expect(result.added == 99)
        #expect(result.failures == 1)
        let course = try #require(result.perCourse.first)
        #expect(course.failedItems.map(\.name) == ["0.txt"])
        #expect(course.failedItems.first?.reason == "Errore del server (503).")
    }

    @Test func allServerFailuresStillReportServiceUnavailable() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        for file in 0..<100 { fixture.upstream.setStatus(course: 1, file: file, status: 503) }

        await #expect(throws: WeBeepAPIError.transport(503)) {
            try await fixture.synchronize(targets: [fixture.targets[0]])
        }
    }

    @Test(arguments: [401, 403])
    func validatesTokenOnceBeforeClassifyingDownloadAuthorizationFailure(_ status: Int) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setStatus(course: 1, file: 0, status: status)

        await #expect(throws: WeBeepAPIError.transport(status)) {
            try await fixture.synchronize(targets: [fixture.targets[0]])
        }
        #expect(fixture.upstream.validationCount == 1)
    }

    @Test func reportsExpiredTokenAfterDownloadAuthorizationFailure() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setStatus(course: 1, file: 0, status: 401)
        fixture.upstream.tokenIsValid = false

        await #expect(throws: WeBeepAPIError.invalidToken) {
            try await fixture.synchronize(targets: [fixture.targets[0]])
        }
        #expect(fixture.upstream.validationCount == 1)
    }

    @Test func recreatesDeletedCourseDirectoryAndReinstallsFiles() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0)))

        try FileManager.default.removeItem(at: fixture.root.appending(path: target.localFolder))
        let restored = try await fixture.synchronize(targets: [target])

        #expect(restored.installed == 100)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: baseline.relativePath.value).path))
    }

    @Test func missingBaselineFileKeepsItsTrackedDestination() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let destination = try RelativePath("Course 1/original.txt")
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(
            remoteID: remoteID,
            relativePath: destination,
            sha256: String(repeating: "0", count: 64),
            remoteRevision: "0"
        ))

        let result = try await fixture.synchronize(targets: [fixture.targets[0]])
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))

        #expect(result.installed == 100)
        #expect(baseline.relativePath == destination)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: destination.value).path))
    }

    @Test func ghostBaselineWithNoLocalFileDoesNotStealAFreshFilesName() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let ghostDestination = try RelativePath("Course 1/Lezioni/0.txt")
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(
            remoteID: "1:100:/webservice/pluginfile.php/1/ghost.txt",
            relativePath: ghostDestination,
            sha256: String(repeating: "0", count: 64),
            remoteRevision: "0"
        ))

        let result = try await fixture.synchronize(targets: [fixture.targets[0]])

        #expect(result.installed == 100)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: ghostDestination.value).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni/0 (1).txt").path))
    }

    @Test func secondRunWithNothingChangedDoesNotHashAnyFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize()
        let hashesAfterFirstRun = await fixture.coordinator.fileStore.hashCount
        #expect(hashesAfterFirstRun > 0)

        let second = try await fixture.synchronize()

        #expect(second.total == 0)
        #expect(await fixture.coordinator.fileStore.hashCount == hashesAfterFirstRun)
    }

    @Test func syncedPathReplacedByDirectoryDoesNotAbortTheRun() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))
        let destination = fixture.root.appending(path: baseline.relativePath.value)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        fixture.upstream.setFile(course: 1, file: 1, value: "remote update", revision: "2")

        let result = try await fixture.synchronize(targets: [target])

        #expect(result.total == 2)
        #expect(result.updated == 1)
        #expect(result.failures == 1)
        #expect(try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID) == baseline)
    }

    @Test func duplicateLogicalRemoteIDsAreNotInstalled() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0)))
        let destination = fixture.root.appending(path: baseline.relativePath.value)
        try FileManager.default.removeItem(at: destination)
        fixture.upstream.addFile(course: 1, file: 100, filename: "0.txt", value: "newcomer", revision: "1")

        let result = try await fixture.synchronize(targets: [target])
        #expect(result.total == 0)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0))?.relativePath == baseline.relativePath)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni/0 (1).txt").path))
    }

    @Test func changedLocalAndRemoteFileConflictsAtTrackedLegacyDestination() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))
        let legacyPath = try RelativePath("Course 1/legacy/0.txt")
        let legacyURL = fixture.root.appending(path: legacyPath.value)
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local edit".utf8).write(to: legacyURL)
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(
            remoteID: remoteID,
            relativePath: legacyPath,
            sha256: baseline.sha256,
            remoteRevision: baseline.remoteRevision
        ))
        fixture.upstream.setFile(course: 1, file: 0, value: "remote edit", revision: "2")

        let result = try await fixture.synchronize(targets: [fixture.targets[0]])
        let conflict = try #require(await fixture.database.conflicts(rootID: fixture.rootID).first)

        #expect(result.conflicts == 1)
        #expect(conflict.relativePath == legacyPath)
        #expect(try Data(contentsOf: legacyURL) == Data("local edit".utf8))
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID)?.relativePath == legacyPath)
    }

    @Test func duplicateTrackedDestinationsFailBeforeDownloading() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let sharedPath = try RelativePath("Course 1/shared.txt")
        for file in 0...1 {
            try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(
                remoteID: fixture.remoteID(course: 1, file: file),
                relativePath: sharedPath,
                sha256: String(repeating: "0", count: 64),
                remoteRevision: "0"
            ))
        }

        await #expect(throws: SyncDatabaseError.execution) {
            try await fixture.synchronize(targets: [fixture.targets[0]])
        }
        #expect(fixture.upstream.downloadCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: sharedPath.value).path))
    }

    @Test func cancellationLeavesNoBaselineOrStagingArtifacts() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setFile(course: 1, file: 0, value: String(repeating: "x", count: 65_536), revision: "2")
        fixture.upstream.downloadDelay = 1
        let task = Task { try await fixture.synchronize(targets: [fixture.targets[0]]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await fixture.database.baselines(rootID: fixture.rootID).isEmpty)
        #expect(fixture.stagingFiles().isEmpty)
    }

    @Test func downloadConcurrencyIsBoundedAndProgressIsMonotonic() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.downloadDelay = 0.01
        let recorder = ProgressRecorder()
        let summary = try await fixture.coordinator.synchronize(targets: [fixture.targets[0]], token: "test-token", mode: .manual, networkAccess: .unrestricted) { update in recorder.append(update) }
        let progress = recorder.values
        #expect(fixture.upstream.maximumActiveDownloads == 3)
        #expect(progress.count == 100)
        #expect(progress.enumerated().allSatisfy { $0.element.completed == $0.offset + 1 })
        #expect(progress.allSatisfy { $0.perCourse.isEmpty })
        #expect(progress.last?.completed == progress.last?.total)
        #expect(summary.perCourse.count == 1)
    }

    @Test func cancellationDuringStagingPreservesExistingFileAndBaseline() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let remoteID = fixture.remoteID(course: 1, file: 0)
        let baseline = try #require(await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID))
        let destination = fixture.root.appending(path: baseline.relativePath.value)
        let original = try Data(contentsOf: destination)
        fixture.upstream.setFile(course: 1, file: 0, value: String(repeating: "x", count: 67_108_864), revision: "2")
        fixture.upstream.downloadDelay = 0.01

        let task = Task { try await fixture.synchronize(targets: [fixture.targets[0]]) }
        var stageCreated = false
        for _ in 0..<2_000 {
            if !fixture.stagingFiles().isEmpty {
                stageCreated = true
                task.cancel()
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(stageCreated)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: remoteID) == baseline)
        #expect(fixture.stagingFiles().isEmpty)
    }

    @Test func missingRootAndConcurrentRunsDoNotMutateState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.downloadDelay = 1
        let first = Task { try await fixture.synchronize(targets: [fixture.targets[0]]) }
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: RootOperationGateError.self) { try await fixture.synchronize(targets: [fixture.targets[0]], mode: .automatic) }
        first.cancel()
        _ = try? await first.value

        try FileManager.default.removeItem(at: fixture.root)
        await #expect(throws: FileStoreError.self) { try await fixture.synchronize(targets: [fixture.targets[0]]) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    /// Proves that an automatic run with "Risparmio dati" on asks macOS to keep its downloads off a
    /// phone hotspot and Low Data Mode networks: if the Mac moves to one midway, the next download
    /// is refused instead of spending the user's data. Guards against `.dataSaver` losing its
    /// limits, or the coordinator ignoring the access it is given.
    @Test func automaticSyncWithDataSaverDownloadsOnlyOverUnlimitedNetworks() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]], mode: .automatic, networkAccess: .dataSaver)
        #expect(fixture.upstream.downloadCount > 0)
        #expect(fixture.upstream.downloadNetworkAccess == [RecordedNetworkAccess(expensive: false, constrained: false)])
    }

    /// Proves that the course listing of a Data Saver run is not limited, only its downloads: the
    /// listing is small, and limiting it would turn a hotspot into a false "Connessione assente"
    /// before the app could tell it apart. Guards against the limits spreading to Moodle calls.
    @Test func automaticSyncWithDataSaverReadsCourseContentsOverAnyNetwork() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]], mode: .automatic, networkAccess: .dataSaver)
        #expect(fixture.upstream.contentsNetworkAccess == [RecordedNetworkAccess(expensive: true, constrained: true)])
    }

    /// Proves that with "Risparmio dati" off (the default) an automatic run downloads over any
    /// network, hotspot included, like a manual one. Guards against the automatic mode quietly
    /// restricting downloads on its own again, which is what showed users a false
    /// "Connessione assente" on a hotspot.
    @Test func automaticSyncWithoutDataSaverDownloadsOverAnyNetwork() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]], mode: .automatic, networkAccess: .unrestricted)
        #expect(fixture.upstream.downloadCount > 0)
        #expect(fixture.upstream.downloadNetworkAccess == [RecordedNetworkAccess(expensive: true, constrained: true)])
    }

    // A course whose contents Moodle refuses (unenrolled, hidden or restricted course) must not
    // stop every other selected course from syncing.
    @Test(arguments: [SyncCoordinatorMode.manual, .automatic])
    func oneRejectedCourseDoesNotAbortTheOtherCourses(_ mode: SyncCoordinatorMode) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.rejectContents(course: 2)

        let result = try await fixture.synchronize(targets: [fixture.targets[0], fixture.targets[1]], mode: mode)

        #expect(result.added == 100)
        #expect(result.failures == 1)
        #expect(result.failedCourses == 1)
        let failed = try #require(result.perCourse.first { $0.courseID == 2 })
        #expect(failed.courseFailure == "Corso non accessibile su Moodle.")
        #expect(failed.courseFolder == "Course 2")
        #expect(fixture.upstream.downloadCount == 100)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni/0.txt").path))
    }

    @Test func adoptsACourseFolderThatAlreadyExistedSoItCanBeRenamedLater() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "Course 1"), withIntermediateDirectories: true)

        _ = try await fixture.synchronize(targets: [fixture.targets[0]])

        let scope = try #require(await fixture.database.scope(rootID: fixture.rootID, courseID: 1))
        let identity = try await FileStore(root: fixture.root).topLevelDirectoryIdentity("Course 1")
        #expect(scope.managedDirectory != nil)
        #expect(scope.managedDirectory == identity)
        let renamer = CourseFolderRenamer(database: fixture.database, fileStore: try FileStore(root: fixture.root), gate: fixture.gate)
        try await renamer.rename(rootID: fixture.rootID, courseID: 1, from: "Course 1", to: "Renamed")
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Renamed/Lezioni/0.txt").path))
    }

    @Test func repairsALegacyScopeSavedWithoutAFolder() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.database.upsertScope(SyncScope(rootID: fixture.rootID, courseID: 1, displayName: "Course 1", localFolder: "", enabled: true))

        _ = try await fixture.synchronize(targets: [fixture.targets[0]])

        let scope = try #require(await fixture.database.scope(rootID: fixture.rootID, courseID: 1))
        #expect(scope.localFolder == "Course 1")
        #expect(scope.managedDirectory == (try await FileStore(root: fixture.root).topLevelDirectoryIdentity("Course 1")))
    }

    @Test func doesNotReplaceTheIdentityOfAnAlreadyManagedFolder() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let recorded = DirectoryIdentity(device: 1, inode: 2)
        try await fixture.database.upsertScope(SyncScope(rootID: fixture.rootID, courseID: 1, displayName: "Course 1", localFolder: "Course 1", enabled: true, managedDirectory: recorded))
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "Course 1"), withIntermediateDirectories: true)

        _ = try await fixture.synchronize(targets: [fixture.targets[0]])

        #expect(try await fixture.database.scope(rootID: fixture.rootID, courseID: 1)?.managedDirectory == recorded)
    }

    @Test func rejectedCourseIsReportedEvenWhenEverythingElseIsUnchanged() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        fixture.upstream.rejectContents(course: 2)

        let result = try await fixture.synchronize(targets: [fixture.targets[0], fixture.targets[1]])

        #expect(result.total == 0)
        #expect(result.failures == 1)
        #expect(result.perCourse.map(\.courseID) == [2])
    }

    @Test func everyCourseFailingWithAServerErrorStillReportsServiceUnavailable() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.failContents(course: 1, status: 503)
        fixture.upstream.failContents(course: 2, status: 502)

        await #expect(throws: WeBeepAPIError.transport(503)) {
            _ = try await fixture.synchronize(targets: [fixture.targets[0], fixture.targets[1]])
        }
    }

    @Test func everyCourseAnsweredByACaptivePortalIsAPlatformProblem() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.failContents(course: 1, status: 200)
        fixture.upstream.failContents(course: 2, status: 200)

        await #expect(throws: WeBeepAPIError.invalidResponse) {
            _ = try await fixture.synchronize(targets: [fixture.targets[0], fixture.targets[1]])
        }
    }

    @Test func everyCourseRefusedByMoodleIsReportedPerCourse() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.rejectContents(course: 1)
        fixture.upstream.rejectContents(course: 2)

        let result = try await fixture.synchronize(targets: [fixture.targets[0], fixture.targets[1]])

        #expect(result.failedCourses == 2)
        #expect(result.added == 0)
    }

    @Test func oneCourseWithAServerErrorDoesNotAbortTheOthers() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.failContents(course: 2, status: 503)

        let result = try await fixture.synchronize(targets: [fixture.targets[0], fixture.targets[1]])

        #expect(result.added == 100)
        #expect(result.failedCourses == 1)
    }

    @Test func expiredTokenWhileReadingContentsStillStopsTheRun() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.rejectContents(course: 2, errorCode: "invalidtoken")

        await #expect(throws: WeBeepAPIError.invalidToken) {
            _ = try await fixture.synchronize(targets: [fixture.targets[0], fixture.targets[1]])
        }
    }

    @Test func manualSyncDownloadsOverAnyNetwork() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]], mode: .manual)
        #expect(fixture.upstream.downloadCount > 0)
        #expect(fixture.upstream.downloadNetworkAccess == [RecordedNetworkAccess(expensive: true, constrained: true)])
    }

    /// Proves that "Sincronizza ora" reads course contents over any network, metered hotspot and
    /// Low Data Mode included: the user asked for the run. Guards against a change that restricts
    /// the Moodle requests a manual run sends, the way downloads can be restricted.
    @Test func manualSyncReadsCourseContentsOverAnyNetwork() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]], mode: .manual)
        #expect(fixture.upstream.contentsRequestCount == 1)
        #expect(fixture.upstream.contentsNetworkAccess == [RecordedNetworkAccess(expensive: true, constrained: true)])
    }

    /// Proves that after a refused download in "Sincronizza ora", the token check that follows may
    /// use any network too. It is the one other Moodle request the coordinator sends, and the app
    /// tests cannot reach it: their controller downloads through a real session.
    @Test func manualSyncChecksTheTokenOverAnyNetwork() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.upstream.setStatus(course: 1, file: 0, status: 401)

        await #expect(throws: WeBeepAPIError.transport(401)) {
            try await fixture.synchronize(targets: [fixture.targets[0]], mode: .manual)
        }
        #expect(fixture.upstream.validationCount == 1)
        #expect(fixture.upstream.validationNetworkAccess == [RecordedNetworkAccess(expensive: true, constrained: true)])
    }

    // MARK: Following moves made on Moodle

    @Test func followsAModuleMovedToAnotherSectionWithoutDownloadingAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])

        fixture.upstream.setSection(course: 1, name: "Lab 1")
        fixture.upstream.resetDownloadCount()
        let moved = try await fixture.synchronize(targets: [target])

        #expect(moved.moved == 100)
        #expect(moved.added == 0 && moved.updated == 0 && moved.conflicts == 0)
        #expect(fixture.upstream.downloadCount == 0)
        let course = try #require(moved.perCourse.first { $0.courseID == 1 })
        #expect(course.courseFolder == "Course 1")
        #expect(course.movedItems.allSatisfy { $0.outcome == .moved && $0.folder == "Lab 1/Lezioni" })
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lab 1/Lezioni/0.txt").path))
        // The old module folder is removed once empty.
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni").path))
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0))?.relativePath.value == "Course 1/Lab 1/Lezioni/0.txt")

        let again = try await fixture.synchronize(targets: [target])
        #expect(again.moved == 0 && again.total == 0 && again.perCourse.isEmpty)
    }

    @Test func followsARenamedModule() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])

        fixture.upstream.setModuleName(course: 1, name: "Lezioni 2026")
        let result = try await fixture.synchronize(targets: [target])

        #expect(result.moved == 100)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni 2026/7.txt").path))
    }

    @Test func aFileEditedLocallyStaysWhereTheUserLeftIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        let edited = fixture.root.appending(path: "Course 1/Lezioni/0.txt")
        try Data("my notes".utf8).write(to: edited)

        fixture.upstream.setSection(course: 1, name: "Lab 1")
        let result = try await fixture.synchronize(targets: [target])

        #expect(result.moved == 99)
        #expect(try Data(contentsOf: edited) == Data("my notes".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lab 1/Lezioni/0.txt").path))
        let kept = try #require(result.perCourse.first?.movedItems.first { $0.id == fixture.remoteID(course: 1, file: 0) })
        #expect(kept.outcome == .keptEdited)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0))?.relativePath.value == "Course 1/Lezioni/0.txt")

        // Reported once, not on every later sync.
        let again = try await fixture.synchronize(targets: [target])
        #expect(again.perCourse.isEmpty)
        #expect(try Data(contentsOf: edited) == Data("my notes".utf8))
    }

    @Test func aFileWhoseNewPlaceIsTakenArrivesWithANumber() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("someone else's file", to: "Course 1/Lab 1/Lezioni/0.txt")

        fixture.upstream.setSection(course: 1, name: "Lab 1")
        fixture.upstream.resetDownloadCount()
        let result = try await fixture.synchronize(targets: [target])

        #expect(result.moved == 100)
        #expect(fixture.upstream.downloadCount == 0)
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == "someone else's file")
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0 (1).txt") == "x")
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0))?.relativePath.value == "Course 1/Lab 1/Lezioni/0 (1).txt")
        #expect(result.perCourse.first?.movedItems.first { $0.id == fixture.remoteID(course: 1, file: 0) }?.name == "0 (1).txt")
    }

    @Test func aDeletedFileMovedOntoAnotherTrackedFileGetsANumberInsteadOfSharingItsPath() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        // Another tracked file, with the same contents, already sits where Moodle will move 0.txt.
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 1", name: "Lezioni")
        fixture.upstream.addFile(course: 1, file: 700, filename: "0.txt", value: "x", revision: "1", module: 150)
        _ = try await fixture.synchronize(targets: [target])
        try FileManager.default.removeItem(at: fixture.root.appending(path: "Course 1/Lezioni/0.txt"))

        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])
        let again = try await fixture.synchronize(targets: [target])

        #expect(again.failures == 0)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0))?.relativePath.value == "Course 1/Lab 1/Lezioni/0 (1).txt")
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 700, module: 150, filename: "0.txt"))?.relativePath.value == "Course 1/Lab 1/Lezioni/0.txt")
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0 (1).txt") == "x")
    }

    @Test func aDeletedFileWhoseNewPlaceIsTakenIsDownloadedThereWithANumber() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        try FileManager.default.removeItem(at: fixture.root.appending(path: "Course 1/Lezioni/0.txt"))
        try fixture.write("someone else's file", to: "Course 1/Lab 1/Lezioni/0.txt")

        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])

        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == "someone else's file")
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0 (1).txt") == "x")
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == nil)
    }

    @Test func filesTrackedByAnOlderVersionAreNotMovedRetroactively() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        // An older version tracked this file without recording where Moodle placed it, and Moodle
        // has since put the module in another section.
        let legacyPath = try RelativePath("Course 1/Lezioni/0.txt")
        let localURL = fixture.root.appending(path: legacyPath.value)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: localURL)
        let store = try FileStore(root: fixture.root)
        guard case .present(let sha256) = try await store.inspect(legacyPath) else { Issue.record("missing local file"); return }
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: fixture.remoteID(course: 1, file: 0), relativePath: legacyPath, sha256: sha256, remoteRevision: String(repeating: "a", count: 40), courseID: 1, moduleID: 100))
        fixture.upstream.setSection(course: 1, name: "Lab 1")

        let first = try await fixture.synchronize(targets: [target])
        let second = try await fixture.synchronize(targets: [target])

        #expect(first.moved == 0 && second.moved == 0)
        #expect(FileManager.default.fileExists(atPath: localURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lab 1/Lezioni/0.txt").path))
        #expect(try await fixture.database.remotePlacements(rootID: fixture.rootID)[fixture.remoteID(course: 1, file: 0)] == RemotePlacement(sectionName: "Lab 1", moduleName: "Lezioni", isSingleFileResource: false))

        // From then on, moves are followed.
        fixture.upstream.setSection(course: 1, name: "Lab 2")
        let third = try await fixture.synchronize(targets: [target])
        #expect(third.moved == 100)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lab 2/Lezioni/0.txt").path))
    }

    @Test func aMoveInterruptedAfterTheRenameIsCompletedWithoutDownloading() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        // The file already reached its new place, but the crash came before the baseline followed.
        let newURL = fixture.root.appending(path: "Course 1/Lab 1/Lezioni/0.txt")
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.root.appending(path: "Course 1/Lezioni/0.txt"), to: newURL)

        fixture.upstream.setSection(course: 1, name: "Lab 1")
        fixture.upstream.resetDownloadCount()
        let result = try await fixture.synchronize(targets: [target])

        #expect(fixture.upstream.downloadCount == 0)
        #expect(result.conflicts == 0)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0))?.relativePath.value == "Course 1/Lab 1/Lezioni/0.txt")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1/Lezioni/0.txt").path))
    }

    @Test func aFileWithAnOpenConflictWaitsUntilTheConflictIsResolved() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        let path = fixture.root.appending(path: "Course 1/Lezioni/0.txt")
        try Data("local edit".utf8).write(to: path)
        fixture.upstream.setFile(course: 1, file: 0, value: "remote update", revision: "2")
        let conflicted = try await fixture.synchronize(targets: [target])
        #expect(conflicted.conflicts == 1)

        fixture.upstream.setSection(course: 1, name: "Lab 1")
        let result = try await fixture.synchronize(targets: [target])

        #expect(result.moved == 99)
        #expect(result.perCourse.first?.movedItems.contains { $0.id == fixture.remoteID(course: 1, file: 0) } == false)
        #expect(try Data(contentsOf: path) == Data("local edit".utf8))
    }

    // MARK: Choices in Conflicts for files Moodle moved or removed

    @Test func anEditedFileMovedOnMoodleWaitsInConflictsAndMovesOnlyWhenChosen() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my notes", to: "Course 1/Lezioni/0.txt")
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])

        let change = try #require(try await fixture.change(for: id))
        #expect(change.kind == .moved)
        #expect(change.isLocallyModified)
        #expect(change.relativePath.value == "Course 1/Lezioni/0.txt")
        #expect(change.targetPath?.value == "Course 1/Lab 1/Lezioni/0.txt")

        #expect(try await fixture.resolve(change, .moveMine) == .done(try RelativePath("Course 1/Lab 1/Lezioni/0.txt")))
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == "my notes")
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == nil)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: id)?.relativePath.value == "Course 1/Lab 1/Lezioni/0.txt")
        #expect(try await fixture.changes().isEmpty)

        fixture.upstream.resetDownloadCount()
        let after = try await fixture.synchronize(targets: [target])
        #expect(after.perCourse.isEmpty && fixture.upstream.downloadCount == 0)
        #expect(try await fixture.changes().isEmpty)
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == "my notes")
    }

    @Test func leaveHereKeepsFollowingTheFileWhereItIs() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my notes", to: "Course 1/Lezioni/0.txt")
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])

        let change = try #require(try await fixture.change(for: id))
        #expect(try await fixture.resolve(change, .leaveHere) == .done(nil))
        let after = try await fixture.synchronize(targets: [target])

        #expect(after.perCourse.isEmpty)
        #expect(try await fixture.changes().isEmpty)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "my notes")
        // The teacher's next update reaches the file where the user left it, as a conflict.
        fixture.upstream.setFile(course: 1, file: 0, value: "teacher update", revision: "2")
        let updated = try await fixture.synchronize(targets: [target])
        #expect(updated.conflicts == 1)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "my notes")
    }

    @Test func anEntryClosesByItselfWhenMoodleMovesTheFileBack() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my notes", to: "Course 1/Lezioni/0.txt")
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])
        #expect(try await fixture.changes().count == 1)

        fixture.upstream.setSection(course: 1, name: "Materiali")
        let back = try await fixture.synchronize(targets: [target])

        #expect(try await fixture.changes().isEmpty)
        #expect(back.moved == 99)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "my notes")
    }

    @Test func aSyncWithAnEntryAlreadyOpenReadsNoFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my notes", to: "Course 1/Lezioni/0.txt")
        fixture.upstream.removeFile(course: 1, file: 1)
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])
        #expect(try await fixture.changes().count == 2)

        let before = await fixture.fileStore.hashCount
        _ = try await fixture.synchronize(targets: [target])
        #expect(await fixture.fileStore.hashCount == before)
        #expect(try await fixture.changes().count == 2)
    }

    @Test func movingMyVersionOntoATakenPlaceGivesItANumber() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my notes", to: "Course 1/Lezioni/0.txt")
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])
        let change = try #require(try await fixture.change(for: fixture.remoteID(course: 1, file: 0)))
        try fixture.write("someone else's file", to: "Course 1/Lab 1/Lezioni/0.txt")

        #expect(try await fixture.resolve(change, .moveMine) == .done(try RelativePath("Course 1/Lab 1/Lezioni/0 (1).txt")))
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == "someone else's file")
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0 (1).txt") == "my notes")
    }

    @Test func anActionOnAFileChangedSinceItWasShownDoesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my notes", to: "Course 1/Lezioni/0.txt")
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])
        let shown = try #require(try await fixture.change(for: id))
        try fixture.write("more notes", to: "Course 1/Lezioni/0.txt")

        #expect(try await fixture.resolve(shown, .moveMine) == .fileChanged)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "more notes")
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == nil)

        // The entry now shows the current contents, and the choice works on them.
        let refreshed = try #require(try await fixture.change(for: id))
        #expect(refreshed.localSHA256 != shown.localSHA256)
        #expect(try await fixture.resolve(refreshed, .moveMine) == .done(try RelativePath("Course 1/Lab 1/Lezioni/0.txt")))
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == "more notes")
    }

    @Test func aFileRemovedFromMoodleIsNeverDeletedAndCanGoToTheTrash() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        fixture.upstream.removeFile(course: 1, file: 0)

        _ = try await fixture.synchronize(targets: [target])
        let change = try #require(try await fixture.change(for: id))
        #expect(change.kind == .removed && !change.isLocallyModified)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "x")
        _ = try await fixture.synchronize(targets: [target])
        #expect(try await fixture.change(for: id)?.id == change.id)

        #expect(try await fixture.resolve(change, .trash) == .done(nil))
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == nil)
        #expect(fixture.trashedFiles() == ["0.txt"])
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: id) == nil)
        #expect(try await fixture.changes().isEmpty)
    }

    @Test func aKeptFileIsTrackedAgainIfItReturnsUnchangedAndConflictsOtherwise() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        fixture.upstream.removeFile(course: 1, file: 0)
        fixture.upstream.removeFile(course: 1, file: 1)
        // Two removed files with the same contents are not taken for one re-uploaded file.
        _ = try await fixture.synchronize(targets: [target])
        for change in try await fixture.changes() {
            #expect(change.kind == .removed)
            #expect(try await fixture.resolve(change, .keep) == .done(nil))
        }
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0)) == nil)
        try fixture.write("mine now", to: "Course 1/Lezioni/1.txt")

        fixture.upstream.addFile(course: 1, file: 0, filename: "0.txt", value: "x", revision: "1")
        fixture.upstream.addFile(course: 1, file: 1, filename: "1.txt", value: "x", revision: "1")
        let back = try await fixture.synchronize(targets: [target])

        #expect(back.conflicts == 1)
        #expect(fixture.contents("Course 1/Lezioni/1.txt") == "mine now")
        #expect(fixture.contents("Course 1/Lezioni/0 (1).txt") == nil && fixture.contents("Course 1/Lezioni/1 (1).txt") == nil)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0))?.relativePath.value == "Course 1/Lezioni/0.txt")
        #expect(try await fixture.changes().isEmpty)
    }

    @Test func aRemovedEntryClosesWhenTheFileReturnsOrTheUserDeletesIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        fixture.upstream.removeFile(course: 1, file: 0)
        fixture.upstream.removeFile(course: 1, file: 1)
        _ = try await fixture.synchronize(targets: [target])
        #expect(try await fixture.changes().count == 2)

        // A module hidden for a while comes back; the other file the user deleted.
        fixture.upstream.addFile(course: 1, file: 0, filename: "0.txt", value: "x", revision: "1")
        try FileManager.default.removeItem(at: fixture.root.appending(path: "Course 1/Lezioni/1.txt"))
        fixture.upstream.resetDownloadCount()
        _ = try await fixture.synchronize(targets: [target])

        #expect(try await fixture.changes().isEmpty)
        #expect(fixture.upstream.downloadCount == 0)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "x")
    }

    @Test func nothingIsReportedRemovedFromAModuleWithAnUnreadableEntry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        fixture.upstream.removeFile(course: 1, file: 0)
        fixture.upstream.addMalformedEntry(course: 1)

        _ = try await fixture.synchronize(targets: [target])

        #expect(try await fixture.changes().isEmpty)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "x")
    }

    @Test func filesRemovedBeforeUpdatingAreListedButUnattributedOnesAreNot() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        _ = try await fixture.synchronize(targets: [target])
        // Left behind by an older version: one knows its course, one does not.
        try fixture.write("old", to: "Course 1/Lezioni/old.txt")
        try fixture.write("older", to: "Course 1/older.txt")
        guard case .present(let oldSHA) = try await fixture.fileStore.inspect(try RelativePath("Course 1/Lezioni/old.txt")),
              case .present(let olderSHA) = try await fixture.fileStore.inspect(try RelativePath("Course 1/older.txt")) else { Issue.record("missing file"); return }
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: "1:100:/:old.txt", relativePath: try RelativePath("Course 1/Lezioni/old.txt"), sha256: oldSHA, remoteRevision: "1:3", courseID: 1, moduleID: 100))
        try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: "1:100:/webservice/pluginfile.php/older.txt", relativePath: try RelativePath("Course 1/older.txt"), sha256: olderSHA, remoteRevision: "1:5"))

        _ = try await fixture.synchronize(targets: [target])

        let changes = try await fixture.changes()
        #expect(changes.map(\.remoteID) == ["1:100:/:old.txt"])
        #expect(changes.first?.kind == .removed)
    }

    @Test func anUneditedFileUploadedAgainElsewhereIsMovedNotDownloaded() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        #expect(fixture.contents("Course 1/Lezioni/es.txt") == "exercise")

        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        fixture.upstream.resetDownloadCount()
        let result = try await fixture.synchronize(targets: [target])

        let newID = fixture.remoteID(course: 1, file: 501, module: 150, filename: "es.txt")
        #expect(fixture.upstream.downloadCount == 0)
        #expect(result.moved == 1)
        #expect(result.perCourse.first?.movedItems.first?.id == newID)
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "exercise")
        #expect(fixture.contents("Course 1/Lezioni/es.txt") == nil)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: newID)?.relativePath.value == "Course 1/Lab 0/Esercizi/es.txt")
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 500, filename: "es.txt")) == nil)
        #expect(try await fixture.changes().isEmpty)
    }

    @Test(arguments: [false, true])
    func aNewMaterialUsesANumberBesideAnUntrackedLocalFile(sameContents: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let path = "Course 1/Lezioni/0.txt"
        try fixture.write(sameContents ? "x" : "my file", to: path)
        let result = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(result.conflicts == 0)
        #expect(result.added == 100)
        #expect(fixture.contents(path) == (sameContents ? "x" : "my file"))
        #expect(fixture.contents("Course 1/Lezioni/0 (1).txt") == "x")
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 0))?.relativePath.value == "Course 1/Lezioni/0 (1).txt")
    }

    @Test func aModifiedReuploadUsesANumberBesideAnUntrackedLocalFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my solution", to: "Course 1/Lezioni/es.txt")
        try fixture.write("unrelated", to: "Course 1/Lab 0/Esercizi/es.txt")
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        let result = try await fixture.synchronize(targets: [target])
        #expect(result.conflicts == 0)
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "unrelated")
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es (1).txt") == "exercise")
        #expect(try await fixture.change(for: fixture.remoteID(course: 1, file: 500, filename: "es.txt"))?.targetPath?.value == "Course 1/Lab 0/Esercizi/es (1).txt")
    }

    @Test(arguments: ["missing", "directory", "symlink", "samePath", "edited"])
    func trashingAReuploadRequiresASeparateRegularTwin(_ state: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let hash = String(repeating: "f", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        try fixture.write("my solution", to: "Course 1/Lezioni/es.txt")
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let change = try #require(try await fixture.change(for: fixture.remoteID(course: 1, file: 500, filename: "es.txt")))
        let twinID = try #require(change.newRemoteID)
        let twin = try #require(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: twinID))
        let twinURL = fixture.root.appending(path: twin.relativePath.value)
        if state == "samePath" {
            try await fixture.database.upsertBaseline(rootID: fixture.rootID, baseline: Baseline(remoteID: twinID, relativePath: change.relativePath, sha256: twin.sha256, remoteRevision: twin.remoteRevision, courseID: twin.courseID, moduleID: twin.moduleID))
        } else if state == "edited" {
            try fixture.write("edited new copy", to: twin.relativePath.value)
        } else {
            try FileManager.default.removeItem(at: twinURL)
            if state == "directory" { try FileManager.default.createDirectory(at: twinURL, withIntermediateDirectories: false) }
            if state == "symlink" { try FileManager.default.createSymbolicLink(at: twinURL, withDestinationURL: fixture.root.appending(path: change.relativePath.value)) }
        }
        let outcome = try await fixture.resolve(change, .trash)
        #expect(outcome == (state == "edited" ? .done(nil) : .newCopyUnavailable))
        if state == "edited" {
            #expect(fixture.contents(twin.relativePath.value) == "edited new copy")
            #expect(fixture.trashedFiles() == ["es.txt"])
        } else {
            #expect(fixture.contents(change.relativePath.value) == "my solution")
            #expect(fixture.trashedFiles().isEmpty)
            #expect(try await fixture.change(for: change.remoteID) != nil)
        }
    }

    @Test func aLateArrivalDuringReuploadGetsANumberWithoutAdoptingTheArrival() async throws {
        let fixture = try await Fixture { root, _, destination in
            guard destination.value == "Course 1/Lab 0/Esercizi/es.txt" else { return }
            try FileManager.default.createDirectory(at: root.appending(path: destination.value).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("late arrival".utf8).write(to: root.appending(path: destination.value))
        }
        defer { fixture.remove() }
        let hash = String(repeating: "f", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        fixture.upstream.resetDownloadCount()
        let result = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(result.moved == 1 && result.conflicts == 0 && result.failures == 0)
        #expect(fixture.upstream.downloadCount == 0)
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "late arrival")
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es (1).txt") == "exercise")
        #expect(fixture.contents("Course 1/Lezioni/es.txt") == nil)
        #expect(try await fixture.database.detachedPaths(rootID: fixture.rootID).isEmpty)
        #expect(try await fixture.database.pendingRemoteMoves(rootID: fixture.rootID).isEmpty)
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "late arrival")
    }

    @Test(arguments: [false, true])
    func anAutomaticReuploadRecoversBeforeAndAfterItsRename(_ renamed: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let hash = String(repeating: "f", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let oldID = fixture.remoteID(course: 1, file: 500, filename: "es.txt")
        let baseline = try #require(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: oldID))
        let destination = try RelativePath("Course 1/Lab 0/Esercizi/es.txt")
        try FileManager.default.createDirectory(at: fixture.root.appending(path: destination.value).deletingLastPathComponent(), withIntermediateDirectories: true)
        try await fixture.database.beginRemoteMoves(rootID: fixture.rootID, [PendingRemoteMove(batchID: UUID(), remoteID: oldID, from: baseline.relativePath, to: destination, sha256: baseline.sha256, placement: RemotePlacement(sectionName: "Lab 0", moduleName: "Esercizi", isSingleFileResource: false))])
        if renamed {
            try FileManager.default.moveItem(at: fixture.root.appending(path: baseline.relativePath.value), to: fixture.root.appending(path: destination.value))
        } else {
            try fixture.write("unrelated late arrival", to: destination.value)
        }
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        fixture.upstream.resetDownloadCount()
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        let newID = fixture.remoteID(course: 1, file: 501, module: 150, filename: "es.txt")
        let adopted = try #require(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: newID))
        #expect(adopted.relativePath.value == (renamed ? destination.value : "Course 1/Lab 0/Esercizi/es (1).txt"))
        #expect(fixture.contents(adopted.relativePath.value) == "exercise")
        #expect(fixture.upstream.downloadCount == 0)
        #expect(try await fixture.database.pendingRemoteMoves(rootID: fixture.rootID).isEmpty)
        #expect(try await fixture.database.detachedPaths(rootID: fixture.rootID).isEmpty)
        if !renamed { #expect(fixture.contents(destination.value) == "unrelated late arrival") }
    }

    @Test(arguments: [false, true])
    func anUnusableDownloadParentFailsOnlyItsFiles(_ symlink: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let parent = fixture.root.appending(path: "Course 1/Lezioni")
        try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        if symlink {
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.trashDirectory)
        } else {
            try Data("user file".utf8).write(to: parent)
        }
        let result = try await fixture.synchronize(targets: [fixture.targets[0], fixture.targets[1]])
        #expect(result.added == 100 && result.failures == 100)
        #expect(fixture.contents("Course 2/Lezioni/0.txt") == "x")
        #expect(fixture.trashedFiles().isEmpty)
        if !symlink { #expect(fixture.contents("Course 1/Lezioni") == "user file") }
    }

    @Test(arguments: ["automatic", "manual", "reupload", "missing"])
    func aCaseRenamedParentStillAllowsRemoteFileMoves(_ mode: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "f", count: 40)
        fixture.upstream.addFile(course: 1, file: 500, filename: "unique.txt", value: "unique", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        if mode == "manual" { try fixture.write("my notes", to: "Course 1/Lezioni/0.txt") }
        if mode == "missing" { try FileManager.default.removeItem(at: fixture.root.appending(path: "Course 1/Lezioni/0.txt")) }
        try FileManager.default.moveItem(at: fixture.root.appending(path: "Course 1"), to: fixture.root.appending(path: "course 1"))
        guard FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1").path) else { return }
        fixture.upstream.resetDownloadCount()
        if mode == "reupload" {
            fixture.upstream.removeFile(course: 1, file: 500)
            fixture.upstream.addFile(course: 1, file: 501, filename: "renamed.txt", value: "unique", revision: "1", contentHash: hash)
        } else { fixture.upstream.setSection(course: 1, name: "Lab 1") }
        let result = try await fixture.synchronize(targets: [target])
        #expect(result.failures == 0 && result.conflicts == 0)
        #expect(fixture.upstream.downloadCount == (mode == "missing" ? 1 : 0))
        if mode == "manual" {
            let change = try #require(try await fixture.change(for: fixture.remoteID(course: 1, file: 0)))
            #expect(try await fixture.resolve(change, .moveMine) == .done(try RelativePath("Course 1/Lab 1/Lezioni/0.txt")))
            #expect(fixture.contents("course 1/Lab 1/Lezioni/0.txt") == "my notes")
        } else if mode == "reupload" {
            #expect(result.moved == 1)
            #expect(fixture.contents("course 1/Lezioni/renamed.txt") == "unique")
            #expect(fixture.contents("course 1/Lezioni/unique.txt") == nil)
        } else {
            #expect(result.moved == (mode == "missing" ? 100 : 101))
            #expect(fixture.contents("course 1/Lab 1/Lezioni/0.txt") == "x")
        }
        #expect(try await fixture.changes().isEmpty)
    }

    @Test func aCaseRenamedParentStillAcceptsNewDownloads() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.synchronize(targets: [fixture.targets[0]])
        try FileManager.default.moveItem(at: fixture.root.appending(path: "Course 1"), to: fixture.root.appending(path: "course 1"))
        guard FileManager.default.fileExists(atPath: fixture.root.appending(path: "Course 1").path) else { return }
        fixture.upstream.addFile(course: 1, file: 501, filename: "new.txt", value: "new", revision: "1")
        let result = try await fixture.synchronize(targets: [fixture.targets[0]])
        #expect(result.added == 1 && result.failures == 0)
        #expect(fixture.contents("course 1/Lezioni/new.txt") == "new")
    }

    @Test func aFailedReuploadDownloadCannotAuthorizeTrashingTheOnlyLocalCopy() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my solution", to: "Course 1/Lezioni/es.txt")
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        fixture.upstream.setStatus(course: 1, file: 501, status: 500)
        fixture.upstream.addFile(course: 1, file: 502, filename: "other.txt", value: "new", revision: "1")
        let result = try await fixture.synchronize(targets: [target])
        #expect(result.failures == 1 && result.added == 1)
        let change = try #require(try await fixture.change(for: fixture.remoteID(course: 1, file: 500, filename: "es.txt")))
        #expect(change.kind == .reuploaded)
        #expect(try await fixture.resolve(change, .trash) == .newCopyUnavailable)
        #expect(fixture.contents("Course 1/Lezioni/es.txt") == "my solution")
        #expect(fixture.trashedFiles().isEmpty)
        fixture.upstream.setStatus(course: 1, file: 501, status: 200)
        _ = try await fixture.synchronize(targets: [target])
        #expect(try await fixture.resolve(change, .trash) == .done(nil))
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "exercise")
    }

    @Test func anEditedFileUploadedAgainElsewhereCanReplaceTheNewCopy() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my solution", to: "Course 1/Lezioni/es.txt")
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)

        let result = try await fixture.synchronize(targets: [target])
        #expect(result.added == 1)
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "exercise")
        let change = try #require(try await fixture.change(for: fixture.remoteID(course: 1, file: 500, filename: "es.txt")))
        #expect(change.kind == .reuploaded)
        #expect(change.targetPath?.value == "Course 1/Lab 0/Esercizi/es.txt")
        _ = try await fixture.synchronize(targets: [target])
        #expect(try await fixture.changes().map(\.id) == [change.id])

        #expect(try await fixture.resolve(change, .replaceNewCopy) == .done(try RelativePath("Course 1/Lab 0/Esercizi/es.txt")))
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "my solution")
        #expect(fixture.contents("Course 1/Lezioni/es.txt") == nil)
        #expect(fixture.trashedFiles() == ["es.txt"])
        #expect(try await fixture.changes().isEmpty)

        // From now on the user's version is their edit of the new file.
        fixture.upstream.setFile(course: 1, file: 501, value: "exercise v2", revision: "2")
        let updated = try await fixture.synchronize(targets: [target])
        #expect(updated.conflicts == 1)
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "my solution")
    }

    @Test func anEditedNewCopyCannotBeReplacedOrTrashed() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my solution", to: "Course 1/Lezioni/es.txt")
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        let change = try #require(try await fixture.change(for: fixture.remoteID(course: 1, file: 500, filename: "es.txt")))
        try fixture.write("new copy edited too", to: "Course 1/Lab 0/Esercizi/es.txt")

        #expect(try await fixture.resolve(change, .replaceNewCopy) == .newCopyNotReplaceable)
        #expect(fixture.contents("Course 1/Lezioni/es.txt") == "my solution")
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "new copy edited too")
        #expect(fixture.trashedFiles().isEmpty)
        #expect(try await fixture.change(for: change.remoteID)?.id == change.id)
    }

    @Test func anEditAfterReuploadSelectionStaysInPlace() async throws {
        let fixture = try await Fixture { root, source, destination in
            guard source.value == "Course 1/Lezioni/es.txt", destination.value == "Course 1/Lab 0/Esercizi/es.txt" else { return }
            let handle = try FileHandle(forWritingTo: root.appending(path: source.value))
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("late solution".utf8))
            try handle.close()
        }
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        let id = fixture.remoteID(course: 1, file: 500, filename: "es.txt")
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        #expect(fixture.contents("Course 1/Lezioni/es.txt") == "late solution")
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "exercise")
        #expect(try await fixture.change(for: id)?.kind == .removed)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: id)?.relativePath.value == "Course 1/Lezioni/es.txt")
    }

    @Test(arguments: [false, true])
    func aDestinationTakenAfterSelectionGetsANumber(manual: Bool) async throws {
        let fixture = try await Fixture { root, _, destination in
            guard destination.value == "Course 1/Lab 1/Lezioni/0.txt" else { return }
            let url = root.appending(path: destination.value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("late arrival".utf8).write(to: url)
        }
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        if manual { try fixture.write("my notes", to: "Course 1/Lezioni/0.txt") }
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        let result = try await fixture.synchronize(targets: [target])
        let numbered = try RelativePath("Course 1/Lab 1/Lezioni/0 (1).txt")
        if manual {
            let change = try #require(try await fixture.change(for: id))
            #expect(try await fixture.resolve(change, .moveMine) == .done(numbered))
        } else {
            #expect(result.moved == 100)
        }
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == "late arrival")
        #expect(fixture.contents(numbered.value) == (manual ? "my notes" : "x"))
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == nil)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: id)?.relativePath == numbered)
        #expect(try await fixture.database.pendingRemoteMoves(rootID: fixture.rootID).isEmpty)
    }

    @Test func anEditAfterAutomaticMoveSelectionStaysInPlace() async throws {
        let fixture = try await Fixture { root, source, destination in
            guard destination.value == "Course 1/Lab 1/Lezioni/0.txt" else { return }
            let handle = try FileHandle(forWritingTo: root.appending(path: source.value))
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("late notes".utf8))
            try handle.close()
        }
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        let result = try await fixture.synchronize(targets: [target])
        #expect(result.moved == 99)
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "late notes")
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == nil)
        #expect(try await fixture.database.pendingRemoteMoves(rootID: fixture.rootID).isEmpty)
        _ = try await fixture.synchronize(targets: [target])
        #expect(try await fixture.change(for: id)?.kind == .moved)
    }

    @Test(arguments: ["section", "module", "type", "nullSection", "nullModule", "nullType", "unknownType"])
    func incompleteListingsPreserveRemovalDecisionsAndTrackedFiles(missing: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        fixture.upstream.removeFile(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        let change = try #require(try await fixture.change(for: id))
        fixture.upstream.omitListingField(course: 1, field: missing)
        fixture.upstream.removeFile(course: 1, file: 1)

        _ = try await fixture.synchronize(targets: [target])

        #expect(try await fixture.changes().map(\.id) == [change.id])
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == "x")
        #expect(fixture.contents("Course 1/Lezioni/1.txt") == "x")
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 1)) != nil)
        fixture.upstream.omitListingField(course: 1, field: nil)
        _ = try await fixture.synchronize(targets: [target])
        #expect(try await fixture.changes().count == 2)
    }

    @Test(arguments: [false, true])
    func replacingNewCopyPreservesFilesChangedWhileTrashing(destinationTaken: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        let oldPath = "Course 1/Lezioni/es.txt"
        let newPath = "Course 1/Lab 0/Esercizi/es.txt"
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my solution", to: oldPath)
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        let change = try #require(try await fixture.change(for: fixture.remoteID(course: 1, file: 500, filename: "es.txt")))
        let root = fixture.root
        let trash = fixture.trashDirectory
        let store = try FileStore(root: root) { url in
            guard url == root.appending(path: newPath),
                  try String(contentsOf: url, encoding: .utf8) == "exercise" else { throw FileStoreError.ioFailure }
            if !destinationTaken {
            let handle = try FileHandle(forWritingTo: root.appending(path: oldPath))
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("newer solution".utf8))
            try handle.close()
            }
            try FileManager.default.moveItem(at: url, to: trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
            if destinationTaken { try Data("late arrival".utf8).write(to: url) }
        }
        let resolver = RemoteChangeResolver(database: fixture.database, fileStore: store, gate: fixture.gate)

        #expect(try await resolver.perform(.replaceNewCopy, on: change.id, rootID: fixture.rootID) == (destinationTaken ? .newCopyNotReplaceable : .fileChanged))
        #expect(fixture.contents(oldPath) == (destinationTaken ? "my solution" : "newer solution"))
        #expect(fixture.contents(newPath) == (destinationTaken ? "late arrival" : nil))
        #expect(fixture.trashedFiles() == ["es.txt"])
        #expect(try await fixture.change(for: change.remoteID)?.id == change.id)
        _ = try await fixture.synchronize(targets: [target])
        #expect(fixture.contents(oldPath) == (destinationTaken ? "my solution" : "newer solution"))
        #expect(fixture.contents(newPath) == (destinationTaken ? "late arrival" : "exercise"))
    }

    @Test(arguments: [false, true])
    func aFileUploadedAgainInTheSamePlaceKeepsItsCopy(edited: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        if edited { try fixture.write("my solution", to: "Course 1/Lezioni/es.txt") }
        // The teacher deleted the module and made a new one with the same name, in the same section.
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addModule(course: 1, id: 150, section: "Materiali", name: "Lezioni")
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)

        fixture.upstream.resetDownloadCount()
        let result = try await fixture.synchronize(targets: [target])

        #expect(fixture.upstream.downloadCount == 0)
        #expect(result.conflicts == 0 && result.moved == 0)
        #expect(fixture.contents("Course 1/Lezioni/es.txt") == (edited ? "my solution" : "exercise"))
        #expect(fixture.contents("Course 1/Lezioni/es (1).txt") == nil)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 501, module: 150, filename: "es.txt"))?.relativePath.value == "Course 1/Lezioni/es.txt")
        #expect(try await fixture.changes().isEmpty)
    }

    @Test func keepBothLeavesBothCopies() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let hash = String(repeating: "c", count: 40)
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 0", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 500, filename: "es.txt", value: "exercise", revision: "1", contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my solution", to: "Course 1/Lezioni/es.txt")
        fixture.upstream.removeFile(course: 1, file: 500)
        fixture.upstream.addFile(course: 1, file: 501, filename: "es.txt", value: "exercise", revision: "1", module: 150, contentHash: hash)
        _ = try await fixture.synchronize(targets: [target])
        let change = try #require(try await fixture.changes().first)

        #expect(try await fixture.resolve(change, .keepBoth) == .done(nil))
        _ = try await fixture.synchronize(targets: [target])

        #expect(fixture.contents("Course 1/Lezioni/es.txt") == "my solution")
        #expect(fixture.contents("Course 1/Lab 0/Esercizi/es.txt") == "exercise")
        #expect(try await fixture.changes().isEmpty)
    }

    @Test func filesWhoseSectionsSwappedNamesTradePlacesWithoutNumbers() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 1", name: "Esercizi")
        fixture.upstream.addModule(course: 1, id: 160, section: "Lab 2", name: "Esercizi")
        fixture.upstream.addModule(course: 1, id: 170, section: "Lab 3", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 600, filename: "testo.txt", value: "one", revision: "1", module: 150, contentHash: String(repeating: "d", count: 40))
        fixture.upstream.addFile(course: 1, file: 601, filename: "testo.txt", value: "two", revision: "1", module: 160, contentHash: String(repeating: "e", count: 40))
        fixture.upstream.addFile(course: 1, file: 602, filename: "testo.txt", value: "three", revision: "1", module: 170, contentHash: String(repeating: "f", count: 40))
        _ = try await fixture.synchronize(targets: [target])

        // Two sections swapped, and three rotated.
        fixture.upstream.setModuleSection(course: 1, id: 150, section: "Lab 2")
        fixture.upstream.setModuleSection(course: 1, id: 160, section: "Lab 3")
        fixture.upstream.setModuleSection(course: 1, id: 170, section: "Lab 1")
        fixture.upstream.resetDownloadCount()
        let result = try await fixture.synchronize(targets: [target])

        #expect(fixture.upstream.downloadCount == 0)
        #expect(result.moved == 3)
        #expect(fixture.contents("Course 1/Lab 2/Esercizi/testo.txt") == "one")
        #expect(fixture.contents("Course 1/Lab 3/Esercizi/testo.txt") == "two")
        #expect(fixture.contents("Course 1/Lab 1/Esercizi/testo.txt") == "three")
        for lab in 1...3 { #expect(fixture.contents("Course 1/Lab \(lab)/Esercizi/testo (1).txt") == nil) }
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: fixture.remoteID(course: 1, file: 600, module: 150, filename: "testo.txt"))?.relativePath.value == "Course 1/Lab 2/Esercizi/testo.txt")
        #expect(try await fixture.database.pendingRemoteMoves(rootID: fixture.rootID).isEmpty)

        let again = try await fixture.synchronize(targets: [target])
        #expect(again.perCourse.isEmpty)
    }

    @Test func aDeletedFileInASwapIsDownloadedAtItsOwnName() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 1", name: "Esercizi")
        fixture.upstream.addModule(course: 1, id: 160, section: "Lab 2", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 600, filename: "testo.txt", value: "one", revision: "1", module: 150, contentHash: String(repeating: "d", count: 40))
        fixture.upstream.addFile(course: 1, file: 601, filename: "testo.txt", value: "two", revision: "1", module: 160, contentHash: String(repeating: "e", count: 40))
        _ = try await fixture.synchronize(targets: [target])
        try FileManager.default.removeItem(at: fixture.root.appending(path: "Course 1/Lab 1/Esercizi/testo.txt"))

        fixture.upstream.setModuleSection(course: 1, id: 150, section: "Lab 2")
        fixture.upstream.setModuleSection(course: 1, id: 160, section: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])

        #expect(fixture.contents("Course 1/Lab 1/Esercizi/testo.txt") == "two")
        #expect(fixture.contents("Course 1/Lab 2/Esercizi/testo.txt") == "one")
        #expect(fixture.contents("Course 1/Lab 2/Esercizi/testo (1).txt") == nil)
    }

    @Test func aSwapInterruptedBeforeItsBaselinesFollowIsCompleted() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        fixture.upstream.addModule(course: 1, id: 150, section: "Lab 1", name: "Esercizi")
        fixture.upstream.addModule(course: 1, id: 160, section: "Lab 2", name: "Esercizi")
        fixture.upstream.addFile(course: 1, file: 600, filename: "testo.txt", value: "one", revision: "1", module: 150, contentHash: String(repeating: "d", count: 40))
        fixture.upstream.addFile(course: 1, file: 601, filename: "testo.txt", value: "two", revision: "1", module: 160, contentHash: String(repeating: "e", count: 40))
        _ = try await fixture.synchronize(targets: [target])
        let one = fixture.remoteID(course: 1, file: 600, module: 150, filename: "testo.txt")
        let two = fixture.remoteID(course: 1, file: 601, module: 160, filename: "testo.txt")
        let lab1 = try RelativePath("Course 1/Lab 1/Esercizi/testo.txt")
        let lab2 = try RelativePath("Course 1/Lab 2/Esercizi/testo.txt")
        let oneSHA = try #require(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: one)).sha256
        let twoSHA = try #require(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: two)).sha256
        // The swap was journaled and done, then the app stopped before the baselines followed.
        let batch = UUID()
        try await fixture.database.beginRemoteMoves(rootID: fixture.rootID, [
            PendingRemoteMove(batchID: batch, remoteID: one, from: lab1, to: lab2, sha256: oneSHA, placement: RemotePlacement(sectionName: "Lab 2", moduleName: "Esercizi", isSingleFileResource: false)),
            PendingRemoteMove(batchID: batch, remoteID: two, from: lab2, to: lab1, sha256: twoSHA, placement: RemotePlacement(sectionName: "Lab 1", moduleName: "Esercizi", isSingleFileResource: false)),
        ])
        try fixture.write("two", to: lab1.value)
        try fixture.write("one", to: lab2.value)
        fixture.upstream.setModuleSection(course: 1, id: 150, section: "Lab 2")
        fixture.upstream.setModuleSection(course: 1, id: 160, section: "Lab 1")

        fixture.upstream.resetDownloadCount()
        let result = try await fixture.synchronize(targets: [target])

        #expect(fixture.upstream.downloadCount == 0 && result.conflicts == 0)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: one)?.relativePath == lab2)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: two)?.relativePath == lab1)
        #expect(try await fixture.changes().isEmpty)
    }

    @Test func aNumberedMoveInterruptedAfterTheRenameIsCompleted() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("someone else's file", to: "Course 1/Lab 1/Lezioni/0.txt")
        let old = try RelativePath("Course 1/Lezioni/0.txt")
        let numbered = try RelativePath("Course 1/Lab 1/Lezioni/0 (1).txt")
        let sha = try #require(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: id)).sha256
        try await fixture.database.beginRemoteMoves(rootID: fixture.rootID, [PendingRemoteMove(batchID: UUID(), remoteID: id, from: old, to: numbered, sha256: sha, placement: RemotePlacement(sectionName: "Lab 1", moduleName: "Lezioni", isSingleFileResource: false))])
        try FileManager.default.moveItem(at: fixture.root.appending(path: old.value), to: fixture.root.appending(path: numbered.value))
        fixture.upstream.setSection(course: 1, name: "Lab 1")

        fixture.upstream.resetDownloadCount()
        _ = try await fixture.synchronize(targets: [target])

        #expect(fixture.upstream.downloadCount == 0)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: id)?.relativePath == numbered)
        #expect(fixture.contents("Course 1/Lab 1/Lezioni/0.txt") == "someone else's file")
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == nil)
    }

    @Test func movingMyVersionInterruptedAfterTheRenameIsCompleted() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.targets[0]
        let id = fixture.remoteID(course: 1, file: 0)
        _ = try await fixture.synchronize(targets: [target])
        try fixture.write("my notes", to: "Course 1/Lezioni/0.txt")
        fixture.upstream.setSection(course: 1, name: "Lab 1")
        _ = try await fixture.synchronize(targets: [target])
        let change = try #require(try await fixture.change(for: id))
        let destination = try #require(change.targetPath)
        try await fixture.database.beginRemoteMoves(rootID: fixture.rootID, [PendingRemoteMove(batchID: UUID(), remoteID: id, from: change.relativePath, to: destination, sha256: change.localSHA256, placement: change.placement)])
        try FileManager.default.moveItem(at: fixture.root.appending(path: change.relativePath.value), to: fixture.root.appending(path: destination.value))

        fixture.upstream.resetDownloadCount()
        _ = try await fixture.synchronize(targets: [target])

        #expect(fixture.upstream.downloadCount == 0)
        #expect(try await fixture.database.baseline(rootID: fixture.rootID, remoteID: id)?.relativePath == destination)
        #expect(fixture.contents(destination.value) == "my notes")
        #expect(fixture.contents("Course 1/Lezioni/0.txt") == nil)
        #expect(try await fixture.changes().isEmpty)
    }

private final class Fixture: @unchecked Sendable {
        let root: URL
        // The real app keeps the database in Application Support, outside the sync folder, so a
        // deleted sync folder must leave it intact. Keep the fixture's layout the same.
        let supportDirectory: URL
        /// Stands in for the macOS Trash, so tests never touch the user's.
        let trashDirectory: URL
        let rootID = UUID()
        let database: SyncDatabase
        let upstream = MutableFixtureUpstream()
        let policy = WeBeepServerPolicy(endpoint: URL(string: "https://fixture.beepbar.test/webservice/rest/server.php")!, siteURL: URL(string: "https://fixture.beepbar.test")!, scheme: "https", host: "fixture.beepbar.test", port: 443)
        let gate = RootOperationGate()
        let targets = (1...10).map { SyncTarget(courseID: Int64($0), localFolder: "Course \($0)") }
        let coordinator: SyncCoordinator
        let fileStore: FileStore

        init(beforeMove: (@Sendable (URL, RelativePath, RelativePath) throws -> Void)? = nil) async throws {
            let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            root = container.appending(path: "Sync", directoryHint: .isDirectory)
            supportDirectory = container.appending(path: "Support", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let trash = container.appending(path: "Trash", directoryHint: .isDirectory)
            trashDirectory = trash
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            database = try SyncDatabase(url: supportDirectory.appending(path: "state.sqlite"))
            FixtureURLProtocol.upstream = upstream
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let client = WeBeepAPIClient(policy: policy, session: session)
            let downloader = RemoteDownloader(session: session, policy: policy)
            let syncRoot = root
            fileStore = try FileStore(root: root, beforeMove: { source, destination in
                try beforeMove?(syncRoot, source, destination)
            }) { url in
                try FileManager.default.moveItem(at: url, to: trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
            }
            coordinator = try SyncCoordinator(rootID: rootID, rootURL: root, database: database, gate: gate, apiClient: client, downloader: downloader, fileStore: fileStore)
            try await database.registerRoot(id: rootID, canonicalPath: root.path)
            for target in targets {
                try await database.upsertScope(SyncScope(rootID: rootID, courseID: target.courseID, displayName: target.localFolder, localFolder: target.localFolder, enabled: true))
            }
            upstream.populate(courses: 10, filesPerCourse: 100)
        }

        func synchronize(targets: [SyncTarget]? = nil, mode: SyncCoordinatorMode = .manual, networkAccess: NetworkAccess = .unrestricted) async throws -> SyncProgress {
            try await coordinator.synchronize(targets: targets ?? self.targets, token: "test-token", mode: mode, networkAccess: networkAccess) { _ in }
        }

        func remoteID(course: Int64, file: Int, module: Int64? = nil, filename: String? = nil) -> String { "\(course):\(module ?? course * 100):/:\(filename ?? "\(file).txt")" }

        func changes() async throws -> [RemoteChange] { try await database.remoteChanges(rootID: rootID) }

        func change(for remoteID: String) async throws -> RemoteChange? { try await changes().first { $0.remoteID == remoteID } }

        func resolve(_ change: RemoteChange, _ action: RemoteChangeAction) async throws -> RemoteChangeOutcome {
            try await RemoteChangeResolver(database: database, fileStore: fileStore, gate: gate).perform(action, on: change.id, rootID: rootID)
        }

        func trashedFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: trashDirectory.path)) ?? []).map { String($0.split(separator: "-").last ?? "") }
        }

        func contents(_ path: String) -> String? {
            (try? Data(contentsOf: root.appending(path: path))).flatMap { String(data: $0, encoding: .utf8) }
        }

        func write(_ value: String, to path: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        func legacyRemoteID(course: Int64, file: Int) -> String { "\(course):\(course * 100):/webservice/pluginfile.php/\(course)/\(file).txt" }

        func stagingFiles() -> [URL] {
            let staging = root.appending(path: ".beepbar/staging", directoryHint: .isDirectory)
            return (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        }

        func remove() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SyncProgress] = []

    func append(_ update: SyncProgress) { lock.withLock { storage.append(update) } }
    var values: [SyncProgress] { lock.withLock { storage } }
}

private struct RecordedNetworkAccess: Hashable {
    let expensive: Bool
    let constrained: Bool
}

private final class MutableFixtureUpstream: @unchecked Sendable {
    private struct File { var value: Data; var revision: String; var status = 200; var filename: String? = nil; var module: Int64? = nil; var contentHash: String? = nil }
    private let lock = NSLock()
    private var files: [Int64: [Int: File]] = [:]
    private var downloads = 0
    private var activeDownloads = 0
    private var peakDownloads = 0
    private var validations = 0
    private var rejectedContents: [Int64: String] = [:]
    private var failedContents: [Int64: Int] = [:]
    private var networkAccess: Set<RecordedNetworkAccess> = []
    private var contentsRequests = 0
    private var contentsAccess: Set<RecordedNetworkAccess> = []
    private var validationAccess: Set<RecordedNetworkAccess> = []
    private var sectionNames: [Int64: String] = [:]
    private var moduleNames: [Int64: String] = [:]
    private var extraModules: [Int64: [Int64: (section: String, name: String)]] = [:]
    private var malformedEntries: Set<Int64> = []
    private var omittedListingFields: [Int64: String] = [:]
    var downloadDelay: TimeInterval = 0
    var tokenIsValid = true

    var downloadCount: Int { lock.withLock { downloads } }
    var maximumActiveDownloads: Int { lock.withLock { peakDownloads } }
    var validationCount: Int { lock.withLock { validations } }
    var downloadNetworkAccess: Set<RecordedNetworkAccess> { lock.withLock { networkAccess } }
    /// `core_course_get_contents` requests and the network restrictions they carried.
    var contentsRequestCount: Int { lock.withLock { contentsRequests } }
    var contentsNetworkAccess: Set<RecordedNetworkAccess> { lock.withLock { contentsAccess } }
    /// The network restrictions the token checks (`core_webservice_get_site_info`) carried.
    var validationNetworkAccess: Set<RecordedNetworkAccess> { lock.withLock { validationAccess } }
    func resetDownloadCount() { lock.withLock { downloads = 0 } }

    func populate(courses: Int, filesPerCourse: Int) {
        lock.withLock {
            files = Dictionary(uniqueKeysWithValues: (1...courses).map { course in
                (Int64(course), Dictionary(uniqueKeysWithValues: (0..<filesPerCourse).map { index in (index, File(value: Data("x".utf8), revision: "1")) }))
            })
        }
    }

    func setFile(course: Int64, file: Int, value: String, revision: String) {
        lock.withLock {
            let existing = files[course]?[file]
            files[course]?[file] = File(value: Data(value.utf8), revision: revision, status: existing?.status ?? 200, filename: existing?.filename, module: existing?.module)
        }
    }
    /// Moves the course's only module to a section with this name, as a teacher dragging it on Moodle does.
    func setSection(course: Int64, name: String) { lock.withLock { sectionNames[course] = name } }
    func setModuleName(course: Int64, name: String) { lock.withLock { moduleNames[course] = name } }
    func rejectContents(course: Int64, errorCode: String = "requireloginerror") { lock.withLock { rejectedContents[course] = errorCode } }
    func failContents(course: Int64, status: Int) { lock.withLock { failedContents[course] = status } }
    func setStatus(course: Int64, file: Int, status: Int) { lock.withLock { guard var value = files[course]?[file] else { return }; value.status = status; files[course]?[file] = value } }
    func addFile(course: Int64, file: Int, filename: String, value: String, revision: String, module: Int64? = nil, contentHash: String? = nil) {
        lock.withLock { files[course, default: [:]][file] = File(value: Data(value.utf8), revision: revision, filename: filename, module: module, contentHash: contentHash) }
    }
    /// Takes the file off Moodle, as a teacher deleting it does.
    func removeFile(course: Int64, file: Int) { lock.withLock { _ = files[course]?.removeValue(forKey: file) } }
    /// Adds a module of its own section; files join it with `addFile(module:)` or `setModule`.
    func addModule(course: Int64, id: Int64, section: String, name: String) { lock.withLock { extraModules[course, default: [:]][id] = (section, name) } }
    func setModuleSection(course: Int64, id: Int64, section: String) { lock.withLock { extraModules[course]?[id]?.section = section } }
    func setModule(course: Int64, file: Int, module: Int64) { lock.withLock { files[course]?[file]?.module = module } }
    func setContentHash(course: Int64, file: Int, hash: String) { lock.withLock { files[course]?[file]?.contentHash = hash } }
    /// Adds an entry Moodle sends but the client cannot read to the course's default module.
    func addMalformedEntry(course: Int64) { lock.withLock { _ = malformedEntries.insert(course) } }

    func omitListingField(course: Int64, field: String?) { lock.withLock { omittedListingFields[course] = field } }

    func response(for request: URLRequest) -> (HTTPURLResponse, Data, TimeInterval, Bool) {
        lock.withLock {
            let url = request.url!
            if request.httpMethod == "POST" {
                let body = String(data: request.httpBody ?? bodyData(from: request.httpBodyStream), encoding: .utf8) ?? ""
                if formValue("wsfunction", body: body) == "core_webservice_get_site_info" {
                    validations += 1
                    validationAccess.insert(RecordedNetworkAccess(expensive: request.allowsExpensiveNetworkAccess, constrained: request.allowsConstrainedNetworkAccess))
                    let response: Data
                    if tokenIsValid {
                        response = Data(#"{"userid":7,"siteurl":"https://fixture.beepbar.test","functions":[{"name":"core_enrol_get_users_courses"},{"name":"core_course_get_contents"}]}"#.utf8)
                    } else {
                        response = Data(#"{"exception":"invalidtoken","errorcode":"invalidtoken"}"#.utf8)
                    }
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, response, 0, false)
                }
                let course = Int64(formValue("courseid", body: body) ?? "") ?? 0
                if formValue("wsfunction", body: body) == "core_course_get_contents" {
                    contentsRequests += 1
                    contentsAccess.insert(RecordedNetworkAccess(expensive: request.allowsExpensiveNetworkAccess, constrained: request.allowsConstrainedNetworkAccess))
                }
                if let status = failedContents[course] {
                    return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, Data(), 0, false)
                }
                let response = rejectedContents[course].map { Data(#"{"exception":"moodle_exception","errorcode":"\#($0)","message":"Refused."}"#.utf8) }
                    ?? contents(course: course)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, response, 0, false)
            }
            let parts = url.path.split(separator: "/")
            guard parts.count >= 4, let course = Int64(parts[2]), let index = Int(parts[3].split(separator: ".")[0]), let file = files[course]?[index] else {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Length": "0"])!, Data(), 0, true)
            }
            downloads += 1
            networkAccess.insert(RecordedNetworkAccess(expensive: request.allowsExpensiveNetworkAccess, constrained: request.allowsConstrainedNetworkAccess))
            activeDownloads += 1
            peakDownloads = max(peakDownloads, activeDownloads)
            return (HTTPURLResponse(url: url, statusCode: file.status, httpVersion: nil, headerFields: ["Content-Length": "\(file.value.count)"])!, file.value, downloadDelay, true)
        }
    }

    func finishDownload() { lock.withLock { activeDownloads = max(0, activeDownloads - 1) } }

    private func contents(course: Int64) -> Data {
        let values = files[course] ?? [:]
        func entries(module: Int64) -> [[String: Any]] {
            var result: [[String: Any]] = values.keys.sorted().compactMap { index in
                guard let file = values[index], (file.module ?? course * 100) == module else { return nil }
                let contentHash = file.contentHash ?? String(repeating: file.revision == "1" ? "a" : "b", count: 40)
                return ["type": "file", "filename": file.filename ?? "\(index).txt", "filepath": "/", "filesize": file.value.count, "timemodified": 1, "contenthash": contentHash, "fileurl": "https://fixture.beepbar.test/webservice/pluginfile.php/\(course)/\(index).txt"]
            }
            if module == course * 100, malformedEntries.contains(course) {
                result.append(["type": "file", "filename": "unreadable.txt", "filepath": "/"])
            }
            return result
        }
        var sections: [[String: Any]] = [["id": course, "name": sectionNames[course] ?? "Materiali", "modules": [["id": course * 100, "name": moduleNames[course] ?? "Lezioni", "modname": "folder", "contents": entries(module: course * 100)]]]]
        for (id, module) in (extraModules[course] ?? [:]).sorted(by: { $0.key < $1.key }) {
            sections.append(["id": id, "name": module.section, "modules": [["id": id, "name": module.name, "modname": "folder", "contents": entries(module: id)]]])
        }
        switch omittedListingFields[course] {
        case "section": sections[0].removeValue(forKey: "modules")
        case "nullSection": sections[0]["modules"] = NSNull()
        case "nullModule":
            var modules = sections[0]["modules"] as! [[String: Any]]
            modules[0]["contents"] = NSNull()
            sections[0]["modules"] = modules
        case "module":
            var modules = sections[0]["modules"] as! [[String: Any]]
            modules[0].removeValue(forKey: "contents")
            sections[0]["modules"] = modules
        case "type", "nullType", "unknownType":
            var modules = sections[0]["modules"] as! [[String: Any]]
            var entry: [String: Any] = ["filename": "unreadable.txt"]
            if omittedListingFields[course] == "nullType" { entry["type"] = NSNull() }
            if omittedListingFields[course] == "unknownType" { entry["type"] = "unknown-future-type" }
            modules[0]["contents"] = [entry]
            sections[0]["modules"] = modules
        default: break
        }
        return try! JSONSerialization.data(withJSONObject: sections)
    }

    private func formValue(_ name: String, body: String) -> String? {
        body.split(separator: "&").first { $0.hasPrefix("\(name)=") }.flatMap { String($0.dropFirst(name.count + 1)).removingPercentEncoding }
    }

    private func bodyData(from stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var upstream: MutableFixtureUpstream!
    private var workItem: DispatchWorkItem?
    private let completionLock = NSLock()
    private var isDownload = false
    private var downloadFinished = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, data, delay, isDownload) = Self.upstream.response(for: request)
        self.isDownload = isDownload
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if delay > 0, !data.isEmpty {
                let split = max(1, data.count / 2)
                self.client?.urlProtocol(self, didLoad: data.prefix(split))
                // `URLProtocol` is not `Sendable` on Linux's Foundation, so the class's own
                // `@unchecked Sendable` does not reach this closure there.
                nonisolated(unsafe) weak var pending = self
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    guard let self = pending else { return }
                    guard self.workItem?.isCancelled != true else { self.finishDownloadIfNeeded(); return }
                    self.client?.urlProtocol(self, didLoad: data.dropFirst(split))
                    self.client?.urlProtocolDidFinishLoading(self)
                    self.finishDownloadIfNeeded()
                }
                return
            }
            if !data.isEmpty { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
            self.finishDownloadIfNeeded()
        }
        workItem = item
        item.perform()
    }

    override func stopLoading() {
        workItem?.cancel()
        finishDownloadIfNeeded()
    }

    private func finishDownloadIfNeeded() {
        completionLock.withLock {
            guard isDownload, !downloadFinished else { return }
            downloadFinished = true
            Self.upstream.finishDownload()
        }
    }
}
