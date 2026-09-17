import XCTest
@testable import AXTerm

/// Choosing between the two coverage rings.
///
/// They answer different questions from different evidence, so the operator
/// picks them one at a time. Drawn together they must stay two rings rather
/// than being merged or reordered into each other.
final class CoverageRingSelectionTests: XCTestCase {

    private let answered = CoverageEstimate.Ring(
        typicalKm: 10, reachKm: 30, stationCount: 4,
        farthestCallsign: "K0NTS-7", evidence: .answered)

    private let digipeated = CoverageEstimate.Ring(
        typicalKm: 25, reachKm: 90, stationCount: 9,
        farthestCallsign: "WA6IFI-6", evidence: .digipeated)

    func testEitherRingCanBeShownOnItsOwn() {
        XCTAssertEqual(
            CoverageRingSelection.rings(answered: answered, showsAnswered: true,
                                        digipeated: digipeated, showsDigipeated: false),
            [answered])
        XCTAssertEqual(
            CoverageRingSelection.rings(answered: answered, showsAnswered: false,
                                        digipeated: digipeated, showsDigipeated: true),
            [digipeated])
    }

    func testBothTogetherStayTwoRingsThatCanBeToldApart() {
        let rings = CoverageRingSelection.rings(
            answered: answered, showsAnswered: true,
            digipeated: digipeated, showsDigipeated: true)

        XCTAssertEqual(rings.count, 2, "one ring drawn over the other measures neither")
        XCTAssertEqual(
            rings.map(\.evidence), [.answered, .digipeated],
            "the connected-mode ring keeps the colour it has when it is alone")
    }

    func testAnUncollectedRingDrawsNothingEvenWhenAskedFor() {
        XCTAssertEqual(
            CoverageRingSelection.rings(answered: nil, showsAnswered: true,
                                        digipeated: nil, showsDigipeated: true),
            [],
            "no evidence, no ring")
    }

    func testBothOffDrawsNothing() {
        XCTAssertEqual(
            CoverageRingSelection.rings(answered: answered, showsAnswered: false,
                                        digipeated: digipeated, showsDigipeated: false),
            [])
    }

    /// The larger ring is not necessarily the connected-mode one. APRS
    /// coverage fills in on its own and routinely outruns it, so order must
    /// not follow size.
    func testOrderDoesNotFollowSize() {
        let rings = CoverageRingSelection.rings(
            answered: answered, showsAnswered: true,
            digipeated: digipeated, showsDigipeated: true)

        XCTAssertGreaterThan(digipeated.reachKm, answered.reachKm, "fixture is the awkward way round")
        XCTAssertEqual(rings.first?.evidence, .answered)
    }
}
