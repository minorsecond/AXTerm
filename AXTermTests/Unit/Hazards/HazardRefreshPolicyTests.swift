import XCTest
@testable import AXTerm

/// When the NWS layer fetches (Docs/HazardLayers.md §1, §4). Every hazard
/// layer starts off: each request carries the station's position.
final class HazardRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_576_000)
    private let home = GreatCircle.Point(latitude: 39.6123, longitude: -104.7332)

    func testTheNWSLayerStartsOff() {
        XCTAssertFalse(MapLayerDefaults.showsNWSAlerts)
    }

    func testOffNeverFetches() {
        XCTAssertFalse(HazardRefreshPolicy.shouldRefresh(enabled: false, position: home,
                                                        lastAttempt: nil, lastPoint: nil, now: now))
    }

    func testNoPositionNoFetch() {
        XCTAssertFalse(HazardRefreshPolicy.shouldRefresh(enabled: true, position: nil,
                                                        lastAttempt: nil, lastPoint: nil, now: now))
    }

    func testOnFetchesAtOnceThenEveryTwoMinutes() {
        XCTAssertTrue(HazardRefreshPolicy.shouldRefresh(enabled: true, position: home,
                                                       lastAttempt: nil, lastPoint: nil, now: now))
        XCTAssertFalse(HazardRefreshPolicy.shouldRefresh(enabled: true, position: home,
                                                        lastAttempt: now.addingTimeInterval(-60),
                                                        lastPoint: home, now: now))
        XCTAssertTrue(HazardRefreshPolicy.shouldRefresh(enabled: true, position: home,
                                                       lastAttempt: now.addingTimeInterval(-121),
                                                       lastPoint: home, now: now))
    }

    /// Driving: more than 5 km from where the alerts were fetched, fetch
    /// again now rather than show the last town's warnings.
    func testMovingFarFetchesEarly() {
        let downTheRoad = GreatCircle.Point(latitude: 39.6123, longitude: -104.66)  // about 6 km east
        XCTAssertTrue(HazardRefreshPolicy.shouldRefresh(enabled: true, position: downTheRoad,
                                                       lastAttempt: now.addingTimeInterval(-30),
                                                       lastPoint: home, now: now))
        let acrossTheStreet = GreatCircle.Point(latitude: 39.6130, longitude: -104.7332)
        XCTAssertFalse(HazardRefreshPolicy.shouldRefresh(enabled: true, position: acrossTheStreet,
                                                        lastAttempt: now.addingTimeInterval(-30),
                                                        lastPoint: home, now: now))
    }
}
