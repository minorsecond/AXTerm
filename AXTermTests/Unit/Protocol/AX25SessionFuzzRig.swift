//
//  AX25SessionFuzzRig.swift
//  AXTermTests
//
//  A local AX25SessionManager on a virtual clock, fed raw AX.25 bytes the
//  way SessionCoordinator feeds it, with an invariant checker that runs
//  after every step. Used by AX25SessionStatePropertyTests.
//
//  Everything the manager puts on the air is captured, encoded to wire
//  bytes and decoded again, so the session layer's own frames are checked
//  as frames, not as Swift values.
//

import Foundation
import XCTest
@testable import AXTerm

/// What one inbound frame was, after decoding, for the response rules.
struct AX25InboundSummary {
    let frameClass: AX25FrameClass
    let sType: AX25SType?
    let uType: AX25UType?
    let ns: Int?
    let nr: Int?
    let pf: Bool
    let isCommand: Bool
}

/// State of the session under test at one moment.
struct AX25SessionSnapshot {
    let exists: Bool
    let id: UUID?
    let state: AX25SessionState
    let vs: Int, va: Int, vr: Int
    let sendBufferKeys: [Int]
    let sendBufferPayloads: [Int: Data]
    let receiveBufferKeys: [Int]
    let retryCount: Int
    let srtt: Double?
    let rto: Double
    let transmittedCount: Int
    let deliveredCount: Int
}

@MainActor
final class AX25SessionFuzzRig {
    let clock = AX25VirtualClock()
    let manager: AX25SessionManager
    let local = AX25Address(call: "LOCAL", ssid: 1)
    let peer = AX25Address(call: "PEER", ssid: 2)
    let path: DigiPath
    let config: AX25SessionConfig

    /// Every frame the manager put on the air, in order.
    private(set) var transmitted: [OutboundFrame] = []
    /// Every payload handed to the application, in order.
    private(set) var delivered: [Data] = []
    /// Every state change the manager announced: (session id, from, to).
    private(set) var transitions: [(UUID, AX25SessionState, AX25SessionState)] = []
    private var lastAnnounced: [UUID: AX25SessionState] = [:]

    var key: SessionKey { SessionKey(destination: peer, path: path, radio: .primary) }
    var session: AX25Session? { manager.sessions[key] }

    private static let xidDefaults = TestDefaults.make("AX25SessionFuzzRig")

    init(_ rng: inout PropertyRNG) {
        config = AX25SessionConfig(
            windowSize: rng.int(in: 1...7),
            paclen: rng.pick([32, 64, 128, 256]),
            maxRetries: rng.int(in: 1...10),
            srejEnabled: rng.chance(0.25),
            rtoMin: rng.pick([0.5, 1.0, 3.0]),
            rtoMax: rng.pick([8.0, 16.0, 30.0]),
            initialRto: rng.pick([1.0, 2.0, 4.0, 6.0]),
            adaptiveTimeout: rng.chance(0.8))
        path = rng.chance(0.25) ? DigiPath([AX25Address(call: "DIGI", ssid: 1)]) : DigiPath()
        manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = config
        manager.xidMemory = XIDAnswerMemory(defaults: Self.xidDefaults)
        manager.onSendFrame = { [unowned self] in self.transmitted.append($0) }
        manager.onDataReceived = { [unowned self] _, data in self.delivered.append(data) }
        manager.onSessionStateChanged = { [unowned self] session, from, to in
            self.transitions.append((session.id, from, to))
            self.lastAnnounced[session.id] = to
        }
    }

    func emit(_ frame: OutboundFrame?) { if let frame { transmitted.append(frame) } }
    func emit(_ frames: [OutboundFrame]) { transmitted.append(contentsOf: frames) }

    func snapshot() -> AX25SessionSnapshot {
        let s = session
        return AX25SessionSnapshot(
            exists: s != nil, id: s?.id, state: s?.state ?? .disconnected,
            vs: s?.vs ?? 0, va: s?.va ?? 0, vr: s?.vr ?? 0,
            sendBufferKeys: s?.sendBuffer.keys.sorted() ?? [],
            sendBufferPayloads: s?.sendBuffer.mapValues(\.payload) ?? [:],
            receiveBufferKeys: s?.stateMachine.receiveBuffer.keys.sorted() ?? [],
            retryCount: s?.stateMachine.retryCount ?? 0,
            srtt: s?.timers.srtt, rto: s?.timers.rto ?? 0,
            transmittedCount: transmitted.count, deliveredCount: delivered.count)
    }

    // MARK: - Inbound frames

    /// Raw bytes for a frame from the peer to us. `command` sets the v2
    /// C bits; nil leaves both clear, as a v1 station sends.
    func frameBytes(control: UInt8, command: Bool?, pid: UInt8? = nil, info: Data = Data()) -> Data {
        var data = Data()
        data.append(local.encodeForAX25(isLast: false, isDestination: true, isCommand: command))
        data.append(peer.encodeForAX25(isLast: path.isEmpty, isDestination: false, isCommand: command))
        for (index, digi) in path.digis.enumerated() {
            data.append(AX25Address(call: digi.call, ssid: digi.ssid, repeated: true)
                .encodeForAX25(isLast: index == path.digis.count - 1))
        }
        data.append(control)
        if let pid { data.append(pid) }
        data.append(info)
        return data
    }

    /// Feeds raw AX.25 bytes to the manager the way SessionCoordinator's
    /// handleIncomingPacket does for a frame addressed to us. Nil when the
    /// bytes do not decode or are not for us.
    @discardableResult
    func receive(_ bytes: Data) -> AX25InboundSummary? {
        guard case .success(let frame) = AX25.checkFrame(ax25: bytes),
              let from = frame.from, let to = frame.to, manager.answers(to) else { return nil }
        let decoded = AX25ControlFieldDecoder.decode(control: frame.control, controlByte1: frame.controlByte1)
        let isCommand: Bool
        if to.repeated && !from.repeated {
            isCommand = true
        } else if !to.repeated && from.repeated {
            isCommand = false
        } else {
            isCommand = decoded.frameClass == .I
                || [AX25UType.SABM, .SABME, .DISC, .UI].contains(decoded.uType ?? .UNKNOWN)
        }
        let path = DigiPath.from(frame.via.map(\.display))
        let pf = (decoded.pf ?? 0) == 1
        let radio = RadioID.primary

        switch decoded.frameClass {
        case .U:
            switch decoded.uType {
            case .UA?:
                manager.handleInboundUA(from: from, path: path, radio: radio)
            case .DM?:
                if !manager.handleInboundDMDuringNegotiation(from: from, radio: radio) {
                    manager.handleInboundDM(from: from, path: path, radio: radio)
                }
            case .FRMR?:
                manager.handleInboundFRMRDuringNegotiation(from: from, radio: radio)
                manager.handleInboundFRMR(from: from, path: path, radio: radio)
            case .XID?:
                emit(manager.handleInboundXID(from: from, to: to, path: path, radio: radio,
                                              info: frame.info, isCommand: isCommand,
                                              pf: frame.control & 0x10 != 0))
            case .DISC?:
                emit(manager.handleInboundDISC(from: from, path: path, radio: radio))
            case .SABM?, .SABME?:
                emit(manager.handleInboundSABM(from: from, to: to, path: path, radio: radio,
                                               extended: decoded.uType == .SABME,
                                               pf: frame.control & 0x10 != 0))
            default:
                break
            }
        case .I:
            emit(manager.handleInboundIFrame(from: from, path: path, radio: radio,
                                             ns: decoded.ns ?? 0, nr: decoded.nr ?? 0, pf: pf,
                                             payload: frame.info, pid: frame.pid))
        case .S:
            switch decoded.sType {
            case .RR?:
                emit(manager.handleInboundRRFrames(from: from, path: path, radio: radio,
                                                   nr: decoded.nr ?? 0, pf: pf, isCommand: isCommand))
            case .RNR?:
                emit(manager.handleInboundRNR(from: from, path: path, radio: radio,
                                              nr: decoded.nr ?? 0, pf: pf, isCommand: isCommand))
            case .REJ?:
                emit(manager.handleInboundREJ(from: from, path: path, radio: radio,
                                              nr: decoded.nr ?? 0, pf: pf, isCommand: isCommand))
            case .SREJ?:
                emit(manager.handleInboundSREJ(from: from, path: path, radio: radio,
                                               nr: decoded.nr ?? 0, pf: pf))
            case nil:
                break
            }
        case .unknown:
            break
        }
        return AX25InboundSummary(frameClass: decoded.frameClass, sType: decoded.sType, uType: decoded.uType,
                                  ns: decoded.ns, nr: decoded.nr, pf: pf, isCommand: isCommand)
    }

    // MARK: - Invariants

    /// Edges the session state may take in one announced change.
    static let allowedTransitions: Set<String> = [
        "disconnected>connecting", "disconnected>connected",
        "connecting>connected", "connecting>disconnected", "connecting>disconnecting", "connecting>error",
        "connected>disconnecting", "connected>disconnected", "connected>error",
        "disconnecting>disconnected",
        "error>connecting", "error>disconnected",
    ]

    private var checkedTransitions = 0

    /// The checks that hold after any step, whatever drove it.
    func checkInvariants(before: AX25SessionSnapshot, inbound: AX25InboundSummary?,
                         step: String, _ v: PropertyViolations) {
        let ctx = "after \(step)"

        // Every announced transition is one the state machine allows.
        while checkedTransitions < transitions.count {
            let (_, from, to) = transitions[checkedTransitions]
            checkedTransitions += 1
            v.check(Self.allowedTransitions.contains("\(from.rawValue)>\(to.rawValue)"),
                    "disallowed transition \(from.rawValue) -> \(to.rawValue) \(ctx)")
        }

        // Frames we transmitted decode as AX.25, from us to the peer.
        let newFrames = Array(transmitted[before.transmittedCount...])
        for frame in newFrames {
            let bytes = frame.encodeAX25()
            guard case .success(let decoded) = AX25.checkFrame(ax25: bytes) else {
                v.record("we transmitted an undecodable \(frame.displayInfo ?? frame.frameType) \(ctx): "
                         + AX25.decodeFailureReason(ax25: bytes))
                continue
            }
            v.check(decoded.to?.call == peer.call && decoded.to?.ssid == peer.ssid,
                    "frame addressed to \(decoded.to?.display ?? "?") \(ctx)")
        }

        guard let s = session else { return }
        let sm = s.stateMachine
        let seq = sm.sequenceState
        let modulo = sm.config.modulo

        // The state the manager last announced is the state it is in, unless
        // this session never announced one (it is then still disconnected).
        if let announced = lastAnnounced[s.id] {
            v.check(announced == s.state, "state is \(s.state.rawValue) but the last announced was \(announced.rawValue) \(ctx)")
        } else {
            v.check(s.state == .disconnected, "state \(s.state.rawValue) reached without an announcement \(ctx)")
        }

        v.check((0..<modulo).contains(seq.vs) && (0..<modulo).contains(seq.va) && (0..<modulo).contains(seq.vr),
                "sequence variable out of range vs=\(seq.vs) va=\(seq.va) vr=\(seq.vr) \(ctx)")

        if s.state == .connected {
            let outstanding = seq.outstandingCount
            v.check(s.sendBuffer.count == outstanding,
                    "sendBuffer.count \(s.sendBuffer.count) != outstanding \(outstanding) (vs=\(seq.vs) va=\(seq.va)) \(ctx)")
            let expectedKeys = Set((0..<outstanding).map { (seq.va + $0) % modulo })
            v.check(Set(s.sendBuffer.keys) == expectedKeys,
                    "sendBuffer keys \(s.sendBuffer.keys.sorted()) are not V(A)..<V(S) \(seq.va)..<\(seq.vs) \(ctx)")
            v.check(outstanding <= sm.config.windowCeiling,
                    "outstanding \(outstanding) exceeds K=\(sm.config.windowCeiling) \(ctx)")
            // Each buffered frame carries its own N(S).
            for (ns, frame) in s.sendBuffer {
                v.check(frame.ns == ns, "sendBuffer[\(ns)] holds a frame with N(S)=\(String(describing: frame.ns)) \(ctx)")
            }
        }

        // Out-of-sequence frames sit strictly ahead of V(R), inside the span.
        for ns in sm.receiveBuffer.keys {
            let distance = (ns - seq.vr + modulo) % modulo
            v.check(distance > 0 && distance < sm.config.receiveWindowSpan,
                    "receive buffer holds N(S)=\(ns) at distance \(distance) from V(R)=\(seq.vr) \(ctx)")
        }

        // N2: while the link is being kept, retries never exceed it.
        if [.connecting, .connected, .disconnecting].contains(s.state) {
            v.check(sm.retryCount <= sm.config.maxRetries,
                    "retryCount \(sm.retryCount) > N2=\(sm.config.maxRetries) in \(s.state.rawValue) \(ctx)")
        }

        let cwnd = s.aimdWindow.cwnd
        v.check(cwnd.isFinite && cwnd >= 1 && s.aimdWindow.effectiveWindow >= 1, "AIMD cwnd \(cwnd) \(ctx)")
        v.check(s.timers.rto.isFinite && s.timers.rto > 0, "RTO \(s.timers.rto) \(ctx)")
        if let srtt = s.timers.srtt { v.check(srtt.isFinite && srtt > 0, "SRTT \(srtt) \(ctx)") }

        // No I-frame goes out on a link that was not up at either end of the step.
        if newFrames.contains(where: { $0.frameType == "i" }) {
            v.check(before.state == .connected || s.state == .connected || before.id != s.id,
                    "I-frame transmitted while \(before.state.rawValue) -> \(s.state.rawValue) \(ctx)")
        }

        if let inbound {
            checkResponse(to: inbound, before: before, after: s, frames: newFrames, ctx: ctx, v)
        }
    }

    static func describe(_ frames: [OutboundFrame]) -> String {
        "[" + frames.map { frame in
            let pf = ((frame.controlByte ?? 0) & 0x10) != 0 ? "P/F" : ""
            let role = frame.isCommand == true ? "cmd" : frame.isCommand == false ? "rsp" : "?"
            return "\(frame.displayInfo ?? frame.frameType) \(role) \(pf)"
        }.joined(separator: ", ") + "]"
    }

    /// The response rules the spec states outright.
    private func checkResponse(to inbound: AX25InboundSummary, before: AX25SessionSnapshot,
                               after s: AX25Session, frames: [OutboundFrame], ctx: String,
                               _ v: PropertyViolations) {
        func has(_ name: String, final: Bool? = nil, command: Bool? = nil) -> Bool {
            frames.contains { frame in
                let info = frame.displayInfo ?? ""
                guard info == name || info.hasPrefix(name + "(") else { return false }
                if let final, ((frame.controlByte ?? 0) & 0x10 != 0) != final { return false }
                if let command, frame.isCommand != command { return false }
                return true
            }
        }
        let anyFinalResponse = frames.contains {
            $0.frameType == "s" && $0.isCommand == false && (($0.controlByte ?? 0) & 0x10) != 0
        }
        let priorState: AX25SessionState? = before.exists ? before.state : nil

        // SREJ is left out: the manager treats it as a response, and the
        // rule below is stated for RR, RNR, REJ and I commands.
        let isPollCommand = inbound.pf && inbound.isCommand && inbound.sType != .SREJ
            && (inbound.frameClass == .I || inbound.frameClass == .S)
        if isPollCommand {
            switch priorState {
            case .connected?:
                // §6.2: the next response to an I or S command with P=1 is
                // an RR, RNR or REJ response with F=1. An RR whose N(R) is
                // outside V(A)...V(S) is left out: AXTerm ignores that frame
                // whole, poll included, where AX.25 2.2 would re-establish
                // the link (N(R) error recovery). Reported, not changed; see
                // AX25PropertyFindingsTests.
                let outstanding = (before.vs - before.va + 8) % 8
                let nrValid = inbound.nr.map { ($0 - before.va + 8) % 8 <= outstanding } ?? true
                let ignoredWhole = inbound.sType == .RR && !nrValid
                if s.state == .connected && before.id == s.id && !ignoredWhole {
                    v.check(anyFinalResponse, "P=1 \(inbound.frameClass.rawValue) command in connected state "
                            + "drew no F=1 supervisory response \(ctx); sent \(Self.describe(frames)); "
                            + "before vs=\(before.vs) va=\(before.va) vr=\(before.vr) rx=\(before.receiveBufferKeys)")
                }
            case .connecting?:
                break  // §6.3.1: everything but SABM, DISC, UA and DM is ignored.
            case nil, .disconnected?, .disconnecting?, .error?:
                // §6.3.5 and SDL C4.3: DM with F=1.
                v.check(has("DM", final: true), "P=1 \(inbound.frameClass.rawValue) command with the link "
                        + "\(priorState?.rawValue ?? "absent") drew no DM(F=1) \(ctx)")
            }
        }

        if inbound.uType == .SABM {
            switch priorState {
            case .disconnecting?:
                v.check(has("DM"), "SABM while disconnecting drew no DM \(ctx)")
            default:
                v.check(has("UA"), "SABM with the link \(priorState?.rawValue ?? "absent") drew no UA \(ctx)")
            }
        }
        if inbound.uType == .SABME {
            v.check(has("DM"), "SABME (modulo 128 is not offered) drew no DM \(ctx)")
        }
        if inbound.uType == .DISC {
            switch priorState {
            case .connected?:
                v.check(has("UA"), "DISC on a connected link drew no UA \(ctx)")
            default:
                v.check(has("DM"), "DISC with the link \(priorState?.rawValue ?? "absent") drew no DM \(ctx)")
            }
        }
    }
}
