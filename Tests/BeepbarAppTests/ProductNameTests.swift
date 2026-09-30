import Foundation
import Testing
@testable import BeepbarApp

/// Issue #56: the product is spelled `BeepBar` in everything the user reads, while every name that
/// existing installs already depend on keeps the old `Beepbar` spelling.
struct ProductNameTests {
    /// Proves the rename reached the messages users actually see, in the language the tests run
    /// in (Italian: `AppLanguage.current` must not be switched in parallel tests). Guards against
    /// a message being rewritten later with the old spelling.
    @Test func messagesShownToTheUserSayBeepBar() {
        #expect(AppFailure.connectivity.detail == "Controlla la connessione. BeepBar riproverà automaticamente.")
        #expect(AppFailure.credentialUnavailable.detail.hasPrefix("BeepBar non riesce"))
        #expect(AppFailure.local(.init("x", "x")).compactDetail == "Apri BeepBar per i dettagli")
        #expect(SyncCopy.newMaterialsNotificationBody(1).hasPrefix("BeepBar "))
    }

    /// Proves the token and the sync database still live in `Application Support/Beepbar`.
    /// On the default case-insensitive APFS volume a folder renamed to `BeepBar` would still be
    /// found, so the mistake would pass every manual test; on a case-sensitive volume it would
    /// make every existing install start signed out with an empty sync database. This pins the
    /// constant and the database path built from it; the token store's default folder is pinned
    /// against the same constant in `FileTokenStoreTests`, which owns `directoryName` while it
    /// runs.
    @Test func applicationSupportFolderKeepsItsOriginalSpelling() {
        #expect(FileTokenStore.applicationSupportDirectoryName == "Beepbar")
        let applicationSupport = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        #expect(WeBeepAuthenticationController.installedDatabaseDirectory(applicationSupport: applicationSupport).path == "/Users/someone/Library/Application Support/Beepbar")
    }

    /// Scans every single-line string literal in `Sources/` for the old spelling used as a word,
    /// including at the end of a sentence. Covers the English half of every `tr(...)` pair, which
    /// the tests above cannot reach without switching the process-wide language. Identifiers
    /// (`BeepbarCore`, `Beepbar.app`, `Beepbar-download-`) don't match because the word is glued
    /// to other characters; the only allowed literal is the Application Support folder name
    /// pinned above. `Sources/` has no multi-line `"""` literals today; one added later would
    /// need this scan extended.
    @Test func noStringInTheSourcesUsesTheOldSpellingAsAWord() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 20, "Sources/ not found next to the tests: the scan would pass vacuously")

        let literal = try Regex(#""(?:[^"\\]|\\.)*""#)
        // NSRegularExpression because Swift `Regex` has no lookbehind. A following dot exempts the
        // match only when a name continues after it (`Beepbar.app`): "Riapri Beepbar." at the end
        // of a sentence is exactly the case a looser pattern let through.
        let oldWord = try NSRegularExpression(pattern: #"(?<![\w./-])Beepbar(?![\w-]|\.\w)"#)
        let allowed = #"static let applicationSupportDirectoryName = "Beepbar""#
        var offenders: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.contains(allowed) { continue }
                for match in line.matches(of: literal) {
                    let text = String(line[match.range])
                    if oldWord.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        offenders.append("\(file.lastPathComponent):\(index + 1): \(text)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "Use BeepBar in user-visible text (#56):\n\(offenders.joined(separator: "\n"))")
    }
}

/// The bundle's display name is what Sparkle's update dialogs and macOS show for the app, while
/// `CFBundleName` stays `$(PRODUCT_NAME)` (`Beepbar`), which `Beepbar.app` and existing installs
/// rely on (#56).
struct BundleDisplayNameTests {
    @Test func infoPlistShowsBeepBarWithoutRenamingTheBundle() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any], "App/Info.plist not found or unreadable")
        #expect(plist["CFBundleDisplayName"] as? String == "BeepBar")
        #expect(plist["CFBundleName"] as? String == "$(PRODUCT_NAME)")
        #expect(plist["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
    }
}
