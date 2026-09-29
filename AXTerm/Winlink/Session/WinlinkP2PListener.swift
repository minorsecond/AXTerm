import Foundation

/// Decides whether an inbound AX.25 connection should be answered as a
/// Winlink P2P mail session.
///
/// Answering is **off by default and explicitly armed**, because it is
/// not a neutral capability: an armed station accepts mail from anyone
/// who calls it, transmits in reply, and does so without the operator
/// present. That is exactly what you want during an activation and
/// exactly what you do not want the rest of the time, so the decision
/// stays the operator's.
///
/// The policy lives here, apart from the transport and the state
/// machine, so it can be tested without a radio.
nonisolated struct WinlinkP2PListener {

    /// Why an inbound call was or was not answered. Every refusal is
    /// explainable — a station that silently ignores callers is
    /// indistinguishable from a broken one.
    enum Decision: Equatable, Sendable {
        case answer
        /// The operator has not armed P2P.
        case notArmed
        /// The call was not addressed to the callsign we answer on.
        case wrongCallsign(called: String, expected: String)
        /// We placed this call; it is not an inbound session at all.
        case weInitiated
        /// A mail exchange is already running — one radio, one session.
        case busy
        /// Another of the operator's devices is already using this callsign
        /// on this TNC. Answering would put two stations on the same address
        /// replying to the same caller.
        case identityContested(holder: String)
    }

    /// Armed by the operator, off by default.
    var isArmed: Bool
    /// The callsign (with SSID) this station answers Winlink calls on.
    var myCallsign: String
    /// True while an exchange is already in progress.
    var isExchangeRunning: Bool
    /// Set when another of the operator's devices holds this callsign on this
    /// TNC — see `StationIdentityLease`. Named rather than boolean so the
    /// refusal can say which device.
    var contestedBy: String?

    /// - Parameters:
    ///   - called: the destination address of the inbound connection —
    ///     what the caller actually asked for.
    ///   - isInitiator: true when *we* placed the call.
    func decide(called: String, isInitiator: Bool) -> Decision {
        if isInitiator { return .weInitiated }
        guard isArmed else { return .notArmed }

        // Checked before the callsign match, not after: if a second device is
        // already answering as this callsign, the fact that the call *does*
        // match ours is precisely the problem. Both would answer.
        if let contestedBy { return .identityContested(holder: contestedBy) }

        let expected = myCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        let actual = called.trimmingCharacters(in: .whitespaces).uppercased()
        // A bare callsign answers on any SSID of itself; a callsign with
        // an SSID answers only on that exact one. Otherwise a station
        // configured as K0EPI-7 would hijack calls meant for the node on
        // K0EPI-1.
        let matches = expected.contains("-")
            ? actual == expected
            : actual == expected || actual.hasPrefix(expected + "-")
        guard matches else {
            return .wrongCallsign(called: actual, expected: expected)
        }

        // One radio, one session: answering while an exchange is running
        // would interleave two conversations on the same channel.
        guard !isExchangeRunning else { return .busy }
        return .answer
    }
}

extension WinlinkP2PListener.Decision {

    /// Log-ready explanation. Shown in the exchange console so a missed
    /// call is diagnosable after the fact.
    var explanation: String {
        switch self {
        case .answer:
            "answering"
        case .notArmed:
            "ignored — Winlink P2P is not armed (Settings → Winlink)"
        case .wrongCallsign(let called, let expected):
            "ignored — the call was to \(called), this station answers as \(expected)"
        case .identityContested(let holder):
            "ignored \u{2014} \(holder) is already answering as this callsign on this TNC. Two stations on one address would both reply to the caller."
        case .weInitiated:
            "not an inbound call"
        case .busy:
            "ignored — an exchange is already running"
        }
    }
}
