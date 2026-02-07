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
/// The graph distinguishes connection evidence tiers to avoid lying about reachability:
///
/// - **DirectPeer**: Confirmed bidirectional endpoint-to-endpoint exchange (no digipeaters)
/// - **HeardMutual**: Mutual direct RF decode evidence (both stations heard each other directly)
/// - **HeardDirect**: One-way direct RF decode evidence (A heard B directly; may not be mutual)
/// - **HeardVia**: Observed via digipeater paths (not proof of direct RF)
/// - **Infrastructure**: BEACON/ID/BBS/etc. traffic (subdued)
enum LinkType: String, Hashable, Sendable, CaseIterable {
    /// Confirmed endpoint-to-endpoint packet exchange (bidirectional, no digipeaters).
    case directPeer = "Direct Peer"

    /// Mutual direct RF decode evidence (both directions observed directly, no digipeaters).
    /// This is the strongest “connectivity” signal for practical RF reachability.
    case heardMutual = "Heard Mutual"

    /// One-way direct RF reception evidence (no digipeaters).
    /// This means the observer decoded the sender directly, but reciprocity is unknown.
    case heardDirect = "Heard Direct"

    /// Observed through digipeater paths (not proof of direct RF reception).
    case heardVia = "Heard Via"

    /// Infrastructure traffic (BEACON, ID, BBS).
    /// Always visually subdued and never counted as peer connection.
    case infrastructure = "Infrastructure"

    /// Human-readable description for UI
    var description: String {
        switch self {
        case .directPeer:
            return "Bidirectional endpoint traffic (no digipeaters)"
        case .heardMutual:
            return "Mutual direct RF decode (likely workable)"
        case .heardDirect:
            return "One-way direct RF decode (not necessarily mutual)"
        case .heardVia:
            return "Observed via digipeaters (not direct RF proof)"
        case .infrastructure:
            return "BEACON/ID/BBS traffic"
        }
    }

    /// Visual priority (lower = drawn on top / emphasized)
    var renderPriority: Int {
        switch self {
        case .directPeer: return 0
        case .heardMutual: return 1
        case .heardDirect: return 2
        case .heardVia: return 3
        case .infrastructure: return 4
        }
    }
}

/// Graph view mode for filtering which link types are displayed.
enum GraphViewMode: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Show direct connectivity evidence.
    /// Best for "who can I probably work directly?"
    case connectivity = "Connectivity"

    /// Emphasize digipeater-mediated paths and routing visibility.
    case routing = "Routing"

    /// Show all connection types with clear visual hierarchy.
    case all = "All"

    /// NET/ROM classic mode: only explicit broadcast-derived routes.
    case netromClassic = "NET/ROM (Classic)"

    /// NET/ROM inference mode: passively inferred routes from packet observations.
    case netromInferred = "NET/ROM (Inferred)"

    /// NET/ROM hybrid mode: combines classic broadcasts with passive inference.
    case netromHybrid = "NET/ROM (Hybrid)"

    var id: String { rawValue }

    /// Human-readable description
    var description: String {
        switch self {
        case .connectivity:
            return GraphCopy.ViewMode.connectivityDescription
        case .routing:
            return GraphCopy.ViewMode.routingDescription
        case .all:
            return GraphCopy.ViewMode.allDescription
        case .netromClassic:
            return GraphCopy.ViewMode.netromClassicDescription
        case .netromInferred:
            return GraphCopy.ViewMode.netromInferredDescription
        case .netromHybrid:
            return GraphCopy.ViewMode.netromHybridDescription
        }
    }

    /// Informative tooltip
    var tooltip: String {
        switch self {
        case .connectivity:
            return GraphCopy.ViewMode.connectivityTooltip
        case .routing:
            return GraphCopy.ViewMode.routingTooltip
        case .all:
            return GraphCopy.ViewMode.allTooltip
        case .netromClassic:
            return GraphCopy.ViewMode.netromClassicTooltip
        case .netromInferred:
            return GraphCopy.ViewMode.netromInferredTooltip
        case .netromHybrid:
            return GraphCopy.ViewMode.netromHybridTooltip
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
        case .netromClassic:
            return "arrow.triangle.branch"
        case .netromInferred:
            return "wand.and.stars"
        case .netromHybrid:
            return "arrow.triangle.merge"
        }
    }

    /// Which link types are visible in this mode
    var visibleLinkTypes: Set<LinkType> {
        switch self {
        case .connectivity:
            // Direct RF evidence + confirmed endpoint exchange
            return [.directPeer, .heardMutual, .heardDirect]
        case .routing:
            // Routing emphasis: include digipeater-mediated observations + direct peer exchanges
            return [.directPeer, .heardVia]
        case .all:
            return Set(LinkType.allCases)
        case .netromClassic, .netromInferred, .netromHybrid:
            // NET/ROM modes show all edge types; filtering is handled by NET/ROM data source
            return Set(LinkType.allCases)
        }
    }

    /// Which link types are emphasized (stronger visual weight) in this mode
    var emphasizedLinkTypes: Set<LinkType> {
        switch self {
        case .connectivity:
            return [.heardMutual, .directPeer]
        case .routing:
            return [.heardVia]
        case .all:
            return [.directPeer, .heardMutual]
        case .netromClassic, .netromInferred, .netromHybrid:
            return [.directPeer]
        }
    }

    /// Whether this mode uses NET/ROM as the data source instead of packet-based graph building.
    var isNetRomMode: Bool {
        switch self {
        case .netromClassic, .netromInferred, .netromHybrid:
            return true
        case .connectivity, .routing, .all:
            return false
        }
    }

    /// Corresponding NET/ROM routing mode for NET/ROM-based graph view modes.
    var netRomRoutingMode: NetRomRoutingMode? {
        switch self {
        case .netromClassic:
            return .classic
        case .netromInferred:
            return .inference
        case .netromHybrid:
            return .hybrid
        case .connectivity, .routing, .all:
            return nil
        }
    }
}

// MARK: - Extended Edge Data

/// Extended edge information including relationship type.
struct ClassifiedEdge: Hashable, Sendable {
    let sourceID: String
    let targetID: String
    let linkType: LinkType
    let weight: Int           // Packet count (or evidence count)
    let bytes: Int64          // Total payload bytes (where applicable, or quality for NET/ROM)
    let lastHeard: Date?      // Most recent packet timestamp
    let viaDigipeaters: [String]  // For heardVia: which digipeaters were in path
    let isStale: Bool         // For NET/ROM: whether route is stale (for dimmed rendering)
    
    init(
        sourceID: String,
        targetID: String,
        linkType: LinkType,
        weight: Int,
        bytes: Int64 = 0,
        lastHeard: Date? = nil,
        viaDigipeaters: [String] = [],
        isStale: Bool = false
    ) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.linkType = linkType
        self.weight = weight
        self.bytes = bytes
        self.lastHeard = lastHeard
        self.viaDigipeaters = viaDigipeaters
        self.isStale = isStale
    }
}

/// Station relationship data for inspector display.
struct StationRelationship: Hashable, Sendable, Identifiable {
    let id: String            // Station callsign
    let linkType: LinkType
    let packetCount: Int
    let lastHeard: Date?
    let viaDigipeaters: [String]  // For heardVia only
    let score: Double         // HeardDirect eligibility score (0-1) (also used for HeardMutual)
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

    /// Minimum score to qualify as "strong" HeardDirect.
    ///
    /// NOTE: We still show weaker one-way HeardDirect edges for visibility,
    /// but this threshold gates “confident” edges and certain promotions.
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
