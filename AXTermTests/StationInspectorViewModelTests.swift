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
        let edges = [
            GraphEdge(source: "alpha", target: "beta", count: 3, bytes: nil),
            GraphEdge(source: "gamma", target: "alpha", count: 3, bytes: nil),
            GraphEdge(source: "alpha", target: "delta", count: 1, bytes: nil),
            GraphEdge(source: "epsilon", target: "alpha", count: 2, bytes: nil)
        ]

        let viewModel = StationInspectorViewModel(stationID: "alpha", packets: packets, edges: edges)

        XCTAssertEqual(
            viewModel.stats.topPeers.map { ($0.stationID, $0.count) },
            [("beta", 3), ("gamma", 3), ("epsilon", 2), ("delta", 1)]
        )
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
