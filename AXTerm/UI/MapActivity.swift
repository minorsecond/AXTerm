import Foundation

/// Which stations transmitted just now, for the map to mark.
///
/// **"Currently transmitting" is not observable, and this does not pretend
/// otherwise.** A packet burst is over in a fraction of a second; by the time
/// a frame is decoded the station has long stopped keying. What the receiver
/// actually knows is *when it last heard someone*, so the honest indicator is
/// "transmitted within the last few seconds" — recent enough that the operator
/// watching the map is seeing the channel live, short enough that it clears
/// on its own and never becomes a second staleness scale competing with the
/// dot's own recency fade.
///
/// The window is deliberately short. Recency across minutes and hours is
/// already carried by opacity (fresh solid → old faded); this answers a
/// different question — "who is on the air right now" — and a long window
/// would blur the two into one mush where most of the map is always "active".
nonisolated enum MapActivity {

    /// How long a station stays marked after a frame from it.
    ///
    /// Fifteen seconds: long enough to still be lit when the operator's eye
    /// reaches the map after a burst, short enough that on a busy channel
    /// (the local one runs a frame every few seconds from a dozen stations)
    /// only a handful are lit at once. Longer and the marking stops meaning
    /// "now".
    static let window: TimeInterval = 15

    /// Whether a station counts as having just transmitted.
    static func isActive(lastHeard: Date?, now: Date, window: TimeInterval = window) -> Bool {
        guard let lastHeard else { return false }
        let age = now.timeIntervalSince(lastHeard)
        // A future timestamp is a clock skew between us and the log, not a
        // transmission that has not happened yet; treat it as just now rather
        // than letting a negative age fall outside the window.
        return age <= window && age > -window
    }

    /// The ids of the sites that just transmitted.
    static func activeIDs(_ sites: [StationScope.Site], now: Date,
                          window: TimeInterval = window) -> Set<String> {
        var active: Set<String> = []
        for site in sites where isActive(lastHeard: site.lastHeard, now: now, window: window) {
            active.insert(site.id)
        }
        return active
    }
}


/// The token that tells a deliberate change from arriving traffic.
///
/// The map batches structural changes — markers appearing and departing — so
/// that a busy channel does not make the whole layer resettle several times a
/// second. That batching must not apply to something the operator just
/// switched: a toggle that changes nothing for several seconds and then
/// applies in a lurch reads as a broken toggle, which is exactly how hiding a
/// radio behaved (the markers stayed until something else forced a pass).
///
/// So everything the operator can switch that changes *which markers exist*
/// belongs in this token, and nothing that merely arrives does.
nonisolated enum MapLayerGeneration {

    /// - Parameter switches: the layer toggles, in a fixed order.
    /// - Parameter hiddenRadios: the radios switched off in the sidebar.
    ///   Hiding one removes every marker only that radio heard, which is a
    ///   change to which markers exist and was the one such switch missing
    ///   from this token.
    static func token(switches: [Bool],
                      trackWindowMinutes: Int,
                      falloffMinutes: Int,
                      hiddenRadios: Set<RadioID>) -> String {
        switches.map { $0 ? "1" : "0" }.joined()
            + "|\(trackWindowMinutes)|\(falloffMinutes)"
            + "|\(hiddenRadios.map(\.rawValue).sorted().joined(separator: ","))"
    }

    /// The part of the signature that covers objects *this station* placed.
    ///
    /// The annotation throttle exists to absorb packet-rate churn, and a
    /// stranger's object is exactly that — it waits its turn with everything
    /// arriving. An object we just transmitted is not churn: the operator
    /// pressed Transmit and then watched nothing happen for up to ten seconds,
    /// which is the same silence the pending-transmission work exists to
    /// remove.
    ///
    /// Position and symbol are in the token as well as the name, so a move and
    /// a corrected symbol land as promptly as a first placement. Sorted, so
    /// dictionary order in the store cannot make an unchanged map look
    /// changed and defeat the throttle on every pass.
    static func ownObjectToken(_ objects: [APRSObjectStore.Placed],
                               ours: Set<String>) -> String {
        let mine = Set(ours.map { $0.uppercased() })
        return objects
            .filter { mine.contains($0.reportedBy.uppercased()) }
            .map { "\($0.report.key)@\($0.report.latitude),\($0.report.longitude)"
                 + "\($0.report.symbolTable)\($0.report.symbolCode)" }
            .sorted()
            .joined(separator: ";")
    }
}
