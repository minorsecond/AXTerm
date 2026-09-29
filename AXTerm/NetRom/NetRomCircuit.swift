//
//  NetRomCircuit.swift
//  AXTerm
//
//  NET/ROM Level 4 circuit state machine.
//
//  Shape mirrors AX25SessionStateMachine: a nonisolated value type that
//  consumes events and returns actions; the owner (NetRomEndpoint) runs
//  timers and I/O. Behavior is transcribed from the Linux AF_NETROM
//  state machines (net/netrom/nr_in.c, nr_out.c, nr_subr.c, v6.6),
//  themselves taken from the ARRL 7th CNC NET/ROM paper. Three deliberate
//  deviations, each marked DEVIATION inline:
//
//   1. After answering a peer NAK with a retransmission, T1 is restarted
//      rather than stopped. The kernel stops it, which can stall the
//      circuit if that single retransmission is lost.
//   2. A T1 expiry with nothing outstanding and nothing queued stops T1
//      instead of counting toward N2. The kernel counts it, which can
//      tear down a healthy idle circuit if T1 was ever left running.
//   3. Reassembly (MORE-flag chains) is capped; exceeding the cap fails
//      the circuit with a protocol error. The kernel chokes instead,
//      which stalls the circuit forever with no operator-visible cause.
//
//  Everything else — window math, ack validation, resequencing, delayed
//  acks, choke, retry counting, refusal shapes — follows the reference.
//

import Foundation

// MARK: - State

nonisolated enum NetRomCircuitState: String, Equatable, Sendable {
    case disconnected   // NR_STATE_0
    case connecting     // NR_STATE_1: CONREQ sent, awaiting CONACK
    case disconnecting  // NR_STATE_2: DISCREQ sent, awaiting DISCACK
    case connected      // NR_STATE_3
}

nonisolated enum NetRomDisconnectReason: Equatable, Sendable {
    case localRequest
    case remoteRequest
    case refused          // CONACK with choke while connecting
    case reset            // DISCACK / refused-CONACK out of the blue, or opcode-7
    case timedOut         // N2 retries exhausted
    case transportFailure(String)  // endpoint could not route a frame
    case protocolError(String)
}

// MARK: - Configuration

nonisolated struct NetRomCircuitConfig: Sendable {
    /// Window we propose / cap at (NR_DEFAULT_WINDOW = 4; max 127).
    var window: Int = 4
    /// Retransmission timer, seconds (NR_DEFAULT_T1 = 120).
    var t1: Double = 120
    /// Delayed-ack timer, seconds (NR_DEFAULT_T2 = 5).
    var t2: Double = 5
    /// Peer-busy (choke) recovery timer, seconds (NR_DEFAULT_T4 = 180).
    var t4: Double = 180
    /// Retry limit N2 (NR_DEFAULT_N2 = 3).
    var maxRetries: Int = 3
    /// Largest INFO payload per frame (NR_MAX_PACKET_SIZE = 236).
    var maxInfoPayload: Int = NetRomWire.maxInfoPayload
    /// Cap on one MORE-flag reassembly chain. DEVIATION 3 above.
    var maxReassemblyBytes: Int = 65536
    /// Emit the two-byte T1 field in CONREQ (BPQ extension; the kernel
    /// always does, BPQ negotiates it down).
    var advertiseT1: Bool = true
    /// Honor Xrouter opcode-7 resets (NR_DEFAULT_RESET = 0: no).
    var acceptResets: Bool = false
    /// TTL for the CONACK BPQ-extension byte (and the endpoint's
    /// datagrams). BPQ networks commonly run 25.
    var ttl: UInt8 = 25

    var clampedWindow: Int { min(max(window, 1), NetRomWire.maxWindow) }

    init() {}
}

// MARK: - Events

nonisolated enum NetRomCircuitEvent: Sendable {
    /// Open the circuit (initiator). Endpoint has already assigned
    /// myIndex/myId and set the identity fields.
    case connectRequest
    /// Accept an inbound CONREQ (responder). Endpoint matched/created the
    /// circuit and assigned myIndex/myId; the frame's fields ride along.
    case acceptInbound(theirIndex: UInt8, theirId: UInt8, proposedWindow: UInt8, t1Seconds: UInt16?, bpqExtension: Bool)
    case disconnectRequest
    case sendData(Data)
    /// A transport frame this circuit owns (endpoint did the matching).
    case received(NetRomL4Frame)
    case t1Timeout
    case t2Timeout
    case t4Timeout
    /// App-level receive backpressure (drives our choke flag).
    case localBusy(Bool)
    /// The endpoint could not transmit for this circuit (no route).
    case transportFailure(String)
}

// MARK: - Actions

nonisolated enum NetRomCircuitAction: Equatable, Sendable {
    case send(NetRomL4Frame)
    case startT1
    case stopT1
    case startT2
    case stopT2
    case startT4
    case stopT4
    case deliverData(Data)
    case notifyConnected(window: Int)
    case notifyDisconnected(NetRomDisconnectReason)
}

// MARK: - State machine

nonisolated struct NetRomCircuitStateMachine: Sendable {

    // Identity (set by the endpoint before the first event)
    let config: NetRomCircuitConfig
    /// Connecting user's callsign (rides in CONREQ).
    let localUser: AX25Address
    /// This station's node callsign (CONREQ origin-node field).
    let localNode: AX25Address
    /// The far endpoint's node callsign.
    let remoteNode: AX25Address
    /// Our circuit handle, assigned by the endpoint. Both nonzero.
    let myIndex: UInt8
    let myId: UInt8

    // Learned identity
    private(set) var yourIndex: UInt8 = 0
    private(set) var yourId: UInt8 = 0
    private(set) var isInitiator = false
    /// Peer detected as speaking the BPQ extension (adds TTL byte to CONACK).
    private(set) var peerSpeaksExtension = false

    // Link state
    private(set) var state: NetRomCircuitState = .disconnected
    /// Negotiated window (valid once connected).
    private(set) var window: Int
    /// Effective T1 after negotiation (responder may shorten to peer's).
    private(set) var effectiveT1: Double

    // Sequence variables, all modulo 256
    private(set) var vs = 0   // next tx seq
    private(set) var va = 0   // oldest unacked
    private(set) var vr = 0   // next expected rx seq
    private(set) var vl = 0   // vr as of the last ack we sent

    // Conditions
    private(set) var ackPending = false      // NR_COND_ACK_PENDING
    private(set) var peerBusy = false        // NR_COND_PEER_RX_BUSY
    private(set) var localBusy = false       // NR_COND_OWN_RX_BUSY
    private(set) var retryCount = 0          // n2count

    // Buffers
    /// Fragments not yet transmitted, in order.
    private(set) var writeQueue: [(payload: Data, moreFollows: Bool)] = []
    /// Transmitted, unacknowledged; index 0 has seq va, contiguous.
    private(set) var ackQueue: [(payload: Data, moreFollows: Bool)] = []
    /// Out-of-sequence arrivals awaiting their gap, keyed by tx seq.
    private(set) var resequenceBuffer: [Int: (payload: Data, moreFollows: Bool)] = [:]
    /// Accumulates a MORE-flag chain until the final fragment.
    private(set) var reassembly = Data()

    // Timer bookkeeping (so the machine can arm idempotently, the way
    // the kernel checks nr_t1timer_running before starting it)
    private(set) var t1Running = false
    private(set) var t2Running = false
    private(set) var t4Running = false

    init(
        config: NetRomCircuitConfig,
        localUser: AX25Address,
        localNode: AX25Address,
        remoteNode: AX25Address,
        myIndex: UInt8,
        myId: UInt8
    ) {
        self.config = config
        self.localUser = localUser
        self.localNode = localNode
        self.remoteNode = remoteNode
        self.myIndex = myIndex
        self.myId = myId
        self.window = config.clampedWindow
        self.effectiveT1 = config.t1
    }

    // MARK: Modular arithmetic

    private func mod(_ x: Int) -> Int {
        ((x % NetRomWire.modulus) + NetRomWire.modulus) % NetRomWire.modulus
    }

    /// nr_validate_nr: is r within [va, vs] (inclusive, circular)?
    func isValidAck(_ r: Int) -> Bool {
        let span = mod(vs - va)
        let dist = mod(r - va)
        return dist <= span
    }

    /// nr_in_rx_window: is ns within [vr, vl + window)?
    func isInReceiveWindow(_ ns: Int) -> Bool {
        let vt = mod(vl + window)
        let span = mod(vt - vr)
        let dist = mod(ns - vr)
        return dist < span
    }

    var outstandingCount: Int { ackQueue.count }

    // MARK: Event entry

    mutating func handle(event: NetRomCircuitEvent) -> [NetRomCircuitAction] {
        switch event {
        case .connectRequest:
            return handleConnectRequest()
        case let .acceptInbound(theirIndex, theirId, proposedWindow, t1Seconds, bpqExtension):
            return handleAcceptInbound(
                theirIndex: theirIndex, theirId: theirId,
                proposedWindow: proposedWindow, t1Seconds: t1Seconds,
                bpqExtension: bpqExtension
            )
        case .disconnectRequest:
            return handleLocalDisconnect()
        case .sendData(let data):
            return handleSendData(data)
        case .received(let frame):
            return handleReceived(frame)
        case .t1Timeout:
            t1Running = false
            return handleT1Timeout()
        case .t2Timeout:
            t2Running = false
            return handleT2Timeout()
        case .t4Timeout:
            t4Running = false
            return handleT4Timeout()
        case .localBusy(let busy):
            return handleLocalBusy(busy)
        case .transportFailure(let reason):
            guard state != .disconnected else { return [] }
            return die(.transportFailure(reason))
        }
    }

    // MARK: Connect / accept

    private mutating func handleConnectRequest() -> [NetRomCircuitAction] {
        guard state == .disconnected else { return [] }
        isInitiator = true
        resetSequenceState()
        retryCount = 0
        state = .connecting
        var actions: [NetRomCircuitAction] = [.send(buildConnectRequest())]
        actions += armT1()
        return actions
    }

    private mutating func handleAcceptInbound(
        theirIndex: UInt8, theirId: UInt8,
        proposedWindow: UInt8, t1Seconds: UInt16?,
        bpqExtension: Bool
    ) -> [NetRomCircuitAction] {
        guard state == .disconnected else { return [] }
        isInitiator = false
        yourIndex = theirIndex
        yourId = theirId
        peerSpeaksExtension = bpqExtension
        resetSequenceState()
        retryCount = 0

        // Window negotiation (nr_rx_frame): adopt the smaller of the
        // proposal and ours; a zero proposal is nonsense, keep ours.
        if proposedWindow > 0 {
            window = min(Int(proposedWindow), config.clampedWindow)
        } else {
            window = config.clampedWindow
        }
        // T1 negotiation: shorten to the peer's if it advertised one.
        if let t1 = t1Seconds, t1 > 0, Double(t1) < config.t1 {
            effectiveT1 = Double(t1)
        }

        state = .connected
        return [.send(buildConnectAck()), .notifyConnected(window: window)]
    }

    // MARK: Local disconnect

    private mutating func handleLocalDisconnect() -> [NetRomCircuitAction] {
        switch state {
        case .disconnected, .disconnecting:
            return []
        case .connecting:
            // Nothing established yet; go quietly (kernel nr_disconnect
            // path for an unaccepted socket sends DISCREQ only from
            // state 3; from state 1 the release sends nothing useful).
            var actions = clearAllTimers()
            state = .disconnected
            purgeBuffers()
            actions.append(.notifyDisconnected(.localRequest))
            return actions
        case .connected:
            purgeBuffers()
            retryCount = 0
            state = .disconnecting
            var actions: [NetRomCircuitAction] = []
            actions += disarmT2()
            actions += disarmT4()
            actions.append(.send(.disconnectRequest(yourIndex: yourIndex, yourId: yourId)))
            actions += rearmT1()
            return actions
        }
    }

    // MARK: Send data

    private mutating func handleSendData(_ data: Data) -> [NetRomCircuitAction] {
        guard state == .connected || state == .connecting else { return [] }
        guard !data.isEmpty else { return [] }
        // nr_output: fragment at maxInfoPayload, MORE on all but the last.
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: config.maxInfoPayload, limitedBy: data.endIndex) ?? data.endIndex
            let chunk = Data(data[offset..<end])
            let more = end < data.endIndex
            writeQueue.append((payload: chunk, moreFollows: more))
            offset = end
        }
        guard state == .connected else { return [] }  // flushes on connect
        return kick()
    }

    // MARK: Received frames

    private mutating func handleReceived(_ frame: NetRomL4Frame) -> [NetRomCircuitAction] {
        // Opcode-7 reset: honored only when configured (NR_DEFAULT_RESET=0).
        if case .reset = frame {
            guard config.acceptResets, state != .disconnected else { return [] }
            return die(.reset)
        }

        switch state {
        case .disconnected:
            return []
        case .connecting:
            return connectingReceived(frame)
        case .disconnecting:
            return disconnectingReceived(frame)
        case .connected:
            return connectedReceived(frame)
        }
    }

    /// nr_state1_machine
    private mutating func connectingReceived(_ frame: NetRomL4Frame) -> [NetRomCircuitAction] {
        switch frame {
        case let .connectAck(_, _, myIndex: theirIndex, myId: theirId, acceptedWindow, _, refused):
            if refused {
                return die(.refused)
            }
            yourIndex = theirIndex
            yourId = theirId
            resetSequenceState()
            retryCount = 0
            // Kernel adopts the returned window wholesale; we clamp it to
            // what we proposed (never larger) and to a sane floor.
            if let w = acceptedWindow, w > 0 {
                window = min(Int(w), config.clampedWindow)
            }
            state = .connected
            var actions = disarmT1()
            actions.append(.notifyConnected(window: window))
            actions += kick()  // flush anything queued while connecting
            return actions
        default:
            return []
        }
    }

    /// nr_state2_machine
    private mutating func disconnectingReceived(_ frame: NetRomL4Frame) -> [NetRomCircuitAction] {
        switch frame {
        case .connectAck(_, _, _, _, _, _, refused: true):
            return die(.reset)
        case .disconnectRequest:
            return [.send(.disconnectAck(yourIndex: yourIndex, yourId: yourId))] + die(.localRequest)
        case .disconnectAck:
            return die(.localRequest)
        default:
            return []
        }
    }

    /// nr_state3_machine
    private mutating func connectedReceived(_ frame: NetRomL4Frame) -> [NetRomCircuitAction] {
        switch frame {
        case .connectRequest:
            // Peer's CONACK to us was lost; it repeats the CONREQ.
            return [.send(buildConnectAck())]

        case .disconnectRequest:
            let ack: NetRomCircuitAction = .send(.disconnectAck(yourIndex: yourIndex, yourId: yourId))
            return [ack] + die(.remoteRequest)

        case .connectAck(_, _, _, _, _, _, refused: true):
            return die(.reset)

        case .disconnectAck:
            // kernel state3: DISCACK out of nowhere means the far end
            // already tore the circuit down — treat as a reset.
            return die(.reset)

        case .connectAck:
            return []  // stale duplicate of the accept; ignore

        case let .informationAck(_, _, rxSeq, choke, nak):
            return processAck(r: Int(rxSeq), choke: choke, nak: nak) + kick()

        case let .information(_, _, txSeq, rxSeq, choke, nak, moreFollows, payload):
            var actions = processAck(r: Int(rxSeq), choke: choke, nak: nak)
            actions += processInformation(ns: Int(txSeq), moreFollows: moreFollows, payload: payload)
            actions += kick()
            return actions

        default:
            return []
        }
    }

    /// The INFOACK/piggyback ack path of nr_state3_machine.
    private mutating func processAck(r: Int, choke: Bool, nak: Bool) -> [NetRomCircuitAction] {
        var actions: [NetRomCircuitAction] = []
        if choke {
            peerBusy = true
            actions += rearmT4()
        } else {
            peerBusy = false
            actions += disarmT4()
        }
        guard isValidAck(r) else { return actions }

        if nak {
            framesAcked(r)
            actions += resendOldestOutstanding()
        } else if peerBusy {
            framesAcked(r)
        } else {
            // nr_check_iframes_acked
            if r == vs {
                framesAcked(r)
                actions += disarmT1()
                retryCount = 0
            } else if r != va {
                framesAcked(r)
                actions += rearmT1()
            }
        }
        return actions
    }

    /// nr_send_nak_frame: retransmit exactly the oldest outstanding frame.
    private mutating func resendOldestOutstanding() -> [NetRomCircuitAction] {
        guard let oldest = ackQueue.first else { return [] }
        var actions: [NetRomCircuitAction] = [.send(.information(
            yourIndex: yourIndex, yourId: yourId,
            txSeq: UInt8(va), rxSeq: UInt8(vr),
            choke: localBusy, nak: false, moreFollows: oldest.moreFollows,
            payload: oldest.payload
        ))]
        vl = vr
        if ackPending {
            ackPending = false
            actions += disarmT2()
        }
        // DEVIATION 1: the kernel stops T1 here; if this lone
        // retransmission is lost, nothing retries. Keep T1 running.
        actions += rearmT1()
        return actions
    }

    /// The INFO resequencing path of nr_state3_machine.
    private mutating func processInformation(ns: Int, moreFollows: Bool, payload: Data) -> [NetRomCircuitAction] {
        var actions: [NetRomCircuitAction] = []

        // Stash the arrival (kernel queues the skb into reseq_queue
        // unconditionally, then the drain loop keeps only what is in
        // window and discards the rest).
        if ns == vr || isInReceiveWindow(ns) {
            // Last write wins for a duplicate seq — payload is identical
            // on a compliant peer.
            resequenceBuffer[ns] = (payload: payload, moreFollows: moreFollows)
        }

        if localBusy {
            // Kernel breaks out before draining or scheduling acks.
            return actions
        }

        // Drain every in-order run now available.
        while let next = resequenceBuffer.removeValue(forKey: vr) {
            switch deliver(payload: next.payload, moreFollows: next.moreFollows) {
            case .delivered(let out):
                if let out { actions.append(.deliverData(out)) }
                vr = mod(vr + 1)
            case .overflow:
                return actions + die(.protocolError(
                    "MORE-flag reassembly exceeded \(config.maxReassemblyBytes) bytes"))
            }
        }
        // Discard anything that fell out of the window as vr advanced
        // (the kernel's drain loop frees these).
        resequenceBuffer = resequenceBuffer.filter { isInReceiveWindow($0.key) }

        // Ack scheduling: window full → immediately; else delayed via T2.
        if mod(vl + window) == vr {
            actions += enquiryResponse()
        } else if !ackPending {
            ackPending = true
            actions += rearmT2()
        }
        return actions
    }

    private enum DeliveryOutcome {
        case delivered(Data?)
        case overflow
    }

    private mutating func deliver(payload: Data, moreFollows: Bool) -> DeliveryOutcome {
        if moreFollows {
            guard reassembly.count + payload.count <= config.maxReassemblyBytes else {
                return .overflow
            }
            reassembly.append(payload)
            return .delivered(nil)
        }
        if reassembly.isEmpty {
            return .delivered(payload.isEmpty ? nil : payload)
        }
        guard reassembly.count + payload.count <= config.maxReassemblyBytes else {
            return .overflow
        }
        var complete = reassembly
        complete.append(payload)
        reassembly = Data()
        return .delivered(complete)
    }

    /// nr_enquiry_response: the stand-alone ack, with NAK when we hold
    /// out-of-order frames and choke when the app is busy. Never NAK
    /// while choked.
    private mutating func enquiryResponse() -> [NetRomCircuitAction] {
        var nak = false
        var choke = false
        if localBusy {
            choke = true
        } else if !resequenceBuffer.isEmpty {
            nak = true
        }
        var actions: [NetRomCircuitAction] = [.send(.informationAck(
            yourIndex: yourIndex, yourId: yourId,
            rxSeq: UInt8(vr), choke: choke, nak: nak
        ))]
        vl = vr
        if ackPending {
            ackPending = false
            actions += disarmT2()
        }
        return actions
    }

    /// nr_frames_acked: advance va, dropping acked frames.
    private mutating func framesAcked(_ r: Int) {
        while va != r && !ackQueue.isEmpty {
            ackQueue.removeFirst()
            va = mod(va + 1)
        }
    }

    // MARK: Transmit pump

    /// nr_kick: move queued fragments into the window as INFO frames.
    private mutating func kick() -> [NetRomCircuitAction] {
        guard state == .connected else { return [] }
        guard !peerBusy else { return [] }
        guard !writeQueue.isEmpty else { return [] }

        let start = ackQueue.isEmpty ? va : vs
        let end = mod(va + window)
        guard start != end else { return [] }

        vs = start
        var actions: [NetRomCircuitAction] = []
        while vs != end, !writeQueue.isEmpty {
            let item = writeQueue.removeFirst()
            actions.append(.send(.information(
                yourIndex: yourIndex, yourId: yourId,
                txSeq: UInt8(vs), rxSeq: UInt8(vr),
                choke: localBusy, nak: false, moreFollows: item.moreFollows,
                payload: item.payload
            )))
            ackQueue.append(item)
            vs = mod(vs + 1)
        }
        // Piggybacked N(R) counts as the pending ack.
        vl = vr
        if ackPending {
            ackPending = false
            actions += disarmT2()
        }
        if !t1Running {
            actions += armT1()
        }
        return actions
    }

    // MARK: Timeouts

    private mutating func handleT1Timeout() -> [NetRomCircuitAction] {
        switch state {
        case .disconnected:
            return []
        case .connecting:
            if retryCount >= config.maxRetries {
                return die(.timedOut)
            }
            retryCount += 1
            return [.send(buildConnectRequest())] + armT1()
        case .disconnecting:
            if retryCount >= config.maxRetries {
                return die(.timedOut)
            }
            retryCount += 1
            return [.send(.disconnectRequest(yourIndex: yourIndex, yourId: yourId))] + armT1()
        case .connected:
            // DEVIATION 2: with nothing outstanding and nothing queued,
            // a stray T1 must not count toward N2 — that would tear
            // down a healthy idle circuit.
            if ackQueue.isEmpty && writeQueue.isEmpty {
                retryCount = 0
                return []
            }
            if retryCount >= config.maxRetries {
                return die(.timedOut)
            }
            retryCount += 1
            // nr_requeue_frames: outstanding frames go back to the head
            // of the write queue; kick resends from va (go-back-N).
            writeQueue.insert(contentsOf: ackQueue, at: 0)
            ackQueue.removeAll()
            var actions = kick()
            if !t1Running {
                actions += armT1()
            }
            return actions
        }
    }

    private mutating func handleT2Timeout() -> [NetRomCircuitAction] {
        guard state == .connected, ackPending else { return [] }
        ackPending = false
        return enquiryResponse()
    }

    private mutating func handleT4Timeout() -> [NetRomCircuitAction] {
        guard state == .connected else { return [] }
        peerBusy = false
        return kick()
    }

    private mutating func handleLocalBusy(_ busy: Bool) -> [NetRomCircuitAction] {
        let was = localBusy
        localBusy = busy
        guard state == .connected, was != busy else { return [] }
        if busy {
            return []
        }
        // Un-busied: drain whatever queued up while choked, then tell
        // the peer we are open again.
        var actions: [NetRomCircuitAction] = []
        while let next = resequenceBuffer.removeValue(forKey: vr) {
            switch deliver(payload: next.payload, moreFollows: next.moreFollows) {
            case .delivered(let out):
                if let out { actions.append(.deliverData(out)) }
                vr = mod(vr + 1)
            case .overflow:
                return actions + die(.protocolError(
                    "MORE-flag reassembly exceeded \(config.maxReassemblyBytes) bytes"))
            }
        }
        resequenceBuffer = resequenceBuffer.filter { isInReceiveWindow($0.key) }
        actions += enquiryResponse()
        return actions
    }

    // MARK: Frame builders

    private func buildConnectRequest() -> NetRomL4Frame {
        .connectRequest(
            myIndex: myIndex, myId: myId,
            proposedWindow: UInt8(config.clampedWindow),
            user: localUser, originNode: localNode,
            t1Seconds: config.advertiseT1 ? UInt16(max(1, min(config.t1, 65535)).rounded()) : nil
        )
    }

    private func buildConnectAck() -> NetRomL4Frame {
        .connectAck(
            yourIndex: yourIndex, yourId: yourId,
            myIndex: myIndex, myId: myId,
            acceptedWindow: UInt8(window),
            ttl: peerSpeaksExtension ? config.ttl : nil,
            refused: false
        )
    }

    // MARK: Teardown

    private mutating func die(_ reason: NetRomDisconnectReason) -> [NetRomCircuitAction] {
        var actions = clearAllTimers()
        state = .disconnected
        purgeBuffers()
        actions.append(.notifyDisconnected(reason))
        return actions
    }

    private mutating func purgeBuffers() {
        writeQueue.removeAll()
        ackQueue.removeAll()
        resequenceBuffer.removeAll()
        reassembly = Data()
        ackPending = false
        peerBusy = false
    }

    private mutating func resetSequenceState() {
        vs = 0; va = 0; vr = 0; vl = 0
        ackPending = false
        peerBusy = false
    }

    // MARK: Timer helpers (idempotent arming, mirrored bookkeeping)

    private mutating func armT1() -> [NetRomCircuitAction] {
        t1Running = true
        return [.startT1]
    }
    private mutating func rearmT1() -> [NetRomCircuitAction] {
        t1Running = true
        return [.startT1]
    }
    private mutating func disarmT1() -> [NetRomCircuitAction] {
        guard t1Running else { return [] }
        t1Running = false
        return [.stopT1]
    }
    private mutating func rearmT2() -> [NetRomCircuitAction] {
        t2Running = true
        return [.startT2]
    }
    private mutating func disarmT2() -> [NetRomCircuitAction] {
        guard t2Running else { return [] }
        t2Running = false
        return [.stopT2]
    }
    private mutating func rearmT4() -> [NetRomCircuitAction] {
        t4Running = true
        return [.startT4]
    }
    private mutating func disarmT4() -> [NetRomCircuitAction] {
        guard t4Running else { return [] }
        t4Running = false
        return [.stopT4]
    }
    private mutating func clearAllTimers() -> [NetRomCircuitAction] {
        disarmT1() + disarmT2() + disarmT4()
    }
}
