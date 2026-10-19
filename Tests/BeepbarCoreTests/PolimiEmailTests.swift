import Testing
@testable import BeepbarCore

/// `PolimiEmail` decides which address may ever be typed into Webex's Polimi sign-in (#148).
/// These tests guard against sending a non-Polimi identity (other or lookalike domains) and
/// against "repairing" malformed input instead of rejecting it.
struct PolimiEmailTests {
    /// Proves both Polimi domains are accepted and stored verbatim when already normalized.
    @Test(arguments: [
        "mario.rossi@mail.polimi.it",
        "mario.rossi@polimi.it",
        "10712345@mail.polimi.it",
        "mario_rossi-2+lab@mail.polimi.it",
        "m@polimi.it"
    ])
    func acceptsPolimiMailboxes(_ raw: String) throws {
        let email = try #require(PolimiEmail(raw))
        #expect(email.value == raw)
    }

    /// Proves surrounding whitespace/newlines are trimmed and case is folded, so the WeBeep
    /// profile's "Mario.Rossi@Mail.Polimi.it\n" and the user's typed value compare equal.
    @Test func normalizesSurroundingWhitespaceAndCase() throws {
        let email = try #require(PolimiEmail("  \tMario.Rossi@Mail.POLIMI.it\r\n"))
        #expect(email.value == "mario.rossi@mail.polimi.it")
        #expect(email == PolimiEmail("mario.rossi@mail.polimi.it"))
    }

    /// Guards the domain check: any other domain, including personal mail set on the Moodle
    /// profile, is rejected.
    @Test(arguments: [
        "mario.rossi@gmail.com",
        "mario.rossi@studenti.unimi.it",
        "mario.rossi@polimi.com",
        "mario.rossi@mail.polimi.it.",
        "mario.rossi@"
    ])
    func rejectsOtherDomains(_ raw: String) {
        #expect(PolimiEmail(raw) == nil)
    }

    /// Guards against a suffix or prefix match: lookalike and sub-domains of Polimi's domains
    /// are not Polimi mailboxes.
    @Test(arguments: [
        "mario.rossi@polimi.it.evil.com",
        "mario.rossi@xpolimi.it",
        "mario.rossi@evil-polimi.it",
        "mario.rossi@studenti.polimi.it",
        "mario.rossi@evil.mail.polimi.it",
        "mario.rossi@mail.polimi.it.evil.com"
    ])
    func rejectsLookalikeDomains(_ raw: String) {
        #expect(PolimiEmail(raw) == nil)
    }

    /// Proves the address must have exactly one `@` and a non-empty local part.
    @Test(arguments: [
        "",
        "   ",
        "mail.polimi.it",
        "@mail.polimi.it",
        "mario@rossi@mail.polimi.it",
        "mario.rossi@@mail.polimi.it"
    ])
    func rejectsWrongShape(_ raw: String) {
        #expect(PolimiEmail(raw) == nil)
    }

    /// Proves dots may only separate characters in the local part.
    @Test(arguments: [
        ".mario@mail.polimi.it",
        "mario.@mail.polimi.it",
        "mario..rossi@mail.polimi.it",
        ".@polimi.it"
    ])
    func rejectsMisplacedDots(_ raw: String) {
        #expect(PolimiEmail(raw) == nil)
    }

    /// Proves the local part must start and end with a letter or digit, and that `-` or `+`
    /// may not touch a dot. Guards against sending a corrupted or hostile profile value such as
    /// `-@polimi.it` to Webex as if it were a mailbox.
    @Test(arguments: [
        "-@polimi.it",
        "+x@polimi.it",
        "_mario@polimi.it",
        "x-@mail.polimi.it",
        "x+@mail.polimi.it",
        "mario_@polimi.it",
        "a.-b@mail.polimi.it",
        "a-.b@mail.polimi.it",
        "a+.b@mail.polimi.it",
        "a.+b@mail.polimi.it"
    ])
    func rejectsSeparatorsAtEdgesOrNextToDots(_ raw: String) {
        #expect(PolimiEmail(raw) == nil)
    }

    /// Proves separators between letters/digits remain valid, so the edge rule above does not
    /// reject real mailboxes.
    @Test(arguments: ["a-b@polimi.it", "a+b@polimi.it", "a_b@polimi.it", "a.b-c+d_e.f@mail.polimi.it", "a_.b@polimi.it"])
    func acceptsSeparatorsBetweenAlphanumerics(_ raw: String) {
        #expect(PolimiEmail(raw)?.value == raw)
    }

    /// Guards against leaking the mailbox name: printing, interpolating, `String(reflecting:)`
    /// and `dump` show only the domain, never the local part.
    @Test func textualRepresentationsRedactTheLocalPart() throws {
        let email = try #require(PolimiEmail("mario.rossi@mail.polimi.it"))
        var dumped = ""
        dump(email, to: &dumped)
        let renderings = [email.description, email.debugDescription, "\(email)", String(describing: email), String(reflecting: email), dumped]
        for rendering in renderings {
            #expect(!rendering.contains("mario"))
            #expect(!rendering.contains("rossi"))
        }
        #expect(email.description == "PolimiEmail(<redacted>@mail.polimi.it)")
        #expect(email.value == "mario.rossi@mail.polimi.it")
    }

    /// Proves inner whitespace, control characters, quoting/punctuation and non-ASCII lookalikes
    /// are rejected rather than stripped (trimming applies to the ends only).
    @Test(arguments: [
        "mario rossi@mail.polimi.it",
        "mario.rossi @mail.polimi.it",
        "mario.rossi@ mail.polimi.it",
        "mario\trossi@mail.polimi.it",
        "mario\nrossi@mail.polimi.it",
        "mario\u{0}rossi@mail.polimi.it",
        "mario.rossi@mail.polimi.it\u{0}",
        "mario\u{7F}@polimi.it",
        "\"mario\"@polimi.it",
        "mario,rossi@polimi.it",
        "mario<rossi>@polimi.it",
        "mário@polimi.it",
        "mario@pоlimi.it", // Cyrillic о
        "\u{212A}@polimi.it" // KELVIN SIGN, which lowercases to an ASCII "k"
    ])
    func rejectsInvalidCharacters(_ raw: String) {
        #expect(PolimiEmail(raw) == nil)
    }

    /// Proves the length bounds: the local part is capped at 64 characters and over-long input
    /// (> 254) is rejected. Guards against unbounded input reaching Webex or storage. With the
    /// 64-character local cap no valid address can exceed 79 characters, so the 254 check only
    /// stops hostile input early; the local cap is what this test pins at its boundary.
    @Test func boundsLength() {
        let domain = "@mail.polimi.it"
        let local64 = String(repeating: "a", count: 64)
        #expect(PolimiEmail(local64 + domain) != nil)
        #expect(PolimiEmail(local64 + "a" + domain) == nil)
        let overall = String(repeating: "a", count: 300) + domain
        #expect(PolimiEmail(overall) == nil)
        // Surrounding whitespace does not count toward the limit; it is trimmed first.
        #expect(PolimiEmail(String(repeating: " ", count: 300) + "m@polimi.it") != nil)
    }
}
