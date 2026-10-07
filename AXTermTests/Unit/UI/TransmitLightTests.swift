//
//  TransmitLightTests.swift
//  AXTermTests
//
//  The TX light on the Mac toolbar and the iPhone and iPad status line
//  (operator, 2026-10-07): the radio's dot is red while it transmits. The
//  iOS strip already uses red for a failed link, so a transmitting radio
//  also says TX; a failed link always carries words of its own.
//

import SwiftUI
import XCTest
@testable import AXTerm

final class TransmitLightTests: XCTestCase {

    func testTheDotIsRedWhileTransmitting() {
        XCTAssertEqual(TransmitLight.dotColor(base: .green, transmitting: true), TransmitLight.color)
        XCTAssertEqual(TransmitLight.dotColor(base: .green, transmitting: false), .green)
    }

    func testTheStripSaysTXWhileARadioTransmits() {
        XCTAssertEqual(TransmitLight.label(transmitting: true, needsAttention: false), "TX")
        XCTAssertNil(TransmitLight.label(transmitting: false, needsAttention: false))
    }

    func testAProblemWithTheLinkKeepsItsOwnWords() {
        XCTAssertNil(TransmitLight.label(transmitting: true, needsAttention: true))
    }
}
