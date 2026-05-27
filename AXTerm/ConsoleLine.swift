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

    var timestampString: String {
        Self.timeFormatter.string(from: timestamp)
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

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

        // Detect BBS/node prompts and session messages (not the interesting data)
        if isPromptOrSessionMessage(normalizedText) {
            return .prompt
        }

        // If it has substantial content and isn't a prompt, it's likely actual data
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
            return .data
        }

        return .message
    }

    /// Check if the text is a BBS/node prompt or session protocol message.
    /// Conservative by design: when in doubt, let the line through as data.
    /// Better to show a noisy prompt than to hide content the user needs to see.
    private static func isPromptOrSessionMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Bare callsign / node prompt: "DRLNOD>", "KB5YZB-7>", "BBS>", "NOS>"
        // Prefix must be callsign-safe characters only (letters, digits, dashes — no spaces).
        // Excludes "de KB5YZB>" (BBS sign-off), "73 de W6ABC>" (farewell), etc.
        if trimmed.hasSuffix(">") {
            let prefix = trimmed.dropLast()
            if !prefix.isEmpty && prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                return true
            }
        }

        // Exact-match known prompts only — heuristics are too risky.
        // "From:", "To:", "Via:", "Date:", "DE", "73", "OK" are all valid BBS content
        // and must not be swallowed. Add entries here as new systems are encountered.
        let exactPrompts: Set<String> = [
            // Colon-terminated command prompts (PBBS, AA4RE, W0RLI, FBB, etc.)
            "CMD:", "BBS:", "[CMD]:", "[FBB]:",
            // Bracket-wrapped node prompts (FBB / European systems)
            "[FBB]>", "[CMD]>",
        ]
        if exactPrompts.contains(trimmed) {
            return true
        }

        // NET/ROM and node session event lines (e.g. "###LINK MADE TO ...", "###DISCONNECTED")
        if trimmed.hasPrefix("###") {
            return true
        }

        // Known multi-word prompt prefixes
        let promptPrefixes: [String] = [
            "ENTER COMMAND",
            "ENTER CMD",
        ]
        for pattern in promptPrefixes where trimmed.hasPrefix(pattern) {
            return true
        }

        return false
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
