import MapKit
import XCTest
@testable import AXTerm

/// What the Offline Data sheet says while a download runs. Live, both
/// downloads looked dead: the region bar was off screen at the bottom of the
/// sheet, and the terrain bar sat empty at "0 of 9" for most of a minute
/// while the first multi-megabyte tile came in, then said nothing at the end.
@MainActor
final class DownloadProgressTests: XCTestCase {

    func testTerrainSaysWhichTileIsComingBeforeAnyIsDone() {
        let first = DownloadProgress.terrain(.downloading(completed: 0, total: 9))
        XCTAssertEqual(first?.text, "Fetching terrain tile 1 of 9…")
        XCTAssertNil(first?.fraction, "a spinner until a tile lands, not an empty bar")

        let fourth = DownloadProgress.terrain(.downloading(completed: 3, total: 9))
        XCTAssertEqual(fourth?.text, "Fetching terrain tile 4 of 9…")
        XCTAssertEqual(fourth?.fraction ?? 0, 3.0 / 9.0, accuracy: 0.0001)
    }

    func testTerrainSaysWhenItIsDone() {
        XCTAssertEqual(DownloadProgress.terrain(.finished(tiles: 9))?.text, "Stored 9 terrain tiles.")
        XCTAssertEqual(DownloadProgress.terrain(.finished(tiles: 1))?.text, "Stored 1 terrain tile.")
        XCTAssertEqual(DownloadProgress.terrain(.finished(tiles: 0))?.text, "Already stored. Nothing new to fetch.")
        XCTAssertTrue(DownloadProgress.terrain(.finished(tiles: 9))?.isDone == true)
        XCTAssertNil(DownloadProgress.terrain(.idle))
    }

    func testARegionSaysItHasStartedBeforeTheFirstTile() {
        let start = DownloadProgress.region(.downloading(completed: 0, total: 118))
        XCTAssertEqual(start?.text, "Starting: 118 tiles to fetch…")
        XCTAssertNil(start?.fraction)

        let partway = DownloadProgress.region(.downloading(completed: 40, total: 118))
        XCTAssertEqual(partway?.text, "40 of 118 tiles")
        XCTAssertEqual(partway?.fraction ?? 0, 40.0 / 118.0, accuracy: 0.0001)

        XCTAssertEqual(DownloadProgress.region(.estimating)?.text, "Working out what is needed…")
        XCTAssertEqual(DownloadProgress.region(.finished(tiles: 118, bytes: 2_400_000))?.text, "Stored 118 tiles.")
        XCTAssertNil(DownloadProgress.region(.idle))
    }

    /// USGS stops at z16; the stepper offered z18 and the estimate counted
    /// two levels the download then skipped.
    func testDetailStopsAtWhatTheSourceHas() {
        XCTAssertEqual(MapTileSource.usgsTopo.offeredZoom, 1...16)
        XCTAssertEqual(MapTileSource.usgsRelief.offeredZoom, 1...13)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.61, longitude: -104.73),
                                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        XCTAssertEqual(OfflineRegionDownloader.estimate(region: region, zoomRange: 1...18, source: .usgsTopo),
                       OfflineRegionDownloader.estimate(region: region, zoomRange: 1...16))
    }
}
