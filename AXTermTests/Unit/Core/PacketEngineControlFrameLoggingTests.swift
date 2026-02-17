//
//  PacketEngineControlFrameLoggingTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

@MainActor
final class PacketEngineControlFrameLoggingTests: XCTestCase {
    func testInboundRRFrameAddsSystemConsoleLine() {
        let settings = makeSettings()
        let engine = PacketEngine(settings: settings)

        let rrPacket = Packet(
            from: AX25Address(call: "PEER", ssid: 1),
            to: AX25Address(call: "ME", ssid: 0),
            frameType: .s,
            control: 0x21, // RR with N(R)=1
            info: Data()
        )

        engine.handleIncomingPacket(rrPacket)

        XCTAssertTrue(engine.consoleLines.contains { line in
            line.kind == .system &&
            line.text.contains("RX: PEER-1") &&
            line.text.contains("RR(1)")
        })
    }

    func testInboundUIFrameDoesNotAddControlSystemLine() {
        let settings = makeSettings()
        let engine = PacketEngine(settings: settings)

        let uiPacket = Packet(
            from: AX25Address(call: "PEER", ssid: 1),
            to: AX25Address(call: "CQ"),
            frameType: .ui,
            control: 0x03, // UI
            info: Data("hello".utf8)
        )

        engine.handleIncomingPacket(uiPacket)

        XCTAssertFalse(engine.consoleLines.contains { line in
            line.kind == .system && line.text.contains("RX: PEER-1")
        })
    }

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }
}
