//
//  CarModeStationsTests.swift
//  AXTermTests
//
//  Other stations in car mode (operator, 2026-10-07): a moving station is an
//  arrow pointing its reported course, with a short tail fading behind it;
//  only stations heard in the last hour are drawn, and fixed ones are drawn
//  smaller and quieter so the mobiles stand out.
//

import XCTest
@testable import AXTerm

final class CarModeStationsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Moving stations

    func testAStationReportingSpeedIsAnArrowAlongItsCourse() {
        XCTAssertEqual(StationMotion.arrowRotation(courseDegrees: 269, speedKnots: 53,
                                                   lastHeard: now.addingTimeInterval(-60), now: now,
                                                   mapHeading: 0), 269)
        XCTAssertEqual(StationMotion.arrowRotation(courseDegrees: 269, speedKnots: 53,
                                                   lastHeard: now.addingTimeInterval(-60), now: now,
                                                   mapHeading: 269), 0, "turned against the map")
    }

    func testAParkedStationIsADot() {
        XCTAssertNil(StationMotion.arrowRotation(courseDegrees: 90, speedKnots: 1,
                                                 lastHeard: now, now: now, mapHeading: 0))
        XCTAssertNil(StationMotion.arrowRotation(courseDegrees: nil, speedKnots: 40,
                                                 lastHeard: now, now: now, mapHeading: 0))
    }

    func testAnOldReportOfSpeedIsNotStillMoving() {
        XCTAssertNil(StationMotion.arrowRotation(courseDegrees: 90, speedKnots: 40,
                                                 lastHeard: now.addingTimeInterval(-3600), now: now,
                                                 mapHeading: 0),
                     "an hour ago it was driving; that says nothing about now")
    }

    // MARK: Fixed stations

    func testFixedStationsAreQuietAndMobilesAreNot() {
        let digi = APRSMapSymbol(table: "/", code: "#")
        let house = APRSMapSymbol(table: "/", code: "-")
        let car = APRSMapSymbol(table: "/", code: ">")
        XCTAssertTrue(StationMotion.isQuiet(symbol: digi, isNode: false, moving: false))
        XCTAssertTrue(StationMotion.isQuiet(symbol: house, isNode: false, moving: false))
        XCTAssertTrue(StationMotion.isQuiet(symbol: nil, isNode: true, moving: false))
        XCTAssertFalse(StationMotion.isQuiet(symbol: car, isNode: false, moving: false), "a car parked is still a car")
        XCTAssertFalse(StationMotion.isQuiet(symbol: house, isNode: false, moving: true))
    }

    // MARK: Recent only

    func testCarModeKeepsTheLastHour() {
        XCTAssertTrue(CarMode.keeps(lastHeard: now.addingTimeInterval(-59 * 60), now: now))
        XCTAssertFalse(CarMode.keeps(lastHeard: now.addingTimeInterval(-61 * 60), now: now))
        XCTAssertFalse(CarMode.keeps(lastHeard: nil, now: now))
    }

    // MARK: Tails

    func testATailIsTheLastTenMinutesAndFades() throws {
        var rover = Station(call: "KF0YKI-9")
        rover.track = [
            .init(latitude: 39.70, longitude: -104.70, timestamp: now.addingTimeInterval(-30 * 60)),
            .init(latitude: 39.71, longitude: -104.71, timestamp: now.addingTimeInterval(-8 * 60)),
            .init(latitude: 39.72, longitude: -104.72, timestamp: now.addingTimeInterval(-4 * 60)),
            .init(latitude: 39.73, longitude: -104.73, timestamp: now.addingTimeInterval(-1 * 60)),
        ]
        let tails = MapTrack.tails(stations: [rover], placedIDs: ["KF0YKI-9"], now: now)
        let tail = try XCTUnwrap(tails.first)
        XCTAssertEqual(tail.points.count, 3, "the fix from half an hour ago is not part of the tail")
        XCTAssertTrue(tail.fades)
    }
}
