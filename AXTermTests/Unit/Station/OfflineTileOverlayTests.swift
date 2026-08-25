import XCTest
import MapKit
@testable import AXTerm

/// The overlay that serves stored tiles to MapKit, and the import path that
/// fills the store.
///
/// Both were previously exercised only through their refusal branches. The
/// parts that actually run in the field — the tile lookup, the offline
/// fallback, importing a file — were not, which is the wrong way round.
final class OfflineTileOverlayTests: XCTestCase {

    private var url: URL!
    private var store: MapTileStore!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-overlay-\(UUID().uuidString).mbtiles")
        store = try MapTileStore(url: url)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// A stored tile is served from disk. This is the whole point: with the
    /// network gone, this is the only path that produces a map.
    func testAStoredTileIsServedFromDisk() throws {
        let bytes = Data("tile".utf8)
        try store.store([(z: 10, x: 213, y: 389, data: bytes)])

        let overlay = OfflineTileOverlay(store: store, source: .imported)
        let expectation = expectation(description: "tile loaded")
        var received: Data?

        overlay.loadTile(at: MKTileOverlayPath(x: 213, y: 389, z: 10, contentScaleFactor: 1)) {
            data, _ in
            received = data
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(received, bytes)
    }

    /// A missing tile with no server behind it reports **nothing**, not an
    /// error. MapKit draws an empty square, which reads as "no data here" —
    /// the truth — rather than raising an alert the operator can do nothing
    /// about.
    func testAMissingTileWithNoServerReportsNothingRatherThanAnError() {
        let overlay = OfflineTileOverlay(store: store, source: .imported)
        let expectation = expectation(description: "tile resolved")
        var received: Data?
        var error: Error?

        overlay.loadTile(at: MKTileOverlayPath(x: 1, y: 1, z: 5, contentScaleFactor: 1)) {
            data, err in
            received = data
            error = err
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNil(received)
        XCTAssertNil(error, "a blank area is not an error condition")
    }

    /// `canReplaceMapContent` is what makes offline actually offline: without
    /// it MapKit draws its own basemap underneath and the map is blank in the
    /// field no matter how many tiles were stored.
    func testTheOverlayReplacesApplesBasemap() {
        let overlay = OfflineTileOverlay(store: store, source: .imported)
        XCTAssertTrue(overlay.canReplaceMapContent)
        XCTAssertEqual(overlay.maximumZ, MapTileSource.imported.maximumZoom)
        XCTAssertEqual(overlay.tileSize, CGSize(width: 256, height: 256))
    }

    /// The overlay clamps to what the provider actually has, so MapKit does
    /// not ask for zoom levels that return 404.
    func testTheOverlayClampsToTheSourceMaximumZoom() {
        XCTAssertEqual(OfflineTileOverlay(store: store, source: .usgsTopo).maximumZ, 16)
        XCTAssertEqual(OfflineTileOverlay(store: store, source: .usgsRelief).maximumZ, 13)
    }

    /// The lookup must go through the TMS conversion in both directions. A
    /// tile stored at XYZ (x, y) and read back at the same (x, y) proves the
    /// conversion is applied consistently — and reading the *unflipped* row
    /// must miss, or the store is not really MBTiles.
    func testTheOverlayReadsTilesBackThroughTheSameRowConvention() throws {
        try store.store([(z: 4, x: 3, y: 2, data: Data("a".utf8))])

        XCTAssertEqual(try store.tile(z: 4, x: 3, y: 2), Data("a".utf8))
        let flipped = MapTileStore.tmsRow(y: 2, zoom: 4)
        XCTAssertNotEqual(flipped, 2, "zoom 4 row 2 should not be its own mirror")
        XCTAssertNil(try store.tile(z: 4, x: 3, y: flipped),
                     "reading the raw stored row should miss")
    }
}

/// Importing an `.mbtiles` file.
@MainActor
final class OfflineRegionImportTests: XCTestCase {

    private var urls: [URL] = []

    private func makeStore() throws -> MapTileStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-import-\(UUID().uuidString).mbtiles")
        urls.append(url)
        return try MapTileStore(url: url)
    }

    override func tearDown() async throws {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
    }

    /// Waits for a **terminal** state, not merely "not busy".
    ///
    /// `importMBTiles` starts a task, so for the first instants the state is
    /// still `.idle` — waiting on `isBusy` returns immediately and reads the
    /// state from before the import began.
    private func settle(_ downloader: OfflineRegionDownloader) async {
        for _ in 0..<400 {
            switch downloader.state {
            case .finished, .failed, .refused: return
            default: try? await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTFail("import never reached a terminal state (last: \(downloader.state))")
    }

    /// The path an operator actually uses for coverage AXTerm cannot fetch
    /// itself: a file in, tiles usable offline.
    func testImportingCopiesEveryTile() async throws {
        let source = try makeStore()
        let tiles = (0..<40).map { (z: 8, x: $0, y: 5, data: Data("t\($0)".utf8)) }
        try source.store(tiles)
        try source.setMetadata("png", for: "format")

        let destination = try makeStore()
        let downloader = OfflineRegionDownloader(store: destination)
        downloader.importMBTiles(from: source.url)
        await settle(downloader)

        guard case .finished(let count, _) = downloader.state else {
            return XCTFail("expected finished, got \(downloader.state)")
        }
        XCTAssertEqual(count, 40)
        XCTAssertEqual(try destination.statistics().tileCount, 40)
        XCTAssertEqual(try destination.tile(z: 8, x: 17, y: 5), Data("t17".utf8))
    }

    /// The import must copy, not reference. On iOS the picked URL is a
    /// security-scoped loan that expires; on macOS the volume may be ejected.
    /// The map has to keep working after the source disappears.
    func testTheImportSurvivesTheSourceFileBeingDeleted() async throws {
        let source = try makeStore()
        try source.store([(z: 6, x: 1, y: 1, data: Data("kept".utf8))])

        let destination = try makeStore()
        let downloader = OfflineRegionDownloader(store: destination)
        downloader.importMBTiles(from: source.url)
        await settle(downloader)

        try FileManager.default.removeItem(at: source.url)
        XCTAssertEqual(try destination.tile(z: 6, x: 1, y: 1), Data("kept".utf8))
    }

    /// A vector `.mbtiles` holds compressed geometry, not images. Importing
    /// one would fill the store with tiles that draw nothing — an offline map
    /// that looks stored and is blank in the field, which is the worst
    /// possible outcome.
    func testAVectorFileIsRefusedByName() async throws {
        let source = try makeStore()
        try source.store([(z: 8, x: 1, y: 1, data: Data("pbf bytes".utf8))])
        try source.setMetadata("pbf", for: "format")

        let destination = try makeStore()
        let downloader = OfflineRegionDownloader(store: destination)
        downloader.importMBTiles(from: source.url)
        await settle(downloader)

        guard case .failed(let message) = downloader.state else {
            return XCTFail("expected failure, got \(downloader.state)")
        }
        XCTAssertTrue(message.contains("vector"), message)
        XCTAssertTrue(message.contains("pbf"), message)
        XCTAssertEqual(try destination.statistics().tileCount, 0,
                       "nothing should have been copied")
    }

    func testAFileWithNoTilesIsRefused() async throws {
        let source = try makeStore()
        let destination = try makeStore()
        let downloader = OfflineRegionDownloader(store: destination)

        downloader.importMBTiles(from: source.url)
        await settle(downloader)

        guard case .failed(let message) = downloader.state else {
            return XCTFail("expected failure, got \(downloader.state)")
        }
        XCTAssertTrue(message.contains("no map tiles"), message)
    }

    func testAnUnreadableFileIsReportedNotCrashed() async throws {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-not-a-db-\(UUID().uuidString).mbtiles")
        try Data("this is not sqlite".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        let downloader = OfflineRegionDownloader(store: try makeStore())
        downloader.importMBTiles(from: bogus)
        await settle(downloader)

        guard case .failed = downloader.state else {
            return XCTFail("expected failure, got \(downloader.state)")
        }
    }

    /// Attribution follows the tiles: an imported file's own credit must
    /// replace AXTerm's default, or the map credits the wrong producer.
    func testImportCarriesTheSourceAttribution() async throws {
        let source = try makeStore()
        try source.store([(z: 8, x: 1, y: 1, data: Data("t".utf8))])
        try source.setMetadata("© Someone Else", for: "attribution")

        let destination = try makeStore()
        let downloader = OfflineRegionDownloader(store: destination)
        downloader.importMBTiles(from: source.url)
        await settle(downloader)

        XCTAssertEqual(try destination.metadata("attribution"), "© Someone Else")
        XCTAssertEqual(try destination.metadata("axterm_source"), MapTileSource.imported.id)
    }

    /// Importing on top of existing tiles adds to them rather than wiping —
    /// an operator building coverage from two files must not lose the first.
    func testImportingASecondFileAddsToTheStore() async throws {
        let destination = try makeStore()
        try destination.store([(z: 8, x: 99, y: 99, data: Data("existing".utf8))])

        let source = try makeStore()
        try source.store([(z: 8, x: 1, y: 1, data: Data("new".utf8))])

        let downloader = OfflineRegionDownloader(store: destination)
        downloader.importMBTiles(from: source.url)
        await settle(downloader)

        XCTAssertEqual(try destination.tile(z: 8, x: 99, y: 99), Data("existing".utf8))
        XCTAssertEqual(try destination.tile(z: 8, x: 1, y: 1), Data("new".utf8))
    }
}
