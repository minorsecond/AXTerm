import Foundation

/// How this station presents itself as a NET/ROM node when it has more
/// than one radio. With one radio the two are the same thing.
nonisolated enum NetRomNodeIdentity: String, Codable, CaseIterable, Sendable {
    /// One node, announced on every radio — BPQ's NODECALL over several
    /// PORTCALLs. The node callsign and alias are the station's; each
    /// radio's NODES frame leaves under that radio's own L2 callsign, and a
    /// connect request for the node is accepted on any radio.
    case unified
    /// One node per radio: each radio's callsign is its own node with its
    /// own alias, and each radio announces only itself. The two nodes
    /// cannot reach each other through this station until L3 forwarding
    /// between radios exists, so an operator choosing this is choosing
    /// two separate nodes.
    case perRadio

    var title: String {
        switch self {
        case .unified: return "One node on every radio"
        case .perRadio: return "One node per radio"
        }
    }

    /// Why an operator would pick this, and what it costs.
    var explanation: String {
        switch self {
        case .unified:
            return "The station callsign and alias are the node, announced from every radio under that radio's own callsign — the way BPQ runs one node over several ports. Stations on either frequency reach the same node."
        case .perRadio:
            return "Each radio's callsign is its own node with its own alias. The nodes do not forward to each other, so a station on one frequency cannot reach the other through this station."
        }
    }
}
