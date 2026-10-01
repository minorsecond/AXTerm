//
//  AX25T1TimerPropertyTests.swift
//  AXTermTests
//
//  Seeded properties for the T1 rule and the RTT estimator (spec 7.3, 7.6;
//  spec 13: "timeouts clamp to [min,max]").
//
//    T1  frackFloor is FRACK x (2 x digipeaters + 1), never below FRACK.
//    T2  t1Delay: without a delayed ack owed it is the RTO; with one it is
//        never shorter than the RTO and never longer than 60 s.
//    T3  The T1 a session actually schedules, over random configs, paths,
//        RTT histories, retries, polls and bytes in flight: never below
//        the FRACK floor, never below the adaptive RTO, bounded; with
//        useDelayedAckT1 off exactly max(RTO, floor); with it on, a retry,
//        a retransmission or a poll outstanding gets exactly the same.
//    T4  AX25SessionTimers: any sequence of samples (NaN, infinities,
//        negatives, zero, huge) and backoffs keeps the RTO inside
//        [rtoMin, rtoMax], SRTT finite and positive; invalid samples change
//        nothing; with adaptive off the RTO never moves.
//    T5  An RTT sample comes only from a frame the acknowledgment newly
//        covers: an RR that acknowledges nothing new leaves SRTT alone.
//

import XCTest
@testable import AXTerm

/// Forwards to a virtual clock and records every delay scheduled.
@MainActor
final class RecordingTimerScheduler: AX25TimerScheduler {
    let clock = AX25VirtualClock()
    private(set) var delays: [TimeInterval] = []

    var currentTime: TimeInterval { clock.currentTime }

    func schedule(delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> AnyCancellableTask {
        delays.append(delay)
        return clock.schedule(delay: delay, action: action)
    }

    func clearDelays() { delays.removeAll() }
}

@MainActor
final class AX25T1TimerPropertyTests: XCTestCase {

    private let local = AX25Address(call: "LOCAL", ssid: 1)
    private let peer = AX25Address(call: "PEER", ssid: 2)

    // T1
    func testFrackFloorScalesWithDigipeaters() {
        checkProperty("T1.frackFloor", cases: 500) { rng, v in
            let frack = rng.double(in: 0...30)
            let digis = rng.int(in: -3...8)
            let floor = AX25SessionManager.frackFloor(frack: frack, digipeaters: digis)
            v.check(floor == frack * Double(2 * max(0, digis) + 1), "floor \(floor) for FRACK \(frack), \(digis) digis")
            v.check(floor >= frack, "floor below FRACK")
            v.check(AX25SessionManager.frackFloor(frack: frack, digipeaters: digis + 1) >= floor,
                    "another digipeater lowered the floor")
        }
    }

    // T2
    func testDelayedAckFormulaNeverShortensTheRTO() {
        checkProperty("T2.t1Delay", cases: 1000) { rng, v in
            let rto = rng.double(in: 0.5...60)
            let srtt: Double? = rng.chance(0.3) ? nil : rng.double(in: 0.01...120)
            let bytes = rng.int(in: 0...(7 * 300))
            let plain = AX25SessionManager.t1Delay(rto: rto, srtt: srtt, bytesInFlight: bytes, awaitingDelayedAck: false)
            let delayed = AX25SessionManager.t1Delay(rto: rto, srtt: srtt, bytesInFlight: bytes, awaitingDelayedAck: true)
            v.check(plain == rto, "with no delayed ack owed T1 \(plain) != RTO \(rto)")
            v.check(delayed >= rto, "the formula shortened T1 below the RTO: \(delayed) < \(rto)")
            v.check(delayed <= 60, "the formula gave \(delayed) s, past 60 s")
            v.check(delayed.isFinite, "non-finite T1")
        }
    }

    // T3
    func testScheduledT1RespectsFloorRTOAndSwitch() {
        checkProperty("T3.scheduledT1", cases: 400) { rng, v in
            let scheduler = RecordingTimerScheduler()
            let manager = AX25SessionManager(localCallsign: local, clock: scheduler)
            let frack: Double? = rng.chance(0.15) ? nil : rng.pick([0.5, 1, 2, 3, 4, 6, 10])
            let config = AX25SessionConfig(
                windowSize: rng.int(in: 1...7),
                maxRetries: 10,
                rtoMin: rng.pick([nil, 0.5, 1, 3]),
                rtoMax: rng.pick([nil, 8, 30, 60]),
                initialRto: frack,
                adaptiveTimeout: rng.chance(0.8))
            manager.defaultConfig = config
            manager.useDelayedAckT1 = rng.chance(0.5)
            let digis = rng.int(in: 0...8)
            let path = DigiPath((0..<digis).map { AX25Address(call: "DIGI\($0)", ssid: 0) })

            if rng.chance(0.5) {
                _ = manager.connect(to: peer, path: path)
                manager.handleInboundUA(from: peer, path: path, radio: .primary)
            } else {
                _ = manager.handleInboundSABM(from: peer, to: local, path: path, radio: .primary)
            }
            guard let session = manager.existingSession(for: peer, path: path), session.state == .connected else {
                v.record("link did not open")
                return
            }
            for _ in 0..<rng.int(in: 0...12) {
                session.timers.updateRTT(sample: rng.pick([rng.double(in: 0.05...5), rng.double(in: 5...90),
                                                          .nan, .infinity, -1, 0]))
            }
            for _ in 0..<rng.int(in: 0...7) {
                _ = manager.sendData(rng.bytes(rng.int(in: 1...256)), to: peer, path: path)
            }
            let retries = session.sendBuffer.isEmpty ? 0 : rng.pick([0, 0, 1, 2, 3])
            for _ in 0..<retries { _ = manager.handleT1Timeout(session: session) }
            guard session.state == .connected else { return }

            scheduler.clearDelays()
            manager.startT1Timer(for: session)
            guard let t1 = scheduler.delays.first else {
                v.record("startT1Timer scheduled nothing")
                return
            }
            let rto = session.timers.rto
            let floor = AX25SessionManager.frackFloor(frack: frack ?? 4.0, digipeaters: digis)
            let polled = session.sendBuffer.values.contains { ($0.controlByte ?? 0) & 0x10 != 0 }
            let plainCase = session.sendBuffer.isEmpty || session.stateMachine.retryCount > 0
                || session.hasRetransmittedOutstanding || polled

            v.check(t1 >= floor, "T1 \(t1) below the FRACK floor \(floor) (digis \(digis))")
            v.check(t1 >= rto, "T1 \(t1) below the adaptive RTO \(rto)")
            v.check(t1.isFinite && t1 <= max(60, floor), "T1 \(t1) unbounded (floor \(floor))")
            if !manager.useDelayedAckT1 {
                v.check(t1 == max(rto, floor), "switch off: T1 \(t1) != max(RTO \(rto), floor \(floor))")
            } else if plainCase {
                v.check(t1 == max(rto, floor), "retry, retransmission or poll outstanding: T1 \(t1) != "
                        + "max(RTO \(rto), floor \(floor)) (retries \(session.stateMachine.retryCount), polled \(polled))")
            }
        }
    }

    // T4
    func testRTOStaysClampedWhateverTheSamples() {
        checkProperty("T4.timers", cases: 1000) { rng, v in
            let rtoMin = rng.pick([-1, 0, 0.1, 0.5, 1, 3, 10, .nan])
            let rtoMax = rng.pick([-5, 0.2, 2, 8, 30, 60, 500, .nan, .infinity])
            let initial = rng.pick([-1, 0.1, 1, 4, 30, 1000, .nan])
            let adaptive = rng.chance(0.8)
            var timers = AX25SessionTimers(rtoMin: rtoMin, rtoMax: rtoMax, initialRto: initial,
                                           adaptiveTimeout: adaptive, t2AckDelay: rng.pick([0, 0.05, 2, 10, .nan]))
            // The documented clamps (AX25SessionTimers.init).
            let lo = max(0.5, rtoMin.isNaN ? 0.5 : rtoMin)
            let hi = max(lo, min(60.0, rtoMax.isNaN ? 60.0 : rtoMax))
            let initialRTO = timers.rto
            v.check(timers.rto.isFinite && timers.rto >= lo && timers.rto <= hi,
                    "initial RTO \(timers.rto) outside [\(lo), \(hi)] (min \(rtoMin), max \(rtoMax), initial \(initial))")
            v.check(timers.t2AckDelay.isFinite && timers.t2AckDelay >= 0.1 && timers.t2AckDelay <= max(0.1, lo * 2 / 3),
                    "T2 \(timers.t2AckDelay) outside [0.1, 2/3 rtoMin]")

            for _ in 0..<rng.int(in: 1...60) {
                let before = (srtt: timers.srtt, rttvar: timers.rttvar, rto: timers.rto)
                if rng.chance(0.2) {
                    timers.backoff()
                    if adaptive {
                        v.check(timers.rto == min(before.rto * 2, hi), "backoff \(before.rto) -> \(timers.rto)")
                    }
                } else {
                    let sample = rng.pick([rng.double(in: 0.001...10), rng.double(in: 10...10_000),
                                           .nan, .infinity, -.infinity, -rng.double(in: 0...10), 0,
                                           .leastNonzeroMagnitude, .greatestFiniteMagnitude])
                    timers.updateRTT(sample: sample)
                    if !(sample > 0 && sample.isFinite) || !adaptive {
                        v.check(timers.srtt == before.srtt && timers.rttvar == before.rttvar && timers.rto == before.rto,
                                "sample \(sample) (adaptive \(adaptive)) changed the estimator")
                    }
                }
                v.check(timers.rto.isFinite && timers.rto >= lo && timers.rto <= hi,
                        "RTO \(timers.rto) outside [\(lo), \(hi)]")
                if let srtt = timers.srtt { v.check(srtt.isFinite && srtt > 0, "SRTT \(srtt)") }
                v.check(timers.rttvar.isFinite && timers.rttvar >= 0, "RTTVAR \(timers.rttvar)")
                if !adaptive { v.check(timers.rto == initialRTO, "RTO moved with adaptive off") }
            }
            timers.reset()
            v.check(timers.rto == initialRTO && timers.srtt == nil, "reset did not restore the initial RTO")
        }
    }

    // T5
    func testRTTSamplesComeOnlyFromNewlyAcknowledgedFrames() {
        checkProperty("T5.rttSampleSource", cases: 400) { rng, v in
            let clock = AX25VirtualClock()
            let manager = AX25SessionManager(localCallsign: local, clock: clock)
            manager.defaultConfig = AX25SessionConfig(windowSize: rng.int(in: 1...7), rtoMin: 0.5, rtoMax: 60, initialRto: 4)
            _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
            guard let session = manager.existingSession(for: peer) else { return }
            var peerVS = 0

            for _ in 0..<rng.int(in: 1...20) {
                let before = (srtt: session.timers.srtt, rto: session.timers.rto, va: session.va)
                switch rng.int(6) {
                case 0, 1:
                    _ = manager.sendData(rng.bytes(rng.int(in: 1...40)), to: peer)
                case 2:
                    // The peer acknowledges by piggybacking on its own I-frame.
                    let outstanding = (session.vs - session.va + 8) % 8
                    let nr = (session.va + rng.int(outstanding + 1)) % 8
                    _ = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                    ns: peerVS % 8, nr: nr, pf: false, payload: Data("x".utf8))
                    peerVS += 1
                case 3:
                    clock.advance(by: rng.double(in: 0.1...30))
                case 4:
                    // An RR that acknowledges nothing new: N(R) = V(A), or
                    // outside V(A)...V(S) altogether.
                    let outstanding = (session.vs - session.va + 8) % 8
                    let stale = rng.chance(0.5) || outstanding == 7
                        ? session.va
                        : (session.va + outstanding + 1 + rng.int(7 - outstanding)) % 8
                    let isCommand = rng.chance(0.5)
                    _ = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                      nr: stale, pf: rng.chance(0.5), isCommand: isCommand)
                    if session.state == .connected {
                        v.check(session.timers.srtt == before.srtt,
                                "RR(\(stale)) acknowledging nothing new (V(A)=\(before.va), V(S)=\(session.vs)) "
                                + "changed SRTT \(String(describing: before.srtt)) -> \(String(describing: session.timers.srtt))")
                    }
                default:
                    // A REJ that acknowledges what is outstanding.
                    let outstanding = (session.vs - session.va + 8) % 8
                    let nr = (session.va + rng.int(outstanding + 1)) % 8
                    _ = manager.handleInboundREJ(from: peer, path: DigiPath(), radio: .primary, nr: nr)
                }
                guard session.state == .connected else { return }
                if !v.isEmpty { return }
            }
        }
    }
}
