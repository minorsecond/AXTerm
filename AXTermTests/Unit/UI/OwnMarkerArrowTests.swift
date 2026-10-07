//
//  OwnMarkerArrowTests.swift
//  AXTermTests
//
//  The station's own marker becomes an arrow pointing the way it travels
//  (operator, 2026-10-07). It points along the GPS course, turned against
//  the map's own rotation, so in the heading view it points straight up.
//  Standing still the course is noise, so it stays a dot.
//

import XCTest
@testable import AXTerm

final class OwnMarkerArrowTests: XCTestCase {

    func testOnANorthUpMapTheArrowPointsAlongTheCourse() {
        XCTAssertEqual(OwnMarkerArrow.rotation(courseDegrees: 90, speed: 15, mapHeading: 0), 90)
    }

    func testInTheHeadingViewTheArrowPointsUp() {
        XCTAssertEqual(OwnMarkerArrow.rotation(courseDegrees: 250, speed: 15, mapHeading: 250), 0)
    }

    func testTheRotationIsKeptInOneTurn() {
        XCTAssertEqual(OwnMarkerArrow.rotation(courseDegrees: 10, speed: 15, mapHeading: 350), 20)
    }

    func testStandingStillOrWithoutACourseIsADot() {
        XCTAssertNil(OwnMarkerArrow.rotation(courseDegrees: 90, speed: 0.5, mapHeading: 0))
        XCTAssertNil(OwnMarkerArrow.rotation(courseDegrees: nil, speed: 15, mapHeading: 0))
        XCTAssertNil(OwnMarkerArrow.rotation(courseDegrees: -1, speed: 15, mapHeading: 0))
    }
}
