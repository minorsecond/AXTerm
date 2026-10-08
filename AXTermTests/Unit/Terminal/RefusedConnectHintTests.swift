//
//  RefusedConnectHintTests.swift
//  AXTermTests
//
//  A refused connect says why when the reason is likely ours (park
//  rehearsal 2026-10-08, finding 19): the phone, still linked to K0EPI-2,
//  called K0EPI-4 at the same station and got a bare DM. Stations that take
//  one link per caller, AXTerm among them, refuse a second.
//

import XCTest
@testable import AXTerm

final class RefusedConnectHintTests: XCTestCase {

    func testALinkToTheSameStationIsNamed() {
        let detail = RefusedConnectHint.detail(destination: "K0EPI-4", liveLinks: ["K0EPI-2"])
        XCTAssertTrue(detail.hasPrefix("K0EPI-4 answered the connect request with DM (refused)."), detail)
        XCTAssertTrue(detail.contains("still connected to K0EPI-2"), detail)
        XCTAssertTrue(detail.contains("Disconnect from K0EPI-2"), detail)
    }

    func testOtherStationsAddNothing() {
        XCTAssertEqual(RefusedConnectHint.detail(destination: "K0EPI-4", liveLinks: []),
                       "K0EPI-4 answered the connect request with DM (refused).")
        XCTAssertEqual(RefusedConnectHint.detail(destination: "K0EPI-4", liveLinks: ["W0ARP-1"]),
                       "K0EPI-4 answered the connect request with DM (refused).")
        XCTAssertEqual(RefusedConnectHint.detail(destination: "K0EPI-4", liveLinks: ["K0EPI-4"]),
                       "K0EPI-4 answered the connect request with DM (refused).",
                       "a link to the very address is not another link")
    }
}
