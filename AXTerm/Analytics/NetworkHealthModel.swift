//
//  NetworkHealthModel.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation

/// Network health metrics and scoring model for APRS/AX.25 packet radio networks.
///
/// The health model uses a HYBRID time window approach:
/// - **Topology metrics** depend on the user-selected timeframe, computed from a CANONICAL graph
///   (minEdge=2, unlimited nodes) that ignores view-only filters
/// - **Activity metrics** use a fixed 10-minute window for "current" state
///
/// This prevents UX whiplash when changing timeframes and ensures view filters don't affect health.
///
/// Formula:
/// ```
/// TopologyScore = 0.5×C1 + 0.3×C2 + 0.2×C3
/// ActivityScore = 0.6×A1 + 0.4×A2
/// NetworkHealthScore = round(0.6×TopologyScore + 0.4×ActivityScore)
/// ```
///
/// Reference: Composite health scoring inspired by network monitoring approaches (e.g., Optigo Networks).
/// See Docs/NetworkHealth.md for full documentation.
struct NetworkHealth: Hashable, Sendable {
    /// Overall health score from 0-100
    let score: Int
    /// Qualitative rating derived from score
    let rating: HealthRating
    /// Explanatory reasons for the score
    let reasons: [String]
    /// Core metrics
    let metrics: NetworkHealthMetrics
    /// Active warnings (only present when relevant)
    let warnings: [NetworkWarning]
    /// Packet activity over recent time window for sparkline
    let activityTrend: [Int]
    /// Detailed score breakdown for explainability
    let scoreBreakdown: HealthScoreBreakdown
    /// Display name for the timeframe used for topology metrics
    let timeframeDisplayName: String

    static let empty = NetworkHealth(
        score: 0,
        rating: .unknown,
        reasons: [],
        metrics: .empty,
        warnings: [],
        activityTrend: [],
        scoreBreakdown: .empty,
        timeframeDisplayName: ""
    )
}

/// Detailed breakdown of how the health score is calculated.
///
/// Uses a composite scoring model:
/// - **TopologyScore** (60%): C1 Main Cluster (50%) + C2 Connectivity (30%) + C3 Isolation Reduction (20%)
/// - **ActivityScore** (40%): A1 Active Nodes (60%) + A2 Packet Rate (40%)
///
/// This ensures view filters (Min Edge slider, Max Node count) do NOT affect the health score.
/// Only timeframe, includeVia toggle, and time passing affect the score.
struct HealthScoreBreakdown: Hashable, Sendable {
    // Topology metrics (timeframe-dependent, canonical graph) - 60% of final score
    let c1MainClusterPct: Double       // % of nodes in largest connected component
    let c2ConnectivityPct: Double      // % of possible edges that exist (capped at 100)
    let c3IsolationReduction: Double   // 100 - % isolated nodes
    let topologyScore: Double          // 0.5×C1 + 0.3×C2 + 0.2×C3

    // Activity metrics (10-minute window) - 40% of final score
    let a1ActiveNodesPct: Double       // % of stations heard in last 10m
    let a2PacketRateScore: Double      // Normalized packet rate score (0-100)
    let packetRatePerMin: Double       // Raw packets/min for display
    let activityScore: Double          // 0.6×A1 + 0.4×A2

    // Counts for display
    let totalNodes: Int
    let activeNodes10m: Int
    let isolatedNodes: Int

    // Final weighted score
    let finalScore: Int

    /// Components for UI display with (name, score, weight, contribution, isActivity) tuple
    var components: [(name: String, score: Double, weight: Double, contribution: Double, isActivity: Bool)] {
        [
            // Topology components (60% total)
            ("Main Cluster (TF)", c1MainClusterPct, 30, c1MainClusterPct * 0.30, false),
            ("Connectivity (TF)", c2ConnectivityPct, 18, c2ConnectivityPct * 0.18, false),
            ("Isolation Reduction (TF)", c3IsolationReduction, 12, c3IsolationReduction * 0.12, false),
            // Activity components (40% total)
            ("Active Nodes (10m)", a1ActiveNodesPct, 24, a1ActiveNodesPct * 0.24, true),
            ("Packet Rate (10m)", a2PacketRateScore, 16, a2PacketRateScore * 0.16, true)
        ]
    }

    var formulaDescription: String {
        """
        TopologyScore = 0.5×C1 + 0.3×C2 + 0.2×C3 = \(String(format: "%.1f", topologyScore))
        ActivityScore = 0.6×A1 + 0.4×A2 = \(String(format: "%.1f", activityScore))
        Final = 0.6×Topology + 0.4×Activity = \(finalScore)
        """
    }

    /// Total weight from activity metrics (10-minute window)
    var activityTotalWeight: Double { 40 }

    /// Total weight from topology metrics (timeframe-dependent)
    var topologyTotalWeight: Double { 60 }

    static let empty = HealthScoreBreakdown(
        c1MainClusterPct: 0, c2ConnectivityPct: 0, c3IsolationReduction: 0, topologyScore: 0,
        a1ActiveNodesPct: 0, a2PacketRateScore: 0, packetRatePerMin: 0, activityScore: 0,
        totalNodes: 0, activeNodes10m: 0, isolatedNodes: 0, finalScore: 0
    )
}

enum HealthRating: String, Hashable, Sendable {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    case unknown = "Unknown"

    static func from(score: Int) -> HealthRating {
        switch score {
        case 80...100: return .excellent
        case 60..<80: return .good
        case 40..<60: return .fair
        case 1..<40: return .poor
        default: return .unknown
        }
    }
}

/// Core metrics container for network health.
///
/// Metrics are split into two categories based on time window and computation source:
/// - **Topology metrics** (canonical graph, timeframe-dependent): Computed from a graph with
///   canonicalMinEdge=2 and no max-node limit, ignoring view-only filters
/// - **Activity metrics** (fixed 10-minute window): activeStations, packetRate, freshness
struct NetworkHealthMetrics: Hashable, Sendable {
    // MARK: - Topology Metrics (canonical graph, depends on selected timeframe)

    /// Total unique stations in the canonical graph
    let totalStations: Int
    /// Total packets received during the selected timeframe
    let totalPackets: Int
    /// C1: Percentage of nodes in the largest connected component (0-100)
    let largestComponentPercent: Double
    /// C2: Connectivity ratio = actualEdges / possibleEdges × 100 (capped at 100)
    let connectivityRatio: Double
    /// C3: 100 - (% isolated nodes). Higher is better.
    let isolationReduction: Double
    /// Number of isolated nodes (degree == 0) in the canonical graph
    let isolatedNodes: Int
    /// Name of the top relay (highest degree node)
    let topRelayCallsign: String?
    /// Percentage of edges involving the top relay
    let topRelayConcentration: Double

    // MARK: - Activity Metrics (fixed 10-minute window)

    /// Stations active in the last 10 minutes (fixed window, independent of timeframe)
    let activeStations: Int
    /// Current packet rate (packets per minute over last 10 minutes), EMA-smoothed
    let packetRate: Double
    /// Ratio of active stations to total stations (freshness indicator)
    let freshness: Double

    static let empty = NetworkHealthMetrics(
        totalStations: 0,
        totalPackets: 0,
        largestComponentPercent: 0,
        connectivityRatio: 0,
        isolationReduction: 100,
        isolatedNodes: 0,
        topRelayCallsign: nil,
        topRelayConcentration: 0,
        activeStations: 0,
        packetRate: 0,
        freshness: 0
    )
}

struct NetworkWarning: Hashable, Identifiable, Sendable {
    let id: String
    let severity: WarningSeverity
    let title: String
    let detail: String

    enum WarningSeverity: String, Hashable, Sendable {
        case info
        case caution
        case warning
    }
}

/// Calculates network health score and metrics using a composite scoring formula.
///
/// ## Key Design Principles
///
/// 1. **Canonical Topology Graph**: Health topology metrics are computed from a canonical graph that:
///    - Uses `canonicalMinEdge = 2` (not the view slider)
///    - Has no max-node limit (shows full network topology)
///    - Applies the `includeViaDigipeaters` toggle
///    - **Ignores** view-only filters (Min Edge slider, Max Node count)
///
/// 2. **Hybrid Time Windows**:
///    - Topology metrics: Based on user-selected timeframe
///    - Activity metrics: Fixed 10-minute window (unless TF < 10m)
///
/// 3. **Stability**: EMA smoothing on packet rate to prevent spiky behavior.
///
/// ## Formula
/// ```
/// TopologyScore = 0.5×C1 + 0.3×C2 + 0.2×C3
/// ActivityScore = 0.6×A1 + 0.4×A2
/// NetworkHealthScore = round(0.6×TopologyScore + 0.4×ActivityScore)
/// ```
///
/// Where:
/// - C1 = Main Cluster % (largest connected component / total nodes × 100)
/// - C2 = Connectivity Ratio % (actualEdges / possibleEdges × 100, capped at 100)
/// - C3 = Isolation Reduction (100 - % isolated nodes)
/// - A1 = Active Nodes % (stations in last 10m / total nodes × 100)
/// - A2 = Packet Rate Score (normalized to ideal rate of 1.0 pkt/min, capped at 100)
///
/// Reference: Composite health scoring approach inspired by network monitoring (e.g., Optigo Networks).
enum NetworkHealthCalculator {
    /// Canonical minimum edge count for health topology graph.
    /// This value is used regardless of the view's Min Edge slider setting.
    static let canonicalMinEdge: Int = 2

    /// Fixed window for activity metrics (independent of user timeframe)
    static let activityWindowMinutes: Int = 10

    /// Ideal packet rate for normalization (packets per minute)
    /// Networks with this rate or higher get a full 100 for A2.
    static let idealPacketRate: Double = 1.0

    /// EMA alpha for packet rate smoothing (0.25 = 25% new, 75% previous)
    static let packetRateEMAAlpha: Double = 0.25

    /// Previous EMA rate for smoothing (in-memory state; resets on app restart)
    private static var previousPacketRateEMA: Double?

    /// Calculate network health using the new composite scoring formula.
    ///
    /// - Parameters:
    ///   - canonicalGraph: Graph built with canonicalMinEdge=2 and no max-node limit
    ///   - timeframePackets: Packets within the user-selected timeframe
    ///   - allRecentPackets: All available packets for activity window calculation
    ///   - timeframeDisplayName: Human-readable name of the selected timeframe (e.g., "24h", "1h")
    ///   - includeViaDigipeaters: Whether the canonical graph includes via paths
    ///   - trendWindowMinutes: Window for sparkline (default 60 minutes)
    ///   - trendBucketMinutes: Bucket size for sparkline (default 5 minutes)
    ///   - now: Current time for calculations
    static func calculate(
        canonicalGraph: GraphModel,
        timeframePackets: [Packet],
        allRecentPackets: [Packet],
        timeframeDisplayName: String,
        includeViaDigipeaters: Bool,
        trendWindowMinutes: Int = 60,
        trendBucketMinutes: Int = 5,
        now: Date = Date()
    ) -> NetworkHealth {
        let metrics = calculateMetrics(
            canonicalGraph: canonicalGraph,
            timeframePackets: timeframePackets,
            allRecentPackets: allRecentPackets,
            now: now
        )

        let breakdown = calculateCompositeScore(metrics: metrics)
        let reasons = generateReasons(metrics: metrics, breakdown: breakdown, timeframeDisplayName: timeframeDisplayName)
        let warnings = generateWarnings(
            metrics: metrics,
            canonicalGraph: canonicalGraph,
            timeframeDisplayName: timeframeDisplayName
        )
        let trend = calculateActivityTrend(
            packets: allRecentPackets,
            windowMinutes: trendWindowMinutes,
            bucketMinutes: trendBucketMinutes,
            now: now
        )

        return NetworkHealth(
            score: breakdown.finalScore,
            rating: HealthRating.from(score: breakdown.finalScore),
            reasons: reasons,
            metrics: metrics,
            warnings: warnings,
            activityTrend: trend,
            scoreBreakdown: breakdown,
            timeframeDisplayName: timeframeDisplayName
        )
    }

    /// Convenience method using the view's graph model (backward compatibility).
    /// This builds a canonical graph internally for health calculation.
    static func calculate(
        graphModel: GraphModel,
        timeframePackets: [Packet],
        allRecentPackets: [Packet],
        timeframeDisplayName: String,
        includeViaDigipeaters: Bool = true,
        trendWindowMinutes: Int = 60,
        trendBucketMinutes: Int = 5,
        now: Date = Date()
    ) -> NetworkHealth {
        // Build canonical graph for health (ignoring view filters)
        let canonicalGraph = buildCanonicalGraph(
            packets: timeframePackets,
            includeViaDigipeaters: includeViaDigipeaters
        )

        return calculate(
            canonicalGraph: canonicalGraph,
            timeframePackets: timeframePackets,
            allRecentPackets: allRecentPackets,
            timeframeDisplayName: timeframeDisplayName,
            includeViaDigipeaters: includeViaDigipeaters,
            trendWindowMinutes: trendWindowMinutes,
            trendBucketMinutes: trendBucketMinutes,
            now: now
        )
    }

    /// Build the canonical topology graph for health metrics.
    /// Uses canonicalMinEdge=2 and unlimited max nodes.
    static func buildCanonicalGraph(packets: [Packet], includeViaDigipeaters: Bool) -> GraphModel {
        NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: includeViaDigipeaters,
                minimumEdgeCount: canonicalMinEdge,
                maxNodes: Int.max  // No limit for canonical health graph
            )
        )
    }

    /// Calculate metrics using the hybrid window model.
    private static func calculateMetrics(
        canonicalGraph: GraphModel,
        timeframePackets: [Packet],
        allRecentPackets: [Packet],
        now: Date
    ) -> NetworkHealthMetrics {
        // TOPOLOGY METRICS (from canonical graph)
        let totalNodes = canonicalGraph.nodes.count
        let totalPackets = timeframePackets.count

        // C1: Main Cluster % = largest connected component / total nodes × 100
        let c1MainClusterPct = calculateLargestComponentPercent(graph: canonicalGraph)

        // C2: Connectivity Ratio % = actualEdges / possibleEdges × 100
        let actualEdges = canonicalGraph.edges.count
        let possibleEdges = totalNodes > 1 ? (totalNodes * (totalNodes - 1)) / 2 : 0
        let c2ConnectivityPct = possibleEdges > 0
            ? min(100, Double(actualEdges) / Double(possibleEdges) * 100)
            : 0

        // C3: Isolation Reduction = 100 - (% isolated nodes)
        let isolatedCount = canonicalGraph.nodes.filter { $0.degree == 0 }.count
        let isolatedPct = totalNodes > 0 ? Double(isolatedCount) / Double(totalNodes) * 100 : 0
        let c3IsolationReduction = 100 - isolatedPct

        // Relay concentration (for warnings)
        let (topRelayPct, topRelayCallsign) = calculateRelayConcentration(graph: canonicalGraph)

        // ACTIVITY METRICS (fixed 10-minute window)
        let activityCutoff = now.addingTimeInterval(-Double(activityWindowMinutes * 60))
        let recentPackets = allRecentPackets.filter { $0.timestamp >= activityCutoff }

        // A1: Active Nodes % = stations heard in last 10m / total nodes × 100
        var activeCallsigns: Set<String> = []
        for packet in recentPackets {
            if let from = packet.from?.call { activeCallsigns.insert(from) }
            if let to = packet.to?.call { activeCallsigns.insert(to) }
        }
        let activeStations = activeCallsigns.count
        let a1ActiveNodesPct = totalNodes > 0 ? Double(activeStations) / Double(totalNodes) * 100 : 0

        // Calculate raw packet rate
        let rawPacketRate = Double(recentPackets.count) / Double(activityWindowMinutes)

        // Apply EMA smoothing for stability
        let smoothedRate: Double
        if let prev = previousPacketRateEMA {
            smoothedRate = packetRateEMAAlpha * rawPacketRate + (1 - packetRateEMAAlpha) * prev
        } else {
            smoothedRate = rawPacketRate
        }
        previousPacketRateEMA = smoothedRate

        // Freshness = active / total
        let freshness = totalNodes > 0 ? Double(activeStations) / Double(totalNodes) : 0

        return NetworkHealthMetrics(
            totalStations: totalNodes,
            totalPackets: totalPackets,
            largestComponentPercent: c1MainClusterPct,
            connectivityRatio: c2ConnectivityPct,
            isolationReduction: c3IsolationReduction,
            isolatedNodes: isolatedCount,
            topRelayCallsign: topRelayCallsign,
            topRelayConcentration: topRelayPct,
            activeStations: activeStations,
            packetRate: smoothedRate,
            freshness: freshness
        )
    }

    /// Calculate the composite health score using the new formula.
    private static func calculateCompositeScore(metrics: NetworkHealthMetrics) -> HealthScoreBreakdown {
        // Topology components (0-100 each)
        let c1 = metrics.largestComponentPercent
        let c2 = metrics.connectivityRatio
        let c3 = metrics.isolationReduction

        // TopologyScore = 0.5×C1 + 0.3×C2 + 0.2×C3
        let topologyScore = 0.5 * c1 + 0.3 * c2 + 0.2 * c3

        // Activity components (0-100 each)
        let a1 = metrics.totalStations > 0
            ? Double(metrics.activeStations) / Double(metrics.totalStations) * 100
            : 0

        // A2 = min(100, (packetRate / idealRate) × 100)
        let a2 = min(100, (metrics.packetRate / idealPacketRate) * 100)

        // ActivityScore = 0.6×A1 + 0.4×A2
        let activityScore = 0.6 * a1 + 0.4 * a2

        // Final = 0.6×TopologyScore + 0.4×ActivityScore
        let finalScore = Int(min(100, max(0, round(0.6 * topologyScore + 0.4 * activityScore))))

        return HealthScoreBreakdown(
            c1MainClusterPct: c1,
            c2ConnectivityPct: c2,
            c3IsolationReduction: c3,
            topologyScore: topologyScore,
            a1ActiveNodesPct: a1,
            a2PacketRateScore: a2,
            packetRatePerMin: metrics.packetRate,
            activityScore: activityScore,
            totalNodes: metrics.totalStations,
            activeNodes10m: metrics.activeStations,
            isolatedNodes: metrics.isolatedNodes,
            finalScore: finalScore
        )
    }

    private static func calculateLargestComponentPercent(graph: GraphModel) -> Double {
        guard !graph.nodes.isEmpty else { return 0 }

        // Build adjacency set for BFS
        var adjacency: [String: Set<String>] = [:]
        for edge in graph.edges {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
            adjacency[edge.targetID, default: []].insert(edge.sourceID)
        }

        var visited: Set<String> = []
        var largestComponentSize = 0

        for node in graph.nodes {
            guard !visited.contains(node.id) else { continue }

            // BFS to find component size
            var queue = [node.id]
            var componentSize = 0
            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard !visited.contains(current) else { continue }
                visited.insert(current)
                componentSize += 1

                if let neighbors = adjacency[current] {
                    for neighbor in neighbors where !visited.contains(neighbor) {
                        queue.append(neighbor)
                    }
                }
            }
            largestComponentSize = max(largestComponentSize, componentSize)
        }

        return Double(largestComponentSize) / Double(graph.nodes.count) * 100
    }

    private static func calculateRelayConcentration(graph: GraphModel) -> (Double, String?) {
        guard !graph.nodes.isEmpty else { return (0, nil) }

        // Find the node with highest degree (most connections = likely relay)
        guard let topNode = graph.nodes.max(by: { $0.degree < $1.degree }) else {
            return (0, nil)
        }

        // Calculate what percentage of total edges involve this node
        let totalEdges = graph.edges.count
        guard totalEdges > 0 else { return (0, nil) }

        let topNodeEdges = graph.edges.filter {
            $0.sourceID == topNode.id || $0.targetID == topNode.id
        }.count

        let concentration = Double(topNodeEdges) / Double(totalEdges) * 100
        return (concentration, topNode.callsign)
    }

    private static func calculateActivityTrend(
        packets: [Packet],
        windowMinutes: Int,
        bucketMinutes: Int,
        now: Date
    ) -> [Int] {
        let windowStart = now.addingTimeInterval(-Double(windowMinutes * 60))
        let bucketCount = windowMinutes / bucketMinutes

        var buckets = [Int](repeating: 0, count: bucketCount)

        for packet in packets {
            guard packet.timestamp >= windowStart else { continue }
            let minutesAgo = now.timeIntervalSince(packet.timestamp) / 60
            let bucketIndex = min(bucketCount - 1, max(0, Int(minutesAgo / Double(bucketMinutes))))
            // Reverse index so oldest is first
            let reversedIndex = bucketCount - 1 - bucketIndex
            if reversedIndex >= 0 && reversedIndex < bucketCount {
                buckets[reversedIndex] += 1
            }
        }

        return buckets
    }

    /// Generate human-readable reasons for the score.
    private static func generateReasons(
        metrics: NetworkHealthMetrics,
        breakdown: HealthScoreBreakdown,
        timeframeDisplayName: String
    ) -> [String] {
        var reasons: [String] = []
        let tfLabel = timeframeDisplayName.isEmpty ? "" : " (\(timeframeDisplayName))"

        // Connectivity reason
        if breakdown.c1MainClusterPct >= 80 {
            reasons.append("Well-connected network\(tfLabel)")
        } else if breakdown.c1MainClusterPct >= 50 {
            reasons.append("Moderately connected (\(Int(breakdown.c1MainClusterPct))%\(tfLabel))")
        }

        // Activity reason
        if breakdown.a1ActiveNodesPct >= 50 {
            reasons.append("\(metrics.activeStations) stations active (10m)")
        } else if metrics.activeStations > 0 {
            reasons.append("\(metrics.activeStations) station\(metrics.activeStations == 1 ? "" : "s") recently active")
        }

        // Packet rate reason
        if metrics.packetRate >= idealPacketRate {
            reasons.append("Healthy traffic (\(String(format: "%.1f", metrics.packetRate))/min)")
        } else if metrics.packetRate > 0 {
            reasons.append("Light traffic (\(String(format: "%.2f", metrics.packetRate))/min)")
        }

        // Ensure at least one reason
        if reasons.isEmpty {
            if breakdown.finalScore == 0 {
                reasons.append("No network activity detected")
            } else {
                reasons.append("Network operational")
            }
        }

        return Array(reasons.prefix(3))
    }

    /// Generate warnings with explicit timeframe context to prevent misleading messages.
    private static func generateWarnings(
        metrics: NetworkHealthMetrics,
        canonicalGraph: GraphModel,
        timeframeDisplayName: String
    ) -> [NetworkWarning] {
        var warnings: [NetworkWarning] = []
        let tfLabel = timeframeDisplayName.isEmpty ? "" : " (\(timeframeDisplayName))"

        // Single-point relay dominance (timeframe-dependent)
        if metrics.topRelayConcentration > 60, let relay = metrics.topRelayCallsign {
            warnings.append(NetworkWarning(
                id: "relay_dominance",
                severity: .caution,
                title: "Single relay dominance",
                detail: "\(relay) handles \(Int(metrics.topRelayConcentration))% of traffic\(tfLabel)"
            ))
        }

        // Stale nodes warning (compares 10-minute activity to timeframe graph)
        if metrics.totalStations > 0 && metrics.freshness < 0.3 {
            let staleCount = metrics.totalStations - metrics.activeStations
            warnings.append(NetworkWarning(
                id: "stale_nodes",
                severity: .info,
                title: "Stale stations",
                detail: "\(staleCount) stations not heard in 10 minutes"
            ))
        }

        // Fragmented network (timeframe-dependent - explicit label)
        if metrics.largestComponentPercent < 50 && canonicalGraph.nodes.count > 5 {
            warnings.append(NetworkWarning(
                id: "fragmented",
                severity: .caution,
                title: "Fragmented network\(tfLabel)",
                detail: "Only \(Int(metrics.largestComponentPercent))% of stations in main cluster"
            ))
        }

        // Isolated nodes (timeframe-dependent)
        if metrics.isolatedNodes > 0 {
            warnings.append(NetworkWarning(
                id: "isolated",
                severity: .info,
                title: "Isolated stations\(tfLabel)",
                detail: "\(metrics.isolatedNodes) station\(metrics.isolatedNodes == 1 ? "" : "s") with no connections"
            ))
        }

        // Low activity (10-minute window)
        if metrics.packetRate < 0.1 && metrics.totalPackets > 0 {
            warnings.append(NetworkWarning(
                id: "low_activity",
                severity: .info,
                title: "Low activity (10m)",
                detail: "Less than 1 packet per 10 minutes"
            ))
        }

        return warnings
    }

    /// Reset EMA state (useful for testing)
    static func resetEMAState() {
        previousPacketRateEMA = nil
    }
}
