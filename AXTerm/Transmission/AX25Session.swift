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
enum AX25Constants {
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
enum AX25SessionState: String, Equatable, Sendable {
    case disconnected
    case connecting      // Sent SABM, waiting UA
    case connected
    case disconnecting   // Sent DISC, waiting UA
    case error
}

// MARK: - Session Configuration

/// Configuration for AX.25 session parameters
struct AX25SessionConfig: Sendable {
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
        initialRto: Double? = nil
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
    }
}

// MARK: - Sequence Numbers

/// AX.25 sequence number state (V(S), V(R), V(A))
struct AX25SequenceState: Sendable {
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

    /// Acknowledge frames up to (but not including) nr
    mutating func ackUpTo(nr: Int) {
        va = nr % modulo
    }

    /// Check if we can send another frame (window not full)
    func canSend(windowSize: Int) -> Bool {
        outstandingCount < windowSize
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
struct AX25SessionTimers: Sendable {
    /// Smoothed RTT estimate
    var srtt: Double? = nil

    /// RTT variance
    var rttvar: Double = 0.0

    /// Current RTO (retransmission timeout)
    private(set) var rto: Double

    /// T3 idle timeout (seconds)
    let t3Timeout: Double = 180.0

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

    init(rtoMin: Double = 3.0, rtoMax: Double = 30.0, initialRto: Double = 4.0) {
        self.rtoMin = max(0.5, rtoMin)
        self.rtoMax = max(self.rtoMin, min(60.0, rtoMax))
        self.rto = max(self.rtoMin, min(self.rtoMax, initialRto))
    }

    /// Update RTT estimates with a new sample
    mutating func updateRTT(sample: Double) {
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
        rto = min(rto * 2, rtoMax)
    }

    /// Reset timers to initial RTO (same bounds)
    mutating func reset() {
        srtt = nil
        rttvar = 0.0
        rto = max(rtoMin, min(rtoMax, Self.defaultInitialRto))
    }
}

// MARK: - Session Statistics

/// Statistics for an AX.25 session
struct AX25SessionStatistics: Sendable {
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
enum AX25SessionEvent: Sendable {
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
    case receivedRR(nr: Int, pf: Bool)
    case receivedRNR(nr: Int, pf: Bool)
    case receivedREJ(nr: Int, pf: Bool)

    // Received I-frame
    case receivedIFrame(ns: Int, nr: Int, pf: Bool, payload: Data)

    // Timeouts
    case t1Timeout
    case t3Timeout
}

// MARK: - Session Actions

/// Actions to take in response to events
enum AX25SessionAction: Sendable, Equatable {
    case sendSABM
    case sendUA
    case sendDM
    case sendDISC
    case sendRR(nr: Int, pf: Bool = false)
    case sendRNR(nr: Int, pf: Bool = false)
    case sendREJ(nr: Int, pf: Bool = false)
    case sendIFrame(ns: Int, nr: Int, payload: Data)
    case startT1
    case stopT1
    case startT3
    case stopT3
    case deliverData(Data)
    case notifyConnected
    case notifyDisconnected
    case notifyError(String)
}

// MARK: - State Machine

/// Buffered I-frame waiting for delivery
struct BufferedIFrame: Sendable {
    let ns: Int
    let nr: Int
    let payload: Data
}

/// AX.25 connected-mode state machine
/// Handles state transitions and generates actions in response to events
struct AX25StateMachine: Sendable {
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

    init(config: AX25SessionConfig) {
        self.config = config
        self.sequenceState = AX25SequenceState(modulo: config.modulo)
    }

    /// Reset all session state for a new connection
    mutating func resetSessionState() {
        sequenceState.reset()
        receiveBuffer.removeAll()
        rejSent = false
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
            // Respond with DM (not connected)
            return [.sendDM]

        case (.disconnected, _):
            // Ignore other events in disconnected state
            return []

        // MARK: - Connecting State

        case (.connecting, .receivedUA):
            state = .connected
            retryCount = 0
            TxLog.inbound(.ax25, "Connection established (UA received)")
            return [.stopT1, .startT3, .notifyConnected]

        case (.connecting, .receivedDM):
            state = .disconnected
            TxLog.error(.ax25, "Connection refused", error: nil, ["reason": "DM received"])
            return [.stopT1, .notifyError("Connection refused (DM received)")]

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
            return [.sendUA, .stopT3, .notifyDisconnected]

        case (.connected, .receivedSABM):
            // Remote is re-establishing - reset and ack
            resetSessionState()
            return [.sendUA, .startT3]

        case (.connected, .receivedIFrame(let ns, let nr, let pf, let payload)):
            TxLog.inbound(.ax25, "I-frame received", ["ns": ns, "nr": nr, "pf": pf, "size": payload.count])
            return handleIFrame(ns: ns, nr: nr, pf: pf, payload: payload)

        case (.connected, .receivedRR(let nr, let pf)):
            return handleRR(nr: nr, pf: pf)

        case (.connected, .receivedRNR(let nr, _)):
            // Remote is busy - ack frames but don't send more
            // TODO: Handle P/F bit if needed for RNR polls?
            sequenceState.ackUpTo(nr: nr)
            return [.stopT1]

        case (.connected, .receivedREJ(let nr, _)):
            // Remote requests retransmit from nr
            sequenceState.ackUpTo(nr: nr)
            // Note: actual retransmit logic would be handled by session manager
            return [.startT1]

        case (.connected, .receivedFRMR):
            state = .error
            TxLog.error(.ax25, "Protocol error", error: nil, ["reason": "FRMR received"])
            return [.stopT3, .notifyError("Protocol error (FRMR received)")]

        case (.connected, .receivedDM):
            state = .disconnected
            TxLog.warning(.ax25, "Remote disconnected (DM received)")
            return [.stopT3, .notifyError("Remote disconnected (DM received)")]

        case (.connected, .t1Timeout):
            retryCount += 1
            TxLog.warning(.ax25, "T1 timeout", [
                "retry": retryCount,
                "outstanding": sequenceState.outstandingCount,
                "windowSize": config.windowSize,
                "vs": sequenceState.vs,
                "va": sequenceState.va,
                "vr": sequenceState.vr
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
            // Per AX.25 spec: on T1 timeout with outstanding frames, send RR
            // with P=1 (poll) to force the peer to respond with its current
            // state. This recovers from lost responses - if the peer already
            // processed our I-frame but its RR was lost, the poll elicits a
            // fresh RR(F=1) instead of wasting airtime on duplicate I-frames.
            // The session manager also retransmits outstanding I-frames.
            var actions: [AX25SessionAction] = [.startT1]
            if sequenceState.outstandingCount > 0 {
                actions.append(.sendRR(nr: sequenceState.vr, pf: true))
            }
            return actions

        case (.connected, .t3Timeout):
            // Send RR as poll to check link
            // Fix: Send P=1 (Poll) so the peer is required to respond.
            // Previously sending P=0 meant the peer could ignore it, causing us to
            // fall through to T1 timeout and waste a retries cycle.
            return [.sendRR(nr: sequenceState.vr, pf: true), .startT1]

        case (.connected, _):
            return []

        // MARK: - Disconnecting State

        case (.disconnecting, .receivedUA):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

        case (.disconnecting, .receivedDM):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

        case (.disconnecting, .forceDisconnect):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

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
        let vr = sequenceState.vr
        let modulo = config.modulo
        let windowHigh = (vr + config.windowSize - 1) % modulo



        // Process N(R) - acknowledge our sent frames
        let vaBeforeIFrameAck = sequenceState.va
        if sequenceState.outstandingCount > 0 {
            sequenceState.ackUpTo(nr: nr)
        }
        
        // Fix: Reset retryCount if V(A) advances via piggybacked ACK.
        if sequenceState.va != vaBeforeIFrameAck {
            retryCount = 0
        }

        // Check if this is the expected sequence number
        if ns == sequenceState.vr {
            // In sequence - deliver this frame and any consecutive buffered frames
            // Pass the P/F bit so we can respond with F=1 if P=1
            actions.append(contentsOf: deliverInSequenceFrame(ns: ns, nr: nr, pf: pf, payload: payload))
        } else if isWithinReceiveWindow(ns: ns) {
            // Out of sequence but within window - buffer for later delivery
            bufferOutOfSequenceFrame(ns: ns, nr: nr, payload: payload)

            // Send REJ only once per gap (with F=1 if remote sent P=1)
            if !rejSent {

                actions.append(.sendREJ(nr: sequenceState.vr, pf: pf))
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
        let oldVR = sequenceState.vr
        sequenceState.incrementVR()

        actions.append(.deliverData(payload))

        // Check for consecutive buffered frames and deliver them
        while let buffered = receiveBuffer.removeValue(forKey: sequenceState.vr) {
            let bufferedOldVR = sequenceState.vr
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

    private mutating func handleRR(nr: Int, pf: Bool) -> [AX25SessionAction] {
        var actions: [AX25SessionAction] = []

        // Reset retryCount when RR advances V(A) (peer acknowledged new frames).
        // This prevents retry counts from earlier T1 timeouts accumulating across
        // unrelated I-frame exchanges, which caused premature "retries exceeded"
        // link failures in the KB5YZB-7 scenario.
        let vaBeforeAck = sequenceState.va
        sequenceState.ackUpTo(nr: nr)

        // Fix: Reset retryCount if V(A) advanced OR if this was a response to our poll (Final bit set).
        if sequenceState.va != vaBeforeAck || pf {
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
