//
//  TNC4BatteryPresentationTests.swift
//  AXTermTests
//
//  The TNC4's battery in the toolbar's radio pill, and when the reading is
//  refreshed (operator request, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class TNC4BatteryPresentationTests: XCTestCase {
    func testTheGlyphStepsWithTheCharge() {
        XCTAssertEqual(TNC4BatteryPresentation.symbol(fraction: 1.0), "battery.100percent")
        XCTAssertEqual(TNC4BatteryPresentation.symbol(fraction: 0.8), "battery.75percent")
        XCTAssertEqual(TNC4BatteryPresentation.symbol(fraction: 0.5), "battery.50percent")
        XCTAssertEqual(TNC4BatteryPresentation.symbol(fraction: 0.3), "battery.25percent")
        XCTAssertEqual(TNC4BatteryPresentation.symbol(fraction: 0.05), "battery.0percent")
        XCTAssertTrue(TNC4BatteryPresentation.isLow(fraction: 0.2))
        XCTAssertFalse(TNC4BatteryPresentation.isLow(fraction: 0.21))
    }

    func testTheTooltipSaysVoltageChargeAndWhenItWasRead() {
        let text = TNC4BatteryPresentation.help(millivolts: 4210, fraction: 1.0, readAt: Date(),
                                                timeFormatter: { _ in "4:45 AM" })
        XCTAssertEqual(text, "TNC4 battery 4.21 V, about 100%, read 4:45 AM")
        let low = TNC4BatteryPresentation.help(millivolts: 3450, fraction: 0.17, readAt: nil,
                                               timeFormatter: { _ in "" })
        XCTAssertEqual(low, "TNC4 battery 3.45 V, about 17%. Low: charge it soon")
    }

    func testARefreshIsDueEveryThirtyMinutesFromTheLastReadingOrAsk() {
        let t = Date(timeIntervalSince1970: 1_791_400_000)
        XCTAssertFalse(TNC4BatteryRefresh.isDue(lastReadAt: t, lastAskedAt: nil, now: t.addingTimeInterval(29 * 60)))
        XCTAssertTrue(TNC4BatteryRefresh.isDue(lastReadAt: t, lastAskedAt: nil, now: t.addingTimeInterval(30 * 60)))
        XCTAssertFalse(TNC4BatteryRefresh.isDue(lastReadAt: t, lastAskedAt: t.addingTimeInterval(20 * 60),
                                                now: t.addingTimeInterval(40 * 60)),
                       "an unanswered ask waits its own 30 minutes")
    }

    func testItIsOnlyAskedForWhenNothingIsLost() {
        let t = Date(timeIntervalSince1970: 1_791_400_000)
        XCTAssertTrue(TNC4BatteryRefresh.mayAsk(tncIdle: true, linkUp: false, lastActivity: t.addingTimeInterval(-60), now: t))
        XCTAssertFalse(TNC4BatteryRefresh.mayAsk(tncIdle: true, linkUp: true, lastActivity: nil, now: t),
                       "never while a link is up on the radio")
        XCTAssertFalse(TNC4BatteryRefresh.mayAsk(tncIdle: false, linkUp: false, lastActivity: nil, now: t),
                       "never while the TNC4 measures or sends a tone")
        XCTAssertFalse(TNC4BatteryRefresh.mayAsk(tncIdle: true, linkUp: false, lastActivity: t.addingTimeInterval(-2), now: t),
                       "never right after a frame")
    }
}
