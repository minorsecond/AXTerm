//
//  NodeTalkHostTests.swift
//  AXTermTests
//
//  The node's part of TALK: it asks the station to page the operator,
//  gives the link up when the operator answers, and says so when nobody
//  does. Over a NET/ROM circuit there is no AX.25 link to hand the
//  operator's terminal, so TALK needs a direct connection.
//

import XCTest
@testable import AXTerm

@MainActor
final class NodeTalkHostTests: XCTestCase {

    private var said = ""
    private var asked: [(key: String, caller: String)] = []

    private func node() -> NetRomNodeHost {
        let host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm") }
        host.onTalkRequest = { [unowned self] key, caller in self.asked.append((key, caller)) }
        host.attachAX25Caller(key: "S1", callsign: "K0EPI-3", dialed: "EPINOD",
                              send: { [unowned self] in self.said += String(decoding: $0, as: UTF8.self) },
                              hangUp: {})
        said = ""
        return host
    }

    func testTalkAsksTheStationToPage() {
        let host = node()
        host.ax25CallerReceived(key: "S1", data: Data("t\r".utf8))
        XCTAssertEqual(asked.map(\.key), ["S1"])
        XCTAssertEqual(asked.map(\.caller), ["K0EPI-3"])
        XCTAssertTrue(said.contains("Paging the operator"), said)
        XCTAssertFalse(said.contains("EPINOD:K0EPI-7}"), "no prompt while paging")
    }

    func testNobodyAnsweringBringsThePromptBack() {
        let host = node()
        host.ax25CallerReceived(key: "S1", data: Data("t\r".utf8))
        said = ""
        host.talkDeclined(key: "S1")
        XCTAssertTrue(said.contains("The operator isn't at the station."), said)
        XCTAssertTrue(said.hasSuffix("EPINOD:K0EPI-7} "), said)
    }

    /// Answered, the node lets the link go, keeping the caller's owner
    /// sign-in for the way back.
    func testAnAnsweredCallerLeavesTheNode() {
        let host = node()
        let owner = host.yieldForTalk(key: "S1")
        XCTAssertEqual(owner?.caller, "K0EPI-3")
        said = ""
        host.ax25CallerReceived(key: "S1", data: Data("i\r".utf8))
        XCTAssertEqual(said, "", "the node no longer answers this link")
        XCTAssertNil(host.yieldForTalk(key: "S1"))
    }

    func testOverACircuitTalkNeedsADirectLink() {
        let host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm") }
        host.onTalkRequest = { [unowned self] key, caller in self.asked.append((key, caller)) }
        let ops = FakeCircuitOps()
        host.useCircuitOps(ops)
        let id = NetRomCircuitID()
        host.inboundCircuitOpened(id, caller: "K0EPI-3")
        host.circuitConnected(id)
        ops.sent.removeAll()
        host.consumeCircuit(id: id, data: Data("talk\r".utf8))
        XCTAssertTrue(asked.isEmpty)
        let text = ops.sent.map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertTrue(text.contains("TALK needs a direct AX.25 connection"), text)
        XCTAssertFalse(text.contains("Paging"), text)
        XCTAssertTrue(text.hasSuffix("EPINOD:K0EPI-7} "), text)
    }
}

private final class FakeCircuitOps: NodeCircuitOps {
    var sent: [Data] = []
    func send(_ data: Data, on id: NetRomCircuitID) { sent.append(data) }
    func disconnect(_ id: NetRomCircuitID) {}
    func openNodeCircuit(to destination: AX25Address) -> NetRomCircuitID? { nil }
}
