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

// MARK: - Session

/// Represents an AX.25 connected-mode session
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

    /// T1 retransmit timer task
    var t1TimerTask: AnyCancellableTask?

    /// Pending retransmit task (grace period after T1 fires); cancelled if RR arrives
    var t1PendingRetransmitTask: AnyCancellableTask?

    /// T3 idle timer task
    var t3TimerTask: AnyCancellableTask?

    /// N(R) at which we last triggered an immediate REJ retransmit.
    /// Used to suppress duplicate REJ retransmission amplification (Bug A):
    /// once we retransmit for REJ(nr), T1 owns the retry cycle until ack
    /// progress or T1 fires. Cleared when T1 fires so next REJ after T1
    /// timeout triggers a fresh immediate retransmit.
    var lastREJRetransmitNR: Int? = nil

    /// Monotonic time when SABM was sent, from the injected clock (for RTT calculation).
    /// Using TimeInterval keeps this compatible with the virtual clock in tests.
    var sabmSentAt: TimeInterval?

    /// Timestamp when session was established
    var connectedAt: Date?

    /// Timestamp of last activity
    var lastActivityAt: Date

    /// Whether we initiated this session (vs responding to incoming SABM)
    let isInitiator: Bool

    /// Via path from the most recently received inbound I-frame (for display only).
    /// Updated each time handleInboundIFrame delivers data.
    var lastReceivedVia: [String] = []

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
        self.timers = AX25SessionTimers(
            rtoMin: config.rtoMin ?? 1.0,
            rtoMax: config.rtoMax ?? 30.0,
            initialRto: config.initialRto ?? 4.0
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
        
        // Loop from va up to (but not including) nr, acknowledging each frame
        while current != nr {
            sendBuffer.removeValue(forKey: current)
            current = (current + 1) % modulo
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

    /// Callback when frames need to be sent
    var onSendFrame: ((OutboundFrame) -> Void)?

    /// Callback when data is received from a connected session
    var onDataReceived: ((AX25Session, Data) -> Void)?

    /// Callback when data is delivered (in-order) from a connected session.
    /// Used for AXDP reassembly - must only append chunks that were accepted by the AX.25 layer,
    /// not out-of-window or buffered frames (those will be delivered later in sequence).
    var onDataDeliveredForReassembly: ((AX25Session, Data) -> Void)?

    /// Callback when session state changes
    var onSessionStateChanged: ((AX25Session, AX25SessionState, AX25SessionState) -> Void)?

    /// Callback when we have a link quality sample (e.g. after RR with RTT) for adaptive tuning. Parameters: session, lossRate, etx, srtt.
    var onLinkQualitySample: ((AX25Session, Double, Double, Double?) -> Void)?

    /// Callback when peer ACKs frames (RR received). Parameters: session, newVa (V(A) after ack).
    /// Used for sender UI to show progressive send/ack highlighting.
    var onOutboundAckReceived: ((AX25Session, Int) -> Void)?

    /// When set, used to get session config per route (destination + path) so direct vs via-digi use separate learned params. If nil, use defaultConfig.
    var getConfigForDestination: ((String, String) -> AX25SessionConfig)?

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
    func checkInvariants(session: AX25Session) {
        #if DEBUG
        session.stateMachine.sequenceState.assertInvariants(windowSize: session.stateMachine.config.windowSize)
        
        // sendBuffer.count must exactly match outstanding frames according to V(S) and V(A)
        // If this fails, we have a memory leak (frames stuck in buffer) or a duplicate tracking bug.
        assert(session.sendBuffer.count == session.stateMachine.sequenceState.outstandingCount,
               "Invariant violation: sendBuffer.count (\(session.sendBuffer.count)) != outstandingCount (\(session.stateMachine.sequenceState.outstandingCount)). vs=\(session.vs) va=\(session.va)")
        #endif
    }

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
        let config = getConfigForDestination?(destination.display, pathSignature) ?? defaultConfig
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
    func removeSession(_ session: AX25Session) {
        sessions.removeValue(forKey: session.key)

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

        session.sabmSentAt = clock.currentTime
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
            onSessionStateChanged?(session, oldState, session.state)
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
            onSessionStateChanged?(session, oldState, session.state)
        }

        // Clear sabmSentAt to prevent late UA from reopening the session
        session.sabmSentAt = nil
        session.clearPendingTransmission(reason: "Force disconnect")
        session.touch()
        _ = processActions(actions, for: session)
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
            // Send chunks that fit in window; queue the rest
            var remaining: [(data: Data, pid: UInt8, displayInfo: String?)] = []
            print("[DEBUG:AX25:SEND] sendData connected | dest=\(destination.display) totalChunks=\(chunks.count) paclen=\(paclen) canSend=\(session.canSendIFrame) va=\(session.va) vs=\(session.vs)")
            for (i, chunk) in chunks.enumerated() {
                guard session.canSendIFrame else {
                    let info = (i == 0) ? displayInfo : nil
                    remaining.append((data: chunk, pid: pid, displayInfo: info))
                    print("[DEBUG:AX25:SEND] window full, queue chunk \(i) | remaining=\(remaining.count)")
                    continue
                }
                let info = (i == 0) ? displayInfo : nil
                let wasIdle = session.outstandingCount == 0
                let ns = session.vs  // Capture before buildIFrame increments vs
                let iFrame = buildIFrame(for: session, payload: chunk, pid: pid, displayInfo: info)
                frames.append(iFrame)
                print("[DEBUG:AX25:SEND] immediate tx chunk \(i) | N(S)=\(ns) payload=\(chunk.count)")

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
            session.pendingDataQueue.insert(contentsOf: remaining, at: 0)
            if !remaining.isEmpty {
                print("[DEBUG:AX25:SEND] queued remaining | count=\(remaining.count) queueDepth=\(session.pendingDataQueue.count)")
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
            let pathSignature = path.display
            let config = getConfigForDestination?(source.display, pathSignature) ?? defaultConfig
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
        if session.state == .connecting, let sabmSent = session.sabmSentAt {
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
        // Use findConnectedSession to match a connected session from this peer (common
        // with digipeaters where return path differs). Also check .disconnecting: per
        // AX.25 §6.4.2, if we sent DISC and receive DISC back simultaneously, we must
        // respond UA and finish teardown — not send DM as if no session existed.
        let disconnecting = sessions.values.first {
            $0.remoteAddress.display.uppercased() == source.display.uppercased() &&
            $0.channel == channel &&
            $0.state == .disconnecting
        }
        guard let session = findConnectedSession(from: source, channel: channel) ?? disconnecting else {
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

        // Clear send buffer and notify UI that frames are acknowledged.
        // When remote sends DISC in response to our I-frame (e.g., "bye" command),
        // they clearly received it. Mark as delivered for UX purposes.
        if !session.sendBuffer.isEmpty {
            let bufferedFrames = session.sendBuffer.keys.sorted()
            TxLog.debug(.session, "Clearing send buffer on DISC", [
                "peer": source.display,
                "bufferedNS": bufferedFrames.map { String($0) }.joined(separator: ",")
            ])
            session.clearPendingTransmission(reason: "remote DISC")
            // Notify that all frames are considered acknowledged
            onOutboundAckReceived?(session, session.vs)
        }

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

        // Capture V(A) before state machine updates it - piggybacked N(R) acks [V(A), N(R))
        let vaBefore = session.va

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

        // Acknowledge received frames in our send buffer: remove [vaBefore, nr)
        session.acknowledgeUpTo(from: vaBefore, to: nr)
        session.statistics.recordReceived(bytes: payload.count)
        session.touch()

        // Record the actual inbound via path so callbacks can thread it to the UI.
        session.lastReceivedVia = path.digis.map { $0.display }

        onOutboundAckReceived?(session, session.va)

        // Deep debug snapshot whenever we successfully process an inbound I-frame.
        debugDumpSessionState(session, context: "inbound-I")
        checkInvariants(session: session)

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
        let actions = session.stateMachine.handle(event: .receivedRR(nr: nr))

        if oldState != session.state {
            debugTrace("state change (RR)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
        }

        // Acknowledge received frames: remove only [vaBefore, nr) - not all ns < nr.
        // When N(S) wraps, ns=0,1,2 may be newer frames; RR(nr=4) acks the FIRST use
        // of 0,1,2,3 (PING/test/chunks), not the WRAPPED use (later chunks).
        let sendBufKeysBefore = session.sendBuffer.keys.sorted()
        session.acknowledgeUpTo(from: vaBefore, to: nr)
        let sendBufKeysAfter = session.sendBuffer.keys.sorted()

        // Bug G fix: AIMD additive increase per acknowledged frame.
        // Call onAck() once for each frame that RR(nr) newly acknowledges so that
        // the congestion window grows proportionally to confirmed delivery.
        // Only grow when frames were actually acked (nr != vaBefore) to avoid
        // spurious growth from duplicate or no-progress RRs.
        let modulo = session.stateMachine.config.modulo
        let ackedCount = (nr - vaBefore + modulo) % modulo
        if ackedCount > 0 {
            for _ in 0..<ackedCount {
                session.aimdWindow.onAck()
            }
        }

        session.touch()

        print("[DEBUG:AX25:RR] rx | nr=\(nr) va=\(session.va) vs=\(session.vs) sendBufBefore=\(sendBufKeysBefore) sendBufAfter=\(sendBufKeysAfter) outstanding=\(session.outstandingCount)")
        onOutboundAckReceived?(session, session.va)

        TxLog.debug(.session, "RR ACK state", [
            "peer": source.display,
            "va": session.va,
            "vs": session.vs,
            "outstanding": session.outstandingCount,
            "queueDepth": session.pendingDataQueue.count
        ])

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

        _ = processActions(actions, for: session)
        checkInvariants(session: session)

        // Feed link quality sample into adaptive settings (session-based learning)
        let framesSent = max(1, session.statistics.framesSent)
        let lossRate = Double(session.statistics.retransmissions) / Double(framesSent)
        let delivery = max(0.05, 1.0 - lossRate)
        let etx = 1.0 / (delivery * delivery)
        onLinkQualitySample?(session, lossRate, etx, session.timers.srtt)

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

        let vaBefore = session.va
        let oldState = session.state
        // Bug D fix: validate N(R) before passing to state machine's ackUpTo.
        // A stale nr (< V(A)) would wrap the modulo loop in acknowledgeUpTo and
        // delete frames that are still outstanding, corrupting the send buffer.
        let validNR = session.stateMachine.sequenceState.isValidNR(nr: nr)
        let actions = session.stateMachine.handle(event: .receivedREJ(nr: nr))

        if oldState != session.state {
            debugTrace("state change (REJ)", [
                "peer": source.display,
                "from": oldState.rawValue,
                "to": session.state.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
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

        // Bug A fix: suppress retransmission amplification from duplicate REJ storms.
        // After the first REJ(nr) triggers an immediate retransmit, T1 owns the retry
        // cycle. A second REJ with the same nr and no ack progress must not retransmit
        // again — T1 will handle it. Rate-limiting is reset when T1 fires.
        let noAckProgress = session.va == vaBefore
        let isDuplicateREJ = session.lastREJRetransmitNR == nr
        let shouldRetransmit = !(noAckProgress && isDuplicateREJ)

        let retransmitFrames: [OutboundFrame]
        if shouldRetransmit {
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
                "to": oldState.rawValue
            ])
            onSessionStateChanged?(session, oldState, session.state)
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

        if session.state == .connected, session.outstandingCount > 0 {
            // Bug G fix: AIMD multiplicative decrease on T1 timeout (loss event).
            // Called once per timeout event, not once per retransmitted frame.
            session.aimdWindow.onLoss()
            TxLog.debug(.session, "AIMD loss event (T1 timeout)", [
                "peer": session.remoteAddress.display,
                "cwnd": String(format: "%.2f", session.aimdWindow.cwnd),
                "effectiveWindow": session.aimdWindow.effectiveWindow
            ])

            let retransmitFrames = session.framesToRetransmit(from: session.va)
            let nsValues = retransmitFrames.compactMap { f -> Int? in
                guard let ctrl = f.controlByte else { return nil }
                return Int((ctrl >> 1) & 0x07)  // N(S) from AX.25 control byte
            }
            print("[DEBUG:AX25:T1] retransmit | va=\(session.va) vs=\(session.vs) vr=\(session.vr) outstanding=\(session.outstandingCount) sendBufKeys=\(session.sendBuffer.keys.sorted()) retransmitNS=\(nsValues) retransmitCount=\(retransmitFrames.count)")
            TxLog.debug(.session, "T1 retransmit", [
                "peer": session.remoteAddress.display,
                "va": session.va,
                "outstanding": session.outstandingCount,
                "retransmitCount": retransmitFrames.count,
                "retransmitNS": nsValues.map { String($0) }.joined(separator: ",")
            ])
            for frame in retransmitFrames {
                // Update N(R) to current V(R) so the peer sees our latest receive state
                let updatedFrame = frame.withUpdatedNR(session.vr)
                debugTrace("TX I (retransmit)", ["frame": describeFrame(updatedFrame)])
                session.statistics.recordRetransmit()
                frames.append(updatedFrame)
                // Bug E fix (Karn's algorithm): mark this N(S) as retransmitted so
                // the subsequent ACK does NOT generate an RTT sample. The ACK is
                // ambiguous — it could be for the original or the retransmit.
                if let ctrl = updatedFrame.controlByte {
                    let ns = Int((ctrl >> 1) & 0x07)
                    session.markRetransmitted(ns: ns)
                }
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
    func startT1Timer(for session: AX25Session) {
        // Cancel any existing T1 timer and pending grace-period retransmit
        session.t1TimerTask?.cancel()
        session.t1PendingRetransmitTask?.cancel()
        session.t1PendingRetransmitTask = nil

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
        let currentOutstanding = session.stateMachine.sequenceState.outstandingCount
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
            let ns = session.vs  // Capture before buildIFrame increments vs
            let iFrame = buildIFrame(for: session, payload: item.data, pid: item.pid, displayInfo: item.displayInfo)
            debugTrace("TX I (drain queue)", ["frame": describeFrame(iFrame)])
            print("[DEBUG:AX25:DRAIN] tx | N(S)=\(ns) payload=\(item.data.count) va=\(session.va) vs=\(session.vs)")
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

            case .deliverData(let data):
                let prefixHex = data.prefix(8).map { String(format: "%02X", $0) }.joined()
                let hasMagic = AXDP.hasMagic(data)
                print("[DEBUG:AX25:DELIVER] I-frame payload to reassembly | from=\(session.remoteAddress.display) size=\(data.count) hasMagic=\(hasMagic) prefix=\(prefixHex)")
                TxLog.debug(.axdp, "I-frame payload delivered to reassembly", [
                    "peer": session.remoteAddress.display,
                    "size": data.count,
                    "hasMagic": hasMagic,
                    "prefixHex": prefixHex
                ])
                onDataDeliveredForReassembly?(session, data)
                onDataReceived?(session, data)

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
