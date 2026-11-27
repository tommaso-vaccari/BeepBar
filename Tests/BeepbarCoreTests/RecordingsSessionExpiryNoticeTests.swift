import Foundation
import Testing
@testable import BeepbarCore

/// The "Polimi sign-in expired" notification rules (#295). Pure: the app persists the record and
/// sends the notification; these tests prove WHEN it fires and how the record moves.
struct RecordingsSessionExpiryNoticeTests {
    private typealias Notice = RecordingsSessionExpiryNotice
    private let armed = Notice.Record(owner: 7, phase: .armed)

    /// Proves both ways a follow-up meets an expired session (the refresh ending midway, and the
    /// skip because access already says "sign in") are expiries, and nothing else is. Guards
    /// against missing the common case (every sync after the first skips) or notifying on an
    /// outage, a cancellation or an unrelated skip.
    @Test func onlyTheTwoExpiredEndingsAreExpiries() {
        #expect(Notice.isExpiry(.needsSignIn(newlyPublished: 0)))
        #expect(Notice.isExpiry(.needsSignIn(newlyPublished: 3)))
        #expect(Notice.isExpiry(.skipped(.needsSignIn)))
        for other: RecordingsSyncOutcome in [.refreshed(newlyPublished: 2, failedKeys: 1), .unavailable(newlyPublished: 0), .cancelled,
                                             .skipped(.signingIn), .skipped(.switchedOff), .skipped(.noCourses), .skipped(.authenticationExpired)] {
            #expect(!Notice.isExpiry(other))
        }
    }

    /// Proves an armed account is notified for an expiry met during a sync, by either ending.
    @Test func anExpiryOnAnArmedAccountNotifies() {
        #expect(Notice.shouldNotify(for: .needsSignIn(newlyPublished: 0), record: armed, owner: 7, notificationsEnabled: true))
        #expect(Notice.shouldNotify(for: .skipped(.needsSignIn), record: armed, owner: 7, notificationsEnabled: true))
    }

    /// Proves once per expiry: after the notification, later syncs that still meet the expiry are
    /// silent. Mutation: `afterNotified` returning the record unchanged makes this fail.
    @Test func theSecondSyncWhileStillExpiredIsSilent() throws {
        let spent = try #require(Notice.afterNotified(armed, owner: 7))
        #expect(spent.phase == .spent)
        #expect(!Notice.shouldNotify(for: .skipped(.needsSignIn), record: spent, owner: 7, notificationsEnabled: true))
        #expect(!Notice.shouldNotify(for: .needsSignIn(newlyPublished: 0), record: spent, owner: 7, notificationsEnabled: true))
    }

    /// Proves nobody who never had a working session is notified: no record (never signed in, or
    /// updated while already expired) and a record of another account are both silent.
    @Test func withoutAnArmedRecordForThisAccountItStaysSilent() {
        #expect(!Notice.shouldNotify(for: .skipped(.needsSignIn), record: nil, owner: 7, notificationsEnabled: true))
        #expect(!Notice.shouldNotify(for: .skipped(.needsSignIn), record: armed, owner: 8, notificationsEnabled: true))
        #expect(!Notice.shouldNotify(for: .skipped(.needsSignIn), record: armed, owner: nil, notificationsEnabled: true))
    }

    /// Proves the "Notifiche" switch off silences it.
    @Test func notificationsOffIsSilent() {
        #expect(!Notice.shouldNotify(for: .needsSignIn(newlyPublished: 0), record: armed, owner: 7, notificationsEnabled: false))
    }

    /// Proves the other endings never notify even for an armed account.
    @Test func otherEndingsAreSilent() {
        for outcome: RecordingsSyncOutcome in [.refreshed(newlyPublished: 4, failedKeys: 0), .unavailable(newlyPublished: 1), .cancelled, .skipped(.signingIn), .skipped(.materialsCancelled)] {
            #expect(!Notice.shouldNotify(for: outcome, record: armed, owner: 7, notificationsEnabled: true))
        }
    }

    /// Proves a successful sign-in re-arms, so the next expiry is notified again (spent or absent before).
    @Test func aSignInReArms() throws {
        let spent = try #require(Notice.afterNotified(armed, owner: 7))
        let again = Notice.afterSignIn(owner: 7)
        #expect(again == armed)
        #expect(Notice.shouldNotify(for: .skipped(.needsSignIn), record: again, owner: 7, notificationsEnabled: true))
        #expect(spent != again)
    }

    /// Proves a student-started sign-in during the expiry spends it (they know), also if they then
    /// give up, and leaves an unarmed account unarmed. Mutation: returning the record unchanged
    /// makes the first expectation fail.
    @Test func aUserStartedSignInSpendsTheExpiry() {
        #expect(Notice.afterUserStartedSignIn(armed, owner: 7)?.phase == .spent)
        #expect(Notice.afterUserStartedSignIn(nil, owner: 7) == nil)
        #expect(Notice.afterUserStartedSignIn(armed, owner: 8) == armed)
    }

    /// Proves finding a live saved session arms an account with no record (the first launch after
    /// updating while signed in), keeps a spent record spent and replaces another account's.
    @Test func aSessionFoundAliveArmsOnlyWhenThereIsNoRecordForTheAccount() {
        #expect(Notice.afterSessionFound(nil, owner: 7) == armed)
        #expect(Notice.afterSessionFound(Notice.Record(owner: 7, phase: .spent), owner: 7).phase == .spent)
        #expect(Notice.afterSessionFound(Notice.Record(owner: 3, phase: .spent), owner: 7) == armed)
    }

    /// Proves the record round-trips through JSON (what UserDefaults stores) and the text carries no
    /// course or lecture name, only a fixed message in both languages.
    @Test func recordRoundTripsAndTextIsFixed() throws {
        let data = try JSONEncoder().encode(armed)
        #expect(try JSONDecoder().decode(Notice.Record.self, from: data) == armed)
        let text = Notice.text()
        #expect(text.title.italian == "Accesso al Politecnico scaduto")
        #expect(text.title.english == "Polimi sign-in expired")
        #expect(!text.body.english.isEmpty && !text.body.italian.isEmpty)
    }
}
