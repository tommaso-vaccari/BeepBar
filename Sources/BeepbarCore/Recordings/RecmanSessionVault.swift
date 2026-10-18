import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

/// The one place that reads, writes and deletes the Polimi session file at run time (issue #97).
///
/// The file holds sign-on cookies, so two things must hold whatever the UI does:
/// - **Nothing of it runs on the main actor.** Every operation (read, decode, encode, write,
///   delete) runs on a private serial queue; the controller only awaits the returned `Task`. A slow
///   disk makes a spinner last longer, never the menu or the window freeze.
/// - **A late write never brings a deleted session back.** `discard()` bumps an *epoch*
///   synchronously and enqueues the delete. A save carries the epoch its cycle started in and the
///   vault compares it with the current one right before writing: a save whose cycle began before
///   a turn-off, a logout or an account change is refused at commit time, inside the store. This
///   is what a guard in the controller cannot promise: between its check and the write it has
///   awaited WebKit for the cookies, and the account may have changed in between.
///
/// Operations run strictly in the order they were enqueued, one at a time (a chain of tasks, each
/// waiting for its predecessor), so "save, then discard" ends with no file and "discard, then
/// save in the new epoch" ends with the new session. The enqueue itself is synchronous, under a
/// lock: the order is the order of the calls, not of when their tasks happen to start. Do not
/// replace the chain with an actor: actors do not promise FIFO, and the delete running before an
/// older save is exactly the ordering the epoch check exists to survive, not to rely on.
///
/// The vault remembers what the file holds (owner, a fingerprint of the cookies and the confirmed
/// Polimi email) so that a session identical to the saved one is not written again: a visit with
/// nothing new writes nothing. The record is seeded by a load and refreshed by a save; a delete
/// forgets it. The email is part of it (#148): a save that left it out would write a file without
/// the email the user confirmed, and a save that only changed the email must not be skipped as
/// "same cookies".
///
/// Storage is three closures so the app passes its 0700/0600 atomic-rename primitives and the
/// Core tests an in-memory box; the vault never decides *how* bytes reach the disk, only *when*.
public final class RecmanSessionVault: Sendable {
    public struct Storage: Sendable {
        /// The saved bytes, or nil when there is no file. Throws when the file exists but can't be read.
        public var load: @Sendable () throws -> Data?
        /// Replaces the file atomically, private from the first byte.
        public var save: @Sendable (Data) throws -> Void
        /// Removes the file and anything a crash mid-save left; no file is not an error.
        public var delete: @Sendable () throws -> Void
        public var expirationDate: @Sendable () throws -> Date?

        public init(load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void, delete: @escaping @Sendable () throws -> Void, expirationDate: @escaping @Sendable () throws -> Date? = { nil }) {
            self.load = load
            self.save = save
            self.delete = delete
            self.expirationDate = expirationDate
        }
    }

    public enum LoadOutcome: Sendable {
        /// No file: the user has never signed in, or the session was discarded.
        case none
        /// A readable session. Whether its owner is the current account is the caller's decision.
        case session(RecmanSessionCodec.Snapshot)
        /// Damaged, or written by a newer BeepBar: the caller should `discard()` it and ask for a sign-in.
        case undecodable
        /// The file exists but can't be read right now (a disk error): kept for the next try.
        case unreadable
    }

    public enum SaveOutcome: Sendable, Equatable {
        case saved
        /// The file already holds these cookies for this owner: nothing written.
        case unchanged
        /// `discard()` ran after this save's cycle began: nothing written, the session stays gone.
        case stale
        case failed(String)
    }

    public enum DeleteOutcome: Sendable, Equatable {
        case deleted
        case failed(String)
        /// `retryDiscard()` only: a save in the current epoch wrote the file since the last
        /// `discard()` (or this launch), so it holds a new session, not the obsolete one.
        case kept
    }

    private struct Saved: Equatable {
        var owner: Int
        var fingerprint: [String]
        var email: String?
    }

    private struct State {
        /// The last operation enqueued; the next one waits for it. Nil until the first operation.
        var tail: Task<Void, Never>?
        /// Bumped by `discard()`. A save from an older epoch is refused at commit time.
        var epoch = 0
        /// What the file holds, when this process knows it (after a load or a save); a delete forgets it.
        var saved: Saved?
        /// A `save` wrote the file after the last `discard()` call (or since launch). Every such
        /// write passed the epoch check, so it is a session of the current epoch: the one thing
        /// `retryDiscard()` must never delete (#200). Reset by `discard()` under the same lock
        /// that bumps the epoch, so a save enqueued before the discard can't set it afterwards
        /// (it is refused as stale and writes nothing).
        var currentEpochWritten = false
    }

    private let storage: Storage
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Where the blocking file work runs. Not the cooperative pool: Swift's pool has one thread per
    /// core and assumes none of them blocks, so a slow disk parked there takes a thread the rest of
    /// the process (or, in tests, the code that would unblock it) needs. Held test disks once
    /// deadlocked the 3-core CI runner this way. The chain below still decides the order.
    private let queue = DispatchQueue(label: "io.github.tvaccari.beepbar.recman-session")

    public init(storage: Storage) {
        self.storage = storage
    }

    /// The epoch a save cycle must capture *before* awaiting anything (the browser's cookies), and
    /// pass to `save`. A `discard()` in between makes that save stale.
    public var epoch: Int { state.withLock { $0.epoch } }

    public func expirationDate() -> Task<Date?, Never> {
        enqueue { [storage] in try? storage.expirationDate() }
    }

    /// Reads and decodes the file off the caller's executor. Expired cookies are dropped as of `now`.
    public func load(now: Date) -> Task<LoadOutcome, Never> {
        enqueue { [storage, state] in
            let data: Data?
            do { data = try storage.load() } catch { return .unreadable }
            guard let data else { return .none }
            guard let snapshot = try? RecmanSessionCodec.decode(data, now: now) else { return .undecodable }
            state.withLock { $0.saved = Saved(owner: snapshot.ownerUserID, fingerprint: RecmanSessionCodec.fingerprint(snapshot.cookies), email: snapshot.email) }
            return .session(snapshot)
        }
    }

    /// Writes the session unless it is unchanged, or `epoch` is older than the current one.
    ///
    /// `epoch` is `self.epoch` read when the save cycle began, before any `await`; see `discard()`.
    /// The epoch is checked once, right before the write, under the lock: that is the check that
    /// matters, and keeping it the only one keeps it covered by tests. A stale save whose cookies
    /// equal what the file still holds reports `.unchanged`; either way nothing is written.
    ///
    /// `email` is the confirmed Polimi address to keep in the file (nil: none). It has no default
    /// on purpose: every save states what the file should say, so a caller that forgets the email
    /// doesn't silently erase the one the user confirmed.
    ///
    /// `keepingFileEmail` is for a caller that never managed to read the file (a disk error at
    /// load) and so does not know what email it holds: the save then keeps the email the file has
    /// for this owner, read here, and `email` is ignored. A file that can't be read now, or
    /// belongs to another owner, counts as having none.
    public func save(_ cookies: [HTTPCookie], ownerUserID: Int, email: String?, keepingFileEmail: Bool = false, epoch: Int, now: Date) -> Task<SaveOutcome, Never> {
        enqueue { [storage, state] in
            var email = email
            if keepingFileEmail {
                email = nil
                if let data = try? storage.load(), let snapshot = try? RecmanSessionCodec.decode(data, now: now), snapshot.ownerUserID == ownerUserID {
                    email = snapshot.email
                }
            }
            let kept = cookies.filter { RecmanSessionCodec.keeps($0, now: now) }
            let candidate = Saved(owner: ownerUserID, fingerprint: RecmanSessionCodec.fingerprint(kept), email: email)
            if state.withLock({ $0.saved == candidate }) { return .unchanged }
            let data: Data
            do { data = try RecmanSessionCodec.encode(kept, ownerUserID: ownerUserID, email: email, now: now) } catch { return .failed(String(reflecting: type(of: error))) }
            // Commit-time check: a discard that ran while this save waited in the chain, or while
            // the controller awaited the browser, must win. Nothing is written for a stale epoch.
            guard state.withLock({ $0.epoch == epoch }) else { return .stale }
            do { try storage.save(data) } catch { return .failed(String(reflecting: type(of: error))) }
            state.withLock { $0.saved = candidate; $0.currentEpochWritten = true }
            return .saved
        }
    }

    /// Changes only the confirmed email of the saved session, keeping its cookies, for an edit
    /// made while no browser is open (the Settings field). Reads the file in turn, so it sees
    /// whatever was enqueued before it.
    ///
    /// Nothing is written, and the outcome is `.unchanged`, when there is no readable session
    /// (the caller keeps the email in memory and the next full `save` writes it), when the file
    /// belongs to another owner than `ownerUserID`, or when it already holds `email`. A discard
    /// since `epoch` makes it `.stale`, like `save`: the commit-time check is the same one.
    public func updateEmail(_ email: String?, ownerUserID: Int, epoch: Int, now: Date) -> Task<SaveOutcome, Never> {
        enqueue { [storage, state] in
            let data: Data?
            do { data = try storage.load() } catch { return .failed(String(reflecting: type(of: error))) }
            guard let data, let snapshot = try? RecmanSessionCodec.decode(data, now: now),
                  snapshot.ownerUserID == ownerUserID, snapshot.email != email else { return .unchanged }
            let kept = snapshot.cookies.filter { RecmanSessionCodec.keeps($0, now: now) }
            let rewritten: Data
            do { rewritten = try RecmanSessionCodec.encode(kept, ownerUserID: ownerUserID, email: email, now: now) } catch { return .failed(String(reflecting: type(of: error))) }
            guard state.withLock({ $0.epoch == epoch }) else { return .stale }
            do { try storage.save(rewritten) } catch { return .failed(String(reflecting: type(of: error))) }
            state.withLock { $0.saved = Saved(owner: ownerUserID, fingerprint: RecmanSessionCodec.fingerprint(kept), email: email) }
            return .saved
        }
    }

    /// Turn-off, logout, account change, damaged file: bumps the epoch *now*, synchronously, then
    /// deletes the file in turn. Everything enqueued before this call still runs first, and every
    /// save that began before it is stale from this moment, whether it is already in the chain or
    /// still waiting for WebKit. The bump and the enqueue happen under one lock so no save can
    /// slip between them.
    ///
    /// What the file holds is forgotten by the delete itself, when it runs, not here: a load or a
    /// save enqueued before this call still runs first and records the file it read or wrote. Were
    /// that record to survive the delete, an identical save in the new epoch would be skipped as
    /// unchanged and the session lost. Clearing it in the delete step covers every such case
    /// (it also runs when the delete fails: the file's state is then unknown, so the next save
    /// writes); only operations enqueued after this one can describe the file again.
    @discardableResult public func discard() -> Task<DeleteOutcome, Never> {
        state.withLock { state in
            state.epoch += 1
            state.currentEpochWritten = false
            return enqueue(into: &state) { [storage, lock = self.state] in
                defer { lock.withLock { $0.saved = nil } }
                do { try storage.delete() } catch { return .failed(String(reflecting: type(of: error))) }
                return .deleted
            }
        }
    }

    /// Deletes the file again after a `discard()` whose delete failed or never ran (the process
    /// ended first), for the caller that persisted the intent to discard (#200). Unlike
    /// `discard()` it does not bump the epoch: a save cycle that started since belongs to a new,
    /// legitimate session and must still be written. For the same reason it deletes nothing
    /// (`.kept`) when a save has written the file since the last `discard()` or since launch;
    /// checked when it runs, in turn, so a save enqueued before it is accounted for. A failed
    /// delete forgets what the file holds, as in `discard()`.
    @discardableResult public func retryDiscard() -> Task<DeleteOutcome, Never> {
        enqueue { [storage, state] in
            if state.withLock({ $0.currentEpochWritten }) { return .kept }
            defer { state.withLock { $0.saved = nil } }
            do { try storage.delete() } catch { return .failed(String(reflecting: type(of: error))) }
            return .deleted
        }
    }

    /// Waits for every operation enqueued so far. For tests, and for callers that must know the
    /// file reflects their last call before reading it from outside the vault.
    public func settle() async {
        await enqueue { }.value
    }

    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () -> T) -> Task<T, Never> {
        state.withLock { enqueue(into: &$0, operation) }
    }

    /// FIFO by construction: the new task first awaits the previous tail, then runs `operation`
    /// on `queue` (never the caller's actor, never a cooperative thread) while it stays suspended,
    /// and becomes the tail itself.
    private func enqueue<T: Sendable>(into state: inout State, _ operation: @escaping @Sendable () -> T) -> Task<T, Never> {
        let previous = state.tail
        let task = Task<T, Never>.detached { [queue] in
            if let previous { await previous.value }
            return await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: operation()) }
            }
        }
        state.tail = Task.detached { _ = await task.value }
        return task
    }
}
