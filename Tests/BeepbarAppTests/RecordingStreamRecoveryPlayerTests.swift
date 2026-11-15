import AppKit
@preconcurrency import AVFoundation
import Foundation
import os
import Testing
import BeepbarCore
@testable import BeepbarApp

/// A player whose `timeControlStatus` a test can force, since a local fixture never stalls:
/// the change is announced to KVO like a real one.
final class StallablePlayer: AVPlayer, @unchecked Sendable {
    private let forced = OSAllocatedUnfairLock<AVPlayer.TimeControlStatus?>(initialState: nil)

    override var timeControlStatus: AVPlayer.TimeControlStatus { forced.withLock { $0 } ?? super.timeControlStatus }

    func force(_ status: AVPlayer.TimeControlStatus?) {
        willChangeValue(forKey: "timeControlStatus")
        forced.withLock { $0 = status }
        didChangeValue(forKey: "timeControlStatus")
    }
}

/// A clock the test moves by hand.
@MainActor final class ManualClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

/// Waits that last until cancelled, recorded: the stall wait, without a clock (#241).
final class RecordedSleeps: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (asked: [TimeInterval](), cancelled: 0, released: false))
    var asked: [TimeInterval] { state.withLock { $0.asked } }
    var cancelled: Int { state.withLock { $0.cancelled } }
    /// Lets every wait finish normally, as if its time had come.
    func release() { state.withLock { $0.released = true } }
    func sleep(_ seconds: TimeInterval) async throws {
        state.withLock { $0.asked.append(seconds) }
        do {
            while !state.withLock({ $0.released }) { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            state.withLock { $0.cancelled += 1 }
            throw error
        }
    }
}

/// What the player does about a stream that may have expired (#241): a stale resume after a long
/// pause or a sleep, through each way playback can be started, and a stall. The player reports
/// both as a mid-lecture failure (`RecordingStreamError`), so the controller's usual recovery
/// fetches a fresh stream at the position; these tests are about the player's side only.
@MainActor
@Suite(.serialized)
struct RecordingStreamRecoveryPlayerTests {
    private struct Rig {
        let controller: RecordingPlayerController
        let clock: ManualClock
        let wake: CountingCenter
        let sleeps: RecordedSleeps
        let player: StallablePlayer
        let recorder: Recorder
    }

    @MainActor final class Recorder {
        var failures: [RecordingPlaybackFailure] = []
        var staleCount: Int { failures.filter { if case .duringPlayback(let e, _) = $0 { (e as? RecordingStreamError) == .stale } else { false } }.count }
        var stalledCount: Int { failures.filter { if case .duringPlayback(let e, _) = $0 { (e as? RecordingStreamError) == .stalled } else { false } }.count }
    }

    private func makeRig() -> Rig {
        let clock = ManualClock()
        let wake = CountingCenter()
        let sleeps = RecordedSleeps()
        let player = StallablePlayer()
        let recorder = Recorder()
        let controller = RecordingPlayerController(
            present: { _ in }, makePlayerView: { FakePlayerView() }, makePlayer: { player },
            activationPolicy: ActivationPolicyControl(current: { .regular }, set: { _ in }),
            frameAutosaveName: nil, defaults: PlayerTestDefaults.throwaway(),
            workspaceNotificationCenter: wake, now: { MainActor.assumeIsolated { clock.date } },
            sleep: { try await sleeps.sleep($0) }, toggleFullScreen: { _ in }, nowPlaying: SilentNowPlaying())
        // The reported failure pauses the real player; the forced status must follow, or the
        // fake would keep "waiting" and re-arm the stall as a real paused player never does.
        controller.onFailure = { _, failure in
            recorder.failures.append(failure)
            player.force(nil)
        }
        return Rig(controller: controller, clock: clock, wake: wake, sleeps: sleeps, player: player, recorder: recorder)
    }

    private func playReady(_ rig: Rig, startAt: TimeInterval? = nil) async throws {
        let media = try await TestMedia.shared.url()
        rig.controller.play(media, title: "Lezione", cookies: [], startAt: startAt, recordingID: "a", metadata: nil)
        try await Self.waitUntil { rig.controller.isStartSettled }
    }

    /// Pauses at `seconds` and lets the pause settle, so the pause time is on the manual clock.
    private func park(_ rig: Rig, at seconds: TimeInterval) async throws {
        rig.player.pause()
        let landed = OSAllocatedUnfairLock(initialState: false)
        rig.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in landed.withLock { $0 = true } }
        try await Self.waitUntil { landed.withLock { $0 } }
        await Self.settle()
    }

    private func isMoving(_ rig: Rig) -> Bool { rig.player.rate != 0 }

    // MARK: Stale resume

    /// A pause just under ten minutes plays on; at ten minutes the same Space key reports the
    /// stale stream instead of playing, at the position where the lecture was paused. Guards
    /// against the threshold drifting, and against sound from an expired address.
    @Test func aPauseResumesUnderTheThresholdAndIsStaleAtIt() async throws {
        let rig = makeRig()
        try await playReady(rig)
        try await park(rig, at: 5)
        rig.clock.advance(RecordingStreamPolicy.staleAfterPause - 1)
        rig.controller.performShortcut(.togglePlayPause)
        await Self.settle()
        #expect(isMoving(rig))
        #expect(rig.recorder.failures.isEmpty)

        try await park(rig, at: 6)
        rig.clock.advance(RecordingStreamPolicy.staleAfterPause)
        rig.controller.performShortcut(.togglePlayPause)
        await Self.settle()
        #expect(!isMoving(rig), "the expired address was played")
        #expect(rig.recorder.staleCount == 1)
        guard case .duringPlayback(_, let position)? = rig.recorder.failures.first else { Issue.record("no failure"); return }
        #expect(abs(position - 6) < 0.5, "resumes where the student was, not before: \(position)")
        rig.controller.close()
    }

    /// A wake after the pause makes the stream stale however short the pause; a wake before the
    /// pause says nothing about it. The Mac sleeping drops the address's connection.
    @Test func aWakeAfterThePauseMakesTheStreamStale() async throws {
        let rig = makeRig()
        try await playReady(rig)
        // Woken while playing, then paused: not stale.
        rig.wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Self.settle()
        rig.clock.advance(1)
        try await park(rig, at: 5)
        rig.clock.advance(1)
        rig.controller.performShortcut(.togglePlayPause)
        await Self.settle()
        #expect(isMoving(rig))
        #expect(rig.recorder.failures.isEmpty)

        // Paused, then woken: stale.
        try await park(rig, at: 6)
        rig.clock.advance(1)
        rig.wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Self.settle()
        rig.clock.advance(1)
        rig.controller.performShortcut(.togglePlayPause)
        await Self.settle()
        #expect(!isMoving(rig))
        #expect(rig.recorder.staleCount == 1)
        rig.controller.close()
    }

    /// The three ways to start a stale lecture: the keyboard (`performShortcut`), the media keys
    /// and Control Center (`handleRemoteCommand(.play)`), and the view's own play button, which
    /// the player can only see as the player starting moving. Each reports the stale stream once
    /// and leaves the player paused.
    @Test(arguments: ["Space or K", "media key", "the view's own button"])
    func everyWayToStartAStaleLectureIsCaught(path: String) async throws {
        let rig = makeRig()
        try await playReady(rig)
        try await park(rig, at: 5)
        rig.clock.advance(RecordingStreamPolicy.staleAfterPause)
        switch path {
        case "Space or K": rig.controller.performShortcut(.togglePlayPause)
        case "media key": rig.controller.handleRemoteCommand(.play)
        default: rig.player.play()
        }
        await Self.settle()
        #expect(rig.recorder.staleCount == 1)
        #expect(!isMoving(rig), "the lecture is left paused for the fresh stream")
        rig.controller.close()
    }

    /// P1-A (#197 regression): after a mid-lecture failure whose recovery left the window open
    /// and paused, a student returning after a long pause or a sleep and starting the lecture,
    /// by any of the three paths, must get the stale stream reported again. Before the fix the
    /// stale start paused the player and `fail` returned silently, because the failure of
    /// before was still marked as reported: no `onFailure`, the lecture stuck with the old
    /// reason in the subtitle.
    @Test(arguments: [
        ("Space or K", false), ("media key", false), ("the view's own button", false),
        ("Space or K", true), ("media key", true), ("the view's own button", true),
    ])
    func aStaleStartAfterAReportedFailureIsReportedAgain(path: String, viaWake: Bool) async throws {
        let rig = makeRig()
        try await playReady(rig)
        rig.controller.fail(generation: rig.controller.generation, error: URLError(.networkConnectionLost))
        await Self.settle()
        #expect(rig.recorder.failures.count == 1)
        #expect(rig.recorder.staleCount == 0)
        rig.controller.window?.subtitle = "Interrotta"
        if viaWake {
            rig.clock.advance(1)
            rig.wake.post(name: NSWorkspace.didWakeNotification, object: nil)
            await Self.settle()
            rig.clock.advance(1)
        } else {
            rig.clock.advance(RecordingStreamPolicy.staleAfterPause)
        }
        switch path {
        case "Space or K": rig.controller.performShortcut(.togglePlayPause)
        case "media key": rig.controller.handleRemoteCommand(.play)
        default: rig.player.play()
        }
        await Self.settle()
        #expect(rig.recorder.staleCount == 1, "the stale start was swallowed")
        #expect(rig.recorder.failures.count == 2)
        #expect(rig.controller.window?.subtitle != "Interrotta", "the old reason stayed in the subtitle")
        #expect(!isMoving(rig))
        rig.controller.close()
    }

    /// The recovery episode's "student paused" mark (RecordingsController.playerCheckpoint) rests on
    /// one fact: a `.paused` checkpoint comes only from a pause the student can make. Each of the
    /// three ways to pause reports it once; the pauses the player makes itself (the stale start,
    /// a stall, a failure) report `.failed` or nothing, never `.paused`. If one of them did, a
    /// stream that starts and dies over and over would reset its own retry budget and never
    /// reach the browser.
    @Test(arguments: ["Space or K", "media key", "the view's own button"])
    func aStudentPauseReportsPaused(path: String) async throws {
        let rig = makeRig()
        var reasons: [RecordingCheckpoint.Reason] = []
        rig.controller.onPositionCheckpoint = { reasons.append($0.reason) }
        try await playReady(rig)
        rig.player.play()
        await Self.settle()
        switch path {
        case "Space or K": rig.controller.performShortcut(.togglePlayPause)
        case "media key": rig.controller.handleRemoteCommand(.pause)
        default: rig.player.pause()
        }
        await Self.settle()
        #expect(reasons == [.paused])
        rig.controller.close()
    }

    @Test(arguments: ["stale start", "stall", "failure"])
    func aPauseThePlayerMakesItselfNeverReportsPaused(cause: String) async throws {
        let rig = makeRig()
        var reasons: [RecordingCheckpoint.Reason] = []
        rig.controller.onPositionCheckpoint = { reasons.append($0.reason) }
        try await playReady(rig)
        switch cause {
        case "stale start":
            try await park(rig, at: 5)
            reasons.removeAll()
            rig.clock.advance(RecordingStreamPolicy.staleAfterPause)
            rig.controller.performShortcut(.togglePlayPause)
        case "stall":
            rig.player.force(.waitingToPlayAtSpecifiedRate)
            try await Self.waitUntil { rig.sleeps.asked.count == 1 }
            rig.sleeps.release()
            try await Self.waitUntil { rig.recorder.stalledCount == 1 }
        default:
            rig.player.play()
            await Self.settle()
            rig.controller.fail(generation: rig.controller.generation, error: URLError(.networkConnectionLost))
        }
        await Self.settle()
        #expect(!reasons.contains(.paused), "the player's own pause looked like the student's: \(reasons)")
        #expect(rig.recorder.failures.count == 1)
        rig.controller.close()
    }

    /// The wake observer exists only while a lecture is open: one after `play` (also after a
    /// second `play`), none after close. A closed player keeps nothing registered.
    @Test func theWakeObserverLivesOnlyWhileALectureIsOpen() async throws {
        let rig = makeRig()
        #expect(rig.wake.active == 0)
        try await playReady(rig)
        #expect(rig.wake.active == 1)
        try await playReady(rig)
        #expect(rig.wake.active == 1)
        rig.controller.close()
        #expect(rig.wake.active == 0)
    }

    // MARK: Stall

    /// Waiting for data for the threshold, once playing, is a failed stream: the wait is armed
    /// with exactly 15 s, and when it elapses the stall is reported once.
    @Test func aStallLongerThanTheThresholdIsReported() async throws {
        let rig = makeRig()
        try await playReady(rig)
        rig.player.force(.waitingToPlayAtSpecifiedRate)
        try await Self.waitUntil { rig.sleeps.asked == [RecordingStreamPolicy.stallThreshold] }
        #expect(rig.recorder.failures.isEmpty, "reported before the threshold")
        rig.sleeps.release()
        try await Self.waitUntil { rig.recorder.stalledCount == 1 }
        #expect(!isMoving(rig), "the stalled item is left paused for the fresh stream")
        rig.controller.close()
    }

    /// A stall that ends first (playing again, or a pause) cancels its wait and reports
    /// nothing: no timer is left running for a lecture that recovered by itself.
    @Test(arguments: [AVPlayer.TimeControlStatus.playing, .paused])
    func aShorterStallCancelsItsWait(then status: AVPlayer.TimeControlStatus) async throws {
        let rig = makeRig()
        try await playReady(rig)
        rig.player.force(.waitingToPlayAtSpecifiedRate)
        try await Self.waitUntil { rig.sleeps.asked.count == 1 }
        rig.player.force(status)
        try await Self.waitUntil { rig.sleeps.cancelled == 1 }
        #expect(rig.recorder.failures.isEmpty)
        rig.controller.close()
    }

    /// Closing the player cancels a stall wait in progress.
    @Test func closingCancelsTheStallWait() async throws {
        let rig = makeRig()
        try await playReady(rig)
        rig.player.force(.waitingToPlayAtSpecifiedRate)
        try await Self.waitUntil { rig.sleeps.asked.count == 1 }
        rig.controller.close()
        try await Self.waitUntil { rig.sleeps.cancelled == 1 }
        #expect(rig.recorder.failures.isEmpty)
    }

    /// A slow first load is the before-ready path, not a stall: nothing is armed until the item
    /// is ready and its start settled.
    @Test func aSlowFirstLoadIsNotAStall() async throws {
        let rig = makeRig()
        let media = try await TestMedia.shared.url()
        rig.controller.play(media, title: "Lezione", cookies: [], startAt: 20, recordingID: "a", metadata: nil)
        rig.player.force(.waitingToPlayAtSpecifiedRate)
        await Self.settle()
        if !rig.controller.isStartSettled { #expect(rig.sleeps.asked.isEmpty) }
        rig.controller.close()
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
