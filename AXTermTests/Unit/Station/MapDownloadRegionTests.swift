import XCTest
import MapKit
@testable import AXTerm

/// Drawing a box to say what to download.
@MainActor
final class MapDownloadRegionTests: XCTestCase {

    private func coordinate(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func session(_ points: [CLLocationCoordinate2D]) -> MapDrawingSession {
        var session = MapDrawingSession()
        session.begin(.download)
        for point in points { _ = session.addVertex(point) }
        return session
    }

    /// Two opposite corners describe a box; asking for a third is busywork.
    func testTwoCornersAreEnough() {
        let drawn = session([coordinate(39.5, -105.5), coordinate(40.5, -104.5)])
        XCTAssertTrue(drawn.canComplete)
        XCTAssertNotNil(drawn.region())
    }

    func testOneCornerIsNotABox() {
        let drawn = session([coordinate(39.5, -105.5)])
        XCTAssertFalse(drawn.canComplete)
        XCTAssertNil(drawn.region())
    }

    func testTheRegionSpansEveryVertex() {
        let drawn = session([
            coordinate(39.0, -105.0), coordinate(40.0, -104.0),
            coordinate(39.5, -106.0),
        ])
        let region = try? XCTUnwrap(drawn.region())
        XCTAssertEqual(region?.center.latitude ?? 0, 39.5, accuracy: 0.001)
        XCTAssertEqual(region?.span.latitudeDelta ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(region?.span.longitudeDelta ?? 0, 2.0, accuracy: 0.001)
    }

    /// A drawn corridor becomes its own bounding box — tiles are square and a
    /// download is a rectangle.
    func testADiagonalCorridorBecomesItsBoundingBox() {
        let drawn = session([coordinate(39.0, -105.0), coordinate(40.0, -104.0)])
        let box = try? XCTUnwrap(drawn.boundingBox())
        XCTAssertEqual(box?.count, 5, "closed rectangle")
        XCTAssertEqual(box?.first?.latitude, box?.last?.latitude)
        XCTAssertEqual(box?.first?.longitude, box?.last?.longitude)
    }

    /// A box with no area would ask for a strip of tiles zero degrees wide.
    func testADegenerateBoxIsRefused() {
        let vertical = session([coordinate(39.0, -105.0), coordinate(40.0, -105.0)])
        XCTAssertNil(vertical.region())
        XCTAssertNil(vertical.boundingBox())
    }

    func testTheDownloadModePreviewsAsTheBoxItself() {
        let drawn = session([coordinate(39.0, -105.0), coordinate(40.0, -104.0)])
        // Not the two tapped points — what is about to be fetched is what
        // should be on screen.
        XCTAssertEqual(drawn.previewVertices().count, 5)
    }

    /// A download box is a question about what to fetch, never a saved
    /// feature, so it is not offered a name.
    func testDownloadIsAMultiPointModeDistinctFromArea() {
        XCTAssertTrue(MapDrawingMode.download.isMultiPoint)
        XCTAssertNotEqual(MapDrawingMode.download, .area)
        XCTAssertEqual(MapDrawingSession.minimumVertices(for: .download), 2)
        XCTAssertEqual(MapDrawingSession.minimumVertices(for: .area), 3)
    }

    // MARK: - Tile budget

    /// A hand can draw a continent in two taps. The cap is what stops that
    /// becoming another sequential march across the country.
    func testAnEnormousBoxIsCappedRatherThanObeyed() {
        let continent = MKCoordinateRegion(
            center: coordinate(38, -95),
            span: MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 50))
        let capped = ElevationStorage.tilesWorthFetching(covering: continent)
        XCTAssertTrue(capped.wasCapped)
        XCTAssertEqual(capped.tiles.count, ElevationStorage.maximumTilesPerRequest)
    }

    func testAReasonableBoxIsNotCapped() {
        let colorado = MKCoordinateRegion(
            center: coordinate(39.5, -105.0),
            span: MKCoordinateSpan(latitudeDelta: 1.5, longitudeDelta: 1.5))
        let capped = ElevationStorage.tilesWorthFetching(covering: colorado)
        XCTAssertFalse(capped.wasCapped)
        XCTAssertLessThanOrEqual(capped.tiles.count,
                                 ElevationStorage.maximumTilesPerRequest)
        XCTAssertFalse(capped.tiles.isEmpty)
    }

    /// Truncation has to be visible; a cap the operator cannot see reads as
    /// coverage they did not get.
    func testTheEstimateReportsWhatTheRegionActuallyCovers() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elev-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let continent = MKCoordinateRegion(
            center: coordinate(38, -95),
            span: MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 50))
        let estimate = ElevationStorage(url: url).estimate(covering: continent)
        XCTAssertTrue(estimate.wasCapped)
        XCTAssertGreaterThan(estimate.requestedTileCount,
                             ElevationStorage.maximumTilesPerRequest)
        XCTAssertEqual(estimate.tileCount, ElevationStorage.maximumTilesPerRequest)
    }
}
