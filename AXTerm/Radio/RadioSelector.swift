import Foundation

/// Picks the radio for a connect the operator left on Auto, and says why in
/// a sentence the connect bar shows verbatim.
///
/// The question is "which of my radios can reach the first hop right now?"
/// and the answer is read off the same per-radio evidence the Stations list
/// shows — when this radio last heard the station, and how the link to it
/// has been performing there — so the two can never disagree. Nothing here
/// is measured; it only ranks what the radios already know.
///
/// The tiers, in order: a radio that heard the first hop within its link's
/// TTL wins, best ETX first; failing that, whichever radio heard it most
/// recently; failing that, the radio a NET/ROM route to the destination was
/// learned on; failing that, the first connected radio in the operator's
/// list. Ties fall to the operator's ordering, so the same inputs always
/// pick the same radio.
nonisolated struct RadioSelector {

    /// What one radio knows about the first hop of a route.
    struct Evidence: Equatable {
        let radio: RadioID
        let name: String
        let connected: Bool
        /// When this radio last heard the first hop, if ever.
        let lastHeard: Date?
        /// Expected transmissions over this radio's link from the first hop,
        /// when there is enough evidence to say.
        let etx: Double?
        /// How long a hearing on this radio stays fresh.
        let ttl: TimeInterval

        init(radio: RadioID, name: String, connected: Bool, lastHeard: Date?, etx: Double?,
             ttl: TimeInterval = 3600) {
            self.radio = radio
            self.name = name
            self.connected = connected
            self.lastHeard = lastHeard
            self.etx = etx
            self.ttl = ttl
        }

        func isFresh(at now: Date) -> Bool {
            guard let lastHeard else { return false }
            return now.timeIntervalSince(lastHeard) <= ttl
        }
    }

    enum Reason: Equatable {
        /// There is nothing to choose between.
        case onlyRadio
        /// Heard the first hop within its TTL, with the best ETX.
        case freshEvidence
        /// Nobody has fresh evidence; this radio heard it most recently.
        case mostRecentlyHeard
        /// Never heard directly, but a NET/ROM route was learned here.
        case netRomRoute
        /// No evidence anywhere; first in the operator's list.
        case firstInList
        /// No radio is connected; the call will fail, but this is where.
        case nothingConnected
    }

    struct Choice: Equatable {
        let radio: RadioID
        let reason: Reason
        /// The whole argument, for the connect bar's help.
        let explanation: String
    }

    /// Two ETX estimates closer than this are the same; recency decides.
    static let etxTolerance = 0.05
    /// Where an unmeasured fresh link sorts: behind every measured one.
    private static let unmeasuredETX = 20.0

    /// - Parameters:
    ///   - firstHop: the station the SABM actually goes to — the first
    ///     digipeater, or the destination when there is none.
    ///   - radios: every enabled radio, in the operator's order.
    ///   - routeRadio: the radio a NET/ROM route to the destination was
    ///     learned on, when there is one.
    static func choose(firstHop: String, radios: [Evidence], routeRadio: RadioID?,
                       now: Date) -> Choice? {
        guard let first = radios.first else { return nil }
        if radios.count == 1 {
            return Choice(radio: first.radio, reason: .onlyRadio,
                          explanation: "Auto → \(first.name): the only radio.")
        }

        let connected = radios.filter(\.connected)
        guard !connected.isEmpty else {
            return Choice(radio: first.radio, reason: .nothingConnected,
                          explanation: "Auto → \(first.name): no radio is connected.")
        }

        let fresh = connected.filter { $0.isFresh(at: now) }
        if !fresh.isEmpty {
            let bestETX = fresh.map { $0.etx ?? unmeasuredETX }.min()!
            let contenders = fresh.filter { ($0.etx ?? unmeasuredETX) - bestETX < etxTolerance }
            // Most recent among equals; `max(by:)` keeps the first of a
            // tie, which is the operator's order.
            let chosen = contenders.enumerated().max { lhs, rhs in
                let l = lhs.element.lastHeard ?? .distantPast
                let r = rhs.element.lastHeard ?? .distantPast
                return l != r ? l < r : lhs.offset > rhs.offset
            }!.element
            return Choice(radio: chosen.radio, reason: .freshEvidence,
                          explanation: freshExplanation(chosen: chosen, firstHop: firstHop,
                                                        radios: radios, now: now))
        }

        let heard = connected.filter { $0.lastHeard != nil }
        if let recent = heard.enumerated().max(by: { lhs, rhs in
            let l = lhs.element.lastHeard!, r = rhs.element.lastHeard!
            return l != r ? l < r : lhs.offset > rhs.offset
        })?.element {
            let ago = Self.ago(now.timeIntervalSince(recent.lastHeard!))
            return Choice(radio: recent.radio, reason: .mostRecentlyHeard,
                          explanation: "Auto → \(recent.name): heard \(firstHop) there \(ago), past its TTL but the most recent of any radio.")
        }

        if let routeRadio, let viaRoute = connected.first(where: { $0.radio == routeRadio }) {
            return Choice(radio: viaRoute.radio, reason: .netRomRoute,
                          explanation: "Auto → \(viaRoute.name): no radio has heard \(firstHop) directly; a NET/ROM route to it was learned there.")
        }

        let fallback = connected[0]
        return Choice(radio: fallback.radio, reason: .firstInList,
                      explanation: "Auto → \(fallback.name): no radio has heard \(firstHop); \(fallback.name) is first in the radio list.")
    }

    private static func freshExplanation(chosen: Evidence, firstHop: String,
                                         radios: [Evidence], now: Date) -> String {
        var sentence = "Auto → \(chosen.name): heard \(firstHop) there \(ago(now.timeIntervalSince(chosen.lastHeard!)))"
        if let etx = chosen.etx { sentence += ", ETX \(etxText(etx))" }
        sentence += "."
        for other in radios where other.radio != chosen.radio {
            sentence += " " + describe(other, firstHop: firstHop, now: now)
        }
        return sentence
    }

    /// One clause about a radio that was not chosen.
    private static func describe(_ radio: Evidence, firstHop: String, now: Date) -> String {
        guard radio.connected else { return "\(radio.name) is not connected." }
        guard let lastHeard = radio.lastHeard else { return "\(radio.name) has never heard it." }
        let when = ago(now.timeIntervalSince(lastHeard))
        if radio.isFresh(at: now) {
            if let etx = radio.etx { return "\(radio.name) heard it \(when), ETX \(etxText(etx))." }
            return "\(radio.name) heard it \(when), link unmeasured."
        }
        return "\(radio.name) last heard it \(when), past its TTL."
    }

    static func etxText(_ etx: Double) -> String {
        String(format: "%.1f", etx)
    }

    /// Coarse and locale-free, so the sentence is the same in every log.
    static func ago(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }
}
