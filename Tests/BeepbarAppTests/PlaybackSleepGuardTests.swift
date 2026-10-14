import AppKit
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import BeepbarApp

/// Stands in for the system power assertions: counts what the guard asks for, so no test ever
/// touches the real ones (they would show up in `pmset -g assertions` on the developer's Mac).
final class FakeAssertions: @unchecked Sendable {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var reasons: [String] = []
    private var live: Set<Int> = []
    /// Assertions begun and not yet ended: must be 0 or 1, and 0 whenever nothing is playing.
    var held: Int { live.count }

    var assertion: PlaybackSleepGuard.Assertion {
        PlaybackSleepGuard.Assertion(
            begin: { reason in
                self.begins += 1
                self.reasons.append(reason)
                self.live.insert(self.begins)
                return self.begins
            },
            end: { token in
                self.ends += 1
                self.live.remove(token as! Int)
            })
    }
}

/// The keep-awake guard on its own: the contract the player relies on when it calls `update`
/// from every state report.
struct PlaybackSleepGuardTests {
    /// Repeated "playing" reports (KVO fires more than once per stretch) take one assertion.
    /// Guards against a leaked assertion per report, which would keep the Mac awake after
    /// the lecture ends. Mutation: drop the `token == nil` check in `update`.
    @Test func repeatedPlayingReportsBeginOnce() {
        let fake = FakeAssertions()
        let guardian = PlaybackSleepGuard(assertion: fake.assertion)
        for _ in 0..<5 { guardian.update(isPlaying: true) }
        #expect(fake.begins == 1)
        #expect(fake.held == 1)
        #expect(guardian.isHolding)
        #expect(!fake.reasons[0].isEmpty)
    }

    /// Stopping ends the assertion exactly once, however many "not playing" reports follow, and
    /// a stop with nothing held does nothing. Guards against a double end and against ending a
    /// token that was never begun. Mutation: do not clear the token in `update(isPlaying: false)`.
    @Test func stoppingEndsOnceAndWithoutBeginIsANoOp() {
        let fake = FakeAssertions()
        let guardian = PlaybackSleepGuard(assertion: fake.assertion)
        guardian.update(isPlaying: false)
        #expect(fake.begins == 0 && fake.ends == 0)
        guardian.update(isPlaying: true)
        for _ in 0..<3 { guardian.update(isPlaying: false) }
        #expect(fake.ends == 1)
        #expect(fake.held == 0)
        #expect(!guardian.isHolding)
    }

    /// Ten play/stop cycles leak nothing: one begin and one end each. Guards against a token
    /// overwritten without ending. Mutation: skip the `assertion.end` call in `update`.
    @Test func tenCyclesBalance() {
        let fake = FakeAssertions()
        let guardian = PlaybackSleepGuard(assertion: fake.assertion)
        for _ in 0..<10 {
            guardian.update(isPlaying: true)
            guardian.update(isPlaying: false)
        }
        #expect(fake.begins == 10 && fake.ends == 10 && fake.held == 0)
    }

    /// The assertion never outlives its owner: dropping the guard while it holds one ends it.
    /// Guards against a controller released mid-lecture leaving the display pinned on.
    /// Mutation: remove `deinit`.
    @Test func droppingTheGuardEndsTheAssertion() {
        let fake = FakeAssertions()
        var guardian: PlaybackSleepGuard? = PlaybackSleepGuard(assertion: fake.assertion)
        guardian?.update(isPlaying: true)
        #expect(fake.held == 1)
        guardian = nil
        #expect(fake.held == 0 && fake.ends == 1)
    }

    /// The real assertion starts and ends without trouble (it is the live `ProcessInfo` one, held
    /// for microseconds). Guards against the token type not round-tripping through `end`.
    @Test func theSystemAssertionRoundTrips() {
        let guardian = PlaybackSleepGuard()
        guardian.update(isPlaying: true)
        #expect(guardian.isHolding)
        guardian.update(isPlaying: false)
        #expect(!guardian.isHolding)
    }
}

/// The player's use of the guard: held exactly while the lecture is playing.
@MainActor
@Suite(.serialized)
struct PlayerKeepAwakeTests {
    private func make(_ fake: FakeAssertions, player created: @escaping (CountingPlayer) -> Void = { _ in }) -> RecordingPlayerController {
        RecordingPlayerController(present: { _ in }, makePlayerView: { FakePlayerView() },
                                  makePlayer: { let player = CountingPlayer(); created(player); return player },
                                  activationPolicy: ActivationPolicyControl(current: { .regular }, set: { _ in }),
                                  frameAutosaveName: nil, defaults: PlayerTestDefaults.throwaway(),
                                  toggleFullScreen: { _ in },
                                  // A silent publisher: the real one registers process-wide remote commands
                                  // that `RecordingNowPlayingTests.theSystemPublisherLoadsAndClears` counts.
                                  nowPlaying: SilentNowPlaying(),
                                  sleepGuard: PlaybackSleepGuard(assertion: fake.assertion))
    }

    private func playing(_ fake: FakeAssertions) async throws -> (RecordingPlayerController, CountingPlayer) {
        var created: CountingPlayer?
        let controller = make(fake) { created = $0 }
        controller.play(try await TestMedia.shared.url(), title: "Lezione", cookies: [])
        let player = try #require(created)
        try await Self.waitUntil { fake.held == 1 && player.timeControlStatus == .playing }
        return (controller, player)
    }

    /// Nothing is held before the player reports `.playing`: an idle controller holds nothing,
    /// and right after Play the item is not ready, so the assertion arrives with the status
    /// report, not with the request. Mutation: begin the assertion inside `play`.
    @Test func nothingIsHeldBeforeThePlayerReportsPlaying() async throws {
        let fake = FakeAssertions()
        let controller = make(fake)
        #expect(fake.begins == 0, "an idle controller holds nothing")
        controller.play(try await TestMedia.shared.url(), title: "Lezione", cookies: [])
        #expect(fake.held == 0)
        controller.close()
        #expect(fake.held == 0)
    }

    /// A lecture that plays holds exactly one assertion; a repeat of the same status adds none.
    /// Guards against the whole feature being absent. Mutation: remove the `update` call in
    /// `timeControlStatusChanged`.
    @Test func playingHoldsOneAssertion() async throws {
        let fake = FakeAssertions()
        let (controller, player) = try await playing(fake)
        player.report(.playing)
        await Self.settle()
        #expect(fake.held == 1 && fake.begins == 1)
        player.report(nil)
        controller.close()
    }

    /// Pausing releases it, and playing again takes it again. Guards against a paused lecture
    /// (the student went for a coffee) pinning the display on. Mutation: pass `true` when paused.
    @Test func pausingReleasesIt() async throws {
        let fake = FakeAssertions()
        let (controller, player) = try await playing(fake)
        controller.pause()
        try await Self.waitUntil { fake.held == 0 }
        #expect(fake.held == 0)
        player.play()
        try await Self.waitUntil { fake.held == 1 }
        #expect(fake.begins == 2 && fake.ends == 1)
        controller.close()
    }

    /// A stall (waiting for data) releases it, and it comes back when playback resumes: a
    /// buffering stream is not being watched. Guards against `!= .paused` being used instead of
    /// `== .playing`. Mutation: use `!= .paused` in the `update` call of `timeControlStatusChanged`.
    @Test func aStallReleasesItAndRecoveryTakesItAgain() async throws {
        let fake = FakeAssertions()
        let (controller, player) = try await playing(fake)
        player.report(.waitingToPlayAtSpecifiedRate)
        await Self.settle()
        #expect(fake.held == 0)
        player.report(.playing)
        await Self.settle()
        #expect(fake.held == 1)
        player.report(nil)
        controller.close()
    }

    /// `close()` releases it before returning, so nothing can outlive the player even if no
    /// status report follows. Mutation: remove the `update` call in `removeItemObservers`.
    @Test func closeReleasesItSynchronously() async throws {
        let fake = FakeAssertions()
        let (controller, _) = try await playing(fake)
        controller.close()
        #expect(fake.held == 0)
        await Self.settle()
        #expect(fake.held == 0, "a late report after close takes nothing")
    }

    /// The window's close button (a different path from `close()`) releases it as well.
    /// Mutation: release only in `close()`.
    @Test func closingTheWindowReleasesIt() async throws {
        let fake = FakeAssertions()
        let (controller, _) = try await playing(fake)
        controller.window?.close()
        #expect(fake.held == 0)
        await Self.settle()
        #expect(fake.held == 0)
    }

    /// Replacing the lecture while it plays releases at once; with a resume position the new
    /// item is held paused until its seek lands, so the assertion returns only when the new
    /// lecture plays. Guards against holding it across the paused stretch of a resume.
    /// Mutation: remove the `update` call in `removeItemObservers` (the assertion survives the
    /// replacement).
    @Test func replacementReleasesAndReturnsOnlyWhenTheNewItemPlays() async throws {
        let fake = FakeAssertions()
        let (controller, _) = try await playing(fake)
        controller.play(try await TestMedia.shared.url(), title: "Lezione 2", cookies: [], startAt: 20)
        #expect(fake.held == 0, "the resume holds the player paused")
        try await Self.waitUntil { fake.held == 1 && controller.isStartSettled }
        #expect(fake.begins == 2 && fake.ends == 1)
        controller.close()
        #expect(fake.held == 0)
    }

    /// Replacing without a resume position, while playing, keeps playing: no status report is
    /// guaranteed, so `play` itself must take the assertion again. Mutation: remove the `update`
    /// call at the end of `play`.
    @Test func replacementOfAPlayingLectureKeepsItHeld() async throws {
        let fake = FakeAssertions()
        let (controller, player) = try await playing(fake)
        // Pinned at playing, as a player that moves on across the replacement reports it.
        player.report(.playing)
        let media = try await TestMedia.shared.url()
        controller.play(media, title: "Lezione 2", cookies: [])
        #expect(fake.held == 1, "taken again inside play, with no status report needed")
        await Self.settle()
        #expect(fake.held == 1)
        player.report(nil)
        controller.close()
        #expect(fake.held == 0)
    }

    /// A failure mid-lecture pauses the player and keeps the window: the assertion goes at once,
    /// not when the pause's report lands. Mutation: remove the `update` in `fail`.
    @Test func aFailureMidLectureReleasesItImmediately() async throws {
        let fake = FakeAssertions()
        let (controller, player) = try await playing(fake)
        try await Self.waitUntil { controller.isStartSettled }
        // Hold the status at playing so only `fail` itself can release the assertion.
        player.report(.playing)
        controller.fail(generation: controller.generation, error: nil)
        #expect(fake.held == 0)
        player.report(nil)
        controller.close()
    }

    /// A failure before the item was ready closes the player (the browser takes over) and holds
    /// nothing. Guards against a failed load leaving the display pinned.
    @Test func aFailureBeforeReadyHoldsNothing() async throws {
        let fake = FakeAssertions()
        let controller = make(fake)
        controller.play(TestMedia.missing, title: "Mancante", cookies: [])
        controller.fail(generation: controller.generation, error: nil)
        #expect(fake.held == 0)
        await Self.settle()
        #expect(fake.held == 0 && !controller.isOpen)
    }

    /// Ten play/close cycles leak no assertion. Mutation: skip the release in `removeItemObservers`.
    @Test func tenPlayCloseCyclesLeakNothing() async throws {
        let fake = FakeAssertions()
        for _ in 0..<10 {
            let (controller, _) = try await playing(fake)
            controller.close()
            #expect(fake.held == 0)
        }
        #expect(fake.begins == fake.ends)
    }

    /// The assertion never outlives the controller: released while playing and never closed, it
    /// ends through the guard's `deinit`. Mutation: remove `deinit` from `PlaybackSleepGuard`.
    @Test func releasingTheControllerWhilePlayingEndsIt() async throws {
        let fake = FakeAssertions()
        var player: CountingPlayer?
        weak var weakController: RecordingPlayerController?
        do {
            let controller = make(fake) { player = $0 }
            weakController = controller
            controller.play(try await TestMedia.shared.url(), title: "Lezione", cookies: [])
            try await Self.waitUntil { fake.held == 1 }
            controller.window?.delegate = nil
        }
        try await Self.waitUntil { weakController == nil }
        #expect(weakController == nil)
        #expect(fake.held == 0)
        player?.pause()
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
