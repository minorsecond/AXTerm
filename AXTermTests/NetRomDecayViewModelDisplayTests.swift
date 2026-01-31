//
//  NetRomDecayViewModelDisplayTests.swift
//  AXTermTests
//
//  TDD tests for decay display strings, tooltips, and accessibility labels in ViewModels.
//

import XCTest
@testable import AXTerm

@MainActor
final class NetRomDecayViewModelDisplayTests: XCTestCase {

    private let ttl: TimeInterval = 100
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Neighbor Display

    func testNeighborDecayDisplayStringsTooltipsAndAccessibility() {
        let fresh = NeighborInfo(call: "W1ABC", quality: 200, lastSeen: now, obsolescenceCount: 1, sourceType: "classic")
        let half = NeighborInfo(call: "W2XYZ", quality: 180, lastSeen: now.addingTimeInterval(-ttl / 2), obsolescenceCount: 1, sourceType: "classic")
        let expired = NeighborInfo(call: "W3OLD", quality: 160, lastSeen: now.addingTimeInterval(-ttl), obsolescenceCount: 1, sourceType: "classic")

        let freshDisplay = NeighborDisplayInfo(from: fresh, now: now, ttl: ttl)
        let halfDisplay = NeighborDisplayInfo(from: half, now: now, ttl: ttl)
        let expiredDisplay = NeighborDisplayInfo(from: expired, now: now, ttl: ttl)

        XCTAssertEqual(freshDisplay.decayDisplayString, "100%")
        XCTAssertEqual(halfDisplay.decayDisplayString, "50%")
        XCTAssertEqual(expiredDisplay.decayDisplayString, "0%")

        XCTAssertEqual(NeighborDisplayInfo.decayTooltip, "Freshness indicates how recently this neighbor was heard. 100% means seen within TTL; lower values fade toward expired.")
        XCTAssertEqual(freshDisplay.decayAccessibilityLabel, "Neighbor W1ABC freshness is 100 percent.")
        XCTAssertEqual(halfDisplay.decayAccessibilityLabel, "Neighbor W2XYZ freshness is 50 percent.")
        XCTAssertEqual(expiredDisplay.decayAccessibilityLabel, "Neighbor W3OLD freshness is expired.")
    }

    // MARK: - Route Display

    func testRouteDecayDisplayClassicAndInferred() {
        let classicRoute = RouteInfo(destination: "N0DEST", origin: "W1ABC", quality: 200, path: ["W1ABC"], lastUpdated: now, sourceType: "broadcast")
        let inferredRoute = RouteInfo(destination: "N0DEST", origin: "W2XYZ", quality: 180, path: ["W2XYZ"], lastUpdated: now.addingTimeInterval(-ttl / 2), sourceType: "inferred")

        let classicDisplay = RouteDisplayInfo(from: classicRoute, now: now, ttl: ttl)
        let inferredDisplay = RouteDisplayInfo(from: inferredRoute, now: now, ttl: ttl)

        XCTAssertEqual(classicDisplay.decayDisplayString, "100%")
        XCTAssertEqual(inferredDisplay.decayDisplayString, "50%")
        XCTAssertEqual(RouteDisplayInfo.decayTooltip, "Route freshness is based on the last time this path was reinforced. Older evidence yields lower freshness.")
        XCTAssertEqual(classicDisplay.decayAccessibilityLabel, "Route to N0DEST freshness is 100 percent.")
        XCTAssertEqual(inferredDisplay.decayAccessibilityLabel, "Route to N0DEST freshness is 50 percent.")
    }

    // MARK: - Link Quality Display

    func testLinkQualityDecayDisplayAndAccessibility() {
        let stat = LinkStatRecord(
            fromCall: "W1ABC",
            toCall: "N0CAL",
            quality: 200,
            lastUpdated: now.addingTimeInterval(-ttl),
            dfEstimate: 0.9,
            drEstimate: nil,
            duplicateCount: 0,
            observationCount: 10
        )

        let display = LinkStatDisplayInfo(from: stat, now: now, ttl: ttl)

        XCTAssertEqual(display.decayDisplayString, "0%")
        XCTAssertEqual(LinkStatDisplayInfo.decayTooltip, "Freshness indicates how recently link statistics were updated. Newer stats appear fresher; older stats fade toward expired.")
        XCTAssertEqual(display.decayAccessibilityLabel, "Link from W1ABC to N0CAL freshness is expired.")
    }

    // MARK: - Linear Mapping

    func testDecay255MappingIsLinear() {
        let neighbor = NeighborInfo(call: "W1ABC", quality: 200, lastSeen: now.addingTimeInterval(-ttl / 2), obsolescenceCount: 1, sourceType: "classic")
        let display = NeighborDisplayInfo(from: neighbor, now: now, ttl: ttl)
        XCTAssertEqual(display.decay255, 128)
    }
}
