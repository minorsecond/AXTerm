//
//  AX25InteropHarness.swift
//  AXTermTests
//
//  A simulated channel for interoperability tests: AXTerm's real session
//  manager on one end, a scripted model of another AX.25 stack on the
//  other, digipeaters in between, all driven by AX25VirtualClock.
//
//  Frames cross the channel as bytes. AXTerm's frames are encoded by
//  `OutboundFrame.encodeAX25()`, the encoder the app transmits with, and
//  decoded on the peer side by `WireFrame`, a separate codec written here
//  so the peer never trusts AXTerm's own reading of its bytes. Frames from
//  the peer are encoded by `WireFrame` and decoded by `AX25.decodeFrame`,
//  the decoder the app receives with.
//
//  Nothing here touches a radio, a TNC or the network.
//

import Foundation
import XCTest
@testable import AXTerm

// MARK: - Wire codec (independent of AXTerm's)

/// One address field as it appears on the wire.
nonisolated struct WireAddress: Equatable, CustomStringConvertible {
    var call: String
    var ssid: Int
    /// Bit 7 of the SSID byte: C bit for destination and source, H bit
    /// for a digipeater.
    var bit7: Bool = false

    init(_ text: String, bit7: Bool = false) {
        let parts = text.uppercased().split(separator: "-")
        call = String(parts.first ?? "")
        ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        self.bit7 = bit7
    }

    init(call: String, ssid: Int, bit7: Bool) {
        self.call = call
        self.ssid = ssid
        self.bit7 = bit7
    }

    var display: String { ssid == 0 ? call : "\(call)-\(ssid)" }
    var description: String { display }

    /// Same station, whatever bit 7 says.
    func sameStation(_ other: WireAddress) -> Bool {
        call == other.call && ssid == other.ssid
    }

    var axterm: AX25Address { AX25Address(call: call, ssid: ssid) }
}

/// A decoded AX.25 frame, modulo 8 only.
nonisolated struct WireFrame: CustomStringConvertible {
    enum SType: String { case rr = "RR", rnr = "RNR", rej = "REJ", srej = "SREJ" }
    enum UType: String {
        case sabm = "SABM", sabme = "SABME", disc = "DISC", dm = "DM", ua = "UA"
        case frmr = "FRMR", ui = "UI", xid = "XID", test = "TEST", unknown = "U?"
    }
    enum Kind: Equatable {
        case i(ns: Int, nr: Int, p: Bool)
        case s(SType, nr: Int, pf: Bool)
        case u(UType, pf: Bool)
    }
    /// AX.25 2.0 §2.4.1.2 / 2.2 §6.1.2: command when the destination C bit
    /// is 1 and the source C bit 0, response the other way round. Both
    /// equal is the version 1 encoding, which a 2.x station must not send.
    enum CR { case command, response, legacy }

    var dest: WireAddress
    var src: WireAddress
    var via: [WireAddress]
    var control: UInt8
    var pid: UInt8?
    var info: Data

    var kind: Kind { Self.classify(control) }

    var cr: CR {
        switch (dest.bit7, src.bit7) {
        case (true, false): return .command
        case (false, true): return .response
        default: return .legacy
        }
    }

    var isCommand: Bool { cr == .command }

    /// Every digipeater has repeated it (or there are none).
    var fullyRepeated: Bool { via.allSatisfy(\.bit7) }

    var pf: Bool { control & 0x10 != 0 }

    static func classify(_ c: UInt8) -> Kind {
        if c & 0x01 == 0 {
            return .i(ns: Int((c >> 1) & 7), nr: Int(c >> 5), p: c & 0x10 != 0)
        }
        if c & 0x03 == 0x01 {
            let type: SType
            switch c & 0x0F {
            case 0x01: type = .rr
            case 0x05: type = .rnr
            case 0x09: type = .rej
            default: type = .srej
            }
            return .s(type, nr: Int(c >> 5), pf: c & 0x10 != 0)
        }
        let type: UType
        switch c & ~0x10 {
        case 0x2F: type = .sabm
        case 0x6F: type = .sabme
        case 0x43: type = .disc
        case 0x0F: type = .dm
        case 0x63: type = .ua
        case 0x87: type = .frmr
        case 0x03: type = .ui
        case 0xAF: type = .xid
        case 0xE3: type = .test
        default: type = .unknown
        }
        return .u(type, pf: c & 0x10 != 0)
    }

    static func uControl(_ type: UType, pf: Bool) -> UInt8 {
        let base: UInt8
        switch type {
        case .sabm: base = 0x2F
        case .sabme: base = 0x6F
        case .disc: base = 0x43
        case .dm: base = 0x0F
        case .ua: base = 0x63
        case .frmr: base = 0x87
        case .ui: base = 0x03
        case .xid: base = 0xAF
        case .test: base = 0xE3
        case .unknown: base = 0xFF
        }
        return pf ? base | 0x10 : base
    }

    static func sControl(_ type: SType, nr: Int, pf: Bool) -> UInt8 {
        let base: UInt8
        switch type {
        case .rr: base = 0x01
        case .rnr: base = 0x05
        case .rej: base = 0x09
        case .srej: base = 0x0D
        }
        return base | UInt8((nr & 7) << 5) | (pf ? 0x10 : 0)
    }

    static func iControl(ns: Int, nr: Int, p: Bool) -> UInt8 {
        UInt8((nr & 7) << 5) | (p ? 0x10 : 0) | UInt8((ns & 7) << 1)
    }

    enum DecodeError: Error, CustomStringConvertible {
        case short, badAddress(String), noControl
        var description: String {
            switch self {
            case .short: return "frame too short"
            case .badAddress(let why): return why
            case .noControl: return "no control field"
            }
        }
    }

    static func decode(_ bytes: Data) throws -> WireFrame {
        let b = [UInt8](bytes)
        guard b.count >= 15 else { throw DecodeError.short }
        var addresses: [WireAddress] = []
        var offset = 0
        var last = false
        while !last {
            guard offset + 7 <= b.count else { throw DecodeError.badAddress("address field never ends") }
            guard addresses.count < 10 else { throw DecodeError.badAddress("more than 8 digipeaters") }
            var call = ""
            for i in 0..<6 {
                let byte = b[offset + i]
                guard byte & 1 == 0 else { throw DecodeError.badAddress("extension bit in callsign byte") }
                let ch = byte >> 1
                if ch != 0x20 { call.append(Character(UnicodeScalar(ch))) }
            }
            let ssidByte = b[offset + 6]
            last = ssidByte & 1 != 0
            if addresses.isEmpty && last { throw DecodeError.badAddress("address field ends after destination") }
            addresses.append(WireAddress(call: call, ssid: Int((ssidByte >> 1) & 0x0F), bit7: ssidByte & 0x80 != 0))
            offset += 7
        }
        guard offset < b.count else { throw DecodeError.noControl }
        let control = b[offset]
        offset += 1
        var pid: UInt8?
        let kind = classify(control)
        let carriesPID: Bool
        switch kind {
        case .i: carriesPID = true
        case .u(.ui, _): carriesPID = true
        default: carriesPID = false
        }
        if carriesPID, offset < b.count {
            pid = b[offset]
            offset += 1
        }
        let info = offset < b.count ? Data(b[offset...]) : Data()
        return WireFrame(dest: addresses[0], src: addresses[1], via: Array(addresses.dropFirst(2)),
                         control: control, pid: pid, info: info)
    }

    func encode() -> Data {
        var out = Data()
        func add(_ a: WireAddress, last: Bool) {
            let padded = a.call.padding(toLength: 6, withPad: " ", startingAt: 0)
            for ch in padded.utf8.prefix(6) { out.append(ch << 1) }
            var ssidByte: UInt8 = 0x60 | UInt8((a.ssid & 0x0F) << 1)
            if a.bit7 { ssidByte |= 0x80 }
            if last { ssidByte |= 0x01 }
            out.append(ssidByte)
        }
        add(dest, last: false)
        add(src, last: via.isEmpty)
        for (i, d) in via.enumerated() { add(d, last: i == via.count - 1) }
        out.append(control)
        if let pid { out.append(pid) }
        out.append(info)
        return out
    }

    var description: String {
        let path = via.isEmpty ? "" : " via " + via.map { $0.display + ($0.bit7 ? "*" : "") }.joined(separator: ",")
        let what: String
        switch kind {
        case .i(let ns, let nr, let p): what = "I(\(ns),\(nr))\(p ? " P" : "") \(info.count)B"
        case .s(let t, let nr, let pf): what = "\(t.rawValue)(\(nr))\(pf ? (isCommand ? " P" : " F") : "")"
        case .u(let t, let pf): what = "\(t.rawValue)\(pf ? (isCommand ? " P" : " F") : "")\(info.isEmpty ? "" : " \(info.count)B")"
        }
        let crText = cr == .command ? "C" : (cr == .response ? "R" : "v1")
        return "\(src.display)>\(dest.display)\(path) \(what) [\(crText)]"
    }
}

// MARK: - Channel

@MainActor
protocol InteropNode: AnyObject {
    var nodeName: String { get }
    func hear(_ bytes: Data)
}

/// One delivery the channel is about to make, for drop rules.
struct ChannelDelivery {
    let sender: String
    let receiver: String
    let frame: WireFrame?
    let time: TimeInterval
}

/// A linear chain of stations where each hears only its neighbors, so a
/// digipeated path only works in the order the stations really sit. Every
/// transmission takes airtime (TX delay plus bits at the baud rate), and
/// one station's frames leave strictly one after another.
///
/// Collisions are not modeled. Two stations may transmit at once and both
/// frames arrive; the tests that care about turnaround timing model the
/// delay in the peer instead.
@MainActor
final class InteropChannel {
    let clock: AX25VirtualClock
    var baud: Double = 1200
    var txDelay: Double = 0.25
    var propagation: Double = 0.005

    private(set) var nodes: [InteropNode] = []
    private var busyUntil: [ObjectIdentifier: TimeInterval] = [:]

    /// Return true to lose that one delivery.
    var dropRule: ((ChannelDelivery) -> Bool)?

    /// Every transmission, in order: time it finished, sender, frame.
    private(set) var log: [(time: TimeInterval, sender: String, frame: WireFrame?)] = []

    init(clock: AX25VirtualClock) { self.clock = clock }

    func add(_ node: InteropNode) { nodes.append(node) }

    func airtime(_ bytes: Data) -> Double {
        baud > 0 ? txDelay + Double(bytes.count + 4) * 8 / baud : 0
    }

    /// Puts `bytes` on the air and returns when the transmission ends.
    @discardableResult
    func transmit(_ bytes: Data, from sender: InteropNode) -> TimeInterval {
        let id = ObjectIdentifier(sender)
        let start = max(clock.currentTime, busyUntil[id] ?? 0)
        let end = start + airtime(bytes)
        busyUntil[id] = end
        let frame = try? WireFrame.decode(bytes)
        log.append((end, sender.nodeName, frame))
        guard let index = nodes.firstIndex(where: { $0 === sender }) else { return end }
        for neighbor in [index - 1, index + 1] where neighbor >= 0 && neighbor < nodes.count {
            let receiver = nodes[neighbor]
            let delivery = ChannelDelivery(sender: sender.nodeName, receiver: receiver.nodeName,
                                           frame: frame, time: end)
            if dropRule?(delivery) == true { continue }
            _ = clock.schedule(delay: end + propagation - clock.currentTime) { [weak receiver] in
                receiver?.hear(bytes)
            }
        }
        return end
    }
}

/// A plain AX.25 digipeater: repeats a frame when it is the next
/// unrepeated address in the path, setting its H bit (AX.25 2.0 §2.2.13.3).
@MainActor
final class InteropDigipeater: InteropNode {
    let address: WireAddress
    weak var channel: InteropChannel?
    var nodeName: String { address.display }
    private(set) var repeated = 0

    init(_ call: String) { address = WireAddress(call) }

    func hear(_ bytes: Data) {
        guard var frame = try? WireFrame.decode(bytes),
              let next = frame.via.firstIndex(where: { !$0.bit7 }),
              frame.via[next].sameStation(address) else { return }
        frame.via[next].bit7 = true
        repeated += 1
        channel?.transmit(frame.encode(), from: self)
    }
}

// MARK: - AXTerm on the channel

/// AXTerm's session manager on the channel, fed the way the app feeds it.
///
/// The app hands inbound frames to the manager in
/// `SessionCoordinator.handleIncomingPacket` and its `handleUFrame`,
/// `handleIFrame` and `handleSFrame`. The coordinator owns a manager built
/// on the wall clock, so it cannot run under the virtual clock; `hear`
/// below repeats its dispatch step for step (address check, digipeated
/// copies, the reply path, turnaround stamp, U/I/S routing with the called
/// address, the XID negotiation hooks) and must be kept in step with it. Probe answers and UI/AXDP handling are
/// left out: no scripted peer sends either.
@MainActor
final class AXTermInteropStation: InteropNode {
    let manager: AX25SessionManager
    weak var channel: InteropChannel?
    let nodeName = "AXTerm"

    /// Everything AXTerm put on the channel, with the time it was handed over.
    private(set) var sent: [(time: TimeInterval, frame: OutboundFrame)] = []
    /// Bytes delivered to the application, per peer, in order.
    private(set) var delivered: [String: Data] = [:]
    private let clock: AX25VirtualClock

    init(call: String, clock: AX25VirtualClock, config: AX25SessionConfig) {
        self.clock = clock
        manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        let parts = call.split(separator: "-")
        manager.localCallsign = AX25Address(call: String(parts[0]), ssid: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        manager.defaultConfig = config
        // The persisted XID verdicts would carry one test's peer into the next.
        manager.xidMemory = XIDAnswerMemory(defaults: TestDefaults.make("AX25Interop"))
        manager.onSendFrame = { [weak self] frame in self?.transmit(frame) }
        manager.onDataReceived = { [weak self] session, data in
            self?.delivered[session.remoteAddress.display, default: Data()].append(data)
        }
    }

    /// The most I-frames any session had outstanding when one went out.
    private(set) var maxOutstanding = 0

    func transmit(_ frame: OutboundFrame) {
        sent.append((clock.currentTime, frame))
        if frame.frameType == "i", let id = frame.sessionId,
           let session = manager.sessions.values.first(where: { $0.id == id }) {
            maxOutstanding = max(maxOutstanding, session.outstandingCount)
        }
        channel?.transmit(frame.encodeAX25(), from: self)
    }

    func transmit(_ frames: [OutboundFrame]) { frames.forEach(transmit) }

    // MARK: Operator actions, as the app performs them

    func connect(to peer: String, via: [String] = []) {
        if let frame = manager.connect(to: Self.address(peer), path: DigiPath.from(via)) {
            transmit(frame)
        }
    }

    func send(_ text: String, to peer: String, via: [String] = []) {
        send(Data(text.utf8), to: peer, via: via)
    }

    func send(_ data: Data, to peer: String, via: [String] = []) {
        transmit(manager.sendData(data, to: Self.address(peer), path: DigiPath.from(via)))
    }

    func disconnect(from peer: String) {
        guard let session = session(with: peer), let disc = manager.disconnect(session: session) else { return }
        transmit(disc)
    }

    func session(with peer: String) -> AX25Session? {
        let address = Self.address(peer)
        return manager.sessions.values.first { $0.remoteAddress.display == address.display && $0.state != .disconnected }
            ?? manager.sessions.values.first { $0.remoteAddress.display == address.display }
    }

    static func address(_ text: String) -> AX25Address {
        let parts = text.uppercased().split(separator: "-")
        return AX25Address(call: String(parts[0]), ssid: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    }

    // MARK: Inbound, mirroring SessionCoordinator

    func hear(_ bytes: Data) {
        guard let decoded = AX25.decodeFrame(ax25: bytes) else { return }
        let packet = Packet(from: decoded.from, to: decoded.to, via: decoded.via,
                            frameType: decoded.frameType, control: decoded.control,
                            controlByte1: decoded.controlByte1, pid: decoded.pid,
                            info: decoded.info, rawAx25: bytes, radioID: .primary)
        guard let from = packet.from, let to = packet.to else { return }
        guard manager.answers(to) else { return }
        guard packet.isFullyDigipeated else { return }

        let radio = RadioID.primary
        let path = DigiPath.replyPath(heardVia: packet.via)
        manager.noteFrameHeard(from: from, path: path, radio: radio)
        let control = AX25ControlFieldDecoder.decode(control: packet.control, controlByte1: packet.controlByte1)

        switch control.frameClass {
        case .U:
            guard let uType = control.uType else { return }
            switch uType {
            case .UA:
                manager.handleInboundUA(from: from, path: path, radio: radio)
            case .DM:
                if manager.handleInboundDMDuringNegotiation(from: from, radio: radio) { break }
                manager.handleInboundDM(from: from, path: path, radio: radio)
            case .FRMR:
                manager.handleInboundFRMRDuringNegotiation(from: from, radio: radio)
                manager.handleInboundFRMR(from: from, path: path, radio: radio)
            case .XID:
                transmit(manager.handleInboundXID(from: from, to: to, path: path, radio: radio,
                                                  info: packet.info, isCommand: packet.isCommand,
                                                  pf: (packet.control & 0x10) != 0))
            case .DISC:
                if let response = manager.handleInboundDISC(from: from, to: to, path: path, radio: radio,
                                                            pf: (packet.control & 0x10) != 0) {
                    transmit(response)
                }
            case .SABM, .SABME:
                if let response = manager.handleInboundSABM(from: from, to: to, path: path, radio: radio,
                                                            extended: uType == .SABME,
                                                            pf: (packet.control & 0x10) != 0) {
                    transmit(response)
                }
            default:
                break
            }
        case .I:
            if let response = manager.handleInboundIFrame(from: from, to: to, path: path, radio: radio,
                                                          ns: control.ns ?? 0, nr: control.nr ?? 0,
                                                          pf: (control.pf ?? 0) == 1,
                                                          payload: packet.info, pid: packet.pid) {
                transmit(response)
            }
        case .S:
            let nr = control.nr ?? 0
            let pf = (control.pf ?? 0) == 1
            switch control.sType {
            case .RR:
                transmit(manager.handleInboundRRFrames(from: from, to: to, path: path, radio: radio, nr: nr,
                                                       pf: pf, isCommand: packet.isCommand))
            case .REJ:
                transmit(manager.handleInboundREJ(from: from, to: to, path: path, radio: radio, nr: nr,
                                                  pf: pf, isCommand: packet.isCommand))
            case .RNR:
                transmit(manager.handleInboundRNR(from: from, to: to, path: path, radio: radio, nr: nr,
                                                  pf: pf, isCommand: packet.isCommand))
            case .SREJ:
                transmit(manager.handleInboundSREJ(from: from, path: path, radio: radio, nr: nr, pf: pf))
            case .none:
                break
            }
        case .unknown:
            break
        }
    }
}
