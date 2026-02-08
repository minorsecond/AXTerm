//
//  AnalyticsEdgesTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-20.
//

import XCTest
@testable import AXTerm

final class AnalyticsEdgesTests: XCTestCase {
    func testComputeEdgesWithoutDigipeaters() {
        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "src"),
            to: AX25Address(call: "dst"),
            via: [AX25Address(call: "dig1"), AX25Address(call: "dig2")],
            frameType: .ui,
            info: Data([0x01, 0x02])
        )

        let edges = AnalyticsEngine.computeEdges(
            packets: [packet],
            includeViaDigipeaters: false,
            minCount: 1
        )

        XCTAssertEqual(edges, [GraphEdge(source: "SRC", target: "DST", count: 1, bytes: 2)])
    }

    func testComputeEdgesWithDigipeaters() {
        let packet = Packet(
            timestamp: Date(),
            from: AX25Address(call: "src"),
            to: AX25Address(call: "dst"),
            via: [AX25Address(call: "dig1"), AX25Address(call: "dig2")],
            frameType: .ui,
            info: Data([0x01, 0x02])
        )

        let edges = AnalyticsEngine.computeEdges(
            packets: [packet],
            includeViaDigipeaters: true,
            minCount: 1
        )

        let expected: Set<GraphEdge> = [
            GraphEdge(source: "SRC", target: "DIG1", count: 1, bytes: 2),
            GraphEdge(source: "DIG1", target: "DIG2", count: 1, bytes: 2),
            GraphEdge(source: "DIG2", target: "DST", count: 1, bytes: 2)
        ]

        XCTAssertEqual(Set(edges), expected)
    }

    func testComputeEdgesMinCountFilters() {
        let packet1 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "a"),
            to: AX25Address(call: "b"),
            frameType: .ui,
            info: Data([0x01])
        )
        let packet2 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "a"),
            to: AX25Address(call: "b"),
            frameType: .ui,
            info: Data([0x02, 0x03])
        )
        let packet3 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "c"),
            to: AX25Address(call: "d"),
            frameType: .ui,
            info: Data([0x04])
        )

        let edges = AnalyticsEngine.computeEdges(
            packets: [packet1, packet2, packet3],
            includeViaDigipeaters: false,
            minCount: 2
        )

        XCTAssertEqual(edges, [GraphEdge(source: "A", target: "B", count: 2, bytes: 3)])
    }

    func testComputeEdgesSkipsUnknownFromOrTo() {
        let packet1 = Packet(
            timestamp: Date(),
            from: nil,
            to: AX25Address(call: "dest"),
            frameType: .ui,
            info: Data([0x01])
        )
        let packet2 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "src"),
            to: nil,
            frameType: .ui,
            info: Data([0x02])
        )
        let packet3 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "src"),
            to: AX25Address(call: "dest"),
            frameType: .ui,
            info: Data([0x03])
        )

        let edges = AnalyticsEngine.computeEdges(
            packets: [packet1, packet2, packet3],
            includeViaDigipeaters: false,
            minCount: 1
        )

        XCTAssertEqual(edges, [GraphEdge(source: "SRC", target: "DEST", count: 1, bytes: 1)])
    }

    func testComputeEdgesDeterministicOrderingWithTies() {
        let packet1 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "a"),
            to: AX25Address(call: "c"),
            frameType: .ui,
            info: Data([0x01])
        )
        let packet2 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "a"),
            to: AX25Address(call: "b"),
            frameType: .ui,
            info: Data([0x02])
        )
        let packet3 = Packet(
            timestamp: Date(),
            from: AX25Address(call: "b"),
            to: AX25Address(call: "a"),
            frameType: .ui,
            info: Data([0x03])
        )

        let edges = AnalyticsEngine.computeEdges(
            packets: [packet1, packet2, packet3],
            includeViaDigipeaters: false,
            minCount: 1
        )

        let expected = [
            GraphEdge(source: "A", target: "B", count: 1, bytes: 1),
            GraphEdge(source: "A", target: "C", count: 1, bytes: 1),
            GraphEdge(source: "B", target: "A", count: 1, bytes: 1)
        ]

        XCTAssertEqual(edges, expected)
    }
}
