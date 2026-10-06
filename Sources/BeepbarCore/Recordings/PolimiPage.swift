import Foundation

/// What the page probe (`RecmanScripts.pageFacts` in the app) found on the page a Recman browser
/// just finished loading. Only signals the page shows, never anything it contains.
public struct PolimiPageFacts: Sendable, Equatable, Codable {
    /// The archive's search form: academic year select, course field and search button.
    public var hasArchiveForm: Bool
    /// `form#automaticaRedirectForm`: Polimi's login pages submit it by themselves to move on.
    public var hasAutomaticRedirectForm: Bool
    /// A visible password or one-time-code field: only the user can fill it in.
    public var asksForCredentials: Bool

    public init(hasArchiveForm: Bool = false, hasAutomaticRedirectForm: Bool = false, asksForCredentials: Bool = false) {
        self.hasArchiveForm = hasArchiveForm
        self.hasAutomaticRedirectForm = hasAutomaticRedirectForm
        self.asksForCredentials = asksForCredentials
    }

    /// Nil when the probe's output isn't what it returns, so an unreadable page is never
    /// mistaken for an empty one.
    public static func decode(_ json: String) -> PolimiPageFacts? {
        try? JSONDecoder().decode(PolimiPageFacts.self, from: Data(json.utf8))
    }
}

/// How BeepBar reads each page on the way into the Recman archive.
///
/// The way in is Polimi's single sign-on: `entryURL` asks aunicalogin for Recman (service 2314);
/// with a live Polimi session it hands a ticket to Recman through a few pages that move on by
/// themselves, otherwise it stops on a page that needs the user (credentials, the 2FA notice).
/// The verdict trusts what the page shows before where it is: a page that submits itself is
/// passing through even on the login host, and a password field needs the user wherever it is.
/// Reading a slow hop of a live session as "sign in" is the failure this guards against: the
/// archive would never load on its own, and the user would be asked to sign in for nothing.
public enum PolimiPage {
    /// Recman through Polimi's single sign-on: the same link "Archivio registrazioni didattica"
    /// opens from the Online Services portal, without going through the portal.
    public static let entryURL = URL(string: "https://aunicalogin.polimi.it/aunicalogin/getservizio.xml?id_servizio=2314")!

    /// The hosts of Polimi's login: a page there that stays still is waiting for the user.
    public static let loginHosts: Set<String> = ["aunicalogin.polimi.it", "shibidp.polimi.it"]

    /// How long a page that submits itself may take before it counts as stuck.
    public static let autoSubmitPatience: Duration = .seconds(10)
    /// How long any other page on the way may stay still before it counts as the end of the road.
    /// A redirect or a new load restarts the wait, so this only bounds a page that does nothing.
    public static let stillPatience: Duration = .seconds(3)

    public enum Verdict: Sendable, Equatable {
        /// The archive with its search form: where every entry is headed.
        case archive
        /// A page only the user can move on (credentials, 2FA).
        case needsUser
        /// A page that should move on by itself. If it is still there after `patience`, it is
        /// treated as `ifStill`.
        case transit(patience: Duration, ifStill: StillOutcome)
        /// Not part of the way in: not https, not Polimi, or credentials in the URL.
        case unrecognized
    }

    public enum StillOutcome: Sendable, Equatable {
        case needsUser
        case unrecognized
    }

    public static func classify(_ url: URL?, facts: PolimiPageFacts) -> Verdict {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), isPolimiHost(host) else { return .unrecognized }
        if host == RecmanURLPolicy.archiveHost, components.path == RecmanURLPolicy.archivePath, facts.hasArchiveForm {
            return .archive
        }
        let isLoginHost = loginHosts.contains(host)
        if facts.hasAutomaticRedirectForm {
            return .transit(patience: autoSubmitPatience, ifStill: isLoginHost ? .needsUser : .unrecognized)
        }
        if facts.asksForCredentials { return .needsUser }
        // The notice Polimi shows before two-factor authentication: it waits for a click.
        if isLoginHost, components.path.hasSuffix("/AvvisiDFA.do") { return .needsUser }
        return .transit(patience: stillPatience, ifStill: isLoginHost ? .needsUser : .unrecognized)
    }

    /// polimi.it itself or any of its subdomains, never a lookalike such as "evilpolimi.it".
    public static func isPolimiHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "polimi.it" || host.hasSuffix(".polimi.it")
    }
}
