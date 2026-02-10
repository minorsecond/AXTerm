//
//  KISSTransport.swift
//  AXTerm
//
//  KISS transport for sending frames to Direwolf via TCP.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 3
//

import Foundation
import Network
import OSLog

// MARK: - Transport State

/// Connection state for KISS transport
nonisolated enum KISSTransportState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

// MARK: - Transport Delegate

/// Delegate for receiving transport events
nonisolated protocol KISSTransportDelegate: AnyObject {
    /// Called when a frame send completes (success or failure)
    func transportDidSend(frameId: UUID, result: Result<Void, Error>)

    /// Called when transport state changes
    func transportDidChangeState(_ state: KISSTransportState)
}

// MARK: - Transport Errors

/// Errors from KISS transport
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

// MARK: - Pending Frame Entry

/// A frame queued for transmission
nonisolated struct PendingFrame: Sendable {
    let id: UUID
    let kissData: Data
    let queuedAt: Date

    init(id: UUID, ax25Frame: Data, port: UInt8 = 0) {
        self.id = id
        self.kissData = KISS.encodeFrame(payload: ax25Frame, port: port)
        self.queuedAt = Date()
    }
}

// MARK: - KISS Transport

/// TCP transport for sending KISS-encoded frames to a TNC.
///
/// Features:
/// - Queues frames when disconnected
/// - Tracks frames by UUID for correlation
/// - Handles reconnection
/// - Thread-safe queue management
nonisolated final class KISSTransport: @unchecked Sendable {

    // MARK: - Configuration

    let host: String
    let port: UInt16

    // MARK: - State

    private let lock = NSLock()

    private var _state: KISSTransportState = .disconnected
    var state: KISSTransportState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    private func setState(_ newState: KISSTransportState) {
        let oldState: KISSTransportState
        lock.lock()
        oldState = _state
        _state = newState
        lock.unlock()

        if oldState != newState {
            delegate?.transportDidChangeState(newState)
        }
    }

    /// Delegate for send/state callbacks
    weak var delegate: KISSTransportDelegate?

    // MARK: - Private State

    private var connection: NWConnection?
    private var _pendingFrames: [PendingFrame] = []
    private var isSending = false
    private let connectionQueue = DispatchQueue(label: "com.axterm.kisstransport.connection")

    // MARK: - Public Interface

    /// Number of frames waiting to be sent
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _pendingFrames.count
    }

    /// Initialize transport with endpoint configuration
    /// - Parameters:
    ///   - host: Hostname or IP address
    ///   - port: TCP port number
    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Connect to the TNC
    func connect() {
        guard state != .connecting && state != .connected else { return }

        TxLog.kissConnect(host: host, port: port)
        setState(.connecting)

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            setState(.failed)
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(host: nwHost, port: nwPort, using: params)

        conn.stateUpdateHandler = { [weak self] newState in
            self?.handleConnectionState(newState)
        }

        lock.lock()
        connection = conn
        lock.unlock()

        conn.start(queue: connectionQueue)
    }

    /// Disconnect from the TNC
    func disconnect() {
        lock.lock()
        let conn = connection
        connection = nil
        isSending = false
        lock.unlock()

        conn?.cancel()
        TxLog.kissDisconnected(reason: "User initiated")
        setState(.disconnected)
    }

    /// Queue a frame for transmission
    /// - Parameters:
    ///   - frameId: Unique identifier for tracking
    ///   - ax25Frame: Raw AX.25 frame bytes
    ///   - port: KISS port (default 0)
    func send(frameId: UUID, ax25Frame: Data, port: UInt8 = 0) {
        let frame = PendingFrame(id: frameId, ax25Frame: ax25Frame, port: port)

        lock.lock()
        _pendingFrames.append(frame)
        let currentState = _state
        let queueDepth = _pendingFrames.count
        lock.unlock()

        TxLog.kissSend(frameId: frameId, size: frame.kissData.count)
        TxLog.debug(.queue, "Frame queued", [
            "frameId": String(frameId.uuidString.prefix(8)),
            "queueDepth": queueDepth,
            "state": currentState.rawValue
        ])
        TxLog.hexDump(.kiss, "KISS frame", data: frame.kissData)

        // If connected, start sending
        if currentState == .connected {
            flushQueue()
        }
    }

    /// Check if a frame is pending
    func isPending(frameId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _pendingFrames.contains { $0.id == frameId }
    }

    /// Cancel a pending frame
    /// - Returns: true if the frame was found and removed
    @discardableResult
    func cancel(frameId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let index = _pendingFrames.firstIndex(where: { $0.id == frameId }) {
            _pendingFrames.remove(at: index)
            return true
        }
        return false
    }

    // MARK: - Private Implementation

    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            TxLog.kissConnected(host: host, port: port)
            setState(.connected)
            // Flush any queued frames
            flushQueue()

        case .failed(let error):
            TxLog.error(.kiss, "Connection failed", error: error, [
                "host": host,
                "port": port
            ])
            setState(.failed)
            // Notify delegate of all pending failures
            lock.lock()
            let pending = _pendingFrames
            _pendingFrames.removeAll()
            lock.unlock()

            TxLog.warning(.queue, "Failing \(pending.count) queued frames due to connection failure")
            for frame in pending {
                delegate?.transportDidSend(
                    frameId: frame.id,
                    result: .failure(KISSTransportError.connectionFailed(error.localizedDescription))
                )
            }

        case .cancelled:
            TxLog.kissDisconnected(reason: "Connection cancelled")
            setState(.disconnected)
            lock.lock()
            isSending = false
            lock.unlock()

        case .waiting(let error):
            TxLog.debug(.kiss, "Connection waiting", ["error": error.localizedDescription])
            break

        default:
            TxLog.debug(.kiss, "Connection state: \(newState)")
            break
        }
    }

    private func flushQueue() {
        lock.lock()
        guard !isSending, let frame = _pendingFrames.first else {
            lock.unlock()
            return
        }
        isSending = true
        let conn = connection
        lock.unlock()

        guard let conn = conn, state == .connected else {
            TxLog.warning(.transport, "Cannot flush: not connected", ["state": state.rawValue])
            lock.lock()
            isSending = false
            lock.unlock()
            return
        }

        TxLog.outbound(.transport, "Transmitting frame", [
            "frameId": String(frame.id.uuidString.prefix(8)),
            "size": frame.kissData.count
        ])

        conn.send(content: frame.kissData, completion: .contentProcessed { [weak self] error in
            self?.handleSendCompletion(frame: frame, error: error)
        })
    }

    private func handleSendCompletion(frame: PendingFrame, error: NWError?) {
        // Remove from pending
        lock.lock()
        if let index = _pendingFrames.firstIndex(where: { $0.id == frame.id }) {
            _pendingFrames.remove(at: index)
        }
        isSending = false
        let currentState = _state
        let remainingCount = _pendingFrames.count
        lock.unlock()

        // Notify delegate
        if let error = error {
            TxLog.kissSendComplete(frameId: frame.id, success: false, error: error)
            delegate?.transportDidSend(
                frameId: frame.id,
                result: .failure(KISSTransportError.sendFailed(error.localizedDescription))
            )
        } else {
            TxLog.kissSendComplete(frameId: frame.id, success: true)
            delegate?.transportDidSend(frameId: frame.id, result: .success(()))
        }

        TxLog.debug(.queue, "Queue updated", ["remaining": remainingCount])

        // Continue with next frame
        if currentState == .connected {
            flushQueue()
        }
    }
}
