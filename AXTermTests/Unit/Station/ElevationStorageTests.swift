import XCTest
import MapKit
@testable import AXTerm

/// What terrain a download is allowed to ask for.
///
/// These exist because the first version of the terrain button handed the
/// downloader a bounding box of every placed station. One far-off station
/// stretched that box across the country and it began fetching a strip of
/// one-degree tiles from Utah to Virginia — 34 of them, 143 MB, one polite
/// request at a time to a public USGS service. Nothing in the app noticed.
@MainActor
final class ElevationStorageTests: XCTestCase {

    private let denver = GreatCircle.Point(latitude: 39.74, longitude: -104.98)

    func testFetchesAtMostOneRingOfTilesAroundTheStation() {
        let tiles = ElevationStorage.tilesWorthFetching(around: denver)
        // A 2.2-degree span can straddle four one-degree tiles per axis in
        // the worst case, so sixteen is the ceiling and a dozen is typical.
        // The number that matters is that it does not scale with how far away
        // the furthest station happens to be.
        XCTAssertLessThanOrEqual(tiles.count, 16)
        XCTAssertFalse(tiles.isEmpty)
    }

    func testEveryFetchedTileTouchesTheStationsOwnNeighbourhood() {
        let tiles = ElevationStorage.tilesWorthFetching(around: denver)
        for tile in tiles {
            XCTAssertLessThanOrEqual(abs(Double(tile.lat) - denver.latitude), 2.5,
                                     "tile at \(tile.lat)/\(tile.lon) is nowhere near the station")
            XCTAssertLessThanOrEqual(abs(Double(tile.lon) - denver.longitude), 2.5,
                                     "tile at \(tile.lat)/\(tile.lon) is nowhere near the station")
        }
    }

    /// The station's own tile is the one a forecast always needs.
    func testTheStationsOwnTileIsIncluded() {
        let tiles = ElevationStorage.tilesWorthFetching(around: denver)
        let own = ElevationStore.tileIndex(for: denver)
        XCTAssertTrue(tiles.contains { $0.lat == own.lat && $0.lon == own.lon })
    }

    /// The radius is not arbitrary: past it, `PredictedPath` stops evaluating
    /// paths at all, so the tiles would answer nothing.
    func testRadiusMatchesTheRangeForecastsActuallyUse() {
        let degreesInKilometres = ElevationStorage.usefulRadiusDegrees * 111
        XCTAssertGreaterThanOrEqual(degreesInKilometres, 120)
        XCTAssertLessThan(degreesInKilometres, 200)
    }

    /// A continent-spanning region is exactly the input that caused the
    /// runaway, and `tiles(covering:)` is honest about how big it is — which
    /// is why the caller must never hand it one.
    func testABoundingBoxAcrossTheCountryIsEnormous() {
        let acrossTheCountry = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 38, longitude: -95),
            span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 34))
        XCTAssertGreaterThan(
            ElevationDownloader.tiles(covering: acrossTheCountry).count,
            ElevationDownloader.largeRegionTileCount,
            "a region this size must land well past the confirmation threshold")
    }

    func testEstimateCountsOnlyTilesNotAlreadyStored() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elev-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let storage = ElevationStorage(url: url)
        let before = storage.estimate(around: denver)
        XCTAssertEqual(before.tileCount,
                       ElevationStorage.tilesWorthFetching(around: denver).count)
        XCTAssertGreaterThan(before.byteCount, 0)

        // Store one of them and it drops out of the estimate.
        let own = ElevationStore.tileIndex(for: denver)
        try storage.store?.store(
            lat: own.lat, lon: own.lon,
            samples: ElevationStore.tileSamples,
            grid: [Float](repeating: 1600,
                          count: ElevationStore.tileSamples * ElevationStore.tileSamples))

        XCTAssertEqual(storage.estimate(around: denver).tileCount, before.tileCount - 1)
    }
}
