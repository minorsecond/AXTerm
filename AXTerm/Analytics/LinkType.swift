//
//  LinkType.swift
//  AXTerm
//
//  Defines relationship types for network graph edges.
//  See Docs/NetworkGraphSemantics.md for full documentation.
//

import Foundation

/// Relationship type for edges in the network graph.
///
/// The graph distinguishes three types of connections to help users understand
/// what kind of communication is occurring:
///
/// - **DirectPeer**: Confirmed endpoint-to-endpoint packet exchange
/// - **HeardDirect**: Likely direct RF reception (no digipeaters in path)
/// - **HeardVia**: Observed only through digipeater paths
///
/// This classification prevents users from incorrectly inferring RF reachability
/// from digipeater-mediated traffic.
enum LinkType: String, Hashable, Sendable, CaseIterable {
    /// Confirmed endpoint-to-endpoint packet exchange.
    /// Both stations appear as from/to in packets without intermediate digipeaters.
    case directPeer = "Direct Peer"

    /// Likely direct RF reception.
    /// Station was heard without digipeaters in the path, indicating probable direct RF link.
    case heardDirect = "Heard Direct"

    /// Observed through digipeater paths.
    /// Station was only seen via digipeaters; not proof of direct RF reception.
    case heardVia = "Heard Via"

    /// Infrastructure traffic (BEACON, ID, BBS).
    /// Always visually subdued and never counted as peer connection.
    case infrastructure = "Infrastructure"

    /// Human-readable description for UI
    var description: String {
        switch self {
        case .directPeer:
            return "Endpoint-to-endpoint traffic"
        case .heardDirect:
            return "Decoded directly (likely RF)"
        case .heardVia:
            return "Observed via digipeaters"
        case .infrastructure:
            return "BEACON/ID/BBS traffic"
        }
    }

    /// Visual priority (lower = drawn on top)
    var renderPriority: Int {
        switch self {
        case .directPeer: return 0
        case .heardDirect: return 1
        case .heardVia: return 2
        case .infrastructure: return 3
        }
    }
}

/// Graph view mode for filtering which link types are displayed.
enum GraphViewMode: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Show direct peer exchanges and likely direct RF links.
    /// Best for understanding "who can I work directly?"
    case connectivity = "Connectivity"

    /// Emphasize digipeater paths and network routing.
    /// Shows how packets flow through the network.
    case routing = "Routing"

    /// Show all connection types with clear visual hierarchy.
    case all = "All"

    var id: String { rawValue }

    /// Human-readable description
    var description: String {
        switch self {
        case .connectivity:
            return "Direct connections"
        case .routing:
            return "Packet flow paths"
        case .all:
            return "Everything"
        }
    }

    /// SF Symbol icon
    var icon: String {
        switch self {
        case .connectivity:
            return "antenna.radiowaves.left.and.right"
        case .routing:
            return "point.3.connected.trianglepath.dotted"
        case .all:
            return "network"
        }
    }

    /// Which link types are visible in this mode
    var visibleLinkTypes: Set<LinkType> {
        switch self {
        case .connectivity:
            return [.directPeer, .heardDirect]
        case .routing:
            return [.directPeer, .heardVia]
        case .all:
            return Set(LinkType.allCases)
        }
    }

    /// Which link types are emphasized (stronger visual weight) in this mode
    var emphasizedLinkTypes: Set<LinkType> {
        switch self {
        case .connectivity:
            return [.directPeer]
        case .routing:
            return [.heardVia]
        case .all:
            return [.directPeer]
        }
    }
}

// MARK: - Extended Edge Data

/// Extended edge information including relationship type.
struct ClassifiedEdge: Hashable, Sendable {
    let sourceID: String
    let targetID: String
    let linkType: LinkType
    let weight: Int           // Packet count
    let bytes: Int            // Total payload bytes
    let lastHeard: Date?      // Most recent packet timestamp
    let viaDigipeaters: [String]  // For heardVia: which digipeaters were in path
}

/// Station relationship data for inspector display.
struct StationRelationship: Hashable, Sendable, Identifiable {
    let id: String            // Station callsign
    let linkType: LinkType
    let packetCount: Int
    let lastHeard: Date?
    let viaDigipeaters: [String]  // For heardVia only
    let score: Double         // HeardDirect eligibility score (0-1)
}

// MARK: - HeardDirect Scoring

/// Parameters for HeardDirect eligibility scoring.
/// Tunable thresholds documented in Docs/NetworkGraphSemantics.md.
enum HeardDirectScoring {
    /// Minimum distinct minutes where station was heard direct
    static let minDirectMinutes: Int = 2

    /// Minimum direct reception count
    static let minDirectCount: Int = 3

    /// Target minutes for normalization (stations heard this many minutes get full score)
    static let targetMinutes: Int = 10

    /// Target count for normalization
    static let targetCount: Int = 20

    /// Recency window for boost (seconds)
    static let recencyWindow: TimeInterval = 300  // 5 minutes

    /// Weight for minutes component
    static let minutesWeight: Double = 0.6

    /// Weight for count component
    static let countWeight: Double = 0.4

    /// Maximum recency boost
    static let maxRecencyBoost: Double = 0.15

    /// Minimum score to qualify as HeardDirect
    static let minimumScore: Double = 0.25

    /// Calculate HeardDirect score for a station.
    ///
    /// - Parameters:
    ///   - directHeardCount: Number of packets received directly (no via)
    ///   - directHeardMinutes: Distinct minutes/buckets where station was heard direct
    ///   - lastDirectHeardAge: Seconds since last direct reception
    /// - Returns: Score between 0 and 1
    static func calculateScore(
        directHeardCount: Int,
        directHeardMinutes: Int,
        lastDirectHeardAge: TimeInterval
    ) -> Double {
        // Check eligibility first
        guard directHeardMinutes >= minDirectMinutes && directHeardCount >= minDirectCount else {
            return 0
        }

        // Normalize components
        let normMinutes = min(1.0, Double(directHeardMinutes) / Double(targetMinutes))
        let normCount = min(1.0, Double(directHeardCount) / Double(targetCount))

        // Base score
        let baseScore = minutesWeight * normMinutes + countWeight * normCount

        // Recency boost
        let recencyFactor = max(0, 1.0 - (lastDirectHeardAge / recencyWindow))
        let recencyBoost = recencyFactor * maxRecencyBoost

        // Final score clamped to 0-1
        return min(1.0, baseScore + recencyBoost)
    }
}

// MARK: - Classified Graph Model

/// Graph model with classified edges by relationship type.
struct ClassifiedGraphModel: Hashable, Sendable {
    let nodes: [NetworkGraphNode]
    let edges: [ClassifiedEdge]
    let adjacency: [String: [StationRelationship]]
    let droppedNodesCount: Int

    /// Edges filtered by link type
    func edges(ofType types: Set<LinkType>) -> [ClassifiedEdge] {
        edges.filter { types.contains($0.linkType) }
    }

    /// Get relationships for a station
    func relationships(for nodeID: String) -> [StationRelationship] {
        adjacency[nodeID] ?? []
    }

    /// Get relationships by type for a station
    func relationships(for nodeID: String, ofType linkType: LinkType) -> [StationRelationship] {
        relationships(for: nodeID).filter { $0.linkType == linkType }
    }

    static let empty = ClassifiedGraphModel(
        nodes: [],
        edges: [],
        adjacency: [:],
        droppedNodesCount: 0
    )
}
