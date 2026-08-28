import XCTest
@testable import AXTerm

/// Fuzz and property tests for the NET/ROM circuit state machine.
///
/// Three layers:
///  1. Event storms — random events must never crash the machine or
///     violate its invariants.
///  2. Adversarial peer — random-but-parseable frames at a connected
///     machine must never produce out-of-order or duplicated delivery.
///  3. Lossy-link soak — two real machines over a chaos link (loss,
///     duplication, reordering, with every frame passing through the
///     wire codec) must still deliver every byte, in order, exactly once.
///
/// All randomness is seeded; failure messages carry the seed.
final class NetRomCircuitFuzzTests: XCTestCase {

    private let user = AX25Address(call: "K0EPI", ssid: 0)
    private let nodeA = AX25Address(call: "K0EPI", ssid: 7)
    private let nodeB = AX25Address(call: "KB5YZB", ssid: 7)

    // MARK: - Invariants

    private func assertInvariants(_ m: NetRomCircuitStateMachine,
                                  seed: UInt64, step: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let context = "seed \(String(seed, radix: 16)) step \(step)"
        XCTAssertLessThanOrEqual(m.outstandingCount, m.window,
                                 "outstanding exceeds window — \(context)", file: file, line: line)
        // After a T1 requeue while choked, vs legitimately sits ahead of
        // va with an empty ack queue until the next kick realigns it
        // (kernel-accurate). So: outstanding ≤ span ≤ window.
        let vaVsSpan = ((m.vs - m.va) % 256 + 256) % 256
        XCTAssertLessThanOrEqual(m.outstandingCount, vaVsSpan,
                                 "outstanding above va→vs span — \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(vaVsSpan, m.window,
                                 "va→vs span above window — \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(m.retryCount, m.config.maxRetries,
                                 "retry count above N2 — \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(m.reassembly.count, m.config.maxReassemblyBytes,
                                 "reassembly above cap — \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(m.resequenceBuffer.count, NetRomWire.modulus,
                                 "resequence buffer runaway — \(context)", file: file, line: line)
        if m.state == .disconnected {
            XCTAssertEqual(m.outstandingCount, 0, "buffers purged on death — \(context)", file: file, line: line)
            XCTAssertTrue(m.writeQueue.isEmpty, "write queue purged — \(context)", file: file, line: line)
        }
    }

    // MARK: - 1. Event storms

    func testRandomEventStormsNeverCrashOrBreakInvariants() {
        for seed: UInt64 in 1...60 {
            var rng = NetRomFuzzRNG(seed: seed)
            var m = NetRomCircuitStateMachine(
                config: NetRomCircuitConfig(),
                localUser: user, localNode: nodeA, remoteNode: nodeB,
                myIndex: 1, myId: 1
            )
            for step in 0..<400 {
                _ = m.handle(event: randomEvent(&rng))
                assertInvariants(m, seed: seed, step: step)
            }
        }
    }

    private func randomEvent(_ rng: inout NetRomFuzzRNG) -> NetRomCircuitEvent {
        switch rng.int(0..<12) {
        case 0: return .connectRequest
        case 1: return .disconnectRequest
        case 2: return .sendData(rng.data(count: rng.int(1..<600)))
        case 3: return .t1Timeout
        case 4: return .t2Timeout
        case 5: return .t4Timeout
        case 6: return .localBusy(rng.chance(0.5))
        case 7: return .acceptInbound(
            theirIndex: rng.byte(), theirId: rng.byte(),
            proposedWindow: rng.byte(),
            t1Seconds: rng.chance(0.5) ? UInt16(truncatingIfNeeded: rng.next()) : nil,
            bpqExtension: rng.chance(0.5))
        case 8: return .transportFailure("fuzz")
        default: return .received(randomL4(&rng))
        }
    }

    private func randomL4(_ rng: inout NetRomFuzzRNG) -> NetRomL4Frame {
        switch rng.int(0..<7) {
        case 0: return .connectRequest(
            myIndex: rng.byte(), myId: rng.byte(), proposedWindow: rng.byte(),
            user: user, originNode: nodeB,
            t1Seconds: rng.chance(0.5) ? 60 : nil)
        case 1: return .connectAck(
            yourIndex: rng.byte(), yourId: rng.byte(),
            myIndex: rng.byte(), myId: rng.byte(),
            acceptedWindow: rng.byte(), ttl: nil, refused: rng.chance(0.3))
        case 2: return .disconnectRequest(yourIndex: rng.byte(), yourId: rng.byte())
        case 3: return .disconnectAck(yourIndex: rng.byte(), yourId: rng.byte())
        case 4: return .information(
            yourIndex: rng.byte(), yourId: rng.byte(),
            txSeq: rng.byte(), rxSeq: rng.byte(),
            choke: rng.chance(0.15), nak: rng.chance(0.15), moreFollows: rng.chance(0.3),
            payload: rng.data(count: rng.int(0..<237)))
        case 5: return .informationAck(
            yourIndex: rng.byte(), yourId: rng.byte(), rxSeq: rng.byte(),
            choke: rng.chance(0.15), nak: rng.chance(0.15))
        default: return .reset(yourIndex: rng.byte(), yourId: rng.byte())
        }
    }

    // MARK: - 2. Adversarial peer: delivery is a prefix, in order, once

    func testAdversarialPeerCannotCorruptTheDeliveredStream() {
        // Payloads are tagged with their intended stream position; every
        // frame the adversary sends is (ns, tag ns). Whatever chaos it
        // plays with ordering and duplication, the delivered stream must
        // be 0,1,2,... with no gaps, repeats, or inversions.
        for seed: UInt64 in 1...40 {
            var rng = NetRomFuzzRNG(seed: seed)
            var m = NetRomCircuitStateMachine(
                config: NetRomCircuitConfig(),
                localUser: user, localNode: nodeA, remoteNode: nodeB,
                myIndex: 1, myId: 1
            )
            _ = m.handle(event: .connectRequest)
            _ = m.handle(event: .received(.connectAck(
                yourIndex: 1, yourId: 1, myIndex: 9, myId: 9,
                acceptedWindow: 4, ttl: nil, refused: false)))

            var deliveredTags: [Int] = []
            for step in 0..<600 {
                guard m.state == .connected else { break }
                let ns = rng.int(0..<256)
                let frame = NetRomL4Frame.information(
                    yourIndex: 1, yourId: 1,
                    txSeq: UInt8(ns), rxSeq: 0,
                    choke: false, nak: false, moreFollows: false,
                    payload: Data("TAG:\(ns)".utf8)
                )
                let actions = m.handle(event: .received(frame))
                for action in actions {
                    if case .deliverData(let data) = action {
                        let text = String(decoding: data, as: UTF8.self)
                        deliveredTags.append(Int(text.dropFirst(4)) ?? -1)
                    }
                }
                // Occasionally let the delayed ack fire.
                if rng.chance(0.3) { _ = m.handle(event: .t2Timeout) }
                assertInvariants(m, seed: seed, step: step)
            }

            // The delivered tags must be exactly vr's walk: consecutive
            // mod 256 starting at 0, no repeats within a lap's window.
            for (i, tag) in deliveredTags.enumerated() {
                XCTAssertEqual(tag, i % 256,
                               "seed \(seed): delivery must advance in strict sequence order")
            }
        }
    }

    // MARK: - 3. Lossy-link soak

    /// One direction of the chaos link: frames in flight, as wire bytes.
    private struct Pipe {
        var frames: [Data] = []
    }

    func testLossyLinkDeliversEverythingInOrderExactlyOnce() {
        for seed: UInt64 in 1...30 {
            runLossySoak(seed: seed, lossRate: 0.15, dupRate: 0.10, shuffle: true)
        }
    }

    func testPerfectLinkDeliversEverythingInOrderExactlyOnce() {
        // Degenerate chaos: sanity-check the harness itself.
        runLossySoak(seed: 424242, lossRate: 0, dupRate: 0, shuffle: false)
    }

    private func runLossySoak(seed: UInt64, lossRate: Double, dupRate: Double, shuffle: Bool) {
        var rng = NetRomFuzzRNG(seed: seed)
        var config = NetRomCircuitConfig()
        config.window = 4
        config.maxRetries = 60  // chaos link needs patience, not brains

        var a = NetRomCircuitStateMachine(
            config: config, localUser: user, localNode: nodeA, remoteNode: nodeB,
            myIndex: 1, myId: 1)
        var b = NetRomCircuitStateMachine(
            config: config, localUser: user, localNode: nodeB, remoteNode: nodeA,
            myIndex: 2, myId: 2)

        var aToB = Pipe()
        var bToA = Pipe()
        var deliveredAtB = Data()
        var deliveredAtA = Data()

        // Establish the circuit over the chaos link too: A's CONREQ can
        // be lost; T1 retries cover it, exactly as on air.
        enqueue(a.handle(event: .connectRequest), from: &a, into: &aToB, rng: &rng,
                lossRate: lossRate, dupRate: dupRate)

        // The message load: distinct, sized to cross fragment boundaries.
        var pendingSends: [(toA: Bool, payload: Data)] = []
        var expectedAtB = Data()
        var expectedAtA = Data()
        for i in 0..<24 {
            let size = [1, 17, 235, 236, 237, 400][rng.int(0..<6)]
            let payload = Data((0..<size).map { UInt8(($0 &+ i) % 251) })
            if rng.chance(0.5) {
                pendingSends.append((toA: false, payload: payload))
                expectedAtB.append(payload)
            } else {
                pendingSends.append((toA: true, payload: payload))
                expectedAtA.append(payload)
            }
        }

        var step = 0
        var aWasConnected = false
        var bWasConnected = false
        let stepLimit = 60_000
        while step < stepLimit {
            step += 1

            // Feed new application sends gradually.
            if !pendingSends.isEmpty && rng.chance(0.2) {
                let send = pendingSends.removeFirst()
                if send.toA {
                    guard b.state == .connected || b.state == .connecting else {
                        pendingSends.insert(send, at: 0); continue
                    }
                    enqueue(b.handle(event: .sendData(send.payload)), from: &b, into: &bToA,
                            rng: &rng, lossRate: lossRate, dupRate: dupRate)
                } else {
                    enqueue(a.handle(event: .sendData(send.payload)), from: &a, into: &aToB,
                            rng: &rng, lossRate: lossRate, dupRate: dupRate)
                }
            }

            // Move a frame across one pipe (possibly out of order).
            let pickAToB = !aToB.frames.isEmpty && (bToA.frames.isEmpty || rng.chance(0.5))
            if pickAToB {
                let index = shuffle ? rng.int(0..<aToB.frames.count) : 0
                let wire = aToB.frames.remove(at: index)
                deliver(wire, to: &b, otherPipe: &bToA, delivered: &deliveredAtB,
                        rng: &rng, lossRate: lossRate, dupRate: dupRate, seed: seed, step: step)
            } else if !bToA.frames.isEmpty {
                let index = shuffle ? rng.int(0..<bToA.frames.count) : 0
                let wire = bToA.frames.remove(at: index)
                deliver(wire, to: &a, otherPipe: &aToB, delivered: &deliveredAtA,
                        rng: &rng, lossRate: lossRate, dupRate: dupRate, seed: seed, step: step)
            } else {
                // Quiet link: fire timers to make progress. T2 first (acks
                // unblock windows), then T1 (retransmits repair loss).
                if b.t2Running {
                    enqueue(b.handle(event: .t2Timeout), from: &b, into: &bToA,
                            rng: &rng, lossRate: lossRate, dupRate: dupRate)
                } else if a.t2Running {
                    enqueue(a.handle(event: .t2Timeout), from: &a, into: &aToB,
                            rng: &rng, lossRate: lossRate, dupRate: dupRate)
                } else if a.t1Running {
                    enqueue(a.handle(event: .t1Timeout), from: &a, into: &aToB,
                            rng: &rng, lossRate: lossRate, dupRate: dupRate)
                } else if b.t1Running {
                    enqueue(b.handle(event: .t1Timeout), from: &b, into: &bToA,
                            rng: &rng, lossRate: lossRate, dupRate: dupRate)
                } else if pendingSends.isEmpty {
                    break  // truly idle: done
                }
            }

            assertInvariants(a, seed: seed, step: step)
            assertInvariants(b, seed: seed, step: step)
            // B starts .disconnected until A's CONREQ survives the chaos
            // link; a death only counts after a circuit existed.
            if a.state == .connected { aWasConnected = true }
            if b.state == .connected { bWasConnected = true }
            if aWasConnected {
                XCTAssertNotEqual(a.state, .disconnected, "seed \(seed) step \(step): A died mid-soak")
            }
            if bWasConnected {
                XCTAssertNotEqual(b.state, .disconnected, "seed \(seed) step \(step): B died mid-soak")
            }

            if pendingSends.isEmpty && deliveredAtB == expectedAtB && deliveredAtA == expectedAtA
                && aToB.frames.isEmpty && bToA.frames.isEmpty
                && a.outstandingCount == 0 && b.outstandingCount == 0 {
                break
            }
        }

        XCTAssertLessThan(step, stepLimit, "seed \(seed): soak did not converge")
        XCTAssertEqual(deliveredAtB, expectedAtB,
                       "seed \(seed): every byte A sent arrives at B, in order, exactly once")
        XCTAssertEqual(deliveredAtA, expectedAtA,
                       "seed \(seed): every byte B sent arrives at A, in order, exactly once")
    }

    /// Encode outgoing frames as real wire datagrams and put them on the
    /// pipe, applying loss and duplication.
    private func enqueue(_ actions: [NetRomCircuitAction],
                         from machine: inout NetRomCircuitStateMachine,
                         into pipe: inout Pipe,
                         rng: inout NetRomFuzzRNG,
                         lossRate: Double, dupRate: Double) {
        for action in actions {
            guard case .send(let frame) = action else { continue }
            let datagram = NetRomDatagram(
                origin: machine.localNode,
                destination: machine.remoteNode,
                ttl: 25,
                transport: frame
            )
            let wire = NetRomTransportWire.encode(datagram)
            if rng.chance(lossRate) { continue }         // lost on air
            pipe.frames.append(wire)
            if rng.chance(dupRate) { pipe.frames.append(wire) }  // duplicated
        }
    }

    /// Push one wire frame through the codec into a machine; its response
    /// actions go onto the reverse pipe.
    private func deliver(_ wire: Data,
                         to machine: inout NetRomCircuitStateMachine,
                         otherPipe: inout Pipe,
                         delivered: inout Data,
                         rng: inout NetRomFuzzRNG,
                         lossRate: Double, dupRate: Double,
                         seed: UInt64, step: Int) {
        guard let datagram = NetRomTransportWire.parse(wire) else {
            return XCTFail("seed \(seed) step \(step): machine-built frame failed to parse")
        }
        if case .connectRequest = datagram.transport {
            // The soak's B accepts A's CONREQ by hand (endpoint's job in
            // production). Duplicates re-enter as normal received frames.
            if machine.state == .disconnected {
                if case let .connectRequest(myIndex, myId, window, _, _, t1) = datagram.transport {
                    let actions = machine.handle(event: .acceptInbound(
                        theirIndex: myIndex, theirId: myId,
                        proposedWindow: window, t1Seconds: t1,
                        bpqExtension: t1 != nil))
                    collect(actions, from: &machine, into: &otherPipe, delivered: &delivered,
                            rng: &rng, lossRate: lossRate, dupRate: dupRate)
                }
                return
            }
        }
        let actions = machine.handle(event: .received(datagram.transport))
        collect(actions, from: &machine, into: &otherPipe, delivered: &delivered,
                rng: &rng, lossRate: lossRate, dupRate: dupRate)
    }

    private func collect(_ actions: [NetRomCircuitAction],
                         from machine: inout NetRomCircuitStateMachine,
                         into pipe: inout Pipe,
                         delivered: inout Data,
                         rng: inout NetRomFuzzRNG,
                         lossRate: Double, dupRate: Double) {
        for action in actions {
            if case .deliverData(let data) = action {
                delivered.append(data)
            }
        }
        enqueue(actions, from: &machine, into: &pipe, rng: &rng,
                lossRate: lossRate, dupRate: dupRate)
    }
}
