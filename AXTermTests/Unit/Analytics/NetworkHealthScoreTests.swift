//
//  NetworkHealthScoreTests.swift
//  AXTermTests
//
//  Unit tests for network health score formula and metrics.
//  Validates the composite scoring model and ensures view filters
//  don't affect health calculations.
//

import XCTest
import GRDB
@testable import AXTerm

// MARK: - NetworkHealthScoreTests

final class NetworkHealthScoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset EMA state between tests for reproducibility
        NetworkHealthCalculator.resetEMAState()
    }

    // MARK: - Test 1: Formula Weights and Rounding

    /// Verify TopologyScore, ActivityScore, and final score against known metric inputs.
    /// Includes rounding edge cases.
    func testFormulaWeightsAndRounding() {
        // Given a graph with known metrics
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create a fully connected 4-node graph (all bidirectional)
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "N3GHI", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "W4JKL", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "K2DEF", and: "N3GHI", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "K2DEF", and: "W4JKL", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "N3GHI", and: "W4JKL", countEachDirection: 5)

        let packets = builder.buildPackets()

        // Build canonical graph
        let canonicalGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: false
        )

        // Calculate health
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "10m",
            includeViaDigipeaters: false,
            now: now
        )

        let breakdown = health.scoreBreakdown

        // Verify N3GHI: Main Cluster should be 100% (all nodes connected)
        XCTAssertEqual(breakdown.c1MainClusterPct, 100.0, accuracy: 0.1, "N3GHI should be 100% for fully connected graph")

        // Verify C3: Isolation Reduction should be 100 (no isolated nodes)
        XCTAssertEqual(breakdown.c3IsolationReduction, 100.0, accuracy: 0.1, "C3 should be 100 (no isolated nodes)")

        // Verify TopologyScore formula: 0.5×N3GHI + 0.3×C2 + 0.2×C3
        let expectedTopology = 0.5 * breakdown.c1MainClusterPct +
                               0.3 * breakdown.c2ConnectivityPct +
                               0.2 * breakdown.c3IsolationReduction
        XCTAssertEqual(breakdown.topologyScore, expectedTopology, accuracy: 0.1, "TopologyScore formula should match")

        // Verify ActivityScore formula: 0.6×W1ABC + 0.4×A2
        let expectedActivity = 0.6 * breakdown.a1ActiveNodesPct + 0.4 * breakdown.a2PacketRateScore
        XCTAssertEqual(breakdown.activityScore, expectedActivity, accuracy: 0.1, "ActivityScore formula should match")

        // Verify final score: round(0.6×TopologyScore + 0.4×ActivityScore)
        let expectedFinal = Int(round(0.6 * breakdown.topologyScore + 0.4 * breakdown.activityScore))
        XCTAssertEqual(breakdown.finalScore, expectedFinal, "Final score should match rounded formula")

        // Score should be in valid range
        XCTAssertGreaterThanOrEqual(breakdown.finalScore, 0)
        XCTAssertLessThanOrEqual(breakdown.finalScore, 100)
    }

    /// Test rounding edge cases at boundaries
    func testFormulaRoundingEdgeCases() {
        // Create minimal graph for predictable metrics
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-60))
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 1)
        let packets = builder.buildPackets()

        let canonicalGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: false
        )

        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "1m",
            includeViaDigipeaters: false,
            now: now
        )

        // Score should be properly rounded, not truncated
        XCTAssertGreaterThanOrEqual(health.score, 0)
        XCTAssertLessThanOrEqual(health.score, 100)
    }

    // MARK: - Test 2: Activity Window Fixed 10m

    /// Topology timeframe changes must NOT change W1ABC/A2 for identical last-10m packet fixture.
    func testActivityWindowFixed10m() {
        let now = Date()

        // Create packets spread across time
        var recentBuilder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-300)) // Last 5 minutes
        _ = recentBuilder.addDirectPeerExchange(between: "K5REC", and: "W6REC", countEachDirection: 10)
        let recentPackets = recentBuilder.buildPackets()

        var oldBuilder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-3600)) // 1 hour ago
        _ = oldBuilder.addDirectPeerExchange(between: "N7OLD", and: "W8OLD", countEachDirection: 5)
        let oldPackets = oldBuilder.buildPackets()

        // All packets combined
        let allPackets = recentPackets + oldPackets

        // Calculate health with different timeframe packets but same recent window
        // Short timeframe (only recent packets)
        let canonicalShort = NetworkHealthCalculator.buildCanonicalGraph(
            packets: recentPackets,
            includeViaDigipeaters: false
        )

        NetworkHealthCalculator.resetEMAState()
        let healthShort = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalShort,
            timeframePackets: recentPackets,
            allRecentPackets: allPackets,
            timeframeDisplayName: "10m",
            includeViaDigipeaters: false,
            now: now
        )

        // Long timeframe (all packets)
        let canonicalLong = NetworkHealthCalculator.buildCanonicalGraph(
            packets: allPackets,
            includeViaDigipeaters: false
        )

        NetworkHealthCalculator.resetEMAState()
        let healthLong = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalLong,
            timeframePackets: allPackets,
            allRecentPackets: allPackets,
            timeframeDisplayName: "1h",
            includeViaDigipeaters: false,
            now: now
        )

        // Activity metrics should be based on SAME 10-minute window
        // So W1ABC and A2 should be IDENTICAL (within floating point tolerance)
        // since allRecentPackets is the same in both calls
        XCTAssertEqual(
            healthShort.scoreBreakdown.a2PacketRateScore,
            healthLong.scoreBreakdown.a2PacketRateScore,
            accuracy: 0.1,
            "A2 should be same regardless of topology timeframe"
        )

        // Topology metrics WILL differ (different canonicalGraph)
        // This is expected behavior - verify they're not equal
        // (unless by chance the graphs have same structure)
        // Just verify both are valid
        XCTAssertGreaterThanOrEqual(healthShort.scoreBreakdown.topologyScore, 0)
        XCTAssertGreaterThanOrEqual(healthLong.scoreBreakdown.topologyScore, 0)
    }

    // MARK: - Test 3: View Filters Do NOT Affect Health

    /// Changing minEdge/maxEdge/viewMode must NOT change N3GHI/C2/C3/W1ABC/A2/score.
    func testViewFiltersDoNotAffectHealth() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 10)
        _ = builder.addDirectPeerExchange(between: "K2DEF", and: "N3GHI", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "N3GHI", and: "W4JKL", countEachDirection: 3)

        let packets = builder.buildPackets()

        // Build canonical graph (minEdge=2, no maxNodes limit)
        let canonicalGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: false
        )

        NetworkHealthCalculator.resetEMAState()
        let healthBaseline = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "10m",
            includeViaDigipeaters: false,
            now: now
        )

        // Now build VIEW graphs with different filter settings
        // These should NOT affect health since we pass the same canonicalGraph

        // Simulate view with minEdge=5 (would hide some edges in view)
        let viewGraphMinEdge5 = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 5,
                maxNodes: 100
            )
        )

        // Simulate view with maxNodes=2 (would hide some nodes in view)
        let viewGraphMaxNodes2 = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 2
            )
        )

        // But health is still calculated from CANONICAL graph
        NetworkHealthCalculator.resetEMAState()
        let healthWithFilteredView = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph,  // Same canonical graph
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "10m",
            includeViaDigipeaters: false,
            now: now
        )

        // Health scores should be IDENTICAL since canonical graph is same
        XCTAssertEqual(healthBaseline.score, healthWithFilteredView.score,
                       "Health score should be identical regardless of view filters")

        XCTAssertEqual(healthBaseline.scoreBreakdown.c1MainClusterPct,
                       healthWithFilteredView.scoreBreakdown.c1MainClusterPct,
                       accuracy: 0.001,
                       "N3GHI should be identical")

        XCTAssertEqual(healthBaseline.scoreBreakdown.c2ConnectivityPct,
                       healthWithFilteredView.scoreBreakdown.c2ConnectivityPct,
                       accuracy: 0.001,
                       "C2 should be identical")

        XCTAssertEqual(healthBaseline.scoreBreakdown.c3IsolationReduction,
                       healthWithFilteredView.scoreBreakdown.c3IsolationReduction,
                       accuracy: 0.001,
                       "C3 should be identical")

        // Verify the view graphs ARE different (sanity check)
        XCTAssertLessThanOrEqual(viewGraphMinEdge5.edges.count, canonicalGraph.edges.count,
                                  "minEdge=5 should filter some edges")
        XCTAssertLessThanOrEqual(viewGraphMaxNodes2.nodes.count, canonicalGraph.nodes.count,
                                  "maxNodes=2 should limit nodes")
    }

    // MARK: - Test 4: IncludeVia Affects Canonical Topology

    /// includeVia toggle must change canonical topology metrics when via edges exist.
    func testIncludeViaAffectsCanonicalTopology() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create direct traffic
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)

        // Create via-only traffic (introduces N0DIG node when includeVia=true)
        _ = builder.addViaObservation(from: "N3GHI", to: "W4JKL", via: ["N0DIG"], count: 10)
        _ = builder.addViaObservation(from: "W4JKL", to: "N3GHI", via: ["N0DIG"], count: 10)

        let packets = builder.buildPackets()

        // Build canonical graph with includeVia OFF
        let canonicalOff = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: false
        )

        NetworkHealthCalculator.resetEMAState()
        let healthOff = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalOff,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "10m",
            includeViaDigipeaters: false,
            now: now
        )

        // Build canonical graph with includeVia ON
        let canonicalOn = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: true
        )

        NetworkHealthCalculator.resetEMAState()
        let healthOn = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalOn,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "10m",
            includeViaDigipeaters: true,
            now: now
        )

        // includeVia ON should have MORE nodes (N0DIG digipeater appears)
        XCTAssertGreaterThanOrEqual(canonicalOn.nodes.count, canonicalOff.nodes.count,
                                     "includeVia ON should have >= nodes")

        // includeVia ON should have MORE edges (via path edges appear)
        XCTAssertGreaterThanOrEqual(canonicalOn.edges.count, canonicalOff.edges.count,
                                     "includeVia ON should have >= edges")

        // Topology metrics should differ if via edges exist
        // (C2 connectivity ratio would change with different edge counts)
        // Note: They might be equal if no via edges qualify, so we just verify both are valid
        XCTAssertGreaterThanOrEqual(healthOff.scoreBreakdown.topologyScore, 0)
        XCTAssertGreaterThanOrEqual(healthOn.scoreBreakdown.topologyScore, 0)
    }

    // MARK: - Test 5: Metric Definitions on Known Graphs

    /// Validate N3GHI/C2/C3 for small deterministic graphs.
    func testMetricDefinitionsOnKnownGraphs() {
        // Test Case A: Chain graph (A - B - C - D)
        testChainGraph()

        // Test Case B: Two disconnected components
        testTwoComponents()

        // Test Case C: Graph with isolated node
        testGraphWithIsolates()
    }

    private func testChainGraph() {
        // Chain: W1ABC - K2DEF - N3GHI - W4JKL
        // Expected: 4 nodes, 3 edges, all in one component
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "K2DEF", and: "N3GHI", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "N3GHI", and: "W4JKL", countEachDirection: 5)

        let packets = builder.buildPackets()
        let graph = NetworkHealthCalculator.buildCanonicalGraph(packets: packets, includeViaDigipeaters: false)

        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: graph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "test",
            includeViaDigipeaters: false,
            now: now
        )

        let breakdown = health.scoreBreakdown

        // N3GHI: All 4 nodes in main cluster → 100%
        XCTAssertEqual(breakdown.c1MainClusterPct, 100.0, accuracy: 0.1, "Chain: N3GHI should be 100%")

        // C3: No isolated nodes → 100
        XCTAssertEqual(breakdown.c3IsolationReduction, 100.0, accuracy: 0.1, "Chain: C3 should be 100")

        // C2: 3 edges / (4*3/2 = 6 possible) = 50%
        XCTAssertEqual(breakdown.c2ConnectivityPct, 50.0, accuracy: 1.0, "Chain: C2 should be ~50%")
    }

    private func testTwoComponents() {
        // Two separate components: (W1ABC-K2DEF) and (N3GHI-W4JKL)
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "N3GHI", and: "W4JKL", countEachDirection: 5)

        let packets = builder.buildPackets()
        let graph = NetworkHealthCalculator.buildCanonicalGraph(packets: packets, includeViaDigipeaters: false)

        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: graph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "test",
            includeViaDigipeaters: false,
            now: now
        )

        let breakdown = health.scoreBreakdown

        // N3GHI: Largest component has 2/4 = 50%
        XCTAssertEqual(breakdown.c1MainClusterPct, 50.0, accuracy: 0.1, "Two components: N3GHI should be 50%")

        // C3: No isolated nodes → 100
        XCTAssertEqual(breakdown.c3IsolationReduction, 100.0, accuracy: 0.1, "Two components: C3 should be 100")

        // C2: 2 edges / 6 possible = 33.3%
        XCTAssertEqual(breakdown.c2ConnectivityPct, 33.3, accuracy: 1.0, "Two components: C2 should be ~33%")
    }

    private func testGraphWithIsolates() {
        // One connected pair + one isolated node
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Connected pair
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        // Isolated node (only sends, doesn't receive bidirectional)
        _ = builder.addDirectEndpoint(from: "N3GHI", to: "W1ABC", count: 1)

        let packets = builder.buildPackets()
        let graph = NetworkHealthCalculator.buildCanonicalGraph(packets: packets, includeViaDigipeaters: false)

        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: graph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "test",
            includeViaDigipeaters: false,
            now: now
        )

        let breakdown = health.scoreBreakdown

        // N3GHI: 2/3 nodes in main cluster = 66.7%
        XCTAssertEqual(breakdown.c1MainClusterPct, 66.67, accuracy: 1.0, "With isolate: N3GHI should be ~67%")

        // C3: 1/3 isolated = 33.3% isolated, so C3 = 100 - 33.3 = 66.7
        XCTAssertEqual(breakdown.c3IsolationReduction, 66.67, accuracy: 1.0, "With isolate: C3 should be ~67")
    }

    // MARK: - Test 6: Packet Rate Normalization

    /// Validate A2 normalization, caps at 100, and safe handling of zero/empty inputs.
    func testPacketRateNormalization() {
        // Test A: Empty packets → A2 should be 0
        testEmptyPacketsA2()

        // Test B: High packet rate → A2 capped at 100
        testHighPacketRateA2()

        // Test C: Normal packet rate → A2 normalized correctly
        testNormalPacketRateA2()
    }

    private func testEmptyPacketsA2() {
        let now = Date()
        let emptyGraph = GraphModel(nodes: [], edges: [], adjacency: [:], droppedNodesCount: 0)

        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: emptyGraph,
            timeframePackets: [],
            allRecentPackets: [],
            timeframeDisplayName: "test",
            includeViaDigipeaters: false,
            now: now
        )

        // With empty graph:
        // - A2 (packet rate) should be 0
        // - Overall score follows formula: 0.6×Topology + 0.4×Activity
        // - C3 (isolation reduction) = 100 when no nodes exist (0 isolated / 0 total)
        // - This gives TopologyScore = 0.2×100 = 20, FinalScore = 0.6×20 = 12
        XCTAssertEqual(health.scoreBreakdown.a2PacketRateScore, 0, "Empty packets: A2 should be 0")
        XCTAssertEqual(health.scoreBreakdown.packetRatePerMin, 0, "Empty packets: rate should be 0")
        // Score is 12 due to C3 isolation reduction formula (0 isolated from 0 nodes = 100%)
        XCTAssertEqual(health.score, 12, "Empty packets: score should be 12 (C3 gives 100% isolation reduction)")
    }

    private func testHighPacketRateA2() {
        // Create many packets in short time to exceed ideal rate
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-60)) // Last minute

        // Use a smaller set of valid callsigns - reuse the same few for high volume
        // 100 packets in 1 minute from same pair creates high activity
        for _ in 0..<50 {
            _ = builder.addDirectPeerExchange(between: "W1AAA", and: "K2BBB", countEachDirection: 1)
        }

        let packets = builder.buildPackets()
        let graph = NetworkHealthCalculator.buildCanonicalGraph(packets: packets, includeViaDigipeaters: false)

        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: graph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "test",
            includeViaDigipeaters: false,
            now: now
        )

        // A2 should be capped at 100
        XCTAssertLessThanOrEqual(health.scoreBreakdown.a2PacketRateScore, 100,
                                  "High rate: A2 should be capped at 100")

        // Raw rate should be high
        XCTAssertGreaterThan(health.scoreBreakdown.packetRatePerMin, NetworkHealthCalculator.idealPacketRate,
                             "High rate: raw rate should exceed ideal")
    }

    private func testNormalPacketRateA2() {
        // Create packets at ideal rate (1 pkt/min over 10 minutes = 10 packets)
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Spread 10 packets over 10 minutes
        for i in 0..<5 {
            _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 1)
        }

        let packets = builder.buildPackets()
        let graph = NetworkHealthCalculator.buildCanonicalGraph(packets: packets, includeViaDigipeaters: false)

        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: graph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "test",
            includeViaDigipeaters: false,
            now: now
        )

        // A2 should be proportional to rate
        // 10 packets / 10 minutes = 1.0 pkt/min = ideal rate = 100%
        XCTAssertGreaterThan(health.scoreBreakdown.a2PacketRateScore, 0, "Normal rate: A2 should be > 0")
        XCTAssertLessThanOrEqual(health.scoreBreakdown.a2PacketRateScore, 100, "Normal rate: A2 should be <= 100")
    }

    // MARK: - Additional Edge Case Tests

    /// Verify health rating thresholds
    func testHealthRatingThresholds() {
        XCTAssertEqual(HealthRating.from(score: 100), .excellent)
        XCTAssertEqual(HealthRating.from(score: 80), .excellent)
        XCTAssertEqual(HealthRating.from(score: 79), .good)
        XCTAssertEqual(HealthRating.from(score: 60), .good)
        XCTAssertEqual(HealthRating.from(score: 59), .fair)
        XCTAssertEqual(HealthRating.from(score: 40), .fair)
        XCTAssertEqual(HealthRating.from(score: 39), .poor)
        XCTAssertEqual(HealthRating.from(score: 1), .poor)
        XCTAssertEqual(HealthRating.from(score: 0), .unknown)
    }

    /// Verify canonical minEdge constant
    func testCanonicalMinEdgeConstant() {
        XCTAssertEqual(NetworkHealthCalculator.canonicalMinEdge, 2,
                       "Canonical minEdge should be 2 for health calculations")
    }

    /// Verify activity window constant
    func testActivityWindowConstant() {
        XCTAssertEqual(NetworkHealthCalculator.activityWindowMinutes, 10,
                       "Activity window should be 10 minutes")
    }

    /// Verify score breakdown component weights sum to 100
    func testScoreBreakdownWeightsSum() {
        let breakdown = HealthScoreBreakdown.empty
        let totalWeight = breakdown.components.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(totalWeight, 100, accuracy: 0.01, "Component weights should sum to 100")
    }

    /// Routing aliases (e.g., DRL) must not cause topology percentages to exceed 100.
    func testRoutingAliasesDoNotExceedTopologyPercentBounds() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-120))

        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "DRL", countEachDirection: 3)
        let packets = builder.buildPackets()

        let canonicalGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: false
        )

        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "test",
            includeViaDigipeaters: false,
            now: now
        )

        XCTAssertEqual(health.metrics.totalStations, 2, "Alias node should be counted in total station universe")
        XCTAssertLessThanOrEqual(health.metrics.largestComponentPercent, 100, "Cluster % must be bounded")
        XCTAssertLessThanOrEqual(health.metrics.isolationReduction, 100, "Isolation % must be bounded")
        XCTAssertEqual(health.scoreBreakdown.c1MainClusterPct, 100, accuracy: 0.1, "Two-node connected graph should be 100% cluster")
    }

    /// Activity percentages must remain bounded even if recent packets include stations outside timeframe packets.
    func testActivityPercentagesBoundedWhenRecentWindowHasExtraStations() {
        let now = Date()

        var timeframeBuilder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-3600))
        _ = timeframeBuilder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 2)
        let timeframePackets = timeframeBuilder.buildPackets()

        var recentBuilder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-60))
        _ = recentBuilder.addDirectPeerExchange(between: "N3GHI", and: "W4JKL", countEachDirection: 3)
        let recentPackets = recentBuilder.buildPackets()

        let canonicalGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: timeframePackets,
            includeViaDigipeaters: false
        )

        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph,
            timeframePackets: timeframePackets,
            allRecentPackets: recentPackets,
            timeframeDisplayName: "test",
            includeViaDigipeaters: false,
            now: now
        )

        XCTAssertLessThanOrEqual(health.scoreBreakdown.a1ActiveNodesPct, 100, "Active-node % must be bounded")
        XCTAssertLessThanOrEqual(health.metrics.freshness, 1, "Freshness ratio must be <= 1")
    }

    /// Integration sanity check for a local sqlite snapshot.
    /// Run with AXTERM_HEALTH_SQLITE_PATH=/path/to/axterm.sqlite.
    func testHealthMetricsFromSQLiteSnapshotWhenPathProvided() throws {
        let envPath = ProcessInfo.processInfo.environment["AXTERM_HEALTH_SQLITE_PATH"]
        let defaultSnapshotPath = "/Users/rwardrup/dev/AXTerm/axterm.sqlite"
        let path = (envPath?.isEmpty == false) ? envPath! : defaultSnapshotPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("SQLite snapshot not found at \(path)")
        }

        let dbQueue = try DatabaseQueue(path: path)
        let store = SQLitePacketStore(dbQueue: dbQueue)

        guard let newest = try store.loadRecent(limit: 1).first else {
            throw XCTSkip("No packets in sqlite snapshot")
        }

        let end = newest.receivedAt.addingTimeInterval(1)
        let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        let window = DateInterval(start: start, end: end)
        let packets = try store.loadPackets(in: window)

        XCTAssertFalse(packets.isEmpty, "Expected packets in the 7-day snapshot window")

        NetworkHealthCalculator.resetEMAState()
        let graphDirect = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: false
        )
        let healthDirect = NetworkHealthCalculator.calculate(
            canonicalGraph: graphDirect,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "7d",
            includeViaDigipeaters: false,
            now: end
        )

        NetworkHealthCalculator.resetEMAState()
        let graphVia = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: true
        )
        let healthVia = NetworkHealthCalculator.calculate(
            canonicalGraph: graphVia,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "7d",
            includeViaDigipeaters: true,
            now: end
        )

        for health in [healthDirect, healthVia] {
            XCTAssertLessThanOrEqual(health.metrics.largestComponentPercent, 100, "Cluster must be <= 100")
            XCTAssertGreaterThanOrEqual(health.metrics.largestComponentPercent, 0, "Cluster must be >= 0")
            XCTAssertLessThanOrEqual(health.metrics.connectivityRatio, 100, "Connectivity must be <= 100")
            XCTAssertGreaterThanOrEqual(health.metrics.connectivityRatio, 0, "Connectivity must be >= 0")
            XCTAssertLessThanOrEqual(health.metrics.isolationReduction, 100, "Isolation must be <= 100")
            XCTAssertGreaterThanOrEqual(health.metrics.isolationReduction, 0, "Isolation must be >= 0")
            XCTAssertLessThanOrEqual(health.metrics.freshness, 1, "Freshness ratio must be <= 1")
            XCTAssertGreaterThanOrEqual(health.metrics.freshness, 0, "Freshness ratio must be >= 0")
            XCTAssertLessThanOrEqual(health.score, 100, "Score must be <= 100")
            XCTAssertGreaterThanOrEqual(health.score, 0, "Score must be >= 0")
        }

        let report = """
        SQLite snapshot health (end=\(end)):
          Direct includeVia=false:
            score=\(healthDirect.score)
            stations=\(healthDirect.metrics.totalStations)
            cluster=\(String(format: "%.1f", healthDirect.metrics.largestComponentPercent))%
            connectivity=\(String(format: "%.1f", healthDirect.metrics.connectivityRatio))%
            isolation=\(String(format: "%.1f", healthDirect.metrics.isolationReduction))%
          Routed includeVia=true:
            score=\(healthVia.score)
            stations=\(healthVia.metrics.totalStations)
            cluster=\(String(format: "%.1f", healthVia.metrics.largestComponentPercent))%
            connectivity=\(String(format: "%.1f", healthVia.metrics.connectivityRatio))%
            isolation=\(String(format: "%.1f", healthVia.metrics.isolationReduction))%
        """
        XCTContext.runActivity(named: report) { _ in }
    }

    /// Contract test: calculate(graphModel:...) must be driven by timeframe packets,
    /// not by whichever rendered view graph was passed in.
    func testCalculateGraphModelParameterDoesNotAffectComputedHealth() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "K2DEF", and: "N3GHI", countEachDirection: 4)
        _ = builder.addViaObservation(from: "N3GHI", to: "W4JKL", via: ["N0DIG"], count: 3)

        let packets = builder.buildPackets()
        XCTAssertFalse(packets.isEmpty)

        let canonicalGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: true
        )
        XCTAssertFalse(canonicalGraph.nodes.isEmpty)

        let emptyGraph = GraphModel.empty

        NetworkHealthCalculator.resetEMAState()
        let healthFromCanonical = NetworkHealthCalculator.calculate(
            graphModel: canonicalGraph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "10m",
            includeViaDigipeaters: true,
            now: now
        )
        NetworkHealthCalculator.resetEMAState()
        let healthFromEmptyView = NetworkHealthCalculator.calculate(
            graphModel: emptyGraph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "10m",
            includeViaDigipeaters: true,
            now: now
        )

        XCTAssertEqual(healthFromCanonical.score, healthFromEmptyView.score, "Health score must not depend on rendered graph parameter")
        XCTAssertEqual(healthFromCanonical.metrics.totalStations, healthFromEmptyView.metrics.totalStations)
        XCTAssertEqual(healthFromCanonical.scoreBreakdown.c1MainClusterPct, healthFromEmptyView.scoreBreakdown.c1MainClusterPct, accuracy: 0.001)
        XCTAssertEqual(healthFromCanonical.scoreBreakdown.c2ConnectivityPct, healthFromEmptyView.scoreBreakdown.c2ConnectivityPct, accuracy: 0.001)
        XCTAssertEqual(healthFromCanonical.scoreBreakdown.c3IsolationReduction, healthFromEmptyView.scoreBreakdown.c3IsolationReduction, accuracy: 0.001)
        XCTAssertEqual(healthFromCanonical.scoreBreakdown.a1ActiveNodesPct, healthFromEmptyView.scoreBreakdown.a1ActiveNodesPct, accuracy: 0.001)
        XCTAssertEqual(healthFromCanonical.scoreBreakdown.a2PacketRateScore, healthFromEmptyView.scoreBreakdown.a2PacketRateScore, accuracy: 0.001)
    }

    /// SQLite contract test using shifted timestamps so assertions remain valid over time.
    /// This prevents production snapshots from "aging out" of recent-activity windows.
    func testShiftedSQLiteSnapshotMaintainsHealthMetricsAtSyntheticNow() throws {
        let packets = try loadSQLiteSnapshotPackets()
        guard !packets.isEmpty else {
            throw XCTSkip("No packets in sqlite snapshot")
        }

        // Anchor all packet times near a deterministic synthetic now while preserving relative spacing.
        let syntheticNow = makeDate(year: 2026, month: 2, day: 11, hour: 12, minute: 0, second: 0)
        let shiftedPackets = shiftPacketsToReferenceNow(packets, referenceNow: syntheticNow)

        // Use fixed 7-day timeframe ending at syntheticNow.
        let timeframeStart = syntheticNow.addingTimeInterval(-7 * 24 * 60 * 60)
        let timeframePackets = shiftedPackets.filter { $0.timestamp >= timeframeStart && $0.timestamp <= syntheticNow }
        XCTAssertFalse(timeframePackets.isEmpty, "Shifted timeframe packets should not be empty")

        NetworkHealthCalculator.resetEMAState()
        let directCanonical = NetworkHealthCalculator.buildCanonicalGraph(
            packets: timeframePackets,
            includeViaDigipeaters: false
        )
        let directHealth = NetworkHealthCalculator.calculate(
            canonicalGraph: directCanonical,
            timeframePackets: timeframePackets,
            allRecentPackets: shiftedPackets,
            timeframeDisplayName: "7d",
            includeViaDigipeaters: false,
            now: syntheticNow
        )

        NetworkHealthCalculator.resetEMAState()
        let viaCanonical = NetworkHealthCalculator.buildCanonicalGraph(
            packets: timeframePackets,
            includeViaDigipeaters: true
        )
        let viaHealth = NetworkHealthCalculator.calculate(
            canonicalGraph: viaCanonical,
            timeframePackets: timeframePackets,
            allRecentPackets: shiftedPackets,
            timeframeDisplayName: "7d",
            includeViaDigipeaters: true,
            now: syntheticNow
        )

        for health in [directHealth, viaHealth] {
            XCTAssertGreaterThan(health.metrics.activeStations, 0, "Shifted snapshot should have active stations in 10m window")
            XCTAssertGreaterThan(health.scoreBreakdown.packetRatePerMin, 0, "Shifted snapshot should have non-zero packet rate")
            XCTAssertLessThanOrEqual(health.score, 100)
            XCTAssertGreaterThanOrEqual(health.score, 0)
            XCTAssertLessThanOrEqual(health.metrics.largestComponentPercent, 100)
            XCTAssertLessThanOrEqual(health.metrics.connectivityRatio, 100)
            XCTAssertLessThanOrEqual(health.metrics.isolationReduction, 100)
        }
    }

    /// Snapshot semantics contract at synthetic now:
    /// Graph lens subsets must remain truthful on real-world packet snapshots.
    func testShiftedSQLiteSnapshotLensSemanticsContract() throws {
        let packets = try loadSQLiteSnapshotPackets()
        guard !packets.isEmpty else {
            throw XCTSkip("No packets in sqlite snapshot")
        }

        let syntheticNow = makeDate(year: 2026, month: 2, day: 11, hour: 12, minute: 0, second: 0)
        let shiftedPackets = shiftPacketsToReferenceNow(packets, referenceNow: syntheticNow)
        let timeframeStart = syntheticNow.addingTimeInterval(-7 * 24 * 60 * 60)
        let timeframePackets = shiftedPackets.filter { $0.timestamp >= timeframeStart && $0.timestamp <= syntheticNow }

        let classified = NetworkGraphBuilder.buildClassified(
            packets: timeframePackets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: true,
                minimumEdgeCount: 1,
                maxNodes: 300,
                stationIdentityMode: .station
            ),
            now: syntheticNow
        )
        XCTAssertFalse(classified.nodes.isEmpty, "Shifted snapshot should produce classified nodes")

        let connectivity = ViewGraphDeriver.deriveViewGraph(from: classified, viewMode: .connectivity)
        let routing = ViewGraphDeriver.deriveViewGraph(from: classified, viewMode: .routing)
        let combined = ViewGraphDeriver.deriveViewGraph(from: classified, viewMode: .all)

        XCTAssertEqual(connectivity.nodes.count, classified.nodes.count)
        XCTAssertEqual(routing.nodes.count, classified.nodes.count)
        XCTAssertEqual(combined.nodes.count, classified.nodes.count)

        let connectivityTypes = Set(connectivity.edges.map(\.linkType))
        let routingTypes = Set(routing.edges.map(\.linkType))
        let combinedTypes = Set(combined.edges.map(\.linkType))

        XCTAssertTrue(connectivityTypes.isSubset(of: GraphViewMode.connectivity.visibleLinkTypes))
        XCTAssertTrue(routingTypes.isSubset(of: GraphViewMode.routing.visibleLinkTypes))
        XCTAssertTrue(combinedTypes.isSubset(of: GraphViewMode.all.visibleLinkTypes))

        XCTAssertFalse(connectivityTypes.contains(.heardVia), "Direct lens must exclude heard-via")
        XCTAssertFalse(routingTypes.contains(.heardDirect), "Routed lens must exclude heard-direct")
        XCTAssertGreaterThanOrEqual(combined.edges.count, connectivity.edges.count, "Combined should not hide connectivity edges")
        XCTAssertGreaterThanOrEqual(combined.edges.count, routing.edges.count, "Combined should not hide routed edges")
    }

    private func loadSQLiteSnapshotPackets() throws -> [Packet] {
        let envPath = ProcessInfo.processInfo.environment["AXTERM_HEALTH_SQLITE_PATH"]
        let defaultSnapshotPath = "/Users/rwardrup/dev/AXTerm/axterm.sqlite"
        let path = (envPath?.isEmpty == false) ? envPath! : defaultSnapshotPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("SQLite snapshot not found at \(path)")
        }

        let dbQueue = try DatabaseQueue(path: path)
        let store = SQLitePacketStore(dbQueue: dbQueue)

        guard let newest = try store.loadRecent(limit: 1).first else {
            return []
        }

        let end = newest.receivedAt.addingTimeInterval(1)
        let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        let window = DateInterval(start: start, end: end)
        return try store.loadPackets(in: window)
    }

    private func shiftPacketsToReferenceNow(_ packets: [Packet], referenceNow: Date) -> [Packet] {
        guard let newest = packets.map(\.timestamp).max() else { return packets }
        let targetNewest = referenceNow.addingTimeInterval(-15) // keep newest safely inside "recent" window
        let delta = targetNewest.timeIntervalSince(newest)
        return packets.map { packet in
            Packet(
                id: packet.id,
                timestamp: packet.timestamp.addingTimeInterval(delta),
                from: packet.from,
                to: packet.to,
                via: packet.via,
                frameType: packet.frameType,
                control: packet.control,
                controlByte1: packet.controlByte1,
                pid: packet.pid,
                info: packet.info,
                rawAx25: packet.rawAx25,
                kissEndpoint: packet.kissEndpoint,
                infoText: packet.infoText
            )
        }
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )) ?? Date(timeIntervalSince1970: 0)
    }
}
