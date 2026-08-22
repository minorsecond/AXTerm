//
//  DRLNODDisconnectRegressionTests.swift
//  AXTermTests
//
//  Deterministic replay of the DRLNOD live-RF disconnect pattern from the
//  console log: UA, repeated RR(P=1) polls, one HELP I-frame, T1 expiry, DM.
//  This does not transmit on RF; it exercises the same session hooks with a
//  virtual clock so it is safe to run in CI and during development.
//

import XCTest
@testable import AXTerm

@MainActor
final class DRLNODDisconnectRegressionTests: XCTestCase {
    private let local = AX25Address(call: "K0EPI", ssid: 7)
    private let drlnod = AX25Address(call: "DRLNOD", ssid: 0)
    private let path = DigiPath()

    func testDRLNODStyleDMCancelsTimersAndDoesNotDuplicateHelpOnFirstT1() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(initialRto: 4.0, adaptiveTimeout: false)

        var timerDrivenFrames: [OutboundFrame] = []
        manager.onSendFrame = { timerDrivenFrames.append($0) }

        let sabm = manager.connect(to: drlnod, path: path, channel: 0)
        XCTAssertNotNil(sabm)
        manager.handleInboundUA(from: drlnod, path: path, channel: 0)

        let session = manager.session(for: drlnod, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected)

        // DRLNOD polls while idle. AXTerm must respond with RR(F=1), but that
        // should not perturb outbound sequence state.
        let idlePoll1 = manager.handleInboundRR(from: drlnod, path: path, channel: 0, nr: 0, pf: true, isCommand: true)
        let idlePoll2 = manager.handleInboundRR(from: drlnod, path: path, channel: 0, nr: 0, pf: true, isCommand: true)
        XCTAssertEqual(idlePoll1?.frameType, "s")
        XCTAssertEqual(idlePoll2?.frameType, "s")
        XCTAssertEqual(session.vs, 0)
        XCTAssertEqual(session.va, 0)

        let helpFrames = manager.sendData(Data("HELP\r".utf8), to: drlnod, path: path, channel: 0)
        XCTAssertEqual(helpFrames.filter { $0.frameType == "i" }.count, 1)
        XCTAssertEqual(session.outstandingCount, 1)

        // First T1 expiry should immediately retransmit the outstanding frame with P=1
        // to solicit an ACK and comply with standard AX.25, avoiding unsolicited S-frame polls.
        clock.advance(by: 4.21)
        XCTAssertEqual(timerDrivenFrames.filter { $0.frameType == "s" }.count, 0)
        XCTAssertEqual(timerDrivenFrames.filter { $0.frameType == "i" }.count, 1)
        XCTAssertEqual(timerDrivenFrames.filter { $0.frameType == "i" }.first?.controlByte.map { Int($0 & 0x10) }, 0x10)

        manager.handleInboundDM(from: drlnod, path: path, channel: 0)
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertNil(session.t1TimerTask)
        XCTAssertNil(session.t1PendingRetransmitTask)

        timerDrivenFrames.removeAll()
        clock.advance(by: 20.0)
        XCTAssertTrue(timerDrivenFrames.isEmpty, "DM must leave no live T1 task behind")
    }

    func testDRLNODNoAckPollRetransmitsHelpBeforeOriginalT1Fires() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(initialRto: 4.0, adaptiveTimeout: false)

        var timerDrivenFrames: [OutboundFrame] = []
        manager.onSendFrame = { timerDrivenFrames.append($0) }

        _ = manager.connect(to: drlnod, path: path, channel: 0)
        manager.handleInboundUA(from: drlnod, path: path, channel: 0)

        let session = manager.session(for: drlnod, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected)

        let helpFrames = manager.sendData(Data("Help\r".utf8), to: drlnod, path: path, channel: 0)
        let helpFrame = helpFrames.first { $0.frameType == "i" }
        XCTAssertEqual(helpFrame?.controlByte.map { Int($0 & 0x10) }, 0x10, "First DRLNOD command I-frame should solicit a response with P=1")
        XCTAssertEqual(session.outstandingCount, 1)

        // Live trace, 2026-05-28 05:43:47: DRLNOD answered our I(0) with
        // RR(P=1,N(R)=0), which polls us but does not ACK Help. Respond with
        // RR(F=1) and retransmit once immediately instead of waiting for the
        // original T1 to expire and letting DRLNOD time us out.
        clock.advance(by: 3.0)
        let responses = manager.handleInboundRRFrames(
            from: drlnod,
            path: path,
            channel: 0,
            nr: 0,
            pf: true,
            isCommand: true
        )

        XCTAssertEqual(responses.filter { $0.frameType == "s" }.count, 1)
        let retransmits = responses.filter { $0.frameType == "i" }
        XCTAssertEqual(retransmits.count, 1)
        XCTAssertEqual(retransmits.first?.payload, Data("Help\r".utf8))
        XCTAssertEqual(retransmits.first?.controlByte.map { Int($0 & 0x10) }, 0x10)

        clock.advance(by: 1.21)
        XCTAssertTrue(timerDrivenFrames.isEmpty, "The original T1 should be cancelled/restarted by the poll recovery")
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.outstandingCount, 1)
    }
}
