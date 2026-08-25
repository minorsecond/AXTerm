import XCTest
import CoreLocation
@testable import AXTerm

/// Writing GeoJSON, and the persistence built on it.
///
/// `GeoJSONWriter` is load-bearing twice over: it is how layers survive a
/// quit, and it is what goes over the air. A mistake here is silent — a file
/// written with the coordinates the wrong way round loads back with every
/// feature in the wrong hemisphere and nothing about it looks malformed.
final class GeoJSONWriterTests: XCTestCase {

    private func layer(_ features: [MapOverlayFeature], name: String = "Marks")
        -> MapOverlayLayer {
        MapOverlayLayer(id: "marks.geojson", name: name, features: features, colorName: "blue")
    }

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Shape of the file

    func testProducesAFeatureCollection() throws {
        let data = try GeoJSONWriter.data(for: layer([
            MapOverlayFeature(name: "Camp", geometry: .point(at(39.74, -104.99))),
        ]))
        let root = try object(data)

        XCTAssertEqual(root["type"] as? String, "FeatureCollection")
        let features = try XCTUnwrap(root["features"] as? [[String: Any]])
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0]["type"] as? String, "Feature")
    }

    /// RFC 7946 order: **longitude first**. The same trap as the shapefile
    /// reader, from the opposite direction.
    func testCoordinatesAreLongitudeThenLatitude() throws {
        let data = try GeoJSONWriter.data(for: layer([
            MapOverlayFeature(name: "Camp", geometry: .point(at(39.74, -104.99))),
        ]))
        let features = try XCTUnwrap(try object(data)["features"] as? [[String: Any]])
        let geometry = try XCTUnwrap(features[0]["geometry"] as? [String: Any])
        let pair = try XCTUnwrap(geometry["coordinates"] as? [Double])

        XCTAssertEqual(pair[0], -104.99, accuracy: 1e-9, "first value must be longitude")
        XCTAssertEqual(pair[1], 39.74, accuracy: 1e-9, "second value must be latitude")
    }

    func testGeometryTypesAreNamedCorrectly() throws {
        let cases: [(ShapefileReader.Geometry, String)] = [
            (.point(at(39, -105)), "Point"),
            (.polyline([[at(39, -105), at(40, -104)]]), "LineString"),
            (.polyline([[at(39, -105), at(40, -104)], [at(41, -103), at(42, -102)]]),
             "MultiLineString"),
            (.polygon([[at(39, -105), at(39, -104), at(40, -104)]]), "Polygon"),
        ]
        for (geometry, expected) in cases {
            let data = try GeoJSONWriter.data(for: layer([MapOverlayFeature(geometry: geometry)]))
            let features = try XCTUnwrap(try object(data)["features"] as? [[String: Any]])
            let written = try XCTUnwrap(features[0]["geometry"] as? [String: Any])
            XCTAssertEqual(written["type"] as? String, expected)
        }
    }

    /// GeoJSON requires closed rings. A shapefile ring usually is closed but
    /// not always, and a strict reader would reject a file this app wrote.
    func testPolygonRingsAreClosed() throws {
        let open = [at(39, -105), at(39, -104), at(40, -104)]
        let data = try GeoJSONWriter.data(for: layer([
            MapOverlayFeature(geometry: .polygon([open])),
        ]))
        let features = try XCTUnwrap(try object(data)["features"] as? [[String: Any]])
        let geometry = try XCTUnwrap(features[0]["geometry"] as? [String: Any])
        let rings = try XCTUnwrap(geometry["coordinates"] as? [[[Double]]])

        XCTAssertEqual(rings[0].count, 4, "the ring should have gained its closing point")
        XCTAssertEqual(rings[0].first!, rings[0].last!)
    }

    func testAnAlreadyClosedRingIsNotClosedTwice() {
        let closed = [at(39, -105), at(39, -104), at(40, -104), at(39, -105)]
        XCTAssertEqual(GeoJSONWriter.closed(closed).count, 4)
    }

    // MARK: - Precision

    /// Six decimals is about 11 cm — finer than any position this app
    /// handles. Those digits are bytes, and these files go over 1200 baud:
    /// full `Double` precision roughly doubles the size of a point for
    /// accuracy nobody has.
    func testCoordinatesAreRoundedToTheStatedPrecision() throws {
        let data = try GeoJSONWriter.data(for: layer([
            MapOverlayFeature(geometry: .point(at(39.123456789, -104.987654321))),
        ]))
        let features = try XCTUnwrap(try object(data)["features"] as? [[String: Any]])
        let geometry = try XCTUnwrap(features[0]["geometry"] as? [String: Any])
        let pair = try XCTUnwrap(geometry["coordinates"] as? [Double])

        XCTAssertEqual(pair[0], -104.987654, accuracy: 1e-9)
        XCTAssertEqual(pair[1], 39.123457, accuracy: 1e-9)
    }

    /// And the saving is real, not theoretical.
    func testRoundingActuallyShrinksTheFile() throws {
        let points = (0..<200).map {
            MapOverlayFeature(geometry: .point(at(39 + Double($0) / 7919.0,
                                                  -104 - Double($0) / 6841.0)))
        }
        let data = try GeoJSONWriter.data(for: layer(points))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        // No coordinate should carry more than six decimals.
        XCTAssertNil(text.range(of: #"-?\d+\.\d{7,}"#, options: .regularExpression),
                     "a coordinate was written at full precision")
    }

    // MARK: - Attributes

    func testTheNameTravelsAsAProperty() throws {
        let data = try GeoJSONWriter.data(for: layer([
            MapOverlayFeature(name: "Zone C", geometry: .point(at(39, -105)),
                              attributes: ["agency": "ARES"]),
        ]))
        let features = try XCTUnwrap(try object(data)["features"] as? [[String: Any]])
        let properties = try XCTUnwrap(features[0]["properties"] as? [String: Any])

        XCTAssertEqual(properties["name"] as? String, "Zone C")
        XCTAssertEqual(properties["agency"] as? String, "ARES")
    }

    // MARK: - Round trip

    /// The check that matters: what the writer produces, the reader reads
    /// back. This is the path a persisted layer takes on every launch.
    func testLayersRoundTripThroughTheReader() throws {
        let original = layer([
            MapOverlayFeature(name: "Camp", geometry: .point(at(39.74, -104.99)),
                              attributes: ["zone": "C"]),
            MapOverlayFeature(name: "Route", geometry: .polyline([[at(39, -105), at(40, -104)]])),
            MapOverlayFeature(name: "Sector",
                              geometry: .polygon([[at(39, -105), at(39, -104), at(40, -104)]])),
        ])

        let data = try GeoJSONWriter.data(for: original)
        let read = try MapOverlayLoader.readGeoJSON(data, filename: "marks.geojson")

        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(Set(read.map(\.name)), ["Camp", "Route", "Sector"])
        XCTAssertEqual(read.first { $0.name == "Camp" }?.attributes["zone"], "C")

        guard case .point(let coordinate) = try XCTUnwrap(read.first { $0.name == "Camp" }?.geometry)
        else { return XCTFail("expected a point") }
        XCTAssertEqual(coordinate.latitude, 39.74, accuracy: 1e-6)
        XCTAssertEqual(coordinate.longitude, -104.99, accuracy: 1e-6)
    }

    /// A layer the operator drew must come back **editable** after a
    /// round-trip, or every relaunch freezes their own marks.
    func testUserPlacedFeaturesSurviveARoundTrip() throws {
        let mine = MapOverlayFeature(name: "Mine", geometry: .point(at(39, -105)),
                                     attributes: ["axterm_placed": "1"], isUserPlaced: true)
        let data = try GeoJSONWriter.data(for: layer([mine]))
        let read = try MapOverlayLoader.readGeoJSON(data, filename: "marks.geojson")

        XCTAssertEqual(read.count, 1)
        XCTAssertTrue(read[0].isUserPlaced, "a mark the operator placed came back frozen")
    }

    func testAnEmptyLayerWritesAnEmptyCollection() throws {
        let data = try GeoJSONWriter.data(for: layer([]))
        let features = try XCTUnwrap(try object(data)["features"] as? [[String: Any]])
        XCTAssertTrue(features.isEmpty)
    }
}

// MARK: - Persistence

/// Storing layers between launches.
///
/// The point of the whole feature: an operator who loaded county boundaries
/// before an activation needs them during it, and the activation is the part
/// where nobody has a spare hand to re-import anything.
@MainActor
final class MapOverlayStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-overlays-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> MapOverlayStore {
        MapOverlayStore(directory: directory)
    }

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Survives a relaunch

    func testAPlacedMarkSurvivesAReopen() async throws {
        let first = makeStore()
        first.addPoint(at: at(39.74, -104.99), name: "Staging")
        XCTAssertEqual(first.layers.count, 1)

        // A second store over the same directory is what a relaunch looks like.
        let second = makeStore()
        XCTAssertEqual(second.layers.count, 1)
        XCTAssertEqual(second.layers[0].features.count, 1)
        XCTAssertEqual(second.layers[0].features[0].name, "Staging")
    }

    func testAnImportedLayerSurvivesAReopen() async throws {
        let store = makeStore()
        let geoJSON = try GeoJSONWriter.data(for: MapOverlayLayer(
            id: "zones.geojson", name: "Zones",
            features: [MapOverlayFeature(name: "Zone C",
                                         geometry: .polygon([[at(39, -105), at(39, -104), at(40, -104)]]))],
            colorName: "blue"))
        store.add(data: geoJSON, filename: "zones.geojson")
        XCTAssertNil(store.lastError)

        let reopened = makeStore()
        XCTAssertEqual(reopened.layers.count, 1)
        XCTAssertEqual(reopened.layers[0].features[0].name, "Zone C")
    }

    /// Colour and visibility are display state, kept in a sidecar so the
    /// `.geojson` stays a clean standard file. They must still come back.
    func testVisibilitySurvivesAReopen() async throws {
        let store = makeStore()
        store.addPoint(at: at(39, -105), name: "A")
        store.setVisible(false, for: store.layers[0])

        let reopened = makeStore()
        XCTAssertEqual(reopened.layers.count, 1)
        XCTAssertFalse(reopened.layers[0].isVisible)
        XCTAssertTrue(reopened.visibleLayers.isEmpty)
    }

    /// A shapefile is converted once, on import, rather than re-parsed every
    /// launch — so what lands on disk is `.geojson` whatever came in.
    func testAnImportedShapefileIsStoredAsGeoJSON() async throws {
        let store = makeStore()
        let shp = try XCTUnwrap(ShapefileWriter.components(layer: MapOverlayLayer(
            id: "x", name: "Zones",
            features: [MapOverlayFeature(name: "A", geometry: .point(at(39, -105)))],
            colorName: "blue"))["shp"])

        store.add(data: shp, filename: "zones.shp")
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.layers[0].id, "zones.geojson")

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains("zones.geojson"), "\(files)")
    }

    // MARK: - Editing

    /// Marks go to a scratch layer, kept separate from imported ones.
    func testMarksGoToTheScratchLayer() async throws {
        let store = makeStore()
        store.addPoint(at: at(39, -105), name: "A")
        store.addPoint(at: at(40, -104), name: "B")

        XCTAssertEqual(store.layers.count, 1)
        XCTAssertEqual(store.layers[0].id, MapOverlayStore.scratchLayerID)
        XCTAssertTrue(store.layers[0].isEditable)
        XCTAssertEqual(store.layers[0].features.count, 2)
    }

    func testDrawnShapesAlsoGoToTheScratchLayer() async throws {
        let store = makeStore()
        store.addShape(.polygon([[at(39, -105), at(39, -104), at(40, -104)]]), name: "Sector 1")

        XCTAssertEqual(store.layers[0].features.count, 1)
        XCTAssertTrue(store.layers[0].features[0].isUserPlaced)
    }

    /// Silently editing an agency's boundary file and writing it back would
    /// leave no way to tell what was original, so it is refused — with an
    /// explanation naming where the operator's own marks live.
    func testAnImportedFeatureCannotBeRemoved() async throws {
        let store = makeStore()
        let geoJSON = try GeoJSONWriter.data(for: MapOverlayLayer(
            id: "zones.geojson", name: "Zones",
            features: [MapOverlayFeature(name: "Zone C", geometry: .point(at(39, -105)))],
            colorName: "blue"))
        store.add(data: geoJSON, filename: "zones.geojson")

        let layer = store.layers[0]
        store.removeFeature(layer.features[0], from: layer)

        XCTAssertEqual(store.layers[0].features.count, 1, "the feature should still be there")
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.lastError!.contains(MapOverlayStore.scratchLayerName), store.lastError!)
    }

    func testAPlacedFeatureCanBeRemoved() async throws {
        let store = makeStore()
        store.addPoint(at: at(39, -105), name: "A")
        store.addPoint(at: at(40, -104), name: "B")

        let layer = store.layers[0]
        store.removeFeature(layer.features[0], from: layer)

        XCTAssertEqual(store.layers[0].features.count, 1)
        XCTAssertEqual(store.layers[0].features[0].name, "B")
    }

    /// Removing the last feature removes the layer rather than leaving an
    /// empty one in the list forever.
    func testRemovingTheLastFeatureRemovesTheLayer() async throws {
        let store = makeStore()
        store.addPoint(at: at(39, -105), name: "Only")
        store.removeFeature(store.layers[0].features[0], from: store.layers[0])

        XCTAssertTrue(store.layers.isEmpty)
        XCTAssertTrue(makeStore().layers.isEmpty, "the file should be gone too")
    }

    func testRenamingPersists() async throws {
        let store = makeStore()
        store.addPoint(at: at(39, -105), name: "Old")
        store.rename(store.layers[0].features[0], to: "New", in: store.layers[0])

        XCTAssertEqual(makeStore().layers[0].features[0].name, "New")
    }

    // MARK: - Removing layers

    func testRemovingALayerDeletesItsFiles() async throws {
        let store = makeStore()
        store.addPoint(at: at(39, -105), name: "A")
        store.remove(store.layers[0])

        XCTAssertTrue(store.layers.isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(files.isEmpty, "left behind: \(files)")
    }

    /// Re-adding the same file replaces it rather than stacking a second copy.
    func testReimportingAFileReplacesIt() async throws {
        let store = makeStore()
        let first = try GeoJSONWriter.data(for: MapOverlayLayer(
            id: "z.geojson", name: "Z",
            features: [MapOverlayFeature(name: "One", geometry: .point(at(39, -105)))],
            colorName: "blue"))
        let second = try GeoJSONWriter.data(for: MapOverlayLayer(
            id: "z.geojson", name: "Z",
            features: [MapOverlayFeature(name: "Two", geometry: .point(at(40, -104))),
                       MapOverlayFeature(name: "Three", geometry: .point(at(41, -103)))],
            colorName: "blue"))

        store.add(data: first, filename: "z.geojson")
        store.add(data: second, filename: "z.geojson")

        XCTAssertEqual(store.layers.count, 1)
        XCTAssertEqual(store.layers[0].features.count, 2)
    }

    // MARK: - Failure

    /// One unreadable file must not cost the operator the other layers, and
    /// they need to know which one to replace.
    func testACorruptFileIsReportedAndTheRestStillLoad() async throws {
        let store = makeStore()
        store.addPoint(at: at(39, -105), name: "Good")

        try Data("not json at all".utf8)
            .write(to: directory.appendingPathComponent("broken.geojson"))

        let reopened = makeStore()
        XCTAssertEqual(reopened.layers.count, 1, "the good layer should still load")
        XCTAssertNotNil(reopened.lastError)
        XCTAssertTrue(reopened.lastError!.contains("broken.geojson"), reopened.lastError!)
    }

    func testAnUnsupportedFormatIsRefusedByName() async throws {
        let store = makeStore()
        store.add(data: Data("whatever".utf8), filename: "boundaries.kml")

        XCTAssertTrue(store.layers.isEmpty)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.lastError!.contains("kml"), store.lastError!)
    }

    // MARK: - Export

    func testExportRoundTripsThroughTheReader() async throws {
        let store = makeStore()
        store.addPoint(at: at(39.74, -104.99), name: "Camp")

        let geoJSON = try store.exportGeoJSON(store.layers[0])
        XCTAssertEqual(try MapOverlayLoader.readGeoJSON(geoJSON, filename: "x.geojson").count, 1)

        let zipped = try store.exportShapefile(store.layers[0])
        XCTAssertGreaterThan(zipped.count, 0)
    }
}
