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

    #if os(macOS)
    /// The status line keeps TX's room while nothing transmits, so the words
    /// after it do not jump each time it comes and goes (park rehearsal
    /// 2026-10-08, finding 15).
    @MainActor
    func testTheStatusLineDoesNotMoveWhenTXComesAndGoes() {
        func width(transmitting: Bool) -> CGFloat {
            let radio = RadioStatusSummary.fixture()
            let strip = TNCStatusStrip(radios: [radio], transmitting: transmitting ? [radio.id] : [])
                .fixedSize()
            let hosting = NSHostingView(rootView: strip)
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.width
        }
        XCTAssertEqual(width(transmitting: true), width(transmitting: false), accuracy: 0.5)
    }
    #endif
}
