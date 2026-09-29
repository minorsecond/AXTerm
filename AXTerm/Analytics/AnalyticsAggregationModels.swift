//
//  AnalyticsAggregationModels.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-01.
//

import Foundation

nonisolated struct AnalyticsSummaryMetrics: Hashable, Sendable {
    let totalPackets: Int
    let uniqueStations: Int
    let totalPayloadBytes: Int
    let uiFrames: Int
    let iFrames: Int
    let infoTextRatio: Double
}

nonisolated struct RankRow: Hashable, Sendable, Identifiable {
    let label: String
    let count: Int

    var id: String { label }
}

nonisolated struct HeatmapData: Hashable, Sendable {
    let matrix: [[Int]]
    let xLabels: [String]
    let yLabels: [String]

    static let empty = HeatmapData(matrix: [], xLabels: [], yLabels: [])
}

nonisolated struct HistogramBin: Hashable, Sendable {
    let lowerBound: Int
    let upperBound: Int
    let count: Int

    var label: String {
        "\(lowerBound)–\(upperBound)"
    }
}

nonisolated struct HistogramData: Hashable, Sendable {
    let bins: [HistogramBin]
    let maxValue: Int

    static let empty = HistogramData(bins: [], maxValue: 0)
}

nonisolated struct AnalyticsAggregationResult: Hashable, Sendable {
    let summary: AnalyticsSummaryMetrics
    let series: AnalyticsSeries
    let heatmap: HeatmapData
    let histogram: HistogramData
    let topTalkers: [RankRow]
    let topDestinations: [RankRow]
    let topDigipeaters: [RankRow]
}
