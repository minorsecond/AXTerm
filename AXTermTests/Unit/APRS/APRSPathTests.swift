import XCTest
@testable import AXTerm

/// What a digipeater path asks the channel for.
///
/// Nothing on APRS is repeated automatically: a frame with no path is heard by
/// stations in direct earshot and by nobody else, which is what a silent query
/// to a station two hops away looks like.
final class APRSPathTests: XCTestCase {

    func testDirectIsOneTransmission() {
        XCTAssertEqual(APRSPath.transmissions(""), 1)
        XCTAssertEqual(APRSPath.label(""), "Direct — no digipeaters")
    }

    /// The hop budget is the `N`, not the number of entries: `WIDE2-2` is two
    /// further transmissions of the same frame, not one.
    func testTheHopBudgetIsTheN() {
        XCTAssertEqual(APRSPath.transmissions("WIDE1-1"), 2)
        XCTAssertEqual(APRSPath.transmissions("WIDE1-1,WIDE2-1"), 3)
        XCTAssertEqual(APRSPath.transmissions("WIDE2-2"), 3)
    }

    /// An explicit digipeater costs one hop; it has no budget to spend.
    func testANamedDigipeaterIsOneHop() {
        XCTAssertEqual(APRSPath.transmissions("DRLNOD"), 2)
        XCTAssertEqual(APRSPath.hops(of: "DRLNOD"), 1)
    }

    func testSpacesAndCommasBothSeparate() {
        XCTAssertEqual(APRSPath.digis("WIDE1-1 WIDE2-1"), ["WIDE1-1", "WIDE2-1"])
        XCTAssertEqual(APRSPath.digis("wide1-1,wide2-1"), ["WIDE1-1", "WIDE2-1"])
    }

    // MARK: - Etiquette

    func testTheUsualFixedStationPathDrawsNoComplaint() {
        XCTAssertNil(APRSPath.advice("WIDE1-1,WIDE2-1"))
        XCTAssertNil(APRSPath.advice(""))
    }

    /// The New-N paradigm exists because unbounded paths flooded the channel,
    /// and most modern digipeaters now ignore the old ones outright — so a
    /// station using them is quieter than it thinks, not louder.
    func testPreNewNPathsAreCalledOut() {
        XCTAssertNotNil(APRSPath.advice("WIDE4-4"))
        XCTAssertNotNil(APRSPath.advice("RELAY,WIDE"))
        XCTAssertTrue(APRSPath.isDeprecated("WIDE3-3"))
        XCTAssertTrue(APRSPath.isDeprecated("RELAY"))
        XCTAssertFalse(APRSPath.isDeprecated("WIDE2-2"))
        XCTAssertFalse(APRSPath.isDeprecated("WIDE1-1"))
    }

    func testTooManyHopsIsCountedInTransmissions() {
        guard let advice = APRSPath.advice("WIDE1-1,WIDE2-2") else {
            return XCTFail("four transmissions of every frame is worth a word")
        }
        XCTAssertTrue(advice.contains("4"), advice)
    }
}

/// Which path a radio's APRS traffic carries.
final class RadioAPRSPathTests: XCTestCase {

    private func radio(aprsPath: String?, beaconKind: BeaconKind, beaconPath: String) -> RadioProfile {
        var r = RadioProfile(id: RadioID(rawValue: "r"), name: "Test")
        r.aprsPath = aprsPath
        r.beacon.kind = beaconKind
        r.beacon.path = beaconPath
        return r
    }

    func testTheOperatorsChoiceWins() {
        let r = radio(aprsPath: "WIDE1-1", beaconKind: .aprsPosition, beaconPath: "WIDE2-2")
        XCTAssertEqual(r.effectiveAPRSPath, "WIDE1-1")
    }

    /// Before this setting existed the path lived on the APRS beacon. An
    /// upgrade must not silently shorten a working station's reach.
    func testAnOlderBuildsBeaconPathIsInherited() {
        let r = radio(aprsPath: nil, beaconKind: .aprsPosition, beaconPath: "WIDE1-1,WIDE2-1")
        XCTAssertEqual(r.effectiveAPRSPath, "WIDE1-1,WIDE2-1")
    }

    /// A text beacon's path is an AX.25 path on a packet channel; WIDEn-N does
    /// not belong to it, so it is not inherited.
    func testATextBeaconsPathIsNotAnAPRSPath() {
        let r = radio(aprsPath: nil, beaconKind: .text, beaconPath: "DRLNOD")
        XCTAssertEqual(r.effectiveAPRSPath, "")
    }

    /// Empty is a decision, not an absence: a station may mean direct.
    func testDirectIsRemembered() {
        let r = radio(aprsPath: "", beaconKind: .aprsPosition, beaconPath: "WIDE2-1")
        XCTAssertEqual(r.effectiveAPRSPath, "")
    }

    func testItSurvivesAnEncodeDecodeRound() throws {
        let r = radio(aprsPath: "WIDE1-1,WIDE2-1", beaconKind: .aprsPosition, beaconPath: "")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RadioProfile.self, from: data)
        XCTAssertEqual(back.effectiveAPRSPath, "WIDE1-1,WIDE2-1")
    }
}
