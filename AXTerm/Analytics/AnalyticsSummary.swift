//
//  AnalyticsSummary.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-18.
//

import Foundation

nonisolated struct StationCount: Hashable, Sendable {
    let station: String
    let count: Int
}

nonisolated struct AnalyticsSummary: Hashable, Sendable {
    let packetCount: Int
    let uniqueStationsCount: Int
    let topTalkersByFrom: [StationCount]
    let topDestinationsByTo: [StationCount]
    let frameTypeCounts: [FrameType: Int]
    let infoTextRatio: Double
    let totalPayloadBytes: Int
}
