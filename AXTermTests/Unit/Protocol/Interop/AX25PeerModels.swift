//
//  AX25PeerModels.swift
//  AXTermTests
//
//  Scripted models of AX.25 stacks found on the air, for interoperability
//  tests. Each is one data-link engine (`ScriptedAX25Peer`) run with a
//  profile of the behavior that stack documents.
//
//  Sources, and how far each is trusted:
//
//  - AX.25 Link Access Protocol, version 2.0 (ARRL/TAPR, October 1984):
//    the 2.0 frame set (no SREJ, no XID, no SABME), C/R bits in the
//    destination and source SSID bytes (§2.4.1.2), a P=1 command answered
//    by a response with F=1, N(S) sequence error answered with REJ and the
//    out-of-sequence frame discarded, DM to a command with P=1 in the
//    disconnected state.
//  - AX.25 Link Access Protocol, version 2.2 (TAPR, 1998): XID (§4.3.3.7,
//    §6.3.2), SREJ (§4.3.2.4, §6.4.4.2), the T1/T3 timer-recovery
//    procedure (§6.7.1) and the SDL in Annex C.
//  - TAPR TNC-2 command set (FRACK, RESPTIME, MAXFRAME, PACLEN, RETRY,
//    CHECK), which Kantronics KPC firmware shares. FRACK is fixed and the
//    wait is FRACK x (2m + 1) for m digipeaters. RESPTIME holds an ack so
//    several frames can be answered at once. Defaults used: FRACK 3 s,
//    RESPTIME 5 (500 ms), MAXFRAME 4, PACLEN 128, RETRY 10, CHECK 30
//    (300 s). The manuals say nothing about how the firmware times out or
//    whether RESPTIME also delays an F=1 answer; the model answers polls
//    at once and uses the 2.0 enquiry for timer recovery.
//  - Linux kernel AX.25 (include/net/ax25.h defaults): T1 10 s, T2 3 s,
//    T3 300 s, N2 10, window 2, paclen 256, linear backoff
//    (ax25_calculate_t1: T1 = (2 + 2 x retries) x rtt, rtt starting at
//    T1 / 2 and smoothed as (9 x rtt + measured) / 10 on clean acks).
//    ax25_in.c answers a frame for which it holds no link, other than SABM
//    or a DM, with DM; that is also what an XID gets, since the kernel does
//    not implement XID. Any N(S) other than V(R), duplicates included,
//    draws REJ. The reply path is the received one reversed
//    (ax25_digi_invert).
//  - Direwolf (ax25_link.c, xid.c; user guide "AX.25 connected mode"):
//    a 2.2 data link written from the 2.2 SDL. Defaults FRACK 4, RETRY 10,
//    PACLEN 256, MAXFRAME 4. It calls with SABME and falls back to SABM
//    when answered DM. XID with SREJ, N1 and k in the xid.c layout AXTerm
//    also uses. Whether it answers an XID that arrives before any link
//    exists, and whether it uses SREJ under modulo 8, depends on version
//    and is not stated in its documentation; both are profile switches.
//  - BPQ32/LinBPQ: the L2 values are the ones this repo's TestRig LinBPQ
//    runs (TestRig/linbpq/bpq32.cfg: FRACK 4000 ms, RESPTIME 1000 ms,
//    RETRIES 8, MAXFRAME 4, PACLEN 128). The DM answer to XID and the
//    greeting, prompt and relay text are the field captures quoted in
//    AXTerm's own code (AX25SessionManager.handleInboundDMDuringNegotiation,
//    NodeCapability.swift, NetRomRelayPlan.swift, ManualRelayDetector).
//  - The DRLNOD-style DM after frequent polls is only known from AXTerm's
//    field notes (AX25SessionManager.sendData: "DRLNOD DMs sessions that
//    poll on every idle line"). The threshold here is an assumption and is
//    named as one.
//

import Foundation
import XCTest
@testable import AXTerm

// MARK: - Profiles

nonisolated struct PeerProfile {
    enum Version { case v20, v22 }

    /// What the station does with an XID command.
    enum XIDBehavior {
        /// AX.25 2.2 §6.3.2: a station that does not implement XID answers FRMR.
        case frmr
        /// Answers as for any frame it holds no link for (Linux, BPQ).
        case dm
        case ignore
        /// Negotiates: the response selects SREJ when both offer it, and
        /// advertises this station's N1 and k.
        case respond(srej: Bool)
    }

    enum T1Policy {
        /// TNC-2 FRACK: fixed, FRACK x (2m + 1) seconds for m digipeaters.
        case frack(Double)
        /// Linux: (2 + 2 x retries) x rtt, rtt from T1 / 2, smoothed on
        /// clean acks. No digipeater scaling.
        case linuxLinear(t1: Double)
        /// AX.25 2.2 SDL "select T1 value": SRT smoothed by 1/8 on clean
        /// acks, T1 = 2 x SRT, doubled per retry. Seeded from
        /// FRACK x (2m + 1).
        case sdl(frack: Double)
    }

    var name: String
    var version: Version
    var xid: XIDBehavior
    /// Direwolf calls with SABME and falls back to SABM on DM.
    var callsWithSABME = false
    var t1: T1Policy
    /// RESPTIME or T2: how long an ack for unpolled frames is held.
    var ackDelay: Double
    var t3: Double
    var retries: Int
    var maxframe: Int
    var paclen: Int
    /// Largest I field it accepts (its N1 as a receiver).
    var maxInfoAccepted = 256

    // Quirks
    /// False for a station that answers a poll with F=0.
    var setsFinal = true
    /// Hold acks until this many unacknowledged frames have arrived. A
    /// poll is still answered.
    var acksEvery: Int?
    /// Extra time before each transmission (slow TX/RX turnaround).
    var turnaround: Double = 0
    /// DM a link after `count` polls on idle lines inside `window` seconds:
    /// P=1 I-frames that arrive `idleGap` seconds or more after the last
    /// frame from the correspondent. AXTerm's notes say only that DRLNOD
    /// DMs "sessions that poll on every idle line"; the numbers are
    /// assumptions.
    var dmAfterPolls: (count: Int, window: Double, idleGap: Double)?
    /// Hold out-of-sequence frames and SREJ the gap (when SREJ negotiated).
    var selectiveReject = false
    /// Let SREJ run on a modulo 8 link once negotiated.
    var srejOnModulo8 = true
    /// The frame that fills the window carries P=1.
    var pollsWhenWindowFull = false
    /// N1 and k this station advertises in XID, when not its PACLEN and
    /// MAXFRAME.
    var xidN1: Int?
    var xidK: Int?
    /// Linux ax25_in.c: any frame for which no link exists, other than SABM
    /// or a DM, is answered with DM, whatever its P bit.
    var dmToAnyFrameWithoutLink = false

    // MARK: Stacks

    /// TAPR TNC-2 (and KPC with AX25L2V2 on) as a 2.0 station.
    static func tnc2(xid: XIDBehavior = .frmr, maxframe: Int = 4, paclen: Int = 128) -> PeerProfile {
        PeerProfile(name: "TNC-2", version: .v20, xid: xid, t1: .frack(3), ackDelay: 0.5,
                    t3: 300, retries: 10, maxframe: maxframe, paclen: paclen)
    }

    static func linux() -> PeerProfile {
        var p = PeerProfile(name: "Linux AX.25", version: .v22, xid: .dm, t1: .linuxLinear(t1: 10), ackDelay: 3,
                            t3: 300, retries: 10, maxframe: 2, paclen: 256)
        p.dmToAnyFrameWithoutLink = true
        return p
    }

    static func direwolf(answersXID: Bool = true, srejOnModulo8: Bool = true) -> PeerProfile {
        // Direwolf has no fixed T2: it sends the ack once it gets the
        // channel. The 1 s here stands in for that and is not a documented
        // value. T3 300 s is assumed, as for the other stacks.
        var p = PeerProfile(name: "Direwolf", version: .v22, xid: answersXID ? .respond(srej: true) : .dm,
                            t1: .sdl(frack: 4), ackDelay: 1, t3: 300, retries: 10, maxframe: 4, paclen: 256)
        p.callsWithSABME = true
        p.selectiveReject = true
        p.srejOnModulo8 = srejOnModulo8
        return p
    }

    /// The TestRig LinBPQ's L2 values. How BPQ scales FRACK for
    /// digipeaters and its idle poll interval are not documented here; the
    /// TNC-2 rule and 300 s are assumed.
    static func bpq() -> PeerProfile {
        PeerProfile(name: "LinBPQ", version: .v20, xid: .dm, t1: .frack(4), ackDelay: 1,
                    t3: 300, retries: 8, maxframe: 4, paclen: 128)
    }
}

// MARK: - Engine

/// A modulo 8 AX.25 data link driven by the virtual clock.
@MainActor
final class ScriptedAX25Peer: InteropNode {
    enum LinkState: Equatable {
        case disconnected, awaitingConnection, connected, timerRecovery, awaitingRelease
    }

    let profile: PeerProfile
    let address: WireAddress
    weak var channel: InteropChannel?
    private let clock: AX25VirtualClock
    var nodeName: String { address.display }

    // Link state
    private(set) var state: LinkState = .disconnected
    private(set) var remote: WireAddress?
    /// The address the far end called, which every response comes from.
    private(set) var localForLink: WireAddress
    private(set) var replyVia: [WireAddress] = []
    private(set) var vs = 0, vr = 0, va = 0
    private var sendQueue: [Data] = []
    private var sentFrames: [Int: Data] = [:]
    private var rejectException = false
    private var srejRequested: Set<Int> = []
    private var oosBuffer: [Int: Data] = [:]
    private var ackPending = false
    private var unackedReceived = 0
    private(set) var peerBusy = false
    private var rc = 0
    private(set) var srejEnabled = false
    /// Paclen and window toward the far end, lowered to what it advertised
    /// in XID (2.2 §6.3.2: N1 and k are notifications of what it accepts).
    private(set) var sendPaclen: Int
    private(set) var sendWindow: Int
    /// What this station advertised in XID, which the far end must honor.
    private(set) var advertisedN1: Int?
    private(set) var advertisedK: Int?
    /// The N(R) in the last frame this station sent.
    private var lastNRSent = 0
    private var usingSABME = false
    private var rtt: Double = 0
    private var t1Started: TimeInterval?
    private var t1Value: Double = 0
    private var t1Task: AnyCancellableTask?
    private var t1Deferred = false
    private var lastTxEnd: TimeInterval = 0
    private var t2Task: AnyCancellableTask?
    private var t3Task: AnyCancellableTask?
    private var pollTimes: [TimeInterval] = []
    private var lastHeardFromRemote: TimeInterval = -.infinity
    private var gapSinceLastHeard: TimeInterval = .infinity
    private var txQueue: [Data] = []
    private var txFlushScheduled = false

    /// When true, I-frames are discarded and answered RNR (own receiver busy).
    var receiverBusy = false {
        didSet {
            // Leaving the busy condition is announced with RR (2.2 SDL).
            if oldValue && !receiverBusy && (state == .connected || state == .timerRecovery) {
                sendS(.rr, pf: false, command: false)
            }
        }
    }
    /// Accept inbound SABM.
    var acceptsConnections = true

    // Observations
    private(set) var delivered = Data()
    private(set) var violations: [String] = []
    private(set) var heard: [(time: TimeInterval, frame: WireFrame)] = []
    private(set) var transmitted: [(time: TimeInterval, frame: WireFrame)] = []
    private(set) var linkFailures = 0
    private(set) var connects = 0
    private(set) var linkResets = 0
    private(set) var disconnects = 0
    private(set) var dmForPolls = 0
    /// Frames from a station other than the one this link is with.
    private(set) var strayFrames = 0
    /// Lines (CR-terminated) received, for application models.
    var onLine: ((String) -> Void)?
    var onConnected: (() -> Void)?
    private var lineBuffer = ""
    private var pendingLines: [String] = []

    init(_ call: String, profile: PeerProfile, clock: AX25VirtualClock) {
        address = WireAddress(call)
        localForLink = address
        self.profile = profile
        self.clock = clock
        sendPaclen = profile.paclen
        sendWindow = profile.maxframe
    }

    var outstanding: Int { (vs - va + 8) % 8 }
    var deliveredText: String { String(decoding: delivered, as: UTF8.self) }
    var isConnected: Bool { state == .connected || state == .timerRecovery }

    // MARK: Operator actions

    func connect(to peer: String, via: [String] = [], sabme: Bool? = nil) {
        remote = WireAddress(peer)
        localForLink = address
        replyVia = via.map { WireAddress($0) }
        resetLink()
        rc = 0
        usingSABME = sabme ?? profile.callsWithSABME
        state = .awaitingConnection
        sendU(usingSABME ? .sabme : .sabm, pf: true, command: true)
        startT1()
    }

    /// Send an XID command before calling, as a 2.2 station may (§6.3.2).
    func negotiate(with peer: String, via: [String] = []) {
        var mine = AX25XIDParameters()
        if case .respond(let srej) = profile.xid { mine.supportsSREJ = srej && profile.srejOnModulo8 }
        mine.iFieldLengthRx = profile.xidN1 ?? profile.paclen
        mine.windowSizeRx = profile.xidK ?? profile.maxframe
        advertisedN1 = mine.iFieldLengthRx
        advertisedK = mine.windowSizeRx
        let frame = WireFrame(dest: WireAddress(call: WireAddress(peer).call, ssid: WireAddress(peer).ssid, bit7: true),
                              src: WireAddress(call: address.call, ssid: address.ssid, bit7: false),
                              via: via.map { WireAddress($0) }, control: WireFrame.uControl(.xid, pf: true),
                              pid: nil, info: mine.encoded(isCommand: true))
        enqueue(frame)
    }

    func send(_ text: String) { send(Data(text.utf8)) }

    func send(_ data: Data) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + sendPaclen, data.count)
            sendQueue.append(data.subdata(in: offset..<end))
            offset = end
        }
        pump()
    }

    func disconnect() {
        guard isConnected else { return }
        sendQueue.removeAll()
        state = .awaitingRelease
        rc = 0
        stopT3()
        sendU(.disc, pf: true, command: true)
        startT1()
    }

    /// Forget the link without telling anyone, as after a restart.
    func forgetLink() {
        stopT1(); stopT2(); stopT3()
        state = .disconnected
        resetLink()
    }

    /// Send FRMR on the live link (as if AXTerm had sent something this
    /// station rejects) and wait for the link to be reset.
    func injectFRMR() {
        guard let remote else { return }
        var frmr = WireFrame(dest: remote, src: localForLink, via: replyVia,
                             control: WireFrame.uControl(.frmr, pf: false), pid: nil,
                             info: Data([0x0D, UInt8((vr << 5) | (vs << 1)), 0x01]))
        frmr.dest.bit7 = false
        frmr.src.bit7 = true
        enqueue(frmr)
        stopT1(); stopT2(); stopT3()
        state = .disconnected
    }

    /// A link held at both ends for tests that start mid-session: as if
    /// SABM/UA had already been exchanged.
    func assumeConnected(to peer: String, via: [String]) {
        remote = WireAddress(peer)
        localForLink = address
        replyVia = via.map { WireAddress($0) }
        resetLink()
        state = .connected
        startT3()
    }

    // MARK: Receive

    func hear(_ bytes: Data) {
        let frame: WireFrame
        do { frame = try WireFrame.decode(bytes) } catch {
            violations.append("undecodable frame: \(error)")
            return
        }
        guard frame.dest.sameStation(address) || (frame.dest.sameStation(localForLink)) else { return }
        guard frame.fullyRepeated else { return }
        heard.append((clock.currentTime, frame))
        check(frame)

        // A station holding a link matches frames to it by both addresses.
        // Anything else is from a station it has no link with.
        if state != .disconnected, let remote,
           !(frame.src.sameStation(remote) && frame.dest.sameStation(localForLink)) {
            stray(frame)
            return
        }
        gapSinceLastHeard = clock.currentTime - lastHeardFromRemote
        lastHeardFromRemote = clock.currentTime

        switch frame.kind {
        case .u(let type, let pf):
            handleU(frame, type: type, pf: pf)
        case .s(let type, let nr, let pf):
            handleS(frame, type: type, nr: nr, pf: pf)
        case .i(let ns, let nr, let p):
            handleI(frame, ns: ns, nr: nr, p: p)
        }
        // Lines go to the application once the frame is fully handled, so
        // its reply can carry the acknowledgment.
        let lines = pendingLines
        pendingLines.removeAll()
        lines.forEach { onLine?($0) }
    }

    /// A frame from a station this one holds no link with, while it holds
    /// a link with someone else: a single-link station answers a connect or
    /// a poll with DM and ignores the rest.
    private func stray(_ f: WireFrame) {
        strayFrames += 1
        switch f.kind {
        case .u(.sabm, let pf), .u(.sabme, let pf), .u(.disc, let pf):
            sendU(.dm, pf: pf, command: false, to: f)
        case .i(_, _, true), .s(_, _, true) where f.isCommand:
            sendU(.dm, pf: true, command: false, to: f)
        default:
            break
        }
    }

    /// What this station's spec version allows a 2.x correspondent to send.
    private func check(_ f: WireFrame) {
        let v20 = profile.version == .v20
        if f.cr == .legacy { violations.append("version 1 C/R bits: \(f)") }
        switch f.kind {
        case .i:
            if !f.isCommand { violations.append("I frame sent as a response (2.2 Annex C error S): \(f)") }
            if f.pid == nil { violations.append("I frame without PID: \(f)") }
            if f.info.count > profile.maxInfoAccepted { violations.append("I field \(f.info.count) > N1 \(profile.maxInfoAccepted): \(f)") }
            if let n1 = advertisedN1, f.info.count > n1 {
                violations.append("I field \(f.info.count) > the N1 \(n1) advertised in XID: \(f)")
            }
            // A sender holds at most k frames past our last N(R); a resend of
            // an older frame sits up to k behind it instead.
            if let k = advertisedK, case .i(let ns, _, _) = f.kind,
               case let d = (ns - lastNRSent + 8) % 8, d >= k, d < 8 - k,
               state == .connected || state == .timerRecovery {
                violations.append("N(S)=\(ns) beyond the k \(k) advertised in XID (last N(R) sent \(lastNRSent)): \(f)")
            }
        case .s(let type, _, _):
            if type == .srej && (v20 || !srejEnabled) {
                violations.append("SREJ without negotiation (\(profile.name) \(v20 ? "2.0" : "2.2")): \(f)")
            }
            if !f.info.isEmpty { violations.append("S frame with information field: \(f)") }
        case .u(let type, _):
            switch type {
            case .sabme:
                violations.append("SABME sent; AXTerm is modulo 8 only: \(f)")
            case .xid:
                // A 2.0 station is allowed to receive one: §6.3.2 expects it
                // to answer FRMR. What it must carry is checked below.
                if f.info.isEmpty {
                    violations.append("XID without an information field (2.2 §4.3.3.7 requires FI/GI and parameters): \(f)")
                } else if AX25XIDParameters.parse(f.info) == nil {
                    violations.append("XID information field does not parse: \(f)")
                }
            case .sabm, .disc:
                if !f.isCommand { violations.append("\(type.rawValue) sent as a response: \(f)") }
            case .ua, .dm, .frmr:
                if f.isCommand { violations.append("\(type.rawValue) sent as a command: \(f)") }
            case .ui, .test:
                break
            case .unknown:
                violations.append("unknown U frame: \(f)")
            }
            if !f.info.isEmpty, ![.xid, .ui, .test, .frmr].contains(type) {
                violations.append("\(type.rawValue) with information field: \(f)")
            }
        }
    }

    private func handleU(_ f: WireFrame, type: WireFrame.UType, pf: Bool) {
        switch type {
        case .sabm:
            guard acceptsConnections else { sendU(.dm, pf: pf, command: false, to: f); return }
            switch state {
            case .disconnected, .awaitingConnection, .connected, .timerRecovery:
                let reset = state == .connected || state == .timerRecovery
                bind(to: f)
                sendU(.ua, pf: pf, command: false)
                stopT1()
                resetLink()
                rc = 0
                state = .connected
                startT3()
                if reset { linkResets += 1 } else { connects += 1 }
                onConnected?()
            case .awaitingRelease:
                sendU(.dm, pf: pf, command: false)
            }
        case .sabme:
            sendU(.dm, pf: pf, command: false, to: f)
        case .disc:
            switch state {
            case .connected, .timerRecovery:
                sendU(.ua, pf: pf, command: false)
                enterDisconnected()
            case .awaitingRelease:
                sendU(.ua, pf: pf, command: false)
            default:
                sendU(.dm, pf: pf, command: false, to: f)
            }
        case .ua:
            switch state {
            case .awaitingConnection:
                stopT1()
                rc = 0
                state = .connected
                connects += 1
                startT3()
                onConnected?()
                pump()
            case .awaitingRelease:
                stopT1()
                enterDisconnected()
            default:
                break
            }
        case .dm:
            switch state {
            case .awaitingConnection where usingSABME:
                // Direwolf: DM to SABME means a 2.0 station; try SABM.
                usingSABME = false
                rc = 0
                sendU(.sabm, pf: true, command: true)
                startT1()
            case .awaitingConnection, .connected, .timerRecovery, .awaitingRelease:
                stopT1()
                enterDisconnected()
            case .disconnected:
                break
            }
        case .frmr:
            violations.append("FRMR from AXTerm: \(f)")
        case .xid:
            handleXID(f, pf: pf)
        case .ui, .test:
            break
        case .unknown:
            if f.isCommand && pf { sendU(state == .disconnected ? .dm : .frmr, pf: true, command: false, to: f) }
        }
    }

    private func handleXID(_ f: WireFrame, pf: Bool) {
        guard f.isCommand else {
            if let params = AX25XIDParameters.parse(f.info) {
                srejEnabled = params.supportsSREJ && profile.srejOnModulo8
                adopt(params)
            }
            return
        }
        switch profile.xid {
        case .frmr:
            // FRMR info: rejected control, V(R)/C-R/V(S), and W (undefined control).
            var frmr = WireFrame(dest: f.src, src: f.dest, via: reversed(f.via), control: WireFrame.uControl(.frmr, pf: pf),
                                 pid: nil, info: Data([f.control, UInt8((vr << 5) | (vs << 1)), 0x01]))
            frmr.dest.bit7 = false
            frmr.src.bit7 = true
            enqueue(frmr)
        case .dm:
            sendU(.dm, pf: pf, command: false, to: f)
        case .ignore:
            break
        case .respond(let offerSREJ):
            let offer = AX25XIDParameters.parse(f.info)
            var mine = AX25XIDParameters()
            mine.supportsSREJ = offerSREJ && (offer?.supportsSREJ ?? false) && profile.srejOnModulo8
            mine.iFieldLengthRx = profile.xidN1 ?? profile.paclen
            mine.windowSizeRx = profile.xidK ?? profile.maxframe
            advertisedN1 = mine.iFieldLengthRx
            advertisedK = mine.windowSizeRx
            srejEnabled = mine.supportsSREJ
            if let offer { adopt(offer) }
            var xid = WireFrame(dest: f.src, src: f.dest, via: reversed(f.via), control: WireFrame.uControl(.xid, pf: pf),
                                pid: nil, info: mine.encoded(isCommand: false))
            xid.dest.bit7 = false
            xid.src.bit7 = true
            enqueue(xid)
        }
    }

    private func adopt(_ params: AX25XIDParameters) {
        if let n1 = params.iFieldLengthRx { sendPaclen = min(profile.paclen, n1) }
        if let k = params.windowSizeRx { sendWindow = min(profile.maxframe, k) }
    }

    private func handleS(_ f: WireFrame, type: WireFrame.SType, nr: Int, pf: Bool) {
        guard isConnected else {
            if state == .disconnected, profile.dmToAnyFrameWithoutLink { sendU(.dm, pf: pf, command: false, to: f); return }
            if state == .disconnected, f.isCommand, pf { sendU(.dm, pf: true, command: false, to: f) }
            if state == .awaitingRelease, f.isCommand, pf { sendU(.dm, pf: true, command: false) }
            return
        }
        if type == .srej && (profile.version == .v20 || !srejEnabled) {
            // 2.0 §2.3.4.3: a control field not implemented draws FRMR (W).
            sendU(.frmr, pf: pf, command: false)
            return
        }
        if f.isCommand && pf { enquiryResponse() }
        guard validNR(nr) else {
            violations.append("N(R)=\(nr) outside V(A)=\(va)..V(S)=\(vs): \(f)")
            return
        }
        switch type {
        case .rr: peerBusy = false
        case .rnr: peerBusy = true
        case .rej: peerBusy = false
        case .srej: break
        }

        if state == .timerRecovery {
            acknowledge(upTo: nr, clean: false)
            if !f.isCommand && pf {
                // Answer to our enquiry: leave timer recovery and resend from N(R).
                stopT1()
                rc = 0
                state = .connected
                if va != vs { retransmit(from: va) } else { startT3() }
                pump()
            } else if type == .rej {
                retransmit(from: nr)
            }
            return
        }

        switch type {
        case .rr, .rnr:
            acknowledge(upTo: nr, clean: true)
            if type == .rnr, outstanding > 0 || !sendQueue.isEmpty { if !t1Running { startT1() } }
        case .rej:
            acknowledge(upTo: nr, clean: false)
            if va != vs { retransmit(from: nr) }
        case .srej:
            if pf { acknowledge(upTo: nr, clean: false) }
            if let info = sentFrames[nr] {
                transmitI(ns: nr, info: info, p: false)
                startT1()
            }
        }
        pump()
    }

    private func handleI(_ f: WireFrame, ns: Int, nr: Int, p: Bool) {
        guard isConnected else {
            if state == .disconnected && (p || profile.dmToAnyFrameWithoutLink) { sendU(.dm, pf: p, command: false, to: f) }
            if state == .awaitingRelease && p { sendU(.dm, pf: true, command: false) }
            return
        }
        if p, let quirk = profile.dmAfterPolls, gapSinceLastHeard >= quirk.idleGap {
            let now = clock.currentTime
            pollTimes.append(now)
            pollTimes = pollTimes.filter { now - $0 <= quirk.window }
            if pollTimes.count >= quirk.count {
                dmForPolls += 1
                sendU(.dm, pf: true, command: false)
                enterDisconnected()
                return
            }
        }
        if validNR(nr) {
            acknowledge(upTo: nr, clean: state == .connected)
        } else {
            violations.append("N(R)=\(nr) outside V(A)=\(va)..V(S)=\(vs): \(f)")
        }
        if receiverBusy {
            sendS(.rnr, pf: p, command: false)
            return
        }
        if ns == vr {
            rejectException = false
            accept(f.info)
            srejRequested.remove(ns)
            if profile.selectiveReject && srejEnabled {
                while let next = oosBuffer.removeValue(forKey: vr) { accept(next) }
                if !oosBuffer.isEmpty, !srejRequested.contains(vr) {
                    srejRequested.insert(vr)
                    sendS(.srej, pf: false, command: false)
                }
            }
            if p {
                enquiryResponse()
            } else {
                ackPending = true
                unackedReceived += 1
                if let every = profile.acksEvery {
                    if unackedReceived >= every { sendAck() }
                } else if t2Task == nil {
                    startT2()
                }
            }
            if state == .connected { pump() }
        } else if profile.selectiveReject && srejEnabled && (ns - vr + 8) % 8 < 4 {
            oosBuffer[ns] = f.info
            if !srejRequested.contains(vr) {
                srejRequested.insert(vr)
                sendS(.srej, pf: p, command: false)
            } else if p {
                enquiryResponse()
            }
        } else {
            // 2.0/2.2: N(S) sequence error. Discard; REJ once per exception.
            if !rejectException {
                rejectException = true
                ackPending = false
                stopT2()
                sendS(.rej, pf: p, command: false)
            } else if p {
                enquiryResponse()
            }
        }
    }

    private func accept(_ info: Data) {
        vr = (vr + 1) % 8
        delivered.append(info)
        lineBuffer += String(decoding: info, as: UTF8.self)
        while let cr = lineBuffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let line = String(lineBuffer[..<cr])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: cr)...])
            if !line.isEmpty { pendingLines.append(line) }
        }
    }

    // MARK: Send side

    private func pump() {
        guard state == .connected, !peerBusy else { return }
        while outstanding < sendWindow, !sendQueue.isEmpty {
            let info = sendQueue.removeFirst()
            let ns = vs
            sentFrames[ns] = info
            vs = (vs + 1) % 8
            let p = profile.pollsWhenWindowFull && outstanding == sendWindow
            transmitI(ns: ns, info: info, p: p)
            if !t1Running { startT1() }
            stopT3()
        }
    }

    private func transmitI(ns: Int, info: Data, p: Bool) {
        ackPending = false
        unackedReceived = 0
        stopT2()
        let frame = WireFrame(dest: WireAddress(call: remote!.call, ssid: remote!.ssid, bit7: true),
                              src: WireAddress(call: localForLink.call, ssid: localForLink.ssid, bit7: false),
                              via: replyVia, control: WireFrame.iControl(ns: ns, nr: vr, p: p),
                              pid: 0xF0, info: info)
        lastNRSent = vr
        enqueue(frame)
    }

    private func retransmit(from nr: Int) {
        var ns = nr
        while ns != vs {
            if let info = sentFrames[ns] { transmitI(ns: ns, info: info, p: false) }
            ns = (ns + 1) % 8
        }
        startT1()
    }

    private func acknowledge(upTo nr: Int, clean: Bool) {
        guard nr != va else { return }
        if clean, rc == 0, let started = t1Started, clock.currentTime > started {
            measured(clock.currentTime - started)
        }
        while va != nr {
            sentFrames[va] = nil
            va = (va + 1) % 8
        }
        if va == vs {
            stopT1()
            if state == .connected { startT3() }
        } else if state == .connected {
            startT1()
        }
    }

    private func validNR(_ nr: Int) -> Bool {
        let span = (vs - va + 8) % 8
        return (nr - va + 8) % 8 <= span
    }

    private func enquiryResponse() {
        ackPending = false
        unackedReceived = 0
        stopT2()
        sendS(receiverBusy ? .rnr : .rr, pf: profile.setsFinal, command: false)
    }

    private func sendAck() {
        ackPending = false
        unackedReceived = 0
        stopT2()
        sendS(receiverBusy ? .rnr : .rr, pf: false, command: false)
    }

    // MARK: Timers

    private func currentT1() -> Double {
        let hops = Double(2 * replyVia.count + 1)
        switch profile.t1 {
        case .frack(let frack):
            return frack * hops
        case .linuxLinear(let t1):
            if rtt == 0 { rtt = t1 / 2 }
            return Double(2 + 2 * rc) * rtt
        case .sdl(let frack):
            if rtt == 0 { rtt = frack * hops / 2 }
            return rc == 0 ? 2 * rtt : pow(2, Double(rc + 1)) * rtt
        }
    }

    private func measured(_ sample: Double) {
        switch profile.t1 {
        case .frack:
            break
        case .linuxLinear:
            rtt = min(30, max(0.01, (9 * rtt + sample) / 10))
        case .sdl:
            rtt = 7 * rtt / 8 + sample / 8
        }
    }

    /// T1 runs from the end of this station's transmission, the way a TNC
    /// times it, not from when the frame was queued.
    private func startT1() {
        t1Task?.cancel()
        t1Task = nil
        t1Value = currentT1()
        if txFlushScheduled {
            t1Deferred = true
            t1Started = nil
            return
        }
        armT1(from: max(clock.currentTime, lastTxEnd))
    }

    private func armT1(from begin: TimeInterval) {
        t1Deferred = false
        t1Started = begin
        t1Task = clock.schedule(delay: begin - clock.currentTime + t1Value) { [weak self] in self?.t1Expired() }
    }

    private var t1Running: Bool { t1Task != nil || t1Deferred }

    private func stopT1() {
        t1Task?.cancel()
        t1Task = nil
        t1Deferred = false
        t1Started = nil
    }

    private func startT2() {
        t2Task?.cancel()
        t2Task = clock.schedule(delay: profile.ackDelay) { [weak self] in
            guard let self else { return }
            self.t2Task = nil
            if self.ackPending, self.isConnected { self.sendAck() }
        }
    }

    private func stopT2() {
        t2Task?.cancel()
        t2Task = nil
    }

    private func startT3() {
        t3Task?.cancel()
        t3Task = clock.schedule(delay: profile.t3) { [weak self] in
            guard let self, self.state == .connected, self.outstanding == 0 else { return }
            self.rc = 0
            self.state = .timerRecovery
            self.sendS(self.receiverBusy ? .rnr : .rr, pf: true, command: true)
            self.startT1()
        }
    }

    private func stopT3() {
        t3Task?.cancel()
        t3Task = nil
    }

    private func t1Expired() {
        t1Task = nil
        switch state {
        case .awaitingConnection:
            rc += 1
            if rc > profile.retries {
                linkFailures += 1
                enterDisconnected()
                return
            }
            sendU(usingSABME ? .sabme : .sabm, pf: true, command: true)
            startT1()
        case .awaitingRelease:
            rc += 1
            if rc > profile.retries { enterDisconnected(); return }
            sendU(.disc, pf: true, command: true)
            startT1()
        case .connected:
            rc = 1
            state = .timerRecovery
            sendS(receiverBusy ? .rnr : .rr, pf: true, command: true)
            startT1()
        case .timerRecovery:
            if rc >= profile.retries {
                linkFailures += 1
                enterDisconnected()
                return
            }
            rc += 1
            sendS(receiverBusy ? .rnr : .rr, pf: true, command: true)
            startT1()
        case .disconnected:
            break
        }
    }

    // MARK: Frame building

    private func bind(to f: WireFrame) {
        remote = WireAddress(call: f.src.call, ssid: f.src.ssid, bit7: false)
        localForLink = WireAddress(call: f.dest.call, ssid: f.dest.ssid, bit7: false)
        replyVia = reversed(f.via)
    }

    private func reversed(_ via: [WireAddress]) -> [WireAddress] {
        via.reversed().map { WireAddress(call: $0.call, ssid: $0.ssid, bit7: false) }
    }

    private func resetLink() {
        vs = 0; vr = 0; va = 0
        sentFrames.removeAll()
        oosBuffer.removeAll()
        srejRequested.removeAll()
        rejectException = false
        ackPending = false
        unackedReceived = 0
        peerBusy = false
        pollTimes.removeAll()
    }

    private func enterDisconnected() {
        let was = state
        state = .disconnected
        stopT1(); stopT2(); stopT3()
        sendQueue.removeAll()
        if was != .disconnected { disconnects += 1 }
    }

    private func sendS(_ type: WireFrame.SType, pf: Bool, command: Bool) {
        guard let remote else { return }
        let frame = WireFrame(dest: WireAddress(call: remote.call, ssid: remote.ssid, bit7: command),
                              src: WireAddress(call: localForLink.call, ssid: localForLink.ssid, bit7: !command),
                              via: replyVia, control: WireFrame.sControl(type, nr: vr, pf: pf), pid: nil, info: Data())
        if type != .srej { lastNRSent = vr }
        if type == .rr || type == .rnr || type == .rej || type == .srej {
            ackPending = false
            unackedReceived = 0
            stopT2()
        }
        enqueue(frame)
    }

    /// A U frame on the current link, or, with `to`, an answer to a frame
    /// that belongs to no link (DM to a stray poll): from the address it was
    /// sent to, back along its path reversed.
    private func sendU(_ type: WireFrame.UType, pf: Bool, command: Bool, to stray: WireFrame? = nil) {
        let dest: WireAddress
        let src: WireAddress
        let via: [WireAddress]
        if let stray {
            dest = stray.src
            src = stray.dest
            via = reversed(stray.via)
        } else {
            guard let remote else { return }
            dest = remote
            src = localForLink
            via = replyVia
        }
        let frame = WireFrame(dest: WireAddress(call: dest.call, ssid: dest.ssid, bit7: command),
                              src: WireAddress(call: src.call, ssid: src.ssid, bit7: !command),
                              via: via, control: WireFrame.uControl(type, pf: pf), pid: nil, info: Data())
        enqueue(frame)
    }

    /// Frames leave in order, after the station's turnaround.
    private func enqueue(_ frame: WireFrame) {
        transmitted.append((clock.currentTime, frame))
        txQueue.append(frame.encode())
        guard !txFlushScheduled else { return }
        txFlushScheduled = true
        _ = clock.schedule(delay: profile.turnaround) { [weak self] in
            guard let self else { return }
            self.txFlushScheduled = false
            let batch = self.txQueue
            self.txQueue.removeAll()
            for bytes in batch {
                if let end = self.channel?.transmit(bytes, from: self) { self.lastTxEnd = end }
            }
            if self.t1Deferred { self.armT1(from: self.lastTxEnd) }
        }
    }
}
