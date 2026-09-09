import XCTest
@testable import AXTerm

/// What may be transmitted, and what may be removed.
///
/// Placing an object is the one map action that transmits on the operator's
/// behalf, into a namespace shared with every other station on the channel
/// and with no authentication anywhere in it.
final class APRSObjectPlacementTests: XCTestCase {

    private func placed(_ name: String, by station: String) -> APRSObjectStore.Placed {
        .init(report: APRSObjectReport(
                kind: .object, name: name, isLive: true,
                latitude: 39.6, longitude: -104.7,
                symbolTable: "/", symbolCode: "+",
                courseDegrees: nil, speedKnots: nil, comment: "", weather: nil),
              reportedBy: station, heard: Date(), firstHeard: Date(), timesHeard: 1)
    }

    private let ours: Set<String> = ["K0EPI-7", "K0EPI-1"]

    // MARK: - Whose name is this

    /// The hazard worth catching before the radio keys. APRS keys objects by
    /// name alone, so an operator naming theirs "AID" while another agency
    /// already has one replaces that agency's marker on every receiver in
    /// range — silently, and without either of them being told.
    func testAnotherStationsLiveNameIsACollision() {
        let problem = APRSObjectPlacement.problem(
            name: "AID", liveObjects: [placed("AID", by: "W0ARP-10")], ourAddresses: ours)
        XCTAssertEqual(problem, .collidesWith(station: "W0ARP-10"))
        XCTAssertTrue(problem!.message.contains("W0ARP-10"), problem!.message)
    }

    /// The key is case- and padding-insensitive everywhere else, so the check
    /// has to be too — otherwise "Fire" sails past a live "FIRE" and stomps it.
    func testACollisionIsFoundRegardlessOfCaseOrPadding() {
        XCTAssertNotNil(APRSObjectPlacement.problem(
            name: "  fire ", liveObjects: [placed("FIRE", by: "W0ARP-10")], ourAddresses: ours))
        XCTAssertNotNil(APRSObjectPlacement.problem(
            name: "FIRE", liveObjects: [placed("Fire", by: "W0ARP-10")], ourAddresses: ours))
    }

    /// Re-sending our own name is how an object is moved or its comment
    /// corrected; the format offers no other way, so it is not a collision.
    func testReplacingOurOwnObjectIsNotACollision() {
        XCTAssertNil(APRSObjectPlacement.problem(
            name: "AID", liveObjects: [placed("AID", by: "K0EPI-7")], ourAddresses: ours))
    }

    /// Any SSID on the licence that this station answers to is us.
    func testAnySSIDWeAnswerToCountsAsOurs() {
        XCTAssertNil(APRSObjectPlacement.problem(
            name: "AID", liveObjects: [placed("AID", by: "k0epi-1")], ourAddresses: ours))
    }

    func testANameWithNothingUsableInItIsRefused() {
        XCTAssertEqual(APRSObjectPlacement.problem(
            name: "!!;)", liveObjects: [], ourAddresses: ours), .unusableName)
        XCTAssertEqual(APRSObjectPlacement.problem(
            name: "   ", liveObjects: [], ourAddresses: ours), .unusableName)
    }

    func testAnOrdinaryNameOnAQuietChannelIsFine() {
        XCTAssertNil(APRSObjectPlacement.problem(
            name: "ROADCLOSE", liveObjects: [], ourAddresses: ours))
    }

    // MARK: - Whose object is this

    func testWeMayRemoveOurOwn() {
        XCTAssertTrue(APRSObjectPlacement.mayRemove(placed("AID", by: "K0EPI-7"),
                                                    ourAddresses: ours))
        XCTAssertTrue(APRSObjectPlacement.mayRemove(placed("AID", by: "k0epi-1"),
                                                    ourAddresses: ours))
    }

    /// APRS honours a kill from anyone. The button is withheld anyway: an
    /// operator who can stand down another agency's road closure with one
    /// click will eventually do it by accident.
    func testWeDoNotOfferToRemoveSomebodyElses() {
        XCTAssertFalse(APRSObjectPlacement.mayRemove(placed("AID", by: "W0ARP-10"),
                                                     ourAddresses: ours))
    }

    /// A kill is a transmission, not a local delete, and the wording has to
    /// say so or the operator will expect the wrong map to change.
    func testRemovalSaysItIsATransmission() {
        let text = APRSObjectPlacement.removalExplanation(placed("ROADCLOSE", by: "K0EPI-7"))
        XCTAssertTrue(text.contains("every station on the channel"), text)
        XCTAssertTrue(text.contains("ROADCLOSE"), text)
    }
}

/// Our own object has to reach our own map.
///
/// Our transmitted frames never enter the packet log, so the store is the
/// only thing that can be told about them — and if nothing tells it, the
/// operator places a road closure and watches nothing appear. The same
/// silence the pending-transmission work exists to remove.
final class APRSOwnObjectVisibilityTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_757_419_200)

    func testAnObjectWeTransmitLandsInTheStoreUnderOurCallsign() {
        var store = APRSObjectStore()
        let info = APRSObjectReport.objectInfo(
            name: "ROADCLOSE", live: true, latitude: 39.6117, longitude: -104.7317,
            symbolTable: "/", symbolCode: "-", comment: "US-85 washed out", at: noon)
        let report = APRSObjectReport.parse(info: Data(info.utf8))!
        XCTAssertTrue(store.record(report, from: "K0EPI-7", at: noon))

        let live = store.live(now: noon)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.reportedBy, "K0EPI-7")
        // And being ours is what makes standing it down possible.
        XCTAssertTrue(APRSObjectPlacement.mayRemove(live.first!, ourAddresses: ["K0EPI-7"]))
    }

    /// Standing down is the same frame with one byte different, and it has to
    /// take the object off our own map too.
    func testStandingDownRemovesItFromOurOwnMap() {
        var store = APRSObjectStore()
        let place = APRSObjectReport.parse(info: Data(APRSObjectReport.objectInfo(
            name: "AID", live: true, latitude: 39.6, longitude: -104.7,
            symbolTable: "/", symbolCode: "+", at: noon).utf8))!
        _ = store.record(place, from: "K0EPI-7", at: noon)
        XCTAssertEqual(store.live(now: noon).count, 1)

        let kill = APRSObjectReport.parse(info: Data(APRSObjectReport.killInfo(
            name: "AID", latitude: 39.6, longitude: -104.7,
            symbolTable: "/", symbolCode: "+", at: noon).utf8))!
        _ = store.record(kill, from: "K0EPI-7", at: noon.addingTimeInterval(60))
        XCTAssertTrue(store.live(now: noon.addingTimeInterval(60)).isEmpty,
                      "the object we stood down must leave our own map too")
    }
}
