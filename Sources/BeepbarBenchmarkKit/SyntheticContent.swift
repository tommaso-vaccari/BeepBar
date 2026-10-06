import CryptoKit
import Foundation

/// The bytes of one revision of one synthetic file, produced on demand so that a file of any size
/// never sits in memory: the mock server streams it in chunks and the benchmark measures the app's
/// memory, not its own.
///
/// The content repeats a pseudo-random block of at most 1 MiB, seeded per file and revision. The
/// app has no way to notice the period (it hashes and copies bytes, it never compresses them), and
/// serving a chunk is a copy rather than fresh generation, which keeps the server's own CPU out of
/// the measurements. Every revision has different bytes, so an update really changes the file.
package struct SyntheticContent: Sendable {
    package let size: Int64
    private let block: [UInt8]

    package static let maximumBlockSize = 1 << 20

    package init(seed: UInt64, size: Int64) {
        precondition(size >= 0)
        self.size = size
        let length = Int(min(size, Int64(Self.maximumBlockSize)))
        var block = [UInt8](repeating: 0, count: length)
        block.withUnsafeMutableBytes { raw in
            var offset = 0
            var word: UInt64 = 0
            while offset < length {
                word = Self.mix(seed &+ UInt64(offset >> 3))
                for byte in 0..<8 where offset + byte < length {
                    raw[offset + byte] = UInt8(truncatingIfNeeded: word >> (8 * UInt64(byte)))
                }
                offset += 8
            }
        }
        self.block = block
    }

    /// `count` bytes starting at `offset`, clamped to the end of the file.
    package func bytes(at offset: Int64, count: Int) -> Data {
        guard offset < size, count > 0 else { return Data() }
        let length = Int(min(Int64(count), size - offset))
        var data = Data(capacity: length)
        var position = Int(offset % Int64(block.count))
        var remaining = length
        while remaining > 0 {
            let run = min(remaining, block.count - position)
            data.append(contentsOf: block[position..<(position + run)])
            remaining -= run
            position = 0
        }
        return data
    }

    /// The SHA-256 the app must compute for this content, as lowercase hex, read in chunks.
    package func sha256() -> String {
        var hash = SHA256()
        var offset: Int64 = 0
        while offset < size {
            let chunk = bytes(at: offset, count: Self.maximumBlockSize)
            hash.update(data: chunk)
            offset += Int64(chunk.count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SplitMix64's finalizer: a cheap, well-spread, deterministic 64-bit mix.
    package static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a over UTF-8: unlike `Hasher`, the same in every process, so corpora are reproducible.
    package static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }
}
