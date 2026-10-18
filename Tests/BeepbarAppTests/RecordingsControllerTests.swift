import AppKit
import Combine
import Foundation
import os
import Testing
import BeepbarCore
@testable import BeepbarApp

/// A Recman browser that answers from a script. An operation can be held at a gate, so a test can
/// act while it is in flight (turn the feature off, close the window) and then let the answer
/// arrive late, as a slow Polimi page would.
@MainActor final class FakeRecmanBrowser: RecmanBrowsing {
    /// Holds an operation until `release()`. Closing the browser doesn't release it: the late
    /// answer is exactly what the stale-answer tests want to deliver.
    @MainActor final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private(set) var isWaiting = false

        func wait() async {
            if released { return }
            isWaiting = true
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            isWaiting = false
            waiters.forEach { $0.resume() }
            waiters = []
            cancellable.values.forEach { $0.resume() }
            cancellable = [:]
        }

        private var cancellable: [UUID: CheckedContinuation<Void, Error>] = [:]
        /// How many `waitOrCancel` calls ended because their task was cancelled.
        private(set) var cancelledWaits = 0

        /// Like `wait`, but ends with `CancellationError` as soon as the awaiting task is
        /// cancelled, as the real browser's operations do (`RecmanWebSession.stream`, its Webex
        /// sign-in included).
        func waitOrCancel() async throws {
            if released { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        cancelledWaits += 1
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    isWaiting = true
                    cancellable[id] = continuation
                }
            } onCancel: {
                Task { @MainActor in self.cancelWait(id) }
            }
        }

        private func cancelWait(_ id: UUID) {
            guard let continuation = cancellable.removeValue(forKey: id) else { return }
            cancelledWaits += 1
            if cancellable.isEmpty && waiters.isEmpty { isWaiting = false }
            continuation.resume(throwing: CancellationError())
        }
    }

    private(set) var isOpen = false
    private(set) var calls: [String] = []
    /// The cookie names each `open(cookies:)` received.
    private(set) var openedWith: [[String]] = []
    private var jar: [HTTPCookie] = []
    /// What the jar holds after a successful sign-in.
    var signedInCookies = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "fresh")]
    var signInError: Error?
    var signInGate: Gate?
    var listResults: [String: Result<[RecmanRecording], Error>] = [:]
    var listGates: [String: Gate] = [:]
    /// When set, a successful listing leaves these cookies in the jar, as Polimi renewing one.
    var cookiesAfterListing: [HTTPCookie]?
    var playbackResults: [String: Result<URL, Error>] = [:]
    var playbackGates: [String: Gate] = [:]
    /// What `stream(for:email:)` answers for a recording, one entry per call, in order; once they
    /// are used up (or when none are set) the stream is unavailable and Play falls back to the
    /// browser.
    var streamResults: [String: [Result<RecordingStream, Error>]] = [:]
    var streamGates: [String: Gate] = [:]
    /// Whether a held stream ends with `CancellationError` when its task is cancelled, as the real
    /// browser does; off by default, so older tests keep a held stream held.
    var streamHonorsCancellation = false
    /// The email each `stream(for:email:)` call received (nil: none).
    private(set) var streamEmails: [String?] = []

    static func cookie(_ name: String, value: String = "v", domain: String = "aunicalogin.polimi.it") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"])!
    }

    var listCalls: [String] { calls.filter { $0.hasPrefix("list ") }.map { String($0.dropFirst(5)) } }
    var playCalls: [String] { calls.filter { $0.hasPrefix("play ") } }
    var streamCalls: [String] { calls.filter { $0.hasPrefix("stream ") } }

    func open(cookies: [HTTPCookie]) async {
        calls.append("open")
        isOpen = true
        jar = cookies
        openedWith.append(cookies.map(\.name).sorted())
    }

    func cookies() async -> [HTTPCookie] { jar }

    func signIn() async throws {
        calls.append("signIn")
        await signInGate?.wait()
        if let signInError { throw signInError }
        jar = signedInCookies
    }

    func recordings(for key: RecmanCourseKey) async throws -> [RecmanRecording] {
        calls.append("list \(key.courseCode)")
        await listGates[key.courseCode]?.wait()
        guard let result = listResults[key.courseCode] else { throw RecmanBrowserError.unrecognized }
        let recordings = try result.get()
        if let cookiesAfterListing { jar = cookiesAfterListing }
        return recordings
    }

    func playbackURL(for recording: RecmanRecording) async throws -> URL {
        calls.append("play \(recording.id)")
        await playbackGates[recording.id]?.wait()
        guard let result = playbackResults[recording.id] else { throw RecmanBrowserError.playbackUnavailable }
        return try result.get()
    }

    func stream(for recording: RecmanRecording, email: PolimiEmail?) async throws -> RecordingStream {
        calls.append("stream \(recording.id)")
        streamEmails.append(email?.value)
        if streamHonorsCancellation { try await streamGates[recording.id]?.waitOrCancel() } else { await streamGates[recording.id]?.wait() }
        guard var results = streamResults[recording.id], !results.isEmpty else { throw RecmanBrowserError.playbackUnavailable }
        let result = results.removeFirst()
        streamResults[recording.id] = results
        return try result.get()
    }

    func close() {
        calls.append("close")
        isOpen = false
        jar = []
    }
}

/// The native player as the controller sees it, without AVFoundation. Behaves like the real one
/// where the controller depends on it: a newer `play` first reports the lecture it replaces
/// (`.replaced`), `close()` reports the lecture on screen before it goes (`.closed`), a pause
/// reports `.paused`, a mid-lecture failure `.failed`, and `tick(at:)` reaches `onProgress` only.
@MainActor final class FakeRecordingPlayer: RecordingPlaying {
    struct Play: Equatable {
        let url: URL
        let title: String
        let startAt: TimeInterval?
        let recordingID: String
        let cookies: Int
    }

    private(set) var isOpen = false
    var onPositionCheckpoint: ((RecordingCheckpoint) -> Void)?
    var onProgress: ((String, TimeInterval, TimeInterval?) -> Void)?
    var onFailure: ((String, RecordingPlaybackFailure) -> Void)?
    private(set) var plays: [Play] = []
    /// The Now Playing metadata of each play, in order (nil: the caller gave none).
    private(set) var metadatas: [RecordingPlaybackMetadata?] = []
    /// The `index`th play, or a recorded failure instead of a crash when the controller started
    /// fewer: an out-of-range index would end the whole test process and hide every other result.
    func play(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> Play {
        try #require(plays.indices.contains(index) ? plays[index] : nil, sourceLocation: sourceLocation)
    }
    private(set) var closes = 0
    private(set) var adoptedPolicies: [NSApplication.ActivationPolicy] = []
    /// The lecture on screen and where it is: what the real player would report.
    private var current: (id: String, position: TimeInterval, duration: TimeInterval?)?
    /// The duration the fake lecture reports.
    var duration: TimeInterval? = 6_000

    func play(_ url: URL, title: String, cookies: [HTTPCookie], startAt: TimeInterval?, recordingID: String, metadata: RecordingPlaybackMetadata?) {
        metadatas.append(metadata)
        report(.replaced)
        plays.append(Play(url: url, title: title, startAt: startAt, recordingID: recordingID, cookies: cookies.count))
        isOpen = true
        current = (recordingID, startAt ?? 0, duration)
        afterPlay?()
    }

    /// Runs at the end of each `play`, inside the controller's call: lets a test act in the exact
    /// main-actor turn the player started.
    var afterPlay: (() -> Void)?

    func pause() {}

    func close() {
        closes += 1
        report(.closed)
        isOpen = false
        current = nil
    }

    func adoptPolicyToRestore(_ policy: NSApplication.ActivationPolicy) { adoptedPolicies.append(policy) }

    /// How many times the controller brought the open window forward (`bringToFront`).
    private(set) var broughtToFront = 0
    func bringToFront() { if isOpen { broughtToFront += 1 } }
    /// What the controller told the open window about a lecture that can't continue
    /// (`showProblem`), in order.
    private(set) var problems: [String] = []
    func showProblem(_ message: String) { if isOpen { problems.append(message) } }

    /// Reports the lecture on screen, if any, with `reason`: what the real player's checkpoint
    /// carries.
    private func report(_ reason: RecordingCheckpoint.Reason) {
        guard isOpen, let current else { return }
        onPositionCheckpoint?(RecordingCheckpoint(id: current.id, position: current.position, duration: current.duration, reason: reason))
    }

    /// The lecture plays on to `position` without any report, as it does between pauses.
    func move(to position: TimeInterval) { current?.position = position }

    /// The lecture plays on to `position` and the periodic observer ticks there: `onProgress`
    /// only, never a checkpoint, as the real player does while playing.
    func tick(at position: TimeInterval) {
        guard let current else { return }
        self.current?.position = position
        onProgress?(current.id, position, current.duration)
    }

    /// The student pauses at `position`: the report the real player makes.
    func pause(at position: TimeInterval) {
        guard current != nil else { return }
        current?.position = position
        report(.paused)
    }

    /// The stream dies mid-lecture at `position`, as the real player reports it: the position
    /// first, then the failure, the window staying open.
    func failDuringPlayback(at position: TimeInterval) {
        guard let id = current?.id else { return }
        current?.position = position
        report(.failed)
        onFailure?(id, .duringPlayback(nil, position: position))
    }

    /// The student closes the window before the stream is ready: the real player reports nothing
    /// then (no settled position), and no failure either.
    func closeBeforeReady() {
        isOpen = false
        current = nil
    }

    /// The stream never starts: the window closes itself and the failure is reported.
    func failBeforeReady() {
        guard let id = current?.id else { return }
        isOpen = false
        current = nil
        onFailure?(id, .beforeReady(nil))
    }

    var currentPosition: TimeInterval? { current?.position }
}

/// Settings that record every write, to prove that a visit with nothing new writes nothing.
class CountingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String] = []

    static func throwaway() -> CountingDefaults {
        CountingDefaults(suiteName: WeBeepAuthenticationController.throwawayDefaultsSuite())!
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        writes.append(defaultName)
        super.removeObject(forKey: defaultName)
    }

    func recordWrite(_ key: String) { writes.append(key) }

    func resetWrites() { writes = [] }
}

/// Controller tests share settings across reconstructed controllers without involving cfprefsd.
/// Disk-backed defaults remain in the persistence tests that open separate suite handles.
final class MemoryCountingDefaults: CountingDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    static func isolated() -> MemoryCountingDefaults {
        MemoryCountingDefaults(suiteName: FileManager.default.temporaryDirectory.appending(path: "BeepbarMemoryDefaults-\(UUID().uuidString)").path)!
    }

    override func set(_ value: Any?, forKey key: String) {
        values[key] = value
        recordWrite(key)
    }
    override func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
        recordWrite(key)
    }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
}

/// Guards controller fixtures against accidentally going back to asynchronous disk preferences.
@MainActor struct MemoryCountingDefaultsTests {
    @Test func valuesStayLocalAndTypedWithoutPersistentWrites() throws {
        let suite = WeBeepAuthenticationController.throwawayDefaultsSuite()
        defer { removeTestDefaults(suite) }
        let defaults = try #require(MemoryCountingDefaults(suiteName: suite))
        let other = MemoryCountingDefaults.isolated()
        defaults.set(true, forKey: "enabled")
        defaults.set([], forKey: "selection")
        defaults.set("namespace", forKey: "namespace")
        defaults.set(Data([1, 2]), forKey: "data")
        defaults.set(42, forKey: "integer")
        defaults.set(1.5, forKey: "double")
        #expect(defaults.bool(forKey: "enabled"))
        #expect(defaults.stringArray(forKey: "selection") == [])
        #expect(defaults.string(forKey: "namespace") == "namespace")
        #expect(defaults.data(forKey: "data") == Data([1, 2]))
        #expect(defaults.integer(forKey: "integer") == 42)
        #expect(defaults.double(forKey: "double") == 1.5)
        #expect(other.object(forKey: "enabled") == nil)
        #expect(defaults.persistentDomain(forName: suite)?.isEmpty != false)
        #expect(defaults.writes == ["enabled", "selection", "namespace", "data", "integer", "double"])
        defaults.resetWrites()
        defaults.removeObject(forKey: "enabled")
        #expect(defaults.object(forKey: "enabled") == nil)
        #expect(!defaults.bool(forKey: "enabled"))
        #expect(defaults.writes == ["enabled"])
    }
}

/// Thread-safe fixture faults/probe for the history executor; session counters stay separate.
final class HistoryFileProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var removalFails = false
    private var mainThreadReads: [Bool] = []
    func setRemovalFailure(_ value: Bool) { lock.withLock { removalFails = value } }
    func recordIO() { lock.withLock { mainThreadReads.append(Thread.isMainThread) } }
    var allIOWasOffMain: Bool { lock.withLock { !mainThreadReads.isEmpty && !mainThreadReads.contains(true) } }
    func remove(_ url: URL) throws {
        if lock.withLock({ removalFails }) { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
    }
}

/// The controller's accesses to the session file, counted from whatever thread the vault runs
/// them on. Any made on the main thread is recorded too: every test checks there are none (#97).
/// `hold(access:)` parks that access (counted from 1) until `release()`, as a slow disk would.
final class SessionFileProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var onMain = 0
    private var holdAt: Int?
    private var held = false
    func record() {
        let parks = lock.withLock { () -> Bool in
            count += 1
            if Thread.isMainThread { onMain += 1 }
            if count == holdAt { held = true }
            return held
        }
        // Never park the main thread: that is the failure this probe reports, not one to hang on.
        // Parking blocks the vault's file thread, never a cooperative one (see `RecmanSessionVault`
        // on the CI deadlock); the deadline makes a regression or a missing release fail, not hang.
        // A hang detector, not a timing bound: CI tests here take up to ~33 s, and 10 s failed there.
        guard parks, !Thread.isMainThread else { return }
        let deadline = Date().addingTimeInterval(120)
        while lock.withLock({ held }) {
            guard Date() < deadline else {
                Issue.record("a held session file access was never released")
                return
            }
            usleep(500)
        }
    }
    func hold(access: Int) { lock.withLock { holdAt = access } }
    var isHolding: Bool { lock.withLock { held } }
    func release() { lock.withLock { holdAt = nil; held = false } }
    var accesses: Int {
        get { lock.withLock { count } }
        set { lock.withLock { count = newValue } }
    }
    var mainThreadAccesses: Int { lock.withLock { onMain } }
}

/// Mutable from a test: the WeBeep account, Polimi or not, the clock, and what was opened.
@MainActor final class RecordingsWorld {
    var owner: Int? = 42
    var polimi = true
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var opened: [URL] = []
    var copied: [URL] = []
    let sessionFiles = SessionFileProbe()
    /// How many times the controller resolved the session file's folder: once per read, write or delete.
    var storeAccesses: Int {
        get { sessionFiles.accesses }
        set { sessionFiles.accesses = newValue }
    }
    var browsersMade = 0
    /// The native player, a fake that never touches AVFoundation, and how many were made.
    let player = FakeRecordingPlayer()
    var playersMade = 0
    /// The WeBeep course list the controller reads when a lecture starts (Now Playing metadata).
    var courses: [RemoteCourseSummary] = []
    /// What the WeBeep profile answers for the user's email (nil: the profile has none, or it
    /// can't be read), and how often it was asked.
    var profileEmail: String?
    var profileEmailCalls = 0
    /// Holds the profile read until released, to answer it late.
    var profileGate: FakeRecmanBrowser.Gate?
    let historyFiles = HistoryFileProbe()
    var historyActors: [RecordingsSeenHistory] = []
    var historyReadGate: FakeRecmanBrowser.Gate?
    var historyAcknowledgeGate: FakeRecmanBrowser.Gate?
    var historyAfterReadGate: FakeRecmanBrowser.Gate?
    var historyAcknowledgementsStarted = 0
    func waitAfterHistoryRead() async { await historyAfterReadGate?.wait() }
    func waitForHistoryRead() async { await historyReadGate?.wait() }
    func waitForHistoryAcknowledge() async { historyAcknowledgementsStarted += 1; await historyAcknowledgeGate?.wait() }
}

/// The Recordings controller against a scripted browser, a throwaway session folder and throwaway
/// settings. Each test names the promise of `RecordingsController` it guards.
@MainActor
struct RecordingsControllerTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-controller-\(UUID().uuidString)", isDirectory: true)
    private let defaults = MemoryCountingDefaults.isolated()
    private let browser = FakeRecmanBrowser()
    private let world = RecordingsWorld()
    private let course = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
    private let other = RecmanCourseKey(courseCode: "052499", academicYear: 2026)!
    private let third = RecmanCourseKey(courseCode: "099999", academicYear: 2026)!

    /// The controller's store: counts its accesses and the threads they ran on.
    private var controllerStore: RecordingsSessionStore {
        let folder = folder
        let probe = world.sessionFiles
        return RecordingsSessionStore {
            probe.record()
            return folder
        }
    }
    /// The same file for the test's own reads and writes, which run on the main thread on purpose.
    private var store: RecordingsSessionStore {
        let folder = folder
        return RecordingsSessionStore { folder }
    }
    private var sessionFile: URL { folder.appendingPathComponent(RecordingsSessionStore.fileName) }

    private func makeController(useDefault: Bool = false, listingCapacity: Int = RecordingsController.listingCapacity, playbackURLCapacity: Int = RecordingsController.playbackURLCapacity) -> RecordingsController {
        if !useDefault && defaults.object(forKey: RecordingsController.enabledKey) == nil {
            defaults.set(false, forKey: RecordingsController.enabledKey)
            defaults.resetWrites()
        }
        let world = world
        let browser = browser
        return RecordingsController(
            makeBrowser: { world.browsersMade += 1; return browser },
            store: controllerStore,
            defaults: defaults,
            makeSeenHistory: { namespace in
                let files = world.historyFiles
                let folder = self.folder
                let storage = RecordingsSeenStore(directory: { files.recordIO(); return folder }, namespace: namespace, removeFile: { try files.remove($0) })
                let history = RecordingsSeenHistory(store: storage, beforeRead: { await world.waitForHistoryRead() }, beforeAcknowledge: { await world.waitForHistoryAcknowledge() }, afterRead: { await world.waitAfterHistoryRead() })
                world.historyActors.append(history)
                return history
            },
            ownerUserID: { world.owner },
            isAvailable: { world.polimi },
            openURL: { world.opened.append($0) },
            copy: { world.copied.append($0) },
            now: { MainActor.assumeIsolated { world.now } },
            makePlayer: { world.playersMade += 1; return world.player },
            courses: { world.courses },
            fetchProfileEmail: {
                world.profileEmailCalls += 1
                await world.profileGate?.wait()
                return world.profileEmail
            },
            listingCapacity: listingCapacity,
            playbackURLCapacity: playbackURLCapacity
        )
    }

    private func recording(_ id: String, _ key: RecmanCourseKey? = nil, daysAgo: Double = 1) -> RecmanRecording {
        let key = key ?? course
        return RecmanRecording(id: id, courseCode: key.courseCode, academicYear: key.academicYear, title: "Lezione \(id)", recordedAt: world.now.addingTimeInterval(-daysAgo * 86_400), kind: "Lezione", duration: "90 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/x?transfer_id=\(id)")!)
    }

    private func saveSession(owner: Int, cookies: [HTTPCookie] = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "saved")]) throws {
        try store.save(RecmanSessionCodec.encode(cookies, ownerUserID: owner, now: world.now))
    }

    private func savedSession() throws -> RecmanSessionCodec.Snapshot? {
        guard let data = try store.load() else { return nil }
        return try RecmanSessionCodec.decode(data, now: world.now)
    }

    /// The session file's inode: a save replaces the file, so a changed number means it was written.
    private func sessionFileNumber() -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: sessionFile.path))?[.systemFileNumber] as? Int
    }

    /// Waits for the controller's tasks; records a failure instead of hanging.
    private func settle(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("never happened: \(comment)", sourceLocation: sourceLocation)
    }

    /// Lets every pending main-actor task run, before checking that something did *not* happen.
    private func drainTasks() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<50 { await Task.yield() }
    }

    /// Turned on, signed in, session saved, browser closed again, then the page shown: the state
    /// after enabling the switch and opening Registrazioni.
    private func readyController(listingCapacity: Int = RecordingsController.listingCapacity, playbackURLCapacity: Int = RecordingsController.playbackURLCapacity) async -> RecordingsController {
        let controller = makeController(listingCapacity: listingCapacity, playbackURLCapacity: playbackURLCapacity)
        controller.setEnabled(true)
        await settle("sign-in finished and browser closed") { controller.access == .ready && !browser.isOpen }
        controller.pageAppeared()
        return controller
    }

    private func cleanUp() {
        #expect(world.sessionFiles.mainThreadAccesses == 0, "the session file was read, written or deleted on the main thread")
        let actors = world.historyActors
        actors.forEach { $0.invalidate() }
        let folder = folder
        Task {
            for history in actors { try? await history.invalidateAndDelete() }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Switch

    /// An explicitly disabled feature stays quiet.
    @Test func disabledCreationTouchesNothing() async {
        defer { cleanUp() }
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        controller.play(recording("a"))
        await drainTasks()
        #expect(!controller.isEnabled)
        #expect(controller.access == .off)
        #expect(world.storeAccesses == 0)
        #expect(world.browsersMade == 0)
        #expect(defaults.writes.isEmpty)
    }

    @Test func enabledByDefaultWithoutStartingWorkAndExplicitOptOutPersists() async {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        #expect(controller.isEnabled)
        await drainTasks()
        #expect(world.storeAccesses == 0)
        #expect(world.browsersMade == 0)
        #expect(defaults.writes.isEmpty)
        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(!makeController(useDefault: true).isEnabled)
        defaults.removeObject(forKey: RecordingsController.enabledKey)
        world.polimi = false
        #expect(!makeController(useDefault: true).isEnabled)
    }

    /// The switch only turns on for Polimi with a known WeBeep account, since the session is saved
    /// under that account. Turning on signs in at once and saves the session for that account.
    @Test func turningOnNeedsPolimiAndAKnownAccount() async throws {
        defer { cleanUp() }
        world.polimi = false
        let controller = makeController()
        #expect(!controller.canTurnOn)
        controller.setEnabled(true)
        #expect(!controller.isEnabled)
        world.polimi = true
        world.owner = nil
        #expect(!controller.canTurnOn)
        controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(browser.calls.isEmpty)
        #expect(defaults.writes.isEmpty)

        world.owner = 42
        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(controller.access == .signingIn)
        #expect(defaults.bool(forKey: RecordingsController.enabledKey))
        // The page isn't shown, so the browser goes once the session is saved.
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        #expect(browser.calls == ["open", "signIn", "close"])
        #expect(try savedSession()?.ownerUserID == 42)
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"])
    }

    /// A switch saved on comes back on after a relaunch, ready, with no sign-in until the page
    /// asks for something. Another university never shows Polimi's feature.
    @Test func theSwitchSurvivesARelaunch() async {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        let controller = makeController()
        #expect(controller.isEnabled)
        #expect(controller.access == .ready)
        await drainTasks()
        #expect(browser.calls.isEmpty)
        world.polimi = false
        #expect(!makeController().isEnabled)
    }

    /// Closing the Polimi window leaves the switch on with the sign-in still to do, and no message;
    /// a real failure says why; a later success saves the session.
    @Test func anUnfinishedSignInKeepsTheSwitchOnAndSaysWhy() async throws {
        defer { cleanUp() }
        browser.signInError = CancellationError()
        let controller = makeController()
        controller.setEnabled(true)
        await settle("cancelled") { controller.access == .needsSignIn(nil) }
        #expect(controller.isEnabled)
        #expect(try store.load() == nil)
        #expect(!browser.isOpen)

        browser.signInError = RecmanBrowserError.unavailable
        controller.signIn()
        await settle("failed with a reason") { controller.access == .needsSignIn(.unavailable) }
        browser.signInError = nil
        controller.signIn()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"])
    }

    /// Off means forgotten: browser closed, session file deleted, every setting removed, lists gone.
    /// Guards against a Polimi session lingering after the user turned the feature off.
    @Test func turningOffForgetsEverything() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(try store.load() != nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(RecordingsSeenStore.fileName).path))

        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(controller.access == .off)
        #expect(!browser.isOpen)
        #expect(controller.listings.isEmpty)
        await controller.settleSessionFile()
        #expect(try store.load() == nil)
        await settle("history cleanup finished") { !FileManager.default.fileExists(atPath: folder.appendingPathComponent(RecordingsSeenStore.fileName).path) }
        #expect(defaults.string(forKey: RecordingsController.historyNamespaceKey) != nil)
        #expect(defaults.object(forKey: RecordingsController.enabledKey) as? Bool == false)
        for key in [RecordingsController.acknowledgedKey, RecordingsController.baselinedKey] {
           #expect(defaults.object(forKey: key) == nil, "\(key) left behind")
        }
        // Nothing to do while off: the page asking again starts nothing.
        controller.refresh([course], selected: course, force: true)
        await drainTasks()
        #expect(!browser.isOpen)
    }

    // MARK: Session file and account

    /// First use shows the explanation before any archive request, even with no synced courses.
    /// Rebuilding or reopening the page keeps the introduction without rereading the session.
    /// The page asks for its courses at once, while the session file is still being read off the
    /// main actor: that request must wait for the answer and never open a browser (#97).
    @Test func firstVisitWithoutASessionShowsSignInWithoutOpeningABrowser() async {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        #expect(world.storeAccesses == 0)
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("the missing session asks for a sign-in") { controller.access == .needsSignIn(nil) }
        #expect(world.storeAccesses == 1)
        #expect(controller.listings.isEmpty)
        controller.pageDisappeared()
        controller.pageAppeared()
        controller.windowClosed()
        controller.pageAppeared()
        await drainTasks()
        #expect(controller.access == .needsSignIn(nil))
        #expect(controller.listings.isEmpty)
        #expect(world.storeAccesses == 1)
        #expect(world.browsersMade == 0)
        #expect(browser.calls.isEmpty)
        #expect(defaults.writes.isEmpty)
    }

    /// A matching saved session still loads automatically; page reconstruction keeps its browser.
    @Test func firstVisitReusesASavedSession() async throws {
        defer { cleanUp() }
        try saveSession(owner: 42)
        world.storeAccesses = 0
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = makeController(useDefault: true)
        #expect(world.storeAccesses == 0)
        controller.pageAppeared()
        #expect(controller.access == .ready)
        #expect(world.browsersMade == 0)
        controller.refresh([course], selected: course)
        await settle("saved session loaded") { controller.listing(for: course)?.recordings != nil }
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(!browser.calls.contains("signIn"))
        // The first visit's check and the worker opening the browser share one read (#97); the
        // unchanged session is not written back.
        #expect(world.storeAccesses == 1)
        let accesses = world.storeAccesses
        controller.pageDisappeared()
        controller.pageAppeared()
        await drainTasks()
        #expect(world.storeAccesses == accesses)
        #expect(browser.isOpen)
    }

    /// A completed explicit sign-in stays usable even when an unknown owner prevented saving it.
    @Test func signInBeforeFirstVisitDoesNotRequireASavedSession() async {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        world.owner = nil
        controller.signIn()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        let accesses = world.storeAccesses
        controller.pageAppeared()
        #expect(controller.access == .ready)
        #expect(world.storeAccesses == accesses)
    }

    /// A saved file containing no reusable cookies asks for sign-in without probing Polimi.
    @Test(arguments: [false, true])
    func anEmptyOrExpiredSessionShowsSignIn(expired: Bool) async throws {
        defer { cleanUp() }
        let cookie = HTTPCookie(properties: [.name: "SSO_LOGIN", .value: "saved", .domain: "aunicalogin.polimi.it", .path: "/", .expires: world.now.addingTimeInterval(60)])!
        try saveSession(owner: 42, cookies: expired ? [cookie] : [])
        if expired { world.now = world.now.addingTimeInterval(120) }
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("asks for a sign-in") { controller.access == .needsSignIn(nil) }
        await drainTasks()
        #expect(world.browsersMade == 0)
        #expect(browser.calls.isEmpty)
        #expect(controller.listings.isEmpty)
    }

    /// A slow disk holding the first visit's read of the session leaves the main actor free, and
    /// nothing the page asks for meanwhile (its courses, Play on a bookmark) opens a browser before
    /// the answer is known. With no session the answer is the sign-in; with one, a single read
    /// serves the check and the worker. Guards the deferred refresh and the worker gate (#97).
    @Test(arguments: [false, true])
    func aSlowSessionReadDefersThePageUntilItAnswers(hasSession: Bool) async throws {
        defer { cleanUp() }
        if hasSession { try saveSession(owner: 42) }
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.playbackResults["a"] = .success(URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=a")!)
        let controller = makeController(useDefault: true)
        controller.toggleWatchlist(recording("a"), courseName: "NLA")
        world.sessionFiles.hold(access: 1)
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        controller.play(recording("a"))
        await settle("the read is held by the slow disk") { world.sessionFiles.isHolding }
        await drainTasks()
        #expect(controller.access == .ready)
        #expect(world.browsersMade == 0)
        #expect(browser.calls.isEmpty)
        #expect(controller.listings.isEmpty)
        world.sessionFiles.release()
        if hasSession {
            await settle("listed with the saved session") { controller.listing(for: course)?.recordings != nil }
            await settle("the queued Play ran") { world.opened.count == 1 }
            #expect(browser.openedWith == [["SSO_LOGIN"]])
            #expect(world.storeAccesses == 1)
        } else {
            await settle("asks for a sign-in") { controller.access == .needsSignIn(nil) }
            await drainTasks()
            #expect(world.browsersMade == 0)
            #expect(controller.listings.isEmpty)
            #expect(controller.openingRecordingID == nil)
            #expect(world.opened.isEmpty)
        }
    }

    /// Turning the feature off while the session is being written to a slow disk ends with no
    /// session file: the delete runs after the write, never before it. Turning on again with the
    /// very same Polimi cookies writes them: the controller must not believe the deleted file still
    /// holds them, or the user would be asked to sign in at every launch (#97).
    @Test func turningOffDuringASlowSaveLeavesNoSessionAndASignInSavesAgain() async throws {
        defer { cleanUp() }
        let controller = makeController()
        // Access 1 reads the (missing) file for the sign-in, access 2 is the save after it.
        world.sessionFiles.hold(access: 2)
        controller.setEnabled(true)
        await settle("the save is held by the slow disk") { world.sessionFiles.isHolding }
        controller.setEnabled(false)
        world.sessionFiles.release()
        await controller.settleSessionFile()
        #expect(try store.load() == nil, "the late write outlived the turn-off")

        controller.setEnabled(true)
        await settle("signed in again and closed") { controller.access == .ready && !browser.isOpen }
        await controller.settleSessionFile()
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"], "the same cookies were not saved again")
    }

    /// A read of the saved session that finishes after a turn-off (or a disconnect) must not adopt
    /// that session's account: a later sign-in that completes while the WeBeep account is unknown
    /// would otherwise be saved under the account whose session was just deleted. Guards the
    /// epoch check applied to a finished read (#97).
    @Test func aReadFinishingAfterTurnOffDoesNotAdoptItsOwner() async throws {
        defer { cleanUp() }
        try saveSession(owner: 42)
        let controller = makeController(useDefault: true)
        world.sessionFiles.hold(access: 1)
        controller.pageAppeared()
        await settle("the read is held by the slow disk") { world.sessionFiles.isHolding }
        controller.turnOff()
        world.sessionFiles.release()
        await controller.settleSessionFile()
        await drainTasks()
        #expect(try store.load() == nil)

        let gate = FakeRecmanBrowser.Gate()
        browser.signInGate = gate
        controller.setEnabled(true)
        await settle("sign-in on screen") { gate.isWaiting }
        world.owner = nil
        gate.release()
        await settle("signed in") { controller.access == .ready }
        await drainTasks()
        await controller.settleSessionFile()
        #expect(try store.load() == nil, "the sign-in was saved under the account of a discarded session")
    }

    /// The WeBeep account changing while the first visit is still reading the saved session: the
    /// read used to be synchronous, so this window is new (#97). The account change can't drop a
    /// session whose owner isn't known yet; the finished read must then compare the file's owner
    /// with the account connected *now*, not when the read began, and drop it unused.
    @Test func anAccountChangeDuringTheFirstReadDropsTheSession() async throws {
        defer { cleanUp() }
        try saveSession(owner: 42)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        defaults.set(["old"], forKey: RecordingsController.acknowledgedKey)
        let controller = makeController()
        world.sessionFiles.hold(access: 1)
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("the read is held by the slow disk") { world.sessionFiles.isHolding }
        world.owner = 7
        controller.webBeepAccountChanged(to: 7)
        world.sessionFiles.release()
        await settle("asks for the sign-in") { controller.access == .needsSignIn(nil) }
        await controller.settleSessionFile()
        #expect(try store.load() == nil, "another account's session was kept")
        #expect(world.browsersMade == 0)
        #expect(browser.calls.isEmpty)
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) == nil)
    }

    /// The cycle's shared read is forgotten when it no longer describes the file, so the next
    /// caller reads again: after a read error (the disk recovered, and the session there is used
    /// by the sign-in instead of an empty one) and after a save (a sign-in reopening the browser
    /// gets the renewed cookies, not the ones read before them) (#97).
    @Test(arguments: ["read error", "save"])
    func aSharedReadIsForgottenWhenTheFileChanges(after event: String) async throws {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        let controller = makeController()
        if event == "read error" {
            try FileManager.default.createDirectory(at: sessionFile, withIntermediateDirectories: true)
            controller.pageAppeared()
            await settle("asks for the sign-in") { controller.access == .needsSignIn(nil) }
            try FileManager.default.removeItem(at: sessionFile)
            try saveSession(owner: 42, cookies: [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "saved"), FakeRecmanBrowser.cookie("JSESSIONID", value: "kept", domain: "onlineservices.polimi.it")])
        } else {
            try saveSession(owner: 42)
            browser.listResults[course.courseCode] = .success([recording("a")])
            browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "renewed"), FakeRecmanBrowser.cookie("JSESSIONID", value: "next", domain: "onlineservices.polimi.it")]
            controller.pageAppeared()
            controller.refresh([course], selected: course)
            await settle("renewed session saved") { (try? savedSession())?.cookies.count == 2 }
            await drainTasks()
        }
        let opens = browser.openedWith.count
        controller.signIn()
        await settle("the sign-in opened the browser") { browser.openedWith.count == opens + 1 }
        #expect(browser.openedWith.last == (event == "read error" ? [] : ["JSESSIONID", "SSO_LOGIN"]), "a failed session check starts fresh; a renewed session reuses the current file")
    }

    /// A session saved for another WeBeep account is deleted unused, with what that account had
    /// seen: a shared Mac must not show one student's archive to the next.
    @Test func anotherAccountsSessionIsDroppedUnused() async throws {
        defer { cleanUp() }
        try saveSession(owner: 7)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        defaults.set(["old"], forKey: RecordingsController.acknowledgedKey)
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("asks for the sign-in") { controller.access == .needsSignIn(nil) }
        await controller.settleSessionFile()
        #expect(browser.calls.isEmpty)
        #expect(world.browsersMade == 0)
        #expect(try store.load() == nil)
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) == nil)
    }

    /// Before WeBeep answers (an offline launch) the account is unknown: the saved session is used,
    /// and a renewed cookie is saved under the file's owner, never under "nobody".
    @Test func anUnknownAccountUsesTheSavedSessionAndKeepsItsOwner() async throws {
        defer { cleanUp() }
        try saveSession(owner: 7)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        world.owner = nil
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "renewed")]
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("renewed session saved") { (try? savedSession())?.cookies.map(\.value) == ["renewed"] }
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(try savedSession()?.ownerUserID == 7)
    }

    /// When the WeBeep account turns out to be someone else's while the page is open, the live
    /// session, the lists and the seen recordings go too; the same account changes nothing.
    @Test func aDifferentAccountAppearingDropsTheLiveSession() async throws {
        defer { cleanUp() }
        try saveSession(owner: 7)
        defaults.set(true, forKey: RecordingsController.enabledKey)
        world.owner = nil
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings?.count == 1 }

        controller.webBeepAccountChanged(to: 7)
        await controller.settleSessionFile()
        #expect(try store.load() != nil)
        #expect(controller.listing(for: course) != nil)
        controller.webBeepAccountChanged(to: 8)
        await controller.settleSessionFile()
        #expect(try store.load() == nil)
        #expect(!browser.isOpen)
        #expect(controller.listings.isEmpty)
        #expect(controller.access == .needsSignIn(nil))
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) == nil)
    }

    /// A Polimi sign-in completed while the WeBeep account was unknown has no session owner, so
    /// nothing was saved. When an account then appears with that browser still open, the live
    /// session can't be attributed: it goes, and the page asks for a sign-in (#191). Only memory
    /// goes: the seen history's namespace is not rotated (the history is scoped by owner and
    /// would hold the same student's progress if the account merely became known).
    /// Guards a second student using the first one's Polimi login.
    /// Mutation: restore `guard let sessionOwner, sessionOwner != userID` (browser stays open).
    @Test func anAccountAppearingDropsALiveSessionWithNoOwner() async throws {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        world.owner = nil
        let controller = makeController()
        let namespace = defaults.string(forKey: RecordingsController.historyNamespaceKey)
        controller.pageAppeared()
        controller.signIn()
        await settle("signed in, page open") { controller.access == .ready && browser.isOpen }
        await controller.settleSessionFile()
        #expect(try store.load() == nil, "fixture: an unknown owner saves nothing")

        world.owner = 8
        controller.webBeepAccountChanged(to: 8)
        #expect(!browser.isOpen)
        #expect(controller.access == .needsSignIn(nil))
        #expect(defaults.string(forKey: RecordingsController.historyNamespaceKey) == namespace, "the seen history is untouched")
    }

    /// With no session owner, listings recorded under the account WeBeep reported at the time
    /// (`ownerUserID()` fallback) and their watch progress go when the account changes (#191);
    /// with nothing in memory, the account becoming known changes nothing (a normal launch
    /// stays free and a sign-in made meanwhile stays usable).
    /// Mutations: restore `guard let sessionOwner, sessionOwner != userID` (the listing and its
    /// progress stay for account 8); drop the `unattributedMemory` emptiness checks (the first
    /// `webBeepAccountChanged(to: 7)` asks for a sign-in).
    @Test func anAccountChangeWithNoSessionOwnerDropsListingsInMemory() async throws {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        world.owner = nil
        let controller = makeController()
        controller.signIn()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        world.owner = 7
        controller.webBeepAccountChanged(to: 7)
        #expect(controller.access == .ready, "nothing in memory: nothing dropped")

        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("listed under the reported account") { controller.listing(for: course)?.recordings?.count == 1 }
        #expect(!controller.watchProgress.known.isEmpty, "fixture: the listing's progress is known")
        await controller.settleSessionFile()
        #expect(try store.load() == nil, "fixture: still no session owner")

        world.owner = 8
        controller.webBeepAccountChanged(to: 8)
        #expect(controller.listings.isEmpty)
        #expect(controller.watchProgress.known.isEmpty)
        #expect(!browser.isOpen)
        #expect(controller.access == .needsSignIn(nil))
    }

    /// A file that can't be decoded (damage, a future version) is deleted and the user signs in
    /// again; one that can't be read right now (a disk error) is kept for the next try.
    @Test func anUndecodableSessionIsDeletedButAnUnreadableOneIsKept() async throws {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(Data("garbage".utf8))
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("asks for the sign-in") { controller.access == .needsSignIn(nil) }
        // The delete runs after the answer: wait for it, or it could remove the folder below.
        await controller.settleSessionFile()
        #expect(browser.calls.isEmpty)
        #expect(world.browsersMade == 0)
        #expect(try store.load() == nil)

        // A folder where the file should be: reading fails, and nothing is deleted.
        try FileManager.default.createDirectory(at: sessionFile, withIntermediateDirectories: true)
        let second = makeController()
        second.pageAppeared()
        second.refresh([course], selected: course)
        await settle("asks for the sign-in") { second.access == .needsSignIn(nil) }
        await second.settleSessionFile()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: sessionFile.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// Without a known account a session is never written: nothing could tell later whose it is.
    @Test func noSessionIsSavedWithoutAnOwner() async throws {
        defer { cleanUp() }
        let controller = makeController()
        controller.setEnabled(true)
        // The account becomes unknown before the sign-in task runs.
        world.owner = nil
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        #expect(try store.load() == nil)
    }

    /// A visit with nothing new writes nothing: neither the session (same cookies) nor the
    /// settings (no recording seen for the first time). A renewed cookie is saved.
    @Test func aVisitWithNothingNewWritesNothing() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("first listing") { controller.listing(for: course)?.recordings != nil }
        await drainTasks()
        let fileBefore = try #require(sessionFileNumber())
        defaults.resetWrites()

        controller.refresh([course], selected: course, force: true)
        await settle("second listing") { browser.listCalls.count == 2 && controller.listing(for: course)?.isLoading == false }
        await drainTasks()
        #expect(sessionFileNumber() == fileBefore, "the same session was written again")
        #expect(defaults.writes.isEmpty)

        browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "fresh"), FakeRecmanBrowser.cookie("JSESSIONID", value: "next", domain: "onlineservices.polimi.it")]
        controller.refresh([course], selected: course, force: true)
        await settle("renewed session saved") { sessionFileNumber() != fileBefore }
        #expect(try savedSession()?.cookies.map(\.name).sorted() == ["JSESSIONID", "SSO_LOGIN"])
    }

    // MARK: Loading

    /// The selected course goes first, then the others for their badges. A course loaded a moment
    /// ago isn't asked for again unless the user refreshes or it has grown old.
    @Test func selectedFirstThenOthersAndRecentOnesAreSkipped() async throws {
        defer { cleanUp() }
        for key in [course, other, third] { browser.listResults[key.courseCode] = .success([recording("r\(key.courseCode)", key)]) }
        let controller = await readyController()
        controller.refresh([course, other, third], selected: third)
        await settle("all listed") { [course, other, third].allSatisfy { controller.listing(for: $0)?.recordings != nil } }
        #expect(browser.listCalls == ["099999", "058167", "052499"])

        controller.refresh([course, other, third], selected: course)
        await drainTasks()
        #expect(browser.listCalls.count == 3)

        controller.refresh([course, other, third], selected: course, force: true)
        await settle("refreshed") { browser.listCalls.count == 6 }
        #expect(Array(browser.listCalls.suffix(3)) == ["058167", "052499", "099999"])
        world.now.addTimeInterval(RecordingsController.freshness + 1)
        controller.refresh([course], selected: course)
        await settle("stale course asked again") { browser.listCalls.count == 7 }
    }

    /// Bounded retention (#100): listings of courses that left the page are forgotten past the
    /// bound, oldest first, while the page's own courses are pinned and kept even beyond it, so
    /// going back to one of them is immediate. A forgotten course is simply asked for again.
    /// Fails with the old unbounded dictionary (the first courses stay) and if pins are ignored
    /// (the page's second course evicts its first before both are listed).
    @Test func listingsOffThePageAreBoundedWhileThePageKeepsItsOwn() async throws {
        defer { cleanUp() }
        for key in [course, other, third] { browser.listResults[key.courseCode] = .success([recording("r\(key.courseCode)", key)]) }
        let controller = await readyController(listingCapacity: 1)
        controller.refresh([course, other], selected: course)
        await settle("both listed") { [course, other].allSatisfy { controller.listing(for: $0)?.recordings != nil } }
        #expect(controller.listings.count == 2, "the page's own courses exceed the bound rather than vanish")

        controller.refresh([third], selected: third)
        await settle("third listed") { controller.listing(for: third)?.recordings != nil }
        #expect(controller.listing(for: course) == nil)
        #expect(controller.listing(for: other) == nil)
        #expect(controller.listings.count == 1)

        let calls = browser.listCalls.count
        controller.refresh([course], selected: course)
        await settle("forgotten course listed again") { controller.listing(for: course)?.recordings != nil }
        #expect(browser.listCalls.count == calls + 1)
    }

    /// The selected course is pinned with the page's keys even when it is not among them (#100):
    /// its listing, loaded earlier, stays while the page lists other courses past the bound.
    /// Fails if `refresh` pins only `keys`: listing `other` would then evict the selected course.
    @Test func theSelectedCourseIsKeptEvenWhenNotAmongThePageKeys() async throws {
        defer { cleanUp() }
        for key in [course, other] { browser.listResults[key.courseCode] = .success([recording("r\(key.courseCode)", key)]) }
        let controller = await readyController(listingCapacity: 1)
        controller.refresh([course], selected: course)
        await settle("selected listed") { controller.listing(for: course)?.recordings != nil }

        controller.refresh([other], selected: course)
        await settle("other listed") { controller.listing(for: other)?.recordings != nil }
        #expect(controller.listing(for: course)?.recordings != nil, "the selected course was evicted")
        #expect(controller.listings.pinnedKeys == [course, other])
    }

    /// Asking again for an unchanged page publishes nothing (#100): `listings` is published and
    /// the page asks for its courses on every appearance and change, so re-pinning the same keys
    /// would redraw the whole page for nothing. Fails if the pins are rewritten unconditionally.
    @Test func refreshingTheSamePageDoesNotRepublish() async throws {
        defer { cleanUp() }
        for key in [course, other] { browser.listResults[key.courseCode] = .success([recording("r\(key.courseCode)", key)]) }
        let controller = await readyController()
        controller.refresh([course, other], selected: course)
        await settle("both listed") { [course, other].allSatisfy { controller.listing(for: $0)?.recordings != nil } }
        await drainTasks()
        var changes = 0
        let subscription = controller.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        controller.refresh([course, other], selected: course)
        #expect(changes == 0, "an unchanged page republished the controller")
        #expect(controller.listings.pinnedKeys == [course, other])
    }

    /// Remembered Webex players are bounded too (#100): within the bound a second opening needs
    /// no lookup, past it the least recently found player is looked up again. Fails with the old
    /// unbounded dictionary, which never looks a player up twice.
    @Test func rememberedPlayersAreBounded() async throws {
        defer { cleanUp() }
        let a = recording("a")
        let b = recording("b")
        browser.listResults[course.courseCode] = .success([a, b])
        browser.playbackResults["a"] = .success(URL(string: "https://politecnicomilano.webex.com/a")!)
        browser.playbackResults["b"] = .success(URL(string: "https://politecnicomilano.webex.com/b")!)
        let controller = await readyController(playbackURLCapacity: 1)
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }

        controller.play(a)
        await settle("a opened") { world.opened.count == 1 }
        controller.play(a)
        await settle("a opened again") { world.opened.count == 2 }
        #expect(browser.playCalls == ["play a"], "a remembered player was looked up again")
        controller.play(b)
        await settle("b opened") { world.opened.count == 3 }
        controller.play(a)
        await settle("a opened once more") { world.opened.count == 4 }
        #expect(browser.playCalls == ["play a", "play b", "play a"], "past the bound the oldest player is forgotten")
    }

    /// A lapsed Polimi session stops the batch and asks for the sign-in, without saving; signing
    /// in again reloads the page's courses.
    @Test func aLapsedSessionAsksForSignInThenReloads() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        browser.listResults[other.courseCode] = .success([recording("b", other)])
        let controller = await readyController()
        controller.refresh([course, other], selected: course)
        await settle("asks for the sign-in") { controller.access == .needsSignIn(nil) }
        #expect(browser.listCalls == ["058167"])
        #expect(controller.listing(for: other)?.isLoading == false)
        #expect(!browser.isOpen)

        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.signIn()
        await settle("both reloaded") { controller.listing(for: other)?.recordings != nil && controller.listing(for: course)?.recordings != nil }
        #expect(controller.access == .ready)
        #expect(browser.openedWith.last == [], "a new sign-in must not reload the rejected session")
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"])
    }

    /// Offline: the first timeout ends the batch, and every waiting course says why instead of each
    /// waiting for its own timeout.
    @Test func beingOfflineStopsTheBatch() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unavailable)
        browser.listResults[other.courseCode] = .success([recording("b", other)])
        let controller = await readyController()
        controller.refresh([course, other], selected: course)
        await settle("both marked") { controller.listing(for: other)?.problem == .unavailable }
        #expect(browser.listCalls == ["058167"])
        #expect(controller.listing(for: course)?.problem == .unavailable)
        #expect(controller.listing(for: other)?.isLoading == false)
        #expect(controller.access == .ready)
    }

    /// Any other failure stays with its course: the rest still load, and an earlier list stays on
    /// screen under the warning.
    @Test func otherFailuresStayWithTheirCourse() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.listResults[other.courseCode] = .success([recording("b", other)])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }

        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.yearUnavailable)
        controller.refresh([course, other], selected: course, force: true)
        await settle("other listed") { controller.listing(for: other)?.recordings != nil }
        #expect(controller.listing(for: course)?.problem == .yearUnavailable)
        #expect(controller.listing(for: course)?.recordings?.map(\.id) == ["a"])
        #expect(controller.listing(for: course)?.isLoading == false)
    }

    /// Trying again clears the last failure while the new attempt runs. Guards against the
    /// warning staying next to the spinner, which reads as the new attempt having failed already
    /// (seen live on 2026-10-06: every course "Loading…" under "Polimi isn't responding").
    @Test func aNewAttemptReplacesTheLastFailure() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unavailable)
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("failed") { controller.listing(for: course)?.problem == .unavailable }

        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([recording("a")])
        controller.refresh([course], selected: course)
        #expect(controller.listing(for: course)?.isLoading == true)
        #expect(controller.listing(for: course)?.problem == nil)
        await settle("second request in flight") { gate.isWaiting }
        gate.release()
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(controller.listing(for: course)?.problem == nil)
    }

    /// Removing a queued course must stop its request and spinner without cancelling an
    /// explicit playback action or the currently running listing; reselecting loads it once.
    @Test(arguments: [false, true], [false, true])
    func removedQueuedCourseDoesNotLoad(copy: Bool, staleSelection: Bool) async {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([])
        browser.listResults[other.courseCode] = .success([])
        let player = URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=x")!
        browser.playbackResults["x"] = .success(player)
        let controller = await readyController()
        defer { controller.windowClosed() }
        controller.refresh([course, other], selected: course)
        await settle("first listing blocked") { gate.isWaiting }
        if copy { controller.copyLink(recording("x")) }
        else { controller.play(recording("x")) }
        controller.refresh([course], selected: staleSelection ? other : course)
        #expect(controller.listing(for: other)?.isLoading == false)
        #expect(controller.listing(for: course)?.isLoading == true)
        gate.release()
        await settle("explicit action completed") { controller.openingRecordingID == nil }
        await drainTasks()
        #expect(browser.listCalls == [course.courseCode])
        #expect(copy ? world.copied == [player] : world.opened == [player])
        controller.refresh([course, other], selected: other)
        controller.refresh([other, course], selected: other)
        await settle("reselected course loaded") { controller.listing(for: other)?.recordings != nil }
        await drainTasks()
        #expect(browser.listCalls == [course.courseCode, other.courseCode])
    }

    /// A Play clicked while a course is loading waits behind it; when that load finds Polimi
    /// unreachable, the Play is dropped with the rest of the batch and says why. Guards against
    /// the click doing nothing at all, as in the live check of 2026-10-06.
    @Test func aPlayDroppedWithTheBatchSaysWhy() async {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unavailable)
        browser.playbackResults["x"] = .success(URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=x")!)
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("request in flight") { gate.isWaiting }
        controller.play(recording("x"))
        #expect(controller.openingRecordingID == "x")
        #expect(controller.openingProblem == nil)
        gate.release()
        await settle("play dropped") { controller.openingRecordingID == nil }
        #expect(controller.openingProblem == .unavailable)
        #expect(browser.playCalls.isEmpty)
        #expect(world.opened.isEmpty)
    }

    // MARK: Stale answers

    /// An answer that arrives after the feature was turned off changes nothing and writes nothing:
    /// the switch and the deleted session stay as the user left them.
    @Test func aLateAnswerAfterTurningOffIsIgnored() async throws {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "late")]
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("request in flight") { gate.isWaiting }
        controller.setEnabled(false)
        gate.release()
        await drainTasks()
        await controller.settleSessionFile()
        #expect(controller.listings.isEmpty)
        #expect(try store.load() == nil)
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) == nil)
        #expect(defaults.object(forKey: RecordingsController.baselinedKey) == nil)
        #expect(!controller.isEnabled)
    }

    /// Closing the window stops the work and drops the browser at once; what was loading no longer
    /// spins, and a late answer isn't applied.
    @Test func closingTheWindowStopsWorkAndDropsTheBrowser() async {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        browser.listGates[course.courseCode] = gate
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("request in flight") { gate.isWaiting }
        controller.windowClosed()
        #expect(!browser.isOpen)
        #expect(controller.listing(for: course)?.isLoading == false)
        gate.release()
        await drainTasks()
        #expect(controller.listing(for: course)?.recordings == nil)
        #expect(controller.access == .ready)
        #expect(!browser.isOpen)
    }

    /// A language switch rebuilds the page (it disappears and appears in the same turn): the browser
    /// and its live session survive it. Leaving the page for real drops them.
    @Test func aRebuiltPageKeepsTheBrowserButLeavingDropsIt() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        await drainTasks()
        #expect(browser.isOpen)
        controller.pageDisappeared()
        controller.pageAppeared()
        await drainTasks()
        #expect(browser.isOpen)
        controller.pageDisappeared()
        await settle("browser dropped") { !browser.isOpen }
        // The lists stay, so the page shows them at once next time.
        #expect(controller.listing(for: course)?.recordings != nil)
    }

    /// A sign-in on screen survives the BeepBar window closing (the user may be typing in Polimi's
    /// window), and the browser goes once it ends.
    @Test func aSignInSurvivesTheWindowClosing() async throws {
        defer { cleanUp() }
        let gate = FakeRecmanBrowser.Gate()
        browser.signInGate = gate
        let controller = makeController()
        controller.pageAppeared()
        controller.setEnabled(true)
        await settle("sign-in on screen") { gate.isWaiting }
        controller.windowClosed()
        #expect(browser.isOpen)
        #expect(controller.access == .signingIn)
        gate.release()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        #expect(try savedSession()?.ownerUserID == 42)
    }

    // MARK: Opening

    /// Play opens the player in the browser and copy puts its link on the clipboard; the player is
    /// looked up once per recording, and opening clears the "new" dot.
    @Test func playAndCopyOpenTheRightPlayerOnce() async throws {
        defer { cleanUp() }
        let player = URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc")!
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.playbackResults["b"] = .success(player)
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        let fresh = recording("b", daysAgo: 0)
        browser.listResults[course.courseCode] = .success([fresh, recording("a")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }

        controller.play(fresh)
        #expect(controller.openingRecordingID == "b")
        await settle("opened") { world.opened == [player] }
        #expect(controller.openingRecordingID == nil)
        await settle("opened recording durably acknowledged") { controller.newCount(for: course) == 0 }
        controller.copyLink(fresh)
        #expect(world.copied == [player])
        #expect(browser.playCalls == ["play b"])
    }

    /// A player that can't be found says so, and the row stops spinning; nothing is opened.
    @Test func aMissingPlayerSaysSo() async {
        defer { cleanUp() }
        let controller = await readyController()
        controller.play(recording("x"))
        await settle("problem shown") { controller.openingProblem == .playbackUnavailable }
        #expect(controller.openingRecordingID == nil)
        #expect(world.opened.isEmpty)
        #expect(world.copied.isEmpty)
    }

    /// A slow old lookup must not overwrite a newer cached copy, or show its error after the
    /// newer choice succeeded. Both Play and Copy share this request ordering.
    @Test(arguments: [false, true])
    func aSlowOpeningCannotReplaceANewerCachedChoice(fails: Bool) async throws {
        defer { cleanUp() }
        let first = URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a")!
        let latest = URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=b")!
        browser.playbackResults["a"] = fails ? .failure(RecmanBrowserError.playbackUnavailable) : .success(first)
        browser.playbackResults["b"] = .success(latest)
        let controller = await readyController()
        controller.copyLink(recording("b"))
        await settle("latest player cached") { world.copied == [latest] }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.playbackGates["a"] = gate
        controller.copyLink(recording("a"))
        await settle("old lookup held") { gate.isWaiting }
        controller.copyLink(recording("b"))
        #expect(world.copied == [latest, latest])
        gate.release()
        // A subsequent list is a barrier: it runs only after the old opening finishes.
        browser.listResults[course.courseCode] = .success([])
        controller.refresh([course], selected: course)
        await settle("old lookup finished") { controller.listing(for: course)?.recordings != nil }
        #expect(world.copied == [latest, latest])
        #expect(controller.openingRecordingID == nil)
        #expect(controller.openingProblem == nil)
        #expect(controller.isNew(recording("a")))
    }

    /// A second Play while lookup is held opens only the last choice, including a repeated Play
    /// of the same recording. The held request may cache its URL, but never opens a stale tab.
    @Test(arguments: ["a", "b"])
    func onlyTheLatestPlayOpensWhileALookupIsRunning(latestID: String) async {
        defer { cleanUp() }
        let first = URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a")!
        let other = URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=b")!
        browser.playbackResults["a"] = .success(first)
        browser.playbackResults["b"] = .success(other)
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.playbackGates["a"] = gate
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("first lookup held") { gate.isWaiting }
        controller.play(recording(latestID))
        gate.release()
        browser.listResults[course.courseCode] = .success([])
        controller.refresh([course], selected: course)
        await settle("openings finished") { controller.listing(for: course)?.recordings != nil }
        #expect(world.opened == [latestID == "a" ? first : other])
        #expect(browser.playCalls == (latestID == "a" ? ["play a"] : ["play a", "play b"]))
        #expect(controller.openingRecordingID == nil)
    }

    // MARK: New recordings

    /// The first listing of a course marks everything as seen; later arrivals are new until opened
    /// or marked seen, and stay new after a relaunch.
    @Test func onlyRecordingsPublishedLaterAreNew() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a"), recording("b")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(controller.newCount(for: course) == 0)
        #expect(controller.listing(for: course)?.seenIDs == ["a", "b"])

        browser.listResults[course.courseCode] = .success([recording("c", daysAgo: 0), recording("a"), recording("b")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }
        #expect(controller.isNew(recording("c")))
        #expect(controller.listing(for: course)?.seenIDs == ["a", "b"], "a new recording was marked seen without being opened")

        let relaunched = makeController()
        relaunched.pageAppeared()
        relaunched.refresh([course], selected: course)
        await settle("relaunch history loaded") { relaunched.listing(for: course)?.recordings != nil }
        #expect(relaunched.isNew(recording("c")))
        #expect(!relaunched.isNew(recording("a")))
        // A course never listed has no baseline, so nothing in it counts as new.
        #expect(!relaunched.isNew(recording("z", other)))

        relaunched.markSeen(course)
        await settle("acknowledgement committed") { relaunched.newCount(for: course) == 0 }
        let acknowledgedRelaunch = makeController()
        acknowledgedRelaunch.pageAppeared()
        acknowledgedRelaunch.refresh([course], selected: course)
        await settle("acknowledged relaunch loaded") { acknowledgedRelaunch.listing(for: course)?.recordings != nil }
        #expect(!acknowledgedRelaunch.isNew(recording("c")))
    }

    /// Guards #106: first baseline, cumulative cross-course history, mark seen and restart
    /// must not rotate an old recording into New when the former global cap is exceeded.
    @Test func historyBeyondFiveThousandSurvivesOtherCoursesAndRelaunch() async {
        defer { cleanUp() }
        let many = (0..<5_010).map { recording("id\($0)") }
        browser.listResults[course.courseCode] = .success(many)
        browser.listResults[other.courseCode] = .success((0..<3_000).map { recording("other\($0)", other) })
        let controller = await readyController()
        controller.refresh([course, other], selected: course)
        await settle("both listed") { controller.listing(for: other)?.recordings != nil }
        #expect(controller.newCount(for: course) == 0)
        #expect(controller.newCount(for: other) == 0)
        #expect(controller.listing(for: course)?.seenIDs?.count == 5_010)
        #expect(controller.listing(for: other)?.seenIDs?.count == 3_000)
        // An old lecture published later is still a new ID: lecture dates aren't checkpoints.
        let late = recording("late", daysAgo: 500)
        browser.listResults[course.courseCode] = .success(many + [late])
        controller.refresh([course], selected: course, force: true)
        await settle("late publication") { controller.newCount(for: course) == 1 }
        #expect(controller.isNew(late))
        controller.markSeen(course)
        await settle("all acknowledged") { controller.newCount(for: course) == 0 }
        let relaunched = makeController()
        relaunched.pageAppeared()
        relaunched.refresh([course, other], selected: course)
        await settle("all history reloaded") { relaunched.listing(for: other)?.recordings != nil }
        #expect(!relaunched.isNew(recording("id0")))
        #expect(!relaunched.isNew(late))
        #expect(!relaunched.isNew(recording("other0", other)))
        browser.listResults[course.courseCode] = .success(many + [late, recording("really-new")])
        relaunched.refresh([course], selected: course, force: true)
        await settle("real arrival") { relaunched.newCount(for: course) == 1 }
        #expect(relaunched.isNew(recording("really-new")))
        // Disappearance from a refresh must not prune history needed on reappearance.
        browser.listResults[course.courseCode] = .success([])
        controller.refresh([course], selected: course, force: true)
        await settle("empty refresh") { controller.listing(for: course)?.recordings == [] }
        browser.listResults[course.courseCode] = .success(many)
        controller.refresh([course], selected: course, force: true)
        await settle("old recordings return") { controller.listing(for: course)?.recordings?.count == many.count }
        #expect(controller.newCount(for: course) == 0)
    }

    /// A v1 upgrade preserves surviving IDs and baselines; previously evicted IDs are
    /// indistinguishable from new publications and stay New until explicitly acknowledged.
    @Test func migrationPreservesSurvivorsWithoutInventingLostHistory() async throws {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        defaults.set(["survivor"], forKey: RecordingsController.acknowledgedKey)
        defaults.set([RecordingsController.baselineID(courseCode: course.courseCode, academicYear: course.academicYear)], forKey: RecordingsController.baselinedKey)
        try saveSession(owner: 42)
        browser.listResults[course.courseCode] = .success([recording("survivor"), recording("lost"), recording("new", daysAgo: 300)])
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("migrated listing") { controller.listing(for: course)?.recordings != nil }
        #expect(!controller.isNew(recording("survivor")))
        #expect(controller.newCount(for: course) == 2)
        #expect(defaults.object(forKey: RecordingsController.acknowledgedKey) == nil)
        let relaunched = makeController()
        relaunched.pageAppeared()
        relaunched.refresh([course], selected: course)
        await settle("migrated relaunch loaded") { relaunched.listing(for: course)?.recordings != nil }
        #expect(!relaunched.isNew(recording("survivor")))
        #expect(relaunched.isNew(recording("lost")))
        relaunched.markSeen(course)
        await settle("migrated recordings acknowledged") { relaunched.newCount(for: course) == 0 }
        let acknowledgedRelaunch = makeController()
        acknowledgedRelaunch.pageAppeared()
        acknowledgedRelaunch.refresh([course], selected: course)
        await settle("migrated acknowledgement reloaded") { acknowledgedRelaunch.listing(for: course)?.recordings != nil }
        #expect(!acknowledgedRelaunch.isNew(recording("lost")))
    }

    /// v1 preferences contain no account ID. A missing saved session cannot prove whose
    /// history survived, so a new account's first listing must establish a clean baseline.
    @Test func migrationWithoutOwnedSessionDoesNotInheritLegacyBaseline() async {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        defaults.set(["old-owner"], forKey: RecordingsController.acknowledgedKey)
        defaults.set([RecordingsController.baselineID(courseCode: course.courseCode, academicYear: course.academicYear)], forKey: RecordingsController.baselinedKey)
        let controller = makeController()
        controller.pageAppeared()
        await settle("unowned legacy history dropped") { defaults.object(forKey: RecordingsController.acknowledgedKey) == nil }
        controller.signIn()
        await settle("signed in") { controller.access == .ready }
        browser.listResults[course.courseCode] = .success([recording("fresh-owner")])
        controller.refresh([course], selected: course)
        await settle("clean first listing") { controller.listing(for: course)?.recordings != nil }
        #expect(controller.newCount(for: course) == 0)
        #expect(controller.listing(for: course)?.seenIDs == ["fresh-owner"])
    }

    /// Disk failure leaves legacy data available for retry and reports it instead of
    /// publishing a false saved baseline. Recovery must preserve the surviving v1 IDs.
    @Test func failedMigrationPreservesLegacyForRetry() async throws {
        defer { cleanUp() }
        defaults.set(true, forKey: RecordingsController.enabledKey)
        defaults.set(["survivor"], forKey: RecordingsController.acknowledgedKey)
        defaults.set([RecordingsController.baselineID(courseCode: course.courseCode, academicYear: course.academicYear)], forKey: RecordingsController.baselinedKey)
        try saveSession(owner: 42)
        let database = folder.appendingPathComponent(RecordingsSeenStore.fileName)
        try Data("not sqlite".utf8).write(to: database)
        browser.listResults[course.courseCode] = .success([recording("survivor"), recording("lost")])
        let controller = makeController()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("history failure") { controller.listing(for: course)?.problem == .historyUnavailable }
        #expect(defaults.stringArray(forKey: RecordingsController.acknowledgedKey) == ["survivor"])
        try FileManager.default.removeItem(at: database)
        controller.refresh([course], selected: course, force: true)
        await settle("retry recovered") { controller.newCount(for: course) == 1 }
        #expect(!controller.isNew(recording("survivor")))
        #expect(controller.isNew(recording("lost")))
    }

    /// Slow disk work must neither run on main nor delay page close. A late history result
    /// from the closed page's generation must not replace its previous successful listing.
    @Test func historyRunsOffMainAndLateResultCannotReviveClosedPage() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("old")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("baseline") { controller.listing(for: course)?.recordings != nil }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        world.historyReadGate = gate
        browser.listResults[course.courseCode] = .success([recording("old"), recording("late")])
        controller.refresh([course], selected: course, force: true)
        await settle("history worker held") { gate.isWaiting }
        #expect(controller.listing(for: course)?.recordings == [recording("old")])
        controller.windowClosed()
        #expect(!browser.isOpen)
        #expect(controller.listing(for: course)?.isLoading == false)
        gate.release()
        await drainTasks()
        #expect(controller.listing(for: course)?.recordings == [recording("old")])
        #expect(controller.newCount(for: course) == 0)
        #expect(world.historyFiles.allIOWasOffMain)
    }

    /// A transient history read error must keep the list and its matching seen snapshot
    /// together. A fresh network list paired with the old snapshot would invent new dots.
    @Test func transientHistoryFailureRetainsPreviousListAndRetries() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("old"), recording("seenPreviously")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("baseline") { controller.listing(for: course)?.recordings != nil }
        // This seen ID disappears from the current snapshot but remains in durable history.
        browser.listResults[course.courseCode] = .success([recording("old")])
        controller.refresh([course], selected: course, force: true)
        await settle("only old remains visible") { controller.listing(for: course)?.recordings?.count == 1 }
        let database = folder.appendingPathComponent(RecordingsSeenStore.fileName)
        let backup = folder.appendingPathComponent("saved-history.fixture")
        try FileManager.default.moveItem(at: database, to: backup)
        try Data("broken database".utf8).write(to: database)
        browser.listResults[course.courseCode] = .success([recording("old"), recording("seenPreviously"), recording("arrival")])
        controller.refresh([course], selected: course, force: true)
        await settle("history failure") { controller.listing(for: course)?.problem == .historyUnavailable }
        #expect(controller.listing(for: course)?.recordings == [recording("old")])
        #expect(controller.listing(for: course)?.seenIDs == ["old"])
        #expect(controller.newCount(for: course) == 0)
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: backup, to: database)
        // A failed history load is retryable even within the normal five-minute freshness.
        controller.refresh([course], selected: course)
        await settle("retry classified arrival") { controller.newCount(for: course) == 1 }
        #expect(!controller.isNew(recording("old")))
        #expect(!controller.isNew(recording("seenPreviously")))
        #expect(controller.isNew(recording("arrival")))
        #expect(controller.listing(for: course)?.problem == nil)
    }

    /// Saving visible acknowledgements after recovering the disk must not clear a failed
    /// list refresh's error/freshness state; the next refresh still needs to classify new IDs.
    @Test func acknowledgementSuccessDoesNotHideFailedListRefresh() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("old")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("baseline") { controller.listing(for: course)?.recordings != nil }
        browser.listResults[course.courseCode] = .success([recording("old"), recording("first")])
        controller.refresh([course], selected: course, force: true)
        await settle("first arrival") { controller.newCount(for: course) == 1 }
        let database = folder.appendingPathComponent(RecordingsSeenStore.fileName)
        let backup = folder.appendingPathComponent("saved-history.fixture")
        try FileManager.default.moveItem(at: database, to: backup)
        try Data("broken".utf8).write(to: database)
        browser.listResults[course.courseCode] = .success([recording("old"), recording("first"), recording("second")])
        controller.refresh([course], selected: course, force: true)
        await settle("failed read") { controller.listing(for: course)?.problem == .historyUnavailable }
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: backup, to: database)
        controller.markSeen(course)
        await settle("visible recordings acknowledged") { controller.newCount(for: course) == 0 }
        #expect(controller.listing(for: course)?.problem == .historyUnavailable)
        #expect(controller.listing(for: course)?.recordings?.count == 2)
        controller.refresh([course], selected: course)
        await settle("failed refresh still retryable") { controller.newCount(for: course) == 1 }
        #expect(controller.isNew(recording("second")))
    }

    /// Failed cleanup leaves an obsolete file, but the persisted namespace tombstone keeps
    /// it inaccessible on same-account re-enable and relaunch. Later work retries deletion.
    @Test func failedCleanupNeverReusesOldBaselineAfterReenableAndRelaunch() async {
        defer { world.historyFiles.setRemovalFailure(false); cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("old")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("old baseline") { controller.listing(for: course)?.recordings != nil }
        let oldDatabase = folder.appendingPathComponent(RecordingsSeenStore.fileName)
        world.historyFiles.setRemovalFailure(true)
        controller.setEnabled(false)
        await drainTasks()
        #expect(FileManager.default.fileExists(atPath: oldDatabase.path))
        #expect(defaults.string(forKey: RecordingsController.historyNamespaceKey) != nil)
        browser.listResults[course.courseCode] = .success([recording("fresh")])
        controller.setEnabled(true)
        await settle("reenabled sign-in") { controller.access == .ready }
        controller.refresh([course], selected: course)
        await settle("new namespace baseline") { controller.listing(for: course)?.recordings != nil }
        #expect(controller.newCount(for: course) == 0)
        #expect(controller.listing(for: course)?.seenIDs == ["fresh"])
        controller.windowClosed()
        let relaunched = makeController()
        relaunched.pageAppeared()
        relaunched.refresh([course], selected: course)
        await settle("new namespace relaunched") { relaunched.listing(for: course)?.recordings != nil }
        #expect(relaunched.newCount(for: course) == 0)
        browser.listResults[course.courseCode] = .success([recording("fresh"), recording("arrival")])
        relaunched.refresh([course], selected: course, force: true)
        await settle("new namespace arrival") { relaunched.newCount(for: course) == 1 }
        world.historyFiles.setRemovalFailure(false)
        relaunched.refresh([course], selected: course, force: true)
        await settle("obsolete file removal retried") { !FileManager.default.fileExists(atPath: oldDatabase.path) }
        #expect(relaunched.newCount(for: course) == 1)
    }

    /// A user action held before its disk write must be rejected after reset; releasing it
    /// must not recreate the deleted old file or put its acknowledgement in the new namespace.
    @Test func heldAcknowledgementCannotRecreateHistoryAfterReset() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("old")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("baseline") { controller.listing(for: course)?.recordings != nil }
        browser.listResults[course.courseCode] = .success([recording("old"), recording("new")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        world.historyAcknowledgeGate = gate
        controller.markSeen(course)
        await settle("acknowledgement held") { gate.isWaiting }
        controller.setEnabled(false)
        let oldDatabase = folder.appendingPathComponent(RecordingsSeenStore.fileName)
        await settle("old namespace removed") { !FileManager.default.fileExists(atPath: oldDatabase.path) }
        controller.setEnabled(true)
        await settle("reenabled") { controller.access == .ready }
        browser.listResults[course.courseCode] = .success([recording("fresh")])
        controller.refresh([course], selected: course)
        await settle("new baseline") { controller.listing(for: course)?.recordings != nil }
        gate.release()
        await drainTasks()
        #expect(!FileManager.default.fileExists(atPath: oldDatabase.path))
        #expect(controller.listing(for: course)?.seenIDs == ["fresh"])
    }

    /// Page closure changes the generation but a requested, scoped acknowledgement is still
    /// durable. Reopening while it commits must eventually show the committed seen state.
    @Test func pendingAcknowledgementSurvivesPageCloseAndReopen() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("old")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("baseline") { controller.listing(for: course)?.recordings != nil }
        browser.listResults[course.courseCode] = .success([recording("old"), recording("new")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        world.historyAcknowledgeGate = gate
        controller.markSeen(course)
        await settle("acknowledgement held") { gate.isWaiting }
        controller.windowClosed()
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("reopened listing loaded") { controller.listing(for: course)?.isLoading == false }
        gate.release()
        await settle("pending acknowledgement published") { controller.newCount(for: course) == 0 }
        let relaunched = makeController()
        relaunched.pageAppeared()
        relaunched.refresh([course], selected: course)
        await settle("durable acknowledgement after relaunch") { relaunched.listing(for: course)?.recordings != nil }
        #expect(relaunched.newCount(for: course) == 0)
    }

    /// Repeated Mark as seen clicks while storage is slow must share the pending IDs,
    /// rather than queue one identical task and retained list per click.
    @Test func repeatedAcknowledgementsAreCoalescedWhileDiskIsSlow() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("old")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("baseline") { controller.listing(for: course)?.recordings != nil }
        browser.listResults[course.courseCode] = .success([recording("old"), recording("new")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        world.historyAcknowledgeGate = gate
        for _ in 0..<100 { controller.markSeen(course) }
        await settle("one acknowledgement held") { gate.isWaiting }
        await drainTasks()
        #expect(world.historyAcknowledgementsStarted == 1)
        gate.release()
        await settle("acknowledgement committed") { controller.newCount(for: course) == 0 }
        #expect(world.historyAcknowledgementsStarted == 1)
    }

    /// A read snapshot can return after a newer acknowledgement. Revision validation must
    /// requery rather than resurrect that recording's dot with the earlier snapshot.
    @Test func delayedReadCannotOverwriteNewerAcknowledgement() async {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("old")])
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("baseline") { controller.listing(for: course)?.recordings != nil }
        browser.listResults[course.courseCode] = .success([recording("old"), recording("new")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        world.historyAfterReadGate = gate
        controller.refresh([course], selected: course, force: true)
        await settle("old snapshot held") { gate.isWaiting }
        controller.markSeen(course)
        await settle("new acknowledgement committed") { controller.newCount(for: course) == 0 }
        gate.release()
        await settle("delayed refresh finished") { controller.listing(for: course)?.isLoading == false }
        #expect(controller.newCount(for: course) == 0)
    }

    /// Every Recman failure maps to a message; a lapsed session or an unknown error reads as an
    /// unrecognized archive, never as an empty list.
    @Test func everyFailureHasAMessage() {
        #expect(RecordingsProblem(RecmanBrowserError.needsSignIn) == .unrecognized)
        #expect(RecordingsProblem(CocoaError(.fileReadUnknown)) == .unrecognized)
        #expect(RecordingsProblem(RecmanBrowserError.incomplete) == .incomplete)
        for problem in [RecordingsProblem.unavailable, .unrecognized, .incomplete, .yearUnavailable, .playbackUnavailable] {
            #expect(!problem.message.isEmpty)
        }
    }
    /// Explicit study choices survive a restart without waiting for any course listing.
    @Test func watchlistRestoresMetadataAndNavigationWithoutNetwork() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("lesson", course)
        let b = recording("other", other)
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.toggleWatchlist(b, courseName: "HPC")
        controller.selectDestination(.watchlist)
        let restored = makeController(useDefault: true)
        let calls = browser.calls
        restored.pageAppeared()
        #expect(restored.study.bookmarks.map(\.courseName) == ["NLA", "HPC"])
        #expect(restored.study.bookmarks.first?.recording == a)
        #expect(Set(restored.study.visibleBookmarks(query: "").map(\.recording.id)) == ["lesson", "other"])
        #expect(restored.study.destination == .watchlist)
        #expect(restored.listings.isEmpty)
        #expect(browser.calls == calls)
        restored.turnOff()
    }

    /// Reused recording IDs in another course or year never share bookmarked state.
    @Test func studyIdentitySeparatesCoursesYearsAndSupportsReversibleActions() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("shared", course)
        let b = recording("shared", other)
        let c = recording("shared", RecmanCourseKey(courseCode: course.courseCode, academicYear: 2025)!)
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.toggleWatchlist(b, courseName: "HPC")
        #expect(controller.study.contains(a) && controller.study.contains(b))
        #expect(!controller.study.contains(c))
        controller.toggleWatchlist(a, courseName: "NLA")
        #expect(!controller.study.contains(a) && controller.study.contains(b))
        controller.toggleWatchlist(a, courseName: "NLA")
        #expect(controller.study.bookmarks.count == 2)
        controller.turnOff()
    }

    /// Reading novelties, copying and playing never add or remove personal bookmarks.
    @Test func playbackCopyAndBaselineNeverChangeBookmarks() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("lecture")
        browser.listResults[course.courseCode] = .success([a])
        browser.playbackResults[a.id] = .success(URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=lecture")!)
        controller.pageAppeared()
        controller.refresh([course], selected: course)
        await settle("course loaded") { controller.listing(for: course)?.recordings != nil }
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.markSeen(course)
        controller.copyLink(a)
        await settle("copied") { !world.copied.isEmpty }
        controller.play(a)
        await settle("played") { !world.opened.isEmpty }
        #expect(controller.study.contains(a))
        #expect(controller.study.bookmarks.count == 1)
        controller.turnOff()
    }

    /// A different account loads its own choices even if there is no saved browser-session owner.
    @Test func studyAccountChangesNeverLeakAndReturnRestoresChoices() async {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        let a = recording("private")
        controller.toggleWatchlist(a, courseName: "NLA")
        let b = recording("other-account")
        world.owner = 99
        controller.webBeepAccountChanged(to: 99)
        #expect(controller.study.bookmarks.isEmpty)
        controller.toggleWatchlist(b, courseName: "HPC")
        world.owner = 42
        controller.webBeepAccountChanged(to: 42)
        #expect(controller.study.contains(a))
        #expect(!controller.study.contains(b))
        world.owner = 99
        controller.webBeepAccountChanged(to: 99)
        #expect(controller.study.contains(b))
        #expect(!controller.study.contains(a))
        controller.turnOff()
    }

    /// Disabling or renewing browser credentials must not erase the personal study queue.
    @Test func disablingAndFailedSignInPreserveStudyChoices() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("keep")
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.turnOff()
        #expect(controller.study.bookmarks.isEmpty)
        browser.signInError = RecmanBrowserError.unavailable
        controller.setEnabled(true)
        await settle("sign-in failed") { controller.access == .needsSignIn(.unavailable) }
        controller.pageAppeared()
        #expect(controller.study.contains(a))
        #expect(controller.studyProblem == nil)
        controller.turnOff()
    }

    /// Bad saved data is reported and preserved rather than overwritten by an empty watchlist.
    @Test func unreadableStudyPreservesOriginalAndRejectsEdits() {
        defer { cleanUp() }
        let key = RecordingsController.studyKey(owner: 42)
        let original = Data("not a plist".utf8)
        defaults.set(original, forKey: key)
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        #expect(controller.studyProblem != nil)
        #expect(!controller.canEditStudy)
        controller.toggleWatchlist(recording("lost"), courseName: "NLA")
        controller.selectDestination(.course(17))
        #expect(controller.study.destination == .course(17))
        #expect(defaults.data(forKey: key) == original)
        controller.turnOff()
    }

    /// Only successful listings update snapshots or availability; failures/cancellation cannot drop a bookmark.
    @Test func refreshUpdatesBookmarksAndMarksMissingWithoutDeleting() async {
        defer { cleanUp() }
        let controller = await readyController()
        let a = recording("keep")
        controller.toggleWatchlist(a, courseName: "NLA")
        controller.pageAppeared()
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.unavailable)
        controller.refresh([course], selected: course, force: true)
        await settle("failed") { controller.listing(for: course)?.problem == .unavailable }
        #expect(controller.study.bookmarks.first?.unavailable == false)
        browser.listResults[course.courseCode] = .success([])
        controller.refresh([course], selected: course, force: true)
        await settle("missing") { controller.study.bookmarks.first?.unavailable == true }
        #expect(controller.study.contains(a))
        let updated = RecmanRecording(id: a.id, courseCode: a.courseCode, academicYear: a.academicYear, title: "Renamed", recordedAt: a.recordedAt, kind: a.kind, duration: "70 min", size: a.size, previewURL: a.previewURL)
        browser.listResults[course.courseCode] = .success([updated])
        controller.refresh([course], selected: course, force: true)
        await settle("returned") { controller.study.bookmarks.first?.recording.title == "Renamed" }
        #expect(controller.study.bookmarks.first?.unavailable == false)
        controller.turnOff()
    }

    /// No valid account means no personal state can be written or borrowed from another account.
    @Test func unknownOwnerCannotEditStudy() {
        defer { cleanUp() }
        world.owner = nil
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        defaults.resetWrites()
        controller.toggleWatchlist(recording("a"), courseName: "NLA")
        #expect(controller.study.bookmarks.isEmpty)
        #expect(defaults.writes.isEmpty)
        controller.turnOff()
    }

    // MARK: Native playback (#148)

    private func stream(_ id: String) -> RecordingStream {
        RecordingStream(url: URL(string: "https://nfg1wss.webex.com/nbr/\(id)/hls.m3u8")!, title: "Webex \(id)", duration: 6_000)
    }

    private func playerLink(_ id: String) -> URL {
        URL(string: "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=\(id)")!
    }

    private var resumeKey: String { RecordingsController.resumePointsKey }

    private func resumeWrites() -> Int { defaults.writes.filter { $0 == resumeKey }.count }

    private func storedResumePoints() throws -> RecordingResumePoints? {
        guard let data = defaults.data(forKey: resumeKey) else { return nil }
        return try PropertyListDecoder().decode(RecordingResumePoints.self, from: data)
    }

    /// Play streams the lecture in BeepBar's player and opens nothing in the browser; the player
    /// gets the archive's title, no cookies (the stream needs none) and no resume position the
    /// first time; the lecture stops being new and the player did not exist before the Play.
    /// Guards against Play still opening the browser, or the player being built at launch.
    /// Mutation: in `playNatively` open the link instead of `startPlayer` and `plays` stays empty.
    @Test func playStreamsInTheNativePlayerAndCreatesItOnlyThen() async throws {
        defer { cleanUp() }
        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.streamResults["b"] = [.success(stream("b"))]
        let controller = await readyController()
        controller.refresh([course], selected: course)
        await settle("listed") { controller.listing(for: course)?.recordings != nil }
        #expect(world.playersMade == 0, "nothing of the player exists before the first Play")
        let fresh = recording("b", daysAgo: 0)
        browser.listResults[course.courseCode] = .success([fresh, recording("a")])
        controller.refresh([course], selected: course, force: true)
        await settle("new recording") { controller.newCount(for: course) == 1 }

        controller.play(fresh)
        #expect(controller.openingRecordingID == "b")
        await settle("player started") { world.player.plays.count == 1 }
        #expect(world.playersMade == 1)
        #expect(world.player.plays == [.init(url: stream("b").url, title: "Lezione b", startAt: nil, recordingID: "b", cookies: 0)])
        #expect(world.opened.isEmpty, "the browser is not opened")
        #expect(browser.playCalls.isEmpty, "the player link is not even looked up")
        #expect(browser.streamEmails == [nil])
        #expect(controller.openingRecordingID == nil)
        #expect(controller.openingProblem == nil)
        await settle("opened lecture durably acknowledged") { controller.newCount(for: course) == 0 }
        controller.turnOff()
    }

    /// Everything the native path can't do falls back to the browser, as Play always did; the
    /// failures the page already explains stay failures, and a missing confirmed email shows the
    /// product decision's sentence with no browser and no player.
    /// Mutation: map `.needsEmail` to `.browser` in `streamFailureOutcome` and the last case fails.
    @Test(arguments: ["playbackUnavailable", "unrecognized", "network error", "needsEmail", "needsSignIn", "unavailable"])
    func aStreamThatCantBeUsedFallsBackOrReports(failure: String) async throws {
        defer { cleanUp() }
        let error: Error = switch failure {
        case "playbackUnavailable": RecmanBrowserError.playbackUnavailable
        case "unrecognized": RecmanBrowserError.unrecognized
        case "network error": URLError(.notConnectedToInternet)
        case "needsEmail": RecmanBrowserError.needsEmail
        case "needsSignIn": RecmanBrowserError.needsSignIn
        default: RecmanBrowserError.unavailable
        }
        browser.streamResults["a"] = [.failure(error)]
        browser.playbackResults["a"] = .success(playerLink("a"))
        let controller = await readyController()
        controller.play(recording("a"))
        switch failure {
        case "playbackUnavailable", "unrecognized", "network error":
            await settle("browser opened") { world.opened == [playerLink("a")] }
            #expect(controller.openingProblem == nil)
        case "needsEmail":
            await settle("problem shown") { controller.openingProblem == .playbackUnavailable }
            #expect(controller.openingProblem?.message == "Non è stato possibile aprire questa registrazione.")
            #expect(world.opened.isEmpty, "no Webex page is shown to the student")
            #expect(browser.playCalls.isEmpty)
        case "needsSignIn":
            await settle("sign-in asked") { controller.access == .needsSignIn(nil) }
            #expect(world.opened.isEmpty)
        default:
            await settle("problem shown") { controller.openingProblem == .unavailable }
            #expect(world.opened.isEmpty)
        }
        #expect(world.player.plays.isEmpty)
        #expect(controller.openingRecordingID == nil)
        controller.turnOff()
    }

    /// Which failures fall back and which are reported, and what each player failure asks for.
    /// Pure, so the table is checked directly. Mutation: return `.freshStream` when
    /// `alreadyRecovered` and the second row fails.
    @Test func theFailureDecisionTables() {
        typealias Controller = RecordingsController
        #expect(Controller.streamFailureOutcome(RecmanBrowserError.playbackUnavailable) == .browser)
        #expect(Controller.streamFailureOutcome(RecmanBrowserError.unrecognized) == .browser)
        #expect(Controller.streamFailureOutcome(URLError(.timedOut)) == .browser)
        #expect(Controller.streamFailureOutcome(RecmanBrowserError.needsEmail) == .report)
        #expect(Controller.streamFailureOutcome(RecmanBrowserError.needsSignIn) == .report)
        #expect(Controller.streamFailureOutcome(RecmanBrowserError.unavailable) == .report)
        #expect(Controller.streamFailureOutcome(CancellationError()) == .report)

        #expect(Controller.recovery(for: .beforeReady(nil), alreadyRecovered: false) == .browser)
        #expect(Controller.recovery(for: .duringPlayback(nil, position: 321), alreadyRecovered: false) == .freshStream(at: 321))
        #expect(Controller.recovery(for: .duringPlayback(nil, position: 321), alreadyRecovered: true) == .browser)
    }

    /// Package F diagnostics: each way a Play can miss the player is logged under its own
    /// reason, with what happens next, and the line holds only names (no email, address or
    /// title). Before the fix all of them logged the same "opening the browser" line. Mutation:
    /// map `.needsEmail` to `.nativeUnavailable` in `playFailureReason` and the no-email row fails.
    @Test func everyPlayFailureIsLoggedUnderItsOwnReason() {
        typealias Controller = RecordingsController
        #expect(Controller.playDiagnosis(RecmanBrowserError.playbackUnavailable) == "play: fallback=browser reason=native-unavailable error=playbackUnavailable")
        #expect(Controller.playDiagnosis(RecmanBrowserError.needsEmail) == "play: fallback=none reason=no-email error=needsEmail")
        #expect(Controller.playDiagnosis(RecmanBrowserError.needsSignIn) == "play: fallback=none reason=needs-sign-in error=needsSignIn")
        #expect(Controller.playDiagnosis(RecmanBrowserError.unavailable) == "play: fallback=none reason=unreachable error=unavailable")
        #expect(Controller.playDiagnosis(RecmanBrowserError.unrecognized) == "play: fallback=browser reason=stream-error error=unrecognized")
        #expect(Controller.playDiagnosis(CancellationError()) == "play: fallback=none reason=cancelled error=cancelled")
        // A URLError's user info carries the failing address: only its code is written.
        let network = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://nfg1wss.webex.com/nbr/secret/hls.m3u8"])
        #expect(Controller.playDiagnosis(network) == "play: fallback=browser reason=stream-error error=URLError(-1001)")

        // A stream that was found but never played: the player's failure, with AVFoundation's
        // domain and code and the underlying cause, never the address in its user info.
        let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12660)
        let avError = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: underlying,
            NSURLErrorFailingURLErrorKey: URL(string: "https://nfg1wss.webex.com/nbr/secret/hls.m3u8")!,
        ])
        let beforeReady = Controller.playerFailureDiagnosis(.beforeReady(avError), recovery: .browser)
        #expect(beforeReady == "play: player failed phase=before-ready recovery=browser reason=player-failure error=AVFoundationErrorDomain(-11800) underlying=CoreMediaErrorDomain(-12660)")
        #expect(Controller.playerFailureDiagnosis(.duringPlayback(nil, position: 30), recovery: .freshStream(at: 30))
            == "play: player failed phase=during-playback recovery=fresh-stream reason=player-failure error=none")
        #expect(!beforeReady.contains("secret") && !beforeReady.contains("http"))
    }

    /// "Apri nel browser" in a row's menu opens the Webex player in the browser and never asks
    /// for a stream; before the fix it called `play` and started BeepBar's player despite its
    /// name. A second click is answered from the cached link. Mutation: point the case's
    /// `finishOpening` at `.play`'s path (`playNatively`) and `streamCalls` is no longer empty.
    @Test func openInBrowserOpensTheBrowserWithoutTheNativePlayer() async throws {
        defer { cleanUp() }
        browser.playbackResults["a"] = .success(playerLink("a"))
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.openInBrowser(recording("a"))
        await settle("browser opened") { world.opened == [playerLink("a")] }
        #expect(browser.streamCalls.isEmpty, "no stream is asked for")
        #expect(world.player.plays.isEmpty)
        #expect(world.playersMade == 0)
        #expect(controller.openingRecordingID == nil)
        controller.openInBrowser(recording("a"))
        await settle("opened again") { world.opened.count == 2 }
        #expect(browser.playCalls.count == 1, "the second click uses the cached link")
        controller.turnOff()
    }

    /// A click replaced by a newer one while the stream is being found never starts the older
    /// lecture. Mutation: remove `guard request == openingRequest` in `playNatively`.
    @Test func onlyTheLatestPlayStartsTheNativePlayer() async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        browser.streamResults["b"] = [.success(stream("b"))]
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.streamGates["a"] = gate
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("first stream held") { gate.isWaiting }
        controller.play(recording("b"))
        gate.release()
        await settle("latest started") { world.player.plays.map(\.recordingID) == ["b"] }
        await drainTasks()
        #expect(world.player.plays.map(\.recordingID) == ["b"])
        controller.turnOff()
    }

    /// A newer Play stops the stale lookup instead of queueing behind it (issue #194): the first
    /// lookup, held as an interactive Webex sign-in would hold it, is cancelled, and the second
    /// starts and reaches the player while the first is still unreleased.
    /// Mutations: drop `runningPlay?.task.cancel()` in `open` (the second lookup never starts
    /// while the first is held); run `playNatively` inline in `drain` again (same).
    @Test func aNewerPlayCancelsTheStaleLookup() async {
        defer { cleanUp() }
        browser.streamHonorsCancellation = true
        browser.streamResults["a"] = [.success(stream("a"))]
        browser.streamResults["b"] = [.success(stream("b"))]
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.streamGates["a"] = gate
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("first stream held") { gate.isWaiting }
        controller.play(recording("b"))
        await settle("the newer Play reached the player") { world.player.plays.map(\.recordingID) == ["b"] }
        #expect(gate.cancelledWaits == 1, "the stale lookup was cancelled, not waited for")
        #expect(browser.streamCalls == ["stream a", "stream b"])
        #expect(world.opened.isEmpty, "a cancelled lookup opens no browser")
        #expect(controller.openingProblem == nil, "and reports nothing")
        controller.turnOff()
    }

    /// A second Play of the lecture already being looked up (a double click on the row) is served
    /// by that lookup: one stream request, one play (issue #194: it ran a second full lookup and
    /// threw the first away). Mutation: drop the same-lecture early return in `open` (a second
    /// stream request, or the first result discarded).
    @Test func aSecondPlayOfTheSameLectureJoinsTheRunningLookup() async {
        defer { cleanUp() }
        browser.streamHonorsCancellation = true
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.streamGates["a"] = gate
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("first stream held") { gate.isWaiting }
        controller.play(recording("a"))
        await drainTasks()
        #expect(gate.cancelledWaits == 0)
        gate.release()
        await settle("a playing") { world.player.plays.count == 1 }
        await drainTasks()
        #expect(browser.streamCalls == ["stream a"])
        #expect(world.player.plays.map(\.recordingID) == ["a"])
        controller.turnOff()
    }

    /// A Play again of the same lecture, clicked right after the player started but before the
    /// worker resumed from the finished lookup, restarts the lecture instead of joining a lookup
    /// that is already over (#194's same-lecture shortcut). The click is scheduled from inside
    /// the player's `play`, so it runs on the main actor after the lookup task ends and before
    /// `drain` resumes. Mutation: clear `runningPlay` only when `drain` resumes (drop the
    /// lookup task's own `defer`): the second click is swallowed.
    @Test func aPlayAgainRightAfterThePlayerStartedIsNotSwallowed() async {
        defer { cleanUp() }
        browser.streamHonorsCancellation = true
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        world.player.afterPlay = { [weak controller] in
            world.player.afterPlay = nil
            Task { @MainActor in controller?.play(recording("a")) }
        }
        controller.play(recording("a"))
        await settle("played again") { world.player.plays.count == 2 }
        #expect(browser.streamCalls == ["stream a", "stream a"])
        controller.turnOff()
    }

    /// A stream found after the feature was turned off starts nothing. Mutation: remove the
    /// generation guard after the stream in `playNatively`.
    @Test func aLateStreamAfterTurningOffStartsNothing() async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.streamGates["a"] = gate
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("stream held") { gate.isWaiting }
        controller.turnOff()
        gate.release()
        await drainTasks()
        #expect(world.player.plays.isEmpty)
        #expect(world.playersMade == 0)
    }

    // MARK: Where you stopped

    /// The place is written only when the player reports it, once per change, and a later Play of
    /// the same lecture resumes there. Guards against periodic writes (nothing is written while
    /// playing), duplicate writes, and a Play that forgets the place.
    /// Mutations: drop `startAt:` in `playNatively` (the third play has no position); write in
    /// `startPlayer` (the "nothing written yet" expectation fails).
    @Test func theStoppedPlaceIsWrittenOnReportsAndResumed() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        browser.streamResults["b"] = [.success(stream("b"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(try world.player.play(0).startAt == nil)
        #expect(resumeWrites() == 0, "nothing is written until the player reports")

        world.player.pause(at: 1_800)
        #expect(resumeWrites() == 1)
        #expect(try storedResumePoints()?.position(for: RecordingsStudyState.identity(recording("a"))) == 1_800)
        world.player.pause(at: 1_800)
        #expect(resumeWrites() == 1, "the same place is not written again")

        controller.play(recording("b"))
        await settle("b playing") { world.player.plays.count == 2 }
        #expect(try world.player.play(1).startAt == nil, "another lecture starts from the beginning")
        controller.play(recording("a"))
        await settle("a again") { world.player.plays.count == 3 }
        #expect(try world.player.play(2).startAt == 1_800)
        controller.turnOff()
    }

    /// A lecture watched to its end is forgotten: it starts from the beginning next time, and
    /// stopping near the start stores nothing. Mutation: treat `.finished` like `.remember` in
    /// `RecordingResumePoints.apply` and the position stays.
    @Test func aFinishedLectureStartsOverAndLeavesNothingStored() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.player.pause(at: 900)
        #expect(try storedResumePoints()?.entries.count == 1)
        world.player.pause(at: 5_990)
        #expect(defaults.object(forKey: resumeKey) == nil, "the last place is forgotten, and so is an empty memory")
        controller.play(recording("a"))
        await settle("a again") { world.player.plays.count == 2 }
        #expect(try world.player.play(1).startAt == nil)
        world.player.pause(at: 2)
        #expect(defaults.object(forKey: resumeKey) == nil)
        controller.turnOff()
    }

    /// Positions stored for another WeBeep account are never used, while this account's are.
    /// Mutation: drop the `stored.owner == owner` comparison in `loadedResumePoints`.
    @Test(arguments: [7, 42])
    func positionsBelongToTheirAccount(owner: Int) async throws {
        defer { cleanUp() }
        var points = RecordingResumePoints(owner: owner)
        points.apply(.remember(999), for: RecordingsStudyState.identity(recording("a")))
        defaults.set(try PropertyListEncoder().encode(points), forKey: resumeKey)
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(try world.player.play(0).startAt == (owner == 42 ? 999 : nil))
        controller.turnOff()
    }

    /// Disconnecting and an account change forget the places and close the player, and the close's
    /// own last report is refused instead of being written and then erased: the stored place
    /// is written once and removed once, nothing in between.
    /// Mutation: call `player?.close()` before clearing `nowPlaying` in
    /// `closePlayerForIdentityChange` and the write count is 3. The address removal
    /// (`emailDeclinedKey`) goes too: drop `forgetEmailOptOut()` from `turnOff` or
    /// `webBeepAccountChanged` and the next account would never get its address pre-filled.
    @Test(arguments: ["disconnect", "account change"])
    func identityChangesCloseThePlayerAndForgetPlaces(change: String) async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.player.pause(at: 1_800)
        #expect(defaults.data(forKey: resumeKey) != nil)
        world.player.move(to: 2_500)
        defaults.set(42, forKey: RecordingsController.emailDeclinedKey)

        if change == "disconnect" {
            controller.turnOff()
        } else {
            world.owner = 7
            controller.webBeepAccountChanged(to: 7)
        }
        #expect(world.player.closes == 1)
        #expect(!world.player.isOpen)
        #expect(defaults.object(forKey: resumeKey) == nil)
        #expect(resumeWrites() == 2, "one write, one removal: the close's report at 2 500 s wrote nothing")
        #expect(defaults.object(forKey: RecordingsController.emailDeclinedKey) == nil, "a removed address belongs to the account that removed it")
        await controller.settleSessionFile()
        #expect(try store.load() == nil)
        controller.turnOff()
    }

    /// Disabling keeps the player's final checkpoint, including after a relaunch.
    /// Removing the preservation flag from setEnabled loses the stored position.
    @Test func disablingKeepsTheLastPlaybackPosition() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.player.pause(at: 1_800)
        world.player.move(to: 2_500)
        controller.setEnabled(false)
        #expect(world.player.closes == 1)
        #expect(defaults.data(forKey: resumeKey) != nil)
        await controller.settleSessionFile()
        let relaunched = makeController()
        relaunched.setEnabled(true)
        await settle("signed in again") { relaunched.access == .ready }
        relaunched.play(recording("a"))
        await settle("a resumed") { world.player.plays.count == 2 }
        #expect(try world.player.play(1).startAt == 2_500)
        relaunched.turnOff()
    }

    @Test(arguments: [42, 7])
    func accountChangeAfterDisablingChecksTheStoredPositionOwner(owner: Int) async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.player.pause(at: 1_800)
        controller.setEnabled(false)
        await controller.settleSessionFile()
        world.owner = owner
        controller.webBeepAccountChanged(to: owner)
        #expect((defaults.data(forKey: resumeKey) != nil) == (owner == 42))
        controller.turnOff()
    }

    /// Closing the Settings window leaves a playing lecture alone. Mutation: call
    /// `player?.close()` in `windowClosed`.
    @Test func closingTheWindowKeepsTheLecturePlaying() async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        controller.windowClosed()
        await drainTasks()
        #expect(world.player.isOpen)
        #expect(world.player.closes == 0)
        controller.turnOff()
    }

    // MARK: Now Playing metadata (issue #148 follow-up)

    private static let pictureA = URL(string: "https://webeep.polimi.it/webservice/pluginfile.php/1/course/overviewfiles/a.png")!
    private static let pictureB = URL(string: "https://webeep.polimi.it/webservice/pluginfile.php/2/course/overviewfiles/b.png")!

    private func webeepCourse(_ id: Int64, name: String, picture: URL?) -> RemoteCourseSummary {
        RemoteCourseSummary(id: id, shortName: "058167 - \(name) [2026-27]", displayName: "058167 - \(name) [2026-27]", isVisible: true, startDate: nil, endDate: nil, imageURL: picture)
    }

    /// A Play hands the player the lecture's title, its course's name (without code and year) and
    /// the course picture's address. Guards against Now Playing showing "BeepBar", or the title
    /// alone, because the controller forgot to pass the metadata.
    @Test func aPlayHandsThePlayerTheLectureCourseAndPicture() async throws {
        defer { cleanUp() }
        world.courses = [webeepCourse(7, name: "NUMERICAL LINEAR ALGEBRA", picture: Self.pictureA)]
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let metadata = try #require(world.player.metadatas.first ?? nil)
        #expect(metadata == RecordingPlaybackMetadata(title: "Lezione a", courseName: "NUMERICAL LINEAR ALGEBRA", artworkURL: Self.pictureA))
        controller.turnOff()
    }

    /// The fresh stream of a recovery keeps the same course and picture, even if the page moved
    /// to another course meanwhile. Guards against a stream recovery dropping the course and the
    /// picture from Now Playing.
    @Test func aRecoveryKeepsTheCourseAndPicture() async throws {
        defer { cleanUp() }
        world.courses = [webeepCourse(7, name: "NUMERICAL LINEAR ALGEBRA", picture: Self.pictureA)]
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.courses = []
        world.player.failDuringPlayback(at: 1_234)
        await settle("resumed") { world.player.plays.count == 2 }
        #expect(world.player.metadatas.count == 2)
        #expect(world.player.metadatas[1] == world.player.metadatas[0])
        #expect(world.player.metadatas[1]?.artworkURL == Self.pictureA)
        controller.turnOff()
    }

    /// Two WeBeep courses with the same archive key (one course split in two sections): the one
    /// the student has selected on the page names the lecture, not neither. Guards against
    /// re-matching by code and year alone, which finds two and drops course and picture.
    @Test func twoCoursesSharingAKeyUseTheSelectedOne() async throws {
        defer { cleanUp() }
        world.courses = [webeepCourse(7, name: "ALGEBRA SEZ. A", picture: Self.pictureA), webeepCourse(8, name: "ALGEBRA SEZ. B", picture: Self.pictureB)]
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.selectDestination(.course(8))
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let metadata = try #require(world.player.metadatas.first ?? nil)
        #expect(metadata.courseName == "ALGEBRA SEZ. B")
        #expect(metadata.artworkURL == Self.pictureB)
        controller.turnOff()
    }

    /// A new Play of a lecture that was closed reads its course again: from another course's
    /// page it shows that course, and a picture the course list gained meanwhile (the first
    /// launch after an update has none yet) shows. A recovery keeps reusing its own metadata
    /// (`aRecoveryKeepsTheCourseAndPicture`). Guards against the metadata of the first Play
    /// sticking to the lecture for the whole session.
    /// Mutation: reuse `playbackMetadata` for any play of the same id AND stop clearing it on
    /// close (both lines: the close clear and the `recoveredLectures` condition are redundant
    /// with each other, so removing only one stays green; the other half is
    /// `aReplayAfterAWindowClosedBeforeReadyReadsTheCourseAgain`).
    @Test func aReplayAfterCloseReadsTheCourseAgain() async throws {
        defer { cleanUp() }
        world.courses = [webeepCourse(7, name: "ALGEBRA SEZ. A", picture: nil), webeepCourse(8, name: "ALGEBRA SEZ. B", picture: nil)]
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.selectDestination(.course(7))
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(world.player.metadatas.first??.courseName == "ALGEBRA SEZ. A")
        world.player.close()
        world.courses = [webeepCourse(7, name: "ALGEBRA SEZ. A", picture: Self.pictureA), webeepCourse(8, name: "ALGEBRA SEZ. B", picture: Self.pictureB)]
        controller.selectDestination(.course(8))
        controller.play(recording("a"))
        await settle("a again") { world.player.plays.count == 2 }
        let again = try #require(world.player.metadatas.last ?? nil)
        #expect(again.courseName == "ALGEBRA SEZ. B")
        #expect(again.artworkURL == Self.pictureB)
        controller.turnOff()
    }

    /// A lecture whose window closed before the stream was ready reports nothing (no checkpoint,
    /// so the close path does not clear `playbackMetadata`), yet a later Play of it from
    /// another course's page names that course: the stored metadata is reused only for a
    /// recovery (`recoveredLectures`), never for "any later play of the same lecture". This is
    /// the test that tells the two rules apart; `aReplayAfterCloseReadsTheCourseAgain` cannot,
    /// because its normal close already clears the metadata.
    /// Mutation: drop `recoveredLectures.contains(recording.id)` from the reuse condition in
    /// `playbackMetadata(for:stream:)` and the replay names course A.
    @Test func aReplayAfterAWindowClosedBeforeReadyReadsTheCourseAgain() async throws {
        defer { cleanUp() }
        world.courses = [webeepCourse(7, name: "ALGEBRA SEZ. A", picture: Self.pictureA), webeepCourse(8, name: "ALGEBRA SEZ. B", picture: Self.pictureB)]
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.selectDestination(.course(7))
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(world.player.metadatas.first??.courseName == "ALGEBRA SEZ. A")
        world.player.closeBeforeReady()
        #expect(!world.player.isOpen)
        #expect(world.player.closes == 0, "no normal close happened: nothing cleared the metadata")
        controller.selectDestination(.course(8))
        controller.play(recording("a"))
        await settle("a again") { world.player.plays.count == 2 }
        let again = try #require(world.player.metadatas.last ?? nil)
        #expect(again.courseName == "ALGEBRA SEZ. B")
        #expect(again.artworkURL == Self.pictureB)
        controller.turnOff()
    }

    /// The course of a menu Play whose stream was never handed to the player (the lookup ended in
    /// the browser) must not outlive an account change: the next account may list the same
    /// WeBeep course ids, and the stale preference would win over the course the student has
    /// selected. This is the one place `menuPlayCourse`'s reset is observable (the playback
    /// metadata's reset is covered by the recovery list, see `closePlayerForIdentityChange`).
    /// Mutation: drop `menuPlayCourse = nil` in `closePlayerForIdentityChange` and the replay
    /// names course B (the stale menu course) instead of the selected course A.
    @Test func aMenuCourseNeverPlayedDoesNotSurviveAnAccountChange() async throws {
        defer { cleanUp() }
        world.courses = [webeepCourse(7, name: "ALGEBRA SEZ. A", picture: nil), webeepCourse(8, name: "ALGEBRA SEZ. B", picture: nil)]
        let controller = await readyController()
        // No stream queued: the lookup fails and the Play ends in the browser, never reaching
        // `startPlayer`, which is the only place the menu course is consumed.
        // A menu Play only accepts a row whose preview link is the archive's own (`validatedNext`).
        let base = recording("a")
        let menuRow = RecmanRecording(id: base.id, courseCode: base.courseCode, academicYear: base.academicYear, title: base.title, recordedAt: base.recordedAt, kind: base.kind, duration: base.duration, size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?evn_preview_link=1&transfer_id=a")!)
        #expect(controller.playFromMenu(menuRow, owner: 42, courseID: 8))
        await settle("the stream was looked up") { !browser.streamCalls.isEmpty }
        await drainTasks()
        #expect(world.player.plays.isEmpty)

        world.owner = 9
        controller.webBeepAccountChanged(to: 9)
        controller.signIn()
        await settle("signed in again") { controller.access == .ready }
        browser.streamResults["a"] = [.success(stream("a"))]
        controller.selectDestination(.course(7))
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(world.player.metadatas.last??.courseName == "ALGEBRA SEZ. A")
        controller.turnOff()
    }

    /// After an account change, the same lecture played again shows the new account's course
    /// and picture, never the previous account's. Guards against Now Playing metadata outliving
    /// the identity it was read for.
    @Test func anAccountChangeDropsThePlaybackMetadata() async throws {
        defer { cleanUp() }
        world.courses = [webeepCourse(7, name: "ALGEBRA VECCHIO", picture: Self.pictureA)]
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.owner = 9
        world.courses = [webeepCourse(70, name: "ALGEBRA NUOVO", picture: Self.pictureB)]
        controller.webBeepAccountChanged(to: 9)
        #expect(!world.player.isOpen)
        controller.signIn()
        await settle("signed in again") { controller.access == .ready }
        controller.play(recording("a"))
        await settle("a again") { world.player.plays.count == 2 }
        let again = try #require(world.player.metadatas.last ?? nil)
        #expect(again.courseName == "ALGEBRA NUOVO")
        #expect(again.artworkURL == Self.pictureB)
        controller.turnOff()
    }

    /// Pure: the preferred course wins only when it is the recording's own; otherwise exactly one
    /// course with the recording's key, nil for none or two.
    @Test func thePlaybackCourseRules() {
        let a = webeepCourse(7, name: "A", picture: nil)
        let b = webeepCourse(8, name: "B", picture: nil)
        let other = RemoteCourseSummary(id: 9, shortName: "099999 - X [2026-27]", displayName: "099999 - X [2026-27]", isVisible: true, startDate: nil, endDate: nil)
        let lecture = recording("a")
        #expect(RecordingsController.playbackCourse(for: lecture, preferredID: 8, in: [a, b]) == b)
        #expect(RecordingsController.playbackCourse(for: lecture, preferredID: nil, in: [a, b]) == nil)
        #expect(RecordingsController.playbackCourse(for: lecture, preferredID: 9, in: [a, other]) == a)
        #expect(RecordingsController.playbackCourse(for: lecture, preferredID: nil, in: [other]) == nil)
    }

    // MARK: Recovery

    /// A stream that dies mid-lecture is resolved again once and resumes where it stopped; a
    /// second failure in the same Play opens the browser and closes the dead window. Guards
    /// against a lecture left frozen, and against retrying forever.
    /// Mutation: never insert into `recoveredLectures` and the third stream request happens.
    @Test func aStreamThatDiesIsResolvedOnceMoreThenTheBrowserOpens() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a")), .success(stream("a"))]
        browser.playbackResults["a"] = .success(playerLink("a"))
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }

        world.player.failDuringPlayback(at: 1_234)
        await settle("resumed") { world.player.plays.count == 2 }
        #expect(try world.player.play(1).startAt == 1_234)
        #expect(try world.player.play(1).recordingID == "a")
        #expect(world.opened.isEmpty)

        world.player.failDuringPlayback(at: 2_000)
        await settle("browser opened") { world.opened == [playerLink("a")] }
        #expect(browser.streamCalls == ["stream a", "stream a"], "no third stream request")
        #expect(!world.player.isOpen, "the dead window is closed")
        controller.turnOff()
    }

    /// A fresh stream that can't be found goes straight to the browser; a stream that never
    /// started does too, without asking for another one.
    /// Mutation: make `.beforeReady` map to `.freshStream` in `recovery(for:)`.
    @Test(arguments: ["fresh stream unavailable", "never started"])
    func recoveryEndsInTheBrowser(scenario name: String) async {
        defer { cleanUp() }
        browser.streamResults["a"] = name == "never started" ? [.success(stream("a"))] : [.success(stream("a")), .failure(RecmanBrowserError.playbackUnavailable)]
        browser.playbackResults["a"] = .success(playerLink("a"))
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        if name == "never started" { world.player.failBeforeReady() } else { world.player.failDuringPlayback(at: 77) }
        await settle("browser opened") { world.opened == [playerLink("a")] }
        #expect(browser.streamCalls.count == (name == "never started" ? 1 : 2))
        #expect(world.player.plays.count == 1)
        controller.turnOff()
    }

    /// A mid-lecture failure whose recovery ends with neither a new stream nor the browser tells
    /// the paused player window why, not only the Recordings page (issue #197: a lecture started
    /// from the menu bar has no page, and its window just froze). Covers each way a recovery can
    /// end like that: Webex needs a confirmed email, the second failure's browser link can't be
    /// found (Polimi offline), and the Polimi session lapsing during the lookup.
    /// Mutations: drop the `reportStoppedLecture` call of the scenario (no problem shown);
    /// drop the `stillShowing` guard in it (not caught here: the window is open throughout).
    @Test(arguments: ["needs email", "browser link unavailable", "session lapsed"])
    func aRecoveryThatEndsWithNothingTellsThePlayerWindow(scenario name: String) async throws {
        defer { cleanUp() }
        switch name {
        case "needs email":
            browser.streamResults["a"] = [.success(stream("a")), .failure(RecmanBrowserError.needsEmail)]
        case "browser link unavailable":
            browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
            browser.playbackResults["a"] = .failure(RecmanBrowserError.unavailable)
        default:
            browser.streamResults["a"] = [.success(stream("a")), .failure(RecmanBrowserError.needsSignIn)]
        }
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.player.failDuringPlayback(at: 300)
        if name == "browser link unavailable" {
            await settle("resumed once") { world.player.plays.count == 2 }
            world.player.failDuringPlayback(at: 400)
        }
        await settle("the window was told") { !world.player.problems.isEmpty }
        let expected: String = switch name {
        case "needs email": RecordingsProblem.playbackUnavailable.message
        case "browser link unavailable": RecordingsProblem.unavailable.message
        default: RecordingsController.signInToContinueMessage
        }
        #expect(world.player.problems == [expected])
        #expect(world.player.isOpen, "the paused window stays, with the reason")
        #expect(world.opened.isEmpty)
        controller.turnOff()
    }

    /// A lecture that stops while the Polimi session is gone can't be recovered: its paused
    /// window says to sign in again (issue #197) instead of sitting frozen.
    /// Mutation: drop the `.duringPlayback` report in `playerFailed`'s access guard.
    @Test func aFailureWhileSignedOutTellsThePlayerWindow() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        controller.refresh([course], selected: course)
        await settle("signed out") { controller.access == .needsSignIn(nil) }
        world.player.failDuringPlayback(at: 300)
        #expect(world.player.problems == [RecordingsController.signInToContinueMessage])
        controller.turnOff()
    }

    /// A recovery that runs with no Recordings page on screen does not leave the browser open
    /// (nothing at rest), and the lecture keeps playing. Mutation: remove `closesBrowserWhenIdle`.
    @Test func aRecoveryWithTheWindowClosedLeavesNoBrowserBehind() async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        controller.windowClosed()
        await drainTasks()
        #expect(!browser.isOpen)

        world.player.failDuringPlayback(at: 500)
        await settle("resumed") { world.player.plays.count == 2 }
        await settle("browser closed again") { !browser.isOpen }
        #expect(world.player.isOpen)
        controller.turnOff()
    }

    // MARK: Polimi email

    private func savedEmail() throws -> String? { try savedSession()?.email }

    /// The confirmed address goes into the session file at once, with the cookies, and every
    /// later save (a visit with renewed cookies) keeps it. Guards against the address being
    /// dropped by the first save after it. Mutation: pass `email: nil` to `vault.save` in
    /// `saveSession` and the final expectation fails.
    @Test func theConfirmedEmailSurvivesLaterSaves() async throws {
        defer { cleanUp() }
        let controller = await readyController()
        #expect(try savedEmail() == nil)
        #expect(controller.confirmEmail("  Mario.Rossi@mail.polimi.it ") == .saved)
        #expect(controller.confirmedEmail?.value == "mario.rossi@mail.polimi.it")
        await controller.settleSessionFile()
        #expect(try savedEmail() == "mario.rossi@mail.polimi.it")
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"], "the cookies are kept")

        browser.listResults[course.courseCode] = .success([recording("a")])
        browser.cookiesAfterListing = [FakeRecmanBrowser.cookie("SSO_LOGIN", value: "renewed")]
        controller.refresh([course], selected: course)
        await settle("renewed session saved") { (try? self.savedSession()?.cookies.first?.value) == "renewed" }
        #expect(try savedEmail() == "mario.rossi@mail.polimi.it")
        controller.turnOff()
    }

    /// Only Polimi addresses are accepted; an empty field removes the address; neither touches
    /// the file when nothing changes. Mutation: accept any address in `emailFieldState`.
    @Test func onlyPolimiAddressesAreAcceptedAndEmptyRemoves() async throws {
        defer { cleanUp() }
        let controller = await readyController()
        #expect(controller.confirmEmail("mario@gmail.com") == .invalid)
        #expect(controller.confirmEmail("mario.rossi@polimi.it.evil.com") == .invalid)
        #expect(controller.confirmEmail("") == .unchanged)
        #expect(controller.confirmedEmail == nil)
        #expect(controller.confirmEmail("mario.rossi@polimi.it") == .saved)
        #expect(controller.confirmEmail("MARIO.ROSSI@polimi.it") == .unchanged, "the same address again")
        #expect(controller.confirmEmail("") == .cleared)
        #expect(controller.confirmedEmail == nil)
        await controller.settleSessionFile()
        #expect(try savedEmail() == nil)
        controller.turnOff()
    }

    /// The address is read from the saved session after a relaunch, without asking WeBeep, and
    /// the Play that follows sends it to the stream lookup. Mutation: skip the email in `adopt`.
    @Test func aSavedEmailIsReadAfterARelaunchAndUsedByPlay() async throws {
        defer { cleanUp() }
        try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN", value: "saved")], ownerUserID: 42, email: "a.b@polimi.it", now: world.now))
        world.profileEmail = "someone.else@mail.polimi.it"
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        await controller.prepareEmailField()
        #expect(controller.confirmedEmail?.value == "a.b@polimi.it")
        #expect(!controller.emailFromProfile)
        #expect(world.profileEmailCalls == 0, "no profile read when an address is already confirmed")
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(browser.streamEmails == ["a.b@polimi.it"])
        controller.turnOff()
    }

    /// Product decision (2026-10-11): the WeBeep profile's Polimi address is in use without a
    /// confirmation step, stored in the session file like a typed one, and Play sends it. A
    /// profile failure, no address or a non-Polimi address leave none, and Play still ends on the
    /// message. Replaces the earlier "only a suggestion" test. Mutation: drop
    /// `confirmedEmail = email` in `performEmailLookup` and the Polimi row fails (no address, no
    /// file email, Play gets nil).
    @Test(arguments: ["polimi address", "personal address", "no address"])
    func theProfileAddressIsUsedWithoutConfirmation(profile: String) async throws {
        defer { cleanUp() }
        world.profileEmail = switch profile {
        case "polimi address": "Mario.Rossi@mail.polimi.it"
        case "personal address": "mario@gmail.com"
        default: nil
        }
        let usable = profile == "polimi address"
        browser.streamResults["a"] = usable ? [.success(stream("a"))] : [.failure(RecmanBrowserError.needsEmail)]
        let controller = await readyController()
        await controller.prepareEmailField()
        #expect(world.profileEmailCalls == 1)
        #expect(controller.confirmedEmail?.value == (usable ? "mario.rossi@mail.polimi.it" : nil))
        #expect(controller.emailFromProfile == usable)
        await controller.settleSessionFile()
        #expect(try savedEmail() == (usable ? "mario.rossi@mail.polimi.it" : nil), "stored like a typed address")

        controller.play(recording("a"))
        if usable {
            await settle("a playing") { world.player.plays.count == 1 }
            #expect(browser.streamEmails == ["mario.rossi@mail.polimi.it"])
        } else {
            await settle("needs an email") { controller.openingProblem == .playbackUnavailable }
            #expect(browser.streamEmails == [nil])
            #expect(world.player.plays.isEmpty)
        }
        #expect(world.profileEmailCalls == 1, "the Play doesn't ask WeBeep again in the same epoch")
        controller.turnOff()
    }

    /// The first Play works without the Settings row ever appearing: Play itself takes the
    /// profile's address, once, and the save after the Play keeps it in the file. Guards against
    /// the lookup depending on the Settings view (the user's report: "Couldn't open this
    /// recording." until the address was confirmed by hand). Mutation: remove the `learnEmail()`
    /// call in `playNatively` and `streamEmails` is `[nil]`.
    @Test func theFirstPlayUsesTheProfileAddressWithoutSettings() async throws {
        defer { cleanUp() }
        world.profileEmail = "mario.rossi@mail.polimi.it"
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        #expect(world.profileEmailCalls == 0, "nothing is asked at rest")
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(browser.streamEmails == ["mario.rossi@mail.polimi.it"])
        #expect(controller.emailFromProfile)
        await settle("stored") { (try? self.savedEmail()) == "mario.rossi@mail.polimi.it" }
        controller.play(recording("a"))
        await settle("played again") { world.player.plays.count == 2 }
        #expect(world.profileEmailCalls == 1)
        controller.turnOff()
    }

    /// The student's choice beats the profile: an edited address is the one used, and a removed
    /// one stays removed, in this launch and after a relaunch (`emailDeclinedKey`), so the
    /// profile is never asked again for that account; entering an address again lifts it.
    /// Mutations: drop the `emailDeclined(by:)` guard in `performEmailLookup`, or the
    /// `defaults.set(owner, forKey: emailDeclinedKey)` in `setConfirmedEmail`, and the relaunch
    /// expectations fail; drop `forgetEmailOptOut()` for a new address and the last one fails.
    /// (In the same launch the removal is also covered by the epoch's single lookup.)
    @Test func theStudentsEditOrRemovalWinsOverTheProfile() async throws {
        defer { cleanUp() }
        world.profileEmail = "mario.rossi@mail.polimi.it"
        let controller = await readyController()
        await controller.prepareEmailField()
        #expect(controller.confirmedEmail?.value == "mario.rossi@mail.polimi.it")
        #expect(controller.confirmEmail("m.rossi@polimi.it") == .saved)
        #expect(!controller.emailFromProfile)
        #expect(controller.confirmEmail("") == .cleared)
        await controller.learnEmail()
        #expect(controller.confirmedEmail == nil, "no re-prefill after a removal")
        #expect(world.profileEmailCalls == 1)
        await controller.settleSessionFile()
        #expect(try savedEmail() == nil)
        #expect(defaults.integer(forKey: RecordingsController.emailDeclinedKey) == 42)

        let relaunched = makeController()
        relaunched.pageAppeared()
        await relaunched.prepareEmailField()
        #expect(relaunched.confirmedEmail == nil, "the removal survives a relaunch")
        #expect(world.profileEmailCalls == 1, "WeBeep is not asked for a removed address")
        #expect(relaunched.confirmEmail("a.b@polimi.it") == .saved)
        #expect(defaults.object(forKey: RecordingsController.emailDeclinedKey) == nil, "an address entered again lifts the removal")
        relaunched.turnOff()
    }

    /// A Play that starts while the Settings row's lookup is still waiting for WeBeep uses its
    /// answer instead of going on without an address or asking twice. Mutation: drop the shared
    /// `emailLookup` (always start a new lookup) and the Play gets nil.
    @Test func aPlayDuringTheSettingsLookupWaitsForIt() async throws {
        defer { cleanUp() }
        world.profileEmail = "mario.rossi@mail.polimi.it"
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        world.profileGate = gate
        let settings = Task { await controller.prepareEmailField() }
        await settle("profile read held") { gate.isWaiting }
        controller.play(recording("a"))
        await drainTasks()
        #expect(browser.streamCalls.isEmpty, "the Play waits for the address")
        gate.release()
        await settings.value
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(browser.streamEmails == ["mario.rossi@mail.polimi.it"])
        #expect(world.profileEmailCalls == 1)
        controller.turnOff()
    }

    /// The Play log says where the address came from and never contains it.
    /// Mutation: return "confirmed" for every address in `emailDiagnosis` and the profile row fails.
    @Test func thePlayLogNamesTheAddressSourceOnly() throws {
        let email = try #require(PolimiEmail("mario.rossi@mail.polimi.it"))
        #expect(RecordingsController.emailDiagnosis(email, fromProfile: true) == "profile")
        #expect(RecordingsController.emailDiagnosis(email, fromProfile: false) == "confirmed")
        #expect(RecordingsController.emailDiagnosis(nil, fromProfile: true) == "none")
        for fromProfile in [true, false] {
            #expect(!RecordingsController.emailDiagnosis(email, fromProfile: fromProfile).contains("mario"))
        }
    }

    /// Typed before any session exists, the address waits in memory and the sign-in writes it.
    /// Mutation: drop `email:` from the save in `saveSession` (same as the survival test).
    @Test func anAddressConfirmedBeforeSigningInIsWrittenBySignIn() async throws {
        defer { cleanUp() }
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        await controller.prepareEmailField()
        #expect(controller.confirmEmail("a.b@polimi.it") == .saved)
        await controller.settleSessionFile()
        #expect(try store.load() == nil, "nothing to write into yet")
        controller.signIn()
        await settle("signed in and saved") { controller.access == .ready && (try? self.savedEmail()) == "a.b@polimi.it" }
        controller.turnOff()
    }

    /// An account change removes the address from memory and from the file.
    /// Mutation: skip `resetEmail()` in `discardSessionFile` and the first expectation fails.
    @Test func theEmailGoesWithTheSession() async throws {
        defer { cleanUp() }
        let controller = await readyController()
        #expect(controller.confirmEmail("a.b@polimi.it") == .saved)
        await controller.settleSessionFile()
        #expect(try savedEmail() == "a.b@polimi.it")
        world.owner = 7
        controller.webBeepAccountChanged(to: 7)
        #expect(controller.confirmedEmail == nil)
        #expect(!controller.emailFromProfile)
        await controller.settleSessionFile()
        #expect(try store.load() == nil)
        controller.turnOff()
    }

    /// A profile answer that arrives after an account change is dropped instead of becoming the
    /// next account's address, whether the Settings row or a Play asked. Mutation: remove the
    /// `epoch == emailEpoch` check after `fetchProfileEmail` in `performEmailLookup` and the
    /// address appears (and reaches the file).
    @Test(arguments: [false, true])
    func aLateProfileAnswerAfterAnAccountChangeIsDropped(fromPlay: Bool) async throws {
        defer { cleanUp() }
        let controller = await readyController()
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        world.profileGate = gate
        world.profileEmail = "previous.account@mail.polimi.it"
        var settings: Task<Void, Never>?
        if fromPlay {
            controller.play(recording("a"))
        } else {
            settings = Task { await controller.prepareEmailField() }
        }
        await settle("profile read held") { gate.isWaiting }
        world.owner = 7
        controller.webBeepAccountChanged(to: 7)
        gate.release()
        await settings?.value
        await drainTasks()
        #expect(controller.confirmedEmail == nil)
        #expect(!controller.emailFromProfile)
        #expect(browser.streamEmails.allSatisfy { $0 == nil })
        await controller.settleSessionFile()
        #expect(try store.load() == nil, "nothing of the old account's answer is written")
        controller.turnOff()
    }

    /// The form's pure rules. Mutation: return `.ready` for the confirmed address.
    @Test func theEmailFieldRules() {
        let confirmed = PolimiEmail("a.b@polimi.it")
        typealias Controller = RecordingsController
        #expect(Controller.emailFieldState(draft: "", confirmed: nil) == .empty)
        #expect(Controller.emailFieldState(draft: "  ", confirmed: nil) == .empty)
        #expect(Controller.emailFieldState(draft: "", confirmed: confirmed) == .removable)
        #expect(Controller.emailFieldState(draft: "A.B@polimi.it", confirmed: confirmed) == .confirmed)
        #expect(Controller.emailFieldState(draft: "c.d@polimi.it", confirmed: confirmed) == .ready(PolimiEmail("c.d@polimi.it")!))
        #expect(Controller.emailFieldState(draft: "c.d@gmail.com", confirmed: confirmed) == .invalid)
        #expect(Controller.emailFieldState(draft: "a.b", confirmed: nil) == .invalid)
    }

    /// `chooseRoot` puts the activation policy back only when it raised it and nothing else has
    /// changed it since, and hands it to an open lecture instead of dropping the Dock icon.
    /// Mutation: ignore `playerOpen` and the third row fails.
    @Test func thePanelPolicyOutcome() {
        typealias Controller = WeBeepAuthenticationController
        #expect(Controller.panelPolicyOutcome(previous: .accessory, current: .regular, playerOpen: false) == .restore)
        #expect(Controller.panelPolicyOutcome(previous: .accessory, current: .regular, playerOpen: true) == .handToPlayer)
        #expect(Controller.panelPolicyOutcome(previous: .regular, current: .regular, playerOpen: true) == .leave)
        #expect(Controller.panelPolicyOutcome(previous: .accessory, current: .accessory, playerOpen: false) == .leave)
        #expect(Controller.panelPolicyOutcome(previous: .accessory, current: .prohibited, playerOpen: false) == .leave)
    }

    @Test(arguments: ["stream", "link"])
    func closingThePlayerRejectsALateRecoveryFallback(stage: String) async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .failure(RecmanBrowserError.playbackUnavailable)]
        browser.playbackResults["a"] = .success(playerLink("a"))
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        if stage == "stream" { browser.streamGates["a"] = gate }
        else { browser.playbackGates["a"] = gate }
        world.player.failDuringPlayback(at: 700)
        await settle("recovery held") { gate.isWaiting }
        world.player.close()
        controller.windowClosed()
        gate.release()
        await settle("recovery finished") { !browser.isOpen }
        #expect(world.opened.isEmpty)
        #expect(world.player.plays.count == 1)
        controller.turnOff()
    }

    /// The student resumes the paused window while the first recovery is still looking up a
    /// fresh stream, and the dead item fails again (RB-002 on #197: resuming re-arms the player's
    /// failure report). That second report must not queue a second recovery: when the fresh
    /// stream arrives the lecture goes on natively, with no browser and no closed window; when it
    /// doesn't, the browser opens once, not twice.
    /// Mutations: drop the pending-recovery check in `playerFailed` and "browser" opens it twice;
    /// drop it together with the item check in `recoverPlayback` (`start == lectureStarts`) and
    /// "fresh" also closes the recovered player and opens the browser. The item check alone is
    /// masked by the pending-recovery check, which stops the second recovery first.
    @Test(arguments: ["fresh", "browser"])
    func aSecondFailureDuringARecoveryQueuesNoSecondRecovery(outcome: String) async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = outcome == "fresh"
            ? [.success(stream("a")), .success(stream("a"))]
            : [.success(stream("a")), .failure(RecmanBrowserError.playbackUnavailable)]
        browser.playbackResults["a"] = .success(playerLink("a"))
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.streamGates["a"] = gate
        world.player.failDuringPlayback(at: 700)
        await settle("recovery running") { gate.isWaiting }
        // Space on the paused window, then the same dead item fails again.
        world.player.failDuringPlayback(at: 700)
        gate.release()
        await settle("first recovery finished") { outcome == "fresh" ? world.player.plays.count == 2 : !world.opened.isEmpty }
        await drainTasks()
        if outcome == "fresh" {
            #expect(world.player.plays.count == 2, "the lecture did not go on natively")
            #expect(try world.player.play(1).startAt == 700)
            #expect(world.player.closes == 0, "a second recovery closed the recovered player")
            #expect(world.opened.isEmpty, "a second recovery opened the browser")
        } else {
            #expect(world.opened == [playerLink("a")], "the browser opened more than once")
        }
        controller.turnOff()
    }

    @Test(arguments: ["duringPlayback", "beforeReady"])
    func aNewPlayRejectsALateRecoveryLink(failure: String) async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .failure(RecmanBrowserError.playbackUnavailable)]
        browser.streamResults["b"] = [.success(stream("b"))]
        browser.playbackResults["a"] = .success(playerLink("a"))
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.playbackGates["a"] = gate
        if failure == "beforeReady" { world.player.failBeforeReady() }
        else { world.player.failDuringPlayback(at: 700) }
        await settle("recovery link held") { gate.isWaiting }
        controller.play(recording("b"))
        controller.windowClosed()
        gate.release()
        await settle("b played") { world.player.plays.count == 2 }
        await settle("browser closed") { !browser.isOpen }
        #expect(world.player.plays.map(\.recordingID) == ["a", "b"])
        #expect(world.opened.isEmpty)
        controller.turnOff()
    }

    @Test(arguments: [false, true])
    func aFailedSessionDeletionCannotRestoreTheDiscardedSession(relaunch: Bool) async throws {
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); cleanUp() }
        let data = try RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN", value: "obsolete")], ownerUserID: 42, email: "obsolete@mail.polimi.it", now: world.now)
        try store.save(data)
        let controller = makeController()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        controller.setEnabled(false)
        await controller.settleSessionFile()
        #expect(try store.load() == data, "failed unlink leaves a readable obsolete session")
        let next = relaunch ? makeController() : controller
        next.setEnabled(true)
        await settle("fresh sign-in finishes") { next.access == .ready && !browser.isOpen }
        #expect(browser.openedWith == [[]])
        #expect(next.confirmedEmail == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        next.signIn()
        await settle("replacement session saved") { next.access == .ready && !browser.isOpen }
        await next.settleSessionFile()
        #expect(try savedEmail() == nil)
        #expect(try savedSession()?.cookies.first?.value == "fresh")
        let reopened = makeController(useDefault: true)
        reopened.pageAppeared()
        await drainTasks()
        #expect(reopened.access == .ready, "a successfully saved replacement can be adopted again")
        reopened.turnOff()
        await reopened.settleSessionFile()
    }

    /// A discarded session whose deletion failed is deleted later: by the next controller (a
    /// relaunch, with nothing opened) or by the next session read of the same controller, and
    /// the discard flag is cleared only once the file is gone (#200). Guards the previous
    /// account's Polimi and Webex cookies and email staying on disk for good after turn-off.
    /// Mutations: drop `retryObsoleteSessionDeletion()` from `init` (relaunch keeps the file) or
    /// from `savedCookies` (same controller keeps it); clear the flag on any outcome (the flag
    /// is gone while the file is still there after the first failure).
    @Test(arguments: [false, true])
    func aFailedSessionDeletionIsRetriedLater(relaunch: Bool) async throws {
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); cleanUp() }
        let discardedKey = "io.github.tvaccari.beepbar.recordings-session-discarded.v1"
        try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN", value: "obsolete")], ownerUserID: 42, email: "obsolete@mail.polimi.it", now: world.now))
        defaults.set(true, forKey: RecordingsController.enabledKey)
        let controller = makeController()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        controller.setEnabled(false)
        await controller.settleSessionFile()
        await drainTasks()
        #expect(try store.load() != nil, "fixture: the first unlink failed")
        #expect(defaults.bool(forKey: discardedKey), "a failed deletion keeps the flag")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)

        let next: RecordingsController
        if relaunch {
            next = makeController()
        } else {
            // The sign-in fails, so no new session replaces the file: only the retry removes it.
            browser.signInError = RecmanBrowserError.unrecognized
            next = controller
            next.setEnabled(true)
        }
        await settle("the obsolete file is deleted") { (try? store.load()) == nil }
        await next.settleSessionFile()
        await drainTasks()
        #expect(!defaults.bool(forKey: discardedKey), "a confirmed deletion clears the flag")
        if !relaunch { next.turnOff() }
    }

    /// A session saved while a newer sign-in starts (the generation moves, the vault epoch does
    /// not) still clears the discard flag, so the next launch keeps that session instead of
    /// deleting it as obsolete (RA-002 on #200). Before the fix the flag was cleared only when the
    /// generation was unchanged: it stayed set over the new file, and the relaunch's retry deleted
    /// it, costing the student one more "Accedi con Polimi".
    /// Mutation: require `generation == self.generation` again to clear the flag on `.saved`.
    @Test func aSaveFinishingDuringANewerSignInStillClearsTheDiscardFlag() async throws {
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path); cleanUp() }
        let discardedKey = "io.github.tvaccari.beepbar.recordings-session-discarded.v1"
        // An earlier discard whose unlink failed: the obsolete file and the flag are both there.
        try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN", value: "obsolete")], ownerUserID: 42, email: nil, now: world.now))
        defaults.set(true, forKey: discardedKey)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let controller = makeController()
        let firstSignIn = FakeRecmanBrowser.Gate()
        browser.signInGate = firstSignIn
        controller.setEnabled(true)
        await settle("first sign-in on screen") { firstSignIn.isWaiting }
        await controller.settleSessionFile()
        await drainTasks()
        #expect(defaults.bool(forKey: discardedKey), "fixture: every retry so far failed")
        // The disk works again; the sign-in's save is held mid-write by a slow disk.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        world.sessionFiles.hold(access: world.storeAccesses + 1)
        firstSignIn.release()
        await settle("the save is held by the slow disk") { world.sessionFiles.isHolding }

        // "Accedi con Polimi" again while the save is still writing: a new generation, no discard.
        let secondSignIn = FakeRecmanBrowser.Gate()
        defer { secondSignIn.release() }
        browser.signInGate = secondSignIn
        controller.signIn()
        await settle("second sign-in on screen") { secondSignIn.isWaiting }
        world.sessionFiles.release()
        await controller.settleSessionFile()
        await drainTasks()
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"], "fixture: the first sign-in's session was written")
        #expect(!defaults.bool(forKey: discardedKey), "the flag stayed set over a session saved in the current epoch")

        let relaunched = makeController()
        await relaunched.settleSessionFile()
        await drainTasks()
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"], "the next launch deleted a legitimate session")
        controller.turnOff()
        await controller.settleSessionFile()
    }

    // MARK: Review follow-ups (#148)

    /// Closing the Settings window (or leaving the page) while a lecture recovery is running or
    /// waiting does not cancel it: the lecture resumes at its place and the browser then closes.
    /// Guards against a lecture left paused and silent with its one retry spent.
    /// Mutation: make `suspend()` always `invalidate()` and close the browser (drop the
    /// `hasRecovery` branch) and both variants stay at one play.
    @Test(arguments: ["running", "queued"])
    func aRecoveryOutlivesTheWindowClosing(scenario: String) async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        if scenario == "running" {
            browser.streamGates["a"] = gate
            world.player.failDuringPlayback(at: 700)
            await settle("recovery running") { gate.isWaiting }
        } else {
            browser.listResults[course.courseCode] = .success([])
            browser.listGates[course.courseCode] = gate
            controller.refresh([course], selected: course)
            await settle("listing held") { gate.isWaiting }
            world.player.failDuringPlayback(at: 700)
        }
        controller.windowClosed()
        gate.release()
        await settle("resumed after the window closed") { world.player.plays.count == 2 }
        #expect(try world.player.play(1).startAt == 700)
        await settle("browser closed again") { !browser.isOpen }
        #expect(world.player.isOpen)
        controller.turnOff()
    }

    /// Copy link on another recording leaves a waiting recovery alone; a new Play replaces it.
    /// Mutation: remove the `.recover` exception for copy in `open` and the lecture never resumes.
    @Test func copyingALinkDoesNotCancelARecovery() async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        browser.playbackResults["c"] = .success(playerLink("c"))
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.listResults[course.courseCode] = .success([])
        browser.listGates[course.courseCode] = gate
        controller.refresh([course], selected: course)
        await settle("listing held") { gate.isWaiting }
        world.player.failDuringPlayback(at: 700)
        controller.copyLink(recording("c"))
        gate.release()
        await settle("link copied") { world.copied == [playerLink("c")] }
        await settle("recovery still ran") { world.player.plays.count == 2 }
        controller.turnOff()
    }

    /// PR #152 review P0: an address learned while no Polimi session exists yet (sign-in never
    /// finished) belongs to the WeBeep account signed in then. After an account change it must
    /// not be shown, written into the next account's session file or sent to Webex as its
    /// sign-in hint. Mutation: remove the `emailAccount` check in `webBeepAccountChanged` and the
    /// old address stays, is saved with the new session and reaches `stream`.
    @Test(arguments: ["profile", "typed"])
    func anAddressLearnedBeforeAnyPolimiSessionStaysWithItsAccount(source: String) async throws {
        defer { cleanUp() }
        browser.signInError = CancellationError()
        world.profileEmail = "previous.account@mail.polimi.it"
        let controller = makeController()
        controller.setEnabled(true)
        await settle("sign-in cancelled") { controller.access == .needsSignIn(nil) }
        if source == "profile" {
            await controller.prepareEmailField()
        } else {
            #expect(controller.confirmEmail("previous.account@mail.polimi.it") == .saved)
        }
        #expect(controller.confirmedEmail == PolimiEmail("previous.account@mail.polimi.it"))
        #expect(try store.load() == nil, "no session file yet: the address lives in memory only")

        world.owner = 7
        world.profileEmail = nil
        controller.webBeepAccountChanged(to: 7)
        #expect(controller.confirmedEmail == nil)
        #expect(!controller.emailFromProfile)

        browser.signInError = nil
        controller.signIn()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        await controller.settleSessionFile()
        #expect(try savedEmail() == nil, "the new account's session holds no address of the old one")
        controller.pageAppeared()
        controller.play(recording("a"))
        await settle("stream asked") { browser.streamCalls.count == 1 }
        #expect(browser.streamEmails == [nil])
        controller.turnOff()
    }

    /// Closing the window while a lecture recovery runs keeps the newer Play
    /// clicked meanwhile: the student asked for "b", and closing Settings doesn't cancel a Play
    /// (menu bar Play decision, 2026-10-12, which replaced the PR #152 review's "drop it"). The
    /// browser still closes once the superseding Play has run. Guards a Play pressed just before closing the
    /// window being silently lost. Mutations: drop the queued-Play case from `hasPlayOrRecovery`
    /// or let `dropQueuedOpenings` drop Plays ("b" is never streamed).
    @Test func closingTheWindowKeepsAPlayQueuedBehindARecovery() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        browser.streamResults["b"] = [.success(stream("b"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.streamGates["a"] = gate
        world.player.failDuringPlayback(at: 700)
        await settle("recovery running") { gate.isWaiting }
        controller.play(recording("b"))
        controller.windowClosed()
        #expect(controller.openingRecordingID == "b", "the kept Play keeps spinning")
        gate.release()
        await settle("b supersedes the recovery") { world.player.plays.count == 2 }
        await settle("browser closed") { !browser.isOpen }
        #expect(world.player.plays.map(\.recordingID) == ["a", "b"])
        #expect(world.opened.isEmpty)
        controller.turnOff()
    }

    /// PR #152 review P1, still true for the clicks that aren't a Play: closing the window while
    /// a recovery runs drops a Copy link (or Open in browser) clicked meanwhile and its spinner;
    /// nobody is looking, and it would otherwise open a browser or sign-in window afterwards.
    /// Mutation: remove `dropQueuedOpenings()` from `suspend` and "b"'s link is looked up.
    @Test func closingTheWindowDropsACopyQueuedBehindARecovery() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        browser.playbackResults["b"] = .success(URL(string: "https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/b")!)
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.streamGates["a"] = gate
        world.player.failDuringPlayback(at: 700)
        await settle("recovery running") { gate.isWaiting }
        controller.copyLink(recording("b"))
        #expect(controller.openingRecordingID == "b")
        controller.windowClosed()
        #expect(controller.openingRecordingID == nil, "the dropped click stops spinning")
        gate.release()
        await settle("a resumed") { world.player.plays.count == 2 }
        await settle("browser closed") { !browser.isOpen }
        #expect(!browser.playCalls.contains("play b"))
        #expect(world.copied.isEmpty)
        controller.turnOff()
    }

    /// PR #152 review P1: when the stream lookup fails after the archive gave the player link,
    /// the browser fallback opens that link instead of walking the archive again, on a Play and
    /// on a failed recovery. Mutation: drop `found:` from either `playerLink` call and the
    /// archive is asked (`play a` appears) — and fails here, since it has no link to give.
    @Test(arguments: ["play", "recovery"])
    func aStreamFailureAfterTheLinkOpensThatLink(path: String) async {
        defer { cleanUp() }
        let failure = RecmanStreamFailure(player: playerLink("a"), underlying: RecmanBrowserError.playbackUnavailable)
        browser.streamResults["a"] = path == "play" ? [.failure(failure)] : [.success(stream("a")), .failure(failure)]
        let controller = await readyController()
        controller.play(recording("a"))
        if path == "recovery" {
            await settle("a playing") { world.player.plays.count == 1 }
            world.player.failDuringPlayback(at: 700)
        }
        await settle("browser opened") { world.opened == [playerLink("a")] }
        #expect(browser.playCalls.isEmpty, "the archive is not walked a second time")
        #expect(controller.openingProblem == nil)
        controller.turnOff()
    }

    /// The wrapper never changes the decision, on a Play or a recovery: a missing email found
    /// after the link shows its sentence, a lapsed Polimi session asks for a sign-in, and a
    /// cancellation stays silent — none opens the browser or walks the archive. Mutation: throw
    /// or decide on the wrapper instead of `streamFailureCause(error).cause` (either path) and
    /// the problem becomes `unrecognized`, the sign-in isn't asked or cancellation shows an error.
    @Test(arguments: ["play", "recovery"], ["needsEmail", "needsSignIn", "cancelled"])
    func aWrappedReportedFailureIsStillReported(path: String, cause: String) async {
        defer { cleanUp() }
        let underlying: Error = switch cause {
        case "needsEmail": RecmanBrowserError.needsEmail
        case "needsSignIn": RecmanBrowserError.needsSignIn
        default: CancellationError()
        }
        let failure = Result<RecordingStream, Error>.failure(RecmanStreamFailure(player: playerLink("a"), underlying: underlying))
        browser.streamResults["a"] = path == "play" ? [failure] : [.success(stream("a")), failure]
        let controller = await readyController()
        controller.play(recording("a"))
        if path == "recovery" {
            await settle("a playing") { world.player.plays.count == 1 }
            world.player.failDuringPlayback(at: 700)
        }
        await settle("stream answered") { browser.streamCalls.count == (path == "play" ? 1 : 2) }
        switch cause {
        case "needsEmail":
            await settle("sentence shown") { controller.openingProblem == .playbackUnavailable }
        case "needsSignIn":
            await settle("sign-in asked") { controller.access == .needsSignIn(nil) }
        default:
            await drainTasks()
            #expect(controller.openingProblem == nil)
            #expect(controller.access == .ready)
        }
        #expect(world.opened.isEmpty)
        #expect(browser.playCalls.isEmpty)
        controller.turnOff()
    }

    /// PR #152 review: with no WeBeep account known (expired token at launch) a typed address is
    /// refused, since it could only end up with whichever account signs in next, and the Settings
    /// field is disabled (`canConfirmEmail`). Mutation: drop the owner check in `canConfirmEmail`
    /// and the address is kept and later sent for account 7.
    @Test func anAddressIsRefusedWhileNoAccountIsKnown() async throws {
        defer { cleanUp() }
        browser.signInError = CancellationError()
        let controller = makeController()
        controller.setEnabled(true)
        await settle("sign-in cancelled") { controller.access == .needsSignIn(nil) }
        #expect(controller.canConfirmEmail)
        world.owner = nil
        #expect(!controller.canConfirmEmail, "the Settings field is disabled and says why")
        #expect(controller.confirmEmail("someone.else@mail.polimi.it") == .unchanged)
        #expect(controller.confirmedEmail == nil)
        world.owner = 7
        controller.webBeepAccountChanged(to: 7)
        browser.signInError = nil
        controller.signIn()
        await settle("signed in and closed") { controller.access == .ready && !browser.isOpen }
        controller.pageAppeared()
        controller.play(recording("a"))
        await settle("stream asked") { browser.streamCalls.count == 1 }
        #expect(browser.streamEmails == [nil])
        controller.turnOff()
    }

    /// The controller's plumbing to the player: no player until a Play, and a policy handed over
    /// reaches it. Mutation: make `keepPolicyAfterLecture` do nothing.
    @Test func thePolicyHandOverReachesTheOpenPlayer() async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        #expect(!controller.isPlayerOpen)
        controller.keepPolicyAfterLecture(.accessory)
        #expect(world.playersMade == 0, "asking about the player never creates it")
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(controller.isPlayerOpen)
        controller.keepPolicyAfterLecture(.accessory)
        #expect(world.player.adoptedPolicies == [.accessory])
        controller.turnOff()
    }

    /// A saved session of another account found when it is read closes the player and forgets
    /// the places and the address removal, like any account change. Mutation: remove
    /// `closePlayerForIdentityChange()`, `forgetResumePoints()` or `forgetEmailOptOut()` from the
    /// owner-mismatch branch of `adopt`.
    @Test func aSessionOfAnotherAccountFoundOnReadClosesThePlayer() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.player.pause(at: 1_800)
        #expect(defaults.data(forKey: resumeKey) != nil)
        defaults.set(42, forKey: RecordingsController.emailDeclinedKey)
        controller.windowClosed()
        await drainTasks()
        try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN", value: "other")], ownerUserID: 9, now: world.now))
        controller.signIn()
        await settle("player closed by the mismatch") { world.player.closes == 1 }
        await settle("signed in again") { controller.access == .ready }
        #expect(defaults.object(forKey: resumeKey) == nil)
        #expect(resumeWrites() == 2, "one write, one removal: the close's report wrote nothing")
        #expect(defaults.object(forKey: RecordingsController.emailDeclinedKey) == nil)
    }

    /// A stream that dies mid-lecture stores where it stopped at once, from the `.failed`
    /// checkpoint alone, with no pause or close after it: if the student then quits, the place
    /// survives. Guards against handling only some checkpoint reasons now that reports carry one.
    /// Mutation: in `currentPlayer` ignore checkpoints whose reason is `.failed` and nothing is
    /// stored.
    @Test func aFailureMidLectureStoresThePlaceAtOnce() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        #expect(resumeWrites() == 0)

        world.player.failDuringPlayback(at: 1_234)
        #expect(resumeWrites() == 1, "written by the failure's own report")
        #expect(try storedResumePoints()?.position(for: RecordingsStudyState.identity(recording("a"))) == 1_234)
        await settle("resumed") { world.player.plays.count == 2 }
        controller.turnOff()
    }

    /// While the Polimi session is gone nothing can look a stream up: a lecture that stops is
    /// left alone and its one retry is not spent, so after signing in again it still recovers.
    /// Mutation: insert into `recoveredLectures` in `playerFailed` again (before the access
    /// guard) and the last expectation fails.
    @Test func aFailureWhileSignedOutDoesNotSpendTheRetry() async throws {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .success(stream("a"))]
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        controller.refresh([course], selected: course)
        await settle("signed out") { controller.access == .needsSignIn(nil) }
        // The sign-in below reloads the page's courses: let that succeed.
        browser.listResults[course.courseCode] = .success([])
        world.player.failDuringPlayback(at: 300)
        await drainTasks()
        #expect(browser.streamCalls == ["stream a"])
        #expect(world.opened.isEmpty)
        #expect(world.player.isOpen, "the paused window stays")

        controller.signIn()
        await settle("signed in") { controller.access == .ready }
        world.player.failDuringPlayback(at: 99)
        await settle("recovered after signing in") { world.player.plays.count == 2 }
        #expect(try world.player.play(1).startAt == 99)
        controller.turnOff()
    }

    /// A lecture that never starts while the Polimi session is gone says so instead of doing
    /// nothing. Mutation: remove the `openingProblem` line in the `access == .ready` guard.
    @Test func aFailureToStartWhileSignedOutSaysSo() async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a"))]
        browser.playbackResults["a"] = .success(playerLink("a"))
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        browser.listResults[course.courseCode] = .failure(RecmanBrowserError.needsSignIn)
        controller.refresh([course], selected: course)
        await settle("signed out") { controller.access == .needsSignIn(nil) }
        world.player.failBeforeReady()
        await settle("problem shown") { controller.openingProblem == .playbackUnavailable }
        #expect(world.opened.isEmpty)
        controller.turnOff()
    }

    /// The profile is asked once per session: an empty or failed answer is not asked again at
    /// every Settings appearance. Mutation: reset `suggestionAttempted` after the answer.
    @Test func theProfileIsAskedOncePerSession() async {
        defer { cleanUp() }
        world.profileEmail = nil
        let controller = await readyController()
        await controller.prepareEmailField()
        await controller.prepareEmailField()
        await controller.prepareEmailField()
        #expect(world.profileEmailCalls == 1)
        controller.turnOff()
    }

    /// A recovery that needs the email (removed meanwhile) shows the product-decision sentence
    /// and does not open Webex in the browser; the window stays. Mutation: remove the `needsEmail`
    /// branch in `recoverPlayback` and the browser opens.
    @Test func aRecoveryWithoutAnEmailOpensNoWebexPage() async {
        defer { cleanUp() }
        browser.streamResults["a"] = [.success(stream("a")), .failure(RecmanBrowserError.needsEmail)]
        browser.playbackResults["a"] = .success(playerLink("a"))
        let controller = await readyController()
        controller.play(recording("a"))
        await settle("a playing") { world.player.plays.count == 1 }
        world.player.failDuringPlayback(at: 400)
        await settle("problem shown") { controller.openingProblem == .playbackUnavailable }
        #expect(controller.openingProblem?.message == "Non è stato possibile aprire questa registrazione.")
        #expect(world.opened.isEmpty)
        #expect(browser.playCalls.isEmpty)
        #expect(world.player.isOpen)
        controller.turnOff()
    }

    /// A session file that could not be read when the app looked (a disk error) still has its
    /// email afterwards: the next sign-in's save keeps what the file holds instead of writing
    /// "none" over it. Mutation: pass `keepingFileEmail: false` in `saveSession`.
    /// (Needs permissions to be enforced, so it does not hold when run as root.)
    @Test func anUnreadableSessionKeepsItsEmailThroughTheNextSave() async throws {
        defer { cleanUp() }
        try store.save(RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN", value: "saved")], ownerUserID: 42, email: "a.b@polimi.it", now: world.now))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sessionFile.path)
        let controller = makeController(useDefault: true)
        controller.pageAppeared()
        await settle("unreadable file asks for a sign-in") { controller.access == .needsSignIn(nil) }
        let gate = FakeRecmanBrowser.Gate()
        defer { gate.release() }
        browser.signInGate = gate
        controller.signIn()
        await settle("sign-in held") { gate.isWaiting }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFile.path)
        gate.release()
        await settle("signed in") { controller.access == .ready }
        await controller.settleSessionFile()
        #expect(try savedEmail() == "a.b@polimi.it")
        #expect(try savedSession()?.cookies.map(\.value) == ["fresh"])
        controller.turnOff()
    }
}

/// Recordings through the real account controller: disconnecting, switching university and a
/// different WeBeep account all delete the Polimi session, even one saved in an earlier launch.
@MainActor
struct RecordingsAccountTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-account-\(UUID().uuidString)", isDirectory: true)

    private var store: RecordingsSessionStore {
        let folder = root.appendingPathComponent("support", isDirectory: true)
        return RecordingsSessionStore { folder }
    }

    private func session(owner: Int) throws -> Data {
        try RecmanSessionCodec.encode([FakeRecmanBrowser.cookie("SSO_LOGIN")], ownerUserID: owner)
    }

    @Test func disconnectingOrSwitchingUniversityDeletesThePolimiSession() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(session(owner: 1))
        let controller = WeBeepAuthenticationController(testRootURL: root.appendingPathComponent("sync"), deleteCredential: {}, defaults: defaults, recordingsStore: store)
        // Not touched in this launch: the sign-out must still find and delete the session.
        #expect(controller.recordingsIfCreated == nil)

        controller.signOut()
        #expect(!controller.hasStoredCredential)
        await controller.recordings.settleSessionFile()
        #expect(try store.load() == nil)
        #expect(defaults.object(forKey: RecordingsController.enabledKey) == nil)
        #expect(!controller.recordings.isEnabled)

        // Switching university, with nothing connected, drops whatever is saved too.
        try store.save(session(owner: 1))
        controller.selectSite(MoodleSite.unipd[0])
        await controller.recordings.settleSessionFile()
        #expect(try store.load() == nil)
    }

    /// A failed disconnect keeps the account, and with it the Recordings switch and session.
    @Test func aFailedDisconnectKeepsTheSession() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        let saved = try session(owner: 1)
        try store.save(saved)
        let controller = WeBeepAuthenticationController(testRootURL: root.appendingPathComponent("sync"), deleteCredential: { throw CredentialStorageError.write }, defaults: defaults, recordingsStore: store)
        controller.signOut()
        #expect(controller.hasStoredCredential)
        #expect(try store.load() == saved)
        #expect(defaults.bool(forKey: RecordingsController.enabledKey))
    }

    /// The account controller tells Recordings who is signed in to WeBeep: a session saved for
    /// another account (used while the account was unknown) is dropped once WeBeep answers.
    /// The local Moodle answers user id 7 (`MoodleRecordingProtocol`).
    @Test func signingInToAnotherWeBeepAccountDropsTheSession() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: sync.path)
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")])
        let vault = CredentialVault(read: { _ in token }, write: { _ in })
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(session(owner: 9))
        let browser = FakeRecmanBrowser()
        let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
        browser.listResults[key.courseCode] = .success([])
        let controller = WeBeepAuthenticationController(testRootURL: sync, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault, defaults: defaults, recordingsStore: store, recordingsBrowser: { browser })

        let recordings = controller.recordings
        recordings.pageAppeared()
        recordings.refresh([key], selected: key)
        for _ in 0..<2_000 where recordings.listing(for: key)?.recordings == nil { try await Task.sleep(for: .milliseconds(1)) }
        #expect(browser.openedWith == [["SSO_LOGIN"]])
        #expect(try store.load() != nil)

        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        #expect(controller.courseLoadError == nil)
        await recordings.settleSessionFile()
        #expect(try store.load() == nil)
        #expect(recordings.access == .needsSignIn(nil))
        #expect(!browser.isOpen)
    }

    /// Disconnecting through the account controller closes an open lecture and forgets the
    /// places stored for it. Mutation: remove `closePlayerForIdentityChange()` or
    /// `forgetResumePoints()` from `turnOff`. (A university change calls the same `turnOff`.)
    @Test func disconnectingClosesThePlayerAndForgetsPlaces() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        defaults.set(true, forKey: RecordingsController.enabledKey)
        try store.save(session(owner: 1))
        let browser = FakeRecmanBrowser()
        let player = FakeRecordingPlayer()
        let url = URL(string: "https://nfg1wss.webex.com/nbr/a/hls.m3u8")!
        browser.streamResults["a"] = [.success(RecordingStream(url: url, title: nil, duration: nil))]
        let controller = WeBeepAuthenticationController(testRootURL: root.appendingPathComponent("sync"), deleteCredential: {}, defaults: defaults, recordingsStore: store, recordingsBrowser: { browser })
        controller.recordingsPlayerForTesting = { player }
        let recordings = controller.recordings
        recordings.pageAppeared()
        let recording = RecmanRecording(id: "a", courseCode: "058167", academicYear: 2026, title: "Lezione a", recordedAt: Date(timeIntervalSince1970: 1_790_000_000), kind: "Lezione", duration: "90 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/x?transfer_id=a")!)
        recordings.play(recording)
        for _ in 0..<2_000 where player.plays.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(player.plays.count == 1)
        player.pause(at: 1_800)
        #expect(defaults.data(forKey: RecordingsController.resumePointsKey) != nil)

        controller.signOut()
        #expect(player.closes == 1)
        #expect(!player.isOpen)
        #expect(defaults.data(forKey: RecordingsController.resumePointsKey) == nil)
        await recordings.settleSessionFile()
    }

    /// A different account signing in clears the previous account's stored places even when
    /// nothing created Recordings in this launch; the same account's are kept.
    /// Mutation: remove `forgetResumePoints(in:notOwnedBy:)` from `siteInfo.didSet`.
    @Test(arguments: [9, 7])
    func anAccountChangeForgetsPlacesEvenWithoutRecordings(storedOwner: Int) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: sync.path)
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")])
        let vault = CredentialVault(read: { _ in token }, write: { _ in })
        let defaults = WeBeepAuthenticationController.throwawayDefaults()
        var points = RecordingResumePoints(owner: storedOwner)
        points.apply(.remember(100), for: "2026:058167:a")
        defaults.set(try PropertyListEncoder().encode(points), forKey: RecordingsController.resumePointsKey)
        defaults.set(storedOwner, forKey: RecordingsController.emailDeclinedKey)
        let controller = WeBeepAuthenticationController(testRootURL: sync, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault, defaults: defaults, recordingsStore: store)
        #expect(controller.recordingsIfCreated == nil)

        // The local Moodle answers user id 7 (`MoodleRecordingProtocol`).
        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        #expect(controller.recordingsIfCreated == nil)
        #expect((defaults.data(forKey: RecordingsController.resumePointsKey) != nil) == (storedOwner == 7))
        #expect((defaults.object(forKey: RecordingsController.emailDeclinedKey) != nil) == (storedOwner == 7))
    }

    /// The profile address is asked only when WeBeep lists the function for this token, and the
    /// listed case returns the address (so the unlisted nil is not a broken fixture).
    /// Mutation: drop the `availableFunctions` check in `profileEmail` and the unlisted case
    /// sends the request.
    @Test(arguments: [true, false])
    func theProfileAddressIsAskedOnlyWhenWeBeepListsIt(listed: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, token) = try await signedInAccount(userID: 7, email: "mario.rossi@mail.polimi.it", listed: listed)
        let address = await controller.profileEmailForTesting()
        #expect(address == (listed ? "mario.rossi@mail.polimi.it" : nil))
        let asked = MoodleRecordingProtocol.requests(token: token).contains { $0.function == WeBeepAPIClient.ownEmailFunction }
        #expect(asked == listed)
    }

    /// An address that arrives after another WeBeep account signed in is not offered: it is the
    /// previous account's. Mutation: return `address` without comparing `siteInfo?.userID` in
    /// `profileEmail` and the late answer is returned.
    @Test func aProfileAddressArrivingAfterAnAccountChangeIsDropped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, token) = try await signedInAccount(userID: 7, email: "mario.rossi@mail.polimi.it", listed: true)
        MoodleRecordingProtocol.holdEmails(token: token)
        let lookup = Task { await controller.profileEmailForTesting() }
        for _ in 0..<2_000 where MoodleRecordingProtocol.heldEmailCount(token: token) == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(MoodleRecordingProtocol.heldEmailCount(token: token) == 1)

        let other = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 8)
        await controller.completeLoginForTesting(moodleLoginCallback(token: other))
        MoodleRecordingProtocol.releaseEmails(token: token)
        #expect(await lookup.value == nil)
    }

    /// The course picture for Now Playing arrives for the account that asked; one that arrives
    /// after another account signed in is dropped (it is the previous account's). Guards against
    /// a late picture of account A showing in account B's player.
    /// Mutation: drop the `apiClient === client, siteInfo?.userID == userID` guard in
    /// `courseImage` and the late picture is returned.
    @Test func aCoursePictureArrivingAfterAnAccountChangeIsDropped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, token) = try await signedInAccount(userID: 7, email: "mario.rossi@mail.polimi.it", listed: false)
        let picture = URL(string: "https://webeep.polimi.it/webservice/pluginfile.php/1/course/overviewfiles/a.png")!
        let delivered = try await controller.courseImageForTesting(picture)
        #expect(delivered == Data([1, 2, 3]), "the same account gets its picture")

        MoodleRecordingProtocol.holdCourseImages(token: token)
        let fetch = Task { try await controller.courseImageForTesting(picture) }
        for _ in 0..<2_000 where MoodleRecordingProtocol.heldCourseImageCount(token: token) == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(MoodleRecordingProtocol.heldCourseImageCount(token: token) == 1)
        let other = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: 8)
        await controller.completeLoginForTesting(moodleLoginCallback(token: other))
        MoodleRecordingProtocol.releaseCourseImages(token: token)
        let late = await fetch.result
        #expect((try? late.get()) == nil, "the previous account's picture was delivered")
    }

    /// A controller signed in to the local Moodle as `userID`, whose profile holds `email`.
    private func signedInAccount(userID: Int, email: String, listed: Bool) async throws -> (WeBeepAuthenticationController, String) {
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: sync.path)
        let token = MoodleRecordingProtocol.register(courses: [(1, "Course")], userID: userID)
        MoodleRecordingProtocol.setProfileEmail(token: token, email, listed: listed)
        let current = OSAllocatedUnfairLock(initialState: token)
        let vault = CredentialVault(read: { _ in current.withLock { $0 } }, write: { new in current.withLock { $0 = new } })
        let controller = WeBeepAuthenticationController(testRootURL: sync, database: database, rootID: rootID, apiClient: MoodleRecordingProtocol.makeClient(), credentialVault: vault, defaults: WeBeepAuthenticationController.throwawayDefaults(), recordingsStore: store)
        await controller.completeLoginForTesting(moodleLoginCallback(token: token))
        #expect(controller.courseLoadError == nil)
        return (controller, token)
    }

}
