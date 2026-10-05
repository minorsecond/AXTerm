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

        let sabm = manager.connect(to: drlnod, path: path, radio: .primary)
        XCTAssertNotNil(sabm)
        manager.handleInboundUA(from: drlnod, path: path, radio: .primary)

        let session = manager.session(for: drlnod, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connected)

        // DRLNOD polls while idle. AXTerm must respond with RR(F=1), but that
        // should not perturb outbound sequence state.
        let idlePoll1 = manager.handleInboundRR(from: drlnod, path: path, radio: .primary, nr: 0, pf: true, isCommand: true)
        let idlePoll2 = manager.handleInboundRR(from: drlnod, path: path, radio: .primary, nr: 0, pf: true, isCommand: true)
        XCTAssertEqual(idlePoll1?.frameType, "s")
        XCTAssertEqual(idlePoll2?.frameType, "s")
        XCTAssertEqual(session.vs, 0)
        XCTAssertEqual(session.va, 0)

        let helpFrames = manager.sendData(Data("HELP\r".utf8), to: drlnod, path: path, radio: .primary)
        XCTAssertEqual(helpFrames.filter { $0.frameType == "i" }.count, 1)
        XCTAssertEqual(session.outstandingCount, 1)

        // First T1 expiry should immediately retransmit the outstanding frame with P=1
        // to solicit an ACK and comply with standard AX.25, avoiding unsolicited S-frame polls.
        clock.advance(by: session.secondsToT1Resend(now: clock.currentTime))
        XCTAssertEqual(timerDrivenFrames.filter { $0.frameType == "s" }.count, 0)
        XCTAssertEqual(timerDrivenFrames.filter { $0.frameType == "i" }.count, 1)
        XCTAssertEqual(timerDrivenFrames.filter { $0.frameType == "i" }.first?.controlByte.map { Int($0 & 0x10) }, 0x10)

        manager.handleInboundDM(from: drlnod, path: path, radio: .primary)
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertNil(session.t1TimerTask)

        timerDrivenFrames.removeAll()
        clock.advance(by: 20.0)
        XCTAssertTrue(timerDrivenFrames.isEmpty, "DM must leave no live T1 task behind")
    }

    /// DRLNOD's poll that acknowledges nothing is answered with RR F=1, and
    /// "Help" goes out again when our own T1 runs out (AX.25 6.2 and the 2.2
    /// SDL: a poll asks for a response, not a resend).
    ///
    /// Live trace, 2026-05-28 05:43:47: DRLNOD answered our I(0) with
    /// RR(P=1, N(R)=0). Until 2026-10-02 AXTerm resent "Help" on that poll,
    /// on the reading that waiting for T1 had let DRLNOD drop the link. The
    /// write-up of that disconnect (Docs/KB5YZB7_Flaky_Connections.md, bug
    /// #6) traced DRLNOD's DM to the poll bit AXTerm then set on idle
    /// I-frames, fixed since; resending on a poll made duplicates whenever a
    /// poll crossed new frames. To be confirmed on the air against DRLNOD.
    func testDRLNODNoAckPollIsAnsweredAndHelpIsResentAtT1() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(initialRto: 4.0, adaptiveTimeout: false)

        var timerDrivenFrames: [OutboundFrame] = []
        manager.onSendFrame = { timerDrivenFrames.append($0) }

        _ = manager.connect(to: drlnod, path: path, radio: .primary)
        manager.handleInboundUA(from: drlnod, path: path, radio: .primary)

        let session = manager.session(for: drlnod, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connected)

        let helpFrames = manager.sendData(Data("Help\r".utf8), to: drlnod, path: path, radio: .primary)
        let helpFrame = helpFrames.first { $0.frameType == "i" }
        XCTAssertEqual(helpFrame?.controlByte.map { Int($0 & 0x10) }, 0x10, "First DRLNOD command I-frame should solicit a response with P=1")
        XCTAssertEqual(session.outstandingCount, 1)

        clock.advance(by: 3.0)
        let responses = manager.handleInboundRRFrames(
            from: drlnod,
            path: path,
            radio: .primary,
            nr: 0,
            pf: true,
            isCommand: true
        )
        XCTAssertEqual(responses.count, 1, "the poll gets RR F=1 and nothing else")
        XCTAssertEqual(responses.first?.frameType, "s")
        XCTAssertEqual(responses.first?.controlByte.map { Int($0 & 0x10) }, 0x10)

        // T1 started once "Help" was out and runs out 4 s later, plus the
        // 200 ms grace before the resend. The poll does not move it.
        let resendIn = session.secondsToT1Resend(now: clock.currentTime)
        clock.advance(by: resendIn - 0.3)
        XCTAssertTrue(timerDrivenFrames.isEmpty, "nothing before T1")
        clock.advance(by: 0.35)
        let resent = timerDrivenFrames.filter { $0.frameType == "i" }
        XCTAssertEqual(resent.count, 1)
        XCTAssertEqual(resent.first?.payload, Data("Help\r".utf8))
        XCTAssertEqual(resent.first?.controlByte.map { Int($0 & 0x10) }, 0x10, "the T1 resend polls")
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.outstandingCount, 1)
    }
}
