//
//  NetRomAutoTry.swift
//  AXTerm
//
//  "Auto try": when the best-known route to a destination will not come
//  up, attempt the next-best rather than reporting failure.
//
//  This is the piece the learned routing table was always for. AXTerm
//  has learned who-can-reach-whom from NODES broadcasts and overheard
//  traffic for a long time; until now nothing *acted* on more than the
//  single best entry, so one refusing node ended the attempt even when
//  the table held two other ways to the same station.
//
//  The policy is kept separate from the driver, and pure where it can
//  be, because "should we try again, and with what" is a judgement worth
//  testing on its own — and because retrying on the air is not free.
//  a refusal from the far node is an *answer*, not a path failure, and
//  is treated differently from silence.
//

import Foundation

nonisolated enum NetRomAutoTryPolicy {

    /// What a finished attempt means for the next one.
    enum Verdict: Equatable {
        /// Try the next hop — this one could not carry the circuit.
        case tryNext
        /// Stop. The destination answered, or the operator ended it, and
        /// trying another hop would be talking past a real answer.
        case stop(String)
    }

    /// Decide whether a failed attempt justifies trying another hop.
    ///
    /// The distinction that matters: **the path failed** vs **the
    /// station answered**. A node that refuses us has been reached — its
    /// answer is "no", and asking again through a different neighbor is
    /// not persistence, it is nagging a station that already replied.
    /// A timeout or a dead link is the path failing, and the whole point
    /// of a routing table is that there may be another one.
    static func verdict(for reason: NetRomDisconnectReason) -> Verdict {
        switch reason {
        case .timedOut:
            return .tryNext
        case .transportFailure:
            return .tryNext
        case .refused:
            // The far node replied. Respect it.
            return .stop("refused the connection")
        case .protocolError(let detail):
            return .stop("broke protocol: \(detail)")
        case .remoteRequest:
            return .stop("closed the connection")
        case .localRequest:
            return .stop("closed locally")
        case .reset:
            return .stop("reset the connection")
        }
    }

    /// Operator-facing summary once every hop has been tried.
    static func exhaustedText(destination: String, attempted: [String]) -> String {
        switch attempted.count {
        case 0:
            return "No NET/ROM route to \(destination). "
                + "This station has not heard a node advertise it."
        case 1:
            return "Could not reach \(destination) through \(attempted[0]), "
                + "and this station knows no other way there."
        default:
            return "Could not reach \(destination). Tried "
                + attempted.joined(separator: ", ") + " — every route this station knows."
        }
    }
}

/// Runs one auto-try campaign: open a circuit to a destination, walking
/// the candidate hops in order until one comes up or all are spent.
///
/// One campaign per destination at a time — the driver enforces that.
/// Deliberately not a retry *loop* over the same hop: T1/N2 inside the
/// circuit already does that, and doubling it up would key the
/// transmitter far more than the network deserves.
/// `nonisolated` like the rest of the NET/ROM engine: plain state, driven
/// from the main thread by convention, and no isolated deinit (see
/// [[axterm-mainactor-default-isolation]]).
nonisolated final class NetRomAutoTryCampaign {

    let destination: AX25Address
    private(set) var remainingHops: [AX25Address]
    private(set) var attemptedHops: [AX25Address] = []
    private(set) var activeCircuit: NetRomCircuitID?
    private(set) var isFinished = false

    init(destination: AX25Address, hops: [AX25Address]) {
        self.destination = destination
        self.remainingHops = hops
    }

    var attemptedDisplay: [String] { attemptedHops.map(\.display) }

    /// The next hop to attempt, or nil when the campaign is spent.
    func nextHop() -> AX25Address? {
        guard !isFinished, !remainingHops.isEmpty else { return nil }
        let hop = remainingHops.removeFirst()
        attemptedHops.append(hop)
        return hop
    }

    func noteAttemptStarted(circuit: NetRomCircuitID) {
        activeCircuit = circuit
    }

    func finish() {
        isFinished = true
        activeCircuit = nil
        remainingHops.removeAll()
    }
}
