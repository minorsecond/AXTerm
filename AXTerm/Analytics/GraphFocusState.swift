//
//  GraphFocusState.swift
//  AXTerm
//
//  Graph Focus state management with k-hop neighborhood filtering and hub metrics.
//
//  Key design decisions:
//  - Focus mode filters the graph to show only nodes within k hops of selection
//  - Primary Hub no longer always auto-zooms; it selects + enables focus + fits ONCE
//  - Fit and Reset are explicit user actions that do not fight manual pan/zoom
//  - Hub metric can be: Degree (default), Traffic (packets), or Bridges (approx betweenness)
//

import Foundation

// MARK: - Int Clamped Extension

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

// MARK: - Hub Metric

/// Metric used to identify the "primary hub" node
enum HubMetric: String, CaseIterable, Identifiable, Sendable {
    case degree = "Degree"
    case traffic = "Traffic"
    case bridges = "Bridges"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .degree:
            return "Most connections"
        case .traffic:
            return "Most packets"
        case .bridges:
            return "Network bridges (betweenness)"
        }
    }
}

// MARK: - Graph Focus State

/// State for graph focus mode and k-hop filtering
struct GraphFocusState: Equatable, Sendable {
    /// Whether focus mode is enabled (filters graph to k-hop neighborhood)
    var isFocusEnabled: Bool = false

    /// Number of hops from selected node to include (1-6)
    var maxHops: Int = 2

    /// Metric used to select the primary hub
    var hubMetric: HubMetric = .degree

    /// Flag to prevent auto-fit after Primary Hub action
    /// Reset when user explicitly changes selection or toggles focus
    var didAutoFitForCurrentSelection: Bool = false

    /// Valid range for maxHops
    static let hopRange: ClosedRange<Int> = 1...6
}

// MARK: - Filtered Graph Result

/// Result of k-hop filtering: contains the visible subgraph
struct FilteredGraphResult: Equatable, Sendable {
    /// Node IDs within k hops of the focus node(s)
    let visibleNodeIDs: Set<String>

    /// Edges where both endpoints are in visibleNodeIDs
    let visibleEdgeKeys: Set<FocusEdgeKey>

    /// The focus node ID (single selection) or nil if multi-selection
    let focusNodeID: String?

    /// Hop distances for each visible node (for potential visualization)
    let hopDistances: [String: Int]

    static let empty = FilteredGraphResult(
        visibleNodeIDs: [],
        visibleEdgeKeys: [],
        focusNodeID: nil,
        hopDistances: [:]
    )
}

/// Hashable key for edges (order-independent for undirected graphs)
struct FocusEdgeKey: Hashable, Sendable {
    let nodeA: String
    let nodeB: String

    init(_ source: String, _ target: String) {
        // Normalize order for undirected edge comparison
        if source < target {
            self.nodeA = source
            self.nodeB = target
        } else {
            self.nodeA = target
            self.nodeB = source
        }
    }
}

// MARK: - Graph Algorithms

/// Graph algorithms for k-hop filtering and hub metrics
enum GraphAlgorithms {
    // MARK: - K-Hop Neighborhood (BFS)

    /// Computes the k-hop neighborhood of a node using BFS.
    /// Returns nodes within k hops and their distances.
    ///
    /// Time complexity: O(V + E) where V = nodes, E = edges
    /// This is efficient and suitable for real-time filtering.
    static func kHopNeighborhood(
        from startNodeID: String,
        maxHops: Int,
        adjacency: [String: [GraphNeighborStat]]
    ) -> (nodeIDs: Set<String>, distances: [String: Int]) {
        var visited: Set<String> = [startNodeID]
        var distances: [String: Int] = [startNodeID: 0]
        var frontier: [String] = [startNodeID]

        for hop in 1...maxHops {
            var nextFrontier: [String] = []
            for nodeID in frontier {
                guard let neighbors = adjacency[nodeID] else { continue }
                for neighbor in neighbors {
                    if !visited.contains(neighbor.id) {
                        visited.insert(neighbor.id)
                        distances[neighbor.id] = hop
                        nextFrontier.append(neighbor.id)
                    }
                }
            }
            frontier = nextFrontier
            if frontier.isEmpty { break }
        }

        return (visited, distances)
    }

    /// Filters graph to k-hop neighborhood of selected node(s).
    /// If multiple nodes are selected, computes union of neighborhoods.
    static func filterToKHop(
        model: GraphModel,
        selectedNodeIDs: Set<String>,
        maxHops: Int
    ) -> FilteredGraphResult {
        guard !selectedNodeIDs.isEmpty else {
            return FilteredGraphResult(
                visibleNodeIDs: Set(model.nodes.map { $0.id }),
                visibleEdgeKeys: Set(model.edges.map { FocusEdgeKey($0.sourceID, $0.targetID) }),
                focusNodeID: nil,
                hopDistances: [:]
            )
        }

        var allVisibleNodes: Set<String> = []
        var allDistances: [String: Int] = [:]

        // For single selection, use that node; for multi, merge neighborhoods
        for nodeID in selectedNodeIDs {
            let (nodes, distances) = kHopNeighborhood(
                from: nodeID,
                maxHops: maxHops,
                adjacency: model.adjacency
            )
            allVisibleNodes.formUnion(nodes)
            for (id, dist) in distances {
                if let existing = allDistances[id] {
                    allDistances[id] = min(existing, dist)
                } else {
                    allDistances[id] = dist
                }
            }
        }

        // Filter edges to those with both endpoints visible
        let visibleEdges = model.edges.filter { edge in
            allVisibleNodes.contains(edge.sourceID) && allVisibleNodes.contains(edge.targetID)
        }
        let edgeKeys = Set(visibleEdges.map { FocusEdgeKey($0.sourceID, $0.targetID) })

        return FilteredGraphResult(
            visibleNodeIDs: allVisibleNodes,
            visibleEdgeKeys: edgeKeys,
            focusNodeID: selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil,
            hopDistances: allDistances
        )
    }

    // MARK: - Hub Metrics

    /// Finds the primary hub node based on the selected metric.
    /// Returns nil if graph is empty.
    static func findPrimaryHub(
        model: GraphModel,
        metric: HubMetric
    ) -> String? {
        guard !model.nodes.isEmpty else { return nil }

        switch metric {
        case .degree:
            // Highest degree (most connections)
            return model.nodes.max(by: { $0.degree < $1.degree })?.id

        case .traffic:
            // Highest total packet count (inCount + outCount)
            return model.nodes.max(by: {
                ($0.inCount + $0.outCount) < ($1.inCount + $1.outCount)
            })?.id

        case .bridges:
            // Approximate betweenness centrality using edge-count heuristic
            // True betweenness is O(V*E) which is expensive for large graphs.
            // This approximation uses: bridge_score = degree * (1 / avg_neighbor_degree)
            // Nodes connected to low-degree neighbors are likely bridges.
            return findApproximateBridgeNode(model: model)
        }
    }

    /// Approximates betweenness centrality using a heuristic.
    ///
    /// True betweenness centrality requires computing shortest paths between all pairs,
    /// which is O(V * E) for unweighted graphs. For real-time use, we use a heuristic:
    ///
    /// Bridge Score = degree * (1 / average_neighbor_degree)
    ///
    /// This identifies nodes that connect low-degree nodes (likely network bridges).
    /// A node with high degree connected to many low-degree nodes is likely a bridge.
    private static func findApproximateBridgeNode(model: GraphModel) -> String? {
        guard !model.nodes.isEmpty else { return nil }

        // Build degree lookup
        let degreeMap = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.id, $0.degree) })

        var bestNodeID: String?
        var bestScore: Double = -1

        for node in model.nodes {
            guard let neighbors = model.adjacency[node.id], !neighbors.isEmpty else { continue }

            // Calculate average neighbor degree
            let neighborDegrees = neighbors.compactMap { degreeMap[$0.id] }
            guard !neighborDegrees.isEmpty else { continue }
            let avgNeighborDegree = Double(neighborDegrees.reduce(0, +)) / Double(neighborDegrees.count)

            // Bridge score: high degree connected to low-degree neighbors
            let bridgeScore = avgNeighborDegree > 0
                ? Double(node.degree) / avgNeighborDegree
                : Double(node.degree)

            if bridgeScore > bestScore {
                bestScore = bridgeScore
                bestNodeID = node.id
            }
        }

        return bestNodeID
    }

    // MARK: - Bounding Box for Fit

    /// Computes bounding box of visible nodes in normalized [0,1] coordinates.
    /// Returns nil if no positions are visible.
    static func boundingBox(
        visibleNodeIDs: Set<String>,
        positions: [NodePosition]
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        let visiblePositions = positions.filter { visibleNodeIDs.contains($0.id) }
        guard !visiblePositions.isEmpty else { return nil }

        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        for pos in visiblePositions {
            minX = min(minX, pos.x)
            minY = min(minY, pos.y)
            maxX = max(maxX, pos.x)
            maxY = max(maxY, pos.y)
        }

        return (minX, minY, maxX, maxY)
    }
}
