//
//  AX25SessionManager.swift
//  AXTerm
//
//  Manages AX.25 connected-mode sessions.
//  Handles session lifecycle, state transitions, and frame routing.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 7
//

import Foundation
import Combine

// MARK: - Session Key

/// Unique key for identifying a session
/// Sessions are identified by destination callsign+SSID, path signature, and channel
nonisolated struct SessionKey: Hashable, Sendable {
    let destination: String      // "N0CALL-5"
    let pathSignature: String    // "WIDE1-1,WIDE2-1" or "" for direct
    let channel: UInt8

    init(destination: AX25Address, path: DigiPath, channel: UInt8 = 0) {
        self.destination = destination.display
        self.pathSignature = path.display
        self.channel = channel
    }
}

/// Token proving exclusive ownership of a session's delivered byte stream
/// (see `AX25SessionManager.claimDelivery`).
nonisolated struct SessionDeliveryClaim: Sendable {
    fileprivate let id: UUID
    let key: SessionKey

    fileprivate init(key: SessionKey) {
        self.id = UUID()
        self.key = key
    }
}

// MARK: - Session

/// Represents an AX.25 connected-mode session
/// One evidence-bearing link-quality observation from a connected session.
/// `newFrames` and `retransmits` are DELTAS since the previous sample, so the
/// link controller's EWMA sees time-local evidence (spec 4.2).
nonisolated struct LinkQualitySample: Sendable {
    /// The worse of the two directions. Route ranking and anything that
    /// asks "is this path any good" wants this.
    let lossRate: Double
    /// Loss on frames **we sent** — retransmissions over transmissions.
    /// The only direction our own paclen and window can affect, and so
    /// the only one allowed to shrink them.
    let forwardLoss: Double
    /// Loss on frames **sent at us** — REJs over inbound frames plus gaps.
    /// Real evidence about the path, and worth showing the operator, but
    /// making our frames smaller cannot mend it.
    let reverseLoss: Double
    let etx: Double
    let srtt: Double?
    let newFrames: Int
    let retransmits: Int
}

nonisolated final class AX25Session: @unchecked Sendable {
    let id: UUID
    let key: SessionKey
    let localAddress: AX25Address
    let remoteAddress: AX25Address
    let path: DigiPath
    let channel: UInt8

    /// The state machine handling protocol logic
    /// Note: Internal setter to allow session manager to mutate
    var stateMachine: AX25StateMachine

    /// Timer management
    /// Note: Internal setter to allow session manager to mutate
    var timers: AX25SessionTimers

    /// Session statistics
    /// Note: Internal setter to allow session manager to mutate
    var statistics: AX25SessionStatistics

    /// Send buffer: frames sent but not yet acknowledged
    /// Key is N(S) sequence number
    var sendBuffer: [Int: OutboundFrame] = [:]

    /// AIMD congestion window.
    /// Starts in slow start (cwnd=1) and grows as ACKs arrive.  Halved on each
    /// T1 timeout (loss event).  The effective send window is
    /// min(config.windowSize, aimdWindow.effectiveWindow) so the congestion
    /// window can never exceed the protocol window K, but can be reduced below K
    /// when the link is lossy.
    var aimdWindow: AIMDWindow

    /// Send timestamp per N(S) for RTT estimation when RR acks frames.
    /// Stored as monotonic TimeInterval from the injected clock so tests can
    /// use a virtual clock and get deterministic RTT measurements.
    private var sendTimeByNs: [Int: TimeInterval] = [:]

    /// N(S) values that have been retransmitted at least once.
    /// Karn's algorithm: RTT samples from retransmitted frames are excluded
    /// because the ACK could belong to either the original or the retransmit,
    /// making the sample ambiguous and potentially inflating SRTT/RTO.
    private var retransmittedNS: Set<Int> = []

    /// Pending data queue: data waiting to be sent once connected
    /// Each entry is (data, pid, displayInfo)
    var pendingDataQueue: [(data: Data, pid: UInt8, displayInfo: String?)] = []

    /// Set when the peer answered our SABM with DM — a refusal. A refusal
    /// is an answer, not a path failure: the connect wait loop reads this
    /// so the strategy ladder stops instead of knocking on other doors.
    /// Cleared at the start of every connect attempt.
    var peerRefusedConnect: Bool = false

    /// T1 retransmit timer task
    var t1TimerTask: AnyCancellableTask?

    /// Pending retransmit task (grace period after T1 fires); cancelled if RR arrives
    var t1PendingRetransmitTask: AnyCancellableTask?

    /// Statistics watermarks from the previous link-quality sample, so each
    /// sample reports fresh evidence (deltas) rather than a session-lifetime
    /// average. Spec 4.2 requires time-local, EWMA-able samples; a cumulative
    /// ratio both dilutes new loss on long sessions and never forgives an old
    /// bad patch.
    var lastSampledFramesSent: Int = 0
    var lastSampledRetransmissions: Int = 0
    var lastSampledFramesReceived: Int = 0
    var lastSampledREJSent: Int = 0

    /// Bumped on every T1 start/stop. A fired T1 closure whose captured generation
    /// no longer matches is stale: cancel() cannot recall a closure the scheduler
    /// already began dispatching, so stopT1 can lose the race against a fire that
    /// is in flight (field capture 2026-08-22: "T1 timeout fired" 60 ms after
    /// "Stopping T1 timer", spending airtime on a needless RR poll).
    var t1Generation: UInt64 = 0

    /// T3 idle timer task
    var t3TimerTask: AnyCancellableTask?

    /// T2 response-delay (delayed-ack) timer task
    var t2TimerTask: AnyCancellableTask?

    /// Bumped on every T2 start/stop so a fire that raced a cancel is
    /// recognized as stale (same pattern and reason as `t1Generation`).
    var t2Generation: UInt64 = 0

    /// N(R) at which we last triggered an immediate REJ retransmit.
    /// Used to suppress duplicate REJ retransmission amplification (Bug A):
    /// once we retransmit for REJ(nr), T1 owns the retry cycle until ack
    /// progress or T1 fires. Cleared when T1 fires so next REJ after T1
    /// timeout triggers a fresh immediate retransmit.
    var lastREJRetransmitNR: Int? = nil

    /// Consecutive T1 expirations while outbound I-frames remain unacknowledged.
    ///
    /// The first expiry is used as an AX.25 RR(P=1) status poll. Retransmitting
    /// immediately on that same expiry can duplicate interactive NET/ROM node
    /// commands when the peer has already received the I-frame but its RR is
    /// merely delayed. A second consecutive expiry is stronger loss evidence.
    var consecutiveT1PollsWithoutAck: Int = 0

    /// Monotonic time when SABM was sent, from the injected clock (for RTT calculation).
    /// Using TimeInterval keeps this compatible with the virtual clock in tests.
    var sabmSentAt: TimeInterval?

    /// True once SABM has been retransmitted, so the connect RTT sample is
    /// discarded (Karn's algorithm).
    ///
    /// `sabmSentAt` deliberately keeps the *first* send time — the late-UA
    /// window is measured from it — so elapsed time spans every retry. A UA
    /// cannot be attributed to a particular SABM, and measuring it against
    /// the first one charges the whole backoff ladder to the path.
    ///
    /// Field capture 2026-08-25, W0ARP-10: UA arrived on the 5th SABM after
    /// 4+8+16+30s of backoff, and the resulting sample was srtt=61.1s,
    /// rttvar=30.6s, rto=30s (clamped). The link's real RTT was 1.8s. Every
    /// subsequent T3 poll then waited 30s on a healthy path.
    var sabmRetransmitted = false

    /// Timestamp when session was established
    var connectedAt: Date?

    /// Timestamp of last activity
    var lastActivityAt: Date

    /// Whether we initiated this session (vs responding to incoming SABM)
    let isInitiator: Bool

    /// Via path from the most recently received inbound I-frame (for display only).
    /// Updated each time handleInboundIFrame delivers data.
    var lastReceivedVia: [String] = []

    /// True when the receive side has buffered out-of-sequence I-frames and is
    /// waiting for the missing N(S) to arrive before delivering data.
    var hasReceiveSequenceGap: Bool {
        !stateMachine.receiveBuffer.isEmpty
    }

    init(
        localAddress: AX25Address,
        remoteAddress: AX25Address,
        path: DigiPath = DigiPath(),
        channel: UInt8 = 0,
        config: AX25SessionConfig = AX25SessionConfig(),
        isInitiator: Bool = true
    ) {
        self.id = UUID()
        self.key = SessionKey(destination: remoteAddress, path: path, channel: channel)
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.path = path
        self.channel = channel
        self.stateMachine = AX25StateMachine(config: config)
        // §6.7.1.1: T1 "should be adjusted according to the number of repeaters" —
        // each digi store-and-forwards the frame in both directions, so a T1 sized
        // for a direct link fires mid-flight on a digipeated one. The spec gives no
        // formula; this uses the TNC-2 FRACK convention, retry interval = FRACK ×
        // (2m+1) for m digis. Only the pre-sample seed is scaled: in adaptive mode
        // the first RTT sample (SABM→UA) replaces it entirely, and the timers'
        // rtoMax clamp still bounds it.
        //
        // A learned full-path RTO for this exact route supersedes the scaled
        // guess VERBATIM — it already includes the digipeater delay, so the
        // hop multiplier must never apply on top (that would double-count the
        // path). Strict either/or; no mixing of the two seed semantics.
        let hopMultiplier = Double(2 * path.digis.count + 1)
        let seed = config.learnedPathRto ?? (config.initialRto ?? 4.0) * hopMultiplier
        self.timers = AX25SessionTimers(
            rtoMin: config.rtoMin ?? 1.0,
            rtoMax: config.rtoMax ?? 30.0,
            initialRto: seed,
            adaptiveTimeout: config.adaptiveTimeout,
            t2AckDelay: config.t2AckDelay ?? 2.0
        )
        self.statistics = AX25SessionStatistics()
        self.lastActivityAt = Date()
        self.isInitiator = isInitiator
        // AIMD window: starts at windowSize (full protocol window) and shrinks
        // on loss events.  We do NOT use slow-start (cwnd=1) because AX.25 has
        // a very small protocol window (max 7) and the round-trip times are large
        // (seconds, not milliseconds).  Starting at 1 would severely limit
        // throughput until enough ACKs arrived.  Instead, the protocol window K
        // acts as the initial burst limit; AIMD only reduces below K on loss.
        self.aimdWindow = AIMDWindow(
            initialWindow: Double(config.windowSize),
            maxWindow: Double(config.windowSize)
        )
    }

    deinit {
        // Ensure timers are cancelled to avoid background tasks outliving the session.
        t1TimerTask?.cancel()
        t1PendingRetransmitTask?.cancel()
        t3TimerTask?.cancel()
    }

    /// Current session state
    var state: AX25SessionState {
        stateMachine.state
    }

    /// True once this session has reached .connected at least once — the
    /// marker that separates an ENDED session (a reconnect must replace it)
    /// from a fresh one still awaiting its first SABM (must be kept, along
    /// with its queued data).
    var hasEverConnected: Bool {
        stateMachine.hasEverConnected
    }

    /// Current send sequence number V(S)
    var vs: Int {
        stateMachine.sequenceState.vs
    }

    /// Current receive sequence number V(R)
    var vr: Int {
        stateMachine.sequenceState.vr
    }

    /// Current acknowledge state V(A)
    var va: Int {
        stateMachine.sequenceState.va
    }

    /// Number of outstanding (unacked) frames.
    /// Use sendBuffer.count so it matches actual buffered frames after RR acks;
    /// (vs-va) can be wrong across wrap when we remove by RR(nr) semantics.
    var outstandingCount: Int {
        sendBuffer.count
    }

    /// Whether we can send another I-frame (window not full)
    var canSendIFrame: Bool {
        stateMachine.sequenceState.canSend(windowSize: stateMachine.config.windowSize)
    }

    /// Add frame to send buffer for retransmission
    func bufferFrame(_ frame: OutboundFrame, ns: Int) {
        sendBuffer[ns] = frame
        consecutiveT1PollsWithoutAck = 0
    }

    /// Record send time for N(S) using the injected clock's monotonic time.
    /// Using `TimeInterval` (not `Date`) ensures tests with a virtual clock get
    /// deterministic RTT measurements instead of wall-clock noise.
    func recordSendTime(ns: Int, time: TimeInterval) {
        sendTimeByNs[ns] = time
        // Sending a frame fresh: it is no longer tainted by retransmit
        retransmittedNS.remove(ns)
    }

    /// Mark a frame N(S) as retransmitted (Karn's algorithm).
    /// Once marked, its send time will NOT be used for RTT estimation because
    /// the ACK could correspond to either the original or the retransmitted copy.
    func markRetransmitted(ns: Int) {
        retransmittedNS.insert(ns)
    }

    /// Clear send times for sequence numbers acked by RR(nr) (nr = next expected)
    func clearSendTimesAcked(by nr: Int) {
        let modulo = stateMachine.config.modulo
        sendTimeByNs = sendTimeByNs.filter { (ns, _) in
            let diff = (nr - ns + modulo) % modulo
            return diff > modulo / 2 || diff == 0
        }
        // Clean up Karn set for acked range
        retransmittedNS = retransmittedNS.filter { ns in
            let diff = (nr - ns + modulo) % modulo
            return diff > modulo / 2 || diff == 0
        }
    }

    /// Clear all send times (used when aborting or disconnecting)
    func clearSendTimes() {
        sendTimeByNs.removeAll()
        retransmittedNS.removeAll()
    }

    /// Get send time for the last frame acked by RR(nr), for RTT sampling.
    /// Returns `nil` if the frame was retransmitted (Karn's algorithm: ambiguous
    /// ACK would produce an inflated and potentially incorrect RTT sample).
    func rttSendTime(ackedBy nr: Int) -> TimeInterval? {
        let modulo = stateMachine.config.modulo
        let ackedNs = (nr - 1 + modulo) % modulo
        guard !retransmittedNS.contains(ackedNs) else {
            return nil  // Karn: skip retransmitted frame
        }
        return sendTimeByNs[ackedNs]
    }

    /// Legacy: returns send time regardless of Karn status (used only for
    /// compatibility during SABM RTT measurement where retransmit status is irrelevant).
    func sendTimeForAckedBy(nr: Int) -> TimeInterval? {
        let modulo = stateMachine.config.modulo
        let ackedNs = (nr - 1 + modulo) % modulo
        return sendTimeByNs[ackedNs]
    }

    /// Remove acknowledged frames from buffer.
    /// RR(N(R)) means "I expect N(R) next" = receiver has received 0..<N(R) (when N(R)>0)
    /// or all frames (when N(R)==0). Remove exactly those keys from sendBuffer so the
    /// sender clears acks correctly and stops retransmitting (fixes freeze and dupes).
    func acknowledgeUpTo(from va: Int, to nr: Int) {
        let modulo = stateMachine.config.modulo
        var current = va
        var removedAny = false
        
        // Loop from va up to (but not including) nr, acknowledging each frame
        while current != nr {
            if sendBuffer.removeValue(forKey: current) != nil {
                removedAny = true
            }
            current = (current + 1) % modulo
        }
        if removedAny {
            consecutiveT1PollsWithoutAck = 0
        }
    }

    /// Legacy entry point for callers that don't have va; uses current va (must be
    /// called before state machine updates va). Prefer acknowledgeUpTo(from:to:).
    func acknowledgeUpTo(nr: Int) {
        acknowledgeUpTo(from: stateMachine.sequenceState.va, to: nr)
    }

    /// Get frames that need retransmission (from nr onwards)
    func framesToRetransmit(from nr: Int) -> [OutboundFrame] {
        let modulo = stateMachine.config.modulo
        var frames: [(Int, OutboundFrame)] = []

        for (ns, frame) in sendBuffer {
            // Include frames from nr up to vs
            let diff = (ns - nr + modulo) % modulo
            if diff < outstandingCount {
                frames.append((ns, frame))
            }
        }

        // Sort by distance from va (maintains correct order for wrapped sequences)
        return frames.sorted { (a, b) in
            let distA = (a.0 - nr + modulo) % modulo
            let distB = (b.0 - nr + modulo) % modulo
            return distA < distB
        }.map { $0.1 }
    }

    /// Update last activity timestamp
    func touch() {
        lastActivityAt = Date()
    }

    /// Clear all pending transmission state for a graceful stop.
    func clearPendingTransmission(reason: String) {
        pendingDataQueue.removeAll()
        sendBuffer.removeAll()
        clearSendTimes()
        consecutiveT1PollsWithoutAck = 0
        TxLog.debug(.session, "Cleared pending transmission state", [
            "session": String(id.uuidString.prefix(8)),
            "peer": remoteAddress.display,
            "reason": reason
        ])
    }
}

// MARK: - Session Manager

/// Manages all AX.25 connected-mode sessions
@MainActor
final class AX25SessionManager: ObservableObject {

    /// All active sessions keyed by SessionKey
    @Published private(set) var sessions: [SessionKey: AX25Session] = [:]

    /// Configuration used when initiating sessions to unknown destinations
    var defaultConfig: AX25SessionConfig = AX25SessionConfig()

    /// The clock used for all timer scheduling (T1, T3, backoffs). Inject VirtualClock for deterministic tests.
    let clock: AX25TimerScheduler

    // MARK: - Debug Logging (Debug Builds Only)
    private func debugTrace(_ message: String, _ data: [String: Any] = [:]) {
#if DEBUG
        #if DEBUG
        if data.isEmpty {
            print("[AX25 TRACE] \(message)")
        } else {
            let details = data.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("[AX25 TRACE] \(message) | \(details)")
        }
        #endif
#endif
    }

    private func describeFrame(_ frame: OutboundFrame) -> String {
        var parts: [String] = []
        parts.append("type=\(frame.frameType)")
        parts.append("to=\(frame.destination.display)")
        parts.append("via=\(frame.path.display.isEmpty ? "(direct)" : frame.path.display)")
        if let ctl = frame.controlByte {
            parts.append(String(format: "ctl=0x%02X", ctl))
        } else {
            parts.append("ctl=nil")
        }
        if let pid = frame.pid {
            parts.append(String(format: "pid=0x%02X", pid))
        }
        if let ns = frame.ns {
            parts.append("ns=\(ns)")
        }
        if let nr = frame.nr {
            parts.append("nr=\(nr)")
        }
        parts.append("len=\(frame.payload.count)")
        return parts.joined(separator: " ")
    }

    /// Local callsign (from settings)
    var localCallsign: AX25Address

    /// Extra addresses this station answers on, keyed by the service owning each.
    ///
    /// A node answers on several addresses at once — a mailbox, a Winlink P2P
    /// listener and the operator's own terminal are three services sharing one
    /// radio, told apart by the callsign the caller dialed. That is how packet
    /// radio has always separated services, and it is the only thing that lets
    /// two of them run at the same time.
    ///
    /// Nothing reaches the session layer unless it is addressed to one of these,
    /// so a service that does not register here is unreachable however carefully
    /// it is configured.
    ///
    /// Keyed by service rather than held as a set, so re-registering replaces:
    /// an operator editing the mailbox SSID must not leave the old one answering.
    private var serviceAddresses: [String: AX25Address] = [:]

    /// Registers the address a service answers on; nil withdraws it.
    func setServiceAddress(_ address: AX25Address?, for service: String) {
        serviceAddresses[service] = address
    }

    /// Whether a frame addressed to `address` belongs to this station at all.
    func answers(_ address: AX25Address) -> Bool {
        if CallsignNormalizer.addressesMatch(address, localCallsign) { return true }
        return serviceAddresses.values.contains {
            CallsignNormalizer.addressesMatch(address, $0)
        }
    }

    /// Every address currently answered, station callsign first. For diagnostics.
    var answeredAddresses: [AX25Address] {
        [localCallsign] + serviceAddresses.values.sorted { $0.display < $1.display }
    }

    /// Callback when frames need to be sent
    var onSendFrame: ((OutboundFrame) -> Void)?

    /// Callback when data is received from a connected session
    var onDataReceived: ((AX25Session, Data) -> Void)?

    /// One complete NET/ROM L3 datagram arrived in a PID-0xCF I-frame on
    /// a connected session (one I-frame = one datagram). The link driver
    /// feeds these to the NetRomEndpoint. PID-demuxed before terminal,
    /// AXDP, and delivery claims ever see the bytes.
    var onNetRomDatagram: ((AX25Session, Data) -> Void)?

    /// Lightweight link-visualization event stream (window state, deliveries,
    /// REJ/retransmit markers). See LinkVizMonitor.
    var onLinkVizEvent: ((LinkVizEvent) -> Void)?

    /// Callback when data is delivered (in-order) from a connected session.
    /// Used for AXDP reassembly - must only append chunks that were accepted by the AX.25 layer,
    /// not out-of-window or buffered frames (those will be delivered later in sequence).
    var onDataDeliveredForReassembly: ((AX25Session, Data) -> Void)?

    /// Callback when session state changes
    var onSessionStateChanged: ((AX25Session, AX25SessionState, AX25SessionState) -> Void)?

    /// Callback when we have a link quality sample (e.g. after RR with RTT) for adaptive tuning. Parameters: session, lossRate, etx, srtt.
    var onLinkQualitySample: ((AX25Session, LinkQualitySample) -> Void)?

    /// Callback when peer ACKs frames (RR received). Parameters: session, newVa (V(A) after ack).
    /// Used for sender UI to show progressive send/ack highlighting.
    var onOutboundAckReceived: ((AX25Session, Int) -> Void)?

    /// When set, used to get session config per route (destination + path) so direct vs via-digi use separate learned params. If nil, use defaultConfig.
    var getConfigForDestination: ((String, String) -> AX25SessionConfig)?

    // MARK: - AX.25 2.2 negotiation (XID)

    /// Master switch for XID parameter negotiation before the first SABM
    /// to an unknown peer. Off by default so bare managers and the test
    /// harnesses keep the classic connect flow; the app enables it from
    /// Settings. A silent peer costs one RTO exactly once — the outcome
    /// is cached per callsign for the life of the process.
    var negotiateV22: Bool = false

    enum PeerXIDStatus {
        case supported(AX25XIDParameters)
        case unsupported
    }

    /// Capability cache keyed by remote callsign display. Capabilities
    /// belong to the station, not to any particular path or session.
    private(set) var peerXIDStatus: [String: PeerXIDStatus] = [:]

    /// Answered XID verdicts, persisted — see XIDAnswerMemory. The
    /// in-memory cache above answers "this launch"; this answers "ever".
    var xidMemory = XIDAnswerMemory()

    /// Records an XID verdict learned outside a negotiation — the ping
    /// prober's XID probes get the same DM/FRMR answers a connect would.
    func rememberXIDAnswer(peer: String, unsupported: Bool) {
        xidMemory.remember(peer, unsupported: unsupported)
    }

    /// XID commands in flight: peer callsign → the half-open session key
    /// and the timeout that resolves a silent peer as pre-2.2.
    private var pendingXID: [String: (key: SessionKey, task: AnyCancellableTask?)] = [:]

    /// True while an XID exchange for this session is unresolved. The
    /// session still reads `.disconnected` during that phase — callers
    /// awaiting a connection outcome must treat it as in-progress, not as
    /// a refusal (field capture 2026-08-24: the Winlink transport threw
    /// "connect refused" milliseconds after the first XID went out, while
    /// the link went on to connect without it).
    func isNegotiating(key: SessionKey) -> Bool {
        pendingXID.values.contains { $0.key == key }
    }

    /// Our offer: SREJ plus our receive limits from the session's config.
    private func localXIDParameters(config: AX25SessionConfig) -> AX25XIDParameters {
        var params = AX25XIDParameters()
        params.supportsSREJ = true
        params.iFieldLengthRx = config.paclen
        params.windowSizeRx = config.windowSize
        return params
    }

    // MARK: - Delivery claims

    /// Exclusive raw-byte taps, keyed by session. While a claim is held,
    /// delivered data bypasses BOTH `onDataReceived` (the terminal, which
    /// line-splits and drops CR/LF) and `onDataDeliveredForReassembly`
    /// (AXDP, whose magic detection must never see foreign protocol bytes).
    /// Used by wire-exact protocol conversations such as Winlink B2F.
    private var deliveryClaims: [SessionKey: (
        id: UUID,
        handler: (AX25Session, Data) -> Void,
        stateHandler: ((AX25Session, AX25SessionState, AX25SessionState) -> Void)?,
        ackHandler: ((AX25Session, Int) -> Void)?
    )] = [:]

    /// Claims the delivered byte stream for one session key. Returns nil if
    /// another feature already holds the claim. `stateHandler`, when given,
    /// receives session state transitions alongside the regular observers.
    func claimDelivery(
        for key: SessionKey,
        handler: @escaping (AX25Session, Data) -> Void,
        stateHandler: ((AX25Session, AX25SessionState, AX25SessionState) -> Void)? = nil,
        ackHandler: ((AX25Session, Int) -> Void)? = nil
    ) -> SessionDeliveryClaim? {
        guard deliveryClaims[key] == nil else { return nil }
        let claim = SessionDeliveryClaim(key: key)
        deliveryClaims[key] = (claim.id, handler, stateHandler, ackHandler)
        return claim
    }

    /// Fans an outbound-ack notification (new V(A)/V(S)) out to the claim
    /// holder and the regular observer.
    private func notifyOutboundAck(_ session: AX25Session, upTo sequence: Int) {
        deliveryClaims[session.key]?.ackHandler?(session, sequence)
        onOutboundAckReceived?(session, sequence)
    }

    func releaseDelivery(_ claim: SessionDeliveryClaim) {
        guard deliveryClaims[claim.key]?.id == claim.id else { return }
        deliveryClaims[claim.key] = nil
    }

    func hasDeliveryClaim(for key: SessionKey) -> Bool {
        deliveryClaims[key] != nil
    }

    /// Routes a state transition to the claim holder (if any) and the
    /// regular observers. All notify sites funnel through here.
    private func notifyStateChanged(_ session: AX25Session, from oldState: AX25SessionState, to newState: AX25SessionState) {
        deliveryClaims[session.key]?.stateHandler?(session, oldState, newState)

        // A claim cannot outlive its session. Claim holders release their
        // own claim on disconnect, but they are held weakly here and a
        // protocol runner routinely drops its transport in the seconds
        // between sending DISC and the UA coming back — the handler above
        // then no-ops and the claim would be stranded, refusing every
        // later connection to this peer as "session busy" until relaunch.
        if newState == .disconnected || newState == .error {
            deliveryClaims[session.key] = nil
        }

        onSessionStateChanged?(session, oldState, newState)
    }

    /// Waits until a connect attempt resolves: the session leaves the
    /// `.connecting` state, or the timeout elapses.
    enum ConnectOutcome: Sendable {
        case connected
        case refused
        case timeout
    }

    func awaitConnectionOutcome(key: SessionKey, timeout: TimeInterval) async -> ConnectOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let session = sessions[key] else { return .refused }
            switch session.state {
            case .connected:
                return .connected
            case .disconnected, .error:
                // A pending XID exchange keeps the session in .disconnected
                // until the answer (or its absence) resolves — that is a
                // connection in progress, never a refusal.
                if !isNegotiating(key: key) { return .refused }
            case .connecting, .disconnecting:
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return .timeout
    }

    // MARK: - Initialization

    init(
        localCallsign: AX25Address,
        clock: AX25TimerScheduler = AX25SystemTimerScheduler()
    ) {
        self.localCallsign = localCallsign
        self.clock = clock
    }

    // MARK: - Invariant Checking

    /// Asserts core state machine and session invariants.
    /// This prevents subtle bugs like queue desync, sequence number wrapping errors, and leaks.
    /// Runs in ALL builds. Violations report a non-fatal Sentry event (so a
    /// release build with corrupted window state is diagnosable — previously
    /// this whole body was compiled out) and then trap in debug so tests fail
    /// loudly. The checks are a handful of comparisons per call: negligible.
    func checkInvariants(session: AX25Session) {
        session.stateMachine.sequenceState.assertInvariants(windowSize: session.stateMachine.config.windowSize)

        // sendBuffer.count must exactly match outstanding frames according to V(S) and V(A)
        // If this fails, we have a memory leak (frames stuck in buffer) or a duplicate tracking bug.
        //
        // Only enforced while connected: a local disconnect deliberately clears
        // sendBuffer (clearPendingTransmissionState) while the sequence state
        // still counts frames that were in flight when DISC went out — e.g. a
        // B2F client sending FQ and immediately disconnecting. That divergence
        // is intentional teardown, not a leak.
        if session.state == .connected,
           session.sendBuffer.count != session.stateMachine.sequenceState.outstandingCount {
            TxLog.invariantViolation("sendBuffer count desynced from outstandingCount", [
                "sendBufferCount": session.sendBuffer.count,
                "outstandingCount": session.stateMachine.sequenceState.outstandingCount,
                "vs": session.vs, "va": session.va,
                "peer": session.remoteAddress.display
            ])
            assertionFailure("Invariant violation: sendBuffer.count (\(session.sendBuffer.count)) != outstandingCount (\(session.stateMachine.sequenceState.outstandingCount)). vs=\(session.vs) va=\(session.va)")
        }

        // Audit B4: AIMD numeric invariants — must hold after every operation.
        let cwnd = session.aimdWindow.cwnd
        if cwnd.isNaN || !cwnd.isFinite || cwnd < 1.0 || session.aimdWindow.effectiveWindow < 1 {
            TxLog.invariantViolation("AIMD window out of bounds", [
                "cwnd": cwnd.isFinite ? String(cwnd) : String(describing: cwnd),
                "effectiveWindow": session.aimdWindow.effectiveWindow,
                "peer": session.remoteAddress.display
            ])
            assertionFailure("AIMD invariant violated: cwnd=\(cwnd) effectiveWindow=\(session.aimdWindow.effectiveWindow)")
        }

        // NOTE: We do NOT assert outstandingCount <= effectiveSendWindow here.
        //
        // After a loss event (T1 timeout or REJ) cwnd is halved, but frames already
        // in flight cannot be "un-sent."  outstandingCount > effectiveSendWindow is a
        // valid transient state; it resolves as ACKs arrive and new sends are constrained
        // to the reduced window.  The send-site invariant (no NEW send exceeds the window)
        // is enforced in sendData and drainPendingDataQueue at the point of transmission,
        // and is tested explicitly in the audit test suite.
    }

    // MARK: - Deep Session Debug (Debug Builds Only)

    /// Emit a detailed snapshot of session state for debugging retries, timers, and window usage.
    /// This is intentionally verbose and only compiled into DEBUG builds.
    private func debugDumpSessionState(_ session: AX25Session, context: String) {
        if let emit = onLinkVizEvent {
            let sm = session.stateMachine
            emit(.snapshot(LinkWindowSnapshot(
                peer: session.remoteAddress.display,
                context: context,
                vs: sm.sequenceState.vs,
                va: sm.sequenceState.va,
                vr: sm.sequenceState.vr,
                outstanding: session.outstandingCount,
                windowSize: sm.config.windowSize,
                retryCount: sm.retryCount,
                sendBufferSeq: session.sendBuffer.keys.sorted(),
                rto: session.timers.rto,
                srtt: session.timers.srtt,
                rttvar: session.timers.rttvar,
                date: Date(),
                framesSent: session.statistics.framesSent,
                framesReceived: session.statistics.framesReceived,
                retransmissions: session.statistics.retransmissions,
                rejSent: session.statistics.rejSent)))
        }
#if DEBUG
        let sm = session.stateMachine
        let timers = session.timers

        let vs = sm.sequenceState.vs
        let vr = sm.sequenceState.vr
        let va = sm.sequenceState.va
        // Use session.outstandingCount (sendBuffer.count) not sequenceState.outstandingCount (vs-va mod 8)
        // After RR ack clears sendBuffer, va may advance past vs causing (vs-va) to wrap incorrectly
        let outstanding = session.outstandingCount

        var fields: [String: Any] = [
            "peer": session.remoteAddress.display,
            "session": String(session.id.uuidString.prefix(8)),
            "context": context,
            "state": sm.state.rawValue,
            "vs": vs,
            "va": va,
            "vr": vr,
            "outstanding": outstanding,
            "windowSize": sm.config.windowSize,
            "retryCount": sm.retryCount,
            "maxRetries": sm.config.maxRetries,
            "rto": String(format: "%.2f", timers.rto),
            "t3Timeout": String(format: "%.1f", timers.t3Timeout),
            "srtt": timers.srtt != nil ? String(format: "%.2f", timers.srtt!) : "nil",
            "rttvar": String(format: "%.2f", timers.rttvar)
        ]

        // Summarize send buffer contents for retransmit analysis
        if !session.sendBuffer.isEmpty {
            let nsValues = session.sendBuffer.keys.sorted()
            fields["sendBufferSeq"] = nsValues.map { String($0) }.joined(separator: ",")
            fields["sendBufferCount"] = nsValues.count
        } else {
            fields["sendBufferSeq"] = "(empty)"
            fields["sendBufferCount"] = 0
        }

        debugTrace("session-state", fields)
#endif
    }

    // MARK: - Session Lifecycle

    deinit {
        // Cancel any outstanding timers to avoid tasks running after teardown.
        // AX25SessionManager is @MainActor, so deinit should run on the main actor.
        MainActor.assumeIsolated {
            for session in sessions.values {
                session.t1TimerTask?.cancel()
                session.t3TimerTask?.cancel()
            }
            sessions.removeAll()
        }
    }

    /// Get or create a session for the given destination
    func session(
        for destination: AX25Address,
        path: DigiPath = DigiPath(),
        channel: UInt8 = 0
    ) -> AX25Session {
        let key = SessionKey(destination: destination, path: path, channel: channel)

        if let existing = sessions[key] {
            return existing
        }

        let pathSignature = path.display
        var config = getConfigForDestination?(destination.display, pathSignature) ?? defaultConfig
        // A completed XID exchange binds every future session with this
        // station: SREJ and the peer's receive ceilings apply whether the
        // next link is opened by us or by an inbound SABM.
        if negotiateV22, case .supported(let params) = peerXIDStatus[destination.display] {
            config = config.negotiating(with: params)
        }

        axDebugPrint("====== DEBUG TRACE: session(for:) ======")
        axDebugPrint("adaptiveTimeout: \(config.adaptiveTimeout)")
        axDebugPrint("hasGetConfig: \(getConfigForDestination != nil)")
        axDebugPrint("defaultAdaptive: \(defaultConfig.adaptiveTimeout)")
        axDebugPrint("session: \(destination.display)")
        axDebugPrint("========================================")

        let session = AX25Session(
            localAddress: localCallsign,
            remoteAddress: destination,
            path: path,
            channel: channel,
            config: config,
            isInitiator: true
        )
        sessions[key] = session

        TxLog.debug(.session, "Session created", [
            "session": String(session.id.uuidString.prefix(8)),
            "peer": destination.display,
            "path": path.display.isEmpty ? "(direct)" : path.display
        ])

        return session
    }

    /// Get existing session if any
    func existingSession(
        for destination: AX25Address,
        path: DigiPath = DigiPath(),
        channel: UInt8 = 0
    ) -> AX25Session? {
        let key = SessionKey(destination: destination, path: path, channel: channel)
        return sessions[key]
    }

    /// Find any connected session (useful for responder UIs that don't have destination set)
    /// Returns the most recently active connected session, or nil if none
    func anyConnectedSession() -> AX25Session? {
        return sessions.values
            .filter { $0.state == .connected }
            .max { $0.lastActivityAt < $1.lastActivityAt }
    }

    /// Find a connected session with a specific peer, regardless of who initiated.
    /// Uses exact address match first; falls back to CallsignNormalizer-based match.
    func connectedSession(withPeer peer: AX25Address) -> AX25Session? {
        if let exact = sessions.values.first(where: { $0.remoteAddress == peer && $0.state == .connected }) {
            return exact
        }
        // Fallback: match by call+SSID using canonical comparison (handles representation variances)
        let peerCall = CallsignNormalizer.parse(peer.display).call
        let peerSsid = peer.ssid
        return sessions.values.first { session in
            guard session.state == .connected else { return false }
            let (sessCall, sessSsid) = CallsignNormalizer.parse(session.remoteAddress.display)
            return sessCall.uppercased() == peerCall.uppercased() && sessSsid == peerSsid
        }
    }

    /// Find a connected session with a specific peer and channel
    func connectedSession(withPeer peer: AX25Address, channel: UInt8) -> AX25Session? {
        return sessions.values.first {
            $0.remoteAddress == peer &&
            $0.channel == channel &&
            $0.state == .connected
        }
    }

    /// Remove a session
    /// Drop a session that has already ENDED so a reconnect under the same
    /// key gets a fresh session — fresh config, fresh timers, fresh evidence
    /// counters. "Ended" means it terminated after running (.error, from any
    /// prior life) or completed a full connect/disconnect cycle — NOT a fresh
    /// session still awaiting its first SABM, whose queued data must survive.
    /// Live sessions are untouched. Returns any pending outbound data the
    /// carcass was still holding so the caller can re-queue it on the fresh
    /// session instead of silently dropping it.
    @discardableResult
    private func discardEndedSession(
        for destination: AX25Address, path: DigiPath, channel: UInt8
    ) -> [(data: Data, pid: UInt8, displayInfo: String?)] {
        let key = SessionKey(destination: destination, path: path, channel: channel)
        guard let stale = sessions[key],
              stale.state == .error
                || (stale.state == .disconnected && stale.hasEverConnected) else { return [] }
        stopT1Timer(for: stale)
        stopT2Timer(for: stale)
        stopT3Timer(for: stale)
        removeSession(stale)
        TxLog.debug(.session, "Discarded ended session for reconnect", [
            "peer": destination.display,
            "state": stale.state.rawValue,
            "session": String(stale.id.uuidString.prefix(8)),
            "orphanedQueue": stale.pendingDataQueue.count
        ])
        return stale.pendingDataQueue
    }

    func removeSession(_ session: AX25Session) {
        sessions.removeValue(forKey: session.key)
        // Nothing can hold a delivery claim on a session that no longer
        // exists; leaving one behind blocks all future connects to the peer.
        deliveryClaims[session.key] = nil

        TxLog.debug(.session, "Session removed", [
            "session": String(session.id.uuidString.prefix(8)),
            "peer": session.remoteAddress.display
        ])
    }

    /// Purge all sessions after a local callsign change.
    /// Active sessions (connecting/connected/disconnecting) are force-disconnected first,
    /// then ALL sessions are removed since they retain the stale `localAddress`.
    func purgeSessionsForCallsignChange() {
        guard !sessions.isEmpty else { return }

        let count = sessions.count
        for session in sessions.values {
            // Cancel timers to prevent background tasks from firing after removal
            session.t1TimerTask?.cancel()
            session.t1PendingRetransmitTask?.cancel()
            session.t3TimerTask?.cancel()

            switch session.state {
            case .connecting, .connected, .disconnecting:
                forceDisconnect(session: session)
            case .disconnected, .error:
                break
            }
        }

        sessions.removeAll()

        TxLog.debug(.session, "Purged all sessions for callsign change", [
            "purgedCount": count
        ])
    }

    /// Find a session that's expecting a UA response from the given source
    /// Used when the return path doesn't match the outbound path
    private func findSessionExpectingUA(
        from source: AX25Address,
        channel: UInt8
    ) -> AX25Session? {
        // Look for any session to this remote address that's in connecting or disconnecting state
        let sourceDisplay = source.display.uppercased()
        return sessions.values.first { session in
            session.remoteAddress.display.uppercased() == sourceDisplay &&
            session.channel == channel &&
            (session.state == .connecting || session.state == .disconnecting)
        }
    }

    /// Find any session for a remote address, regardless of state/path
    private func findAnySession(
        from source: AX25Address,
        channel: UInt8
    ) -> AX25Session? {
        let sourceDisplay = source.display.uppercased()
        return sessions.values.first { session in
            session.remoteAddress.display.uppercased() == sourceDisplay &&
            session.channel == channel
        }
    }

    /// Find any session for a remote callsign, ignoring SSID.
    /// Useful when remote responds on a different SSID than expected.
    private func findAnySessionByCallsign(
        from source: AX25Address,
        channel: UInt8
    ) -> AX25Session? {
        let sourceCall = normalizeCallsign(source.call)
        return sessions.values.first { session in
            normalizeCallsign(session.remoteAddress.call) == sourceCall &&
            session.channel == channel
        }
    }

    /// Find any session for a remote callsign, ignoring SSID and channel.
    /// Last-resort fallback when channel information is unreliable.
    private func findAnySessionByCallsignIgnoringChannel(
        from source: AX25Address
    ) -> AX25Session? {
        let sourceCall = normalizeCallsign(source.call)
        return sessions.values.first { session in
            normalizeCallsign(session.remoteAddress.call) == sourceCall
        }
    }

    private func normalizeCallsign(_ call: String) -> String {
        let upper = call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let dashIndex = upper.firstIndex(of: "-") {
            return String(upper[..<dashIndex])
        }
        return upper
    }

    private func connectingSession(withPeer peer: AX25Address, channel: UInt8) -> AX25Session? {
        let peerDisplay = peer.display.uppercased()
        return sessions.values.first { session in
            session.remoteAddress.display.uppercased() == peerDisplay &&
            session.channel == channel &&
            session.state == .connecting
        }
    }

    /// Find a connected session to the given remote address
    /// Used when the return path doesn't match the outbound path (common with digipeaters)
    private func findConnectedSession(
        from source: AX25Address,
        channel: UInt8
    ) -> AX25Session? {
        let sourceDisplay = source.display.uppercased()
        return sessions.values.first { session in
            session.remoteAddress.display.uppercased() == sourceDisplay &&
            session.channel == channel &&
            session.state == .connected
        }
    }

    /// Find a connected session for a remote callsign, ignoring SSID.
    private func findConnectedSessionByCallsign(
        from source: AX25Address,
        channel: UInt8
    ) -> AX25Session? {
        let sourceCall = normalizeCallsign(source.call)
        return sessions.values.first { session in
            normalizeCallsign(session.remoteAddress.call) == sourceCall &&
            session.channel == channel &&
            session.state == .connected
        }
    }

    // MARK: - Connection Management

    /// Initiate a connection to a remote station
    /// Returns the SABM frame to send
    func connect(
        to destination: AX25Address,
        path: DigiPath = DigiPath(),
        channel: UInt8 = 0
    ) -> OutboundFrame? {
        debugTrace("connect request", [
            "dest": destination.display,
            "path": path.display.isEmpty ? "(direct)" : path.display,
            "channel": channel
        ])
        if let existing = connectedSession(withPeer: destination, channel: channel) {
            logPathOverrideIfNeeded(session: existing, requestedPath: path, reason: "connect")
            TxLog.warning(.session, "Cannot connect: session already connected", [
                "peer": destination.display
            ])
            return nil
        }

        if let existing = connectingSession(withPeer: destination, channel: channel) {
            logPathOverrideIfNeeded(session: existing, requestedPath: path, reason: "connect")
            TxLog.warning(.session, "Cannot connect: session already connecting", [
                "peer": destination.display
            ])
            return nil
        }

        // A negotiation in flight is a connect in flight.
        //
        // While an XID is outstanding the session is still `.disconnected` —
        // it has not sent SABM yet — so neither guard above sees it, and every
        // further attempt put another XID on the air. An operator clicking a
        // station that was slow to answer produced a frame per click, for the
        // whole RTO, which on a marginal path is tens of seconds.
        if pendingXID[destination.display] != nil {
            TxLog.warning(.session, "Cannot connect: already negotiating with peer", [
                "peer": destination.display
            ])
            return nil
        }

        // Never reconnect through a dead session's carcass: its config (and
        // therefore the learned-RTO seed) was baked in at creation, and its
        // timers still hold the backed-off RTO it died with — after N2
        // exhaustion that is rtoMax, making the RETRY maximally sluggish.
        // Drop it so session(for:) builds a fresh one through
        // getConfigForDestination with current learned state; any data the
        // carcass was still holding rides along.
        let orphanedQueue = discardEndedSession(for: destination, path: path, channel: channel)

        let session = session(for: destination, path: path, channel: channel)
        session.pendingDataQueue.append(contentsOf: orphanedQueue)

        guard session.state == .disconnected || session.state == .error else {
            TxLog.warning(.session, "Cannot connect: session not disconnected", [
                "state": session.state.rawValue
            ])
            return nil
        }

        // A fresh attempt starts with a clean verdict — last hour's DM says
        // nothing about a peer that may have rebooted since.
        session.peerRefusedConnect = false

        // AX.25 2.2 negotiation: an unknown peer gets one XID command
        // before any SABM. Known peers use the cached outcome directly.
        if negotiateV22 {
            switch peerXIDStatus[destination.display] {
            case .none:
                // A remembered DM or FRMR is this peer's firmware speaking —
                // an answered rejection from a previous launch. Skip the
                // probe and go straight to SABM instead of re-spending a
                // frame and up to an RTO to relearn it.
                if xidMemory.isKnownUnsupported(destination.display) {
                    debugTrace("XID probe skipped — peer answered DM/FRMR before", [
                        "peer": destination.display
                    ])
                    peerXIDStatus[destination.display] = .unsupported
                } else {
                    return beginXIDNegotiation(session: session)
                }
            case .supported(let params):
                applyNegotiatedConfig(params, to: session)
            case .unsupported:
                break
            }
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .connectRequest)

        if oldState != session.state {
            debugTrace("state change (connect)", [
                "peer": destination.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        session.sabmSentAt = clock.currentTime
        session.sabmRetransmitted = false
        session.touch()

        debugTrace("sending SABM", [
            "peer": destination.display,
            "session": String(session.id.uuidString.prefix(8))
        ])
        return processActions(actions, for: session).first
    }

    /// Disconnect from a connected session
    /// Returns the DISC frame to send
    func disconnect(session: AX25Session) -> OutboundFrame? {
        guard session.state == .connected || session.state == .connecting else {
            TxLog.warning(.session, "Cannot disconnect: session not connected/connecting", [
                "state": session.state.rawValue
            ])
            return nil
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .disconnectRequest)

        if oldState != session.state {
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        // Clear sabmSentAt to prevent late UA from reopening the session
        session.sabmSentAt = nil
        // Stop any queued or in-flight data immediately on local disconnect request.
        session.clearPendingTransmission(reason: "Local disconnect requested")
        session.touch()
        return processActions(actions, for: session).first
    }

    /// Force disconnect immediately without on-air DISC/UA exchange.
    /// Use for emergency stop or immediate cancellation of a stuck connection.
    func forceDisconnect(session: AX25Session) {
        let oldState = session.state
        let actions = session.stateMachine.handle(event: .forceDisconnect)

        if oldState != session.state {
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        // Clear sabmSentAt to prevent late UA from reopening the session
        session.sabmSentAt = nil
        session.clearPendingTransmission(reason: "Force disconnect")
        session.touch()
        _ = processActions(actions, for: session)
    }

    // MARK: - XID negotiation flow

    /// Sends the XID command for a virgin session and arms the timeout
    /// that treats silence as "pre-2.2". Returns the XID frame.
    private func beginXIDNegotiation(session: AX25Session) -> OutboundFrame {
        let peerKey = session.remoteAddress.display
        let frame = AX25FrameBuilder.buildXID(
            from: session.localAddress,
            to: session.remoteAddress,
            via: session.path,
            parameters: localXIDParameters(config: session.stateMachine.config),
            isCommand: true,
            pf: true
        )
        debugTrace("TX XID command", ["peer": peerKey])

        let sessionKey = session.key
        let task = clock.schedule(delay: session.timers.rto) { [weak self] in
            guard let self else { return }
            guard self.pendingXID[peerKey] != nil else { return }
            TxLog.debug(.session, "XID timeout — peer treated as pre-2.2", ["peer": peerKey])
            self.resolveXID(peer: peerKey, status: .unsupported)
        }
        // Belt and braces now that `connect` refuses a duplicate: an
        // overwritten entry would leave its timeout running, and that stray
        // task resolves whichever negotiation is current when it fires.
        pendingXID[peerKey]?.task?.cancel()
        pendingXID[peerKey] = (key: sessionKey, task: task)
        session.touch()
        return frame
    }

    /// Resolves an in-flight negotiation and continues the deferred
    /// connect (SABM) with whatever was agreed.
    private func resolveXID(peer: String, status: PeerXIDStatus) {
        guard let pending = pendingXID.removeValue(forKey: peer) else { return }
        pending.task?.cancel()
        peerXIDStatus[peer] = status

        guard let session = sessions[pending.key],
              session.state == .disconnected || session.state == .error else { return }

        if case .supported(let params) = status {
            applyNegotiatedConfig(params, to: session)
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .connectRequest)
        if oldState != session.state {
            notifyStateChanged(session, from: oldState, to: session.state)
        }
        session.sabmSentAt = clock.currentTime
        session.sabmRetransmitted = false
        session.touch()
        for frame in processActions(actions, for: session) {
            onSendFrame?(frame)
        }
    }

    /// Rebuilds a virgin session's state machine with the negotiated
    /// parameters. Safe only before SABM: no sequence state exists yet.
    private func applyNegotiatedConfig(_ params: AX25XIDParameters, to session: AX25Session) {
        guard session.state == .disconnected || session.state == .error,
              session.stateMachine.sequenceState.vs == 0,
              session.stateMachine.sequenceState.vr == 0 else { return }
        let negotiated = session.stateMachine.config.negotiating(with: params)
        session.stateMachine = AX25StateMachine(config: negotiated)
        debugTrace("Negotiated config applied", [
            "peer": session.remoteAddress.display,
            "srej": negotiated.srejEnabled ? 1 : 0,
            "k": negotiated.windowSize,
            "paclen": negotiated.paclen
        ])
    }

    /// Handles an inbound XID frame — either the peer answering our
    /// command, or the peer opening its own negotiation.
    ///
    /// A malformed information field resolves as "unsupported": stranding
    /// the connect on a parse error would turn a peer bug into a dead
    /// button, and defaults are always safe.
    func handleInboundXID(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        info: Data,
        isCommand: Bool,
        pf: Bool
    ) -> [OutboundFrame] {
        let peerKey = source.display
        let parsed = AX25XIDParameters.parse(info)

        if isCommand {
            // The peer negotiates with us. Answer with the intersection of
            // its offer and our capabilities, and remember the outcome for
            // the SABM that follows.
            var ours = localXIDParameters(config: defaultConfig)
            ours.supportsSREJ = ours.supportsSREJ && (parsed?.supportsSREJ ?? false)
            if let parsed {
                peerXIDStatus[peerKey] = .supported(parsed)
            }
            debugTrace("RX XID command", ["peer": peerKey, "srej": ours.supportsSREJ ? 1 : 0])
            return [AX25FrameBuilder.buildXID(
                from: localCallsign,
                to: source,
                via: path,
                parameters: ours,
                isCommand: false,
                pf: pf
            )]
        }

        debugTrace("RX XID response", ["peer": peerKey, "parsed": parsed != nil ? 1 : 0])
        if let parsed {
            xidMemory.remember(peerKey, unsupported: false)
            resolveXID(peer: peerKey, status: .supported(parsed))
        } else {
            resolveXID(peer: peerKey, status: .unsupported)
        }
        return []
    }

    /// §6.3.2: a pre-2.2 peer answers an XID command with FRMR. During
    /// negotiation that is the documented "use defaults" — never an error.
    func handleInboundFRMRDuringNegotiation(from source: AX25Address, channel: UInt8) {
        guard pendingXID[source.display] != nil else { return }
        xidMemory.remember(source.display, unsupported: true)
        resolveXID(peer: source.display, status: .unsupported)
    }

    /// The other pre-2.2 answer, and the common one on this network: DM.
    ///
    /// §6.3.2 names FRMR, but a node that does not implement XID has no
    /// connection to the station that sent it and so replies "no such
    /// link" — which is exactly what DM means. BPQ does this. Without
    /// this case the DM landed on a `.disconnected` session, the state
    /// machine no-opped, and the negotiation ran out its full RTO before
    /// sending SABM: DRLNOD answered in 2.1 s on 2026-08-27 and the
    /// connect still waited until 8 s had elapsed. A definite answer is
    /// not something to keep waiting through.
    ///
    /// - Returns: true when the DM was consumed by the negotiation. The
    ///   caller must then NOT run normal DM handling: resolving sends the
    ///   deferred SABM, and a DM arriving at a `.connecting` session reads
    ///   as "connection refused" — the negotiation's own answer would
    ///   cancel the connect it just started.
    @discardableResult
    func handleInboundDMDuringNegotiation(from source: AX25Address, channel: UInt8) -> Bool {
        guard pendingXID[source.display] != nil else { return false }
        TxLog.debug(.session, "XID answered with DM — peer treated as pre-2.2", ["peer": source.display])
        xidMemory.remember(source.display, unsupported: true)
        resolveXID(peer: source.display, status: .unsupported)
        return true
    }

    // MARK: - Data Transmission

    /// Fragment payload into paclen-sized chunks for transmission
    private func fragment(_ data: Data, paclen: Int) -> [Data] {
        guard paclen > 0, !data.isEmpty else { return [] }
        if data.count <= paclen { return [data] }
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + paclen, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }

    /// Send data over a connected session
    /// Handles connection establishment if not yet connected
    /// Fragments payload per paclen; returns frames to send (may include SABM if not connected)
    func sendData(
        _ data: Data,
        to destination: AX25Address,
        path: DigiPath = DigiPath(),
        channel: UInt8 = 0,
        pid: UInt8 = 0xF0,
        displayInfo: String? = nil
    ) -> [OutboundFrame] {
        let session = selectSession(for: destination, path: path, channel: channel)
        let paclen = session.stateMachine.config.paclen
        let chunks = fragment(data, paclen: paclen)
        var frames: [OutboundFrame] = []

        switch session.state {
        case .disconnected, .error:
            // Need to connect first
            if let sabm = connect(to: destination, path: path, channel: channel) {
                frames.append(sabm)
            }
            // Queue each chunk for when connection is established
            for (i, chunk) in chunks.enumerated() {
                let info = (i == 0) ? displayInfo : nil
                session.pendingDataQueue.append((data: chunk, pid: pid, displayInfo: info))
            }
            TxLog.debug(.session, "Queued data pending connection", [
                "peer": destination.display,
                "size": data.count,
                "chunks": chunks.count,
                "queueDepth": session.pendingDataQueue.count
            ])

        case .connecting:
            // Already connecting, queue each chunk
            for (i, chunk) in chunks.enumerated() {
                let info = (i == 0) ? displayInfo : nil
                session.pendingDataQueue.append((data: chunk, pid: pid, displayInfo: info))
            }
            TxLog.debug(.session, "Queued data, connection in progress", [
                "peer": destination.display,
                "size": data.count,
                "chunks": chunks.count,
                "queueDepth": session.pendingDataQueue.count
            ])

        case .connected:
            guard !session.hasReceiveSequenceGap else {
                for (i, chunk) in chunks.enumerated() {
                    let info = (i == 0) ? displayInfo : nil
                    session.pendingDataQueue.append((data: chunk, pid: pid, displayInfo: info))
                }
                TxLog.debug(.session, "Queued data while receive sequence gap is unresolved", [
                    "peer": destination.display,
                    "size": data.count,
                    "chunks": chunks.count,
                    "receiveBufferCount": session.stateMachine.receiveBuffer.count,
                    "vr": session.vr
                ])
                return frames
            }

            // FIFO discipline: if older data is already queued, new chunks must go
            // behind it — transmitting them now would put newer bytes on the air
            // ahead of older ones and reorder the stream at the peer. (Caught by
            // AX25FieldFuzzTests: 12 queued messages arrived as 0,1,2,3,11,10,9,8,…)
            // Append and drain instead, so the oldest data claims the free window
            // slots; drained frames go out via onSendFrame.
            guard session.pendingDataQueue.isEmpty else {
                for (i, chunk) in chunks.enumerated() {
                    let info = (i == 0) ? displayInfo : nil
                    session.pendingDataQueue.append((data: chunk, pid: pid, displayInfo: info))
                }
                drainPendingDataQueue(for: session)
                checkInvariants(session: session)
                return frames
            }

            // Send chunks that fit in window; queue the rest.
            //
            // Audit B1 fix: AIMD window must be respected in the direct-send path, not only
            // in drainPendingDataQueue.  Without this check, sendData bursts up to K frames
            // regardless of the congestion window whenever outstandingCount < K — which
            // happens every time a loss+recovery cycle empties the send buffer.
            //
            // effectiveSendWindow = min(K, aimdWindow.effectiveWindow).  canSendIFrame stays
            // as the sequence-number gate; the outstandingCount check is the AIMD gate.
            var remaining: [(data: Data, pid: UInt8, displayInfo: String?)] = []
            let aimdEffectiveDirect = session.aimdWindow.effectiveWindow
            let effectiveSendWindowDirect = min(session.stateMachine.config.windowSize, aimdEffectiveDirect)
            axDebugPrint("[DEBUG:AX25:SEND] sendData connected | dest=\(destination.display) totalChunks=\(chunks.count) paclen=\(paclen) canSend=\(session.canSendIFrame) aimdEffective=\(aimdEffectiveDirect) effectiveWindow=\(effectiveSendWindowDirect) va=\(session.va) vs=\(session.vs)")
            for (i, chunk) in chunks.enumerated() {
                guard session.canSendIFrame, session.outstandingCount < effectiveSendWindowDirect else {
                    let info = (i == 0) ? displayInfo : nil
                    remaining.append((data: chunk, pid: pid, displayInfo: info))
                    axDebugPrint("[DEBUG:AX25:SEND] window full, queue chunk \(i) | remaining=\(remaining.count)")
                    continue
                }
                let info = (i == 0) ? displayInfo : nil
                let wasIdle = session.outstandingCount == 0
                // Checkpoint (§6.2): the frame that fills the send window
                // carries P=1, matching what RMS gateways do on the air
                // (field capture 2026-08-24: every burst poll-terminated).
                // The peer's mandatory F=1 response acks the whole burst at
                // once — essential now that receivers may delay acks on T2.
                // Deliberately only on window-full, not on every burst end:
                // DRLNOD DMs sessions that poll on every idle line (see
                // shouldPollFirstOutboundIFrame).
                let fillsWindow = session.outstandingCount + 1 >= effectiveSendWindowDirect
                let ns = session.vs  // Capture before buildIFrame increments vs
                let iFrame = buildIFrame(
                    for: session,
                    payload: chunk,
                    pid: pid,
                    displayInfo: info,
                    pf: fillsWindow || shouldPollFirstOutboundIFrame(for: session, wasIdle: wasIdle)
                )
                frames.append(iFrame)
                axDebugPrint("[DEBUG:AX25:SEND] immediate tx chunk \(i) | N(S)=\(ns) payload=\(chunk.count)")

                session.bufferFrame(iFrame, ns: ns)  // ns, not vs-1 (avoids -1 when vs wraps 7->0)
                session.recordSendTime(ns: ns, time: clock.currentTime)
                session.statistics.recordSent(bytes: chunk.count)
                session.touch()

                if wasIdle {
                    // Transition from idle to active: stop T3 keepalive, start T1 retransmit timer.
                    // Per AX.25 spec, T3 and T1 are mutually exclusive — T1 takes over when
                    // there are outstanding unacked frames.
                    stopT3Timer(for: session)
                    startT1Timer(for: session)
                }
            }
            // Append, never prepend: the queue was empty when this call started
            // (guard above), and any chunks another path queues concurrently are
            // older than these. insert(at: 0) here reversed message order across
            // successive sendData calls once the window filled.
            session.pendingDataQueue.append(contentsOf: remaining)
            if !remaining.isEmpty {
                axDebugPrint("[DEBUG:AX25:SEND] queued remaining | count=\(remaining.count) queueDepth=\(session.pendingDataQueue.count)")
                TxLog.debug(.session, "Window filled, queued remaining chunks", [
                    "peer": destination.display,
                    "remaining": remaining.count,
                    "queueDepth": session.pendingDataQueue.count
                ])
            }
            
            checkInvariants(session: session)

        case .disconnecting:
            TxLog.warning(.session, "Cannot send: session disconnecting")
        }

        return frames
    }

    private func selectSession(
        for destination: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) -> AX25Session {
        if let connected = connectedSession(withPeer: destination, channel: channel) {
            logPathOverrideIfNeeded(session: connected, requestedPath: path, reason: "sendData")
            return connected
        }

        if let connecting = connectingSession(withPeer: destination, channel: channel) {
            logPathOverrideIfNeeded(session: connecting, requestedPath: path, reason: "sendData")
            return connecting
        }

        return session(for: destination, path: path, channel: channel)
    }

    private func logPathOverrideIfNeeded(
        session: AX25Session,
        requestedPath: DigiPath,
        reason: String
    ) {
        guard session.path != requestedPath else { return }

        let currentPath = session.path.display.isEmpty ? "(direct)" : session.path.display
        let requested = requestedPath.display.isEmpty ? "(direct)" : requestedPath.display

        TxLog.debug(.path, "Using existing session path", [
            "peer": session.remoteAddress.display,
            "current": currentPath,
            "requested": requested,
            "reason": reason
        ])
    }

    // MARK: - Inbound Frame Handling

    /// Handle an inbound SABM (connection request)
    func handleInboundSABM(
        from source: AX25Address,
        to destination: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) -> OutboundFrame? {
        debugTrace("SABM received", [
            "from": source.display,
            "to": destination.display,
            "local": localCallsign.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "channel": channel
        ])

        // Create session if it doesn't exist (we're the responder). A LIVE
        // existing session is reused — SABM into a connected session is the
        // spec's link reset and belongs to the state machine. A DEAD one is
        // replaced: (.error, .receivedSABM) has no transition at all, so the
        // carcass would answer the peer's fresh connect with silence, and its
        // stale config/timers predate the route's current learned state.
        discardEndedSession(for: source, path: path, channel: channel)
        let key = SessionKey(destination: source, path: path, channel: channel)

        let session: AX25Session
        if let existing = sessions[key] {
            debugTrace("SABM existing session", [
                "peer": source.display,
                "state": existing.state.rawValue
            ])
            session = existing
        } else {
            debugTrace("SABM creating session", [
                "peer": source.display
            ])
            let pathSignature = path.display
            var config = getConfigForDestination?(source.display, pathSignature) ?? defaultConfig
            // Honor a completed XID exchange (see session(for:)): the SABM
            // following our XID response must open the link with what the
            // response promised.
            if negotiateV22, case .supported(let params) = peerXIDStatus[source.display] {
                config = config.negotiating(with: params)
            }
            session = AX25Session(
                localAddress: destination,  // We're the destination of the SABM
                remoteAddress: source,
                path: path,
                channel: channel,
                config: config,
                isInitiator: false
            )
            sessions[key] = session
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedSABM)
        debugTrace("SABM state transition", [
            "peer": source.display,
            "from": oldState.rawValue,
            "to": session.state.rawValue,
            "actions": actions.map { String(describing: $0) }.joined(separator: ",")
        ])

        if oldState != session.state {
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        if session.state == .connected {
            session.connectedAt = Date()
        }

        session.touch()
        let frames = processActions(actions, for: session)
        print("[AX25SessionManager] processActions returned \(frames.count) frames")
        if let frame = frames.first {
            print("[AX25SessionManager] Returning UA frame to \(frame.destination.display)")
        }
        return frames.first
    }

    /// Handle an inbound UA (unnumbered acknowledge)
    func handleInboundUA(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) {
        debugTrace("UA received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "channel": channel
        ])
        // Try to find session with exact path match first
        var session = existingSession(for: source, path: path, channel: channel)

        // If not found, try to find any session to this remote address that's expecting a UA
        // This handles the common case where the return path differs from the outbound path
        // (digipeaters modify the path on return, or the path is empty on the response)
        if session == nil {
            session = findSessionExpectingUA(from: source, channel: channel)
            if session != nil {
                TxLog.debug(.session, "Found session with different path", [
                    "from": source.display,
                    "expectedPath": session?.path.display ?? "(none)",
                    "receivedPath": path.display.isEmpty ? "(empty)" : path.display
                ])
            }
        }

        // If still not found, fall back to any session for this peer (late UA or path mismatch)
        if session == nil {
            session = findAnySession(from: source, channel: channel)
            if session != nil {
                TxLog.debug(.session, "Found session by peer only (late UA)", [
                    "from": source.display,
                    "state": session?.state.rawValue ?? "unknown",
                    "expectedPath": session?.path.display ?? "(none)",
                    "receivedPath": path.display.isEmpty ? "(empty)" : path.display
                ])
            }
        }

        // Last resort: match by callsign only (SSID mismatch)
        if session == nil {
            session = findAnySessionByCallsign(from: source, channel: channel)
            if session != nil {
                TxLog.debug(.session, "Found session by callsign only (SSID mismatch)", [
                    "from": source.display,
                    "state": session?.state.rawValue ?? "unknown",
                    "expectedPeer": session?.remoteAddress.display ?? "(none)"
                ])
            }
        }

        // Final fallback: match by callsign even if channel differs
        if session == nil {
            session = findAnySessionByCallsignIgnoringChannel(from: source)
            if session != nil {
                TxLog.debug(.session, "Found session by callsign (ignoring channel)", [
                    "from": source.display,
                    "state": session?.state.rawValue ?? "unknown",
                    "expectedPeer": session?.remoteAddress.display ?? "(none)",
                    "expectedChannel": session?.channel ?? -1
                ])
            }
        }

        guard let session = session else {
            debugTrace("UA for unknown session", [
                "from": source.display
            ])
            TxLog.warning(.session, "UA received for unknown session", ["from": source.display])
            return
        }

        // If we timed out and fell back to disconnected, allow a late UA to complete the connect.
        if session.state == .disconnected || session.state == .error {
            var allowLateUA = false
            if let sabmSent = session.sabmSentAt {
                let elapsed = clock.currentTime - sabmSent
                if elapsed <= max(session.timers.rto * 2.0, 5.0) {
                    allowLateUA = true
                    TxLog.debug(.session, "Treating late UA as connect completion", [
                        "peer": source.display,
                        "elapsed": String(format: "%.2fs", elapsed)
                    ])
                    debugTrace("late UA accepted", [
                        "peer": source.display,
                        "elapsed": String(format: "%.2fs", elapsed)
                    ])
                }
            }
            if !allowLateUA {
                debugTrace("UA ignored (session not connecting)", [
                    "peer": source.display,
                    "state": session.state.rawValue
                ])
                return
            }
        }

        let oldState = session.state

        // Calculate RTT if we were connecting (Bug F fix: use clock.currentTime not Date())
        //
        // Karn's algorithm, which the I-frame path already honours via
        // `rttSendTime(ackedBy:)`: a UA answering a retransmitted SABM is
        // ambiguous, so it yields no sample at all. The timers keep whatever
        // they had, which is a better estimate than one built from backoff.
        if session.state == .connecting, let sabmSent = session.sabmSentAt,
           !session.sabmRetransmitted {
            let rtt = clock.currentTime - sabmSent
            session.timers.updateRTT(sample: rtt)
            TxLog.rttUpdate(
                peer: source.display,
                srtt: session.timers.srtt ?? rtt,
                rttvar: session.timers.rttvar,
                rto: session.timers.rto
            )
        }

        let actions = session.stateMachine.handle(event: .receivedUA)

        if oldState != session.state {
            debugTrace("state change (UA)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        // Execute the state machine's actions BEFORE draining. The UA actions
        // include .stopT1 (cancelling the SABM timer) — computed when nothing was
        // outstanding. The drain below can put fresh I-frames on the air and start
        // T1 for them; running the stale stopT1 afterwards would cancel that timer
        // and leave unacknowledged frames with no retransmit protection (field
        // capture 2026-08-22: "Starting T1 timer" from the drain immediately
        // followed by "Stopping T1 timer" from the stale action).
        _ = processActions(actions, for: session)

        if session.state == .connected {
            session.connectedAt = Date()
            TxLog.sessionOpen(
                sessionId: session.id,
                peer: source.display,
                mode: "connected"
            )

            // Drain pending data queue now that we're connected
            drainPendingDataQueue(for: session)
        } else if session.state == .disconnected {
            TxLog.sessionClose(
                sessionId: session.id,
                peer: source.display,
                reason: "Normal disconnect"
            )
        }

        session.touch()
    }

    /// Handle an inbound DM (disconnected mode)
    func handleInboundDM(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) {
        debugTrace("DM received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "channel": channel
        ])
        // Try to find session with exact path match first
        var session = existingSession(for: source, path: path, channel: channel)

        // If not found, try to find any session to this remote address that's expecting a response
        if session == nil {
            session = findSessionExpectingUA(from: source, channel: channel)
        }
        if session == nil {
            session = findAnySession(from: source, channel: channel)
        }
        if session == nil {
            session = findAnySessionByCallsign(from: source, channel: channel)
        }

        guard let session = session else {
            debugTrace("DM for unknown session", [
                "from": source.display
            ])
            // Warning: this is the classic desync signature — the peer thinks
            // we are disconnected while we hold no matching session. Debug
            // level made it invisible in the field.
            TxLog.warning(.session, "DM received for unknown session (state desync?)", ["from": source.display])
            return
        }

        let oldState = session.state
        // A DM while we were connecting is the peer refusing our SABM
        // (§6.3.1) — record it before the state machine erases the context.
        if oldState == .connecting {
            session.peerRefusedConnect = true
        }
        let actions = session.stateMachine.handle(event: .receivedDM)

        if oldState != session.state {
            debugTrace("state change (DM)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }
        session.touch()
        _ = processActions(actions, for: session)
    }

    /// Handle an inbound FRMR (frame reject).
    ///
    /// FRMR means the peer received something it considers an unrecoverable
    /// protocol violation from us. Until this entry point existed, inbound
    /// FRMR was decoded and displayed but silently ignored by the session
    /// layer — the state machine's handler was dead code. The session moves to
    /// .error and the operator is notified; reconnecting issues a fresh SABM,
    /// which is the §6.4.10-sanctioned recovery for v2.0 peers.
    func handleInboundFRMR(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) {
        debugTrace("FRMR received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "channel": channel
        ])
        var session = existingSession(for: source, path: path, channel: channel)
        if session == nil {
            session = findAnySession(from: source, channel: channel)
        }
        if session == nil {
            session = findAnySessionByCallsign(from: source, channel: channel)
        }
        guard let session = session else {
            TxLog.warning(.session, "FRMR received for unknown session", ["from": source.display])
            return
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedFRMR)

        if oldState != session.state {
            debugTrace("state change (FRMR)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }
        session.touch()
        _ = processActions(actions, for: session)
    }

    /// Handle an inbound DISC (disconnect request)
    func handleInboundDISC(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) -> OutboundFrame? {
        debugTrace("DISC received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "channel": channel
        ])
        // Use findConnectedSession to match a connected session from this peer (common
        // with digipeaters where return path differs). Also check .disconnecting: per
        // AX.25 §6.4.2, if we sent DISC and receive DISC back simultaneously, we must
        // respond UA and finish teardown — not send DM as if no session existed.
        let disconnecting = sessions.values.first {
            $0.remoteAddress.display.uppercased() == source.display.uppercased() &&
            $0.channel == channel &&
            $0.state == .disconnecting
        }
        // Bug I fix: also match a session in .connecting state.
        // Previously, if the remote peer refused the connection by sending DISC before we
        // received their UA, findConnectedSession returned nil, no state transition occurred,
        // and the session remained stuck in .connecting — continuing to retransmit SABM until
        // T1 max-retries expired. Per AX.25 §6.3.4, a DISC received while connecting MUST
        // cause an immediate disconnect: send DM and cancel the connect attempt.
        let connecting = sessions.values.first {
            $0.remoteAddress.display.uppercased() == source.display.uppercased() &&
            $0.channel == channel &&
            $0.state == .connecting
        }
        guard let session = findConnectedSession(from: source, channel: channel) ?? disconnecting ?? connecting else {
            debugTrace("DISC with no session -> DM", [
                "from": source.display
            ])
            // No session - respond with DM
            return AX25FrameBuilder.buildDM(
                from: localCallsign,
                to: source,
                via: path
            )
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedDISC)

        // A DISC no longer always ends the session: per SDL C4.2, a DISC received
        // while our SABM is outstanding is answered with DM and the connect attempt
        // continues. Only perform teardown bookkeeping when the state machine
        // actually left the link.
        let sessionEnded = session.state == .disconnected

        // Clear send buffer and notify UI that frames are acknowledged.
        // When remote sends DISC in response to our I-frame (e.g., "bye" command),
        // they clearly received it. Mark as delivered for UX purposes.
        if sessionEnded && !session.sendBuffer.isEmpty {
            let bufferedFrames = session.sendBuffer.keys.sorted()
            TxLog.debug(.session, "Clearing send buffer on DISC", [
                "peer": source.display,
                "bufferedNS": bufferedFrames.map { String($0) }.joined(separator: ",")
            ])
            session.clearPendingTransmission(reason: "remote DISC")
            // Notify that all frames are considered acknowledged
            notifyOutboundAck(session, upTo: session.vs)
        }

        if oldState != session.state {
            debugTrace("state change (DISC)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        if sessionEnded {
            TxLog.sessionClose(
                sessionId: session.id,
                peer: source.display,
                reason: "Remote DISC"
            )
        }

        session.touch()
        return processActions(actions, for: session).first
    }

    /// Handle an inbound I-frame (information)
    /// - Parameters:
    ///   - source: Remote station address
    ///   - path: Digipeater path
    ///   - channel: KISS channel
    ///   - ns: N(S) sequence number
    ///   - nr: N(R) sequence number
    ///   - pf: P/F bit - if true, we must respond with F=1
    ///   - payload: Frame payload
    /// - Returns: Response frame (RR or REJ) to send
    func handleInboundIFrame(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        ns: Int,
        nr: Int,
        pf: Bool = false,
        payload: Data,
        pid: UInt8? = nil
    ) -> OutboundFrame? {
        debugTrace("I-frame received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "ns": ns,
            "nr": nr,
            "pf": pf ? 1 : 0,
            "len": payload.count
        ])
        onLinkVizEvent?(.inboundIFrame(peer: source.display, ns: ns, bytes: payload.count))
        // Try exact path match first, then fall back to address-only lookup
        var session = existingSession(for: source, path: path, channel: channel)
        if session == nil {
            session = findConnectedSession(from: source, channel: channel)
        }
        if session == nil {
            session = findConnectedSessionByCallsign(from: source, channel: channel)
        }

        if session == nil {
            // Fall back to any session for this peer, regardless of state.
            // This avoids tearing down valid links when path/state lookup fails.
            if let anySession = findAnySession(from: source, channel: channel) {
                TxLog.warning(.session, "I-frame received for non-connected session", [
                    "peer": source.display,
                    "state": anySession.state.rawValue
                ])
                return nil
            }
            if let anySession = findAnySessionByCallsign(from: source, channel: channel) {
                TxLog.warning(.session, "I-frame received for non-connected session (SSID mismatch)", [
                    "peer": source.display,
                    "state": anySession.state.rawValue,
                    "expectedPeer": anySession.remoteAddress.display
                ])
                return nil
            }
            if let anySession = findAnySessionByCallsignIgnoringChannel(from: source) {
                TxLog.warning(.session, "I-frame received for non-connected session (channel mismatch)", [
                    "peer": source.display,
                    "state": anySession.state.rawValue,
                    "expectedPeer": anySession.remoteAddress.display,
                    "expectedChannel": anySession.channel
                ])
                return nil
            }

            // §6.3.5: with no session at all we are in the disconnected state for
            // this peer, and a command frame with P=1 must be answered with DM(F=1).
            // I frames are always commands in AX.25 v2.2. The P=1 gate is the spec's
            // own protection against DM storms: digipeated duplicates carry P=0 and
            // are ignored, while a deliberate poll gets the answer that lets the
            // peer clear its stale session instead of retrying until N2.
            if pf {
                debugTrace("I-frame poll with no session -> DM", ["from": source.display])
                return AX25FrameBuilder.buildDM(from: localCallsign, to: source, via: path)
            }
            TxLog.warning(.session, "I-frame received with no matching session; ignoring", [
                "from": source.display,
                "path": path.display.isEmpty ? "(empty)" : path.display,
                "ns": ns,
                "nr": nr,
                "pf": pf ? 1 : 0
            ])
            debugTrace("I-frame with no session (ignored, no DM)", [
                "from": source.display,
                "path": path.display.isEmpty ? "(empty)" : path.display
            ])
            return nil
        }

        guard let session = session else {
            TxLog.warning(.session, "I-frame received but no session after lookup", [
                "from": source.display
            ])
            return nil
        }

        if session.state == .connecting {
            // Stale remote state: the peer is sending numbered traffic before
            // accepting our SABM. Let the state machine emit DM to reset the
            // remote phantom session while our connect attempt continues.
            let actions = session.stateMachine.handle(event: .receivedIFrame(ns: ns, nr: nr, pf: pf, payload: payload, pid: pid))
            session.touch()
            return processActions(actions, for: session).first
        }

        guard session.state == .connected else {
            TxLog.warning(.session, "I-frame received but not connected", [
                "state": session.state.rawValue
            ])
            return nil
        }

        // Capture V(A) before state machine updates it - piggybacked N(R) acks [V(A), N(R))
        let vaBefore = session.va

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedIFrame(ns: ns, nr: nr, pf: pf, payload: payload, pid: pid))

        if oldState != session.state {
            debugTrace("state change (I-frame)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        // Acknowledge received frames in our send buffer: remove [vaBefore, vaAfter)
        // Bug J fix: use state-machine-validated V(A) instead of raw N(R) from frame.
        // If the state machine rejects the piggybacked N(R) (e.g., nr is outside the valid
        // window [V(A), V(S)]), session.va stays at vaBefore so vaAfter == vaBefore and
        // acknowledgeUpTo is a no-op — preventing spurious sendBuffer deletions that would
        // corrupt the sendBuffer.count == outstandingCount invariant.
        // Root cause: identical to Bug B3 (fixed in handleInboundRR) — raw nr was threaded
        // directly into acknowledgeUpTo, bypassing the state machine's window validation.
        let vaAfter = session.va
        session.acknowledgeUpTo(from: vaBefore, to: vaAfter)
        session.statistics.recordReceived(bytes: payload.count)
        session.touch()

        // Record the actual inbound via path so callbacks can thread it to the UI.
        session.lastReceivedVia = path.digis.map { $0.display }

        notifyOutboundAck(session, upTo: session.va)

        // Execute the state machine's actions BEFORE draining: the actions can carry
        // .stopT1 (computed while nothing was outstanding), and the drain below may
        // transmit fresh I-frames and start T1 for them. Running the stale stopT1
        // after the drain cancels the timer protecting the new frames.
        let responseFrame = processActions(actions, for: session).first

        if session.state == .connected && !session.hasReceiveSequenceGap && !session.pendingDataQueue.isEmpty {
            let queueBeforeDrain = session.pendingDataQueue.count
            drainPendingDataQueue(for: session)
            let drained = queueBeforeDrain - session.pendingDataQueue.count
            if drained > 0 {
                TxLog.debug(.session, "Drain completed after receive gap cleared", [
                    "peer": session.remoteAddress.display,
                    "drained": drained,
                    "remaining": session.pendingDataQueue.count
                ])
            }
        }

        // Deep debug snapshot whenever we successfully process an inbound I-frame.
        debugDumpSessionState(session, context: "inbound-I")
        checkInvariants(session: session)

        // The piggybacked N(R) is an acknowledgement like any other — without
        // this, a peer that never sends standalone RRs (the BBS pattern)
        // starves the adaptive controller of evidence entirely.
        emitLinkQualitySampleIfNeeded(for: session)

        return responseFrame
    }

    /// Handle an inbound RR (receive ready)
    /// - Parameters:
    ///   - source: Remote station address
    ///   - path: Digipeater path
    ///   - channel: KISS channel
    ///   - nr: N(R) from the frame
    ///   - pf: Whether the P/F bit is set
    ///   - isCommand: Whether the S-frame is an AX.25 command. Only command
    ///     frames with P/F set are polls; response frames with F set are not.
    /// - Returns: Response frame (RR with F=1) if this was a poll, nil otherwise
    func handleInboundRRFrames(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        nr: Int,
        pf: Bool = false,
        isCommand: Bool = false
    ) -> [OutboundFrame] {
        let isPoll = pf && isCommand
        debugTrace("RR received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "nr": nr,
            "pf": pf ? 1 : 0,
            "isCommand": isCommand ? 1 : 0
        ])
        // Try exact path match first, then fall back to address-only lookup
        var session = existingSession(for: source, path: path, channel: channel)
        if session == nil {
            session = findConnectedSession(from: source, channel: channel)
        }
        if session == nil {
            session = findConnectedSessionByCallsign(from: source, channel: channel)
        }

        guard let session = session else {
            debugTrace("RR for unknown session", [
                "from": source.display,
                "pf": pf ? 1 : 0,
                "isCommand": isCommand ? 1 : 0
            ])
            // §6.3.5: with no session we are in the disconnected state for this peer.
            // "Any TNC receiving a command frame other than a SABM(E) or UI frame with
            // the P bit set to '1' responds with a DM frame with the F bit set to '1'."
            // This is what lets a peer holding a stale session (e.g. after we crashed
            // or restarted) clear it promptly instead of polling until its N2 expires.
            // P=0 frames and response frames are ignored per the same sentence.
            if pf && isCommand {
                return [AX25FrameBuilder.buildDM(from: localCallsign, to: source, via: path)]
            }
            return []
        }

        // Measure RTT from last acked frame so T1 (RTO) adapts during transfer.
        // Bug E fix (Karn's algorithm): rttSendTime(ackedBy:) returns nil for
        // any frame that was retransmitted, because the ACK is ambiguous — it
        // might correspond to the original or the retransmit. Using the original
        // send time would overstate RTT by including the retransmit wait.
        // Bug F fix: use clock.currentTime instead of Date() for determinism.
        if let sentAt = session.rttSendTime(ackedBy: nr) {
            let rtt = clock.currentTime - sentAt
            session.timers.updateRTT(sample: rtt)
            TxLog.rttUpdate(
                peer: source.display,
                srtt: session.timers.srtt ?? rtt,
                rttvar: session.timers.rttvar,
                rto: session.timers.rto
            )
        }
        session.clearSendTimesAcked(by: nr)

        // Capture V(A) BEFORE state machine update - RR only acks [V(A), N(R))
        let vaBefore = session.va

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedRR(nr: nr, pf: pf, isCommand: isCommand))

        if oldState != session.state {
            debugTrace("state change (RR)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        // Acknowledge received frames: remove only [vaBefore, nr) - not all ns < nr.
        // When N(S) wraps, ns=0,1,2 may be newer frames; RR(nr=4) acks the FIRST use
        // of 0,1,2,3 (PING/test/chunks), not the WRAPPED use (later chunks).
        // Audit B3 fix: capture the VA the state machine actually accepted — not the raw nr
        // field from the frame.  If the state machine rejects the RR (e.g. nr is outside the
        // valid window), session.va stays at vaBefore and vaAfter == vaBefore, so ackedCount=0
        // and acknowledgeUpTo is a no-op.  Previously the raw `nr` was used in both places,
        // causing spurious sendBuffer removals and onAck() calls for out-of-window NRs.
        let vaAfter = session.va

        let sendBufKeysBefore = session.sendBuffer.keys.sorted()
        session.acknowledgeUpTo(from: vaBefore, to: vaAfter)
        let sendBufKeysAfter = session.sendBuffer.keys.sorted()

        // Bug G fix: AIMD additive increase per acknowledged frame.
        // Call onAck() once for each frame that RR(nr) newly acknowledges so that
        // the congestion window grows proportionally to confirmed delivery.
        // Only grow when frames were actually acked (vaAfter != vaBefore) to avoid
        // spurious growth from duplicate, no-progress, or state-machine-rejected RRs.
        let modulo = session.stateMachine.config.modulo
        let ackedCount = (vaAfter - vaBefore + modulo) % modulo
        if ackedCount > 0 {
            for _ in 0..<ackedCount {
                session.aimdWindow.onAck()
            }
        }

        session.touch()

        axDebugPrint("[DEBUG:AX25:RR] rx | nr=\(nr) va=\(session.va) vs=\(session.vs) sendBufBefore=\(sendBufKeysBefore) sendBufAfter=\(sendBufKeysAfter) outstanding=\(session.outstandingCount)")
        notifyOutboundAck(session, upTo: session.va)

        TxLog.debug(.session, "RR ACK state", [
            "peer": source.display,
            "va": session.va,
            "vs": session.vs,
            "outstanding": session.outstandingCount,
            "queueDepth": session.pendingDataQueue.count
        ])

        // Outstanding count BEFORE the drain. The no-ACK-progress retransmit below must
        // only consider frames the peer has actually had a chance to see — the drain can
        // put brand-new I-frames on the air microseconds earlier, and retransmitting those
        // immediately sends every freshly drained frame twice.
        let outstandingBeforeDrain = session.outstandingCount

        // Execute the state machine's actions BEFORE draining. The RR actions can
        // carry .stopT1 (all frames acked at handle time); the drain below may put a
        // fresh I-frame on the air and start T1 for it. Running the stale stopT1
        // afterwards cancelled that timer and left the new frame with no retransmit
        // protection until the T3 enquiry — observed live on 2026-08-22 when "bbs"
        // was drained by an RR(F=1) and immediately stripped of its T1.
        let actionFrames = processActions(actions, for: session)
        var responseFrames = actionFrames

        // Drain pending queue now that window space freed (paclen-fragmented chunks)
        let queueBeforeDrain = session.pendingDataQueue.count
        drainPendingDataQueue(for: session)
        let drained = queueBeforeDrain - session.pendingDataQueue.count
        if drained > 0 {
            TxLog.debug(.session, "Drain completed", [
                "peer": session.remoteAddress.display,
                "drained": drained,
                "remaining": session.pendingDataQueue.count
            ])
        }

        // Deep debug snapshot whenever we advance ACK state from RR.
        debugDumpSessionState(session, context: isPoll ? "inbound-RR-poll" : "inbound-RR")

        if isPoll && session.state == .connected && outstandingBeforeDrain > 0 && vaAfter == vaBefore {
            // Every poll-driven retransmit must climb the N2 ladder. The peer's
            // polls arrive inside our RTO, so each one used to restart T1 before
            // it could expire — retryCount froze at 0 and the session
            // retransmitted the same frame forever (livelock, field capture
            // 2026-08-22). Now a peer that polls without ever acking exhausts
            // N2 exactly like unanswered T1 expiries would.
            let failureActions = session.stateMachine.noteRetransmissionWithoutProgress()
            guard failureActions.isEmpty else {
                TxLog.warning(.session, "RR poll retransmission ladder exhausted N2", [
                    "peer": session.remoteAddress.display,
                    "retries": session.stateMachine.retryCount
                ])
                notifyStateChanged(session, from: .connected, to: session.state)
                responseFrames.append(contentsOf: processActions(failureActions, for: session))
                // Final evidence flush: the retransmissions that exhausted N2
                // are the loss the next attempt on this route must know about.
                emitLinkQualitySampleIfNeeded(for: session)
                return responseFrames
            }

            TxLog.debug(.session, "RR poll made no ACK progress; retransmitting outstanding frames", [
                "peer": session.remoteAddress.display,
                "va": session.va,
                "vs": session.vs,
                "vr": session.vr,
                "outstanding": session.outstandingCount,
                "retryCount": session.stateMachine.retryCount
            ])

            responseFrames.append(contentsOf: retransmitOutstandingFrames(for: session, from: session.va, reason: "inbound-RR-poll-no-ack"))
            if responseFrames.contains(where: { $0.frameType == "i" }) {
                session.consecutiveT1PollsWithoutAck = 0
                startT1Timer(for: session)
            }
        }

        checkInvariants(session: session)

        emitLinkQualitySampleIfNeeded(for: session)

        return responseFrames
    }

    /// Feed link-quality evidence into the adaptive settings (session-based
    /// learning). Called from EVERY inbound path that can advance V(A) or
    /// trigger retransmission — I-frames (piggybacked N(R)), RR, RNR and REJ.
    ///
    /// A chatty peer such as a BBS acks almost exclusively by piggybacking
    /// N(R) on its own I-frames; sampling only in the RR handler starved the
    /// controller for whole sessions (field capture 2026-08-22, YZBBPQ).
    ///
    /// Only with real evidence: the session must be connected and must have
    /// put at least one I-frame on the air. Without the gate, RR polls from
    /// a peer's stale session arriving while we were still CONNECTING (four
    /// unanswered SABMs deep) produced loss=0/0 → "Good link quality" —
    /// adaptive announcing a great link to a station we could not reach at
    /// all (field capture 2026-08-22). SABMs are not part of the loss
    /// metric, so a session with no I-frame history has no data to learn from.
    ///
    /// Delta-based (spec 4.2): each sample covers only what happened since
    /// the previous one, so the EWMA in the link controller sees time-local
    /// evidence. An inbound frame that changed nothing emits nothing.
    func emitLinkQualitySampleIfNeeded(for session: AX25Session) {
        // .error is included so a dying link's terminal retransmissions still
        // reach the controller — that loss is exactly the evidence that should
        // make the next attempt on this route skeptical.
        guard session.state == .connected || session.state == .error,
              session.statistics.framesSent > 0 else { return }
        // The statistics counters are monotonic by design; clamp anyway so a
        // broken invariant degrades to a missed sample, never to negative
        // evidence or a loss rate above 1 handed to the controller.
        let deltaSent = max(0, session.statistics.framesSent - session.lastSampledFramesSent)
        let deltaRetrans = max(0, session.statistics.retransmissions - session.lastSampledRetransmissions)
        // Reverse-path evidence. A receive-heavy session (any download)
        // sends almost no I-frames, so gating on forward evidence alone
        // starved the controller exactly when the link was working hardest.
        let deltaReceived = max(0, session.statistics.framesReceived - session.lastSampledFramesReceived)
        let deltaREJ = max(0, session.statistics.rejSent - session.lastSampledREJSent)
        guard deltaSent > 0 || deltaRetrans > 0 || deltaREJ > 0 else { return }
        session.lastSampledFramesSent = session.statistics.framesSent
        session.lastSampledRetransmissions = session.statistics.retransmissions
        session.lastSampledFramesReceived = session.statistics.framesReceived
        session.lastSampledREJSent = session.statistics.rejSent

        // df — forward delivery probability. Fraction of this sample's
        // transmissions that were first attempts; bounded [0, 1], unlike
        // retransmissions/framesSent which exceeded 1.0 whenever a frame
        // needed several tries.
        let transmissions = deltaSent + deltaRetrans
        let forwardLoss = transmissions > 0
            ? Double(deltaRetrans) / Double(transmissions)
            : 0
        let df = 1.0 - forwardLoss

        // dr — reverse delivery probability. Each REJ we sent marks a gap
        // in the peer's stream, so REJs over (frames that arrived + gaps
        // we had to ask about) estimates how much of what the peer sent
        // actually reached us. With no inbound traffic this sample carries
        // no reverse evidence and dr falls back to df rather than
        // inventing a number.
        let reverseObservations = deltaReceived + deltaREJ
        let dr = reverseObservations > 0
            ? 1.0 - Double(deltaREJ) / Double(reverseObservations)
            : df

        // AXTERM CLAUDE.md §8: ETX = 1 / (max(df,0.05) · max(dr,0.05)),
        // clamped to [1, 20]. The two directions are separate terms —
        // substituting df for dr (the old 1/df²) makes an asymmetric link
        // look symmetric, which is the one case where it matters most.
        let etx = min(20.0, max(1.0, 1.0 / (max(df, 0.05) * max(dr, 0.05))))

        // Both directions travel, separately. The composite below is the
        // worse of the two and still answers "is this path any good" for
        // route ranking; sizing our own frames and window is a different
        // question and must read `forwardLoss`.
        let reverseLoss = min(1.0, max(0.0, 1.0 - dr))
        let lossRate = min(1.0, max(forwardLoss, reverseLoss))

        onLinkQualitySample?(session, LinkQualitySample(
            lossRate: lossRate,
            forwardLoss: forwardLoss,
            reverseLoss: reverseLoss,
            etx: etx,
            srtt: session.timers.srtt,
            newFrames: deltaSent,
            retransmits: deltaRetrans
        ))
    }

    func handleInboundRR(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        nr: Int,
        pf: Bool = false,
        isCommand: Bool = false
    ) -> OutboundFrame? {
        handleInboundRRFrames(
            from: source,
            path: path,
            channel: channel,
            nr: nr,
            pf: pf,
            isCommand: isCommand
        ).first
    }

    /// Compatibility entry point for tests and older call sites that only
    /// distinguished "poll" from ordinary RR. A poll implies P/F set on a
    /// command frame; an ordinary RR has neither.
    func handleInboundRR(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        nr: Int,
        isPoll: Bool
    ) -> OutboundFrame? {
        handleInboundRR(
            from: source,
            path: path,
            channel: channel,
            nr: nr,
            pf: isPoll,
            isCommand: isPoll
        )
    }

    /// Handle an inbound RNR (receiver not ready — peer buffer full).
    ///
    /// RNR was previously dropped at both S-frame dispatch sites, which meant the
    /// acknowledgement carried in its N(R) field was never applied. V(A) stalled, T1
    /// kept retransmitting frames the peer had already taken, and the retry counter
    /// climbed until the link failed with "retries exceeded" — even though the peer
    /// was healthy and merely busy.
    func handleInboundRNR(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        nr: Int,
        pf: Bool = false,
        isCommand: Bool = false
    ) -> [OutboundFrame] {
        debugTrace("RNR received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "nr": nr,
            "pf": pf ? 1 : 0,
            "isCommand": isCommand ? 1 : 0
        ])

        // Same three-tier lookup as RR: exact path, then address-only fallbacks.
        var session = existingSession(for: source, path: path, channel: channel)
        if session == nil {
            session = findConnectedSession(from: source, channel: channel)
        }
        if session == nil {
            session = findConnectedSessionByCallsign(from: source, channel: channel)
        }

        guard let session = session else {
            debugTrace("RNR for unknown session", ["from": source.display])
            // §6.3.5: DM(F=1) to a P=1 command with no session (see RR handler).
            if pf && isCommand {
                return [AX25FrameBuilder.buildDM(from: localCallsign, to: source, via: path)]
            }
            return []
        }

        // The N(R) in an RNR is a real acknowledgement, so it yields a valid RTT
        // sample under the same Karn's-algorithm rules used for RR.
        if let sentAt = session.rttSendTime(ackedBy: nr) {
            let rtt = clock.currentTime - sentAt
            session.timers.updateRTT(sample: rtt)
        }
        session.clearSendTimesAcked(by: nr)

        let vaBefore = session.va
        let oldState = session.state
        let actions = session.stateMachine.handle(
            event: .receivedRNR(nr: nr, pf: pf, isCommand: isCommand)
        )

        if oldState != session.state {
            debugTrace("state change (RNR)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        // Retire the frames this RNR acknowledged, using the V(A) the state machine
        // actually accepted rather than the raw nr field (see the RR handler).
        let vaAfter = session.va
        session.acknowledgeUpTo(from: vaBefore, to: vaAfter)

        let modulo = session.stateMachine.config.modulo
        let ackedCount = (vaAfter - vaBefore + modulo) % modulo
        if ackedCount > 0 {
            for _ in 0..<ackedCount {
                session.aimdWindow.onAck()
            }
        }

        session.touch()
        notifyOutboundAck(session, upTo: session.va)

        TxLog.debug(.session, "RNR ACK state (peer busy)", [
            "peer": source.display,
            "va": session.va,
            "vs": session.vs,
            "outstanding": session.outstandingCount,
            "queueDepth": session.pendingDataQueue.count
        ])

        // Deliberately no drainPendingDataQueue here: the peer has told us its receive
        // buffer is full, so queued data stays queued until it clears the condition.
        debugDumpSessionState(session, context: "inbound-RNR")

        let frames = processActions(actions, for: session)
        checkInvariants(session: session)
        emitLinkQualitySampleIfNeeded(for: session)
        return frames
    }

    /// Handle an inbound REJ (reject - request retransmit)
    /// Selective reject: the peer asks for exactly frame N(R)
    /// (AX.25 2.2 §6.4.4.2). Unlike REJ this is not go-back-N: the send
    /// buffer keeps every other outstanding frame, and — §4.3.2.4 — only
    /// an F=1 SREJ acknowledges the frames below N(R); an F=0 SREJ
    /// acknowledges nothing at all.
    func handleInboundSREJ(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        nr: Int,
        pf: Bool = false
    ) -> [OutboundFrame] {
        var session = existingSession(for: source, path: path, channel: channel)
        if session == nil {
            session = findConnectedSession(from: source, channel: channel)
        }
        if session == nil {
            session = findConnectedSessionByCallsign(from: source, channel: channel)
        }
        guard let session, session.state == .connected else { return [] }

        debugTrace("SREJ received", [
            "from": source.display, "nr": nr, "pf": pf ? 1 : 0
        ])

        if pf {
            // F=1 acknowledges everything below N(R): clear both the send
            // buffer and V(A) — the buffer alone leaves the window closed.
            let vaBefore = session.va
            if session.stateMachine.sequenceState.isValidNR(nr: nr) {
                session.acknowledgeUpTo(from: vaBefore, to: nr)
                session.stateMachine.sequenceState.ackUpTo(nr: nr)
                if session.va != vaBefore {
                    notifyOutboundAck(session, upTo: session.va)
                }
            }
        }

        guard let buffered = session.sendBuffer[nr] else {
            // Nothing we still hold — most likely an ack crossed the SREJ
            // in flight. Ignoring is safe; the peer's next S-frame resyncs.
            return []
        }

        // Same amplification guard as REJ: once we retransmit for this
        // N(R), T1 owns the retry cycle until progress or expiry.
        if session.lastREJRetransmitNR == nr {
            debugTrace("Duplicate SREJ suppressed", ["nr": nr])
            return []
        }
        session.lastREJRetransmitNR = nr

        if session.timers.adaptiveTimeout {
            // One selective loss is still a loss event.
            session.aimdWindow.onLoss()
        }

        // Refresh N(R) to the current V(R) — the buffered copy's ack
        // field is stale by definition.
        let frame = buffered.withUpdatedNR(session.vr)
        session.statistics.recordRetransmit()
        if let ctrl = frame.controlByte {
            session.markRetransmitted(ns: Int((ctrl >> 1) & 0x07))
        }
        startT1Timer(for: session)
        session.touch()
        return [frame]
    }

    func handleInboundREJ(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        nr: Int,
        pf: Bool = false,
        isCommand: Bool = false
    ) -> [OutboundFrame] {
        debugTrace("REJ received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "nr": nr,
            "channel": channel,
            "pf": pf ? 1 : 0,
            "isCommand": isCommand ? 1 : 0
        ])
        var session = existingSession(for: source, path: path, channel: channel)
        if session == nil {
            session = findConnectedSession(from: source, channel: channel)
            if let connected = session {
                logPathOverrideIfNeeded(session: connected, requestedPath: path, reason: "rej")
            }
        }
        if session == nil {
            session = findConnectedSessionByCallsign(from: source, channel: channel)
            if let connected = session {
                logPathOverrideIfNeeded(session: connected, requestedPath: path, reason: "rej-ssid")
            }
        }

        guard let session = session else {
            debugTrace("REJ for unknown session", [
                "from": source.display
            ])
            // §6.3.5: DM(F=1) to a P=1 command with no session (see RR handler).
            if pf && isCommand {
                return [AX25FrameBuilder.buildDM(from: localCallsign, to: source, via: path)]
            }
            return []
        }

        let vaBefore = session.va
        let oldState = session.state
        // Bug D fix: validate N(R) before passing to state machine's ackUpTo.
        // A stale nr (< V(A)) would wrap the modulo loop in acknowledgeUpTo and
        // delete frames that are still outstanding, corrupting the send buffer.
        let validNR = session.stateMachine.sequenceState.isValidNR(nr: nr)
        // §6.2: "The next response frame returned to a supervisory command frame with
        // the P bit set to '1', received during the information transfer state, is an
        // RR, RNR or REJ response frame with the F bit set to '1'."  The pf/isCommand
        // flags were previously not forwarded here at all, so an REJ command poll
        // never received its mandatory F=1 reply — the polling peer would hit its own
        // T1 timeout waiting for a Final that never came.
        let actions = session.stateMachine.handle(event: .receivedREJ(nr: nr, pf: pf, isCommand: isCommand))

        if oldState != session.state {
            debugTrace("state change (REJ)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        if !validNR {
            // Stale or out-of-window REJ: ignore ack side-effects and retransmit.
            // Still process state machine actions (e.g. startT1 guard).
            debugTrace("Stale REJ discarded", [
                "peer": source.display, "nr": nr, "va": session.va, "vs": session.vs
            ])
            session.touch()
            checkInvariants(session: session)
            return processActions(actions, for: session)
        }

        // REJ(nr) acknowledges all frames up to nr-1, so we MUST clear them from the send buffer.
        // It then requests retransmission starting from nr.
        session.acknowledgeUpTo(from: vaBefore, to: nr)

        // REJ carries a valid N(R) acknowledgement just like RR/RNR do, so the
        // outbound-progress UI must hear about it. Without this, a message whose
        // final ack arrives via REJ (e.g. the peer REJs a duplicate retransmission
        // that crossed its ack in flight) stays stuck at "Sending…" forever.
        if session.va != vaBefore {
            notifyOutboundAck(session, upTo: session.va)
        }

        // Bug A fix: suppress retransmission amplification from duplicate REJ storms.
        // After the first REJ(nr) triggers an immediate retransmit, T1 owns the retry
        // cycle. A second REJ with the same nr and no ack progress must not retransmit
        // again — T1 will handle it. Rate-limiting is reset when T1 fires.
        let noAckProgress = session.va == vaBefore
        let isDuplicateREJ = session.lastREJRetransmitNR == nr
        let shouldRetransmit = !(noAckProgress && isDuplicateREJ)

        let retransmitFrames: [OutboundFrame]
        if shouldRetransmit {
            if session.timers.adaptiveTimeout {
                // AIMD is adaptive-mode behavior. In fixed AX.25 mode, REJ still
                // triggers retransmission but must not mutate the configured window.
                session.aimdWindow.onLoss()
                TxLog.debug(.session, "AIMD loss event (REJ)", [
                    "peer": source.display,
                    "cwnd": String(format: "%.2f", session.aimdWindow.cwnd),
                    "effectiveWindow": session.aimdWindow.effectiveWindow
                ])
            }

            retransmitFrames = session.framesToRetransmit(from: nr)
            for frame in retransmitFrames {
                session.statistics.recordRetransmit()
                // Karn's algorithm: mark REJ-retransmitted frames so the ACK
                // that follows doesn't generate an ambiguous RTT sample.
                if let ctrl = frame.controlByte {
                    session.markRetransmitted(ns: Int((ctrl >> 1) & 0x07))
                }
            }
            session.lastREJRetransmitNR = nr
        } else {
            retransmitFrames = []
            debugTrace("Duplicate REJ suppressed (T1 owns retry cycle)", [
                "peer": source.display, "nr": nr
            ])
        }

        session.touch()

        // Deep debug snapshot when peer explicitly requests retransmit.
        debugDumpSessionState(session, context: "inbound-REJ")
        checkInvariants(session: session)

        // Process actions first, then return retransmit frames with updated N(R)
        var frames = processActions(actions, for: session)
        for frame in retransmitFrames {
            let updatedFrame = frame.withUpdatedNR(session.vr)
            frames.append(updatedFrame)
        }

        // REJ-driven retransmission is loss evidence the controller must hear
        // even when the peer never sends a standalone RR afterwards.
        emitLinkQualitySampleIfNeeded(for: session)

        return frames
    }

    // MARK: - Timer Handling

    /// Handle T1 (retransmit) timeout for a session
    func handleT1Timeout(session: AX25Session) -> [OutboundFrame] {
        let oldState = session.state
        // Recorded before the transition, while the state still says why the
        // timer fired: a T1 expiry in `connecting` means the SABM is about to
        // go out again, which makes any later UA an ambiguous RTT sample.
        if oldState == .connecting {
            session.sabmRetransmitted = true
        }
        let actions = session.stateMachine.handle(event: .t1Timeout)

        if oldState != session.state {
            debugTrace("state change (T1 timeout)", [
                "peer": session.remoteAddress.display,
                "from": oldState.rawValue,
                "to": oldState.rawValue
            ])
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        session.timers.backoff()  // Exponential backoff
        // T1 firing resets the REJ deduplication window: the next REJ after a T1
        // retransmit should trigger a fresh immediate retransmit, not be suppressed.
        session.lastREJRetransmitNR = nil
        session.touch()

        // Deep debug snapshot after every T1 timeout, to understand why we're retransmitting
        // or giving up. This is the primary place to diagnose "AXTerm is giving up too early".
        debugDumpSessionState(session, context: "T1-timeout")

        var frames = processActions(actions, for: session)

        if session.state == .connected, session.outstandingCount > 0, !session.stateMachine.peerBusy {
            if session.timers.adaptiveTimeout {
                session.aimdWindow.onLoss()
                TxLog.debug(.session, "AIMD loss event (T1 timeout)", [
                    "peer": session.remoteAddress.display,
                    "cwnd": String(format: "%.2f", session.aimdWindow.cwnd),
                    "effectiveWindow": session.aimdWindow.effectiveWindow
                ])
            }

            // Filter out any S-frame RR poll command returned by processActions,
            // as the retransmitted oldest I-frame with P=1 acts as the poll per §6.4.4.1.
            frames.removeAll(where: { $0.frameType == "s" && $0.isCommand == true })

            axDebugPrint("[DEBUG:AX25:T1] retransmit | va=\(session.va) vs=\(session.vs) vr=\(session.vr) outstanding=\(session.outstandingCount) sendBufKeys=\(session.sendBuffer.keys.sorted())")
            frames.append(contentsOf: retransmitOutstandingFrames(for: session, from: session.va, reason: "T1-timeout", preservePollFinal: false, forcePollOnFirst: true))
        }

        // Loss evidence must be TIMELY: a T1 retransmission reaches the
        // controller now, not when the next inbound frame happens to arrive —
        // a degrading link is exactly the case where inbound traffic stops.
        // On N2 exhaustion (state == .error) this is the final evidence flush.
        emitLinkQualitySampleIfNeeded(for: session)

        return frames
    }

    /// Handle T3 (idle) timeout for a session
    func handleT3Timeout(session: AX25Session) -> [OutboundFrame] {
        let oldState = session.state
        let actions = session.stateMachine.handle(event: .t3Timeout)

        if oldState != session.state {
            notifyStateChanged(session, from: oldState, to: session.state)
        }

        return processActions(actions, for: session)
    }

    // MARK: - Timer Management

    /// Start T1 (retransmit) timer for a session
    func startT1Timer(for session: AX25Session) {
        // Cancel any existing T1 timer and pending grace-period retransmit
        session.t1TimerTask?.cancel()
        session.t1PendingRetransmitTask?.cancel()
        session.t1PendingRetransmitTask = nil
        session.t1Generation &+= 1
        let generation = session.t1Generation

        let rto = session.timers.rto
        let sessionId = session.id

        TxLog.debug(.session, "Starting T1 timer", [
            "session": String(sessionId.uuidString.prefix(8)),
            "rto": String(format: "%.1fs", rto),
            "state": session.state.rawValue
        ])

        session.t1TimerTask = clock.schedule(delay: rto) { [weak self] in
            guard let self = self else { return }
            // Find the session (it may have been removed)
            guard let session = self.sessions.values.first(where: { $0.id == sessionId }) else {
                TxLog.debug(.session, "T1 timeout but session gone", ["session": String(sessionId.uuidString.prefix(8))])
                return
            }
            guard session.t1Generation == generation else {
                TxLog.debug(.session, "Stale T1 timeout ignored", [
                    "session": String(sessionId.uuidString.prefix(8))
                ])
                return
            }

            TxLog.warning(.session, "T1 timeout fired", [
                "session": String(sessionId.uuidString.prefix(8)),
                "state": session.state.rawValue,
                "retryCount": session.stateMachine.retryCount
            ])

            // Grace period: delay retransmit so if RR is in flight we can cancel and avoid duplicate frames
            let gracePeriod: TimeInterval = 0.2 // 200ms
            session.t1PendingRetransmitTask?.cancel()
            session.t1PendingRetransmitTask = self.clock.schedule(delay: gracePeriod) { [weak self] in
                guard let self = self else { return }
                guard let session = self.sessions.values.first(where: { $0.id == sessionId }) else { return }
                guard session.t1Generation == generation else { return }
                session.t1PendingRetransmitTask = nil
                let frames = self.handleT1Timeout(session: session)
                for frame in frames {
                    self.onSendFrame?(frame)
                }
            }
        }
    }

    /// Stop T1 timer for a session
    private func stopT1Timer(for session: AX25Session) {
        session.t1Generation &+= 1
        if session.t1TimerTask != nil {
            TxLog.debug(.session, "Stopping T1 timer", [
                "session": String(session.id.uuidString.prefix(8))
            ])
            session.t1TimerTask?.cancel()
            session.t1TimerTask = nil
        }
        session.t1PendingRetransmitTask?.cancel()
        session.t1PendingRetransmitTask = nil
    }

    /// Arm T2, the response-delay timer — once. The first unacknowledged
    /// delivery starts the clock; later frames in the burst leave the
    /// deadline alone. Re-arming per frame looked attractive (transmit
    /// only when the channel goes quiet) but is unbounded: any arrival
    /// cadence faster than T2 defers the ack forever, and the sender's T1
    /// (rtoMin 3 s) fires spuriously first — observed directly as RTO
    /// oscillation in the adaptive harness. Arm-once bounds the deferral
    /// at t2AckDelay, comfortably inside any sane peer's T1, and on the
    /// air it rarely matters anyway: gateways end every burst with a P=1
    /// poll (field capture 2026-08-24) whose F=1 response carries the ack.
    private func startT2Timer(for session: AX25Session) {
        guard session.t2TimerTask == nil else { return }
        session.t2Generation &+= 1
        let generation = session.t2Generation
        let sessionId = session.id

        session.t2TimerTask = clock.schedule(delay: session.timers.t2AckDelay) { [weak self] in
            guard let self = self else { return }
            guard let session = self.sessions.values.first(where: { $0.id == sessionId }) else { return }
            guard session.t2Generation == generation else { return }
            session.t2TimerTask = nil
            let actions = session.stateMachine.handle(event: .t2Timeout)
            let frames = self.processActions(actions, for: session)
            for frame in frames {
                self.onSendFrame?(frame)
            }
        }
    }

    private func stopT2Timer(for session: AX25Session) {
        session.t2Generation &+= 1
        session.t2TimerTask?.cancel()
        session.t2TimerTask = nil
    }

    /// Start T3 (idle) timer for a session
    private func startT3Timer(for session: AX25Session) {
        // Cancel any existing T3 timer
        session.t3TimerTask?.cancel()

        let timeout = session.timers.t3Timeout
        let sessionId = session.id

        session.t3TimerTask = clock.schedule(delay: timeout) { [weak self] in
            guard let self = self else { return }
            guard let session = self.sessions.values.first(where: { $0.id == sessionId }) else {
                return
            }

            TxLog.debug(.session, "T3 timeout fired", [
                "session": String(sessionId.uuidString.prefix(8)),
                "state": session.state.rawValue
            ])

            let frames = self.handleT3Timeout(session: session)
            for frame in frames {
                self.onSendFrame?(frame)
            }
        }
    }

    /// Stop T3 timer for a session
    private func stopT3Timer(for session: AX25Session) {
        session.t3TimerTask?.cancel()
        session.t3TimerTask = nil
    }

    // MARK: - Private Helpers

    /// Drain the pending data queue (paclen-fragmented chunks) when window has space
    private func drainPendingDataQueue(for session: AX25Session) {
        guard !session.pendingDataQueue.isEmpty else { return }

        // I frames may only flow in the information-transfer state. Data queued while
        // still connecting must wait for UA — draining early would put numbered frames
        // on the air before the link exists (§6.3.1/§6.4.1). This guard matters because
        // the RR handler calls drain unconditionally, and RR can arrive in any state.
        guard session.state == .connected else {
            TxLog.debug(.session, "Drain suppressed (not connected)", [
                "peer": session.remoteAddress.display,
                "state": session.state.rawValue,
                "queueDepth": session.pendingDataQueue.count
            ])
            return
        }

        // The peer has signalled RNR: its receive buffer is full. Hold queued data until
        // it clears the condition with RR/REJ, otherwise we simply generate drops.
        guard !session.stateMachine.peerBusy else {
            TxLog.debug(.session, "Drain suppressed (peer busy)", [
                "peer": session.remoteAddress.display,
                "queueDepth": session.pendingDataQueue.count
            ])
            return
        }

        TxLog.debug(.session, "Draining pending data queue", [
            "peer": session.remoteAddress.display,
            "queueDepth": session.pendingDataQueue.count
        ])

        // Bug I fix: the old loop checked canSendIFrame (which reads sequenceState.outstandingCount)
        // against the *initial* V(S)/V(A) for every iteration.  buildIFrame only increments V(S)
        // in the second (execution) loop, so the window check was stale for every item after the
        // first.  A partial RR ack that frees 1 slot would therefore drain all pending frames,
        // driving outstandingCount far past windowSize and firing assertInvariants.
        //
        // Fix: compute the available window space ONCE from the current sequence state and limit
        // the drain to at most that many frames.
        let windowSize = session.stateMachine.config.windowSize
        // Audit B5 fix: use sendBuffer.count (session.outstandingCount) as the canonical
        // outstanding-frame count.  The design comment on outstandingCount says
        // "use sendBuffer.count so it matches actual buffered frames after RR acks;
        // (vs-va) can be wrong across wrap."  sequenceState.outstandingCount is the
        // V(S)−V(A) view and can briefly diverge from sendBuffer.count during wrap.
        let currentOutstanding = session.outstandingCount
        // Bug G fix: effective send window is the minimum of the AX.25 protocol
        // window K and the AIMD congestion window.  This ensures the congestion
        // window actually constrains transmit rate — not just bookkeeping.
        let aimdEffective = session.aimdWindow.effectiveWindow
        let effectiveSendWindow = min(windowSize, aimdEffective)
        let availableSlots = max(0, effectiveSendWindow - currentOutstanding)

        var drained: [(data: Data, pid: UInt8, displayInfo: String?)] = []
        var remaining: [(data: Data, pid: UInt8, displayInfo: String?)] = []
        var slotsConsumed = 0
        for item in session.pendingDataQueue {
            if slotsConsumed < availableSlots {
                drained.append(item)
                slotsConsumed += 1
            } else {
                remaining.append(item)
            }
        }
        session.pendingDataQueue = remaining

        var wasIdle = session.outstandingCount == 0
        for item in drained {
            // Checkpoint on window-full, as in sendData (§6.2).
            let fillsWindow = session.outstandingCount + 1 >= effectiveSendWindow
            let ns = session.vs  // Capture before buildIFrame increments vs
            let iFrame = buildIFrame(
                for: session,
                payload: item.data,
                pid: item.pid,
                displayInfo: item.displayInfo,
                pf: fillsWindow || shouldPollFirstOutboundIFrame(for: session, wasIdle: wasIdle)
            )
            debugTrace("TX I (drain queue)", ["frame": describeFrame(iFrame)])
            axDebugPrint("[DEBUG:AX25:DRAIN] tx | N(S)=\(ns) payload=\(item.data.count) va=\(session.va) vs=\(session.vs)")
            // Use ns directly - (vs-1) wraps to -1 when vs goes 7->0, corrupting sendBuffer
            session.bufferFrame(iFrame, ns: ns)
            session.recordSendTime(ns: ns, time: clock.currentTime)
            session.statistics.recordSent(bytes: item.data.count)

            if wasIdle {
                startT1Timer(for: session)
                wasIdle = false
            }
            onSendFrame?(iFrame)

            TxLog.debug(.session, "Sent queued data", [
                "peer": session.remoteAddress.display,
                "size": item.data.count
            ])
        }

        if !remaining.isEmpty {
            TxLog.debug(.session, "Window filled during drain, re-queued", [
                "remaining": remaining.count
            ])
        }
        session.touch()
        checkInvariants(session: session)
    }

    /// Build an I-frame for the session with current sequence numbers
    private func shouldPollFirstOutboundIFrame(for session: AX25Session, wasIdle: Bool) -> Bool {
        // Some NET/ROM node stacks (including DRLNOD in live testing) need a poll
        // on the first user I-frame after SABM/UA so they ACK promptly, but will
        // DM if every later idle line is also sent as a poll.  Keep the compatibility
        // nudge scoped to the first outbound numbered I-frame of an initiated session.
        wasIdle && session.isInitiator && session.va == 0 && session.vs == 0
    }

    /// Build an I-frame for the session with current sequence numbers
    private func buildIFrame(
        for session: AX25Session,
        payload: Data,
        pid: UInt8,
        displayInfo: String?,
        pf: Bool = false
    ) -> OutboundFrame {
        let ns = session.vs
        let nr = session.vr

        // This frame's N(R) is the cumulative ack — the T2 debt is settled.
        session.stateMachine.noteAckTransmitted()
        stopT2Timer(for: session)

        // Increment V(S) in state machine
        session.stateMachine.sequenceState.incrementVS()

        return AX25FrameBuilder.buildIFrame(
            from: session.localAddress,
            to: session.remoteAddress,
            via: session.path,
            ns: ns,
            nr: nr,
            pid: pid,
            payload: payload,
            pf: pf,
            sessionId: session.id,
            displayInfo: displayInfo
        )
    }

    private func retransmitOutstandingFrames(
        for session: AX25Session,
        from nr: Int,
        reason: String,
        preservePollFinal: Bool = true,
        forcePollOnFirst: Bool = false
    ) -> [OutboundFrame] {
        let retransmitFrames = session.framesToRetransmit(from: nr)
        let nsValues = retransmitFrames.compactMap { frame -> Int? in
            guard let ctrl = frame.controlByte else { return nil }
            return Int((ctrl >> 1) & 0x07)
        }

        TxLog.debug(.session, "Retransmitting outstanding I-frames", [
            "peer": session.remoteAddress.display,
            "reason": reason,
            "fromNR": nr,
            "count": retransmitFrames.count,
            "ns": nsValues.map { String($0) }.joined(separator: ",")
        ])

        return retransmitFrames.enumerated().map { index, frame in
            let shouldForcePoll = forcePollOnFirst && (index == 0)
            let updatedFrame = frame.withUpdatedNR(session.vr, preservePollFinal: preservePollFinal, forcePoll: shouldForcePoll)
            debugTrace("TX I (retransmit)", ["reason": reason, "frame": describeFrame(updatedFrame)])
            onLinkVizEvent?(.retransmit(peer: session.remoteAddress.display, count: 1))
            session.statistics.recordRetransmit()
            if let ctrl = updatedFrame.controlByte {
                session.markRetransmitted(ns: Int((ctrl >> 1) & 0x07))
            }
            return updatedFrame
        }
    }

    /// Process actions from the state machine and return frames to send
    /// Unsticks a session whose receive window is blocked behind a lost frame,
    /// for a caller that knows the missing bytes can be spared.
    ///
    /// Returns the frames to send and whether anything was actually stranded,
    /// so the caller can tell "the banner was stuck" from "the node is silent"
    /// — two failures that look identical from outside and need different
    /// advice.
    @discardableResult
    func flushReceiveGapForHandshake(for session: AX25Session) -> (frames: [OutboundFrame], flushed: Bool) {
        let actions = session.stateMachine.skipReceiveGapForHandshake()
        guard !actions.isEmpty else { return ([], false) }
        return (processActions(actions, for: session), true)
    }

    private func processActions(_ actions: [AX25SessionAction], for session: AX25Session) -> [OutboundFrame] {
        var frames: [OutboundFrame] = []

        for action in actions {
            switch action {
            case .sendSABM:
                let frame = AX25FrameBuilder.buildSABM(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    extended: session.stateMachine.config.extended
                )
                debugTrace("TX SABM", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .sendUA:
                let frame = AX25FrameBuilder.buildUA(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                debugTrace("TX UA", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .sendDM:
                let frame = AX25FrameBuilder.buildDM(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                debugTrace("TX DM", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .sendDISC:
                let frame = AX25FrameBuilder.buildDISC(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                debugTrace("TX DISC", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .sendRR(let nr, let pf, let isCommand):
                let frame = AX25FrameBuilder.buildRR(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    nr: nr,
                    pf: pf,
                    isCommand: isCommand
                )
                debugTrace("TX RR", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .sendRNR(let nr, let pf, let isCommand):
                let frame = AX25FrameBuilder.buildRNR(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    nr: nr,
                    pf: pf,
                    isCommand: isCommand
                )
                debugTrace("TX RNR", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .sendREJ(let nr, let pf, let isCommand):
                onLinkVizEvent?(.rejSent(peer: session.remoteAddress.display, nr: nr))
                session.statistics.recordREJSent()
                let frame = AX25FrameBuilder.buildREJ(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    nr: nr,
                    pf: pf,
                    isCommand: isCommand
                )
                debugTrace("TX REJ", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .sendSREJ(let nr, let pf, let isCommand):
                // Each SREJ is a detected gap in the peer's stream — the
                // same reverse-path loss evidence a REJ is.
                onLinkVizEvent?(.rejSent(peer: session.remoteAddress.display, nr: nr))
                session.statistics.recordREJSent()
                let frame = AX25FrameBuilder.buildSREJ(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    nr: nr,
                    pf: pf,
                    isCommand: isCommand
                )
                debugTrace("TX SREJ", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .sendIFrame(let ns, let nr, let payload):
                let frame = AX25FrameBuilder.buildIFrame(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    ns: ns,
                    nr: nr,
                    payload: payload,
                    sessionId: session.id
                )
                debugTrace("TX I", ["frame": describeFrame(frame)])
                frames.append(frame)

            case .deliverData(let data, let pid):
                // PID is the protocol demux (AX.25 §3.3): 0xCF payloads
                // are NET/ROM L3 datagrams for the transport engine —
                // never terminal text, never AXDP, never a claim's bytes.
                if pid == NetRomWire.pid {
                    TxLog.debug(.session, "NET/ROM datagram delivered from L2", [
                        "peer": session.remoteAddress.display,
                        "size": data.count
                    ])
                    onNetRomDatagram?(session, data)
                    continue
                }
                let prefixHex = data.prefix(8).map { String(format: "%02X", $0) }.joined()
                let hasMagic = AXDP.hasMagic(data)
                axDebugPrint("[DEBUG:AX25:DELIVER] I-frame payload to reassembly | from=\(session.remoteAddress.display) size=\(data.count) hasMagic=\(hasMagic) prefix=\(prefixHex)")
                TxLog.debug(.axdp, "I-frame payload delivered to reassembly", [
                    "peer": session.remoteAddress.display,
                    "size": data.count,
                    "hasMagic": hasMagic,
                    "prefixHex": prefixHex
                ])
                onLinkVizEvent?(.delivered(peer: session.remoteAddress.display, bytes: data.count))
                if let claim = deliveryClaims[session.key] {
                    // A protocol conversation (e.g. Winlink B2F) owns this
                    // session's bytes; terminal and AXDP must not see them.
                    claim.handler(session, data)
                } else {
                    onDataDeliveredForReassembly?(session, data)
                    onDataReceived?(session, data)
                }

            case .notifyConnected:
                TxLog.sessionOpen(
                    sessionId: session.id,
                    peer: session.remoteAddress.display,
                    mode: "connected"
                )

            case .notifyDisconnected:
                session.clearPendingTransmission(reason: "Session disconnected")
                TxLog.sessionClose(
                    sessionId: session.id,
                    peer: session.remoteAddress.display,
                    reason: "Disconnected"
                )

            case .notifyError(let message):
                if session.state == .error || session.state == .disconnected {
                    session.clearPendingTransmission(reason: "Session error: \(message)")
                }
                TxLog.error(.session, message, error: nil, [
                    "session": String(session.id.uuidString.prefix(8)),
                    "peer": session.remoteAddress.display
                ])

            case .startT1:
                startT1Timer(for: session)

            case .stopT1:
                stopT1Timer(for: session)

            case .startT2:
                startT2Timer(for: session)

            case .stopT2:
                stopT2Timer(for: session)

            case .startT3:
                startT3Timer(for: session)

            case .stopT3:
                stopT3Timer(for: session)

            case .clearSendBuffer:
                // Full link reset: flush all unacknowledged outbound frames and RTT state.
                // Used when a peer re-sends SABM on an active connection (AX.25 §4.3.3.1).
                session.sendBuffer.removeAll()
                session.clearSendTimes()
                debugTrace("Send buffer cleared (link reset)", ["peer": session.remoteAddress.display])
            }
        }

        return frames
    }
}
