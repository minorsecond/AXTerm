//
//  StandardT1Tests.swift
//  AXTermTests
//
//  T1 as a classic TNC sets it: never below FRACK x (2 x digipeaters + 1),
//  where FRACK is the operator's AX.25 T1 setting. The adaptive RTO can
//  only lengthen it. The delayed-ack formula (T1PeerAckDelayTests) is kept
//  behind `useDelayedAckT1`, off by default.
//

import XCTest
@testable import AXTerm

@MainActor
final class StandardT1Tests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 2)
    private let local = AX25Address(call: "K0EPI", ssid: 3)

    func testTheFloorIsFrackTimesTwoDigisPlusOne() {
        XCTAssertEqual(AX25SessionManager.frackFloor(frack: 4, digipeaters: 0), 4)
        XCTAssertEqual(AX25SessionManager.frackFloor(frack: 4, digipeaters: 1), 12)
        XCTAssertEqual(AX25SessionManager.frackFloor(frack: 6, digipeaters: 2), 30)
        XCTAssertEqual(AX25SessionManager.frackFloor(frack: 4, digipeaters: -1), 4, "never below one hop")
    }

    func testTheFormulaIsOffByDefault() {
        XCTAssertFalse(AX25SessionManager(localCallsign: local).useDelayedAckT1)
    }

    /// The field case under the standard rule: with FRACK 6 s, a lone
    /// unpolled line is not resent at 4.3 s, and is resent once 6 s pass.
    func testT1NeverFiresBeforeFrack() throws {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = local
        manager.defaultConfig = AX25SessionConfig(rtoMin: 3.0, rtoMax: 30.0, initialRto: 6.0)
        var timerSends: [OutboundFrame] = []
        manager.onSendFrame = { timerSends.append($0) }
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))

        _ = manager.sendData(Data("B to A test 1".utf8), to: peer)
        clock.advance(by: 4.5)
        XCTAssertEqual(session.stateMachine.retryCount, 0, "T1 fired before FRACK")
        XCTAssertTrue(timerSends.isEmpty)

        clock.advance(by: 2.0)
        XCTAssertGreaterThanOrEqual(session.stateMachine.retryCount, 1, "a lost frame is still recovered")
    }

    /// Through one digipeater the floor triples, as on a TNC-2.
    func testADigipeatedPathMultipliesTheFloor() throws {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = local
        manager.defaultConfig = AX25SessionConfig(rtoMin: 3.0, rtoMax: 30.0, initialRto: 4.0)
        let path = DigiPath.from(["DIGI"])
        _ = manager.handleInboundSABM(from: peer, to: local, path: path, radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: path, radio: .primary))

        _ = manager.sendData(Data("hello".utf8), to: peer, path: path)
        clock.advance(by: 11.0)
        XCTAssertEqual(session.stateMachine.retryCount, 0, "T1 fired before 3 x FRACK on a one-digi path")
        clock.advance(by: 1.5)
        XCTAssertGreaterThanOrEqual(session.stateMachine.retryCount, 1)
    }

    /// Quick acks pull the adaptive RTO down toward rtoMin; T1 still never
    /// drops below FRACK, so a peer with a slow turnaround is not retried
    /// over its own answer.
    func testFastAcksDoNotPullT1BelowFrack() throws {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = local
        manager.defaultConfig = AX25SessionConfig(rtoMin: 3.0, rtoMax: 30.0, initialRto: 6.0)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        for _ in 0..<20 { session.timers.updateRTT(sample: 0.4) }
        XCTAssertLessThan(session.timers.rto, 6.0, "precondition: the adaptive RTO fell below FRACK")

        _ = manager.sendData(Data("hello".utf8), to: peer)
        clock.advance(by: 5.5)

        XCTAssertEqual(session.stateMachine.retryCount, 0, "T1 followed the RTO below FRACK")
    }
}
