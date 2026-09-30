//
//  AdaptiveToolbarVisibilityTests.swift
//  AXTermTests
//
//  The Adaptive chip reports connected-mode tuning, so it stays out of the
//  toolbar when every enabled radio is on an APRS channel.
//

import XCTest
@testable import AXTerm

final class AdaptiveToolbarVisibilityTests: XCTestCase {

    func testShownWithAPacketRadioUp() {
        XCTAssertTrue(AdaptiveToolbarControl.isShown(adaptiveEnabled: true, linkUp: true, allRadiosOnAPRS: false))
    }

    func testHiddenWhenEveryRadioIsOnAPRS() {
        XCTAssertFalse(AdaptiveToolbarControl.isShown(adaptiveEnabled: true, linkUp: true, allRadiosOnAPRS: true))
    }

    func testHiddenWhenOffOrDown() {
        XCTAssertFalse(AdaptiveToolbarControl.isShown(adaptiveEnabled: false, linkUp: true, allRadiosOnAPRS: false))
        XCTAssertFalse(AdaptiveToolbarControl.isShown(adaptiveEnabled: true, linkUp: false, allRadiosOnAPRS: false))
    }

    @MainActor
    func testAllRadiosOnAPRSCountsOnlyEnabledRadios() {
        let settings = AppSettingsStore(defaults: TestDefaults.make("AdaptiveChipAPRS"))
        let first = settings.activeRadios[0].id
        settings.updateRadio(first) { RadioChannel.aprs.apply(to: &$0); $0.enabled = true }
        XCTAssertTrue(settings.allRadiosOnAPRS)
        let second = settings.addRadio().id
        settings.updateRadio(second) { RadioChannel.packet.apply(to: &$0); $0.enabled = false }
        XCTAssertTrue(settings.allRadiosOnAPRS, "a switched-off packet radio runs nothing")
        settings.updateRadio(second) { $0.enabled = true }
        XCTAssertFalse(settings.allRadiosOnAPRS)
    }
}
