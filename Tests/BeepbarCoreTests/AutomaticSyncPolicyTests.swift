import Testing
@testable import BeepbarCore

/// What a scheduled automatic run does, for every input that matters. "Risparmio dati" may only
/// hold back a run that could otherwise go ahead, on a network that actually limits data.
struct AutomaticSyncPolicyTests {
    /// Proves the order of the checks. Guards against Data Saver hiding a more important state: a
    /// "paused" app that is really signed out, or a run sent while Low Power Mode is on.
    @Test(arguments: [
        // Low Power Mode defers first, whatever else is true.
        (true, false, true, true, NetworkPathConditions?.some(.hotspot), AutomaticSyncDecision.deferForLowPowerMode),
        (true, true, false, false, .unrestricted, .deferForLowPowerMode),
        // A busy app defers before Data Saver looks at the network.
        (false, true, true, true, .hotspot, .deferWhileBusy),
        // An app that cannot sync is never shown as paused.
        (false, false, false, true, .hotspot, .skipUnconfigured),
        (false, false, false, false, .unrestricted, .skipUnconfigured),
        // Data Saver on: a hotspot or Low Data Mode pauses, anything else runs.
        (false, false, true, true, .hotspot, .pause(.hotspot)),
        (false, false, true, true, .lowDataMode, .pause(.lowDataMode)),
        (false, false, true, true, .unrestricted, .run),
        (false, false, true, true, .offline, .run),
        (false, false, true, true, nil, .run),
        // Data Saver off (the default): every network runs.
        (false, false, true, false, .hotspot, .run),
        (false, false, true, false, .lowDataMode, .run),
        (false, false, true, false, .unrestricted, .run)
    ])
    func decides(_ lowPowerMode: Bool, _ busy: Bool, _ configured: Bool, _ dataSaver: Bool, _ network: NetworkPathConditions?, _ expected: AutomaticSyncDecision) {
        #expect(AutomaticSyncPolicy.decision(lowPowerMode: lowPowerMode, busy: busy, configured: configured, dataSaverEnabled: dataSaver, network: network) == expected)
    }

    /// Proves which networks count as limited. An outage or an unknown network must never read as
    /// a pause, or a real "Connessione assente" would be hidden behind "In pausa"; a phone hotspot
    /// with Low Data Mode too is reported as a hotspot, the cause the user recognises and fixes.
    @Test(arguments: [
        (NetworkPathConditions?.some(.hotspot), DataSaverPause?.some(.hotspot)),
        (.lowDataMode, .lowDataMode),
        (NetworkPathConditions(isSatisfied: true, isExpensive: true, isConstrained: true), .hotspot),
        (.unrestricted, nil),
        (.offline, nil),
        (NetworkPathConditions(isSatisfied: false, isExpensive: true, isConstrained: true), nil),
        (nil, nil)
    ])
    func classifiesTheNetwork(_ network: NetworkPathConditions?, _ expected: DataSaverPause?) {
        #expect(AutomaticSyncPolicy.dataSaverPause(for: network) == expected)
    }

    /// Proves the request limits behind each choice: only Data Saver keeps downloads off a hotspot
    /// and Low Data Mode. Guards against the two values drifting, which would either spend the
    /// user's data or bring back the false "Connessione assente" with the switch off.
    @Test func networkAccessLimitsOnlyWithDataSaver() {
        #expect(NetworkAccess.unrestricted.allowsExpensiveNetworkAccess)
        #expect(NetworkAccess.unrestricted.allowsConstrainedNetworkAccess)
        #expect(!NetworkAccess.dataSaver.allowsExpensiveNetworkAccess)
        #expect(!NetworkAccess.dataSaver.allowsConstrainedNetworkAccess)
    }
}
