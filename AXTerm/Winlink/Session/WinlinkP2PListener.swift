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
        /// The running exchange is with this same caller, whose link was
        /// just reset by a second SABM. That exchange is ending with the old
        /// link; answer the new one once it has.
        case answerWhenFree
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
    /// The station the running exchange is with, when one is running.
    var runningExchangePeer: String?

    /// - Parameters:
    ///   - called: the destination address of the inbound connection —
    ///     what the caller actually asked for.
    ///   - isInitiator: true when *we* placed the call.
    ///   - caller: the station calling, used to tell a reset link from a
    ///     second caller while an exchange runs.
    func decide(called: String, isInitiator: Bool, caller: String? = nil) -> Decision {
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
        // would interleave two conversations on the same channel. The
        // exception is the caller the running exchange is with: a new link
        // from them means a SABM reset the old one (live test log, bug 40),
        // and the exchange on it is already ending.
        guard isExchangeRunning else { return .answer }
        if let caller, let running = runningExchangePeer,
           Self.normalized(caller) == Self.normalized(running) {
            return .answerWhenFree
        }
        return .busy
    }

    private static func normalized(_ callsign: String) -> String {
        callsign.trimmingCharacters(in: .whitespaces).uppercased()
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
            "ignored: Winlink P2P is not armed (Settings › Winlink)"
        case .wrongCallsign(let called, let expected):
            "ignored: the call was to \(called), this station answers as \(expected)"
        case .identityContested(let holder):
            "ignored: \(holder) is already answering as this callsign on this TNC. Two stations on one address would both reply to the caller."
        case .weInitiated:
            "not an inbound call"
        case .busy:
            "ignored: an exchange is already running"
        case .answerWhenFree:
            "the caller's link was reset; answering again once the exchange on the old link has closed"
        }
    }
}
