import XCTest
@testable import AXTerm

/// Where a fanned marker lands must depend on the stations, not on the order
/// they happened to arrive in.
final class HeardStationMapFanTests: XCTestCase {

    /// Two stations a few centimetres apart round to the same cluster key but
    /// are not the same point, so whichever one the cluster listed first
    /// became the centre everything else fanned around — and the map rebuilds
    /// that list as packets arrive.
    func testFanningDoesNotDependOnInputOrder() throws {
        let a = entry("K0EPI-1", latitude: 39.600001, longitude: -104.700001)
        let b = entry("K0EPI-7", latitude: 39.600002, longitude: -104.700002)

        let forwards = HeardStationMap.fannedPositions([a, b])
        let backwards = HeardStationMap.fannedPositions([b, a])

        XCTAssertEqual(forwards.keys.sorted(), backwards.keys.sorted())
        for callsign in forwards.keys {
            let one = try XCTUnwrap(forwards[callsign])
            let other = try XCTUnwrap(backwards[callsign])
            XCTAssertEqual(one.latitude, other.latitude, accuracy: 1e-12,
                           "\(callsign) latitude moved")
            XCTAssertEqual(one.longitude, other.longitude, accuracy: 1e-12,
                           "\(callsign) longitude moved")
        }
    }

    /// A station on its own sits exactly where it is; only a crowd is fanned.
    func testALoneStationIsNotMoved() throws {
        let placed = HeardStationMap.fannedPositions(
            [entry("K0EPI-7", latitude: 39.6, longitude: -104.7)])
        let point = try XCTUnwrap(placed["K0EPI-7"])
        XCTAssertEqual(point.latitude, 39.6, accuracy: 1e-12)
        XCTAssertEqual(point.longitude, -104.7, accuracy: 1e-12)
    }

    private func entry(_ callsign: String,
                       latitude: Double,
                       longitude: Double) -> HeardStationMap.Entry {
        var entry = HeardStationMap.Entry(callsign: callsign, heardCount: 1,
                                          lastHeard: nil, lastVia: [])
        entry.position = GreatCircle.Point(latitude: latitude, longitude: longitude)
        return entry
    }
}
