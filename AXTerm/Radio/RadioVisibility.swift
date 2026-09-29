import Foundation

/// Which stations are drawn when the operator has switched radios off in the
/// sidebar.
///
/// A rule, not a service: it reads two values and returns a Bool, so the map,
/// the station list and the tests can all ask the same question without
/// standing up a `PacketEngine` to ask it. That matters beyond tidiness — the
/// engine's initialiser opens a database and reads the defaults domain, and a
/// test that only wants to know whether a dot is drawn should not be sharing
/// state with every other test that happens to build one.
nonisolated enum RadioVisibility {

    /// A station is hidden only when **every** radio that heard it is hidden.
    ///
    /// Hiding a radio hides that radio's traffic, not the stations themselves:
    /// one station heard on two radios stays one dot on the map while either
    /// is shown, because it is one station and the map draws stations, not
    /// receptions.
    ///
    /// - Parameter heardOn: the radios that have heard this station. Empty for
    ///   a station stored before radios existed, which is treated as the
    ///   primary's — that is where it was heard, the row simply predates
    ///   anywhere to record it.
    static func isVisible(heardOn: [RadioID], hidden: Set<RadioID>) -> Bool {
        guard !hidden.isEmpty else { return true }
        let radios = heardOn.isEmpty ? [RadioID.primary] : heardOn
        return radios.contains { !hidden.contains($0) }
    }

    static func isVisible(_ station: Station, hidden: Set<RadioID>) -> Bool {
        isVisible(heardOn: station.heardOn, hidden: hidden)
    }
}
