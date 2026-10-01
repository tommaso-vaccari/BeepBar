import Foundation

/// The network the Mac is on, as far as "Risparmio dati" (Data Saver) cares. Read once at the
/// start of an automatic run (see `NetworkPathReader`), never watched.
public struct NetworkPathConditions: Sendable, Equatable {
    /// Whether there is a usable network at all. An unusable one is never treated as a reason to
    /// pause: a real outage must keep showing as one ("Connessione assente").
    public var isSatisfied: Bool
    /// A phone hotspot or another network macOS treats as paid by the amount used.
    public var isExpensive: Bool
    /// A network with Low Data Mode ("Modalità dati ridotti") turned on.
    public var isConstrained: Bool

    public init(isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// An ordinary Wi-Fi or wired network with no data limits.
    public static let unrestricted = NetworkPathConditions(isSatisfied: true, isExpensive: false, isConstrained: false)
    public static let hotspot = NetworkPathConditions(isSatisfied: true, isExpensive: true, isConstrained: false)
    public static let lowDataMode = NetworkPathConditions(isSatisfied: true, isExpensive: false, isConstrained: true)
    public static let offline = NetworkPathConditions(isSatisfied: false, isExpensive: false, isConstrained: false)
}

/// Why Data Saver is holding automatic sync back. The two causes are told apart because the user
/// fixes them differently: leaving a hotspot, or turning Low Data Mode off on a Wi-Fi network.
/// Telling a user on Wi-Fi that BeepBar is "waiting for Wi-Fi" would be wrong.
public enum DataSaverPause: Sendable, Equatable {
    case hotspot
    case lowDataMode
}

/// What a scheduled automatic run does once it fires.
public enum AutomaticSyncDecision: Sendable, Equatable {
    case run
    /// Low Power Mode: retried later by the scheduler, whatever Data Saver says.
    case deferForLowPowerMode
    /// Another sync, a course refresh or a folder operation is running.
    case deferWhileBusy
    /// Nothing to sync with yet (no account, no folder, blocked recovery): not a reason to retry soon.
    case skipUnconfigured
    /// Data Saver is on and the Mac is on a hotspot or a Low Data Mode network.
    case pause(DataSaverPause)
}

/// The decision behind `runAutomaticSync`, kept pure so every combination is testable. The order
/// matters: Low Power Mode and a busy app defer before anything else; an app that cannot sync at
/// all is never shown as "paused", since the real problem (sign in, choose a folder) must stay in
/// front; only then does Data Saver look at the network.
public enum AutomaticSyncPolicy {
    public static func decision(lowPowerMode: Bool, busy: Bool, configured: Bool, dataSaverEnabled: Bool, network: NetworkPathConditions?) -> AutomaticSyncDecision {
        if lowPowerMode { return .deferForLowPowerMode }
        if busy { return .deferWhileBusy }
        if !configured { return .skipUnconfigured }
        if dataSaverEnabled, let pause = dataSaverPause(for: network) { return .pause(pause) }
        return .run
    }

    /// Why Data Saver would hold a run back on `network`, or `nil` if it would not. A hotspot is
    /// reported before Low Data Mode, since a phone hotspot often has both and "hotspot" is the
    /// cause the user recognises. An unknown or unusable network never pauses: the run goes ahead,
    /// the per-request limits in `NetworkAccess.dataSaver` still apply, and a real outage shows
    /// as one.
    public static func dataSaverPause(for network: NetworkPathConditions?) -> DataSaverPause? {
        guard let network, network.isSatisfied else { return nil }
        if network.isExpensive { return .hotspot }
        if network.isConstrained { return .lowDataMode }
        return nil
    }
}
