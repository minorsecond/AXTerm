//
//  AnnouncedGridTests.swift
//  AXTermTests
//
//  Locators harvested from beacon text — the placement source for the part
//  of the world no directory covers ("what about europe"). The parser's
//  contract is caution: four-character squares are unambiguous, but an
//  all-caps six-character locator is shaped exactly like a callsign, so it
//  needs either the conventional lowercase subsquare or a context keyword.
//

import XCTest
@testable import AXTerm

final class AnnouncedGridTests: XCTestCase {

    // MARK: Parser

    func testTheConventionalLowercaseSubsquareIsAccepted() {
        XCTAssertEqual(
            BeaconLocatorParser.locator(in: "K0EPI AXTerm Packet Station | DM79po"),
            "DM79PO")
        XCTAssertEqual(
            BeaconLocatorParser.locator(in: "DB0ABC Digi Muenchen JN58td op Hans"),
            "JN58TD")
    }

    func testFourCharacterSquaresNeedNoHelp() {
        XCTAssertEqual(BeaconLocatorParser.locator(in: "G8BPQ node IO91 Bedford"),
                       "IO91")
    }

    func testAllCapsSixCharactersNeedsAContextKeyword() {
        // JN58TD is also a syntactically valid callsign; without a keyword
        // the parser refuses to guess.
        XCTAssertNil(BeaconLocatorParser.locator(in: "CQ de DL1ABC JN58TD"))
        XCTAssertEqual(BeaconLocatorParser.locator(in: "DL1ABC QTH locator JN58TD"),
                       "JN58TD")
    }

    func testNonLocatorsAreRejected() {
        // Field letters run A–R only; SX and TU are callsign territory.
        XCTAssertNil(BeaconLocatorParser.locator(in: "SX34ab TU12cd nothing here"))
        XCTAssertNil(BeaconLocatorParser.locator(in: "Denver Radio Club"))
        XCTAssertNil(BeaconLocatorParser.locator(in: ""))
    }

    // MARK: Store

    @MainActor
    func testIngestStoresAndReplayIsIdempotent() async {
        let defaults = UserDefaults(suiteName: "AnnouncedGridTests")!
        defaults.removePersistentDomain(forName: "AnnouncedGridTests")
        let store = AnnouncedGridStore(defaults: defaults)

        let stamp = Date(timeIntervalSince1970: 1_000_000)
        let info = "DB0ABC Digi JN58td".data(using: .ascii)!
        let beacon = Packet(
            timestamp: stamp,
            from: AX25Address(call: "DB0ABC", ssid: 0),
            to: AX25Address(call: "BEACON", ssid: 0),
            via: [],
            frameType: .ui,
            info: info,
            rawAx25: info,
            infoText: "DB0ABC Digi JN58td")

        store.ingest(packets: [beacon])
        XCTAssertEqual(store.grids["DB0ABC"], "JN58TD")
        let firstHeard = store.announcements["DB0ABC"]?.heardAt

        // Re-sweeping the same stored packet must not forge freshness.
        store.ingest(packets: [beacon])
        XCTAssertEqual(store.announcements["DB0ABC"]?.heardAt, firstHeard)

        defaults.removePersistentDomain(forName: "AnnouncedGridTests")
    }
}
