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
///   delete) is handed to a detached task; the controller only awaits the returned `Task`. A slow
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
/// The vault remembers what the file holds (owner and a fingerprint of the cookies) so that a
/// session identical to the saved one is not written again: a visit with nothing new writes
/// nothing. The fingerprint is seeded by a load and refreshed by a save; a delete forgets it.
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

        public init(load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void, delete: @escaping @Sendable () throws -> Void) {
            self.load = load
            self.save = save
            self.delete = delete
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
    }

    private struct Saved: Equatable {
        var owner: Int
        var fingerprint: [String]
    }

    private struct State {
        /// The last operation enqueued; the next one waits for it. Nil once the chain ran dry.
        var tail: Task<Void, Never>?
        /// Bumped by `discard()`. A save from an older epoch is refused at commit time.
        var epoch = 0
        /// What the file holds, when this process knows it (after a load or a save).
        var saved: Saved?
    }

    private let storage: Storage
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(storage: Storage) {
        self.storage = storage
    }

    /// The epoch a save cycle must capture *before* awaiting anything (the browser's cookies), and
    /// pass to `save`. A `discard()` in between makes that save stale.
    public var epoch: Int { state.withLock { $0.epoch } }

    /// Reads and decodes the file off the caller's executor. Expired cookies are dropped as of `now`.
    public func load(now: Date) -> Task<LoadOutcome, Never> {
        enqueue { [storage, state] in
            let data: Data?
            do { data = try storage.load() } catch { return .unreadable }
            guard let data else { return .none }
            guard let snapshot = try? RecmanSessionCodec.decode(data, now: now) else { return .undecodable }
            state.withLock { $0.saved = Saved(owner: snapshot.ownerUserID, fingerprint: RecmanSessionCodec.fingerprint(snapshot.cookies)) }
            return .session(snapshot)
        }
    }

    /// Writes the session unless it is unchanged, or `epoch` is older than the current one.
    ///
    /// `epoch` is `self.epoch` read when the save cycle began, before any `await`; see `discard()`.
    /// The check against the current epoch happens twice: once before encoding, to spare the work,
    /// and once right before the write, which is the one that matters. Keep the second one.
    public func save(_ cookies: [HTTPCookie], ownerUserID: Int, epoch: Int, now: Date) -> Task<SaveOutcome, Never> {
        enqueue { [storage, state] in
            let kept = cookies.filter { RecmanSessionCodec.keeps($0, now: now) }
            let candidate = Saved(owner: ownerUserID, fingerprint: RecmanSessionCodec.fingerprint(kept))
            switch state.withLock({ state -> SaveOutcome? in
                if state.epoch != epoch { return .stale }
                if state.saved == candidate { return .unchanged }
                return nil
            }) {
            case let outcome?: return outcome
            case nil: break
            }
            let data: Data
            do { data = try RecmanSessionCodec.encode(kept, ownerUserID: ownerUserID, now: now) } catch { return .failed(String(reflecting: type(of: error))) }
            // Commit-time check: a discard that ran while this save waited in the chain, or while
            // the controller awaited the browser, must win. Nothing is written for a stale epoch.
            guard state.withLock({ $0.epoch == epoch }) else { return .stale }
            do { try storage.save(data) } catch { return .failed(String(reflecting: type(of: error))) }
            state.withLock { $0.saved = candidate }
            return .saved
        }
    }

    /// Turn-off, logout, account change, damaged file: bumps the epoch *now*, synchronously, then
    /// deletes the file in turn. Everything enqueued before this call still runs first, and every
    /// save that began before it is stale from this moment, whether it is already in the chain or
    /// still waiting for WebKit. The bump and the enqueue happen under one lock so no save can
    /// slip between them.
    @discardableResult public func discard() -> Task<DeleteOutcome, Never> {
        state.withLock { state in
            state.epoch += 1
            state.saved = nil
            return enqueue(into: &state) { [storage] in
                do { try storage.delete() } catch { return .failed(String(reflecting: type(of: error))) }
                return .deleted
            }
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
    /// on a detached task (never the caller's actor), and becomes the tail itself.
    private func enqueue<T: Sendable>(into state: inout State, _ operation: @escaping @Sendable () -> T) -> Task<T, Never> {
        let previous = state.tail
        let task = Task<T, Never>.detached {
            if let previous { await previous.value }
            return operation()
        }
        state.tail = Task.detached { _ = await task.value }
        return task
    }
}
