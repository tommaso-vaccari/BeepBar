import Foundation
import Testing
@testable import BeepbarCore

/// The saved course list (#98): what the window may show before the network answers. Each test
/// guards one acceptance rule of the issue: a foreign, old, oversized or corrupt file is never
/// shown, the file never carries the token, and an unchanged list costs no write.
struct CourseListSnapshotTests {
    private let identity = CourseListSnapshot.Identity(siteID: "polimi", userID: 42)
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

    /// Account A's list must never be shown to account B, nor one site's list on another site.
    @Test func foreignIdentityIsRejected() throws {
        let data = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(1)))
        #expect(throws: CourseListSnapshotCodec.DecodeError.wrongIdentity) {
            try CourseListSnapshotCodec.decode(data, expecting: CourseListSnapshot.Identity(siteID: "polimi", userID: 43), now: now)
        }
        #expect(throws: CourseListSnapshotCodec.DecodeError.wrongIdentity) {
            try CourseListSnapshotCodec.decode(data, expecting: CourseListSnapshot.Identity(siteID: "unipd", userID: 42), now: now)
        }
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

    /// The file holds names, ids and dates only: no token, no folder, no selection. Pinned by the
    /// exact key set so a field added by mistake fails here before it ships.
    @Test func fileCarriesOnlyTheCourseListFields() throws {
        let data = try CourseListSnapshotCodec.encode(CourseListSnapshot(identity: identity, savedAt: now, courses: courses(2)))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(object.keys) == ["version", "identity", "savedAt", "courses"])
        #expect(Set((object["identity"] as! [String: Any]).keys) == ["siteID", "userID"])
        let course = (object["courses"] as! [[String: Any]])[0]
        #expect(Set(course.keys).isSubset(of: ["id", "shortName", "displayName", "isVisible", "startDate", "endDate"]))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("token"))
        #expect(!text.contains("folder"))
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
        #expect(CourseListSnapshotCodec.shouldSave(list, identity: CourseListSnapshot.Identity(siteID: "polimi", userID: 7), after: previous, now: now))
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
        let other = CourseListSnapshot.Identity(siteID: "polimi", userID: 99)
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
}
