import XCTest
@testable import AXTerm

/// A radio going on an APRS channel for the first time with no path gets
/// WIDE1-1,WIDE2-1. No existing radio changes what it sends.
final class NewRadioAPRSPathTests: XCTestCase {

    func testANewRadioMovedToAPRSGetsTheUsualPath() {
        var radio = RadioProfile(id: RadioID(rawValue: "n"), name: "")
        RadioChannel.aprs.apply(to: &radio)
        XCTAssertEqual(radio.aprsPath, "WIDE1-1,WIDE2-1")
        XCTAssertEqual(radio.effectiveAPRSPath, "WIDE1-1,WIDE2-1")
        XCTAssertEqual(APRSPath.menuTitle(radio.effectiveAPRSPath), "WIDE1-1,WIDE2-1")
    }

    func testAnExplicitDirectPathStaysDirect() {
        var radio = RadioProfile(id: RadioID(rawValue: "d"), name: "")
        radio.aprsPath = ""
        RadioChannel.aprs.apply(to: &radio)
        XCTAssertEqual(radio.aprsPath, "")
        XCTAssertEqual(APRSPath.menuTitle(radio.effectiveAPRSPath), "Direct")
    }

    func testARadioAlreadyOnAPRSWithNoPathIsUnchanged() {
        var radio = RadioProfile(id: RadioID(rawValue: "e"), name: "")
        radio.aprsEnabled = true
        radio.beacon.kind = .aprsPosition
        radio.beacon.path = "WIDE2-1"
        radio.beacon.aprs = .followingStation
        let before = radio.effectiveAPRSPath
        RadioChannel.aprs.apply(to: &radio)
        XCTAssertNil(radio.aprsPath)
        XCTAssertEqual(radio.effectiveAPRSPath, before)
    }

    func testARadioBackOnAPRSKeepsResolvingFromItsBeacon() {
        // Was on APRS before (it has a position beacon set up), went to
        // packet, and comes back: its path is not replaced.
        var radio = RadioProfile(id: RadioID(rawValue: "f"), name: "")
        radio.beacon.aprs = .followingStation
        radio.beacon.path = "WIDE2-2"
        RadioChannel.aprs.apply(to: &radio)
        XCTAssertNil(radio.aprsPath)
        XCTAssertEqual(radio.effectiveAPRSPath, "WIDE2-2")
    }

    func testPacketChannelIsUnaffected() {
        var radio = RadioProfile(id: RadioID(rawValue: "p"), name: "")
        RadioChannel.packet.apply(to: &radio)
        XCTAssertNil(radio.aprsPath)
    }

    func testTheFlowSetsTheDefaultWhenChoosingAPRS() {
        var radio = RadioProfile(id: RadioID(rawValue: "g"), name: "")
        XCTAssertTrue(RadioChannel.takesDefaultAPRSPath(radio, movingTo: .aprs))
        XCTAssertFalse(RadioChannel.takesDefaultAPRSPath(radio, movingTo: .packet))
        radio.aprsPath = "WIDE1-1"
        XCTAssertFalse(RadioChannel.takesDefaultAPRSPath(radio, movingTo: .aprs))
    }
}
