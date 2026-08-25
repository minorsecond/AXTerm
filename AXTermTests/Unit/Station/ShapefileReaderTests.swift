import XCTest
import CoreLocation
@testable import AXTerm

/// Reading ESRI shapefiles.
///
/// Binary format tests are built from bytes rather than fixtures so the
/// endianness and offsets are visible in the test itself — a shapefile mixes
/// big- and little-endian in one record, and a fixture would hide which is
/// which.
final class ShapefileReaderTests: XCTestCase {

    // MARK: - Building test files

    private func header(shapeType: Int32) -> Data {
        var data = Data()
        data.append(bigEndian: Int32(9994))          // magic
        for _ in 0..<5 { data.append(bigEndian: Int32(0)) }   // unused
        data.append(bigEndian: Int32(0))             // file length
        data.append(littleEndian: Int32(1000))       // version
        data.append(littleEndian: shapeType)
        for _ in 0..<8 { data.append(littleEndian: Double(0)) } // bounding box
        XCTAssertEqual(data.count, 100)
        return data
    }

    /// Content length is in **16-bit words**, not bytes — the detail that has
    /// broken every naive shapefile reader ever written.
    private func record(number: Int32, content: Data) -> Data {
        var data = Data()
        data.append(bigEndian: number)
        data.append(bigEndian: Int32(content.count / 2))
        data.append(content)
        return data
    }

    private func pointContent(lon: Double, lat: Double) -> Data {
        var data = Data()
        data.append(littleEndian: Int32(1))
        data.append(littleEndian: lon)
        data.append(littleEndian: lat)
        return data
    }

    private func polyContent(type: Int32, parts: [[(Double, Double)]]) -> Data {
        var data = Data()
        data.append(littleEndian: type)
        for _ in 0..<4 { data.append(littleEndian: Double(0)) }   // bbox
        data.append(littleEndian: Int32(parts.count))
        data.append(littleEndian: Int32(parts.reduce(0) { $0 + $1.count }))

        var start: Int32 = 0
        for part in parts {
            data.append(littleEndian: start)
            start += Int32(part.count)
        }
        for part in parts {
            for (lon, lat) in part {
                data.append(littleEndian: lon)
                data.append(littleEndian: lat)
            }
        }
        return data
    }

    // MARK: - Geometry

    func testReadsPoints() throws {
        var file = header(shapeType: 1)
        file.append(record(number: 1, content: pointContent(lon: -104.99, lat: 39.74)))

        let shapes = try ShapefileReader.read(file)
        XCTAssertEqual(shapes.count, 1)
        guard case .point(let coordinate) = shapes[0] else { return XCTFail("expected a point") }
        XCTAssertEqual(coordinate.longitude, -104.99, accuracy: 1e-9)
        XCTAssertEqual(coordinate.latitude, 39.74, accuracy: 1e-9)
    }

    /// x is longitude and y is latitude, in that order in the file. Swapping
    /// them puts a Colorado county off the coast of Somalia — and produces no
    /// error at all, which is why this is asserted rather than assumed.
    func testCoordinateOrderIsLongitudeThenLatitude() throws {
        var file = header(shapeType: 1)
        file.append(record(number: 1, content: pointContent(lon: -104.99, lat: 39.74)))

        guard case .point(let coordinate) = try ShapefileReader.read(file)[0] else {
            return XCTFail("expected a point")
        }
        XCTAssertLessThan(coordinate.longitude, 0, "longitude should be the negative one here")
        XCTAssertGreaterThan(coordinate.latitude, 0)
    }

    func testReadsAMultiPartPolyline() throws {
        var file = header(shapeType: 3)
        file.append(record(number: 1, content: polyContent(type: 3, parts: [
            [(-105.0, 39.0), (-104.0, 39.5)],
            [(-103.0, 40.0), (-102.5, 40.5), (-102.0, 41.0)],
        ])))

        guard case .polyline(let parts) = try ShapefileReader.read(file)[0] else {
            return XCTFail("expected a polyline")
        }
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].count, 2)
        XCTAssertEqual(parts[1].count, 3)
        XCTAssertEqual(parts[1][2].longitude, -102.0, accuracy: 1e-9)
    }

    /// A polygon with a hole: the first ring is the boundary, the rest are
    /// holes. Dropping the second ring draws a solid county over a lake.
    func testReadsAPolygonWithAHole() throws {
        var file = header(shapeType: 5)
        file.append(record(number: 1, content: polyContent(type: 5, parts: [
            [(-105.0, 39.0), (-104.0, 39.0), (-104.0, 40.0), (-105.0, 40.0), (-105.0, 39.0)],
            [(-104.8, 39.2), (-104.6, 39.2), (-104.6, 39.4), (-104.8, 39.2)],
        ])))

        guard case .polygon(let rings) = try ShapefileReader.read(file)[0] else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(rings.count, 2)
        XCTAssertEqual(rings[0].count, 5)
        XCTAssertEqual(rings[1].count, 4)
    }

    func testReadsSeveralRecords() throws {
        var file = header(shapeType: 1)
        for (index, lon) in [-105.0, -104.0, -103.0].enumerated() {
            file.append(record(number: Int32(index + 1),
                               content: pointContent(lon: lon, lat: 39.0)))
        }
        XCTAssertEqual(try ShapefileReader.read(file).count, 3)
    }

    /// A null shape is a legal record meaning "no geometry here" — skipped,
    /// not an error, or a file with one gap in it would fail entirely.
    func testNullShapesAreSkippedNotRejected() throws {
        var file = header(shapeType: 1)
        var nullContent = Data()
        nullContent.append(littleEndian: Int32(0))
        file.append(record(number: 1, content: nullContent))
        file.append(record(number: 2, content: pointContent(lon: -105.0, lat: 39.0)))

        XCTAssertEqual(try ShapefileReader.read(file).count, 1)
    }

    /// Z and M variants carry elevation or measure values after the
    /// coordinates but lay x/y out identically. A county boundary with
    /// elevations is still a county boundary.
    func testZVariantsReadAsTheirTwoDimensionalEquivalent() throws {
        var file = header(shapeType: 15)
        file.append(record(number: 1, content: polyContent(type: 15, parts: [
            [(-105.0, 39.0), (-104.0, 39.0), (-104.0, 40.0), (-105.0, 39.0)],
        ])))

        guard case .polygon(let rings) = try ShapefileReader.read(file)[0] else {
            return XCTFail("expected a polygon from a polygonZ")
        }
        XCTAssertEqual(rings[0].count, 4)
    }

    // MARK: - Refusing rather than half-drawing

    func testRejectsAFileThatIsNotAShapefile() {
        var file = Data()
        file.append(bigEndian: Int32(1234))
        file.append(Data(repeating: 0, count: 200))

        XCTAssertThrowsError(try ShapefileReader.read(file)) { error in
            guard case ShapefileReader.ReadError.notAShapefile = error else {
                return XCTFail("wrong error: \(error)")
            }
            // The message must say what to open instead — an operator handed a
            // .zip does not know which file inside it is the one.
            XCTAssertTrue((error as! ShapefileReader.ReadError).explanation.contains(".shp"))
        }
    }

    func testRejectsAFileTooShortToHaveAHeader() {
        XCTAssertThrowsError(try ShapefileReader.read(Data(repeating: 0, count: 20))) { error in
            XCTAssertEqual(error as? ShapefileReader.ReadError, .tooShort)
        }
    }

    /// A record that runs off the end stops the read. A partially-drawn
    /// evacuation boundary is indistinguishable from a complete one, and
    /// somebody may plan around it.
    func testATruncatedRecordStopsTheRead() {
        var file = header(shapeType: 1)
        var truncated = record(number: 1, content: pointContent(lon: -105, lat: 39))
        truncated.removeLast(6)
        file.append(truncated)

        XCTAssertThrowsError(try ShapefileReader.read(file)) { error in
            guard case ShapefileReader.ReadError.truncatedRecord = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testUnsupportedGeometryIsNamedRatherThanSkipped() {
        var file = header(shapeType: 31)
        var content = Data()
        content.append(littleEndian: Int32(31))
        content.append(Data(repeating: 0, count: 40))
        file.append(record(number: 1, content: content))

        XCTAssertThrowsError(try ShapefileReader.read(file)) { error in
            guard case ShapefileReader.ReadError.unsupportedShapeType(_, let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "multipatch geometry")
        }
    }

    // MARK: - Projection

    /// The dangerous one. A shapefile carries no coordinate system in the
    /// .shp — the numbers are just numbers. Reading State Plane feet as
    /// degrees puts every feature in the Gulf of Guinea, silently.
    func testAProjectedCoordinateSystemIsRefused() {
        let statePlane = """
        PROJCS["NAD_1983_StatePlane_Colorado_Central_FIPS_0502_Feet",GEOGCS["GCS_North_American_1983"]]
        """
        XCTAssertThrowsError(try ShapefileReader.validateProjection(statePlane)) { error in
            guard case ShapefileReader.ReadError.unsupportedProjection(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(name.contains("StatePlane"), name)
        }
    }

    func testGeographicWGS84AndNAD83AreAccepted() throws {
        try ShapefileReader.validateProjection(
            #"GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984"]]"#)
        try ShapefileReader.validateProjection(
            #"GEOGCS["GCS_North_American_1983",DATUM["D_North_American_1983",NAD83]]"#)
    }

    /// Most agency downloads have no .prj at all, and are lat/lon. Refusing
    /// them would reject the common case; a wrong projection makes itself
    /// obvious the moment nothing appears where it should.
    func testAMissingProjectionFileIsAccepted() throws {
        try ShapefileReader.validateProjection(nil)
        try ShapefileReader.validateProjection("")
    }
}

// MARK: - Byte helpers

private extension Data {
    mutating func append(bigEndian value: Int32) {
        var raw = value.bigEndian
        append(Data(bytes: &raw, count: 4))
    }

    mutating func append(littleEndian value: Int32) {
        var raw = value.littleEndian
        append(Data(bytes: &raw, count: 4))
    }

    mutating func append(littleEndian value: Double) {
        var raw = value.bitPattern.littleEndian
        append(Data(bytes: &raw, count: 8))
    }
}
