import Foundation

/// Deciding who actually said a line.
///
/// During a prompt relay every downstream node's words ride the link peer's
/// frames, so "which station sent this frame" is not the same question as
/// "which station is talking". Getting it wrong files one node's knowledge
/// under another's name, and the app then plans routes from it.
///
/// Field case 2026-08-31: once the chain to BBSCBH was up, COSCO's own
/// confirmation was credited to BBSCBH — a BBS at the end of the chain —
/// which then appeared in the sidebar as a node that reaches other nodes.
///
/// Evidence, best first: the line naming its own speaker, then the relay's
/// expectation of who should answer, then the station whose frames these are.
nonisolated enum RelaySpeaker {

    /// The callsign a BPQ prompt prefix names, when the line carries one.
    ///
    /// BPQ prefixes its output with `ALIAS:CALLSIGN}`. That is the station
    /// identifying itself, which beats anything inferred from which link the
    /// bytes arrived on.
    static func speaker(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // The prefix must open the line. A pair quoted mid-sentence is being
        // talked about, not talking.
        guard let brace = trimmed.firstIndex(of: "}") else { return nil }
        let head = trimmed[trimmed.startIndex..<brace]
        guard let colon = head.firstIndex(of: ":") else { return nil }
        // Requiring no spaces keeps prose with a colon out — "ENTER COMMAND:
        // B,C,J,N" has no brace, but "Gateway: 145.050" could otherwise
        // reach here on a line that has one elsewhere.
        guard !head.contains(" ") else { return nil }

        let callsign = String(head[head.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        // The callsign identifies the station; the alias is only a name for
        // it and may be shared or reused across the network.
        guard CallsignValidator.isValidRoutingNode(callsign) else { return nil }
        return callsign
    }

    /// Who to credit a line to.
    static func attribute(line: String, relayWaitingOn: String?, linkPeer: String) -> String {
        if let named = speaker(in: line) { return named }
        if let expected = relayWaitingOn, !expected.isEmpty { return expected.uppercased() }
        return linkPeer.uppercased()
    }
}
