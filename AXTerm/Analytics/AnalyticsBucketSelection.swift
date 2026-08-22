//
//  AnalyticsBucketSelection.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-20.
//

import CoreGraphics
import Foundation

nonisolated enum AnalyticsBucketSelection: String, CaseIterable, Hashable, Sendable {
    case auto
    case tenSeconds
    case minute
    case fiveMinutes
    case fifteenMinutes
    case hour

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .tenSeconds:
            return "10s"
        case .minute:
            return "1m"
        case .fiveMinutes:
            return "5m"
        case .fifteenMinutes:
            return "15m"
        case .hour:
            return "1h"
        }
    }

    var manualBucket: TimeBucket? {
        switch self {
        case .auto:
            return nil
        case .tenSeconds:
            return .tenSeconds
        case .minute:
            return .minute
        case .fiveMinutes:
            return .fiveMinutes
        case .fifteenMinutes:
            return .fifteenMinutes
        case .hour:
            return .hour
        }
    }

    func resolvedBucket(for timeframe: AnalyticsTimeframe, chartWidth: CGFloat, customRange: DateInterval) -> TimeBucket {
        if let manualBucket {
            return manualBucket
        }

        // .day participates in auto-resolution so a 7-day chart gets ~7 points,
        // not 168 hourly ones.
        let available: [TimeBucket] = [.tenSeconds, .minute, .fiveMinutes, .fifteenMinutes, .hour, .day]
        let seconds = timeframe.duration ?? max(60, customRange.duration)
        let targetBucketCount = max(12, min(160, Int(chartWidth / AnalyticsStyle.Chart.targetBucketPixelWidth)))
        let secondsPerBucket = max(1, seconds / Double(targetBucketCount))

        // Compare on the log scale: bucket durations span 10s to 1 day, and linear
        // distance always favored the largest bucket for long windows (7d at 640pt
        // wanted ~27000s/bucket and picked .hour purely because 3600 is linearly
        // "closest", yielding 168 points instead of ~22).
        return available.min { lhs, rhs in
            abs(log(lhs.seconds) - log(secondsPerBucket)) < abs(log(rhs.seconds) - log(secondsPerBucket))
        } ?? .minute
    }
}

private extension TimeBucket {
    var seconds: Double {
        switch self {
        case .tenSeconds:
            return 10
        case .minute:
            return 60
        case .fiveMinutes:
            return 5 * 60
        case .fifteenMinutes:
            return 15 * 60
        case .hour:
            return 60 * 60
        case .day:
            return 60 * 60 * 24
        }
    }
}
