//
//  NetRomDecayViewModelDisplayTests.swift
//  AXTermTests
//
//  TDD tests for freshness display strings, tooltips, and accessibility labels in ViewModels.
//

import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class NetRomDecayViewModelDisplayTests: XCTestCase {

    private let ttl: TimeInterval = 30 * 60 // 30 minutes
    private let plateau: TimeInterval = 5 * 60 // 5 minutes
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Neighbor Display

    func testNeighborDecayDisplayStringsTooltipsAndAccessibility() {
        // Fresh neighbor (just seen)
        let fresh = NeighborInfo(call: "W1ABC", quality: 200, lastSeen: now, obsolescenceCount: 1, sourceType: "classic")
        // Neighbor at end of plateau (5 minutes)
        let atPlateau = NeighborInfo(call: "W2XYZ", quality: 180, lastSeen: now.addingTimeInterval(-plateau), obsolescenceCount: 1, sourceType: "classic")
        // Expired neighbor (at TTL)
        let expired = NeighborInfo(call: "W3OLD", quality: 160, lastSeen: now.addingTimeInterval(-ttl), obsolescenceCount: 1, sourceType: "classic")

        let freshDisplay = NeighborDisplayInfo(from: fresh, now: now, ttl: ttl, plateau: plateau)
        let plateauDisplay = NeighborDisplayInfo(from: atPlateau, now: now, ttl: ttl, plateau: plateau)
        let expiredDisplay = NeighborDisplayInfo(from: expired, now: now, ttl: ttl, plateau: plateau)

        // Use freshness display strings
        XCTAssertEqual(freshDisplay.freshnessDisplayString, "100%")
        XCTAssertEqual(plateauDisplay.freshnessDisplayString, "95%")
        XCTAssertEqual(expiredDisplay.freshnessDisplayString, "0%")

        // Freshness status labels
        XCTAssertEqual(freshDisplay.freshnessStatus, "Fresh")
        XCTAssertEqual(plateauDisplay.freshnessStatus, "Fresh")
        XCTAssertEqual(expiredDisplay.freshnessStatus, "Expired")

        // Tooltip
        XCTAssertTrue(NeighborDisplayInfo.freshnessTooltip.contains("Freshness"))

        // Accessibility labels should include status and color
        XCTAssertTrue(freshDisplay.freshnessAccessibilityLabel.contains("fresh"))
        XCTAssertTrue(freshDisplay.freshnessAccessibilityLabel.contains("100 percent"))
        XCTAssertTrue(expiredDisplay.freshnessAccessibilityLabel.contains("expired"))
    }

    // MARK: - Route Display

    func testRouteDecayDisplayClassicAndInferred() {
        let classicRoute = RouteInfo(destination: "N0DEST", origin: "W1ABC", quality: 200, path: ["W1ABC"], lastUpdated: now, sourceType: "broadcast")
        let inferredRoute = RouteInfo(destination: "N0DEST", origin: "W2XYZ", quality: 180, path: ["W2XYZ"], lastUpdated: now.addingTimeInterval(-plateau), sourceType: "inferred")

        let classicDisplay = RouteDisplayInfo(from: classicRoute, now: now, ttl: ttl, plateau: plateau)
        let inferredDisplay = RouteDisplayInfo(from: inferredRoute, now: now, ttl: ttl, plateau: plateau)

        XCTAssertEqual(classicDisplay.freshnessDisplayString, "100%")
        XCTAssertEqual(inferredDisplay.freshnessDisplayString, "95%")
        XCTAssertTrue(RouteDisplayInfo.freshnessTooltip.contains("freshness"))
        XCTAssertTrue(classicDisplay.freshnessAccessibilityLabel.contains("fresh"))
        XCTAssertTrue(inferredDisplay.freshnessAccessibilityLabel.contains("fresh"))
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

        let display = LinkStatDisplayInfo(from: stat, now: now, ttl: ttl, plateau: plateau)

        XCTAssertEqual(display.freshnessDisplayString, "0%")
        XCTAssertEqual(display.freshnessStatus, "Expired")
        XCTAssertTrue(LinkStatDisplayInfo.freshnessTooltip.contains("freshness"))
        XCTAssertTrue(display.freshnessAccessibilityLabel.contains("expired"))
    }

    // MARK: - Freshness 255 Mapping

    func testDecay255MappingIsLinear() {
        // At T0, freshness should be 255
        let fresh = NeighborInfo(call: "W1ABC", quality: 200, lastSeen: now, obsolescenceCount: 1, sourceType: "classic")
        let freshDisplay = NeighborDisplayInfo(from: fresh, now: now, ttl: ttl, plateau: plateau)
        XCTAssertEqual(freshDisplay.freshness255, 255)

        // At TTL, freshness should be 0
        let expired = NeighborInfo(call: "W2XYZ", quality: 200, lastSeen: now.addingTimeInterval(-ttl), obsolescenceCount: 1, sourceType: "classic")
        let expiredDisplay = NeighborDisplayInfo(from: expired, now: now, ttl: ttl, plateau: plateau)
        XCTAssertEqual(expiredDisplay.freshness255, 0)

        // At end of plateau, freshness should be ~243 (95% of 255)
        let plateauEnd = NeighborInfo(call: "W3PLT", quality: 200, lastSeen: now.addingTimeInterval(-plateau), obsolescenceCount: 1, sourceType: "classic")
        let plateauDisplay = NeighborDisplayInfo(from: plateauEnd, now: now, ttl: ttl, plateau: plateau)
        XCTAssertEqual(plateauDisplay.freshness255, 242) // round(0.95 * 255) = 242
    }

    // MARK: - Freshness Colors

    func testFreshnessColors() {
        let fresh = NeighborInfo(call: "W1ABC", quality: 200, lastSeen: now, obsolescenceCount: 1, sourceType: "classic")
        let stale = NeighborInfo(call: "W2XYZ", quality: 200, lastSeen: now.addingTimeInterval(-20 * 60), obsolescenceCount: 1, sourceType: "classic")
        let expired = NeighborInfo(call: "W3OLD", quality: 200, lastSeen: now.addingTimeInterval(-ttl), obsolescenceCount: 1, sourceType: "classic")

        let freshDisplay = NeighborDisplayInfo(from: fresh, now: now, ttl: ttl, plateau: plateau)
        let staleDisplay = NeighborDisplayInfo(from: stale, now: now, ttl: ttl, plateau: plateau)
        let expiredDisplay = NeighborDisplayInfo(from: expired, now: now, ttl: ttl, plateau: plateau)

        // Fresh should be green
        XCTAssertEqual(freshDisplay.freshnessColor, .green)

        // Stale should be orange or similar (not green, not gray)
        XCTAssertNotEqual(staleDisplay.freshnessColor, .green)
        XCTAssertNotEqual(staleDisplay.freshnessColor, .gray)

        // Expired should be gray
        XCTAssertEqual(expiredDisplay.freshnessColor, .gray)
    }

    // MARK: - Legacy API Compatibility

    func testLegacyDecayAPIStillWorks() {
        // The deprecated decay methods should still work (returning freshness values)
        let neighbor = NeighborInfo(call: "W1ABC", quality: 200, lastSeen: now, obsolescenceCount: 1, sourceType: "classic")
        let display = NeighborDisplayInfo(from: neighbor, now: now, ttl: ttl, plateau: plateau)

        // Deprecated properties should return same values as freshness
        XCTAssertEqual(display.decayFraction, display.freshness)
        XCTAssertEqual(display.decayDisplayString, display.freshnessDisplayString)
        XCTAssertEqual(display.decay255, display.freshness255)
    }
}
