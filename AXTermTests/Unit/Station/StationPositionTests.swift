import XCTest
@testable import AXTerm

/// Choosing a position, and knowing what it is worth.
final class StationPositionTests: XCTestCase {

    private let denver = GreatCircle.Point(latitude: 39.74, longitude: -104.99)
    private let aurora = GreatCircle.Point(latitude: 39.70, longitude: -104.70)

    private func candidates(
        _ build: (inout StationPositionResolver.Candidates) -> Void
    ) -> StationPositionResolver.Candidates {
        var c = StationPositionResolver.Candidates()
        build(&c)
        return c
    }

    /// Best available, by accuracy, using the type's own ordering so a source
    /// added later cannot quietly land in the wrong place.
    func testTheBestAvailableSourceWins() {
        let resolved = StationPositionResolver.resolve(candidates {
            $0.gridSquare = denver
            $0.licenceAddress = denver
            $0.deviceGPS = aurora
        })
        XCTAssertEqual(resolved?.source, .deviceGPS)
        XCTAssertEqual(resolved?.point, aurora)
    }

    /// With only a grid square, that is the answer, and it says how coarse
    /// it is rather than pretending otherwise.
    func testAGridSquareIsUsedAndAdmitsItsError() throws {
        let resolved = try XCTUnwrap(StationPositionResolver.resolve(candidates {
            $0.gridSquare = denver
        }))
        XCTAssertEqual(resolved.source, .gridSquare)
        XCTAssertGreaterThan(resolved.accuracyMetres, 4_000)
        XCTAssertTrue(resolved.summary.contains("Grid centre"))
        XCTAssertTrue(resolved.summary.contains("km"))
    }

    func testNothingKnownIsNoPositionRatherThanAGuess() {
        XCTAssertNil(StationPositionResolver.resolve(candidates { _ in }))
    }

    // MARK: - Doubts

    /// A PO box makes the licence coordinate a post office, and the position
    /// has to carry that where it is relied on.
    func testAMailboxDemotesTheLicenceCoordinate() throws {
        let resolved = try XCTUnwrap(StationPositionResolver.resolve(candidates {
            $0.licenceAddress = denver
            $0.licenceStreet = "PO BOX 412"
        }))
        XCTAssertEqual(resolved.doubts, [.postOfficeBox])
        XCTAssertGreaterThanOrEqual(resolved.accuracyMetres, 5_000,
                                    "a post office is not worth 2 km")
    }

    func testASharedCoordinateIsDoubtedToo() throws {
        let resolved = try XCTUnwrap(StationPositionResolver.resolve(candidates {
            $0.licenceAddress = denver
            $0.sharedWith = 2
        }))
        XCTAssertEqual(resolved.doubts, [.sharedWithOthers(count: 2)])
    }

    /// A surveyed position is not a post office because the licence happens
    /// to be one. The doubt belongs to the coordinate it is about.
    func testDoubtsDoNotFollowABetterSource() throws {
        let resolved = try XCTUnwrap(StationPositionResolver.resolve(candidates {
            $0.surveyed = aurora
            $0.licenceAddress = denver
            $0.licenceStreet = "PO BOX 412"
            $0.sharedWith = 3
        }))
        XCTAssertEqual(resolved.source, .surveyed)
        XCTAssertTrue(resolved.doubts.isEmpty)
        XCTAssertLessThan(resolved.accuracyMetres, 50)
    }

    // MARK: - Whether a path is worth profiling

    /// The measurement that started this: a grid centre is good to 4.3 km,
    /// and the operator's shortest working paths are 6 to 11 km. Terrain
    /// under an origin that uncertain is not the terrain being flown over.
    func testAShortPathFromAGridCentreIsNotWorthProfiling() throws {
        let grid = try XCTUnwrap(StationPositionResolver.resolve(candidates {
            $0.gridSquare = denver
        }))
        XCTAssertFalse(grid.isUsable(forPathOf: 6_000), "6 km from a 4.3 km origin")
        XCTAssertFalse(grid.isUsable(forPathOf: 8_000))
        XCTAssertTrue(grid.isUsable(forPathOf: 40_000), "40 km survives it")
    }

    /// A recorded antenna makes even a short path answerable, which is the
    /// argument for recording one.
    func testASurveyedOriginMakesShortPathsAnswerable() throws {
        let surveyed = try XCTUnwrap(StationPositionResolver.resolve(candidates {
            $0.surveyed = denver
        }))
        XCTAssertTrue(surveyed.isUsable(forPathOf: 1_000))
        XCTAssertFalse(surveyed.isUsable(forPathOf: 0), "a path of nothing is not a path")
    }
}
