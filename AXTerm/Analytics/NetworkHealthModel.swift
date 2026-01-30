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
/// - **Topology metrics** (stations heard, packets, cluster %, relay share) depend on the user-selected timeframe
/// - **Activity metrics** (active stations, packet rate) use a fixed 10-minute window for "current" state
///
/// This prevents UX whiplash when changing timeframes while keeping activity metrics stable.
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
/// Uses a HYBRID weighting model:
/// - **60% Topology** (timeframe-dependent): Connectivity (30%) + Redundancy (20%) + Stability (10%)
/// - **40% Activity** (10-minute window): Activity (25%) + Freshness (15%)
///
/// This ensures the score is stable when changing timeframes while still reflecting
/// current network activity.
struct HealthScoreBreakdown: Hashable, Sendable {
    // Activity metrics (10-minute window) - 40% total
    let activityScore: Double
    let activityWeight: Double      // 25%
    let freshnessScore: Double
    let freshnessWeight: Double     // 15%

    // Topology metrics (timeframe-dependent) - 60% total
    let connectivityScore: Double
    let connectivityWeight: Double  // 30%
    let redundancyScore: Double
    let redundancyWeight: Double    // 20%
    let stabilityScore: Double
    let stabilityWeight: Double     // 10%

    var components: [(name: String, score: Double, weight: Double, contribution: Double, isActivity: Bool)] {
        [
            ("Activity (10m)", activityScore, activityWeight, activityScore * activityWeight / 100, true),
            ("Freshness (10m)", freshnessScore, freshnessWeight, freshnessScore * freshnessWeight / 100, true),
            ("Connectivity", connectivityScore, connectivityWeight, connectivityScore * connectivityWeight / 100, false),
            ("Redundancy", redundancyScore, redundancyWeight, redundancyScore * redundancyWeight / 100, false),
            ("Stability", stabilityScore, stabilityWeight, stabilityScore * stabilityWeight / 100, false)
        ]
    }

    var formulaDescription: String {
        """
        Score = Activity (10m) × \(Int(activityWeight))% + Freshness (10m) × \(Int(freshnessWeight))% + \
        Connectivity × \(Int(connectivityWeight))% + Redundancy × \(Int(redundancyWeight))% + \
        Stability × \(Int(stabilityWeight))%
        """
    }

    /// Total weight from activity metrics (10-minute window)
    var activityTotalWeight: Double { activityWeight + freshnessWeight }

    /// Total weight from topology metrics (timeframe-dependent)
    var topologyTotalWeight: Double { connectivityWeight + redundancyWeight + stabilityWeight }

    static let empty = HealthScoreBreakdown(
        activityScore: 0, activityWeight: 25,
        freshnessScore: 0, freshnessWeight: 15,
        connectivityScore: 0, connectivityWeight: 30,
        redundancyScore: 0, redundancyWeight: 20,
        stabilityScore: 0, stabilityWeight: 10
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
/// Metrics are split into two categories based on time window:
/// - **Topology metrics** (timeframe-dependent): totalStations, totalPackets, largestComponentPercent,
///   topRelayConcentration, isolatedNodes
/// - **Activity metrics** (fixed 10-minute window): activeStations, packetRate, freshness
struct NetworkHealthMetrics: Hashable, Sendable {
    // MARK: - Topology Metrics (depend on selected timeframe)

    /// Total unique stations heard during the selected timeframe
    let totalStations: Int
    /// Total packets received during the selected timeframe
    let totalPackets: Int
    /// Percentage of nodes in the largest connected component (based on timeframe graph)
    let largestComponentPercent: Double
    /// Percentage of traffic handled by the top relay/digipeater (based on timeframe graph)
    let topRelayConcentration: Double
    /// Name of the top relay (if any)
    let topRelayCallsign: String?
    /// Number of isolated nodes (degree == 0) in the timeframe graph
    let isolatedNodes: Int

    // MARK: - Activity Metrics (fixed 10-minute window)

    /// Stations active in the last 10 minutes (fixed window, independent of timeframe)
    let activeStations: Int
    /// Current packet rate (packets per minute over last 10 minutes)
    let packetRate: Double
    /// Ratio of active stations to total stations (freshness indicator)
    let freshness: Double

    static let empty = NetworkHealthMetrics(
        totalStations: 0,
        totalPackets: 0,
        largestComponentPercent: 0,
        topRelayConcentration: 0,
        topRelayCallsign: nil,
        isolatedNodes: 0,
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

/// Calculates network health score and metrics from graph data and packet history.
///
/// Uses a HYBRID time window model:
/// - **Topology metrics**: Based on the user-selected timeframe (via graphModel and timeframePackets)
/// - **Activity metrics**: Always use a fixed 10-minute window (activityWindowMinutes) regardless of timeframe
///
/// This approach prevents UX "whiplash" when changing timeframes:
/// - Changing 24h → 1h: topology metrics update, but "Active (10m)" stays stable
/// - Activity-based score components remain consistent across timeframe changes
enum NetworkHealthCalculator {
    /// Scoring weights for health index components
    ///
    /// HYBRID model: 60% topology (timeframe-dependent) + 40% activity (10-minute window)
    private enum Weights {
        // Activity metrics (10-minute window) - 40% total
        static let activity: Double = 0.25      // Is traffic flowing right now?
        static let freshness: Double = 0.15     // Are nodes recently active?

        // Topology metrics (timeframe-dependent) - 60% total
        static let connectivity: Double = 0.30  // Is the network well-connected?
        static let redundancy: Double = 0.20    // Is there relay diversity?
        static let stability: Double = 0.10     // Consistent packet rate?
    }

    /// Fixed window for activity metrics (independent of user timeframe)
    static let activityWindowMinutes: Int = 10

    /// Calculate network health from current state
    ///
    /// - Parameters:
    ///   - graphModel: The network graph built from the selected timeframe's packets
    ///   - timeframePackets: Packets within the user-selected timeframe (for topology metrics)
    ///   - allRecentPackets: All packets in the activity window (for activity metrics, typically 10 min)
    ///   - timeframeDisplayName: Human-readable name of the selected timeframe (e.g., "24h", "1h")
    ///   - trendWindowMinutes: Window for sparkline (default 60 minutes)
    ///   - trendBucketMinutes: Bucket size for sparkline (default 5 minutes)
    ///   - now: Current time for calculations
    static func calculate(
        graphModel: GraphModel,
        timeframePackets: [Packet],
        allRecentPackets: [Packet],
        timeframeDisplayName: String,
        trendWindowMinutes: Int = 60,
        trendBucketMinutes: Int = 5,
        now: Date = Date()
    ) -> NetworkHealth {
        let metrics = calculateMetrics(
            graphModel: graphModel,
            timeframePackets: timeframePackets,
            allRecentPackets: allRecentPackets,
            now: now
        )

        let (score, reasons, breakdown) = calculateScore(
            metrics: metrics,
            graphModel: graphModel,
            timeframeDisplayName: timeframeDisplayName
        )
        let warnings = generateWarnings(
            metrics: metrics,
            graphModel: graphModel,
            timeframeDisplayName: timeframeDisplayName
        )
        let trend = calculateActivityTrend(
            packets: allRecentPackets,
            windowMinutes: trendWindowMinutes,
            bucketMinutes: trendBucketMinutes,
            now: now
        )

        return NetworkHealth(
            score: score,
            rating: HealthRating.from(score: score),
            reasons: reasons,
            metrics: metrics,
            warnings: warnings,
            activityTrend: trend,
            scoreBreakdown: breakdown,
            timeframeDisplayName: timeframeDisplayName
        )
    }

    /// Convenience method for backward compatibility (uses timeframePackets for both)
    static func calculate(
        graphModel: GraphModel,
        packets: [Packet],
        recentWindowMinutes: Int = 10,
        trendWindowMinutes: Int = 60,
        trendBucketMinutes: Int = 5,
        now: Date = Date()
    ) -> NetworkHealth {
        // Filter packets to activity window for activity metrics
        let activityCutoff = now.addingTimeInterval(-Double(recentWindowMinutes * 60))
        let recentPackets = packets.filter { $0.timestamp >= activityCutoff }

        return calculate(
            graphModel: graphModel,
            timeframePackets: packets,
            allRecentPackets: recentPackets,
            timeframeDisplayName: "",
            trendWindowMinutes: trendWindowMinutes,
            trendBucketMinutes: trendBucketMinutes,
            now: now
        )
    }

    /// Calculate metrics using the hybrid window model.
    ///
    /// - Parameters:
    ///   - graphModel: Network graph from the selected timeframe
    ///   - timeframePackets: Packets in the selected timeframe (for topology metrics)
    ///   - allRecentPackets: All available packets for activity window calculation
    ///   - now: Current time
    private static func calculateMetrics(
        graphModel: GraphModel,
        timeframePackets: [Packet],
        allRecentPackets: [Packet],
        now: Date
    ) -> NetworkHealthMetrics {
        // TOPOLOGY METRICS (from timeframe/graph)
        let totalStations = graphModel.nodes.count
        let totalPackets = timeframePackets.count

        // Calculate largest connected component percentage (from timeframe graph)
        let largestComponentPercent = calculateLargestComponentPercent(graphModel: graphModel)

        // Calculate relay concentration (from timeframe graph)
        let (topRelayPercent, topRelayCallsign) = calculateRelayConcentration(graphModel: graphModel)

        // Count isolated nodes (from timeframe graph)
        let isolatedNodes = graphModel.nodes.filter { $0.degree == 0 }.count

        // ACTIVITY METRICS (fixed 10-minute window)
        let activityCutoff = now.addingTimeInterval(-Double(activityWindowMinutes * 60))
        let recentPackets = allRecentPackets.filter { $0.timestamp >= activityCutoff }

        // Calculate active stations (heard in last 10 minutes)
        var activeCallsigns: Set<String> = []
        for packet in recentPackets {
            if let from = packet.from?.call { activeCallsigns.insert(from) }
            if let to = packet.to?.call { activeCallsigns.insert(to) }
        }
        let activeStations = activeCallsigns.count

        // Calculate packet rate (packets per minute over 10-minute window)
        let packetRate = Double(recentPackets.count) / Double(activityWindowMinutes)

        // Calculate freshness (ratio of active stations to total stations in graph)
        let freshness = totalStations > 0 ? Double(activeStations) / Double(totalStations) : 0

        return NetworkHealthMetrics(
            totalStations: totalStations,
            totalPackets: totalPackets,
            largestComponentPercent: largestComponentPercent,
            topRelayConcentration: topRelayPercent,
            topRelayCallsign: topRelayCallsign,
            isolatedNodes: isolatedNodes,
            activeStations: activeStations,
            packetRate: packetRate,
            freshness: freshness
        )
    }

    private static func calculateLargestComponentPercent(graphModel: GraphModel) -> Double {
        guard !graphModel.nodes.isEmpty else { return 0 }

        // Build adjacency set for BFS
        var adjacency: [String: Set<String>] = [:]
        for edge in graphModel.edges {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
            adjacency[edge.targetID, default: []].insert(edge.sourceID)
        }

        var visited: Set<String> = []
        var largestComponentSize = 0

        for node in graphModel.nodes {
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

        return Double(largestComponentSize) / Double(graphModel.nodes.count) * 100
    }

    private static func calculateRelayConcentration(graphModel: GraphModel) -> (Double, String?) {
        guard !graphModel.nodes.isEmpty else { return (0, nil) }

        // Find the node with highest degree (most connections = likely relay)
        guard let topNode = graphModel.nodes.max(by: { $0.degree < $1.degree }) else {
            return (0, nil)
        }

        // Calculate what percentage of total edges involve this node
        let totalEdges = graphModel.edges.count
        guard totalEdges > 0 else { return (0, nil) }

        let topNodeEdges = graphModel.edges.filter {
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

    /// Calculate health score using the hybrid model.
    ///
    /// Weights: 60% topology (timeframe) + 40% activity (10-minute window)
    private static func calculateScore(
        metrics: NetworkHealthMetrics,
        graphModel: GraphModel,
        timeframeDisplayName: String
    ) -> (Int, [String], HealthScoreBreakdown) {
        var reasons: [String] = []

        // ACTIVITY METRICS (10-minute window) - 40% total

        // Activity score (0-100): Based on packet rate over 10 minutes
        // Excellent: >2 pkt/min, Good: >0.5, Fair: >0.1, Poor: <0.1
        let activityScore: Double
        switch metrics.packetRate {
        case 2...: activityScore = 100
        case 1..<2: activityScore = 85
        case 0.5..<1: activityScore = 70
        case 0.2..<0.5: activityScore = 50
        case 0.05..<0.2: activityScore = 30
        default: activityScore = metrics.totalPackets > 0 ? 15 : 0
        }
        if activityScore >= 70 {
            reasons.append("Healthy activity (\(String(format: "%.1f", metrics.packetRate))/min)")
        } else if activityScore > 0 {
            reasons.append("Low packet activity")
        }

        // Freshness score (0-100): Ratio of active to total stations
        let freshnessScore = metrics.freshness * 100
        if freshnessScore >= 50 {
            reasons.append("\(metrics.activeStations) stations active (10m)")
        }

        // TOPOLOGY METRICS (timeframe-dependent) - 60% total

        // Connectivity score (0-100): Largest component percentage
        let connectivityScore = metrics.largestComponentPercent
        let tfLabel = timeframeDisplayName.isEmpty ? "" : " (\(timeframeDisplayName))"
        if connectivityScore >= 80 {
            reasons.append("Well-connected network\(tfLabel)")
        } else if connectivityScore >= 50 && connectivityScore < 80 {
            reasons.append("Moderately connected (\(Int(connectivityScore))%\(tfLabel))")
        }

        // Redundancy score (0-100): Inverse of relay concentration
        // Lower concentration = better redundancy
        let redundancyScore: Double
        if metrics.topRelayConcentration <= 30 {
            redundancyScore = 100
        } else if metrics.topRelayConcentration <= 50 {
            redundancyScore = 70
        } else if metrics.topRelayConcentration <= 70 {
            redundancyScore = 40
        } else {
            redundancyScore = 20
        }

        // Stability score (0-100): Based on having consistent activity
        // Uses packets-per-station ratio from the timeframe
        let stabilityScore: Double
        if metrics.totalStations > 0 && metrics.totalPackets > 0 {
            let packetsPerStation = Double(metrics.totalPackets) / Double(metrics.totalStations)
            stabilityScore = min(100, packetsPerStation * 10)
        } else {
            stabilityScore = 0
        }

        // Weighted final score (60% topology + 40% activity)
        let weightedScore =
            activityScore * Weights.activity +
            freshnessScore * Weights.freshness +
            connectivityScore * Weights.connectivity +
            redundancyScore * Weights.redundancy +
            stabilityScore * Weights.stability

        let finalScore = Int(min(100, max(0, weightedScore)))

        // Ensure we have at least one reason
        if reasons.isEmpty {
            if finalScore == 0 {
                reasons.append("No network activity detected")
            } else {
                reasons.append("Network operational")
            }
        }

        // Build score breakdown for explainability
        let breakdown = HealthScoreBreakdown(
            activityScore: activityScore,
            activityWeight: Weights.activity * 100,
            freshnessScore: freshnessScore,
            freshnessWeight: Weights.freshness * 100,
            connectivityScore: connectivityScore,
            connectivityWeight: Weights.connectivity * 100,
            redundancyScore: redundancyScore,
            redundancyWeight: Weights.redundancy * 100,
            stabilityScore: stabilityScore,
            stabilityWeight: Weights.stability * 100
        )

        return (finalScore, Array(reasons.prefix(3)), breakdown)
    }

    /// Generate warnings with explicit timeframe context to prevent misleading messages.
    private static func generateWarnings(
        metrics: NetworkHealthMetrics,
        graphModel: GraphModel,
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
        if metrics.largestComponentPercent < 50 && graphModel.nodes.count > 5 {
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
}
