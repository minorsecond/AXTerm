import XCTest
import CoreLocation
@testable import AXTerm

/// Writing shapefiles and GeoJSON.
///
/// Mostly round-trip tests: writing and reading back is the only check that
/// actually proves the bytes are right, because every mistake available here —
/// wrong endianness, wrong units, swapped coordinates — produces a file that
/// *looks* fine and is wrong.
final class ShapefileWriterTests: XCTestCase {

    private func layer(_ features: [MapOverlayFeature], name: String = "Test Layer")
        -> MapOverlayLayer {
        MapOverlayLayer(id: "test.geojson", name: name, features: features, colorName: "blue")
    }

    private func point(_ lon: Double, _ lat: Double, name: String = "") -> MapOverlayFeature {
        MapOverlayFeature(name: name,
                          geometry: .point(CLLocationCoordinate2D(latitude: lat, longitude: lon)))
    }

    // MARK: - Round trip through the reader

    /// The test that matters most: what the writer produces, the reader reads
    /// back identically. Both halves were written against the same spec, so
    /// this catches every symmetric mistake at once.
    func testPointsRoundTripThroughTheReader() throws {
        let source = layer([point(-104.99, 39.74), point(-105.5, 40.1), point(-103.0, 38.5)])
        let shp = try XCTUnwrap(ShapefileWriter.components(layer: source)["shp"])

        let read = try ShapefileReader.read(shp)
        XCTAssertEqual(read.count, 3)
        guard case .point(let first) = read[0] else { return XCTFail("expected a point") }
        XCTAssertEqual(first.longitude, -104.99, accuracy: 1e-9)
        XCTAssertEqual(first.latitude, 39.74, accuracy: 1e-9)
    }

    func testPolylinesRoundTrip() throws {
        let line = ShapefileReader.Geometry.polyline([
            [CLLocationCoordinate2D(latitude: 39, longitude: -105),
             CLLocationCoordinate2D(latitude: 39.5, longitude: -104)],
            [CLLocationCoordinate2D(latitude: 40, longitude: -103),
             CLLocationCoordinate2D(latitude: 40.5, longitude: -102.5),
             CLLocationCoordinate2D(latitude: 41, longitude: -102)],
        ])
        let shp = try XCTUnwrap(
            ShapefileWriter.components(layer: layer([MapOverlayFeature(geometry: line)]))["shp"])

        guard case .polyline(let parts) = try ShapefileReader.read(shp)[0] else {
            return XCTFail("expected a polyline")
        }
        XCTAssertEqual(parts.map(\.count), [2, 3])
        XCTAssertEqual(parts[1][2].longitude, -102, accuracy: 1e-9)
    }

    func testPolygonsWithHolesRoundTrip() throws {
        let outer = [(-105.0, 39.0), (-104.0, 39.0), (-104.0, 40.0), (-105.0, 40.0)]
            .map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) }
        let hole = [(-104.8, 39.2), (-104.6, 39.2), (-104.6, 39.4)]
            .map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) }

        let shp = try XCTUnwrap(ShapefileWriter.components(
            layer: layer([MapOverlayFeature(geometry: .polygon([outer, hole]))]))["shp"])

        guard case .polygon(let rings) = try ShapefileReader.read(shp)[0] else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings.count, 2, "the hole must survive, or a lake becomes solid ground")
        // Rings are closed on write, so each gains its first point back.
        XCTAssertEqual(rings[0].count, 5)
        XCTAssertEqual(rings[1].count, 4)
    }

    // MARK: - Winding

    /// A shapefile polygon's outer ring winds clockwise and its holes
    /// counter-clockwise; readers use the winding to tell them apart. A ring
    /// wound the wrong way becomes a hole, and the county disappears leaving a
    /// county-shaped gap.
    func testOuterRingsAreWoundClockwiseAndHolesTheOtherWay() throws {
        // Written counter-clockwise on purpose, so the writer must flip it.
        let counterClockwise = [(-105.0, 39.0), (-104.0, 39.0), (-104.0, 40.0), (-105.0, 40.0)]
            .map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) }

        let clockwise = ShapefileWriter.wound(counterClockwise, clockwise: true)
        XCTAssertEqual(clockwise.count, counterClockwise.count)
        XCTAssertNotEqual(clockwise.map(\.latitude), counterClockwise.map(\.latitude),
                          "a counter-clockwise ring should have been reversed")

        // Already clockwise: left alone rather than flipped back and forth.
        XCTAssertEqual(ShapefileWriter.wound(clockwise, clockwise: true).map(\.longitude),
                       clockwise.map(\.longitude))
    }

    func testWindingLeavesDegenerateRingsAlone() {
        let two = [CLLocationCoordinate2D(latitude: 39, longitude: -105),
                   CLLocationCoordinate2D(latitude: 40, longitude: -104)]
        XCTAssertEqual(ShapefileWriter.wound(two, clockwise: true).count, 2)
    }

    // MARK: - The other three files

    /// A `.shp` alone is not a shapefile. Delivering one without its index,
    /// attributes and projection produces something the recipient cannot open.
    func testEveryComponentFileIsProduced() throws {
        let parts = try ShapefileWriter.components(layer: layer([point(-105, 39, name: "Camp")]))
        XCTAssertEqual(Set(parts.keys), ["shp", "shx", "dbf", "prj"])
        for (name, data) in parts {
            XCTAssertGreaterThan(data.count, 0, "\(name) is empty")
        }
    }

    /// Without a `.prj` the numbers are just numbers, and a reader is free to
    /// assume whatever it likes. This is the file that keeps a boundary in
    /// Colorado rather than the Gulf of Guinea.
    func testTheProjectionFileDeclaresWGS84() throws {
        let parts = try ShapefileWriter.components(layer: layer([point(-105, 39)]))
        let prj = try XCTUnwrap(String(data: try XCTUnwrap(parts["prj"]), encoding: .utf8))
        XCTAssertTrue(prj.hasPrefix("GEOGCS"), prj)
        XCTAssertTrue(prj.contains("WGS_1984"), prj)
        // And the reader must accept what the writer produces.
        XCTAssertNoThrow(try ShapefileReader.validateProjection(prj))
    }

    /// The index gives a byte offset and length per record. Getting the units
    /// wrong — bytes instead of 16-bit words — produces an index that points
    /// into the middle of records.
    func testTheIndexOffsetsPointAtRealRecords() throws {
        let source = layer([point(-105, 39), point(-104, 40), point(-103, 41)])
        let parts = try ShapefileWriter.components(layer: source)
        let shx = try XCTUnwrap(parts["shx"])
        let shp = try XCTUnwrap(parts["shp"])

        XCTAssertEqual(shx.count, 100 + 3 * 8)

        for record in 0..<3 {
            let base = 100 + record * 8
            let offsetWords = Int(Int32(bigEndian: shx.int32(at: base)))
            let offsetBytes = offsetWords * 2
            // Each record header starts with its 1-based record number.
            let number = Int32(bigEndian: shp.int32(at: offsetBytes))
            XCTAssertEqual(number, Int32(record + 1),
                           "index entry \(record) does not point at record \(record + 1)")
        }
    }

    /// A shapefile declares one shape type in its header and every record
    /// must match. Mixing produces a file most readers reject, so it is
    /// refused with an explanation rather than written.
    func testMixedGeometryIsRefusedWithAnExplanation() {
        let mixed = layer([
            point(-105, 39),
            MapOverlayFeature(geometry: .polygon([[
                CLLocationCoordinate2D(latitude: 39, longitude: -105),
                CLLocationCoordinate2D(latitude: 39, longitude: -104),
                CLLocationCoordinate2D(latitude: 40, longitude: -104),
            ]])),
        ])
        XCTAssertThrowsError(try ShapefileWriter.components(layer: mixed)) { error in
            guard case ShapefileWriter.WriteError.mixedGeometryTypes = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue((error as! ShapefileWriter.WriteError).explanation.contains("GeoJSON"),
                          "the refusal should offer the format that does allow this")
        }
    }

    func testAnEmptyLayerIsRefused() {
        XCTAssertThrowsError(try ShapefileWriter.components(layer: layer([])))
    }

    // MARK: - Filenames

    /// dBASE and older GIS tools are unforgiving about spaces and
    /// punctuation, and a layer called "Evac Zone C (draft)" would produce a
    /// file some readers refuse to open.
    func testFilenamesAreMadeSafeForOldTools() {
        XCTAssertEqual(ShapefileWriter.safeStem("Evac Zone C (draft)"), "Evac_Zone_C__draft")
        XCTAssertEqual(ShapefileWriter.safeStem(""), "layer")
        XCTAssertEqual(ShapefileWriter.safeStem("___"), "layer")
        XCTAssertLessThanOrEqual(ShapefileWriter.safeStem(String(repeating: "a", count: 200)).count, 60)
    }
}

// MARK: - dBASE

final class DBFWriterTests: XCTestCase {

    func testFieldNamesAreUpperCasedAndCapped() {
        XCTAssertEqual(DBFWriter.fieldName("zone name"), "ZONE_NAME")
        XCTAssertEqual(DBFWriter.fieldName("a-very-long-attribute"), "A_VERY_LON")
        XCTAssertEqual(DBFWriter.fieldName("Évacuation"), "_VACUATION")
    }

    func testValuesArePaddedToAFixedWidth() {
        XCTAssertEqual(DBFWriter.padded("Camp").count, DBFWriter.fieldWidth)
        XCTAssertEqual(DBFWriter.padded("").count, DBFWriter.fieldWidth)
        XCTAssertEqual(DBFWriter.padded(String(repeating: "x", count: 500)).count,
                       DBFWriter.fieldWidth)
    }

    /// A dBASE III reader handed UTF-8 shows mojibake, so an accent is
    /// transliterated rather than passed through — the operator's note should
    /// still be readable on the other end.
    func testNonASCIIIsTransliteratedNotPassedThrough() throws {
        let padded = DBFWriter.padded("Café")
        let text = try XCTUnwrap(String(data: padded, encoding: .ascii))
        XCTAssertTrue(text.hasPrefix("Cafe"), text)
    }

    /// The header declares the record count and lengths; a reader trusts them
    /// absolutely and will read garbage if they are wrong.
    func testHeaderDeclaresTheRecordCountAndLengths() throws {
        let features = [
            MapOverlayFeature(name: "One", geometry: .point(.init(latitude: 39, longitude: -105)),
                              attributes: ["zone": "C"]),
            MapOverlayFeature(name: "Two", geometry: .point(.init(latitude: 40, longitude: -104)),
                              attributes: ["zone": "D"]),
        ]
        let dbf = DBFWriter.data(for: features)

        XCTAssertEqual(dbf[dbf.startIndex], 0x03, "dBASE III signature")
        let count = UInt32(littleEndian: dbf.uint32(at: 4))
        XCTAssertEqual(count, 2)

        let headerLength = Int(UInt16(littleEndian: dbf.uint16(at: 8)))
        let recordLength = Int(UInt16(littleEndian: dbf.uint16(at: 10)))
        // NAME plus ZONE.
        XCTAssertEqual(headerLength, 32 + 2 * 32 + 1)
        XCTAssertEqual(recordLength, 1 + 2 * DBFWriter.fieldWidth)
        XCTAssertEqual(dbf.count, headerLength + 2 * recordLength + 1)
    }
}

// MARK: - Zip

final class ZipWriterTests: XCTestCase {

    /// Verified against the system `unzip` rather than against my own reader:
    /// a self-consistent archive that no other tool accepts is worthless,
    /// since the whole point is handing the file to somebody else's GIS.
    func testTheArchiveIsReadableBySystemUnzip() throws {
        let files = [
            (name: "alpha.txt", data: Data("first file".utf8)),
            (name: "beta.bin", data: Data((0..<512).map { UInt8($0 % 251) })),
        ]
        let archive = ZipWriter.archive(files: files)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let zipURL = directory.appendingPathComponent("test.zip")
        try archive.write(to: zipURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "unzip rejected the archive")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("alpha.txt")),
                       files[0].data)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("beta.bin")),
                       files[1].data)
    }

    /// The CRC is what `unzip` checks; a wrong one fails the extraction above
    /// but this pins the value against the published test vector so a
    /// regression says *why*.
    func testCRC32MatchesTheKnownVector() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipWriter.crc32(Data()), 0)
    }

    func testAShapefileExportsAsAReadableArchive() throws {
        let layer = MapOverlayLayer(
            id: "marks.geojson", name: "My Marks",
            features: [MapOverlayFeature(name: "Camp",
                                         geometry: .point(.init(latitude: 39.74, longitude: -104.99)))],
            colorName: "blue")
        let archive = try ShapefileWriter.zippedShapefile(layer: layer)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-shp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let zipURL = directory.appendingPathComponent("marks.zip")
        try archive.write(to: zipURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        for ext in ["shp", "shx", "dbf", "prj"] {
            let file = directory.appendingPathComponent("My_Marks.\(ext)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "missing .\(ext)")
        }

        // And the extracted .shp still reads.
        let shp = try Data(contentsOf: directory.appendingPathComponent("My_Marks.shp"))
        XCTAssertEqual(try ShapefileReader.read(shp).count, 1)
    }
}

// MARK: - Byte reading

private extension Data {
    func int32(at offset: Int) -> Int32 {
        let start = startIndex + offset
        return self[start..<start + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    }

    func uint32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<start + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return self[start..<start + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }
}
