//
//  NetworkHealthModel.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation

/// Network health metrics and scoring model for APRS/AX.25 packet radio networks.
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

    static let empty = NetworkHealth(
        score: 0,
        rating: .unknown,
        reasons: [],
        metrics: .empty,
        warnings: [],
        activityTrend: []
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

struct NetworkHealthMetrics: Hashable, Sendable {
    /// Total unique stations heard this session
    let totalStations: Int
    /// Stations active in the last 10 minutes
    let activeStations: Int
    /// Total packets received this session
    let totalPackets: Int
    /// Current packet rate (packets per minute, rolling average)
    let packetRate: Double
    /// Percentage of nodes in the largest connected component
    let largestComponentPercent: Double
    /// Percentage of traffic handled by the top relay/digipeater
    let topRelayConcentration: Double
    /// Name of the top relay (if any)
    let topRelayCallsign: String?
    /// Average node freshness (0-1, where 1 = all nodes active recently)
    let freshness: Double
    /// Number of isolated nodes (no connections)
    let isolatedNodes: Int

    static let empty = NetworkHealthMetrics(
        totalStations: 0,
        activeStations: 0,
        totalPackets: 0,
        packetRate: 0,
        largestComponentPercent: 0,
        topRelayConcentration: 0,
        topRelayCallsign: nil,
        freshness: 0,
        isolatedNodes: 0
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
enum NetworkHealthCalculator {
    /// Scoring weights for health index components
    private enum Weights {
        static let activity: Double = 0.25      // Is traffic flowing?
        static let freshness: Double = 0.20     // Are nodes recently active?
        static let connectivity: Double = 0.25  // Is the network well-connected?
        static let redundancy: Double = 0.20    // Is there relay diversity?
        static let stability: Double = 0.10     // Consistent packet rate?
    }

    /// Calculate network health from current state
    static func calculate(
        graphModel: GraphModel,
        packets: [Packet],
        recentWindowMinutes: Int = 10,
        trendWindowMinutes: Int = 60,
        trendBucketMinutes: Int = 5,
        now: Date = Date()
    ) -> NetworkHealth {
        let metrics = calculateMetrics(
            graphModel: graphModel,
            packets: packets,
            recentWindowMinutes: recentWindowMinutes,
            now: now
        )

        let (score, reasons) = calculateScore(metrics: metrics, graphModel: graphModel)
        let warnings = generateWarnings(metrics: metrics, graphModel: graphModel)
        let trend = calculateActivityTrend(
            packets: packets,
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
            activityTrend: trend
        )
    }

    private static func calculateMetrics(
        graphModel: GraphModel,
        packets: [Packet],
        recentWindowMinutes: Int,
        now: Date
    ) -> NetworkHealthMetrics {
        let totalStations = graphModel.nodes.count
        let totalPackets = packets.count

        // Calculate active stations (heard in last N minutes)
        let recentCutoff = now.addingTimeInterval(-Double(recentWindowMinutes * 60))
        let recentPackets = packets.filter { $0.timestamp >= recentCutoff }
        var activeCallsigns: Set<String> = []
        for packet in recentPackets {
            if let from = packet.from?.call { activeCallsigns.insert(from) }
            if let to = packet.to?.call { activeCallsigns.insert(to) }
        }
        let activeStations = activeCallsigns.count

        // Calculate packet rate (packets per minute over recent window)
        let windowDuration = max(1, Double(recentWindowMinutes))
        let packetRate = Double(recentPackets.count) / windowDuration

        // Calculate largest connected component percentage
        let largestComponentPercent = calculateLargestComponentPercent(graphModel: graphModel)

        // Calculate relay concentration
        let (topRelayPercent, topRelayCallsign) = calculateRelayConcentration(graphModel: graphModel)

        // Calculate freshness (ratio of active to total stations)
        let freshness = totalStations > 0 ? Double(activeStations) / Double(totalStations) : 0

        // Count isolated nodes
        let isolatedNodes = graphModel.nodes.filter { $0.degree == 0 }.count

        return NetworkHealthMetrics(
            totalStations: totalStations,
            activeStations: activeStations,
            totalPackets: totalPackets,
            packetRate: packetRate,
            largestComponentPercent: largestComponentPercent,
            topRelayConcentration: topRelayPercent,
            topRelayCallsign: topRelayCallsign,
            freshness: freshness,
            isolatedNodes: isolatedNodes
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

    private static func calculateScore(
        metrics: NetworkHealthMetrics,
        graphModel: GraphModel
    ) -> (Int, [String]) {
        var reasons: [String] = []

        // Activity score (0-100): Based on packet rate
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
            reasons.append("Healthy packet activity (\(String(format: "%.1f", metrics.packetRate))/min)")
        } else if activityScore > 0 {
            reasons.append("Low packet activity")
        }

        // Freshness score (0-100): Ratio of active to total stations
        let freshnessScore = metrics.freshness * 100
        if freshnessScore >= 50 {
            reasons.append("\(metrics.activeStations) stations active recently")
        }

        // Connectivity score (0-100): Largest component percentage
        let connectivityScore = metrics.largestComponentPercent
        if connectivityScore >= 80 {
            reasons.append("Well-connected network")
        } else if connectivityScore >= 50 && connectivityScore < 80 {
            reasons.append("Moderately connected (\(Int(connectivityScore))% in main cluster)")
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
        // For now, use a simple heuristic based on total stations vs packets
        let stabilityScore: Double
        if metrics.totalStations > 0 && metrics.totalPackets > 0 {
            let packetsPerStation = Double(metrics.totalPackets) / Double(metrics.totalStations)
            stabilityScore = min(100, packetsPerStation * 10)
        } else {
            stabilityScore = 0
        }

        // Weighted final score
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

        return (finalScore, Array(reasons.prefix(3)))
    }

    private static func generateWarnings(
        metrics: NetworkHealthMetrics,
        graphModel: GraphModel
    ) -> [NetworkWarning] {
        var warnings: [NetworkWarning] = []

        // Single-point relay dominance
        if metrics.topRelayConcentration > 60, let relay = metrics.topRelayCallsign {
            warnings.append(NetworkWarning(
                id: "relay_dominance",
                severity: .caution,
                title: "Single relay dominance",
                detail: "\(relay) handles \(Int(metrics.topRelayConcentration))% of traffic"
            ))
        }

        // Stale nodes warning
        if metrics.totalStations > 0 && metrics.freshness < 0.3 {
            let staleCount = metrics.totalStations - metrics.activeStations
            warnings.append(NetworkWarning(
                id: "stale_nodes",
                severity: .info,
                title: "Stale stations",
                detail: "\(staleCount) stations not heard in 10 minutes"
            ))
        }

        // Fragmented network
        if metrics.largestComponentPercent < 50 && graphModel.nodes.count > 5 {
            warnings.append(NetworkWarning(
                id: "fragmented",
                severity: .caution,
                title: "Fragmented network",
                detail: "Only \(Int(metrics.largestComponentPercent))% of stations connected"
            ))
        }

        // Isolated nodes
        if metrics.isolatedNodes > 0 {
            warnings.append(NetworkWarning(
                id: "isolated",
                severity: .info,
                title: "Isolated stations",
                detail: "\(metrics.isolatedNodes) station\(metrics.isolatedNodes == 1 ? "" : "s") with no connections"
            ))
        }

        // Low activity
        if metrics.packetRate < 0.1 && metrics.totalPackets > 0 {
            warnings.append(NetworkWarning(
                id: "low_activity",
                severity: .info,
                title: "Low activity",
                detail: "Less than 6 packets per hour"
            ))
        }

        return warnings
    }
}
