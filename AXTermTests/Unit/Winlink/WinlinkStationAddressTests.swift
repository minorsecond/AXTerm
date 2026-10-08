//
//  WinlinkStationAddressTests.swift
//  AXTermTests
//
//  Winlink peer-to-peer answering on the station's own address takes every
//  connect to it (park rehearsal 2026-10-08: a file offer from the phone to
//  K0EPI-2 went into a Winlink session and A never asked to accept it).
//  Settings warns when that is how it is set.
//

import XCTest
@testable import AXTerm

final class WinlinkStationAddressTests: XCTestCase {

    func testAnsweringOnTheStationsOwnAddressIsFlagged() {
        XCTAssertTrue(WinlinkSettings.takesStationAddress(p2pCallsign: "", stationCallsign: "K0EPI-2"),
                      "empty answers as the station")
        XCTAssertTrue(WinlinkSettings.takesStationAddress(p2pCallsign: "k0epi-2", stationCallsign: "K0EPI-2"))
    }

    func testItsOwnSSIDIsFine() {
        XCTAssertFalse(WinlinkSettings.takesStationAddress(p2pCallsign: "K0EPI-5", stationCallsign: "K0EPI-2"))
        XCTAssertFalse(WinlinkSettings.takesStationAddress(p2pCallsign: "", stationCallsign: ""),
                       "no station callsign yet: nothing to collide with")
    }
}
