//
//  GraphFixtures.swift
//  AXTermTests
//
//  Test fixtures and helpers for network graph testing.
//  Provides synthetic packet datasets and graph comparison utilities.
//

import Foundation
@testable import AXTerm

// MARK: - Lightweight Packet Row (for test fixtures)

/// Lightweight packet representation for test fixtures.
/// Matches production parser output without full Packet overhead.
struct PacketRow {
    let ts: Date
    let from: String
    let to: String?
    let via: [String]        // empty = direct, non-empty = via digipeaters
    let payloadType: String? // optional (UI, I, etc.)
    let payloadBytes: Int

    init(
        ts: Date = Date(),
        from: String,
        to: String? = nil,
        via: [String] = [],
        payloadType: String? = "UI",
        payloadBytes: Int = 10
    ) {
        self.ts = ts
        self.from = from
        self.to = to
        self.via = via
        self.payloadType = payloadType
        self.payloadBytes = payloadBytes
    }
}

// MARK: - Graph Fixture Builder

/// Builds synthetic packet datasets for predictable graph testing.
struct GraphFixtureBuilder {
    private var packets: [PacketRow] = []
    private var baseTimestamp: Date
    private var timestampOffset: TimeInterval = 0

    init(baseTimestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.baseTimestamp = baseTimestamp
    }

    // MARK: - Packet Building

    /// Adds a direct endpoint message (A -> B with no via path).
    /// This creates endpoint-to-endpoint traffic for DirectPeer detection.
    mutating func addDirectEndpoint(from: String, to: String, count: Int = 1) -> GraphFixtureBuilder {
        for i in 0..<count {
            packets.append(PacketRow(
                ts: nextTimestamp(),
                from: from,
                to: to,
                via: [],
                payloadType: "I" // Info frame for endpoint traffic
            ))
        }
        return self
    }

    /// Adds bidirectional direct endpoint traffic (A <-> B).
    /// This qualifies as DirectPeer (bidirectional endpoint exchange).
    mutating func addDirectPeerExchange(between a: String, and b: String, countEachDirection: Int = 2) -> GraphFixtureBuilder {
        for _ in 0..<countEachDirection {
            packets.append(PacketRow(ts: nextTimestamp(), from: a, to: b, via: []))
            packets.append(PacketRow(ts: nextTimestamp(), from: b, to: a, via: []))
        }
        return self
    }

    /// Adds a via-path observation (A sees B via digipeaters).
    /// This creates HeardVia (seenVia) relationships.
    mutating func addViaObservation(from: String, to: String, via: [String], count: Int = 1) -> GraphFixtureBuilder {
        for _ in 0..<count {
            packets.append(PacketRow(
                ts: nextTimestamp(),
                from: from,
                to: to,
                via: via
            ))
        }
        return self
    }

    /// Adds a direct reception (local station hears a packet with no via path).
    /// Creates HeardDirect relationship when the local station decodes it.
    mutating func addDirectReception(heardBy localStation: String, from sender: String, count: Int = 1) -> GraphFixtureBuilder {
        // In APRS/AX.25, if localStation decodes a packet from sender with no via path,
        // this is evidence of direct RF reception. Model as sender -> localStation with empty via.
        for _ in 0..<count {
            packets.append(PacketRow(
                ts: nextTimestamp(),
                from: sender,
                to: localStation,
                via: []
            ))
        }
        return self
    }

    /// Adds a UI broadcast (beacon/ID) heard directly.
    mutating func addUIBroadcast(from sender: String, hearingStation: String? = nil, via: [String] = []) -> GraphFixtureBuilder {
        // UI frames often have to=BEACON or to=ID
        let dest = hearingStation ?? "BEACON"
        packets.append(PacketRow(
            ts: nextTimestamp(),
            from: sender,
            to: dest,
            via: via,
            payloadType: "UI"
        ))
        return self
    }

    /// Adds many packets to create sustained activity (for HeardDirect scoring).
    /// Spreads across multiple 5-minute buckets for scoring eligibility.
    mutating func addSustainedDirectActivity(from: String, to: String, minuteSpan: Int = 15, packetsPerMinute: Int = 2) -> GraphFixtureBuilder {
        for minute in 0..<minuteSpan {
            for _ in 0..<packetsPerMinute {
                packets.append(PacketRow(
                    ts: baseTimestamp.addingTimeInterval(Double(minute * 60) + timestampOffset),
                    from: from,
                    to: to,
                    via: []
                ))
                timestampOffset += 10
            }
        }
        return self
    }

    // MARK: - Build

    /// Returns the built packet rows.
    func build() -> [PacketRow] {
        packets
    }

    /// Converts packet rows to production Packet objects.
    func buildPackets() -> [Packet] {
        packets.map { row in
            Packet(
                timestamp: row.ts,
                from: AX25Address(call: row.from),
                to: row.to.map { AX25Address(call: $0) },
                via: row.via.map { AX25Address(call: $0) },
                frameType: frameType(from: row.payloadType),
                info: Data(repeating: 0x41, count: row.payloadBytes)
            )
        }
    }

    /// Converts packet rows to PacketEvent objects.
    func buildEvents() -> [PacketEvent] {
        buildPackets().map { PacketEvent(packet: $0) }
    }

    // MARK: - Private Helpers

    private mutating func nextTimestamp() -> Date {
        let ts = baseTimestamp.addingTimeInterval(timestampOffset)
        timestampOffset += 1
        return ts
    }

    private func frameType(from payloadType: String?) -> FrameType {
        switch payloadType?.uppercased() {
        case "I": return .i
        case "UI": return .ui
        case "S": return .s
        case "U": return .u
        default: return .ui
        }
    }
}

// MARK: - Graph Assertions

/// Helpers for asserting graph properties in tests.
struct GraphAssertions {

    // MARK: - Node Assertions

    /// Asserts that the graph contains exactly the expected node IDs.
    static func assertNodes(
        _ graph: ClassifiedGraphModel,
        expectedIDs: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let actualIDs = Set(graph.nodes.map { $0.id })
        if actualIDs != expectedIDs {
            print("GraphAssertions.assertNodes FAILED at \(file):\(line)")
            print("  Expected nodes: \(expectedIDs.sorted())")
            print("  Actual nodes:   \(actualIDs.sorted())")
            print("  Missing: \(expectedIDs.subtracting(actualIDs).sorted())")
            print("  Extra:   \(actualIDs.subtracting(expectedIDs).sorted())")
            return false
        }
        return true
    }

    /// Asserts that the graph contains at least the specified node IDs.
    static func assertContainsNodes(
        _ graph: ClassifiedGraphModel,
        requiredIDs: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let actualIDs = Set(graph.nodes.map { $0.id })
        let missing = requiredIDs.subtracting(actualIDs)
        if !missing.isEmpty {
            print("GraphAssertions.assertContainsNodes FAILED at \(file):\(line)")
            print("  Required nodes: \(requiredIDs.sorted())")
            print("  Actual nodes:   \(actualIDs.sorted())")
            print("  Missing: \(missing.sorted())")
            return false
        }
        return true
    }

    /// Asserts that the ViewGraph (GraphModel) contains the specified node.
    static func assertViewGraphContainsNode(
        _ viewGraph: GraphModel,
        nodeID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let actualIDs = Set(viewGraph.nodes.map { $0.id })
        if !actualIDs.contains(nodeID) {
            print("GraphAssertions.assertViewGraphContainsNode FAILED at \(file):\(line)")
            print("  Expected node '\(nodeID)' to be present")
            print("  Actual nodes: \(actualIDs.sorted())")
            return false
        }
        return true
    }

    // MARK: - Edge Assertions

    /// Asserts that an edge of the specified type exists between two nodes.
    static func assertEdgeExists(
        _ graph: ClassifiedGraphModel,
        from: String,
        to: String,
        type: LinkType,
        minWeight: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let edge = graph.edges.first { edge in
            let matches = (edge.sourceID == from && edge.targetID == to) ||
                          (edge.sourceID == to && edge.targetID == from)
            return matches && edge.linkType == type
        }

        if edge == nil {
            print("GraphAssertions.assertEdgeExists FAILED at \(file):\(line)")
            print("  Expected edge: \(from) <-> \(to) [\(type.rawValue)]")
            print("  Existing edges:")
            for e in graph.edges {
                print("    \(e.sourceID) <-> \(e.targetID) [\(e.linkType.rawValue)] weight=\(e.weight)")
            }
            return false
        }

        if let minWeight = minWeight, let foundEdge = edge, foundEdge.weight < minWeight {
            print("GraphAssertions.assertEdgeExists FAILED at \(file):\(line)")
            print("  Edge \(from) <-> \(to) [\(type.rawValue)] has weight \(foundEdge.weight), expected >= \(minWeight)")
            return false
        }

        return true
    }

    /// Asserts that NO edge of the specified type exists between two nodes.
    static func assertNoEdge(
        _ graph: ClassifiedGraphModel,
        from: String,
        to: String,
        type: LinkType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let edge = graph.edges.first { edge in
            let matches = (edge.sourceID == from && edge.targetID == to) ||
                          (edge.sourceID == to && edge.targetID == from)
            return matches && edge.linkType == type
        }

        if edge != nil {
            print("GraphAssertions.assertNoEdge FAILED at \(file):\(line)")
            print("  Unexpected edge found: \(from) <-> \(to) [\(type.rawValue)]")
            return false
        }
        return true
    }

    /// Asserts that an edge exists in the ViewGraph (unclassified).
    static func assertViewGraphEdgeExists(
        _ viewGraph: GraphModel,
        from: String,
        to: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let edge = viewGraph.edges.first { edge in
            (edge.sourceID == from && edge.targetID == to) ||
            (edge.sourceID == to && edge.targetID == from)
        }

        if edge == nil {
            print("GraphAssertions.assertViewGraphEdgeExists FAILED at \(file):\(line)")
            print("  Expected edge: \(from) <-> \(to)")
            print("  Existing edges:")
            for e in viewGraph.edges {
                print("    \(e.sourceID) <-> \(e.targetID) weight=\(e.weight)")
            }
            return false
        }
        return true
    }

    // MARK: - Edge Count Assertions

    /// Asserts that the graph has exactly the expected number of edges of each type.
    static func assertEdgeCounts(
        _ graph: ClassifiedGraphModel,
        directPeer: Int? = nil,
        heardDirect: Int? = nil,
        heardVia: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        var success = true

        if let expected = directPeer {
            let actual = graph.edges.filter { $0.linkType == .directPeer }.count
            if actual != expected {
                print("GraphAssertions.assertEdgeCounts FAILED at \(file):\(line)")
                print("  DirectPeer edges: expected \(expected), got \(actual)")
                success = false
            }
        }

        if let expected = heardDirect {
            let actual = graph.edges.filter { $0.linkType == .heardDirect }.count
            if actual != expected {
                print("GraphAssertions.assertEdgeCounts FAILED at \(file):\(line)")
                print("  HeardDirect edges: expected \(expected), got \(actual)")
                success = false
            }
        }

        if let expected = heardVia {
            let actual = graph.edges.filter { $0.linkType == .heardVia }.count
            if actual != expected {
                print("GraphAssertions.assertEdgeCounts FAILED at \(file):\(line)")
                print("  HeardVia edges: expected \(expected), got \(actual)")
                success = false
            }
        }

        return success
    }

    // MARK: - SSID Grouping Assertions

    /// Asserts that a node contains the expected grouped SSIDs.
    static func assertGroupedSSIDs(
        _ graph: ClassifiedGraphModel,
        nodeID: String,
        expectedSSIDs: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
            print("GraphAssertions.assertGroupedSSIDs FAILED at \(file):\(line)")
            print("  Node '\(nodeID)' not found")
            return false
        }

        let actualSSIDs = Set(node.groupedSSIDs)
        if actualSSIDs != expectedSSIDs {
            print("GraphAssertions.assertGroupedSSIDs FAILED at \(file):\(line)")
            print("  Node: \(nodeID)")
            print("  Expected SSIDs: \(expectedSSIDs.sorted())")
            print("  Actual SSIDs:   \(actualSSIDs.sorted())")
            return false
        }
        return true
    }
}

// MARK: - Debug Dump

/// Debug utilities for failing test diagnostics.
struct GraphDebugDump {

    /// Prints detailed graph diagnostics.
    static func dump(
        classifiedGraph: ClassifiedGraphModel,
        viewGraph: GraphModel? = nil,
        options: NetworkGraphBuilder.Options? = nil,
        label: String = "Graph Debug Dump"
    ) {
        print("\n=== \(label) ===")

        if let options = options {
            print("Options:")
            print("  includeViaDigipeaters: \(options.includeViaDigipeaters)")
            print("  minimumEdgeCount: \(options.minimumEdgeCount)")
            print("  maxNodes: \(options.maxNodes)")
            print("  stationIdentityMode: \(options.stationIdentityMode.rawValue)")
        }

        print("\nClassified Graph:")
        print("  Nodes (\(classifiedGraph.nodes.count)):")
        for node in classifiedGraph.nodes.sorted(by: { $0.id < $1.id }) {
            let ssids = node.groupedSSIDs.count > 1 ? " [SSIDs: \(node.groupedSSIDs.joined(separator: ", "))]" : ""
            print("    \(node.id) - weight=\(node.weight), degree=\(node.degree)\(ssids)")
        }

        print("  Edges (\(classifiedGraph.edges.count)):")
        for edge in classifiedGraph.edges.sorted(by: { "\($0.sourceID)-\($0.targetID)" < "\($1.sourceID)-\($1.targetID)" }) {
            let via = edge.viaDigipeaters.isEmpty ? "" : " via=[\(edge.viaDigipeaters.joined(separator: ","))]"
            print("    \(edge.sourceID) <-> \(edge.targetID) [\(edge.linkType.rawValue)] weight=\(edge.weight)\(via)")
        }

        // Count by type
        let directPeerCount = classifiedGraph.edges.filter { $0.linkType == .directPeer }.count
        let heardDirectCount = classifiedGraph.edges.filter { $0.linkType == .heardDirect }.count
        let heardViaCount = classifiedGraph.edges.filter { $0.linkType == .heardVia }.count
        print("  Edge counts by type: DirectPeer=\(directPeerCount), HeardDirect=\(heardDirectCount), HeardVia=\(heardViaCount)")

        if let viewGraph = viewGraph {
            print("\nView Graph (filtered):")
            print("  Nodes (\(viewGraph.nodes.count)):")
            for node in viewGraph.nodes.sorted(by: { $0.id < $1.id }) {
                print("    \(node.id) - weight=\(node.weight), degree=\(node.degree)")
            }
            print("  Edges (\(viewGraph.edges.count)):")
            for edge in viewGraph.edges.sorted(by: { "\($0.sourceID)-\($0.targetID)" < "\($1.sourceID)-\($1.targetID)" }) {
                print("    \(edge.sourceID) <-> \(edge.targetID) weight=\(edge.weight)")
            }
        }

        print("=== End Debug Dump ===\n")
    }

    /// Returns a compact summary string.
    static func summary(_ graph: ClassifiedGraphModel) -> String {
        let nodeCount = graph.nodes.count
        let edgeCount = graph.edges.count
        let nodeIDs = graph.nodes.map { $0.id }.sorted().joined(separator: ", ")
        return "Nodes(\(nodeCount)): [\(nodeIDs)], Edges(\(edgeCount))"
    }
}

// MARK: - View Graph Derivation (Mirrors AnalyticsDashboardViewModel logic)

/// Derives a ViewGraph from ClassifiedGraphModel using the same logic as production.
/// This allows testing view filtering without the full ViewModel.
struct ViewGraphDeriver {

    /// Derives a GraphModel by filtering edges based on view mode.
    static func deriveViewGraph(
        from classifiedModel: ClassifiedGraphModel,
        viewMode: GraphViewMode
    ) -> GraphModel {
        let visibleTypes = viewMode.visibleLinkTypes
        let filteredEdges = classifiedModel.edges
            .filter { visibleTypes.contains($0.linkType) }
            .map { edge in
                NetworkGraphEdge(
                    sourceID: edge.sourceID,
                    targetID: edge.targetID,
                    weight: edge.weight,
                    bytes: edge.bytes
                )
            }

        // Build adjacency from filtered edges
        var adjacency: [String: [GraphNeighborStat]] = [:]
        for edge in filteredEdges {
            adjacency[edge.sourceID, default: []].append(
                GraphNeighborStat(id: edge.targetID, weight: edge.weight, bytes: edge.bytes)
            )
            adjacency[edge.targetID, default: []].append(
                GraphNeighborStat(id: edge.sourceID, weight: edge.weight, bytes: edge.bytes)
            )
        }

        // Update node degrees based on filtered edges
        let updatedNodes = classifiedModel.nodes.map { node in
            let neighbors = adjacency[node.id] ?? []
            return NetworkGraphNode(
                id: node.id,
                callsign: node.callsign,
                weight: node.weight,
                inCount: node.inCount,
                outCount: node.outCount,
                inBytes: node.inBytes,
                outBytes: node.outBytes,
                degree: neighbors.count,
                groupedSSIDs: node.groupedSSIDs
            )
        }

        // Sort adjacency by weight
        let sortedAdjacency = adjacency.mapValues { neighbors in
            neighbors.sorted { lhs, rhs in
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.id < rhs.id
            }
        }

        return GraphModel(
            nodes: updatedNodes,
            edges: filteredEdges.sorted { lhs, rhs in
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.sourceID < rhs.sourceID
            },
            adjacency: sortedAdjacency,
            droppedNodesCount: classifiedModel.droppedNodesCount
        )
    }
}
