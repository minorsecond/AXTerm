//
//  ComposeAXDPSwitchTests.swift
//  AXTermTests
//
//  The compose bar's AXDP switch. Typed text goes to a station confirmed as
//  AXTerm as AXDP, and the switch is the only way to send it plain instead.
//  It left the bar in a redesign (d08542c5) and nothing took its place, so
//  plain text to an AXTerm station could not be sent at all (remote access
//  test 2026-10-11, step 4a).
//

import XCTest
@testable import AXTerm

final class ComposeAXDPSwitchTests: XCTestCase {

    /// Shown whenever what is typed would go as AXDP: a session with a
    /// station confirmed as AXTerm.
    func testShownForAConfirmedStationInASession() {
        XCTAssertTrue(ComposeAXDPSwitch.isShown(capabilityStatus: .confirmed, connectionMode: .connected,
                                                isRawMode: false))
    }

    /// Nothing to switch when the text would go plain anyway.
    func testHiddenWhenTheTextGoesPlainAnyway() {
        for status: SessionCoordinator.CapabilityStatus in [.unknown, .pending, .notSupported] {
            XCTAssertFalse(ComposeAXDPSwitch.isShown(capabilityStatus: status, connectionMode: .connected,
                                                     isRawMode: false), "\(status)")
        }
        XCTAssertFalse(ComposeAXDPSwitch.isShown(capabilityStatus: .confirmed, connectionMode: .datagram,
                                                 isRawMode: false), "a broadcast is never AXDP")
        XCTAssertFalse(ComposeAXDPSwitch.isShown(capabilityStatus: .confirmed, connectionMode: .connected,
                                                 isRawMode: true), "raw keys are never AXDP")
    }

    /// The tooltip says what the switch does in each position.
    func testTheTooltipSaysWhatHappens() {
        XCTAssertTrue(ComposeAXDPSwitch.help(isOn: true).contains("AXDP"))
        XCTAssertTrue(ComposeAXDPSwitch.help(isOn: false).contains("plain text"))
    }
}
