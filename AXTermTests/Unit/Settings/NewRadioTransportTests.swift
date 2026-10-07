//
//  NewRadioTransportTests.swift
//  AXTermTests
//
//  A fresh iPhone install began with a Direwolf radio at localhost:8001,
//  which a phone cannot run (smoke run 2026-10-03-1, test 13.3, issue 107).
//  A phone or tablet reaches its TNC over Bluetooth.
//

import XCTest
@testable import AXTerm

final class NewRadioTransportTests: XCTestCase {

    func testAHandheldStartsANewRadioOnBluetooth() {
        XCTAssertEqual(RadioTransportKind.defaultForNewRadio(onHandheld: true), .ble)
        XCTAssertEqual(RadioTransportKind.defaultForNewRadio(onHandheld: false), .tcp)
    }

    func testThisMacStartsANewRadioOnTCPAsBefore() {
        XCTAssertEqual(RadioProfile(id: RadioID(), name: "").kind, .tcp)
    }
}
