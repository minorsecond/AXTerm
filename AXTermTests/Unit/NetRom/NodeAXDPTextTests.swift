//
//  NodeAXDPTextTests.swift
//  AXTermTests
//
//  On air 2026-10-12: the iPad sent `i` and `info` to EPINOD as AXDP chat,
//  since A answers an AXDP probe for every one of its addresses and the
//  iPad remembered the node as AXTerm. The node prompt read the AXDP bytes
//  as a command, echoed binary back, and then waited for a line end that
//  never came. It reads an AXTerm caller's AXDP text as typing now, as the
//  mailbox does, and answers a capability check inside the session.
//

import XCTest
@testable import AXTerm

@MainActor
final class NodeAXDPTextTests: XCTestCase {

    private var said = Data()
    private var text: String { String(decoding: said, as: UTF8.self) }

    private func node() -> NetRomNodeHost {
        let host = NetRomNodeHost()
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm") }
        host.attachAX25Caller(key: "S1", callsign: "K0EPI-3", dialed: "EPINOD",
                              send: { [weak self] in self?.said.append($0) }, hangUp: {})
        said = Data()
        return host
    }

    private func chat(_ line: String, id: UInt32 = 1) -> Data {
        AXDP.Message(type: .chat, sessionId: 0, messageId: id, payload: Data(line.utf8)).encode()
    }

    func testAXDPTextIsReadAsTyping() {
        let host = node()
        host.ax25CallerReceived(key: "S1", data: chat("i"))
        XCTAssertTrue(text.contains("Node EPINOD:K0EPI-7"), text)
        XCTAssertFalse(text.contains("AXT1"), text)
    }

    /// Each message is a line of its own, so the next one is answered too.
    func testEachMessageIsALine() {
        let host = node()
        host.ax25CallerReceived(key: "S1", data: chat("info", id: 1))
        said = Data()
        host.ax25CallerReceived(key: "S1", data: chat("info", id: 2))
        XCTAssertTrue(text.contains("Node EPINOD:K0EPI-7"), text)
    }

    /// A message cut across I-frames is read once it is whole.
    func testAMessageAcrossFramesIsReadWhenWhole() {
        let host = node()
        let message = chat("nodes")
        host.ax25CallerReceived(key: "S1", data: message.prefix(10))
        XCTAssertTrue(said.isEmpty)
        host.ax25CallerReceived(key: "S1", data: message.dropFirst(10))
        XCTAssertFalse(said.isEmpty)
        XCTAssertFalse(text.contains("AXT1"), text)
    }

    /// Plain typing still works on the same link.
    func testPlainTypingStillWorks() {
        let host = node()
        host.ax25CallerReceived(key: "S1", data: Data("i\r".utf8))
        XCTAssertTrue(text.contains("Node EPINOD:K0EPI-7"), text)
    }

    /// A capability check inside the session is answered, as the mailbox
    /// answers it.
    func testACapabilityCheckIsAnswered() {
        let host = node()
        var asked: (AXDP.MessageType, String)?
        host.capabilityPingHandler = { message, caller, reply in
            asked = (message.type, caller)
            reply(Data("PONG".utf8))
        }
        host.ax25CallerReceived(key: "S1", data: AXDP.Message(type: .ping, sessionId: 0, messageId: 3).encode())
        XCTAssertEqual(asked?.0, .ping)
        XCTAssertEqual(asked?.1, "K0EPI-3")
        XCTAssertEqual(text, "PONG")
    }
}
