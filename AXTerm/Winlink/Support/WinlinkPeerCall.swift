//
//  WinlinkPeerCall.swift
//  AXTerm
//
//  Calling another station directly for peer-to-peer mail: which callsign
//  the operator meant, which one to suggest, and which queued mail belongs
//  in the exchange. See WinlinkPeerCallSheet.
//

import Foundation

nonisolated enum WinlinkPeerCall {

    /// The station to call, tidied up, or nil if `input` isn't a callsign
    /// or is the station's own.
    static func callsign(from input: String, myCallsign: String = "") -> String? {
        let call = CallsignValidator.normalize(input)
        guard CallsignValidator.isValid(call) else { return nil }
        guard call != CallsignValidator.normalize(myCallsign) else { return nil }
        return call
    }

    /// What the sheet fills in: the station last called, or else the first
    /// queued recipient that is a callsign, since peer-to-peer mail is
    /// usually addressed to the station it goes to. Empty if neither.
    static func suggestion(recentPeers: [String], outboxRecipients: [String]) -> String {
        if let last = recentPeers.first { return last }
        return outboxRecipients.lazy.compactMap(addressCallsign).first ?? ""
    }

    /// Whether `message` belongs in an exchange with `peer`.
    ///
    /// A peer delivers nothing onward to the CMS, so mail for anyone else
    /// handed to it would be marked sent and never arrive. A recipient
    /// matches when it is the peer's callsign exactly, or the peer's bare
    /// callsign (the Winlink account) when the peer listens on an SSID.
    static func isAddressed(_ message: WinlinkB2Message, to peer: String) -> Bool {
        let peer = CallsignValidator.normalize(peer)
        let base = peer.split(separator: "-").first.map(String.init) ?? peer
        return (message.to + message.cc).contains { address in
            guard let call = addressCallsign(address) else { return false }
            return call == peer || call == base
        }
    }

    /// The callsign in a Winlink address, "K0EPI-3" or "K0EPI-3@winlink.org",
    /// or nil for an internet address.
    private static func addressCallsign(_ address: String) -> String? {
        var call = CallsignValidator.normalize(address)
        if call.hasSuffix("@WINLINK.ORG") { call.removeLast("@WINLINK.ORG".count) }
        return CallsignValidator.isValid(call) ? call : nil
    }
}
