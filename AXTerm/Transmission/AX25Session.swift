//
//  AX25Session.swift
//  AXTerm
//
//  AX.25 connected-mode session state machine.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 7
//

import Foundation

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

    /// Maximum retries N2
    let maxRetries: Int

    /// Use extended mode (modulo 128 vs modulo 8)
    let extended: Bool

    /// Sequence number modulo (8 or 128)
    var modulo: Int { extended ? 128 : 8 }

    init(windowSize: Int = 2, maxRetries: Int = 10, extended: Bool = false) {
        // Clamp window size to valid range
        let maxWindow = extended ? 127 : 7
        self.windowSize = max(1, min(windowSize, maxWindow))
        self.maxRetries = max(1, maxRetries)
        self.extended = extended
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
    private(set) var rto: Double = 3.0

    /// T3 idle timeout (seconds)
    let t3Timeout: Double = 180.0

    /// Smoothing factor for SRTT (1/8 per RFC 6298)
    private let alpha: Double = 1.0 / 8.0

    /// Smoothing factor for RTTVAR (1/4 per RFC 6298)
    private let beta: Double = 1.0 / 4.0

    /// Minimum RTO (seconds)
    private let rtoMin: Double = 1.0

    /// Maximum RTO (seconds)
    private let rtoMax: Double = 30.0

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

    /// Reset timers
    mutating func reset() {
        srtt = nil
        rttvar = 0.0
        rto = 3.0
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
    case sendData(Data)

    // Received U-frames
    case receivedUA
    case receivedDM
    case receivedSABM
    case receivedDISC
    case receivedFRMR

    // Received S-frames
    case receivedRR(nr: Int)
    case receivedRNR(nr: Int)
    case receivedREJ(nr: Int)

    // Received I-frame
    case receivedIFrame(ns: Int, nr: Int, payload: Data)

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
    case sendRR(nr: Int)
    case sendRNR(nr: Int)
    case sendREJ(nr: Int)
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

/// AX.25 connected-mode state machine
/// Handles state transitions and generates actions in response to events
struct AX25StateMachine: Sendable {
    /// Current session state
    private(set) var state: AX25SessionState = .disconnected

    /// Session configuration
    let config: AX25SessionConfig

    /// Sequence number state
    var sequenceState: AX25SequenceState

    /// Retry counter for current operation
    private(set) var retryCount: Int = 0

    init(config: AX25SessionConfig) {
        self.config = config
        self.sequenceState = AX25SequenceState(modulo: config.modulo)
    }

    /// Handle an event and return the list of actions to execute
    mutating func handle(event: AX25SessionEvent) -> [AX25SessionAction] {
        switch (state, event) {

        // MARK: - Disconnected State

        case (.disconnected, .connectRequest):
            state = .connecting
            retryCount = 0
            sequenceState.reset()
            return [.sendSABM, .startT1]

        case (.disconnected, .receivedSABM):
            // Remote initiated connection
            state = .connected
            sequenceState.reset()
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
            return [.stopT1, .startT3, .notifyConnected]

        case (.connecting, .receivedDM):
            state = .disconnected
            return [.stopT1, .notifyError("Connection refused (DM received)")]

        case (.connecting, .t1Timeout):
            retryCount += 1
            if retryCount > config.maxRetries {
                state = .error
                return [.stopT1, .notifyError("Connection timeout (retries exceeded)")]
            }
            return [.sendSABM, .startT1]

        case (.connecting, .disconnectRequest):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

        case (.connecting, _):
            return []

        // MARK: - Connected State

        case (.connected, .disconnectRequest):
            state = .disconnecting
            retryCount = 0
            return [.sendDISC, .stopT3, .startT1]

        case (.connected, .receivedDISC):
            state = .disconnected
            return [.sendUA, .stopT3, .notifyDisconnected]

        case (.connected, .receivedSABM):
            // Remote is re-establishing - reset and ack
            sequenceState.reset()
            return [.sendUA, .startT3]

        case (.connected, .receivedIFrame(let ns, let nr, let payload)):
            return handleIFrame(ns: ns, nr: nr, payload: payload)

        case (.connected, .receivedRR(let nr)):
            return handleRR(nr: nr)

        case (.connected, .receivedRNR(let nr)):
            // Remote is busy - ack frames but don't send more
            sequenceState.ackUpTo(nr: nr)
            return [.stopT1]

        case (.connected, .receivedREJ(let nr)):
            // Remote requests retransmit from nr
            sequenceState.ackUpTo(nr: nr)
            // Note: actual retransmit logic would be handled by session manager
            return [.startT1]

        case (.connected, .receivedFRMR):
            state = .error
            return [.stopT3, .notifyError("Protocol error (FRMR received)")]

        case (.connected, .receivedDM):
            state = .disconnected
            return [.stopT3, .notifyError("Remote disconnected (DM received)")]

        case (.connected, .t1Timeout):
            retryCount += 1
            if retryCount > config.maxRetries {
                state = .error
                return [.stopT1, .stopT3, .notifyError("Link failure (retries exceeded)")]
            }
            // Retransmit would happen here
            return [.startT1]

        case (.connected, .t3Timeout):
            // Send RR as poll to check link
            return [.sendRR(nr: sequenceState.vr), .startT1]

        case (.connected, _):
            return []

        // MARK: - Disconnecting State

        case (.disconnecting, .receivedUA):
            state = .disconnected
            return [.stopT1, .notifyDisconnected]

        case (.disconnecting, .receivedDM):
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
            sequenceState.reset()
            return [.sendSABM, .startT1]

        case (.error, _):
            return []
        }
    }

    // MARK: - I-Frame Handling

    private mutating func handleIFrame(ns: Int, nr: Int, payload: Data) -> [AX25SessionAction] {
        var actions: [AX25SessionAction] = []

        // Process N(R) - acknowledge our sent frames
        if sequenceState.outstandingCount > 0 {
            sequenceState.ackUpTo(nr: nr)
        }

        // Check if this is the expected sequence number
        if ns == sequenceState.vr {
            // In sequence - accept and advance
            sequenceState.incrementVR()
            actions.append(.deliverData(payload))
            actions.append(.sendRR(nr: sequenceState.vr))
            actions.append(.startT3)

            if sequenceState.outstandingCount == 0 {
                actions.append(.stopT1)
            }
        } else {
            // Out of sequence - request retransmit
            actions.append(.sendREJ(nr: sequenceState.vr))
        }

        return actions
    }

    // MARK: - RR Handling

    private mutating func handleRR(nr: Int) -> [AX25SessionAction] {
        var actions: [AX25SessionAction] = []

        sequenceState.ackUpTo(nr: nr)

        if sequenceState.outstandingCount == 0 {
            // All frames acked
            actions.append(.stopT1)
            actions.append(.startT3)
        }

        return actions
    }
}
