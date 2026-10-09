import XCTest
@testable import AXTerm

/// Whether the station is on the move: car mode on, or a recent GPS fix
/// with walking speed or more.
final class StationMotionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(speed: Double?, age: TimeInterval) -> StationLocation {
        StationLocation(latitude: 39.61, longitude: -104.74, gridSquare: "DM79po", source: .gps,
                        timestamp: now.addingTimeInterval(-age), speed: speed)
    }

    func testCarModeMeansMoving() {
        XCTAssertTrue(StationMotion.isMoving(carMode: true, fix: nil, now: now))
    }

    func testARecentFixAtDrivingSpeedMeansMoving() {
        XCTAssertTrue(StationMotion.isMoving(carMode: false, fix: fix(speed: 13, age: 20), now: now))
    }

    func testStandingStillOrAnOldFixIsNot() {
        XCTAssertFalse(StationMotion.isMoving(carMode: false, fix: fix(speed: 0.4, age: 20), now: now))
        XCTAssertFalse(StationMotion.isMoving(carMode: false, fix: fix(speed: 13, age: 600), now: now),
                       "a fix ten minutes old says nothing about now")
        XCTAssertFalse(StationMotion.isMoving(carMode: false, fix: fix(speed: nil, age: 5), now: now))
        XCTAssertFalse(StationMotion.isMoving(carMode: false, fix: nil, now: now))
    }
}
