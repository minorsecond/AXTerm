//
//  TNC4BatteryPresentation.swift
//  AXTerm
//
//  A connected TNC4's battery, as a glyph inside the toolbar's radio pill
//  rather than a pill of its own, and the rule for keeping the reading
//  fresh without disturbing the link.
//

import Foundation

nonisolated enum TNC4BatteryPresentation {
    /// At or below this the glyph turns red.
    static let lowFraction = 0.2

    /// The SF Symbol for a charge level, in the system's five steps.
    static func symbol(fraction: Double) -> String {
        switch fraction {
        case ..<0.125: return "battery.0percent"
        case ..<0.375: return "battery.25percent"
        case ..<0.625: return "battery.50percent"
        case ..<0.875: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func isLow(fraction: Double) -> Bool { fraction <= lowFraction }

    /// "TNC4 battery 4.21 V, about 100%, read 4:45 AM".
    static func help(millivolts: Int, fraction: Double, readAt: Date?,
                     timeFormatter: (Date) -> String) -> String {
        var text = String(format: "TNC4 battery %.2f V, about %d%%", Double(millivolts) / 1000,
                          Int((fraction * 100).rounded()))
        if let readAt { text += ", read \(timeFormatter(readAt))" }
        if isLow(fraction: fraction) { text += ". Low: charge it soon" }
        return text
    }
}

/// When to read a TNC4's battery again. Reading it stops the demodulator
/// for a moment (the query runs on the audio task, and a RESET follows), so
/// it is only asked for when nothing is lost: no link up on the radio, the
/// TNC4 doing nothing else, and the channel quiet. Approved by the operator
/// on 2026-10-07, with a 30-minute interval.
nonisolated enum TNC4BatteryRefresh {
    static let interval: TimeInterval = 30 * 60
    /// No read within 5 s of a frame received or sent, as the level check.
    static let quietBefore: TimeInterval = 5

    /// Due once `interval` has passed since the last reading, or since the
    /// last time it was asked for, so a TNC4 that never answers is not asked
    /// every minute.
    static func isDue(lastReadAt: Date?, lastAskedAt: Date?, now: Date) -> Bool {
        let since = [lastReadAt, lastAskedAt].compactMap { $0 }.max()
        guard let since else { return true }
        return now.timeIntervalSince(since) >= interval
    }

    static func mayAsk(tncIdle: Bool, linkUp: Bool, lastActivity: Date?, now: Date) -> Bool {
        guard tncIdle, !linkUp else { return false }
        if let lastActivity, now.timeIntervalSince(lastActivity) < quietBefore { return false }
        return true
    }
}
