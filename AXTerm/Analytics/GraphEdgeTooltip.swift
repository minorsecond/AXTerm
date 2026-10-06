//
//  GraphEdgeTooltip.swift
//  AXTerm
//
//  What the graph says about a link when the pointer rests on its edge. The
//  edges encode df, dr, ETX, duplicates, freshness and traffic, and hovering
//  one showed nothing (smoke run 2026-10-03-1, issue 95). CLAUDE.md §11 asks
//  every advanced metric to explain why its value is what it is.
//

import CoreGraphics
import Foundation

nonisolated enum GraphEdgeHitTest {
    /// Distance from `point` to the segment `a`–`b`, in the same units.
    static func distance(from point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// How close the pointer must come to an edge to hover it, in points.
    static let hitTolerancePoints: CGFloat = 5
}

enum GraphEdgeTooltip {
    /// The link estimates for one direction of an edge: the most observed
    /// pair of callsigns that maps onto it, and how many pairs did.
    struct Direction {
        let stats: LinkStatDisplayInfo
        let pairCount: Int
    }

    /// The link records that belong to one direction of an edge. In station
    /// mode a node gathers every SSID of a call, so several records can map
    /// onto one edge; the busiest one speaks for it.
    static func direction(
        from sourceID: String, to targetID: String,
        records: [LinkStatRecord], identityMode: StationIdentityMode, now: Date
    ) -> Direction? {
        func key(_ call: String) -> String? {
            StationNormalizer.normalize(call).map { CallsignParser.identityKey(for: $0, mode: identityMode) }
        }
        let matching = records.filter { key($0.fromCall) == sourceID && key($0.toCall) == targetID }
        guard let busiest = matching.max(by: { lhs, rhs in
            if lhs.observationCount != rhs.observationCount { return lhs.observationCount < rhs.observationCount }
            return lhs.lastUpdated < rhs.lastUpdated
        }) else { return nil }
        return Direction(stats: LinkStatDisplayInfo(from: busiest, now: now), pairCount: matching.count)
    }

    static func lines(
        sourceCall: String, targetCall: String,
        linkType: LinkType, weight: Int, isNetRomSource: Bool,
        forward: Direction?, reverse: Direction?
    ) -> [String] {
        var lines = ["\(sourceCall) ↔ \(targetCall)"]
        let unit = isNetRomSource ? (weight == 1 ? "route" : "routes") : (weight == 1 ? "frame" : "frames")
        lines.append("\(linkType.rawValue) · \(weight) \(unit) heard")
        lines.append(contentsOf: directionLines(from: sourceCall, to: targetCall, forward))
        lines.append(contentsOf: directionLines(from: targetCall, to: sourceCall, reverse))
        if forward != nil || reverse != nil {
            lines.append("quality = 255 / ETX, where ETX = 1 / (df × dr)")
            lines.append("(See Docs/RoutingMetrics.md)")
        }
        return lines
    }

    private static func directionLines(from: String, to: String, _ direction: Direction?) -> [String] {
        guard let direction else {
            return ["\(from) → \(to): no delivery evidence measured"]
        }
        let s = direction.stats
        var lines = ["\(from) → \(to): quality \(s.quality) (\(Int(s.qualityPercent.rounded()))%)"]
        let df = s.dfEstimate.map { String(format: "df %.2f", $0) } ?? "df unobserved"
        let dr = s.drEstimate.map { String(format: "dr %.2f", $0) } ?? "dr unobserved (0.99 assumed)"
        if let etx = s.etx {
            lines.append("  \(df) × \(dr) → ETX \(String(format: "%.2f", etx))")
        } else {
            lines.append("  \(df), \(dr)")
        }
        let retries = s.duplicateCount == 1 ? "1 duplicate or retry" : "\(s.duplicateCount) duplicates or retries"
        lines.append("  \(retries) · freshness \(s.freshnessDisplayString) (\(s.lastUpdatedRelative))")
        if direction.pairCount > 1 {
            lines.append("  busiest of \(direction.pairCount) callsign pairs")
        }
        return lines
    }
}

/// The edge under the pointer, and where the pointer is in the graph's
/// top-left-origin coordinates.
nonisolated struct GraphEdgeHover: Equatable {
    let sourceID: String
    let targetID: String
    let point: CGPoint
}
