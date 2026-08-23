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
nonisolated struct NetworkHealth: Hashable, Sendable {
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
nonisolated struct HealthScoreBreakdown: Hashable, Sendable {
    // Topology metrics (timeframe-dependent, canonical graph) - 60% of final score
    let c1MainClusterPct: Double       // % of nodes in largest connected component
    let c2ConnectivityPct: Double      // mean degree vs target (capped at 100)
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

nonisolated enum HealthRating: String, Hashable, Sendable {
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
nonisolated struct NetworkHealthMetrics: Hashable, Sendable {
    // MARK: - Topology Metrics (canonical graph, depends on selected timeframe)

    /// Total unique stations in the canonical graph
    let totalStations: Int
    /// Total packets received during the selected timeframe
    let totalPackets: Int
    /// C1: Percentage of nodes in the largest connected component (0-100)
    let largestComponentPercent: Double
    /// C2: Connectivity = mean degree / target mean degree × 100 (capped at 100)
    let connectivityRatio: Double
    /// C3: 100 - (% isolated nodes). Higher is better.
    let isolationReduction: Double
    /// Stations heard in the timeframe with no observed link to another valid station
    let isolatedNodes: Int
    /// Name of the top relay (highest degree node)
    let topRelayCallsign: String?
    /// Percentage of edges involving the top relay
    let topRelayConcentration: Double

    // MARK: - Activity Metrics (fixed 10-minute window)

    /// Stations active in the last 10 minutes (fixed window, independent of timeframe)
    let activeStations: Int
    /// Current packet rate (packets per minute over the last 10 minutes)
    let packetRate: Double
    /// Ratio of active stations to total stations (freshness indicator)
    let freshness: Double

    /// Fraction of the timeframe during which the app was actually listening
    /// (1.0 when unknown or fully covered). Quiet spans outside coverage are
    /// app downtime, not network silence.
    let coverageFraction: Double

    static let empty = NetworkHealthMetrics(
        totalStations: 0,
        totalPackets: 0,
        largestComponentPercent: 0,
        connectivityRatio: 0,
        isolationReduction: 0,
        isolatedNodes: 0,
        topRelayCallsign: nil,
        topRelayConcentration: 0,
        activeStations: 0,
        packetRate: 0,
        freshness: 0,
        coverageFraction: 1
    )
}

nonisolated struct NetworkWarning: Hashable, Identifiable, Sendable {
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
///    - Uses `canonicalMinEdge = 1` (not the view slider)
///    - Has no max-node limit (shows full network topology)
///    - Applies the `includeViaDigipeaters` toggle
///    - **Ignores** view-only filters (Min Edge slider, Max Node count)
///
/// 2. **Hybrid Time Windows**:
///    - Topology metrics: Based on user-selected timeframe
///    - Activity metrics: Fixed 10-minute window (unless TF < 10m)
///
/// 3. **Determinism**: same inputs always produce the same score — no cross-call state.
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
/// - C2 = Connectivity % (mean degree / target mean degree × 100, capped at 100)
/// - C3 = Isolation Reduction (100 - % isolated nodes)
/// - A1 = Active Nodes % (stations in last 10m / total nodes × 100)
/// - A2 = Packet Rate Score (ramps to 100 at 1.0 pkt/min, declines past congestion onset)
///
/// Reference: Composite health scoring approach inspired by network monitoring (e.g., Optigo Networks).
nonisolated enum NetworkHealthCalculator {
    /// Canonical minimum edge count for health topology graph.
    /// 1: any observed link is topology evidence. A single decoded frame proves the
    /// stations exist and can reach each other; requiring 2+ frames made a station
    /// heard once read as "isolated" (a false statement) and produced a score cliff
    /// between the first and second packet of a pair.
    static let canonicalMinEdge: Int = 1

    /// Fixed window for activity metrics (clamped to the timeframe when shorter)
    static let activityWindowMinutes: Int = 10

    /// Ideal packet rate for normalization (packets per minute).
    /// Networks at or above this rate score a full 100 for A2 until congestion onset.
    static let idealPacketRate: Double = 1.0

    /// Rate at which a shared 1200-baud AX.25 channel approaches saturation.
    /// A typical ~200-byte frame occupies ~1.4 s of air time, so ~30 frames/min is
    /// already heavy CSMA contention; A2 declines above this instead of rewarding it.
    static let congestionOnsetRate: Double = 30.0

    /// Rate treated as fully saturated (collision-dominated); A2 floors at
    /// `saturatedScore` from here up.
    static let saturatedRate: Double = 60.0

    /// A2 floor for a saturated channel.
    static let saturatedScore: Double = 20.0

    /// Minimum evidence required to emit a score at all. Below this the sample is too
    /// small for any composite to be meaningful (two stations exchanging two packets
    /// used to rate "Excellent").
    static let minimumStationsForScore: Int = 3
    static let minimumPacketsForScore: Int = 10

    /// Target mean degree for C2. Packet-radio meshes have bounded per-node RF
    /// neighborhoods; ~3 links per station provides path redundancy without saturating
    /// a shared channel. Mean degree is size-invariant, unlike graph density
    /// (edges / n(n-1)/2), which decays as O(1/n) and made the old C2 punish growth.
    static let targetMeanDegree: Double = 3.0

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
        stationIdentityMode: StationIdentityMode = .station,
        timeframeDuration: TimeInterval? = nil,
        coverage: CaptureCoverage? = nil,
        trendWindowMinutes: Int = 60,
        trendBucketMinutes: Int = 5,
        now: Date = Date()
    ) -> NetworkHealth {
        let metrics = calculateMetrics(
            canonicalGraph: canonicalGraph,
            timeframePackets: timeframePackets,
            allRecentPackets: allRecentPackets,
            includeViaDigipeaters: includeViaDigipeaters,
            stationIdentityMode: stationIdentityMode,
            timeframeDuration: timeframeDuration,
            coverage: coverage,
            now: now
        )

        let breakdown = calculateCompositeScore(metrics: metrics)
        let trend = calculateActivityTrend(
            packets: allRecentPackets,
            windowMinutes: trendWindowMinutes,
            bucketMinutes: trendBucketMinutes,
            now: now
        )

        // Sample gate: with almost no evidence any composite is noise. Keep the
        // metrics and breakdown for the explainer, but report Unknown instead of a
        // score built from two packets.
        if metrics.totalStations < minimumStationsForScore || metrics.totalPackets < minimumPacketsForScore {
            let reason = metrics.totalPackets == 0
                ? "No packets in the selected timeframe"
                : "Not enough data to score (needs ≥\(minimumStationsForScore) stations and ≥\(minimumPacketsForScore) packets)"
            return NetworkHealth(
                score: 0,
                rating: .unknown,
                reasons: [reason],
                metrics: metrics,
                warnings: [],
                activityTrend: trend,
                scoreBreakdown: breakdown,
                timeframeDisplayName: timeframeDisplayName
            )
        }

        let reasons = generateReasons(metrics: metrics, breakdown: breakdown, timeframeDisplayName: timeframeDisplayName)
        let warnings = generateWarnings(
            metrics: metrics,
            canonicalGraph: canonicalGraph,
            timeframeDisplayName: timeframeDisplayName,
            timeframeDuration: timeframeDuration
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

    /// Convenience entry point: builds the canonical graph internally.
    /// Health is a function of the timeframe packets alone — it deliberately takes no
    /// rendered view graph, so view filters cannot influence it.
    static func calculate(
        timeframePackets: [Packet],
        allRecentPackets: [Packet],
        timeframeDisplayName: String,
        includeViaDigipeaters: Bool = true,
        stationIdentityMode: StationIdentityMode = .station,
        timeframeDuration: TimeInterval? = nil,
        coverage: CaptureCoverage? = nil,
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
            stationIdentityMode: stationIdentityMode,
            timeframeDuration: timeframeDuration,
            coverage: coverage,
            trendWindowMinutes: trendWindowMinutes,
            trendBucketMinutes: trendBucketMinutes,
            now: now
        )
    }

    /// Build the canonical topology graph for health metrics.
    /// Uses canonicalMinEdge (1) and unlimited max nodes.
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
        includeViaDigipeaters: Bool,
        stationIdentityMode: StationIdentityMode,
        timeframeDuration: TimeInterval?,
        coverage: CaptureCoverage?,
        now: Date
    ) -> NetworkHealthMetrics {
        // TOPOLOGY METRICS (from canonical graph)
        let countedStations = calculateTotalStations(
            packets: timeframePackets,
            includeViaDigipeaters: includeViaDigipeaters,
            identityMode: stationIdentityMode
        )
        // Keep denominator aligned with canonical graph membership.
        // Graph may include routing aliases (e.g., DRL/DRLNOD) that strict callsign-only
        // counting previously excluded, which could produce >100% topology metrics.
        let totalNodes = max(countedStations, canonicalGraph.nodes.count)
        let totalPackets = timeframePackets.count

        // C1: Main Cluster % = largest connected component / total nodes × 100
        let c1MainClusterPct = clampPercent(calculateLargestComponentPercent(
            graph: canonicalGraph,
            totalNodesOverride: totalNodes
        ))

        // C2: mean degree relative to the target (size-invariant connectivity).
        // Graph density (edges / n(n-1)/2) decays as O(1/n) for bounded-degree RF
        // networks, which made C2 unreachable for any real network and rewarded
        // degenerate two-node graphs with 100%.
        let actualEdges = canonicalGraph.edges.count
        let meanDegree = totalNodes > 0 ? 2.0 * Double(actualEdges) / Double(totalNodes) : 0
        let c2ConnectivityPct = clampPercent(meanDegree / targetMeanDegree * 100)

        // C3: Isolation Reduction = 100 - (% isolated nodes).
        // An empty network has nothing to praise: 0, not 100.
        let graphNodeIDs = Set(canonicalGraph.nodes.map(\.id))
        let isolatedCount = max(0, totalNodes - graphNodeIDs.count)
        let c3IsolationReduction: Double
        if totalNodes > 0 {
            let isolatedPct = clampPercent(Double(isolatedCount) / Double(totalNodes) * 100)
            c3IsolationReduction = clampPercent(100 - isolatedPct)
        } else {
            c3IsolationReduction = 0
        }

        // Relay concentration (for warnings)
        let (topRelayPct, topRelayCallsign) = calculateRelayConcentration(graph: canonicalGraph)

        // ACTIVITY METRICS: 10-minute window, clamped to the timeframe when the
        // user selected a shorter one (otherwise the numerator would come from a
        // wider window than the denominator and silently saturate).
        let windowSeconds = min(Double(activityWindowMinutes * 60), timeframeDuration ?? .infinity)
        let activityCutoff = now.addingTimeInterval(-windowSeconds)
        let recentPackets = allRecentPackets.filter { $0.timestamp >= activityCutoff }

        // A1 source count uses the same station-identity normalization as totalNodes.
        // This keeps percentages stable when SSIDs are grouped into station identities.
        let activeStationsRaw = calculateTotalStations(
            packets: recentPackets,
            includeViaDigipeaters: includeViaDigipeaters,
            identityMode: stationIdentityMode
        )
        let activeStations = min(activeStationsRaw, totalNodes)

        // Packet rate over the observed span. If the buffer's earliest packet lies
        // inside the window we may not have been listening for the whole window, so
        // divide by the span we actually observed (floor 1 minute) instead of
        // under-reporting by up to the full window right after launch.
        // The 10-minute window is itself the smoothing; no cross-call EMA state
        // (a per-invocation EMA made the rate depend on UI recompute frequency).
        let earliestAvailable = allRecentPackets.map(\.timestamp).min()
        var effectiveSeconds: Double
        if let earliestAvailable, earliestAvailable > activityCutoff {
            effectiveSeconds = max(60, now.timeIntervalSince(earliestAvailable))
        } else {
            effectiveSeconds = max(60, windowSeconds)
        }
        // Coverage-aware denominator: divide by listening time within the
        // window, not wall time — reopening the app after downtime must not
        // under-report a live channel.
        if let coverage {
            let activityWindow = DateInterval(start: activityCutoff, end: now)
            let covered = coverage.coveredSeconds(in: activityWindow)
            if covered >= 60 {
                effectiveSeconds = min(effectiveSeconds, covered)
            }
        }
        let smoothedRate = Double(recentPackets.count) / (effectiveSeconds / 60)

        // Freshness = active / total (same identity model for numerator + denominator)
        let freshness = clampRatio(totalNodes > 0 ? Double(activeStations) / Double(totalNodes) : 0)

        let coverageFraction: Double
        if let coverage, let timeframeDuration, timeframeDuration > 0 {
            let window = DateInterval(start: now.addingTimeInterval(-timeframeDuration), end: now)
            coverageFraction = coverage.coverageFraction(in: window)
        } else {
            coverageFraction = 1
        }

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
            freshness: freshness,
            coverageFraction: coverageFraction
        )
    }

    /// Calculate the composite health score using the new formula.
    private static func calculateCompositeScore(metrics: NetworkHealthMetrics) -> HealthScoreBreakdown {
        // Topology components (0-100 each)
        let c1 = clampPercent(metrics.largestComponentPercent)
        let c2 = clampPercent(metrics.connectivityRatio)
        let c3 = clampPercent(metrics.isolationReduction)

        // TopologyScore = 0.5×C1 + 0.3×C2 + 0.2×C3
        let topologyScore = 0.5 * c1 + 0.3 * c2 + 0.2 * c3

        // Activity components (0-100 each)
        let a1 = clampPercent(metrics.totalStations > 0
            ? Double(metrics.activeStations) / Double(metrics.totalStations) * 100
            : 0)

        // A2: ramps to 100 at the ideal rate, holds through normal load, then
        // declines toward the congestion floor — on a shared CSMA channel a busier
        // channel past ~30 frames/min is collision territory, not better health.
        let rate = metrics.packetRate
        let a2: Double
        if rate <= 0 {
            a2 = 0
        } else if rate < idealPacketRate {
            a2 = clampPercent(rate / idealPacketRate * 100)
        } else if rate <= congestionOnsetRate {
            a2 = 100
        } else if rate < saturatedRate {
            let t = (rate - congestionOnsetRate) / (saturatedRate - congestionOnsetRate)
            a2 = clampPercent(100 - t * (100 - saturatedScore))
        } else {
            a2 = saturatedScore
        }

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

    private static func calculateLargestComponentPercent(
        graph: GraphModel,
        totalNodesOverride: Int
    ) -> Double {
        guard !graph.nodes.isEmpty, totalNodesOverride > 0 else { return 0 }

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

        return clampPercent(Double(largestComponentSize) / Double(totalNodesOverride) * 100)
    }

    private static func calculateTotalStations(
        packets: [Packet],
        includeViaDigipeaters: Bool,
        identityMode: StationIdentityMode = .station
    ) -> Int {
        guard !packets.isEmpty else { return 0 }

        var stations: Set<String> = []

        for packet in packets {
            if let from = packet.from?.display, CallsignValidator.isValidRoutingNode(from) {
                stations.insert(CallsignParser.identityKey(for: from, mode: identityMode))
            }
            if let to = packet.to?.display, CallsignValidator.isValidRoutingNode(to) {
                stations.insert(CallsignParser.identityKey(for: to, mode: identityMode))
            }
            if includeViaDigipeaters {
                for via in packet.via where via.repeated {
                    if CallsignValidator.isValidRoutingNode(via.display) {
                        stations.insert(CallsignParser.identityKey(for: via.display, mode: identityMode))
                    }
                }
            }
        }

        return stations.count
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func clampRatio(_ value: Double) -> Double {
        min(1, max(0, value))
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

        // Packet rate reason (positive observations only — negatives are warnings)
        if metrics.packetRate >= idealPacketRate && metrics.packetRate <= congestionOnsetRate {
            reasons.append("Healthy traffic (\(String(format: "%.1f", metrics.packetRate))/min)")
        }

        // Ensure at least one reason
        if reasons.isEmpty {
            if breakdown.finalScore == 0 || metrics.totalStations == 0 {
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
        timeframeDisplayName: String,
        timeframeDuration: TimeInterval?
    ) -> [NetworkWarning] {
        var warnings: [NetworkWarning] = []
        let tfLabel = timeframeDisplayName.isEmpty ? "" : " (\(timeframeDisplayName))"

        // Single-point relay dominance. Skipped for tiny graphs, where the top node
        // trivially touches most links. Concentration is measured over distinct
        // links, not traffic volume — the copy must say so.
        if metrics.topRelayConcentration > 60,
           let relay = metrics.topRelayCallsign,
           canonicalGraph.nodes.count > 4 {
            warnings.append(NetworkWarning(
                id: "relay_dominance",
                severity: .caution,
                title: "Single relay dominance",
                detail: "\(relay) is on \(Int(metrics.topRelayConcentration.rounded()))% of network links\(tfLabel)"
            ))
        }

        // Partial capture coverage: quiet spans may be OUR downtime, not the
        // network's. Called out first, and the downtime-sensitive warnings below
        // are suppressed under it.
        let hasReliableCoverage = metrics.coverageFraction >= 0.5
        if metrics.coverageFraction < 0.6 {
            warnings.append(NetworkWarning(
                id: "partial_coverage",
                severity: .info,
                title: "Partial capture coverage\(tfLabel)",
                detail: String(
                    format: "Listening for %.0f%% of this window — quiet spans may be app downtime, not network silence",
                    metrics.coverageFraction * 100
                )
            ))
        }

        // Stale stations: only meaningful for short timeframes. Over 24h it is
        // *expected* that most of the day's stations were quiet in the last 10
        // minutes, so the warning would fire permanently and carry no signal.
        if metrics.totalStations > 0,
           metrics.freshness < 0.3,
           hasReliableCoverage,
           let duration = timeframeDuration,
           duration <= 3600 {
            let staleCount = metrics.totalStations - metrics.activeStations
            warnings.append(NetworkWarning(
                id: "stale_nodes",
                severity: .info,
                title: "Stale stations\(tfLabel)",
                detail: "\(staleCount) of \(metrics.totalStations) stations quiet for 10+ minutes"
            ))
        }

        // Fragmented network (timeframe-dependent - explicit label)
        if metrics.largestComponentPercent < 50 && canonicalGraph.nodes.count > 5 && hasReliableCoverage {
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
                detail: String(format: "Packet rate %.2f/min over the last 10 minutes", metrics.packetRate)
            ))
        }

        return warnings
    }
}
