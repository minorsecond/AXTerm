//
//  TransmissionDurationMenuTests.swift
//  AXTermTests
//
//  The Transmission pane's paced-transmission settings moved from Steppers
//  to preset pop-up menus (2026-08-28, "these time adjustment up/down
//  widgets are awful"). The one piece of logic worth pinning: a stored
//  value that isn't a preset — dialed in under the old steppers — must be
//  spliced into the menu, because a macOS pop-up whose selection has no
//  matching tag renders blank and the operator's setting looks lost.
//

import XCTest
@testable import AXTerm

final class TransmissionDurationMenuTests: XCTestCase {

    func testPresetValueLeavesTheMenuAlone() {
        let presets = [5, 10, 15, 30, 60]
        XCTAssertEqual(
            TransmissionSettingsView.durationMenuOptions(presets: presets, current: 15),
            presets)
    }

    func testStepperEraValueIsSplicedInSorted() {
        let options = TransmissionSettingsView.durationMenuOptions(
            presets: [5, 10, 15, 30, 60], current: 25)
        XCTAssertEqual(options, [5, 10, 15, 25, 30, 60])
        XCTAssertEqual(options, options.sorted(), "menu must stay in ascending order")
    }

    func testMinutesLabelPromotesWholeHours() {
        XCTAssertEqual(TransmissionSettingsView.minutesLabel(45), "45 min")
        XCTAssertEqual(TransmissionSettingsView.minutesLabel(60), "1 hour")
        XCTAssertEqual(TransmissionSettingsView.minutesLabel(240), "4 hours")
        XCTAssertEqual(TransmissionSettingsView.minutesLabel(90), "90 min",
                       "an hour and a half is clearer as minutes than as a fraction")
    }

    func testSecondsLabelPromotesWholeMinutes() {
        XCTAssertEqual(TransmissionSettingsView.secondsLabel(30), "30 s")
        XCTAssertEqual(TransmissionSettingsView.secondsLabel(90), "90 s")
        XCTAssertEqual(TransmissionSettingsView.secondsLabel(300), "5 min")
    }
}
