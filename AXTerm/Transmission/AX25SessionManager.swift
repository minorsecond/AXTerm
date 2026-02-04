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

    /// Pending data queue: data waiting to be sent once connected
    /// Each entry is (data, pid, displayInfo)
    var pendingDataQueue: [(data: Data, pid: UInt8, displayInfo: String?)] = []

    /// T1 retransmit timer task
    var t1TimerTask: Task<Void, Never>?

    /// T3 idle timer task
    var t3TimerTask: Task<Void, Never>?

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

    deinit {
        // Ensure timers are cancelled to avoid background tasks outliving the session.
        t1TimerTask?.cancel()
        t3TimerTask?.cancel()
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
    var localCallsign: AX25Address = AX25Address(call: "NOCALL", ssid: 0)

    /// Callback when frames need to be sent
    var onSendFrame: ((OutboundFrame) -> Void)?

    /// Callback when data is received from a connected session
    var onDataReceived: ((AX25Session, Data) -> Void)?

    /// Callback when session state changes
    var onSessionStateChanged: ((AX25Session, AX25SessionState, AX25SessionState) -> Void)?

    /// Callback when frames need to be sent from timer retransmission
    var onRetransmitFrame: ((OutboundFrame) -> Void)?

    // MARK: - Deep Session Debug (Debug Builds Only)

    /// Emit a detailed snapshot of session state for debugging retries, timers, and window usage.
    /// This is intentionally verbose and only compiled into DEBUG builds.
    private func debugDumpSessionState(_ session: AX25Session, context: String) {
#if DEBUG
        let sm = session.stateMachine
        let timers = session.timers

        let vs = sm.sequenceState.vs
        let vr = sm.sequenceState.vr
        let va = sm.sequenceState.va
        let outstanding = sm.sequenceState.outstandingCount

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

    /// Find any connected session (useful for responder UIs that don't have destination set)
    /// Returns the most recently active connected session, or nil if none
    func anyConnectedSession() -> AX25Session? {
        return sessions.values
            .filter { $0.state == .connected }
            .max { $0.lastActivityAt < $1.lastActivityAt }
    }

    /// Find a connected session with a specific peer, regardless of who initiated
    func connectedSession(withPeer peer: AX25Address) -> AX25Session? {
        return sessions.values.first {
            $0.remoteAddress == peer && $0.state == .connected
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
            debugTrace("state change (connect)", [
                "peer": destination.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
        }

        session.sabmSentAt = Date()
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
        let session = selectSession(for: destination, path: path, channel: channel)
        var frames: [OutboundFrame] = []

        switch session.state {
        case .disconnected, .error:
            // Need to connect first
            if let sabm = connect(to: destination, path: path, channel: channel) {
                frames.append(sabm)
            }
            // Queue the data for when connection is established
            session.pendingDataQueue.append((data: data, pid: pid, displayInfo: displayInfo))
            TxLog.debug(.session, "Queued data pending connection", [
                "peer": destination.display,
                "size": data.count,
                "queueDepth": session.pendingDataQueue.count
            ])

        case .connecting:
            // Already connecting, queue the data
            session.pendingDataQueue.append((data: data, pid: pid, displayInfo: displayInfo))
            TxLog.debug(.session, "Queued data, connection in progress", [
                "peer": destination.display,
                "size": data.count,
                "queueDepth": session.pendingDataQueue.count
            ])

        case .connected:
            // Can send immediately if window allows
            if session.canSendIFrame {
                let wasIdle = session.outstandingCount == 0
                let iFrame = buildIFrame(for: session, payload: data, pid: pid, displayInfo: displayInfo)
                frames.append(iFrame)

                // Buffer for potential retransmission
                session.bufferFrame(iFrame, ns: session.vs - 1)  // vs was incremented
                session.statistics.recordSent(bytes: data.count)
                session.touch()

                if wasIdle {
                    startT1Timer(for: session)
                }
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

        // Create session if it doesn't exist (we're the responder)
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
        debugTrace("SABM state transition", [
            "peer": source.display,
            "from": oldState.rawValue,
            "to": session.state.rawValue,
            "actions": actions.map { String(describing: $0) }.joined(separator: ",")
        ])

        if oldState != session.state {
            onSessionStateChanged?(session, oldState, session.state)
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
                let elapsed = Date().timeIntervalSince(sabmSent)
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
            debugTrace("state change (UA)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
        }

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
        _ = processActions(actions, for: session)
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
            TxLog.debug(.session, "DM received for unknown session", ["from": source.display])
            return
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedDM)

        if oldState != session.state {
            debugTrace("state change (DM)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
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
        debugTrace("DISC received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "channel": channel
        ])
        guard let session = existingSession(for: source, path: path, channel: channel) else {
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

        if oldState != session.state {
            debugTrace("state change (DISC)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
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
        debugTrace("I-frame received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "ns": ns,
            "nr": nr,
            "pf": pf ? 1 : 0,
            "len": payload.count
        ])
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

            // Robust behavior per AX.25 guidance: if we receive an I-frame that we
            // can't associate with any session, we **ignore** it rather than sending
            // DM. Sending DM here can erroneously tear down a valid remote session,
            // especially when duplicate decodes or path mismatches occur via digipeaters.
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

        guard let session = session, session.state == .connected else {
            TxLog.warning(.session, "I-frame received but not connected", [
                "state": session?.state.rawValue ?? "unknown"
            ])
            return nil
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedIFrame(ns: ns, nr: nr, pf: pf, payload: payload))

        if oldState != session.state {
            debugTrace("state change (I-frame)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
        }

        // Acknowledge received frames in our send buffer
        session.acknowledgeUpTo(nr: nr)
        session.statistics.recordReceived(bytes: payload.count)
        session.touch()

        // Deep debug snapshot whenever we successfully process an inbound I-frame.
        debugDumpSessionState(session, context: "inbound-I")

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
        debugTrace("RR received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "nr": nr,
            "pf": isPoll ? 1 : 0
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
                "from": source.display
            ])
            return nil
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedRR(nr: nr))

        if oldState != session.state {
            debugTrace("state change (RR)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
        }

        // Acknowledge received frames
        session.acknowledgeUpTo(nr: nr)
        session.touch()

        // Deep debug snapshot whenever we advance ACK state from RR.
        debugDumpSessionState(session, context: isPoll ? "inbound-RR-poll" : "inbound-RR")

        _ = processActions(actions, for: session)

        // If this was a poll (P=1), respond with RR F=1
        if isPoll && session.state == .connected {
            let currentVR = session.vr
            debugTrace("RR poll -> response", [
                "peer": source.display,
                "nr": currentVR
            ])
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
        debugTrace("REJ received", [
            "from": source.display,
            "path": path.display.isEmpty ? "(empty)" : path.display,
            "nr": nr,
            "channel": channel
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
            return []
        }

        let oldState = session.state
        let actions = session.stateMachine.handle(event: .receivedREJ(nr: nr))

        if oldState != session.state {
            debugTrace("state change (REJ)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
        }

        // Get frames to retransmit
        let retransmitFrames = session.framesToRetransmit(from: nr)
        for frame in retransmitFrames {
            session.statistics.recordRetransmit()
        }

        session.touch()

        // Deep debug snapshot when peer explicitly requests retransmit.
        debugDumpSessionState(session, context: "inbound-REJ")

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
            debugTrace("state change (T1 timeout)", [
                "peer": session.remoteAddress.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
        }

        session.timers.backoff()  // Exponential backoff
        session.touch()

        // Deep debug snapshot after every T1 timeout, to understand why we're retransmitting
        // or giving up. This is the primary place to diagnose "AXTerm is giving up too early".
        debugDumpSessionState(session, context: "T1-timeout")

        var frames = processActions(actions, for: session)

        if session.state == .connected, session.outstandingCount > 0 {
            let retransmitFrames = session.framesToRetransmit(from: session.va)
            for frame in retransmitFrames {
                debugTrace("TX I (retransmit)", ["frame": describeFrame(frame)])
                session.statistics.recordRetransmit()
                frames.append(frame)
            }
        }

        return frames
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

    // MARK: - Timer Management

    /// Start T1 (retransmit) timer for a session
    private func startT1Timer(for session: AX25Session) {
        // Cancel any existing T1 timer
        session.t1TimerTask?.cancel()

        let rto = session.timers.rto
        let sessionId = session.id

        TxLog.debug(.session, "Starting T1 timer", [
            "session": String(sessionId.uuidString.prefix(8)),
            "rto": String(format: "%.1fs", rto),
            "state": session.state.rawValue
        ])

        session.t1TimerTask = Task { [weak self] in
            do {
                // Convert RTO from seconds to nanoseconds
                try await Task.sleep(nanoseconds: UInt64(rto * 1_000_000_000))

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    // Find the session (it may have been removed)
                    guard let session = self.sessions.values.first(where: { $0.id == sessionId }) else {
                        TxLog.debug(.session, "T1 timeout but session gone", ["session": String(sessionId.uuidString.prefix(8))])
                        return
                    }

                    TxLog.warning(.session, "T1 timeout fired", [
                        "session": String(sessionId.uuidString.prefix(8)),
                        "state": session.state.rawValue,
                        "retryCount": session.stateMachine.retryCount
                    ])

                    // Handle the timeout
                    let frames = self.handleT1Timeout(session: session)

                    // Send any resulting frames via the retransmit callback
                    for frame in frames {
                        self.onRetransmitFrame?(frame)
                    }
                }
            } catch {
                // Task was cancelled, nothing to do
            }
        }
    }

    /// Stop T1 timer for a session
    private func stopT1Timer(for session: AX25Session) {
        if session.t1TimerTask != nil {
            TxLog.debug(.session, "Stopping T1 timer", [
                "session": String(session.id.uuidString.prefix(8))
            ])
            session.t1TimerTask?.cancel()
            session.t1TimerTask = nil
        }
    }

    /// Start T3 (idle) timer for a session
    private func startT3Timer(for session: AX25Session) {
        // Cancel any existing T3 timer
        session.t3TimerTask?.cancel()

        let timeout = session.timers.t3Timeout
        let sessionId = session.id

        session.t3TimerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
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
                        self.onRetransmitFrame?(frame)
                    }
                }
            } catch {
                // Task was cancelled
            }
        }
    }

    /// Stop T3 timer for a session
    private func stopT3Timer(for session: AX25Session) {
        session.t3TimerTask?.cancel()
        session.t3TimerTask = nil
    }

    // MARK: - Private Helpers

    /// Drain the pending data queue for a session that just connected
    private func drainPendingDataQueue(for session: AX25Session) {
        guard !session.pendingDataQueue.isEmpty else { return }

        TxLog.debug(.session, "Draining pending data queue", [
            "peer": session.remoteAddress.display,
            "queueDepth": session.pendingDataQueue.count
        ])

        // Copy and clear the queue
        let pendingData = session.pendingDataQueue
        session.pendingDataQueue.removeAll()

        // Send each queued item
        for item in pendingData {
            guard session.canSendIFrame else {
                // Window full, re-queue remaining items
                session.pendingDataQueue.append(item)
                TxLog.warning(.session, "Window full during queue drain, re-queued", [
                    "remaining": session.pendingDataQueue.count
                ])
                continue
            }

            let iFrame = buildIFrame(for: session, payload: item.data, pid: item.pid, displayInfo: item.displayInfo)
            debugTrace("TX I (drain queue)", ["frame": describeFrame(iFrame)])

            // Buffer for potential retransmission
            session.bufferFrame(iFrame, ns: session.vs - 1)
            session.statistics.recordSent(bytes: item.data.count)

            // Send via callback
            onSendFrame?(iFrame)

            TxLog.debug(.session, "Sent queued data", [
                "peer": session.remoteAddress.display,
                "size": item.data.count
            ])
        }

        session.touch()
    }

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
                debugTrace("TX SABM", ["frame": describeFrame(frame)])
                frames.append(frame)
                onSendFrame?(frame)

            case .sendUA:
                let frame = AX25FrameBuilder.buildUA(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                debugTrace("TX UA", ["frame": describeFrame(frame)])
                frames.append(frame)
                onSendFrame?(frame)

            case .sendDM:
                let frame = AX25FrameBuilder.buildDM(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                debugTrace("TX DM", ["frame": describeFrame(frame)])
                frames.append(frame)
                onSendFrame?(frame)

            case .sendDISC:
                let frame = AX25FrameBuilder.buildDISC(
                    from: session.localAddress,
                    to: session.remoteAddress,
                    via: session.path
                )
                debugTrace("TX DISC", ["frame": describeFrame(frame)])
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
                debugTrace("TX RR", ["frame": describeFrame(frame)])
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
                debugTrace("TX RNR", ["frame": describeFrame(frame)])
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
                debugTrace("TX REJ", ["frame": describeFrame(frame)])
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
                debugTrace("TX I", ["frame": describeFrame(frame)])
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

            case .startT1:
                startT1Timer(for: session)

            case .stopT1:
                stopT1Timer(for: session)

            case .startT3:
                startT3Timer(for: session)

            case .stopT3:
                stopT3Timer(for: session)
            }
        }

        return frames
    }
}
