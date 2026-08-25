import XCTest
@testable import AXTerm

final class GreatCircleTests: XCTestCase {

    private let denver = GreatCircle.Point(latitude: 39.7392, longitude: -104.9903)
    private let boulder = GreatCircle.Point(latitude: 40.0150, longitude: -105.2705)
    private let london = GreatCircle.Point(latitude: 51.5074, longitude: -0.1278)

    // MARK: - Distance

    /// Denver to Boulder is about 39 km.
    func testShortDistanceIsRight() {
        XCTAssertEqual(GreatCircle.kilometres(from: denver, to: boulder), 39, accuracy: 2)
    }

    /// Denver to London is about 7,500 km — catches a radius or radians
    /// error that a short hop would hide.
    func testLongDistanceIsRight() {
        XCTAssertEqual(GreatCircle.kilometres(from: denver, to: london), 7500, accuracy: 100)
    }

    func testDistanceIsSymmetricAndZeroToItself() {
        XCTAssertEqual(GreatCircle.kilometres(from: denver, to: boulder),
                       GreatCircle.kilometres(from: boulder, to: denver), accuracy: 0.001)
        XCTAssertEqual(GreatCircle.kilometres(from: denver, to: denver), 0, accuracy: 0.0001)
    }

    // MARK: - Bearing

    /// Boulder is north-northwest of Denver.
    func testBearingPointsTheRightWay() {
        let bearing = GreatCircle.bearingDegrees(from: denver, to: boulder)
        XCTAssertGreaterThan(bearing, 300)
        XCTAssertLessThan(bearing, 340)
        XCTAssertEqual(GreatCircle.compassPoint(bearing), "NW")
    }

    /// Due-north, east, south and west cases pin the quadrants — where a
    /// swapped sin/cos hides.
    func testCardinalBearings() {
        let origin = GreatCircle.Point(latitude: 0, longitude: 0)
        XCTAssertEqual(GreatCircle.bearingDegrees(
            from: origin, to: .init(latitude: 10, longitude: 0)), 0, accuracy: 0.01)
        XCTAssertEqual(GreatCircle.bearingDegrees(
            from: origin, to: .init(latitude: 0, longitude: 10)), 90, accuracy: 0.01)
        XCTAssertEqual(GreatCircle.bearingDegrees(
            from: origin, to: .init(latitude: -10, longitude: 0)), 180, accuracy: 0.01)
        XCTAssertEqual(GreatCircle.bearingDegrees(
            from: origin, to: .init(latitude: 0, longitude: -10)), 270, accuracy: 0.01)
    }

    /// Bearings are compass bearings: 0…360, never negative.
    func testBearingIsAlwaysPositive() {
        for longitude in stride(from: -180.0, through: 180.0, by: 15) {
            let bearing = GreatCircle.bearingDegrees(
                from: .init(latitude: 10, longitude: 0),
                to: .init(latitude: -10, longitude: longitude))
            XCTAssertGreaterThanOrEqual(bearing, 0, "lon \(longitude)")
            XCTAssertLessThan(bearing, 360, "lon \(longitude)")
        }
    }

    func testCompassPointsCoverTheRose() {
        XCTAssertEqual(GreatCircle.compassPoint(0), "N")
        XCTAssertEqual(GreatCircle.compassPoint(45), "NE")
        XCTAssertEqual(GreatCircle.compassPoint(180), "S")
        XCTAssertEqual(GreatCircle.compassPoint(270), "W")
        // Wraps rather than falling off the end.
        XCTAssertEqual(GreatCircle.compassPoint(359), "N")
        XCTAssertEqual(GreatCircle.compassPoint(360), "N")
    }
}

final class StationScopeTests: XCTestCase {

    private func site(_ id: String,
                      km: Double,
                      bearing: Double,
                      signal: StationScope.Signal = .good) -> StationScope.Site {
        StationScope.Site(
            id: id, label: id, kilometres: km, bearingDegrees: bearing,
            signal: signal, subtitle: "", detail: "", isStale: false)
    }

    // MARK: - Range and rings

    /// The outer ring is a round number, not whatever the furthest
    /// station happens to be.
    func testRangeRoundsUpToARingStep() {
        XCTAssertEqual(StationScope.range(covering: [site("a", km: 16, bearing: 0)]), 25)
        XCTAssertEqual(StationScope.range(covering: [site("a", km: 71, bearing: 0)]), 100)
        XCTAssertEqual(StationScope.range(covering: [site("a", km: 25, bearing: 0)]), 25)
    }

    func testRangeCoversTheFurthestSite() {
        let sites = [site("near", km: 5, bearing: 0), site("far", km: 180, bearing: 90)]
        XCTAssertGreaterThanOrEqual(StationScope.range(covering: sites), 180)
    }

    func testEmptyScopeStillHasARange() {
        let scope = StationScope.build(observerLabel: "K0EPI", sites: [])
        XCTAssertTrue(scope.isEmpty)
        XCTAssertGreaterThan(scope.maxRange, 0)
    }

    /// Rings are a scale, not a bullseye — at most three, all inside the
    /// edge.
    func testRingsStayInsideTheRangeAndAreFew() {
        for range in StationScope.ringSteps {
            let rings = StationScope.rings(forRange: range)
            XCTAssertLessThanOrEqual(rings.count, 3, "range \(range)")
            XCTAssertTrue(rings.allSatisfy { $0 < range }, "range \(range)")
        }
    }

    // MARK: - Ordering

    /// Nearest first, ties broken by id, so two builds of the same data
    /// draw identically.
    func testSitesSortByDistanceThenIdentity() {
        let scope = StationScope.build(observerLabel: "K0EPI", sites: [
            site("zulu", km: 10, bearing: 0),
            site("alpha", km: 10, bearing: 90),
            site("near", km: 2, bearing: 180),
        ])
        XCTAssertEqual(scope.sites.map(\.id), ["near", "alpha", "zulu"])
    }

    // MARK: - Plotting

    /// North is up, east is right, and the outer ring is the unit edge.
    func testUnitPointsUseScreenOrientation() {
        let north = site("n", km: 50, bearing: 0).unitPoint(maxRange: 50)
        XCTAssertEqual(north.x, 0, accuracy: 0.001)
        XCTAssertEqual(north.y, -1, accuracy: 0.001, "north is up, so negative y")

        let east = site("e", km: 50, bearing: 90).unitPoint(maxRange: 50)
        XCTAssertEqual(east.x, 1, accuracy: 0.001)
        XCTAssertEqual(east.y, 0, accuracy: 0.001)

        let south = site("s", km: 25, bearing: 180).unitPoint(maxRange: 50)
        XCTAssertEqual(south.y, 0.5, accuracy: 0.001, "half range, southward")
    }

    /// A site beyond the edge is clamped to the rim rather than drawn
    /// off the scope.
    func testSitesBeyondTheEdgeClampToTheRim() {
        let point = site("far", km: 500, bearing: 90).unitPoint(maxRange: 50)
        XCTAssertEqual(point.x, 1, accuracy: 0.001)
    }

    func testObserverIsAtTheCentre() {
        let point = site("here", km: 0, bearing: 0).unitPoint(maxRange: 50)
        XCTAssertEqual(point.x, 0, accuracy: 0.001)
        XCTAssertEqual(point.y, 0, accuracy: 0.001)
    }

    // MARK: - Building from coordinates

    /// A station with no known position is dropped, never guessed at —
    /// plotting it in the wrong place is worse than not plotting it.
    func testSitesWithoutAPositionAreDropped() {
        let scope = StationScope.build(
            observerLabel: "K0EPI",
            observer: .init(latitude: 39.7392, longitude: -104.9903),
            entries: [
                (id: "known", label: "W0ARP-10",
                 position: .init(latitude: 39.6, longitude: -104.9),
                 signal: .good, subtitle: "", detail: "", isStale: false,
                 isApproximate: false),
                (id: "unknown", label: "N0XYZ", position: nil,
                 signal: .unknown, subtitle: "", detail: "", isStale: false,
                 isApproximate: false),
            ])
        XCTAssertEqual(scope.sites.map(\.id), ["known"])
    }

    /// Distance and bearing come out of the coordinates, not the caller.
    func testCoordinatesBecomeRangeAndBearing() throws {
        let scope = StationScope.build(
            observerLabel: "K0EPI",
            observer: .init(latitude: 0, longitude: 0),
            entries: [
                (id: "north", label: "N", position: .init(latitude: 1, longitude: 0),
                 signal: .good, subtitle: "", detail: "", isStale: false,
                 isApproximate: false),
            ])
        let site = try XCTUnwrap(scope.sites.first)
        XCTAssertEqual(site.bearingDegrees, 0, accuracy: 0.01)
        XCTAssertEqual(site.kilometres, 111, accuracy: 2)
        XCTAssertEqual(site.compassPoint, "N")
    }

    /// The whole point of the model being view-free: a grid square is
    /// enough to plot a station, with no network involved.
    func testAGridSquareIsEnoughToPlotAStation() throws {
        let gateway = try XCTUnwrap(Maidenhead.center(of: "DM79QL"))
        let observer = try XCTUnwrap(Maidenhead.center(of: "DM79po"))
        let scope = StationScope.build(
            observerLabel: "DM79po",
            observer: .init(observer),
            entries: [
                (id: "W0ARP-10", label: "W0ARP-10", position: .init(gateway),
                 signal: .fair, subtitle: "145.050", detail: "", isStale: false,
                 isApproximate: false),
            ])
        let site = try XCTUnwrap(scope.sites.first)
        // Both squares are in DM79, so this is a short hop.
        XCTAssertLessThan(site.kilometres, 100)
        XCTAssertGreaterThan(site.kilometres, 0)
    }
}
