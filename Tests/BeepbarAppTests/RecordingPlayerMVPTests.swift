import AppKit
@preconcurrency import AVFoundation
import Foundation
import os
import Testing
@testable import BeepbarApp

// MARK: Test doubles

/// In-memory defaults that count writes, so a test can prove the speed preference is written
/// only when the student changes it. Every accessor the player and these tests use is
/// overridden, so nothing reaches a preferences file (a suite, even emptied with
/// `removePersistentDomain`, leaves its plist behind).
final class PlayerTestDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String] = []
    private var values: [String: Any] = [:]

    static func throwaway() -> PlayerTestDefaults {
        PlayerTestDefaults(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }

    override func double(forKey defaultName: String) -> Double {
        (values[defaultName] as? NSNumber)?.doubleValue ?? 0
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        values[defaultName] = value
    }

    override func set(_ value: Double, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }

    /// Kept so tests read naturally; there is nothing on disk to remove.
    func discard() { values = [:] }
}

/// Records the activation policy changes a player makes; starts `.regular`.
@MainActor final class PolicyLog {
    var current: NSApplication.ActivationPolicy = .regular
    var sets: [NSApplication.ActivationPolicy] = []
}

/// A plain view that takes a player through key-value coding, as `AVPlayerView` does, without
/// AVKit: whatever is registered on the player then comes from the controller alone.
final class FakePlayerView: NSView {
    @objc dynamic var player: AVPlayer?
}

/// A view without a `player` key: key-value coding on it would raise an uncatchable exception.
final class ViewWithoutPlayer: NSView {}

/// Counts time observers added and removed, and the intervals asked for: the player may hold one
/// periodic observer only while playing, and never a boundary observer.
class CountingPlayer: AVPlayer, @unchecked Sendable {
    struct Counts {
        var periodicAdded = 0
        var boundaryAdded = 0
        var removed = 0
        var intervals: [Double] = []
    }
    let counts = OSAllocatedUnfairLock(initialState: Counts())
    /// Observers registered and not yet removed.
    var active: Int { counts.withLock { $0.periodicAdded + $0.boundaryAdded - $0.removed } }

    override func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void) -> Any {
        counts.withLock {
            $0.periodicAdded += 1
            $0.intervals.append(interval.seconds)
        }
        return super.addPeriodicTimeObserver(forInterval: interval, queue: queue, using: block)
    }

    override func addBoundaryTimeObserver(forTimes times: [NSValue], queue: DispatchQueue?, using block: @escaping @Sendable () -> Void) -> Any {
        counts.withLock { $0.boundaryAdded += 1 }
        return super.addBoundaryTimeObserver(forTimes: times, queue: queue, using: block)
    }

    override func removeTimeObserver(_ observer: Any) {
        counts.withLock { $0.removed += 1 }
        super.removeTimeObserver(observer)
    }

    /// Runs inside every `play()`, before the player starts: lets a test see the controller's
    /// state at the exact moment it starts playback, before any status report can change it.
    /// Tests only call `play()` on the main thread.
    nonisolated(unsafe) var onPlay: (@MainActor () -> Void)?

    override func play() {
        if let onPlay { MainActor.assumeIsolated { onPlay() } }
        super.play()
    }

    private let forcedStatus = OSAllocatedUnfairLock<AVPlayer.TimeControlStatus?>(initialState: nil)

    override var timeControlStatus: AVPlayer.TimeControlStatus {
        forcedStatus.withLock { $0 } ?? super.timeControlStatus
    }

    /// Reports `status` (nil: the real one) through the `timeControlStatus` KVO, as AVFoundation
    /// does when a stream stalls and waits for data: a state the local fixture never reaches.
    func report(_ status: AVPlayer.TimeControlStatus?) {
        willChangeValue(forKey: "timeControlStatus")
        forcedStatus.withLock { $0 = status }
        didChangeValue(forKey: "timeControlStatus")
    }
}

/// Records every seek's tolerances and can hold seeks in flight, to observe the moment between
/// a resume seek being issued and landing. A `CountingPlayer`, so a held resume can also force
/// its status and count its time observers.
final class SeekRecordingPlayer: CountingPlayer, @unchecked Sendable {
    struct Seek { let target: Double; let before: CMTime; let after: CMTime }
    private struct Held { let time: CMTime; let before: CMTime; let after: CMTime; let completion: @Sendable (Bool) -> Void }
    private let state = OSAllocatedUnfairLock(initialState: (seeks: [Seek](), hold: false, held: [Held]()))
    var seeks: [Seek] { state.withLock { $0.seeks } }
    func holdSeeks() { state.withLock { $0.hold = true } }

    /// Stops holding and lets every held seek run, in order.
    func releaseSeeks() {
        let held = state.withLock { state -> [Held] in
            state.hold = false
            defer { state.held = [] }
            return state.held
        }
        for seek in held {
            super.seek(to: seek.time, toleranceBefore: seek.before, toleranceAfter: seek.after, completionHandler: seek.completion)
        }
    }

    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        let hold = state.withLock { state -> Bool in
            state.seeks.append(Seek(target: time.seconds, before: toleranceBefore, after: toleranceAfter))
            if state.hold { state.held.append(Held(time: time, before: toleranceBefore, after: toleranceAfter, completion: completionHandler)) }
            return state.hold
        }
        // A held seek has not landed: neither the player moves nor the completion runs.
        guard !hold else { return }
        super.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter, completionHandler: completionHandler)
    }
}

extension RecordingPlayerController {
    /// Test shorthand: the title doubles as the recording id.
    func play(_ url: URL, title: String, cookies: [HTTPCookie], startAt: TimeInterval? = nil) {
        play(url, title: title, cookies: cookies, startAt: startAt, recordingID: title)
    }
}

/// Tracks block observers added and removed, so a test sees an observer left behind.
final class CountingCenter: NotificationCenter, @unchecked Sendable {
    private let tokens = OSAllocatedUnfairLock(initialState: [ObjectIdentifier]())
    var active: Int { tokens.withLock { $0.count } }

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        let token = super.addObserver(forName: name, object: obj, queue: queue, using: block)
        let id = ObjectIdentifier(token)
        tokens.withLock { $0.append(id) }
        return token
    }

    override func removeObserver(_ observer: Any) {
        let id = ObjectIdentifier(observer as AnyObject)
        tokens.withLock { $0.removeAll { $0 == id } }
        super.removeObserver(observer)
    }
}

/// Package G of issue #148: speeds, skips, keyboard shortcuts and the resume hooks
/// (`startAt`, `onPositionCheckpoint`). Same rules as `RecordingPlayerControllerTests`: nothing
/// is shown, the activation policy is faked, and defaults are throwaway.
@MainActor
@Suite(.serialized)
struct RecordingPlayerMVPTests {
    @MainActor final class Recorder {
        var checkpoints: [RecordingCheckpoint] = []
        var ticks: [(id: String, position: TimeInterval, duration: TimeInterval?)] = []
        var failures: [RecordingPlaybackFailure] = []
        var failureIDs: [String] = []
        var events: [String] = []
        var fullScreenToggles = 0
    }

    private func makeController(defaults: UserDefaults = PlayerTestDefaults.throwaway(),
                                makePlayerView: @escaping @MainActor () -> NSView? = { FakePlayerView() },
                                makePlayer: @escaping @MainActor () -> AVPlayer = { AVPlayer() },
                                notificationCenter: NotificationCenter = .default,
                                progressInterval: TimeInterval = RecordingPlayerController.progressInterval,
                                recorder: Recorder? = nil) -> RecordingPlayerController {
        let policy = ActivationPolicyControl(current: { .regular }, set: { _ in })
        let controller = RecordingPlayerController(present: { _ in }, makePlayerView: makePlayerView, makePlayer: makePlayer,
                                                   activationPolicy: policy, frameAutosaveName: nil, defaults: defaults,
                                                   notificationCenter: notificationCenter,
                                                   toggleFullScreen: { _ in recorder?.fullScreenToggles += 1 },
                                                   progressInterval: progressInterval)
        if let recorder {
            controller.onPositionCheckpoint = { checkpoint in
                recorder.checkpoints.append(checkpoint)
                recorder.events.append("checkpoint")
            }
            controller.onProgress = { id, position, duration in
                // Not in `events`: a tick AVFoundation queued before a pause may land after it.
                recorder.ticks.append((id, position, duration))
            }
            controller.onFailure = { id, failure in
                recorder.failureIDs.append(id)
                recorder.failures.append(failure)
                recorder.events.append("failure")
            }
        }
        return controller
    }

    /// Plays the fixture and waits until it is ready and started.
    private func playReady(_ controller: RecordingPlayerController, startAt: TimeInterval? = nil) async throws {
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: startAt)
        try await Self.waitUntil { controller.isStartSettled }
    }

    /// Pauses at a known position and lets the pause report settle, so a test starts clean.
    private func park(_ controller: RecordingPlayerController, at seconds: TimeInterval) async throws {
        let player = try #require(controller.player)
        player.pause()
        let landed = OSAllocatedUnfairLock(initialState: false)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            landed.withLock { $0 = true }
        }
        try await Self.waitUntil { landed.withLock { $0 } }
        await Self.settle()
    }

    private func time(_ controller: RecordingPlayerController) -> TimeInterval {
        controller.player?.currentTime().seconds ?? .nan
    }

    /// Waits for the hops and the seek they started, then checks the paused player landed within
    /// the seek tolerance of `seconds`.
    private func landed(_ controller: RecordingPlayerController, near seconds: TimeInterval,
                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await Self.drainHops()
        try await Self.waitUntil { controller.pendingSeekTarget == nil }
        await Self.settle()
        #expect(abs(time(controller) - seconds) <= 1.01, "landed at \(time(controller))", sourceLocation: sourceLocation)
    }

    // MARK: Speed and pitch

    /// Every item uses the spoken-word pitch algorithm, explicitly. Guards against relying on a
    /// default that changed before (spectral before macOS 12) and costs more CPU.
    @Test func everyItemUsesTimeDomainPitch() async throws {
        let controller = makeController()
        try await playReady(controller)
        #expect(controller.player?.currentItem?.audioTimePitchAlgorithm == .timeDomain)
        controller.close()
    }

    /// The remembered speed is applied to `defaultRate` (what play/resume uses), and playing
    /// never writes the preference. Guards against a speed that resets on resume, and against
    /// writes at every play.
    @Test func theRememberedSpeedIsAppliedWithoutWriting() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        defer { defaults.discard() }
        defaults.set(1.5, forKey: RecordingPlayerPolicy.speedDefaultsKey)
        let written = defaults.writes.count
        let controller = makeController(defaults: defaults)
        try await playReady(controller)
        let player = try #require(controller.player)
        #expect(player.defaultRate == 1.5)
        #expect(player.rate == 1.5)
        player.pause()
        player.play()
        #expect(player.rate == 1.5)
        #expect(defaults.writes.count == written)
        controller.close()
    }

    /// Choosing a speed applies it at once while playing, keeps it across pause/resume and the
    /// next lecture, and writes it once; choosing the same speed again writes nothing.
    @Test func choosingASpeedAppliesAndRemembersIt() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        defer { defaults.discard() }
        let controller = makeController(defaults: defaults)
        try await playReady(controller)
        let player = try #require(controller.player)
        controller.selectSpeed(1.75)
        #expect(player.defaultRate == 1.75)
        #expect(player.rate == 1.75)
        #expect(defaults.double(forKey: RecordingPlayerPolicy.speedDefaultsKey) == 1.75)
        let writes = defaults.writes.count
        #expect(writes >= 1)
        controller.selectSpeed(1.75)
        #expect(defaults.writes.count == writes)
        player.pause()
        controller.selectSpeed(0.75)
        #expect(player.rate == 0)
        #expect(player.defaultRate == 0.75)
        player.play()
        #expect(player.rate == 0.75)
        try await playReady(controller)
        #expect(controller.player?.defaultRate == 0.75)
        controller.selectSpeed(1.1)
        #expect(controller.player?.defaultRate == 0.75)
        controller.close()
    }

    /// Choosing the default speed when nothing is stored writes nothing: there is no change.
    @Test func choosingNormalSpeedFirstWritesNothing() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        defer { defaults.discard() }
        let controller = makeController(defaults: defaults)
        try await playReady(controller)
        controller.selectSpeed(1)
        #expect(defaults.writes.isEmpty)
        controller.close()
    }

    /// 2.5x and 3x wait for the item to say it can fast-forward: until it is ready the player
    /// runs at most at 2x, then at the remembered 3x (the local fixture can fast-forward).
    @Test func fastSpeedsWaitForFastForwardSupport() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        defer { defaults.discard() }
        defaults.set(3.0, forKey: RecordingPlayerPolicy.speedDefaultsKey)
        let controller = makeController(defaults: defaults)
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: nil)
        #expect(controller.player?.defaultRate == 2)
        #expect(controller.rateSupport == .unknown)
        try await Self.waitUntil { controller.isStartSettled }
        #expect(controller.player?.currentItem?.canPlayFastForward == true)
        #expect(controller.player?.defaultRate == 3)
        #expect(controller.preferredSpeed == 3)
        controller.close()
    }

    /// A speed chosen in `AVPlayerView`'s own menu (which sets `defaultRate`) is the student's
    /// choice: kept and remembered. A rate outside the list is followed but not remembered.
    @Test func aSpeedFromThePlayerViewIsRemembered() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        defer { defaults.discard() }
        let controller = makeController(defaults: defaults)
        try await playReady(controller)
        let player = try #require(controller.player)
        player.defaultRate = 2.5
        try await Self.waitUntil { controller.preferredSpeed == 2.5 }
        #expect(defaults.double(forKey: RecordingPlayerPolicy.speedDefaultsKey) == 2.5)
        player.defaultRate = 1.1
        try await Self.waitUntil { controller.appliedSpeed == 1.1 }
        #expect(defaults.double(forKey: RecordingPlayerPolicy.speedDefaultsKey) == 2.5)
        controller.close()
    }

    /// The title-bar menu lists the speeds, marks the current one, and choosing an item applies
    /// it (through the main-actor hop). Guards against a menu that shows but does nothing.
    @Test func theTitleBarMenuChangesSpeed() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        defer { defaults.discard() }
        let controller = makeController(defaults: defaults)
        try await playReady(controller)
        let window = try #require(controller.window)
        #expect(window is RecordingPlayerWindow)
        let popUp = try #require(controller.speedPopUp)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        let menu = try #require(popUp.menu)
        let speedItems = menu.items.filter { $0.representedObject is NSNumber }
        #expect(speedItems.map { ($0.representedObject as? NSNumber)?.floatValue } == RecordingPlayerPolicy.speeds)
        #expect(menu.item(at: 0)?.title == "1×")
        #expect(speedItems.filter { $0.state == .on }.count == 1)
        #expect(popUp.toolTip?.contains("K") == true)
        let item = try #require(speedItems.first { ($0.representedObject as? NSNumber)?.floatValue == 1.25 })
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        try await Self.waitUntil { controller.player?.defaultRate == 1.25 }
        #expect(item.state == .on)
        #expect(menu.item(at: 0)?.title == "1,25×")
        #expect(defaults.double(forKey: RecordingPlayerPolicy.speedDefaultsKey) == 1.25)
        controller.close()
    }

    /// `AVPlayerView` gets the same speed list, built at runtime without importing AVKit:
    /// capped at 2x before the item is ready, complete once it can fast-forward.
    @Test func theRealPlayerViewGetsTheSpeedList() async throws {
        let controller = makeController(makePlayerView: AVKitLoader.makePlayerView)
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: nil)
        let view = try #require(controller.playerView)
        func rates() -> [Float] { ((view.value(forKey: "speeds") as? [NSObject]) ?? []).compactMap { ($0.value(forKey: "rate") as? NSNumber)?.floatValue } }
        #expect(rates() == RecordingPlayerPolicy.availableSpeeds(.unknown))
        try await Self.waitUntil { controller.isStartSettled }
        #expect(rates() == RecordingPlayerPolicy.speeds)
        controller.close()
    }

    /// Every play gives `AVPlayerView` fresh speed objects, so their labels follow a language
    /// switch made between plays (tests never switch the language itself: it is process-wide).
    @Test func theViewSpeedsAreRebuiltAtEveryPlay() async throws {
        let controller = makeController(makePlayerView: AVKitLoader.makePlayerView)
        try await playReady(controller)
        let view = try #require(controller.playerView)
        let first = try #require(view.value(forKey: "speeds") as? [NSObject])
        try await playReady(controller)
        let second = try #require(view.value(forKey: "speeds") as? [NSObject])
        #expect(first.count == second.count)
        #expect(zip(first, second).allSatisfy { $0 !== $1 })
        controller.close()
    }

    /// Rate support can change after the item is ready: 2.5x/3x and 0.5x/0.75x follow it, both
    /// ways, and the remembered speed is never rewritten by a cap. A report from a replaced item
    /// is ignored.
    @Test func speedsFollowRateSupportChanges() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        defaults.set(3.0, forKey: RecordingPlayerPolicy.speedDefaultsKey)
        let written = defaults.writes.count
        let controller = makeController(defaults: defaults)
        try await playReady(controller)
        let player = try #require(controller.player)
        #expect(player.defaultRate == 3)
        let generation = controller.generation
        controller.rateSupportChanged(generation: generation, to: .unknown)
        #expect(player.defaultRate == 2)
        let threeItem = controller.speedPopUp?.menu?.items.first { ($0.representedObject as? NSNumber)?.floatValue == 3 }
        #expect(threeItem?.isEnabled == false)
        controller.rateSupportChanged(generation: generation, to: .all)
        #expect(player.defaultRate == 3)
        #expect(threeItem?.isEnabled == true)
        controller.rateSupportChanged(generation: generation - 1, to: .unknown)
        #expect(player.defaultRate == 3)
        #expect(defaults.writes.count == written)
        controller.close()
    }

    /// 0.5x and 0.75x wait for slow-forward support like the fast speeds wait for fast-forward:
    /// before the item is ready a remembered 0.5x plays at 1x, then at 0.5x once allowed.
    @Test func slowSpeedsWaitForSlowForwardSupport() async throws {
        let defaults = PlayerTestDefaults.throwaway()
        defaults.set(0.5, forKey: RecordingPlayerPolicy.speedDefaultsKey)
        let controller = makeController(defaults: defaults)
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: nil)
        #expect(controller.player?.defaultRate == 1)
        try await Self.waitUntil { controller.isStartSettled }
        #expect(controller.player?.currentItem?.canPlaySlowForward == true)
        #expect(controller.player?.defaultRate == 0.5)
        controller.rateSupportChanged(generation: controller.generation, to: RateSupport(fastForward: true, slowForward: false))
        #expect(controller.player?.defaultRate == 1)
        controller.close()
    }

    /// The runtime `AVPlaybackSpeed` factory produces real objects with the right rate and label.
    @Test func playbackSpeedsAreBuiltAtRuntime() throws {
        let speeds = try #require(AVKitLoader.makePlaybackSpeeds([0.75, 2.5]))
        #expect(speeds.map { NSStringFromClass(type(of: $0)) } == ["AVPlaybackSpeed", "AVPlaybackSpeed"])
        #expect(speeds.map { ($0.value(forKey: "rate") as? NSNumber)?.floatValue } == [0.75, 2.5])
        #expect(speeds.map { $0.value(forKey: "localizedName") as? String } == ["0,75×", "2,5×"])
    }

    // MARK: Skips and jumps

    /// Skips move by 10 / 30 s within a second's tolerance, accumulate when pressed in a row, and
    /// stop at 0 and at the end. Guards against skips past the ends or lost key repeats.
    @Test func skipsMoveAndClamp() async throws {
        let controller = makeController()
        try await playReady(controller)
        try await park(controller, at: 20)
        controller.skip(by: 10)
        controller.skip(by: 10)
        #expect(controller.pendingSeekTarget == 40)
        try await Self.waitUntil { controller.pendingSeekTarget == nil }
        #expect(abs(time(controller) - 40) <= 1.01)
        controller.skip(by: 30)
        try await Self.waitUntil { controller.pendingSeekTarget == nil }
        #expect(abs(time(controller) - TestMedia.duration) <= 1.01)
        try await park(controller, at: 3)
        controller.skip(by: -10)
        #expect(controller.pendingSeekTarget == 0)
        try await Self.waitUntil { controller.pendingSeekTarget == nil }
        #expect(time(controller) <= 1.01)
        controller.close()
    }

    /// Every seek the player makes (skips, jumps, the resume) has a bounded tolerance, well
    /// below the 10 s skip. An unlimited tolerance could snap to a keyframe behind the student
    /// in a lecture with long keyframe intervals, so "+10 s" would stay put or go back; the
    /// local fixture cannot show that, so the request itself is checked.
    @Test func seeksUseABoundedTolerance() async throws {
        var created: SeekRecordingPlayer?
        let controller = makeController(makePlayer: { let player = SeekRecordingPlayer(); created = player; return player })
        try await playReady(controller, startAt: 20)
        controller.skip(by: 10)
        controller.performShortcut(.jump(0.5))
        let player = try #require(created)
        // The view is a plain one, so every seek on this player is the controller's.
        let ours = player.seeks
        #expect(ours.count == 3)
        #expect(ours.first?.target == 20)
        #expect(ours.last?.target == 30)
        for seek in ours {
            for tolerance in [seek.before, seek.after] {
                #expect(tolerance.isNumeric && tolerance.seconds >= 0 && tolerance.seconds < RecordingPlayerPolicy.shortSkip / 2)
            }
        }
        controller.close()
    }

    /// Before the item is ready there is no timeline: skips and jumps do nothing.
    @Test func skipsBeforeReadyAreIgnored() async throws {
        let controller = makeController()
        controller.play(TestMedia.missing, title: "Mancante", cookies: [], startAt: nil)
        controller.skip(by: 10)
        controller.performShortcut(.jump(0.5))
        #expect(controller.pendingSeekTarget == nil)
        controller.close()
    }

    /// A digit jumps to that tenth of the lecture.
    @Test func digitsJump() async throws {
        let controller = makeController()
        try await playReady(controller)
        try await park(controller, at: 2)
        controller.performShortcut(.jump(0.5))
        #expect(controller.pendingSeekTarget == 30)
        try await Self.waitUntil { controller.pendingSeekTarget == nil }
        #expect(abs(time(controller) - 30) <= 1.01)
        controller.close()
    }

    // MARK: Resume position

    /// `startAt` holds playback until the item is ready, seeks there once, then plays. A second
    /// ready report does not seek again. Guards against the lecture starting at 0 then jumping,
    /// and against a later report undoing the student's own seek.
    @Test func startAtSeeksOnceThenPlays() async throws {
        let controller = makeController()
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: 30)
        #expect(controller.player?.rate == 0)
        try await Self.waitUntil { controller.isStartSettled }
        #expect(abs(time(controller) - 30) <= 1.5)
        #expect(controller.player?.rate != 0)
        try await park(controller, at: 10)
        controller.itemBecameReady(generation: controller.generation)
        await Self.settle()
        #expect(abs(time(controller) - 10) <= 0.5)
        controller.close()
    }

    /// A resume position near either end starts the lecture from the beginning, at once.
    @Test(arguments: [3.0, 57.0, 600.0]) func startAtNearTheEndsIsIgnored(startAt: TimeInterval) async throws {
        let controller = makeController()
        try await playReady(controller, startAt: startAt)
        #expect(controller.player?.rate != 0)
        #expect(time(controller) < 5)
        #expect(controller.pendingSeekTarget == nil)
        controller.close()
    }

    // MARK: Checkpoints

    /// Exactly one periodic time observer exists while the lecture plays, at 30 s of media time,
    /// and none once it pauses (the pause removes it; resuming adds it again, once) or closes;
    /// never a boundary observer. Guards the "quiet at rest" budget: a paused or closed lecture
    /// must cost no wakeups. (The observer added while the item loads is replaced once when the
    /// start settles, see `settleStart`, so only the live count is exact at that point.)
    /// Mutations: skip the removal on `.paused` in `updateProgressObserver` and the wait for 0
    /// after the pause times out; drop the `progressObservation == nil` guard and the status
    /// reports while playing leave more than one alive; drop the removal in `removeItemObservers`
    /// and close leaves 1 behind.
    @Test func onePeriodicObserverExistsOnlyWhilePlaying() async throws {
        let recorder = Recorder()
        var created: CountingPlayer?
        let controller = makeController(makePlayer: { let player = CountingPlayer(); created = player; return player }, recorder: recorder)
        try await playReady(controller)
        let player = try #require(created)
        try await Self.waitUntil { player.timeControlStatus == .playing }
        await Self.settle()
        #expect(player.active == 1, "several status reports while playing keep one observer")
        let added = player.counts.withLock { $0.periodicAdded }
        #expect(player.counts.withLock { $0.boundaryAdded } == 0)
        #expect(player.counts.withLock { $0.intervals }.allSatisfy { $0 == RecordingPlayerController.progressInterval })
        #expect(RecordingPlayerController.progressInterval == 30)
        await Self.settle()
        #expect(player.counts.withLock { $0.periodicAdded } == added, "playing on adds nothing")

        controller.pause()
        try await Self.waitUntil { player.active == 0 }
        await Self.settle()
        #expect(player.active == 0, "paused: no clock")
        #expect(recorder.checkpoints.map(\.reason) == [.paused])

        player.play()
        try await Self.waitUntil { player.active == 1 }
        await Self.settle()
        #expect(player.active == 1)
        #expect(player.counts.withLock { $0.periodicAdded } == added + 1, "resuming adds exactly one")

        controller.close()
        #expect(player.active == 0, "closed: removed synchronously")
        await Self.settle()
        #expect(player.active == 0)
        #expect(player.counts.withLock { $0.periodicAdded } == added + 1)
    }

    /// When the student started the held player during the resume and its status reports are
    /// all handled before the seek lands, landing may bring no further status change: the
    /// observer replaced in `settleStart` must be added again right there, or the lecture plays
    /// to its end with no progress at all. The state is read inside the `play()` that
    /// `settleStart` makes after the replacement, so a later status report cannot hide a missing
    /// observer by adding one back (it did in the first version of this test). The status is
    /// also pinned to `.playing`. Mutations: drop the `updateProgressObserver` call after
    /// `removeProgressObserver()` in `settleStart` and the serial seen at that moment is nil;
    /// drop the whole replacement and it is the early one.
    @Test func settlingReplacesTheEarlyObserverWithALiveOne() async throws {
        let recorder = Recorder()
        let (controller, player) = try await makeHeldResume(recorder: recorder)
        player.play()
        try await Self.waitUntil { player.timeControlStatus == .playing && controller.progressObserverSerial != nil }
        await Self.settle()
        let early = try #require(controller.progressObserverSerial)
        player.report(.playing)
        var serialWhenSettled: Int?? = .none
        player.onPlay = { serialWhenSettled = .some(controller.progressObserverSerial) }
        player.releaseSeeks()
        try await Self.waitUntil { controller.isStartSettled }
        player.onPlay = nil
        let seen = try #require(serialWhenSettled, "settling restarts playback")
        #expect(seen != nil, "still playing: the observer must exist when the start settles")
        #expect(seen != early, "a fresh observer, not the early one")
        await Self.settle()
        #expect(player.active == 1)
        player.report(nil)
        controller.close()
        #expect(player.active == 0)
    }

    /// A lecture that stalls (waiting for data at a rate) is still moving: the observer stays,
    /// so progress resumes the moment data arrives, and no checkpoint is made, since the student
    /// did not pause. Only `.paused` removes it. Guards against a buffering stream being treated
    /// as a pause. Mutation: add the observer only for `.playing` in `updateProgressObserver` and
    /// the observer is gone while waiting.
    @Test func aStalledLectureKeepsItsObserver() async throws {
        let recorder = Recorder()
        var created: CountingPlayer?
        let controller = makeController(makePlayer: { let player = CountingPlayer(); created = player; return player }, recorder: recorder)
        try await playReady(controller)
        let player = try #require(created)
        try await Self.waitUntil { player.timeControlStatus == .playing && player.active == 1 }
        player.report(.waitingToPlayAtSpecifiedRate)
        await Self.settle()
        #expect(player.active == 1, "waiting for data is not a pause")
        #expect(recorder.checkpoints.isEmpty)
        player.report(nil)
        await Self.settle()
        #expect(player.active == 1)
        controller.close()
        #expect(player.active == 0)
    }

    /// A replacement removes the old lecture's observer before anything else (with a resume
    /// position the player is held paused, so none exists until the resume lands), and a failure
    /// mid-lecture removes it before `onFailure` runs. Guards against an observer left ticking on
    /// a replaced item or on a failed stream. A replacement while playing adds the new item's
    /// observer inside `play` itself, since the new `timeControlStatus` observation reports
    /// changes only. Mutations: drop the removal in `removeItemObservers` and the synchronous
    /// expectation after the replacement fails; drop the `updateProgressObserver` call at the end
    /// of `play` and the synchronous count after the second replacement is 0; drop the removal in
    /// `fail` and the count seen from `onFailure` is 1.
    @Test func theObserverGoesOnReplacementAndFailure() async throws {
        let recorder = Recorder()
        var created: CountingPlayer?
        let controller = makeController(makePlayer: { let player = CountingPlayer(); created = player; return player }, recorder: recorder)
        try await playReady(controller)
        let player = try #require(created)
        try await Self.waitUntil { player.timeControlStatus == .playing && player.active == 1 }
        let media = try await TestMedia.shared.url()

        // Replaced by a lecture with a resume position: held paused, so no observer at all.
        controller.play(media, title: "Altra", cookies: [], startAt: 30, recordingID: "rec-2")
        #expect(player.active == 0, "the replaced lecture's observer is gone at once")
        #expect(recorder.checkpoints.last?.reason == .replaced)
        try await Self.waitUntil { controller.isStartSettled && player.active == 1 }

        // Replaced while playing, without a resume position: the old observer goes, one new one.
        let removed = player.counts.withLock { $0.removed }
        controller.play(media, title: "Terza", cookies: [], startAt: nil, recordingID: "rec-3")
        #expect(player.counts.withLock { $0.removed } == removed + 1)
        #expect(player.active == 1, "re-added within `play`, not left to a status report that may never come")
        try await Self.waitUntil { player.timeControlStatus == .playing && player.active == 1 }
        await Self.settle()
        #expect(player.active == 1)

        var activeAtFailure: Int?
        controller.onFailure = { _, _ in activeAtFailure = player.active }
        let item = try #require(player.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
        try await Self.waitUntil { activeAtFailure != nil }
        #expect(activeAtFailure == 0, "removed before the caller hears of the failure")
        #expect(recorder.checkpoints.last?.reason == .failed)
        await Self.settle()
        #expect(player.active == 0)
        controller.close()
        #expect(player.active == 0)
    }

    /// While playing, ticks reach `onProgress` with the lecture's id, position and duration, and
    /// never produce a checkpoint: only pauses, closes, replacements and failures do. Guards
    /// against a "save every N seconds" creeping in through the ticks. The interval is shortened
    /// so real AVFoundation ticks arrive within the fixture. Mutations: make `progressTicked`
    /// call `checkpointIfMeaningful(.paused)` and the checkpoints are no longer empty; forward
    /// nothing and the wait for ticks times out.
    @Test func ticksReportProgressAndNeverCheckpoint() async throws {
        let recorder = Recorder()
        let controller = makeController(progressInterval: 0.2, recorder: recorder)
        try await playReady(controller)
        try await Self.waitUntil { recorder.ticks.count >= 3 }
        #expect(recorder.checkpoints.isEmpty, "ticks are never checkpoints")
        #expect(recorder.ticks.allSatisfy { $0.id == "Lezione" && $0.duration == TestMedia.duration })
        let positions = recorder.ticks.map(\.position)
        #expect(positions.allSatisfy { $0 >= 0 && $0 <= TestMedia.duration })
        #expect((positions.last ?? 0) > (positions.first ?? 0), "the position moves on")
        #expect(controller.player?.rate != 0)
        controller.close()
        #expect(recorder.checkpoints.map(\.reason) == [.closed])
        let ticks = recorder.ticks.count
        try await Task.sleep(for: .milliseconds(600))
        #expect(recorder.ticks.count == ticks, "nothing after close")
    }

    /// A tick from a replaced or closed item is dropped by the generation check, and a tick that
    /// is not a finite, non-negative position is dropped too. Guards against a late tick
    /// crediting the previous lecture's position to the new one, and against NaN or a negative
    /// time reaching watch progress. Mutations: drop `observed == generation` and the
    /// replaced-generation tick is delivered; drop `position.isFinite, position >= 0` and the
    /// NaN and -1 ticks are delivered.
    @Test func ticksFromAReplacedItemOrWithoutAPositionAreDropped() async throws {
        let recorder = Recorder()
        let controller = makeController(recorder: recorder)
        try await playReady(controller)
        let old = controller.generation
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Altra", cookies: [], startAt: nil, recordingID: "rec-2")
        try await Self.waitUntil { controller.isStartSettled && controller.progressObserverSerial != nil }
        let serial = try #require(controller.progressObserverSerial)
        recorder.ticks.removeAll()
        controller.progressTicked(generation: old, observer: serial, position: 5)
        #expect(recorder.ticks.isEmpty, "a tick from the replaced lecture is dropped")
        controller.progressTicked(generation: controller.generation, observer: serial, position: .nan)
        controller.progressTicked(generation: controller.generation, observer: serial, position: -1)
        #expect(recorder.ticks.isEmpty, "no position, no tick")
        controller.progressTicked(generation: controller.generation, observer: serial, position: 5)
        #expect(recorder.ticks.count == 1)
        #expect(recorder.ticks.first?.id == "rec-2")
        #expect(recorder.ticks.first?.position == 5)
        #expect(recorder.ticks.first?.duration == TestMedia.duration)
        controller.close()
        controller.progressTicked(generation: controller.generation, observer: serial, position: 6)
        #expect(recorder.ticks.count == 1, "nothing after close")
    }

    /// The race behind P2-1 of the review: during a resume the student starts the held player
    /// from the system controls, so the observer exists while the player still shows ~0. A tick
    /// AVFoundation read then can land after the resume settles; it must be dropped, or a lecture
    /// resumed at 92% would report "below 90%" and closing could re-complete a lecture the
    /// student un-ticked. Before the start settles, ticks are dropped outright. Mutations: drop
    /// the re-arm in `settleStart` and the pre-settle tick delivered after the landing gets
    /// through; drop `isStartSettled` in `progressTicked` and the tick during the resume gets
    /// through; drop `observer == progressObserverSerial` and the pre-settle tick gets through.
    @Test func aTickReadBeforeTheResumeLandedIsDroppedAfterIt() async throws {
        let recorder = Recorder()
        let (controller, player) = try await makeHeldResume(recorder: recorder)
        // The student presses play on the system controls before the resume seek lands.
        player.play()
        try await Self.waitUntil { controller.progressObserverSerial != nil }
        let early = try #require(controller.progressObserverSerial)
        controller.progressTicked(generation: controller.generation, observer: early, position: 0.5)
        #expect(recorder.ticks.isEmpty, "the resume has not landed: 0.5 is not where the student is")

        player.releaseSeeks()
        try await Self.waitUntil { controller.isStartSettled }
        // A tick the early observer read at 0.5 s, delivered only now. Real ticks may arrive
        // too (AVFoundation fires on start and after the seek), all at or after the resume
        // target, so the check is that nothing below it got through.
        controller.progressTicked(generation: controller.generation, observer: early, position: 0.5)
        #expect(!recorder.ticks.contains { $0.position < 29 }, "read before the resume landed: dropped")
        let current = try #require(controller.progressObserverSerial)
        #expect(current != early, "the start settling replaced the observer")
        controller.progressTicked(generation: controller.generation, observer: current, position: 31)
        #expect(recorder.ticks.contains { $0.position == 31 }, "the new observer's ticks go through")
        #expect(recorder.checkpoints.isEmpty)
        controller.close()
    }

    /// A pause reports once, with the position and duration: `pause()`, a pause from outside
    /// (media keys, the controls: the player paused directly) and Space all do; pausing an
    /// already-paused player does not report again.
    @Test func pausesReportOnce() async throws {
        let recorder = Recorder()
        let controller = makeController(recorder: recorder)
        try await playReady(controller)
        let player = try #require(controller.player)
        controller.pause()
        try await Self.waitUntil { recorder.checkpoints.count == 1 }
        let first = try #require(recorder.checkpoints.first)
        #expect(abs(first.position - time(controller)) < 0.5)
        #expect(first.duration == TestMedia.duration)
        controller.pause()
        await Self.settle()
        #expect(recorder.checkpoints.count == 1)

        player.play()
        try await Self.waitUntil { player.timeControlStatus == .playing }
        await Self.settle()
        player.pause()
        try await Self.waitUntil { recorder.checkpoints.count == 2 }

        player.play()
        try await Self.waitUntil { player.timeControlStatus == .playing }
        await Self.settle()
        controller.performShortcut(.togglePlayPause)
        try await Self.waitUntil { recorder.checkpoints.count == 3 }
        await Self.settle()
        #expect(recorder.checkpoints.count == 3)
        #expect(recorder.checkpoints.map(\.reason) == [.paused, .paused, .paused])
        controller.close()
    }

    /// Closing reports the last position synchronously, while the player still exists, by
    /// `close()` and by the window's close button. Guards against losing the position the
    /// student closed on.
    @Test(arguments: [false, true]) func closingReportsBeforeTeardown(byUser: Bool) async throws {
        let recorder = Recorder()
        let controller = makeController(recorder: recorder)
        var openWhenReported: Bool?
        try await playReady(controller)
        try await park(controller, at: 25)
        let before = recorder.checkpoints.count
        controller.onPositionCheckpoint = { checkpoint in
            openWhenReported = controller.player != nil
            recorder.checkpoints.append(checkpoint)
        }
        if byUser { controller.window?.close() } else { controller.close() }
        #expect(recorder.checkpoints.count == before + 1)
        #expect(openWhenReported == true)
        #expect(abs((recorder.checkpoints.last?.position ?? 0) - 25) < 0.5)
        #expect(recorder.checkpoints.last?.reason == .closed)
        controller.close()
        await Self.settle()
        #expect(recorder.checkpoints.count == before + 1)
    }

    /// Closing before the stream is ready reports nothing: a saved position must never be
    /// replaced by 0.
    @Test func closingWhileLoadingReportsNothing() async throws {
        let recorder = Recorder()
        let controller = makeController(recorder: recorder)
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: 30)
        controller.pause()
        controller.close()
        await Self.settle()
        #expect(recorder.checkpoints.isEmpty)
    }

    /// A controller whose resume seeks are held in flight (the player is still at 0).
    private func makeHeldResume(recorder: Recorder, startAt: TimeInterval = 30) async throws -> (RecordingPlayerController, SeekRecordingPlayer) {
        var created: SeekRecordingPlayer?
        let controller = makeController(makePlayer: {
            let player = SeekRecordingPlayer()
            player.holdSeeks()
            created = player
            return player
        }, recorder: recorder)
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: startAt)
        try await Self.waitUntil { controller.isCurrentItemReady }
        let player = try #require(created)
        #expect(player.seeks.contains { $0.target == startAt })
        #expect(controller.isStartSettled == false && controller.isResuming)
        return (controller, player)
    }

    /// Closing while the resume seek is still in flight reports the resume position, not the 0
    /// the player still shows: the saved position survives.
    @Test func closingDuringTheResumeSeekReportsTheResumePosition() async throws {
        let recorder = Recorder()
        let (controller, _) = try await makeHeldResume(recorder: recorder)
        #expect(abs(time(controller)) < 0.5)
        controller.close()
        #expect(recorder.checkpoints.map(\.position) == [30])
        #expect(recorder.checkpoints.map(\.reason) == [.closed])
    }

    /// A failure while the resume seek is in flight reports the resume position, in the
    /// checkpoint and in the failure alike, and the resume landing afterwards does not restart
    /// playback. Guards against telling the caller to resume a failed lecture from 0.
    @Test func aFailureDuringTheResumeSeekReportsTheResumePosition() async throws {
        let recorder = Recorder()
        let (controller, player) = try await makeHeldResume(recorder: recorder)
        let item = try #require(controller.player?.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
        try await Self.waitUntil { !recorder.failures.isEmpty }
        guard case .duringPlayback(_, let position)? = recorder.failures.first else {
            Issue.record("Expected duringPlayback")
            return
        }
        #expect(position == 30)
        #expect(recorder.checkpoints.map(\.position) == [30])
        #expect(recorder.failureIDs == ["Lezione"])
        player.releaseSeeks()
        try await Self.waitUntil { controller.isStartSettled }
        await Self.settle()
        #expect(player.rate == 0)
        controller.close()
    }

    /// A failure while a skip is in flight reports where the skip was going, in the checkpoint
    /// and in the failure alike.
    @Test func aFailureDuringASkipReportsTheSkipTarget() async throws {
        let recorder = Recorder()
        var created: SeekRecordingPlayer?
        let controller = makeController(makePlayer: { let player = SeekRecordingPlayer(); created = player; return player }, recorder: recorder)
        try await playReady(controller)
        try await park(controller, at: 20)
        let player = try #require(created)
        recorder.checkpoints.removeAll()
        player.holdSeeks()
        controller.skip(by: 10)
        let target = try #require(controller.pendingSeekTarget)
        let item = try #require(player.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
        try await Self.waitUntil { !recorder.failures.isEmpty }
        guard case .duringPlayback(_, let position)? = recorder.failures.first else {
            Issue.record("Expected duringPlayback")
            return
        }
        #expect(abs(target - 30) < 0.5)
        #expect(position == target)
        #expect(recorder.checkpoints.map(\.position) == [target])
        controller.close()
    }

    /// Pausing during the resume (K, Space, `pause()`) does not drive the held player but
    /// records the intent, which the landing honours: paused stays paused, a second Space plays.
    @Test func pausingDuringTheResumeIsHonouredWhenItLands() async throws {
        let recorder = Recorder()
        let (controller, player) = try await makeHeldResume(recorder: recorder)
        controller.performShortcut(.pause)
        #expect(controller.playWhenSettled == false)
        #expect(player.rate == 0)
        controller.performShortcut(.togglePlayPause)
        #expect(controller.playWhenSettled == true)
        #expect(player.rate == 0, "Still held: the lecture must not start at 0")
        controller.pause()
        #expect(controller.playWhenSettled == false)
        player.releaseSeeks()
        try await Self.waitUntil { controller.isStartSettled }
        await Self.settle()
        #expect(player.rate == 0)
        #expect(abs(time(controller) - 30) <= 1.01)
        controller.close()

        let playing = Recorder()
        let (second, secondPlayer) = try await makeHeldResume(recorder: playing)
        second.performShortcut(.pause)
        second.performShortcut(.togglePlayPause)
        secondPlayer.releaseSeeks()
        try await Self.waitUntil { second.isStartSettled }
        #expect(secondPlayer.rate != 0)
        second.close()
    }

    /// A student who starts the held player from the system controls (play button, media key)
    /// before the resume seek lands is hearing the lecture from 0: K, Space and `pause()` must
    /// stop that playback, not only change the intention for when the seek lands. Guards against
    /// a lecture that keeps playing after "pause". Mutation: make `pause()` return right after
    /// recording the intent (the old code) and the first expectation fails; make `.togglePlayPause`
    /// always toggle the intention and the Space expectation fails.
    @Test func pausingDuringTheResumeStopsAPlayerTheStudentStarted() async throws {
        for stopper in ["pause()", "K", "Space"] {
            let recorder = Recorder()
            let (controller, player) = try await makeHeldResume(recorder: recorder)
            // The system controls drive the AVPlayer directly, past the controller.
            player.play()
            #expect(player.rate != 0, "the student started the held player (\(stopper))")
            switch stopper {
            case "pause()": controller.pause()
            case "K": controller.performShortcut(.pause)
            default: controller.performShortcut(.togglePlayPause)
            }
            #expect(player.rate == 0, "\(stopper) must pause what is playing")
            #expect(controller.playWhenSettled == false, "and the landing must not start it again (\(stopper))")
            player.releaseSeeks()
            try await Self.waitUntil { controller.isStartSettled }
            await Self.settle()
            #expect(player.rate == 0)
            #expect(abs(time(controller) - 30) <= 1.01)
            controller.close()
        }
    }

    /// The rate-support notification carries no value: the controller reads the item's flags
    /// itself when the notification lands, so a notification that arrives late still applies the
    /// item's current state, and one from a replaced item is dropped. Guards against an older hop
    /// overwriting a newer value. Mutation: restore the capture of the flags on AVFoundation's
    /// thread (pass a value into the hop) and the "reads the current item" expectation fails.
    @Test func theRateSupportNotificationReadsTheItemWhenItLands() async throws {
        let controller = makeController()
        try await playReady(controller)
        let player = try #require(controller.player)
        let generation = controller.generation
        // Pretend an older report left the controller believing nothing is supported.
        controller.rateSupportChanged(generation: generation, to: .unknown)
        #expect(controller.rateSupport == .unknown)
        #expect(player.currentItem?.canPlayFastForward == true)
        controller.rateSupportObserved(generation: generation)
        #expect(controller.rateSupport == .all, "reads the current item, not a value carried by the hop")
        controller.rateSupportChanged(generation: generation, to: .unknown)
        controller.rateSupportObserved(generation: generation - 1)
        #expect(controller.rateSupport == .unknown, "a notification from a replaced item is dropped")
        controller.close()
        controller.rateSupportObserved(generation: controller.generation)
        #expect(controller.player == nil, "nothing to read after close")
    }

    /// Handing the activation policy over (`chooseRoot` finding a lecture open after its panel):
    /// the player restores it at close, and only if BeepBar is still regular; a player that is
    /// not open adopts nothing. Guards against the Dock icon dropping under an open lecture, or
    /// staying forever after it. Mutation: empty the body of `adoptPolicyToRestore` and the
    /// restore expectation fails.
    @Test func aPolicyHandedOverIsRestoredAtClose() async throws {
        let log = PolicyLog()
        let controller = RecordingPlayerController(present: { _ in }, makePlayerView: { FakePlayerView() },
                                                   activationPolicy: ActivationPolicyControl(current: { log.current }, set: { log.current = $0; log.sets.append($0) }),
                                                   frameAutosaveName: nil, defaults: PlayerTestDefaults.throwaway())
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: nil)
        // BeepBar was already regular when the lecture opened, so the player holds nothing to restore.
        controller.adoptPolicyToRestore(.accessory)
        controller.close()
        #expect(log.sets == [.accessory], "restored once, at close")
        #expect(log.current == .accessory)

        let idle = PolicyLog()
        let idlePlayer = RecordingPlayerController(present: { _ in }, makePlayerView: { FakePlayerView() },
                                                   activationPolicy: ActivationPolicyControl(current: { idle.current }, set: { idle.current = $0; idle.sets.append($0) }),
                                                   frameAutosaveName: nil, defaults: PlayerTestDefaults.throwaway())
        idlePlayer.adoptPolicyToRestore(.accessory)
        idlePlayer.close()
        #expect(idle.sets.isEmpty)
    }

    /// A Play with a resume position while a lecture is playing pauses at once: the old
    /// lecture's sound must not run on into the new item before its resume lands.
    @Test func replacingWhilePlayingWithAResumePositionPausesFirst() async throws {
        let controller = makeController()
        try await playReady(controller)
        let player = try #require(controller.player)
        try await Self.waitUntil { player.timeControlStatus == .playing }
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Altra", cookies: [], startAt: 30)
        #expect(player.rate == 0)
        try await Self.waitUntil { controller.isStartSettled }
        #expect(player.rate != 0)
        controller.close()
    }

    /// A newer play reports where the previous lecture was left, synchronously, before it is
    /// replaced (the replaced lecture is closed). Package F must read its current recording
    /// before calling `play`.
    @Test func aReplacementReportsThePreviousLecture() async throws {
        let recorder = Recorder()
        let controller = makeController(recorder: recorder)
        try await playReady(controller)
        try await park(controller, at: 40)
        let before = recorder.checkpoints.count
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Altra", cookies: [], startAt: nil, recordingID: "rec-2")
        #expect(recorder.checkpoints.count == before + 1)
        #expect(abs((recorder.checkpoints.last?.position ?? 0) - 40) < 0.5)
        #expect(recorder.checkpoints.last?.id == "Lezione", "The replaced lecture's id, not the new one")
        #expect(recorder.checkpoints.last?.reason == .replaced)
        #expect(controller.recordingID == "rec-2")
        controller.close()
    }

    /// A mid-playback failure reports the position once, before `onFailure`, and the pause the
    /// player makes for it is not reported a second time. A failure before ready reports none.
    @Test func failuresReportOnceBeforeTheFailure() async throws {
        let recorder = Recorder()
        let controller = makeController(recorder: recorder)
        try await playReady(controller)
        try await Self.waitUntil { controller.player?.timeControlStatus == .playing }
        await Self.settle()
        recorder.events.removeAll()
        let item = try #require(controller.player?.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item,
                                        userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: URLError(.networkConnectionLost)])
        try await Self.waitUntil { !recorder.failures.isEmpty }
        await Self.settle()
        #expect(recorder.events == ["checkpoint", "failure"])
        #expect(recorder.checkpoints.map(\.reason) == [.failed])
        controller.close()

        let early = Recorder()
        let failing = makeController(recorder: early)
        failing.play(TestMedia.missing, title: "Mancante", cookies: [], startAt: nil)
        try await Self.waitUntil { !early.failures.isEmpty }
        await Self.settle()
        #expect(early.checkpoints.isEmpty)
    }

    // MARK: Observers and views

    /// The failed-to-play-to-end observer is removed on replacement and on close: exactly one
    /// lives while a lecture plays, none afterwards. Guards against observers piling up.
    @Test func theItemObserverIsRemoved() async throws {
        let center = CountingCenter()
        let controller = makeController(notificationCenter: center)
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Uno", cookies: [], startAt: nil)
        #expect(center.active == 1)
        controller.play(media, title: "Due", cookies: [], startAt: nil)
        #expect(center.active == 1)
        controller.close()
        #expect(center.active == 0)
    }

    /// An injected view that cannot take a player fails as "AVKit unavailable", without the
    /// key-value coding exception Swift cannot catch, and creates nothing.
    @Test(.timeLimit(.minutes(1))) func aViewWithoutAPlayerKeyFailsCleanly() async throws {
        let recorder = Recorder()
        let controller = makeController(makePlayerView: { ViewWithoutPlayer() }, recorder: recorder)
        controller.play(URL(fileURLWithPath: "/nonexistent.mp4"), title: "Lezione", cookies: [], startAt: nil)
        try await Self.waitUntil { !recorder.failures.isEmpty }
        guard case .beforeReady(let error)? = recorder.failures.first else {
            Issue.record("Expected beforeReady")
            return
        }
        #expect(error is RecordingPlayerError)
        #expect(controller.window == nil && controller.player == nil)
    }

    // MARK: Keyboard

    /// Synthesized key events through the window: the mapped keys act (and are taken, so
    /// `AVPlayerView` never runs its own binding), chords and unmapped keys go through, and a
    /// held toggle does not repeat.
    @Test func keyEventsDriveThePlayer() async throws {
        let recorder = Recorder()
        let defaults = PlayerTestDefaults.throwaway()
        defer { defaults.discard() }
        let controller = makeController(defaults: defaults, recorder: recorder)
        try await playReady(controller)
        let window = try #require(controller.window)
        let player = try #require(controller.player)
        func key(_ characters: String, _ ignoring: String? = nil, _ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: repeated, keyCode: 0)!
        }
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)

        /// Sends through the window, then lets the main-actor hop run.
        func send(_ event: NSEvent) async {
            window.sendEvent(event)
            await Self.drainHops()
        }

        // The hard rule: `sendEvent` acts only through a hop, never synchronously.
        window.sendEvent(key("m"))
        #expect(!player.isMuted, "Acted inside the AppKit callback")
        await Self.drainHops()
        #expect(player.isMuted)
        await send(key("m", repeated: true))
        #expect(player.isMuted)
        await send(key("m"))
        #expect(!player.isMuted)

        try await park(controller, at: 20)
        await send(key("l"))
        try await landed(controller, near: 30)
        await send(key(left, left, [.function, .numericPad, .shift]))
        try await landed(controller, near: 0)
        try await park(controller, at: 20)
        await send(key(right, right, [.function, .numericPad]))
        try await landed(controller, near: 30)
        await send(key("j"))
        try await landed(controller, near: 20)

        await send(key(">", ".", [.shift]))
        #expect(player.defaultRate == 1.25)
        await send(key("<", ",", [.shift]))
        await send(key("<", ",", [.shift]))
        #expect(player.defaultRate == 0.75)

        await send(key("f"))
        #expect(recorder.fullScreenToggles == 1)

        player.play()
        #expect(player.rate != 0)
        await send(key(" "))
        #expect(player.rate == 0)
        await send(key(" "))
        #expect(player.rate != 0)
        await send(key("k"))
        #expect(player.rate == 0)

        // Chords and unmapped keys go through; a held toggle is taken but does nothing.
        #expect(RecordingPlayerPolicy.keyDecision(for: key("f", "f", [.command])) == nil)
        #expect(RecordingPlayerPolicy.keyDecision(for: key("x")) == nil)
        let heldMute = try #require(RecordingPlayerPolicy.keyDecision(for: key("m", repeated: true)))
        #expect(heldMute.shortcut == .toggleMute && !heldMute.perform)
        await send(key("f", repeated: true))
        #expect(recorder.fullScreenToggles == 1)
        controller.close()
    }

    /// A held skip key's repeats, each through its own hop, add up: the hops run in order and
    /// each skip starts from where the previous one is going.
    @Test func heldSkipRepeatsAccumulate() async throws {
        let controller = makeController()
        try await playReady(controller)
        try await park(controller, at: 10)
        let window = try #require(controller.window)
        func key(repeated: Bool) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: "l", charactersIgnoringModifiers: "l", isARepeat: repeated, keyCode: 37)!
        }
        window.sendEvent(key(repeated: false))
        window.sendEvent(key(repeated: true))
        window.sendEvent(key(repeated: true))
        try await landed(controller, near: 40)
        controller.close()
    }

    /// On a layout that types non-Latin letters, the physical J key still skips back.
    @Test func aCyrillicLayoutUsesThePhysicalKey() async throws {
        let controller = makeController()
        try await playReady(controller)
        try await park(controller, at: 30)
        let window = try #require(controller.window)
        // On the Russian layout the J key types "о" (U+043E).
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: "\u{043E}", charactersIgnoringModifiers: "\u{043E}", isARepeat: false, keyCode: 38)!
        window.sendEvent(event)
        try await landed(controller, near: 20)
        controller.close()
    }

    // MARK: Helpers

    /// Lets queued main-actor hops (key shortcuts, menu actions) run.
    private static func drainHops() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private static func waitUntil(seconds: Double = 20, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { Issue.record("Condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<5 { await Task.yield() }
    }
}
