import Foundation
import Testing
@testable import BeepbarCore

/// The way into the Recman archive, page by page. The sequences are the real ones, recorded from a
/// live session (query values replaced). The failure these tests exist for is the one an earlier
/// version had: a live session whose hops were read as "sign in", so the recordings never loaded
/// on their own and the user had to open the archive by hand.
struct RecmanEntryNavigatorTests {
    // The warm chain: a live Polimi session goes from the entry to the archive without the user.
    static let entry = URL(string: "https://aunicalogin.polimi.it/aunicalogin/getservizio.xml?id_servizio=2314")!
    static let loginJSP = URL(string: "https://aunicalogin.polimi.it/aunicalogin/aunicalogin.jsp?id_servizio=2314&profile=x")!
    static let checkCookie = URL(string: "https://aunicalogin.polimi.it/aunicalogin/aunicalogin/controller/AunicaLogin.do?evn_checkCookieSSO=x&id_servizio=2314")!
    static let extensionPoint = URL(string: "https://aunicalogin.polimi.it/aunicalogin/aunicalogin/controller/passi/LoginExtensionPoint.do?jaf_currentWFID=x&EVN_DEFAULT=x")!
    static let ticket = URL(string: "https://onlineservices.polimi.it/recman_frontend?ticket=x&al_id_srv=2314")!
    static let ticketHTTP = URL(string: "http://onlineservices.polimi.it/recman_frontend/?ticket=x&al_id_srv=2314")!
    static let ticketHTTPS = URL(string: "https://onlineservices.polimi.it/recman_frontend/?ticket=x&al_id_srv=2314")!
    static let archive = URL(string: "https://onlineservices.polimi.it/recman_frontend/recman_frontend/controller/ArchivioListActivity.do?jaf_currentWFID=x&EVN_SHOW_SCREEN=evento")!
    // The cold chain: credentials, then the 2FA notice.
    static let identification = URL(string: "https://aunicalogin.polimi.it/aunicalogin/aunicalogin/controller/IdentificazioneUnica.do;jsessionid=x?jaf_currentWFID=x")!
    static let twoFactorNotice = URL(string: "https://aunicalogin.polimi.it/aunicalogin/aunicalogin/controller/passi/AvvisiDFA.do?jaf_currentWFID=x&EVN_DEFAULT=x")!

    static let archiveForm = PolimiPageFacts(hasArchiveForm: true)
    static let autoSubmit = PolimiPageFacts(hasAutomaticRedirectForm: true)
    static let credentials = PolimiPageFacts(asksForCredentials: true)
    static let plain = PolimiPageFacts()

    /// Replays loads as the web view reports them: each starts, may redirect, then finishes.
    struct Replay {
        var navigator: RecmanEntryNavigator
        var nextID = 0
        var commands: [RecmanEntryNavigator.Command] = []

        init(_ mode: RecmanEntryNavigator.Mode) { navigator = RecmanEntryNavigator(mode: mode) }

        /// A load that goes through `redirects` before finishing on `url`. Returns its id.
        @discardableResult mutating func load(_ url: URL, _ facts: PolimiPageFacts, redirects: Int = 0) -> Int {
            for _ in 0...redirects { start() }
            send(.loadFinished(id: nextID, url: url, facts: facts))
            return nextID
        }

        mutating func start() {
            nextID += 1
            send(.loadStarted(id: nextID))
        }

        mutating func send(_ event: RecmanEntryNavigator.Event) {
            commands += navigator.handle(event)
        }

        var finished: RecmanEntryNavigator.Outcome? {
            commands.compactMap { if case .finish(let outcome) = $0 { outcome } else { nil } }.first
        }

        var windowShows: Int { commands.filter { $0 == .showWindow }.count }
    }

    /// The fix itself: a live session reaches the archive in the background, through the
    /// self-submitting login pages and Recman's http ticket hop, without ever asking for the user.
    @Test func liveSessionReachesTheArchiveWithoutTheUser() {
        var replay = Replay(.background)
        replay.load(Self.entry, Self.plain)
        replay.load(Self.loginJSP, Self.autoSubmit)
        replay.load(Self.checkCookie, Self.autoSubmit)
        replay.load(Self.extensionPoint, Self.autoSubmit)
        // ticket → http → https → archive is one load with three redirects.
        replay.load(Self.archive, Self.archiveForm, redirects: 3)
        #expect(replay.finished == .archive)
        #expect(replay.windowShows == 0)
        #expect(replay.navigator.isFinished)
    }

    /// A slow hop is still a hop: the patience timer of a page that has since moved on must not
    /// end the entry. This is how "sign in" used to appear with a live session.
    @Test func aTimerForAPageThatMovedOnIsIgnored() {
        var replay = Replay(.background)
        let first = replay.load(Self.checkCookie, Self.plain)
        #expect(replay.commands == [.schedulePatience(id: first, delay: PolimiPage.stillPatience)])
        replay.start()
        replay.send(.patienceElapsed(id: first))
        #expect(replay.finished == nil)
        // A probe result that arrives late, for the old page, is ignored too.
        replay.send(.loadFinished(id: first, url: Self.loginJSP, facts: Self.credentials))
        #expect(replay.finished == nil)
        replay.send(.loadFinished(id: replay.nextID, url: Self.archive, facts: Self.archiveForm))
        #expect(replay.finished == .archive)
    }

    /// A page that submits itself is passing through even on the login host, and even if it also
    /// carries a password field: only if it is still there after its (longer) patience does it
    /// count as needing the user.
    @Test func aSelfSubmittingLoginPageGetsTimeBeforeCountingAsSignIn() {
        var replay = Replay(.background)
        let id = replay.load(Self.loginJSP, PolimiPageFacts(hasAutomaticRedirectForm: true, asksForCredentials: true))
        #expect(replay.commands == [.schedulePatience(id: id, delay: PolimiPage.autoSubmitPatience)])
        replay.send(.patienceElapsed(id: id))
        #expect(replay.finished == .needsUser)
    }

    /// Without a live session the background entry stops at once on the credentials page, so the
    /// Recordings page can offer "Accedi con Polimi" without waiting out a timer.
    @Test func backgroundStopsAtTheSignInForm() {
        var replay = Replay(.background)
        replay.load(Self.entry, Self.plain)
        replay.load(Self.loginJSP, Self.credentials)
        #expect(replay.finished == .needsUser)
        #expect(replay.windowShows == 0)
    }

    /// The 2FA notice has no password field but waits for a click: it needs the user.
    @Test func theTwoFactorNoticeNeedsTheUser() {
        var replay = Replay(.background)
        replay.load(Self.twoFactorNotice, Self.plain)
        #expect(replay.finished == .needsUser)
    }

    /// A login page with nothing telling on it that stays still is waiting for the user; any other
    /// Polimi page that stays still is a way in BeepBar doesn't know.
    @Test func aStillPageEndsByWhereItIs() {
        var login = Replay(.background)
        let loginID = login.load(Self.checkCookie, Self.plain)
        login.send(.patienceElapsed(id: loginID))
        #expect(login.finished == .needsUser)

        var other = Replay(.background)
        let otherID = other.load(Self.ticketHTTPS, Self.plain)
        other.send(.patienceElapsed(id: otherID))
        #expect(other.finished == .unrecognized)

        // The archive's address without its search form (an error page) is not the archive.
        var broken = Replay(.background)
        let brokenID = broken.load(Self.archive, Self.plain)
        broken.send(.patienceElapsed(id: brokenID))
        #expect(broken.finished == .unrecognized)
    }

    /// The sign-in the user asked for: the window appears only once the user is needed, stays up
    /// through credentials, the 2FA notice and the hops after them (no timers while the user is
    /// driving), and the entry ends when the archive is reached.
    @Test func interactiveSignInShowsTheWindowOnceAndEndsAtTheArchive() {
        var replay = Replay(.interactive)
        replay.load(Self.entry, Self.plain)
        #expect(replay.windowShows == 0)
        replay.load(Self.loginJSP, Self.credentials)
        #expect(replay.windowShows == 1)
        #expect(replay.navigator.isWaitingForUser)
        replay.commands = []
        replay.load(Self.identification, Self.plain)
        replay.load(Self.twoFactorNotice, Self.plain)
        replay.load(Self.extensionPoint, Self.autoSubmit)
        #expect(replay.commands.isEmpty)
        replay.send(.deadlineElapsed)
        replay.send(.loadFailed(id: replay.nextID))
        #expect(replay.commands.isEmpty)
        replay.load(Self.archive, Self.archiveForm, redirects: 3)
        #expect(replay.commands == [.finish(.archive)])
    }

    /// A live session gets through an interactive entry without any window flashing up.
    @Test func interactiveWithALiveSessionNeverShowsTheWindow() {
        var replay = Replay(.interactive)
        replay.load(Self.loginJSP, Self.autoSubmit)
        replay.load(Self.archive, Self.archiveForm)
        #expect(replay.finished == .archive)
        #expect(replay.windowShows == 0)
    }

    /// Closing the sign-in window cancels; an unfamiliar way in shows the window instead of
    /// failing, so the user can still reach the archive by hand.
    @Test func interactiveDeadEndsHandOverToTheUser() {
        var closed = Replay(.interactive)
        closed.load(Self.loginJSP, Self.credentials)
        closed.send(.windowClosed)
        #expect(closed.finished == .cancelled)

        var unfamiliar = Replay(.interactive)
        unfamiliar.load(URL(string: "https://www.polimi.it/servizi-online")!, Self.plain)
        unfamiliar.send(.patienceElapsed(id: unfamiliar.nextID))
        #expect(unfamiliar.windowShows == 1)
        #expect(unfamiliar.finished == nil)

        var slow = Replay(.interactive)
        slow.start()
        slow.send(.deadlineElapsed)
        #expect(slow.windowShows == 1)
        #expect(slow.finished == nil)
    }

    /// Background entries are bounded: no verdict by the deadline, a failed load, or a page that
    /// isn't Polimi's or isn't https each end it.
    @Test func backgroundEndsOnDeadlineFailureAndForeignPages() {
        var slow = Replay(.background)
        slow.start()
        slow.send(.deadlineElapsed)
        #expect(slow.finished == .timedOut)

        var offline = Replay(.background)
        offline.start()
        offline.send(.loadFailed(id: offline.nextID))
        #expect(offline.finished == .failed)

        for url in ["https://evil.example/aunicalogin", "http://aunicalogin.polimi.it/aunicalogin/aunicalogin.jsp", "https://aunicalogin.polimi.it:8443/x", "https://user:pw@aunicalogin.polimi.it/x"] {
            var foreign = Replay(.background)
            foreign.load(URL(string: url)!, Self.archiveForm)
            #expect(foreign.finished == .unrecognized, "\(url)")
        }

        var missing = Replay(.background)
        missing.start()
        missing.send(.loadFinished(id: missing.nextID, url: nil, facts: Self.archiveForm))
        #expect(missing.finished == .unrecognized)
    }

    /// Once over, the entry ignores everything: a second `finish` would resume its caller twice.
    @Test func aFinishedEntryIgnoresLaterEvents() {
        var replay = Replay(.background)
        replay.load(Self.archive, Self.archiveForm)
        replay.commands = []
        replay.load(Self.loginJSP, Self.credentials)
        replay.send(.deadlineElapsed)
        replay.send(.cancelled)
        replay.send(.windowClosed)
        #expect(replay.commands.isEmpty)

        var cancelled = Replay(.background)
        cancelled.start()
        cancelled.send(.cancelled)
        #expect(cancelled.finished == .cancelled)
    }

    /// The archive needs its address and its form; a lookalike host never counts as Polimi.
    @Test func classifierChecksAddressAndPage() {
        #expect(PolimiPage.classify(Self.archive, facts: Self.archiveForm) == .archive)
        #expect(PolimiPage.classify(URL(string: "https://onlineservices.polimi.it/other.do")!, facts: Self.archiveForm) == .transit(patience: PolimiPage.stillPatience, ifStill: .unrecognized))
        #expect(PolimiPage.classify(URL(string: "https://aunicalogin.polimi.it" + RecmanURLPolicy.archivePath)!, facts: Self.archiveForm) == .transit(patience: PolimiPage.stillPatience, ifStill: .needsUser))
        #expect(PolimiPage.classify(URL(string: "https://shibidp.polimi.it/idp/profile/SAML2/Redirect/SSO")!, facts: Self.plain) == .transit(patience: PolimiPage.stillPatience, ifStill: .needsUser))
        #expect(PolimiPage.classify(URL(string: "https://www.polimi.it/")!, facts: Self.credentials) == .needsUser)
        #expect(PolimiPage.isPolimiHost("polimi.it"))
        #expect(PolimiPage.isPolimiHost("AUNICALOGIN.POLIMI.IT"))
        #expect(!PolimiPage.isPolimiHost("evilpolimi.it"))
        #expect(!PolimiPage.isPolimiHost("polimi.it.evil.com"))
        #expect(PolimiPageFacts.decode(#"{"hasArchiveForm":true,"hasAutomaticRedirectForm":false,"asksForCredentials":false}"#) == Self.archiveForm)
        #expect(PolimiPageFacts.decode("null") == nil)
        #expect(PolimiPageFacts.decode(#"{"hasArchiveForm":true}"#) == nil)
    }

    /// The http ticket hop is the one plain-http load allowed. Blocking it breaks every entry at
    /// the last step; allowing http anywhere else would let a page downgrade the session.
    @Test func navigationPolicyAllowsOnlyTheTicketHopOverHTTP() {
        func allows(_ url: String, mainFrame: Bool = true, userDriven: Bool = false) -> Bool {
            RecmanNavigationPolicy.allows(URL(string: url)!, mainFrame: mainFrame, userDriven: userDriven)
        }
        #expect(allows(Self.ticketHTTP.absoluteString))
        #expect(allows(Self.ticketHTTP.absoluteString, userDriven: true))
        #expect(!allows(Self.ticketHTTP.absoluteString, mainFrame: false))
        #expect(!allows("http://onlineservices.polimi.it/other/"))
        #expect(!allows("http://aunicalogin.polimi.it/aunicalogin/aunicalogin.jsp"))
        #expect(!allows("http://user:pw@onlineservices.polimi.it/recman_frontend/"))
        for step in [Self.entry, Self.loginJSP, Self.checkCookie, Self.extensionPoint, Self.ticket, Self.ticketHTTPS, Self.archive] {
            #expect(allows(step.absoluteString), "\(step)")
        }
        // Alone, BeepBar stays on Polimi; with the user driving, any https site is fine.
        #expect(!allows("https://politecnicomilano.webex.com/x"))
        #expect(!allows("https://polimi.it.evil.com/"))
        #expect(allows("https://login.example-idp.it/spid", userDriven: true))
        #expect(allows("https://www.google.com/recaptcha/api2/anchor", mainFrame: false))
        #expect(!allows("https://user:pw@aunicalogin.polimi.it/", userDriven: true))
        for other in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "mailto:x@polimi.it", "beepbar://x"] {
            #expect(!allows(other, userDriven: true), "\(other)")
        }
        #expect(allows("about:blank", mainFrame: false))
    }
}
