import XCTest
@testable import AXTerm

/// How a station click decides to reach a station.
///
/// The bug this pins: the sidebar row says "Via DRLNOD" and the click called
/// direct anyway. A row that displays one fact and acts on another is worse
/// than one that displays nothing.
@MainActor
final class StationConnectModeTests: XCTestCase {

    private func coordinator() -> ConnectCoordinator { ConnectCoordinator() }

    func testAStationOnlyHeardThroughADigipeaterIsCalledThroughIt() {
        XCTAssertEqual(
            coordinator().preferredMode(for: "KB5YZB-7", hasNetRomRoute: false,
                                        heardVia: ["DRLNOD"]),
            .ax25ViaDigi)
    }

    func testAStationHeardDirectIsCalledDirect() {
        XCTAssertEqual(
            coordinator().preferredMode(for: "K0NTS-7", hasNetRomRoute: false, heardVia: []),
            .ax25)
    }

    /// A NET/ROM route is a better answer than a digipeater path when both
    /// exist, and was already preferred.
    func testANetRomRouteStillWins() {
        XCTAssertEqual(
            coordinator().preferredMode(for: "KB5YZB-7", hasNetRomRoute: true,
                                        heardVia: ["DRLNOD"]),
            .netrom)
    }

    /// Whatever the operator chose last for this station outranks any guess.
    func testTheOperatorsLastChoiceOutranksTheEvidence() {
        let sut = coordinator()
        sut.requestConnect(ConnectRequest(
            intent: ConnectIntent(kind: .ax25Direct, to: "KB5YZB-7",
                                  sourceContext: .stations, suggestedRoutePreview: nil,
                                  validationErrors: [], routeHint: nil, note: nil),
            mode: .ax25, executeImmediately: false))

        XCTAssertEqual(
            sut.preferredMode(for: "KB5YZB-7", hasNetRomRoute: true, heardVia: ["DRLNOD"]),
            .ax25)
    }

    /// `heardVia` is ordered as the frame travelled *to* us; the way out is the
    /// same hops the other way. No difference through one digipeater and every
    /// difference through two.
    func testTheReturnPathIsReversed() {
        XCTAssertEqual(ConnectCoordinator.returnPath(heardVia: ["DRLNOD"]), ["DRLNOD"])
        XCTAssertEqual(ConnectCoordinator.returnPath(heardVia: ["FNKTWN", "DRLNOD"]),
                       ["DRLNOD", "FNKTWN"])
        XCTAssertEqual(ConnectCoordinator.returnPath(heardVia: []), [])
    }
}
