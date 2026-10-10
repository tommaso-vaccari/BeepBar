import Foundation

/// A dictionary that keeps at most `capacity` entries, forgetting the least recently written
/// unpinned one when a new key arrives (#100). It holds what the Recordings page may show again
/// (course listings, resolved Webex players) without growing with every course and year visited
/// during a long-running session.
///
/// Pinned keys are never evicted, whatever the capacity: they are the keys the page shows now, so
/// reopening a course stays immediate. If every entry is pinned the cache exceeds its capacity
/// rather than drop something on screen; the bound then is the page's own key set.
///
/// Recency is updated on writes only. Reads are plain lookups so a `@Published` value can be read
/// from `body` without a mutation; a listing is written whenever it loads or its state changes,
/// which is what "recent" means here.
public struct BoundedCache<Key: Hashable, Value> {
    public let capacity: Int
    private var storage: [Key: Value] = [:]
    /// Keys from least to most recently written; the tail is kept longest.
    private var order: [Key] = []
    private var pinned: Set<Key> = []

    /// `capacity` must be at least one.
    public init(capacity: Int) {
        precondition(capacity >= 1, "a cache that keeps nothing is a bug")
        self.capacity = capacity
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var keys: Dictionary<Key, Value>.Keys { storage.keys }
    public var values: Dictionary<Key, Value>.Values { storage.values }
    public var pinnedKeys: Set<Key> { pinned }

    public subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            guard let newValue else {
                storage.removeValue(forKey: key)
                order.removeAll { $0 == key }
                return
            }
            let isNew = storage.updateValue(newValue, forKey: key) == nil
            if !isNew { order.removeAll { $0 == key } }
            order.append(key)
            if isNew { evictIfNeeded() }
        }
    }

    /// Like `Dictionary`'s: `cache[key, default: Value()].field = x` writes through.
    public subscript(key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        get { storage[key] ?? defaultValue() }
        set { self[key] = newValue }
    }

    /// Replaces the set of keys that are never evicted. Keys pinned earlier and not in `keys`
    /// become ordinary entries again; nothing is evicted until the next insertion.
    public mutating func pin(_ keys: Set<Key>) {
        pinned = keys
    }

    /// Forgets every entry; pins stay, since they describe the page, not the data.
    public mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private mutating func evictIfNeeded() {
        guard storage.count > capacity else { return }
        // The oldest unpinned key goes; `order` is short (at most capacity + pinned), so a linear
        // scan is cheaper than a linked structure.
        guard let index = order.firstIndex(where: { !pinned.contains($0) }) else { return }
        storage.removeValue(forKey: order.remove(at: index))
    }
}
