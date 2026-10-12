import Foundation
#if canImport(os)
import os
#endif
import Testing
@testable import BeepbarCore

/// The saved course list (#98): what the window may show before the network answers. Each test
/// guards one acceptance rule of the issue: a foreign, old, oversized or corrupt file is never
/// shown, the file never carries the token, an unchanged list costs no write, and a save that
/// arrives after a sign-out never writes the old account's list back.
struct CourseListSnapshotTests {
    private static let rootID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let identity = CourseListSnapshot.Identity(siteID: "polimi", rootID: Self.rootID, token: "token-a")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func courses(_ count: Int) -> [RemoteCourseSummary] {
        (1...count).map { RemoteCourseSummary(id: Int64($0), shortName: "C\($0)", displayName: "Course \($0)", isVisible: $0 % 2 == 0, startDate: $0 == 1 ? now : nil, endDate: nil) }
    }

    // MARK: Codec

    @Test func roundTripKeepsEveryCourseField() throws {
        let snapshot = CourseListSnapshot(identity: identity, savedAt: now, courses: courses(3))
        let data = try CourseListSnapshotCodec.encode(snapshot)
        let decoded = try CourseListSnapshotCodec.decode(data, expecting: identity, now: now)
        #expect(decoded == snapshot)
        #expect(decoded.summaries == courses(3))
        #expect(decoded.version == CourseListSnapshotCodec.currentVersion)
    }

    /// Account A's list must never be shown after another sign-in (account B, or A signing in
    /// again with a new token), on another site, or for another sync folder: each part of the
    /// identity on its own refuses the file.
    @Test func foreignIdentityIsRejected() throws {
        let data = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(1)))
        let others = [
            CourseListSnapshot.Identity(siteID: "polimi", rootID: Self.rootID, token: "token-b"),
            CourseListSnapshot.Identity(siteID: "unipd-math", rootID: Self.rootID, token: "token-a"),
            CourseListSnapshot.Identity(siteID: "polimi", rootID: UUID(), token: "token-a"),
        ]
        for other in others {
            #expect(throws: CourseListSnapshotCodec.DecodeError.wrongIdentity) {
                try CourseListSnapshotCodec.decode(data, expecting: other, now: now)
            }
        }
        #expect(throws: Never.self) {
            try CourseListSnapshotCodec.decode(data, expecting: CourseListSnapshot.Identity(siteID: "polimi", rootID: Self.rootID, token: "token-a"), now: now)
        }
    }

    /// The fingerprint names a sign-in without carrying it: stable for one token and site,
    /// different for another token or another site, and never the token or a prefix of it.
    @Test func credentialFingerprintIsStableOneWayAndSiteBound() {
        let token = "0123456789abcdef0123456789abcdef"
        let fingerprint = CourseListSnapshot.credentialFingerprint(token: token, siteID: "polimi")
        #expect(fingerprint == CourseListSnapshot.credentialFingerprint(token: token, siteID: "polimi"))
        #expect(fingerprint != CourseListSnapshot.credentialFingerprint(token: token + "0", siteID: "polimi"))
        #expect(fingerprint != CourseListSnapshot.credentialFingerprint(token: token, siteID: "unipd-math"))
        #expect(fingerprint.count == 64)
        #expect(fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(!fingerprint.contains(token))
        #expect(!fingerprint.contains(token.prefix(8)))
    }

    /// The age limit is explicit: a list confirmed within the limit is shown, one past it is not,
    /// and a date in the future (clock moved back) still counts as the last confirmed list.
    @Test func ageLimitIsEnforcedOnDecode() throws {
        let data = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(1)))
        let justInside = now.addingTimeInterval(CourseListSnapshotCodec.maximumAge)
        #expect(throws: Never.self) { try CourseListSnapshotCodec.decode(data, expecting: identity, now: justInside) }
        #expect(throws: CourseListSnapshotCodec.DecodeError.expired) {
            try CourseListSnapshotCodec.decode(data, expecting: identity, now: justInside.addingTimeInterval(1))
        }
        #expect(throws: Never.self) { try CourseListSnapshotCodec.decode(data, expecting: identity, now: now.addingTimeInterval(-86_400)) }
        #expect(CourseListSnapshotCodec.maximumAge == 30 * 86_400)
    }

    /// A file from a future BeepBar, or a damaged one, is refused as such rather than half read.
    @Test func unsupportedVersionAndGarbageAreRejected() throws {
        var object = try JSONSerialization.jsonObject(with: CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(1)))) as! [String: Any]
        object["version"] = CourseListSnapshotCodec.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CourseListSnapshotCodec.DecodeError.unsupportedVersion(CourseListSnapshotCodec.currentVersion + 1)) {
            try CourseListSnapshotCodec.decode(newer, expecting: identity, now: now)
        }
        #expect(throws: CourseListSnapshotCodec.DecodeError.unreadable) {
            try CourseListSnapshotCodec.decode(Data("not json".utf8), expecting: identity, now: now)
        }
        // Right version, wrong shape: still unreadable, not a crash and not an empty list.
        #expect(throws: CourseListSnapshotCodec.DecodeError.unreadable) {
            try CourseListSnapshotCodec.decode(Data(#"{"version":\#(CourseListSnapshotCodec.currentVersion),"courses":"x"}"#.utf8), expecting: identity, now: now)
        }
    }

    /// The size and count limits are explicit and hold on both sides: a list over the count limit
    /// is never written, and a file over either limit is refused before it is used.
    @Test func sizeAndCountLimitsHoldOnBothSides() throws {
        #expect(CourseListSnapshotCodec.maximumCourses == 500)
        #expect(CourseListSnapshotCodec.maximumBytes == 1_048_576)
        #expect(throws: Never.self) { try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(500))) }
        #expect(throws: CourseListSnapshotCodec.EncodeError.tooManyCourses) {
            try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(501)))
        }
        // A hand-made file over the count limit: the count is checked, not only the byte size.
        let tooMany = CourseListSnapshot(identity: identity, savedAt: now, courses: courses(501))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        #expect(throws: CourseListSnapshotCodec.DecodeError.tooManyCourses) {
            try CourseListSnapshotCodec.decode(try encoder.encode(tooMany), expecting: identity, now: now)
        }
        let oversized = Data(repeating: UInt8(ascii: " "), count: CourseListSnapshotCodec.maximumBytes + 1)
        #expect(throws: CourseListSnapshotCodec.DecodeError.tooLarge) {
            try CourseListSnapshotCodec.decode(oversized, expecting: identity, now: now)
        }
    }

    /// The file holds names, ids and dates only: no token, no folder, no selection, no Moodle
    /// user id. Pinned by the exact key set so a field added by mistake fails here before it ships.
    @Test func fileCarriesOnlyTheCourseListFields() throws {
        let token = "0123456789abcdef0123456789abcdef"
        let identity = CourseListSnapshot.Identity(siteID: "polimi", rootID: Self.rootID, token: token)
        let data = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(2)))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(object.keys) == ["version", "identity", "savedAt", "courses"])
        #expect(Set((object["identity"] as! [String: Any]).keys) == ["siteID", "rootID", "credential"])
        let course = (object["courses"] as! [[String: Any]])[0]
        #expect(Set(course.keys).isSubset(of: ["id", "shortName", "displayName", "isVisible", "startDate", "endDate"]))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains(token))
        #expect(!text.contains("token"))
        #expect(!text.contains("folder"))
        #expect(!text.contains("user"))
    }

    /// Moodle may list the same enrollments in another order: that is the same list, kept in one
    /// canonical order on disk, and it costs no rewrite.
    @Test func responseOrderIsNotAChange() {
        let list = courses(3)
        let previous = CourseListSnapshot(identity: identity, savedAt: now, courses: list.reversed())
        #expect(previous.summaries == list)
        #expect(!CourseListSnapshotCodec.shouldSave(Array(list.reversed()), identity: identity, after: previous, now: now.addingTimeInterval(60)))
        #expect(!CourseListSnapshotCodec.shouldSave(list, identity: identity, after: previous, now: now.addingTimeInterval(60)))
    }

    /// An unchanged list is not rewritten on every refresh, but `savedAt` is refreshed once a day
    /// so the age limit measures the last confirmation, not the last change.
    @Test func unchangedListIsSavedOnlyOncePerInterval() {
        let list = courses(3)
        #expect(CourseListSnapshotCodec.shouldSave(list, identity: identity, after: nil, now: now))
        let previous = CourseListSnapshot(identity: identity, savedAt: now, courses: list)
        #expect(!CourseListSnapshotCodec.shouldSave(list, identity: identity, after: previous, now: now.addingTimeInterval(3_600)))
        #expect(CourseListSnapshotCodec.shouldSave(list, identity: identity, after: previous, now: now.addingTimeInterval(CourseListSnapshotCodec.saveRefreshInterval)))
        // A renamed course, a removed course, or another account: always written.
        let renamed = [RemoteCourseSummary(id: 1, shortName: "C1", displayName: "Renamed", isVisible: nil, startDate: nil, endDate: nil)] + Array(list.dropFirst())
        #expect(CourseListSnapshotCodec.shouldSave(renamed, identity: identity, after: previous, now: now))
        #expect(CourseListSnapshotCodec.shouldSave(Array(list.dropLast()), identity: identity, after: previous, now: now))
        #expect(CourseListSnapshotCodec.shouldSave(list, identity: CourseListSnapshot.Identity(siteID: "polimi", rootID: Self.rootID, token: "token-b"), after: previous, now: now))
    }

    // MARK: Store

    private func makeStore() throws -> (CourseListSnapshotStore, URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CourseListSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        let store = CourseListSnapshotStore(directory: { folder })
        return (store, folder, { try? FileManager.default.removeItem(at: folder) })
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Saving creates the file 0600 in a 0700 folder, with no temporary file left behind, and a
    /// second store (the next launch) reads the same list back.
    @Test func saveWritesPrivateFileThatTheNextLaunchRestores() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        let list = courses(5)
        #expect(try await store.save(list, identity: identity, now: now))
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        #expect(try permissions(file) == 0o600)
        #expect(try permissions(folder) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [CourseListSnapshotStore.fileName])

        let relaunched = CourseListSnapshotStore(directory: { folder })
        let outcome = await relaunched.load(expecting: identity, now: now.addingTimeInterval(60))
        guard case .restored(let snapshot) = outcome else {
            Issue.record("Expected the saved list back, got \(outcome)")
            return
        }
        #expect(snapshot.summaries == list)
        #expect(snapshot.savedAt == now)
    }

    @Test func missingFileIsNotAnError() async throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(await store.load(expecting: identity, now: now) == .missing)
        await #expect(throws: Never.self) { try await store.delete() }
    }

    /// Account A → B with the deletion at sign-out missed: B must not see A's list, and the file
    /// must be gone so it cannot come back on a later launch either.
    @Test func foreignFileIsDiscardedAndRemoved() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        try await store.save(courses(2), identity: identity, now: now)
        let other = CourseListSnapshot.Identity(siteID: "polimi", rootID: Self.rootID, token: "token-b")
        #expect(await store.load(expecting: other, now: now) == .discarded(.wrongIdentity))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CourseListSnapshotStore.fileName).path))
        #expect(await store.load(expecting: identity, now: now) == .missing)
    }

    /// An old list is discarded on load even though it was written by this very BeepBar.
    @Test func expiredFileIsDiscardedAndRemoved() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        try await store.save(courses(2), identity: identity, now: now)
        let later = now.addingTimeInterval(CourseListSnapshotCodec.maximumAge + 1)
        #expect(await store.load(expecting: identity, now: later) == .discarded(.expired))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CourseListSnapshotStore.fileName).path))
    }

    /// A damaged file is paid for once: refused and deleted, never shown as an empty list.
    @Test func corruptFileIsDiscardedAndRemoved() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        try Data("{broken".utf8).write(to: file)
        #expect(await store.load(expecting: identity, now: now) == .discarded(.unreadable))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// A file over the byte limit is refused by its size alone, before any of it is decoded.
    @Test func oversizedFileIsDiscardedWithoutDecoding() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        // Valid JSON padded past the limit: decoding it would succeed, so only the size check can refuse it.
        var data = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(1)))
        data.append(Data(repeating: UInt8(ascii: " "), count: CourseListSnapshotCodec.maximumBytes))
        try data.write(to: file)
        #expect(await store.load(expecting: identity, now: now) == .discarded(.tooLarge))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Cost proportional to what changed: a refresh that confirms the same list writes nothing,
    /// a changed list is written, and the file keeps the date of the write that really happened.
    @Test func unchangedListWritesNothing() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        let list = courses(3)
        #expect(try await store.save(list, identity: identity, now: now))
        #expect(try await store.save(list, identity: identity, now: now.addingTimeInterval(3_600)) == false)
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        let unchanged = try CourseListSnapshotCodec.decode(Data(contentsOf: file), expecting: identity, now: now)
        #expect(unchanged.savedAt == now)
        #expect(try await store.save(Array(list.dropLast()), identity: identity, now: now.addingTimeInterval(7_200)))
        let rewritten = try CourseListSnapshotCodec.decode(Data(contentsOf: file), expecting: identity, now: now)
        #expect(rewritten.summaries == Array(list.dropLast()))
        #expect(rewritten.savedAt == now.addingTimeInterval(7_200))
    }

    /// A list over the count limit is not saved, and an older shorter file goes with it: a stale
    /// list must not outlive the longer live one.
    @Test func listOverTheLimitRemovesTheOlderFile() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        try await store.save(courses(2), identity: identity, now: now)
        #expect(try await store.save(courses(CourseListSnapshotCodec.maximumCourses + 1), identity: identity, now: now) == false)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CourseListSnapshotStore.fileName).path))
    }

    /// Sign-out: the list and any temporary file a crash left behind are gone.
    @Test func deleteRemovesFileAndLeftoverTemporaries() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        try await store.save(courses(2), identity: identity, now: now)
        try Data("half".utf8).write(to: folder.appendingPathComponent(".course-list-leftover.tmp"))
        try await store.delete()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(await store.load(expecting: identity, now: now) == .missing)
        // After a delete the next save writes again even for the same list: nothing is on disk.
        #expect(try await store.save(courses(2), identity: identity, now: now))
    }

    /// Sign-out while a save is in flight, whichever reaches the store first: a save made before
    /// the sign-out is refused once the deletion retired its epoch, so the signed-out account's
    /// list is not written back. A save made after it (the next account's) still writes.
    @Test func retiredEpochSavesAreRefused() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        try await store.delete(retiringEpochsBelow: 1)
        #expect(try await store.save(courses(2), identity: identity, epoch: 0, now: now) == false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.save(courses(2), identity: identity, epoch: 1, now: now))
        #expect(FileManager.default.fileExists(atPath: file.path))
        // A later delete with a smaller epoch never revives retired epochs.
        try await store.delete(retiringEpochsBelow: 0)
        #expect(try await store.save(courses(2), identity: identity, epoch: 0, now: now) == false)
    }

    /// The other order: the late save arrived first and wrote; the sign-out's deletion then
    /// removes it, so nothing of the old account is left on disk either way.
    @Test func deletionAfterAnEarlierSaveRemovesIt() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(try await store.save(courses(2), identity: identity, epoch: 0, now: now))
        try await store.delete(retiringEpochsBelow: 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CourseListSnapshotStore.fileName).path))
        #expect(await store.load(expecting: identity, now: now) == .missing)
    }

    /// A deletion that fails (the folder cannot be read) still retires the epoch: the old
    /// account's list is not written by a save that arrives afterwards.
    @Test func failedDeletionStillRetiresTheEpoch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CourseListSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let failing = OSAllocatedUnfairLock(initialState: true)
        let store = CourseListSnapshotStore(directory: {
            if failing.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return folder
        })
        await #expect(throws: CocoaError.self) { try await store.delete(retiringEpochsBelow: 1) }
        failing.withLock { $0 = false }
        #expect(try await store.save(courses(2), identity: identity, epoch: 0, now: now) == false)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CourseListSnapshotStore.fileName).path))
    }

    /// A file dated well ahead of now was written with a wrong clock: its age says nothing, so it
    /// is refused rather than shown "saved in 3 days" and never expiring. A day ahead is still
    /// accepted (a clock moved back a little), and an unchanged list dated ahead is rewritten at
    /// once instead of waiting for its future date to pass.
    @Test func futureDatesAreRefusedOrRewritten() throws {
        let data = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(1)))
        let dayBefore = now.addingTimeInterval(-CourseListSnapshotCodec.saveRefreshInterval)
        #expect(throws: Never.self) { try CourseListSnapshotCodec.decode(data, expecting: identity, now: dayBefore) }
        #expect(throws: CourseListSnapshotCodec.DecodeError.savedInTheFuture) {
            try CourseListSnapshotCodec.decode(data, expecting: identity, now: dayBefore.addingTimeInterval(-1))
        }
        let ahead = CourseListSnapshot(identity: identity, savedAt: now.addingTimeInterval(3_600), courses: courses(1))
        #expect(CourseListSnapshotCodec.shouldSave(courses(1), identity: identity, after: ahead, now: now))
    }

    /// The first save of a launch reads the file before deciding: a sync from the menu before the
    /// window ever opened must not rewrite an unchanged list on every launch (no disk write when
    /// nothing changed). A changed list is still written.
    @Test func aNewLaunchDoesNotRewriteAnUnchangedList() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(try await store.save(courses(3), identity: identity, now: now))
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        let written = try Data(contentsOf: file)

        let relaunched = CourseListSnapshotStore(directory: { folder })
        #expect(try await relaunched.save(courses(3), identity: identity, now: now.addingTimeInterval(3_600)) == false)
        #expect(try Data(contentsOf: file) == written)
        #expect(try await relaunched.save(courses(2), identity: identity, now: now.addingTimeInterval(3_600)))
    }

    /// A file refused on load is gone, so the store must not keep believing it holds the list: the
    /// next save of that very list writes it again instead of skipping it as unchanged.
    @Test func aDiscardedFileIsWrittenAgain() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        #expect(try await store.save(courses(2), identity: identity, now: now))
        try Data("{broken".utf8).write(to: file)
        #expect(await store.load(expecting: identity, now: now) == .discarded(.unreadable))
        #expect(try await store.save(courses(2), identity: identity, now: now.addingTimeInterval(60)))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A temporary file a crash left behind is swept by the next write, not only at sign-out.
    @Test func aSaveRemovesLeftoverTemporaries() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: folder.appendingPathComponent(".course-list-leftover.tmp"))
        #expect(try await store.save(courses(1), identity: identity, now: now))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [CourseListSnapshotStore.fileName])
    }

    /// Storage limitation (PR #138): the age limit is enforced without the window, whoever the
    /// file belongs to. A file within 30 days stays (the account's list, still useful); past
    /// them it is deleted. Fails if the pruning deletes a valid list, keeps an expired one, or
    /// only handles the identity it was saved for.
    @Test func removeIfExpiredDeletesOnlyAnExpiredFile() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        #expect(await store.removeIfExpired(now: now) == false, "no file is not a deletion")
        let foreign = CourseListSnapshot.Identity(siteID: "unipd-math", rootID: UUID(), token: "token-z")
        #expect(try await CourseListSnapshotStore(directory: { folder }).save(courses(2), identity: foreign, now: now))

        let relaunched = CourseListSnapshotStore(directory: { folder })
        #expect(await relaunched.removeIfExpired(now: now.addingTimeInterval(CourseListSnapshotCodec.maximumAge - 60)) == false)
        #expect(FileManager.default.fileExists(atPath: file.path), "a list within the age limit was deleted")
        #expect(await relaunched.removeIfExpired(now: now.addingTimeInterval(CourseListSnapshotCodec.maximumAge + 60)))
        #expect(!FileManager.default.fileExists(atPath: file.path), "an expired list outlived the age limit")
    }

    /// Pruning is not a sign-out: the same account's next confirmed list is saved again.
    @Test func removeIfExpiredRetiresNothing() async throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        #expect(try await store.save(courses(1), identity: identity, epoch: 3, now: now))
        let later = now.addingTimeInterval(CourseListSnapshotCodec.maximumAge + 60)
        #expect(await store.removeIfExpired(now: later))
        #expect(try await store.save(courses(1), identity: identity, epoch: 3, now: later), "pruning retired the account's epoch")
    }

    /// A file the pruning can't decode (a newer format after a downgrade, damage) is aged by its
    /// modification date: kept while young, deleted once past the limit, and read only once in
    /// between. Fails if such a file is never pruned or is re-read at every check.
    @Test func removeIfExpiredAgesAnUndecodableFileByItsModificationDate() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

        #expect(await store.removeIfExpired(now: now.addingTimeInterval(60)) == false)
        #expect(FileManager.default.fileExists(atPath: file.path), "a young undecodable file was deleted")
        // Made readable and fresh behind the store's back: a store that read again would now keep it.
        #expect(try await CourseListSnapshotStore(directory: { folder }).save(courses(1), identity: identity, now: now.addingTimeInterval(CourseListSnapshotCodec.maximumAge)))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        #expect(await store.removeIfExpired(now: now.addingTimeInterval(CourseListSnapshotCodec.maximumAge + 60)))
        #expect(!FileManager.default.fileExists(atPath: file.path), "an undecodable file outlived the age limit")
    }

    /// Cost proportional to what changed: once the store knows the file's date, later checks
    /// don't read it again. Swapping the file for unreadable bytes after the first check shows
    /// it: the known date still decides. Fails if every check re-reads the file.
    @Test func removeIfExpiredReadsTheFileOnlyOnce() async throws {
        let (store, folder, cleanup) = try makeStore()
        defer { cleanup() }
        let file = folder.appendingPathComponent(CourseListSnapshotStore.fileName)
        #expect(try await CourseListSnapshotStore(directory: { folder }).save(courses(1), identity: identity, now: now))
        #expect(await store.removeIfExpired(now: now) == false)
        try Data("{broken".utf8).write(to: file)
        #expect(await store.removeIfExpired(now: now.addingTimeInterval(CourseListSnapshotCodec.maximumAge + 60)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
