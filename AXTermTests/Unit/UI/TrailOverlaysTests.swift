import MapKit
import XCTest
@testable import AXTerm

/// The overlays a trail plan becomes on the map.
final class TrailOverlaysTests: XCTestCase {
    private let points = [GreatCircle.Point(latitude: 39.52, longitude: -105.31),
                          GreatCircle.Point(latitude: 39.64, longitude: -105.13)]

    func testAPieceCarriesItsPointsAndStyle() {
        let piece = TrailPlan.Piece(points: points, startAlpha: 0.2, endAlpha: 0.9, width: 4.5, dashed: true)
        let line = TrailPieceLine.make(piece, color: .systemOrange)
        XCTAssertEqual(line.pointCount, 2)
        XCTAssertEqual(line.points()[1].coordinate.latitude, 39.64, accuracy: 1e-9)
        XCTAssertEqual(line.startAlpha, 0.2, accuracy: 1e-9)
        XCTAssertEqual(line.endAlpha, 0.9, accuracy: 1e-9)
        XCTAssertEqual(line.width, 4.5, accuracy: 1e-9)
        XCTAssertTrue(line.dashed)
        XCTAssertEqual(line.color, .systemOrange)
    }

    /// Every fix dot lies inside the overlay's bounds, or MapKit never asks
    /// for the tile that would draw it.
    func testTheFixesOverlayBoundsEveryFix() {
        let overlay = TrailFixesOverlay(points: points, color: .systemOrange)
        XCTAssertEqual(overlay.points.count, 2)
        for point in overlay.points {
            XCTAssertTrue(overlay.boundingMapRect.contains(point))
        }
    }
}
