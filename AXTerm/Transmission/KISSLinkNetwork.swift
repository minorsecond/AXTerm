//
//  KISSLinkNetwork.swift
//  AXTerm
//
//  KISS transport over TCP using Network.framework.
//  Conforms to KISSLink to provide a transport-agnostic byte stream.
//

import Foundation
import Network

/// TCP-based KISS link using Network.framework.
///
/// This wraps the existing NWConnection pattern from PacketEngine
/// behind the KISSLink protocol so the engine doesn't need to know
/// whether bytes come from TCP or serial.
///
/// ## Coming back
///
/// For a long time this was the one transport that gave up. The serial and
/// Bluetooth links have had auto-reconnect and a settings switch for it since
/// they were written; a failed TCP connection just sat there until somebody
/// clicked Connect. On 2026-09-18 the socket to Direwolf on a Raspberry Pi was
/// reset at about 20:20 and the station was off the air until the operator
/// came back the next morning — with the app running, the network up, and
/// nothing in the code that would ever try again.
///
/// The policy is deliberately the same one `ModemRadioLink` uses, rather than
/// a second invention: double from a small base, cap it, never stop trying,
/// and only clear the count once a connection has held long enough to prove
/// it is real. A Pi that comes up, accepts a connection and reboots again
/// should not be rewarded with a reset backoff every few seconds.
final class KISSLinkNetwork: KISSLink, @unchecked Sendable {

    // MARK: - Configuration

    let host: String
    let port: UInt16
    /// Whether a link that fails on its own should come back on its own.
    let autoReconnect: Bool

    // MARK: - KISSLink

    private let lock = NSLock()
    private var _state: KISSLinkState = .disconnected

    var state: KISSLinkState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var endpointDescription: String {
        "\(host):\(port)"
    }

    weak var delegate: KISSLinkDelegate?

    // MARK: - Private

    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "com.axterm.kisslink.network")

    // MARK: - Reconnect

    /// Whether the operator wants this link up. `close()` clears it, which is
    /// what stops a deliberate disconnect from being undone a second later.
    private var wantsOpen = false
    private var reconnectAttempt = 0
    private var reconnectTimer: DispatchSourceTimer?
    private var stabilityTimer: DispatchSourceTimer?
    private static let baseReconnectDelay: TimeInterval = 1
    private static let maxReconnectDelay: TimeInterval = 30
    /// How long a connection must hold before its backoff is cleared. Direwolf
    /// accepts a TCP connection before it knows whether it can serve one, so a
    /// socket that opens and dies inside a few seconds is a failure wearing a
    /// success's clothes.
    let stableConnectionSeconds: TimeInterval

    // MARK: - Init

    init(host: String, port: UInt16,
         autoReconnect: Bool = true,
         stableConnectionSeconds: TimeInterval = 12) {
        self.host = host
        self.port = port
        self.autoReconnect = autoReconnect
        self.stableConnectionSeconds = stableConnectionSeconds
    }

    deinit {
        reconnectTimer?.cancel()
        stabilityTimer?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    #if DEBUG
    /// Test seam: read or seed the backoff counter, so "clear only once the
    /// connection holds" can be exercised without waiting out a real delay.
    var testReconnectAttempt: Int {
        get { lock.lock(); defer { lock.unlock() }; return reconnectAttempt }
        set { lock.lock(); reconnectAttempt = newValue; lock.unlock() }
    }
    #endif

    /// Advance the attempt counter. Clamped rather than terminal: a link the
    /// operator wants open should recover on its own whenever the far end
    /// comes back, however long that takes.
    static func nextReconnectAttempt(_ current: Int) -> Int {
        min(current + 1, 8)
    }

    /// The delay before attempt `attempt` (1-based), doubling from the base
    /// and capped. Jitter is added by the caller.
    static func reconnectBackoff(attempt: Int) -> TimeInterval {
        let steps = max(0, attempt - 1)
        return min(baseReconnectDelay * pow(2, Double(steps)), maxReconnectDelay)
    }

    // MARK: - KISSLink Conformance

    func open() {
        lock.lock()
        wantsOpen = true
        lock.unlock()
        cancelReconnectTimer()

        let current = state
        guard current != .connecting && current != .connected else { return }

        setState(.connecting)
        KISSLinkLog.opened(endpointDescription)

        let nwHost = NWEndpoint.Host(host)
        // Neither this nor the host check below schedules a reconnect. Both
        // are settled facts rather than transient ones, and a backoff against
        // a settled fact is an infinite loop with a delay in it.
        //
        // Port 0 has to be rejected by hand: `NWEndpoint.Port(rawValue: 0)`
        // succeeds and means "any", which for an outbound connection is not a
        // port at all.
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            setState(.failed)
            notifyError("Invalid port \(port)")
            return
        }

        guard AppEnvironment.mayConnect(to: host) else {
            setState(.failed)
            notifyError("a test host may not reach \(host)")
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(host: nwHost, port: nwPort, using: params)

        conn.stateUpdateHandler = { [weak self] newState in
            self?.handleConnectionState(newState)
        }

        lock.lock()
        let previous = connection
        connection = conn
        lock.unlock()
        discard(previous)

        conn.start(queue: connectionQueue)
    }

    func close() {
        lock.lock()
        wantsOpen = false
        reconnectAttempt = 0
        let conn = connection
        connection = nil
        lock.unlock()

        cancelReconnectTimer()
        cancelStabilityTimer()
        discard(conn)
        setState(.disconnected)
        KISSLinkLog.closed(endpointDescription, reason: "User initiated")
    }

    /// The machine is going to sleep. Drop the socket on purpose so the far
    /// end sees a close rather than a client that stopped answering, and keep
    /// `wantsOpen` set so `resume()` knows this link is still wanted.
    func suspend() {
        lock.lock()
        let wanted = wantsOpen
        let conn = connection
        connection = nil
        lock.unlock()

        guard wanted || conn != nil else { return }
        cancelReconnectTimer()
        cancelStabilityTimer()
        discard(conn)
        setState(.disconnected)
        KISSLinkLog.closed(endpointDescription, reason: "System sleep")
    }

    /// The machine is back. Reopen at once, with the backoff cleared: the drop
    /// was expected, and making the station serve a penalty for the operator's
    /// lid is how a node stays off the air long after its Mac is awake.
    func resume() {
        lock.lock()
        let wanted = wantsOpen
        reconnectAttempt = 0
        lock.unlock()

        guard wanted else { return }
        KISSLinkLog.info(endpointDescription, message: "Reopening after system sleep")
        open()
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock()
        let conn = connection
        let current = _state
        lock.unlock()

        guard current == .connected, let conn = conn else {
            completion(KISSTransportError.notConnected)
            return
        }

        KISSLinkLog.bytesOut(endpointDescription, count: data.count)

        conn.send(content: data, completion: .contentProcessed { error in
            if let nwError = error {
                completion(KISSTransportError.sendFailed(nwError.localizedDescription))
            } else {
                completion(nil)
            }
        })
    }

    // MARK: - Private

    private func setState(_ newState: KISSLinkState) {
        let old: KISSLinkState
        lock.lock()
        old = _state
        _state = newState
        lock.unlock()

        if old != newState {
            KISSLinkLog.stateChange(endpointDescription, from: old, to: newState)
            Task { @MainActor [weak self] in
                self?.delegate?.linkDidChangeState(newState)
            }
        }
    }

    private func notifyError(_ message: String) {
        KISSLinkLog.error(endpointDescription, message: message)
        Task { @MainActor [weak self] in
            self?.delegate?.linkDidError(message)
        }
    }

    private func handleConnectionState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            setState(.connected)
            scheduleBackoffResetIfStable()
            startReceiving()

        case .failed(let error):
            setState(.failed)
            notifyError("Connection failed: \(error.localizedDescription)")
            scheduleReconnect()

        case .cancelled:
            setState(.disconnected)

        case .waiting(let error):
            // Network.framework is still trying on its own here, so this is a
            // progress report rather than a failure. Saying so does not earn a
            // reconnect of ours on top of the one already running.
            notifyError("Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
    }

    // MARK: - Private: Reconnect

    /// Try again after a growing delay, until it connects, or `close()` says
    /// to stop. Never gives up on its own.
    private func scheduleReconnect() {
        lock.lock()
        let wanted = wantsOpen
        guard autoReconnect, wanted else {
            lock.unlock()
            return
        }
        reconnectAttempt = Self.nextReconnectAttempt(reconnectAttempt)
        let attempt = reconnectAttempt
        lock.unlock()

        cancelStabilityTimer()

        // Jitter so two radios on one Direwolf, which fail together, do not
        // then retry together forever.
        let delay = Self.reconnectBackoff(attempt: attempt) + Double.random(in: 0...0.5)
        KISSLinkLog.reconnect(endpointDescription, attempt: attempt)

        let timer = DispatchSource.makeTimerSource(queue: connectionQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Re-check under the lock: a close() or a successful open in the
            // meantime must win over a timer that was already in flight.
            self.lock.lock()
            let stillWanted = self.wantsOpen
            let stillDown = self._state == .failed || self._state == .disconnected
            self.lock.unlock()
            guard stillWanted, stillDown else { return }
            self.open()
        }

        lock.lock()
        reconnectTimer?.cancel()
        reconnectTimer = timer
        lock.unlock()

        timer.resume()
    }

    /// Clear the backoff, but only once the connection has held. A flap
    /// cancels this before it fires, so a far end that keeps dropping keeps a
    /// growing delay instead of resetting to zero every few seconds.
    private func scheduleBackoffResetIfStable() {
        let timer = DispatchSource.makeTimerSource(queue: connectionQueue)
        timer.schedule(deadline: .now() + stableConnectionSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self._state == .connected { self.reconnectAttempt = 0 }
            self.lock.unlock()
        }

        lock.lock()
        stabilityTimer?.cancel()
        stabilityTimer = timer
        lock.unlock()

        timer.resume()
    }

    /// Drop a connection for good.
    ///
    /// Clearing the handler before cancelling matters: `cancel()` delivers a
    /// `.cancelled` state asynchronously, and if the link has been reopened in
    /// the meantime that late report from a dead connection lands on the live
    /// one and puts it back to `.disconnected`. Which is how a resume after
    /// sleep could open a socket and immediately appear not to have.
    private func discard(_ conn: NWConnection?) {
        guard let conn else { return }
        conn.stateUpdateHandler = nil
        conn.cancel()
    }

    private func cancelReconnectTimer() {
        lock.lock()
        let timer = reconnectTimer
        reconnectTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func cancelStabilityTimer() {
        lock.lock()
        let timer = stabilityTimer
        stabilityTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func startReceiving() {
        lock.lock()
        let conn = connection
        lock.unlock()

        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let data = content, !data.isEmpty {
                KISSLinkLog.bytesIn(self.endpointDescription, count: data.count)
                Task { @MainActor [weak self] in
                    self?.delegate?.linkDidReceive(data)
                }
            }

            if let error = error {
                // The read failing is how a reset arrives when the connection's
                // own state handler has not caught up yet. Treat it as the
                // failure it is, so the reconnect starts here rather than
                // waiting for a state change that may never come.
                self.notifyError("Receive error: \(error.localizedDescription)")
                self.setState(.failed)
                self.scheduleReconnect()
                return
            }

            if isComplete {
                // The far end closed cleanly. Direwolf does this when it is
                // restarted, so it is worth coming back from — but through the
                // backoff, not instantly, because a Pi that is rebooting will
                // refuse the next few attempts.
                self.lock.lock()
                let finished = self.connection
                self.connection = nil
                self.lock.unlock()
                self.discard(finished)
                self.setState(.failed)
                KISSLinkLog.info(self.endpointDescription, message: "Far end closed the connection")
                self.scheduleReconnect()
                return
            }

            self.startReceiving()
        }
    }
}

// MARK: - Errors

/// Failures a KISS link reports through its send completion.
///
/// Named for the TCP client it came from, which is gone: `KISSLinkNetwork`
/// replaced it long ago and nothing else constructed it.
nonisolated enum KISSTransportError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Transport not connected"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        }
    }
}
