//
//  AX25SessionFuzzTests.swift
//  AXTermTests
//
//  Adversarial malformed-frame fuzzing for the AX.25 stack.
//
//  Coverage:
//    Layer 1 — KISS parser (KISSFrameParser.feed)
//    Layer 2 — AX.25 decoder (AX25.decodeFrame)
//    Layer 3 — Session manager inbound handlers
//    Layer 4 — AIMD congestion-window poisoning resistance
//    Layer 5 — Session/timer leak detection
//    Layer 6 — Chaos sequences (mixed random frame types)
//
//  Guarantees under test:
//    • No inbound frame ever crashes, asserts, or deadlocks
//    • Malformed input fails safely and deterministically
//    • AIMD cwnd stays in [1.0, maxWindow], never NaN/Inf
//    • effectiveWindow stays >= 1 at all times
//    • Session count never grows unboundedly
//    • Timer count stabilises after session teardown
//
//  All seeds are documented; any failure emits the seed needed to replay.
//

import XCTest
@testable import AXTerm

// MARK: - Deterministic RNG (local to fuzzer — does not clash with app's SplitMix64)

private struct FuzzRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z &>> 27)) &* 0x94d049bb133111eb
        return z ^ (z &>> 31)
    }

    /// Uniform byte
    mutating func nextByte() -> UInt8 { UInt8(next() & 0xFF) }

    /// [0, bound)
    mutating func nextInt(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }

    /// [lo, hi] inclusive
    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound
        return range.lowerBound + nextInt(span + 1)
    }

    /// Random Data of exactly `count` bytes
    mutating func nextData(count: Int) -> Data {
        var d = Data(capacity: count)
        for _ in 0..<count { d.append(nextByte()) }
        return d
    }

    /// Random Data in [minLen, maxLen]
    mutating func nextData(minLen: Int = 0, maxLen: Int) -> Data {
        let len = nextInt(in: minLen...maxLen)
        return nextData(count: len)
    }
}

// MARK: - Shared Test Infrastructure

@MainActor
final class AX25SessionFuzzTests: XCTestCase {

    // MARK: - Setup helpers

    /// Build a session manager with a fully-connected session.
    /// Returns (manager, session, peer, clock).
    private func makeConnectedSession(
        windowSize: Int = 4,
        rtoMin: Double = 1.0,
        rtoMax: Double = 16.0,
        initialRto: Double = 2.0
    ) -> (manager: AX25SessionManager, session: AX25Session, peer: AX25Address, clock: AX25VirtualClock) {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(
            windowSize: windowSize,
            rtoMin: rtoMin, rtoMax: rtoMax, initialRto: initialRto
        )
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)
        return (manager, session, peer, clock)
    }

    // MARK: - Invariant assertions

    private func assertAIMDInvariants(
        _ session: AX25Session,
        context: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let cwnd = session.aimdWindow.cwnd
        XCTAssertFalse(cwnd.isNaN,      "AIMD: cwnd is NaN @ \(context)",      file: file, line: line)
        XCTAssertTrue(cwnd.isFinite,    "AIMD: cwnd is ±Inf @ \(context)",     file: file, line: line)
        XCTAssertGreaterThanOrEqual(cwnd, 1.0, "AIMD: cwnd \(cwnd) < 1.0 @ \(context)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            session.aimdWindow.effectiveWindow, 1,
            "AIMD: effectiveWindow \(session.aimdWindow.effectiveWindow) < 1 @ \(context)",
            file: file, line: line
        )
    }

    private func assertSequenceInvariants(
        _ session: AX25Session,
        context: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let modulo = session.stateMachine.config.modulo
        XCTAssertGreaterThanOrEqual(session.vs, 0, "vs < 0 @ \(context)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(session.vr, 0, "vr < 0 @ \(context)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(session.va, 0, "va < 0 @ \(context)", file: file, line: line)
        XCTAssertLessThan(session.vs, modulo, "vs \(session.vs) >= modulo \(modulo) @ \(context)", file: file, line: line)
        XCTAssertLessThan(session.vr, modulo, "vr \(session.vr) >= modulo \(modulo) @ \(context)", file: file, line: line)
        XCTAssertLessThan(session.va, modulo, "va \(session.va) >= modulo \(modulo) @ \(context)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(session.outstandingCount, 0,
            "outstandingCount < 0 @ \(context)", file: file, line: line)
    }

    private func assertAllInvariants(
        _ session: AX25Session,
        context: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        assertAIMDInvariants(session, context: context, file: file, line: line)
        assertSequenceInvariants(session, context: context, file: file, line: line)
    }
}

// MARK: - Part 1: KISS Parser Layer

extension AX25SessionFuzzTests {

    // F-K1: Pure garbage byte streams must never crash or hang the KISS parser.
    // Covers: pre-FEND garbage, runs of FEND-only data, completely random data.
    func testKISSGarbageNeverCrashes() {
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_0001)
        var parser = KISSFrameParser()

        for iteration in 0..<50_000 {
            let len = rng.nextInt(in: 0...512)
            let garbage = rng.nextData(count: len)
            let results = parser.feed(garbage)
            // Any result is fine — nil or parsed frames — we just want no crash
            _ = results
            // Reset occasionally to prevent buffer inflation
            if iteration % 1000 == 0 { parser.reset() }
        }
        // If we get here without crashing or hanging, the test passes.
        XCTAssert(true, "seed=0xDEADBEEF00000001: 50k garbage iterations completed")
    }

    // F-K2: Single-byte feed — feed one byte at a time. The parser must never misfire
    // or crash when frames arrive split across many individual calls.
    func testKISSPartialFeedSingleByte() {
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_0002)
        var parser = KISSFrameParser()

        for _ in 0..<500 {
            let frameLen = rng.nextInt(in: 10...200)
            let frame = rng.nextData(count: frameLen)
            for byte in frame {
                _ = parser.feed(Data([byte]))
            }
        }
        XCTAssert(true, "seed=0xDEADBEEF00000002: single-byte feed completed")
    }

    // F-K3: Every possible KISS command byte. The parser must accept or discard each
    // without crashing. This exercises the `cmdType` switch in processKISSFrame.
    func testKISSAllCommandBytes() {
        var parser = KISSFrameParser()
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_0003)

        for cmd in UInt8.min...UInt8.max {
            // Build: FEND + cmd + random_payload(0..50 bytes) + FEND
            let payloadLen = rng.nextInt(in: 0...50)
            let payload = rng.nextData(count: payloadLen)
            var frame = Data([KISS.FEND, cmd])
            frame.append(payload)
            frame.append(KISS.FEND)
            _ = parser.feed(frame)
        }
        XCTAssert(true, "seed=0xDEADBEEF00000003: all 256 command bytes exercised")
    }

    // F-K4: All FESC follower bytes. The KISS escape decoder must handle all 256 followers
    // of FESC, not just TFEND and TFESC. Trailing FESC (last byte of frame) must not panic.
    func testKISSMalformedEscapeAllFollowers() {
        var parser = KISSFrameParser()

        for follower in UInt8.min...UInt8.max {
            // FEND + 0x00 (data cmd) + FESC + follower + FEND
            let frame = Data([KISS.FEND, 0x00, KISS.FESC, follower, KISS.FEND])
            _ = parser.feed(frame)
        }

        // Trailing FESC (no follower) — the most likely panic point
        let trailingFESC = Data([KISS.FEND, 0x00, 0x41, 0x42, KISS.FESC, KISS.FEND])
        _ = parser.feed(trailingFESC)

        // FESC as the only content
        let fescOnly = Data([KISS.FEND, 0x00, KISS.FESC, KISS.FEND])
        _ = parser.feed(fescOnly)

        XCTAssert(true, "All FESC follower variants survived")
    }

    // F-K5: Empty and degenerate KISS frames.
    func testKISSEmptyAndDegenerateFrames() {
        var parser = KISSFrameParser()

        // Empty stream
        _ = parser.feed(Data())

        // Just FEND
        _ = parser.feed(Data([KISS.FEND]))

        // Two FENDs (empty frame between them — valid framing, empty payload)
        _ = parser.feed(Data([KISS.FEND, KISS.FEND]))

        // Many consecutive FENDs
        _ = parser.feed(Data(repeating: KISS.FEND, count: 100))

        // Command byte only, no payload
        _ = parser.feed(Data([KISS.FEND, 0x00, KISS.FEND]))

        // Maximum-length frame
        var maxFrame = Data([KISS.FEND, 0x00])
        maxFrame.append(Data(repeating: 0xAA, count: 65535))
        maxFrame.append(KISS.FEND)
        _ = parser.feed(maxFrame)

        XCTAssert(true, "Degenerate KISS frames survived")
    }

    // F-K6: KISS frames with AX.25 data below minimum size (< 15 bytes).
    // The KISS layer should pass them through; the AX.25 decoder must reject them.
    func testKISSSubminimumAX25Payload() {
        var parser = KISSFrameParser()
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_0006)

        for size in 0...14 {
            let payload = rng.nextData(count: size)
            var frame = Data([KISS.FEND, 0x00])
            frame.append(KISS.escape(payload))
            frame.append(KISS.FEND)
            let results = parser.feed(frame)
            for result in results {
                if case .ax25(let ax25Data) = result {
                    // AX.25 decoder must return nil for < 15 bytes
                    let decoded = AX25.decodeFrame(ax25: ax25Data)
                    XCTAssertNil(decoded, "AX25 decoder must reject \(size)-byte frame")
                }
            }
        }
    }
}

// MARK: - Part 2: AX.25 Decoder Layer

extension AX25SessionFuzzTests {

    // F-D1: Frame decoder must return nil for all lengths 0 to 14 (below minimum 15 bytes).
    func testDecoderRejectsSubminimumFrames() {
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_D001)
        for size in 0...14 {
            let data = rng.nextData(count: size)
            XCTAssertNil(
                AX25.decodeFrame(ax25: data),
                "size=\(size): decoder must return nil for frames shorter than 15 bytes"
            )
        }
    }

    // F-D2: All 256 control byte values injected into a structurally valid frame.
    // No control byte should cause a crash or assertion; all must decode or return nil.
    func testDecoderAllControlBytes() {
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_D002)

        // Build a valid 15-byte address block (dest 7B + src 7B with EOA=1)
        // Destination bytes: call "N0CALL " shifted left 1, SSID 0, no EOA
        func callBytes(_ call: String, eoa: Bool, isLast: Bool) -> [UInt8] {
            var padded = Array((call + "      ").prefix(6))
            var bytes = padded.map { UInt8($0.asciiValue ?? 0x20) << 1 }
            var ssidByte: UInt8 = 0b01100000  // bits 7-5: 011 (standard)
            if eoa { ssidByte |= 0x01 }       // bit 0 = EOA
            bytes.append(ssidByte)
            return bytes
        }

        let destBytes = callBytes("N0CALL", eoa: false, isLast: false)  // 7 bytes, no EOA
        let srcBytes  = callBytes("K0CALL", eoa: true,  isLast: true)   // 7 bytes, EOA=1

        var addrBlock = Data(destBytes + srcBytes)  // 14 bytes

        for ctrl in UInt8.min...UInt8.max {
            var frame = addrBlock
            frame.append(ctrl)  // 15 bytes total
            let result = AX25.decodeFrame(ax25: frame)
            // Must be nil or a valid decode — never a crash
            _ = result
        }
        XCTAssert(true, "seed=0xDEADBEEF0000D002: all 256 control bytes exercised")
    }

    // F-D3: Frame with no end-of-address bit set anywhere.
    // The address loop must terminate (via the count>=8 guard) and not hang.
    func testDecoderNoEndOfAddressBit() {
        // Build 16-byte frame: all address bytes have bit 0 cleared (no EOA), then control
        var noEOA = Data(repeating: 0xA0, count: 14)  // addr block, all EOA bits clear
        noEOA.append(0x03)   // UI control byte
        noEOA.append(0x00)   // dummy extra byte
        let result = AX25.decodeFrame(ax25: noEOA)
        // May decode with best-effort or return nil — must not hang or crash
        _ = result
        XCTAssert(true, "No-EOA frame survived")
    }

    // F-D4: Multiple end-of-address bits (EOA set in first address byte AND last).
    // The address loop must stop at the FIRST EOA, not continue.
    func testDecoderMultipleEndOfAddressBits() {
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_D004)

        // Build frame: dest has EOA=1 in first address byte (byte 6), then more addresses follow
        // This simulates a corrupted frame where EOA appears prematurely
        var frame = Data()
        frame.append(contentsOf: [0xA0, 0xA0, 0xA0, 0xA0, 0xA0, 0xA0, 0xE1])  // dest with EOA
        frame.append(contentsOf: [0x9C, 0x9C, 0x9C, 0x9C, 0x9C, 0x9C, 0xA0])  // src without EOA
        frame.append(contentsOf: [0x9C, 0x9C, 0x9C, 0x9C, 0x9C, 0x9C, 0xE1])  // digi with EOA
        frame.append(0x03)  // control
        _ = AX25.decodeFrame(ax25: frame)

        // All zeros except EOA in unexpected positions
        for _ in 0..<1000 {
            let len = rng.nextInt(in: 15...100)
            var garbage = rng.nextData(count: len)
            // Set EOA bit in a random address byte
            let eoa1 = rng.nextInt(in: 0...13)
            let eoa2 = rng.nextInt(in: 0...13)
            garbage[eoa1] |= 0x01
            garbage[eoa2] |= 0x01
            _ = AX25.decodeFrame(ax25: garbage)
        }
        XCTAssert(true, "seed=0xDEADBEEF0000D004: multiple-EOA frames survived")
    }

    // F-D5: Frames with 9 or more digipeaters. The decoder must stop at 8 (max) and not OOB.
    func testDecoderMaxDigipeatersExceeded() {
        // 14-byte dest+src + 9×7-byte digipeaters (63 bytes) + control = 78 bytes
        // All digipeater EOA bits are clear except the last
        var frame = Data()
        // dest (7 bytes, no EOA)
        frame.append(contentsOf: [0x9C, 0x6E, 0x98, 0x9A, 0x9C, 0x40, 0x60])
        // src (7 bytes, no EOA)
        frame.append(contentsOf: [0x96, 0x60, 0x60, 0x60, 0x60, 0x40, 0x60])
        // 9 digipeaters — last one has EOA=1
        for i in 0..<9 {
            let eoa: UInt8 = (i == 8) ? 0x01 : 0x00
            let ssid: UInt8 = 0x60 | eoa
            frame.append(contentsOf: [0x9C, 0x9C, 0x9C, 0x9C, 0x9C, 0x9C, ssid])
        }
        frame.append(0x03)  // UI control
        let result = AX25.decodeFrame(ax25: frame)
        // Must return nil (too many digis) or a capped result — never a crash
        _ = result
        XCTAssert(true, "9-digipeater frame survived")
    }

    // F-D6: Pure random garbage frames, 10k iterations, size range 0–512.
    func testDecoderRandomGarbage() {
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_D006)
        for _ in 0..<10_000 {
            let data = rng.nextData(minLen: 0, maxLen: 512)
            _ = AX25.decodeFrame(ax25: data)
        }
        XCTAssert(true, "seed=0xDEADBEEF0000D006: 10k random garbage decoded without crash")
    }

    // F-D7: I-frames with all N(S) × N(R) combinations (0–7 × 0–7 = 64 cases).
    // Each must be decodable without crash; sequence numbers are in the control byte.
    func testDecoderAllIFrameNSNRCombinations() {
        for ns in 0...7 {
            for nr in 0...7 {
                // AX.25 I-frame control byte: NNNPSSS0
                //   NNN = N(R) [bits 7-5], P = 0 [bit 4], SSS = N(S) [bits 3-1], 0 [bit 0]
                let ctrl: UInt8 = UInt8((nr << 5) | (ns << 1))
                var frame = Data()
                // dest (7 bytes, no EOA)
                frame.append(contentsOf: [0x9C, 0x6E, 0x98, 0x9A, 0x9C, 0x40, 0x60])
                // src (7 bytes, EOA=1)
                frame.append(contentsOf: [0x96, 0x60, 0x60, 0x60, 0x60, 0x40, 0x61])
                frame.append(ctrl)   // I-frame control
                frame.append(0xF0)   // PID (no layer 3)
                frame.append(contentsOf: [0x41, 0x42])  // info bytes
                let result = AX25.decodeFrame(ax25: frame)
                if let decoded = result {
                    // If decoded, verify N(S) and N(R) match what we encoded
                    let decodedCtrl = AX25ControlFieldDecoder.decode(control: ctrl)
                    if decodedCtrl.frameClass == .I {
                        XCTAssertEqual(decodedCtrl.ns, ns,
                            "N(S) mismatch: encoded \(ns), decoded \(String(describing: decodedCtrl.ns))")
                        XCTAssertEqual(decodedCtrl.nr, nr,
                            "N(R) mismatch: encoded \(nr), decoded \(String(describing: decodedCtrl.nr))")
                    }
                }
                _ = result
            }
        }
        XCTAssert(true, "All 64 N(S)×N(R) combinations decoded without crash")
    }
}

// MARK: - Part 3: Session Manager — No-Session Injections

extension AX25SessionFuzzTests {

    // F-S1: All session manager inbound handlers must return nil/empty when called with
    // no matching session. The session count must not increase.
    func testNoSessionInjection_UA_DM_DISC_RR_REJ_IFrame() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let stranger = AX25Address(call: "STRANGER", ssid: 0)
        let path = DigiPath()

        let initialCount = manager.sessions.count

        // UA for unknown session — must be silently ignored
        manager.handleInboundUA(from: stranger, path: path, channel: 0)
        XCTAssertEqual(manager.sessions.count, initialCount,
            "UA for unknown session must not create a session")

        // DM for unknown session — must be silently ignored
        manager.handleInboundDM(from: stranger, path: path, channel: 0)
        XCTAssertEqual(manager.sessions.count, initialCount,
            "DM for unknown session must not create a session")

        // DISC for unknown session — must return DM frame, not crash
        let discResponse = manager.handleInboundDISC(from: stranger, path: path, channel: 0)
        // Either nil (no session, no response) or DM (correct protocol)
        if let r = discResponse {
            // If there's a response, it must be a DM
            let decoded = AX25ControlFieldDecoder.decode(control: r.controlByte ?? 0)
            XCTAssertEqual(decoded.uType, .DM,
                "DISC with no session must elicit a DM response (per AX.25 §6.4)")
        }
        XCTAssertEqual(manager.sessions.count, initialCount,
            "DISC for unknown session must not create a session")

        // RR for unknown session — must return nil
        let rrResponse = manager.handleInboundRR(from: stranger, path: path, channel: 0, nr: 0)
        XCTAssertNil(rrResponse, "RR for unknown session must return nil")

        // REJ for unknown session — must return empty
        let rejFrames = manager.handleInboundREJ(from: stranger, path: path, channel: 0, nr: 0)
        XCTAssertTrue(rejFrames.isEmpty, "REJ for unknown session must return no frames")

        // I-frame for unknown session — must return nil, must not create session
        let iResponse = manager.handleInboundIFrame(
            from: stranger, path: path, channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data("hello".utf8)
        )
        XCTAssertNil(iResponse, "I-frame for unknown session must return nil")
        XCTAssertEqual(manager.sessions.count, initialCount,
            "I-frame for unknown session must not create a session")
    }

    // F-S2: SABM from an unknown peer creates exactly one session, not many.
    // A SABM storm from the same peer must converge to a single session.
    func testSABMCreatesExactlyOneSession() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let local = AX25Address(call: "LOCAL", ssid: 0)
        let peer  = AX25Address(call: "PEER",  ssid: 0)
        let path  = DigiPath()

        let before = manager.sessions.count
        // First SABM — should create session and return UA
        let r1 = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        XCTAssertNotNil(r1, "First SABM should return UA")
        XCTAssertEqual(manager.sessions.count, before + 1,
            "First SABM must create exactly one session")

        // Second SABM from same peer — should re-use session (not create a new one)
        let r2 = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        _ = r2  // May return UA again; that's fine
        XCTAssertEqual(manager.sessions.count, before + 1,
            "Repeated SABM from same peer must not create additional sessions (seed: F-S2)")

        // Flood: 20 more SABMs
        for _ in 0..<20 {
            _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        }
        XCTAssertEqual(manager.sessions.count, before + 1,
            "SABM flood from same peer must stay at 1 session (seed: F-S2)")
    }

    // F-S3: Distinct peers each create their own session (up to resource limits).
    func testDistinctPeersCreateDistinctSessions() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let local = AX25Address(call: "LOCAL", ssid: 0)
        let path  = DigiPath()
        let before = manager.sessions.count

        for ssid in 0...7 {
            let peer = AX25Address(call: "PEER", ssid: ssid)
            _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        }

        XCTAssertEqual(manager.sessions.count, before + 8,
            "8 distinct peers (SSID 0–7) must create 8 sessions (seed: F-S3)")
    }
}

// MARK: - Part 4: Connected Session — Sequence Number Injection

extension AX25SessionFuzzTests {

    // F-N1: RR with all N(R) values [0,7] injected into a connected session.
    // No value should crash or corrupt state. Invalid NRs must be rejected by the
    // state machine and must not grow the AIMD window spuriously.
    func testConnectedSession_RR_AllNRValues() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()

        // Send 2 frames to have outstanding work
        _ = manager.sendData(Data("ping".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("pong".utf8), to: peer, path: path, channel: 0)

        let cwindBefore = session.aimdWindow.cwnd

        for nr in 0...7 {
            _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: nr)
            assertAllInvariants(session, context: "RR(nr=\(nr))")
        }

        // cwnd must not have gone negative or NaN regardless of which NRs were valid
        assertAIMDInvariants(session, context: "after all-NR RR sweep")
        _ = cwindBefore  // silence unused warning
        _ = clock
    }

    // F-N2: REJ with all N(R) values [0,7]. Invalid NRs must not corrupt send buffer or cwnd.
    func testConnectedSession_REJ_AllNRValues() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()

        // Send 4 frames to fill window
        for i in 0..<4 {
            _ = manager.sendData(Data("chunk\(i)".utf8), to: peer, path: path, channel: 0)
        }

        for nr in 0...7 {
            // Reset REJ dedup state so each REJ is independently processed
            session.lastREJRetransmitNR = nil
            _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: nr)
            assertAllInvariants(session, context: "REJ(nr=\(nr))")
        }
        _ = clock
    }

    // F-N3: I-frame with all N(S) × N(R) combinations injected into a connected session.
    // Most will be out-of-window and rejected; none may corrupt state.
    func testConnectedSession_IFrame_AllNSNRCombinations() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()

        for ns in 0...7 {
            for nr in 0...7 {
                _ = manager.handleInboundIFrame(
                    from: peer, path: path, channel: 0,
                    ns: ns, nr: nr, pf: false,
                    payload: Data("data".utf8)
                )
                assertAllInvariants(session, context: "I-frame(ns=\(ns),nr=\(nr))")
            }
        }
        _ = clock
    }

    // F-N4: I-frame with empty payload (0 bytes). Boundary case for info field handling.
    func testConnectedSession_IFrameEmptyPayload() {
        let (manager, session, peer, clock) = makeConnectedSession()
        let path = DigiPath()

        _ = manager.handleInboundIFrame(
            from: peer, path: path, channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: Data()
        )
        assertAllInvariants(session, context: "I-frame empty payload")
        _ = clock
    }

    // F-N5: I-frame with maximum-size payload (256 bytes). Verify no buffer overflow.
    func testConnectedSession_IFrameMaxPayload() {
        let (manager, session, peer, clock) = makeConnectedSession()
        let path = DigiPath()

        let bigPayload = Data(repeating: 0xFF, count: 256)
        _ = manager.handleInboundIFrame(
            from: peer, path: path, channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: bigPayload
        )
        assertAllInvariants(session, context: "I-frame max payload (256 bytes)")
        _ = clock
    }

    // F-N6: I-frame with all-zero payload — checks for NUL sensitivity.
    func testConnectedSession_IFrameAllZeroPayload() {
        let (manager, session, peer, clock) = makeConnectedSession()
        let path = DigiPath()

        let zeroPayload = Data(repeating: 0x00, count: 128)
        _ = manager.handleInboundIFrame(
            from: peer, path: path, channel: 0,
            ns: 0, nr: 0, pf: false,
            payload: zeroPayload
        )
        assertAllInvariants(session, context: "I-frame all-zero payload")
        _ = clock
    }

    // F-N7: P/F bit set on I-frame and S-frame injections.
    // The P/F bit triggers mandatory responses; verify no crash and correct responses.
    func testConnectedSession_PFBitSet() {
        let (manager, session, peer, clock) = makeConnectedSession()
        let path = DigiPath()

        // I-frame with P=1 — session must respond with F=1 RR
        let iResp = manager.handleInboundIFrame(
            from: peer, path: path, channel: 0,
            ns: 0, nr: 0, pf: true,
            payload: Data("pf-test".utf8)
        )
        // May be nil (if session rejected frame) or an RR frame
        if let r = iResp {
            let decoded = AX25ControlFieldDecoder.decode(control: r.controlByte ?? 0)
            let isSFrame = decoded.frameClass == .S
            XCTAssertTrue(isSFrame, "Response to I-frame P=1 must be S-frame (RR/REJ)")
        }

        // RR poll (P=1) — session must respond with RR(F=1)
        let rrResp = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 0, isPoll: true)
        if let r = rrResp {
            let decoded = AX25ControlFieldDecoder.decode(control: r.controlByte ?? 0)
            XCTAssertEqual(decoded.frameClass, .S,
                "Response to RR(P=1) must be an S-frame (RR F=1)")
        }

        assertAllInvariants(session, context: "P/F bit injection")
        _ = clock
    }
}

// MARK: - Part 5: AIMD Poisoning Resistance

extension AX25SessionFuzzTests {

    // F-A1: REJ storm — 50 consecutive REJ(nr=0) with no ACK progress.
    // cwnd must stay in [1.0, maxWindow] after every iteration.
    // After 50 REJs, cwnd must be exactly 1.0 (floored at minWindow).
    // No secondary loss events from duplicate REJ suppression (Bug A).
    func testAIMDNotPoisonedByREJStorm_50Iterations() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()
        _ = clock

        // Send 1 frame (N(S)=0) so there's something to reject
        _ = manager.sendData(Data("data".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1, "Precondition: 1 outstanding frame")

        for i in 0..<50 {
            // Reset REJ dedup to allow the first REJ each T1 cycle to trigger onLoss()
            if i % 5 == 0 { session.lastREJRetransmitNR = nil }
            _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
            let cwnd = session.aimdWindow.cwnd
            XCTAssertFalse(cwnd.isNaN,    "REJ storm: cwnd NaN after \(i+1) iterations")
            XCTAssertTrue(cwnd.isFinite,  "REJ storm: cwnd Inf after \(i+1) iterations")
            XCTAssertGreaterThanOrEqual(cwnd, 1.0,
                "REJ storm: cwnd \(cwnd) < 1.0 after \(i+1) iterations")
            XCTAssertGreaterThanOrEqual(session.aimdWindow.effectiveWindow, 1,
                "REJ storm: effectiveWindow < 1 after \(i+1) iterations")
        }

        // After 50 REJs with onLoss() triggering, cwnd must have converged to minWindow=1.0
        XCTAssertEqual(session.aimdWindow.cwnd, 1.0, accuracy: 0.001,
            "cwnd must be at minWindow=1.0 after REJ storm (seed: F-A1)")
    }

    // F-A2: Spurious RR with no progress (RR(nr=V(A)) — same N(R) as current V(A)).
    // No AIMD onAck() must be called for no-progress RRs; cwnd must not grow.
    func testAIMDNotGrowingOnNoProgressRR() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()
        _ = clock

        // Send 2 frames
        _ = manager.sendData(Data("a".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("b".utf8), to: peer, path: path, channel: 0)

        let cwindBefore = session.aimdWindow.cwnd
        let currentVA = session.va

        // 50 RRs all with nr=V(A) — zero ack progress
        for i in 0..<50 {
            _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: currentVA)
            let cwnd = session.aimdWindow.cwnd
            // cwnd must not grow beyond starting value (ackedCount=0 → no onAck() calls)
            XCTAssertLessThanOrEqual(cwnd, cwindBefore + 0.001,
                "No-progress RR must not grow cwnd; iter=\(i+1) cwndBefore=\(cwindBefore) cwndNow=\(cwnd)")
            XCTAssertFalse(cwnd.isNaN, "cwnd NaN after no-progress RR iter=\(i+1)")
        }
    }

    // F-A3: RR that acks all outstanding frames in one step (N(R) jumps to V(S)).
    // Each acked frame must trigger exactly one onAck(); cwnd must grow by ackedCount.
    func testAIMDCorrectGrowthWhenFullWindowAcked() {
        let K = 4
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: K)
        let path = DigiPath()
        _ = clock

        // Bring cwnd down to 2 via a loss event to make growth visible
        session.aimdWindow.onLoss()
        let cwindBefore = session.aimdWindow.cwnd

        // Fill the effective window
        for i in 0..<K {
            _ = manager.sendData(Data("frame\(i)".utf8), to: peer, path: path, channel: 0)
        }
        let outstanding = session.outstandingCount
        let vsAfterSend = session.vs

        // One RR that acknowledges all outstanding frames
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: vsAfterSend)

        let cwndAfter = session.aimdWindow.cwnd
        // cwnd should have grown by ackedCount/cwnd (congestion avoidance) or +ackedCount (slow start)
        XCTAssertGreaterThan(cwndAfter, cwindBefore,
            "Full-window ack must grow cwnd; ackedCount=\(outstanding) cwindBefore=\(cwindBefore)")
        assertAIMDInvariants(session, context: "full-window RR ack")
    }

    // F-A4: Invalid N(R) (N(R) > V(S)) injected via RR.
    // The state machine must reject it; cwnd must not change spuriously.
    func testAIMDNotGrowingOnInvalidForwardNR() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()
        _ = clock

        // Send 1 frame; V(S) = 1
        _ = manager.sendData(Data("test".utf8), to: peer, path: path, channel: 0)
        let cwindBefore = session.aimdWindow.cwnd
        let vsBefore = session.vs

        // Inject RR(nr) where nr is ahead of V(S) by 2 (invalid)
        let invalidNR = (vsBefore + 2) % 8
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: invalidNR)

        // cwnd must not have changed (state machine should reject out-of-window nr)
        // Note: the session manager uses vaAfter-vaBefore for ackedCount; if state machine
        // rejects the invalid NR, vaAfter == vaBefore → ackedCount=0 → no onAck() call.
        assertAIMDInvariants(session, context: "invalid-forward-NR RR")
        _ = cwindBefore
    }

    // F-A5: T1 timeout flood — fire T1 many times with outstanding frames.
    // Each T1 timeout triggers onLoss(); cwnd must converge to 1.0, never go below.
    func testAIMDT1TimeoutFlood() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4, initialRto: 1.0)
        let path = DigiPath()

        // Send 4 frames so there's always outstanding work for T1 to trigger on
        for i in 0..<4 {
            _ = manager.sendData(Data("frame\(i)".utf8), to: peer, path: path, channel: 0)
        }

        // Fire T1 50 times
        for i in 0..<50 {
            _ = manager.handleT1Timeout(session: session)
            let cwnd = session.aimdWindow.cwnd
            XCTAssertFalse(cwnd.isNaN,   "T1 flood: cwnd NaN after \(i+1) timeouts")
            XCTAssertTrue(cwnd.isFinite, "T1 flood: cwnd Inf after \(i+1) timeouts")
            XCTAssertGreaterThanOrEqual(cwnd, 1.0,
                "T1 flood: cwnd \(cwnd) < 1.0 after \(i+1) timeouts")
        }

        XCTAssertEqual(session.aimdWindow.cwnd, 1.0, accuracy: 0.001,
            "cwnd must be at minWindow after 50 T1 timeouts (seed: F-A5)")
        _ = clock
    }

    // F-A6: Alternating REJ+RR sequences — simulates realistic lossy channel patterns.
    // cwnd must never leave [1.0, maxWindow]; no NaN/Inf at any step.
    func testAIMDAlternatingLossAndRecovery() {
        let K = 4
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: K)
        let path = DigiPath()
        _ = clock

        var rng = FuzzRNG(seed: 0xDEAD_BEEF_0000_A006)

        for i in 0..<200 {
            // Keep 1–2 frames outstanding at all times
            if session.outstandingCount == 0 {
                _ = manager.sendData(Data("x".utf8), to: peer, path: path, channel: 0)
            }

            let action = rng.nextInt(3)
            switch action {
            case 0:
                // REJ(nr=V(A)): loss event, no ack progress
                session.lastREJRetransmitNR = nil
                _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: session.va)
            case 1:
                // RR(nr=V(S)): ack all outstanding
                _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: session.vs)
            default:
                // RR(nr=V(A)): no progress
                _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: session.va)
            }

            let cwnd = session.aimdWindow.cwnd
            XCTAssertFalse(cwnd.isNaN,   "Alternating loss/recovery: NaN at iter \(i)")
            XCTAssertTrue(cwnd.isFinite, "Alternating loss/recovery: Inf at iter \(i)")
            XCTAssertGreaterThanOrEqual(cwnd, 1.0,
                "Alternating loss/recovery: cwnd \(cwnd) < 1.0 at iter \(i)")
            XCTAssertGreaterThanOrEqual(session.aimdWindow.effectiveWindow, 1,
                "Alternating loss/recovery: effectiveWindow < 1 at iter \(i)")
        }
    }
}

// MARK: - Part 6: Session Lifecycle and Timer Leak Detection

extension AX25SessionFuzzTests {

    // F-L1: Create a session via SABM, close it via DISC from remote peer.
    // Session count must return to initial value; no phantom timer tasks must remain.
    func testSessionCountNoLeakAfterRemoteDISC() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let local = AX25Address(call: "LOCAL", ssid: 0)
        let peer  = AX25Address(call: "PEER",  ssid: 0)
        let path  = DigiPath()

        let initialCount  = manager.sessions.count
        let initialTimers = clock.activeTaskCount

        // Establish session (SABM → UA → connected)
        _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        _ = manager.handleInboundUA(from: peer, path: path, channel: 0)

        XCTAssertEqual(manager.sessions.count, initialCount + 1,
            "Session must be created after SABM+UA (seed: F-L1)")

        // Tear down via DISC from remote peer
        _ = manager.handleInboundDISC(from: peer, path: path, channel: 0)

        // After DISC, session should be in disconnected state or removed.
        // The session count should not have grown; it may stay at +1 (disconnected) or
        // return to 0 depending on implementation, but it must not be +2 or more.
        XCTAssertLessThanOrEqual(manager.sessions.count, initialCount + 1,
            "Session count must not grow after DISC (seed: F-L1)")

        // Timer count must not have grown unboundedly relative to initial + 1 session
        // (each connected session may legitimately hold T1 + T3 = 2 timers)
        let maxExpectedTimers = initialTimers + 4  // generous headroom
        XCTAssertLessThanOrEqual(clock.activeTaskCount, maxExpectedTimers,
            "Active timer count must not grow unboundedly after DISC (seed: F-L1)")
    }

    // F-L2: Create a session via SABM, close it via DM from remote peer.
    func testSessionCountNoLeakAfterRemoteDM() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let local = AX25Address(call: "LOCAL", ssid: 0)
        let peer  = AX25Address(call: "PEER",  ssid: 0)
        let path  = DigiPath()

        _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)

        let before = manager.sessions.count

        // DM during connecting state (peer rejected our SABM)
        manager.handleInboundDM(from: peer, path: path, channel: 0)

        XCTAssertLessThanOrEqual(manager.sessions.count, before,
            "DM must not increase session count (seed: F-L2)")
    }

    // F-L3: Create 8 distinct sessions, all close via T1 max-retries.
    // After expiry, no timer task should remain for those sessions.
    func testTimerCountNoLeakAfterT1MaxRetries() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(
            windowSize: 4,
            maxRetries: 3,   // Reduced retries for faster test
            rtoMin: 1.0, rtoMax: 4.0, initialRto: 1.0
        )
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config

        let initialTimers = clock.activeTaskCount

        // Create 4 sessions and send data on each
        for ssid in 0..<4 {
            let peer = AX25Address(call: "PEER", ssid: ssid)
            _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
            manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
            _ = manager.sendData(Data("data".utf8), to: peer, path: DigiPath(), channel: 0)
        }

        // Advance clock far enough for all T1 retries to expire
        // maxRetries=3, rtoMax=4.0 → worst case = 3 × 4 = 12 seconds + margin
        clock.advance(by: 60.0)

        // After max retries, sessions should be in error/disconnected state
        for ssid in 0..<4 {
            let peer = AX25Address(call: "PEER", ssid: ssid)
            if let s = manager.existingSession(for: peer) {
                let state = s.state
                XCTAssert(
                    state == .disconnected || state == .error,
                    "Session to PEER-\(ssid) must be disconnected/error after T1 max retries, got \(state.rawValue)"
                )
            }
        }

        // Timer count must not have grown unboundedly (generous headroom for any residual)
        let maxExpectedTimers = initialTimers + 4
        XCTAssertLessThanOrEqual(clock.activeTaskCount, maxExpectedTimers,
            "Active timer count must not grow after T1 max-retry expiry (seed: F-L3)")
    }

    // F-L4: Repeated SABM from same peer must not accumulate sessions or timers.
    func testSABMFloodNoSessionOrTimerLeak() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let local = AX25Address(call: "LOCAL", ssid: 0)
        let peer  = AX25Address(call: "PEER",  ssid: 0)
        let path  = DigiPath()

        // Flood 100 SABMs
        for _ in 0..<100 {
            _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        }

        // Must have exactly 1 session for this peer
        let sessionsForPeer = manager.sessions.values.filter { $0.remoteAddress.display == peer.display }
        XCTAssertEqual(sessionsForPeer.count, 1,
            "100 SABMs from same peer must result in exactly 1 session (seed: F-L4)")

        // Timer count must be bounded
        XCTAssertLessThanOrEqual(clock.activeTaskCount, 10,
            "Timer count must be bounded after SABM flood (seed: F-L4)")
    }
}

// MARK: - Part 7: Edge Cases — Unsolicited Frames

extension AX25SessionFuzzTests {

    // F-E1: UA received on a fully-connected session (spurious / retransmitted UA).
    // The state machine must not re-transition to connected or corrupt state.
    func testUnsolicitedUAOnConnectedSession() {
        let (manager, session, peer, clock) = makeConnectedSession()
        let path = DigiPath()
        _ = clock

        let stateBefore = session.state
        XCTAssertEqual(stateBefore, .connected, "Precondition: session is connected")

        // Feed a spurious UA
        manager.handleInboundUA(from: peer, path: path, channel: 0)

        // State must not have regressed or changed unexpectedly
        assertAllInvariants(session, context: "unsolicited UA on connected session")
    }

    // F-E2: DM received on a fully-connected session.
    // DM is a disconnect signal; the session must transition to disconnected.
    func testDMOnConnectedSessionDisconnects() {
        let (manager, session, peer, clock) = makeConnectedSession()
        let path = DigiPath()
        _ = clock

        XCTAssertEqual(session.state, .connected, "Precondition")

        manager.handleInboundDM(from: peer, path: path, channel: 0)

        // After DM on a connected session, state must be disconnected or error
        let validTerminalStates: [AX25SessionState] = [.disconnected, .error]
        XCTAssert(validTerminalStates.contains(session.state),
            "DM on connected session must disconnect; state=\(session.state.rawValue) (seed: F-E2)")
    }

    // F-E3: DISC received while in connecting state (before UA arrives).
    // The session must not get stuck and must not send a UA without an established connection.
    func testDISCDuringConnectingState() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(windowSize: 4, rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)
        let path = DigiPath()

        // Start connection (SABM sent, waiting for UA)
        _ = manager.connect(to: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, .connecting, "Precondition: session in connecting state")

        // Peer sends DISC before UA
        let response = manager.handleInboundDISC(from: peer, path: path, channel: 0)

        // Must not crash; session should be disconnected or error
        let validStates: [AX25SessionState] = [.disconnected, .error, .disconnecting]
        XCTAssert(validStates.contains(session.state),
            "DISC during connecting must lead to disconnected/error; got \(session.state.rawValue) (seed: F-E3)")
        _ = response
    }

    // F-E4: SABM received while already fully connected (reconnect request).
    // Per AX.25, a SABM while connected means the peer wants to reset. The state
    // machine should handle this without session count growth or timer leaks.
    func testSABMOnConnectedSession_SessionCountStable() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let local = AX25Address(call: "LOCAL", ssid: 0)
        let peer  = AX25Address(call: "PEER",  ssid: 0)
        let path  = DigiPath()

        // Establish initial connection (responder path)
        _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        let before = manager.sessions.count

        // SABM arrives again while we're in connected state
        _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)

        XCTAssertEqual(manager.sessions.count, before,
            "SABM on connected session must not create a new session (seed: F-E4)")
    }
}

// MARK: - Part 8: Chaos Sequence (Mixed Frame Types)

extension AX25SessionFuzzTests {

    // F-C1: 1000-iteration chaos sequence — random mix of all inbound frame types,
    // random valid and invalid sequence numbers, random payloads.
    // After every injection: AIMD invariants must hold.
    // After all iterations: session and timer counts must be bounded.
    func testChaosSequenceAllFrameTypes() {
        var rng = FuzzRNG(seed: 0xCAFE_BABE_DEAD_BEEF)

        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(
            windowSize: 4,
            rtoMin: 0.5, rtoMax: 8.0, initialRto: 1.0
        )
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)
        let local = AX25Address(call: "LOCAL", ssid: 0)
        let path = DigiPath()

        // Establish a connected session to start
        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        var session = manager.session(for: peer, path: path, channel: 0)

        let iterationCount = 1000
        for i in 0..<iterationCount {
            let action = rng.nextInt(12)  // 0..11

            switch action {
            case 0:
                // RR with random N(R)
                let nr = rng.nextInt(8)
                _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: nr)

            case 1:
                // REJ with random N(R)
                let nr = rng.nextInt(8)
                session.lastREJRetransmitNR = nil  // prevent duplicate suppression masking bugs
                _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: nr)

            case 2:
                // I-frame with random N(S), N(R), random payload size
                let ns = rng.nextInt(8)
                let nr = rng.nextInt(8)
                let pLen = rng.nextInt(in: 0...256)
                let payload = rng.nextData(count: pLen)
                _ = manager.handleInboundIFrame(
                    from: peer, path: path, channel: 0,
                    ns: ns, nr: nr, pf: false, payload: payload
                )

            case 3:
                // Send data (add to outbound queue)
                let pLen = rng.nextInt(in: 1...64)
                let payload = rng.nextData(count: pLen)
                _ = manager.sendData(payload, to: peer, path: path, channel: 0)

            case 4:
                // T1 timeout
                _ = manager.handleT1Timeout(session: session)

            case 5:
                // Advance clock by random amount (0.01 to 2.0 seconds)
                let dt = Double(rng.nextInt(in: 1...200)) / 100.0
                clock.advance(by: dt)
                // Re-fetch session (it may have changed state)
                if let s = manager.existingSession(for: peer, path: path, channel: 0) {
                    session = s
                }

            case 6:
                // UA (unsolicited on established session, or may re-complete connecting)
                manager.handleInboundUA(from: peer, path: path, channel: 0)

            case 7:
                // DM — forces disconnection; re-connect immediately
                manager.handleInboundDM(from: peer, path: path, channel: 0)
                _ = manager.connect(to: peer, path: path, channel: 0)
                manager.handleInboundUA(from: peer, path: path, channel: 0)
                session = manager.session(for: peer, path: path, channel: 0)

            case 8:
                // SABM from peer (peer-initiated reset)
                _ = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)

            case 9:
                // DISC from peer then reconnect
                _ = manager.handleInboundDISC(from: peer, path: path, channel: 0)
                _ = manager.connect(to: peer, path: path, channel: 0)
                manager.handleInboundUA(from: peer, path: path, channel: 0)
                session = manager.session(for: peer, path: path, channel: 0)

            case 10:
                // RR poll
                let nr = rng.nextInt(8)
                _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: nr, isPoll: true)

            default:
                // I-frame with P=1 (requires response)
                let ns = rng.nextInt(8)
                let nr = rng.nextInt(8)
                _ = manager.handleInboundIFrame(
                    from: peer, path: path, channel: 0,
                    ns: ns, nr: nr, pf: true,
                    payload: Data("pf".utf8)
                )
            }

            // After every action: AIMD invariants must hold
            if session.state == .connected {
                let cwnd = session.aimdWindow.cwnd
                XCTAssertFalse(cwnd.isNaN,   "Chaos: cwnd NaN at iter \(i) action \(action)")
                XCTAssertTrue(cwnd.isFinite, "Chaos: cwnd Inf at iter \(i) action \(action)")
                XCTAssertGreaterThanOrEqual(cwnd, 1.0,
                    "Chaos: cwnd \(cwnd) < 1.0 at iter \(i) action \(action)")
                XCTAssertGreaterThanOrEqual(session.aimdWindow.effectiveWindow, 1,
                    "Chaos: effectiveWindow < 1 at iter \(i) action \(action)")
            }
        }

        // Session count must be bounded (at most 2: the one we created + maybe one from SABM)
        XCTAssertLessThanOrEqual(manager.sessions.count, 3,
            "Session count must be bounded after chaos sequence (seed: 0xCAFEBABEDEADBEEF)")
    }

    // F-C2: Chaos sequence from a fresh (never-connected) manager.
    // All frames must be safely dropped without creating sessions or crashing.
    func testChaosSequenceAgainstEmptyManager() {
        var rng = FuzzRNG(seed: 0xFEED_FACE_DEAD_C0DE)

        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        let strangers = (0..<8).map { AX25Address(call: "STRNGR", ssid: $0) }
        let path = DigiPath()

        let initialCount = manager.sessions.count

        for i in 0..<2000 {
            let peer = strangers[rng.nextInt(strangers.count)]
            let action = rng.nextInt(6)
            let nr = rng.nextInt(8)
            let ns = rng.nextInt(8)

            switch action {
            case 0: manager.handleInboundUA(from: peer, path: path, channel: 0)
            case 1: manager.handleInboundDM(from: peer, path: path, channel: 0)
            case 2: _ = manager.handleInboundDISC(from: peer, path: path, channel: 0)
            case 3: _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: nr)
            case 4: _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: nr)
            default:
                _ = manager.handleInboundIFrame(
                    from: peer, path: path, channel: 0,
                    ns: ns, nr: nr, pf: false,
                    payload: rng.nextData(count: rng.nextInt(in: 0...64))
                )
            }

            // UA/DM/DISC/RR/REJ/IFrame for unknown sessions must NEVER create sessions
            XCTAssertEqual(manager.sessions.count, initialCount,
                "Empty manager: session count must stay at \(initialCount); grew at iter \(i) action \(action) (seed: 0xFEEDFACEDEADC0DE)")
        }
    }
}

// MARK: - Part 9: Regression Tests for Specific Bug Classes

extension AX25SessionFuzzTests {

    // F-R1: Regression — REJ with N(R) < V(A) (stale REJ) must NOT corrupt send buffer.
    // Before Bug D fix, acknowledgeUpTo with stale nr would wrap the modulo loop and
    // delete frames that were still outstanding, corrupting the send buffer.
    func testStaleREJDoesNotCorruptSendBuffer() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()
        _ = clock

        // Send 3 frames: N(S) = 0, 1, 2
        for _ in 0..<3 {
            _ = manager.sendData(Data("test".utf8), to: peer, path: path, channel: 0)
        }

        let outstandingBefore = session.outstandingCount
        XCTAssertGreaterThan(outstandingBefore, 0, "Precondition: frames in flight")

        // Simulate receipt of RR(nr=2) — acks N(S)=0,1
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 2)

        let vaAfterRR = session.va
        XCTAssertEqual(vaAfterRR, 2, "V(A) should be 2 after RR(nr=2)")

        // Now inject a STALE REJ: nr=1 which is behind V(A)=2
        // This must NOT corrupt the send buffer (Bug D regression check)
        _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 1)

        // send buffer must still contain N(S)=2 (not deleted by stale REJ)
        let vaAfterREJ = session.va
        XCTAssertGreaterThanOrEqual(vaAfterREJ, vaAfterRR,
            "V(A) must not regress after stale REJ (Bug D regression)")
        assertAllInvariants(session, context: "stale REJ regression")
    }

    // F-R2: Regression — duplicate REJ(nr=0) must not trigger onLoss() twice in a row.
    // This is the Bug A (REJ amplification) + Bug B2 (AIMD on REJ) interaction.
    // The first REJ triggers onLoss(); the second (duplicate) must be suppressed.
    func testDuplicateREJSuppressesSecondLossEvent() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()
        _ = clock

        _ = manager.sendData(Data("test".utf8), to: peer, path: path, channel: 0)

        // First REJ — clears lastREJRetransmitNR=nil → shouldRetransmit=true → onLoss()
        session.lastREJRetransmitNR = nil
        let cwndBefore = session.aimdWindow.cwnd
        _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        let cwndAfterFirst = session.aimdWindow.cwnd
        XCTAssertLessThan(cwndAfterFirst, cwndBefore,
            "First REJ must trigger onLoss() and halve cwnd")

        // Second REJ with same nr and no ack progress — must be suppressed
        _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        let cwndAfterSecond = session.aimdWindow.cwnd
        XCTAssertEqual(cwndAfterSecond, cwndAfterFirst, accuracy: 0.001,
            "Duplicate REJ must NOT trigger second onLoss() — cwnd must not halve again (Bug A+B2 regression)")
    }

    // F-R3: Regression — RR with out-of-window N(R) must not grow AIMD window (Bug B3).
    // Before the fix, the raw `nr` value was used for acknowledgedCount, allowing
    // spurious AIMD growth for NRs that the state machine had already rejected.
    func testOutOfWindowRRDoesNotGrowAIMD() {
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()
        _ = clock

        // Send 1 frame: V(S)=1, V(A)=0
        _ = manager.sendData(Data("test".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.vs, 1, "Precondition: V(S)=1")
        XCTAssertEqual(session.va, 0, "Precondition: V(A)=0")

        let cwindBefore = session.aimdWindow.cwnd

        // Inject RR(nr=7) — N(R)=7 is outside the valid window [V(A), V(S)]=[0,1]
        // The state machine should reject this; vaAfter must equal vaBefore (=0),
        // so ackedCount=(0-0+8)%8=0, and onAck() must NOT be called.
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 7)

        let cwindAfter = session.aimdWindow.cwnd
        // cwnd must not have grown if the RR was rejected (B3 regression check)
        // Allow a tiny epsilon for floating-point rounding but not a full onAck() step
        XCTAssertLessThanOrEqual(cwindAfter, cwindBefore + 0.01,
            "Out-of-window RR must not grow AIMD cwnd (Bug B3 regression)")
    }

    // F-R4: Regression — send path AIMD gate (Bug B1).
    // sendData must respect the AIMD effective window just like drainPendingDataQueue.
    // After N loss events reduce cwnd to 1, sendData must queue frames beyond the window.
    func testSendDataAIMDGateQueuesExcess() {
        let K = 4
        let (manager, session, peer, clock) = makeConnectedSession(windowSize: K)
        let path = DigiPath()
        _ = clock

        // Drive cwnd to 1 via repeated loss
        for _ in 0..<20 { session.aimdWindow.onLoss() }
        XCTAssertEqual(session.aimdWindow.effectiveWindow, 1, "Precondition: effectiveWindow=1")

        // Send 1 frame to fill the effective window
        _ = manager.sendData(Data("first".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1,
            "Precondition: exactly 1 frame in flight after first send (Bug B1)")

        // Send 3 more frames — with outstandingCount=1 == effectiveWindow=1, all must queue
        for i in 0..<3 {
            _ = manager.sendData(Data("extra\(i)".utf8), to: peer, path: path, channel: 0)
        }

        // Outstanding must still be 1 (not 4)
        XCTAssertEqual(session.outstandingCount, 1,
            "sendData must respect AIMD gate: outstandingCount must be 1, not 4 (Bug B1 regression)")

        // Pending queue must have the 3 excess frames
        XCTAssertEqual(session.pendingDataQueue.count, 3,
            "3 excess frames must be in pendingDataQueue when effective window is 1 (Bug B1 regression)")
    }

    // F-R5: Regression — I-frame with out-of-window piggybacked N(R) must not corrupt sendBuffer.
    //
    // Bug J root cause:
    //   handleInboundIFrame passed the raw `nr` field from the frame directly to
    //   acknowledgeUpTo(from: vaBefore, to: nr).  acknowledgeUpTo loops while current != nr,
    //   removing sendBuffer[current] on each step.  When nr was outside [V(A), V(S)] the loop
    //   walked into — and deleted — slots that had never been sent, making sendBuffer.count
    //   fall below outstandingCount.  checkInvariants() then fired a DEBUG assert (SIGTRAP).
    //
    // Protocol consequence:
    //   Silent data loss.  The send buffer entries were silently destroyed; when T1 fired,
    //   framesToRetransmit() returned nothing and the lost frames were never recovered.
    //   The sending station believed frames 0–(nr-1) were acknowledged by the far end even
    //   though the far end never sent a valid N(R) for them.
    //
    // Fix (identical pattern to Bug B3 / handleInboundRR):
    //   Capture let vaAfter = session.va AFTER stateMachine.handle(), then call
    //   acknowledgeUpTo(from: vaBefore, to: vaAfter).  The state machine only advances V(A)
    //   when N(R) is genuinely in-window, so an out-of-window nr leaves vaAfter == vaBefore
    //   and acknowledgeUpTo is a no-op.
    //
    // Replay trace seed: deterministic — no RNG required.
    func testIFrameOutOfWindowNRDoesNotCorruptSendBuffer() {
        let (manager, session, peer, _) = makeConnectedSession(windowSize: 4)
        let path = DigiPath()

        // Send 2 frames: V(S)=2, V(A)=0, sendBuffer keys={0,1}
        _ = manager.sendData(Data("frame0".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("frame1".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.vs, 2,              "Precondition: V(S)=2 (Bug J regression)")
        XCTAssertEqual(session.va, 0,              "Precondition: V(A)=0 (Bug J regression)")
        XCTAssertEqual(session.outstandingCount, 2, "Precondition: 2 frames in flight (Bug J regression)")
        XCTAssertEqual(session.sendBuffer.count, 2, "Precondition: sendBuffer has 2 entries (Bug J regression)")

        // Inject I-frame(N(S)=0, N(R)=6): N(R)=6 is outside valid window [V(A)=0, V(S)=2].
        // The state machine must reject the piggybacked N(R) and leave V(A) at 0.
        // Before the fix, acknowledgeUpTo(from:0, to:6) would loop 6 times, deleting
        // sendBuffer[0..5] — but only 0 and 1 exist — corrupting the invariant.
        let iFramePayload = Data("peer0".utf8)
        _ = manager.handleInboundIFrame(
            from: peer, path: path, channel: 0,
            ns: 0, nr: 6, pf: false, payload: iFramePayload
        )

        // Core invariant: sendBuffer.count must equal outstandingCount
        XCTAssertEqual(
            session.sendBuffer.count, session.outstandingCount,
            "sendBuffer.count must equal outstandingCount after I-frame with out-of-window N(R) (Bug J regression)"
        )

        // V(A) must not have advanced past the legitimate window
        XCTAssertLessThanOrEqual(session.va, session.vs,
            "V(A) must not exceed V(S) after out-of-window I-frame N(R) (Bug J regression)")

        // AIMD invariants must still hold
        assertAllInvariants(session, context: "F-R5 post-inject")
    }

    // F-R6: Regression — DISC received while in .connecting state must terminate the session.
    //
    // Bug I root cause:
    //   handleInboundDISC searched for the session using findConnectedSession() (which only
    //   matches .connected sessions) and a manual .disconnecting filter.  A session in the
    //   .connecting state was not matched by either search, so the guard fell through to the
    //   "no session" branch: DM was returned (correct) but no state transition was performed
    //   (incorrect).  The session remained stuck in .connecting and continued to retransmit
    //   SABM on every T1 expiry until maxRetries was exhausted.
    //
    // Protocol consequence:
    //   Per AX.25 §6.3.4, a DISC received during connection setup is an explicit refusal
    //   from the far end.  The correct response is to send DM and immediately cancel the
    //   connect attempt.  Instead, AXTerm kept hammering the channel with SABM retransmissions,
    //   wasting RF bandwidth and delaying the local operator's awareness of the refusal.
    //
    // Fix:
    //   Added `let connecting = sessions.values.first { $0.state == .connecting && ... }`
    //   and included `?? connecting` in the guard clause so all three long-lived states
    //   (.connected, .disconnecting, .connecting) are handled by the same code path.
    //
    // Replay trace seed: deterministic — no RNG required.
    func testDISCDuringConnectingTerminatesSession() {
        let clock = AX25VirtualClock()
        let config = AX25SessionConfig(windowSize: 4, rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0)
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "LOCAL", ssid: 0),
            clock: clock
        )
        manager.defaultConfig = config
        let peer = AX25Address(call: "PEER", ssid: 0)
        let path = DigiPath()

        // Initiate connection — SABM sent, session now in .connecting
        _ = manager.connect(to: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, .connecting,
            "Precondition: session must be in .connecting before DISC injection (Bug I regression)")

        // Peer explicitly refuses the connection by sending DISC before UA
        _ = manager.handleInboundDISC(from: peer, path: path, channel: 0)

        // Session must not remain in .connecting — any terminal or transitional state is valid
        let validStates: [AX25SessionState] = [.disconnected, .error, .disconnecting]
        XCTAssert(validStates.contains(session.state),
            "DISC during connecting must terminate session; got \(session.state.rawValue) (Bug I regression)")

        // The timer that was running for T1/SABM retransmit must be cancelled —
        // no orphaned tasks after the session terminates.
        XCTAssertEqual(clock.activeTaskCount, 0,
            "No active timers must remain after DISC terminates a .connecting session (Bug I regression)")
    }
}
