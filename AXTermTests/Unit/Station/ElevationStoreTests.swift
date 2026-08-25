import XCTest
@testable import AXTerm

/// Storing and sampling elevation grids.
///
/// The dangerous mistakes here are all silent: a grid stored upside down, a
/// no-data gap read as sea level, a tile index that puts a negative longitude
/// in the wrong square. Each produces a path profile that looks entirely
/// reasonable and describes the wrong terrain.
final class ElevationStoreTests: XCTestCase {

    private var url: URL!
    private var store: ElevationStore!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-dem-\(UUID().uuidString).sqlite")
        store = try ElevationStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func point(_ lat: Double, _ lon: Double) -> GreatCircle.Point {
        GreatCircle.Point(latitude: lat, longitude: lon)
    }

    // MARK: - Tile indexing

    /// Floor, not truncation. `Int(-104.99)` is -104, which would put Denver
    /// in the tile to its east and read the wrong mountains.
    func testNegativeLongitudesFloorRatherThanTruncate() {
        let index = ElevationStore.tileIndex(for: point(39.74, -104.99))
        XCTAssertEqual(index.lat, 39)
        XCTAssertEqual(index.lon, -105)

        let bounds = ElevationStore.bounds(lat: index.lat, lon: index.lon)
        XCTAssertLessThanOrEqual(bounds.west, -104.99)
        XCTAssertGreaterThanOrEqual(bounds.east, -104.99)
    }

    func testTileBoundsCoverExactlyOneDegree() {
        let bounds = ElevationStore.bounds(lat: 39, lon: -105)
        XCTAssertEqual(bounds.south, 39)
        XCTAssertEqual(bounds.west, -105)
        XCTAssertEqual(bounds.north, 40)
        XCTAssertEqual(bounds.east, -104)
    }

    // MARK: - Storage

    func testAGridRoundTrips() throws {
        let grid = (0..<16).map { Float($0) }
        try store.store(lat: 39, lon: -105, samples: 4, grid: grid)

        XCTAssertTrue(try store.hasTile(lat: 39, lon: -105))
        let read = try XCTUnwrap(store.tile(lat: 39, lon: -105))
        XCTAssertEqual(read.samples, 4)
        XCTAssertEqual(read.grid, grid)
    }

    func testStatisticsReportWhatIsStored() throws {
        try store.store(lat: 39, lon: -105, samples: 4, grid: [Float](repeating: 1, count: 16))
        try store.store(lat: 40, lon: -105, samples: 4, grid: [Float](repeating: 2, count: 16))

        let stats = try store.statistics()
        XCTAssertEqual(stats.tileCount, 2)
        // Two 4×4 grids of 4-byte floats.
        XCTAssertEqual(stats.byteSize, 2 * 16 * 4)
    }

    func testDeletingEverythingEmptiesTheStore() throws {
        try store.store(lat: 39, lon: -105, samples: 4, grid: [Float](repeating: 1, count: 16))
        try store.removeAll()
        XCTAssertEqual(try store.statistics().tileCount, 0)
        XCTAssertNil(try store.tile(lat: 39, lon: -105))
    }

    // MARK: - Sampling

    /// Grids are stored north-row-first, the way every raster format writes
    /// them. Getting this inverted mirrors the terrain north to south — the
    /// same class of bug as the MBTiles row convention, and just as invisible.
    func testTheFirstRowIsTheNorthEdge() throws {
        // 2×2: north row is 100, south row is 0.
        try store.store(lat: 39, lon: -105, samples: 2, grid: [100, 100, 0, 0])
        let sampler = StoredElevationSampler(store: store)

        let north = try XCTUnwrap(sampler.elevation(at: point(39.99, -104.5)))
        let south = try XCTUnwrap(sampler.elevation(at: point(39.01, -104.5)))

        XCTAssertGreaterThan(north, south, "the first row must be the north edge")
        XCTAssertEqual(north, 100, accuracy: 2)
        XCTAssertEqual(south, 0, accuracy: 2)
    }

    /// West is the first column, east the last.
    func testTheFirstColumnIsTheWestEdge() throws {
        try store.store(lat: 39, lon: -105, samples: 2, grid: [0, 100, 0, 100])
        let sampler = StoredElevationSampler(store: store)

        let west = try XCTUnwrap(sampler.elevation(at: point(39.5, -104.99)))
        let east = try XCTUnwrap(sampler.elevation(at: point(39.5, -104.01)))

        XCTAssertLessThan(west, east)
    }

    /// Bilinear, not nearest neighbour: at ~100 m spacing nearest neighbour
    /// puts visible steps in a profile and can miss a ridge crest by half a
    /// sample.
    func testSamplingInterpolatesBetweenGridPoints() throws {
        try store.store(lat: 39, lon: -105, samples: 2, grid: [0, 100, 0, 100])
        let sampler = StoredElevationSampler(store: store)

        let middle = try XCTUnwrap(sampler.elevation(at: point(39.5, -104.5)))
        XCTAssertEqual(middle, 50, accuracy: 1, "halfway across should be halfway up")
    }

    /// A gap must stay a gap. Read as zero it becomes sea level, which turns
    /// an unknown mountain into a clear path — the most dangerous possible
    /// way to be wrong.
    func testANoDataSampleIsNilRatherThanZero() throws {
        try store.store(lat: 39, lon: -105, samples: 2,
                        grid: [ElevationStore.noDataValue, 100, 0, 100])
        let sampler = StoredElevationSampler(store: store)

        // Near the no-data corner, interpolation would involve the gap.
        XCTAssertNil(sampler.elevation(at: point(39.99, -104.99)))
        XCTAssertFalse(ElevationStore.noDataValue.isFinite,
                       "the marker must not be a plausible elevation")
    }

    func testAMissingTileSamplesAsNil() {
        let sampler = StoredElevationSampler(store: store)
        XCTAssertNil(sampler.elevation(at: point(0, 0)))
    }

    /// The gap propagates all the way to the verdict, rather than being
    /// smoothed over somewhere in between.
    func testAGapInTheStoreProducesNoPathVerdict() throws {
        try store.store(lat: 39, lon: -105, samples: 2, grid: [1600, 1600, 1600, 1600])
        // The neighbouring tile is absent, so a path crossing into it has a
        // hole in the middle.
        let sampler = StoredElevationSampler(store: store)

        let profile = TerrainProfile.between(
            origin: point(39.5, -104.9), destination: point(39.5, -103.5),
            originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000, sampler: sampler)

        guard case .unknown = profile.verdict else {
            return XCTFail("expected unknown, got \(profile.verdict)")
        }
    }

    /// A real profile, end to end, over stored terrain.
    func testAProfileCanBeComputedFromStoredTerrain() throws {
        // Flat 1600 m tile.
        try store.store(lat: 39, lon: -105, samples: 8,
                        grid: [Float](repeating: 1600, count: 64))
        let sampler = StoredElevationSampler(store: store)

        let profile = TerrainProfile.between(
            origin: point(39.2, -104.9), destination: point(39.3, -104.8),
            originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000, sampler: sampler)

        XCTAssertFalse(profile.samples.isEmpty)
        XCTAssertEqual(profile.samples.first?.groundElevation ?? 0, 1600, accuracy: 1)
        // A short path over flat ground: line of sight exists.
        switch profile.verdict {
        case .clear, .marginal: break
        default: XCTFail("unexpected verdict: \(profile.verdict)")
        }
    }

    /// The tile size has to stay something an operator can actually download
    /// on a field connection.
    func testATileIsAReasonableSize() {
        let bytes = ElevationStore.tileSamples * ElevationStore.tileSamples * 4
        XCTAssertLessThanOrEqual(bytes, 8 * 1024 * 1024, "a tile should stay a few MB")
        // And fine enough to see the ridges that decide a VHF path: roughly
        // 100 m per sample at mid-latitudes.
        let metresPerSample = 111_000.0 / Double(ElevationStore.tileSamples)
        XCTAssertLessThan(metresPerSample, 150)
    }
}
