import XCTest
@testable import AXTerm

final class WinlinkReadinessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A station that would pass every check.
    private func goodInputs() -> WinlinkReadiness.Inputs {
        WinlinkReadiness.Inputs(
            callsign: "K0EPI-7",
            hasPassword: true,
            gatewayCount: 2,
            gridSquare: "DM79po",
            hasPositionFix: false,
            catalogItemCount: 1466,
            catalogFetchedAt: now.addingTimeInterval(-86_400),
            outageKitCount: 8,
            outageKitBytes: 15_520,
            p2pArmed: true,
            lastSuccessfulSessionAt: now.addingTimeInterval(-3600),
            queuedOutboundCount: 0,
            now: now)
    }

    private func check(_ readiness: WinlinkReadiness, _ id: String) throws -> WinlinkReadiness.Check {
        try XCTUnwrap(readiness.checks.first { $0.id == id }, "no check \(id)")
    }

    // MARK: - Overall

    func testAFullyConfiguredStationIsReady() {
        let readiness = WinlinkReadiness.evaluate(goodInputs())
        XCTAssertEqual(readiness.overall, .ready)
        XCTAssertTrue(readiness.blockers.isEmpty)
        XCTAssertTrue(readiness.warnings.isEmpty, "\(readiness.warnings.map(\.title))")
    }

    /// A station is only as ready as its weakest check.
    func testOverallIsTheWorstIndividualResult() {
        var input = goodInputs()
        input.hasPassword = false
        XCTAssertEqual(WinlinkReadiness.evaluate(input).overall, .warning)

        input.callsign = ""
        XCTAssertEqual(WinlinkReadiness.evaluate(input).overall, .blocked)
    }

    // MARK: - Callsign

    func testMissingCallsignBlocks() throws {
        var input = goodInputs()
        input.callsign = "  "
        XCTAssertEqual(try check(WinlinkReadiness.evaluate(input), "callsign").status, .blocked)
    }

    /// NOCALL is the app's placeholder, not a licence — nothing accepts it.
    func testNOCALLPlaceholderBlocks() throws {
        var input = goodInputs()
        input.callsign = "nocall"
        XCTAssertEqual(try check(WinlinkReadiness.evaluate(input), "callsign").status, .blocked)
    }

    // MARK: - Reach

    /// With no gateway and no P2P the station can compose mail and never
    /// move it. That is the definition of blocked.
    func testNoGatewayAndNoP2PBlocks() throws {
        var input = goodInputs()
        input.gatewayCount = 0
        input.p2pArmed = false
        let reach = try check(WinlinkReadiness.evaluate(input), "reach")
        XCTAssertEqual(reach.status, .blocked)
        XCTAssertNotNil(reach.remedy)
    }

    /// P2P alone is a legitimate grid-down posture, not a failure.
    func testP2PAloneIsAWarningNotABlocker() throws {
        var input = goodInputs()
        input.gatewayCount = 0
        input.p2pArmed = true
        XCTAssertEqual(try check(WinlinkReadiness.evaluate(input), "reach").status, .warning)
    }

    // MARK: - Password

    /// P2P needs no password, so a missing one degrades rather than
    /// blocks.
    func testMissingPasswordWarnsRatherThanBlocks() throws {
        var input = goodInputs()
        input.hasPassword = false
        let password = try check(WinlinkReadiness.evaluate(input), "password")
        XCTAssertEqual(password.status, .warning)
        XCTAssertTrue(password.remedy?.contains("P2P") == true, "\(password.remedy ?? "")")
    }

    // MARK: - Position

    func testInvalidGridWarns() throws {
        var input = goodInputs()
        input.gridSquare = "ZZ99zz"
        XCTAssertEqual(try check(WinlinkReadiness.evaluate(input), "position").status, .warning)
    }

    /// A 4-character grid is 60 km of uncertainty — enough that link
    /// measurements taken there will not count as "from here".
    func testFourCharacterGridWarnsAboutPrecision() throws {
        var input = goodInputs()
        input.gridSquare = "DM79"
        let position = try check(WinlinkReadiness.evaluate(input), "position")
        XCTAssertEqual(position.status, .warning)
        XCTAssertTrue(position.detail.contains("60 km"), position.detail)
    }

    /// A live fix beats any configured square.
    func testAGPSFixSatisfiesPositionEvenWithNoGrid() throws {
        var input = goodInputs()
        input.gridSquare = ""
        input.hasPositionFix = true
        XCTAssertEqual(try check(WinlinkReadiness.evaluate(input), "position").status, .ready)
    }

    // MARK: - Catalog and kit

    func testUncachedCatalogWarns() throws {
        var input = goodInputs()
        input.catalogItemCount = 0
        input.catalogFetchedAt = nil
        XCTAssertEqual(try check(WinlinkReadiness.evaluate(input), "catalog").status, .warning)
    }

    func testStaleCatalogWarnsAndSaysHowOld() throws {
        var input = goodInputs()
        input.catalogFetchedAt = now.addingTimeInterval(-40 * 86_400)
        let catalog = try check(WinlinkReadiness.evaluate(input), "catalog")
        XCTAssertEqual(catalog.status, .warning)
        XCTAssertTrue(catalog.detail.contains("40 days"), catalog.detail)
    }

    func testEmptyOutageKitWarns() throws {
        var input = goodInputs()
        input.outageKitCount = 0
        XCTAssertEqual(try check(WinlinkReadiness.evaluate(input), "outageKit").status, .warning)
    }

    // MARK: - Proven path

    /// Settings that have never completed a session are a plan, not a
    /// capability — and that distinction is the whole point of the panel.
    func testNeverHavingExchangedWarns() throws {
        var input = goodInputs()
        input.lastSuccessfulSessionAt = nil
        let proven = try check(WinlinkReadiness.evaluate(input), "provenPath")
        XCTAssertEqual(proven.status, .warning)
        XCTAssertTrue(proven.remedy?.contains("plan") == true, "\(proven.remedy ?? "")")
    }

    func testLongStaleSessionWarns() throws {
        var input = goodInputs()
        input.lastSuccessfulSessionAt = now.addingTimeInterval(-45 * 86_400)
        XCTAssertEqual(try check(WinlinkReadiness.evaluate(input), "provenPath").status, .warning)
    }

    // MARK: - Outbox

    /// Mail sitting in the Outbox when the path is about to disappear is
    /// worth surfacing before departure, not after.
    func testQueuedMailWarns() throws {
        var input = goodInputs()
        input.queuedOutboundCount = 3
        let outbox = try check(WinlinkReadiness.evaluate(input), "outbox")
        XCTAssertEqual(outbox.status, .warning)
        XCTAssertTrue(outbox.detail.contains("3"), outbox.detail)
    }

    // MARK: - Presentation

    /// Every failing check has to say how to fix it; a red dot with no
    /// remedy just moves the problem.
    func testEveryNonReadyCheckCarriesARemedy() {
        var input = WinlinkReadiness.Inputs()
        input.now = now
        let readiness = WinlinkReadiness.evaluate(input)
        XCTAssertFalse(readiness.checks.isEmpty)
        for check in readiness.checks where check.status != .ready {
            XCTAssertNotNil(check.remedy, "\(check.id) has no remedy")
            XCTAssertFalse(check.detail.isEmpty, "\(check.id) has no detail")
        }
    }

    func testCheckIdentifiersAreUnique() {
        let ids = WinlinkReadiness.evaluate(goodInputs()).checks.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
