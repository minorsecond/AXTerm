//
//  StationInspectorViewModelTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-23.
//

import XCTest
@testable import AXTerm

final class StationInspectorViewModelTests: XCTestCase {
    func testCountsCorrect() {
        let timestamp = Date(timeIntervalSince1970: 0)
        let packets = [
            makePacket(timestamp: timestamp, from: "alpha", to: "beta"),
            makePacket(timestamp: timestamp, from: "alpha", to: "delta"),
            makePacket(timestamp: timestamp, from: "gamma", to: "alpha"),
            makePacket(timestamp: timestamp, from: "beta", to: "gamma", via: ["alpha"]),
            makePacket(timestamp: timestamp, from: "delta", to: "epsilon", via: ["alpha"])
        ]
        let edges: [GraphEdge] = []

        let viewModel = StationInspectorViewModel(stationID: "alpha", packets: packets, edges: edges)

        XCTAssertEqual(viewModel.stats.fromCount, 2)
        XCTAssertEqual(viewModel.stats.toCount, 1)
        XCTAssertEqual(viewModel.stats.viaCount, 2)
    }

    func testTopPeersDeterministic() {
        let packets: [Packet] = []
        // GraphEdge uses normalized (uppercase) station IDs to match AX25Address behavior
        let edges = [
            GraphEdge(source: "ALPHA", target: "BETA", count: 3, bytes: nil),
            GraphEdge(source: "GAMMA", target: "ALPHA", count: 3, bytes: nil),
            GraphEdge(source: "ALPHA", target: "DELTA", count: 1, bytes: nil),
            GraphEdge(source: "EPSILON", target: "ALPHA", count: 2, bytes: nil)
        ]

        let viewModel = StationInspectorViewModel(stationID: "alpha", packets: packets, edges: edges)

        let topPeers = viewModel.stats.topPeers
        XCTAssertEqual(topPeers.count, 4)
        XCTAssertEqual(topPeers[0].stationID, "BETA")
        XCTAssertEqual(topPeers[0].count, 3)
        XCTAssertEqual(topPeers[1].stationID, "GAMMA")
        XCTAssertEqual(topPeers[1].count, 3)
        XCTAssertEqual(topPeers[2].stationID, "EPSILON")
        XCTAssertEqual(topPeers[2].count, 2)
        XCTAssertEqual(topPeers[3].stationID, "DELTA")
        XCTAssertEqual(topPeers[3].count, 1)
    }
}

private extension StationInspectorViewModelTests {
    func makePacket(
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
            frameType: .ui
        )
    }
}
