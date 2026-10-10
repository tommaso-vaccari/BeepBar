#if os(Linux)
import CLinuxCompat
import Foundation
import Glibc

// Linux stand-ins for the Darwin APIs BeepbarCore uses, so the Core test suite can run where no
// Mac is available (see docs/team-workflow.md, "Linux Core checks"). Nothing in this file is
// compiled on macOS: the product keeps calling the real APIs, and these shims carry the same
// names so call sites stay identical and a diff between platforms stays reviewable. Each shim
// states what it does *not* reproduce; a Linux green run proves Core logic, never macOS behavior
// (Finder metadata, APFS timestamps, the trash).

/// `OSAllocatedUnfairLock` from `os`: a mutex guarding one value, with the same `withLock` shape.
/// Not unfair and not allocated in place like the original, which no test depends on.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()

    public init(initialState: State) {
        state = initialState
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}

/// macOS `renameatx_np` flags, mapped onto `renameat2(2)`; see `CLinuxCompat`.
let RENAME_EXCL: Int32 = 1
let RENAME_SWAP: Int32 = 2

/// `renameatx_np` on Linux: only the two flag values `FileStore` uses are supported, exactly as
/// the atomic install and swap paths need them. Any other flag is a programming error.
func renameatx_np(_ fromFD: Int32, _ from: String, _ toFD: Int32, _ to: String, _ flags: UInt32) -> Int32 {
    switch Int32(flags) {
    case RENAME_EXCL: beepbar_renameat_noreplace(fromFD, from, toFD, to)
    case RENAME_SWAP: beepbar_renameat_exchange(fromFD, from, toFD, to)
    default: preconditionFailure("unsupported renameatx_np flags \(flags)")
    }
}

/// Finder's hidden flag has no Linux counterpart: `.beepbar` stays visible, and nothing is set.
let UF_HIDDEN: Int32 = 0x8000
@discardableResult
func fchflags(_ fd: Int32, _ flags: UInt32) -> Int32 { 0 }

/// Darwin names for the `stat` timestamps (`st_mtimespec`); Linux calls them `st_mtim`.
extension stat {
    var st_atimespec: timespec { st_atim }
    var st_mtimespec: timespec { st_mtim }
    var st_ctimespec: timespec { st_ctim }
}
#endif

#if os(Linux)
import FoundationNetworking

/// `URLRequest.allowsExpensiveNetworkAccess` / `allowsConstrainedNetworkAccess` exist only in
/// Apple's Foundation. Here they are carried as two reserved header fields, so the Core tests
/// can still prove that Data Saver reaches every request the sync makes. The headers never
/// leave a test process: this file is not part of the macOS product.
extension URLRequest {
    private static let expensiveHeader = "X-Beepbar-Linux-Allows-Expensive-Network-Access"
    private static let constrainedHeader = "X-Beepbar-Linux-Allows-Constrained-Network-Access"

    private func flag(_ header: String) -> Bool { value(forHTTPHeaderField: header) != "0" }
    private mutating func setFlag(_ header: String, _ value: Bool) { setValue(value ? "1" : "0", forHTTPHeaderField: header) }

    var allowsExpensiveNetworkAccess: Bool {
        get { flag(Self.expensiveHeader) }
        set { setFlag(Self.expensiveHeader, newValue) }
    }

    var allowsConstrainedNetworkAccess: Bool {
        get { flag(Self.constrainedHeader) }
        set { setFlag(Self.constrainedHeader, newValue) }
    }
}
#endif

#if os(Linux)
/// No Objective-C runtime, so no autorelease pools: `FileStore.forEachChunk` keeps its per-chunk
/// pool on macOS (where it bounds peak memory, see there) and simply runs the body here.
func autoreleasepool<R>(invoking body: () throws -> R) rethrows -> R {
    try body()
}
#endif

#if os(Linux)
import Crypto

/// CryptoKit's `SHA256` is `Sendable`; swift-crypto's is a plain value type over the same state.
/// Marked so `FileStore`, an actor, can keep feeding chunks into one hasher as it does on macOS.
extension SHA256: @unchecked @retroactive Sendable {}
#endif
