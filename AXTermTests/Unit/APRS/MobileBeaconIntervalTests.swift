//
//  MobileBeaconIntervalTests.swift
//  AXTermTests
//
//  A position beacon could not go below 5 minutes, so a 5-minute drive got
//  one or two positions. A mobile APRS station beacons every minute or two;
//  an APRS position beacon now steps down to 1 minute. A text ID beacon on a
//  packet channel keeps its 5-minute floor (operator, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class MobileBeaconIntervalTests: XCTestCase {

    func testAPositionBeaconGoesDownToOneMinute() {
        XCTAssertEqual(BeaconConfig.floorMinutes(for: .aprsPosition), 1)
        let beacon = BeaconConfig(enabled: true, kind: .aprsPosition, intervalMinutes: 1)
        XCTAssertEqual(beacon.scheduledMinutes, 1)
    }

    func testAnIDBeaconKeepsItsFiveMinuteFloor() {
        let beacon = BeaconConfig(enabled: true, kind: .text, intervalMinutes: 1)
        XCTAssertEqual(beacon.scheduledMinutes, 5)
    }

    func testThePositionStepsAreFineAtTheBottom() {
        XCTAssertEqual(BeaconConfig.step(from: 5, up: false, kind: .aprsPosition), 3)
        XCTAssertEqual(BeaconConfig.step(from: 3, up: false, kind: .aprsPosition), 2)
        XCTAssertEqual(BeaconConfig.step(from: 1, up: false, kind: .aprsPosition), 1)
        XCTAssertEqual(BeaconConfig.step(from: 2, up: true, kind: .aprsPosition), 3)
        XCTAssertEqual(BeaconConfig.step(from: 5, up: true, kind: .aprsPosition), 10)
        XCTAssertEqual(BeaconConfig.step(from: 240, up: true, kind: .aprsPosition), 240)
    }

    func testTheIDStepsAreFiveMinutes() {
        XCTAssertEqual(BeaconConfig.step(from: 5, up: false, kind: .text), 5)
        XCTAssertEqual(BeaconConfig.step(from: 30, up: true, kind: .text), 35)
    }
}
