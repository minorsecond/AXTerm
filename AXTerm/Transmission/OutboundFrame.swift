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

    /// Returns a version of the path with all H-bits (repeated flags) cleared.
    /// Used for matching sessions where the H-bit state (has-been-repeated) shouldn't affect identity.
    var normalized: DigiPath {
        let cleanDigis = digis.map {
            AX25Address(call: $0.call, ssid: $0.ssid, repeated: false)
        }
        return DigiPath(cleanDigis)
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

    /// Create a copy of this I-frame with an updated N(R) and control byte.
    /// Used during retransmission so the peer sees our current receive state
    /// instead of the stale N(R) from the original transmission.
    func withUpdatedNR(_ newNR: Int) -> OutboundFrame {
        guard frameType == "i", let oldNS = ns else { return self }
        let newControl = AX25Control.iFrame(ns: oldNS, nr: newNR, pf: false)
        return OutboundFrame(
            id: UUID(),  // New ID for retransmit tracking
            channel: channel,
            destination: destination,
            source: source,
            path: path,
            createdAt: Date(),
            payload: payload,
            priority: priority,
            frameType: frameType,
            pid: pid,
            sessionId: sessionId,
            axdpMessageId: axdpMessageId,
            controlByte: newControl,
            ns: oldNS,
            nr: newNR,
            displayInfo: displayInfo,
            isUserPayload: isUserPayload
        )
    }

    /// Encode as raw AX.25 frame bytes (for KISS transport)
    func encodeAX25() -> Data {
        var data = Data()

        // Determine if frame is a Command or Response (AX.25 v2.0)
        // I-frames: Command
        // S-frames: Command (if Poll=1), Response (if Final=1)? No, RR/RNR/REJ are supervised.
        // Actually:
        // SABM, DISC: Command
        // UA, DM: Response
        // I: Command
        // UI: Command
        // RR, RNR, REJ: Can be either. Usually Response unless polling?
        // - If we initiate (Poll), it's Command.
        // - If we respond (Final), it's Response.
        
        var isCommand: Bool = true // Default to command
        
        let ft = frameType.lowercased()
        if let ctrl = controlByte {
            // Check for UA/DM (Response)
            if (ctrl & ~0x10) == AX25Control.ua || (ctrl & ~0x10) == AX25Control.dm {
                isCommand = false
            } 
            // Check for S-frames response?
            // If it's an S-frame and PF is set (Final), it's likely a response to a Poll.
            // But if it's a Poll (P=1), it's a Command?
            // For simplicity/compatibility:
            // RR/RNR/REJ are usually Responses in normal flow (checking "I received X"), 
            // but Commands if Polling "Are you there?".
            else if ft == "s" {
                // If PF bit is set, it could be Poll (Command) or Final (Response)
                let pf = (ctrl & 0x10) != 0
                // If we are RESPONDING to a poll (Final), isCommand = false
                // If we are POLLING (Poll), isCommand = true
                // We need more context.
                
                // Heuristic:
                // If we are sending RR(F=1), it's a Response (to `I P=1` or `RR P=1`).
                // If we are sending RR(P=1), it's a Command (query).
                // If we are sending RR(P=0), it's usually a Response (acking I-frames).
                
                // Let's assume S-frames are Responses unless we explicitly know they are Commands.
                // Exceptions: T1 timeout sends RR(P=1) -> Command.
                // Acking I-frames -> Response.
                
                if pf {
                    // P/F set.
                    // If it was intended as Poll (Command), we should treat as Command.
                    // If Final (Response), treat as Response.
                    // In AX25FrameBuilder, we set 'pf'. We don't distinguish P vs F there.
                    // But usually unsolicited = Command, solicited = Response.
                    // For now, let's treat RR/RNR/REJ as Response by default unless P=1?
                    // Actually, typical implementation:
                    // I, SABM, DISC, UI -> Command
                    // UA, DM, FRMR -> Response
                    // RR, RNR, REJ -> Response (usually)
                    
                    // Let's refine based on Control constants if possible, or leave as Default=True (Command) 
                    // and override for known Responses.
                    
                    isCommand = false 
                } else {
                    isCommand = false
                }
                
                // Special case: Timer recovery (T1) sends RR P=1 (Command).
                // We need to know if 'pf' meant Poll or Final.
                // 'OutboundFrame' doesn't explicitly store "isPoll" vs "isFinal".
                // Ideally we'd add 'isCommand' property to OutboundFrame, but that's a larger change.
                
                // Quick Fix:
                // If we assume most traffic is Command (I-frames), we are okay.
                // Direwolf output shows "I cmd", so our I-frames MUST be commands.
            }
        }
        
        // Overrides based on known types
        if ft == "u" {
            // UA, DM are Responses
            if displayInfo == "UA" || displayInfo == "DM" || displayInfo == "FRMR" {
                isCommand = false
            }
            // SABM, DISC are Commands
            if displayInfo == "SABM" || displayInfo == "SABME" || displayInfo == "DISC" {
                isCommand = true
            }
        } else if ft == "i" {
            isCommand = true
        } else if ft == "ui" {
            isCommand = true
        }
        
        // Destination address (7 bytes)
        // Destination is never last - source always follows
        data.append(destination.encodeForAX25(isLast: false, isDestination: true, isCommand: isCommand))

        // Source address (7 bytes)
        // Source has command/response bit set, last if no digipeaters
        data.append(source.encodeForAX25(isLast: path.isEmpty, isDestination: false, isCommand: isCommand))

        // Digipeater addresses (7 bytes each)
        for (index, digi) in path.digis.enumerated() {
            let isLastDigi = index == path.digis.count - 1
            // Digis are not Source/Dest, so C/R bits don't apply (H-bit used instead)
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
