import MapKit
import XCTest
@testable import AXTerm

/// Hazards as MapKit polygons, each carrying its own style so the map can
/// draw it and leave it alone when it rebuilds the operator's layers.
final class HazardOverlayBuilderTests: XCTestCase {
    private func p(_ lat: Double, _ lon: Double) -> GreatCircle.Point {
        GreatCircle.Point(latitude: lat, longitude: lon)
    }

    private var item: HazardDrawing.Item {
        HazardDrawing.Item(
            id: "rf",
            polygons: [
                [[p(39, -105), p(39, -104), p(40, -104), p(40, -105)],
                 [p(39.4, -104.6), p(39.4, -104.4), p(39.6, -104.4)]],
                [[p(41, -105), p(41, -104), p(42, -104)]],
            ],
            hex: "FF1493", fillAlpha: 0.18, strokeAlpha: 0.9, dashed: true)
    }

    func testEachPolygonBecomesOneMapPolygonWithItsHoles() {
        let polygons = HazardOverlayBuilder.polygons(for: item)
        XCTAssertEqual(polygons.count, 2)
        XCTAssertEqual(polygons[0].pointCount, 4)
        XCTAssertEqual(polygons[0].interiorPolygons?.count, 1)
        XCTAssertEqual(polygons[0].interiorPolygons?.first?.pointCount, 3)
        XCTAssertNil(polygons[1].interiorPolygons?.first)
        let first = polygons[0].points()[0].coordinate
        XCTAssertEqual(first.latitude, 39, accuracy: 1e-9)
        XCTAssertEqual(first.longitude, -105, accuracy: 1e-9)
    }

    func testEachMapPolygonCarriesItsStyle() throws {
        let polygon = try XCTUnwrap(HazardOverlayBuilder.polygons(for: item).first)
        XCTAssertEqual(polygon.hazardID, "rf")
        XCTAssertEqual(polygon.hex, "FF1493")
        XCTAssertEqual(polygon.fillAlpha, 0.18)
        XCTAssertEqual(polygon.strokeAlpha, 0.9)
        XCTAssertTrue(polygon.dashed)
    }

    func testTheNWSHexBecomesRGB() throws {
        let rgb = try XCTUnwrap(HazardOverlayBuilder.rgb("FF1493"))
        XCTAssertEqual(rgb.red, 1, accuracy: 1e-9)
        XCTAssertEqual(rgb.green, 20.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(rgb.blue, 147.0 / 255, accuracy: 1e-9)
        XCTAssertNil(HazardOverlayBuilder.rgb("nope"))
    }
}
