//
//  AX25SessionStatePropertyTests.swift
//  AXTermTests
//
//  Seeded property tests for the connected-mode state machine under hostile
//  and random input (CLAUDE.md §13: property tests for malformed and
//  replayed packets). Each case drives one AX25SessionManager through a few
//  hundred steps on a virtual clock and checks the invariants in
//  AX25SessionFuzzRig after every step.
//
//  S1 (hostile): a random mix of every inbound frame type with random
//     N(S), N(R), P/F and C bits, raw control bytes, local connect,
//     disconnect and sends, and clock jumps that fire T1, T2 and T3.
//     Invariants: sendBuffer matches V(A)..<V(S); outstanding <= K;
//     sequence variables in range; the receive buffer stays inside the
//     span; retries never pass N2 while the link is kept; every state
//     change is an allowed edge and is announced; every frame we send
//     decodes; no I-frame on a link that is not up; P=1 commands answered
//     with F=1 (or DM F=1 with no link); SABM, SABME and DISC answered as
//     §6.3 says.
//
//  S2 (faithful peer): the same manager against a model AX.25 station
//     (go-back-N receiver, window 1 to 7, 2.0 or 2.2 timer recovery) over
//     a channel that loses and duplicates frames. On top of S1's checks:
//     data reaches the application exactly once and in order, our stream
//     reaches the peer exactly once and in order, we never acknowledge a
//     frame the peer has not sent, and once the channel turns clean the
//     link drains (nothing stuck in either direction).
//
//  S3: out-of-window N(R) on any S or I frame leaves V(A), the send buffer
//     and the RTT estimate untouched.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25SessionStatePropertyTests: XCTestCase {

    // MARK: - S1 hostile

    func testHostileEventSequencesKeepEveryInvariant() {
        var coverage = Coverage()
        let cases = checkProperty("S1.hostile", cases: 120) { rng, v in
            let rig = AX25SessionFuzzRig(&rng)
            open(rig, &rng)
            defer { coverage.add(rig) }

            for step in 0..<rng.int(in: 120...260) {
                let before = rig.snapshot()
                var inbound: AX25InboundSummary?
                let label: String
                let roll = rng.int(100)
                switch roll {
                case 0..<25:
                    let (bytes, name) = Self.hostileSFrame(rig, &rng)
                    label = name
                    inbound = rig.receive(bytes)
                case 25..<45:
                    let (bytes, name) = Self.hostileIFrame(rig, &rng)
                    label = name
                    inbound = rig.receive(bytes)
                case 45..<51:
                    let (bytes, name) = Self.hostileUFrame(rig, &rng)
                    label = name
                    inbound = rig.receive(bytes)
                case 51..<55:
                    let control = rng.byte()
                    label = String(format: "raw control 0x%02X", control)
                    let bytes = rig.frameBytes(control: control, command: rng.pick([true, false, nil]),
                                               info: rng.bytes(rng.int(in: 0...8)))
                    inbound = rig.receive(bytes)
                case 55..<70:
                    let size = rng.int(in: 1...300)
                    label = "sendData \(size)"
                    rig.emit(rig.manager.sendData(rng.bytes(size), to: rig.peer, path: rig.path))
                case 70..<72:
                    label = "connect"
                    rig.emit(rig.manager.connect(to: rig.peer, path: rig.path))
                case 72..<77:
                    // Reopen from either end, so most steps run on a live link.
                    label = "reopen"
                    if rig.session?.state != .connected { open(rig, &rng) }
                case 77..<80:
                    label = "disconnect"
                    if let s = rig.session { rig.emit(rig.manager.disconnect(session: s)) }
                case 80..<81:
                    label = "forceDisconnect"
                    if let s = rig.session { rig.manager.forceDisconnect(session: s) }
                default:
                    let dt = rng.pick([rng.double(in: 0.05...1.0), rng.double(in: 1...10), rng.double(in: 10...60)])
                    label = String(format: "advance %.2fs", dt)
                    rig.clock.advance(by: dt)
                }
                rig.checkInvariants(before: before, inbound: inbound, step: "step \(step) (\(label))", v)
                coverage.note(rig)
                if !v.isEmpty { return }
            }
        }
        coverage.report("S1.hostile", cases: cases)
        guard PropertyRun.replaySeed == nil else { return }
        // A harness that never reaches the interesting states proves nothing.
        XCTAssertGreaterThan(coverage.delivered, cases * 3, "S1 delivered almost nothing: \(coverage)")
        XCTAssertGreaterThan(coverage.retransmissions, cases / 4, "S1 never retransmitted: \(coverage)")
        XCTAssertGreaterThan(coverage.statesSeen.count, 4, "S1 visited too few states: \(coverage)")
    }

    // MARK: - S2 faithful peer

    func testFaithfulPeerOverLossyChannelDeliversExactlyOnceInOrder() {
        var coverage = Coverage()
        var peerReceived = 0
        let cases = checkProperty("S2.faithfulPeer", cases: 120) { rng, v in
            let rig = AX25SessionFuzzRig(&rng)
            defer { coverage.add(rig) }
            let peer = AX25ModelPeer(rig: rig, k: rng.int(in: 1...7), enquiryOnT1: rng.chance(0.5), v)
            let channel = AX25FuzzChannel(rig: rig, peer: peer,
                                          loss: rng.pick([0, 0.05, 0.15, 0.3]),
                                          duplicate: rng.pick([0, 0.05, 0.2]))
            var localTag: UInt32 = 0
            var lastDelivered: Int64 = -1
            var checkedDeliveries = 0
            var lastPeerReceived: Int64 = -1
            var checkedPeerReceived = 0

            /// Checks what reached each application since the last call.
            /// False when something is wrong (the violation is recorded).
            @MainActor func audit(_ ctx: String, _ before: AX25SessionSnapshot) -> Bool {
                // What reached our application: the peer's tags, strictly increasing.
                while checkedDeliveries < rig.delivered.count {
                    let data = rig.delivered[checkedDeliveries]
                    checkedDeliveries += 1
                    guard let tag = AX25ModelPeer.tag(data, marker: 0x50) else {
                        v.record("delivered a payload that is not one the peer sent \(ctx)")
                        continue
                    }
                    v.check(Int64(tag) > lastDelivered,
                            "delivered peer frame \(tag) after \(lastDelivered): duplicate or out of order \(ctx); "
                            + "before vr=\(before.vr) rx=\(before.receiveBufferKeys) retries=\(before.retryCount) "
                            + "state=\(before.state.rawValue)")
                    channel.note("delivered P\(tag)")
                    lastDelivered = max(lastDelivered, Int64(tag))
                }
                // What reached the peer: our tags, strictly increasing.
                while checkedPeerReceived < peer.receivedTags.count {
                    let tag = peer.receivedTags[checkedPeerReceived]
                    checkedPeerReceived += 1
                    v.check(Int64(tag) > lastPeerReceived,
                            "peer received our frame \(tag) after \(lastPeerReceived) \(ctx)")
                    lastPeerReceived = max(lastPeerReceived, Int64(tag))
                }
                guard v.isEmpty else {
                    v.record("context: \(ctx), peer K=\(peer.k), local K=\(rig.config.windowSize), "
                             + "N2=\(rig.config.maxRetries), SREJ=\(rig.config.srejEnabled)\n      "
                             + channel.trace.joined(separator: "\n      "))
                    return false
                }
                return true
            }

            if rng.chance(0.5) {
                rig.emit(rig.manager.connect(to: rig.peer, path: rig.path))
            } else {
                peer.connect()
            }
            channel.pump()

            for step in 0..<rng.int(in: 150...300) {
                let before = rig.snapshot()
                var inbound: AX25InboundSummary?
                let label: String
                switch rng.int(100) {
                case 0..<24:
                    label = "deliver to local"
                    inbound = channel.deliverToLocal(&rng)
                case 24..<46:
                    label = "deliver to peer"
                    channel.deliverToPeer(&rng)
                case 46..<58:
                    label = "peer sends I"
                    peer.sendNew(&rng)
                case 58..<63:
                    label = "peer acks"
                    peer.ackIfOwed()
                case 63..<69:
                    label = "peer T1"
                    peer.t1Expiry()
                case 69..<80:
                    label = "local sendData"
                    var payload = Data([0x4C])
                    withUnsafeBytes(of: localTag.bigEndian) { payload.append(contentsOf: $0) }
                    payload.append(rng.bytes(rng.int(in: 0...20)))
                    localTag += 1
                    rig.emit(rig.manager.sendData(payload, to: rig.peer, path: rig.path))
                case 80..<97:
                    let dt = rng.double(in: 0.1...8)
                    label = String(format: "advance %.2fs", dt)
                    channel.note(label)
                    rig.clock.advance(by: dt)
                case 97:
                    label = "reconnect"
                    if rng.chance(0.5) { peer.connect() } else { rig.emit(rig.manager.connect(to: rig.peer, path: rig.path)) }
                case 98:
                    label = "peer disconnect"
                    if rng.chance(0.3) { peer.disconnect() }
                default:
                    label = "local disconnect"
                    if rng.chance(0.3), let s = rig.session { rig.emit(rig.manager.disconnect(session: s)) }
                }
                channel.pump()
                let ctx = "step \(step) (\(label))"
                if !label.hasPrefix("deliver") && !label.hasPrefix("advance") {
                    channel.note("\(label) [local \(rig.session?.state.rawValue ?? "none")]")
                }
                rig.checkInvariants(before: before, inbound: inbound, step: ctx, v)

                coverage.note(rig)
                if !audit(ctx, before) { return }
            }

            // Liveness: once the channel is clean the link must drain. Both
            // ends keep their timers; nothing is lost or duplicated.
            var drained = false
            for round in 0..<150 {
                let before = rig.snapshot()
                channel.deliverAllCleanly()
                peer.ackIfOwed()
                if round % 3 == 2 { peer.t1Expiry() }
                channel.pump()
                channel.deliverAllCleanly()
                rig.clock.advance(by: 2)
                channel.pump()
                let ctx = "drain round \(round)"
                channel.note(ctx)
                rig.checkInvariants(before: before, inbound: nil, step: ctx, v)
                if !audit(ctx, before) { return }
                guard let s = rig.session, s.state == .connected, peer.state == .connected else { break }
                if s.sendBuffer.isEmpty, s.pendingDataQueue.isEmpty, s.stateMachine.receiveBuffer.isEmpty,
                   !peer.hasOutstanding, channel.isEmpty {
                    drained = true
                    break
                }
            }
            if !drained, let s = rig.session, s.state == .connected, peer.state == .connected {
                v.record("link did not drain on a clean channel: sendBuffer=\(s.sendBuffer.keys.sorted()) "
                         + "queued=\(s.pendingDataQueue.count) rx=\(s.stateMachine.receiveBuffer.keys.sorted()) "
                         + "vs=\(s.vs) va=\(s.va) vr=\(s.vr) peerOutstanding=\(peer.hasOutstanding)")
                _ = audit("after drain", rig.snapshot())
                return
            }
            peerReceived += peer.receivedTags.count
        }
        coverage.report("S2.faithfulPeer", cases: cases, extra: "peerReceived=\(peerReceived)")
        guard PropertyRun.replaySeed == nil else { return }
        XCTAssertGreaterThan(coverage.delivered, cases * 3, "S2 delivered almost nothing: \(coverage)")
        XCTAssertGreaterThan(peerReceived, cases * 3, "S2 sent almost nothing to the peer")
        XCTAssertGreaterThan(coverage.retransmissions, cases, "S2 never retransmitted: \(coverage)")
    }

    // MARK: - S3 out-of-window N(R)

    func testOutOfWindowNRNeverMovesTheSendSide() {
        checkProperty("S3.outOfWindowNR", cases: 300) { rng, v in
            let rig = AX25SessionFuzzRig(&rng)
            open(rig, &rng)
            // Put a few of our frames in flight and get some acknowledged.
            for _ in 0..<rng.int(in: 0...12) {
                rig.emit(rig.manager.sendData(rng.bytes(rng.int(in: 1...20)), to: rig.peer, path: rig.path))
                if rng.chance(0.4), let s = rig.session, s.vs != s.va {
                    let nr = (s.va + 1 + rng.int((s.vs - s.va + 8) % 8)) % 8
                    rig.receive(rig.frameBytes(control: AX25Control.sFrame(base: AX25Control.rrBase, nr: nr),
                                               command: false))
                }
            }
            guard let s = rig.session, s.state == .connected else { return }
            let outstanding = (s.vs - s.va + 8) % 8
            let invalid = (0..<8).filter { candidate in
                (candidate - s.va + 8) % 8 > outstanding
            }
            guard let nr = invalid.isEmpty ? nil : rng.pick(invalid) else { return }

            let before = rig.snapshot()
            let pf = rng.chance(0.5)
            let bytes: Data
            let kind = rng.int(5)
            switch kind {
            case 0: bytes = rig.frameBytes(control: AX25Control.sFrame(base: AX25Control.rrBase, nr: nr, pf: pf), command: rng.chance(0.5))
            case 1: bytes = rig.frameBytes(control: AX25Control.sFrame(base: AX25Control.rnrBase, nr: nr, pf: pf), command: rng.chance(0.5))
            case 2: bytes = rig.frameBytes(control: AX25Control.sFrame(base: AX25Control.rejBase, nr: nr, pf: pf), command: rng.chance(0.5))
            case 3: bytes = rig.frameBytes(control: AX25Control.sFrame(base: AX25Control.srejBase, nr: nr, pf: pf), command: false)
            default:
                bytes = rig.frameBytes(control: AX25Control.iFrame(ns: s.vr, nr: nr, pf: pf), command: true,
                                       pid: 0xF0, info: rng.bytes(rng.int(in: 0...30)))
            }
            let inbound = rig.receive(bytes)
            rig.checkInvariants(before: before, inbound: inbound, step: "invalid N(R)=\(nr) kind \(kind)", v)
            guard let after = rig.session, after.state == .connected, after.id == before.id else { return }
            v.check(after.va == before.va, "invalid N(R)=\(nr) moved V(A) \(before.va) -> \(after.va) (vs=\(before.vs))")
            v.check(after.sendBuffer.keys.sorted() == before.sendBufferKeys,
                    "invalid N(R)=\(nr) changed the send buffer \(before.sendBufferKeys) -> \(after.sendBuffer.keys.sorted())")
            v.check(after.timers.srtt == before.srtt && after.timers.rto == before.rto,
                    "invalid N(R)=\(nr) changed the RTT estimate srtt \(String(describing: before.srtt)) -> "
                    + "\(String(describing: after.timers.srtt)), rto \(before.rto) -> \(after.timers.rto)")
        }
    }

    // MARK: - Generators

    /// Opens the link from either end.
    private func open(_ rig: AX25SessionFuzzRig, _ rng: inout PropertyRNG) {
        if rng.chance(0.5) {
            rig.emit(rig.manager.connect(to: rig.peer, path: rig.path))
            rig.receive(rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.ua, pf: true), command: false))
        } else {
            rig.receive(rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.sabm, pf: true), command: true))
        }
    }

    /// An N(R) that is usually inside V(A)...V(S) and sometimes anything.
    private static func plausibleNR(_ rig: AX25SessionFuzzRig, _ rng: inout PropertyRNG) -> Int {
        guard let s = rig.session, rng.chance(0.7) else { return rng.int(8) }
        let outstanding = (s.vs - s.va + 8) % 8
        return (s.va + rng.int(outstanding + 1)) % 8
    }

    private static func hostileSFrame(_ rig: AX25SessionFuzzRig, _ rng: inout PropertyRNG) -> (Data, String) {
        let (base, name) = rng.pick([(AX25Control.rrBase, "RR"), (AX25Control.rnrBase, "RNR"),
                                     (AX25Control.rejBase, "REJ"), (AX25Control.srejBase, "SREJ")])
        let nr = plausibleNR(rig, &rng)
        let pf = rng.chance(0.4)
        let command: Bool? = rng.chance(0.05) ? nil : rng.chance(0.5)
        return (rig.frameBytes(control: AX25Control.sFrame(base: base, nr: nr, pf: pf), command: command),
                "\(name) nr=\(nr) pf=\(pf) cmd=\(String(describing: command))")
    }

    private static func hostileIFrame(_ rig: AX25SessionFuzzRig, _ rng: inout PropertyRNG) -> (Data, String) {
        let vr = rig.session?.vr ?? 0
        let ns: Int
        switch rng.int(100) {
        case 0..<45: ns = vr
        case 45..<65: ns = (vr + rng.int(in: 1...3)) % 8
        case 65..<80: ns = (vr + 8 - rng.int(in: 1...4)) % 8
        default: ns = rng.int(8)
        }
        let nr = plausibleNR(rig, &rng)
        let pf = rng.chance(0.3)
        let length = rng.pick([0, 1, rng.int(in: 2...64), 256])
        let command: Bool? = rng.chance(0.85) ? true : rng.chance(0.5) ? false : nil
        let pid: UInt8 = rng.chance(0.9) ? 0xF0 : rng.byte()
        return (rig.frameBytes(control: AX25Control.iFrame(ns: ns, nr: nr, pf: pf), command: command,
                               pid: pid, info: rng.bytes(length)),
                "I ns=\(ns) nr=\(nr) pf=\(pf) len=\(length) cmd=\(String(describing: command))")
    }

    private static func hostileUFrame(_ rig: AX25SessionFuzzRig, _ rng: inout PropertyRNG) -> (Data, String) {
        let pf = rng.chance(0.7)
        let flip = rng.chance(0.1)
        switch rng.int(8) {
        case 0: return (rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.sabm, pf: pf), command: !flip), "SABM pf=\(pf)")
        case 1: return (rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.sabme, pf: pf), command: !flip), "SABME pf=\(pf)")
        case 2: return (rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.disc, pf: pf), command: !flip), "DISC pf=\(pf)")
        case 3: return (rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.dm, pf: pf), command: flip), "DM pf=\(pf)")
        case 4: return (rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.ua, pf: pf), command: flip), "UA pf=\(pf)")
        case 5: return (rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.frmr, pf: pf), command: flip,
                                       info: rng.bytes(3)), "FRMR pf=\(pf)")
        case 6:
            let command = rng.chance(0.7)
            var params = AX25XIDParameters()
            params.supportsSREJ = rng.chance(0.5)
            params.iFieldLengthRx = rng.pick([nil, 64, 128, 256])
            params.windowSizeRx = rng.pick([nil, 1, 4, 7])
            let info = rng.chance(0.8) ? params.encoded(isCommand: command) : rng.bytes(rng.int(in: 0...12))
            return (rig.frameBytes(control: 0xAF | (pf ? 0x10 : 0), command: command, info: info),
                    "XID cmd=\(command) pf=\(pf)")
        default:
            return (rig.frameBytes(control: AX25Control.uFrame(base: AX25Control.ui, pf: pf), command: true,
                                   pid: 0xF0, info: rng.bytes(rng.int(in: 0...20))), "UI")
        }
    }
}

// MARK: - Coverage

/// Totals across cases, so a run can show it reached the states it claims
/// to test.
struct Coverage: CustomStringConvertible {
    var delivered = 0
    var transmitted = 0
    var retransmissions = 0
    var steps = 0
    var connectedSteps = 0
    var statesSeen: Set<String> = []

    @MainActor
    mutating func note(_ rig: AX25SessionFuzzRig) {
        steps += 1
        let state = rig.session?.state ?? .disconnected
        statesSeen.insert(state.rawValue)
        if state == .connected { connectedSteps += 1 }
    }

    @MainActor
    mutating func add(_ rig: AX25SessionFuzzRig) {
        delivered += rig.delivered.count
        transmitted += rig.transmitted.count
        retransmissions += rig.manager.sessions.values.reduce(0) { $0 + $1.statistics.retransmissions }
    }

    var description: String {
        "steps=\(steps) connectedSteps=\(connectedSteps) delivered=\(delivered) transmitted=\(transmitted) "
            + "retransmissions=\(retransmissions) states=\(statesSeen.sorted())"
    }

    func report(_ name: String, cases: Int, extra: String = "") {
        if PropertyRun.soakIterations != nil || PropertyRun.verbose {
            print("[property] \(name) coverage over \(cases) cases: \(self) \(extra)")
        }
    }
}

// MARK: - Model peer

/// A plain AX.25 station for the far end: go-back-N receiver (it discards
/// any I-frame whose N(S) is not V(R), as §6.4.4.1 says), a sender with
/// window k, and timer recovery either 2.0 style (resend the outstanding
/// frames, the first with P=1) or 2.2 style (an RR enquiry with P=1).
///
/// It checks the one thing only the far end can see: that we never
/// acknowledge a frame it has not sent.
@MainActor
final class AX25ModelPeer {
    enum State { case disconnected, connecting, connected, disconnecting }

    let rig: AX25SessionFuzzRig
    let k: Int
    let enquiryOnT1: Bool
    let violations: PropertyViolations
    private(set) var state: State = .disconnected

    // Counts since the last link reset; the wire carries them modulo 8.
    private var vs = 0, va = 0, vr = 0
    private var rejSent = false, ackOwed = false, pollPending = false
    private var unansweredT1 = 0
    private var outstanding: [Int: Data] = [:]
    private var nextTag: UInt32 = 0

    var hasOutstanding: Bool { !outstanding.isEmpty }

    /// Tags of our frames the peer accepted, in order.
    private(set) var receivedTags: [UInt32] = []
    /// Bytes waiting to go on the air toward us.
    var outbox: [Data] = []

    init(rig: AX25SessionFuzzRig, k: Int, enquiryOnT1: Bool, _ violations: PropertyViolations) {
        self.rig = rig
        self.k = k
        self.enquiryOnT1 = enquiryOnT1
        self.violations = violations
    }

    /// The 4-byte tag after a marker byte, or nil.
    static func tag(_ data: Data, marker: UInt8) -> UInt32? {
        let bytes = Array(data)
        guard bytes.count >= 5, bytes[0] == marker else { return nil }
        return bytes[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func reset() {
        vs = 0; va = 0; vr = 0
        outstanding = [:]
        rejSent = false; ackOwed = false; pollPending = false
        unansweredT1 = 0
    }

    private func send(control: UInt8, command: Bool, pid: UInt8? = nil, info: Data = Data()) {
        outbox.append(rig.frameBytes(control: control, command: command, pid: pid, info: info))
    }

    private func sendS(_ base: UInt8, pf: Bool, command: Bool) {
        send(control: AX25Control.sFrame(base: base, nr: vr % 8, pf: pf), command: command)
        ackOwed = false
    }

    private func sendU(_ base: UInt8, pf: Bool, command: Bool) {
        send(control: AX25Control.uFrame(base: base, pf: pf), command: command)
    }

    private func sendI(_ serial: Int, poll: Bool) {
        guard let payload = outstanding[serial] else { return }
        send(control: AX25Control.iFrame(ns: serial % 8, nr: vr % 8, pf: poll), command: true, pid: 0xF0, info: payload)
        ackOwed = false
    }

    private func resend(from start: Int, pollFirst: Bool) {
        for (index, serial) in (start..<vs).enumerated() { sendI(serial, poll: pollFirst && index == 0) }
    }

    // MARK: Actions

    func connect() {
        guard state == .disconnected else { return }
        reset()
        state = .connecting
        sendU(AX25Control.sabm, pf: true, command: true)
    }

    func disconnect() {
        guard state == .connected else { return }
        state = .disconnecting
        sendU(AX25Control.disc, pf: true, command: true)
    }

    func sendNew(_ rng: inout PropertyRNG) {
        guard state == .connected, vs - va < k else { return }
        var payload = Data([0x50])
        withUnsafeBytes(of: nextTag.bigEndian) { payload.append(contentsOf: $0) }
        payload.append(rng.bytes(rng.int(in: 0...20)))
        nextTag += 1
        outstanding[vs] = payload
        let fillsWindow = vs + 1 - va == k
        vs += 1
        sendI(vs - 1, poll: fillsWindow || rng.chance(0.1))
    }

    func ackIfOwed() {
        if state == .connected, ackOwed { sendS(AX25Control.rrBase, pf: false, command: false) }
    }

    func t1Expiry() {
        switch state {
        case .disconnected:
            return
        case .connecting:
            sendU(AX25Control.sabm, pf: true, command: true)
        case .disconnecting:
            sendU(AX25Control.disc, pf: true, command: true)
        case .connected:
            guard !outstanding.isEmpty || pollPending else { return }
            if outstanding.isEmpty || enquiryOnT1 {
                sendS(AX25Control.rrBase, pf: true, command: true)
                pollPending = true
            } else {
                resend(from: va, pollFirst: true)
            }
        }
        unansweredT1 += 1
        // Its own N2.
        if unansweredT1 > 12 { reset(); state = .disconnected }
    }

    // MARK: Receiving our frames

    func receive(_ bytes: Data) {
        guard case .success(let frame) = AX25.checkFrame(ax25: bytes),
              frame.from != nil, let to = frame.to,
              to.call == rig.peer.call, to.ssid == rig.peer.ssid else { return }
        let decoded = AX25ControlFieldDecoder.decode(control: frame.control, controlByte1: frame.controlByte1)
        let isCommand = frame.isCommand == true
        let pf = (decoded.pf ?? 0) == 1

        switch decoded.frameClass {
        case .U:
            switch decoded.uType {
            case .SABM?:
                sendU(AX25Control.ua, pf: pf, command: false)
                reset()
                state = .connected
            case .SABME?:
                sendU(AX25Control.dm, pf: pf, command: false)
            case .DISC?:
                sendU(state == .disconnected ? AX25Control.dm : AX25Control.ua, pf: pf, command: false)
                reset()
                state = .disconnected
            case .UA?:
                if state == .connecting { reset(); state = .connected }
                else if state == .disconnecting { reset(); state = .disconnected }
            case .DM?:
                reset()
                state = .disconnected
            default:
                break
            }
        case .I:
            guard state == .connected else {
                if pf { sendU(AX25Control.dm, pf: true, command: false) }
                return
            }
            acknowledge(decoded.nr ?? 0)
            if decoded.ns == vr % 8 {
                vr += 1
                rejSent = false
                if let tag = Self.tag(frame.info, marker: 0x4C) {
                    receivedTags.append(tag)
                } else {
                    violations.record("peer accepted an I-frame that is not one of our tagged sends")
                }
                if pf { sendS(AX25Control.rrBase, pf: true, command: false) } else { ackOwed = true }
            } else if !rejSent {
                sendS(AX25Control.rejBase, pf: pf, command: false)
                rejSent = true
            } else if pf {
                sendS(AX25Control.rrBase, pf: true, command: false)
            }
        case .S:
            guard state == .connected else {
                if pf && isCommand { sendU(AX25Control.dm, pf: true, command: false) }
                return
            }
            acknowledge(decoded.nr ?? 0)
            if decoded.sType == .REJ { resend(from: va, pollFirst: false) }
            if decoded.sType == .SREJ, let nr = decoded.nr,
               let serial = (va..<vs).first(where: { $0 % 8 == nr }) {
                sendI(serial, poll: false)
            }
            if isCommand && pf {
                sendS(AX25Control.rrBase, pf: true, command: false)
            } else if !isCommand && pf && pollPending {
                pollPending = false
                unansweredT1 = 0
                if decoded.sType != .REJ { resend(from: va, pollFirst: false) }
            }
        case .unknown:
            break
        }
    }

    /// Applies an N(R) from us. It must name a frame in V(A)...V(S): an
    /// N(R) past V(S) acknowledges frames this station never sent.
    private func acknowledge(_ nr: Int) {
        guard let serial = (va...vs).first(where: { $0 % 8 == nr }) else {
            violations.record("we sent N(R)=\(nr) but the peer's window is V(A)=\(va % 8)...V(S)=\(vs % 8) "
                              + "(\(vs - va) outstanding): it acknowledges frames never sent")
            return
        }
        if serial > va { unansweredT1 = 0 }
        for done in va..<serial { outstanding[done] = nil }
        va = serial
    }
}

// MARK: - Channel

/// FIFO in each direction, as one AX.25 path is: frames may be lost or
/// duplicated, never reordered. A delivered U frame (a link reset or
/// teardown) flushes whatever was queued before it, since frames of the old
/// link arriving on the new one are an ambiguity AX.25 itself does not
/// resolve.
@MainActor
final class AX25FuzzChannel {
    let rig: AX25SessionFuzzRig
    let peer: AX25ModelPeer
    let loss: Double
    let duplicate: Double
    private var toPeer: [Data] = []
    private var toLocal: [Data] = []
    private var pumped = 0

    init(rig: AX25SessionFuzzRig, peer: AX25ModelPeer, loss: Double, duplicate: Double) {
        self.rig = rig
        self.peer = peer
        self.loss = loss
        self.duplicate = duplicate
    }

    func pump() {
        while pumped < rig.transmitted.count {
            toPeer.append(rig.transmitted[pumped].encodeAX25())
            pumped += 1
        }
        toLocal.append(contentsOf: peer.outbox)
        peer.outbox.removeAll()
    }

    private static func isLinkControl(_ bytes: Data) -> Bool {
        guard case .success(let frame) = AX25.checkFrame(ax25: bytes) else { return false }
        return frame.frameType == .u
    }

    /// The last few channel events, for a failure report.
    private(set) var trace: [String] = []

    func note(_ event: String) {
        trace.append(event)
        if trace.count > 40 { trace.removeFirst(trace.count - 40) }
    }

    static func describe(_ bytes: Data) -> String {
        guard case .success(let frame) = AX25.checkFrame(ax25: bytes) else { return "undecodable" }
        let d = AX25ControlFieldDecoder.decode(control: frame.control, controlByte1: frame.controlByte1)
        let cmd = frame.isCommand == true ? "cmd" : "rsp"
        let pf = (d.pf ?? 0) == 1 ? " P/F" : ""
        switch d.frameClass {
        case .I:
            let tag = AX25ModelPeer.tag(frame.info, marker: 0x50).map { "P\($0)" }
                ?? AX25ModelPeer.tag(frame.info, marker: 0x4C).map { "L\($0)" } ?? "?"
            return "I ns=\(d.ns ?? -1) nr=\(d.nr ?? -1)\(pf) \(tag)"
        case .S: return "\(d.sType?.rawValue ?? "S") nr=\(d.nr ?? -1) \(cmd)\(pf)"
        case .U: return "\(d.uType?.rawValue ?? "U") \(cmd)\(pf)"
        case .unknown: return "unknown"
        }
    }

    private func take(_ queue: inout [Data], _ rng: inout PropertyRNG, toward: String) -> Data? {
        guard !queue.isEmpty else { return nil }
        let bytes = queue.removeFirst()
        if rng.chance(loss) { note("lost \(toward): \(Self.describe(bytes))"); return nil }
        if rng.chance(duplicate) { queue.insert(bytes, at: 0) }
        note("\(toward): \(Self.describe(bytes))")
        return bytes
    }

    func deliverToLocal(_ rng: inout PropertyRNG) -> AX25InboundSummary? {
        guard let bytes = take(&toLocal, &rng, toward: "-> local") else { return nil }
        let summary = rig.receive(bytes)
        // The reply to the U frame is not pumped yet, so it survives.
        if Self.isLinkControl(bytes) { toLocal.removeAll(); toPeer.removeAll() }
        return summary
    }

    var isEmpty: Bool { toPeer.isEmpty && toLocal.isEmpty }

    /// Delivers everything queued both ways, replies included, with no
    /// loss or duplication.
    func deliverAllCleanly() {
        var budget = 400
        pump()
        while !isEmpty, budget > 0 {
            budget -= 1
            if !toLocal.isEmpty {
                let bytes = toLocal.removeFirst()
                note("-> local: \(Self.describe(bytes))")
                rig.receive(bytes)
                if Self.isLinkControl(bytes) { toLocal.removeAll(); toPeer.removeAll() }
            } else {
                let bytes = toPeer.removeFirst()
                note("-> peer: \(Self.describe(bytes))")
                peer.receive(bytes)
                if Self.isLinkControl(bytes) { toLocal.removeAll(); toPeer.removeAll() }
            }
            pump()
        }
    }

    func deliverToPeer(_ rng: inout PropertyRNG) {
        guard let bytes = take(&toPeer, &rng, toward: "-> peer") else { return }
        peer.receive(bytes)
        if Self.isLinkControl(bytes) { toLocal.removeAll(); toPeer.removeAll() }
    }
}
