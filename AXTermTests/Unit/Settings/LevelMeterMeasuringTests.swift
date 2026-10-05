//
//  LevelMeterMeasuringTests.swift
//  AXTermTests
//
//  The TNC4 level meter follows the link when a measurement ends on its own.
//
//  Smoke run 2026-10-03-1, issue 40: the meter kept showing Stop and "Packets
//  aren't received while measuring" after the link's two-minute limit had
//  ended the measurement, and kept Calibrate disabled. The page kept its own
//  flag and nothing told it.
//

import XCTest
@testable import AXTerm

@MainActor
final class LevelMeterMeasuringTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testStillMeasuringWhileTheLinkIs() {
        XCTAssertFalse(MobilinkdSettingsSections.measurementEnded(
            activity: .measuring, startedAt: start, now: start.addingTimeInterval(90)))
    }

    func testEndedOnceTheLinkHasStopped() {
        XCTAssertTrue(MobilinkdSettingsSections.measurementEnded(
            activity: .idle, startedAt: start, now: start.addingTimeInterval(121)))
    }

    /// The link starts on its own queue, so right after Measure it may not
    /// say so yet.
    func testTheFirstMomentsAreGivenTime() {
        XCTAssertFalse(MobilinkdSettingsSections.measurementEnded(
            activity: .idle, startedAt: start, now: start.addingTimeInterval(0.5)))
    }

    /// A tone or a recording took the audio over; that ends the measurement
    /// too. So does a link that went away.
    func testAnotherActivityOrNoLinkEndsIt() {
        XCTAssertTrue(MobilinkdSettingsSections.measurementEnded(
            activity: .sendingTone(.both), startedAt: start, now: start.addingTimeInterval(5)))
        XCTAssertTrue(MobilinkdSettingsSections.measurementEnded(
            activity: nil, startedAt: start, now: start.addingTimeInterval(5)))
    }
}
