import XCTest
import CoreLocation
@testable import AXTerm

/// Reading zip archives, and importing spatial data that arrived by radio.
final class ZipReaderTests: XCTestCase {

    /// The round trip that matters most: what AXTerm sends, AXTerm receives.
    /// Two stations exchanging a layer is the whole point of the feature.
    func testReadsWhatTheWriterProduced() throws {
        let files = [
            (name: "zones.shp", data: Data((0..<300).map { UInt8($0 % 251) })),
            (name: "zones.prj", data: Data(ShapefileWriter.wgs84WKT.utf8)),
        ]
        let archive = ZipWriter.archive(files: files)
        let entries = try ZipReader.entries(in: archive)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.name == "zones.shp" }?.data, files[0].data)
        XCTAssertEqual(entries.first { $0.name == "zones.prj" }?.data, files[1].data)
    }

    /// Real archives come from other tools, and those deflate. An agency's
    /// shapefile zip is not going to be stored-mode.
    func testReadsADeflatedArchiveFromTheSystemZip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-zipread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Highly compressible, so the system zip definitely deflates it.
        let payload = Data(String(repeating: "boundary,", count: 4000).utf8)
        try payload.write(to: directory.appendingPathComponent("big.txt"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "out.zip", "big.txt"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let archive = try Data(contentsOf: directory.appendingPathComponent("out.zip"))
        XCTAssertLessThan(archive.count, payload.count, "the system zip should have compressed it")

        let entries = try ZipReader.entries(in: archive)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "big.txt")
        XCTAssertEqual(entries[0].data, payload)
    }

    func testFindsAnEntryByExtension() throws {
        let archive = ZipWriter.archive(files: [
            (name: "a.dbf", data: Data("dbf".utf8)),
            (name: "a.shp", data: Data("shp".utf8)),
        ])
        XCTAssertEqual(try ZipReader.entry(in: archive, withExtension: "SHP")?.data,
                       Data("shp".utf8))
        XCTAssertNil(try ZipReader.entry(in: archive, withExtension: "prj"))
    }

    // MARK: - Refusing bad input

    func testRejectsSomethingThatIsNotAZip() {
        XCTAssertThrowsError(try ZipReader.entries(in: Data(repeating: 0, count: 400))) { error in
            XCTAssertEqual(error as? ZipReader.ReadError, .notAZip)
        }
        XCTAssertThrowsError(try ZipReader.entries(in: Data("short".utf8)))
    }

    /// A damaged archive must be refused, not half-read. This arrived over a
    /// radio link, so corruption is a normal outcome rather than an exotic
    /// one — and a boundary read from damaged bytes is a boundary in the
    /// wrong place.
    func testDetectsCorruptionByChecksum() throws {
        var archive = ZipWriter.archive(files: [
            (name: "a.txt", data: Data(repeating: 65, count: 200)),
        ])
        // Flip a byte in the payload, leaving the stored CRC intact.
        let index = archive.startIndex + 40
        archive[index] = archive[index] ^ 0xFF

        XCTAssertThrowsError(try ZipReader.entries(in: archive)) { error in
            guard case ZipReader.ReadError.checksumMismatch(let entry) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(entry, "a.txt")
            XCTAssertTrue((error as! ZipReader.ReadError).explanation.contains("damaged"))
        }
    }

    func testTruncationIsDetected() throws {
        let archive = ZipWriter.archive(files: [(name: "a.txt", data: Data(repeating: 65, count: 500))])
        // Removing the tail removes the end-of-directory record.
        XCTAssertThrowsError(try ZipReader.entries(in: archive.prefix(archive.count - 30)))
    }

    /// A zip bomb is a small archive that expands to gigabytes. This is data
    /// from a third party over the air, so the ceiling is deliberate.
    func testTheDecompressionCeilingIsModest() {
        XCTAssertLessThanOrEqual(ZipReader.maximumDecompressedBytes, 128 * 1024 * 1024)
    }

    func testAnEmptyArchiveReadsAsNoEntries() throws {
        XCTAssertTrue(try ZipReader.entries(in: ZipWriter.archive(files: [])).isEmpty)
    }
}

/// Turning a received attachment into a map layer.
final class MapOverlayAttachmentTests: XCTestCase {

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func sampleLayer(name: String = "Zones") -> MapOverlayLayer {
        MapOverlayLayer(id: "z.geojson", name: name,
                        features: [MapOverlayFeature(name: "Zone C",
                                                     geometry: .point(at(39.74, -104.99)))],
                        colorName: "blue")
    }

    // MARK: - Recognition

    /// Name-based, because it decides whether to *offer* the action —
    /// sniffing contents would mean parsing every attachment of every message
    /// on arrival.
    func testRecognisesTheFormatsItCanRead() {
        XCTAssertEqual(MapOverlayAttachment.kind(forAttachmentNamed: "zones.geojson"), .geoJSON)
        XCTAssertEqual(MapOverlayAttachment.kind(forAttachmentNamed: "ZONES.GeoJSON"), .geoJSON)
        XCTAssertEqual(MapOverlayAttachment.kind(forAttachmentNamed: "zones.json"), .geoJSON)
        XCTAssertEqual(MapOverlayAttachment.kind(forAttachmentNamed: "zones.shp"), .bareShapefile)
        XCTAssertEqual(MapOverlayAttachment.kind(forAttachmentNamed: "zones.zip"), .zippedShapefile)
        XCTAssertNil(MapOverlayAttachment.kind(forAttachmentNamed: "ICS213.txt"))
        XCTAssertNil(MapOverlayAttachment.kind(forAttachmentNamed: "photo.jpg"))
    }

    // MARK: - The round trip over the air

    /// Station A exports, station B receives. This is the feature.
    func testAGeoJSONAttachmentBecomesALayer() throws {
        let sent = try GeoJSONWriter.data(for: sampleLayer())
        let layer = try MapOverlayAttachment.layer(
            from: sent, named: "zones.geojson", senderCallsign: "w0arp", colorName: "blue")

        XCTAssertEqual(layer.features.count, 1)
        XCTAssertEqual(layer.features[0].name, "Zone C")
    }

    /// Provenance survives onto the map. Who drew a zone matters as much as
    /// where it is, and a boundary from somebody else must never be confused
    /// with the operator's own work.
    func testTheSenderIsNamedOnTheLayer() throws {
        let sent = try GeoJSONWriter.data(for: sampleLayer())
        let layer = try MapOverlayAttachment.layer(
            from: sent, named: "zones.geojson", senderCallsign: "w0arp", colorName: "blue")

        XCTAssertEqual(layer.name, "zones (from W0ARP)")
    }

    /// Two stations sending `zones.geojson` must not overwrite each other.
    func testStoredNamesAreDistinctPerSender() {
        let a = MapOverlayAttachment.storedName(for: "zones.geojson", from: "W0ARP")
        let b = MapOverlayAttachment.storedName(for: "zones.geojson", from: "KD0SSP")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".geojson"))
    }

    func testAZippedShapefileBecomesALayer() throws {
        let archive = try ShapefileWriter.zippedShapefile(layer: sampleLayer(name: "Zones"))
        let layer = try MapOverlayAttachment.layer(
            from: archive, named: "zones.zip", senderCallsign: "W0ARP", colorName: "blue")

        XCTAssertEqual(layer.features.count, 1)
    }

    func testABareShapefileBecomesALayer() throws {
        let shp = try XCTUnwrap(ShapefileWriter.components(layer: sampleLayer())["shp"])
        let layer = try MapOverlayAttachment.layer(
            from: shp, named: "zones.shp", senderCallsign: "W0ARP", colorName: "blue")

        XCTAssertEqual(layer.features.count, 1)
    }

    // MARK: - Refusing

    /// The projection inside the archive is honoured. A zipped shapefile in
    /// State Plane feet read as degrees would put the zone thousands of miles
    /// away, with no error — so it is refused by name instead.
    func testAProjectedShapefileInAnArchiveIsRefused() throws {
        let shp = try XCTUnwrap(ShapefileWriter.components(layer: sampleLayer())["shp"])
        let archive = ZipWriter.archive(files: [
            (name: "zones.shp", data: shp),
            (name: "zones.prj",
             data: Data(#"PROJCS["NAD_1983_StatePlane_Colorado_Central_FIPS_0502_Feet"]"#.utf8)),
        ])

        XCTAssertThrowsError(try MapOverlayAttachment.layer(
            from: archive, named: "zones.zip", senderCallsign: "W0ARP", colorName: "blue")) { error in
            guard case MapOverlayAttachment.ImportError.shapefile(let inner) = error else {
                return XCTFail("wrong error: \(error)")
            }
            guard case ShapefileReader.ReadError.unsupportedProjection(let name) = inner else {
                return XCTFail("wrong inner error: \(inner)")
            }
            XCTAssertTrue(name.contains("StatePlane"), name)
        }
    }

    func testAnAttachmentThatIsNotMapDataIsRefusedWithGuidance() {
        XCTAssertThrowsError(try MapOverlayAttachment.layer(
            from: Data("hello".utf8), named: "ICS213.txt",
            senderCallsign: "W0ARP", colorName: "blue")) { error in
            let text = (error as! MapOverlayAttachment.ImportError).explanation
            XCTAssertTrue(text.contains("GeoJSON"), text)
            XCTAssertTrue(text.contains(".shp"), text)
        }
    }

    /// Data from a third party over the air needs a ceiling that is not
    /// incidental.
    func testAnOversizedAttachmentIsRefusedBeforeParsing() {
        let huge = Data(count: MapOverlayAttachment.maximumBytes + 1)
        XCTAssertThrowsError(try MapOverlayAttachment.layer(
            from: huge, named: "zones.geojson",
            senderCallsign: "W0ARP", colorName: "blue")) { error in
            guard case MapOverlayAttachment.ImportError.tooLarge = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testDamagedGeoJSONIsRefusedNotPartiallyRead() {
        XCTAssertThrowsError(try MapOverlayAttachment.layer(
            from: Data(#"{"type":"FeatureCollection","featur"#.utf8),
            named: "zones.geojson", senderCallsign: "W0ARP", colorName: "blue"))
    }

    func testAnEmptyLayerIsRefused() throws {
        let empty = try GeoJSONWriter.data(for: MapOverlayLayer(
            id: "e.geojson", name: "Empty", features: [], colorName: "blue"))
        XCTAssertThrowsError(try MapOverlayAttachment.layer(
            from: empty, named: "empty.geojson",
            senderCallsign: "W0ARP", colorName: "blue")) { error in
            guard case MapOverlayAttachment.ImportError.empty = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}

/// The store side of receiving.
@MainActor
final class MapOverlayReceiveTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-receive-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample() throws -> Data {
        try GeoJSONWriter.data(for: MapOverlayLayer(
            id: "z.geojson", name: "Zones",
            features: [MapOverlayFeature(
                name: "Zone C",
                geometry: .point(CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99)))],
            colorName: "blue"))
    }

    /// A received layer persists like any other — it is on the map after a
    /// relaunch, which is when the operator will actually need it.
    func testAReceivedLayerSurvivesAReopen() async throws {
        let store = MapOverlayStore(directory: directory)
        XCTAssertNotNil(store.addFromAttachment(
            data: try sample(), filename: "zones.geojson", senderCallsign: "W0ARP"))

        let reopened = MapOverlayStore(directory: directory)
        XCTAssertEqual(reopened.layers.count, 1)
        XCTAssertTrue(reopened.layers[0].name.contains("W0ARP"))
    }

    /// Two stations sending the same filename produce two layers, not one
    /// silently overwriting the other.
    func testTwoSendersDoNotOverwriteEachOther() async throws {
        let store = MapOverlayStore(directory: directory)
        store.addFromAttachment(data: try sample(), filename: "zones.geojson", senderCallsign: "W0ARP")
        store.addFromAttachment(data: try sample(), filename: "zones.geojson", senderCallsign: "KD0SSP")

        XCTAssertEqual(store.layers.count, 2)
    }

    /// A refusal is reported and nothing is added — the operator must not be
    /// left thinking a boundary is on the map when it is not.
    func testARefusedAttachmentReportsAndAddsNothing() async throws {
        let store = MapOverlayStore(directory: directory)
        let result = store.addFromAttachment(
            data: Data("not map data".utf8), filename: "notes.txt", senderCallsign: "W0ARP")

        XCTAssertNil(result)
        XCTAssertTrue(store.layers.isEmpty)
        XCTAssertNotNil(store.lastError)
    }
}
