import XCTest
@testable import AXTerm

final class NetworkGraphBuilderTests: XCTestCase {

    func testMinEdgeCountFiltersEdgesAndNodes() {
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(2), from: "K9ALP", to: "N3CHR")
        ]

        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(includeViaDigipeaters: false, minimumEdgeCount: 2, maxNodes: 10)
        )

        XCTAssertEqual(model.edges.count, 1)
        XCTAssertEqual(model.nodes.count, 2)
        XCTAssertEqual(model.nodes.map { $0.id }.sorted(), ["K9ALP", "W5BRV"])
    }

    func testIncludeViaDigipeatersAddsNodesAndEdges() {
        let base = Date(timeIntervalSince1970: 1_700_110_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV", via: ["N0DIG"])
        ]

        let modelWithoutVia = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(includeViaDigipeaters: false, minimumEdgeCount: 1, maxNodes: 10)
        )

        let modelWithVia = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(includeViaDigipeaters: true, minimumEdgeCount: 1, maxNodes: 10)
        )

        XCTAssertEqual(modelWithoutVia.nodes.count, 2)
        XCTAssertEqual(modelWithVia.nodes.count, 3)
        XCTAssertEqual(modelWithVia.edges.count, 2)
    }

    func testStableNodeIDsAcrossRebuilds() {
        let base = Date(timeIntervalSince1970: 1_700_120_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(5), from: "W5BRV", to: "N3CHR")
        ]

        let options = NetworkGraphBuilder.Options(includeViaDigipeaters: false, minimumEdgeCount: 1, maxNodes: 10)
        let modelA = NetworkGraphBuilder.build(packets: packets, options: options)
        let modelB = NetworkGraphBuilder.build(packets: packets, options: options)

        XCTAssertEqual(modelA.nodes.map { $0.id }.sorted(), modelB.nodes.map { $0.id }.sorted())
    }

    func testMaxNodesCappingDeterministic() {
        let base = Date(timeIntervalSince1970: 1_700_130_000)
        let packets = [
            makePacket(timestamp: base, from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "K9ALP", to: "W5BRV"),
            makePacket(timestamp: base.addingTimeInterval(2), from: "N3CHR", to: "W4DEL")
        ]

        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(includeViaDigipeaters: false, minimumEdgeCount: 1, maxNodes: 2)
        )

        XCTAssertEqual(model.nodes.count, 2)
        XCTAssertTrue(model.nodes.map { $0.id }.sorted().contains("K9ALP"))
        XCTAssertTrue(model.nodes.map { $0.id }.sorted().contains("W5BRV"))
        XCTAssertEqual(model.droppedNodesCount, 2)
    }

    // MARK: - Station Identity Mode Tests

    func testStationModeGroupsSSIDsIntoSingleNode() {
        let base = Date(timeIntervalSince1970: 1_700_140_000)
        let packets = [
            // W6ANH and W6ANH-1 and W6ANH-15 should all become a single "W6ANH" node
            makePacket(timestamp: base, from: "W6ANH", to: "N4DRL"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "W6ANH-1", to: "N4DRL"),
            makePacket(timestamp: base.addingTimeInterval(2), from: "W6ANH-15", to: "N4DRL")
        ]

        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 10,
                stationIdentityMode: .station
            )
        )

        // Should have 2 nodes: W6ANH (grouped) and N4DRL
        XCTAssertEqual(model.nodes.count, 2)
        XCTAssertTrue(model.nodes.map { $0.id }.contains("W6ANH"))
        XCTAssertTrue(model.nodes.map { $0.id }.contains("N4DRL"))

        // Find the W6ANH node and check its grouped SSIDs
        let anhNode = model.nodes.first { $0.id == "W6ANH" }
        XCTAssertNotNil(anhNode)
        XCTAssertEqual(anhNode?.groupedSSIDs.count, 3)
        XCTAssertTrue(anhNode?.groupedSSIDs.contains("W6ANH") == true)
        XCTAssertTrue(anhNode?.groupedSSIDs.contains("W6ANH-1") == true)
        XCTAssertTrue(anhNode?.groupedSSIDs.contains("W6ANH-15") == true)

        // Packet counts should aggregate
        XCTAssertEqual(anhNode?.outCount, 3)
    }

    func testSSIDModeShowsSeparateNodes() {
        let base = Date(timeIntervalSince1970: 1_700_150_000)
        let packets = [
            // In SSID mode, W6ANH and W6ANH-15 should be separate nodes
            makePacket(timestamp: base, from: "W6ANH", to: "N4DRL"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "W6ANH-15", to: "N4DRL")
        ]

        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 10,
                stationIdentityMode: .ssid
            )
        )

        // Should have 3 nodes: W6ANH, W6ANH-15, and N4DRL
        XCTAssertEqual(model.nodes.count, 3)
        XCTAssertTrue(model.nodes.map { $0.id }.contains("W6ANH"))
        XCTAssertTrue(model.nodes.map { $0.id }.contains("W6ANH-15"))
        XCTAssertTrue(model.nodes.map { $0.id }.contains("N4DRL"))
    }

    func testSSIDZeroTreatedAsNoSSID() {
        let base = Date(timeIntervalSince1970: 1_700_160_000)
        let packets = [
            // W6ANH-0 should be normalized to W6ANH in station mode
            makePacket(timestamp: base, from: "W6ANH-0", to: "N4DRL"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "W6ANH", to: "N4DRL")
        ]

        let modelStation = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(
                includeViaDigipeaters: false,
                minimumEdgeCount: 1,
                maxNodes: 10,
                stationIdentityMode: .station
            )
        )

        // W6ANH-0 and W6ANH should both be "W6ANH" in station mode
        XCTAssertEqual(modelStation.nodes.count, 2)
        let anhNode = modelStation.nodes.first { $0.id == "W6ANH" }
        XCTAssertEqual(anhNode?.outCount, 2)
    }

    private func makePacket(
        timestamp: Date,
        from: String,
        to: String,
        via: [String] = []
    ) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: .ui,
            info: Data(repeating: 0x41, count: 10)
        )
    }
}
