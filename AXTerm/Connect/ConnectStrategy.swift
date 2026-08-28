//
//  ConnectStrategy.swift
//  AXTerm
//
//  The vocabulary for cross-family connect planning: every way this station
//  knows to reach a destination, ranked by evidence, each carrying the WHY.
//
//  This exists because the old shape chose a *mode* first and ranked only
//  within it — direct AX.25 had an empty auto-plan, and the node-prompt
//  relay was an unrankable fallback buried inside the NET/ROM path. The
//  operator's ask is simpler than any of that: "connect to this station,
//  you figure out how." Answering it takes a plan that can compare a fresh
//  direct sighting against a scraped route against a teller chain — and can
//  say, in one line, why each attempt is being made.
//

import Foundation

/// One family of ways to reach a station.
nonisolated enum ConnectStrategyKind: Equatable, Hashable {
    /// Plain L2 SABM, no digis — for a station heard direct recently.
    case directL2
    /// L2 through a digi path the evidence suggests.
    case ax25ViaDigis([String])
    /// A native NET/ROM circuit, optionally pinned to one next hop.
    case netromCircuit(nextHopOverride: String?)
    /// Drive node command prompts (`C <call>`) hop by hop. Works through
    /// KA-Nodes and BPQ alike — the workhorse on NODES-silent channels.
    case nodePromptRelay(teller: String?)

    /// Deterministic ordering between equal scores only — the real order is
    /// evidence-driven per plan. Cheapest-to-try first.
    var familyRank: Int {
        switch self {
        case .directL2: return 0
        case .ax25ViaDigis: return 1
        case .netromCircuit: return 2
        case .nodePromptRelay: return 3
        }
    }

    /// Stable key for tie-breaking and deduplication.
    var canonicalKey: String {
        switch self {
        case .directL2: return "direct"
        case .ax25ViaDigis(let digis): return "digis:" + digis.joined(separator: ",")
        case .netromCircuit(let override): return "netrom:" + (override ?? "")
        case .nodePromptRelay(let teller): return "relay:" + (teller ?? "")
        }
    }

    var familyLabel: String {
        switch self {
        case .directL2: return "direct"
        case .ax25ViaDigis: return "digi path"
        case .netromCircuit: return "native circuit"
        case .nodePromptRelay: return "node relay"
        }
    }
}

/// Where a strategy's evidence came from, and how old it is.
nonisolated struct ConnectStrategyProvenance: Equatable {
    enum Source: Equatable {
        case heardDirect
        case digiPath(ConnectSuggestions.DigiPath.Source)
        /// A candidate route, by its trust tier string ("broadcast",
        /// "harvested", "inferred") — see NetRomRouter.sourceTier.
        case route(sourceType: String)
        case directoryClaim(teller: String)
    }

    let source: Source
    /// Seconds since the evidence was last observed; nil = undated.
    let evidenceAge: TimeInterval?
}

/// One rung of the ladder.
nonisolated struct ConnectStrategyStep: Equatable {
    let kind: ConnectStrategyKind
    let score: Double
    let provenance: ConnectStrategyProvenance
    /// The one-line WHY shown in the transcript, built at plan time so it is
    /// pure and pinned by tests.
    let reason: String
    /// Seconds this rung may spend before the ladder moves on.
    let budget: TimeInterval
}

/// The full plan: rungs to try in order, and the families that had no
/// usable evidence — each with the reason, so silence is never the answer.
nonisolated struct ConnectStrategyLadder: Equatable {
    struct Skipped: Equatable {
        let familyLabel: String
        let reason: String
    }

    let destination: String
    let steps: [ConnectStrategyStep]
    let skipped: [Skipped]

    var isEmpty: Bool { steps.isEmpty }
}

/// Whether a rung's failure ends the ladder or falls through to the next.
nonisolated enum ConnectStrategyAdvancePolicy {
    enum Verdict: Equatable {
        case fallThrough
        case stopLadder(String)
    }

    /// A refusal is an answer, not a path failure (the same philosophy as
    /// NetRomAutoTryPolicy): the station replied, and trying a different
    /// family after "no" is nagging. Timeouts and dead paths fall through.
    /// `.unavailable` also falls through — one family's "no route" says
    /// nothing about another family's chances, which is exactly where this
    /// differs from the single-family runner.
    static func verdict(after result: ConnectAttemptStepResult) -> Verdict {
        switch result {
        case .refused(let detail):
            return .stopLadder(detail)
        case .failed, .timeout, .unavailable:
            return .fallThrough
        case .success, .cancelled:
            // The runner acts on these before consulting the policy; a
            // fall-through here is inert and keeps the switch total.
            return .fallThrough
        }
    }
}
