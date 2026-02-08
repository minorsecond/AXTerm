//
//  AnalyticsSeries.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-18.
//

import Foundation

struct AnalyticsSeriesPoint: Hashable, Sendable {
    let bucket: Date
    let value: Int
}

struct AnalyticsSeries: Hashable, Sendable {
    let packetsPerBucket: [AnalyticsSeriesPoint]
    let bytesPerBucket: [AnalyticsSeriesPoint]
    let uniqueStationsPerBucket: [AnalyticsSeriesPoint]

    static let empty = AnalyticsSeries(
        packetsPerBucket: [],
        bytesPerBucket: [],
        uniqueStationsPerBucket: []
    )
}
