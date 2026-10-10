import XCTest
@testable import AXTerm

/// Outlines thinned for drawing. NWS coastal zone outlines run to 8,000
/// points each; 191 cached Florida and Georgia zones held 140,000, all
/// copied, compared and drawn on each update, and iOS lagged (2026-10-09).
/// About 50 m is finer than any screen shows a county.
final class HazardSimplifyTests: XCTestCase {
    private func p(_ lat: Double, _ lon: Double) -> GreatCircle.Point { .init(latitude: lat, longitude: lon) }

    func testPointsAlongAStraightEdgeGo() {
        // A square with 250 points along each side, closed.
        var ring: [GreatCircle.Point] = []
        for i in 0..<250 { ring.append(p(39, -105 + Double(i) / 250)) }
        for i in 0..<250 { ring.append(p(39 + Double(i) / 250, -104)) }
        for i in 0..<250 { ring.append(p(40, -104 - Double(i) / 250)) }
        for i in 0..<250 { ring.append(p(40 - Double(i) / 250, -105)) }
        ring.append(ring[0])
        let thin = HazardSimplify.ring(ring, tolerance: HazardSimplify.drawingTolerance)
        XCTAssertEqual(thin.count, 5, "four corners and the closing point")
        XCTAssertEqual(thin.first, thin.last)
    }

    func testAShapeLargerThanTheToleranceStays() {
        // A notch about 1 km deep in one side survives 50 m thinning.
        let ring = [p(39, -105), p(39, -104.5), p(39.01, -104.5), p(39, -104.49), p(39, -104),
                    p(40, -104), p(40, -105), p(39, -105)]
        let thin = HazardSimplify.ring(ring, tolerance: HazardSimplify.drawingTolerance)
        XCTAssertTrue(thin.contains(p(39.01, -104.5)))
    }

    func testARingNeverCollapses() {
        let tiny = [p(39, -105), p(39.0001, -105), p(39.0001, -105.0001), p(39, -105)]
        let thin = HazardSimplify.ring(tiny, tolerance: HazardSimplify.drawingTolerance)
        XCTAssertGreaterThanOrEqual(thin.count, 4, "still a closed ring")
        XCTAssertEqual(thin.first, thin.last)
    }

    /// Zones are thinned as they are read, and a point well inside one is
    /// still inside.
    func testZonesAreThinnedWhenRead() throws {
        let url = try XCTUnwrap(Bundle(for: HazardSimplifyTests.self).url(forResource: "nws-zone-COC007", withExtension: "json"))
        let zone = try NWSAlertFeed.parseZone(try Data(contentsOf: url))
        guard case .polygons(let polygons) = try XCTUnwrap(zone.geometry) else { return XCTFail("no polygon") }
        let points = polygons.flatMap { $0 }.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(points, 50, "the fixture's 50 points thinned")
        XCTAssertTrue(HazardContainment.contains(.polygons(polygons), p(37.2, -107.0)), "Pagosa Springs area still inside")
    }
}
