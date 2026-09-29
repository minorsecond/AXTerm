//
//  HarvestedRoutePolicyTests.swift
//  AXTermTests
//
//  The gate between a scraped ROUTES row and the route table. The policy is
//  positive: only a proven NET/ROM-capable anchor may contribute, because
//  a KA-Node's table lists stations it has heard, not routes it can carry.
//

import XCTest
@testable import AXTerm

final class HarvestedRoutePolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    private func row(_ neighbor: String, anchor: String = "KB5YZB-7", quality: Int = 192) -> BpqRoutesScraper.HarvestedLink {
        BpqRoutesScraper.HarvestedLink(
            anchor: anchor, neighbor: neighbor, port: 1,
            quality: quality, count: 9, isActive: true, observedAt: now)
    }

    func testAProvenAnchorYieldsHarvestedRoutes() {
        let decision = HarvestedRoutePolicy.decide(
            rows: [row("KE0GB-7"), row("VE3CGR-7")],
            anchorCanRouteNetRom: true,
            localCallsign: "K0EPI-7")

        XCTAssertEqual(decision.accepted.count, 2)
        let first = decision.accepted[0]
        XCTAssertEqual(first.destination, "KE0GB-7")
        XCTAssertEqual(first.origin, "KB5YZB-7")
        XCTAssertEqual(first.path, ["KB5YZB-7", "KE0GB-7"])
        XCTAssertEqual(first.sourceType, "harvested")
        XCTAssertEqual(first.quality, 192)
        XCTAssertTrue(decision.refused.isEmpty)
    }

    /// DRLNOD's case: a KA-Node verdict refuses every row, with the reason.
    func testAKaNodeAnchorIsRefused() {
        let decision = HarvestedRoutePolicy.decide(
            rows: [row("KE0GB-7", anchor: "KE0NCQ")],
            anchorCanRouteNetRom: false,
            localCallsign: "K0EPI-7")
        XCTAssertTrue(decision.accepted.isEmpty)
        XCTAssertTrue(decision.refused.first?.reason.contains("KA-Node") ?? false)
    }

    /// Unknown is not good enough: second-hand routing knowledge needs a
    /// positive verdict, so nil refuses too.
    func testAnUnprovenAnchorIsRefused() {
        let decision = HarvestedRoutePolicy.decide(
            rows: [row("KE0GB-7")],
            anchorCanRouteNetRom: nil,
            localCallsign: "K0EPI-7")
        XCTAssertTrue(decision.accepted.isEmpty)
        XCTAssertTrue(decision.refused.first?.reason.contains("unproven") ?? false)
    }

    func testSelfAndAnchorAndZeroQualityRowsAreRefused() {
        let decision = HarvestedRoutePolicy.decide(
            rows: [
                row("KB5YZB-7"),            // the anchor itself
                row("K0EPI-7"),             // this station
                row("W0DEAD", quality: 0)   // the anchor's own zero
            ],
            anchorCanRouteNetRom: true,
            localCallsign: "K0EPI-7")
        XCTAssertTrue(decision.accepted.isEmpty)
        XCTAssertEqual(decision.refused.count, 3)
    }

    /// The anchor's figure is its own opinion; the ceiling keeps a scraped
    /// claim from entering the table dressed as a perfect link.
    func testQualityIsCappedAtTheCeiling() {
        let decision = HarvestedRoutePolicy.decide(
            rows: [row("KE0GB-7", quality: 255)],
            anchorCanRouteNetRom: true,
            localCallsign: "K0EPI-7")
        XCTAssertEqual(decision.accepted.first?.quality, HarvestedRoutePolicy.qualityCeiling)
    }
}
