import XCTest
@testable import AXTerm

/// How an elevation tile is stored.
///
/// Tiles were raw Float32, four megabytes each. The compression is worth
/// having, but only if what comes back is what went in: a terrain forecast
/// built on quietly corrupted ground is worse than no forecast, because an
/// operator will believe it.
final class ElevationTileCodecTests: XCTestCase {

    /// Terrain shaped like terrain: smooth, with a ridge. Random noise would
    /// flatter neither the codec nor the test, since real ground is what this
    /// has to carry.
    private func terrain(samples: Int, seed: Double = 0) -> [Float] {
        (0..<(samples * samples)).map { index in
            let row = Double(index / samples), column = Double(index % samples)
            let base = 1_600 + 400 * sin((column + seed) / 90) + 250 * cos(row / 70)
            let ridge = 600 * exp(-pow((column - Double(samples) * 0.6) / 40, 2))
            return Float((base + ridge).rounded())
        }
    }

    // MARK: - What comes back

    /// Every sample, to the metre. The source is quantised to a metre long
    /// before it reaches here, so this is lossless for the data that exists.
    func testEverySampleSurvivesToTheMetre() throws {
        let samples = 128
        let original = terrain(samples: samples)
        let decoded = try ElevationTileCodec.decode(
            ElevationTileCodec.encode(original, samples: samples))

        XCTAssertEqual(decoded.samples, samples)
        XCTAssertEqual(decoded.grid.count, original.count)
        for (index, value) in original.enumerated() {
            XCTAssertEqual(decoded.grid[index], value, accuracy: 0.5,
                           "sample \(index)")
        }
    }

    /// The property TerrainProfile depends on. A gap read as sea level turns
    /// an unknown ridge into a clear path, which is the most dangerous
    /// possible way for this to be wrong.
    func testAGapStaysAGapRatherThanBecomingSeaLevel() throws {
        var grid = terrain(samples: 32)
        grid[100] = .nan
        grid[101] = .nan
        grid[500] = .nan

        let decoded = try ElevationTileCodec.decode(
            ElevationTileCodec.encode(grid, samples: 32))

        XCTAssertTrue(decoded.grid[100].isNaN)
        XCTAssertTrue(decoded.grid[101].isNaN)
        XCTAssertTrue(decoded.grid[500].isNaN)
        XCTAssertFalse(decoded.grid[99].isNaN, "a gap must not spread")
        XCTAssertFalse(decoded.grid[102].isNaN)
        XCTAssertEqual(decoded.grid[102], grid[102], accuracy: 0.5,
                       "and the row keeps its heights after it")
    }

    /// Real elevations, at both ends of what the United States has.
    func testTheRangeCoversTheGroundItHasToCarry() {
        for metres in [Float(-86), 0, 1_609, 4_421, 6_190] {
            XCTAssertEqual(Float(ElevationTileCodec.quantise(metres)), metres,
                           accuracy: 0.5, "\(metres) m")
        }
    }

    /// Anything outside a plausible elevation is unreadable rather than
    /// wrapped into a plausible-looking number.
    func testImpossibleValuesBecomeGapsNotWrongHeights() {
        for bad in [Float.infinity, -.infinity, .nan, 40_000, -40_000] {
            XCTAssertEqual(ElevationTileCodec.quantise(bad), ElevationTileCodec.noData,
                           "\(bad)")
        }
    }

    // MARK: - What it costs

    /// The point of the exercise, measured rather than assumed.
    func testATileGetsSubstantiallySmaller() throws {
        let samples = 256
        let grid = terrain(samples: samples)
        let raw = grid.count * MemoryLayout<Float>.size
        let encoded = try ElevationTileCodec.encode(grid, samples: samples).count

        XCTAssertLessThan(encoded, raw / 4,
                          "expected at least 4x; got \(raw) -> \(encoded)")
    }

    // MARK: - Telling the formats apart

    /// A raw Float32 tile from before the codec has to keep reading. Its
    /// first four bytes are an elevation as a little-endian float, which
    /// cannot spell AXEL for any plausible height.
    func testARawTileIsNotMistakenForAnEncodedOne() {
        for metres in [Float(-86), 0, 1_609, 4_421, 6_190] {
            let raw = [metres].withUnsafeBufferPointer { Data(buffer: $0) }
            XCTAssertFalse(ElevationTileCodec.isEncoded(raw), "\(metres) m")
        }
    }

    func testAnEncodedTileSaysSo() throws {
        let data = try ElevationTileCodec.encode(terrain(samples: 16), samples: 16)
        XCTAssertTrue(ElevationTileCodec.isEncoded(data))
    }

    /// Truncated or corrupt input throws rather than returning a grid of
    /// something. Half a tile of wrong ground is the failure this is here to
    /// prevent.
    func testCorruptInputFailsLoudly() throws {
        let good = try ElevationTileCodec.encode(terrain(samples: 16), samples: 16)

        XCTAssertThrowsError(try ElevationTileCodec.decode(good.prefix(12)))
        XCTAssertThrowsError(try ElevationTileCodec.decode(Data([1, 2, 3])))

        var corrupt = good
        corrupt.replaceSubrange(corrupt.count - 20..<corrupt.count,
                                with: Data(repeating: 0xFF, count: 20))
        XCTAssertThrowsError(try ElevationTileCodec.decode(corrupt))
    }
}

/// The codec through the store it exists for.
final class ElevationStoreCodecTests: XCTestCase {

    /// A tile written and read back is the same ground. The store is where a
    /// format mistake would actually bite, so the round trip is checked
    /// there and not only in the codec.
    func testAStoredTileComesBackUnchanged() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("elev-\(UUID().uuidString)")
            .appendingPathComponent("elevation.sqlite")
        let store = try ElevationStore(url: url)

        let samples = 64
        let grid = (0..<(samples * samples)).map { index -> Float in
            index % 977 == 0 ? .nan
                : Float(1_500 + 300 * sin(Double(index % samples) / 12))
        }
        try store.store(lat: 39, lon: -105, samples: samples, grid: grid)

        let read = try XCTUnwrap(try store.tile(lat: 39, lon: -105))
        XCTAssertEqual(read.samples, samples)
        for (index, value) in grid.enumerated() {
            if value.isNaN {
                XCTAssertTrue(read.grid[index].isNaN, "gap at \(index)")
            } else {
                XCTAssertEqual(read.grid[index], value, accuracy: 0.5, "sample \(index)")
            }
        }
    }
}
