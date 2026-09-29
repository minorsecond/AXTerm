//
//  TimeDisplayTests.swift
//  AXTermTests
//
//  One clock for every user-facing timestamp — following the system's
//  12/24-hour preference by default, pinnable to either style.
//

import XCTest
@testable import AXTerm

final class TimeDisplayTests: XCTestCase {

    // 16:05:07 local time on a fixed day.
    private var afternoon: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 29
        components.hour = 16; components.minute = 5; components.second = 7
        return Calendar.current.date(from: components)!
    }

    func testPinnedStylesIgnoreTheLocale() {
        XCTAssertEqual(
            TimeDisplay.timeString(afternoon, format: .twentyFourHour), "16:05:07")
        XCTAssertEqual(
            TimeDisplay.timeString(afternoon, format: .twelveHour), "4:05:07 PM")
        XCTAssertEqual(
            TimeDisplay.timeString(afternoon, seconds: false, format: .twentyFourHour),
            "16:05")
        XCTAssertEqual(
            TimeDisplay.timeString(afternoon, seconds: false, format: .twelveHour),
            "4:05 PM")
    }

    /// The system style is whatever the OS says — the test can only pin
    /// that it produces *something* containing the minutes, because the
    /// machine running the tests owns the preference.
    func testSystemStyleFollowsTheMachine() {
        let text = TimeDisplay.timeString(afternoon, format: .system)
        XCTAssertTrue(text.contains("05"), text)
    }

    func testUnknownStoredValueFallsBackToSystem() {
        let defaults = UserDefaults(suiteName: "TimeDisplayTests.\(UUID().uuidString)")!
        defaults.set("fortnight", forKey: TimeDisplay.formatKey)
        XCTAssertEqual(TimeDisplay.format(from: defaults), .system)
    }
}

/// Label ink is spent where it reads: city zoom yes, state zoom no.
final class MapLabelPolicyTests: XCTestCase {
    func testLabelsShowAtCityZoomAndHideAtStateZoom() {
        XCTAssertTrue(MapLabelPolicy.showsLabels(latitudeDelta: 0.2))
        XCTAssertFalse(MapLabelPolicy.showsLabels(latitudeDelta: 3.0))
        XCTAssertFalse(MapLabelPolicy.showsLabels(
            latitudeDelta: MapLabelPolicy.labelSpanThresholdDegrees))
    }
}
