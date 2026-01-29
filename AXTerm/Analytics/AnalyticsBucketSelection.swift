//
//  AnalyticsBucketSelection.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-20.
//

import CoreGraphics
import Foundation

enum AnalyticsBucketSelection: String, CaseIterable, Hashable, Sendable {
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

        let available: [TimeBucket] = [.tenSeconds, .minute, .fiveMinutes, .fifteenMinutes, .hour]
        let seconds = timeframe.duration ?? max(60, customRange.duration)
        let targetBucketCount = max(12, min(160, Int(chartWidth / AnalyticsStyle.Chart.targetBucketPixelWidth)))
        let secondsPerBucket = max(1, seconds / Double(targetBucketCount))

        return available.min { lhs, rhs in
            abs(lhs.seconds - secondsPerBucket) < abs(rhs.seconds - secondsPerBucket)
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
