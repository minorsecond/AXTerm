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

    // MARK: - Being asked rather than told

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func ask(_ grid: String, _ defaults: UserDefaults,
                     at point: GreatCircle.Point? = nil) -> Bool {
        ElevationStorage.shouldAskAboutHomeTerrain(
            gridSquare: grid, observer: point ?? here, defaults: defaults)
    }

    /// Asked once. Not asked again after either answer — a modal that
    /// reappears every launch is not a question, it is a demand.
    func testAnAnswerIsRememberedPerGridSquare() {
        let name = "HomeTerrainOffer.remembered"
        let defaults = freshDefaults(name)

        XCTAssertTrue(ask("DM79po", defaults),
                      "no answer on file means the question is still live")

        defaults.set("declined", forKey: ElevationStorage.decisionKey("DM79PO"))
        XCTAssertFalse(ask("DM79po", defaults), "declining has to stick")

        // A move is a new question: different ground, different answer.
        XCTAssertTrue(ask("DM79pp", defaults))
        defaults.removePersistentDomain(forName: name)
    }

    /// Case is not an answer. "dm79po" and "DM79PO" are the same square, and
    /// keying the decision on the raw string would re-ask on a re-typed grid.
    func testTheDecisionIsNotCaseSensitive() {
        let name = "HomeTerrainOffer.case"
        let defaults = freshDefaults(name)

        defaults.set("declined", forKey: ElevationStorage.decisionKey(
            ElevationStorage.normalizedGrid("dm79po ")))
        XCTAssertFalse(ask("DM79PO", defaults))
        XCTAssertFalse(ask(" dm79po", defaults))
        defaults.removePersistentDomain(forName: name)
    }

    /// Switched off means never ask, which is a different thing from having
    /// answered — and it is checked first, so turning it back on asks again.
    func testTheSettingSuppressesTheQuestionEntirely() {
        let name = "HomeTerrainOffer.disabled"
        let defaults = freshDefaults(name)

        defaults.set(false, forKey: ElevationStorage.autoFetchEnabledKey)
        XCTAssertFalse(ask("DM79po", defaults))

        defaults.set(true, forKey: ElevationStorage.autoFetchEnabledKey)
        XCTAssertTrue(ask("DM79po", defaults))
        defaults.removePersistentDomain(forName: name)
    }

    /// Nothing to ask about outside the source's coverage, and nothing to ask
    /// about with no grid set.
    func testThereIsNoQuestionWhenThereIsNothingToOffer() {
        let name = "HomeTerrainOffer.nothing"
        let defaults = freshDefaults(name)

        let copenhagen = GreatCircle.Point(latitude: 55.68, longitude: 12.57)
        XCTAssertFalse(ask("JO65fr", defaults, at: copenhagen))
        XCTAssertFalse(ask("", defaults))
        XCTAssertFalse(ask("   ", defaults))
        defaults.removePersistentDomain(forName: name)
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
