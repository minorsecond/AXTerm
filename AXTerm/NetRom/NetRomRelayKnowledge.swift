//
//  NetRomRelayKnowledge.swift
//  AXTerm
//
//  The knowledge the relay planner walks, gathered behind one door.
//
//  Chain planning consults four sources in a fixed order of trust: fresh
//  measured routes, stale measured routes (TTL-expired signposts — the relay
//  proves every hop live anyway), the alias directory's name↔callsign
//  mapping, and finally filtered hearsay ("who lists whom"). That order was
//  earned one field failure at a time (2026-08-27 through 2026-08-28), and
//  by the time it stabilized it lived in two copy-pasted closures in
//  TerminalView and a near-twin in the profile resolver — three places for
//  the next fix to miss one of.
//
//  This type is the single implementation. The relay call sites use
//  `routeLookup`; the pre-connect preview uses `plannedPath(to:)`, which
//  walks the *same* resolution while keeping each hop's evidence, so the
//  path the operator is shown and the path the relay drives are one
//  computation — the picture cannot promise what the walk will not do.
//

import Foundation

/// One node of a planned relay chain, with the reason it is there —
/// rendered as a tooltip, because CLAUDE.md's rule is that every derived
/// value explains its own derivation.
nonisolated struct PlannedRelayHop: Equatable, Identifiable, Sendable {
    let name: String
    let evidence: String
    var id: String { name }
}

// MainActor by the module default: the closures it holds reach into
// MainActor stores (router, alias directory, capability verdicts).
struct NetRomRelayKnowledge {

    /// `bestRouteTo(_:)?.origin` — TTL-filtered, hysteresis-arbitrated:
    /// the router's live answer.
    var freshRouteOrigin: (String) -> String?

    /// The best origin for a destination in the *unfiltered* route table.
    /// Receives an already-uppercased name.
    var anyRouteOrigin: (String) -> String?

    /// Node name → the callsign behind it (COSCO → KE0GB-7), from the
    /// alias directory.
    var aliasCallsign: (String) -> String?

    /// Who lists this station, newest first — the hearsay edges.
    var tellerClaims: (String) -> [(teller: String, claimedAt: Date)]

    /// Capability verdict for hearsay filtering: a KA-Node prints no node
    /// table, so a claim credited to one is mis-attribution.
    var canRouteNetRom: (String) -> Bool?

    /// The chain walk's lookup: who reaches `station`, best evidence first.
    /// Exactly the resolution `resolve(_:)` performs, with the evidence
    /// prose dropped.
    func routeLookup(_ station: String) -> String? {
        resolve(station)?.origin
    }

    /// The full answer: who reaches `station`, and how we know.
    ///
    /// Routes are filed by callsign, tellers by node *name* — COSCO's route
    /// lives under KE0GB-7 — so both names are tried against the route
    /// table before any hearsay. Fresh routes for either name beat stale
    /// routes for either, which beat claims; hearsay comes last and
    /// filtered, because a relay session can poison the directory (field
    /// captures 2026-08-28, 18:28 and 18:39).
    func resolve(_ station: String) -> (origin: String, evidence: String)? {
        let names = [station, aliasCallsign(station)]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        for name in names {
            if let origin = freshRouteOrigin(name) {
                return (origin, "A measured NET/ROM route reaches \(name) "
                        + "through \(origin.uppercased()).")
            }
        }
        for name in names {
            if let origin = anyRouteOrigin(name) {
                return (origin, "A measured route reaches \(name) through "
                        + "\(origin.uppercased()) — stale by TTL, but the relay "
                        + "proves every hop live before going further.")
            }
        }
        let key = station.trimmingCharacters(in: .whitespaces).uppercased()
        if let teller = NetRomRelayPlan.tellerFallback(
            for: key, claims: tellerClaims(key), canRouteNetRom: canRouteNetRom) {
            return (teller, "\(teller.uppercased()) lists \(key) in its node "
                    + "directory — hearsay until the hop is made.")
        }
        return nil
    }

    /// The chain a node-prompt relay would walk to `destination`, each hop
    /// carrying the evidence that put it there. Empty when nothing is known
    /// about the destination — which is itself the honest preview.
    /// How far the walk may chain. Defaults to the planner's own cap;
    /// builders set it from the operator's setting so the preview, the
    /// profile chain and the dial all obey the same budget.
    var maxChainLength: Int = NetRomRelayPlan.maxChainLength

    func plannedPath(to destination: String) -> [PlannedRelayHop] {
        let target = destination.trimmingCharacters(in: .whitespaces).uppercased()
        guard !target.isEmpty, let seed = resolve(target) else { return [] }
        var evidence = [seed.origin.uppercased(): seed.evidence]
        let plan = NetRomRelayPlan.plan(
            destination: target,
            teller: seed.origin,
            routeLookup: { station in
                guard let hit = resolve(station) else { return nil }
                evidence[hit.origin.uppercased()] = hit.evidence
                return hit.origin
            },
            aliasResolve: aliasCallsign,
            maxChainLength: maxChainLength)
        return plan.chain.map { name in
            PlannedRelayHop(
                name: name,
                evidence: evidence[name.uppercased()]
                    ?? "\(name) is listed as the way to \(target).")
        }
    }
}
