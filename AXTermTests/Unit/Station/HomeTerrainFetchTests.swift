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

    /// Asked once in the life of the install, not once per grid square.
    ///
    /// The operator is answering "should this app keep terrain for my area".
    /// That answer does not expire because they corrected a typo in their
    /// locator, refined four characters to six, or drove one square east — and
    /// re-asking on each of those is a nag, not a question.
    func testTheQuestionIsAskedOnceNotOncePerGridSquare() {
        let name = "HomeTerrainOffer.once"
        let defaults = freshDefaults(name)

        XCTAssertTrue(ask("DM79po", defaults))
        defaults.set(true, forKey: ElevationStorage.askedKey)

        for grid in ["DM79po", "DM79pp", "DM79", "DN70aa"] {
            XCTAssertFalse(ask(grid, defaults), "asked again for \(grid)")
        }
        defaults.removePersistentDomain(forName: name)
    }

    /// Declining is an answer about the behaviour, so it survives a move.
    /// Accepting likewise: a new square is fetched, not re-negotiated.
    func testEitherAnswerStandsAcrossAMove() {
        let name = "HomeTerrainOffer.stands"
        for (label, accepted) in [("declined", false), ("accepted", true)] {
            let defaults = freshDefaults(name)
            defaults.set(true, forKey: ElevationStorage.askedKey)
            defaults.set(accepted, forKey: ElevationStorage.autoFetchEnabledKey)

            XCTAssertFalse(ask("DN70aa", defaults), "\(label) should not re-ask")
            XCTAssertEqual(defaults.bool(forKey: ElevationStorage.autoFetchEnabledKey),
                           accepted, "\(label) should stand")
            defaults.removePersistentDomain(forName: name)
        }
    }

    /// Somewhere the source has nothing must not burn the one question. An
    /// operator abroad who later moves into coverage should still be asked.
    func testBeingOutsideCoverageDoesNotSpendTheQuestion() {
        let name = "HomeTerrainOffer.abroad"
        let defaults = freshDefaults(name)
        let copenhagen = GreatCircle.Point(latitude: 55.68, longitude: 12.57)

        XCTAssertFalse(ask("JO65fr", defaults, at: copenhagen))
        XCTAssertFalse(defaults.bool(forKey: ElevationStorage.askedKey),
                       "no question was put, so none was used up")
        XCTAssertTrue(ask("DM79po", defaults), "still owed a question in coverage")
        defaults.removePersistentDomain(forName: name)
    }

    /// Case is not an answer, and neither is stray whitespace.
    func testAGridIsNormalisedBeforeItIsJudged() {
        XCTAssertEqual(ElevationStorage.normalizedGrid(" dm79po "), "DM79PO")
        XCTAssertEqual(ElevationStorage.normalizedGrid(""), "")
        XCTAssertEqual(ElevationStorage.normalizedGrid("   "), "")
    }

    /// No grid, no question — and specifically not a question about wherever
    /// an empty locator happens to decode to.
    func testThereIsNoQuestionWithoutAGridSquare() {
        let name = "HomeTerrainOffer.nogrid"
        let defaults = freshDefaults(name)
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
