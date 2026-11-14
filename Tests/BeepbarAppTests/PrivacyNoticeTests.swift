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
        #expect(italian.contains("**Statistiche d’uso.**"))
        #expect(english.contains("**Usage statistics.**"))
        #expect(!italian.contains("**Telemetria.**"))
        #expect(!english.contains("**Telemetry.**"))
        #expect(italian.contains("**Aggiornamenti.**"))
        #expect(english.contains("**Updates.**"))
        #expect(!italian.contains("**Publisher and contact:**"))
        #expect(!english.contains("**Sincronizzazione e registrazioni.**"))
        for text in [italian, english] {
            #expect(text.contains("tommaso.vaccari@mail.polimi.it"))
            #expect(text.contains("90"))
            #expect(text.contains("6(1)(c)"))
            // Telemetry was removed (#239): no link to the provider, no pointer to a Settings switch
            // that no longer exists, and nothing left that says the app sends statistics.
            #expect(!text.contains("telemetrydeck.com"))
            // The usage-statistics paragraph is one line: it does not name the provider and does not
            // describe what earlier versions sent.
            #expect(!text.localizedCaseInsensitiveContains("TelemetryDeck"))
            #expect(!text.contains("Le versioni precedenti inviavano"))
            #expect(!text.contains("Earlier versions sent"))
            #expect(!text.contains("Impostazioni → Telemetria"))
            #expect(!text.contains("Settings → Telemetry"))
            #expect(text.contains("https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement"))
        }
    }
}
