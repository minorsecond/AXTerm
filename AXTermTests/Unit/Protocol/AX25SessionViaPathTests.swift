//
//  AX25SessionViaPathTests.swift
//  AXTermTests
//
//  Tests for threading the digipeater via path through to session chat lines.
//  Verifies that lastReceivedVia is set on inbound I-frames and that the
//  callback chain delivers it to appendSessionChatLine / ConsoleLine.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25SessionViaPathTests: XCTestCase {

    // MARK: - Helpers

    private func makeManager() -> AX25SessionManager {
        let manager = AX25SessionManager()
        manager.localCallsign = AX25Address(call: "K0EPI", ssid: 7)
        return manager
    }

    private func connectSession(
        manager: AX25SessionManager,
        destination: AX25Address,
        path: DigiPath = DigiPath()
    ) -> AX25Session {
        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)
        manager.handleInboundUA(from: destination, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    private func makeEngine() -> PacketEngine {
        let settings = AppSettingsStore()
        settings.myCallsign = "K0EPI-7"
        return PacketEngine(settings: settings)
    }

    // MARK: - lastReceivedVia is set on inbound I-frame

    func testLastReceivedViaSetOnDigipeatedIFrame() {
        let manager = makeManager()
        let dest = AX25Address(call: "KB5YZB", ssid: 7)
        let digiPath = DigiPath.from(["DRL"])
        let session = connectSession(manager: manager, destination: dest, path: digiPath)

        // Initially empty
        XCTAssertTrue(session.lastReceivedVia.isEmpty)

        // Receive an I-frame via DRL
        let payload = Data("Hello\r".utf8)
        _ = manager.handleInboundIFrame(
            from: dest, path: digiPath, channel: 0,
            ns: 0, nr: 0, pf: false, payload: payload
        )

        XCTAssertEqual(session.lastReceivedVia, ["DRL"],
                       "lastReceivedVia should reflect the digi path from the I-frame")
    }

    func testLastReceivedViaEmptyForDirectIFrame() {
        let manager = makeManager()
        let dest = AX25Address(call: "N0HI", ssid: 0)
        let session = connectSession(manager: manager, destination: dest)

        let payload = Data("Hi\r".utf8)
        _ = manager.handleInboundIFrame(
            from: dest, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: false, payload: payload
        )

        XCTAssertTrue(session.lastReceivedVia.isEmpty,
                      "Direct I-frame should leave lastReceivedVia empty")
    }

    func testLastReceivedViaUpdatedOnSubsequentIFrames() {
        let manager = makeManager()
        let dest = AX25Address(call: "KB5YZB", ssid: 7)
        let digiPath = DigiPath.from(["DRL"])
        let session = connectSession(manager: manager, destination: dest, path: digiPath)

        // First I-frame via DRL
        _ = manager.handleInboundIFrame(
            from: dest, path: digiPath, channel: 0,
            ns: 0, nr: 0, pf: false, payload: Data("Line1\r".utf8)
        )
        XCTAssertEqual(session.lastReceivedVia, ["DRL"])

        // Second I-frame direct (no digi) — simulates path change
        _ = manager.handleInboundIFrame(
            from: dest, path: DigiPath(), channel: 0,
            ns: 1, nr: 0, pf: false, payload: Data("Line2\r".utf8)
        )
        XCTAssertTrue(session.lastReceivedVia.isEmpty,
                      "lastReceivedVia should update to reflect each I-frame's actual path")
    }

    func testLastReceivedViaMultiHopPath() {
        let manager = makeManager()
        let dest = AX25Address(call: "WH6ANH", ssid: 0)
        let multiPath = DigiPath.from(["DRL", "N0HI-2"])
        let session = connectSession(manager: manager, destination: dest, path: multiPath)

        _ = manager.handleInboundIFrame(
            from: dest, path: multiPath, channel: 0,
            ns: 0, nr: 0, pf: false, payload: Data("Test\r".utf8)
        )

        XCTAssertEqual(session.lastReceivedVia, ["DRL", "N0HI-2"],
                       "Multi-hop path should be fully captured")
    }

    // MARK: - onDataReceived callback has access to via path

    func testOnDataReceivedCanReadLastReceivedVia() {
        let manager = makeManager()
        let dest = AX25Address(call: "KB5YZB", ssid: 7)
        let digiPath = DigiPath.from(["DRL"])
        _ = connectSession(manager: manager, destination: dest, path: digiPath)

        var capturedVia: [String]?
        manager.onDataReceived = { session, _ in
            capturedVia = session.lastReceivedVia
        }

        _ = manager.handleInboundIFrame(
            from: dest, path: digiPath, channel: 0,
            ns: 0, nr: 0, pf: false, payload: Data("Hello\r".utf8)
        )

        XCTAssertEqual(capturedVia, ["DRL"],
                       "onDataReceived should see lastReceivedVia already set")
    }

    func testOnDataReceivedSeesEmptyViaForDirectFrame() {
        let manager = makeManager()
        let dest = AX25Address(call: "N0HI", ssid: 0)
        _ = connectSession(manager: manager, destination: dest)

        var capturedVia: [String]?
        manager.onDataReceived = { session, _ in
            capturedVia = session.lastReceivedVia
        }

        _ = manager.handleInboundIFrame(
            from: dest, path: DigiPath(), channel: 0,
            ns: 0, nr: 0, pf: false, payload: Data("Hi\r".utf8)
        )

        XCTAssertNotNil(capturedVia)
        XCTAssertTrue(capturedVia?.isEmpty ?? false,
                      "Direct frame should produce empty via in callback")
    }

    // MARK: - appendSessionChatLine passes via to ConsoleLine

    func testAppendSessionChatLineWithVia() {
        let engine = makeEngine()

        engine.appendSessionChatLine(from: "KB5YZB-7", text: "Hello", via: ["DRL"])

        guard let lastLine = engine.consoleLines.last else {
            XCTFail("Expected a console line to be appended")
            return
        }
        XCTAssertEqual(lastLine.via, ["DRL"],
                       "ConsoleLine should carry the via path")
        XCTAssertEqual(lastLine.from, "KB5YZB-7")
        XCTAssertEqual(lastLine.to, "K0EPI-7")
    }

    func testAppendSessionChatLineWithoutVia() {
        let engine = makeEngine()

        engine.appendSessionChatLine(from: "N0HI", text: "Direct message")

        guard let lastLine = engine.consoleLines.last else {
            XCTFail("Expected a console line to be appended")
            return
        }
        XCTAssertTrue(lastLine.via.isEmpty,
                      "Direct message should have empty via")
    }

    func testAppendSessionChatLineMultiHopVia() {
        let engine = makeEngine()

        engine.appendSessionChatLine(from: "WH6ANH", text: "Multi-hop", via: ["DRL", "N0HI-2"])

        guard let lastLine = engine.consoleLines.last else {
            XCTFail("Expected a console line to be appended")
            return
        }
        XCTAssertEqual(lastLine.via, ["DRL", "N0HI-2"],
                       "Multi-hop via should be preserved on ConsoleLine")
    }
}
