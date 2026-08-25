import XCTest
import CoreLocation
@testable import AXTerm

/// Drawing rules, tested without tapping anything.
///
/// The rules matter more than they look. A two-point "area" and a one-point
/// "line" are degenerate geometry that the shapefile writer, GeoJSON and
/// MapKit's renderer each handle differently and none handle well — refusing
/// them here is cheaper than discovering them in a file somebody else opened.
final class MapDrawingSessionTests: XCTestCase {

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Points

    /// A mark completes on the first tap — there is nothing to accumulate.
    func testAPointCompletesImmediately() {
        var session = MapDrawingSession()
        session.begin(.point)
        XCTAssertTrue(session.addVertex(at(39.74, -104.99)))

        guard case .point(let coordinate) = try? XCTUnwrap(session.geometry()) else {
            return XCTFail("expected a point")
        }
        XCTAssertEqual(coordinate.latitude, 39.74, accuracy: 1e-9)
        XCTAssertEqual(coordinate.longitude, -104.99, accuracy: 1e-9)
    }

    // MARK: - Minimum vertices

    /// A line needs two points and an area needs three. Below that the
    /// session refuses to produce geometry rather than emitting something
    /// degenerate.
    func testAnIncompleteShapeProducesNothing() {
        var line = MapDrawingSession()
        line.begin(.line)
        line.addVertex(at(39, -105))
        XCTAssertFalse(line.canComplete)
        XCTAssertNil(line.geometry())

        var area = MapDrawingSession()
        area.begin(.area)
        area.addVertex(at(39, -105))
        area.addVertex(at(39, -104))
        XCTAssertFalse(area.canComplete)
        XCTAssertNil(area.geometry())
    }

    func testALineCompletesAtTwoPoints() throws {
        var session = MapDrawingSession()
        session.begin(.line)
        XCTAssertFalse(session.addVertex(at(39, -105)))
        XCTAssertFalse(session.addVertex(at(39.5, -104)))

        XCTAssertTrue(session.canComplete)
        guard case .polyline(let parts) = try XCTUnwrap(session.geometry()) else {
            return XCTFail("expected a polyline")
        }
        XCTAssertEqual(parts[0].count, 2)
    }

    func testAnAreaCompletesAtThreeCorners() throws {
        var session = MapDrawingSession()
        session.begin(.area)
        for point in [at(39, -105), at(39, -104), at(40, -104)] {
            session.addVertex(point)
        }

        guard case .polygon(let rings) = try XCTUnwrap(session.geometry()) else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings[0].count, 3)
    }

    /// The ring is stored **open**. Both GeoJSON and the shapefile writer
    /// close it themselves; a ring closed twice has a duplicated point that
    /// some readers report as a degenerate edge.
    func testTheStoredRingIsNotClosedTwice() throws {
        var session = MapDrawingSession()
        session.begin(.area)
        for point in [at(39, -105), at(39, -104), at(40, -104), at(40, -105)] {
            session.addVertex(point)
        }

        guard case .polygon(let rings) = try XCTUnwrap(session.geometry()) else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings[0].count, 4, "the ring should stay open")
        XCTAssertNotEqual(rings[0].first?.latitude, rings[0].last?.latitude)

        // And the writer closes it on the way out.
        XCTAssertEqual(GeoJSONWriter.closed(rings[0]).count, 5)
    }

    // MARK: - Preview

    /// While drawing an area the operator should see the shape, not the open
    /// path they have tapped so far.
    func testAnAreaPreviewShowsItsClosingEdge() {
        var session = MapDrawingSession()
        session.begin(.area)
        for point in [at(39, -105), at(39, -104), at(40, -104)] {
            session.addVertex(point)
        }
        let preview = session.previewVertices()
        XCTAssertEqual(preview.count, 4)
        XCTAssertEqual(preview.first?.latitude, preview.last?.latitude)
    }

    /// Below three points there is no area to close, so the preview is just
    /// the path.
    func testAPartialAreaPreviewIsJustThePath() {
        var session = MapDrawingSession()
        session.begin(.area)
        session.addVertex(at(39, -105))
        session.addVertex(at(39, -104))
        XCTAssertEqual(session.previewVertices().count, 2)
    }

    // MARK: - Undo and cancel

    func testUndoRemovesTheLastVertex() {
        var session = MapDrawingSession()
        session.begin(.area)
        for point in [at(39, -105), at(39, -104), at(40, -104)] {
            session.addVertex(point)
        }
        session.undoVertex()

        XCTAssertEqual(session.vertices.count, 2)
        XCTAssertFalse(session.canComplete)
    }

    func testUndoOnAnEmptySessionIsHarmless() {
        var session = MapDrawingSession()
        session.begin(.line)
        session.undoVertex()
        XCTAssertTrue(session.vertices.isEmpty)
        XCTAssertFalse(session.canUndo)
    }

    func testCancelClearsEverything() {
        var session = MapDrawingSession()
        session.begin(.area)
        session.addVertex(at(39, -105))
        session.cancel()

        XCTAssertEqual(session.mode, .off)
        XCTAssertTrue(session.vertices.isEmpty)
        XCTAssertFalse(session.isDrawing)
    }

    /// Starting a new shape must not inherit the last one's vertices.
    func testBeginningANewShapeDiscardsTheOldVertices() {
        var session = MapDrawingSession()
        session.begin(.area)
        session.addVertex(at(39, -105))
        session.begin(.line)
        XCTAssertTrue(session.vertices.isEmpty)
    }

    /// Taps must do nothing while not drawing, or a stray tap in select mode
    /// silently starts collecting a shape.
    func testTapsAreIgnoredWhenNotDrawing() {
        var session = MapDrawingSession()
        XCTAssertFalse(session.addVertex(at(39, -105)))
        XCTAssertTrue(session.vertices.isEmpty)
    }

    // MARK: - Progress text

    /// A disabled Done button the operator cannot explain is worse than one
    /// that says what it is waiting for.
    func testProgressSaysWhatIsStillNeeded() {
        var session = MapDrawingSession()
        session.begin(.area)
        XCTAssertEqual(session.progressText, "0 of 3 — tap 3 more")
        session.addVertex(at(39, -105))
        XCTAssertEqual(session.progressText, "1 of 3 — tap 2 more")
        session.addVertex(at(39, -104))
        session.addVertex(at(40, -104))
        XCTAssertEqual(session.progressText, "3 points — tap Done to finish")
    }

    /// A mark needs no running commentary.
    func testAPointHasNoProgressText() {
        var session = MapDrawingSession()
        session.begin(.point)
        XCTAssertNil(session.progressText)
    }
}

/// Where a feature's label goes.
final class MapFeatureLabelTests: XCTestCase {

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func testAPointLabelsItself() throws {
        let anchor = try XCTUnwrap(MapFeatureLabel.anchor(for: .point(at(39.74, -104.99))))
        XCTAssertEqual(anchor.latitude, 39.74, accuracy: 1e-9)
    }

    /// The label sits in the middle of a route, not at its start — where it
    /// would land on top of whatever the route begins at.
    func testALineLabelsItsMiddle() throws {
        let line = ShapefileReader.Geometry.polyline([[
            at(39, -105), at(39.5, -104.5), at(40, -104),
        ]])
        let anchor = try XCTUnwrap(MapFeatureLabel.anchor(for: line))
        XCTAssertEqual(anchor.latitude, 39.5, accuracy: 1e-9)
    }

    /// A square's centroid is its middle — the simple case, pinned so the
    /// formula's sign conventions cannot drift.
    func testASquareCentroidIsItsMiddle() throws {
        let square = [at(39, -105), at(39, -104), at(40, -104), at(40, -105)]
        let centre = try XCTUnwrap(MapFeatureLabel.centroid(of: square))
        XCTAssertEqual(centre.latitude, 39.5, accuracy: 1e-9)
        XCTAssertEqual(centre.longitude, -104.5, accuracy: 1e-9)
    }

    /// The case that makes an area-weighted centroid worth computing. An
    /// L-shape's bounding-box centre falls in the notch — outside the polygon
    /// — which would float the label over the neighbouring zone. The centroid
    /// is pulled toward the mass of the shape instead.
    func testAnLShapeCentroidIsNotTheBoundingBoxCentre() throws {
        let lShape = [
            at(0, 0), at(0, 3), at(1, 3), at(1, 1), at(3, 1), at(3, 0),
        ]
        let centroid = try XCTUnwrap(MapFeatureLabel.centroid(of: lShape))
        let boxCentre = try XCTUnwrap(MapFeatureLabel.boundingCentre(of: lShape))

        XCTAssertEqual(boxCentre.latitude, 1.5, accuracy: 1e-9)
        XCTAssertEqual(boxCentre.longitude, 1.5, accuracy: 1e-9)
        // The centroid must differ, and must sit nearer the occupied arms.
        XCTAssertLessThan(centroid.latitude, 1.5)
        XCTAssertLessThan(centroid.longitude, 1.5)
    }

    /// Winding must not move the centroid. A ring stored clockwise and the
    /// same ring counter-clockwise are the same shape, and the shoelace
    /// formula flips sign between them — which cancels only if the code is
    /// right.
    func testCentroidIsIndependentOfWindingDirection() throws {
        let ring = [at(39, -105), at(39, -104), at(40, -104), at(40, -105)]
        let forward = try XCTUnwrap(MapFeatureLabel.centroid(of: ring))
        let reversed = try XCTUnwrap(MapFeatureLabel.centroid(of: ring.reversed()))

        XCTAssertEqual(forward.latitude, reversed.latitude, accuracy: 1e-9)
        XCTAssertEqual(forward.longitude, reversed.longitude, accuracy: 1e-9)
    }

    /// Three collinear points enclose no area, and the formula divides by it.
    /// Falls back to the bounding centre rather than producing infinity.
    func testADegenerateRingFallsBackRatherThanDividingByZero() throws {
        let collinear = [at(39, -105), at(39, -104), at(39, -103)]
        XCTAssertNil(MapFeatureLabel.centroid(of: collinear))

        let anchor = try XCTUnwrap(MapFeatureLabel.anchor(for: .polygon([collinear])))
        XCTAssertEqual(anchor.latitude, 39, accuracy: 1e-9)
        XCTAssertEqual(anchor.longitude, -104, accuracy: 1e-9)
    }

    func testAnEmptyGeometryHasNoAnchor() {
        XCTAssertNil(MapFeatureLabel.anchor(for: .polyline([])))
        XCTAssertNil(MapFeatureLabel.anchor(for: .polygon([])))
    }
}
