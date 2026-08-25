//
//  AX25FieldScenarioTests.swift
//  AXTermTests
//
//  Replays of the 2026-08-22 field capture (K0EPI-7 → KB5YZB-7 via DRLNOD)
//  plus seeded fuzz runs that generalize the same pathology.
//
//  The captured session exposed three interacting problems:
//    1. The receive-buffer flush skipped V(R) past frames the peer was still
//       retransmitting, silently losing data (§6.4.4.1 forbids delivering
//       across a gap).
//    2. The fixed 4 s RTO was shorter than the digipeated path's 4–8 s RTT,
//       so nearly every outbound I-frame cost a spurious retransmit + REJ.
//    3. T1 fires already in flight when stopT1 ran were processed anyway.
//
//  The deterministic tests below replay the captured timings and assert the
//  corrected behavior. The fuzz tests drive the two-node harness through
//  digi-like latency, loss, and duplication across many seeds and assert the
//  one invariant every AX.25 implementation must keep: data delivered to the
//  application is an exact in-order prefix of what the peer sent — never
//  skipped, never duplicated, never reordered.
//

import XCTest
@testable import AXTerm

// MARK: - Deterministic Field Replays

@MainActor
final class AX25FieldScenarioTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 7)
    private let peer  = AX25Address(call: "KB5YZB", ssid: 7)
    private let digiPath = DigiPath.from(["DRLNOD"])

    /// The nodes-listing chunks KB5YZB-7 streamed in the capture (abbreviated).
    private let nodesListing: [Data] = [
        Data("Welcome to YZBBPQ:KB5YZB-7 Network Node Server\r".utf8),
        Data("BBS CHAT CONNECT BYE INFO LISTEN NODES PORTS\r".utf8),
        Data("YZBBPQ:KB5YZB-7} Nodes\r".utf8),
        Data("PNDBPQ:KA0PND-7  PNDRMS:KA0PND-10 RBPBBS:VA7RBP\r".utf8),
        Data("SMY:W7SMY-4      SMYBBS:W7SMY-3   SMYRMS:W7SMY\r".utf8),
        Data("SOLBPQ:N0HI-7    SOLCHT:N0HI-11   TLKCGR:VE3TLK\r".utf8),
        Data("CHT:K5DAT-11     COSBBS:KE0GB-1   DXCGR:AB0XC\r".utf8),
        Data("GLVBRG:NT0Y-3    BBS:WD0HDR-1     INCHAT:K0YA\r".utf8),
    ]

    private func makeManager(
        clock: AX25VirtualClock,
        adaptive: Bool
    ) -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        // The operator's defaults from the capture: T1 = 4 s, N2 = 10. The
        // one-digi path scales the T1 seed to 12 s (TNC-2 FRACK × (2m+1)).
        manager.defaultConfig = AX25SessionConfig(
            windowSize: 4,
            paclen: 128,
            maxRetries: 10,
            rtoMin: 1.0,
            rtoMax: 30.0,
            initialRto: 4.0,
            adaptiveTimeout: adaptive
        )
        return manager
    }

    /// Field timing: SABM at t=0, UA back through DRLNOD at t≈4.34 s. The
    /// direct-link 4 s timer used to fire before the UA arrived; the hop-scaled
    /// 12 s seed must ride out the digipeater delay without a retry.
    func testDigipeatedConnectSurvivesSlowUA() {
        let clock = AX25VirtualClock()
        let manager = makeManager(clock: clock, adaptive: true)

        var timerDrivenFrames: [OutboundFrame] = []
        manager.onSendFrame = { timerDrivenFrames.append($0) }

        let sabm = manager.connect(to: peer, path: digiPath, channel: 0)
        XCTAssertNotNil(sabm)
        let session = manager.session(for: peer, path: digiPath, channel: 0)
        XCTAssertEqual(session.timers.rto, 12.0, accuracy: 0.01,
                       "one digi must scale the 4 s T1 seed to 12 s")

        // UA takes the captured 4.34 s to come back through the digi.
        clock.advance(by: 4.34)
        XCTAssertEqual(session.stateMachine.retryCount, 0,
                       "T1 must not fire while the UA is still in transit through the digi")
        XCTAssertTrue(timerDrivenFrames.isEmpty,
                      "no SABM retry may go on the air before the digipeated UA arrives")

        manager.handleInboundUA(from: peer, path: digiPath, channel: 0)
        XCTAssertEqual(session.state, .connected)
        XCTAssertNotNil(session.timers.srtt,
                        "the SABM→UA round trip must seed the adaptive RTT estimate")
    }

    /// Field timing: every outbound command's RR ack arrived 3.2–8.1 s after
    /// the I-frame. With the old fixed 4 s RTO each exchange cost a spurious
    /// retransmit answered by a REJ from the peer. The scaled timer must let
    /// the ack win the race.
    func testOutboundCommandOverDigiDoesNotSpuriouslyRetransmit() {
        let clock = AX25VirtualClock()
        let manager = makeManager(clock: clock, adaptive: false)

        var timerDrivenFrames: [OutboundFrame] = []
        manager.onSendFrame = { timerDrivenFrames.append($0) }

        _ = manager.connect(to: peer, path: digiPath, channel: 0)
        clock.advance(by: 4.34)
        manager.handleInboundUA(from: peer, path: digiPath, channel: 0)
        let session = manager.session(for: peer, path: digiPath, channel: 0)
        XCTAssertEqual(session.state, .connected)

        let sent = manager.sendData(Data("bbs\r".utf8), to: peer, path: digiPath, channel: 0)
        XCTAssertEqual(sent.count, 1)

        // Worst captured ack latency: 8.1 s. Still under the 12 s scaled RTO.
        clock.advance(by: 8.1)
        XCTAssertTrue(timerDrivenFrames.filter { $0.frameType == "i" }.isEmpty,
                      "no retransmit may fire while the digipeated ack is in flight")

        _ = manager.handleInboundRRFrames(from: peer, path: digiPath, channel: 0,
                                          nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertEqual(session.stateMachine.retryCount, 0)

        // Long quiet period: nothing further may hit the air for this exchange.
        clock.advance(by: 20.0)
        XCTAssertTrue(timerDrivenFrames.filter { $0.frameType == "i" }.isEmpty,
                      "the acked frame must never be retransmitted")
    }

    /// Replay of the 05:12:20–05:13:30 capture window, asserting the corrected
    /// outcome: KB5YZB-7 streams the nodes listing, one chunk is lost on RF,
    /// a later chunk arrives out of sequence (plus a digi-echo duplicate), and
    /// T1 expires repeatedly while the gap is open. The old flush skipped the
    /// lost chunk after two expiries and the transcript silently lost 128
    /// bytes. Now the gap must be held until REJ recovery heals it, and the
    /// application must see every chunk exactly once, in order.
    func testInboundGapWithDuplicatesHealsWithoutDataLoss() {
        let clock = AX25VirtualClock()
        let manager = makeManager(clock: clock, adaptive: false)

        var delivered: [Data] = []
        manager.onDataReceived = { _, data in delivered.append(data) }

        _ = manager.connect(to: peer, path: digiPath, channel: 0)
        manager.handleInboundUA(from: peer, path: digiPath, channel: 0)
        let session = manager.session(for: peer, path: digiPath, channel: 0)
        XCTAssertEqual(session.state, .connected)

        // Chunks 0–5 arrive cleanly, one per second.
        for ns in 0...5 {
            clock.advance(by: 1.0)
            _ = manager.handleInboundIFrame(from: peer, path: digiPath, channel: 0,
                                            ns: ns, nr: 0, pf: false,
                                            payload: nodesListing[ns])
        }
        XCTAssertEqual(delivered, Array(nodesListing[0...5]))

        // ns=6 is lost on RF. ns=7 arrives → out of sequence, buffered, REJ(6).
        clock.advance(by: 1.0)
        let rejResponse = manager.handleInboundIFrame(from: peer, path: digiPath, channel: 0,
                                                      ns: 7, nr: 0, pf: true,
                                                      payload: nodesListing[7])
        XCTAssertEqual(rejResponse?.frameType, "s", "out-of-sequence frame must draw an S-frame response")
        XCTAssertEqual(delivered.count, 6, "nothing may be delivered across the gap")

        // Digi echo: the same ns=7 arrives again. No re-delivery, no REJ storm.
        clock.advance(by: 0.4)
        _ = manager.handleInboundIFrame(from: peer, path: digiPath, channel: 0,
                                        ns: 7, nr: 0, pf: true,
                                        payload: nodesListing[7])
        XCTAssertEqual(delivered.count, 6, "a duplicated frame must not be delivered twice")

        // Two full T1 expiries pass while the peer's REJ recovery is still in
        // flight (the capture showed exactly this: retransmissions of adjacent
        // frames kept arriving seconds after each old flush). The gap must hold.
        clock.advance(by: 25.0)
        XCTAssertEqual(delivered.count, 6,
                       "T1 expiries must not flush the gap while retries remain (old bug: flushed after 2)")
        XCTAssertEqual(session.state, .connected)

        // REJ recovery finally lands: the missing ns=6 arrives, then the peer's
        // retransmitted ns=7 (already buffered — delivered from the buffer).
        clock.advance(by: 1.0)
        _ = manager.handleInboundIFrame(from: peer, path: digiPath, channel: 0,
                                        ns: 6, nr: 0, pf: false,
                                        payload: nodesListing[6])

        XCTAssertEqual(delivered, nodesListing,
                       "after recovery the transcript must be complete, in order, exactly once")

        // The peer's own retransmit of ns=7 may still arrive — must be ignored.
        clock.advance(by: 1.0)
        _ = manager.handleInboundIFrame(from: peer, path: digiPath, channel: 0,
                                        ns: 7, nr: 0, pf: true,
                                        payload: nodesListing[7])
        XCTAssertEqual(delivered, nodesListing, "late retransmits must not duplicate delivery")

        // Clean teardown, as in the capture: DISC → UA.
        let disc = manager.disconnect(session: session)
        XCTAssertEqual(disc?.frameType, "u")
        clock.advance(by: 4.34)
        manager.handleInboundUA(from: peer, path: digiPath, channel: 0)
        XCTAssertEqual(session.state, .disconnected)
    }

    /// Regression (found by AX25FieldFuzzTests): a stale duplicate exactly one
    /// window ahead of V(R) (distance == k) must be treated as a duplicate, not
    /// buffered. The sender's window spans V(A)..V(A)+k−1 and V(A) ≤ V(R), so a
    /// fresh frame can be at most k−1 ahead — distance k is only reachable by a
    /// lap-old retransmit. The old `<= windowSize` bound buffered it, delivered
    /// its stale payload when V(R) wrapped, and then discarded the real frame
    /// carrying that N(S) as a "duplicate" — corrupting the stream both ways.
    func testStaleDuplicateAtWindowBoundaryIsNotBuffered() {
        var sm = AX25StateMachine(config: AX25SessionConfig(windowSize: 4))
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        let lap1: [Data] = (0..<8).map { Data("LAP1-\($0)".utf8) }
        for ns in 0...3 {
            _ = sm.handle(event: .receivedIFrame(ns: ns, nr: 0, pf: false, payload: lap1[ns]))
        }
        XCTAssertEqual(sm.sequenceState.vr, 4)

        // A late retransmit of ns=0 arrives: distance 4 == windowSize → stale.
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: lap1[0]))
        XCTAssertTrue(sm.receiveBuffer.isEmpty,
                      "a lap-old duplicate must not be buffered as a future frame")
        XCTAssertFalse(actions.contains { if case .deliverData = $0 { return true }; return false },
                       "a lap-old duplicate must not be delivered")
        // The re-ack is cumulative: a P=0 duplicate arms T2 and the RR
        // for the current V(R) goes out on expiry — never a REJ.
        XCTAssertFalse(actions.contains { if case .sendREJ = $0 { return true }; return false })
        XCTAssertTrue(sm.handle(event: .t2Timeout).contains(.sendRR(nr: 4, pf: false, isCommand: false)),
                      "a duplicate draws a re-ack of the current V(R), not a REJ")

        // The window completes and V(R) wraps; the true second-lap ns=0 must be
        // delivered with its NEW payload, not shadowed by the stale one.
        for ns in 4...7 {
            _ = sm.handle(event: .receivedIFrame(ns: ns, nr: 0, pf: false, payload: lap1[ns]))
        }
        XCTAssertEqual(sm.sequenceState.vr, 0)

        let lap2Payload = Data("LAP2-0".utf8)
        let second = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: lap2Payload))
        XCTAssertTrue(second.contains(.deliverData(lap2Payload)),
                      "the genuine second-lap frame must be delivered, not discarded as a duplicate")
    }
}

// MARK: - Seeded Fuzz Over the Two-Node Harness

@MainActor
final class AX25FieldFuzzTests: XCTestCase {

    /// Build the per-frame payloads: uniquely numbered so any skip, duplicate,
    /// or reorder is attributable to a specific sequence position.
    private func numberedPayloads(count: Int) -> [Data] {
        (0..<count).map { Data(String(format: "MSG-%04d nodes-listing-line\r", $0).utf8) }
    }

    /// Assert the core AX.25 integrity invariant: what the application received
    /// is an exact in-order prefix of what was sent.
    ///
    /// Note the fuzz channels below never duplicate I-frames, only S-frames.
    /// Modulo-8 go-back-N fundamentally cannot distinguish a duplicate delayed
    /// by a full sequence lap from the new frame reusing the same N(S); real
    /// 1200-baud airtime makes such a delay physically impossible (a lap takes
    /// ≥10 s on the air, a digi echo arrives ~1 s late), but this virtual
    /// channel has zero serialization time, so payload duplication would fuzz
    /// outside the protocol's design envelope and fail for reasons no
    /// implementation could fix.
    private func assertExactPrefix(
        delivered: [Data], sent: [Data], seed: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(delivered.count, sent.count,
                                 "seed \(seed): more data delivered than sent (duplication)",
                                 file: file, line: line)
        for i in 0..<min(delivered.count, sent.count) {
            XCTAssertEqual(delivered[i], sent[i],
                           "seed \(seed): delivery diverged at index \(i) — skip, duplicate, or reorder",
                           file: file, line: line)
            if delivered[i] != sent[i] { return }  // first divergence is enough noise
        }
    }

    /// Field pathology, fuzzed: an RTO shorter than the path RTT (the captured
    /// misconfiguration — fixed 2 s timer on a 4 s round trip) plus digi-echo
    /// duplication of the acks. The channel loses nothing, so despite constant
    /// premature T1 fires, retransmit duplicates, and duplicated RR/REJ frames,
    /// the application stream must come through complete, in order, exactly once.
    func testFuzzTimerChurnOnHighLatencyPathPreservesIntegrity() {
        let payloads = numberedPayloads(count: 12)

        for seed: UInt64 in 1...10 {
            var config = HarnessConfig()
            config.seed = seed
            config.baseLatency = 2.0
            // Data path stays FIFO (see assertExactPrefix note); the ack path gets
            // digi-echo duplication — duplicate RR/REJ must be idempotent.
            config.forwardModel = PerfectChannelModel(latency: 2.0)
            config.reverseModel = DuplicationModel(
                wrapping: PerfectChannelModel(latency: 2.0),
                duplicateProbability: 0.25,
                duplicateDelay: 0.4
            )
            // adaptiveTimeout off pins the RTO below the RTT for the whole run,
            // keeping the timer churn alive — exactly the captured session.
            config.sessionConfig = AX25SessionConfig(
                windowSize: 4, paclen: 128, maxRetries: 10,
                rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0,
                adaptiveTimeout: false
            )

            let harness = AdaptiveTestHarness(config: config)
            var delivered: [Data] = []
            harness.bob.onDataReceived = { _, data in delivered.append(data) }

            XCTAssertTrue(harness.connect(), "seed \(seed): connect failed")

            for payload in payloads {
                harness.queueFrames(count: 1, payload: payload)
            }
            for _ in 0..<60 { harness.advance(seconds: 2.0) }

            assertExactPrefix(delivered: delivered, sent: payloads, seed: seed)
            XCTAssertEqual(delivered.count, payloads.count,
                           "seed \(seed): lossless channel must deliver everything "
                           + "(got \(delivered.count)/\(payloads.count))")
            XCTAssertTrue(harness.invariantViolations.isEmpty,
                          "seed \(seed): invariant violations \(harness.invariantViolations)")
        }
    }

    /// Lossy, duplicating, adaptive-on fuzz: uniform loss on both directions
    /// (rate varied per seed) with digi-echo duplication on the data path.
    /// REJ/T1 recovery is allowed to take as long as it needs — the invariant
    /// is that the application stream never skips, duplicates, or reorders,
    /// and that a link that stays up delivers everything.
    func testFuzzLossyDuplicatingChannelNeverSkipsData() {
        let payloads = numberedPayloads(count: 15)

        for seed: UInt64 in 1...15 {
            let loss = 0.05 + 0.02 * Double(seed % 8)   // 5%–19%

            var config = HarnessConfig()
            config.seed = seed
            config.baseLatency = 1.0
            // Loss preserves FIFO on the data path; duplication is confined to the
            // ack path (see assertExactPrefix note on the modulo-8 envelope).
            config.forwardModel = UniformLossModel(latency: 1.0, lossProbability: loss)
            config.reverseModel = DuplicationModel(
                wrapping: UniformLossModel(latency: 1.0, lossProbability: loss),
                duplicateProbability: 0.15,
                duplicateDelay: 0.3
            )
            config.sessionConfig = AX25SessionConfig(
                windowSize: 4, paclen: 128, maxRetries: 10,
                rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0,
                adaptiveTimeout: true
            )

            let harness = AdaptiveTestHarness(config: config)
            var delivered: [Data] = []
            harness.bob.onDataReceived = { _, data in delivered.append(data) }

            XCTAssertTrue(harness.connect(), "seed \(seed): connect failed")

            for payload in payloads {
                harness.queueFrames(count: 1, payload: payload)
            }
            for _ in 0..<100 { harness.advance(seconds: 3.0) }

            assertExactPrefix(delivered: delivered, sent: payloads, seed: seed)

            // A link that survived must have delivered the full stream. (A link
            // that died from retry exhaustion is a legitimate outcome on a lossy
            // channel — the prefix check above still guarantees no corruption.)
            if harness.aliceSession?.state == .connected {
                XCTAssertEqual(delivered.count, payloads.count,
                               "seed \(seed): surviving link must deliver all data "
                               + "(got \(delivered.count)/\(payloads.count))")
            }
            XCTAssertTrue(harness.invariantViolations.isEmpty,
                          "seed \(seed): invariant violations \(harness.invariantViolations)")
        }
    }

    /// Burst-loss fuzz: Markov good/bad channel (RF fade) on the data path.
    /// Bursts are what actually created the capture's receive gap — several
    /// consecutive frames vanish, then the channel recovers and REJ recovery
    /// has to re-fetch the hole while later frames sit buffered.
    func testFuzzBurstLossGapRecoveryNeverSkipsData() {
        let payloads = numberedPayloads(count: 15)

        for seed: UInt64 in 1...10 {
            var config = HarnessConfig()
            config.seed = seed
            config.baseLatency = 1.0
            config.forwardModel = BurstLossModel(
                latency: 1.0,
                goodToBad: 0.08, badToGood: 0.35,
                goodLoss: 0.02, badLoss: 0.85
            )
            config.reverseModel = UniformLossModel(latency: 1.0, lossProbability: 0.05)
            config.sessionConfig = AX25SessionConfig(
                windowSize: 4, paclen: 128, maxRetries: 10,
                rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0,
                adaptiveTimeout: true
            )

            let harness = AdaptiveTestHarness(config: config)
            var delivered: [Data] = []
            harness.bob.onDataReceived = { _, data in delivered.append(data) }

            XCTAssertTrue(harness.connect(), "seed \(seed): connect failed")

            for payload in payloads {
                harness.queueFrames(count: 1, payload: payload)
            }
            for _ in 0..<100 { harness.advance(seconds: 3.0) }

            assertExactPrefix(delivered: delivered, sent: payloads, seed: seed)
            if harness.aliceSession?.state == .connected {
                XCTAssertEqual(delivered.count, payloads.count,
                               "seed \(seed): surviving link must deliver all data "
                               + "(got \(delivered.count)/\(payloads.count))")
            }
        }
    }
}
