//
//  NetRomRelayPlan.swift
//  AXTerm
//
//  Working out the chain of nodes a terminal relay has to walk.
//
//  The relay drives a node's *command prompt*: connect, wait for the
//  banner, type `C <somewhere>`. Until now it modelled exactly one hop —
//  `us → node → destination` — and picked the node from whichever
//  station's table listed the destination.
//
//  That is not enough on this network, and the field capture of
//  2026-08-27 shows why. COSCO is listed by KB5YZB-7, so the relay dialled
//  KB5YZB-7 direct; the link came up and the node never greeted, three
//  separate times. What *did* work, by hand, was two hops:
//
//      C DRLNOD                      → ###CONNECTED TO NODE DRLNOD
//      C KB5YZB-7                    → ###LINK MADE, then YZBBPQ's banner
//      C COSCO                       → Connected to COSCO:KE0GB-7
//
//  The route table already held the missing piece — `KB5YZB-7 via DRLNOD`
//  — it was simply never consulted for the *relay's own* first hop. This
//  type joins the two sources: the alias directory says who lists the
//  destination, the route table says how to reach that station, and the
//  answer is an ordered chain of node prompts to drive.
//

import Foundation

nonisolated enum NetRomRelayPlan {

    /// A chain of node hops to walk, in order, before commanding the
    /// final destination.
    struct Plan: Equatable {
        /// The station to open the L2 link to. Always the first hop.
        let linkTarget: String
        /// Node prompts to drive after the link comes up, in order.
        /// Empty means the link target itself is asked for the
        /// destination — the classic one-hop relay.
        let intermediateHops: [String]
        /// The station the operator actually wants.
        let destination: String

        /// Every node in the chain, first to last.
        var chain: [String] { [linkTarget] + intermediateHops }

        /// One line naming the whole route, for the transcript.
        ///
        /// Says what the method *is*. This plan does not open a NET/ROM
        /// circuit — it connects to a node and types `C <somewhere>` at its
        /// command interpreter, once per hop. The operator who sees three
        /// node menus scroll past on the way to COSCO deserves to have been
        /// told that was going to happen, rather than reading "NET/ROM
        /// circuit" and having to work out from frame addresses why the
        /// packet menus are there (2026-08-27).
        var operatorSummary: String {
            let route = (chain + [destination]).joined(separator: " → ")
            let method = "Each node's own menus will appear below — this asks them at "
                + "their command prompts rather than opening a NET/ROM circuit."
            return intermediateHops.isEmpty
                ? "Asking \(linkTarget) to connect to \(destination). \(method)"
                : "Reaching \(destination) the long way: \(route). \(method)"
        }
    }

    /// Guard against a routing table that points in circles, and against
    /// spending the operator's airtime on an absurdly long chain.
    ///
    /// Four, because the field needs four: SOLBPQ sits behind
    /// DRLNOD → KB5YZB-7 → COSCO (walked live 2026-08-28 18:51), so a
    /// station SOLBPQ's own table lists needs SOLBPQ as a fourth chain
    /// node. Anything longer is past what the per-hop watchdogs can babysit
    /// inside the relay's ladder budget.
    static let maxChainLength = 4

    /// Build the chain to `destination` given the station that lists it.
    ///
    /// - Parameters:
    ///   - destination: what the operator asked for.
    ///   - teller: the station whose node table lists it — from the alias
    ///     directory. Nil when the destination is reached directly.
    ///   - routeLookup: station → the neighbour that reaches it, from the
    ///     NET/ROM route table (`bestRouteTo(_:)?.origin`).
    ///   - aliasResolve: node name → the callsign behind it. The route
    ///     table files routes by callsign, but a teller is usually a node
    ///     *name* — ASHCHT's teller is COSCO, and COSCO's route lives
    ///     under KE0GB-7. Without this the walk ended at the alias and the
    ///     relay dialled COSCO direct into silence (field capture
    ///     2026-08-28).
    static func plan(
        destination: String,
        teller: String?,
        routeLookup: (String) -> String?,
        aliasResolve: (String) -> String? = { _ in nil },
        maxChainLength: Int = NetRomRelayPlan.maxChainLength
    ) -> Plan {
        let target = normalize(destination)
        let start = teller.map(normalize) ?? target

        // Walk backwards from the teller: who reaches it, and who reaches
        // *them*, until we hit a station the route table says nothing
        // more about — that one we can dial ourselves.
        var chain = [start]
        var seen: Set<String> = [start, target]
        var cursor = start

        while chain.count < max(1, maxChainLength) {
            let resolved = routeLookup(cursor)
                ?? aliasResolve(cursor).flatMap { routeLookup(normalize($0)) }
            guard let hopText = resolved, !hopText.isEmpty else { break }
            let hop = normalize(hopText)
            // A station that reaches itself is the end of the walk, not a
            // hop; so is one already in the chain (that would loop).
            guard hop != cursor, !seen.contains(hop) else { break }
            chain.insert(hop, at: 0)
            seen.insert(hop)
            cursor = hop
        }

        return Plan(
            linkTarget: chain[0],
            intermediateHops: Array(chain.dropFirst()),
            destination: target
        )
    }

    /// Picks the node to ask for a station when no measured route exists —
    /// hearsay, with the two lies filtered out.
    ///
    /// Never the station's own claim about itself: a banner harvested
    /// mid-relay reads as self-listing, and a self-claim ends the walk at a
    /// node we cannot hear. And never a claim credited to a node that
    /// cannot route NET/ROM — a KA-Node prints no node table, so a claim
    /// with one as teller is a mis-attribution, not knowledge. Field
    /// capture 2026-08-28 18:28: COSCO's banner rode the L2 link from
    /// DRLNOD, "DRLNOD lists COSCO" was recorded as the freshest claim,
    /// and the next plan asked a KA-Node for a station it cannot hear —
    /// KB5YZB-7, the node that genuinely lists COSCO, was sitting right
    /// behind it in the claim list.
    ///
    /// Unknown capability (nil) passes: refusing to guess is the
    /// classifier's discipline, and most tellers are unclassified.
    static func tellerFallback(
        for station: String,
        claims: [(teller: String, claimedAt: Date)],
        canRouteNetRom: (String) -> Bool?
    ) -> String? {
        let key = normalize(station)
        return claims.first {
            normalize($0.teller) != key && canRouteNetRom($0.teller) != false
        }?.teller
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).uppercased()
    }
}
