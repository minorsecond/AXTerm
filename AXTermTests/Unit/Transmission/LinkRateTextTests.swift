//
//  LinkRateTextTests.swift
//  AXTermTests
//
//  One way of writing a link's rate everywhere. Field case 2026-10-02 (live
//  test log, bug 43): Winlink showed "47 B/s" and file transfers "333 bps",
//  and the operator read the Winlink exchange as seven times slower when it
//  was a little faster.
//

import XCTest
@testable import AXTerm

final class LinkRateTextTests: XCTestCase {

    func testBytesPerSecondAreShownAsBits() {
        XCTAssertEqual(LinkRateText.bytesPerSecond(48), "384 bps")
        XCTAssertEqual(LinkRateText.bytesPerSecond(100), "800 bps")
    }

    func testFasterRatesUseKilobits() {
        XCTAssertEqual(LinkRateText.bytesPerSecond(150), "1.2 kbps")
        XCTAssertEqual(LinkRateText.bitsPerSecond(9_600), "9.6 kbps")
        XCTAssertEqual(LinkRateText.bitsPerSecond(2_500_000), "2.50 Mbps")
    }

    /// Where a tooltip divides a size by the rate, the bytes figure has to be
    /// there too, or the arithmetic doesn't work.
    func testTheDerivationFormShowsBothUnits() {
        XCTAssertEqual(LinkRateText.withBytes(30), "240 bps (30 bytes/s)")
        XCTAssertEqual(LinkRateText.withBytes(2.5), "20 bps (2.5 bytes/s)")
    }

    /// A slow link still reads as a number, not "0 bps".
    func testASlowRateKeepsOneDecimal() {
        XCTAssertEqual(LinkRateText.bytesPerSecond(0.5), "4 bps")
        XCTAssertEqual(LinkRateText.bitsPerSecond(0.4), "0.4 bps")
    }
}
