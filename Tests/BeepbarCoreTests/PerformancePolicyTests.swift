import Testing
@testable import BeepbarCore

struct PerformancePolicyTests {
    /// A dropped clear is retried after the interval; an unchanged accepted snapshot stays quiet.
    @Test func throttleRetriesClearAndRejectsDuplicates() {
        let now = ContinuousClock.now
        var throttle = SyncProgressThrottle(minimumInterval: .milliseconds(200))
        let active = SyncProgress(completed: 0, total: 2, added: 0, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0, transfer: SyncTransferProgress(received: 20, total: 100))
        let cleared = SyncProgress(completed: 0, total: 2, added: 0, updated: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        #expect(throttle.accept(active, now: now) != nil)
        #expect(throttle.accept(cleared, now: now + .milliseconds(100)) == nil)
        #expect(throttle.accept(cleared, now: now + .milliseconds(201)) != nil)
        #expect(throttle.accept(cleared, now: now + .seconds(1)) == nil)
    }

    @Test func progressThrottleLimitsIntermediateUpdatesAndAlwaysDeliversFinal() {
        let clock = ContinuousClock()
        let start = clock.now
        var throttle = SyncProgressThrottle(minimumInterval: .milliseconds(200))

        var publications = 0
        for completed in 0..<10_000 {
            let progress = SyncProgress(completed: completed, total: 10_000, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
            if throttle.accept(progress, now: start) != nil { publications += 1 }
        }
        #expect(publications == 1)

        throttle.reset()
        let first = SyncProgress(completed: 0, total: 10_000, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        #expect(throttle.accept(first, now: start) == first)
        let second = SyncProgress(completed: 1, total: 10_000, installed: 1, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        #expect(throttle.accept(second, now: start.advanced(by: .milliseconds(199))) == nil)
        #expect(throttle.accept(second, now: start.advanced(by: .milliseconds(200))) == second)

        let final = SyncProgress(completed: 10_000, total: 10_000, installed: 10_000, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0)
        #expect(throttle.accept(final, now: start.advanced(by: .milliseconds(201))) == final)
    }

    @Test func progressThrottleRejectsRegressionsAndResets() {
        let clock = ContinuousClock()
        let now = clock.now
        var throttle = SyncProgressThrottle(minimumInterval: .zero)
        #expect(throttle.accept(SyncProgress(completed: 4, total: 10, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0), now: now) != nil)
        #expect(throttle.accept(SyncProgress(completed: 3, total: 10, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0), now: now) == nil)
        throttle.reset()
        #expect(throttle.accept(SyncProgress(completed: 0, total: 10, installed: 0, preservedLocal: 0, unchanged: 0, conflicts: 0, failures: 0), now: now) != nil)
    }

    @Test func automaticSchedulingRequiresEveryPrerequisite() {
        let valid = BackgroundScheduleInput(automaticSyncEnabled: true, hasCredential: true, hasRoot: true, enabledCourseCount: 1, recoveryBlocked: false)
        #expect(BackgroundSchedulePolicy.shouldSchedule(valid))
        #expect(!BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: false, hasCredential: true, hasRoot: true, enabledCourseCount: 1, recoveryBlocked: false)))
        #expect(!BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: true, hasCredential: false, hasRoot: true, enabledCourseCount: 1, recoveryBlocked: false)))
        #expect(!BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: true, hasCredential: true, hasRoot: false, enabledCourseCount: 1, recoveryBlocked: false)))
        #expect(!BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: true, hasCredential: true, hasRoot: true, enabledCourseCount: 0, recoveryBlocked: false)))
        #expect(!BackgroundSchedulePolicy.shouldSchedule(.init(automaticSyncEnabled: true, hasCredential: true, hasRoot: true, enabledCourseCount: 1, recoveryBlocked: true)))
    }
}
