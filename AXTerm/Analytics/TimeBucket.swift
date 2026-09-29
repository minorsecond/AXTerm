//
//  TimeBucket.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-18.
//

import Foundation

nonisolated enum TimeBucket: String, CaseIterable, Hashable, Sendable {
    case tenSeconds
    case minute
    case fiveMinutes
    case fifteenMinutes
    case hour
    case day

    var displayName: String {
        switch self {
        case .tenSeconds:
            return "10 sec"
        case .minute:
            return "1 min"
        case .fiveMinutes:
            return "5 min"
        case .fifteenMinutes:
            return "15 min"
        case .hour:
            return "1 hour"
        case .day:
            return "1 day"
        }
    }

    var axisStride: (component: Calendar.Component, count: Int) {
        switch self {
        case .tenSeconds:
            return (.second, 10)
        case .minute:
            return (.minute, 1)
        case .fiveMinutes:
            return (.minute, 5)
        case .fifteenMinutes:
            return (.minute, 15)
        case .hour:
            return (.hour, 1)
        case .day:
            return (.day, 1)
        }
    }

    func normalizedStart(for date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let seconds = calendar.component(.second, from: date)
        switch self {
        case .tenSeconds:
            components.second = floorSecond(seconds, divisor: 10)
        case .minute:
            components.second = 0
        case .fiveMinutes:
            components.minute = floorMinute(components.minute, divisor: 5)
            components.second = 0
        case .fifteenMinutes:
            components.minute = floorMinute(components.minute, divisor: 15)
            components.second = 0
        case .hour:
            components.minute = 0
            components.second = 0
        case .day:
            components.hour = 0
            components.minute = 0
            components.second = 0
        }
        return calendar.date(from: components) ?? date
    }

    private func floorMinute(_ minute: Int?, divisor: Int) -> Int {
        guard let minute else { return 0 }
        return (minute / divisor) * divisor
    }

    private func floorSecond(_ second: Int, divisor: Int) -> Int {
        (second / divisor) * divisor
    }
}

nonisolated struct BucketKey: Hashable, Comparable, Sendable {
    let date: Date

    init(date: Date, bucket: TimeBucket, calendar: Calendar) {
        self.date = bucket.normalizedStart(for: date, calendar: calendar)
    }

    static func < (lhs: BucketKey, rhs: BucketKey) -> Bool {
        if lhs.date == rhs.date {
            return lhs.date.timeIntervalSinceReferenceDate < rhs.date.timeIntervalSinceReferenceDate
        }
        return lhs.date < rhs.date
    }
}
