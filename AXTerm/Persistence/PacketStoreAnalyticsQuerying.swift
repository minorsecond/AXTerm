//
//  PacketStoreAnalyticsQuerying.swift
//  AXTerm
//
//  Created by AXTerm on 2026-10-02.
//

import Foundation

nonisolated protocol PacketStoreAnalyticsQuerying: Sendable {
    func aggregateAnalytics(
        in timeframe: DateInterval,
        bucket: TimeBucket,
        calendar: Calendar,
        options: AnalyticsAggregator.Options
    ) throws -> AnalyticsAggregationResult
}
