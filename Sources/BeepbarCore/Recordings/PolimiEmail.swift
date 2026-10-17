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
/// `scripts/recman-probe.sh`. The address is personal data: never log `value`. `description`,
/// `debugDescription` and the reflection mirror are redacted so that string interpolation,
/// `print`, `dump` or a debugger summary of the value cannot leak the mailbox name by accident.
public struct PolimiEmail: Sendable, Equatable, Hashable {
    /// The trimmed, lowercased address, e.g. `mario.rossi@mail.polimi.it`.
    public let value: String

    /// The only domains Webex's Polimi sign-on accepts. Compared for exact equality after
    /// lowercasing, never with a suffix match, which would accept `xpolimi.it`.
    static let allowedDomains: Set<String> = ["mail.polimi.it", "polimi.it"]

    /// RFC 5321 limits: 254 characters for a usable address, 64 for the local part.
    static let maximumLength = 254
    static let maximumLocalPartLength = 64

    /// Letters and digits allowed in the local part, and the only characters it may start or end
    /// with. ASCII only on purpose: a Unicode lookalike letter would pass `CharacterSet.letters`
    /// yet name a different mailbox.
    private static let alphanumericScalars: Set<Unicode.Scalar> = {
        var scalars = Set<Unicode.Scalar>()
        for range in [("a", "z"), ("0", "9")] {
            for value in Unicode.Scalar(range.0)!.value...Unicode.Scalar(range.1)!.value {
                scalars.insert(Unicode.Scalar(value)!)
            }
        }
        return scalars
    }()

    /// Separators allowed between letters and digits in the local part.
    private static let separatorScalars: Set<Unicode.Scalar> = [".", "_", "-", "+"]

    /// Normalizes `raw` (surrounding whitespace and newlines removed, lowercased) and returns nil
    /// unless it is a plausible Polimi mailbox: exactly one `@`; a local part of at most 64
    /// letters, digits, `.`, `_`, `-`, `+` that starts and ends with a letter or digit, has no
    /// consecutive dots and no `-` or `+` next to a dot; and a domain that is exactly
    /// `mail.polimi.it` or `polimi.it`. Inner whitespace, control characters and over-long input
    /// are rejected, not repaired.
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
        let domain = String(parts[1])
        guard Self.allowedDomains.contains(domain), Self.isPlausibleLocalPart(parts[0]) else { return nil }
        value = normalized
    }

    /// The local-part rule, kept strict on purpose: Polimi mailboxes are `name.surname` or
    /// person-code forms, so a value like `-@polimi.it` or `a.-b@…` is far more likely a
    /// corrupted or hostile profile field than a real mailbox, and must not be sent to Webex.
    private static func isPlausibleLocalPart(_ local: Substring) -> Bool {
        let scalars = Array(local.unicodeScalars)
        guard let first = scalars.first, let last = scalars.last,
              scalars.count <= maximumLocalPartLength,
              alphanumericScalars.contains(first), alphanumericScalars.contains(last) else { return false }
        for (index, scalar) in scalars.enumerated() {
            guard alphanumericScalars.contains(scalar) || separatorScalars.contains(scalar) else { return false }
            guard index > 0 else { continue }
            let previous = scalars[index - 1]
            if previous == ".", [".", "-", "+"].contains(scalar) { return false }
            if scalar == ".", ["-", "+"].contains(previous) { return false }
        }
        return true
    }
}

extension PolimiEmail: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Only the domain is shown; the mailbox name is personal data.
    public var description: String {
        let domain = value.split(separator: "@").last.map(String.init) ?? ""
        return "PolimiEmail(<redacted>@\(domain))"
    }

    public var debugDescription: String { description }

    /// Without this, `dump` and the debugger would print the stored `value` field by field.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
