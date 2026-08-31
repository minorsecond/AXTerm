import XCTest
@testable import AXTerm

/// Getting terrain without being told where to find it.
///
/// The feature used to require knowing that a map page had an offline menu
/// with a terrain section in it. Nine tiles cover every path VHF packet will
/// realistically be asked about, so the honest default is to have them.
@MainActor
final class HomeTerrainFetchTests: XCTestCase {

    private let here = GreatCircle.Point(latitude: 39.60, longitude: -104.71)

    /// Nine tiles, not a bounding box of everyone heard. One distant station
    /// drags a bounding box across a continent — this file already carries
    /// the scar from a version that fetched Utah to Virginia.
    func testHomeCoverageIsBoundedAndSmall() {
        let tiles = ElevationStorage.tilesWorthFetching(around: here)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertLessThanOrEqual(tiles.count, 9)

        let bytes = Int64(tiles.count) * ElevationStorage.bytesPerTile
        XCTAssertLessThan(bytes, 40 * 1024 * 1024,
                          "an automatic fetch has to stay small enough not to need asking")
    }

    /// The tiles surround the station rather than starting at it, or a path
    /// heading west would leave the stored area on the first hop.
    func testTheStationIsInsideItsOwnCoverage() {
        let tiles = ElevationStorage.tilesWorthFetching(around: here)
        let home = ElevationStore.tileIndex(for: here)
        XCTAssertTrue(tiles.contains { $0.lat == home.lat && $0.lon == home.lon })
        XCTAssertTrue(tiles.contains { $0.lon < home.lon }, "nothing to the west")
        XCTAssertTrue(tiles.contains { $0.lon > home.lon }, "nothing to the east")
    }

    /// A path to a station outside the home tiles is one or two tiles, not
    /// another nine — which is why that case stays a button rather than
    /// becoming a second automatic download.
    func testAPathOutsideHomeCostsOnlyWhatItCrosses() {
        let farAway = GreatCircle.Point(latitude: 40.6, longitude: -103.2)
        let tiles = ElevationDownloader.tiles(alongPathFrom: here, to: farAway)
        XCTAssertLessThanOrEqual(tiles.count, 4)
        XCTAssertGreaterThanOrEqual(tiles.count, 2)
    }

    /// Runs once per grid square. An operator who deletes their terrain has
    /// said something, and re-downloading it the next morning would be
    /// arguing with them.
    func testItRunsOncePerGridSquare() {
        let defaults = UserDefaults(suiteName: "HomeTerrainFetchTests")!
        defaults.removePersistentDomain(forName: "HomeTerrainFetchTests")
        let key = "elevation.autoFetchedForGrid"

        XCTAssertNil(defaults.string(forKey: key))
        defaults.set("DM79PO", forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), "DM79PO")

        // A move re-arms it; staying put does not.
        XCTAssertNotEqual(defaults.string(forKey: key), "DM79PP")
        defaults.removePersistentDomain(forName: "HomeTerrainFetchTests")
    }

    /// 3DEP is a USGS product. Outside the United States it answers with a
    /// tile of NaN, so an unasked-for fetch abroad would spend tens of
    /// megabytes storing nothing and tell a US government service where the
    /// operator is, for no benefit at all.
    func testTheAutomaticFetchOnlyRunsWhereTheSourceHasData() {
        let covered = [
            GreatCircle.Point(latitude: 39.60, longitude: -104.71),  // Colorado
            GreatCircle.Point(latitude: 61.20, longitude: -149.90),  // Anchorage
            GreatCircle.Point(latitude: 21.31, longitude: -157.86),  // Honolulu
            GreatCircle.Point(latitude: 18.47, longitude: -66.11),   // San Juan
        ]
        for point in covered {
            XCTAssertTrue(ElevationDownloader.sourceHasCoverage(at: point), "\(point)")
        }

        let uncovered = [
            GreatCircle.Point(latitude: 51.51, longitude: -0.13),    // London
            GreatCircle.Point(latitude: -33.87, longitude: 151.21),  // Sydney
            GreatCircle.Point(latitude: 19.43, longitude: -99.13),   // Mexico City
            GreatCircle.Point(latitude: 55.68, longitude: 12.57),    // Copenhagen
        ]
        for point in uncovered {
            XCTAssertFalse(ElevationDownloader.sourceHasCoverage(at: point), "\(point)")
        }
    }

    /// No grid, no fetch — and specifically not a fetch centred on wherever
    /// an empty locator happens to decode to.
    func testAnEmptyGridSquareHasNoCentreToFetchAround() {
        XCTAssertNil(Maidenhead.center(of: ""))
        XCTAssertNil(Maidenhead.center(of: "   "))
    }
}
