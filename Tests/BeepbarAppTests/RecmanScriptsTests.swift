import Foundation
import Testing
import WebKit
import BeepbarCore
@testable import BeepbarApp

/// The page scripts, run through `RecmanWebSession.run` exactly as the session runs them, against
/// pages laid out like the real archive and Polimi's sign-in pages. They guard the reading half of
/// the feature: a script that misreads the page would show the wrong list, or none, with no error.
@MainActor
struct RecmanScriptsTests {
    private static let archiveURL = URL(string: "https://onlineservices.polimi.it\(RecmanURLPolicy.archivePath)")!

    /// Loads `body` as if served at `url` and waits until WebKit has finished loading it. After
    /// that, every page load the fixture asks for is recorded and refused, so a test sees where a
    /// script would have gone without any request leaving the machine.
    @MainActor private final class FixturePage: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private var finished: CheckedContinuation<Void, Never>?
        private var loaded = false
        /// The page loads asked for since the fixture finished loading, in order.
        private(set) var requestedLoads: [URL] = []

        init(_ body: String, at url: URL = RecmanScriptsTests.archiveURL) async {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            super.init()
            webView.navigationDelegate = self
            await withCheckedContinuation { continuation in
                finished = continuation
                webView.loadHTMLString("<html><body>\(body)</body></html>", baseURL: url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            finished?.resume()
            finished = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard loaded, action.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }
            if let url = action.request.url { requestedLoads.append(url) }
            decisionHandler(.cancel)
        }

        /// The page loads asked for once WebKit has had time to act on a script's navigation,
        /// which it decides after the script returns.
        func requestedLoadsAfterScript() async -> [URL] {
            for _ in 0..<50 where requestedLoads.isEmpty {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return requestedLoads
        }

        func run(_ script: String, arguments: [String: Any]? = nil) async -> String? {
            await RecmanWebSession.run(script, arguments: arguments, in: webView)
        }

        /// A value the page's own scripts recorded, read in the page's world.
        func pageValue(_ expression: String) async throws -> String? {
            try await webView.evaluateJavaScript("String(\(expression))") as? String
        }
    }

    /// The archive's search form as Recman lays it out, with every filter BeepBar has to empty.
    /// Submitting records what would have been sent instead of navigating.
    private static let searchForm = """
    <form onsubmit="window.sent = [this.aa.value, this.contesto.value, this.fromDateReg.value, this.toDateReg_day.value, this.argomento.value, this.tipologia.value].join('|'); return false">
      <select name="aa"><option value="">Tutti</option><option value="2025">2025 / 26</option><option value="2026">2026 / 27</option></select>
      <input name="contesto" value="old">
      <input name="fromDateReg" value="01/09/2026"><input name="toDateReg_day" value="30">
      <input name="argomento" value="limits">
      <select name="tipologia"><option value="">Tutte</option><option value="LE" selected>Lezione</option></select>
      <input type="submit" name="EVN_SEARCH" value="Cerca">
    </form>
    """

    private static func row(id: String = "123", date: String = "30/09/2026 12:29", link: Bool = true) -> String {
        let play = link ? "<a href='?evn_preview_link=evento&amp;transfer_id=\(id)'>Riproduci</a>" : ""
        return "<tr><td>\(play)</td><td>2026 / 27</td><td>\(date)</td><td>058167 - NUMERICAL   LINEAR ALGEBRA (DOCENTE)</td><td>Laboratorio</td><td>Linear\n systems</td><td></td><td>97 min</td><td>179 MB</td></tr>"
    }

    private static func results(_ rows: String, footer: String = "<p>pag. 1/1 (totale:1)</p>") -> String {
        // The layout table around the form mirrors Recman's: its rows contain other rows and
        // must not be read as results.
        "<table><tr><td>\(searchForm)</td></tr></table><table><tr><th>Riproduci</th><th>Anno</th><th>Data</th></tr>\(rows)</table>\(footer)"
    }

    // MARK: Page facts

    @Test func pageFactsTellTheArchiveASelfSubmittingPageAndASignInApart() async throws {
        let archive = await FixturePage(Self.searchForm)
        #expect(PolimiPageFacts.decode(try #require(await archive.run(RecmanScripts.pageFacts))) == PolimiPageFacts(hasArchiveForm: true))

        // Polimi's self-submitting hop carries hidden fields, including a hidden password-type
        // one on some pages: hidden fields must not count as asking the user.
        let redirect = await FixturePage("<form id='automaticaRedirectForm' onsubmit='return false'><input type='hidden' name='ticket' value='x'><input type='password' style='display:none'></form>")
        #expect(PolimiPageFacts.decode(try #require(await redirect.run(RecmanScripts.pageFacts))) == PolimiPageFacts(hasAutomaticRedirectForm: true))

        let signIn = await FixturePage("<form onsubmit='return false'><input name='login'><input type='password' name='password'></form>")
        #expect(PolimiPageFacts.decode(try #require(await signIn.run(RecmanScripts.pageFacts)))?.asksForCredentials == true)
        let code = await FixturePage("<form onsubmit='return false'><input name='otp' autocomplete='one-time-code'></form>")
        #expect(PolimiPageFacts.decode(try #require(await code.run(RecmanScripts.pageFacts)))?.asksForCredentials == true)

        // A page without all three archive controls isn't the archive.
        let partial = await FixturePage("<select name='aa'></select><input name='contesto'>")
        #expect(PolimiPageFacts.decode(try #require(await partial.run(RecmanScripts.pageFacts)))?.hasArchiveForm == false)
    }

    // MARK: Search

    /// The search sets the course and year and empties every other filter, so a date range or a
    /// kind left over from an earlier search can't silently shorten the list.
    @Test func searchFillsCourseAndYearAndEmptiesEveryOtherFilter() async throws {
        let page = await FixturePage(Self.searchForm)
        #expect(await page.run(RecmanScripts.search, arguments: ["code": "058167", "year": "2026"]) == "submitted")
        #expect(try await page.pageValue("window.sent") == "2026|058167||||")
    }

    /// The course code travels as an argument, never spliced into the script: a value with
    /// quotes stays a value.
    @Test func searchArgumentsAreNotSplicedIntoTheScript() async throws {
        let page = await FixturePage(Self.searchForm)
        #expect(await page.run(RecmanScripts.search, arguments: ["code": "x'); window.injected = true; ('", "year": "2026"]) == "submitted")
        #expect(try await page.pageValue("window.injected") == "undefined")
        #expect(try await page.pageValue("window.sent")?.hasPrefix("2026|x'); window.injected") == true)
    }

    @Test func searchReportsAMissingYearOrFormWithoutSubmitting() async throws {
        let page = await FixturePage(Self.searchForm)
        #expect(await page.run(RecmanScripts.search, arguments: ["code": "058167", "year": "2027"]) == "missingYear")
        #expect(try await page.pageValue("window.sent") == "undefined")
        let other = await FixturePage("<p>Servizio non disponibile</p>")
        #expect(await other.run(RecmanScripts.search, arguments: ["code": "058167", "year": "2026"]) == "missingForm")
    }

    @Test func columnFiltersAreClearedOnlyWhenSet() async throws {
        let clean = await FixturePage("<input name='search_transfers__CAMPO_1' value=' '><input type='submit' name='evn_ricerca_recordset' onclick='window.applied = true; return false'>")
        #expect(await clean.run(RecmanScripts.clearColumnFilters) == "clean")
        #expect(try await clean.pageValue("window.applied") == "undefined")

        let filtered = await FixturePage("<form onsubmit='return false'><input name='search_transfers__CAMPO_1' value='Rossi'><input name='search_transfers__CAMPO_2' value='LE'><input type='submit' name='evn_ricerca_recordset_x' onclick=\"window.applied = document.querySelector('[name=search_transfers__CAMPO_1]').value + '|' + document.querySelector('[name=search_transfers__CAMPO_2]').value\"></form>")
        #expect(await filtered.run(RecmanScripts.clearColumnFilters) == "submitted")
        #expect(try await filtered.pageValue("window.applied") == "|")

        let noButton = await FixturePage("<input name='search_transfers__CAMPO_1' value='Rossi'>")
        #expect(await noButton.run(RecmanScripts.clearColumnFilters) == "missing")
        #expect(try await noButton.pageValue("document.querySelector('[name=search_transfers__CAMPO_1]').value") == "Rossi")
    }

    // MARK: Results

    /// A results page read end to end: rows (with whitespace collapsed and the relative preview
    /// link resolved), the total, the search the form holds, and nothing from the layout table.
    @Test func resultsPageReadsRowsTotalAndTheSearchItShows() async throws {
        let page = await FixturePage(Self.results(Self.row()))
        _ = await page.run("document.querySelector('[name=aa]').value = '2026'; document.querySelector('[name=contesto]').value = ' 058167 '; ''")
        let decoded = try RecmanResultsPage.decode(try #require(await page.run(RecmanScripts.resultsPage)))
        #expect(decoded.recordings.map(\.id) == ["123"])
        #expect(decoded.recordings.first?.title == "Linear systems")
        #expect(decoded.recordings.first?.previewURL.host == "onlineservices.polimi.it")
        #expect(decoded.declaredTotal == 1)
        #expect(decoded.hasNext == false)
        #expect(decoded.searchedCode == "058167")
        #expect(decoded.searchedYear == "2026")
    }

    /// A dated row without a preview link is still reported, so it fails the page instead of
    /// quietly dropping out of the list.
    @Test func aRowWithoutAPreviewLinkFailsThePage() async throws {
        let page = await FixturePage(Self.results(Self.row() + Self.row(id: "124", link: false), footer: "<p>pag. 1/1 (totale:2)</p>"))
        let report = try #require(await page.run(RecmanScripts.resultsPage))
        #expect(throws: RecmanRecordingParser.ParseError.incompatibleRows) { try RecmanResultsPage.decode(report) }
    }

    @Test func resultsPageReportsTheEmptyStateItSees() async throws {
        let zero = await FixturePage(Self.results("", footer: "<p>pag. 1/1 (totale:0)</p>"))
        let empty = try RecmanResultsPage.decode(try #require(await zero.run(RecmanScripts.resultsPage)))
        #expect(empty.recordings.isEmpty)
        #expect(empty.declaredTotal == 0)
        let notice = await FixturePage(Self.results("", footer: "<p>Nessuna registrazione trovata</p>"))
        let worded = try RecmanResultsPage.decode(try #require(await notice.run(RecmanScripts.resultsPage)))
        #expect(worded.saysEmpty)
        #expect(worded.declaredTotal == nil)
    }

    /// Recman's pager as the live archive draws it: the current page and page size as plain text,
    /// the others as links whose clicks Recman's own script takes over to swap the table in place
    /// (`window.swapped` records such a click). Pass the link texts to leave out.
    private static func pager(without missing: Set<String> = []) -> String {
        let links = [("2", "page2"), ("prossima", "next"), ("ultima", "last"), ("25", "size25"), ("50", "size50"), ("100", "size100"), ("tutte", "sizeAll")]
            .filter { !missing.contains($0.0) }
            .map { "<a class='paginator_link' href='?evn_paginator=\($0.1)'>\($0.0)</a>" }
            .joined(separator: " ")
        return """
        <p>pag. 1/3 (totale:25) prima precedente 1 \(links) elementi per pagina: 10</p>
        <script>
          document.addEventListener('click', e => {
            const link = e.target.closest('a.paginator_link');
            if (link) { e.preventDefault(); window.swapped = link.getAttribute('href'); }
          });
        </script>
        """
    }

    private static func pagerURL(_ name: String) -> URL {
        URL(string: "?evn_paginator=\(name)", relativeTo: archiveURL)!.absoluteURL
    }

    /// An enabled "prossima" is followed with a real page load, even though Recman's script
    /// swaps the table in place when the link is clicked. Guards against clicking it again: that
    /// changes the page with no load for the session to wait for, and every course with more than
    /// one page of recordings hung until the timeout, then failed as "Polimi isn't responding".
    @Test func theNextPageIsLoadedNotClicked() async throws {
        let page = await FixturePage(Self.results(Self.row(), footer: Self.pager()))
        #expect(try RecmanResultsPage.decode(try #require(await page.run(RecmanScripts.resultsPage))).hasNext)
        #expect(await page.run(RecmanScripts.nextPage) == "submitted")
        #expect(await page.requestedLoadsAfterScript() == [Self.pagerURL("next")])
        #expect(try await page.pageValue("window.swapped") == "undefined")
    }

    /// Only an enabled "prossima" counts as a next page; with none, nothing is followed.
    @Test func aDisabledOrMissingNextLinkIsNotFollowed() async throws {
        let disabled = await FixturePage(Self.results(Self.row(), footer: "<span>prossima</span><a href='?evn_paginator=a' class='disabled'>prossima</a><a href='?evn_paginator=b' aria-disabled='true'>prossima</a><a href='?evn_paginator=c'>precedente</a>"))
        #expect(try RecmanResultsPage.decode(try #require(await disabled.run(RecmanScripts.resultsPage))).hasNext == false)
        #expect(await disabled.run(RecmanScripts.nextPage) == "missing")
        #expect(await disabled.requestedLoadsAfterScript().isEmpty)
    }

    /// A search over several pages switches to a hundred a page, by loading the "100" link (not
    /// clicking it, for the reason above), so a long course is read in one load.
    @Test func severalPagesSwitchToAHundredAPage() async throws {
        let page = await FixturePage(Self.results(Self.row(), footer: Self.pager()))
        #expect(await page.run(RecmanScripts.hundredPerPage) == "submitted")
        #expect(await page.requestedLoadsAfterScript() == [Self.pagerURL("size100")])
        #expect(try await page.pageValue("window.swapped") == "undefined")
    }

    /// No switch, and no extra load, when everything already fits on the page, when a hundred is
    /// the size already shown (no "100" link), or when "prossima" is disabled.
    @Test func thePageSizeStaysWhenThereIsNothingToGain() async throws {
        let onePage = await FixturePage(Self.results(Self.row(), footer: Self.pager(without: ["2", "prossima", "ultima"])))
        let atHundred = await FixturePage(Self.results(Self.row(), footer: Self.pager(without: ["100"])))
        let disabledNext = await FixturePage(Self.results(Self.row(), footer: "<a class='disabled' href='?evn_paginator=next'>prossima</a> <a href='?evn_paginator=size100'>100</a>"))
        for page in [onePage, atHundred, disabledNext] {
            #expect(await page.run(RecmanScripts.hundredPerPage) == "unchanged")
            #expect(await page.requestedLoadsAfterScript().isEmpty)
        }
    }

    @Test func playbackLinkFindsOnlyThePolimiWebexPlayer() async throws {
        let linked = await FixturePage("<a href='https://example.com/x'>x</a><a href='https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc'>Guarda</a>")
        #expect(await linked.run(RecmanScripts.playbackLink) == "https://politecnicomilano.webex.com/politecnicomilano/ldr.php?RCID=abc")
        let framed = await FixturePage("<iframe src='https://politecnicomilano.webex.com/recordingservice/sites/politecnicomilano/recording/playback/abc'></iframe>")
        #expect(await framed.run(RecmanScripts.playbackLink)?.hasSuffix("/recording/playback/abc") == true)
        let lookalike = await FixturePage("<a href='https://politecnicomilano.webex.com.evil.com/ldr.php?RCID=a'>x</a>")
        #expect(await lookalike.run(RecmanScripts.playbackLink) == "")
    }

    /// The scripts run in their own content world: a page that replaces the built-ins they rely
    /// on can't change what they report.
    @Test func thePagesOwnScriptsCannotTamperWithTheReading() async throws {
        let page = await FixturePage("<script>JSON.stringify = () => '{\"hasArchiveForm\":true,\"hasAutomaticRedirectForm\":false,\"asksForCredentials\":false}'; Array.from = () => [];</script>" + Self.results(Self.row()))
        let facts = PolimiPageFacts.decode(try #require(await page.run(RecmanScripts.pageFacts)))
        #expect(facts?.hasArchiveForm == true)
        let decoded = try RecmanResultsPage.decode(try #require(await page.run(RecmanScripts.resultsPage)))
        #expect(decoded.recordings.count == 1)
        let tampered = await FixturePage("<script>JSON.stringify = () => '{\"hasArchiveForm\":true,\"hasAutomaticRedirectForm\":false,\"asksForCredentials\":false}';</script><p>Login</p>")
        #expect(PolimiPageFacts.decode(try #require(await tampered.run(RecmanScripts.pageFacts)))?.hasArchiveForm == false)
    }

    /// A script that throws, or answers something other than a string, reads as nil, which the
    /// session turns into "unrecognized" instead of a crash or a guess.
    @Test func aFailingScriptAnswersNil() async throws {
        let page = await FixturePage("<p>x</p>")
        #expect(await page.run("throw new Error('x')") == nil)
        #expect(await page.run("undefined") == nil)
        #expect(await page.run("42") == nil)
        #expect(await page.run("return 1", arguments: [:]) == nil)
    }
}
