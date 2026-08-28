import XCTest
@testable import AXTerm

/// Behavioral tests for the NET/ROM L4 circuit state machine, checked
/// against the Linux AF_NETROM reference (nr_in.c / nr_out.c / nr_subr.c).
/// Where AXTerm deliberately deviates (NAK-resend T1, idle-T1, reassembly
/// cap) the tests pin the deviation, with the rationale in NetRomCircuit.swift.
final class NetRomCircuitTests: XCTestCase {

    private let user = AX25Address(call: "K0EPI", ssid: 0)
    private let node = AX25Address(call: "K0EPI", ssid: 7)
    private let remote = AX25Address(call: "KB5YZB", ssid: 7)

    private func machine(_ mutate: (inout NetRomCircuitConfig) -> Void = { _ in }) -> NetRomCircuitStateMachine {
        var config = NetRomCircuitConfig()
        mutate(&config)
        return NetRomCircuitStateMachine(
            config: config, localUser: user, localNode: node,
            remoteNode: remote, myIndex: 0x01, myId: 0x01
        )
    }

    private func connected(_ mutate: (inout NetRomCircuitConfig) -> Void = { _ in }) -> NetRomCircuitStateMachine {
        var m = machine(mutate)
        _ = m.handle(event: .connectRequest)
        _ = m.handle(event: .received(.connectAck(
            yourIndex: 1, yourId: 1, myIndex: 0x1A, myId: 0x2B,
            acceptedWindow: UInt8(m.config.clampedWindow), ttl: nil, refused: false)))
        XCTAssertEqual(m.state, .connected)
        return m
    }

    // MARK: Action extraction helpers

    private func sentFrames(_ actions: [NetRomCircuitAction]) -> [NetRomL4Frame] {
        actions.compactMap { if case .send(let f) = $0 { return f }; return nil }
    }

    private func sentInfos(_ actions: [NetRomCircuitAction]) -> [(txSeq: UInt8, rxSeq: UInt8, more: Bool, payload: Data)] {
        sentFrames(actions).compactMap {
            if case let .information(_, _, txSeq, rxSeq, _, _, more, payload) = $0 {
                return (txSeq, rxSeq, more, payload)
            }
            return nil
        }
    }

    private func sentAcks(_ actions: [NetRomCircuitAction]) -> [(rxSeq: UInt8, choke: Bool, nak: Bool)] {
        sentFrames(actions).compactMap {
            if case let .informationAck(_, _, rxSeq, choke, nak) = $0 {
                return (rxSeq, choke, nak)
            }
            return nil
        }
    }

    private func delivered(_ actions: [NetRomCircuitAction]) -> [Data] {
        actions.compactMap { if case .deliverData(let d) = $0 { return d }; return nil }
    }

    private func disconnectReason(_ actions: [NetRomCircuitAction]) -> NetRomDisconnectReason? {
        actions.compactMap { if case .notifyDisconnected(let r) = $0 { return r }; return nil }.first
    }

    private func infoAck(_ r: Int, choke: Bool = false, nak: Bool = false) -> NetRomL4Frame {
        .informationAck(yourIndex: 1, yourId: 1, rxSeq: UInt8(r), choke: choke, nak: nak)
    }

    private func info(_ ns: Int, rxSeq: Int = 0, more: Bool = false, choke: Bool = false,
                      payload: Data = Data([0xAA])) -> NetRomL4Frame {
        .information(yourIndex: 1, yourId: 1, txSeq: UInt8(ns), rxSeq: UInt8(rxSeq),
                     choke: choke, nak: false, moreFollows: more, payload: payload)
    }

    // MARK: - Connect (initiator)

    func testConnectSendsConreqAndArmsT1() {
        var m = machine()
        let actions = m.handle(event: .connectRequest)
        XCTAssertEqual(m.state, .connecting)
        guard case let .connectRequest(myIndex, myId, window, u, n, t1)? = sentFrames(actions).first else {
            return XCTFail("expected CONREQ")
        }
        XCTAssertEqual(myIndex, 1); XCTAssertEqual(myId, 1)
        XCTAssertEqual(window, 4)
        XCTAssertEqual(u, user); XCTAssertEqual(n, node)
        XCTAssertEqual(t1, 120, "the kernel always advertises T1; so do we by default")
        XCTAssertTrue(actions.contains(.startT1))
    }

    func testConackEstablishesAndAdoptsHandleAndWindow() {
        var m = machine()
        _ = m.handle(event: .connectRequest)
        let actions = m.handle(event: .received(.connectAck(
            yourIndex: 1, yourId: 1, myIndex: 0x1A, myId: 0x2B,
            acceptedWindow: 3, ttl: nil, refused: false)))
        XCTAssertEqual(m.state, .connected)
        XCTAssertEqual(m.yourIndex, 0x1A)
        XCTAssertEqual(m.yourId, 0x2B)
        XCTAssertEqual(m.window, 3, "acceptor negotiated down; adopt it")
        XCTAssertTrue(actions.contains(.notifyConnected(window: 3)))
        XCTAssertTrue(actions.contains(.stopT1))
    }

    func testConackCannotInflateOurWindow() {
        var m = machine()  // proposes 4
        _ = m.handle(event: .connectRequest)
        _ = m.handle(event: .received(.connectAck(
            yourIndex: 1, yourId: 1, myIndex: 2, myId: 2,
            acceptedWindow: 200, ttl: nil, refused: false)))
        XCTAssertEqual(m.window, 4,
                       "a peer claiming a window above our proposal is clamped — kernel adopts blindly, we do not")
    }

    func testRefusalDisconnectsWithRefused() {
        var m = machine()
        _ = m.handle(event: .connectRequest)
        let actions = m.handle(event: .received(.connectAck(
            yourIndex: 1, yourId: 1, myIndex: 0, myId: 0,
            acceptedWindow: 0, ttl: nil, refused: true)))
        XCTAssertEqual(m.state, .disconnected)
        XCTAssertEqual(disconnectReason(actions), .refused)
    }

    func testConnectRetriesThenTimesOut() {
        var m = machine()  // maxRetries 3
        _ = m.handle(event: .connectRequest)
        for attempt in 1...3 {
            let actions = m.handle(event: .t1Timeout)
            XCTAssertEqual(sentFrames(actions).count, 1, "retry \(attempt) resends CONREQ")
            XCTAssertEqual(m.state, .connecting)
        }
        let final = m.handle(event: .t1Timeout)
        XCTAssertEqual(m.state, .disconnected)
        XCTAssertEqual(disconnectReason(final), .timedOut)
        XCTAssertTrue(sentFrames(final).isEmpty, "exhaustion sends nothing — mirrors nr_disconnect")
    }

    func testFramesForOtherStatesIgnoredWhileConnecting() {
        var m = machine()
        _ = m.handle(event: .connectRequest)
        for frame: NetRomL4Frame in [
            info(0), infoAck(0), .disconnectRequest(yourIndex: 1, yourId: 1),
            .disconnectAck(yourIndex: 1, yourId: 1)
        ] {
            XCTAssertTrue(m.handle(event: .received(frame)).isEmpty,
                          "state 1 ignores \(frame) (kernel default arm)")
            XCTAssertEqual(m.state, .connecting)
        }
    }

    // MARK: - Accept (responder)

    func testAcceptNegotiatesWindowDownAndConacks() {
        var m = machine { $0.window = 10 }
        let actions = m.handle(event: .acceptInbound(
            theirIndex: 9, theirId: 8, proposedWindow: 4, t1Seconds: nil, bpqExtension: false))
        XCTAssertEqual(m.state, .connected)
        XCTAssertEqual(m.window, 4, "min(theirs 4, ours 10)")
        guard case let .connectAck(yourIndex, yourId, myIndex, myId, window, ttl, refused)? = sentFrames(actions).first else {
            return XCTFail("expected CONACK")
        }
        XCTAssertEqual(yourIndex, 9); XCTAssertEqual(yourId, 8)
        XCTAssertEqual(myIndex, 1); XCTAssertEqual(myId, 1)
        XCTAssertEqual(window, 4)
        XCTAssertNil(ttl, "no BPQ TTL byte for a classic CONREQ")
        XCTAssertFalse(refused)
        XCTAssertTrue(actions.contains(.notifyConnected(window: 4)))
    }

    func testAcceptHonorsOurSmallerWindowAndPeerT1() {
        var m = machine { $0.window = 2; $0.t1 = 120 }
        _ = m.handle(event: .acceptInbound(
            theirIndex: 9, theirId: 8, proposedWindow: 60, t1Seconds: 30, bpqExtension: true))
        XCTAssertEqual(m.window, 2, "min(theirs 60, ours 2)")
        XCTAssertEqual(m.effectiveT1, 30, "peer's shorter T1 adopted (nr_rx_frame)")
    }

    func testAcceptWithZeroWindowProposalKeepsOurs() {
        var m = machine()
        _ = m.handle(event: .acceptInbound(
            theirIndex: 9, theirId: 8, proposedWindow: 0, t1Seconds: nil, bpqExtension: false))
        XCTAssertEqual(m.window, 4, "a zero window is nonsense; a zero window would stall forever")
    }

    func testBPQExtensionConackCarriesTTL() {
        var m = machine()
        let actions = m.handle(event: .acceptInbound(
            theirIndex: 9, theirId: 8, proposedWindow: 4, t1Seconds: 120, bpqExtension: true))
        guard case let .connectAck(_, _, _, _, _, ttl, _)? = sentFrames(actions).first else {
            return XCTFail("expected CONACK")
        }
        XCTAssertEqual(ttl, 25, "extended peers get the TTL byte (nr_write_internal bpqext)")
    }

    func testDuplicateConreqInConnectedResendsConack() {
        var m = machine()
        _ = m.handle(event: .acceptInbound(
            theirIndex: 9, theirId: 8, proposedWindow: 4, t1Seconds: nil, bpqExtension: false))
        let actions = m.handle(event: .received(.connectRequest(
            myIndex: 9, myId: 8, proposedWindow: 4, user: user, originNode: remote, t1Seconds: nil)))
        guard case .connectAck? = sentFrames(actions).first else {
            return XCTFail("a repeated CONREQ means our CONACK was lost; repeat it (nr_state3_machine)")
        }
        XCTAssertEqual(m.state, .connected)
    }

    // MARK: - Sending data

    func testSendWithinWindowEmitsInfosWithPiggybackNR() {
        var m = connected()
        let actions = m.handle(event: .sendData(Data("HELLO".utf8)))
        let infos = sentInfos(actions)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].txSeq, 0)
        XCTAssertEqual(infos[0].rxSeq, 0)
        XCTAssertFalse(infos[0].more)
        XCTAssertEqual(infos[0].payload, Data("HELLO".utf8))
        XCTAssertEqual(m.vs, 1)
        XCTAssertEqual(m.outstandingCount, 1)
        XCTAssertTrue(actions.contains(.startT1))
    }

    func testFragmentationBoundaries() {
        // 236 → 1 frame; 237 → 236+1; 473 → 236+236+1. MORE on all but last.
        var m = connected { $0.window = 10 }
        for (size, expectedCounts) in [(236, [236]), (237, [236, 1]), (473, [236, 236, 1])] {
            var fresh = connected { $0.window = 10 }
            let actions = fresh.handle(event: .sendData(Data(repeating: 0x42, count: size)))
            let infos = sentInfos(actions)
            XCTAssertEqual(infos.map { $0.payload.count }, expectedCounts, "size \(size)")
            XCTAssertEqual(infos.map { $0.more }, expectedCounts.enumerated().map { $0.offset < expectedCounts.count - 1 },
                           "MORE on all but the last fragment (nr_output)")
        }
        _ = m  // silence unused
    }

    func testWindowNeverExceeded() {
        var m = connected()  // window 4
        let actions = m.handle(event: .sendData(Data(repeating: 0x00, count: 236 * 7)))
        XCTAssertEqual(sentInfos(actions).count, 4, "window 4 caps the burst")
        XCTAssertEqual(m.outstandingCount, 4)
        XCTAssertEqual(m.writeQueue.count, 3, "the rest waits")
        // No further sends until acks arrive.
        let more = m.handle(event: .sendData(Data([0x01])))
        XCTAssertTrue(sentInfos(more).isEmpty)
    }

    func testAckFreesWindowAndResumesSending() {
        var m = connected()
        _ = m.handle(event: .sendData(Data(repeating: 0x00, count: 236 * 6)))
        let actions = m.handle(event: .received(infoAck(2)))
        XCTAssertEqual(m.va, 2)
        let infos = sentInfos(actions)
        XCTAssertEqual(infos.map { $0.txSeq }, [4, 5], "two slots freed, two queued frames go")
    }

    func testFullAckStopsT1AndResetsRetries() {
        var m = connected()
        _ = m.handle(event: .sendData(Data("X".utf8)))
        _ = m.handle(event: .t1Timeout)  // one retry, retryCount = 1
        XCTAssertEqual(m.retryCount, 1)
        let actions = m.handle(event: .received(infoAck(1)))
        XCTAssertEqual(m.va, 1)
        XCTAssertEqual(m.retryCount, 0, "nr_check_iframes_acked resets n2count on full ack")
        XCTAssertTrue(actions.contains(.stopT1))
    }

    func testPartialAckRestartsT1() {
        var m = connected()
        _ = m.handle(event: .sendData(Data(repeating: 0x00, count: 236 * 2)))
        let actions = m.handle(event: .received(infoAck(1)))
        XCTAssertEqual(m.va, 1)
        XCTAssertTrue(actions.contains(.startT1), "partial ack restarts T1 (nr_check_iframes_acked)")
    }

    func testInvalidAckOutsideVaVsIgnored() {
        var m = connected()
        _ = m.handle(event: .sendData(Data("X".utf8)))  // vs=1, va=0
        _ = m.handle(event: .received(infoAck(7)))
        XCTAssertEqual(m.va, 0, "N(R) outside [va, vs] is ignored (nr_validate_nr)")
        _ = m.handle(event: .received(infoAck(255)))
        XCTAssertEqual(m.va, 0)
    }

    // MARK: - Retransmission

    func testT1RetransmitsAllOutstandingGoBackN() {
        var m = connected()
        _ = m.handle(event: .sendData(Data(repeating: 0x00, count: 236 * 3)))
        let actions = m.handle(event: .t1Timeout)
        let infos = sentInfos(actions)
        XCTAssertEqual(infos.map { $0.txSeq }, [0, 1, 2], "go-back-N from va (nr_requeue_frames + nr_kick)")
        XCTAssertEqual(m.retryCount, 1)
    }

    func testRetriesExhaustTearsDown() {
        var m = connected()
        _ = m.handle(event: .sendData(Data("X".utf8)))
        for _ in 1...3 { _ = m.handle(event: .t1Timeout) }
        let final = m.handle(event: .t1Timeout)
        XCTAssertEqual(m.state, .disconnected)
        XCTAssertEqual(disconnectReason(final), .timedOut)
    }

    func testIdleT1DoesNotCountTowardRetries() {
        // DEVIATION 2: a stray T1 with nothing outstanding must not
        // accumulate toward tearing down a healthy circuit.
        var m = connected()
        for _ in 0..<10 {
            XCTAssertTrue(m.handle(event: .t1Timeout).isEmpty)
        }
        XCTAssertEqual(m.state, .connected)
        XCTAssertEqual(m.retryCount, 0)
    }

    func testPeerNakResendsOldestOutstandingOnly() {
        var m = connected()
        _ = m.handle(event: .sendData(Data(repeating: 0x00, count: 236 * 3)))
        let actions = m.handle(event: .received(infoAck(1, nak: true)))
        XCTAssertEqual(m.va, 1, "NAK's rxSeq still acks below it")
        let infos = sentInfos(actions)
        XCTAssertEqual(infos.count, 1, "exactly the oldest unacked frame is resent (nr_send_nak_frame)")
        XCTAssertEqual(infos[0].txSeq, 1)
        // DEVIATION 1: T1 keeps running so a lost resend still retries.
        XCTAssertTrue(actions.contains(.startT1))
    }

    // MARK: - Choke (peer busy)

    func testChokeStopsTransmissionAndArmsT4() {
        var m = connected()
        _ = m.handle(event: .sendData(Data(repeating: 0x00, count: 236 * 6)))
        let actions = m.handle(event: .received(infoAck(4, choke: true)))
        XCTAssertTrue(m.peerBusy)
        XCTAssertTrue(actions.contains(.startT4))
        XCTAssertTrue(sentInfos(actions).isEmpty, "choked: acked slots do NOT refill (nr_kick returns early)")
    }

    func testChokeClearResumes() {
        var m = connected()
        _ = m.handle(event: .sendData(Data(repeating: 0x00, count: 236 * 6)))
        _ = m.handle(event: .received(infoAck(4, choke: true)))
        let actions = m.handle(event: .received(infoAck(4, choke: false)))
        XCTAssertFalse(m.peerBusy)
        XCTAssertTrue(actions.contains(.stopT4))
        XCTAssertFalse(sentInfos(actions).isEmpty, "un-choked: queued frames flow again")
    }

    func testT4ExpiryClearsBusyAndResumes() {
        var m = connected()
        _ = m.handle(event: .sendData(Data(repeating: 0x00, count: 236 * 6)))
        _ = m.handle(event: .received(infoAck(4, choke: true)))
        let actions = m.handle(event: .t4Timeout)
        XCTAssertFalse(m.peerBusy, "T4 expiry clears peer-busy (nr_t4timer_expiry)")
        XCTAssertFalse(sentInfos(actions).isEmpty)
    }

    // MARK: - Receiving data

    func testInSequenceDeliveryAdvancesVrAndArmsT2() {
        var m = connected()
        let actions = m.handle(event: .received(info(0, payload: Data("HI".utf8))))
        XCTAssertEqual(delivered(actions), [Data("HI".utf8)])
        XCTAssertEqual(m.vr, 1)
        XCTAssertTrue(actions.contains(.startT2), "ack rides T2, not every frame (NR_COND_ACK_PENDING)")
        XCTAssertTrue(sentAcks(actions).isEmpty)
    }

    func testT2FiresTheDelayedAck() {
        var m = connected()
        _ = m.handle(event: .received(info(0)))
        let actions = m.handle(event: .t2Timeout)
        let acks = sentAcks(actions)
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks[0].rxSeq, 1)
        XCTAssertFalse(acks[0].nak)
        // A second T2 with nothing pending is a no-op.
        XCTAssertTrue(m.handle(event: .t2Timeout).isEmpty)
    }

    func testWindowFullAcksImmediately() {
        var m = connected()  // window 4
        var lastActions: [NetRomCircuitAction] = []
        for ns in 0..<4 { lastActions = m.handle(event: .received(info(ns))) }
        let acks = sentAcks(lastActions)
        XCTAssertEqual(acks.count, 1, "receive window full → immediate INFOACK (nr_state3_machine)")
        XCTAssertEqual(acks[0].rxSeq, 4)
    }

    func testOutOfOrderIsBufferedThenDrainedInOrder() {
        var m = connected()
        let first = m.handle(event: .received(info(1, payload: Data("B".utf8))))
        XCTAssertTrue(delivered(first).isEmpty, "ns=1 with vr=0 waits in the resequence buffer")
        XCTAssertEqual(m.vr, 0)
        let second = m.handle(event: .received(info(0, payload: Data("A".utf8))))
        XCTAssertEqual(delivered(second), [Data("A".utf8), Data("B".utf8)],
                       "the gap heals and the whole run delivers in order")
        XCTAssertEqual(m.vr, 2)
    }

    func testGapTriggersNakOnEnquiry() {
        var m = connected()
        _ = m.handle(event: .received(info(2)))
        let actions = m.handle(event: .t2Timeout)
        let acks = sentAcks(actions)
        XCTAssertEqual(acks.count, 1)
        XCTAssertTrue(acks[0].nak, "holding out-of-order frames → NAK (nr_enquiry_response)")
        XCTAssertEqual(acks[0].rxSeq, 0, "asking for the gap at vr")
    }

    func testStaleDuplicateStillGetsAcked() {
        // If our INFOACK was lost the peer retransmits an old frame; a
        // silent drop would stall it until its N2 exhausts.
        var m = connected()
        _ = m.handle(event: .received(info(0, payload: Data("A".utf8))))
        _ = m.handle(event: .t2Timeout)  // acked, vl = vr = 1
        let dupActions = m.handle(event: .received(info(0, payload: Data("A".utf8))))
        XCTAssertTrue(delivered(dupActions).isEmpty, "duplicate is not re-delivered")
        XCTAssertEqual(m.vr, 1)
        let t2 = m.handle(event: .t2Timeout)
        XCTAssertEqual(sentAcks(t2).map { $0.rxSeq }, [1], "but it is re-acked")
    }

    func testFrameOutsideReceiveWindowIsDiscarded() {
        var m = connected()  // window 4, vr=0, vl=0
        let actions = m.handle(event: .received(info(9, payload: Data("X".utf8))))
        XCTAssertTrue(delivered(actions).isEmpty)
        XCTAssertTrue(m.resequenceBuffer.isEmpty, "ns=9 outside [vr, vl+window) is dropped (nr_in_rx_window)")
    }

    func testPiggybackAckOnInfoProcessed() {
        var m = connected()
        _ = m.handle(event: .sendData(Data("PING".utf8)))  // vs=1
        let actions = m.handle(event: .received(info(0, rxSeq: 1, payload: Data("PONG".utf8))))
        XCTAssertEqual(m.va, 1, "INFO's rxSeq acks our frame")
        XCTAssertEqual(delivered(actions), [Data("PONG".utf8)])
        XCTAssertTrue(actions.contains(.stopT1))
    }

    func testOutgoingInfoPiggybacksTheOwedAck() {
        var m = connected()
        _ = m.handle(event: .received(info(0)))  // ackPending armed
        XCTAssertTrue(m.ackPending)
        let actions = m.handle(event: .sendData(Data("REPLY".utf8)))
        let infos = sentInfos(actions)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].rxSeq, 1, "N(R) rides the outgoing INFO")
        XCTAssertFalse(m.ackPending, "which satisfies the pending ack (nr_kick: vl = vr)")
        XCTAssertTrue(actions.contains(.stopT2))
    }

    // MARK: - Reassembly (MORE flag)

    func testMoreChainReassemblesIntoOneDelivery() {
        var m = connected()
        _ = m.handle(event: .received(info(0, more: true, payload: Data("FRAG1-".utf8))))
        _ = m.handle(event: .received(info(1, more: true, payload: Data("FRAG2-".utf8))))
        let final = m.handle(event: .received(info(2, more: false, payload: Data("END".utf8))))
        XCTAssertEqual(delivered(final), [Data("FRAG1-FRAG2-END".utf8)])
        XCTAssertTrue(m.reassembly.isEmpty)
    }

    func testMoreChainFragmentsDeliverNothingUntilComplete() {
        var m = connected()
        let a = m.handle(event: .received(info(0, more: true)))
        XCTAssertTrue(delivered(a).isEmpty)
        XCTAssertEqual(m.vr, 1, "fragments still advance and get acked")
    }

    func testReassemblyOverflowFailsTheCircuit() {
        // DEVIATION 3: the kernel chokes forever; we fail loudly.
        var m = connected { $0.maxReassemblyBytes = 300; $0.window = 10 }
        _ = m.handle(event: .received(info(0, more: true, payload: Data(repeating: 0, count: 236))))
        let actions = m.handle(event: .received(info(1, more: true, payload: Data(repeating: 0, count: 236))))
        XCTAssertEqual(m.state, .disconnected)
        guard case .protocolError? = disconnectReason(actions) else {
            return XCTFail("overflow must surface as a protocol error, got \(String(describing: disconnectReason(actions)))")
        }
    }

    func testInterleavedRoundTripFragmentation() {
        // What one machine fragments, its twin reassembles.
        var sender = connected { $0.window = 10 }
        var receiver = connected { $0.window = 10 }
        let payload = Data((0..<600).map { UInt8($0 % 251) })
        let sendActions = sender.handle(event: .sendData(payload))
        var received: [Data] = []
        for frame in sentFrames(sendActions) {
            // Re-key the frame for the receiver's handle (test twins share 1/1).
            let actions = receiver.handle(event: .received(frame))
            received += delivered(actions)
        }
        XCTAssertEqual(received, [payload])
    }

    // MARK: - Sequence wraparound

    func testSequenceNumbersWrapAt256OnBothSides() {
        var sender = connected { $0.window = 1 }
        var receiver = connected { $0.window = 1 }
        for i in 0..<300 {
            let payload = Data([UInt8(i % 256)])
            let out = sender.handle(event: .sendData(payload))
            let infos = sentInfos(out)
            XCTAssertEqual(infos.count, 1, "iteration \(i)")
            XCTAssertEqual(Int(infos[0].txSeq), i % 256, "tx seq wraps mod 256")
            let inActions = receiver.handle(event: .received(sentFrames(out)[0]))
            XCTAssertEqual(delivered(inActions), [payload], "iteration \(i) delivers")
            // With window 1 the receive window fills instantly, so the ack
            // rides the receive actions; harvest T2 too for completeness.
            let ackActions = receiver.handle(event: .t2Timeout)
            for frame in sentFrames(inActions) + sentFrames(ackActions) {
                if case .informationAck = frame {
                    _ = sender.handle(event: .received(frame))
                }
            }
            XCTAssertEqual(sender.outstandingCount, 0, "iteration \(i) acked")
        }
        XCTAssertEqual(sender.vs, 300 % 256)
    }

    // MARK: - Local busy (our choke)

    func testLocalBusyBuffersAndChokesOnAck() {
        var m = connected()
        _ = m.handle(event: .localBusy(true))
        let during = m.handle(event: .received(info(0, payload: Data("HELD".utf8))))
        XCTAssertTrue(delivered(during).isEmpty, "busy: arrivals wait (kernel breaks before drain)")
        XCTAssertEqual(m.vr, 0)
        let after = m.handle(event: .localBusy(false))
        XCTAssertEqual(delivered(after), [Data("HELD".utf8)], "un-busy drains the backlog")
        let acks = sentAcks(after)
        XCTAssertEqual(acks.count, 1)
        XCTAssertFalse(acks[0].choke, "and tells the peer we are open")
    }

    func testOutgoingInfoCarriesChokeWhileBusy() {
        var m = connected()
        _ = m.handle(event: .localBusy(true))
        let actions = m.handle(event: .sendData(Data("X".utf8)))
        guard case let .information(_, _, _, _, choke, _, _, _)? = sentFrames(actions).first else {
            return XCTFail("expected INFO")
        }
        XCTAssertTrue(choke, "own-busy piggybacks on outgoing INFO (nr_send_iframe)")
    }

    // MARK: - Disconnect

    func testLocalDisconnectHandshake() {
        var m = connected()
        let request = m.handle(event: .disconnectRequest)
        XCTAssertEqual(m.state, .disconnecting)
        guard case .disconnectRequest? = sentFrames(request).first else {
            return XCTFail("expected DISCREQ")
        }
        XCTAssertTrue(request.contains(.startT1))
        let done = m.handle(event: .received(.disconnectAck(yourIndex: 1, yourId: 1)))
        XCTAssertEqual(m.state, .disconnected)
        XCTAssertEqual(disconnectReason(done), .localRequest)
    }

    func testDisconnectRetriesThenTimesOut() {
        var m = connected()
        _ = m.handle(event: .disconnectRequest)
        for _ in 1...3 {
            let actions = m.handle(event: .t1Timeout)
            XCTAssertEqual(sentFrames(actions).count, 1)
        }
        let final = m.handle(event: .t1Timeout)
        XCTAssertEqual(disconnectReason(final), .timedOut)
    }

    func testRemoteDisconnectAcksAndNotifies() {
        var m = connected()
        let actions = m.handle(event: .received(.disconnectRequest(yourIndex: 1, yourId: 1)))
        guard case .disconnectAck? = sentFrames(actions).first else {
            return XCTFail("DISCREQ must be answered with DISCACK")
        }
        XCTAssertEqual(m.state, .disconnected)
        XCTAssertEqual(disconnectReason(actions), .remoteRequest)
    }

    func testCrossingDisconnectsBothResolve() {
        // Both ends DISCREQ simultaneously: each answers with DISCACK
        // and goes down (nr_state2_machine DISCREQ arm).
        var m = connected()
        _ = m.handle(event: .disconnectRequest)
        let actions = m.handle(event: .received(.disconnectRequest(yourIndex: 1, yourId: 1)))
        guard case .disconnectAck? = sentFrames(actions).first else {
            return XCTFail("crossing DISCREQ still gets DISCACK")
        }
        XCTAssertEqual(m.state, .disconnected)
    }

    func testUnexpectedDiscackInConnectedResets() {
        var m = connected()
        let actions = m.handle(event: .received(.disconnectAck(yourIndex: 1, yourId: 1)))
        XCTAssertEqual(m.state, .disconnected)
        XCTAssertEqual(disconnectReason(actions), .reset)
    }

    func testRefusedConackInConnectedResets() {
        var m = connected()
        let actions = m.handle(event: .received(.connectAck(
            yourIndex: 1, yourId: 1, myIndex: 0, myId: 0,
            acceptedWindow: 0, ttl: nil, refused: true)))
        XCTAssertEqual(disconnectReason(actions), .reset)
    }

    func testStaleDuplicateConackIgnoredInConnected() {
        var m = connected()
        XCTAssertTrue(m.handle(event: .received(.connectAck(
            yourIndex: 1, yourId: 1, myIndex: 0x1A, myId: 0x2B,
            acceptedWindow: 4, ttl: nil, refused: false))).isEmpty)
        XCTAssertEqual(m.state, .connected)
    }

    // MARK: - Reset opcode

    func testResetIgnoredByDefault() {
        var m = connected()
        XCTAssertTrue(m.handle(event: .received(.reset(yourIndex: 1, yourId: 1))).isEmpty)
        XCTAssertEqual(m.state, .connected, "NR_DEFAULT_RESET = 0: resets are not honored")
    }

    func testResetHonoredWhenConfigured() {
        var m = connected { $0.acceptResets = true }
        let actions = m.handle(event: .received(.reset(yourIndex: 1, yourId: 1)))
        XCTAssertEqual(m.state, .disconnected)
        XCTAssertEqual(disconnectReason(actions), .reset)
    }

    // MARK: - Queued data across connect

    func testDataQueuedWhileConnectingFlushesOnConnect() {
        var m = machine()
        _ = m.handle(event: .connectRequest)
        XCTAssertTrue(sentInfos(m.handle(event: .sendData(Data("EARLY".utf8)))).isEmpty)
        let actions = m.handle(event: .received(.connectAck(
            yourIndex: 1, yourId: 1, myIndex: 2, myId: 2,
            acceptedWindow: 4, ttl: nil, refused: false)))
        let infos = sentInfos(actions)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].payload, Data("EARLY".utf8))
    }

    func testSendWhileDisconnectedIsIgnored() {
        var m = machine()
        XCTAssertTrue(m.handle(event: .sendData(Data("VOID".utf8))).isEmpty)
        XCTAssertTrue(m.writeQueue.isEmpty)
    }

    // MARK: - Transport failure

    func testTransportFailureTearsDown() {
        var m = connected()
        let actions = m.handle(event: .transportFailure("no route"))
        XCTAssertEqual(m.state, .disconnected)
        XCTAssertEqual(disconnectReason(actions), .transportFailure("no route"))
    }
}
