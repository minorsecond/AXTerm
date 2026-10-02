//
//  BurstAckHoldTests.swift
//  AXTermTests
//
//  A receiver does not acknowledge a burst while the burst is still
//  arriving.
//
//  Field case 2026-10-01 (live test log, bug 25): with in-session growth on,
//  a session grew to K3 with 174-byte frames, about 4 s of airtime per
//  burst at 1200 baud. The receiver's T2 ran 2 s from the first frame, so
//  its delayed RR went out in a gap mid-burst; the sender filled the freed
//  slot at once and keyed over the receiver's answer to its poll, and the
//  session fell to K1, paclen 64. T2 now restarts on every frame that
//  arms it, so the delayed ack waits for a pause, and the poll on the
//  burst's last frame is answered at once as before.
//

import XCTest
@testable import AXTerm

@MainActor
final class BurstAckHoldTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 3)
    private let peer = AX25Address(call: "K0EPI", ssid: 2)

    private func connected(clock: AX25VirtualClock) -> (AX25SessionManager, AX25Session, () -> [OutboundFrame]) {
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        // T2 is clamped to 2/3 of the RTO floor; the app's 3 s floor gives
        // the 2 s T2 these tests are about.
        manager.defaultConfig = AX25SessionConfig(rtoMin: 3.0)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        return (manager, session, { sent })
    }

    private func receive(_ manager: AX25SessionManager, ns: Int, pf: Bool = false) -> OutboundFrame? {
        manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                    ns: ns, nr: 0, pf: pf, payload: Data(repeating: 0x41, count: 174))
    }

    /// Frames 1.5 s apart, each inside T2 of the one before: no RR until the
    /// burst has gone quiet for a full T2.
    func testTheDelayedAckWaitsForThePauseAfterTheBurst() {
        let clock = AX25VirtualClock()
        let (manager, _, sent) = connected(clock: clock)

        XCTAssertNil(receive(manager, ns: 0))
        clock.advance(by: 1.5)
        XCTAssertNil(receive(manager, ns: 1))
        clock.advance(by: 1.5)
        XCTAssertNil(receive(manager, ns: 2))
        clock.advance(by: 1.9)
        XCTAssertTrue(sent().isEmpty, "an RR went out while the burst was still arriving: \(sent().compactMap(\.displayInfo))")

        clock.advance(by: 0.2)
        let rrs = sent().filter { $0.displayInfo?.hasPrefix("RR") == true }
        XCTAssertEqual(rrs.count, 1)
        XCTAssertEqual(rrs.first?.nr, 3, "one cumulative ack for the whole burst")
    }

    /// The poll on the burst's last frame is answered at once, and the T2 ack
    /// that was waiting is then not sent as well.
    func testThePollEndingABurstIsAnsweredAtOnceAndOnlyOnce() {
        let clock = AX25VirtualClock()
        let (manager, _, sent) = connected(clock: clock)

        XCTAssertNil(receive(manager, ns: 0))
        clock.advance(by: 1.5)
        XCTAssertNil(receive(manager, ns: 1))
        clock.advance(by: 1.5)
        let answer = receive(manager, ns: 2, pf: true)
        XCTAssertEqual(answer?.nr, 3)
        XCTAssertEqual(answer?.controlByte.map { $0 & 0x10 }, 0x10, "F=1")

        clock.advance(by: 10)
        XCTAssertTrue(sent().isEmpty, "the poll's answer already acknowledged everything")
    }

    /// Restarting without a limit was tried once and rejected: frames
    /// arriving faster than T2 put the ack off until the sender's T1 fired
    /// first. The hold ends three T2 periods after the first frame it owes
    /// an ack for, however the frames keep coming.
    func testTheHoldIsBoundedByThreeT2Periods() {
        let clock = AX25VirtualClock()
        let (manager, _, sent) = connected(clock: clock)

        var ns = 0
        XCTAssertNil(receive(manager, ns: ns))
        for _ in 0..<3 {
            clock.advance(by: 1.5)
            ns += 1
            XCTAssertNil(receive(manager, ns: ns))
        }
        // 4.5 s after the first frame, still arriving every 1.5 s.
        clock.advance(by: 1.4)
        XCTAssertTrue(sent().isEmpty)
        clock.advance(by: 0.2)
        let rrs = sent().filter { $0.displayInfo?.hasPrefix("RR") == true }
        XCTAssertEqual(rrs.count, 1, "by 6 s after the first frame the ack is out")
        XCTAssertEqual(rrs.first?.nr, 4)
    }

    /// A single frame is acknowledged T2 after it, exactly as before.
    func testALoneFrameIsStillAckedAfterOneT2() {
        let clock = AX25VirtualClock()
        let (manager, _, sent) = connected(clock: clock)
        XCTAssertNil(receive(manager, ns: 0))
        clock.advance(by: 1.9)
        XCTAssertTrue(sent().isEmpty)
        clock.advance(by: 0.2)
        XCTAssertEqual(sent().filter { $0.displayInfo?.hasPrefix("RR") == true }.count, 1)
    }
}

