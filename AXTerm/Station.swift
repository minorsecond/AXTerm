//
//  Station.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a heard station for MHeard tracking
nonisolated struct Station: Identifiable, Hashable {

    let call: String
    var lastHeard: Date?
    /// Frames counted this session, from the capped in-memory list.
    var heardCount: Int
    /// Frames in the whole log, when it has been consulted.
    ///
    /// Separate from `heardCount` rather than replacing it, because the two
    /// answer different questions and a rebuild from the in-memory packets
    /// would otherwise wipe the lifetime figure every time history loaded.
    var lifetimeCount: Int?

    /// What to show an operator asking how much this station has been heard.
    var displayedCount: Int { max(lifetimeCount ?? 0, heardCount) }
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
        // The whole log where it is known. The in-memory list is capped at
        // 5,000 frames, so on a busy channel this row was counting the last
        // few hours and reading as a total.
        let shown = displayedCount
        parts.append("\(shown.formatted()) pkt\(shown == 1 ? "" : "s")")
        if let date = lastHeard {
            parts.append(TimeDisplay.timeString(date))
        }
        return parts.joined(separator: " | ")
    }

    var lastViaDisplay: String {
        guard !lastVia.isEmpty else { return "" }
        return lastVia.joined(separator: ", ")
    }
}
