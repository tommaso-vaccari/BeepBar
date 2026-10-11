import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
import Testing
@testable import BeepbarCore

/// An in-memory session file whose operations record where they ran and can be held open, so a
/// test can enqueue more work while one operation is in the middle of reading, writing or deleting.
private final class MemoryDisk: Sendable {
    enum Operation: Sendable { case load, save, delete }

    struct State {
        var data: Data?
        var writes = 0
        var deletes = 0
        var mainThreadCalls = 0
        var loadFails = false
        var deleteFails = false
        /// The operation to hold, and whether one is currently held inside it.
        var hold: Operation?
        var held = false
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    var storage: RecmanSessionVault.Storage {
        RecmanSessionVault.Storage(
            load: { [self] in
                try enter(.load)
                return state.withLock { $0.data }
            },
            save: { [self] data in
                try enter(.save)
                state.withLock { $0.data = data; $0.writes += 1 }
            },
            delete: { [self] in
                try enter(.delete)
                state.withLock { $0.data = nil; $0.deletes += 1 }
            }
        )
    }

    /// Records the thread, fails when told to, and parks in a held operation until `release()`.
    /// Parking blocks the vault's file thread, as a slow disk does. It must never be a cooperative
    /// pool thread: the test's own wake-up needs one, and three held tests at once deadlocked the
    /// 3-core CI runner before the vault moved its file work to a queue. The deadline turns any
    /// such regression, or a missing `release()`, into a failure instead of a run that never ends.
    /// It detects hangs, it does not bound timing: on that runner ordinary tests take up to ~33 s
    /// (10 s made held tests fail there), so keep it well above that.
    private func enter(_ operation: Operation) throws {
        let fails = state.withLock { state -> Bool in
            if Thread.isMainThread { state.mainThreadCalls += 1 }
            if state.hold == operation { state.held = true }
            return (operation == .load && state.loadFails) || (operation == .delete && state.deleteFails)
        }
        let deadline = Date().addingTimeInterval(120)
        while state.withLock({ $0.held }) {
            guard Date() < deadline else {
                Issue.record("a held disk operation was never released")
                break
            }
            usleep(500)
        }
        if fails { throw CocoaError(.fileReadUnknown) }
    }

    func hold(_ operation: MemoryDisk.Operation) { state.withLock { $0.hold = operation } }

    /// Waits until a held operation is parked inside the disk.
    func waitUntilHeld() async {
        for _ in 0..<5_000 where !state.withLock({ $0.held }) { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(state.withLock { $0.held }, "the held operation never started")
    }

    func release() { state.withLock { $0.hold = nil; $0.held = false } }

    var data: Data? { state.withLock { $0.data } }
    var writes: Int { state.withLock { $0.writes } }
}

/// `RecmanSessionVault`, the only run-time path to the Polimi session file (issue #97). What it
/// guards: a session written again after logout, turn-off or an account change (a late save must
/// lose to the delete, wherever it was waiting); a session lost because the vault believed the
/// deleted file still held it; files rewritten when nothing changed; and file work on the main
/// thread, where a slow disk freezes the menu and the window.
@MainActor
struct RecmanSessionVaultTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let disk: MemoryDisk
    private let vault: RecmanSessionVault

    init() {
        disk = MemoryDisk()
        vault = RecmanSessionVault(storage: disk.storage)
    }

    nonisolated private func cookies(_ value: String) -> [HTTPCookie] {
        [HTTPCookie(properties: [.name: "SSO_LOGIN", .value: value, .domain: "aunicalogin.polimi.it", .path: "/", .secure: "TRUE"])!]
    }

    private func fileValue() throws -> String? {
        guard let data = disk.data else { return nil }
        return try RecmanSessionCodec.decode(data, now: now).cookies.first?.value
    }

    /// A save whose cycle began before a discard writes nothing, whether the discard came while
    /// the controller was still waiting for WebKit (before the save was enqueued) or while the
    /// save waited behind a slow operation. Without the commit-time check either case would
    /// rewrite the session that logout just deleted.
    @Test(arguments: [false, true])
    func aSaveFromBeforeADiscardIsRefusedAtCommit(queuedBehindSlowLoad: Bool) async throws {
        let epoch = vault.epoch
        let save: Task<RecmanSessionVault.SaveOutcome, Never>
        if queuedBehindSlowLoad {
            disk.hold(.load)
            _ = vault.load(now: now)
            await disk.waitUntilHeld()
            save = vault.save(cookies("late"), ownerUserID: 42, email: nil, epoch: epoch, now: now)
            vault.discard()
            disk.release()
        } else {
            vault.discard()
            save = vault.save(cookies("late"), ownerUserID: 42, email: nil, epoch: epoch, now: now)
        }
        #expect(await save.value == .stale)
        await vault.settle()
        #expect(disk.data == nil)
        #expect(disk.writes == 0)
    }

    /// A save in the epoch that followed the discard is current and is written.
    @Test func aSaveAfterADiscardIsWritten() async throws {
        vault.discard()
        #expect(await vault.save(cookies("new"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileValue() == "new")
    }

    /// "Save, then discard" ends with no file even when the save is still writing as the discard
    /// arrives; "discard, then save" ends with the new session even when the delete is slow. Each
    /// held operation would let a reordered chain run the other one first.
    @Test func operationsRunInTheOrderTheyWereEnqueued() async throws {
        disk.hold(.save)
        let first = vault.save(cookies("a"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now)
        await disk.waitUntilHeld()
        let delete = vault.discard()
        disk.release()
        #expect(await first.value == .saved)
        #expect(await delete.value == .deleted)
        #expect(disk.data == nil, "the delete ran before the save it followed")

        disk.hold(.delete)
        let secondDelete = vault.discard()
        await disk.waitUntilHeld()
        let second = vault.save(cookies("b"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now)
        disk.release()
        #expect(await secondDelete.value == .deleted)
        #expect(await second.value == .saved)
        #expect(try fileValue() == "b", "the save ran before the delete it followed")
    }

    /// A session identical to the one on disk is not written again, whether the vault learned it
    /// from its own save or from loading the file; a changed cookie is written.
    @Test(arguments: [false, true])
    func anUnchangedSessionIsNotRewritten(seededByLoad: Bool) async throws {
        if seededByLoad {
            disk.state.withLock { $0.data = try? RecmanSessionCodec.encode(cookies("same"), ownerUserID: 42, now: now) }
            guard case .session(let snapshot) = await vault.load(now: now).value else {
                Issue.record("the saved session did not load")
                return
            }
            #expect(snapshot.ownerUserID == 42)
        } else {
            #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        }
        let writes = disk.writes
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .unchanged)
        #expect(disk.writes == writes)
        #expect(await vault.save(cookies("same"), ownerUserID: 7, email: nil, epoch: vault.epoch, now: now).value == .saved, "another owner is a different session")
        #expect(await vault.save(cookies("renewed"), ownerUserID: 7, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(disk.writes == writes + 2)
        #expect(try fileValue() == "renewed")
    }

    /// After a discard the vault no longer believes the file holds the old session, however it
    /// learned it: a load or a save enqueued before the discard (one still writing as it arrives),
    /// or a delete that failed. Signing in again with the same cookies must write them; reporting
    /// `.unchanged` would leave the user without a saved session, asked to sign in at every launch.
    @Test(arguments: ["load", "save", "save held while discarding", "failed delete"])
    func aDiscardForgetsTheSessionItRemoves(learnedBy: String) async throws {
        switch learnedBy {
        case "load":
            disk.state.withLock { $0.data = try? RecmanSessionCodec.encode(cookies("same"), ownerUserID: 42, now: now) }
            _ = vault.load(now: now)
            vault.discard()
        case "save held while discarding":
            disk.hold(.save)
            _ = vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now)
            await disk.waitUntilHeld()
            vault.discard()
            disk.release()
        case "failed delete":
            #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
            disk.state.withLock { $0.deleteFails = true }
            #expect(await vault.discard().value != .deleted)
            disk.state.withLock { $0.deleteFails = false; $0.data = nil }
        default:
            #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
            vault.discard()
        }
        await vault.settle()
        #expect(disk.data == nil)
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileValue() == "same")
    }

    /// Each kind of file gets its own answer: nothing saved, a readable session (expired cookies
    /// dropped), a damaged file the caller should discard, and a read error the caller keeps for
    /// the next try.
    @Test func loadTellsTheFileStatesApart() async throws {
        if case .none = await vault.load(now: now).value {} else { Issue.record("no file is not .none") }

        let expired = HTTPCookie(properties: [.name: "OLD", .value: "x", .domain: "aunicalogin.polimi.it", .path: "/", .expires: now.addingTimeInterval(60)])!
        disk.state.withLock { $0.data = try? RecmanSessionCodec.encode(cookies("live") + [expired], ownerUserID: 42, now: now) }
        if case .session(let snapshot) = await vault.load(now: now.addingTimeInterval(120)).value {
            #expect(snapshot.cookies.map(\.name) == ["SSO_LOGIN"])
        } else { Issue.record("a readable session did not load") }

        disk.state.withLock { $0.data = Data("not a session".utf8) }
        if case .undecodable = await vault.load(now: now).value {} else { Issue.record("damaged file is not .undecodable") }

        disk.state.withLock { $0.loadFails = true }
        if case .unreadable = await vault.load(now: now).value {} else { Issue.record("read error is not .unreadable") }
        #expect(disk.data != nil, "a file that can't be read right now must be kept")
    }

    // MARK: The confirmed Polimi email (#148)

    private func fileEmail() throws -> String? {
        guard let data = disk.data else { return nil }
        return try RecmanSessionCodec.decode(data, now: now).email
    }

    /// The email is written with the cookies, and a save whose cookies are unchanged but whose
    /// email changed (or was removed) is still written, while an identical one is not. Guards
    /// against the email being left out of the saved record: every save would then either drop
    /// the confirmed address or skip the write that adds it.
    /// Mutation: remove `email` from the `Saved` candidate in `save` and the second expectation
    /// fails (`.unchanged`, the file has no email).
    @Test func theEmailIsPartOfWhatMakesASessionChanged() async throws {
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == nil)
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: "mario.rossi@mail.polimi.it", epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == "mario.rossi@mail.polimi.it")
        let writes = disk.writes
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: "mario.rossi@mail.polimi.it", epoch: vault.epoch, now: now).value == .unchanged)
        #expect(disk.writes == writes, "nothing new writes nothing")
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == nil, "clearing the email removes it from the file")
    }

    /// A load seeds the record with the file's email: saving the same cookies and the same email
    /// afterwards writes nothing, and saving them without it does write (the user removed it).
    /// Mutation: seed `Saved` in `load` without the email and the first save is written again.
    @Test func aLoadLearnsTheEmailItFound() async throws {
        disk.state.withLock { $0.data = try? RecmanSessionCodec.encode(cookies("same"), ownerUserID: 42, email: "a.b@polimi.it", now: now) }
        guard case .session(let snapshot) = await vault.load(now: now).value else {
            Issue.record("the saved session did not load")
            return
        }
        #expect(snapshot.email == "a.b@polimi.it")
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: "a.b@polimi.it", epoch: vault.epoch, now: now).value == .unchanged)
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == nil)
    }

    /// `updateEmail` rewrites the saved file with the new address and the same cookies and owner,
    /// without a browser, and records what it wrote so the next full save of those cookies and
    /// that email is `.unchanged`.
    /// Mutation: encode `[]` instead of the file's cookies and the cookie check fails.
    @Test func updatingTheEmailKeepsTheCookies() async throws {
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(await vault.updateEmail("a.b@polimi.it", ownerUserID: 42, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == "a.b@polimi.it")
        #expect(try fileValue() == "same")
        let writes = disk.writes
        #expect(await vault.updateEmail("a.b@polimi.it", ownerUserID: 42, epoch: vault.epoch, now: now).value == .unchanged)
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: "a.b@polimi.it", epoch: vault.epoch, now: now).value == .unchanged)
        #expect(disk.writes == writes)
        #expect(await vault.updateEmail(nil, ownerUserID: 42, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == nil)
    }

    /// With no saved session, or one that belongs to another account, nothing is written: the
    /// controller keeps the address in memory and the next full save writes it.
    /// Mutation: drop the owner comparison in `updateEmail` and the second expectation fails.
    @Test func updatingTheEmailWritesNothingWithoutThisAccountsSession() async throws {
        #expect(await vault.updateEmail("a.b@polimi.it", ownerUserID: 42, epoch: vault.epoch, now: now).value == .unchanged)
        #expect(disk.writes == 0)
        #expect(await vault.save(cookies("same"), ownerUserID: 7, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(await vault.updateEmail("a.b@polimi.it", ownerUserID: 42, epoch: vault.epoch, now: now).value == .unchanged)
        #expect(try fileEmail() == nil)
        #expect(disk.writes == 1)
    }

    /// An email edit that began before a discard (logout, turn-off, account change) is refused at
    /// commit time and the session stays gone, even though the file was still there when the edit
    /// read it. Mutation: remove the epoch comparison in `updateEmail` and the file reappears.
    @Test func anEmailUpdateFromBeforeADiscardIsRefused() async throws {
        #expect(await vault.save(cookies("same"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        let epoch = vault.epoch
        disk.hold(.load)
        let update = vault.updateEmail("a.b@polimi.it", ownerUserID: 42, epoch: epoch, now: now)
        await disk.waitUntilHeld()
        vault.discard()
        disk.release()
        #expect(await update.value == .stale)
        await vault.settle()
        #expect(disk.data == nil)
    }

    /// A save by a caller that never managed to read the file keeps the email the file has for
    /// this owner, and carries none over from another owner; without the flag the given email
    /// (here none) wins. Guards against a disk error at launch costing the confirmed address.
    /// Mutation: ignore `keepingFileEmail` and the first expectation fails.
    @Test func aSaveBlindToTheFileKeepsItsEmail() async throws {
        let seeded = try RecmanSessionCodec.encode(cookies("old"), ownerUserID: 42, email: "a.b@polimi.it", now: now)
        disk.state.withLock { $0.data = seeded }
        #expect(await vault.save(cookies("new"), ownerUserID: 42, email: nil, keepingFileEmail: true, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == "a.b@polimi.it")
        #expect(try fileValue() == "new")

        #expect(await vault.save(cookies("other"), ownerUserID: 7, email: "z@polimi.it", keepingFileEmail: true, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == nil, "another owner's email is never carried over")

        disk.state.withLock { $0.data = seeded }
        #expect(await vault.save(cookies("new"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now).value == .saved)
        #expect(try fileEmail() == nil, "without the flag the caller's answer stands")
    }

    /// Every operation, called from the main actor, does its file work elsewhere.
    @Test func fileWorkNeverRunsOnTheMainThread() async {
        _ = vault.load(now: now)
        _ = vault.save(cookies("a"), ownerUserID: 42, email: nil, epoch: vault.epoch, now: now)
        vault.discard()
        await vault.settle()
        #expect(disk.state.withLock { $0.mainThreadCalls } == 0)
        #expect(disk.state.withLock { $0.deletes } == 1)
    }
}
