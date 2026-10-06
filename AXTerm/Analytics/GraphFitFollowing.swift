//
//  GraphFitFollowing.swift
//  AXTerm
//

import Foundation

/// When a fit-all view should follow the graph as it grows.
nonisolated enum GraphFitFollowing {
    /// Refit when a station is shown that the last fit did not frame. One
    /// that leaves the graph needs nothing: whatever stays is still in view.
    static func shouldRefit(framed: Set<String>, shown: Set<String>) -> Bool {
        !shown.isSubset(of: framed)
    }
}
