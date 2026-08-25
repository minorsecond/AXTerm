import XCTest
import MapKit
@testable import AXTerm

/// Tile arithmetic and the local store. This is where an offline map goes
/// silently wrong: a tile that renders in the wrong place still renders.
final class MapTileMathTests: XCTestCase {

    /// The whole world is one tile at zoom 0, and every coordinate is in it.
    func testZoomZeroIsASingleTile() {
        for (lat, lon) in [(0.0, 0.0), (60.0, -120.0), (-45.0, 170.0)] {
            let tile = MapTileMath.tile(latitude: lat, longitude: lon, zoom: 0)
            XCTAssertEqual(tile.x, 0, "\(lat),\(lon)")
            XCTAssertEqual(tile.y, 0, "\(lat),\(lon)")
        }
    }

    /// Null Island sits on the corner where all four zoom-1 tiles meet, which
    /// pins both the origin and the axis directions at once.
    func testOriginLandsOnTheExpectedQuadrant() {
        let tile = MapTileMath.tile(latitude: 0, longitude: 0, zoom: 1)
        XCTAssertEqual(tile.x, 1)
        XCTAssertEqual(tile.y, 1)
    }

    /// x grows eastward and y grows *southward*. Getting y backwards is the
    /// classic slippy-map bug and produces a map mirrored north-to-south —
    /// which on a bearing-and-range tool puts the ridge on the wrong side of
    /// the operator.
    func testAxesRunEastAndSouth() {
        let denver = MapTileMath.tile(latitude: 39.74, longitude: -104.99, zoom: 10)
        let east = MapTileMath.tile(latitude: 39.74, longitude: -100.00, zoom: 10)
        let south = MapTileMath.tile(latitude: 35.00, longitude: -104.99, zoom: 10)

        XCTAssertGreaterThan(east.x, denver.x)
        XCTAssertGreaterThan(south.y, denver.y)
    }

    /// Coordinates beyond Web Mercator's limit must clamp rather than
    /// producing an out-of-range tile the store would happily key on.
    func testPolarCoordinatesClampInsideTheGrid() {
        for zoom in [1, 8, 14] {
            let maximum = (1 << zoom) - 1
            for lat in [89.9, -89.9] {
                let tile = MapTileMath.tile(latitude: lat, longitude: 179.9, zoom: zoom)
                XCTAssertTrue((0...maximum).contains(tile.x), "z\(zoom) lat\(lat)")
                XCTAssertTrue((0...maximum).contains(tile.y), "z\(zoom) lat\(lat)")
            }
        }
    }

    /// A region's tile list must actually contain the region's own corners,
    /// or the download leaves gaps exactly at the edges the operator panned
    /// to see.
    func testRegionCoverageIncludesItsCorners() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99),
            span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.5))
        let tiles = Set(MapTileMath.tiles(covering: region, zoomRange: 10...10)
            .map { "\($0.z)/\($0.x)/\($0.y)" })

        let corners = [
            (39.74 + 0.5, -104.99 - 0.75), (39.74 + 0.5, -104.99 + 0.75),
            (39.74 - 0.5, -104.99 - 0.75), (39.74 - 0.5, -104.99 + 0.75),
        ]
        for (lat, lon) in corners {
            let tile = MapTileMath.tile(latitude: lat, longitude: lon, zoom: 10)
            XCTAssertTrue(tiles.contains("10/\(tile.x)/\(tile.y)"), "corner \(lat),\(lon) missing")
        }
    }

    /// Each extra zoom level roughly quadruples the count. The size estimate
    /// shown before a download depends on this being true, and an operator
    /// who is told "about 40 MB" and gets 4 GB will not trust the app again.
    func testEachZoomLevelRoughlyQuadruplesTheCount() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99),
            span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        let atTwelve = MapTileMath.tileCount(covering: region, zoomRange: 12...12)
        let atThirteen = MapTileMath.tileCount(covering: region, zoomRange: 13...13)

        let ratio = Double(atThirteen) / Double(atTwelve)
        XCTAssertGreaterThan(ratio, 3.0)
        XCTAssertLessThan(ratio, 5.0)
    }

    /// Coarse levels come first so an interrupted download leaves a blurry
    /// map of the whole area rather than a sharp patch and nothing around it.
    func testCoarseZoomLevelsAreFetchedFirst() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
        let zooms = MapTileMath.tiles(covering: region, zoomRange: 8...11).map(\.z)
        XCTAssertEqual(zooms, zooms.sorted())
    }
}

final class MapTileStoreTests: XCTestCase {

    private var url: URL!
    private var store: MapTileStore!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-tiles-\(UUID().uuidString).mbtiles")
        store = try MapTileStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    func testStoredTileReadsBackAtTheSameCoordinates() throws {
        let data = Data("tile-bytes".utf8)
        try store.store([(z: 12, x: 858, y: 1596, data: data)])

        XCTAssertEqual(try store.tile(z: 12, x: 858, y: 1596), data)
        XCTAssertTrue(try store.hasTile(z: 12, x: 858, y: 1596))
        XCTAssertNil(try store.tile(z: 12, x: 858, y: 1597))
    }

    /// MBTiles rows are bottom-up (TMS) while MapKit asks top-down (XYZ).
    /// The conversion must round-trip, and — critically — must not be the
    /// identity, or the file is not MBTiles and other tools will read it
    /// upside down.
    func testTMSConversionRoundTripsAndActuallyFlips() {
        for zoom in [0, 1, 8, 14] {
            let maximum = (1 << zoom) - 1
            for y in [0, maximum / 2, maximum] {
                let flipped = MapTileStore.tmsRow(y: y, zoom: zoom)
                XCTAssertEqual(MapTileStore.tmsRow(y: flipped, zoom: zoom), y, "z\(zoom) y\(y)")
                XCTAssertTrue((0...maximum).contains(flipped), "z\(zoom) y\(y)")
            }
        }
        // At zoom 1 the top row (0) must become the bottom row (1).
        XCTAssertEqual(MapTileStore.tmsRow(y: 0, zoom: 1), 1)
    }

    func testStoringTheSameTileTwiceReplacesRatherThanDuplicates() throws {
        try store.store([(z: 5, x: 1, y: 2, data: Data("first".utf8))])
        try store.store([(z: 5, x: 1, y: 2, data: Data("second".utf8))])

        XCTAssertEqual(try store.tile(z: 5, x: 1, y: 2), Data("second".utf8))
        XCTAssertEqual(try store.statistics().tileCount, 1)
    }

    func testStatisticsReportWhatIsActuallyStored() throws {
        try store.store([
            (z: 8, x: 1, y: 1, data: Data(repeating: 0, count: 100)),
            (z: 10, x: 2, y: 2, data: Data(repeating: 0, count: 200)),
        ])
        let stats = try store.statistics()

        XCTAssertEqual(stats.tileCount, 2)
        XCTAssertEqual(stats.byteSize, 300)
        XCTAssertEqual(stats.minimumZoom, 8)
        XCTAssertEqual(stats.maximumZoom, 10)
    }

    /// Deleting must actually free the space. An operator deletes a stored
    /// map to reclaim gigabytes, and a file that still occupies them has not
    /// done what they asked.
    func testDeletingEverythingEmptiesTheStore() throws {
        try store.store((0..<50).map { (z: 9, x: $0, y: 1, data: Data(repeating: 7, count: 512)) })
        XCTAssertEqual(try store.statistics().tileCount, 50)

        try store.removeAllTiles()

        XCTAssertEqual(try store.statistics().tileCount, 0)
        XCTAssertEqual(try store.statistics().byteSize, 0)
    }

    /// The paging used by an import must return every tile exactly once, in
    /// XYZ coordinates — a copy that drops or repeats tiles produces holes in
    /// the imported map that only show up in the field.
    func testStreamingAZoomLevelReturnsEveryTileOnce() throws {
        let expected = (0..<300).map { (z: 7, x: $0, y: 5, data: Data("t\($0)".utf8)) }
        try store.store(expected)

        var seen: [String: Data] = [:]
        try store.forEachTile(atZoom: 7, batchSize: 64) { batch in
            for tile in batch {
                XCTAssertNil(seen["\(tile.x)/\(tile.y)"], "tile repeated")
                seen["\(tile.x)/\(tile.y)"] = tile.data
            }
        }

        XCTAssertEqual(seen.count, expected.count)
        XCTAssertEqual(seen["42/5"], Data("t42".utf8))
    }

    func testMetadataRoundTrips() throws {
        try store.setMetadata("© OpenStreetMap contributors", for: "attribution")
        XCTAssertEqual(try store.metadata("attribution"), "© OpenStreetMap contributors")
        XCTAssertNil(try store.metadata("absent"))
    }
}

final class MapTileSourceTests: XCTestCase {

    /// Every source states its terms. A source that silently defaulted to
    /// "bulk download is fine" would have the app pulling tens of thousands
    /// of tiles from someone's donated hardware.
    func testEverySourceDeclaresItsTerms() {
        for source in MapTileSource.all {
            XCTAssertFalse(source.attribution.isEmpty, source.id)
            XCTAssertFalse(source.summary.isEmpty, source.id)
            if !source.permitsBulkDownload {
                XCTAssertNotNil(source.bulkDownloadNote, "\(source.id) refuses without saying why")
            }
        }
    }

    /// The community tile servers must be refused for bulk download. This is
    /// a term of service, not a preference, so it is asserted rather than
    /// left to a code review.
    func testCommunityTileServersRefuseBulkDownload() {
        XCTAssertFalse(MapTileSource.openStreetMap.permitsBulkDownload)
        XCTAssertFalse(MapTileSource.openTopo.permitsBulkDownload)
    }

    /// An imported file has no server to abuse, so it is the one source that
    /// is always allowed.
    func testImportedFilesAreAlwaysAllowed() {
        XCTAssertTrue(MapTileSource.imported.permitsBulkDownload)
        XCTAssertFalse(MapTileSource.imported.isNetworkBacked)
        XCTAssertNil(MapTileSource.imported.url(z: 1, x: 1, y: 1))
    }

    func testURLTemplateFillsEveryPlaceholder() throws {
        let url = try XCTUnwrap(MapTileSource.openTopo.url(z: 12, x: 858, y: 1596))
        let string = url.absoluteString
        XCTAssertTrue(string.hasSuffix("/12/858/1596.png"), string)
        XCTAssertFalse(string.contains("{"), "unfilled placeholder in \(string)")
    }

    /// The same tile must always resolve to the same host, or every
    /// intermediate cache misses and the provider serves three times the
    /// requests it needs to.
    func testSubdomainChoiceIsStable() {
        let first = MapTileSource.openTopo.url(z: 12, x: 858, y: 1596)
        let second = MapTileSource.openTopo.url(z: 12, x: 858, y: 1596)
        XCTAssertEqual(first, second)
    }
}

/// Async throughout: the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor`, and a synchronous test method on a `@MainActor` case is not
/// guaranteed to run on the main actor — constructing a main-actor object
/// from it trips the isolation check and the test dies with no message.
@MainActor
final class OfflineRegionDownloaderTests: XCTestCase {

    private func makeStore() throws -> MapTileStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-dl-\(UUID().uuidString).mbtiles")
        return try MapTileStore(url: url)
    }

    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))

    /// The rule that keeps this app a good citizen: a source whose terms
    /// forbid bulk download is refused before a single request is made, and
    /// the refusal carries the provider's own reason.
    func testASourceThatForbidsBulkDownloadIsRefusedWithItsReason() async throws {
        let downloader = OfflineRegionDownloader(store: try makeStore())
        downloader.download(region: region, zoomRange: 10...12, source: .openStreetMap)

        guard case .refused(let reason) = downloader.state else {
            return XCTFail("expected refusal, got \(downloader.state)")
        }
        XCTAssertTrue(reason.contains("bulk"), reason)
    }

    /// An imported source has no server; asking it to download is a mistake
    /// worth naming rather than a silent no-op.
    func testDownloadingFromAFileSourceFailsWithAnExplanation() async throws {
        let downloader = OfflineRegionDownloader(store: try makeStore())
        downloader.download(region: region, zoomRange: 10...12, source: .imported)

        guard case .failed(let message) = downloader.state else {
            return XCTFail("expected failure, got \(downloader.state)")
        }
        XCTAssertTrue(message.contains("Import"), message)
    }

    /// The estimate must be shown *before* committing, and must flag a
    /// download big enough to matter.
    func testEstimateFlagsLargeRegions() {
        let small = OfflineRegionDownloader.estimate(region: region, zoomRange: 10...12)
        XCTAssertFalse(small.isLarge)
        XCTAssertGreaterThan(small.tileCount, 0)

        let wide = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99),
            span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 8))
        XCTAssertTrue(OfflineRegionDownloader.estimate(region: wide, zoomRange: 8...14).isLarge)
    }

    /// Concurrency is deliberately low: these are shared community servers,
    /// and the difference between four connections and forty is nothing to
    /// the operator and a great deal to the provider.
    func testConcurrencyStaysPolite() {
        XCTAssertLessThanOrEqual(OfflineRegionDownloader.maximumConcurrentRequests, 6)
    }
}
