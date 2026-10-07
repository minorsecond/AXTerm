//
//  CaptureIndicatorTests.swift
//  AXTermTests
//
//  On the iPad a running capture showed as a red dot and nothing else; its
//  explanation is a hover tooltip, which a touch screen never shows, so the
//  operator could not tell what it was (smoke run 2026-10-03-1, 13.4, issue
//  117). On a touch device a running capture says so in words.
//

import XCTest
@testable import AXTerm

final class CaptureIndicatorTests: XCTestCase {

    func testARunningCaptureIsNamedOnATouchDevice() {
        XCTAssertEqual(CaptureIndicator.caption(isCapturing: true, touch: true), "Capturing")
    }

    func testNothingIsShownWhenNotCapturing() {
        XCTAssertNil(CaptureIndicator.caption(isCapturing: false, touch: true))
    }

    func testThePointerKeepsItsTooltip() {
        XCTAssertNil(CaptureIndicator.caption(isCapturing: true, touch: false))
    }
}
