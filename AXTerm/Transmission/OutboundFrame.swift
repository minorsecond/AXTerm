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
            let trimmed = call.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let repeated = trimmed.hasSuffix("*")
            let clean = repeated ? String(trimmed.dropLast()) : trimmed
            guard !clean.isEmpty else { return nil }

            let parts = clean.split(separator: "-")
            let callsign = String(parts[0])
            let ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return AX25Address(call: callsign, ssid: ssid, repeated: repeated)
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

    /// True when payload is user terminal data (chat); console shows as DATA (purple) not SYS
    let isUserPayload: Bool

    /// Explicit control byte (for U-frames, S-frames, I-frames)
    /// If nil, defaults to 0x03 (UI frame) for backwards compatibility
    let controlByte: UInt8?

    /// N(S) - Send sequence number for I-frames (0-7 for mod 8, 0-127 for mod 128)
    let ns: Int?

    /// N(R) - Receive sequence number for I-frames and S-frames
    let nr: Int?

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
        controlByte: UInt8? = nil,
        ns: Int? = nil,
        nr: Int? = nil,
        displayInfo: String? = nil,
        isUserPayload: Bool = false
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
        self.controlByte = controlByte
        self.ns = ns
        self.nr = nr
        self.displayInfo = displayInfo
        self.isUserPayload = isUserPayload
    }

    private enum CodingKeys: String, CodingKey {
        case id, channel, destination, source, path, createdAt, payload, priority
        case frameType, pid, sessionId, axdpMessageId, displayInfo, isUserPayload
        case controlByte, ns, nr
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        channel = try c.decode(UInt8.self, forKey: .channel)
        destination = try c.decode(AX25Address.self, forKey: .destination)
        source = try c.decode(AX25Address.self, forKey: .source)
        path = try c.decode(DigiPath.self, forKey: .path)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        payload = try c.decode(Data.self, forKey: .payload)
        priority = try c.decode(TxPriority.self, forKey: .priority)
        frameType = try c.decode(String.self, forKey: .frameType)
        pid = try c.decodeIfPresent(UInt8.self, forKey: .pid)
        sessionId = try c.decodeIfPresent(UUID.self, forKey: .sessionId)
        axdpMessageId = try c.decodeIfPresent(UInt32.self, forKey: .axdpMessageId)
        displayInfo = try c.decodeIfPresent(String.self, forKey: .displayInfo)
        isUserPayload = try c.decodeIfPresent(Bool.self, forKey: .isUserPayload) ?? false
        controlByte = try c.decodeIfPresent(UInt8.self, forKey: .controlByte)
        ns = try c.decodeIfPresent(Int.self, forKey: .ns)
        nr = try c.decodeIfPresent(Int.self, forKey: .nr)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(channel, forKey: .channel)
        try c.encode(destination, forKey: .destination)
        try c.encode(source, forKey: .source)
        try c.encode(path, forKey: .path)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(payload, forKey: .payload)
        try c.encode(priority, forKey: .priority)
        try c.encode(frameType, forKey: .frameType)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(axdpMessageId, forKey: .axdpMessageId)
        try c.encodeIfPresent(displayInfo, forKey: .displayInfo)
        try c.encode(isUserPayload, forKey: .isUserPayload)
        try c.encodeIfPresent(controlByte, forKey: .controlByte)
        try c.encodeIfPresent(ns, forKey: .ns)
        try c.encodeIfPresent(nr, forKey: .nr)
    }

    /// Encode as raw AX.25 frame bytes (for KISS transport)
    func encodeAX25() -> Data {
        var data = Data()

        // Destination address (7 bytes)
        // Destination is never last - source always follows
        data.append(destination.encodeForAX25(isLast: false))

        // Source address (7 bytes)
        // Source has command/response bit set, last if no digipeaters
        data.append(source.encodeForAX25(isLast: path.isEmpty))

        // Digipeater addresses (7 bytes each)
        for (index, digi) in path.digis.enumerated() {
            let isLastDigi = index == path.digis.count - 1
            data.append(digi.encodeForAX25(isLast: isLastDigi))
        }

        // Control field
        // Use explicit controlByte if provided, otherwise default to UI (0x03)
        let control = controlByte ?? 0x03
        data.append(control)

        // PID (protocol identifier) - only for UI and I frames
        // U-frames (except UI) and S-frames don't have PID
        let frameClass = frameType.lowercased()
        if frameClass == "ui" || frameClass == "i" {
            if let pid = pid {
                data.append(pid)
            }
        }

        // Info field (payload) - only for UI and I frames
        // S-frames and most U-frames have no info field
        if frameClass == "ui" || frameClass == "i" {
            data.append(payload)
        }

        return data
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

    /// Order in which this entry was enqueued (for FIFO within priority)
    var enqueueOrder: UInt64 = 0

    var id: UUID { frame.id }

    init(frame: OutboundFrame) {
        self.frame = frame
        self.state = TxFrameState(frameId: frame.id)
    }
}
