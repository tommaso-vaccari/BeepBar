import Foundation

/// A Politecnico di Milano mailbox (`name.surname@mail.polimi.it` or `…@polimi.it`), normalized.
///
/// Native recordings playback (#148) has to type the student's Polimi address into Webex's
/// sign-in page. BeepBar takes it from the WeBeep profile and the user confirms it, but the value
/// still comes from the network or from a text field, so this type is the single gate that decides
/// what may ever be sent to Webex: only an address on Polimi's own domains. Anything else, such as
/// a personal address set on the Moodle profile or a lookalike domain (`polimi.it.evil.com`,
/// `xpolimi.it`), is rejected rather than "fixed", so a wrong identity is never submitted.
///
/// Deliberately Foundation-only and free of app types: this folder is compiled on its own by
/// `scripts/recman-probe.sh`. The address is personal data: never log `value`.
public struct PolimiEmail: Sendable, Equatable, Hashable {
    /// The trimmed, lowercased address, e.g. `mario.rossi@mail.polimi.it`.
    public let value: String

    /// The only domains Webex's Polimi sign-on accepts. Compared for exact equality after
    /// lowercasing, never with a suffix match, which would accept `xpolimi.it`.
    static let allowedDomains: Set<String> = ["mail.polimi.it", "polimi.it"]

    /// RFC 5321 limits: 254 characters for a usable address, 64 for the local part.
    static let maximumLength = 254
    static let maximumLocalPartLength = 64

    /// Mailbox characters accepted in the local part. ASCII only on purpose: a Unicode lookalike
    /// letter would pass `CharacterSet.letters` yet name a different mailbox.
    private static let localPartScalars: Set<Unicode.Scalar> = {
        var scalars = Set<Unicode.Scalar>()
        for range in [("a", "z"), ("0", "9")] {
            for value in Unicode.Scalar(range.0)!.value...Unicode.Scalar(range.1)!.value {
                scalars.insert(Unicode.Scalar(value)!)
            }
        }
        for symbol in "._-+".unicodeScalars { scalars.insert(symbol) }
        return scalars
    }()

    /// Normalizes `raw` (surrounding whitespace and newlines removed, lowercased) and returns nil
    /// unless it is a plausible Polimi mailbox: exactly one `@`, a non-empty local part of
    /// letters, digits, `.`, `_`, `-`, `+` without leading, trailing or consecutive dots, and a
    /// domain that is exactly `mail.polimi.it` or `polimi.it`. Inner whitespace, control
    /// characters and over-long input are rejected, not repaired.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // ASCII is checked before lowercasing: Unicode case mapping turns some non-ASCII
        // characters into ASCII ones (KELVIN SIGN U+212A becomes "k"), which would let a
        // lookalike address normalize into a different, valid-looking mailbox.
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumLength,
              trimmed.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let normalized = trimmed.lowercased()
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let local = parts[0]
        let domain = String(parts[1])
        guard Self.allowedDomains.contains(domain),
              !local.isEmpty, local.utf8.count <= Self.maximumLocalPartLength,
              local.unicodeScalars.allSatisfy(Self.localPartScalars.contains),
              local.first != ".", local.last != ".", !local.contains("..") else { return nil }
        value = normalized
    }
}
