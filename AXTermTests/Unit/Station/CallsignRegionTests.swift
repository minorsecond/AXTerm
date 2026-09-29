//
//  CallsignRegionTests.swift
//  AXTermTests
//
//  The licensing country read from the ITU prefix — the one fact the app
//  can state about a node-table entry from the other side of the planet
//  without pretending to know whether the path there is RF or internet.
//  Cases are the actual callsigns from COSCO's harvested table.
//

import XCTest
@testable import AXTerm

final class CallsignRegionTests: XCTestCase {

    func testTheCoscoTableResolves() {
        XCTAssertEqual(CallsignRegion.region(for: "VK2RZ-1"),
                       "Australia \u{00B7} New South Wales")
        XCTAssertEqual(CallsignRegion.region(for: "ZL2BAU-3"), "New Zealand")
        XCTAssertEqual(CallsignRegion.region(for: "GB7BED"), "United Kingdom")
        XCTAssertEqual(CallsignRegion.region(for: "VE3CGR-1"),
                       "Canada \u{00B7} Ontario")
        XCTAssertEqual(CallsignRegion.region(for: "VE7ASS-1"),
                       "Canada \u{00B7} British Columbia")
        XCTAssertEqual(CallsignRegion.region(for: "CX2SA-7"), "Uruguay")
        XCTAssertEqual(CallsignRegion.region(for: "KD8FTR-1"), "United States")
        XCTAssertEqual(CallsignRegion.region(for: "AE5E-3"), "United States")
        XCTAssertEqual(CallsignRegion.region(for: "N3HYM-15"), "United States")
        XCTAssertEqual(CallsignRegion.region(for: "WG3K-4"), "United States")
    }

    func testOfficialCallAreasRefineTheCountry() {
        XCTAssertEqual(CallsignRegion.region(for: "VK6ABC"),
                       "Australia \u{00B7} Western Australia")
        XCTAssertEqual(CallsignRegion.region(for: "VO1XYZ"),
                       "Canada \u{00B7} Newfoundland and Labrador")
        XCTAssertEqual(CallsignRegion.region(for: "VY1AB"),
                       "Canada \u{00B7} Yukon")
        XCTAssertEqual(CallsignRegion.region(for: "GM4ABC"),
                       "United Kingdom \u{00B7} Scotland")
        XCTAssertEqual(CallsignRegion.region(for: "GW4ABC"),
                       "United Kingdom \u{00B7} Wales")
        XCTAssertEqual(CallsignRegion.region(for: "M0XYZ"),
                       "United Kingdom \u{00B7} England")
        // US call areas deliberately unrefined: the digit does not follow
        // the licensee when they move.
        XCTAssertEqual(CallsignRegion.region(for: "N3HYM"), "United States")
    }

    func testCountryStripsTheRefinement() {
        XCTAssertEqual(CallsignRegion.country(for: "VK2RZ-1"), "Australia")
        XCTAssertEqual(CallsignRegion.country(for: "VE7ASS"), "Canada")
        XCTAssertEqual(CallsignRegion.country(for: "K0EPI-7"), "United States")
        XCTAssertNil(CallsignRegion.country(for: "DRLNOD"))
    }

    func testLocalStationsAreDomestic() {
        for call in ["K0EPI-7", "KB5YZB-7", "KE0NCQ", "W0TX", "AB0VZ"] {
            XCTAssertEqual(CallsignRegion.region(for: call), "United States", call)
        }
    }

    func testTwoCharacterBlocksBeatSingleLetterFallbacks() {
        // VE is Canada even though V alone matches nothing; DL is Germany;
        // MW is the United Kingdom via the M block.
        XCTAssertEqual(CallsignRegion.region(for: "DL1ABC"), "Germany")
        XCTAssertEqual(CallsignRegion.region(for: "F5ABC"), "France")
        XCTAssertEqual(CallsignRegion.region(for: "G8BPQ"),
                       "United Kingdom \u{00B7} England")
        XCTAssertEqual(CallsignRegion.region(for: "JA1ABC"), "Japan")
    }

    func testMoroccoIsNotSwallowedByCuba() {
        XCTAssertEqual(CallsignRegion.region(for: "CN8ABC"), "Morocco")
        XCTAssertEqual(CallsignRegion.region(for: "CM2ABC"), "Cuba")
        XCTAssertEqual(CallsignRegion.region(for: "CO6ABC"), "Cuba")
    }

    func testAliasesAndJunkResolveToNothing() {
        // Tactical aliases are not callsigns and must not get a country.
        XCTAssertNil(CallsignRegion.region(for: "5EBBS"))  // alias for AE5E-3
        XCTAssertNil(CallsignRegion.region(for: "QQ"))
        XCTAssertNil(CallsignRegion.region(for: ""))
    }
}
