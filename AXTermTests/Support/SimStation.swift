//
//  SimStation.swift
//  AXTermTests
//
//  A station on the HalfDuplexChannel: a real AX25SessionManager on the
//  shared virtual clock, with frames encoded to AX.25 bytes on the way out
//  and decoded and dispatched on the way in exactly as
//  SessionCoordinator.handleIncomingPacket does it.
//
//  The station also watches its own timers. Anything the manager hands to
//  onSendFrame outside a dispatch or a host call came from a timer: an
//  I-frame is a T1 retransmission, an RR response with F=0 is a T2 ack, an
//  RR command with P=1 is a T1 or T3 poll. That is how the stress tests
//  count early T1 expiries and mid-burst T2 acks without touching the
//  production code.
//

import Foundation
@testable import AXTerm

/// Why a frame went out, for the per-kind reception counts.
enum SimFrameKind: String, CaseIterable {
    case host
    case response
    case t1Retransmit
    case t1Poll
    case t3Poll
    case t2Ack
    case t2AckMidBurst
    case timerOther
}

/// How T1 retransmissions and T2 acks went for one station.
struct SimTimerMetrics {
    var t1Batches = 0
    var t1Frames = 0
    var t1Polls = 0
    var t3Polls = 0
    var t2Acks = 0
    /// T1 ran out while our own frames were still queued in the TNC or on
    /// the air.
    var earlyT1OwnBurst = 0
    /// T1 ran out after the peer took the frame, with the peer's T2 still
    /// running: the delayed ack had not even been sent.
    var earlyT1PeerT2 = 0
    /// T1 ran out after the peer took the frame and its ack was queued or on
    /// the air.
    var earlyT1AckInFlight = 0
    /// The peer took the frame and its ack was lost on the way.
    var spuriousT1AckLost = 0
    /// The peer never got the frame: the retransmission was needed.
    var neededT1 = 0
    /// T2 fired while the peer was still keyed or had frames queued.
    var midBurstT2 = 0

    var earlyT1: Int { earlyT1OwnBurst + earlyT1PeerT2 + earlyT1AckInFlight }

    static func + (a: SimTimerMetrics, b: SimTimerMetrics) -> SimTimerMetrics {
        var r = SimTimerMetrics()
        r.t1Batches = a.t1Batches + b.t1Batches
        r.t1Frames = a.t1Frames + b.t1Frames
        r.t1Polls = a.t1Polls + b.t1Polls
        r.t3Polls = a.t3Polls + b.t3Polls
        r.t2Acks = a.t2Acks + b.t2Acks
        r.earlyT1OwnBurst = a.earlyT1OwnBurst + b.earlyT1OwnBurst
        r.earlyT1PeerT2 = a.earlyT1PeerT2 + b.earlyT1PeerT2
        r.earlyT1AckInFlight = a.earlyT1AckInFlight + b.earlyT1AckInFlight
        r.spuriousT1AckLost = a.spuriousT1AckLost + b.spuriousT1AckLost
        r.neededT1 = a.neededT1 + b.neededT1
        r.midBurstT2 = a.midBurstT2 + b.midBurstT2
        return r
    }
}

/// Where a station's session config comes from.
enum SimConfigSource {
    /// A fixed config, as a bare manager or a test sets it.
    case fixed(AX25SessionConfig)
    /// A SessionCoordinator's adaptive logic: its config for each new
    /// session and its controller fed with every link-quality sample, with
    /// the result pushed back to the session the way pushLinkTargets does.
    /// `frack` replaces the operator's T1 setting when given.
    case coordinator(SessionCoordinator, frack: Double?)
}

/// The channel, the stations and the frame bookkeeping for one run.
@MainActor
final class StressNet {
    let clock: AX25VirtualClock
    let channel: HalfDuplexChannel
    private(set) var stations: [SimStation] = []
    private var tagKinds: [Int: (station: Int, kind: SimFrameKind)] = [:]
    private var nextTag = 0
    /// Reception outcomes at the intended receiver, by frame kind.
    private(set) var outcomes: [SimFrameKind: [SimReception: Int]] = [:]

    init(seed: UInt64) {
        clock = AX25VirtualClock()
        channel = HalfDuplexChannel(clock: clock, seed: seed)
        channel.onReception = { [weak self] tag, _, _, outcome in
            guard let self, let entry = self.tagKinds[tag] else { return }
            self.outcomes[entry.kind, default: [:]][outcome, default: 0] += 1
        }
    }

    func add(_ station: SimStation) { stations.append(station) }

    func station(for address: AX25Address) -> SimStation? {
        stations.first { HalfDuplexChannel.sameStation($0.address, address) }
    }

    func tag(for station: Int, kind: SimFrameKind) -> Int {
        nextTag += 1
        tagKinds[nextTag] = (station, kind)
        return nextTag
    }

    func outcomeCount(_ kind: SimFrameKind, _ outcome: SimReception) -> Int {
        outcomes[kind]?[outcome] ?? 0
    }
}

@MainActor
final class SimStation {
    enum Context { case timer, dispatch, host }

    let name: String
    let address: AX25Address
    let node: Int
    unowned let net: StressNet
    private let configSource: SimConfigSource
    let useDelayedAckT1: Bool

    private(set) var manager: AX25SessionManager
    /// Every session any of this station's managers created, for totals.
    private(set) var sessionsSeen: [UUID: AX25Session] = [:]
    private var context: Context = .timer
    private var lastT1BatchTime: TimeInterval = -1
    private(set) var metrics = SimTimerMetrics()

    /// What the application handed to the link while it was connected, and
    /// what the link delivered to the application, per peer.
    private(set) var sent: [String: Data] = [:]
    private(set) var received: [String: Data] = [:]
    /// Where the current streams start, after a link reset this station
    /// was not told about (see `receive`).
    private var sentBase: [String: Int] = [:]
    private var receivedBase: [String: Int] = [:]
    /// UAs that arrived while the session was already connected. AX.25
    /// 2.2's SDL re-establishes the link on one (error C); AXTerm ignores it.
    private(set) var unexpectedUAs: [TimeInterval] = []
    /// Link resets (SABM on a connected session) that threw away frames
    /// still unacknowledged without telling the application.
    private(set) var silentResets: [(time: TimeInterval, peer: String, outstanding: Int)] = []

    /// The stream sent to a peer since the session (or the last link reset)
    /// began.
    func sentStream(to peer: SimStation) -> Data {
        let all = sent[peer.address.display] ?? Data()
        return all.dropFirst(min(all.count, sentBase[peer.address.display] ?? 0))
    }

    /// The stream received from a peer since the session (or the last link
    /// reset) began.
    func receivedStream(from peer: SimStation) -> Data {
        let all = received[peer.address.display] ?? Data()
        return all.dropFirst(min(all.count, receivedBase[peer.address.display] ?? 0))
    }

    /// State changes the station reported.
    private(set) var stateLog: [(time: TimeInterval, peer: String, from: AX25SessionState, to: AX25SessionState)] = []
    /// Deliveries made by the receive-gap flush, which skips a frame that
    /// never arrived.
    private(set) var gapFlushes: [(time: TimeInterval, peer: String)] = []
    /// Counts the times each stream to or from a peer started over, so a
    /// checker knows where to compare from: both when a session comes up,
    /// the receive side alone when this station restarts and forgets what
    /// it had received. A restart keeps what was sent: the peer may still
    /// be receiving it.
    private(set) var sendEpoch: [String: Int] = [:]
    private(set) var receiveEpoch: [String: Int] = [:]
    /// Restarts so far; each one is a new manager with no sessions.
    private(set) var restarts = 0

    init(net: StressNet, name: String, address: AX25Address, node: Int,
         config: SimConfigSource, useDelayedAckT1: Bool = false) {
        self.net = net
        self.name = name
        self.address = address
        self.node = node
        self.configSource = config
        self.useDelayedAckT1 = useDelayedAckT1
        self.manager = AX25SessionManager(localCallsign: address, clock: net.clock)
        wire(manager)
        net.channel.nodes[node].deliver = { [weak self] bytes in self?.receive(bytes) }
    }

    // MARK: Manager wiring

    private func wire(_ manager: AX25SessionManager) {
        manager.useDelayedAckT1 = useDelayedAckT1
        switch configSource {
        case .fixed(let config):
            manager.defaultConfig = config
        case .coordinator(let brain, let frack):
            let base = brain.sessionManager.getConfigForDestination
            manager.getConfigForDestination = { destination, path, radio in
                let config = base?(destination, path, radio) ?? AX25SessionConfig()
                guard let frack else { return config }
                return config.replacingInitialRto(frack)
            }
            manager.onLinkQualitySample = { [weak manager, weak brain] session, sample in
                guard let brain, let manager else { return }
                // The coordinator's handler teaches the route's controller.
                // Its push lands on its own manager, which does not hold this
                // session, so the same push is repeated here.
                brain.sessionManager.onLinkQualitySample?(session, sample)
                let entry = brain.effectiveAdaptiveSettings(destination: session.remoteAddress.display,
                                                            path: session.path.display,
                                                            radio: session.radio)
                manager.updateLinkTargets(for: session, window: entry.windowSize.currentAdaptive,
                                          paclen: entry.paclen.currentAdaptive,
                                          reason: entry.windowSize.adaptiveReason
                                            ?? entry.paclen.adaptiveReason ?? "Adaptive")
            }
        }
        manager.onSendFrame = { [weak self] frame in self?.emit(frame) }
        manager.onDataReceived = { [weak self] session, data in
            guard let self else { return }
            // Data is delivered while handling an inbound frame. Delivered
            // from a timer, it is the receive-gap flush at T1 (the state
            // machine's last-ditch skip past a missing frame).
            if self.context == .timer {
                self.gapFlushes.append((self.net.clock.currentTime, session.remoteAddress.display))
            }
            self.received[session.remoteAddress.display, default: Data()].append(data)
        }
        manager.onSessionStateChanged = { [weak self] session, from, to in
            guard let self else { return }
            self.sessionsSeen[session.id] = session
            let peer = session.remoteAddress.display
            self.stateLog.append((self.net.clock.currentTime, peer, from, to))
            self.net.channel.note("\(self.name) \(from.rawValue)>\(to.rawValue) with \(peer)")
            // A link that (re)connects starts new streams both ways: the
            // application was told, so nothing before it carries over.
            if to == .connected {
                self.sent[peer] = Data()
                self.received[peer] = Data()
                self.sentBase[peer] = 0
                self.receivedBase[peer] = 0
                self.sendEpoch[peer, default: 0] += 1
                self.receiveEpoch[peer, default: 0] += 1
            }
        }
    }

    /// The station crashes and comes back with no sessions. Its old manager
    /// and every timer it held are gone.
    func restart() {
        for session in manager.sessions.values { sessionsSeen[session.id] = session }
        manager.onSendFrame = nil
        manager.onSessionStateChanged = nil
        manager.onDataReceived = nil
        manager = AX25SessionManager(localCallsign: address, clock: net.clock)
        wire(manager)
        restarts += 1
        for key in received.keys { receiveEpoch[key, default: 0] += 1 }
        received.removeAll()
        net.channel.note("\(name) restarted")
    }

    // MARK: Host calls

    func session(with peer: SimStation, path: DigiPath = DigiPath()) -> AX25Session? {
        manager.existingSession(for: peer.address, path: path, radio: .primary)
            ?? manager.connectedSession(withPeer: peer.address)
    }

    func connect(to peer: SimStation, path: DigiPath = DigiPath()) {
        context = .host
        defer { context = .timer }
        if let sabm = manager.connect(to: peer.address, path: path, radio: .primary) {
            transmit(sabm, kind: .host)
        }
        if let session = manager.existingSession(for: peer.address, path: path, radio: .primary) {
            sessionsSeen[session.id] = session
        }
    }

    func disconnect(from peer: SimStation, path: DigiPath = DigiPath()) {
        guard let session = session(with: peer, path: path) else { return }
        context = .host
        defer { context = .timer }
        if let disc = manager.disconnect(session: session) {
            transmit(disc, kind: .host)
        }
    }

    /// Hands application data to a connected session. Returns false, and
    /// sends nothing, when the session is not connected.
    @discardableResult
    func send(_ data: Data, to peer: SimStation, path: DigiPath = DigiPath()) -> Bool {
        guard let session = session(with: peer, path: path), session.state == .connected else { return false }
        context = .host
        defer { context = .timer }
        sent[peer.address.display, default: Data()].append(data)
        let frames = manager.sendData(data, to: peer.address, path: session.path, radio: .primary)
        for frame in frames { transmit(frame, kind: .host) }
        return true
    }

    // MARK: Outbound

    private func emit(_ frame: OutboundFrame) {
        let kind: SimFrameKind
        switch context {
        case .dispatch: kind = .response
        case .host: kind = .host
        case .timer: kind = classifyTimerFrame(frame)
        }
        transmit(frame, kind: kind)
    }

    private func transmit(_ frame: OutboundFrame, kind: SimFrameKind) {
        let tag = net.tag(for: node, kind: kind)
        net.channel.send(from: node, bytes: frame.encodeAX25(), tag: tag)
    }

    private func peerNodes(for destination: AX25Address) -> [Int] {
        var result: [Int] = []
        if let peer = net.station(for: destination) { result.append(peer.node) }
        result.append(contentsOf: net.channel.nodes.filter(\.isDigipeater).map(\.index))
        return result
    }

    private func classifyTimerFrame(_ frame: OutboundFrame) -> SimFrameKind {
        let control = frame.controlByte ?? 0
        let now = net.clock.currentTime
        switch frame.frameType.lowercased() {
        case "i":
            metrics.t1Frames += 1
            if now != lastT1BatchTime {
                lastT1BatchTime = now
                metrics.t1Batches += 1
                classifyT1(firstFrame: frame)
            }
            return .t1Retransmit
        case "s":
            let isRR = (control & 0x0F) == 0x01
            let pf = (control & 0x10) != 0
            let command = frame.isCommand ?? false
            if isRR, !command, !pf {
                metrics.t2Acks += 1
                // Mid-burst: the peer (or the digipeater carrying its
                // burst) is keyed, or still has I-frames for us to send.
                let busy = peerNodes(for: frame.destination).contains { other in
                    net.channel.isTransmitting(other)
                        || net.channel.unsentFrames(of: other).compactMap(Self.decodeControl).contains {
                            $0.control.frameClass == .I
                                && $0.to.map { HalfDuplexChannel.sameStation($0, address) } == true
                        }
                }
                if busy {
                    metrics.midBurstT2 += 1
                    return .t2AckMidBurst
                }
                return .t2Ack
            }
            if isRR, command, pf {
                let session = manager.connectedSession(withPeer: frame.destination)
                if (session?.stateMachine.retryCount ?? 0) > 0 {
                    metrics.t1Polls += 1
                    return .t1Poll
                }
                metrics.t3Polls += 1
                return .t3Poll
            }
            return .timerOther
        default:
            return .timerOther
        }
    }

    /// Why T1 ran out, judged at the moment it did.
    private func classifyT1(firstFrame frame: OutboundFrame) {
        guard let ns = frame.ns,
              let session = manager.connectedSession(withPeer: frame.destination) else {
            metrics.neededT1 += 1
            return
        }
        let modulo = session.stateMachine.config.modulo
        let outstanding = (session.vs - session.va + modulo) % modulo
        // The frame T1 was timing is still waiting in our TNC or on the air:
        // T1 was shorter than our own channel access and airtime.
        let ownUnsent = net.channel.unsentFrames(of: node).compactMap(Self.decodeControl)
        if ownUnsent.contains(where: { $0.to.map { HalfDuplexChannel.sameStation($0, frame.destination) } == true
                                        && $0.control.frameClass == .I && $0.control.ns == ns }) {
            metrics.earlyT1OwnBurst += 1
            return
        }
        guard let peer = net.station(for: frame.destination),
              let peerSession = peer.manager.connectedSession(withPeer: address) else {
            metrics.neededT1 += 1
            return
        }
        let taken = (peerSession.vr - ns + modulo) % modulo
        guard taken >= 1, taken <= outstanding else {
            metrics.neededT1 += 1
            return
        }
        // An ack on its way to us: any frame for us whose N(R) covers ns.
        let acksOnTheWay = peerNodes(for: frame.destination)
            .flatMap { net.channel.unsentFrames(of: $0) }
            .compactMap(Self.decodeControl)
            .contains { decoded in
                guard decoded.to.map({ HalfDuplexChannel.sameStation($0, address) }) == true,
                      decoded.control.frameClass == .I || decoded.control.frameClass == .S,
                      let nr = decoded.control.nr else { return false }
                let covered = (nr - ns + modulo) % modulo
                return covered >= 1 && covered <= outstanding
            }
        if acksOnTheWay {
            metrics.earlyT1AckInFlight += 1
        } else if peerSession.stateMachine.ackPending, peerSession.t2TimerTask != nil {
            metrics.earlyT1PeerT2 += 1
        } else {
            metrics.spuriousT1AckLost += 1
        }
    }

    private static func decodeControl(_ bytes: Data) -> (to: AX25Address?, control: AX25ControlFieldDecoded)? {
        guard let frame = AX25.decodeFrame(ax25: bytes) else { return nil }
        return (frame.to, AX25ControlFieldDecoder.decode(control: frame.control, controlByte1: frame.controlByte1))
    }

    // MARK: Inbound

    /// The coordinator's inbound path, for the frames a session uses.
    private func receive(_ bytes: Data) {
        guard case .success(let decoded) = AX25.checkFrame(ax25: bytes) else { return }
        let packet = Packet(from: decoded.from, to: decoded.to, via: decoded.via,
                            frameType: decoded.frameType, control: decoded.control,
                            controlByte1: decoded.controlByte1, pid: decoded.pid,
                            info: decoded.info, rawAx25: bytes, radioID: .primary)
        guard let from = packet.from, let to = packet.to,
              manager.answers(to), packet.isFullyDigipeated else { return }
        let control = AX25ControlFieldDecoder.decode(control: packet.control,
                                                     controlByte1: packet.controlByte1)
        // Session frames are keyed and answered by the reversed heard path.
        let path = DigiPath.replyPath(heardVia: packet.via)
        let radio = RadioID.primary
        manager.noteFrameHeard(from: from, path: path, radio: radio)

        // A SABM on a connected session is a link reset (AX.25 2.2 SDL,
        // appendix C4, connected and timer-recovery states). Watched so a
        // reset that loses data without a word to the application is caught.
        var resetWatch: (session: AX25Session, outstanding: Int, unsentBytes: Int, logCount: Int)?
        if control.frameClass == .U, control.uType == .SABM,
           let existing = manager.existingSession(for: from, path: path, radio: radio)
            ?? manager.connectedSession(withPeer: from),
           existing.state == .connected {
            let unsent = existing.pendingDataQueue.reduce(0) { $0 + $1.data.count }
                + existing.sendBuffer.values.reduce(0) { $0 + $1.payload.count }
            resetWatch = (existing, existing.outstandingCount, unsent, stateLog.count)
        }
        defer {
            if let watch = resetWatch, watch.session.state == .connected, stateLog.count == watch.logCount {
                let peer = from.display
                if watch.outstanding > 0 {
                    silentResets.append((net.clock.currentTime, peer, watch.outstanding))
                }
                // Not told: the streams carry on, from here.
                sentBase[peer] = max(0, (sent[peer]?.count ?? 0) - watch.unsentBytes)
                receivedBase[peer] = received[peer]?.count ?? 0
                sendEpoch[peer, default: 0] += 1
                receiveEpoch[peer, default: 0] += 1
                net.channel.note("\(name) link reset by \(peer), outstanding \(watch.outstanding)")
            }
        }

        context = .dispatch
        defer { context = .timer }
        var replies: [OutboundFrame] = []
        switch control.frameClass {
        case .U:
            guard let uType = control.uType else { return }
            let pf = (packet.control & 0x10) != 0
            switch uType {
            case .UA:
                if let existing = manager.connectedSession(withPeer: from), existing.state == .connected {
                    unexpectedUAs.append(net.clock.currentTime)
                    net.channel.note("\(name) UA from \(from.display) while connected")
                }
                manager.handleInboundUA(from: from, path: path, radio: radio)
            case .DM:
                if manager.handleInboundDMDuringNegotiation(from: from, radio: radio) { break }
                manager.handleInboundDM(from: from, path: path, radio: radio)
            case .FRMR:
                manager.handleInboundFRMRDuringNegotiation(from: from, radio: radio)
                manager.handleInboundFRMR(from: from, path: path, radio: radio)
            case .XID:
                replies += manager.handleInboundXID(from: from, to: to, path: path, radio: radio,
                                                    info: packet.info, isCommand: packet.isCommand, pf: pf)
            case .DISC:
                if let r = manager.handleInboundDISC(from: from, to: to, path: path, radio: radio) { replies.append(r) }
            case .SABM, .SABME:
                if let r = manager.handleInboundSABM(from: from, to: to, path: path, radio: radio,
                                                     extended: uType == .SABME, pf: pf) {
                    replies.append(r)
                }
            default:
                break
            }
        case .I:
            if let r = manager.handleInboundIFrame(from: from, to: to, path: path, radio: radio,
                                                   ns: control.ns ?? 0, nr: control.nr ?? 0,
                                                   pf: (control.pf ?? 0) == 1,
                                                   payload: packet.info, pid: packet.pid) {
                replies.append(r)
            }
        case .S:
            let nr = control.nr ?? 0
            let pf = (control.pf ?? 0) == 1
            switch control.sType {
            case .RR?:
                replies += manager.handleInboundRRFrames(from: from, to: to, path: path, radio: radio, nr: nr,
                                                         pf: pf, isCommand: packet.isCommand)
            case .REJ?:
                replies += manager.handleInboundREJ(from: from, to: to, path: path, radio: radio, nr: nr,
                                                    pf: pf, isCommand: packet.isCommand)
            case .RNR?:
                replies += manager.handleInboundRNR(from: from, to: to, path: path, radio: radio, nr: nr,
                                                    pf: pf, isCommand: packet.isCommand)
            case .SREJ?:
                replies += manager.handleInboundSREJ(from: from, path: path, radio: radio, nr: nr, pf: pf)
            case nil:
                break
            }
        case .unknown:
            break
        }
        for session in manager.sessions.values where sessionsSeen[session.id] == nil {
            sessionsSeen[session.id] = session
        }
        for reply in replies { transmit(reply, kind: .response) }
    }

    // MARK: Totals

    var newIFrames: Int { sessionsSeen.values.reduce(0) { $0 + $1.statistics.framesSent } }
    var retransmittedIFrames: Int { sessionsSeen.values.reduce(0) { $0 + $1.statistics.retransmissions } }
}

extension AX25SessionConfig {
    /// The same config with another operator T1 (FRACK), clamped the way
    /// SessionCoordinator.configFromAdaptive clamps it.
    func replacingInitialRto(_ frack: Double) -> AX25SessionConfig {
        let lo = rtoMin ?? 1.0
        let hi = rtoMax ?? 30.0
        return AX25SessionConfig(
            windowSize: windowSize, paclen: paclen, maxReceiveBufferSize: maxReceiveBufferSize,
            maxRetries: maxRetries, extended: extended, srejEnabled: srejEnabled,
            rtoMin: rtoMin, rtoMax: rtoMax, initialRto: max(lo, min(hi, frack)),
            t2AckDelay: t2AckDelay, adaptiveTimeout: adaptiveTimeout, learnedPathRto: learnedPathRto,
            maxWindowSize: maxWindowSize, maxPaclen: maxPaclen,
            minWindowSize: minWindowSize, minPaclen: minPaclen, startSource: startSource)
    }
}
