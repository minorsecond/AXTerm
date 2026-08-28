//
//  NetRomRelayProgress.swift
//  AXTerm
//
//  Which node a prompt relay is negotiating with right now, derived from
//  the phase the relay machinery already keeps. The phase's `remaining`
//  list shrinks as hops are made, so it alone cannot say which hops are
//  behind us — the planned chain supplies the fixed frame and the
//  remaining count locates the relay inside it.
//

import Foundation

/// Per-hop progress of a node-prompt relay, for display.
///
/// Purely derived — this holds no state of its own, so the picture can
/// never disagree with the relay's actual phase.
nonisolated enum NetRomRelayProgress {

    enum HopState: Equatable {
        /// This node answered and the chain has moved past it.
        case done
        /// The negotiation is here: waiting for this node's prompt, or for
        /// the node behind it to report this link made.
        case active
        /// Not reached yet.
        case pending
    }

    struct Hop: Equatable, Identifiable {
        let name: String
        let state: HopState
        /// Chain position, not name: a planner bug producing a duplicate
        /// name must not collapse two chips into one.
        let id: Int
    }

    /// Lays the relay's position over its planned chain.
    ///
    /// - Parameters:
    ///   - chain: the planned node chain, link target first (`Plan.chain`).
    ///   - destination: the station past the last node.
    ///   - remainingCount: how many chain entries the relay still has to
    ///     drive prompts for (`NetRomRelayPhase`'s `remaining`).
    ///   - askInFlight: true in `.awaitingConnected` — a `C` command is out
    ///     and the *next* node is the one being negotiated toward, which is
    ///     where the operator's eye should be. In `.awaitingBanner` the
    ///     current node owes us its prompt and stays the active one.
    ///   - established: the circuit is up end to end.
    static func hops(
        chain: [String],
        destination: String,
        remainingCount: Int,
        askInFlight: Bool,
        established: Bool
    ) -> [Hop] {
        guard !chain.isEmpty else { return [] }
        let names = chain + [destination]
        if established {
            return names.enumerated().map { Hop(name: $1, state: .done, id: $0) }
        }
        let base = max(0, chain.count - 1 - max(0, remainingCount))
        let active = min(askInFlight ? base + 1 : base, names.count - 1)
        return names.enumerated().map { index, name in
            Hop(name: name,
                state: index < active ? .done : (index == active ? .active : .pending),
                id: index)
        }
    }
}
