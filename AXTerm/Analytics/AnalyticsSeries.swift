//
//  AnalyticsSeries.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-18.
//

import Foundation

nonisolated struct AnalyticsSeriesPoint: Hashable, Sendable {
    let bucket: Date
    let value: Int
}

nonisolated struct AnalyticsSeries: Hashable, Sendable {
    let packetsPerBucket: [AnalyticsSeriesPoint]
    let bytesPerBucket: [AnalyticsSeriesPoint]
    let uniqueStationsPerBucket: [AnalyticsSeriesPoint]
    /// Per-bucket frame-type breakdown (UI / I / everything else).
    let uiFramesPerBucket: [AnalyticsSeriesPoint]
    let iFramesPerBucket: [AnalyticsSeriesPoint]
    let otherFramesPerBucket: [AnalyticsSeriesPoint]
    /// Per-bucket REJ + SREJ supervisory frames — peers requesting retransmits,
    /// a direct RF-loss indicator.
    let rejectFramesPerBucket: [AnalyticsSeriesPoint]

    init(
        packetsPerBucket: [AnalyticsSeriesPoint],
        bytesPerBucket: [AnalyticsSeriesPoint],
        uniqueStationsPerBucket: [AnalyticsSeriesPoint],
        uiFramesPerBucket: [AnalyticsSeriesPoint] = [],
        iFramesPerBucket: [AnalyticsSeriesPoint] = [],
        otherFramesPerBucket: [AnalyticsSeriesPoint] = [],
        rejectFramesPerBucket: [AnalyticsSeriesPoint] = []
    ) {
        self.packetsPerBucket = packetsPerBucket
        self.bytesPerBucket = bytesPerBucket
        self.uniqueStationsPerBucket = uniqueStationsPerBucket
        self.uiFramesPerBucket = uiFramesPerBucket
        self.iFramesPerBucket = iFramesPerBucket
        self.otherFramesPerBucket = otherFramesPerBucket
        self.rejectFramesPerBucket = rejectFramesPerBucket
    }

    static let empty = AnalyticsSeries(
        packetsPerBucket: [],
        bytesPerBucket: [],
        uniqueStationsPerBucket: []
    )
}
