//
//  PacketNodeSummaryTests.swift
//  AXTermTests
//
//  The Packet Node page, redesigned (park rehearsal 2026-10-08, finding 46;
//  operator agreed the layout 2026-10-11). The top of the page says what is
//  on the air now; each service then has one card with the radios that
//  carry it; a radio that is switched off folds to one line.
//

import XCTest
@testable import AXTerm

final class PacketNodeSummaryTests: XCTestCase {

    private func radio(_ name: String, enabled: Bool = true, pings: Bool = true, node: Bool = true,
                       mailbox: Bool = true, digi: Bool = false, beacon: Bool = false) -> RadioProfile {
        var profile = RadioProfile(id: RadioID(rawValue: name), name: name)
        profile.enabled = enabled
        profile.pings = pings
        profile.announcesNode = node
        profile.answersMailbox = mailbox
        profile.digi.enabled = digi
        profile.beacon.enabled = beacon
        return profile
    }

    private func summary(radios: [RadioProfile], nodeRuns: Bool = false, announces: Bool = false,
                         alias: String = "EPINOD", pings: Bool = false,
                         mailboxOnAir: Bool? = nil) -> PacketNodeSummary {
        PacketNodeSummary(radios: radios, nodeRuns: nodeRuns, announces: announces, alias: alias,
                          pings: pings, mailboxOnAir: mailboxOnAir)
    }

    func testWhatIsOnTheAirIsListedAndTheRestIsOneLine() {
        let s = summary(radios: [radio("IC-705"), radio("Direwolf", enabled: false)],
                        nodeRuns: true, announces: true, mailboxOnAir: true)
        XCTAssertEqual(s.on, ["Node EPINOD answers callers and announces on IC-705",
                              "Mailbox answers on IC-705"])
        XCTAssertEqual(s.off, "Ping, digipeater and ID beacon are off.")
    }

    func testARadioThatIsSwitchedOffCarriesNothing() {
        let s = summary(radios: [radio("Direwolf", enabled: false, digi: true, beacon: true)],
                        nodeRuns: true, pings: true, mailboxOnAir: true)
        XCTAssertEqual(s.on, ["Node EPINOD answers callers"])
        XCTAssertEqual(s.off, "Mailbox, ping, digipeater and ID beacon are off.")
    }

    func testPerRadioServicesAreNamed() {
        let s = summary(radios: [radio("IC-705", pings: true, digi: true),
                                 radio("ID-50", pings: false, beacon: true)],
                        pings: true)
        XCTAssertEqual(s.on, ["Pings stations on IC-705", "Digipeats on IC-705", "ID beacon on ID-50"])
        XCTAssertEqual(s.off, "Node is off.")
    }

    /// Announcing with no radio to carry it says so, rather than nothing.
    func testAnnouncingOnNoRadioSaysSo() {
        let s = summary(radios: [radio("IC-705", node: false)], nodeRuns: false, announces: true)
        XCTAssertEqual(s.on.first, "Node EPINOD announces on no radio")
    }

    func testANodeWithoutAnAliasSaysSo() {
        let s = summary(radios: [radio("IC-705")], nodeRuns: true, alias: " ")
        XCTAssertEqual(s.on.first, "Node (no alias) answers callers")
    }

    /// Mailbox state lives on the mailbox page; unknown here, it is left out.
    func testUnknownMailboxStateIsLeftOut() {
        let s = summary(radios: [radio("IC-705")])
        XCTAssertFalse(s.on.contains { $0.hasPrefix("Mailbox") })
        XCTAssertEqual(s.off, "Node, ping, digipeater and ID beacon are off.")
    }

    func testEverythingOnHasNoOffLine() {
        let s = summary(radios: [radio("IC-705", digi: true, beacon: true)],
                        nodeRuns: true, announces: true, pings: true, mailboxOnAir: true)
        XCTAssertNil(s.off)
    }

    // MARK: - Which radios fold

    func testOnlySwitchedOffRadiosFold() {
        let radios = [radio("IC-705"), radio("Direwolf", enabled: false)]
        XCTAssertEqual(PacketNodeSummary.shown(radios).map(\.name), ["IC-705"])
        XCTAssertEqual(PacketNodeSummary.folded(radios).map(\.name), ["Direwolf"])
    }
}
