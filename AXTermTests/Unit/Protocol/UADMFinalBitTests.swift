//
//  UADMFinalBitTests.swift
//  AXTermTests
//
//  AX.25 2.2 §6.2: a response's F bit is set to the P bit of the command it
//  answers. UA and DM answer SABM, SABME and DISC, which a station may send
//  with P=0 or P=1, so the answer's F bit must follow. A DM to an I or S
//  command is only sent for P=1 (§6.3.5), so that one always carries F=1.
//  Every check reads the control byte back off the encoded frame.
//

import XCTest
@testable import AXTerm

@MainActor
final class UADMFinalBitTests: XCTestCase {

    private let local = AX25Address(call: "LOCAL", ssid: 1)
    private let peer = AX25Address(call: "PEER", ssid: 2)

    private func makeManager() -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: local, clock: AX25VirtualClock())
        manager.defaultConfig = AX25SessionConfig(maxRetries: 3, rtoMin: 1, rtoMax: 4, initialRto: 1)
        return manager
    }

    /// The decoded frame type and F bit of `frame` as it goes on the wire.
    private func onTheWire(_ frame: OutboundFrame?, file: StaticString = #filePath,
                           line: UInt = #line) throws -> (type: String, final: Bool) {
        let frame = try XCTUnwrap(frame, "no answer", file: file, line: line)
        let bytes = frame.encodeAX25()
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: bytes), file: file, line: line)
        let control = AX25ControlFieldDecoder.decode(control: decoded.control,
                                                     controlByte1: decoded.controlByte1)
        let type = control.uType.map(\.rawValue) ?? "?"
        return (type, (decoded.control & 0x10) != 0)
    }

    private func connectedAsResponder(_ manager: AX25SessionManager) -> AX25Session {
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary, pf: true)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    // MARK: - UA

    func testUAToSABMCarriesThePollBit() throws {
        for p in [false, true] {
            let manager = makeManager()
            let answer = try onTheWire(manager.handleInboundSABM(from: peer, to: local, path: DigiPath(),
                                                                 radio: .primary, pf: p))
            XCTAssertEqual(answer.type, "UA")
            XCTAssertEqual(answer.final, p, "UA to a P=\(p ? 1 : 0) SABM")
        }
    }

    func testUAToALinkResetSABMCarriesThePollBit() throws {
        for p in [false, true] {
            let manager = makeManager()
            _ = connectedAsResponder(manager)
            let answer = try onTheWire(manager.handleInboundSABM(from: peer, to: local, path: DigiPath(),
                                                                 radio: .primary, pf: p))
            XCTAssertEqual(answer.type, "UA")
            XCTAssertEqual(answer.final, p, "UA to a P=\(p ? 1 : 0) SABM on a connected link")
        }
    }

    func testUAToACollidingSABMCarriesThePollBit() throws {
        for p in [false, true] {
            let manager = makeManager()
            _ = manager.connect(to: peer)
            let answer = try onTheWire(manager.handleInboundSABM(from: peer, to: local, path: DigiPath(),
                                                                 radio: .primary, pf: p))
            XCTAssertEqual(answer.type, "UA")
            XCTAssertEqual(answer.final, p, "UA to a P=\(p ? 1 : 0) SABM crossing ours")
        }
    }

    func testUAToDISCCarriesThePollBit() throws {
        for p in [false, true] {
            let manager = makeManager()
            let session = connectedAsResponder(manager)
            let answer = try onTheWire(manager.handleInboundDISC(from: peer, to: local, path: DigiPath(),
                                                                 radio: .primary, pf: p))
            XCTAssertEqual(answer.type, "UA")
            XCTAssertEqual(answer.final, p, "UA to a P=\(p ? 1 : 0) DISC")
            XCTAssertEqual(session.state, .disconnected)
        }
    }

    // MARK: - DM

    func testDMToSABMECarriesThePollBit() throws {
        for p in [false, true] {
            let manager = makeManager()
            let answer = try onTheWire(manager.handleInboundSABM(from: peer, to: local, path: DigiPath(),
                                                                 radio: .primary, extended: true, pf: p))
            XCTAssertEqual(answer.type, "DM")
            XCTAssertEqual(answer.final, p, "DM to a P=\(p ? 1 : 0) SABME")
        }
    }

    func testDMToDISCWithNoSessionCarriesThePollBit() throws {
        for p in [false, true] {
            let manager = makeManager()
            let answer = try onTheWire(manager.handleInboundDISC(from: peer, to: local, path: DigiPath(),
                                                                 radio: .primary, pf: p))
            XCTAssertEqual(answer.type, "DM")
            XCTAssertEqual(answer.final, p, "DM to a P=\(p ? 1 : 0) DISC with no link")
        }
    }

    func testDMToDISCWhileConnectingCarriesThePollBit() throws {
        for p in [false, true] {
            let manager = makeManager()
            _ = manager.connect(to: peer)
            let answer = try onTheWire(manager.handleInboundDISC(from: peer, to: local, path: DigiPath(),
                                                                 radio: .primary, pf: p))
            XCTAssertEqual(answer.type, "DM")
            XCTAssertEqual(answer.final, p, "DM to a P=\(p ? 1 : 0) DISC while our SABM is out")
        }
    }

    func testAnswersToDISCAndSABMWhileDisconnectingCarryThePollBit() throws {
        for p in [false, true] {
            let manager = makeManager()
            let session = connectedAsResponder(manager)
            XCTAssertNotNil(manager.disconnect(session: session))
            XCTAssertEqual(session.state, .disconnecting)
            let sabm = try onTheWire(manager.handleInboundSABM(from: peer, to: local, path: DigiPath(),
                                                               radio: .primary, pf: p))
            XCTAssertEqual(sabm.type, "DM")
            XCTAssertEqual(sabm.final, p, "DM to a P=\(p ? 1 : 0) SABM while our DISC is out")
            let disc = try onTheWire(manager.handleInboundDISC(from: peer, to: local, path: DigiPath(),
                                                               radio: .primary, pf: p))
            // Figure C4.3: a DISC crossing ours is answered UA, F = P.
            XCTAssertEqual(disc.type, "UA")
            XCTAssertEqual(disc.final, p, "UA to a P=\(p ? 1 : 0) DISC crossing ours")
        }
    }

    /// I and S commands draw DM only when they poll, so the DM is F=1, and
    /// a P=0 command is still ignored.
    func testDMToPollsWithNoSessionStaysFinal() throws {
        let manager = makeManager()
        let iPoll = try onTheWire(manager.handleInboundIFrame(from: peer, to: local, path: DigiPath(), radio: .primary,
                                                              ns: 0, nr: 0, pf: true, payload: Data("x".utf8)))
        XCTAssertEqual(iPoll.type, "DM")
        XCTAssertTrue(iPoll.final)
        let rrPoll = try onTheWire(manager.handleInboundRRFrames(from: peer, to: local, path: DigiPath(),
                                                                 radio: .primary, nr: 0, pf: true,
                                                                 isCommand: true).first)
        XCTAssertEqual(rrPoll.type, "DM")
        XCTAssertTrue(rrPoll.final)
        XCTAssertNil(manager.handleInboundIFrame(from: peer, to: local, path: DigiPath(), radio: .primary,
                                                 ns: 0, nr: 0, pf: false, payload: Data("x".utf8)))
        XCTAssertTrue(manager.handleInboundRRFrames(from: peer, to: local, path: DigiPath(), radio: .primary,
                                                    nr: 0, pf: false, isCommand: true).isEmpty)
    }
}
