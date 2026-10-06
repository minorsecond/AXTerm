//
//  GraphEdgeTooltipTests.swift
//  AXTermTests
//
//  Hovering an edge showed nothing (smoke run 2026-10-03-1, issue 95).
//

import XCTest
@testable import AXTerm

@MainActor
final class GraphEdgeTooltipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_500_000)

    func testDistanceToASegment() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
        XCTAssertEqual(GraphEdgeHitTest.distance(from: CGPoint(x: 5, y: 3), toSegmentFrom: a, to: b), 3, accuracy: 1e-9)
        XCTAssertEqual(GraphEdgeHitTest.distance(from: CGPoint(x: -4, y: 3), toSegmentFrom: a, to: b), 5, accuracy: 1e-9,
                       "past an end, the distance is to that end")
        XCTAssertEqual(GraphEdgeHitTest.distance(from: CGPoint(x: 3, y: 4), toSegmentFrom: a, to: a), 5, accuracy: 1e-9)
    }

    func testTheTooltipExplainsEachDirection() throws {
        let records = [
            LinkStatRecord(fromCall: "K0EPI-2", toCall: "K0EPI-3", quality: 230, lastUpdated: now.addingTimeInterval(-60),
                           dfEstimate: 0.97, drEstimate: 0.96, duplicateCount: 2, observationCount: 180)
        ]
        let forward = try XCTUnwrap(GraphEdgeTooltip.direction(
            from: "K0EPI-2", to: "K0EPI-3", records: records, identityMode: .ssid, now: now))
        let reverse = GraphEdgeTooltip.direction(
            from: "K0EPI-3", to: "K0EPI-2", records: records, identityMode: .ssid, now: now)
        XCTAssertNil(reverse)

        let lines = GraphEdgeTooltip.lines(
            sourceCall: "K0EPI-2", targetCall: "K0EPI-3", linkType: .heardDirect, weight: 264,
            isNetRomSource: false, forward: forward, reverse: reverse)
        XCTAssertEqual(lines[0], "K0EPI-2 ↔ K0EPI-3")
        XCTAssertEqual(lines[1], "Heard Direct · 264 frames heard")
        XCTAssertEqual(lines[2], "K0EPI-2 → K0EPI-3: quality 230 (90%)")
        XCTAssertEqual(lines[3], "  df 0.97 × dr 0.96 → ETX 1.07")
        XCTAssertTrue(lines[4].hasPrefix("  2 duplicates or retries · freshness "), lines[4])
        XCTAssertTrue(lines.contains("K0EPI-3 → K0EPI-2: no delivery evidence measured"))
        XCTAssertTrue(lines.contains("quality = 255 / ETX, where ETX = 1 / (df × dr)"))
    }

    /// In station mode a node gathers every SSID, so the busiest pair speaks
    /// for the edge and the tooltip says how many there were.
    func testStationModeUsesTheBusiestPair() throws {
        let records = [
            LinkStatRecord(fromCall: "W0ARP-1", toCall: "K0EPI-2", quality: 100, lastUpdated: now,
                           dfEstimate: 0.6, observationCount: 5),
            LinkStatRecord(fromCall: "W0ARP-7", toCall: "K0EPI-2", quality: 200, lastUpdated: now,
                           dfEstimate: 0.9, observationCount: 40)
        ]
        let direction = try XCTUnwrap(GraphEdgeTooltip.direction(
            from: "W0ARP", to: "K0EPI", records: records, identityMode: .station, now: now))
        XCTAssertEqual(direction.stats.fromCall, "W0ARP-7")
        XCTAssertEqual(direction.pairCount, 2)
        let lines = GraphEdgeTooltip.lines(sourceCall: "W0ARP", targetCall: "K0EPI", linkType: .heardDirect,
                                           weight: 45, isNetRomSource: false, forward: direction, reverse: nil)
        XCTAssertTrue(lines.contains("  busiest of 2 callsign pairs"))
        XCTAssertTrue(lines.contains("  df 0.90 × dr unobserved (0.99 assumed) → ETX 1.12"), lines.joined(separator: "\n"))
    }
}
