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

    /// Maximum receive buffer size for out-of-sequence frames. When nil, equals windowSize.
    /// Can be set smaller than windowSize to force discard-oldest behavior under load (e.g. testing).
    let maxReceiveBufferSize: Int?

    /// Maximum retries N2
    let maxRetries: Int

    /// Use extended mode (modulo 128 vs modulo 8)
    let extended: Bool

    /// Minimum RTO (seconds). When nil, session timers use default 1.0.
    let rtoMin: Double?

    /// Maximum RTO (seconds). When nil, session timers use default 30.0.
    let rtoMax: Double?

    /// Initial RTO (seconds) before any RTT sample. When nil, session timers use default 4.0.
    let initialRto: Double?

    /// Whether adaptive timeout estimation is enabled
    let adaptiveTimeout: Bool

    /// Sequence number modulo (8 or 128)
    var modulo: Int { extended ? 128 : 8 }

    init(
        windowSize: Int = 4,
        paclen: Int = 128,
        maxReceiveBufferSize: Int? = nil,
        maxRetries: Int = 10,
        extended: Bool = false,
        rtoMin: Double? = nil,
        rtoMax: Double? = nil,
        initialRto: Double? = nil,
        adaptiveTimeout: Bool = true
    ) {
        // Clamp window size to valid range
        let maxWindow = extended ? 127 : 7
        let ws = max(1, min(windowSize, maxWindow))
        self.windowSize = ws
        self.paclen = max(32, min(paclen, 256))
        self.maxReceiveBufferSize = maxReceiveBufferSize.map { max(1, min($0, ws)) }
        self.maxRetries = max(1, maxRetries)
        self.extended = extended
        self.rtoMin = rtoMin
        self.rtoMax = rtoMax
        self.initialRto = initialRto
        self.adaptiveTimeout = adaptiveTimeout
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
        assert(isValidNR(nr: nr), "Attempted to ackUpTo invalid N(R): \(nr)")
        va = nr % modulo
    }

    /// Check if we can send another frame (window not full)
    func canSend(windowSize: Int) -> Bool {
        assert(windowSize > 0 && windowSize < modulo, "Window size must be > 0 and < modulo")
        return outstandingCount < windowSize
    }
    
    /// Asserts core invariants
    func assertInvariants(windowSize: Int) {
        assert(vs >= 0 && vs < modulo, "V(S) out of bounds: \(vs)")
        assert(vr >= 0 && vr < modulo, "V(R) out of bounds: \(vr)")
        assert(va >= 0 && va < modulo, "V(A) out of bounds: \(va)")
        assert(outstandingCount >= 0 && outstandingCount <= windowSize, "outstandingCount \(outstandingCount) exceeds windowSize \(windowSize)")
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

    init(rtoMin: Double = 3.0, rtoMax: Double = 30.0, initialRto: Double = AX25SessionTimers.defaultInitialRto, adaptiveTimeout: Bool = true) {
        self.rtoMin = max(0.5, rtoMin)
        self.rtoMax = max(self.rtoMin, min(60.0, rtoMax))
        self.initialRto = max(self.rtoMin, min(self.rtoMax, initialRto))
        self.rto = self.initialRto
        self.adaptiveTimeout = adaptiveTimeout
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

    mutating func reset() {
        framesSent = 0
        framesReceived = 0
        retransmissions = 0
        bytesSent = 0
        bytesReceived = 0
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
    case receivedIFrame(ns: Int, nr: Int, pf: Bool, payload: Data)

    // Timeouts
    case t1Timeout
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
    case sendIFrame(ns: Int, nr: Int, payload: Data)
    case startT1
    case stopT1
    case startT3
    case stopT3
    case deliverData(Data)
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
}

/// AX.25 connected-mode state machine
/// Handles state transitions and generates actions in response to events
nonisolated struct AX25StateMachine: Sendable {
    /// Current session state
    private(set) var state: AX25SessionState = .disconnected

    /// Session configuration (fixed at connection start; never changed mid-session to avoid corrupting in-flight data).
    let config: AX25SessionConfig

    /// Sequence number state
    var sequenceState: AX25SequenceState

    /// Retry counter for current operation
    private(set) var retryCount: Int = 0

    /// Receive buffer for out-of-sequence I-frames
    /// Key is N(S) sequence number
    var receiveBuffer: [Int: BufferedIFrame] = [:]

    /// Flag indicating we've sent REJ and are waiting for retransmission
    /// This prevents sending multiple REJs for the same gap
    private(set) var rejSent: Bool = false

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

        // Log state transitions and key actions in DEBUG builds; this is intentionally
        // verbose trace data to help diagnose retry / timeout behavior.
#if DEBUG
        if oldState != state {
            TxLog.debug(.session, "AX25 state transition", [
                "from": oldState.rawValue,
                "to": state.rawValue,
                "event": String(describing: event).prefix(80)
            ])
        }

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

        case (.disconnected, .receivedIFrame(_, _, let pf, _)):
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

        case (.connected, .receivedIFrame(let ns, let nr, let pf, let payload)):
            TxLog.inbound(.ax25, "I-frame received", ["ns": ns, "nr": nr, "pf": pf, "size": payload.count])
            return handleIFrame(ns: ns, nr: nr, pf: pf, payload: payload)

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
            peerBusy = false
            let vaBeforeREJ = sequenceState.va
            if sequenceState.isValidNR(nr: nr) {
                sequenceState.ackUpTo(nr: nr)
            }
            if sequenceState.va != vaBeforeREJ {
                // Ack progress means the link is alive; reset retries for the same
                // reason handleRR does. Without this, an REJ-heavy exchange kept the
                // retry count from earlier T1 timeouts and failed the link early.
                retryCount = 0
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
                actions.append(.startT1)
            } else {
                // The REJ acknowledged everything we sent, so there is nothing to
                // retransmit (the peer's reject condition was raised by a duplicate,
                // e.g. a T1 retransmission that crossed its ack in flight). Running
                // T1 here creates an infinite enquiry loop: T1 fires with nothing
                // outstanding, we poll RR(P=1), the peer answers REJ(F=1) because
                // its reject condition only clears on the next NEW I-frame, and we
                // start T1 again — forever. Mirror handleRR: stop T1, start T3.
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
            return [.stopT3, .notifyError("Protocol error (FRMR received)")]

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
            if retryCount >= flushThreshold && !receiveBuffer.isEmpty {
                // Find the lowest buffered sequence number (closest gap to fill)
                if let lowestBuffered = receiveBuffer.keys.min(by: { distanceFromVR($0) < distanceFromVR($1) }) {
                    let skippedCount = (lowestBuffered - sequenceState.vr + config.modulo) % config.modulo
                    TxLog.warning(.session, "Flushing receive buffer: skipping lost frame(s)", [
                        "currentVR": sequenceState.vr,
                        "jumpingTo": lowestBuffered,
                        "skippedFrames": skippedCount,
                        "bufferedCount": receiveBuffer.count
                    ])

                    // Advance V(R) to the lowest buffered frame
                    sequenceState.vr = lowestBuffered

                    // Deliver consecutive buffered frames starting from the new V(R)
                    while let buffered = receiveBuffer.removeValue(forKey: sequenceState.vr) {
                        sequenceState.incrementVR()
                        actions.append(.deliverData(buffered.payload))
                    }

                    rejSent = false
                    retryCount = 0  // Reset retries since we made progress
                }
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

        case (.disconnecting, .receivedIFrame(_, _, let pf, _)):
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

    private mutating func handleIFrame(ns: Int, nr: Int, pf: Bool, payload: Data) -> [AX25SessionAction] {
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
            actions.append(contentsOf: deliverInSequenceFrame(ns: ns, nr: nr, pf: pf, payload: payload))
        } else if isWithinReceiveWindow(ns: ns) {
            // Out of sequence but within window - buffer for later delivery

            bufferOutOfSequenceFrame(ns: ns, nr: nr, payload: payload)

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
                actions.append(.sendREJ(nr: sequenceState.vr, pf: pf))
                actions.append(.startT1)
                rejSent = true
            } else {
                // Still need to respond if P=1, even if REJ already sent
                if pf {
                    actions.append(.sendRR(nr: sequenceState.vr, pf: true))
                }
            }
        } else {
            // Outside window - this is likely a duplicate of an already-received frame

            // Always send RR to re-ack current V(R). This helps peers recover when
            // our previous RR was lost and they retransmit a duplicate.
            actions.append(.sendRR(nr: sequenceState.vr, pf: pf))
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
    private mutating func deliverInSequenceFrame(ns: Int, nr: Int, pf: Bool, payload: Data) -> [AX25SessionAction] {
        var actions: [AX25SessionAction] = []

        // Clear REJ flag since we're receiving the expected frame
        rejSent = false

        // Deliver the current frame
        sequenceState.incrementVR()

        actions.append(.deliverData(payload))

        // Check for consecutive buffered frames and deliver them
        while let buffered = receiveBuffer.removeValue(forKey: sequenceState.vr) {
            sequenceState.incrementVR()

            actions.append(.deliverData(buffered.payload))
        }

        // Send RR acknowledging all delivered frames
        // If incoming frame had P=1, respond with F=1
        actions.append(.sendRR(nr: sequenceState.vr, pf: pf))
        actions.append(.startT3)

        if sequenceState.outstandingCount == 0 {
            actions.append(.stopT1)
        }

        return actions
    }

    /// Buffer an out-of-sequence frame for later delivery
    private mutating func bufferOutOfSequenceFrame(ns: Int, nr: Int, payload: Data) {
        // Don't buffer duplicates
        guard receiveBuffer[ns] == nil else {

            return
        }

        let bufferLimit = config.maxReceiveBufferSize ?? config.windowSize
        if receiveBuffer.count >= bufferLimit {

            // Remove the frame with the LARGEST distance from V(R), i.e. the one we will need last.
            // (Removing the smallest distance would drop the next frame we need—e.g. N(S)=4 when V(R)=0—
            // causing consistent loss of the same chunk index in file transfers.)
            if let farthestKey = receiveBuffer.keys.max(by: { distanceFromVR($0) < distanceFromVR($1) }) {
                receiveBuffer.removeValue(forKey: farthestKey)
            }
        }

        receiveBuffer[ns] = BufferedIFrame(ns: ns, nr: nr, payload: payload)

    }

    /// Check if a sequence number is within the receive window
    /// A frame is within the window if it's between V(R) and V(R) + window size (modulo)
    private func isWithinReceiveWindow(ns: Int) -> Bool {
        let modulo = config.modulo
        let vr = sequenceState.vr

        // Calculate distance from V(R) in forward direction
        let distance = (ns - vr + modulo) % modulo

        // Frame is within window if distance is less than window size
        // Distance of 0 means it's the expected frame (handled separately)
        // Distance > 0 but < windowSize means it's ahead but within window
        return distance > 0 && distance <= config.windowSize
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
            // All frames acked
            actions.append(.stopT1)
            actions.append(.startT3)
        } else if sequenceState.va != vaBeforeAck {
            // Progress made but frames still outstanding: restart T1 per §6.4.6
            actions.append(.startT1)
        }

        return actions
    }
}
