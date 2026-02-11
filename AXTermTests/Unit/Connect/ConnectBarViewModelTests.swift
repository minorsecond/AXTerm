import XCTest
@testable import AXTerm

final class ConnectBarViewModelTests: XCTestCase {
    func testDigipeaterParserHandlesSpacesAndCommas() {
        let parsed = DigipeaterListParser.parse("DIGI1 DIGI2,DIGI3")
        XCTAssertEqual(parsed, ["DIGI1", "DIGI2", "DIGI3"])
    }

    func testCallsignValidationRejectsInvalidSSID() {
        XCTAssertTrue(ConnectCallsign.isValidSSIDCall("N0CALL-7"))
        XCTAssertFalse(ConnectCallsign.isValidSSIDCall("BAD-99"))
    }

    func testRoutePrefillDirectUsesHeardAsWhenDifferent() {
        let target = ConnectPrefillLogic.ax25DirectTarget(destination: "AA0QC", heardAs: "W0TX-7")
        XCTAssertEqual(target.to, "W0TX-7")
        XCTAssertEqual(target.note, "Heard as: W0TX-7")
    }

    func testContextDefaultModeSelectsRoutesAsNetRom() {
        XCTAssertEqual(ConnectBarMode.defaultMode(for: .routes), .netrom)
        XCTAssertEqual(ConnectBarMode.defaultMode(for: .stations), .ax25)
    }

    func testConnectCoordinatorRequestsNavigationOnConnectIntent() {
        let intent = ConnectIntent(
            kind: .ax25Direct,
            to: "N0CALL",
            sourceContext: .stations,
            suggestedRoutePreview: nil,
            validationErrors: [],
            routeHint: nil,
            note: nil
        )
        let request = ConnectRequest(intent: intent, mode: .ax25, executeImmediately: true)
        XCTAssertTrue(ConnectPrefillLogic.shouldNavigateOnConnect(request))

        let noNav = ConnectRequest(intent: intent, mode: .ax25, executeImmediately: false)
        XCTAssertFalse(ConnectPrefillLogic.shouldNavigateOnConnect(noNav))
    }

    func testFallbackDigipeatersUseRoutePathWithoutDestinationTail() {
        let hint = NetRomRouteHint(
            nextHop: "DRL",
            heardAs: "DRL",
            path: ["DRL", "KB5YZB-7"],
            hops: 2
        )
        let digis = ConnectPrefillLogic.fallbackDigipeaters(
            destination: "KB5YZB-7",
            hint: hint,
            nextHopOverride: nil
        )
        XCTAssertEqual(digis, ["DRL"])
    }

    func testDigipeaterValidationAllowsRoutingAlias() {
        XCTAssertTrue(CallsignValidator.isValidDigipeaterAddress("DRLNOD"))
        XCTAssertTrue(CallsignValidator.isValidDigipeaterAddress("DRLNOD-1"))
        XCTAssertFalse(CallsignValidator.isValidDigipeaterAddress("DRLNOD-99"))
    }

    func testDigipeaterValidationRejectsHopChainSyntax() {
        XCTAssertFalse(CallsignValidator.isValidDigipeaterAddress("A->B->C"))
    }

}
