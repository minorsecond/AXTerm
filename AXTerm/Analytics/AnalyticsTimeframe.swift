//
//  AnalyticsTimeframe.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-20.
//

import Foundation

nonisolated enum AnalyticsTimeframe: String, CaseIterable, Hashable, Sendable {
    case fifteenMinutes
    case oneHour
    case sixHours
    case twentyFourHours
    case sevenDays
    case custom

    var displayName: String {
        switch self {
        case .fifteenMinutes:
            return "15m"
        case .oneHour:
            return "1h"
        case .sixHours:
            return "6h"
        case .twentyFourHours:
            return "24h"
        case .sevenDays:
            return "7d"
        case .custom:
            return "Custom…"
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .fifteenMinutes:
            return 15 * 60
        case .oneHour:
            return 60 * 60
        case .sixHours:
            return 6 * 60 * 60
        case .twentyFourHours:
            return 24 * 60 * 60
        case .sevenDays:
            return 7 * 24 * 60 * 60
        case .custom:
            return nil
        }
    }

    func dateInterval(now: Date, customStart: Date, customEnd: Date) -> DateInterval {
        if let duration {
            let end = now
            let start = end.addingTimeInterval(-duration)
            return DateInterval(start: start, end: end)
        }
        let normalizedStart = min(customStart, customEnd)
        let normalizedEnd = max(customStart, customEnd)
        return DateInterval(start: normalizedStart, end: normalizedEnd)
    }
}
