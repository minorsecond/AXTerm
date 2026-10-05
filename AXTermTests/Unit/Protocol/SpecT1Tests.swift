//
//  SpecT1Tests.swift
//  AXTermTests
//
//  T1 exactly as AX.25 2.2 defines it: Appendix C, Figure C4.7b "Select T1"
//  (2017 revision), and §6.7.1.1 for the initial default.
//
//  Smoke run 2026-10-03-1, issue 34: A (705) sent SABM, its T1 fired at 4 s,
//  and the second SABM crossed B (ID-50)'s UA. T1 was a TCP-style RTO with
//  a 4 s start, doubled on each retry. The operator asked for the spec,
//  exactly. These replace StandardT1Tests and T1PeerAckDelayTests, which
//  pinned the FRACK floor and the delayed-ack formula the spec does not have.
//

import XCTest
@testable import AXTerm

@MainActor
final class SpecT1Tests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)
    private let local = AX25Address(call: "K0EPI", ssid: 2)

    // MARK: - Select T1 (Figure C4.7b)

    func testT1VStartsAtTheInitialSRT() {
        let timers = AX25SessionTimers(initialSRT: 3.0)
        XCTAssertEqual(timers.srt, 3.0)
        XCTAssertEqual(timers.rto, 3.0, "T1V's default initial value is the initial value of SRT")
        XCTAssertNil(timers.srtt, "the initial default is not a measurement")
    }

    /// RC = 0: SRT ← 7·SRT/8 + T1/8 − (remaining time on T1)/8, the same as
    /// 7/8·SRT + 1/8·(time T1 ran); then T1V ← 2·SRT.
    func testWithNoRetriesTheTimeT1RanFoldsIntoSRT() {
        var timers = AX25SessionTimers(initialSRT: 3.0)
        timers.selectT1(retryCount: 0, t1Expired: false, t1Elapsed: 1.0)
        XCTAssertEqual(timers.srt, 2.75, accuracy: 1e-9)
        XCTAssertEqual(timers.rto, 5.5, accuracy: 1e-9)
        XCTAssertEqual(timers.srtt ?? 0, 2.75, accuracy: 1e-9)
    }

    /// RC ≠ 0 after T1 expired: T1V ← RC·0.25 s + 2·SRT. Linear; nothing
    /// doubles.
    func testAfterARetryT1VIsAQuarterSecondPerRetryPlusTwiceSRT() {
        var timers = AX25SessionTimers(initialSRT: 3.0)
        timers.selectT1(retryCount: 1, t1Expired: true, t1Elapsed: nil)
        XCTAssertEqual(timers.rto, 6.25, accuracy: 1e-9)
        timers.selectT1(retryCount: 2, t1Expired: true, t1Elapsed: nil)
        XCTAssertEqual(timers.rto, 6.5, accuracy: 1e-9)
        XCTAssertEqual(timers.srt, 3.0, "a retry never changes SRT")
    }

    /// RC ≠ 0 with T1 stopped, not expired: the round trip is ambiguous and
    /// T1V stays.
    func testAnAcknowledgmentAfterRetriesLeavesT1VAlone() {
        var timers = AX25SessionTimers(initialSRT: 3.0)
        timers.selectT1(retryCount: 2, t1Expired: true, t1Elapsed: nil)
        timers.selectT1(retryCount: 2, t1Expired: false, t1Elapsed: 1.0)
        XCTAssertEqual(timers.rto, 6.5, accuracy: 1e-9)
        XCTAssertEqual(timers.srt, 3.0)
    }

    func testAnImpossibleTimeIsNotASample() {
        var timers = AX25SessionTimers(initialSRT: 3.0)
        for bad in [0.0, -1.0, .nan, .infinity] {
            timers.selectT1(retryCount: 0, t1Expired: false, t1Elapsed: bad)
        }
        timers.selectT1(retryCount: 0, t1Expired: false, t1Elapsed: nil)
        XCTAssertEqual(timers.srt, 3.0)
        XCTAssertEqual(timers.rto, 3.0)
    }

    /// With adaptive timing off SRT stays at the initial default; the retry
    /// rule still applies.
    func testWithoutLearningOnlyTheRetryRuleApplies() {
        var timers = AX25SessionTimers(initialSRT: 3.0, adaptiveTimeout: false)
        timers.selectT1(retryCount: 0, t1Expired: false, t1Elapsed: 1.0)
        XCTAssertEqual(timers.rto, 3.0)
        timers.selectT1(retryCount: 1, t1Expired: true, t1Elapsed: nil)
        XCTAssertEqual(timers.rto, 6.25, accuracy: 1e-9)
    }

    /// Figure C4.2, UA with V(S) ≠ V(A): SRT ← initial default, T1V ← 2·SRT.
    func testReestablishingWithFramesLostRestartsFromTheInitialDefault() {
        var timers = AX25SessionTimers(initialSRT: 3.0)
        timers.selectT1(retryCount: 0, t1Expired: false, t1Elapsed: 1.0)
        timers.resetForReestablishment()
        XCTAssertEqual(timers.srt, 3.0)
        XCTAssertEqual(timers.rto, 6.0)
    }

    // MARK: - The initial default (§6.7.1.1)

    func testTheConfiguredT1IsScaledForDigipeaters() {
        XCTAssertEqual(AX25SessionTimers.initialSRT(t1Setting: 3, digipeaters: 0, maxFrameBytes: 128,
                                                    keyUpSeconds: nil), 3)
        XCTAssertEqual(AX25SessionTimers.initialSRT(t1Setting: 3, digipeaters: 1, maxFrameBytes: 128,
                                                    keyUpSeconds: nil), 9)
        XCTAssertEqual(AX25SessionTimers.initialSRT(t1Setting: 3, digipeaters: 2, maxFrameBytes: 128,
                                                    keyUpSeconds: nil), 15)
    }

    /// "At least twice the amount of time it would take to send maximum
    /// length frame to the distant TNC and get the proper response frame
    /// back." B (ID-50)'s TNC4 keys up in 0.8 s; a 128-byte frame takes
    /// 146 bytes on the air and an RR 17, at 1200 bit/s.
    func testItIsNeverLessThanTwiceAFullFrameRoundTrip() {
        let srt = AX25SessionTimers.initialSRT(t1Setting: 3, digipeaters: 0, maxFrameBytes: 128,
                                               keyUpSeconds: 0.8, peerKeyUpSeconds: 0.8)
        let roundTrip = (0.8 + 146.0 * 8 / 1200) + (0.8 + 17.0 * 8 / 1200)
        XCTAssertEqual(srt, 2 * roundTrip, accuracy: 1e-9)
        XCTAssertGreaterThan(srt, 5.3)
    }

    /// The issue 34 link: A (705)'s frames reach the air about 4.3 s after
    /// it asks to key (Warbler's PTT confirmation, the radio's buffer and
    /// the TX delay); B answered 3.9 s after the SABM went to the radio.
    func testA705LinkStartsLongEnoughForTheAnswer() {
        let srt = AX25SessionTimers.initialSRT(t1Setting: 3, digipeaters: 0, maxFrameBytes: 128,
                                               keyUpSeconds: 4.3, peerKeyUpSeconds: 0.3)
        XCTAssertGreaterThan(srt, 3.9 + 1, "the first SABM's T1 must outlast B's answer")
    }

    // MARK: - On a link

    private func manager(_ config: AX25SessionConfig = AX25SessionConfig(initialRto: 3.0))
        -> (AX25SessionManager, AX25VirtualClock) {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = local
        manager.defaultConfig = config
        return (manager, clock)
    }

    private func airtime(_ frame: OutboundFrame) -> Double {
        Double(AX25Session.airBytes(frame)) * 8 / 1200
    }

    /// The first SABM waits the initial SRT; each retry waits RC·0.25 s +
    /// 2·SRT (Figure C4.2's T1 expiry calls Select T1). T1 runs from when
    /// the SABM has left the radio (no key-up time here, so its airtime),
    /// and AXTerm resends 0.2 s after T1 fires.
    func testSABMRetriesFollowTheSpec() throws {
        let (manager, clock) = manager()
        var sabms: [(at: Double, frame: OutboundFrame)] = []
        manager.onSendFrame = { sabms.append((clock.currentTime, $0)) }   // only SABMs while connecting
        let first = try XCTUnwrap(manager.connect(to: peer))
        sabms.append((clock.currentTime, first))

        for _ in 0..<3 { clock.advance(by: 7.0) }

        XCTAssertGreaterThanOrEqual(sabms.count, 4, "\(sabms.map(\.at))")
        guard sabms.count >= 4 else { return }
        let air = airtime(first)
        XCTAssertEqual(sabms[1].at - sabms[0].at, air + 3.0 + 0.2, accuracy: 0.02)
        XCTAssertEqual(sabms[2].at - sabms[1].at, air + 6.25 + 0.2, accuracy: 0.02)
        XCTAssertEqual(sabms[3].at - sabms[2].at, air + 6.5 + 0.2, accuracy: 0.02)
    }

    /// A UA to the only SABM is a round trip: SRT learns it, T1V = 2·SRT.
    func testTheUAToAFirstSABMIsASample() throws {
        let (manager, clock) = manager()
        let sabm = try XCTUnwrap(manager.connect(to: peer))
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        clock.currentTime += 2.0
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
        let ran = 2.0 - airtime(sabm)
        XCTAssertEqual(session.timers.srt, 3.0 * 7 / 8 + ran / 8, accuracy: 1e-6)
        XCTAssertEqual(session.timers.rto, 2 * session.timers.srt, accuracy: 1e-9)
    }

    /// On a connected link, retries keep T1V (Figure C4.5c does not call
    /// Select T1); each T1 runs from when the frame before it left the radio.
    func testConnectedRetriesKeepT1() throws {
        let (manager, clock) = manager()
        var sent: [(at: Double, frame: OutboundFrame)] = []
        manager.onSendFrame = { sent.append((clock.currentTime, $0)) }   // each T1 expiry's poll or resend
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        let t1 = session.timers.rto

        let first = try XCTUnwrap(manager.sendData(Data("hello".utf8), to: peer).first)
        sent.insert((clock.currentTime, first), at: 0)
        for _ in 0..<3 { clock.advance(by: t1 + 1.0) }

        XCTAssertGreaterThanOrEqual(sent.count, 4, "\(sent.map(\.at))")
        guard sent.count >= 4 else { return }
        // Each gap is the previous frame's airtime, T1V and the 0.2 s grace;
        // a poll the resend replaced may still be counted, an RR's 0.12 s.
        for i in 1...3 {
            let gap = sent[i].at - sent[i - 1].at - airtime(sent[i - 1].frame) - 0.2
            XCTAssertTrue(gap >= t1 - 0.01 && gap <= t1 + 0.13, "retry \(i): \(gap) for T1V \(t1)")
        }
        XCTAssertEqual(session.timers.rto, t1)
    }

    /// Frames added to a burst move T1's start to the burst's end, so four
    /// 256-byte frames (about 7.4 s at 1200 bit/s) are not retried while
    /// they are still going out.
    func testABurstIsNotRetriedWhileItIsStillGoingOut() throws {
        let (manager, clock) = manager(AX25SessionConfig(windowSize: 4, paclen: 256, initialRto: 3.0))
        var resent = 0
        manager.onSendFrame = { _ in resent += 1 }
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        let frames = manager.sendData(Data(repeating: 0x41, count: 4 * 256), to: peer)
        XCTAssertEqual(frames.count, 4)
        let burst = frames.map(airtime).reduce(0, +)
        XCTAssertGreaterThan(burst, 7)

        clock.advance(by: burst + session.timers.rto - 0.1)
        XCTAssertEqual(resent, 0, "T1 fired while the burst was still on the air")
        XCTAssertEqual(session.stateMachine.retryCount, 0)
    }

    /// Check I Frame Acknowledged with N(R) = V(S) and RC = 0 folds the time
    /// T1 ran into SRT.
    func testAFullAcknowledgmentWithoutRetriesIsASample() throws {
        let (manager, clock) = manager()
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        let before = session.timers.srt

        let frame = try XCTUnwrap(manager.sendData(Data("hello".utf8), to: peer).first)
        clock.currentTime += 1.5
        _ = manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: 1)

        XCTAssertEqual(session.outstandingCount, 0)
        // T1 started once the frame was out; it ran 1.5 s less that airtime.
        let ran = 1.5 - airtime(frame)
        XCTAssertEqual(session.timers.srt, before * 7 / 8 + ran / 8, accuracy: 1e-6)
        XCTAssertEqual(session.timers.rto, 2 * session.timers.srt, accuracy: 1e-9)
    }
}
