//
//  AnalyticsViewState.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-08.
//

import Foundation

struct AnalyticsViewState: Hashable, Sendable {
    var summary: AnalyticsSummaryMetrics?
    var series: AnalyticsSeries
    var heatmap: HeatmapData
    var histogram: HistogramData
    var topTalkers: [RankRow]
    var topDestinations: [RankRow]
    var topDigipeaters: [RankRow]
    var graphModel: GraphModel
    /// Classified graph model with typed edges (DirectPeer, HeardDirect, SeenVia).
    /// Used for inspector display and relationship classification.
    var classifiedGraphModel: ClassifiedGraphModel
    var nodePositions: [NodePosition]
    var layoutEnergy: Double
    var graphNote: String?
    var selectedNodeID: String?
    var selectedNodeIDs: Set<String>
    var hoveredNodeID: String?
    var networkHealth: NetworkHealth

    static let empty = AnalyticsViewState(
        summary: nil,
        series: .empty,
        heatmap: .empty,
        histogram: .empty,
        topTalkers: [],
        topDestinations: [],
        topDigipeaters: [],
        graphModel: .empty,
        classifiedGraphModel: .empty,
        nodePositions: [],
        layoutEnergy: 0,
        graphNote: nil,
        selectedNodeID: nil,
        selectedNodeIDs: [],
        hoveredNodeID: nil,
        networkHealth: .empty
    )
}
