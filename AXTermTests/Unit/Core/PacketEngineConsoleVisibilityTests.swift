//
//  PacketEngineConsoleVisibilityTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

@MainActor
final class PacketEngineConsoleVisibilityTests: XCTestCase {
    func testEmptyUIPayloadStillAppearsInTerminalConsole() {
        let settings = makeSettings()
        let engine = PacketEngine(settings: settings)

        let packet = Packet(
            from: AX25Address(call: "K0EPI", ssid: 15),
            to: AX25Address(call: "CQ"),
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: Data()
        )

        engine.handleIncomingPacket(packet)

        XCTAssertTrue(
            engine.consoleLines.contains {
                $0.kind == .packet &&
                $0.from == "K0EPI-15" &&
                $0.to == "CQ" &&
                $0.text == "[no payload]"
            },
            "UI frames with empty payload should still be visible in the terminal."
        )
    }

    func testBinaryUIPayloadUsesByteCountFallbackInTerminalConsole() {
        let settings = makeSettings()
        let engine = PacketEngine(settings: settings)

        let packet = Packet(
            from: AX25Address(call: "PEER", ssid: 1),
            to: AX25Address(call: "CQ"),
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: Data([0x00, 0x01, 0x02, 0x03])
        )

        engine.handleIncomingPacket(packet)

        XCTAssertTrue(
            engine.consoleLines.contains {
                $0.kind == .packet &&
                $0.from == "PEER-1" &&
                $0.to == "CQ" &&
                $0.text == "[4 bytes]"
            },
            "Binary UI payload should be visible with a byte-count placeholder."
        )
    }

    /// Smoke run 2026-10-03-1, issue 1: an AXTerm broadcast is AXDP chat in a
    /// UI frame (spec §6), and the receiving terminal showed "[48 bytes]".
    func testAXDPChatBroadcastShowsItsText() {
        let engine = PacketEngine(settings: makeSettings())
        let chat = AXDP.Message(type: .chat, sessionId: 0, messageId: 7,
                                payload: Data("smoke 0.1 broadcast".utf8))
        let packet = Packet(
            from: AX25Address(call: "K0EPI", ssid: 2),
            to: AX25Address(call: "CQ"),
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: chat.encode()
        )

        engine.handleIncomingPacket(packet)

        let lines = engine.consoleLines.filter { $0.kind == .packet && $0.from == "K0EPI-2" }
        XCTAssertEqual(lines.map(\.text), ["smoke 0.1 broadcast"])
    }

    /// AXDP that is not chat (a ping, a capability probe) is protocol, not
    /// something the operator typed. It keeps a label instead of a byte count.
    func testOtherAXDPInAUIFrameIsLabeled() {
        let engine = PacketEngine(settings: makeSettings())
        let ping = AXDP.Message(type: .ping, sessionId: 0, messageId: 1)
        let packet = Packet(
            from: AX25Address(call: "K0EPI", ssid: 2),
            to: AX25Address(call: "CQ"),
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: ping.encode()
        )

        engine.handleIncomingPacket(packet)

        let lines = engine.consoleLines.filter { $0.kind == .packet && $0.from == "K0EPI-2" }
        XCTAssertEqual(lines.map(\.text), ["[AXDP ping]"])
    }

    private func makeSettings() -> AppSettingsStore {
        let suiteName = TestDefaults.name("AXTermTests")
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }
}
