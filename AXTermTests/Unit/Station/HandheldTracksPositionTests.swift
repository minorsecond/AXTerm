//
//  HandheldTracksPositionTests.swift
//  AXTermTests
//
//  On a drive the iPhone's map kept the operator's pin where the drive
//  began, and every beacon carried that point. The app took one fix when
//  device location was switched on and never another (smoke run
//  2026-10-03-1, issue 118). Like a navigation app, the handheld now asks
//  for continuous updates while it is on screen, filtered by distance so a
//  station standing still is not redrawn every second.
//

import XCTest
@testable import AXTerm

@MainActor
final class HandheldTracksPositionTests: XCTestCase {

    private final class TrackingGPS: GPSProviding, @unchecked Sendable {
        var onFix: (@Sendable ((latitude: Double, longitude: Double)) -> Void)?
        var filter: Double?
        var stopped = 0
        func requestOneShotFix(timeout: TimeInterval) async throws -> (latitude: Double, longitude: Double) {
            (39.60, -104.80)
        }
        func startTracking(distanceFilter: Double,
                           onFix: @escaping @Sendable ((latitude: Double, longitude: Double)) -> Void) {
            filter = distanceFilter
            self.onFix = onFix
        }
        func stopTracking() { stopped += 1 }
    }

    private func service(_ gps: TrackingGPS, deviceLocation: Bool = true) -> StationLocationService {
        StationLocationService(gps: gps, manualGridProvider: { "DM79" }, deviceLocationEnabled: { deviceLocation })
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testEachFixMovesTheStationPosition() throws {
        let gps = TrackingGPS()
        let service = service(gps)
        service.startTracking()
        XCTAssertEqual(gps.filter, 10, "a fix every 10 m moved")

        gps.onFix?((39.61, -104.79))
        settle()
        XCTAssertEqual(try XCTUnwrap(service.lastLocation).latitude, 39.61, accuracy: 1e-9)
        gps.onFix?((39.70, -104.60))
        settle()
        let moved = try XCTUnwrap(service.lastLocation)
        XCTAssertEqual(moved.latitude, 39.70, accuracy: 1e-9)
        XCTAssertEqual(moved.source, .gps)
    }

    func testStoppingStopsTheProvider() {
        let gps = TrackingGPS()
        let service = service(gps)
        service.startTracking()
        service.stopTracking()
        XCTAssertEqual(gps.stopped, 1)
    }

    func testNothingTracksWithDeviceLocationOff() {
        let gps = TrackingGPS()
        service(gps, deviceLocation: false).startTracking()
        XCTAssertNil(gps.filter)
    }
}
