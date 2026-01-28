//
//  ConsoleLine.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a line in the console view
struct ConsoleLine: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case system
        case error
        case packet
    }

    let id: UUID
    let kind: Kind
    let timestamp: Date
    let from: String?
    let to: String?
    let text: String

    init(
        id: UUID = UUID(),
        kind: Kind = .packet,
        timestamp: Date = Date(),
        from: String? = nil,
        to: String? = nil,
        text: String
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.text = text
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

    static func packet(from: String, to: String, text: String, timestamp: Date = Date()) -> ConsoleLine {
        ConsoleLine(kind: .packet, timestamp: timestamp, from: from, to: to, text: text)
    }
}
