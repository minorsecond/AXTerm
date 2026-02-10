//
//  AnalyticsInputNormalizer.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-08.
//

import Foundation

nonisolated enum AnalyticsInputNormalizer {
    static func minEdgeCount(_ value: Int) -> Int {
        max(1, min(value, 20))
    }

    static func maxNodes(_ value: Int) -> Int {
        max(AnalyticsStyle.Graph.minNodes, min(value, 500))
    }
}
