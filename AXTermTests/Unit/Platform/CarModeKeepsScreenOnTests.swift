//
//  CarModeKeepsScreenOnTests.swift
//  AXTermTests
//
//  Car mode keeps the screen on whatever the keep-awake setting says: a map
//  that dims and locks on the dashboard stops tracking and beaconing
//  (operator, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class CarModeKeepsScreenOnTests: XCTestCase {

    func testCarModeHoldsTheScreenOnEvenWithKeepAwakeOff() {
        XCTAssertEqual(KeepAwakeController.hold(policy: .never, isConnected: false, isTransferring: false,
                                                isListening: false, isDriving: true),
                       .schedulingAndAwake)
    }

    func testWithoutCarModeTheSettingDecides() {
        XCTAssertEqual(KeepAwakeController.hold(policy: .never, isConnected: true, isTransferring: false,
                                                isListening: false, isDriving: false),
                       .scheduling)
    }
}
