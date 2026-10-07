//
//  SmoothFollowTests.swift
//  AXTermTests
//
//  The follow camera and the own arrow moved in jerks (operator, 2026-10-07,
//  watching the simulated drive): the camera hopped to each fix and waited,
//  and the arrow was drawn from a position rounded to 25 m, so the two
//  stepped out of time. Navigation apps glide. The camera and the arrow now
//  move at a steady pace over the time between fixes, and a moving station
//  is drawn where it is, not where it last crossed the noise floor.
//

import XCTest
@testable import AXTerm

final class SmoothFollowTests: XCTestCase {
    private let held = GreatCircle.Point(latitude: 39.5944, longitude: -104.8650)
    private let nearby = GreatCircle.Point(latitude: 39.5944, longitude: -104.86488)   // about 10 m east

    func testTheGlideLastsUntilTheNextFix() {
        XCTAssertEqual(MapFollow.glide(sinceLastFix: 1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(MapFollow.glide(sinceLastFix: 0.05), 0.3, accuracy: 1e-9, "never a snap")
        XCTAssertEqual(MapFollow.glide(sinceLastFix: 30), 1.5, accuracy: 1e-9, "a gap is not a slow crawl")
        XCTAssertEqual(MapFollow.glide(sinceLastFix: nil), 0.8, accuracy: 1e-9, "the first move")
    }

    func testAStationStandingStillKeepsItsAnchor() {
        XCTAssertEqual(OwnPositionAnchor.drawn(held: held, live: nearby, speed: 0), held)
    }

    func testAMovingStationIsDrawnWhereItIs() {
        XCTAssertEqual(OwnPositionAnchor.drawn(held: held, live: nearby, speed: 18), nearby)
    }

    func testAMoveBeyondTheNoiseFloorIsTakenStandingStill() {
        let far = GreatCircle.Point(latitude: 39.5950, longitude: -104.8650)       // about 67 m north
        XCTAssertEqual(OwnPositionAnchor.drawn(held: held, live: far, speed: 0), far)
    }
}
