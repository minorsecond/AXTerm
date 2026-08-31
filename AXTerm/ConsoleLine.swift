//
//  ConsoleLine.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a line in the console view
nonisolated struct ConsoleLine: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case system
        case error
        case packet
    }

    /// Message type for packet-based console lines
    enum MessageType: String, Hashable, Sendable {
        case id       // Station identification
        case beacon   // Beacon message
        case mail     // Mail notification
        case data     // Actual content/data being transferred (the interesting stuff)
        case prompt   // BBS/node prompts and session protocol messages
        case message  // Fallback for unclassified messages
    }

    let id: UUID
    let kind: Kind
    let timestamp: Date
    let from: String?
    let to: String?
    let text: String
    /// Digipeater path (if any)
    let via: [String]
    /// Message type for packets (nil for system/error lines)
    let messageType: MessageType?
    /// Signature for duplicate detection (from+to+normalized_text)
    let contentSignature: String?
    /// Whether this is a duplicate of a recently seen packet (received via different path)
    let isDuplicate: Bool

    init(
        id: UUID = UUID(),
        kind: Kind = .packet,
        timestamp: Date = Date(),
        from: String? = nil,
        to: String? = nil,
        text: String,
        via: [String] = [],
        messageType: MessageType? = nil,
        isDuplicate: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.text = text
        self.via = via
        self.isDuplicate = isDuplicate

        // Auto-detect message type for packets if not explicitly provided
        if let messageType = messageType {
            self.messageType = messageType
        } else if kind == .packet {
            // Detect message type even if 'to' is nil (use empty string as fallback)
            self.messageType = Self.detectMessageType(text: text, to: to ?? "")
        } else {
            self.messageType = nil
        }

        // Compute content signature for duplicate detection
        if kind == .packet, let from = from, let to = to {
            let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.contentSignature = "\(from.uppercased())|\(to.uppercased())|\(normalizedText)"
        } else {
            self.contentSignature = nil
        }
    }

    // MARK: - Formatting Helpers

    /// Whether this station is one of the three parties to the line: sender,
    /// addressee, or a digipeater that carried it.
    ///
    /// Matched on the base callsign, so every SSID this operator runs counts
    /// — K0EPI-7 on the terminal and K0EPI-10 on Winlink are the same person
    /// at the same desk, and a filter that showed one and hid the other would
    /// be a worse answer to "what am I doing" than no filter.
    ///
    /// Deliberately looser than `CoverageEstimate`, which matches the full
    /// address because it is making a measurement claim about one
    /// transmitter. This only decides what to draw.
    func involvesStation(_ callsign: String) -> Bool {
        let base = Self.base(of: callsign)
        guard !base.isEmpty else { return false }
        if let from, Self.base(of: from) == base { return true }
        if let to, Self.base(of: to) == base { return true }
        // A frame we digipeated went out of our transmitter, whoever it was
        // addressed to.
        return via.contains { Self.base(of: $0) == base }
    }

    /// Callsign without SSID or the `*` has-been-repeated marker.
    private static func base(of address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespaces).uppercased()
        while text.hasSuffix("*") { text.removeLast() }
        return String(text.split(separator: "-").first ?? "")
    }

    /// True when the line was heard as a digipeated copy (any via marked `*` —
    /// the H bit was set, so what we heard was the digipeater's transmitter).
    var heardViaDigipeater: Bool {
        via.contains { $0.hasSuffix("*") }
    }

    /// The digipeaters that actually repeated this frame (H-bit set), without
    /// the `*` marker — e.g. ["DRLNOD"] for a copy heard off DRLNOD's
    /// transmitter. Empty for TX-time lines and direct frames.
    var repeatedDigis: [String] {
        via.filter { $0.hasSuffix("*") }.map { String($0.dropLast()) }
    }

    /// Why this copy reached us — when it did not reach us directly.
    ///
    /// Hearing a station's own transmitter and hearing a digipeater repeat it
    /// are different facts, and for a beacon they arrive as two rows a second
    /// apart with identical text. Without this the operator cannot tell "I
    /// hear KB5YZB-7" from "DRLNOD hears KB5YZB-7", which is most of what a
    /// beacon is for (2026-08-31).
    enum RepeatAttribution: Equatable, Sendable {
        /// Someone else's frame, reaching us off a digipeater's transmitter.
        case heardVia([String])
        /// Our own frame coming back. Carries no new content — the transmit
        /// line already showed it — but proves the digi relayed us.
        case ourFrameEchoed([String])

        var digis: [String] {
            switch self {
            case let .heardVia(digis), let .ourFrameEchoed(digis): return digis
            }
        }
    }

    /// Nil when the frame reached us directly, which needs no explanation.
    func repeatAttribution(localCallsign: String) -> RepeatAttribution? {
        let digis = repeatedDigis
        guard !digis.isEmpty else { return nil }
        return isDigipeatEcho(localCallsign: localCallsign)
            ? .ourFrameEchoed(digis)
            : .heardVia(digis)
    }

    /// True when this line is a digipeated copy of the local station's own
    /// transmission — the digi repeating our frame back at us. These carry no
    /// new content (the TX-time line already shows the frame), but seeing them
    /// confirms the digipeater actually relayed us.
    func isDigipeatEcho(localCallsign: String) -> Bool {
        guard heardViaDigipeater, let from else { return false }
        let local = CallsignValidator.normalize(localCallsign)
        guard !local.isEmpty else { return false }
        return CallsignValidator.normalize(from) == local
    }

    var timestampString: String {
        TimeDisplay.timeString(timestamp)
    }

    var formattedLine: String {
        var parts: [String] = [timestampString]
        if let from = from {
            if let to = to {
                parts.append("\(from)>\(to):")
            } else {
                parts.append("\(from):")
            }
        }
        parts.append(text)
        return parts.joined(separator: " ")
    }

    // MARK: - Convenience Initializers

    static func system(_ text: String) -> ConsoleLine {
        ConsoleLine(kind: .system, text: text)
    }

    static func error(_ text: String) -> ConsoleLine {
        ConsoleLine(kind: .error, text: text)
    }

    static func packet(
        from: String,
        to: String,
        text: String,
        timestamp: Date = Date(),
        via: [String] = [],
        isDuplicate: Bool = false,
        messageType: MessageType? = nil
    ) -> ConsoleLine {
        let detectedType = messageType ?? detectMessageType(text: text, to: to)
        // Normalize via path for console display so repeated digis like
        // "W0ARP-7,W0ARP-7*" collapse to a single "W0ARP-7*" entry. This keeps
        // the console, tests, and packet model consistent.
        let normalizedVia = normalizedViaItems(from: via)
        return ConsoleLine(
            kind: .packet,
            timestamp: timestamp,
            from: from,
            to: to,
            text: text,
            via: normalizedVia,
            messageType: detectedType,
            isDuplicate: isDuplicate
        )
    }

    /// Detect message type from packet text content and destination
    private static func detectMessageType(text: String, to: String) -> MessageType {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedTo = to.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // ID messages: destination is "ID", or text starts with "ID", "ID ...", "ID:..."
        if normalizedTo == "ID" || normalizedText == "ID" || normalizedText.hasPrefix("ID ") || normalizedText.hasPrefix("ID:") {
            return .id
        }

        // CQ broadcasts: destination is usually "CQ", or text is CQ
        if normalizedTo == "CQ" || normalizedText == "CQ" || normalizedText.hasPrefix("CQ ") {
            return .data
        }

        // Beacon messages: destination is "BEACON" or text starts with "BEACON"
        if normalizedTo == "BEACON" || normalizedText.hasPrefix("BEACON") {
            return .beacon
        }

        // Mail messages: "Mail for:", "MAIL:", etc.
        if normalizedText.hasPrefix("MAIL FOR:") || normalizedText.hasPrefix("MAIL:") || normalizedText.hasPrefix("MAIL ") {
            return .mail
        }

        // If it has substantial content, it's likely actual data
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
            return .data
        }

        return .message
    }

    /// Display string for the via path
    var viaDisplay: String {
        Self.normalizedViaItems(from: via).joined(separator: ",")
    }

    private static func normalizedViaItems(from via: [String]) -> [String] {
        guard !via.isEmpty else { return [] }

        var order: [String] = []
        var displayByKey: [String: String] = [:]
        var repeatedByKey: [String: Bool] = [:]

        for item in via {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let isRepeated = trimmed.hasSuffix("*")
            let base = isRepeated ? String(trimmed.dropLast()) : trimmed
            let key = base.uppercased()

            if displayByKey[key] == nil {
                displayByKey[key] = base
                order.append(key)
            }
            if isRepeated {
                repeatedByKey[key] = true
            }
        }

        return order.compactMap { key in
            guard let display = displayByKey[key] else { return nil }
            return (repeatedByKey[key] ?? false) ? "\(display)*" : display
        }
    }
}
