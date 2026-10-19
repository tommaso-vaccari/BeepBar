import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

struct PrivacyNoticeTests {
    /// The SwiftPM bundle matches the reviewed notice and keeps both translations and provider references complete.
    @Test func bundledNoticeMatchesReviewedDocumentAndBothLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reviewed = try String(contentsOf: root.appendingPathComponent("docs/privacy-notice.md"), encoding: .utf8)
        let bundledURL = try #require(PrivacyNotice.bundle.url(forResource: "privacy-notice", withExtension: "md"))
        #expect(try String(contentsOf: bundledURL, encoding: .utf8) == reviewed)
        let italian = try PrivacyNotice.text(language: .italian)
        let english = try PrivacyNotice.text(language: .english)
        #expect(italian.contains("**Assistenza e diritti.**"))
        #expect(english.contains("**Support and rights.**"))
        #expect(italian.contains("**Aggiornamenti.**"))
        #expect(english.contains("**Updates.**"))
        #expect(!italian.contains("**Publisher and contact:**"))
        #expect(!english.contains("**Sincronizzazione e registrazioni.**"))
        for text in [italian, english] {
            #expect(text.contains("tommaso.vaccari@mail.polimi.it"))
            #expect(text.contains("90"))
            #expect(text.contains("6(1)(f)"))
            #expect(text.contains("TelemetryDeck"))
            #expect(text.contains("https://telemetrydeck.com/docs/guides/privacy-faq/"))
            #expect(text.contains("https://telemetrydeck.com/avv/"))
            #expect(text.contains("https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement"))
        }
    }
}
