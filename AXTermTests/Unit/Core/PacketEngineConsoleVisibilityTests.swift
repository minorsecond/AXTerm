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

    private func makeSettings() -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return AppSettingsStore(defaults: defaults)
    }
}
