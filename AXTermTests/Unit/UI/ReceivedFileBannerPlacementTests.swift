//
//  ReceivedFileBannerPlacementTests.swift
//  AXTermTests
//
//  Park rehearsal 2026-10-08, finding 38: on the iPad the received-file
//  banner sat at the top, under the floating tab bar. The iPhone's tab bar is
//  at the bottom and the Mac has none, so they keep the banner at the top;
//  the iPad shows it at the bottom, where the transfer card was.
//

import XCTest
@testable import AXTerm

final class ReceivedFileBannerPlacementTests: XCTestCase {

    func testAWideScreenShowsTheBannerAtTheBottom() {
        XCTAssertEqual(ReceivedFileBannerPlacement.forWidth(isRegular: true), .bottom)
    }

    func testANarrowScreenKeepsItAtTheTop() {
        XCTAssertEqual(ReceivedFileBannerPlacement.forWidth(isRegular: false), .top)
    }
}
