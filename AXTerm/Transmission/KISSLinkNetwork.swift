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
final class KISSLinkNetwork: KISSLink, @unchecked Sendable {

    // MARK: - Configuration

    let host: String
    let port: UInt16

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

    // MARK: - Init

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    deinit {
        connection?.cancel()
    }

    // MARK: - KISSLink Conformance

    func open() {
        let current = state
        guard current != .connecting && current != .connected else { return }

        setState(.connecting)
        KISSLinkLog.opened(endpointDescription)

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            setState(.failed)
            notifyError("Invalid port \(port)")
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

    func close() {
        lock.lock()
        let conn = connection
        connection = nil
        lock.unlock()

        conn?.cancel()
        setState(.disconnected)
        KISSLinkLog.closed(endpointDescription, reason: "User initiated")
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
            startReceiving()

        case .failed(let error):
            setState(.failed)
            notifyError("Connection failed: \(error.localizedDescription)")

        case .cancelled:
            setState(.disconnected)

        case .waiting(let error):
            notifyError("Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
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
                self.notifyError("Receive error: \(error.localizedDescription)")
                return
            }

            if isComplete {
                self.close()
                return
            }

            self.startReceiving()
        }
    }
}
