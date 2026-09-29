import XCTest
@testable import AXTerm

/// The graph findings as they reach the identity page.
@MainActor
final class NodeProfileTopologyTests: XCTestCase {

    /// A chain: A — HUB — B. HUB is the only thing joining the two halves.
    private var chain: [NetworkPath] {
        [path("A", "HUB"), path("HUB", "B")]
    }

    private func path(_ from: String, _ to: String) -> NetworkPath {
        NetworkPath(from: from, to: to, via: [], evidence: .heardDirect,
                    observations: 4, firstSeen: Date(), lastSeen: Date(),
                    unansweredAttempts: 0)
    }

    private func resolver(_ paths: [NetworkPath]) -> NodeProfileResolver {
        var resolver = NodeProfileResolver()
        resolver.networkPaths = paths
        return resolver
    }

    func testHubIsReportedCriticalWithWhatItStrands() {
        let topology = resolver(chain).profile(for: "HUB").topology
        XCTAssertEqual(topology?.neighbourCount, 2)
        XCTAssertTrue(topology?.isCritical == true)
        // Two pieces of one station each; losing the hub strands one of them.
        XCTAssertEqual(topology?.partitionsWithoutIt, [1, 1])
        XCTAssertEqual(topology?.strandedCount, 1)
    }

    func testLeafIsNotCritical() {
        let topology = resolver(chain).profile(for: "A").topology
        XCTAssertEqual(topology?.neighbourCount, 1)
        XCTAssertFalse(topology?.isCritical == true)
        XCTAssertEqual(topology?.strandedCount, 0)
    }

    /// Everything reachable is one cluster, so each station lists the others.
    func testClusterListsTheOtherMembersAndNotItself() {
        let members = resolver(chain).profile(for: "HUB").topology?.communityMembers
        XCTAssertEqual(members, ["A", "B"])
    }

    /// Two groups that never talk must not be reported as one local network.
    func testSeparateGroupsAreSeparateClusters() {
        let paths = [path("A", "B"), path("B", "C"),
                     path("X", "Y"), path("Y", "Z")]
        let resolved = resolver(paths)
        let first = resolved.profile(for: "A").topology?.communityMembers ?? []
        XCTAssertFalse(first.contains("X"))
        XCTAssertFalse(first.contains("Z"))
    }

    /// A station nothing has been heard from has no place in the graph, and
    /// the page must show nothing rather than an empty-looking section.
    func testUnknownStationHasNoTopology() {
        XCTAssertNil(resolver(chain).profile(for: "K0NTS-10").topology)
    }

    func testNoObservedPathsMeansNoSection() {
        XCTAssertNil(resolver([]).profile(for: "HUB").topology)
    }
}
