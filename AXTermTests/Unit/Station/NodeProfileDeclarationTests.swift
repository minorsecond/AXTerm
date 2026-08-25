//
//  NodeProfileDeclarationTests.swift
//  AXTermTests
//
//  The neighbour table is built by watching traffic — `observePacket` records
//  any direct frame, and "classic" versus "inferred" distinguishes two
//  inference paths, not declared versus guessed. Calling every neighbour a
//  NET/ROM node put that label on ordinary stations that merely transmitted
//  nearby.
//

import XCTest
@testable import AXTerm

final class NodeProfileDeclarationTests: XCTestCase {

    func testBeingInTheNeighbourTableIsNotADeclaration() {
        let profile = NodeProfile.make(callsign: "W0TX", neighbourQuality: 200)
        XCTAssertFalse(profile.roles.contains(.netromNode),
                       "a loud nearby station is not a node")
        // The measurement itself is still real and still shown.
        XCTAssertEqual(profile.netrom?.neighbourQuality, 200)
    }

    func testANodesBroadcastIsADeclaration() {
        let profile = NodeProfile.make(callsign: "DRLNOD",
                                       netRomDeclaration: .nodesBroadcast)
        XCTAssertTrue(profile.roles.contains(.netromNode))
    }

    func testAnAliasAnnouncementIsADeclaration() {
        let profile = NodeProfile.make(callsign: "KD0SSP-7",
                                       netRomDeclaration: .aliasAnnouncement("DWARC"))
        XCTAssertTrue(profile.roles.contains(.netromNode))
    }

    func testEachDeclarationExplainsItselfDifferently() {
        let broadcast = NodeProfile.NetRomDeclaration.nodesBroadcast.evidence
        let alias = NodeProfile.NetRomDeclaration.aliasAnnouncement("DWARC").evidence
        XCTAssertNotEqual(broadcast, alias)
        XCTAssertTrue(alias.contains("DWARC"), "the evidence must quote what was announced")
        XCTAssertTrue(broadcast.contains("0xCF"), "the evidence must name the frame")
    }

    func testTheDeclarationSurvivesOntoTheProfile() {
        let profile = NodeProfile.make(callsign: "DRLNOD",
                                       netRomDeclaration: .nodesBroadcast)
        XCTAssertEqual(profile.netRomDeclaration, .nodesBroadcast)
    }

    // MARK: - Service endpoints

    func testDestinationsAreRecognisedAsNonStations() {
        for name in ["BEACON", "ID", "NODES", "QST", "MAIL", "WIDE1-1", "ALL"] {
            XCTAssertTrue(NodeProfile.make(callsign: name).isServiceEndpoint,
                          "\(name) is an address, not a licensee")
        }
    }

    func testRealCallsignsAreNotServiceEndpoints() {
        for name in ["K0EPI-7", "W0ARP-10", "KB5YZB-1", "N0HI"] {
            XCTAssertFalse(NodeProfile.make(callsign: name).isServiceEndpoint,
                           "\(name) is a station")
        }
    }

    func testAServiceEndpointIsNotMerelyBare() {
        // "Nothing known yet" invites the operator to wait for a lookup that
        // will never return anything. There is nothing to know.
        let profile = NodeProfile.make(callsign: "BEACON")
        XCTAssertTrue(profile.isServiceEndpoint)
    }
}
