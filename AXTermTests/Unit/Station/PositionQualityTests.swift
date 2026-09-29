import XCTest
@testable import AXTerm

/// What a coordinate actually describes.
///
/// Measured on this operator's directory of 166 stations: 143 carry seven
/// decimal places, which is centimetre precision, and three unrelated
/// callsigns share one coordinate to the last digit. A licence address
/// printed that way looked exactly as authoritative as a surveyed antenna,
/// and the whole app builds distances, bearings, coverage rings and terrain
/// verdicts on top of it.
final class PositionQualityTests: XCTestCase {

    private typealias Source = PositionQuality.Source

    /// A grid square is coarse and says so. A licence coordinate is
    /// confidently wrong by an unknown amount, which is worse, so nothing
    /// should rank it above a position the operator actually gave.
    func testSourcesRankByHowWellTheyDescribeAnAntenna() {
        XCTAssertLessThan(Source.surveyed, Source.deviceGPS)
        XCTAssertLessThan(Source.deviceGPS, Source.geocodedAddress)
        XCTAssertLessThan(Source.geocodedAddress, Source.licenceAddress)
        XCTAssertLessThan(Source.licenceAddress, Source.gridSquare)
    }

    /// Picking the best available is a `min`, not a ladder rewritten at every
    /// call site.
    func testTheBestAvailableSourceIsJustTheSmallest() {
        XCTAssertEqual([Source.gridSquare, .licenceAddress, .deviceGPS].min(), .deviceGPS)
        XCTAssertEqual([Source.gridSquare, .licenceAddress].min(), .licenceAddress)
    }

    /// A six-character subsquare is about 7 km by 4.6 km, so its centre can
    /// be four kilometres from the antenna. That has to be the number, since
    /// it is what decides whether a short path is worth profiling at all.
    func testAGridSquareAdmitsHowCoarseItIs() {
        XCTAssertGreaterThan(Source.gridSquare.accuracyMetres, 4_000)
        XCTAssertLessThan(Source.surveyed.accuracyMetres, 50)
    }

    // MARK: - Post office boxes

    /// The street line is the only way to tell a house from a mailbox, and it
    /// was being discarded. A PO box means the coordinate is a post office.
    func testAMailboxIsRecognised() {
        for address in ["PO BOX 412", "P.O. Box 7", "PO. BOX 1234", "POB 55",
                        "Post Office Box 90", "PMB 340", "Box 22"] {
            XCTAssertTrue(PositionQuality.isMailbox(address), "\(address)")
        }
    }

    /// A false positive throws away a usable position, so the test is narrow
    /// on purpose. These are streets.
    func testStreetsThatMerelyLookLikeOneAreNot() {
        for address in ["Box Canyon Road", "1421 Boxwood Lane", "22 Boxelder Ct",
                        "9 Post Road", "1200 Postal Way", "455 Mailbox Peak Trail"] {
            XCTAssertFalse(PositionQuality.isMailbox(address), "\(address)")
        }
    }

    func testNoAddressIsNotAMailbox() {
        XCTAssertFalse(PositionQuality.isMailbox(nil))
        XCTAssertFalse(PositionQuality.isMailbox(""))
        XCTAssertFalse(PositionQuality.isMailbox("   "))
    }

    // MARK: - Shared coordinates

    /// The case found in this operator's own data. Three unrelated callsigns
    /// at one coordinate to seven decimal places is a town or postcode
    /// centre, and it is nobody's antenna.
    func testACoordinateSharedBySeveralStationsBelongsToNoneOfThem() {
        let shared = PositionQuality.sharedCoordinates([
            ("N9LYA", 38.740297, -86.4723061),
            ("K9BBS", 38.740297, -86.4723061),
            ("W9OTR", 38.740297, -86.4723061),
            ("K0EPI", 39.6123232, -104.7332721),
        ])
        XCTAssertEqual(shared["N9LYA"], 2)
        XCTAssertEqual(shared["K9BBS"], 2)
        XCTAssertEqual(shared["W9OTR"], 2)
        XCTAssertNil(shared["K0EPI"], "a coordinate of its own is not suspect")
    }

    /// Two operators genuinely on one street are metres apart, not identical.
    /// Comparing as printed rather than by distance is what keeps them out.
    func testNeighboursAreNotTreatedAsACentroid() {
        let shared = PositionQuality.sharedCoordinates([
            ("K0AAA", 39.612300, -104.733200),
            ("K0BBB", 39.612390, -104.733280),
        ])
        XCTAssertTrue(shared.isEmpty)
    }

    /// The same station listed twice is not two stations.
    func testOneStationCountedTwiceIsNotSuspicious() {
        let shared = PositionQuality.sharedCoordinates([
            ("K0EPI", 39.6123232, -104.7332721),
            ("k0epi", 39.6123232, -104.7332721),
        ])
        XCTAssertTrue(shared.isEmpty)
    }

    /// The warnings have to say what is wrong with the position, not that
    /// something is.
    func testTheWarningsNameTheProblem() {
        XCTAssertTrue(PositionQuality.Doubt.postOfficeBox.warning.contains("post office"))
        let shared = PositionQuality.Doubt.sharedWithOthers(count: 2).warning
        XCTAssertTrue(shared.contains("2 other stations"))
        XCTAssertTrue(PositionQuality.Doubt.sharedWithOthers(count: 1).warning
            .contains("1 other station"))
    }
}
