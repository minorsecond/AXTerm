//
//  NodeProfileDirectoryLookupTests.swift
//  AXTermTests
//
//  Field find 2026-08-28 ("where is Brunswick?"): the directory is keyed
//  by base callsign — one licence covers every SSID — but the resolver
//  looked records up under the SSID'd name. N3HYM-15 showed "Brunswick"
//  with no state even though the store held the complete Maryland record;
//  the name and city leaked in through the heard map, which carries only
//  those two fields. This pins the base-callsign fallback.
//

import XCTest
@testable import AXTerm

final class NodeProfileDirectoryLookupTests: XCTestCase {

    @MainActor
    func testAnSSIDedCallsignFindsItsBaseRecord() async {
        var resolver = NodeProfileResolver()
        resolver.directory = ["N3HYM": CallsignRecord(
            callsign: "N3HYM",
            name: "Ray Adkins",
            gridSquare: "FM19eh",
            latitude: 39.3145,
            longitude: -77.6179,
            locality: "Brunswick",
            state: "MD",
            country: "United States",
            licenseClass: "G",
            expires: "2030-01-01",
            source: "HamDB",
            fetchedAt: Date())]

        let profile = resolver.profile(for: "N3HYM-15")
        XCTAssertEqual(profile.name, "Ray Adkins")
        XCTAssertEqual(profile.state, "MD", "the base record must cover every SSID")
        XCTAssertEqual(profile.country, "United States")
        XCTAssertEqual(profile.licenseClass, "G")
        XCTAssertEqual(profile.licenseExpires, "2030-01-01")
    }

    @MainActor
    func testABaseCallsignStillFindsItsOwnRecord() async {
        var resolver = NodeProfileResolver()
        resolver.directory = ["AB0VZ": CallsignRecord(
            callsign: "AB0VZ", name: "Walter Burns", gridSquare: nil,
            latitude: nil, longitude: nil, locality: "Parker", state: "CO",
            country: "United States", licenseClass: nil, expires: nil,
            source: "HamDB", fetchedAt: Date())]

        XCTAssertEqual(resolver.profile(for: "AB0VZ").state, "CO")
    }
}
