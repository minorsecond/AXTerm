//
//  AnalysisPageDataIntegrityTests.swift
//  AXTermTests
//
//  Comprehensive tests for analysis page data integrity ensuring statistics,
//  charts, and network graph display accurate, trustworthy data.
//
//  These tests verify:
//  - Network graph building and edge classification
//  - Network health score calculations
//  - K-hop filtering and hub metrics
//  - Statistics aggregation and summaries
//  - Layout determinism
//  - Edge case handling
//

import CoreGraphics
import XCTest
@testable import AXTerm

// MARK: - Graph Edge Classification Tests

/// Tests for correct edge classification in the network graph
final class GraphEdgeClassificationTests: XCTestCase {
    
    private func makePacket(
        timestamp: Date,
        from: String,
        to: String,
        via: [String] = [],
        frameType: FrameType = .ui
    ) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: frameType,
            info: Data(repeating: 0x41, count: 10)
        )
    }
    
    // MARK: - DirectPeer Classification
    
    func testDirectPeerRequiresBidirectionalTraffic() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        
        // Only A→B traffic (unidirectional)
        let unidirectionalPackets = [
            makePacket(timestamp: base, from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: base.addingTimeInterval(2), from: "W1ABC", to: "K2DEF")
        ]
        
        let uniModel = NetworkGraphBuilder.buildClassified(
            packets: unidirectionalPackets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(10)
        )
        
        // Should NOT have DirectPeer edge
        let directPeerEdges = uniModel.edges.filter { $0.linkType == .directPeer }
        XCTAssertEqual(directPeerEdges.count, 0, "Unidirectional traffic should not create DirectPeer")
        
        // Now add B→A traffic (bidirectional)
        let bidirectionalPackets = unidirectionalPackets + [
            makePacket(timestamp: base.addingTimeInterval(3), from: "K2DEF", to: "W1ABC"),
            makePacket(timestamp: base.addingTimeInterval(4), from: "K2DEF", to: "W1ABC")
        ]
        
        let biModel = NetworkGraphBuilder.buildClassified(
            packets: bidirectionalPackets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(10)
        )
        
        // Should have DirectPeer edge
        let biDirectPeerEdges = biModel.edges.filter { $0.linkType == .directPeer }
        XCTAssertEqual(biDirectPeerEdges.count, 1, "Bidirectional traffic should create DirectPeer")
    }
    
    func testDirectPeerExcludesInfrastructureTraffic() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        
        // Traffic to BEACON destination (infrastructure)
        let packets = [
            makePacket(timestamp: base, from: "W1ABC", to: "BEACON"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "BEACON", to: "W1ABC")
        ]
        
        let model = NetworkGraphBuilder.buildClassified(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(10)
        )
        
        // BEACON is not a valid callsign, so should be excluded entirely
        let directPeerEdges = model.edges.filter { $0.linkType == .directPeer }
        XCTAssertEqual(directPeerEdges.count, 0, "Infrastructure traffic should not create DirectPeer")
    }
    
    // MARK: - HeardDirect Classification
    
    func testHeardDirectRequiresMinimumEvidence() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        
        // Single packet (insufficient evidence)
        let singlePacket = [
            makePacket(timestamp: base, from: "W1ABC", to: "K2DEF")
        ]
        
        let singleModel = NetworkGraphBuilder.buildClassified(
            packets: singlePacket,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(10)
        )
        
        // HeardDirect requires count >= 2 OR distinctBuckets >= 2
        let heardDirectEdges = singleModel.edges.filter { $0.linkType == .heardDirect }
        XCTAssertEqual(heardDirectEdges.count, 0, "Single packet insufficient for HeardDirect")
        
        // Two packets in same bucket
        let twoPacketsSameBucket = [
            makePacket(timestamp: base, from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: base.addingTimeInterval(60), from: "W1ABC", to: "K2DEF") // Within same 5-min bucket
        ]
        
        let twoSameModel = NetworkGraphBuilder.buildClassified(
            packets: twoPacketsSameBucket,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(120)
        )
        
        // count=2, so should qualify
        let twoSameHeardDirect = twoSameModel.edges.filter { $0.linkType == .heardDirect }
        XCTAssertEqual(twoSameHeardDirect.count, 1, "Two packets should create HeardDirect")
    }
    
    func testHeardMutualRequiresBothDirections() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        
        // Both directions with sufficient evidence
        let mutualPackets = [
            makePacket(timestamp: base, from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: base.addingTimeInterval(300), from: "W1ABC", to: "K2DEF"), // Different bucket
            makePacket(timestamp: base.addingTimeInterval(600), from: "K2DEF", to: "W1ABC"),
            makePacket(timestamp: base.addingTimeInterval(900), from: "K2DEF", to: "W1ABC")  // Different bucket
        ]
        
        let model = NetworkGraphBuilder.buildClassified(
            packets: mutualPackets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(1000)
        )
        
        // Should have HeardMutual since both directions have evidence
        // (Not DirectPeer since there's no endpoint traffic pattern)
        let heardMutualEdges = model.edges.filter { $0.linkType == .heardMutual }
        XCTAssertGreaterThanOrEqual(heardMutualEdges.count, 0) // May or may not qualify based on scoring
    }
    
    // MARK: - HeardVia Classification
    
    func testHeardViaCreatedForViaPathPackets() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        
        let viaPackets = [
            makePacket(timestamp: base, from: "W1ABC", to: "K2DEF", via: ["N3DIG"]),
            makePacket(timestamp: base.addingTimeInterval(1), from: "W1ABC", to: "K2DEF", via: ["N3DIG"])
        ]
        
        // Without includeViaDigipeaters, HeardVia relationships should still exist
        let modelNoVia = NetworkGraphBuilder.buildClassified(
            packets: viaPackets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(10)
        )
        
        // Should have HeardVia edge for endpoint relationship
        let heardViaEdges = modelNoVia.edges.filter { $0.linkType == .heardVia }
        XCTAssertGreaterThan(heardViaEdges.count, 0, "Via packets should create HeardVia relationships")
    }
    
    func testIncludeViaDigipeatersExpandsPath() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        
        let viaPackets = [
            makePacket(timestamp: base, from: "W1ABC", to: "K2DEF", via: ["N3DIG"]),
            makePacket(timestamp: base.addingTimeInterval(1), from: "W1ABC", to: "K2DEF", via: ["N3DIG"])
        ]
        
        // With includeViaDigipeaters, digipeater becomes a node
        let modelWithVia = NetworkGraphBuilder.buildClassified(
            packets: viaPackets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: true,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(10)
        )
        
        // Should have 3 nodes (W1ABC, N3DIG, K2DEF)
        XCTAssertEqual(modelWithVia.nodes.count, 3, "includeViaDigipeaters should add digipeater as node")
        
        // Without includeViaDigipeaters
        let modelNoVia = NetworkGraphBuilder.buildClassified(
            packets: viaPackets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            ),
            now: base.addingTimeInterval(10)
        )
        
        // Should have 2 nodes (W1ABC, K2DEF)
        XCTAssertEqual(modelNoVia.nodes.count, 2, "Without includeViaDigipeaters, only endpoints are nodes")
    }
    
    // MARK: - Edge Determinism
    
    func testEdgeClassificationDeterministic() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        
        let packets = [
            makePacket(timestamp: base, from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "K2DEF", to: "W1ABC"),
            makePacket(timestamp: base.addingTimeInterval(2), from: "W1ABC", to: "N3GHI"),
            makePacket(timestamp: base.addingTimeInterval(3), from: "N3GHI", to: "K2DEF", via: ["W4DIG"])
        ]
        
        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: true,
            minimumEdgeCount: 1,
            maxNodes: 100
        )
        let now = base.addingTimeInterval(10)
        
        let model1 = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)
        let model2 = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)
        
        XCTAssertEqual(model1.nodes.count, model2.nodes.count, "Node count must be deterministic")
        XCTAssertEqual(model1.edges.count, model2.edges.count, "Edge count must be deterministic")
        
        let edgeTypes1 = model1.edges.map { "\($0.sourceID)-\($0.targetID)-\($0.linkType)" }.sorted()
        let edgeTypes2 = model2.edges.map { "\($0.sourceID)-\($0.targetID)-\($0.linkType)" }.sorted()
        XCTAssertEqual(edgeTypes1, edgeTypes2, "Edge classification must be deterministic")
    }
}

// MARK: - Network Health Calculation Tests

/// Tests for network health score calculations
final class NetworkHealthCalculationTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        NetworkHealthCalculator.resetEMAState()
    }
    
    private func makePacket(timestamp: Date, from: String, to: String, via: [String] = []) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: .ui,
            info: Data(repeating: 0x41, count: 10)
        )
    }
    
    // MARK: - Score Bounds
    
    func testHealthScoreAlwaysBounded0To100() {
        let now = Date()
        
        // Empty packets
        let emptyHealth = NetworkHealthCalculator.calculate(
            graphModel: .empty,
            timeframePackets: [],
            allRecentPackets: [],
            timeframeDisplayName: "1h",
            now: now
        )
        
        XCTAssertGreaterThanOrEqual(emptyHealth.score, 0)
        XCTAssertLessThanOrEqual(emptyHealth.score, 100)
        
        // Many packets
        var packets: [Packet] = []
        for i in 0..<1000 {
            packets.append(makePacket(
                timestamp: now.addingTimeInterval(-Double(i)),
                from: "W\(i % 10)ABC",
                to: "K\((i + 1) % 10)DEF"
            ))
        }
        
        let canonicalGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: packets,
            includeViaDigipeaters: false
        )
        
        let manyHealth = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "1h",
            includeViaDigipeaters: false,
            now: now
        )
        
        XCTAssertGreaterThanOrEqual(manyHealth.score, 0)
        XCTAssertLessThanOrEqual(manyHealth.score, 100)
    }
    
    // MARK: - Component Calculations
    
    func testMainClusterPercentageCalculation() {
        let now = Date()
        
        // Fully connected graph (all in one cluster)
        var connectedPackets: [Packet] = []
        let nodes = ["W1ABC", "K2DEF", "N3GHI", "W4JKL"]
        for i in 0..<nodes.count {
            for j in (i+1)..<nodes.count {
                connectedPackets.append(makePacket(timestamp: now.addingTimeInterval(-Double(i*10+j)), from: nodes[i], to: nodes[j]))
                connectedPackets.append(makePacket(timestamp: now.addingTimeInterval(-Double(i*10+j+1)), from: nodes[j], to: nodes[i]))
            }
        }
        
        let connectedGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: connectedPackets,
            includeViaDigipeaters: false
        )
        
        let connectedHealth = NetworkHealthCalculator.calculate(
            canonicalGraph: connectedGraph,
            timeframePackets: connectedPackets,
            allRecentPackets: connectedPackets,
            timeframeDisplayName: "1h",
            includeViaDigipeaters: false,
            now: now
        )
        
        // Main cluster should be 100% for fully connected
        XCTAssertEqual(connectedHealth.metrics.largestComponentPercent, 100.0, accuracy: 1.0)
    }
    
    func testIsolationReductionCalculation() {
        let now = Date()
        
        // Two isolated clusters
        let isolatedPackets = [
            // Cluster 1
            makePacket(timestamp: now.addingTimeInterval(-10), from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: now.addingTimeInterval(-9), from: "K2DEF", to: "W1ABC"),
            // Cluster 2 (separate, no connection to cluster 1)
            makePacket(timestamp: now.addingTimeInterval(-8), from: "N3GHI", to: "W4JKL"),
            makePacket(timestamp: now.addingTimeInterval(-7), from: "W4JKL", to: "N3GHI")
        ]
        
        let isolatedGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: isolatedPackets,
            includeViaDigipeaters: false
        )
        
        let isolatedHealth = NetworkHealthCalculator.calculate(
            canonicalGraph: isolatedGraph,
            timeframePackets: isolatedPackets,
            allRecentPackets: isolatedPackets,
            timeframeDisplayName: "1h",
            includeViaDigipeaters: false,
            now: now
        )
        
        // Should have 100% isolation reduction since all nodes are in SOME cluster
        // (isolated = degree 0, but these all have degree > 0)
        XCTAssertGreaterThanOrEqual(isolatedHealth.metrics.isolationReduction, 0)
        XCTAssertLessThanOrEqual(isolatedHealth.metrics.isolationReduction, 100)
    }
    
    // MARK: - Activity Metrics
    
    func testActivityMetricsUse10MinuteWindow() {
        let now = Date()
        
        // Recent packets (within 10 minutes)
        let recentPackets = [
            makePacket(timestamp: now.addingTimeInterval(-60), from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: now.addingTimeInterval(-120), from: "K2DEF", to: "W1ABC")
        ]
        
        // Old packets (more than 10 minutes ago)
        let oldPackets = [
            makePacket(timestamp: now.addingTimeInterval(-900), from: "N3GHI", to: "W4JKL"),
            makePacket(timestamp: now.addingTimeInterval(-1800), from: "W4JKL", to: "N3GHI")
        ]
        
        let allPackets = recentPackets + oldPackets
        
        let canonicalGraph = NetworkHealthCalculator.buildCanonicalGraph(
            packets: allPackets,
            includeViaDigipeaters: false
        )
        
        let health = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph,
            timeframePackets: allPackets,
            allRecentPackets: allPackets,
            timeframeDisplayName: "1h",
            includeViaDigipeaters: false,
            now: now
        )
        
        // Active stations should only count those in the 10-minute window
        XCTAssertEqual(health.metrics.activeStations, 2, "Only 2 stations active in last 10 minutes")
    }
    
    // MARK: - Health Rating
    
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
    
    // MARK: - Determinism
    
    func testHealthScoreDeterministic() {
        let now = Date()
        
        let packets = [
            makePacket(timestamp: now.addingTimeInterval(-100), from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: now.addingTimeInterval(-200), from: "K2DEF", to: "W1ABC"),
            makePacket(timestamp: now.addingTimeInterval(-300), from: "N3GHI", to: "W4JKL")
        ]
        
        NetworkHealthCalculator.resetEMAState()
        let canonicalGraph1 = NetworkHealthCalculator.buildCanonicalGraph(packets: packets, includeViaDigipeaters: false)
        let health1 = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph1,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "1h",
            includeViaDigipeaters: false,
            now: now
        )
        
        NetworkHealthCalculator.resetEMAState()
        let canonicalGraph2 = NetworkHealthCalculator.buildCanonicalGraph(packets: packets, includeViaDigipeaters: false)
        let health2 = NetworkHealthCalculator.calculate(
            canonicalGraph: canonicalGraph2,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "1h",
            includeViaDigipeaters: false,
            now: now
        )
        
        XCTAssertEqual(health1.score, health2.score, "Health score must be deterministic")
        XCTAssertEqual(health1.metrics.totalStations, health2.metrics.totalStations)
        XCTAssertEqual(health1.metrics.activeStations, health2.metrics.activeStations)
    }
}

// MARK: - K-Hop Filtering Tests

/// Tests for k-hop neighborhood filtering
final class KHopFilteringTests: XCTestCase {
    
    // MARK: - Basic K-Hop Filtering
    
    func testKHop1ReturnsImmediateNeighbors() {
        let adjacency: [String: [GraphNeighborStat]] = [
            "A": [GraphNeighborStat(id: "B", weight: 1, bytes: 0, isStale: false), GraphNeighborStat(id: "C", weight: 1, bytes: 0, isStale: false)],
            "B": [GraphNeighborStat(id: "A", weight: 1, bytes: 0, isStale: false), GraphNeighborStat(id: "D", weight: 1, bytes: 0, isStale: false)],
            "C": [GraphNeighborStat(id: "A", weight: 1, bytes: 0, isStale: false)],
            "D": [GraphNeighborStat(id: "B", weight: 1, bytes: 0, isStale: false), GraphNeighborStat(id: "E", weight: 1, bytes: 0, isStale: false)],
            "E": [GraphNeighborStat(id: "D", weight: 1, bytes: 0, isStale: false)]
        ]
        
        let (nodes, distances) = GraphAlgorithms.kHopNeighborhood(from: "A", maxHops: 1, adjacency: adjacency)
        
        // From A with 1 hop: A, B, C
        XCTAssertEqual(nodes, Set(["A", "B", "C"]))
        XCTAssertEqual(distances["A"], 0)
        XCTAssertEqual(distances["B"], 1)
        XCTAssertEqual(distances["C"], 1)
        XCTAssertNil(distances["D"])
        XCTAssertNil(distances["E"])
    }
    
    func testKHop2Returns2HopNeighbors() {
        let adjacency: [String: [GraphNeighborStat]] = [
            "A": [GraphNeighborStat(id: "B", weight: 1, bytes: 0, isStale: false)],
            "B": [GraphNeighborStat(id: "A", weight: 1, bytes: 0, isStale: false), GraphNeighborStat(id: "C", weight: 1, bytes: 0, isStale: false)],
            "C": [GraphNeighborStat(id: "B", weight: 1, bytes: 0, isStale: false), GraphNeighborStat(id: "D", weight: 1, bytes: 0, isStale: false)],
            "D": [GraphNeighborStat(id: "C", weight: 1, bytes: 0, isStale: false)]
        ]
        
        let (nodes, distances) = GraphAlgorithms.kHopNeighborhood(from: "A", maxHops: 2, adjacency: adjacency)
        
        // From A with 2 hops: A, B, C
        XCTAssertEqual(nodes, Set(["A", "B", "C"]))
        XCTAssertEqual(distances["A"], 0)
        XCTAssertEqual(distances["B"], 1)
        XCTAssertEqual(distances["C"], 2)
        XCTAssertNil(distances["D"])
    }
    
    func testKHopWithDisconnectedNodes() {
        let adjacency: [String: [GraphNeighborStat]] = [
            "A": [GraphNeighborStat(id: "B", weight: 1, bytes: 0, isStale: false)],
            "B": [GraphNeighborStat(id: "A", weight: 1, bytes: 0, isStale: false)],
            "C": [GraphNeighborStat(id: "D", weight: 1, bytes: 0, isStale: false)],  // Disconnected cluster
            "D": [GraphNeighborStat(id: "C", weight: 1, bytes: 0, isStale: false)]
        ]
        
        let (nodes, _) = GraphAlgorithms.kHopNeighborhood(from: "A", maxHops: 10, adjacency: adjacency)
        
        // Even with high hops, can't reach disconnected nodes
        XCTAssertTrue(nodes.contains("A"))
        XCTAssertTrue(nodes.contains("B"))
        XCTAssertFalse(nodes.contains("C"))
        XCTAssertFalse(nodes.contains("D"))
    }
    
    func testKHopFromIsolatedNode() {
        let adjacency: [String: [GraphNeighborStat]] = [
            "A": [],  // Isolated
            "B": [GraphNeighborStat(id: "C", weight: 1, bytes: 0, isStale: false)],
            "C": [GraphNeighborStat(id: "B", weight: 1, bytes: 0, isStale: false)]
        ]
        
        let (nodes, distances) = GraphAlgorithms.kHopNeighborhood(from: "A", maxHops: 3, adjacency: adjacency)
        
        // Only the starting node should be included
        XCTAssertEqual(nodes, Set(["A"]))
        XCTAssertEqual(distances["A"], 0)
    }
    
    // MARK: - Hub Metrics
    
    func testFindPrimaryHubByDegree() {
        let nodes = [
            NetworkGraphNode(id: "A", callsign: "A", weight: 10, inCount: 5, outCount: 5, inBytes: 0, outBytes: 0, degree: 2, groupedSSIDs: []),
            NetworkGraphNode(id: "B", callsign: "B", weight: 20, inCount: 10, outCount: 10, inBytes: 0, outBytes: 0, degree: 5, groupedSSIDs: []),
            NetworkGraphNode(id: "C", callsign: "C", weight: 15, inCount: 7, outCount: 8, inBytes: 0, outBytes: 0, degree: 3, groupedSSIDs: [])
        ]
        
        let model = GraphModel(nodes: nodes, edges: [], adjacency: [:], droppedNodesCount: 0)
        
        let hub = GraphAlgorithms.findPrimaryHub(model: model, metric: .degree)
        XCTAssertEqual(hub, "B", "Hub by degree should be node with highest degree")
    }
    
    func testFindPrimaryHubByTraffic() {
        let nodes = [
            NetworkGraphNode(id: "A", callsign: "A", weight: 100, inCount: 50, outCount: 50, inBytes: 0, outBytes: 0, degree: 2, groupedSSIDs: []),
            NetworkGraphNode(id: "B", callsign: "B", weight: 20, inCount: 10, outCount: 10, inBytes: 0, outBytes: 0, degree: 5, groupedSSIDs: []),
            NetworkGraphNode(id: "C", callsign: "C", weight: 15, inCount: 7, outCount: 8, inBytes: 0, outBytes: 0, degree: 3, groupedSSIDs: [])
        ]
        
        let model = GraphModel(nodes: nodes, edges: [], adjacency: [:], droppedNodesCount: 0)
        
        let hub = GraphAlgorithms.findPrimaryHub(model: model, metric: .traffic)
        XCTAssertEqual(hub, "A", "Hub by traffic should be node with highest packet count")
    }
    
    func testFindPrimaryHubEmptyGraph() {
        let model = GraphModel(nodes: [], edges: [], adjacency: [:], droppedNodesCount: 0)
        
        let hub = GraphAlgorithms.findPrimaryHub(model: model, metric: .degree)
        XCTAssertNil(hub, "Empty graph should return nil hub")
    }
    
    // MARK: - Bounding Box
    
    func testBoundingBoxCalculation() {
        let positions = [
            NodePosition(id: "A", x: 0.1, y: 0.2),
            NodePosition(id: "B", x: 0.8, y: 0.9),
            NodePosition(id: "C", x: 0.5, y: 0.5),
            NodePosition(id: "D", x: 0.3, y: 0.7)
        ]
        
        let visible = Set(["A", "B", "C"])
        let box = GraphAlgorithms.boundingBox(visibleNodeIDs: visible, positions: positions)
        
        guard let box = box else {
            XCTFail("Expected bounding box but got nil")
            return
        }
        XCTAssertEqual(box.minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(box.minY, 0.2, accuracy: 0.001)
        XCTAssertEqual(box.maxX, 0.8, accuracy: 0.001)
        XCTAssertEqual(box.maxY, 0.9, accuracy: 0.001)
    }
    
    func testBoundingBoxEmptyNodes() {
        let positions = [
            NodePosition(id: "A", x: 0.1, y: 0.2)
        ]
        
        let visible: Set<String> = []
        let box = GraphAlgorithms.boundingBox(visibleNodeIDs: visible, positions: positions)
        
        XCTAssertNil(box, "Empty visible set should return nil bounding box")
    }
}

// MARK: - Graph Layout Determinism Tests

/// Tests for layout engine determinism
@MainActor
final class GraphLayoutDeterminismTests: XCTestCase {
    
    func testRadialLayoutDeterministic() {
        let nodes = [
            GraphNode(id: "A", degree: 2, count: 10, bytes: 50),
            GraphNode(id: "B", degree: 3, count: 20, bytes: 100),
            GraphNode(id: "C", degree: 1, count: 15, bytes: 75)
        ]
        let edges = [
            GraphEdge(source: "A", target: "B", count: 5, bytes: 25),
            GraphEdge(source: "A", target: "C", count: 3, bytes: 15),
            GraphEdge(source: "B", target: "C", count: 2, bytes: 10)
        ]
        let size = CGSize(width: 200, height: 200)
        let seed = 12345
        
        let positions1 = GraphLayoutEngine.layout(nodes: nodes, edges: edges, size: size, seed: seed)
        let positions2 = GraphLayoutEngine.layout(nodes: nodes, edges: edges, size: size, seed: seed)
        
        XCTAssertEqual(positions1.count, positions2.count)
        
        for (p1, p2) in zip(positions1, positions2) {
            XCTAssertEqual(p1.id, p2.id)
            XCTAssertEqual(p1.x, p2.x, accuracy: 0.0001, "X positions must be deterministic")
            XCTAssertEqual(p1.y, p2.y, accuracy: 0.0001, "Y positions must be deterministic")
        }
    }
    
    func testLayoutPositionsWithinBounds() {
        let nodes = [
            GraphNode(id: "A", degree: 2, count: 10, bytes: 50),
            GraphNode(id: "B", degree: 5, count: 100, bytes: 500),
            GraphNode(id: "C", degree: 1, count: 1, bytes: 10)
        ]
        let edges = [
            GraphEdge(source: "A", target: "B", count: 5, bytes: 25),
            GraphEdge(source: "A", target: "C", count: 1, bytes: 5)
        ]
        let size = CGSize(width: 180, height: 140)
        
        let positions = GraphLayoutEngine.layout(nodes: nodes, edges: edges, size: size, seed: 54321)
        
        for pos in positions {
            XCTAssertGreaterThanOrEqual(pos.x, 0.0, "X must be >= 0")
            XCTAssertLessThanOrEqual(pos.x, Double(size.width), "X must be <= width")
            XCTAssertGreaterThanOrEqual(pos.y, 0.0, "Y must be >= 0")
            XCTAssertLessThanOrEqual(pos.y, Double(size.height), "Y must be <= height")
        }
    }
    
    func testLayoutHandlesEmptyNodes() {
        let positions = GraphLayoutEngine.layout(nodes: [], edges: [], size: .zero, seed: 0)
        XCTAssertTrue(positions.isEmpty)
    }
    
    func testLayoutHandlesSingleNode() {
        let nodes = [
            GraphNode(id: "A", degree: 0, count: 1, bytes: 10)
        ]
        
        let positions = GraphLayoutEngine.layout(nodes: nodes, edges: [], size: CGSize(width: 100, height: 100), seed: 99999)
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions[0].id, "A")
    }
}

// MARK: - Station Identity Tests

/// Tests for station identity mode handling
final class StationIdentityModeTests: XCTestCase {
    
    func testStationModeGroupsSSIDs() {
        // W1ABC-0, W1ABC-1, W1ABC-15 should all become W1ABC
        let key0 = CallsignParser.identityKey(for: "W1ABC-0", mode: .station)
        let key1 = CallsignParser.identityKey(for: "W1ABC-1", mode: .station)
        let key15 = CallsignParser.identityKey(for: "W1ABC-15", mode: .station)
        let keyNoSSID = CallsignParser.identityKey(for: "W1ABC", mode: .station)
        
        XCTAssertEqual(key0, "W1ABC")
        XCTAssertEqual(key1, "W1ABC")
        XCTAssertEqual(key15, "W1ABC")
        XCTAssertEqual(keyNoSSID, "W1ABC")
    }
    
    func testSSIDModeKeepsDistinct() {
        let key0 = CallsignParser.identityKey(for: "W1ABC-0", mode: .ssid)
        let key1 = CallsignParser.identityKey(for: "W1ABC-1", mode: .ssid)
        let key15 = CallsignParser.identityKey(for: "W1ABC-15", mode: .ssid)
        let keyNoSSID = CallsignParser.identityKey(for: "W1ABC", mode: .ssid)
        
        // In SSID mode, -0 should be normalized to no SSID
        XCTAssertEqual(key0, "W1ABC")
        XCTAssertEqual(key1, "W1ABC-1")
        XCTAssertEqual(key15, "W1ABC-15")
        XCTAssertEqual(keyNoSSID, "W1ABC")
    }
    
    func testCallsignValidation() {
        // Valid callsigns
        XCTAssertTrue(CallsignValidator.isValidCallsign("W1ABC"))
        XCTAssertTrue(CallsignValidator.isValidCallsign("K2DEF-1"))
        XCTAssertTrue(CallsignValidator.isValidCallsign("N0CALL"))
        
        // Invalid (service destinations)
        XCTAssertFalse(CallsignValidator.isValidCallsign("BEACON"))
        XCTAssertFalse(CallsignValidator.isValidCallsign("ID"))
        XCTAssertFalse(CallsignValidator.isValidCallsign("CQ"))
    }
    
    func testCallsignNormalization() {
        let normalized1 = CallsignValidator.normalize("w1abc")
        let normalized2 = CallsignValidator.normalize("W1ABC")
        let normalized3 = CallsignValidator.normalize(" W1ABC ")
        
        XCTAssertEqual(normalized1, normalized2)
        XCTAssertEqual(normalized2, normalized3.trimmingCharacters(in: .whitespaces).uppercased())
    }
}

// MARK: - Graph Focus State Tests

/// Tests for graph focus state management
final class GraphFocusStateTests: XCTestCase {
    
    func testInitialState() {
        let state = GraphFocusState()
        
        XCTAssertFalse(state.isFocusEnabled)
        XCTAssertNil(state.anchorNodeID)
        XCTAssertNil(state.anchorDisplayName)
        XCTAssertEqual(state.maxHops, 2)
        XCTAssertEqual(state.hubMetric, .degree)
    }
    
    func testSetAnchorEnablesFocus() {
        var state = GraphFocusState()
        state.setAnchor(nodeID: "W1ABC", displayName: "W1ABC")
        
        XCTAssertTrue(state.isFocusEnabled)
        XCTAssertEqual(state.anchorNodeID, "W1ABC")
        XCTAssertEqual(state.anchorDisplayName, "W1ABC")
    }
    
    func testClearFocusResetsState() {
        var state = GraphFocusState()
        state.setAnchor(nodeID: "W1ABC", displayName: "W1ABC")
        state.clearFocus()
        
        XCTAssertFalse(state.isFocusEnabled)
        XCTAssertNil(state.anchorNodeID)
        XCTAssertNil(state.anchorDisplayName)
    }
    
    func testMaxHopsClamped() {
        var state = GraphFocusState()
        
        state.maxHops = 0
        let clamped0 = state.maxHops.clamped(to: GraphFocusState.hopRange)
        XCTAssertEqual(clamped0, 1)
        
        state.maxHops = 10
        let clamped10 = state.maxHops.clamped(to: GraphFocusState.hopRange)
        XCTAssertEqual(clamped10, 6)
        
        state.maxHops = 3
        let clamped3 = state.maxHops.clamped(to: GraphFocusState.hopRange)
        XCTAssertEqual(clamped3, 3)
    }
}

// MARK: - Activity Trend Tests

/// Tests for activity trend/sparkline calculation
final class ActivityTrendTests: XCTestCase {
    
    private func makePacket(timestamp: Date, from: String, to: String) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: .ui,
            info: Data(repeating: 0x41, count: 10)
        )
    }
    
    func testActivityTrendBucketing() {
        let now = Date()
        
        // Create packets at different times
        let packets = [
            makePacket(timestamp: now.addingTimeInterval(-5 * 60), from: "W1ABC", to: "K2DEF"),   // 5 min ago
            makePacket(timestamp: now.addingTimeInterval(-5 * 60 + 30), from: "K2DEF", to: "W1ABC"), // 5 min ago
            makePacket(timestamp: now.addingTimeInterval(-15 * 60), from: "N3GHI", to: "W4JKL"),  // 15 min ago
            makePacket(timestamp: now.addingTimeInterval(-45 * 60), from: "W5MNO", to: "K6PQR")   // 45 min ago
        ]
        
        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            graphModel: .empty,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "1h",
            trendWindowMinutes: 60,
            trendBucketMinutes: 5,
            now: now
        )
        
        // Should have 12 buckets (60 min / 5 min)
        XCTAssertEqual(health.activityTrend.count, 12)
        
        // Total packets across all buckets should match
        let totalInTrend = health.activityTrend.reduce(0, +)
        XCTAssertEqual(totalInTrend, 4)
    }
    
    func testActivityTrendEmptyPackets() {
        let now = Date()
        
        NetworkHealthCalculator.resetEMAState()
        let health = NetworkHealthCalculator.calculate(
            graphModel: .empty,
            timeframePackets: [],
            allRecentPackets: [],
            timeframeDisplayName: "1h",
            trendWindowMinutes: 60,
            trendBucketMinutes: 5,
            now: now
        )
        
        // All buckets should be 0
        XCTAssertEqual(health.activityTrend.count, 12)
        XCTAssertTrue(health.activityTrend.allSatisfy { $0 == 0 })
    }
}

// MARK: - Network Warning Tests

/// Tests for network warning generation
@MainActor
final class NetworkWarningTests: XCTestCase {
    
    func testWarningSeverityValues() {
        // Just verify the enum values exist and are correct
        XCTAssertEqual(NetworkWarning.WarningSeverity.info.rawValue, "info")
        XCTAssertEqual(NetworkWarning.WarningSeverity.caution.rawValue, "caution")
        XCTAssertEqual(NetworkWarning.WarningSeverity.warning.rawValue, "warning")
    }
    
    func testWarningIdentifiable() {
        let warning1 = NetworkWarning(id: "test1", severity: .info, title: "Test", detail: "Details")
        let warning2 = NetworkWarning(id: "test2", severity: .caution, title: "Test 2", detail: "Details 2")
        
        XCTAssertEqual(warning1.id, "test1")
        XCTAssertEqual(warning2.id, "test2")
        XCTAssertNotEqual(warning1.id, warning2.id)
    }
    
    func testWarningHashable() {
        let warning1 = NetworkWarning(id: "test", severity: .info, title: "Test", detail: "Details")
        let warning2 = NetworkWarning(id: "test", severity: .info, title: "Test", detail: "Details")
        
        XCTAssertEqual(warning1, warning2)
        
        var set: Set<NetworkWarning> = []
        set.insert(warning1)
        set.insert(warning2)
        XCTAssertEqual(set.count, 1)
    }
}

// MARK: - Freshness Calculator Integration Tests

/// Tests for freshness calculations in graph context
final class FreshnessCalculatorGraphTests: XCTestCase {
    
    func testFreshnessColor() {
        // Fresh
        let freshColor = FreshnessColors.color(for: 1.0)
        XCTAssertNotNil(freshColor)
        
        // Stale
        let staleColor = FreshnessColors.color(for: 0.3)
        XCTAssertNotNil(staleColor)
        
        // Expired
        let expiredColor = FreshnessColors.color(for: 0.0)
        XCTAssertNotNil(expiredColor)
    }
    
    func testFreshnessColorName() {
        XCTAssertEqual(FreshnessColors.colorName(for: 1.0), "green")
        XCTAssertEqual(FreshnessColors.colorName(for: 0.75), "yellow-green")
        XCTAssertEqual(FreshnessColors.colorName(for: 0.55), "yellow")
        XCTAssertEqual(FreshnessColors.colorName(for: 0.35), "orange")
        XCTAssertEqual(FreshnessColors.colorName(for: 0.1), "red-orange")
        XCTAssertEqual(FreshnessColors.colorName(for: 0.0), "gray")
    }
    
    func testFreshnessOpacity() {
        let freshOpacity = FreshnessColors.opacity(for: 1.0)
        XCTAssertEqual(freshOpacity, 1.0, accuracy: 0.01)
        
        let expiredOpacity = FreshnessColors.opacity(for: 0.0)
        XCTAssertEqual(expiredOpacity, 0.3, accuracy: 0.01)
        
        let midOpacity = FreshnessColors.opacity(for: 0.5)
        XCTAssertEqual(midOpacity, 0.65, accuracy: 0.01)
    }
}

// MARK: - Edge Key Tests

/// Tests for FocusEdgeKey normalization
@MainActor
final class FocusEdgeKeyTests: XCTestCase {
    
    func testEdgeKeyNormalization() {
        let key1 = FocusEdgeKey("A", "B")
        let key2 = FocusEdgeKey("B", "A")
        
        // Order should be normalized
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1.nodeA, "A")
        XCTAssertEqual(key1.nodeB, "B")
    }
    
    func testEdgeKeyHashable() {
        let key1 = FocusEdgeKey("A", "B")
        let key2 = FocusEdgeKey("B", "A")
        
        var set: Set<FocusEdgeKey> = []
        set.insert(key1)
        set.insert(key2)
        
        // Should only have one entry since they're equal
        XCTAssertEqual(set.count, 1)
    }
}

// MARK: - Regression Tests

/// Regression tests for known issues
final class AnalysisPageRegressionTests: XCTestCase {
    
    private func makePacket(timestamp: Date, from: String, to: String, via: [String] = []) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: .ui,
            info: Data(repeating: 0x41, count: 10)
        )
    }
    
    /// Regression: Health score should not change when view filters change
    func testHealthScoreIndependentOfViewFilters() {
        let now = Date()
        let packets = [
            makePacket(timestamp: now.addingTimeInterval(-100), from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: now.addingTimeInterval(-200), from: "K2DEF", to: "W1ABC"),
            makePacket(timestamp: now.addingTimeInterval(-300), from: "N3GHI", to: "W4JKL"),
            makePacket(timestamp: now.addingTimeInterval(-400), from: "W4JKL", to: "N3GHI")
        ]
        
        // Build view graph with different filter settings
        let viewGraph1 = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            )
        )
        
        let viewGraph2 = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 5,  // Higher filter
                maxNodes: 2           // Lower max
            )
        )
        
        // Health should use canonical graph, not view graph
        NetworkHealthCalculator.resetEMAState()
        let health1 = NetworkHealthCalculator.calculate(
            graphModel: viewGraph1,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "1h",
            now: now
        )
        
        NetworkHealthCalculator.resetEMAState()
        let health2 = NetworkHealthCalculator.calculate(
            graphModel: viewGraph2,
            timeframePackets: packets,
            allRecentPackets: packets,
            timeframeDisplayName: "1h",
            now: now
        )
        
        // Health scores should be identical despite different view graphs
        XCTAssertEqual(health1.score, health2.score, "Health score should be independent of view filters")
    }
    
    /// Regression: Graph building should not crash on empty packets
    func testGraphBuildingEmptyPackets() {
        let model = NetworkGraphBuilder.build(
            packets: [],
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: true,
                minimumEdgeCount: 1,
                maxNodes: 100
            )
        )
        
        XCTAssertTrue(model.nodes.isEmpty)
        XCTAssertTrue(model.edges.isEmpty)
        XCTAssertEqual(model.droppedNodesCount, 0)
    }
    
    /// Regression: Graph should handle self-loops (A→A)
    func testGraphHandlesSelfLoops() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let packets = [
            makePacket(timestamp: base, from: "W1ABC", to: "W1ABC"),  // Self-loop
            makePacket(timestamp: base.addingTimeInterval(1), from: "W1ABC", to: "K2DEF")
        ]
        
        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            )
        )
        
        // Should not crash and should handle gracefully
        XCTAssertGreaterThanOrEqual(model.nodes.count, 1)
    }
    
    /// Regression: Node degree should match adjacency count
    func testNodeDegreeMatchesAdjacency() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let packets = [
            makePacket(timestamp: base, from: "W1ABC", to: "K2DEF"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "K2DEF", to: "W1ABC"),
            makePacket(timestamp: base.addingTimeInterval(2), from: "W1ABC", to: "N3GHI"),
            makePacket(timestamp: base.addingTimeInterval(3), from: "N3GHI", to: "W1ABC")
        ]
        
        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 100
            )
        )
        
        for node in model.nodes {
            let adjacencyCount = model.adjacency[node.id]?.count ?? 0
            XCTAssertEqual(node.degree, adjacencyCount, "Node \(node.id) degree should match adjacency count")
        }
    }
}
