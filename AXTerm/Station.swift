//
//  Station.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a heard station for MHeard tracking
struct Station: Identifiable, Hashable {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    let call: String
    var lastHeard: Date?
    var heardCount: Int
    var lastVia: [String]

    var id: String { call }

    init(call: String, lastHeard: Date? = nil, heardCount: Int = 0, lastVia: [String] = []) {
        self.call = call
        self.lastHeard = lastHeard
        self.heardCount = heardCount
        self.lastVia = lastVia
    }

    var subtitle: String {
        var parts: [String] = []
        parts.append("\(heardCount) pkt\(heardCount == 1 ? "" : "s")")
        if let date = lastHeard {
            parts.append(Self.timeFormatter.string(from: date))
        }
        return parts.joined(separator: " | ")
    }

    var lastViaDisplay: String {
        guard !lastVia.isEmpty else { return "" }
        return lastVia.joined(separator: ", ")
    }
}
