//
//  PacketClassifier.swift
//  AXTerm
//
//  Classifies AX.25 packets based on decoded control fields for routing,
//  quality estimation, and UI display.
//
//  Classification determines how packets affect:
//  - Routing freshness (should neighbor/route timestamps refresh?)
//  - Link quality metrics (does this evidence indicate link health?)
//  - UI display (what badge/description to show?)
//

import Foundation

/// Classification of an AX.25 packet based on its control field semantics.
enum PacketClassification: String, Codable, Hashable, Sendable {
    /// I-frame carrying new data or routing information.
    /// High-value evidence for routing freshness and link quality.
    case dataProgress

    /// Supervisory frame (RR/RNR) without payload.
    /// Indicates link is operational but doesn't carry new data.
    /// Should NOT refresh routing timestamps (only acknowledges).
    case ackOnly

    /// Evidence of retransmission: REJ/SREJ frames, or detected duplicate I-frames.
    /// Indicates link quality issues - should penalize quality estimates.
    case retryOrDuplicate

    /// UI frame used for beacons, position reports, etc.
    /// Weak evidence for routing (one-way, no acknowledgement).
    case uiBeacon

    /// NET/ROM routing broadcast (PID 0xCF to NODES).
    /// Strong evidence for routing table updates.
    case routingBroadcast

    /// Session control frames: SABM, SABME, UA, DISC, DM, FRMR.
    /// Indicates session state changes, not data transfer.
    case sessionControl

    /// Unknown or unclassified frame type.
    case unknown

    // MARK: - Display Properties

    /// Short badge text for UI display
    var badge: String {
        switch self {
        case .dataProgress: return "DATA"
        case .ackOnly: return "ACK"
        case .retryOrDuplicate: return "RETRY"
        case .uiBeacon: return "BEACON"
        case .routingBroadcast: return "ROUTE"
        case .sessionControl: return "CTRL"
        case .unknown: return "—"
        }
    }

    /// Human-readable tooltip/description (Apple HIG friendly - no jargon)
    var tooltip: String {
        switch self {
        case .dataProgress:
            return "DATA — A data frame carrying information between stations."
        case .ackOnly:
            return "ACK — An acknowledgement frame confirming reception. Does not carry new data."
        case .retryOrDuplicate:
            return "RETRY — A retransmission or duplicate frame, indicating possible link issues."
        case .uiBeacon:
            return "BEACON — A beacon or broadcast frame, typically position reports or status."
        case .routingBroadcast:
            return "ROUTE — A routing update sharing network topology information."
        case .sessionControl:
            return "CTRL — A session management frame (connect, disconnect, or error)."
        case .unknown:
            return "— — Frame type could not be determined."
        }
    }

    /// Whether this classification should refresh neighbor timestamps by default.
    /// Route-level refresh is handled separately to allow policy overrides.
    var refreshesNeighbor: Bool {
        switch self {
        case .dataProgress:
            return true
        case .uiBeacon:
            return true  // Weak refresh - configurable in routing layer
        case .routingBroadcast:
            return false // Policy may allow for direct evidence
        case .ackOnly, .retryOrDuplicate, .sessionControl, .unknown:
            return false
        }
    }

    /// Whether this classification should refresh route timestamps by default.
    var refreshesRoute: Bool {
        switch self {
        case .dataProgress, .routingBroadcast:
            return true
        case .uiBeacon:
            return false // Weak refresh disabled by default (policy may enable)
        case .ackOnly, .retryOrDuplicate, .sessionControl, .unknown:
            return false
        }
    }

    /// Weight for forward delivery evidence (0.0 = ignore, 1.0 = full weight)
    var forwardEvidenceWeight: Double {
        switch self {
        case .dataProgress: return 1.0
        case .routingBroadcast: return 0.8
        case .uiBeacon: return 0.4
        case .ackOnly: return 0.0
        case .sessionControl: return 0.0
        case .retryOrDuplicate: return 0.0
        case .unknown: return 0.0
        }
    }

    /// Weight for reverse delivery evidence (ACK-based).
    var reverseEvidenceWeight: Double {
        switch self {
        case .ackOnly: return 0.3
        case .dataProgress: return 0.0
        case .routingBroadcast: return 0.0
        case .uiBeacon: return 0.0
        case .sessionControl: return 0.0
        case .retryOrDuplicate: return 0.0
        case .unknown: return 0.0
        }
    }
}

/// Pure function classifier for AX.25 packets based on decoded control fields.
enum PacketClassifier {

    /// Classify a packet based on its control field semantics.
    ///
    /// - Parameter packet: The packet to classify
    /// - Returns: Classification for routing/quality/UI purposes
    static func classify(packet: Packet) -> PacketClassification {
        classify(packet: packet, previousPackets: [])
    }

    /// Classify a packet, considering previous packets for retry detection.
    ///
    /// - Parameters:
    ///   - packet: The packet to classify
    ///   - previousPackets: Recent packets for retry/duplicate detection
    /// - Returns: Classification for routing/quality/UI purposes
    static func classify(packet: Packet, previousPackets: [Packet]) -> PacketClassification {
        let decoded = packet.controlFieldDecoded

        // Check for NET/ROM routing broadcast first (highest priority for routing)
        if isNetRomBroadcast(packet) {
            return .routingBroadcast
        }

        // Check for retry/duplicate using previous packets
        if isRetryOrDuplicate(packet: packet, previousPackets: previousPackets, decoded: decoded) {
            return .retryOrDuplicate
        }

        // Classify based on frame class
        switch decoded.frameClass {
        case .I:
            return classifyIFrame(packet: packet, decoded: decoded)

        case .S:
            return classifySFrame(decoded: decoded)

        case .U:
            return classifyUFrame(packet: packet, decoded: decoded)

        case .unknown:
            // Fallback to declared frameType when control bytes are incomplete.
            switch packet.frameType {
            case .i:
                return .dataProgress
            case .s:
                return classifySFrame(decoded: decoded)
            case .u, .ui:
                return .uiBeacon
            case .unknown:
                return .unknown
            }
        }
    }

    // MARK: - Frame Class Classification

    /// Classify an I-frame (Information frame)
    private static func classifyIFrame(packet: Packet, decoded: AX25ControlFieldDecoded) -> PacketClassification {
        // I-frames always carry sequence progress - they're meaningful data
        return .dataProgress
    }

    /// Classify an S-frame (Supervisory frame)
    private static func classifySFrame(decoded: AX25ControlFieldDecoded) -> PacketClassification {
        guard let sType = decoded.sType else {
            return .unknown
        }

        switch sType {
        case .RR, .RNR:
            // Receive Ready / Receive Not Ready - acknowledgement only
            return .ackOnly

        case .REJ, .SREJ:
            // Reject / Selective Reject - indicates retry needed
            return .retryOrDuplicate
        }
    }

    /// Classify a U-frame (Unnumbered frame)
    private static func classifyUFrame(packet: Packet, decoded: AX25ControlFieldDecoded) -> PacketClassification {
        guard let uType = decoded.uType else {
            return .unknown
        }

        switch uType {
        case .UI:
            // UI frames are typically beacons or broadcasts
            return .uiBeacon

        case .SABM, .SABME, .DISC, .UA, .DM, .FRMR:
            // Session control frames
            return .sessionControl

        case .UNKNOWN:
            return .unknown
        }
    }

    // MARK: - Special Detection

    /// Check if packet is a NET/ROM routing broadcast
    private static func isNetRomBroadcast(_ packet: Packet) -> Bool {
        // NET/ROM broadcasts are UI frames with PID=0xCF to destination "NODES"
        guard packet.frameType == .ui else { return false }
        guard let pid = packet.pid, pid == NetRomBroadcastParser.netromPID else { return false }
        guard let toCall = packet.to?.call.uppercased(), toCall == "NODES" else { return false }

        // Verify it has the signature byte
        guard packet.info.count >= 1, packet.info[0] == 0xFF else { return false }

        return true
    }

    /// Check if packet is a retry/duplicate based on N(S) reuse
    private static func isRetryOrDuplicate(
        packet: Packet,
        previousPackets: [Packet],
        decoded: AX25ControlFieldDecoded
    ) -> Bool {
        // Only I-frames have N(S) for retry detection
        guard decoded.frameClass == .I,
              let ns = decoded.ns else {
            return false
        }

        // Get packet identifiers
        guard let fromCall = packet.from?.call,
              let toCall = packet.to?.call else {
            return false
        }

        // Compute payload hash for comparison
        let payloadHash = packet.info.hashValue

        // Check previous packets for matching N(S), src, dst, and payload
        for prev in previousPackets {
            let prevDecoded = prev.controlFieldDecoded
            guard prevDecoded.frameClass == .I,
                  let prevNs = prevDecoded.ns else {
                continue
            }

            // Check for same source and destination
            guard prev.from?.call == fromCall,
                  prev.to?.call == toCall else {
                continue
            }

            // Check for same N(S) and same payload
            if prevNs == ns && prev.info.hashValue == payloadHash {
                return true
            }
        }

        return false
    }
}

// MARK: - Packet Extension

extension Packet {
    /// Get the classification for this packet
    var classification: PacketClassification {
        PacketClassifier.classify(packet: self)
    }
}
