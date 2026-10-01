//
//  TurnaroundEvidenceSessionTests.swift
//  AXTermTests
//
//  The link layer's side of the turnaround hint: each session keeps its own
//  evidence, fed from what the session already records (first sends, the
//  retransmissions that mark Karn's ambiguous frames, acknowledgments) and
//  from the time the coordinator last heard the station. See
//  TurnaroundEvidenceTests for the rule itself.
//

import XCTest
@testable import AXTerm

@MainActor
final class TurnaroundEvidenceSessionTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 2)
    private let local = AX25Address(call: "K0EPI", ssid: 3)

    private func makeManager() -> (AX25SessionManager, AX25VirtualClock) {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = local
        return (manager, clock)
    }

    private func connect(_ manager: AX25SessionManager, _ clock: AX25VirtualClock) throws -> AX25Session {
        _ = manager.connect(to: peer)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        clock.currentTime += 1
        manager.noteFrameHeard(from: peer, path: DigiPath(), radio: .primary)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    /// A reply sent at once is missed; the T1 retry five seconds later is
    /// acknowledged. One sample in each class.
    private func missedReplyThenHeardRetry(_ manager: AX25SessionManager, _ clock: AX25VirtualClock,
                                           _ session: AX25Session) {
        clock.currentTime += 10
        manager.noteFrameHeard(from: peer, path: DigiPath(), radio: .primary)
        _ = manager.sendData(Data("reply".utf8), to: peer)
        clock.currentTime += 5
        _ = manager.handleT1Timeout(session: session)
        clock.currentTime += 1
        manager.noteFrameHeard(from: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                          nr: session.vs, pf: true, isCommand: false)
    }

    func testTheLinkLayerFeedsTheEvidence() throws {
        let (manager, clock) = makeManager()
        let session = try connect(manager, clock)

        missedReplyThenHeardRetry(manager, clock, session)

        let tally = session.turnaroundEvidence.tally
        XCTAssertEqual(tally.turnaroundSent, 1, "\(tally)")
        XCTAssertEqual(tally.turnaroundMissed, 1, "\(tally)")
        XCTAssertEqual(tally.laterSent, 1, "\(tally)")
        XCTAssertEqual(tally.laterMissed, 0, "\(tally)")
    }

    func testARejectedReplyCountsAsMissed() throws {
        let (manager, clock) = makeManager()
        let session = try connect(manager, clock)

        clock.currentTime += 10
        manager.noteFrameHeard(from: peer, path: DigiPath(), radio: .primary)
        _ = manager.sendData(Data("reply".utf8), to: peer)
        // The peer asks for it again, and hears the resend this time.
        clock.currentTime += 3
        manager.noteFrameHeard(from: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundREJ(from: peer, path: DigiPath(), radio: .primary,
                                     nr: 0, pf: false, isCommand: false)
        clock.currentTime += 2
        _ = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                          nr: session.vs, pf: false, isCommand: false)

        let tally = session.turnaroundEvidence.tally
        XCTAssertEqual(tally.turnaroundSent, 2, "the reply and its immediate resend: \(tally)")
        XCTAssertEqual(tally.turnaroundMissed, 1, "\(tally)")
    }

    func testEachConnectionStartsWithNoEvidence() throws {
        let (manager, clock) = makeManager()
        let first = try connect(manager, clock)
        missedReplyThenHeardRetry(manager, clock, first)
        XCTAssertEqual(first.turnaroundEvidence.tally.turnaroundSent, 1)

        manager.forceDisconnect(session: first)
        clock.currentTime += 1
        let second = try connect(manager, clock)
        XCTAssertEqual(second.turnaroundEvidence.tally.turnaroundSent, 0)
        XCTAssertEqual(second.turnaroundEvidence.tally.laterSent, 0)
        XCTAssertFalse(second.turnaroundEvidence.isShowing)
    }

    func testALinkResetStartsWithNoEvidence() throws {
        let (manager, clock) = makeManager()
        let session = try connect(manager, clock)
        missedReplyThenHeardRetry(manager, clock, session)
        XCTAssertEqual(session.turnaroundEvidence.tally.turnaroundSent, 1)

        // The peer opens the link again over the live one (AX.25 §6.3.1).
        clock.currentTime += 1
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary,
                                      extended: false, pf: true)
        let current = try XCTUnwrap(manager.connectedSession(withPeer: peer, radio: .primary))
        XCTAssertEqual(current.turnaroundEvidence.tally.turnaroundSent, 0)
        XCTAssertEqual(current.turnaroundEvidence.tally.laterSent, 0)
    }

    func testTheHintComesFromTheSessionAndNamesTheStationItHears() throws {
        let (manager, clock) = makeManager()
        let session = try connect(manager, clock)
        XCTAssertEqual(session.turnaroundStation, "K0EPI-2")
        for _ in 0..<30 { missedReplyThenHeardRetry(manager, clock, session) }
        XCTAssertTrue(session.turnaroundEvidence.isShowing, "\(session.turnaroundEvidence.tally)")
    }

    func testOverADigipeaterTheStationHeardIsTheFirstHop() {
        let session = AX25Session(localAddress: local, remoteAddress: peer,
                                  path: DigiPath.from(["WIDE1-1", "K0ARK-5"]))
        XCTAssertEqual(session.turnaroundStation, "WIDE1-1",
                       "frames from the peer reach us from the first digipeater, "
                       + "and that one has to hear the reply")
    }

    // MARK: - Where frames are heard

    func testTheCoordinatorStampsFramesHeardFromTheStation() throws {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "K0EPI-3"
        let sabm = Packet(from: peer, to: local, frameType: .u, control: 0x3F)
        coordinator.handleIncomingPacket(sabm)
        let session = try XCTUnwrap(coordinator.sessionManager.connectedSession(withPeer: peer, radio: .primary))

        let rr = Packet(from: peer, to: local, frameType: .s, control: 0x01)
        coordinator.handleIncomingPacket(rr)
        let heard = try XCTUnwrap(session.turnaroundEvidence.lastHeardAt)
        XCTAssertEqual(heard, coordinator.sessionManager.clock.currentTime, accuracy: 1.0)
    }
}
