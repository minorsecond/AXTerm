//
//  NetworkTopologyTests.swift
//  AXTermTests
//
//  Graph facts that no amount of link-quality measurement reveals: quality
//  describes edges, and these are properties of the shape of the whole graph.
//

import XCTest
@testable import AXTerm

final class NetworkTopologyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func path(_ from: String, _ to: String, via: [String] = [],
                      evidence: NetworkPath.Evidence = .heardDirect) -> NetworkPath {
        NetworkPath(from: from, to: to, via: via, evidence: evidence,
                    observations: 1, firstSeen: t0, lastSeen: t0,
                    unansweredAttempts: 0)
    }

    // MARK: - Adjacency

    func testADigipeaterBecomesItsOwnVertex() {
        let graph = NetworkTopology.adjacency([
            path("A", "B", via: ["DIGI"], evidence: .heardDigipeated),
        ])
        // Collapsing the hop into a single A–B edge would hide the vertex
        // whose removal breaks everything, which is the whole point.
        XCTAssertEqual(graph["A"], ["DIGI"])
        XCTAssertEqual(graph["DIGI"], ["A", "B"])
        XCTAssertFalse(graph["A"]?.contains("B") ?? true,
                       "A reaches B only through the digipeater")
    }

    func testWeakEvidenceCanBeExcluded() {
        let paths = [path("A", "B", evidence: .transitive)]
        XCTAssertTrue(NetworkTopology.adjacency(paths, minimumEvidence: .heardDirect).isEmpty)
        XCTAssertFalse(NetworkTopology.adjacency(paths, minimumEvidence: .transitive).isEmpty)
    }

    // MARK: - Articulation points

    func testTheHubOfAStarIsACutVertex() {
        let graph = NetworkTopology.adjacency([
            path("A", "DIGI"), path("B", "DIGI"), path("C", "DIGI"),
        ])
        XCTAssertEqual(NetworkTopology.articulationPoints(in: graph), ["DIGI"])
    }

    func testAnEndpointIsNeverACutVertex() {
        let graph = NetworkTopology.adjacency([path("A", "B")])
        // Removing a leaf leaves the rest connected, by definition.
        XCTAssertTrue(NetworkTopology.articulationPoints(in: graph).isEmpty)
    }

    func testARingHasNoSinglePointOfFailure() {
        let graph = NetworkTopology.adjacency([
            path("A", "B"), path("B", "C"), path("C", "D"), path("D", "A"),
        ])
        // Redundancy is exactly what this detects the absence of.
        XCTAssertTrue(NetworkTopology.articulationPoints(in: graph).isEmpty)
    }

    func testTheBridgeBetweenTwoClustersIsFound() {
        let graph = NetworkTopology.adjacency([
            path("A", "B"), path("B", "C"), path("A", "C"),
            path("C", "D"),
            path("D", "E"), path("E", "F"), path("D", "F"),
        ])
        XCTAssertEqual(NetworkTopology.articulationPoints(in: graph), ["C", "D"])
    }

    func testAChainOfDigipeatersDoesNotOverflowTheStack() {
        // Iterative on purpose: a deep chain would otherwise put the stack
        // depth at the mercy of someone else's network.
        var paths: [NetworkPath] = []
        for i in 0..<5_000 {
            paths.append(path("N\(i)", "N\(i + 1)"))
        }
        let graph = NetworkTopology.adjacency(paths)
        XCTAssertEqual(NetworkTopology.articulationPoints(in: graph).count, 5_000 - 1)
    }

    // MARK: - What is lost

    func testPartitionsNameWhatGoesWithTheNode() {
        let graph = NetworkTopology.adjacency([
            path("A", "DIGI"), path("B", "DIGI"), path("B", "C"),
        ])
        let parts = NetworkTopology.partitionsWithout("DIGI", in: graph)
        // "DRLNOD is an articulation point" is a fact; "and you lose these
        // stations" is something an operator can act on.
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.first, ["B", "C"])
        XCTAssertEqual(parts.last, ["A"])
    }

    func testRemovingALeafLeavesOneNetwork() {
        let graph = NetworkTopology.adjacency([path("A", "B"), path("B", "C")])
        XCTAssertEqual(NetworkTopology.partitionsWithout("A", in: graph).count, 1)
    }

    // MARK: - Communities

    func testTwoUnconnectedClustersAreSeparateCommunities() {
        let graph = NetworkTopology.adjacency([
            path("DRL1", "DRL2"), path("DRL2", "DRL3"), path("DRL1", "DRL3"),
            path("CTN1", "CTN2"), path("CTN2", "CTN3"), path("CTN1", "CTN3"),
        ])
        let groups = NetworkTopology.communityGroups(in: graph)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains(["DRL1", "DRL2", "DRL3"]))
        XCTAssertTrue(groups.contains(["CTN1", "CTN2", "CTN3"]))
    }

    func testTheResultIsStableAcrossRuns() {
        let graph = NetworkTopology.adjacency([
            path("A", "B"), path("B", "C"), path("C", "A"),
            path("D", "E"), path("E", "F"), path("F", "D"),
        ])
        let first = NetworkTopology.communities(in: graph)
        for _ in 0..<5 {
            // Non-determinism would repaint the map on every redraw, which
            // reads as the network changing when nothing has.
            XCTAssertEqual(NetworkTopology.communities(in: graph), first)
        }
    }

    func testAnIsolatedStationIsNotANetworkOfOne() {
        let graph = NetworkTopology.adjacency([
            path("A", "B"), path("B", "C"),
        ])
        let groups = NetworkTopology.communityGroups(in: graph)
        XCTAssertTrue(groups.allSatisfy { $0.count > 1 })
    }

    func testAClusterJoinedByOneBridgeStillResolves() {
        let graph = NetworkTopology.adjacency([
            path("A", "B"), path("B", "C"), path("A", "C"),
            path("C", "D"),
            path("D", "E"), path("E", "F"), path("D", "F"),
        ])
        // Whatever the split, every station must land somewhere.
        let groups = NetworkTopology.communityGroups(in: graph)
        let covered = groups.reduce(into: Set<String>()) { $0.formUnion($1) }
        XCTAssertEqual(covered, ["A", "B", "C", "D", "E", "F"])
    }

    func testAnEmptyGraphAnalysesToNothing() {
        XCTAssertTrue(NetworkTopology.articulationPoints(in: [:]).isEmpty)
        XCTAssertTrue(NetworkTopology.communityGroups(in: [:]).isEmpty)
    }
}
