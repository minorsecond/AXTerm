//
//  SimulatorClient.swift
//  AXTermIntegrationTests
//
//  Bidirectional KISS TCP client for integration testing with Direwolf simulation.
//  Provides async/await API for sending and receiving AX.25 frames.
//

import Foundation
import Network
@testable import AXTerm

// MARK: - Errors

/// Errors from simulator client
enum SimulatorClientError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case timeout
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Client not connected"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .timeout:
            return "Operation timed out"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        }
    }
}

// MARK: - Simulator Client

/// Bidirectional KISS TCP client for integration tests.
///
/// Usage:
/// ```swift
/// let client = SimulatorClient(host: "localhost", port: 8001)
/// try await client.connect()
/// try await client.sendAX25Frame(frameData)
/// let received = try await client.waitForFrame(timeout: 5.0)
/// client.disconnect()
/// ```
final class SimulatorClient: @unchecked Sendable {

    // MARK: - Configuration

    let host: String
    let port: UInt16
    let stationName: String

    // MARK: - State

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.axterm.simulator-client")

    private var isConnected = false
    private var parser = KISSFrameParser()
    private var receivedFrames: [Data] = []
    private let lock = NSLock()

    // MARK: - Initialization

    /// Initialize client for a specific TNC endpoint
    /// - Parameters:
    ///   - host: Hostname (default localhost)
    ///   - port: KISS TCP port
    ///   - stationName: Descriptive name for logging
    init(host: String = "localhost", port: UInt16, stationName: String = "Unknown") {
        self.host = host
        self.port = port
        self.stationName = stationName
    }

    // MARK: - Connection

    /// Connect to the TNC
    func connect() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(throwing: SimulatorClientError.connectionFailed("Invalid port"))
                return
            }

            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: params
            )

            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.lock.lock()
                    self?.isConnected = true
                    self?.lock.unlock()
                    self?.startReceiving()
                    continuation.resume()

                case .failed(let error):
                    continuation.resume(throwing: SimulatorClientError.connectionFailed(error.localizedDescription))

                case .cancelled:
                    self?.lock.lock()
                    self?.isConnected = false
                    self?.lock.unlock()

                default:
                    break
                }
            }

            self.connection = conn
            conn.start(queue: queue)
        }
    }

    /// Disconnect from TNC
    func disconnect() {
        lock.lock()
        isConnected = false
        parser.reset()
        receivedFrames.removeAll()
        let conn = connection
        connection = nil
        lock.unlock()

        conn?.cancel()
    }

    // MARK: - Send

    /// Send a raw AX.25 frame (will be KISS-encoded)
    /// - Parameter ax25Frame: Raw AX.25 frame bytes
    func sendAX25Frame(_ ax25Frame: Data) async throws {
        guard let conn = connection, isConnected else {
            throw SimulatorClientError.notConnected
        }

        let kissFrame = KISS.encodeFrame(payload: ax25Frame, port: 0)

        return try await withCheckedThrowingContinuation { continuation in
            conn.send(content: kissFrame, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: SimulatorClientError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Receive

    /// Wait for a frame to be received
    /// - Parameter timeout: Maximum time to wait in seconds
    /// - Returns: Raw AX.25 frame data
    func waitForFrame(timeout: TimeInterval = 5.0) async throws -> Data {
        // Check if we already have a frame
        lock.lock()
        if !receivedFrames.isEmpty {
            let frame = receivedFrames.removeFirst()
            lock.unlock()
            return frame
        }
        lock.unlock()

        // Wait for a frame with timeout using a simpler pattern
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            // Check for a frame
            lock.lock()
            if !receivedFrames.isEmpty {
                let frame = receivedFrames.removeFirst()
                lock.unlock()
                return frame
            }
            lock.unlock()

            // Brief sleep before checking again
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }

        throw SimulatorClientError.timeout
    }

    /// Get all currently buffered frames (non-blocking)
    func drainReceivedFrames() -> [Data] {
        lock.lock()
        let frames = receivedFrames
        receivedFrames.removeAll()
        lock.unlock()
        return frames
    }

    /// Clear receive buffer
    func clearReceiveBuffer() {
        lock.lock()
        receivedFrames.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func startReceiving() {
        guard let conn = connection else { return }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content {
                self.handleReceivedData(data)
            }

            if let error = error {
                print("[\(self.stationName)] Receive error: \(error)")
            }

            if !isComplete && error == nil {
                // Continue receiving
                self.startReceiving()
            }
        }
    }

    private func handleReceivedData(_ data: Data) {
        lock.lock()
        let frames = parser.feed(data)
        // Buffer all received frames
        receivedFrames.append(contentsOf: frames)
        lock.unlock()
    }
}

// MARK: - Convenience Extensions

extension SimulatorClient {
    /// Create a client for Station A (TEST-1)
    static func stationA(host: String = "localhost") -> SimulatorClient {
        SimulatorClient(host: host, port: 8001, stationName: "Station-A")
    }

    /// Create a client for Station B (TEST-2)
    static func stationB(host: String = "localhost") -> SimulatorClient {
        SimulatorClient(host: host, port: 8002, stationName: "Station-B")
    }
}
