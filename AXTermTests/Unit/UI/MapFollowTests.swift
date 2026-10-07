//
//  MapFollowTests.swift
//  AXTermTests
//
//  The map's "show me" button and its navigation-style follow (operator,
//  2026-10-07, after a drive where the iPhone's map never moved). One tap
//  follows the station north-up, a second turns the map with the direction
//  of travel and tilts it like a navigation app, a third lets go. Panning
//  lets go too.
//

import CoreLocation
import XCTest
@testable import AXTerm

final class MapFollowTests: XCTestCase {
    private let home = GreatCircle.Point(latitude: 39.6124, longitude: -104.7332)

    func testTheButtonCyclesLikeMaps() {
        XCTAssertEqual(MapFollow.Mode.free.next, .follow)
        XCTAssertEqual(MapFollow.Mode.follow.next, .heading)
        XCTAssertEqual(MapFollow.Mode.heading.next, .free)
    }

    func testFreeHasNoCamera() {
        XCTAssertNil(MapFollow.camera(mode: .free, at: home, courseDegrees: nil, speedMetersPerSecond: nil))
    }

    func testFollowIsNorthUpAndFlatOverTheStation() throws {
        let camera = try XCTUnwrap(MapFollow.camera(mode: .follow, at: home, courseDegrees: 90, speedMetersPerSecond: 20))
        XCTAssertEqual(camera.heading, 0)
        XCTAssertEqual(camera.pitch, 0)
        XCTAssertEqual(camera.center.latitude, home.latitude, accuracy: 1e-9)
        XCTAssertEqual(camera.center.longitude, home.longitude, accuracy: 1e-9)
    }

    func testHeadingTurnsWithTravelTiltsAndLooksAhead() throws {
        let camera = try XCTUnwrap(MapFollow.camera(mode: .heading, at: home, courseDegrees: 90, speedMetersPerSecond: 20))
        XCTAssertEqual(camera.heading, 90)
        XCTAssertEqual(camera.pitch, MapFollow.navigationPitch)
        XCTAssertGreaterThan(camera.center.longitude, home.longitude, "the view looks ahead, east, so the station sits low")
        XCTAssertEqual(camera.center.latitude, home.latitude, accuracy: 1e-4)
    }

    func testStandingStillKeepsTheLastHeading() throws {
        let camera = try XCTUnwrap(MapFollow.camera(mode: .heading, at: home, courseDegrees: nil,
                                                    speedMetersPerSecond: 0, lastHeading: 135))
        XCTAssertEqual(camera.heading, 135, "a course from a station standing still means nothing")
    }

    func testTheTiltedViewStaysLowEnoughToKeepItsTilt() throws {
        let highway = try XCTUnwrap(MapFollow.camera(mode: .heading, at: home, courseDegrees: 0, speedMetersPerSecond: 30))
        XCTAssertLessThanOrEqual(highway.distanceMeters, MapFollow.tiltedCeiling)
    }

    func testFasterZoomsOut() throws {
        let walking = try XCTUnwrap(MapFollow.camera(mode: .follow, at: home, courseDegrees: nil, speedMetersPerSecond: 1))
        let town = try XCTUnwrap(MapFollow.camera(mode: .follow, at: home, courseDegrees: nil, speedMetersPerSecond: 13))
        let highway = try XCTUnwrap(MapFollow.camera(mode: .follow, at: home, courseDegrees: nil, speedMetersPerSecond: 30))
        XCTAssertLessThan(walking.distanceMeters, town.distanceMeters)
        XCTAssertLessThan(town.distanceMeters, highway.distanceMeters)
    }
}
