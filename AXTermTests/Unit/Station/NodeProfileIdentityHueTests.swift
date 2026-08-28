//
//  NodeProfileIdentityHueTests.swift
//  AXTermTests
//
//  The profile header's monogram colours a station by a hash of its base
//  callsign. The promise worth pinning is stability: the same station is
//  the same colour every launch, every SSID of one licence shares it, and
//  case never matters — a colour that flickered between openings would
//  read as a different station.
//

import XCTest
@testable import AXTerm

final class NodeProfileIdentityHueTests: XCTestCase {

    func testHueIsDeterministicAndCaseInsensitive() {
        let a = NodeProfileView.identityHue(for: "K0EPI")
        XCTAssertEqual(a, NodeProfileView.identityHue(for: "K0EPI"))
        XCTAssertEqual(a, NodeProfileView.identityHue(for: "k0epi"))
    }

    func testHueStaysInUnitRange() {
        for call in ["K0EPI", "KB5YZB", "KE0NCQ", "W0TX", "AB0VZ", "N0BN", ""] {
            let hue = NodeProfileView.identityHue(for: call)
            XCTAssertGreaterThanOrEqual(hue, 0.0)
            XCTAssertLessThan(hue, 1.0)
        }
    }

    func testDifferentStationsGetDifferentColours() {
        // Not guaranteed for every pair by pigeonhole, but the local
        // neighbourhood should not collide — that is the whole point.
        let calls = ["K0EPI", "KB5YZB", "KE0NCQ", "W0TX", "AB0VZ", "K0NTS", "KF0HEG"]
        let hues = Set(calls.map { NodeProfileView.identityHue(for: $0) })
        XCTAssertEqual(hues.count, calls.count)
    }
}
