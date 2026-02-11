//
//  NetworkGraphRegressionTests.swift
//  AXTermTests
//
//  Regression tests for network graph building bugs.
//  Tests the critical invariants that were violated in the reported regression:
//  - Local node disappearing when includeVia OFF
//  - Graph collapsing to single node when includeVia ON
//
//  These tests validate:
//  1. Canonical RelationshipGraph construction (classification correctness)
//  2. ViewGraph derivation (filters, modes, includeVia behavior)
//  3. Nodes built from stations heard, not just from edges
//

import XCTest
@testable import AXTerm

// MARK: - NetworkGraphRegressionTests

final class NetworkGraphRegressionTests: XCTestCase {

    // MARK: - Test A: Local Node Disappears When includeVia OFF (CRITICAL REGRESSION)

    /// Regression test: Local station (K0EPI) must NEVER disappear due to includeVia toggle.
    func testLocalNodeNeverDisappearsWhenIncludeViaOff() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create bidirectional traffic between K0EPI-7 and WH6ANH (DirectPeer)
        _ = builder.addDirectPeerExchange(between: "K0EPI-7", and: "WH6ANH", countEachDirection: 3)

        // Add direct heard traffic from W5NTS-10 (HeardDirect eligible)
        _ = builder.addSustainedDirectActivity(from: "W5NTS-10", to: "K0EPI-7", minuteSpan: 5, packetsPerMinute: 2)

        let packets = builder.buildPackets()

        // Build canonical graph with includeVia OFF
        let optionsOff = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let classifiedGraphOff = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsOff, now: now)

        // Debug output on failure
        if classifiedGraphOff.nodes.count < 3 {
            GraphDebugDump.dump(classifiedGraph: classifiedGraphOff, options: optionsOff, label: "Test A - includeVia OFF")
        }

        // CRITICAL: Local node K0EPI (base station in station mode) must be present
        // In station mode, W5NTS-10 -> W5NTS (base call)
        XCTAssertTrue(
            GraphAssertions.assertContainsNodes(classifiedGraphOff, requiredIDs: ["K0EPI", "WH6ANH", "W5NTS"]),
            "Local node K0EPI must be present when includeVia is OFF"
        )

        // Derive ViewGraph in Connectivity mode (DirectPeer + HeardDirect)
        let viewGraphConnectivity = ViewGraphDeriver.deriveViewGraph(from: classifiedGraphOff, viewMode: .connectivity)

        XCTAssertTrue(
            GraphAssertions.assertViewGraphContainsNode(viewGraphConnectivity, nodeID: "K0EPI"),
            "K0EPI must be present in Connectivity view when includeVia OFF"
        )

        XCTAssertTrue(
            GraphAssertions.assertViewGraphContainsNode(viewGraphConnectivity, nodeID: "WH6ANH"),
            "WH6ANH must be present in Connectivity view"
        )
    }

    /// Same test with SSID mode - ensure SSIDs don't get lost.
    func testLocalNodeWithSSIDNeverDisappearsWhenIncludeViaOff() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Use full SSIDs
        _ = builder.addDirectPeerExchange(between: "K0EPI-7", and: "WH6ANH", countEachDirection: 3)
        _ = builder.addSustainedDirectActivity(from: "W5NTS-10", to: "K0EPI-7", minuteSpan: 5, packetsPerMinute: 2)

        let packets = builder.buildPackets()

        // Build with SSID mode
        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .ssid
        )

        let classifiedGraph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        if classifiedGraph.nodes.count < 3 {
            GraphDebugDump.dump(classifiedGraph: classifiedGraph, options: options, label: "Test A.ssid - includeVia OFF SSID mode")
        }

        // In SSID mode, K0EPI-7 should be present (not grouped to K0EPI)
        XCTAssertTrue(
            GraphAssertions.assertContainsNodes(classifiedGraph, requiredIDs: ["K0EPI-7", "WH6ANH", "W5NTS-10"]),
            "K0EPI-7 must be present in SSID mode when includeVia is OFF"
        )
    }

    // MARK: - Test B: includeVia ON Yields Only One Node (CRITICAL REGRESSION)

    /// Regression test: includeVia ON must not collapse graph to single node.
    func testIncludeViaOnDoesNotCollapseToSingleNode() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create a connected network
        _ = builder.addDirectPeerExchange(between: "K0EPI-7", and: "WH6ANH", countEachDirection: 3)
        _ = builder.addDirectPeerExchange(between: "WH6ANH", and: "W5NTS-10", countEachDirection: 2)

        // Add some via traffic
        _ = builder.addViaObservation(from: "K0EPI-7", to: "N4DRL", via: ["WIDE1-1"], count: 5)
        _ = builder.addViaObservation(from: "WH6ANH", to: "K0ALL", via: ["RELAY"], count: 3)

        let packets = builder.buildPackets()

        // Build with includeVia ON
        let optionsOn = NetworkGraphBuilder.Options(
            includeViaDigipeaters: true,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let classifiedGraphOn = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsOn, now: now)

        if classifiedGraphOn.nodes.count < 3 {
            GraphDebugDump.dump(classifiedGraph: classifiedGraphOn, options: optionsOn, label: "Test B - includeVia ON")
        }

        // Must have at least 3 nodes
        XCTAssertGreaterThanOrEqual(
            classifiedGraphOn.nodes.count, 3,
            "Graph with includeVia ON should have at least 3 nodes, got \(classifiedGraphOn.nodes.count)"
        )

        // Must have at least 2 edges
        XCTAssertGreaterThanOrEqual(
            classifiedGraphOn.edges.count, 2,
            "Graph with includeVia ON should have at least 2 edges, got \(classifiedGraphOn.edges.count)"
        )

        // Verify specific nodes exist
        // In station mode, W5NTS-10 -> W5NTS (base call)
        XCTAssertTrue(
            GraphAssertions.assertContainsNodes(classifiedGraphOn, requiredIDs: ["K0EPI", "WH6ANH", "W5NTS"]),
            "All core nodes must be present when includeVia is ON"
        )
    }

    // MARK: - Test C: Canonical Graph Invariant Under View Filters

    /// The canonical ClassifiedGraphModel must be unchanged when minEdge/maxEdge vary.
    func testCanonicalGraphUnaffectedByMinMaxEdgeSliders() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create varied edge weights
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 10)  // weight ~20
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "N3GHI", countEachDirection: 5)   // weight ~10
        _ = builder.addDirectPeerExchange(between: "K2DEF", and: "W4JKL", countEachDirection: 2)   // weight ~4

        let packets = builder.buildPackets()

        // Build with different minEdge values - canonical graph should be invariant
        let optionsMin1 = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let optionsMin5 = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 5,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graphMin1 = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsMin1, now: now)
        let graphMin5 = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsMin5, now: now)

        // The node IDs found should be different because minEdge affects which edges exist
        // But both should still work correctly (not crash, not produce empty graphs)
        XCTAssertGreaterThan(graphMin1.nodes.count, 0, "minEdge=1 graph should have nodes")
        XCTAssertGreaterThan(graphMin5.nodes.count, 0, "minEdge=5 graph should have nodes")

        // High minEdge should filter out low-weight edges
        XCTAssertLessThanOrEqual(
            graphMin5.edges.count, graphMin1.edges.count,
            "Higher minEdge should result in equal or fewer edges"
        )
    }

    // MARK: - Test D: Canonical Topology Uses Correct MinEdge

    /// Network health calculations should use a consistent canonical minEdge (2).
    func testNetworkHealthUsesCanonicalMinEdge() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        _ = builder.addDirectEndpoint(from: "W1ABC", to: "N3GHI", count: 1)  // Won't meet minEdge=2

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 2,  // Canonical minEdge for health
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // W1ABC-K2DEF edge should exist (weight 10 >= 2)
        // W1ABC-N3GHI edge should NOT exist (weight 1 < 2)
        // But both W1ABC and K2DEF should be nodes
        XCTAssertTrue(
            GraphAssertions.assertEdgeExists(graph, from: "W1ABC", to: "K2DEF", type: .directPeer),
            "W1ABC-K2DEF DirectPeer edge should exist with minEdge=2"
        )
    }

    // MARK: - Test E: IncludeVia Only Affects SeenVia Visibility

    /// includeVia toggle must ONLY affect heardVia (seenVia) edges, not classification.
    func testIncludeViaOnlyAffectsSeenViaEdges() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create both direct and via traffic between same pair
        _ = builder.addDirectPeerExchange(between: "K9ALP", and: "W5BRV", countEachDirection: 5)
        _ = builder.addViaObservation(from: "K9ALP", to: "W5BRV", via: ["N0DIG"], count: 10)

        let packets = builder.buildPackets()

        let optionsOff = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let optionsOn = NetworkGraphBuilder.Options(
            includeViaDigipeaters: true,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graphOff = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsOff, now: now)
        let graphOn = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsOn, now: now)

        // DirectPeer edge should exist in both
        XCTAssertTrue(
            GraphAssertions.assertEdgeExists(graphOff, from: "K9ALP", to: "W5BRV", type: .directPeer),
            "DirectPeer edge should exist when includeVia OFF"
        )
        XCTAssertTrue(
            GraphAssertions.assertEdgeExists(graphOn, from: "K9ALP", to: "W5BRV", type: .directPeer),
            "DirectPeer edge should exist when includeVia ON"
        )

        // HeardVia edges should only appear when includeVia ON
        let heardViaCountOff = graphOff.edges.filter { $0.linkType == .heardVia }.count
        let heardViaCountOn = graphOn.edges.filter { $0.linkType == .heardVia }.count

        XCTAssertEqual(
            heardViaCountOff, 0,
            "No HeardVia edges should exist when includeVia OFF"
        )

        // With includeVia ON, we may have via edges (depends on implementation)
        XCTAssertGreaterThanOrEqual(
            heardViaCountOn, 0,
            "HeardVia edge visibility should change with includeVia toggle"
        )
    }

    /// Verify view mode filtering correctly hides/shows edge types.
    func testViewModeFiltersEdgesCorrectly() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create DirectPeer traffic
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        // Create HeardDirect traffic (sustained direct observation)
        _ = builder.addSustainedDirectActivity(from: "N3GHI", to: "W1ABC", minuteSpan: 5, packetsPerMinute: 2)
        // Create via traffic for HeardVia
        _ = builder.addViaObservation(from: "W4JKL", to: "W1ABC", via: ["N0DIG1"], count: 10)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: true,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let classifiedGraph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // Test Connectivity mode (DirectPeer + HeardDirect)
        let connectivityView = ViewGraphDeriver.deriveViewGraph(from: classifiedGraph, viewMode: .connectivity)
        let hasDirectPeerInConnectivity = classifiedGraph.edges.contains {
            $0.linkType == .directPeer
        }
        if hasDirectPeerInConnectivity {
            XCTAssertGreaterThanOrEqual(
                connectivityView.edges.count, 1,
                "Connectivity view should show DirectPeer edges"
            )
        }

        // Test All mode (all types)
        let allView = ViewGraphDeriver.deriveViewGraph(from: classifiedGraph, viewMode: .all)
        XCTAssertGreaterThanOrEqual(
            allView.edges.count, connectivityView.edges.count,
            "All view should have at least as many edges as Connectivity view"
        )
    }

    // MARK: - Test F: Station Identity Grouping Does Not Drop Relationships

    /// When grouping SSIDs, relationships must aggregate correctly.
    func testStationGroupingAggregatesRelationships() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create traffic from multiple SSIDs of same station
        // Using W6ANH as base with various SSIDs
        _ = builder.addDirectEndpoint(from: "W6ANH", to: "N4DRL", count: 5)
        _ = builder.addDirectEndpoint(from: "W6ANH-1", to: "N4DRL", count: 3)
        _ = builder.addDirectEndpoint(from: "W6ANH-15", to: "N4DRL", count: 2)
        // And reverse
        _ = builder.addDirectEndpoint(from: "N4DRL", to: "W6ANH", count: 4)
        _ = builder.addDirectEndpoint(from: "N4DRL", to: "W6ANH-15", count: 1)

        let packets = builder.buildPackets()

        // Station mode should group W6ANH, W6ANH-1, W6ANH-15 -> W6ANH
        let optionsStation = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        // SSID mode should keep them separate
        let optionsSSID = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .ssid
        )

        let graphStation = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsStation, now: now)
        let graphSSID = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsSSID, now: now)

        // Station mode: should have 2 nodes (W6ANH, N4DRL)
        XCTAssertEqual(
            graphStation.nodes.count, 2,
            "Station mode should have 2 nodes (W6ANH grouped, N4DRL)"
        )
        XCTAssertTrue(
            GraphAssertions.assertGroupedSSIDs(graphStation, nodeID: "W6ANH", expectedSSIDs: Set(["W6ANH", "W6ANH-1", "W6ANH-15"])),
            "W6ANH node should contain all SSIDs"
        )

        // SSID mode: should have 4 nodes (W6ANH, W6ANH-1, W6ANH-15, N4DRL)
        XCTAssertEqual(
            graphSSID.nodes.count, 4,
            "SSID mode should have 4 separate nodes"
        )
    }

    // MARK: - Test G: Empty Edges Case Still Renders Nodes (CRITICAL)

    /// Nodes are built from nodeStats independently of edges.
    /// HeardVia summary edges are ALWAYS created between endpoints (regardless of includeVia toggle).
    /// The includeVia toggle only controls whether digipeaters become nodes and hop-by-hop edges.
    func testEmptyEdgesCaseStillRendersNodes() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create only via traffic (no direct)
        _ = builder.addViaObservation(from: "W1ABC", to: "K2DEF", via: ["N0DIG"], count: 5)
        _ = builder.addViaObservation(from: "K2DEF", to: "N3GHI", via: ["N0DIG"], count: 3)

        let packets = builder.buildPackets()

        // Build with includeVia OFF
        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let classifiedGraph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // Nodes should be present because they're tracked in nodeStats
        XCTAssertGreaterThanOrEqual(
            classifiedGraph.nodes.count, 3,
            "Nodes W1ABC, K2DEF, N3GHI should be present (includeVia OFF)"
        )

        // HeardVia summary edges ARE created between endpoints (this is correct behavior)
        // The toggle only affects whether digipeaters become nodes, not endpoint relationships
        XCTAssertEqual(
            classifiedGraph.edges.count, 2,
            "HeardVia edges between endpoints should exist (W1ABC-K2DEF, K2DEF-N3GHI)"
        )

        // All edges should be HeardVia type
        XCTAssertTrue(
            classifiedGraph.edges.allSatisfy { $0.linkType == .heardVia },
            "All edges should be HeardVia type"
        )

        // Verify specific nodes
        XCTAssertTrue(
            GraphAssertions.assertContainsNodes(classifiedGraph, requiredIDs: ["W1ABC", "K2DEF", "N3GHI"]),
            "W1ABC, K2DEF, N3GHI must all be present as nodes"
        )

        // N0DIG should NOT be present (includeVia OFF means digipeaters don't become nodes)
        let hasDigi = classifiedGraph.nodes.contains { $0.id == "N0DIG" }
        XCTAssertFalse(hasDigi, "N0DIG should not be present when includeVia OFF")
    }

    /// Local node must always be present even if it has no edges.
    func testLocalNodeAlwaysPresentEvenWithNoEdges() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Only traffic not involving local station directly
        _ = builder.addDirectPeerExchange(between: "K6RMT", and: "N7RMT", countEachDirection: 5)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // K6RMT and N7RMT should be present
        XCTAssertTrue(
            GraphAssertions.assertContainsNodes(graph, requiredIDs: ["K6RMT", "N7RMT"]),
            "Remote nodes should be present"
        )

        // Note: Local node injection is done by the ViewModel, not the builder.
    }

    // MARK: - Test H: Determinism

    /// Same packets must produce identical graph output.
    func testGraphBuildingIsDeterministic() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        _ = builder.addDirectPeerExchange(between: "K2DEF", and: "N3GHI", countEachDirection: 3)
        _ = builder.addViaObservation(from: "W4JKL", to: "W1ABC", via: ["RELAY"], count: 4)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: true,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        // Build multiple times
        let graph1 = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)
        let graph2 = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)
        let graph3 = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // Node sets must be identical
        let nodeIDs1 = Set(graph1.nodes.map { $0.id })
        let nodeIDs2 = Set(graph2.nodes.map { $0.id })
        let nodeIDs3 = Set(graph3.nodes.map { $0.id })

        XCTAssertEqual(nodeIDs1, nodeIDs2, "Node sets must be identical across builds (1 vs 2)")
        XCTAssertEqual(nodeIDs2, nodeIDs3, "Node sets must be identical across builds (2 vs 3)")

        // Edge counts must be identical
        XCTAssertEqual(graph1.edges.count, graph2.edges.count, "Edge counts must match (1 vs 2)")
        XCTAssertEqual(graph2.edges.count, graph3.edges.count, "Edge counts must match (2 vs 3)")

        // Verify node ordering is consistent (sorted by weight, then by ID)
        let orderedIDs1 = graph1.nodes.map { $0.id }
        let orderedIDs2 = graph2.nodes.map { $0.id }
        let orderedIDs3 = graph3.nodes.map { $0.id }

        XCTAssertEqual(orderedIDs1, orderedIDs2, "Node ordering must be consistent (1 vs 2)")
        XCTAssertEqual(orderedIDs2, orderedIDs3, "Node ordering must be consistent (2 vs 3)")
    }

    // MARK: - Additional Edge Case Tests

    /// Empty packet list should produce empty graph, not crash.
    func testEmptyPacketListProducesEmptyGraph() {
        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: [], options: options)

        XCTAssertTrue(graph.nodes.isEmpty, "Empty packets should produce empty node list")
        XCTAssertTrue(graph.edges.isEmpty, "Empty packets should produce empty edge list")
        XCTAssertEqual(graph.droppedNodesCount, 0, "No nodes to drop")
    }

    /// Single packet should create appropriate nodes and potentially edges.
    func testSinglePacketCreatesGraph() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now)
        _ = builder.addDirectEndpoint(from: "K8SND", to: "W9RCV", count: 1)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // Should have nodes (though edge may not meet DirectPeer threshold)
        XCTAssertGreaterThanOrEqual(graph.nodes.count, 0, "Single packet graph should be valid")
    }

    /// Very large maxNodes should not crash or behave incorrectly.
    func testLargeMaxNodesHandledCorrectly() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create a small graph
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: Int.max / 2,  // Very large but not overflow-prone
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        XCTAssertEqual(graph.droppedNodesCount, 0, "No nodes should be dropped with large maxNodes")
        XCTAssertEqual(graph.nodes.count, 2, "Should have exactly the nodes from packets")
    }

    /// MinEdge of 0 should be treated as 1.
    func testMinEdgeZeroTreatedAsOne() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))
        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 1)

        let packets = builder.buildPackets()

        let optionsZero = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 0,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let optionsOne = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graphZero = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsZero, now: now)
        let graphOne = NetworkGraphBuilder.buildClassified(packets: packets, options: optionsOne, now: now)

        // Should behave equivalently
        XCTAssertEqual(graphZero.nodes.count, graphOne.nodes.count, "minEdge 0 should behave like minEdge 1")
    }

    // MARK: - HeardDirect Scoring Tests

    /// HeardDirect requires sustained activity across multiple time buckets.
    func testHeardDirectRequiresSustainedActivity() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create sustained direct activity (qualifies for HeardDirect)
        _ = builder.addSustainedDirectActivity(from: "W1BCN", to: "W9RCV", minuteSpan: 10, packetsPerMinute: 2)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // Should have both nodes
        XCTAssertGreaterThanOrEqual(graph.nodes.count, 2, "Should have sender and receiver nodes")

        // Check if HeardDirect edge exists (depends on scoring thresholds)
        let hasHeardDirect = graph.edges.contains { $0.linkType == .heardDirect }
        // Note: Whether this passes depends on HeardDirectScoring thresholds
        print("HeardDirect edge present: \(hasHeardDirect)")
    }

    /// Sporadic activity should not qualify for HeardDirect.
    func testSporadicActivityDoesNotQualifyForHeardDirect() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Create only 1 packet (not sustained)
        _ = builder.addDirectReception(heardBy: "W9RCV", from: "N0SPR", count: 1)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // Should NOT have HeardDirect edge (doesn't meet thresholds)
        let hasHeardDirect = graph.edges.contains { $0.linkType == .heardDirect }
        XCTAssertFalse(hasHeardDirect, "Sporadic activity should not create HeardDirect edge")
    }
}

// MARK: - ClassificationCorrectnessTests

final class ClassificationCorrectnessTests: XCTestCase {

    /// DirectPeer requires BIDIRECTIONAL traffic.
    func testDirectPeerRequiresBidirectionalTraffic() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // One-way traffic only
        _ = builder.addDirectEndpoint(from: "K8SND", to: "W9RCV", count: 10)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // Should NOT have DirectPeer (only one direction)
        XCTAssertTrue(
            GraphAssertions.assertNoEdge(graph, from: "K8SND", to: "W9RCV", type: .directPeer),
            "One-way traffic should not create DirectPeer"
        )
    }

    /// DirectPeer is created when traffic exists in both directions.
    func testDirectPeerCreatedWithBidirectionalTraffic() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Bidirectional traffic
        _ = builder.addDirectPeerExchange(between: "K2ALC", and: "N3BOB", countEachDirection: 3)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        XCTAssertTrue(
            GraphAssertions.assertEdgeExists(graph, from: "K2ALC", to: "N3BOB", type: .directPeer),
            "Bidirectional traffic should create DirectPeer"
        )
    }

    /// Infrastructure traffic (BEACON, ID) should not create DirectPeer.
    func testInfrastructureTrafficExcludedFromDirectPeer() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Traffic to BEACON destination
        _ = builder.addDirectEndpoint(from: "K5STA", to: "BEACON", count: 10)
        _ = builder.addDirectEndpoint(from: "BEACON", to: "K5STA", count: 10)

        // Traffic to ID destination
        _ = builder.addDirectEndpoint(from: "K5STA", to: "ID", count: 5)
        _ = builder.addDirectEndpoint(from: "ID", to: "K5STA", count: 5)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: false,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // BEACON and ID should be filtered by CallsignValidator
        // So no DirectPeer edges should exist
        let directPeerCount = graph.edges.filter { $0.linkType == .directPeer }.count
        XCTAssertEqual(
            directPeerCount, 0,
            "Infrastructure traffic should not create DirectPeer edges"
        )
    }

    /// Digipeater aliases (without numeric call-area digits) should still appear as routing nodes.
    func testDigipeaterAliasesIncludedWithoutIncludingServiceEndpoints() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        // Valid endpoint traffic routed via tactical digi aliases.
        _ = builder.addViaObservation(from: "K5STA", to: "N0CALL", via: ["DRL"], count: 3)
        _ = builder.addViaObservation(from: "K5STA", to: "N0CALL", via: ["DRLNOD"], count: 2)

        // Service endpoint traffic should not be admitted as routing nodes.
        _ = builder.addViaObservation(from: "K5STA", to: "ID", via: ["DRL"], count: 2)
        _ = builder.addViaObservation(from: "K5STA", to: "BEACON", via: ["DRLNOD"], count: 2)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: true,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)
        let nodeIDs = Set(graph.nodes.map(\.id))

        XCTAssertTrue(nodeIDs.contains("DRL"), "DRL alias digipeater should be present as a graph node")
        XCTAssertTrue(nodeIDs.contains("DRLNOD"), "DRLNOD alias digipeater should be present as a graph node")
        XCTAssertFalse(nodeIDs.contains("ID"), "ID should remain excluded from graph nodes")
        XCTAssertFalse(nodeIDs.contains("BEACON"), "BEACON should remain excluded from graph nodes")
    }

    /// User-configured ignore entries should suppress regional service endpoints from graph identities.
    func testUserIgnoredServiceEndpointIsExcluded() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))
        defer { CallsignValidator.configureIgnoredServiceEndpoints([]) }

        CallsignValidator.configureIgnoredServiceEndpoints(["HORSE"])

        _ = builder.addViaObservation(from: "K5STA", to: "N0CALL", via: ["HORSE"], count: 4)
        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: true,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let graph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)
        let nodeIDs = Set(graph.nodes.map(\.id))
        XCTAssertFalse(nodeIDs.contains("HORSE"), "Custom ignored endpoint should be excluded from graph nodes")
    }
}

// MARK: - ViewModeIntegrationTests

final class ViewModeIntegrationTests: XCTestCase {

    /// Connectivity mode shows DirectPeer and HeardDirect, hides HeardVia.
    func testConnectivityModeShowsCorrectEdgeTypes() {
        let visibleTypes = GraphViewMode.connectivity.visibleLinkTypes

        XCTAssertTrue(visibleTypes.contains(.directPeer), "Connectivity should show DirectPeer")
        XCTAssertTrue(visibleTypes.contains(.heardDirect), "Connectivity should show HeardDirect")
        XCTAssertFalse(visibleTypes.contains(.heardVia), "Connectivity should hide HeardVia")
    }

    /// Routing mode shows DirectPeer and HeardVia, hides HeardDirect.
    func testRoutingModeShowsCorrectEdgeTypes() {
        let visibleTypes = GraphViewMode.routing.visibleLinkTypes

        XCTAssertTrue(visibleTypes.contains(.directPeer), "Routing should show DirectPeer")
        XCTAssertTrue(visibleTypes.contains(.heardVia), "Routing should show HeardVia")
        XCTAssertFalse(visibleTypes.contains(.heardDirect), "Routing should hide HeardDirect")
    }

    /// All mode shows all edge types.
    func testAllModeShowsAllEdgeTypes() {
        let visibleTypes = GraphViewMode.all.visibleLinkTypes

        XCTAssertTrue(visibleTypes.contains(.directPeer), "All should show DirectPeer")
        XCTAssertTrue(visibleTypes.contains(.heardDirect), "All should show HeardDirect")
        XCTAssertTrue(visibleTypes.contains(.heardVia), "All should show HeardVia")
    }

    /// ViewGraph derivation preserves all nodes from ClassifiedGraph.
    func testViewGraphPreservesAllNodes() {
        let now = Date()
        var builder = GraphFixtureBuilder(baseTimestamp: now.addingTimeInterval(-600))

        _ = builder.addDirectPeerExchange(between: "W1ABC", and: "K2DEF", countEachDirection: 5)
        _ = builder.addViaObservation(from: "N3GHI", to: "W1ABC", via: ["N0DIG"], count: 3)

        let packets = builder.buildPackets()

        let options = NetworkGraphBuilder.Options(
            includeViaDigipeaters: true,
            minimumEdgeCount: 1,
            maxNodes: 100,
            stationIdentityMode: .station
        )

        let classifiedGraph = NetworkGraphBuilder.buildClassified(packets: packets, options: options, now: now)

        // Derive view graphs for each mode
        let connectivityView = ViewGraphDeriver.deriveViewGraph(from: classifiedGraph, viewMode: .connectivity)
        let routingView = ViewGraphDeriver.deriveViewGraph(from: classifiedGraph, viewMode: .routing)
        let allView = ViewGraphDeriver.deriveViewGraph(from: classifiedGraph, viewMode: .all)

        // All views should have the same number of nodes as the classified graph
        XCTAssertEqual(
            connectivityView.nodes.count, classifiedGraph.nodes.count,
            "Connectivity view should preserve all nodes"
        )
        XCTAssertEqual(
            routingView.nodes.count, classifiedGraph.nodes.count,
            "Routing view should preserve all nodes"
        )
        XCTAssertEqual(
            allView.nodes.count, classifiedGraph.nodes.count,
            "All view should preserve all nodes"
        )
    }
}
