//
//  PersonalBBSListener.swift
//  AXTerm
//
//  Decides whether an inbound AX.25 connection is answered by the mailbox.
//

import Foundation

/// Whether an inbound call gets a mailbox prompt.
///
/// Answering is **off by default and explicitly armed**, for the same reason
/// `WinlinkP2PListener` is: an armed mailbox accepts callers and transmits in
/// reply with nobody present, which is automatic control. That is a decision
/// the operator makes, not one the app makes for them by shipping it on.
///
/// The policy lives here, apart from the transport and the shell, so it can be
/// tested without a radio.
nonisolated struct PersonalBBSListener {

    /// Why a call was or was not answered. Every refusal is explainable — a
    /// station that silently ignores callers is indistinguishable from a
    /// broken one, and the operator is the person who has to tell them apart.
    enum Decision: Equatable, Sendable {
        case answer
        /// We placed this call; it is not an inbound session at all.
        case weInitiated
        /// The operator has not armed the mailbox.
        case notArmed
        /// Winlink P2P answers on this same address.
        ///
        /// Not a general conflict: Winlink P2P and a mailbox are different
        /// services, and a node runs both at once by giving each its own
        /// callsign — which is how packet radio has always told services
        /// apart. They collide only when both answer the address that was
        /// dialed, and then neither can tell what the caller wanted, because
        /// the answering station speaks first in both protocols.
        case addressSharedWithWinlink(address: String)
        /// Another of the operator's devices already holds this callsign on
        /// this TNC. Answering would put two stations on one address.
        case identityContested(holder: String)
        /// The call was not addressed to the callsign we answer on.
        case wrongCallsign(called: String, expected: String)
        /// Someone is already using the mailbox — one radio, one caller.
        case busy(caller: String)

        var isAnswer: Bool { self == .answer }
    }

    /// Armed by the operator, off by default.
    var isArmed: Bool
    /// The address Winlink P2P answers on, or nil when it is not armed.
    var winlinkP2PAddress: String?
    /// The callsign (with SSID) the mailbox answers on.
    var myCallsign: String
    /// Set when another of the operator's devices holds this callsign on this
    /// TNC — see `StationIdentityLease`. Named rather than boolean so the
    /// refusal can say which device.
    var contestedBy: String?
    /// The caller already being served, if any.
    var currentCaller: String?

    /// - Parameters:
    ///   - called: the destination address of the inbound connection — what
    ///     the caller actually asked for.
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
        guard Self.answers(actual, as: expected) else {
            return .wrongCallsign(called: actual, expected: expected)
        }

        // Checked only after we know the call is ours, and only against the
        // address actually dialed: two services on one radio are normal, and
        // giving the mailbox its own SSID separates them completely.
        if let winlinkP2PAddress {
            let winlink = winlinkP2PAddress.trimmingCharacters(in: .whitespaces).uppercased()
            if Self.answers(actual, as: winlink) {
                return .addressSharedWithWinlink(address: winlink)
            }
        }

        // One caller at a time. This is not only channel courtesy: the shell
        // predicts the next message number when it says "Message 12 stored",
        // which is only sound while nothing else can take that number first.
        if let currentCaller { return .busy(caller: currentCaller) }
        return .answer
    }

    /// Whether a station configured as `configured` answers a call to `called`.
    ///
    /// A bare callsign answers on any SSID of itself; a callsign with an SSID
    /// answers only on that exact one. Otherwise a mailbox configured as
    /// K0EPI-2 would hijack calls meant for the node on K0EPI-7.
    static func answers(_ called: String, as configured: String) -> Bool {
        let expected = configured.trimmingCharacters(in: .whitespaces).uppercased()
        let actual = called.trimmingCharacters(in: .whitespaces).uppercased()
        guard !expected.isEmpty else { return false }
        return expected.contains("-")
            ? actual == expected
            : actual == expected || actual.hasPrefix(expected + "-")
    }
}

extension PersonalBBSListener.Decision {

    /// Log-ready explanation, shown in the mailbox activity log so a missed
    /// call is diagnosable after the fact.
    var explanation: String {
        switch self {
        case .answer:
            "answering"
        case .weInitiated:
            "outbound call — not a mailbox session"
        case .notArmed:
            "ignored — the mailbox is not on air (Settings → BBS)"
        case .addressSharedWithWinlink(let address):
            "ignored — Winlink P2P also answers as \(address). Give the mailbox "
            + "its own SSID (Settings → BBS) and both can run at once."
        case .identityContested(let holder):
            "ignored — \(holder) already holds this callsign on this TNC"
        case .wrongCallsign(let called, let expected):
            "ignored — called \(called), mailbox answers as \(expected)"
        case .busy(let caller):
            "refused — already serving \(caller)"
        }
    }
}
