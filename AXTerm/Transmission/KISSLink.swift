//
//  KISSLink.swift
//  AXTerm
//
//  Transport abstraction for KISS byte streams.
//  Both network (TCP) and serial (USB) transports conform to this protocol.
//

import Foundation
import OSLog

// MARK: - KISSLink State

/// Connection state shared across all KISSLink transports
nonisolated enum KISSLinkState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

// MARK: - KISSLink Delegate

/// Delegate for receiving transport events from any KISSLink
@MainActor
protocol KISSLinkDelegate: AnyObject {
    /// Called when raw bytes arrive from the transport (pre-KISS-deframing)
    func linkDidReceive(_ data: Data)

    /// Called when the link state changes
    func linkDidChangeState(_ state: KISSLinkState)

    /// Called when the link encounters an error
    func linkDidError(_ message: String)
}

// MARK: - KISSLink Protocol

/// Abstraction for a KISS byte stream transport.
///
/// Concrete implementations:
/// - `KISSLinkNetwork`: TCP connection via Network.framework
/// - `KISSLinkSerial`: USB serial via POSIX file descriptors
protocol KISSLink: AnyObject {
    /// Current connection state
    var state: KISSLinkState { get }

    /// Human-readable description of the endpoint (e.g. "localhost:8001" or "/dev/cu.usbmodem1234")
    var endpointDescription: String { get }

    /// Delegate for receiving data and state changes
    var delegate: KISSLinkDelegate? { get set }

    /// Open the connection
    func open()

    /// Close the connection
    func close()

    /// Send raw bytes (already KISS-framed)
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
}

// MARK: - KISSLink Logger

/// Shared structured logging for KISSLink transports
nonisolated enum KISSLinkLog {
    private static let logger = Logger(subsystem: "com.rosswardrup.AXTerm", category: "KISSLink")

    static func opened(_ endpoint: String) {
        logger.info("Link opened: \(endpoint, privacy: .public)")
    }

    static func closed(_ endpoint: String, reason: String) {
        logger.info("Link closed: \(endpoint, privacy: .public) reason=\(reason, privacy: .public)")
    }

    static func stateChange(_ endpoint: String, from: KISSLinkState, to: KISSLinkState) {
        logger.debug("Link state: \(endpoint, privacy: .public) \(from.rawValue, privacy: .public) → \(to.rawValue, privacy: .public)")
    }

    static func bytesIn(_ endpoint: String, count: Int) {
        logger.debug("Link RX: \(endpoint, privacy: .public) \(count) bytes")
    }

    static func bytesOut(_ endpoint: String, count: Int) {
        logger.debug("Link TX: \(endpoint, privacy: .public) \(count) bytes")
    }

    static func error(_ endpoint: String, message: String) {
        logger.error("Link error: \(endpoint, privacy: .public) \(message, privacy: .public)")
    }

    static func reconnect(_ endpoint: String, attempt: Int) {
        logger.info("Link reconnect: \(endpoint, privacy: .public) attempt #\(attempt)")
    }

    static func frameDecodeError(_ endpoint: String, reason: String) {
        logger.warning("Link frame decode error: \(endpoint, privacy: .public) \(reason, privacy: .public)")
    }
}
