import XCTest
@testable import AXTerm

/// Decoding the elevation rasters USGS actually sends.
///
/// The fixture is a **real 3DEP response** (bbox −105,39 to −104,40 — the
/// Front Range and the plains east of Denver), not a synthetic file. That
/// matters: 3DEP returns *tiled* TIFFs whose tiles are padded beyond the
/// requested image size, and a reader written against a hand-made stripped
/// TIFF passes its own tests and then produces skewed terrain from live data.
///
/// Expected values were derived by decoding the fixture independently, and
/// cross-checked against the real world: the south-west corner is Front Range
/// foothills at ~2790 m, the north-east corner is plains at ~1444 m.
final class GeoTIFFReaderTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "usgs-3dep-64x64", withExtension: "tif"),
            "the USGS fixture is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    // MARK: - The real thing

    func testDecodesARealUSGSTile() throws {
        let grid = try GeoTIFFReader.floatGrid(from: try fixture(), expecting: 64)

        XCTAssertEqual(grid.count, 64 * 64)
        XCTAssertTrue(grid.allSatisfy(\.isFinite), "this tile is fully inside coverage")

        let minimum = try XCTUnwrap(grid.min())
        let maximum = try XCTUnwrap(grid.max())
        XCTAssertEqual(minimum, 1443.81, accuracy: 0.1)
        XCTAssertEqual(maximum, 2814.16, accuracy: 0.1)
    }

    /// Orientation is the whole game. A grid read upside down or mirrored
    /// gives a profile of terrain that exists — somewhere else.
    ///
    /// This tile spans the Front Range in the south-west to the plains in the
    /// north-east, so every corner is a different elevation and the four
    /// together pin the orientation completely.
    func testTheCornersProveTheOrientation() throws {
        let grid = try GeoTIFFReader.floatGrid(from: try fixture(), expecting: 64)
        let width = 64

        let northWest = grid[0]
        let northEast = grid[width - 1]
        let southWest = grid[(width - 1) * width]
        let southEast = grid[width * width - 1]

        XCTAssertEqual(northWest, 1588.44, accuracy: 0.1)
        XCTAssertEqual(northEast, 1443.81, accuracy: 0.1)
        XCTAssertEqual(southWest, 2790.45, accuracy: 0.1)
        XCTAssertEqual(southEast, 1863.51, accuracy: 0.1)

        // And the relationships, stated so a failure says what went wrong:
        // the mountains are to the south-west, the plains to the north-east.
        XCTAssertGreaterThan(southWest, northWest, "row order is inverted")
        XCTAssertGreaterThan(northWest, northEast, "column order is inverted")
    }

    /// Row-major, north row first — the order `ElevationStore` assumes.
    func testTheWesternEdgeIsHigherThanTheEastern() throws {
        let grid = try GeoTIFFReader.floatGrid(from: try fixture(), expecting: 64)
        let width = 64

        var westSum: Float = 0
        var eastSum: Float = 0
        for row in 0..<width {
            westSum += grid[row * width]
            eastSum += grid[row * width + width - 1]
        }
        let west = westSum / Float(width)
        let east = eastSum / Float(width)

        XCTAssertEqual(west, 1947, accuracy: 5)
        XCTAssertEqual(east, 1662, accuracy: 5)
        XCTAssertGreaterThan(west, east, "the Front Range is on the west side of this tile")
    }

    /// The image is 64×64 but arrives inside a padded 128×128 tile. Reading
    /// the buffer linearly would take the first 4096 floats — the top half of
    /// the tile — and produce terrain that is subtly, plausibly wrong.
    func testThePaddedTileIsUnpackedRatherThanReadLinearly() throws {
        let data = try fixture()
        let grid = try GeoTIFFReader.floatGrid(from: data, expecting: 64)

        // Row 1 of the image starts at sample 128 in the padded tile, not 64.
        // Comparing the two tells the readings apart.
        let tileOffset = 806
        func rawSample(_ index: Int) -> Float {
            let start = data.startIndex + tileOffset + index * 4
            let bits = data[start..<start + 4].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
            return Float(bitPattern: UInt32(littleEndian: bits))
        }

        XCTAssertEqual(grid[64], rawSample(128), accuracy: 0.001,
                       "the second image row must come from tile stride 128")
        XCTAssertNotEqual(grid[64], rawSample(64), accuracy: 0.001)
    }

    // MARK: - Refusing

    func testRejectsSomethingThatIsNotATIFF() {
        XCTAssertThrowsError(try GeoTIFFReader.floatGrid(
            from: Data(repeating: 0, count: 64), expecting: 64)) { error in
            XCTAssertEqual(error as? GeoTIFFReader.ReadError, .notATIFF)
        }
    }

    func testRejectsATruncatedFile() throws {
        let data = try fixture()
        XCTAssertThrowsError(try GeoTIFFReader.floatGrid(
            from: data.prefix(200), expecting: 64))
    }

    /// A tile of the wrong size is refused rather than stretched to fit: the
    /// grid's geographic bounds come from the request, so a mismatched size
    /// would silently misplace every sample.
    func testRejectsAWrongSizedTile() throws {
        XCTAssertThrowsError(try GeoTIFFReader.floatGrid(
            from: try fixture(), expecting: 1024)) { error in
            guard case GeoTIFFReader.ReadError.sizeMismatch(_, _, let expected) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(expected, 1024)
        }
    }

    /// Every refusal has to be explicable — an operator seeing "terrain
    /// unavailable" needs to know whether to retry or to stop trying.
    func testEveryErrorExplainsItself() {
        let errors: [GeoTIFFReader.ReadError] = [
            .notATIFF, .unsupported("compressed"),
            .sizeMismatch(width: 64, height: 64, expected: 1024), .truncated,
        ]
        for error in errors {
            XCTAssertGreaterThan(error.explanation.count, 20, "\(error)")
        }
    }

    // MARK: - End to end

    /// The real tile, stored and sampled back, produces sane elevations for
    /// known places. Denver sits at about 1609 m.
    func testARealTileSamplesBackToKnownElevations() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-dem-real-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try ElevationStore(url: url)
        let grid = try GeoTIFFReader.floatGrid(from: try fixture(), expecting: 64)
        try store.store(lat: 39, lon: -105, samples: 64, grid: grid)

        let sampler = StoredElevationSampler(store: store)
        // Denver, 39.74 N 104.99 W — the tile's resolution here is coarse, so
        // the tolerance is generous; the point is that it is not the plains
        // and not the summit.
        let denver = try XCTUnwrap(sampler.elevation(
            at: GreatCircle.Point(latitude: 39.74, longitude: -104.99)))
        XCTAssertEqual(denver, 1609, accuracy: 250)
    }
}
