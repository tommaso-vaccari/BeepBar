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

/// A plain view that takes a player through key-value coding, as `AVPlayerView` does, without
/// AVKit: whatever is registered on the player then comes from the controller alone.
final class FakePlayerView: NSView {
    @objc dynamic var player: AVPlayer?
}

/// A view without a `player` key: key-value coding on it would raise an uncatchable exception.
final class ViewWithoutPlayer: NSView {}

/// Counts periodic and boundary time observers: the player must never register either.
final class CountingPlayer: AVPlayer, @unchecked Sendable {
    let timeObservers = OSAllocatedUnfairLock(initialState: 0)

    override func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void) -> Any {
        timeObservers.withLock { $0 += 1 }
        return super.addPeriodicTimeObserver(forInterval: interval, queue: queue, using: block)
    }

    override func addBoundaryTimeObserver(forTimes times: [NSValue], queue: DispatchQueue?, using block: @escaping @Sendable () -> Void) -> Any {
        timeObservers.withLock { $0 += 1 }
        return super.addBoundaryTimeObserver(forTimes: times, queue: queue, using: block)
    }
}

/// Records every seek's tolerances and can hold seeks in flight, to observe the moment between
/// a resume seek being issued and landing.
final class SeekRecordingPlayer: AVPlayer, @unchecked Sendable {
    struct Seek { let target: Double; let before: CMTime; let after: CMTime }
    private let state = OSAllocatedUnfairLock(initialState: (seeks: [Seek](), hold: false))
    var seeks: [Seek] { state.withLock { $0.seeks } }
    func holdSeeks() { state.withLock { $0.hold = true } }

    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        let hold = state.withLock { state -> Bool in
            state.seeks.append(Seek(target: time.seconds, before: toleranceBefore, after: toleranceAfter))
            return state.hold
        }
        // A held seek never lands: neither the player moves nor the completion runs.
        guard !hold else { return }
        super.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter, completionHandler: completionHandler)
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
        var checkpoints: [(position: TimeInterval, duration: TimeInterval?)] = []
        var failures: [RecordingPlaybackFailure] = []
        var events: [String] = []
        var fullScreenToggles = 0
    }

    private func makeController(defaults: UserDefaults = PlayerTestDefaults.throwaway(),
                                makePlayerView: @escaping @MainActor () -> NSView? = { FakePlayerView() },
                                makePlayer: @escaping @MainActor () -> AVPlayer = { AVPlayer() },
                                notificationCenter: NotificationCenter = .default,
                                recorder: Recorder? = nil) -> RecordingPlayerController {
        let policy = ActivationPolicyControl(current: { .regular }, set: { _ in })
        let controller = RecordingPlayerController(present: { _ in }, makePlayerView: makePlayerView, makePlayer: makePlayer,
                                                   activationPolicy: policy, frameAutosaveName: nil, defaults: defaults,
                                                   notificationCenter: notificationCenter,
                                                   toggleFullScreen: { _ in recorder?.fullScreenToggles += 1 })
        if let recorder {
            controller.onPositionCheckpoint = { position, duration in
                recorder.checkpoints.append((position, duration))
                recorder.events.append("checkpoint")
            }
            controller.onFailure = { failure in
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
        #expect(controller.canFastForward == false)
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
        #expect(rates() == RecordingPlayerPolicy.availableSpeeds(canPlayFastForward: false))
        try await Self.waitUntil { controller.isStartSettled }
        #expect(rates() == RecordingPlayerPolicy.speeds)
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

    /// While playing, nothing is reported and no periodic or boundary time observer exists: the
    /// position is never sampled on a clock. Guards against a "save every N seconds" creeping in.
    @Test func playbackAloneReportsNothingAndUsesNoTimeObserver() async throws {
        let recorder = Recorder()
        var created: CountingPlayer?
        let controller = makeController(makePlayer: { let player = CountingPlayer(); created = player; return player }, recorder: recorder)
        try await playReady(controller)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(recorder.checkpoints.isEmpty)
        #expect(controller.player?.rate != 0)
        let player = try #require(created)
        controller.close()
        #expect(player.timeObservers.withLock { $0 } == 0)
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
        controller.onPositionCheckpoint = { position, duration in
            openWhenReported = controller.player != nil
            recorder.checkpoints.append((position, duration))
        }
        if byUser { controller.window?.close() } else { controller.close() }
        #expect(recorder.checkpoints.count == before + 1)
        #expect(openWhenReported == true)
        #expect(abs((recorder.checkpoints.last?.position ?? 0) - 25) < 0.5)
        controller.close()
        await Self.settle()
        #expect(recorder.checkpoints.count == before + 1)
    }

    /// Closing before the stream is ready, or before the resume seek has landed, reports
    /// nothing: a saved position must never be replaced by 0.
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

    /// Between the item becoming ready and the resume seek landing, the player is still at 0:
    /// closing or pausing then reports nothing, so the saved position survives.
    @Test func closingBeforeTheResumeSeekLandsReportsNothing() async throws {
        let recorder = Recorder()
        var created: SeekRecordingPlayer?
        let controller = makeController(makePlayer: {
            let player = SeekRecordingPlayer()
            player.holdSeeks()
            created = player
            return player
        }, recorder: recorder)
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione", cookies: [], startAt: 30)
        try await Self.waitUntil { controller.isCurrentItemReady }
        #expect(created?.seeks.contains { $0.target == 30 } == true)
        #expect(controller.isStartSettled == false)
        controller.pause()
        await Self.settle()
        controller.close()
        await Self.settle()
        #expect(recorder.checkpoints.isEmpty)
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
        controller.play(media, title: "Altra", cookies: [], startAt: nil)
        #expect(recorder.checkpoints.count == before + 1)
        #expect(abs((recorder.checkpoints.last?.position ?? 0) - 40) < 0.5)
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

        try await park(controller, at: 20)
        window.sendEvent(key("l"))
        #expect(controller.pendingSeekTarget == 30)
        try await Self.waitUntil { controller.pendingSeekTarget == nil }
        window.sendEvent(key(left, left, [.function, .numericPad, .shift]))
        #expect(controller.pendingSeekTarget.map { $0 <= 1.01 } == true)
        try await Self.waitUntil { controller.pendingSeekTarget == nil }
        try await park(controller, at: 20)
        window.sendEvent(key(right, right, [.function, .numericPad]))
        #expect(controller.pendingSeekTarget == 30)
        try await Self.waitUntil { controller.pendingSeekTarget == nil }
        window.sendEvent(key("j"))
        #expect(controller.pendingSeekTarget.map { abs($0 - 20) <= 1.01 } == true)
        try await Self.waitUntil { controller.pendingSeekTarget == nil }

        window.sendEvent(key(">", ".", [.shift]))
        #expect(player.defaultRate == 1.25)
        window.sendEvent(key("<", ",", [.shift]))
        window.sendEvent(key("<", ",", [.shift]))
        #expect(player.defaultRate == 0.75)

        window.sendEvent(key("m"))
        #expect(player.isMuted)
        window.sendEvent(key("m", repeated: true))
        #expect(player.isMuted)
        window.sendEvent(key("m"))
        #expect(!player.isMuted)

        window.sendEvent(key("f"))
        #expect(recorder.fullScreenToggles == 1)

        player.play()
        #expect(player.rate != 0)
        window.sendEvent(key(" "))
        #expect(player.rate == 0)
        window.sendEvent(key(" "))
        #expect(player.rate != 0)
        window.sendEvent(key("k"))
        #expect(player.rate == 0)

        #expect(controller.handleKeyDown(key("f", "f", [.command])) == false)
        #expect(controller.handleKeyDown(key("x")) == false)
        #expect(controller.handleKeyDown(key("m", repeated: true)) == true)
        #expect(recorder.fullScreenToggles == 1)
        controller.close()
    }

    // MARK: Helpers

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
