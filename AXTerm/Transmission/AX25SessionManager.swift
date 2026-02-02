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
struct SessionKey: Hashable, Sendable {
    let destination: String      // "N0CALL-5"
    let pathSignature: String    // "WIDE1-1,WIDE2-1" or "" for direct
    let channel: UInt8

    init(destination: AX25Address, path: DigiPath, channel: UInt8 = 0) {
        self.destination = destination.display
        self.pathSignature = path.display
        self.channel = channel
    }
}

// MARK: - Session

/// Represents an AX.25 connected-mode session
final class AX25Session: @unchecked Sendable {
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

    /// Timestamp when SABM was sent (for RTT calculation)
    var sabmSentAt: Date?

    /// Timestamp when session was established
    var connectedAt: Date?

    /// Timestamp of last activity
    var lastActivityAt: Date

    /// Whether we initiated this session (vs responding to incoming SABM)
    let isInitiator: Bool

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
        self.timers = AX25SessionTimers()
        self.statistics = AX25SessionStatistics()
        self.lastActivityAt = Date()
        self.isInitiator = isInitiator
    }

    /// Current session state
    var state: AX25SessionState {
        stateMachine.state
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

    /// Number of outstanding (unacked) frames
    var outstandingCount: Int {
        stateMachine.sequenceState.outstandingCount
    }

    /// Whether we can send another I-frame (window not full)
    var canSendIFrame: Bool {
        stateMachine.sequenceState.canSend(windowSize: stateMachine.config.windowSize)
    }

    /// Add frame to send buffer for retransmission
    func bufferFrame(_ frame: OutboundFrame, ns: Int) {
        sendBuffer[ns] = frame
    }

    /// Remove acknowledged frames from buffer
    func acknowledgeUpTo(nr: Int) {
        let modulo = stateMachine.config.modulo
        // Remove all frames with sequence numbers < nr (accounting for wraparound)
        sendBuffer = sendBuffer.filter { (ns, _) in
            // Check if ns is still unacked (ns >= va in modular arithmetic)
            // nr is the next expected, so ack everything < nr
            let diff = (nr - ns + modulo) % modulo
            return diff > modulo / 2 || diff == 0  // ns >= nr in modular space
        }
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

        // Sort by sequence number
        return frames.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Update last activity timestamp
    func touch() {
        lastActivityAt = Date()
    }
}

// MARK: - Session Manager

/// Manages all AX.25 connected-mode sessions
@MainActor
final class AX25SessionManager: ObservableObject {

    /// All active sessions keyed by SessionKey
    @Published private(set) var sessions: [SessionKey: AX25Session] = [:]

    /// Default session configuration
    var defaultConfig: AX25SessionConfig = AX25SessionConfig()

    /// Local callsign (from settings)
    var localCallsign: AX25Address = AX25Address(call: "NOCALL", ssid: 0)

    /// Callback when frames need to be sent
    var onSendFrame: ((OutboundFrame) -> Void)?

    /// Callback when data is received from a connected session
    var onDataReceived: ((AX25Session, Data) -> Void)?

    /// Callback when session state changes
    var onSessionStateChanged: ((AX25Session, AX25SessionState, AX25SessionState) -> Void)?

    // MARK: - Session Lifecycle

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

        let session = AX25Session(
            localAddress: localCallsign,
            remoteAddress: destination,
            path: path,
            channel: channel,
            config: defaultConfig,
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

    /// Remove a session
    func removeSession(_ session: AX25Session) {
        sessions.removeValue(forKey: session.key)

        TxLog.debug(.session, "Session removed", [
            "session": String(session.id.uuidString.prefix(8)),
            "peer": session.remoteAddress.display
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

    // MARK: - Connection Management

    /// Initiate a connection to a remote station
    /// Returns the SABM frame to send
    func connect(
        to destination: AX25Address,
        path: DigiPath = DigiPath(),
        channel: UInt8 = 0
    ) -> OutboundFrame? {
        let session = session(for: destination, path: path, channel: channel)

        guard session.state == .disconnected || session.state == .error else {
            TxLog.warning(.session, "Cannot connect: session not disconnected", [
                "state": session.state.rawValue
            ])
            return nil
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .connectRequest)

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        session.sabmSentAt = Date()
        session.touch()

        return processActions(actions, for: session).first
    }

    /// Disconnect from a connected session
    /// Returns the DISC frame to send
    func disconnect(session: AX25Session) -> OutboundFrame? {
        guard session.state == .connected else {
            TxLog.warning(.session, "Cannot disconnect: session not connected", [
                "state": session.state.rawValue
            ])
            return nil
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .disconnectRequest)

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        session.touch()
        return processActions(actions, for: session).first
    }

    // MARK: - Data Transmission

    /// Send data over a connected session
    /// Handles connection establishment if not yet connected
    /// Returns frames to send (may include SABM if not connected)
    func sendData(
        _ data: Data,
        to destination: AX25Address,
        path: DigiPath = DigiPath(),
        channel: UInt8 = 0,
        pid: UInt8 = 0xF0,
        displayInfo: String? = nil
    ) -> [OutboundFrame] {
        let session = session(for: destination, path: path, channel: channel)
        var frames: [OutboundFrame] = []

        switch session.state {
        case .disconnected, .error:
            // Need to connect first
            if let sabm = connect(to: destination, path: path, channel: channel) {
                frames.append(sabm)
            }
            // Queue the data for when connection is established
            // For now, we'll buffer it in the session
            // TODO: Implement pending data queue
            TxLog.debug(.session, "Queued data pending connection", [
                "peer": destination.display,
                "size": data.count
            ])

        case .connecting:
            // Already connecting, queue the data
            TxLog.debug(.session, "Queued data, connection in progress", [
                "peer": destination.display,
                "size": data.count
            ])

        case .connected:
            // Can send immediately if window allows
            if session.canSendIFrame {
                let iFrame = buildIFrame(for: session, payload: data, pid: pid, displayInfo: displayInfo)
                frames.append(iFrame)

                // Buffer for potential retransmission
                session.bufferFrame(iFrame, ns: session.vs - 1)  // vs was incremented
                session.statistics.recordSent(bytes: data.count)
                session.touch()
            } else {
                TxLog.warning(.session, "Window full, cannot send", [
                    "outstanding": session.outstandingCount,
                    "windowSize": session.stateMachine.config.windowSize
                ])
            }

        case .disconnecting:
            TxLog.warning(.session, "Cannot send: session disconnecting")
        }

        return frames
    }

    // MARK: - Inbound Frame Handling

    /// Handle an inbound SABM (connection request)
    func handleInboundSABM(
        from source: AX25Address,
        to destination: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) -> OutboundFrame? {
        // Create session if it doesn't exist (we're the responder)
        let key = SessionKey(destination: source, path: path, channel: channel)

        let session: AX25Session
        if let existing = sessions[key] {
            session = existing
        } else {
            session = AX25Session(
                localAddress: destination,  // We're the destination of the SABM
                remoteAddress: source,
                path: path,
                channel: channel,
                config: defaultConfig,
                isInitiator: false
            )
            sessions[key] = session
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedSABM)

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        if session.state == .connected {
            session.connectedAt = Date()
        }

        session.touch()
        return processActions(actions, for: session).first
    }

    /// Handle an inbound UA (unnumbered acknowledge)
    func handleInboundUA(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) {
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

        guard let session = session else {
            TxLog.warning(.session, "UA received for unknown session", ["from": source.display])
            return
        }

        let oldState = session.state

        // Calculate RTT if we were connecting
        if session.state == .connecting, let sabmSent = session.sabmSentAt {
            let rtt = Date().timeIntervalSince(sabmSent)
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
            onSessionStateChanged?(session, oldState, session.state)
        }

        if session.state == .connected {
            session.connectedAt = Date()
            TxLog.sessionOpen(
                sessionId: session.id,
                peer: source.display,
                mode: "connected"
            )
        } else if session.state == .disconnected {
            TxLog.sessionClose(
                sessionId: session.id,
                peer: source.display,
                reason: "Normal disconnect"
            )
        }

        session.touch()
        _ = processActions(actions, for: session)
    }

    /// Handle an inbound DM (disconnected mode)
    func handleInboundDM(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8
    ) {
        // Try to find session with exact path match first
        var session = existingSession(for: source, path: path, channel: channel)

        // If not found, try to find any session to this remote address that's expecting a response
        if session == nil {
            session = findSessionExpectingUA(from: source, channel: channel)
        }

        guard let session = session else {
            TxLog.debug(.session, "DM received for unknown session", ["from": source.display])
            return
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedDM)

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
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
        guard let session = existingSession(for: source, path: path, channel: channel) else {
            // No session - respond with DM
            return AX25FrameBuilder.buildDM(
                from: localCallsign,
                to: source,
                via: path
            )
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedDISC)

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        TxLog.sessionClose(
            sessionId: session.id,
            peer: source.display,
            reason: "Remote DISC"
        )

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
        payload: Data
    ) -> OutboundFrame? {
        // Try exact path match first, then fall back to address-only lookup
        var session = existingSession(for: source, path: path, channel: channel)
        if session == nil {
            session = findConnectedSession(from: source, channel: channel)
        }

        guard let session = session else {
            // No session - respond with DM
            return AX25FrameBuilder.buildDM(
                from: localCallsign,
                to: source,
                via: path
            )
        }

        guard session.state == .connected else {
            TxLog.warning(.session, "I-frame received but not connected", [
                "state": session.state.rawValue
            ])
            return nil
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedIFrame(ns: ns, nr: nr, pf: pf, payload: payload))

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        // Acknowledge received frames in our send buffer
        session.acknowledgeUpTo(nr: nr)
        session.statistics.recordReceived(bytes: payload.count)
        session.touch()

        return processActions(actions, for: session).first
    }

    /// Handle an inbound RR (receive ready)
    /// - Parameters:
    ///   - source: Remote station address
    ///   - path: Digipeater path
    ///   - channel: KISS channel
    ///   - nr: N(R) from the frame
    ///   - isPoll: Whether this is a poll (P=1) requiring a response
    /// - Returns: Response frame (RR with F=1) if this was a poll, nil otherwise
    func handleInboundRR(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        nr: Int,
        isPoll: Bool = false
    ) -> OutboundFrame? {
        // Try exact path match first, then fall back to address-only lookup
        var session = existingSession(for: source, path: path, channel: channel)
        if session == nil {
            session = findConnectedSession(from: source, channel: channel)
        }

        guard let session = session else {
            return nil
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedRR(nr: nr))

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        // Acknowledge received frames
        session.acknowledgeUpTo(nr: nr)
        session.touch()

        _ = processActions(actions, for: session)

        // If this was a poll (P=1), respond with RR F=1
        if isPoll && session.state == .connected {
            let currentVR = session.vr
            print("[AX25SessionManager] Responding to RR poll from \(source.display) with N(R)=\(currentVR)")
            TxLog.debug(.session, "Responding to RR poll", [
                "from": source.display,
                "nr": currentVR
            ])
            return AX25FrameBuilder.buildRR(
                from: session.localAddress,
                to: session.remoteAddress,
                via: session.path,
                nr: currentVR,
                pf: true
            )
        }

        return nil
    }

    /// Handle an inbound REJ (reject - request retransmit)
    func handleInboundREJ(
        from source: AX25Address,
        path: DigiPath,
        channel: UInt8,
        nr: Int
    ) -> [OutboundFrame] {
        guard let session = existingSession(for: source, path: path, channel: channel) else {
            return []
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedREJ(nr: nr))

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        // Get frames to retransmit
        let retransmitFrames = session.framesToRetransmit(from: nr)
        for frame in retransmitFrames {
            session.statistics.recordRetransmit()
        }

        session.touch()

        // Process actions first, then return retransmit frames
        var frames = processActions(actions, for: session)
        frames.append(contentsOf: retransmitFrames)
        return frames
    }

    // MARK: - Timer Handling

    /// Handle T1 (retransmit) timeout for a session
    func handleT1Timeout(session: AX25Session) -> [OutboundFrame] {
        let oldState = session.state
        let actions = session.stateMachine.handle(event: .t1Timeout)

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        session.timers.backoff()  // Exponential backoff
        session.touch()

        return processActions(actions, for: session)
    }

    /// Handle T3 (idle) timeout for a session
    func handleT3Timeout(session: AX25Session) -> [OutboundFrame] {
        let oldState = session.state
        let actions = session.stateMachine.handle(event: .t3Timeout)

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
        }

        return processActions(actions, for: session)
    }

    // MARK: - Private Helpers

    /// Build an I-frame for the session with current sequence numbers
    private func buildIFrame(
        for session: AX25Session,
        payload: Data,
        pid: UInt8,
        displayInfo: String?
    ) -> OutboundFrame {
        let ns = session.vs
        let nr = session.vr

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
            sessionId: session.id,
            displayInfo: displayInfo
        )
    }

    /// Process actions from the state machine and return frames to send
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
                frames.append(frame)
                onSendFrame?(frame)

            case .sendUA:
                let frame = AX25FrameBuilder.buildUA(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                frames.append(frame)
                onSendFrame?(frame)

            case .sendDM:
                let frame = AX25FrameBuilder.buildDM(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                frames.append(frame)
                onSendFrame?(frame)

            case .sendDISC:
                let frame = AX25FrameBuilder.buildDISC(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                frames.append(frame)
                onSendFrame?(frame)

            case .sendRR(let nr, let pf):
                let frame = AX25FrameBuilder.buildRR(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    nr: nr,
                    pf: pf
                )
                frames.append(frame)
                onSendFrame?(frame)

            case .sendRNR(let nr, let pf):
                let frame = AX25FrameBuilder.buildRNR(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    nr: nr,
                    pf: pf
                )
                frames.append(frame)
                onSendFrame?(frame)

            case .sendREJ(let nr, let pf):
                let frame = AX25FrameBuilder.buildREJ(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path,
                    nr: nr,
                    pf: pf
                )
                frames.append(frame)
                onSendFrame?(frame)

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
                frames.append(frame)
                onSendFrame?(frame)

            case .deliverData(let data):
                onDataReceived?(session, data)

            case .notifyConnected:
                TxLog.sessionOpen(
                    sessionId: session.id,
                    peer: session.remoteAddress.display,
                    mode: "connected"
                )

            case .notifyDisconnected:
                TxLog.sessionClose(
                    sessionId: session.id,
                    peer: session.remoteAddress.display,
                    reason: "Disconnected"
                )

            case .notifyError(let message):
                TxLog.error(.session, message, error: nil, [
                    "session": String(session.id.uuidString.prefix(8)),
                    "peer": session.remoteAddress.display
                ])

            case .startT1, .stopT1, .startT3, .stopT3:
                // Timer management would be handled by a timer service
                // For now, just log
                TxLog.debug(.session, "Timer action: \(action)")
            }
        }

        return frames
    }
}
