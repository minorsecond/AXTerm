//
//  ConnectStrategyPlanner.swift
//  AXTerm
//
//  Given everything this station knows about reaching one destination,
//  produce the ladder: which families to try, in what order, and why.
//
//  Pure on purpose. The planner sees a value snapshot and returns a value
//  plan — no MainActor state, no clocks of its own — so every ranking
//  decision is pinned by a test with a sentence attached. Scoring uses
//  piecewise freshness bands rather than smooth decay because a band edge
//  is explainable ("heard within the last half hour") and deterministic
//  where a float curve invites flapping between near-equal rungs.
//

import Foundation

/// The snapshot the planner reads. Built on the MainActor by whoever owns
/// the stores; consumed here without touching any of them.
nonisolated struct ConnectStrategyEvidence {
    struct DirectSighting: Equatable {
        let lastHeard: Date
        /// The via path it was last heard over — empty means truly direct.
        let heardVia: [String]
    }

    struct TellerClaim: Equatable {
        let teller: String
        let claimedAt: Date?
    }

    let destination: String
    let now: Date
    var direct: DirectSighting?
    /// Digi-path candidates with the suggestion engine's scores intact —
    /// the engine already folds in the recent-failure penalty.
    var digiPaths: [ConnectSuggestions.DigiPath] = []
    /// Tier-ranked, TTL-filtered candidate routes (NetRomRouter).
    var candidateRoutes: [RouteInfo] = []
    /// Capability verdicts for route anchors; absent key = unknown.
    var capabilityByAnchor: [String: Bool] = [:]
    /// Nodes that list this destination, newest claim first.
    var tellers: [TellerClaim] = []
    /// True while the native-circuit negative cache is holding.
    var nativeCircuitCoolingDown: Bool = false
    /// Whether this station advertises itself — without it, a far node has
    /// no route home for the CONACK and native circuits usually die.
    var advertiseSelfEnabled: Bool = false
}

nonisolated enum ConnectStrategyPlanner {

    static let maxRungs = 4
    /// Whole-ladder wall-clock ceiling, budgets plus inter-rung backoffs.
    static let totalBudgetSeconds: TimeInterval = 180
    static let interRungBackoffSeconds: TimeInterval = 5

    // Budgets per family. Direct and digi attempts are bounded by how long
    // an unanswered SABM is worth waiting on; the native circuit matches
    // its existing grace; the relay needs L2 connect plus a hand-driven
    // handshake per hop.
    static let directBudget: TimeInterval = 25
    static let digiBudget: TimeInterval = 35
    static let netromBudget: TimeInterval = 30
    static let relayBudget: TimeInterval = 90

    static func plan(evidence: ConnectStrategyEvidence) -> ConnectStrategyLadder {
        var steps: [ConnectStrategyStep] = []
        var skipped: [ConnectStrategyLadder.Skipped] = []

        planDirect(evidence, into: &steps, skipped: &skipped)
        planDigis(evidence, into: &steps, skipped: &skipped)
        planNetRom(evidence, into: &steps, skipped: &skipped)
        planRelay(evidence, into: &steps, skipped: &skipped)

        steps.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.kind.familyRank != rhs.kind.familyRank {
                return lhs.kind.familyRank < rhs.kind.familyRank
            }
            return lhs.kind.canonicalKey < rhs.kind.canonicalKey
        }
        steps = Array(steps.prefix(maxRungs))

        // Trim lowest-scoring rungs until the worst-case wall clock fits.
        // The operator asked for a connection, not an afternoon.
        while steps.count > 1, wallClock(of: steps) > totalBudgetSeconds {
            steps.removeLast()
        }

        return ConnectStrategyLadder(
            destination: evidence.destination,
            steps: steps,
            skipped: skipped
        )
    }

    private static func wallClock(of steps: [ConnectStrategyStep]) -> TimeInterval {
        steps.map(\.budget).reduce(0, +)
            + interRungBackoffSeconds * TimeInterval(max(0, steps.count - 1))
    }

    // MARK: - Direct L2

    private static func planDirect(
        _ evidence: ConnectStrategyEvidence,
        into steps: inout [ConnectStrategyStep],
        skipped: inout [ConnectStrategyLadder.Skipped]
    ) {
        guard let direct = evidence.direct, direct.heardVia.isEmpty else {
            skipped.append(.init(
                familyLabel: "direct",
                reason: evidence.direct == nil
                    ? "never heard this station direct"
                    : "only heard it through digipeaters"))
            return
        }
        let age = evidence.now.timeIntervalSince(direct.lastHeard)
        let score: Double
        switch age {
        case ..<(30 * 60): score = 1.0
        case ..<(2 * 3600): score = 0.75
        case ..<(8 * 3600): score = 0.5
        default:
            skipped.append(.init(
                familyLabel: "direct",
                reason: "last direct sighting was \(ageText(age)) ago — too stale to bet a timeout on"))
            return
        }
        steps.append(ConnectStrategyStep(
            kind: .directL2,
            score: score,
            provenance: .init(source: .heardDirect, evidenceAge: age),
            reason: "Direct — heard \(ageText(age)) ago with no digis.",
            budget: directBudget))
    }

    // MARK: - Digi paths

    private static func planDigis(
        _ evidence: ConnectStrategyEvidence,
        into steps: inout [ConnectStrategyStep],
        skipped: inout [ConnectStrategyLadder.Skipped]
    ) {
        let usable = evidence.digiPaths.filter { !$0.digis.isEmpty }
        guard !usable.isEmpty else {
            skipped.append(.init(
                familyLabel: "digi path",
                reason: "no observed or previously successful path"))
            return
        }
        for path in usable.prefix(2) {
            steps.append(ConnectStrategyStep(
                kind: .ax25ViaDigis(path.digis),
                score: 0.9 * path.score,
                provenance: .init(source: .digiPath(path.source), evidenceAge: nil),
                reason: "Via \(path.digis.joined(separator: " → ")) — \(digiSourceText(path.source)).",
                budget: digiBudget))
        }
    }

    private static func digiSourceText(_ source: ConnectSuggestions.DigiPath.Source) -> String {
        switch source {
        case .routeDerived: return "derived from the best known route"
        case .observedForDestination: return "a path this station was actually heard over"
        case .historicalSuccess: return "a path that connected before"
        case .neighborStrong: return "through a strong nearby neighbor"
        }
    }

    // MARK: - Native NET/ROM circuit

    private static func planNetRom(
        _ evidence: ConnectStrategyEvidence,
        into steps: inout [ConnectStrategyStep],
        skipped: inout [ConnectStrategyLadder.Skipped]
    ) {
        guard !evidence.candidateRoutes.isEmpty else {
            skipped.append(.init(
                familyLabel: "native circuit",
                reason: "no NET/ROM route known for this station"))
            return
        }
        guard !evidence.nativeCircuitCoolingDown else {
            skipped.append(.init(
                familyLabel: "native circuit",
                reason: "a native circuit failed here recently — retrying after the hold expires"))
            return
        }
        // A route anchored on a proven non-router is not a route; if every
        // candidate hangs off one, the family has nothing to offer.
        let candidates = evidence.candidateRoutes.filter {
            evidence.capabilityByAnchor[$0.origin.uppercased()] != false
        }
        guard let best = candidates.first else {
            skipped.append(.init(
                familyLabel: "native circuit",
                reason: "every known route anchors on a node that cannot route NET/ROM"))
            return
        }

        let tierBase: Double
        switch best.sourceType {
        case "broadcast", "classic": tierBase = 0.9
        case "harvested": tierBase = 0.7
        default: tierBase = 0.55
        }
        let age = evidence.now.timeIntervalSince(best.lastUpdated)
        let freshness: Double
        switch age {
        case ..<(15 * 60): freshness = 1.0
        case ..<(2 * 3600): freshness = 0.9
        default: freshness = 0.75
        }
        var score = tierBase * freshness
        var caveats: [String] = []
        if evidence.capabilityByAnchor[best.origin.uppercased()] == nil {
            score *= 0.85
            caveats.append("\(best.origin)'s node software is unproven")
        }
        if !evidence.advertiseSelfEnabled {
            // Without self-advertisement the far node has no route home for
            // the CONACK; the rung stays worth one try, but a dampened one,
            // and the reason says what would fix it.
            score *= 0.6
            caveats.append("this station is not advertising itself, so the reply may have no route home — turn on Announce this station to fix that")
        }

        var reason = "NET/ROM circuit via \(best.origin) — \(routeSourceText(best.sourceType)) route, quality \(best.quality), \(ageText(age)) old."
        if !caveats.isEmpty {
            reason += " (" + caveats.joined(separator: "; ") + ".)"
        }
        steps.append(ConnectStrategyStep(
            kind: .netromCircuit(nextHopOverride: nil),
            score: score,
            provenance: .init(source: .route(sourceType: best.sourceType), evidenceAge: age),
            reason: reason,
            budget: netromBudget))
    }

    private static func routeSourceText(_ sourceType: String) -> String {
        switch sourceType {
        case "broadcast", "classic": return "a broadcast"
        case "harvested": return "a harvested"
        default: return "an inferred"
        }
    }

    // MARK: - Node-prompt relay

    private static func planRelay(
        _ evidence: ConnectStrategyEvidence,
        into steps: inout [ConnectStrategyStep],
        skipped: inout [ConnectStrategyLadder.Skipped]
    ) {
        guard let claim = evidence.tellers.first else {
            skipped.append(.init(
                familyLabel: "node relay",
                reason: "no node has listed this station"))
            return
        }
        var score: Double
        let age = claim.claimedAt.map { evidence.now.timeIntervalSince($0) }
        switch age {
        case .some(let seconds) where seconds < 3600: score = 0.8
        case .some(let seconds) where seconds < 24 * 3600: score = 0.65
        default: score = 0.5
        }
        // A measured route to the teller means the first leg is more than
        // hearsay — the chain starts on known ground.
        let tellerKey = claim.teller.uppercased()
        if evidence.candidateRoutes.contains(where: { $0.origin.uppercased() == tellerKey })
            || evidence.capabilityByAnchor[tellerKey] != nil {
            score += 0.1
        }

        let claimText = age.map { "it listed \(evidence.destination) \(ageText($0)) ago" }
            ?? "it has listed \(evidence.destination)"
        steps.append(ConnectStrategyStep(
            kind: .nodePromptRelay(teller: claim.teller),
            score: score,
            provenance: .init(source: .directoryClaim(teller: claim.teller), evidenceAge: age),
            reason: "Node-prompt relay via \(claim.teller) — \(claimText).",
            budget: relayBudget))
    }

    // MARK: - Age prose

    static func ageText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "moments"
        case ..<3600: return "\(Int(seconds / 60)) min"
        case ..<(48 * 3600): return "\(Int(seconds / 3600)) h"
        default: return "\(Int(seconds / 86_400)) days"
        }
    }
}
