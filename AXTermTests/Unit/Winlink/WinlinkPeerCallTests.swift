//
//  WinlinkPeerCallTests.swift
//  AXTermTests
//
//  Calling another station directly for peer-to-peer mail: the callsign the
//  operator types, the one the sheet suggests, and the peers it remembers.
//  Field case 2026-10-01: the only way to reach K0EPI-3 was to add it to the
//  RMS gateway ladder, which also put it in line for every gateway exchange.
//

import XCTest
@testable import AXTerm

@MainActor
final class WinlinkPeerCallTests: XCTestCase {

    // MARK: Callsign

    func testATypedCallsignIsTidiedUp() {
        XCTAssertEqual(WinlinkPeerCall.callsign(from: " k0epi-3 "), "K0EPI-3")
        XCTAssertEqual(WinlinkPeerCall.callsign(from: "w0arp"), "W0ARP")
    }

    func testSomethingThatIsNotACallsignIsRefused() {
        XCTAssertNil(WinlinkPeerCall.callsign(from: ""))
        XCTAssertNil(WinlinkPeerCall.callsign(from: "K0EPI-99X"))
        XCTAssertNil(WinlinkPeerCall.callsign(from: "someone@example.com"))
        XCTAssertNil(WinlinkPeerCall.callsign(from: "12345"))
    }

    /// Calling yourself goes nowhere useful.
    func testOwnCallsignIsRefusedButAnotherSSIDIsNot() {
        XCTAssertNil(WinlinkPeerCall.callsign(from: "K0EPI-2", myCallsign: "k0epi-2"))
        XCTAssertEqual(WinlinkPeerCall.callsign(from: "K0EPI-3", myCallsign: "K0EPI-2"), "K0EPI-3")
    }

    // MARK: Suggestion

    /// The station last called is the likeliest next one.
    func testTheLastPeerIsSuggestedFirst() {
        XCTAssertEqual(WinlinkPeerCall.suggestion(recentPeers: ["K0EPI-3", "W1AW"],
                                                  outboxRecipients: ["N0CALL"]),
                       "K0EPI-3")
    }

    /// With no history, the queued message's To address: peer-to-peer mail
    /// is usually addressed to the station it goes to.
    func testWithoutHistoryTheOutboxRecipientIsSuggested() {
        XCTAssertEqual(WinlinkPeerCall.suggestion(recentPeers: [],
                                                  outboxRecipients: ["SMTP:a@example.com", "k0epi-3"]),
                       "K0EPI-3")
    }

    func testANumberSuffixedWinlinkAddressCountsAsItsCallsign() {
        XCTAssertEqual(WinlinkPeerCall.suggestion(recentPeers: [],
                                                  outboxRecipients: ["K0EPI-3@winlink.org"]),
                       "K0EPI-3")
    }

    func testNothingToSuggestLeavesTheFieldEmpty() {
        XCTAssertEqual(WinlinkPeerCall.suggestion(recentPeers: [], outboxRecipients: ["a@example.com"]), "")
    }

    // MARK: Remembering peers

    private func settings(_ defaults: UserDefaults) -> WinlinkSettings {
        WinlinkSettings(defaults: defaults, keychain: KeychainStore(service: "test-\(UUID().uuidString)"))
    }

    func testPeersAreRememberedNewestFirstWithoutRepeats() {
        let defaults = TestDefaults.make("peers")
        let s = settings(defaults)
        XCTAssertEqual(s.recentP2PPeers, [])
        s.rememberP2PPeer("K0EPI-3")
        s.rememberP2PPeer("W1AW")
        s.rememberP2PPeer("k0epi-3")
        XCTAssertEqual(s.recentP2PPeers, ["K0EPI-3", "W1AW"])
        XCTAssertEqual(settings(defaults).recentP2PPeers, ["K0EPI-3", "W1AW"], "kept across launches")
    }

    func testOnlyAHandfulOfPeersAreKept() {
        let s = settings(TestDefaults.make("peers"))
        for n in 1...8 { s.rememberP2PPeer("W\(n)AW") }
        XCTAssertEqual(s.recentP2PPeers, ["W8AW", "W7AW", "W6AW", "W5AW", "W4AW"])
    }

    /// A peer call is not a gateway exchange: it must never add the station
    /// to the RMS ladder.
    func testRememberingAPeerLeavesTheGatewayLadderAlone() {
        let s = settings(TestDefaults.make("peers"))
        s.rememberP2PPeer("K0EPI-3")
        XCTAssertEqual(s.gatewayLadder, [])
    }
}

// MARK: - Which mail goes to a peer

/// A peer is not a gateway: it delivers nothing onward to the CMS. Mail to
/// anyone else handed to it would be marked sent and never arrive, so a peer
/// exchange offers only what is addressed to that station.
final class WinlinkPeerAddressingTests: XCTestCase {

    private func message(to: [String], cc: [String] = []) -> WinlinkB2Message {
        WinlinkB2Message(mid: "PEERADDR0001", date: Date(), type: .privateMessage,
                         from: "K0EPI", to: to, cc: cc, subject: "s", mbo: "K0EPI",
                         body: Data(), attachments: [])
    }

    func testMailToThePeerGoes() {
        XCTAssertTrue(WinlinkPeerCall.isAddressed(message(to: ["K0EPI-3"]), to: "K0EPI-3"))
        XCTAssertTrue(WinlinkPeerCall.isAddressed(message(to: ["w1aw"], cc: ["k0epi-3"]), to: "K0EPI-3"))
        XCTAssertTrue(WinlinkPeerCall.isAddressed(message(to: ["K0EPI-3@winlink.org"]), to: "K0EPI-3"))
    }

    /// Winlink mail is usually addressed to the account, the bare callsign,
    /// while the peer listens on an SSID.
    func testMailToThePeersAccountGoes() {
        XCTAssertTrue(WinlinkPeerCall.isAddressed(message(to: ["K0EPI"]), to: "K0EPI-3"))
    }

    func testMailToAnyoneElseStays() {
        XCTAssertFalse(WinlinkPeerCall.isAddressed(message(to: ["N0CALL"]), to: "K0EPI-3"))
        XCTAssertFalse(WinlinkPeerCall.isAddressed(message(to: ["K0EPI-5"]), to: "K0EPI-3"),
                       "another SSID is another station")
        XCTAssertFalse(WinlinkPeerCall.isAddressed(message(to: ["SMTP:k0epi@example.com"]), to: "K0EPI-3"))
    }
}
