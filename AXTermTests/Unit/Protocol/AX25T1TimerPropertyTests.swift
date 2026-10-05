//
//  AX25T1TimerPropertyTests.swift
//  AXTermTests
//
//  Seeded properties for T1 as AX.25 2.2 defines it (spec 7.3; Appendix C,
//  Figure C4.7b "Select T1").
//
//    T1  initialSRT is the configured T1 × (2·digis + 1) when the key-up
//        time is unknown, never less than that, never less than twice a
//        full frame's round trip, finite, and never shorter for another
//        digipeater or a slower key-up.
//    T2  Select T1 over any sequence: with RC = 0 and a real time,
//        SRT ← 7/8·SRT + 1/8·time and T1V ← 2·SRT exactly; after an
//        expired T1 with RC ≠ 0, T1V ← RC·0.25 + 2·SRT and SRT stays; an
//        acknowledgment after retries, an impossible time, or (with
//        adaptive off) any time changes nothing it should not. SRT and T1V
//        stay finite and positive.
//    T3  The T1 a session schedules, over random configs, paths, histories,
//        retries and sends: exactly T1V from when our frames have left the
//        radio; no floor and no allowance.
//    T5  A sample comes only from an acknowledgment that newly covers
//        frames: an RR that acknowledges nothing new leaves SRT alone.
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
    func testTheInitialDefaultFollowsSection6711() {
        checkProperty("T1.initialSRT", cases: 1000) { rng, v in
            let t1 = rng.double(in: 0.1...30)
            let digis = rng.int(in: -2...7)
            let bytes = rng.int(in: 0...256)
            let keyUp: Double? = rng.chance(0.3) ? nil : rng.double(in: 0...5)
            let peer: Double? = rng.chance(0.3) ? nil : rng.double(in: 0...2)
            let srt = AX25SessionTimers.initialSRT(t1Setting: t1, digipeaters: digis, maxFrameBytes: bytes,
                                                   keyUpSeconds: keyUp, peerKeyUpSeconds: peer)
            let configured = t1 * Double(2 * max(0, digis) + 1)
            v.check(srt.isFinite && srt > 0, "initial SRT \(srt)")
            v.check(srt >= configured - 1e-9, "below the scaled T1 \(configured): \(srt)")
            if keyUp == nil { v.check(abs(srt - configured) < 1e-9, "no key-up, yet \(srt) != \(configured)") }
            if let keyUp {
                let frame = Double(14 + 7 * max(0, digis) + 4 + bytes) * 8 / 1200
                v.check(srt >= 2 * (keyUp + frame) - 1e-9, "under twice our leg alone: \(srt)")
                let slower = AX25SessionTimers.initialSRT(t1Setting: t1, digipeaters: digis, maxFrameBytes: bytes,
                                                          keyUpSeconds: keyUp + 1, peerKeyUpSeconds: peer)
                v.check(slower >= srt, "a slower key-up shortened it: \(slower) < \(srt)")
            }
            let more = AX25SessionTimers.initialSRT(t1Setting: t1, digipeaters: digis + 1, maxFrameBytes: bytes,
                                                    keyUpSeconds: keyUp, peerKeyUpSeconds: peer)
            v.check(more >= srt, "another digipeater shortened it: \(more) < \(srt)")
        }
    }

    // T2
    func testSelectT1IsTheSDLWhateverTheSequence() {
        checkProperty("T2.selectT1", cases: 1000) { rng, v in
            let initial = rng.pick([0.5, 1, 3, 6, 30])
            let adaptive = rng.chance(0.8)
            var timers = AX25SessionTimers(initialSRT: initial, adaptiveTimeout: adaptive)
            v.check(timers.rto == initial && timers.srt == initial, "T1V must start at the initial SRT")
            for _ in 0..<rng.int(in: 1...60) {
                let before = (srt: timers.srt, t1v: timers.rto)
                let rc = rng.pick([0, 0, 0, 1, 2, 5, 10])
                let expired = rng.chance(0.4)
                let elapsed: Double? = rng.pick([nil, rng.double(in: 0.001...20), rng.double(in: 20...5000),
                                                 .nan, .infinity, -1, 0])
                timers.selectT1(retryCount: rc, t1Expired: expired, t1Elapsed: elapsed)
                if rc == 0 {
                    if adaptive, let e = elapsed, e.isFinite, e > 0 {
                        let expected = 7 * before.srt / 8 + e / 8
                        v.check(abs(timers.srt - expected) < 1e-9 * max(1, expected), "SRT \(timers.srt) != \(expected)")
                        v.check(abs(timers.rto - 2 * timers.srt) < 1e-9 * max(1, timers.rto), "T1V != 2·SRT")
                    } else {
                        v.check(timers.srt == before.srt && timers.rto == before.t1v,
                                "RC 0, time \(String(describing: elapsed)), adaptive \(adaptive): changed")
                    }
                } else if expired {
                    v.check(timers.srt == before.srt, "a retry changed SRT")
                    v.check(abs(timers.rto - (Double(rc) * 0.25 + 2 * before.srt)) < 1e-9 * max(1, timers.rto),
                            "retry \(rc): T1V \(timers.rto)")
                } else {
                    v.check(timers.srt == before.srt && timers.rto == before.t1v, "an ack after retries changed T1")
                }
                v.check(timers.srt.isFinite && timers.srt > 0 && timers.rto.isFinite && timers.rto > 0,
                        "SRT \(timers.srt), T1V \(timers.rto)")
                if !adaptive { v.check(timers.srt == initial, "SRT learned with adaptive off") }
            }
            timers.reset()
            v.check(timers.rto == initial && timers.srt == initial && timers.srtt == nil, "reset")
        }
    }

    // T3
    func testScheduledT1IsExactlyT1V() {
        checkProperty("T3.scheduledT1", cases: 400) { rng, v in
            let scheduler = RecordingTimerScheduler()
            let manager = AX25SessionManager(localCallsign: local, clock: scheduler)
            let t1: Double? = rng.chance(0.15) ? nil : rng.pick([0.5, 1, 2, 3, 4, 6, 10])
            manager.defaultConfig = AX25SessionConfig(windowSize: rng.int(in: 1...7), maxRetries: 10,
                                                      initialRto: t1, adaptiveTimeout: rng.chance(0.8))
            if rng.chance(0.5) {
                let ours = rng.double(in: 0...4), peer = rng.double(in: 0...1)
                manager.keyUpSeconds = { _ in (ours, peer) }
            }
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
                session.timers.selectT1(retryCount: rng.pick([0, 0, 1, 3]), t1Expired: rng.chance(0.5),
                                        t1Elapsed: rng.pick([rng.double(in: 0.05...5), rng.double(in: 5...90), .nan, -1]))
            }
            for _ in 0..<rng.int(in: 0...7) {
                _ = manager.sendData(rng.bytes(rng.int(in: 1...256)), to: peer, path: path)
            }
            let retries = session.sendBuffer.isEmpty ? 0 : rng.pick([0, 0, 1, 2, 3])
            for _ in 0..<retries { _ = manager.handleT1Timeout(session: session) }
            guard session.state == .connected else { return }

            scheduler.clearDelays()
            let untilOnAir = max(0, session.onAirUntil - scheduler.currentTime)
            manager.startT1Timer(for: session)
            guard let scheduled = scheduler.delays.first else {
                v.record("startT1Timer scheduled nothing")
                return
            }
            // T1V, from when our frames have left the radio.
            v.check(abs(scheduled - (untilOnAir + session.timers.rto)) < 1e-9,
                    "T1 \(scheduled) != \(untilOnAir) until on air + T1V \(session.timers.rto)")
            v.check(scheduled.isFinite && scheduled > 0, "T1 \(scheduled)")
        }
    }

    // T5
    func testRTTSamplesComeOnlyFromNewlyAcknowledgedFrames() {
        checkProperty("T5.rttSampleSource", cases: 400) { rng, v in
            let clock = AX25VirtualClock()
            let manager = AX25SessionManager(localCallsign: local, clock: clock)
            manager.defaultConfig = AX25SessionConfig(windowSize: rng.int(in: 1...7), initialRto: 4)
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
                                + "changed SRT \(String(describing: before.srtt)) -> \(String(describing: session.timers.srtt))")
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
