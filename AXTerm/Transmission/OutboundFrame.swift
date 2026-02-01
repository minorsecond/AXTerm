//
//  OutboundFrame.swift
//  AXTerm
//
//  TX queue model for outbound frames.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 11.1
//

import Foundation

/// Priority levels for TX queue ordering
/// Higher values = higher priority (processed first)
enum TxPriority: Int, Codable, Comparable {
    case bulk = 10          // File transfers, bulk sync
    case normal = 50        // Standard messages
    case interactive = 100  // Chat, session control

    static func < (lhs: TxPriority, rhs: TxPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Digipeater path for routing
struct DigiPath: Codable, Hashable, Sendable {
    let digis: [AX25Address]

    init(_ digis: [AX25Address] = []) {
        // Limit to 8 digipeaters per AX.25 spec
        self.digis = Array(digis.prefix(8))
    }

    /// Create a path from callsign strings (e.g., "WIDE1-1", "WIDE2-1")
    static func from(_ calls: [String]) -> DigiPath {
        let addresses = calls.compactMap { call -> AX25Address? in
            let parts = call.split(separator: "-")
            let callsign = String(parts[0])
            let ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return AX25Address(call: callsign, ssid: ssid)
        }
        return DigiPath(addresses)
    }

    var isEmpty: Bool { digis.isEmpty }
    var count: Int { digis.count }

    /// String representation for display
    var display: String {
        digis.map { $0.display }.joined(separator: ",")
    }
}

/// Status of an outbound frame in the TX queue
enum TxFrameStatus: String, Codable {
    case queued         // Waiting to be sent
    case sending        // Currently being transmitted
    case sent           // Sent to TNC (no ack expected or received)
    case awaitingAck    // Sent, waiting for acknowledgment
    case acked          // Acknowledged successfully
    case failed         // Max retries exceeded or error
    case cancelled      // Removed from queue before sending
}

/// An outbound frame queued for transmission
/// Immutable once created; status tracked separately
struct OutboundFrame: Identifiable, Codable, Sendable {
    let id: UUID
    let channel: UInt8
    let destination: AX25Address
    let source: AX25Address
    let path: DigiPath
    let createdAt: Date
    let payload: Data
    let priority: TxPriority

    /// Frame type (ui, i, s, u) for tracking
    let frameType: String

    /// Protocol ID (for UI/I frames)
    let pid: UInt8?

    /// Session ID if part of a connected session
    let sessionId: UUID?

    /// AXDP message ID if this is an AXDP message
    let axdpMessageId: UInt32?

    /// Human-readable description for UI display
    let displayInfo: String?

    init(
        id: UUID = UUID(),
        channel: UInt8 = 0,
        destination: AX25Address,
        source: AX25Address,
        path: DigiPath = DigiPath(),
        createdAt: Date = Date(),
        payload: Data,
        priority: TxPriority = .normal,
        frameType: String = "ui",
        pid: UInt8? = 0xF0,
        sessionId: UUID? = nil,
        axdpMessageId: UInt32? = nil,
        displayInfo: String? = nil
    ) {
        self.id = id
        self.channel = channel
        self.destination = destination
        self.source = source
        self.path = path
        self.createdAt = createdAt
        self.payload = payload
        self.priority = priority
        self.frameType = frameType
        self.pid = pid
        self.sessionId = sessionId
        self.axdpMessageId = axdpMessageId
        self.displayInfo = displayInfo
    }
}

/// Tracks the transmission state of an OutboundFrame
struct TxFrameState: Identifiable, Codable {
    let frameId: UUID
    var status: TxFrameStatus
    var attempts: Int
    var lastAttemptAt: Date?
    var sentAt: Date?
    var ackedAt: Date?
    var errorMessage: String?

    var id: UUID { frameId }

    init(frameId: UUID) {
        self.frameId = frameId
        self.status = .queued
        self.attempts = 0
        self.lastAttemptAt = nil
        self.sentAt = nil
        self.ackedAt = nil
        self.errorMessage = nil
    }

    /// Mark frame as being sent
    mutating func markSending() {
        status = .sending
        attempts += 1
        lastAttemptAt = Date()
    }

    /// Mark frame as sent (to TNC)
    mutating func markSent() {
        status = .sent
        sentAt = Date()
    }

    /// Mark frame as awaiting acknowledgment
    mutating func markAwaitingAck() {
        status = .awaitingAck
    }

    /// Mark frame as acknowledged
    mutating func markAcked() {
        status = .acked
        ackedAt = Date()
    }

    /// Mark frame as failed
    mutating func markFailed(reason: String) {
        status = .failed
        errorMessage = reason
    }

    /// Mark frame as cancelled
    mutating func markCancelled() {
        status = .cancelled
    }
}

// MARK: - TX Queue Entry (combines frame + state)

/// Complete entry in the TX queue for display and processing
struct TxQueueEntry: Identifiable {
    let frame: OutboundFrame
    var state: TxFrameState

    var id: UUID { frame.id }

    init(frame: OutboundFrame) {
        self.frame = frame
        self.state = TxFrameState(frameId: frame.id)
    }
}
