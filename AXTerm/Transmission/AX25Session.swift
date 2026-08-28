//
//  AX25Session.swift
//  AXTerm
//
//  AX.25 connected-mode session state machine.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 7
//

import Foundation

// MARK: - AX.25 Constants

/// Common AX.25 protocol constants
nonisolated enum AX25Constants {
    /// Default packet length (paclen) in bytes
    static let defaultPacketLength: Int = 128
    
    /// Default window size (max outstanding I-frames in modulo-8)
    static let defaultWindowSize: Int = 4
    
    /// Sequence number modulo for standard AX.25
    static let modulo8: Int = 8
    
    /// Sequence number modulo for extended AX.25
    static let modulo128: Int = 128
}

// MARK: - Session State

/// State of an AX.25 connected-mode session
nonisolated enum AX25SessionState: String, Equatable, Sendable {
    case disconnected
    case connecting      // Sent SABM, waiting UA
    case connected
    case disconnecting   // Sent DISC, waiting UA
    case error
}

// MARK: - Session Configuration

/// Configuration for AX.25 session parameters
nonisolated struct AX25SessionConfig: Sendable {
    /// Window size K (max outstanding I-frames)
    let windowSize: Int

    /// Maximum payload bytes per I-frame (paclen). Frames are fragmented at this size.
    let paclen: Int

    /// Maximum receive buffer size for out-of-sequence frames. When nil, holds
    /// a full receive span (`receiveWindowSpan - 1`). Can be set smaller to
    /// force discard-oldest behavior under load (e.g. testing).
    let maxReceiveBufferSize: Int?

    /// Maximum retries N2
    let maxRetries: Int

    /// Use extended mode (modulo 128 vs modulo 8)
    let extended: Bool

    /// Selective reject negotiated via XID (AX.25 2.2 §6.4.4.2). Off by
    /// default: a peer that never agreed to SREJ treats one as a protocol
    /// error. When on, a receive gap draws SREJ for exactly the missing
    /// frame instead of go-back-N REJ.
    let srejEnabled: Bool

    /// Minimum RTO (seconds). When nil, session timers use default 1.0.
    let rtoMin: Double?

    /// Maximum RTO (seconds). When nil, session timers use default 30.0.
    let rtoMax: Double?

    /// Initial RTO (seconds) before any RTT sample. When nil, session timers use default 4.0.
    let initialRto: Double?

    /// T2 response-delay (delayed-ack) ceiling, seconds. nil → 2.0, tuned
    /// for 1200-baud RF: it spans one max-size frame's ~1.9 s of airtime
    /// (so back-to-back frames batch into one cumulative ack) while
    /// staying inside the 3 s production RTO floor. The invariant that
    /// matters is ecosystem-wide: every peer's T1 must exceed our T2 plus
    /// a round trip, or the peer retransmits frames we were about to ack.
    /// Timers enforce a local version of it by clamping to 2/3 of rtoMin.
    let t2AckDelay: Double?

    /// Whether adaptive timeout estimation is enabled
    let adaptiveTimeout: Bool

    /// A FULL-PATH initial RTO learned for one specific route (destination +
    /// path). When present it IS the seed, verbatim — never hop-scaled,
    /// because the learned value already includes digipeater delay. Exactly
    /// one writer exists: the adaptive per-route cache-hit branch (adaptive
    /// on, TTL-fresh entry). Nil everywhere else, including merged configs —
    /// a route-specific RTO has no meaning across mixed routes.
    let learnedPathRto: Double?

    /// Sequence number modulo (8 or 128)
    var modulo: Int { extended ? 128 : 8 }

    /// How far ahead of V(R) an out-of-sequence I-frame may sit and still be
    /// buffered instead of discarded.
    ///
    /// Deliberately NOT `windowSize`. K is *our transmit* window — what our
    /// congestion control picked for frames we send. It says nothing about how
    /// many frames the peer keeps in flight, and without XID nothing negotiates
    /// a common value. Deriving the receive span from K meant that at K=2
    /// anything more than one frame ahead was thrown away, so a peer running
    /// four outstanding frames had its early arrivals discarded — and once V(R)
    /// reached them we had to ask for frames the peer had already sent and
    /// considered delivered. That deadlocks the link (field capture 2026-08-24,
    /// W0ARP-10: N(S)=7 arrived twice while V(R)=4, was dropped both times, and
    /// the session died 60 s later still waiting for it).
    ///
    /// Half the modulo is the standard sliding-window disambiguation bound:
    /// inside it a sequence number ahead of V(R) is unambiguously a future
    /// frame; at or beyond it, it may be a duplicate from the previous lap.
    var receiveWindowSpan: Int { modulo / 2 }

    init(
        windowSize: Int = 4,
        paclen: Int = 128,
        maxReceiveBufferSize: Int? = nil,
        maxRetries: Int = 10,
        extended: Bool = false,
        srejEnabled: Bool = false,
        rtoMin: Double? = nil,
        rtoMax: Double? = nil,
        initialRto: Double? = nil,
        t2AckDelay: Double? = nil,
        adaptiveTimeout: Bool = true,
        learnedPathRto: Double? = nil
    ) {
        // Clamp window size to valid range
        let maxWindow = extended ? 127 : 7
        let ws = max(1, min(windowSize, maxWindow))
        self.windowSize = ws
        self.paclen = max(32, min(paclen, 256))
        // Bounded by the receive span, not by ws: the two are unrelated (see
        // `receiveWindowSpan`).
        let span = (extended ? 128 : 8) / 2
        self.maxReceiveBufferSize = maxReceiveBufferSize.map { max(1, min($0, span - 1)) }
        self.maxRetries = max(1, maxRetries)
        self.extended = extended
        self.srejEnabled = srejEnabled
        self.rtoMin = rtoMin
        self.rtoMax = rtoMax
        self.initialRto = initialRto
        self.t2AckDelay = t2AckDelay
        self.adaptiveTimeout = adaptiveTimeout
        self.learnedPathRto = learnedPathRto
    }

    /// This config with the outcome of an XID exchange applied (§6.3.2):
    /// SREJ if the response selected it, and the peer's advertised receive
    /// limits taken as ceilings — N1 and k are notifications of what the
    /// peer can accept, so ours are clamped to them, never raised.
    func negotiating(with peer: AX25XIDParameters) -> AX25SessionConfig {
        AX25SessionConfig(
            windowSize: min(windowSize, peer.windowSizeRx ?? windowSize),
            paclen: min(paclen, peer.iFieldLengthRx ?? paclen),
            maxReceiveBufferSize: maxReceiveBufferSize,
            maxRetries: maxRetries,
            extended: extended,
            srejEnabled: peer.supportsSREJ,
            rtoMin: rtoMin,
            rtoMax: rtoMax,
            initialRto: initialRto,
            t2AckDelay: t2AckDelay,
            adaptiveTimeout: adaptiveTimeout,
            learnedPathRto: learnedPathRto
        )
    }
}

// MARK: - Sequence Numbers

/// AX.25 sequence number state (V(S), V(R), V(A))
nonisolated struct AX25SequenceState: Sendable {
    /// Modulo for sequence numbers (8 or 128)
    let modulo: Int

    /// V(S) - Send state variable (next sequence number to send)
    var vs: Int = 0

    /// V(R) - Receive state variable (next expected sequence number)
    var vr: Int = 0

    /// V(A) - Acknowledge state variable (oldest unacked sequence number)
    var va: Int = 0

    init(modulo: Int = 8) {
        self.modulo = modulo
    }

    /// Increment V(S) with wraparound
    mutating func incrementVS() {
        vs = (vs + 1) % modulo
    }

    /// Increment V(R) with wraparound
    mutating func incrementVR() {
        vr = (vr + 1) % modulo
    }

    /// Number of outstanding (unacknowledged) frames
    var outstandingCount: Int {
        if vs >= va {
            return vs - va
        } else {
            // Wrapped around
            return (modulo - va) + vs
        }
    }

    /// Checks if a received N(R) is valid (between V(A) and V(S))
    func isValidNR(nr: Int) -> Bool {
        guard nr >= 0 && nr < modulo else { return false }
        if vs >= va {
            return nr >= va && nr <= vs
        } else {
            return nr >= va || nr <= vs
        }
    }

    /// Acknowledge frames up to (but not including) nr
    mutating func ackUpTo(nr: Int) {
        if !isValidNR(nr: nr) {
            // Report before trapping: the assert compiles out in release, and
            // this used to make an invalid ack silently corrupt V(A).
            TxLog.invariantViolation("ackUpTo invalid N(R)", ["nr": nr, "va": va, "vs": vs])
            assertionFailure("Attempted to ackUpTo invalid N(R): \(nr)")
        }
        va = nr % modulo
    }

    /// Check if we can send another frame (window not full)
    func canSend(windowSize: Int) -> Bool {
        assert(windowSize > 0 && windowSize < modulo, "Window size must be > 0 and < modulo")
        return outstandingCount < windowSize
    }
    
    /// Verifies core invariants. Violations are reported to Sentry in ALL
    /// builds (previously bare asserts: SIGTRAP with no report in debug,
    /// compiled out entirely — silent corruption — in release), then trap in
    /// debug so tests still fail loudly.
    func assertInvariants(windowSize: Int) {
        var violations: [String] = []
        if !(vs >= 0 && vs < modulo) { violations.append("V(S) out of bounds: \(vs)") }
        if !(vr >= 0 && vr < modulo) { violations.append("V(R) out of bounds: \(vr)") }
        if !(va >= 0 && va < modulo) { violations.append("V(A) out of bounds: \(va)") }
        if !(outstandingCount >= 0 && outstandingCount <= windowSize) {
            violations.append("outstandingCount \(outstandingCount) exceeds windowSize \(windowSize)")
        }
        guard !violations.isEmpty else { return }
        TxLog.invariantViolation(
            "sequence state: \(violations.joined(separator: "; "))",
            ["vs": vs, "vr": vr, "va": va, "windowSize": windowSize, "modulo": modulo]
        )
        assertionFailure("Sequence invariants violated: \(violations.joined(separator: "; "))")
    }

    /// Reset sequence numbers
    mutating func reset() {
        vs = 0
        vr = 0
        va = 0
    }
}

// MARK: - Session Timers

/// Timer management for AX.25 session
nonisolated struct AX25SessionTimers: Sendable {
    /// Smoothed RTT estimate
    var srtt: Double? = nil

    /// RTT variance
    var rttvar: Double = 0.0

    /// Current RTO (retransmission timeout)
    private(set) var rto: Double

    /// Whether adaptive timeout estimation is enabled
    let adaptiveTimeout: Bool

    /// T3 idle timeout (seconds)
    let t3Timeout: Double = 30.0

    /// T2 response-delay (delayed-ack) timeout, seconds. Long enough to
    /// span the gap between a burst's frames at 1200 baud (a 256-byte
    /// frame is ~1.9 s of airtime), short enough to stay inside any sane
    /// peer's T1 — enforced locally by clamping to 2/3 of rtoMin, since a
    /// peer on the same link will run a comparable RTO floor. In practice
    /// it rarely fires: bursts end with a P=1 poll whose mandatory F=1
    /// response carries the cumulative ack.
    let t2AckDelay: Double

    /// Smoothing factor for SRTT (1/8 per RFC 6298)
    private let alpha: Double = 1.0 / 8.0

    /// Smoothing factor for RTTVAR (1/4 per RFC 6298)
    private let beta: Double = 1.0 / 4.0

    /// Minimum RTO (seconds)
    private let rtoMin: Double

    /// Maximum RTO (seconds)
    private let rtoMax: Double

    /// Default initial RTO (seconds)
    private static let defaultInitialRto: Double = 4.0

    /// The clamped initial RTO this session was configured with, so `reset()` can
    /// restore it. Without it, reset() fell back to the hardcoded 4 s default and
    /// silently discarded the operator's configured T1.
    private let initialRto: Double

    init(rtoMin: Double = 3.0, rtoMax: Double = 30.0, initialRto: Double = AX25SessionTimers.defaultInitialRto, adaptiveTimeout: Bool = true, t2AckDelay: Double = 2.0) {
        self.rtoMin = max(0.5, rtoMin)
        self.rtoMax = max(self.rtoMin, min(60.0, rtoMax))
        self.initialRto = max(self.rtoMin, min(self.rtoMax, initialRto))
        self.rto = self.initialRto
        self.adaptiveTimeout = adaptiveTimeout
        self.t2AckDelay = max(0.1, min(t2AckDelay, self.rtoMin * 2.0 / 3.0))
    }

    /// Update RTT estimates with a new sample (Jacobson/Karels, RFC 6298).
    ///
    /// Bug H guard: malformed RTT samples (NaN, Inf, ≤0) are silently discarded
    /// rather than poisoning the estimator. A single bad sample could set SRTT to
    /// NaN which then contaminates every subsequent estimate.
    mutating func updateRTT(sample: Double) {
        guard adaptiveTimeout else {
            TxLog.debug(.session, "RTT sample discarded (adaptive disabled)")
            return
        }

        // Discard physically impossible samples before they corrupt state.
        guard sample > 0, sample.isFinite else {
            TxLog.debug(.session, "RTT sample discarded (invalid)", [
                "sample": String(describing: sample)
            ])
            return
        }
        if let s = srtt {
            // Update existing estimates (Jacobson/Karels algorithm)
            rttvar = (1 - beta) * rttvar + beta * abs(s - sample)
            srtt = (1 - alpha) * s + alpha * sample
        } else {
            // First sample
            srtt = sample
            rttvar = sample / 2
        }

        // Calculate RTO with clamping
        let newRTO = (srtt ?? 3.0) + 4 * rttvar
        rto = max(rtoMin, min(rtoMax, newRTO))
    }

    /// Apply exponential backoff (double RTO)
    mutating func backoff() {
        guard adaptiveTimeout else {
            TxLog.debug(.session, "T1 backoff skipped (adaptive disabled)")
            return
        }
        rto = min(rto * 2, rtoMax)
    }

    /// Reset timers to initial RTO (same bounds)
    mutating func reset() {
        srtt = nil
        rttvar = 0.0
        rto = initialRto
    }
}

// MARK: - Session Statistics

/// Statistics for an AX.25 session
nonisolated struct AX25SessionStatistics: Sendable {
    var framesSent: Int = 0
    var framesReceived: Int = 0
    var retransmissions: Int = 0
    var bytesSent: Int = 0
    var bytesReceived: Int = 0

    /// REJs we sent — each one is a gap detected in the peer's I-frame
    /// stream, so each is direct evidence of a loss on the *reverse* path.
    ///
    /// Without this the link controller only ever sees forward-path
    /// evidence. During a download we transmit almost nothing but RRs, so
    /// a link dropping a quarter of the gateway's frames reported loss=0
    /// and ETX=1.00 while the transfer visibly struggled (field capture
    /// 2026-08-23, W0ARP-10: 344 inbound I-frames, 16 REJs sent, adaptive
    /// still at "perfect link").
    var rejSent: Int = 0

    mutating func recordSent(bytes: Int) {
        framesSent += 1
        bytesSent += bytes
    }

    mutating func recordReceived(bytes: Int) {
        framesReceived += 1
        bytesReceived += bytes
    }

    mutating func recordRetransmit() {
        retransmissions += 1
    }

    mutating func recordREJSent() {
        rejSent += 1
    }

    mutating func reset() {
        framesSent = 0
        framesReceived = 0
        retransmissions = 0
        bytesSent = 0
        bytesReceived = 0
        rejSent = 0
    }
}

// MARK: - Session Events

/// Events that can trigger state transitions
nonisolated enum AX25SessionEvent: Sendable {
    // Local requests
    case connectRequest
    case disconnectRequest
    case forceDisconnect
    case sendData(Data)

    // Received U-frames
    case receivedUA
    case receivedDM
    case receivedSABM
    case receivedDISC
    case receivedFRMR

    // Received S-frames
    case receivedRR(nr: Int, pf: Bool = false, isCommand: Bool = false)
    case receivedRNR(nr: Int, pf: Bool = false, isCommand: Bool = false)
    case receivedREJ(nr: Int, pf: Bool = false, isCommand: Bool = false)

    // Received I-frame
    case receivedIFrame(ns: Int, nr: Int, pf: Bool, payload: Data, pid: UInt8? = nil)

    // Timeouts
    case t1Timeout
    /// The T2 response-delay timer expired: an ack is owed and no frame
    /// carrying N(R) has gone out since it was armed.
    case t2Timeout
    case t3Timeout
}

// MARK: - Session Actions

/// Actions to take in response to events
nonisolated enum AX25SessionAction: Sendable, Equatable {
    case sendSABM
    case sendUA
    case sendDM
    case sendDISC
    case sendRR(nr: Int, pf: Bool = false, isCommand: Bool = false)
    case sendRNR(nr: Int, pf: Bool = false, isCommand: Bool = false)
    case sendREJ(nr: Int, pf: Bool = false, isCommand: Bool = false)
    /// Selective reject: retransmit exactly frame N(R). F-bit asymmetry
    /// (§4.3.2.4): F=1 acknowledges everything below N(R); F=0
    /// acknowledges nothing.
    case sendSREJ(nr: Int, pf: Bool = false, isCommand: Bool = false)
    case sendIFrame(ns: Int, nr: Int, payload: Data)
    case startT1
    case stopT1
    /// Arm the T2 response-delay timer (idempotent — the manager keeps an
    /// already-running deadline): an in-sequence delivery with P=0 owes
    /// the peer a cumulative ack, but sending it immediately wastes a
    /// key-up per frame and can collide with the peer's next I-frame on
    /// simplex. The ack rides the next F=1 poll response, the next
    /// outgoing I-frame's N(R), or a REJ — or goes out alone when T2
    /// expires, at most t2AckDelay after the first unacked delivery.
    case startT2
    case stopT2
    case startT3
    case stopT3
    case deliverData(Data, pid: UInt8? = nil)
    case notifyConnected
    case notifyDisconnected
    case notifyError(String)
    /// Clear the session's outbound send buffer (used on link reset, e.g. SABM while connected)
    case clearSendBuffer
}

// MARK: - State Machine

/// Buffered I-frame waiting for delivery
nonisolated struct BufferedIFrame: Sendable {
    let ns: Int
    let nr: Int
    let payload: Data
    /// AX.25 PID of the frame that carried this payload. Delivery keeps
    /// it so the manager can demux by protocol (0xF0 terminal text vs
    /// 0xCF NET/ROM datagrams) even for frames that sat in the
    /// resequencing buffer.
    var pid: UInt8? = nil
}

/// AX.25 connected-mode state machine
/// Handles state transitions and generates actions in response to events
nonisolated struct AX25StateMachine: Sendable {
    /// Current session state
    private(set) var state: AX25SessionState = .disconnected {
        didSet { if state == .connected { hasEverConnected = true } }
    }

    /// Distinguishes a session that ENDED (connected once, now
    /// disconnected/error) from one that merely hasn't started yet — both
    /// read .disconnected, but only the former is a stale carcass that a
    /// reconnect must replace. A fresh session with queued data awaiting its
    /// first SABM must never be discarded.
    private(set) var hasEverConnected = false

    /// Session configuration (fixed at connection start; never changed mid-session to avoid corrupting in-flight data).
    let config: AX25SessionConfig

    /// Sequence number state
    var sequenceState: AX25SequenceState

    /// Retry counter for current operation
    private(set) var retryCount: Int = 0

    /// Consecutive polls from the peer answered while nothing was in flight in
    /// either direction.
    ///
    /// Not a protocol condition — answering a poll is mandatory and every one of
    /// these exchanges is correct. It is the *shape* that is wrong: a link that
    /// is up, is being polled every few seconds, and has carried no data since it
    /// opened is a link that is not working, and the operator sees only
    /// "connected". Field capture 2026-08-26, KB5YZB-7 direct: ten polls in
    /// ninety seconds, `vr` never left 0, the BBS never answered.
    private(set) var idlePollCount: Int = 0

    /// Consecutive REJs that acknowledged nothing new and asked for a frame we
    /// have never sent.
    ///
    /// Counted apart from `retryCount` on purpose. §6.7.1.1 requires an F=1
    /// answer to a poll to clear the retry count, and that rule is right — but
    /// it is also what made this livelock permanent, because the peer's answer
    /// is always F=1. Escaping it by refusing to clear `retryCount` would break
    /// the spec rule to fix a case the spec does not cover; a separate count
    /// leaves §6.7.1.1 intact.
    private(set) var unsatisfiableREJCount: Int = 0

    /// Record a retransmission cycle that produced no ack progress — e.g. the
    /// peer's RR command poll arrived with V(A) frozen and we are about to
    /// retransmit in response. Climbs the same N2 ladder as T1 expiry.
    ///
    /// Without this, a peer that cannot hear us but keeps command-polling
    /// (each poll arriving inside our RTO and restarting T1) froze retryCount
    /// at 0 forever: T1 never expired, N2 never tripped, and the session
    /// retransmitted the same I-frame indefinitely (field capture 2026-08-22:
    /// ns=2 "b" resent every ~10 s with va pinned, no escalation, no failure).
    /// Returns the link-failure actions when N2 is exhausted; empty otherwise.
    /// Any genuine ack progress resets the ladder via the usual paths.
    mutating func noteRetransmissionWithoutProgress() -> [AX25SessionAction] {
        retryCount += 1
        guard retryCount > config.maxRetries else { return [] }
        state = .error
        TxLog.error(.ax25, "Link failure", error: nil, [
            "reason": "no ACK progress after \(config.maxRetries) retransmissions",
            "retries": retryCount,
            "vs": sequenceState.vs,
            "va": sequenceState.va,
            "vr": sequenceState.vr
        ])
        return [.stopT1, .stopT3, .notifyError("Link failure (no ACK progress after \(config.maxRetries) retries)")]
    }

    /// Advances V(R) past a frame that is not coming, delivering whatever was
    /// buffered behind it. Returns no actions when there is no gap to skip.
    ///
    /// Permanently discards the missing frame's contents, so every caller must
    /// have its own reason why that is the lesser loss. Shared so both reasons
    /// discard identically and report identically.
    private mutating func skipReceiveGap(reason: String) -> [AX25SessionAction] {
        guard !receiveBuffer.isEmpty,
              let lowestBuffered = receiveBuffer.keys
                .min(by: { distanceFromVR($0) < distanceFromVR($1) })
        else { return [] }

        let skippedCount = (lowestBuffered - sequenceState.vr + config.modulo) % config.modulo
        // First-class Sentry event, not just a breadcrumb: this is the one
        // path that permanently discards received user data, and it resets
        // retryCount below — which prevents the N2 link-failure event that
        // would otherwise have been the only thing to ship the surrounding
        // breadcrumbs.
        TxLog.dataLoss(.session, "Receive-gap flush skipped lost frame(s)", [
            "currentVR": sequenceState.vr,
            "jumpingTo": lowestBuffered,
            "skippedFrames": skippedCount,
            "bufferedCount": receiveBuffer.count,
            "reason": reason
        ])

        sequenceState.vr = lowestBuffered
        var actions: [AX25SessionAction] = []
        while let buffered = receiveBuffer.removeValue(forKey: sequenceState.vr) {
            sequenceState.incrementVR()
            actions.append(.deliverData(buffered.payload, pid: buffered.pid))
        }
        rejSent = false
        retryCount = 0
        return actions
    }

    /// Skips a gap on the caller's word that the lost bytes can be spared.
    ///
    /// Exists for one caller: a NET/ROM relay waiting on a node's greeting. The
    /// T1-driven flush above is gated at the retry before link failure, which
    /// at a 30 s RTO is minutes — far past any handshake — so a banner whose
    /// first frame was lost deadlocks: the rest sits buffered, nothing is
    /// delivered, and the handshake times out with the prompt in hand but
    /// unread (KB5YZB-7, 2026-08-27).
    ///
    /// Safe *here* and nowhere else, because the discarded bytes are greeting
    /// text. The handshake needs only to see that the node spoke, and a node
    /// re-prompts on a bare CR anyway. Weighed against losing the connection
    /// attempt entirely, part of a banner is the cheaper loss.
    mutating func skipReceiveGapForHandshake() -> [AX25SessionAction] {
        skipReceiveGap(reason: "relay-handshake")
    }

    /// Receive buffer for out-of-sequence I-frames
    /// Key is N(S) sequence number
    var receiveBuffer: [Int: BufferedIFrame] = [:]

    /// Flag indicating we've sent REJ and are waiting for retransmission
    /// This prevents sending multiple REJs for the same gap
    private(set) var rejSent: Bool = false

    /// True while an in-sequence delivery is still unacknowledged — the T2
    /// delayed-ack debt. Settled by the F=1 poll response, by T2 expiry, by
    /// a REJ (it carries N(R)), or by any outgoing I-frame's piggybacked
    /// N(R) via `noteAckTransmitted()`.
    private(set) var ackPending: Bool = false

    /// The manager builds I-frames itself and every one carries N(R); it
    /// calls this when one goes out so T2 does not fire a redundant RR.
    mutating func noteAckTransmitted() {
        ackPending = false
    }

    /// Peer receiver-busy condition (AX.25 §4.3.2.3).
    /// Set when the remote sends RNR; cleared when it answers RR/REJ or the link is
    /// re-established. While set, no new I-frames may be sent — the peer has told us
    /// its receive buffer is full — but T1 keeps running so we can poll it.
    private(set) var peerBusy: Bool = false

    init(config: AX25SessionConfig) {
        self.config = config
        self.sequenceState = AX25SequenceState(modulo: config.modulo)
    }

    /// Reset all session state for a new connection
    mutating func resetSessionState() {
        sequenceState.reset()
        receiveBuffer.removeAll()
        rejSent = false
        ackPending = false
        peerBusy = false
    }

    /// Force recovery from late UA. Called by session manager only when it determines
    /// a late UA should be accepted (SABM sent recently, within timeout window).
    /// This is a manager-level override — the spec-strict handle(event:) ignores UA
    /// in disconnected/error states per AX.25 §6.3.
    mutating func forceRecoverFromLateUA() -> [AX25SessionAction] {
        state = .connected
        retryCount = 0
        resetSessionState()
        return [.stopT1, .startT3, .notifyConnected]
    }

    /// Handle an event and return the list of actions to execute
    mutating func handle(event: AX25SessionEvent) -> [AX25SessionAction] {
        let oldState = state
        let actions = handleInternal(event: event)

        // State transitions are logged in ALL builds: they are rare (a handful
        // per session) and are exactly the breadcrumbs a link-failure event
        // needs. Entering .error is a warning so it survives flood control.
        if oldState != state {
            let fields: [String: Any] = [
                "from": oldState.rawValue,
                "to": state.rawValue,
                "event": String(String(describing: event).prefix(80))
            ]
            if state == .error {
                TxLog.warning(.session, "AX25 state transition", fields)
            } else {
                TxLog.debug(.session, "AX25 state transition", fields)
            }
        }

        // The per-event action dump is genuinely verbose trace data — DEBUG only.
#if DEBUG
        if !actions.isEmpty {
            TxLog.debug(.ax25, "AX25 actions", [
                "state": state.rawValue,
                "event": String(describing: event).prefix(80),
                "actions": actions.map { String(describing: $0) }.joined(separator: ", ")
            ])
        }
#endif

        return actions
    }

    /// Internal handler for state machine logic
    private mutating func handleInternal(event: AX25SessionEvent) -> [AX25SessionAction] {
        switch (state, event) {

        // MARK: - Disconnected State

        case (.disconnected, .connectRequest):
            state = .connecting
            retryCount = 0
            resetSessionState()
            TxLog.outbound(.ax25, "Initiating connection (SABM)")
            return [.sendSABM, .startT1]

        case (.disconnected, .receivedSABM):
            // Remote initiated connection
            state = .connected
            resetSessionState()
            TxLog.inbound(.ax25, "Connection request received (SABM)")
            return [.sendUA, .startT3, .notifyConnected]

        case (.disconnected, .receivedDISC):
            // §6.3.5: "In the disconnected state, a TNC ... transmits a DM frame in
            // response to a DISC command."
            return [.sendDM]

        case (.disconnected, .receivedIFrame(_, _, let pf, _, _)):
            // §6.3.5: "Any TNC receiving a command frame other than a SABM(E) or UI
            // frame with the P bit set to '1' responds with a DM frame with the F bit
            // set to '1'. The offending frame is ignored."  I frames are always
            // commands in AX.25 v2.2 (an I *response* is itself a protocol error,
            // Annex C error code S). Without this DM, a peer holding a stale session
            // keeps polling us until its own N2 expires instead of clearing promptly.
            // P=0 frames are ignored per the same sentence — this also protects
            // against DM storms from digipeated duplicates, which carry P=0.
            return pf ? [.sendDM] : []

        case (.disconnected, .receivedRR(_, let pf, let isCommand)),
             (.disconnected, .receivedRNR(_, let pf, let isCommand)),
             (.disconnected, .receivedREJ(_, let pf, let isCommand)):
            // §6.3.5 / §6.2: "The next response frame returned to a S or I command
            // frame with the P bit set to '1', received in the disconnected state, is
            // a DM response frame with the F bit set to '1'."  Response frames and
            // P=0 commands are ignored.
            return (pf && isCommand) ? [.sendDM] : []

        case (.disconnected, _):
            // Ignore other events in disconnected state
            return []

        // MARK: - Connecting State

        case (.connecting, .receivedUA):
            state = .connected
            retryCount = 0
            TxLog.inbound(.ax25, "Connection established (UA received)")
            return [.stopT1, .startT3, .notifyConnected]

        case (.connecting, .receivedSABM):
            // SABM Collision (Section 6.3.3)
            state = .connected
            retryCount = 0
            TxLog.inbound(.ax25, "SABM collision - Connection established")
            return [.stopT1, .sendUA, .startT3, .notifyConnected]

        case (.connecting, .receivedDM):
            state = .disconnected
            TxLog.error(.ax25, "Connection refused", error: nil, ["reason": "DM received"])
            return [.stopT1, .notifyError("Connection refused (DM received)")]

        case (.connecting, .receivedDISC):
            // SDL C4.2 (awaiting connection): a DISC is answered with DM — not UA,
            // because UA would acknowledge a mode-setting command for a link that is
            // not up — and the state machine REMAINS in awaiting-connection with the
            // SABM retry cycle running.
            //
            // Why stay: DISC crossing our SABM usually means the peer is tearing down
            // an old session, not refusing a new one. Once its teardown completes,
            // our next SABM retry establishes the fresh link. A peer that is actually
            // refusing answers the SABM itself with DM (§6.3.1), which the
            // (.connecting, .receivedDM) case turns into an immediate, clean abort.
            // Either way termination is bounded: refusal aborts on DM, and silence
            // exhausts N2 via the T1 path. (This replaces the earlier Bug I behavior
            // of aborting on DISC, which misread crossed teardown frames as refusal.)
            TxLog.warning(.ax25, "DISC while connecting — answered DM, SABM retry continues")
            return [.sendDM]

        case (.connecting, .receivedIFrame),
             (.connecting, .receivedRR),
             (.connecting, .receivedRNR),
             (.connecting, .receivedREJ):
            // §6.3.1: "The originating TNC sending a SABM(E) command ignores and
            // discards any frames except SABM, DISC, UA and DM frames from the
            // distant TNC."
            //
            // This case previously answered with DM to "reset a phantom session".
            // That was a spec violation with real consequences (seen live against
            // KB5YZB-7, a BPQ node): the peer had answered our SABM with UA and its
            // first I-frame, both lost on RF. It was legitimately connected — and DM
            // told it to tear the fresh link down. §6.3.1 already provides the reset
            // mechanism for a genuinely stale peer: our retransmitted SABM forces it
            // to re-establish and zero its state variables. No DM is needed.
            return []

        case (.connecting, .t1Timeout):
            retryCount += 1
            TxLog.warning(.ax25, "T1 timeout during connect", ["retry": retryCount, "maxRetries": config.maxRetries])
            if retryCount > config.maxRetries {
                state = .error
                TxLog.error(.ax25, "Connection failed", error: nil, ["reason": "retries exceeded"])
                return [.stopT1, .notifyError("Connection timeout (retries exceeded)")]
            }
            return [.sendSABM, .startT1]

        case (.connecting, .disconnectRequest):
            state = .disconnecting
            return [.stopT1, .sendDISC, .startT1]

        case (.connecting, .forceDisconnect):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

        case (.connecting, _):
            return []

        // MARK: - Connected State

        case (.connected, .disconnectRequest):
            state = .disconnecting
            retryCount = 0
            return [.sendDISC, .stopT3, .startT1]

        case (.connected, .forceDisconnect):
            state = .disconnected
            retryCount = 0
            return [.stopT1, .stopT3, .notifyDisconnected]

        case (.connected, .receivedDISC):
            state = .disconnected
            // .stopT1 is required: T1 may be running for outstanding I-frames.
            // Without it, the timer fires after disconnect and incorrectly triggers
            // a retransmit or state-machine event against a dead session.
            return [.sendUA, .stopT1, .stopT3, .notifyDisconnected]

        case (.connected, .receivedSABM):
            // Remote is re-establishing the link from scratch per AX.25 §4.3.3.1.
            // Must fully reset: V(S)/V(R)/V(A) via resetSessionState(), plus flush the
            // outer send buffer (clearSendBuffer action) so no stale frames remain.
            resetSessionState()
            return [.clearSendBuffer, .stopT1, .sendUA, .startT3]

        case (.connected, .receivedIFrame(let ns, let nr, let pf, let payload, let pid)):
            // The link is carrying data after all.
            idlePollCount = 0
            TxLog.inbound(.ax25, "I-frame received", ["ns": ns, "nr": nr, "pf": pf, "size": payload.count])
            return handleIFrame(ns: ns, nr: nr, pf: pf, payload: payload, pid: pid)

        case (.connected, .receivedRR(let nr, let pf, let isCommand)):
            return sequenceState.isValidNR(nr: nr) ? handleRR(nr: nr, pf: pf, isCommand: isCommand) : []

        case (.connected, .receivedRNR(let nr, let pf, let isCommand)):
            // Peer receiver busy (§4.3.2.3). The N(R) field still carries a valid
            // acknowledgement, so process it before entering the busy condition.
            let vaBeforeRNR = sequenceState.va
            if sequenceState.isValidNR(nr: nr) {
                sequenceState.ackUpTo(nr: nr)
            }
            if sequenceState.va != vaBeforeRNR {
                // The peer acknowledged new frames, so the link is alive. Clear the retry
                // counter exactly as handleRR does — otherwise retries accumulated before
                // the busy condition persist and trip a premature "retries exceeded".
                retryCount = 0
            }
            if pf && !isCommand {
                // F=1 RNR answers a poll we sent: the peer is alive, merely busy
                // (§4.4.5.2 names RNR as a valid enquiry answer). Exit timer recovery.
                retryCount = 0
            }
            if !peerBusy {
                // Warning so the busy period is visible in Sentry: a peer stuck
                // in RNR stalls all outbound data, and this transition used to
                // be logged nowhere at all.
                TxLog.warning(.ax25, "Peer busy (RNR received) — outbound data held", [
                    "nr": nr, "pf": pf, "isCommand": isCommand
                ])
            }
            peerBusy = true

            // Keep T1 running. §6.4.9 clears a busy peer by polling it until it answers
            // RR or REJ. The previous [.stopT1] left the link with no timer running at
            // all (T3 is not started here either), so a busy peer stalled the session
            // indefinitely unless it spoke first.
            // AX.25 v2.2 "check I frame acknowledged", peer_receiver_busy branch:
            //   V(A) <- N(R); start T3; if T1 is not running, start T1.
            // T3 is the link-validity backstop while no I-frame exchange can happen;
            // T1 drives the poll that eventually clears the busy condition.
            var rnrActions: [AX25SessionAction] = [.startT3, .startT1]
            if pf && isCommand {
                rnrActions.append(.sendRR(nr: sequenceState.vr, pf: true, isCommand: false))
            }
            return rnrActions

        case (.connected, .receivedREJ(let nr, let pf, let isCommand)):
            // Remote requests retransmit from nr. An REJ also clears a peer-busy
            // condition (§4.3.2.3) — the peer is asking for data again.
            if peerBusy {
                TxLog.warning(.ax25, "Peer busy condition cleared (REJ received)", ["nr": nr])
            }
            peerBusy = false
            let vaBeforeREJ = sequenceState.va
            if sequenceState.isValidNR(nr: nr) {
                sequenceState.ackUpTo(nr: nr)
            }
            let hadAckProgress = sequenceState.va != vaBeforeREJ
            if hadAckProgress {
                // Ack progress means the link is alive; reset retries for the same
                // reason handleRR does. Without this, an REJ-heavy exchange kept the
                // retry count from earlier T1 timeouts and failed the link early.
                retryCount = 0
                unsatisfiableREJCount = 0
            }
            if pf && !isCommand {
                // §6.2 lists REJ among the valid F=1 answers to a poll — the peer is
                // alive and asking for retransmission. Exit timer recovery.
                retryCount = 0
            }
            var actions: [AX25SessionAction] = []
            if sequenceState.outstandingCount > 0 {
                // Frames remain unacked: the session manager will retransmit from nr,
                // and T1 must protect those retransmissions.
                unsatisfiableREJCount = 0
                actions.append(.startT1)
            } else {
                // The REJ acknowledged everything we sent, so there is nothing to
                // retransmit (the peer's reject condition was raised by a duplicate,
                // e.g. a T1 retransmission that crossed its ack in flight). Running
                // T1 here creates an infinite enquiry loop: T1 fires with nothing
                // outstanding, we poll RR(P=1), the peer answers REJ(F=1) because
                // its reject condition only clears on the next NEW I-frame, and we
                // start T1 again — forever. Mirror handleRR: stop T1, start T3.
                //
                // Stopping T1 keeps that loop off T1's cadence but does not end it:
                // T3 still polls, the peer still answers REJ, and the exchange
                // repeats until one side gives up. Nothing can satisfy it — the
                // peer's reject clears only on the I-frame it is asking for, and we
                // have none to send.
                //
                // §6.7.1.1: a link that cannot make progress climbs the N2 ladder and
                // fails. Resetting `retryCount` here (as the F=1 rule above used to,
                // unconditionally) pinned the count at zero and made the livelock
                // permanent — the same defect `noteRetransmissionWithoutProgress`
                // was written for, arriving through REJ instead of through polling.
                if !hadAckProgress {
                    unsatisfiableREJCount += 1
                    if unsatisfiableREJCount > config.maxRetries {
                        state = .error
                        TxLog.error(.ax25, "Link failure", error: nil, [
                            "reason": "peer rejected \(unsatisfiableREJCount) times asking "
                                    + "for a frame that was never sent",
                            "nr": nr,
                            "vs": sequenceState.vs,
                            "va": sequenceState.va
                        ])
                        return [.stopT1, .stopT3,
                                .notifyError("Link failure (peer asking for a frame "
                                             + "that was never sent)")]
                    }
                }
                actions.append(.stopT1)
                actions.append(.startT3)
            }
            if pf && isCommand {
                actions.append(.sendRR(nr: sequenceState.vr, pf: true, isCommand: false))
            }
            // Note: actual retransmit logic would be handled by session manager
            return actions

        case (.connected, .receivedFRMR):
            state = .error
            TxLog.error(.ax25, "Protocol error", error: nil, ["reason": "FRMR received"])
            // Stop T1 as well: the session is dead, and a live T1 would fire a
            // spurious retransmit/poll into the error state (same class of bug
            // as the stale-timer fixes elsewhere).
            return [.stopT1, .stopT3, .notifyError("Protocol error (FRMR received)")]

        case (.connected, .receivedDM):
            state = .disconnected
            TxLog.warning(.ax25, "Remote disconnected (DM received)")
            // Stop T1 too: a DM can arrive while outbound I-frames are outstanding
            // or while the T1 grace retransmit task is pending. Leaving T1 alive
            // causes a spurious timeout/retransmit after the session is already dead.
            return [.stopT1, .stopT3, .notifyError("Remote disconnected (DM received)")]

        case (.connected, .t1Timeout):
            retryCount += 1
            TxLog.warning(.ax25, "T1 timeout", [
                "retry": retryCount,
                "outstanding": sequenceState.outstandingCount,
                "windowSize": config.windowSize,
                "vs": sequenceState.vs,
                "va": sequenceState.va,
                "vr": sequenceState.vr,
                "receiveBufferCount": receiveBuffer.count
            ])
            if retryCount > config.maxRetries {
                state = .error
                TxLog.error(.ax25, "Link failure", error: nil, [
                    "reason": "retries exceeded",
                    "retries": retryCount,
                    "windowSize": config.windowSize,
                    "vs": sequenceState.vs,
                    "va": sequenceState.va,
                    "vr": sequenceState.vr
                ])
                return [.stopT1, .stopT3, .notifyError("Link failure (retries exceeded)")]
            }

            // RECEIVE BUFFER FLUSH — LAST DITCH ONLY (deliberate spec deviation):
            // §6.4.4.1 (implicit reject) forbids delivering data across a missing
            // N(S): out-of-sequence I frames are discarded and the gap must heal
            // via REJ retransmission. (Buffering them at all is already an
            // SREJ-style extension.) Skipping V(R) past the gap permanently loses whatever the
            // missing frame carried, so it may only happen when the alternative is
            // worse — N2 exhaustion tearing the whole link down (which loses all
            // subsequent data too). That is the one scenario this flush exists for:
            // a peer that truly never retransmits the missing frame (observed once
            // with DRLNOD: it sent ns=0,3,1 and never resent ns=2, leaving V(R)
            // stuck until it DM'd us).
            //
            // The threshold is therefore the retry just before link failure, not a
            // small constant. Field capture 2026-08-22 (KB5YZB-7 via DRLNOD): a
            // retryCount>=2 threshold with a 4 s RTO flushed after ~8 s on a path
            // whose measured RTT was 4–8 s, and silently dropped two 128-byte
            // frames the peer was still actively retransmitting.
            var actions: [AX25SessionAction] = []
            let flushThreshold = max(2, config.maxRetries - 1)
            if retryCount >= flushThreshold {
                actions.append(contentsOf: skipReceiveGap(reason: "n2-exhaustion"))
            }

            // Per AX.25 spec §6.4.1: on T1 timeout, send RR with P=1 (poll)
            // to verify the link only if there are no outstanding I-frames.
            // If outstanding I-frames exist, standard protocol dictates we
            // immediately retransmit the oldest outstanding I-frame with P=1
            // (handled at the SessionManager level).
            // When the peer is busy we must not retransmit I-frames into its full
            // buffer; poll it with RR(P=1) instead until it clears the condition.
            if sequenceState.outstandingCount == 0 || peerBusy {
                actions.append(.sendRR(nr: sequenceState.vr, pf: true, isCommand: true))
            }
            actions.append(.startT1)
            return actions

        case (.connected, .t2Timeout):
            // Fire the owed cumulative ack — once. Anything that carried
            // N(R) in the meantime already settled the debt and cleared
            // the flag, so a stale expiry stays silent.
            guard ackPending else { return [] }
            ackPending = false
            return [.sendRR(nr: sequenceState.vr, pf: false)]

        case (_, .t2Timeout):
            return []

        case (.connected, .t3Timeout):
            // §4.4.5.2: "When T3 times out, an RR or RNR frame is transmitted as a
            // command with the P bit set, and then T1 is started. When a response to
            // this command is received, T1 is stopped and T3 is started. If T1
            // expires before a response is received, then the waiting acknowledgement
            // procedure (Section 6.4.11) is executed."
            //
            // This previously sent a response-mode RR(F=0) and passively restarted T3
            // as a DRLNOD compatibility measure. That keepalive was decorative: an
            // unsolicited response demands no answer, so it could never actually
            // confirm the link was alive. The spec enquiry can — and a peer that
            // answers a live-link poll with DM is telling us the session is genuinely
            // gone (its §6.3.5 disconnected-state response), in which case tearing
            // down is correct, not flakiness.
            //
            // retryCount starts at 0 for the enquiry cycle (SDL: RC←0 on T3 expiry);
            // unanswered polls then escalate through the T1 path until N2 declares
            // link failure.
            retryCount = 0
            return [.sendRR(nr: sequenceState.vr, pf: true, isCommand: true), .startT1]

        case (.connected, _):
            return []

        // MARK: - Disconnecting State

        case (.disconnecting, .receivedUA):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

        case (.disconnecting, .receivedDISC):
            // DISC collision — both sides sent DISC. SDL C4.3 (awaiting release)
            // answers a DISC with DM, and §6.3.4 confirms the peer accepts it:
            // "After receiving a UA or DM response to a sent DISC command, the TNC
            // cancels timer T1 and enters the disconnected state." UA is the reply
            // for a DISC received on an established link (§6.3.4); with our own DISC
            // outstanding the link is already half-down, so DM is the accurate answer.
            state = .disconnected
            return [.stopT1, .sendDM, .notifyDisconnected]

        case (.disconnecting, .receivedDM):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

        case (.disconnecting, .forceDisconnect):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

        case (.disconnecting, .receivedSABM):
            // SDL awaiting-release state (Annex C, Figure C4.3): a SABM arriving while
            // our DISC is outstanding is refused with DM. We are tearing the link
            // down; the peer may retry SABM once teardown completes.
            return [.sendDM]

        case (.disconnecting, .receivedIFrame(_, _, let pf, _, _)):
            // SDL awaiting-release (Figure C4.3): command frames with P=1 received
            // while a DISC is outstanding are answered with DM (F=1); everything
            // else is discarded. Mirrors the §6.3.5 disconnected-state rule.
            return pf ? [.sendDM] : []

        case (.disconnecting, .receivedRR(_, let pf, let isCommand)),
             (.disconnecting, .receivedRNR(_, let pf, let isCommand)),
             (.disconnecting, .receivedREJ(_, let pf, let isCommand)):
            // SDL awaiting-release (Figure C4.3): same DM(F=1) rule for supervisory
            // command polls.
            return (pf && isCommand) ? [.sendDM] : []

        case (.disconnecting, .t1Timeout):
            retryCount += 1
            if retryCount > config.maxRetries {
                state = .disconnected
                return [.stopT1, .notifyDisconnected]
            }
            return [.sendDISC, .startT1]

        case (.disconnecting, _):
            return []

        // MARK: - Error State

        case (.error, .connectRequest):
            state = .connecting
            retryCount = 0
            resetSessionState()
            return [.sendSABM, .startT1]

        case (.error, .forceDisconnect):
            state = .disconnected
            return [.stopT1, .stopT3, .notifyDisconnected]

        case (.error, _):
            return []
        }
    }

    // MARK: - I-Frame Handling

    private mutating func handleIFrame(ns: Int, nr: Int, pf: Bool, payload: Data, pid: UInt8?) -> [AX25SessionAction] {
        var actions: [AX25SessionAction] = []

        // Process N(R) - acknowledge our sent frames
        let vaBeforeIFrameAck = sequenceState.va
        if sequenceState.outstandingCount > 0 && sequenceState.isValidNR(nr: nr) {
            sequenceState.ackUpTo(nr: nr)
        }

        // Check if this is the expected sequence number
        if ns == sequenceState.vr {
            // In sequence - deliver this frame and any consecutive buffered frames
            // Pass the P/F bit so we can respond with F=1 if P=1
            actions.append(contentsOf: deliverInSequenceFrame(ns: ns, nr: nr, pf: pf, payload: payload, pid: pid))
        } else if isWithinReceiveWindow(ns: ns) {
            // Out of sequence but within window - buffer for later delivery

            bufferOutOfSequenceFrame(ns: ns, nr: nr, payload: payload, pid: pid)

            // Send REJ only once per gap (with F=1 if remote sent P=1).
            //
            // .startT1 is essential, not decoration: T1 is what eventually rescues a gap the
            // peer never fills. The T1-timeout handler above flushes the receive buffer past
            // a lost frame after 2 expiries, but that can only run if T1 is actually ticking.
            // With no outbound I-frames outstanding T1 is stopped, so a peer that opens the
            // link and then sends a wrong N(S) left the gap — and everything gated on it —
            // stuck until the peer happened to poll. Starting T1 here matches AX.25 REJ
            // recovery, where the rejecting station times the awaited retransmission.
            if !rejSent {
                if config.srejEnabled {
                    // Ask for exactly the missing frame. §4.3.2.4: only an
                    // F=1 SREJ acknowledges below N(R) — an F=0 SREJ acks
                    // nothing, so the T2 ack debt must survive it and the
                    // cumulative RR still goes out later.
                    actions.append(.sendSREJ(nr: sequenceState.vr, pf: pf))
                    if pf, ackPending {
                        ackPending = false
                        actions.append(.stopT2)
                    }
                } else {
                    actions.append(.sendREJ(nr: sequenceState.vr, pf: pf))
                    // REJ carries N(R): everything before the gap is now
                    // acked, so a pending T2 would only fire a redundant RR.
                    if ackPending {
                        ackPending = false
                        actions.append(.stopT2)
                    }
                }
                actions.append(.startT1)
                rejSent = true
            } else {
                // Still need to respond if P=1, even if REJ already sent
                if pf {
                    actions.append(.sendRR(nr: sequenceState.vr, pf: true))
                    if ackPending {
                        ackPending = false
                        actions.append(.stopT2)
                    }
                }
            }
        } else {
            // Outside window - this is likely a duplicate of an already-received frame

            // Re-ack V(R) so a peer whose RR we lost can resynchronize —
            // but cumulatively, like any other ack. A retransmitted burst
            // arrives as several duplicates; re-acking each one repeats
            // the key-up-per-frame waste the delay exists to remove.
            if pf {
                actions.append(.sendRR(nr: sequenceState.vr, pf: true))
                if ackPending {
                    ackPending = false
                    actions.append(.stopT2)
                }
            } else {
                ackPending = true
                actions.append(.startT2)
            }
        }

        // If piggybacked ack advanced V(A) and frames remain, restart T1 per §6.4.6
        if sequenceState.va != vaBeforeIFrameAck && sequenceState.outstandingCount > 0 {
            actions.append(.startT1)
        }

        return actions
    }

    /// Deliver an in-sequence frame and any consecutive buffered frames
    /// - Parameters:
    ///   - ns: N(S) sequence number
    ///   - nr: N(R) sequence number
    ///   - pf: P/F bit from incoming frame - if true, we must respond with F=1
    ///   - payload: Frame payload
    private mutating func deliverInSequenceFrame(ns: Int, nr: Int, pf: Bool, payload: Data, pid: UInt8?) -> [AX25SessionAction] {
        var actions: [AX25SessionAction] = []

        // Clear REJ flag since we're receiving the expected frame
        rejSent = false

        // Deliver the current frame
        sequenceState.incrementVR()

        actions.append(.deliverData(payload, pid: pid))

        // Check for consecutive buffered frames and deliver them
        while let buffered = receiveBuffer.removeValue(forKey: sequenceState.vr) {
            sequenceState.incrementVR()

            actions.append(.deliverData(buffered.payload, pid: buffered.pid))
        }

        // A second gap can already be visible: frames beyond it are still
        // buffered. With SREJ negotiated, ask for the new missing frame
        // now — leaving it costs a full T1 before anything moves.
        if config.srejEnabled, !receiveBuffer.isEmpty, !rejSent {
            actions.append(.sendSREJ(nr: sequenceState.vr, pf: false))
            actions.append(.startT1)
            rejSent = true
        }

        // Acknowledge cumulatively. A P=1 frame demands an immediate F=1
        // response and that one RR covers every frame delivered so far. A
        // P=0 frame only arms T2: at 1200 baud on simplex, acking each
        // frame of a K=4 burst spends four key-ups where one is needed,
        // and our RR can collide with the peer's next I-frame — turning
        // the ack itself into inbound loss and a go-back-N resend.
        if pf {
            actions.append(.sendRR(nr: sequenceState.vr, pf: true))
            if ackPending {
                ackPending = false
                actions.append(.stopT2)
            }
        } else {
            ackPending = true
            actions.append(.startT2)
        }
        actions.append(.startT3)

        if sequenceState.outstandingCount == 0 {
            actions.append(.stopT1)
        }

        return actions
    }

    /// Buffer an out-of-sequence frame for later delivery
    private mutating func bufferOutOfSequenceFrame(ns: Int, nr: Int, payload: Data, pid: UInt8?) {
        // Don't buffer duplicates
        guard receiveBuffer[ns] == nil else {

            return
        }

        // Room for a full receive span. Defaulting this to K threw away frames
        // the window test had just accepted.
        let bufferLimit = config.maxReceiveBufferSize ?? max(1, config.receiveWindowSpan - 1)
        if receiveBuffer.count >= bufferLimit {

            // Remove the frame with the LARGEST distance from V(R), i.e. the one we will need last.
            // (Removing the smallest distance would drop the next frame we need—e.g. N(S)=4 when V(R)=0—
            // causing consistent loss of the same chunk index in file transfers.)
            if let farthestKey = receiveBuffer.keys.max(by: { distanceFromVR($0) < distanceFromVR($1) }) {
                receiveBuffer.removeValue(forKey: farthestKey)
            }
        }

        receiveBuffer[ns] = BufferedIFrame(ns: ns, nr: nr, payload: payload, pid: pid)

    }

    /// Check if a sequence number is within the receive window
    /// A frame is within the window if it's between V(R) and V(R) + window size (modulo)
    private func isWithinReceiveWindow(ns: Int) -> Bool {
        let modulo = config.modulo
        let vr = sequenceState.vr

        // Calculate distance from V(R) in forward direction
        let distance = (ns - vr + modulo) % modulo

        // Distance 0 is the expected frame (handled separately). Everything
        // strictly inside half the modulo is unambiguously ahead of V(R), so it
        // is a future frame worth holding; at or past that point the number may
        // instead be a duplicate from the previous sequence lap, which must not
        // be buffered as "future" (an earlier `<= windowSize` bound did exactly
        // that and delivered a lap-old payload when V(R) wrapped onto it —
        // caught by AX25FieldFuzzTests under retransmit churn).
        //
        // The bound is a property of the sequence space, not of our transmit
        // window: see `AX25SessionConfig.receiveWindowSpan`.
        return distance > 0 && distance < config.receiveWindowSpan
    }

    /// Calculate distance from V(R) for buffer management
    private func distanceFromVR(_ ns: Int) -> Int {
        let modulo = config.modulo
        return (ns - sequenceState.vr + modulo) % modulo
    }

    // MARK: - RR Handling

    private mutating func handleRR(nr: Int, pf: Bool = false, isCommand: Bool = false) -> [AX25SessionAction] {
        var actions: [AX25SessionAction] = []

        // An RR clears any peer receiver-busy condition (§4.3.2.3).
        if peerBusy {
            TxLog.warning(.ax25, "Peer busy condition cleared (RR received)", ["nr": nr])
        }
        peerBusy = false

        // An F=1 *response* is the answer to a P=1 poll we sent (T3 enquiry or T1
        // recovery). It proves the link is alive, so the retry counter resets even
        // when no new frames are acknowledged — this is the SDL's exit from the
        // timer-recovery condition. Without it, retries accumulated during one
        // enquiry cycle would leak into the next and trip a premature N2 failure.
        if pf && !isCommand {
            retryCount = 0
        }
        
        if pf && isCommand {
            actions.append(.sendRR(nr: sequenceState.vr, pf: true, isCommand: false))
            // A poll answered while nothing is in flight either way. Data moving
            // in either direction clears this; see `idlePollCount`.
            if sequenceState.outstandingCount == 0 && sequenceState.vr == 0 {
                idlePollCount += 1
            }
        }

        // Reset retryCount when RR advances V(A) (peer acknowledged new frames).
        // This prevents retry counts from earlier T1 timeouts accumulating across
        // unrelated I-frame exchanges, which caused premature "retries exceeded"
        // link failures in the KB5YZB-7 scenario.
        let vaBeforeAck = sequenceState.va
        sequenceState.ackUpTo(nr: nr)
        if sequenceState.va != vaBeforeAck {
            retryCount = 0
        }

        if sequenceState.outstandingCount == 0 {
            actions.append(.startT3)
            // All frames of ours are acked — but leave T1 alone if a REJ is
            // outstanding, because there T1 is timing the retransmission we
            // asked the peer for, not anything we sent.
            //
            // Stopping it unconditionally disarmed REJ recovery on every
            // inbound RR. During a download `outstandingCount` is always 0, so
            // the peer's own keepalive polls (W0ARP-10 polls every ~15 s, well
            // inside an 18.7 s RTO) cancelled T1 before it could ever fire: one
            // lost REJ stranded the gap permanently and the gateway eventually
            // disconnected (field capture 2026-08-24). Emitting neither
            // start nor stop leaves the running timer undisturbed — restarting
            // it would push the deadline out on every poll, which is the same
            // stall by another route.
            if !rejSent {
                actions.append(.stopT1)
            }
        } else if sequenceState.va != vaBeforeAck {
            // Progress made but frames still outstanding: restart T1 per §6.4.6
            actions.append(.startT1)
        }

        return actions
    }
}
