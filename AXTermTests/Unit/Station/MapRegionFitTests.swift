import XCTest
@testable import AXTerm

final class MapRegionFitTests: XCTestCase {

    private func point(_ latitude: Double, _ longitude: Double) -> GreatCircle.Point {
        GreatCircle.Point(latitude: latitude, longitude: longitude)
    }

    /// The property that matters: a framing that clips a station is the
    /// bug this type exists to prevent.
    func testEveryPointIsInsideTheRegion() throws {
        let points = [
            point(39.7392, -104.9903),   // Denver
            point(39.6, -104.9),         // W0ARP-10
            point(40.4, -105.6),         // K0ARK-10
            point(38.9, -104.7),
        ]
        let region = try XCTUnwrap(MapRegionFit.region(covering: points))
        for candidate in points {
            XCTAssertTrue(MapRegionFit.contains(region, candidate), "\(candidate) was clipped")
        }
    }

    func testCentreIsBetweenTheExtremes() throws {
        let region = try XCTUnwrap(MapRegionFit.region(covering: [
            point(39, -105), point(41, -103),
        ]))
        XCTAssertEqual(region.centerLatitude, 40, accuracy: 0.0001)
        XCTAssertEqual(region.centerLongitude, -104, accuracy: 0.0001)
    }

    /// Stations in one grid square must not zoom the map to the molecule.
    func testIdenticalPointsStillGetAUsableSpan() throws {
        let region = try XCTUnwrap(MapRegionFit.region(covering: [
            point(39.7392, -104.9903), point(39.7392, -104.9903),
        ]))
        XCTAssertGreaterThanOrEqual(region.latitudeDelta, MapRegionFit.minimumDelta)
        XCTAssertGreaterThanOrEqual(region.longitudeDelta, MapRegionFit.minimumDelta)
    }

    func testSinglePointIsFramedNotRejected() throws {
        let region = try XCTUnwrap(MapRegionFit.region(covering: [point(39.7, -105)]))
        XCTAssertEqual(region.centerLatitude, 39.7, accuracy: 0.0001)
        XCTAssertTrue(MapRegionFit.contains(region, point(39.7, -105)))
    }

    func testNoPointsMeansNoRegion() {
        XCTAssertNil(MapRegionFit.region(covering: []))
    }

    /// The span is padded past the extremes so markers are not sitting
    /// on the frame.
    func testSpanIsPaddedBeyondTheExtremes() throws {
        let region = try XCTUnwrap(MapRegionFit.region(covering: [
            point(39, -105), point(41, -105),
        ]))
        XCTAssertGreaterThan(region.latitudeDelta, 2.0)
    }

    /// Works in the southern and eastern hemispheres too — a sign error
    /// in the midpoint would survive a Denver-only test.
    func testFramesSouthernAndEasternPoints() throws {
        let points = [point(-33.87, 151.21), point(-34.5, 150.9)]
        let region = try XCTUnwrap(MapRegionFit.region(covering: points))
        for candidate in points {
            XCTAssertTrue(MapRegionFit.contains(region, candidate))
        }
        XCTAssertLessThan(region.centerLatitude, 0)
        XCTAssertGreaterThan(region.centerLongitude, 0)
    }
}
