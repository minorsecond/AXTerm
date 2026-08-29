//
//  TimeDisplay.swift
//  AXTerm
//
//  One clock for every user-facing timestamp.
//
//  The app grew up hard-coding "HH:mm:ss" — natural for an operator's log,
//  wrong as the only option on a machine whose owner reads 12-hour time
//  (field ask 2026-08-29: the menu bar said "4:55 AM" while every AXTerm
//  surface said "04:55"). The default follows the system's locale and
//  12/24-hour preference; the setting can pin either style for operators
//  who log in one convention regardless of what the OS is set to.
//
//  Deliberately not applied to protocol content, debug traces, or chart
//  axis ticks: a Winlink form timestamp is wire format, a KISS trace is a
//  developer artifact, and axis labels stay compact by convention.
//

import Foundation

nonisolated enum TimeDisplayFormat: String, CaseIterable, Identifiable, Sendable {
    /// The system's locale and 12/24-hour preference, as set in the OS.
    case system
    case twelveHour
    case twentyFourHour

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }
}

nonisolated enum TimeDisplay {

    static let formatKey = "display.timeFormat"

    static func format(from defaults: UserDefaults = .standard) -> TimeDisplayFormat {
        defaults.string(forKey: formatKey).flatMap(TimeDisplayFormat.init) ?? .system
    }

    /// DateFormatter is not thread-safe and timestamps are formatted from
    /// more than one context, so the cache lives behind a lock. Rebuilt
    /// when the setting changes; existing on-screen lines keep their
    /// rendered text and new ones pick up the new style.
    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    /// A time-of-day string in the operator's chosen convention.
    static func timeString(_ date: Date, seconds: Bool = true,
                           format: TimeDisplayFormat? = nil) -> String {
        let style = format ?? Self.format()
        let key = "\(style.rawValue)|\(seconds)"
        lock.lock()
        defer { lock.unlock() }
        if let formatter = cache[key] {
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        switch style {
        case .system:
            // timeStyle rather than a template: it follows both the locale
            // and the user's explicit 12/24-hour override in the OS.
            formatter.locale = .autoupdatingCurrent
            formatter.timeStyle = seconds ? .medium : .short
        case .twelveHour:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = seconds ? "h:mm:ss a" : "h:mm a"
        case .twentyFourHour:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        }
        cache[key] = formatter
        return formatter.string(from: date)
    }
}
