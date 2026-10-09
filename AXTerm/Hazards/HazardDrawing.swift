import Foundation

/// What the map draws for a hazard layer (Docs/HazardLayers.md §1, §4):
/// each hazard in the NWS's color, the most urgent on top, a stale copy
/// fainter, an expired one a dashed outline with no fill.
nonisolated enum HazardDrawing {

    struct Item: Equatable, Sendable {
        let id: String
        let polygons: [[[GreatCircle.Point]]]
        /// RGB as six hex digits, from `NWSHazardStyle`.
        let hex: String
        let fillAlpha: Double
        let strokeAlpha: Double
        let dashed: Bool
    }

    struct Plan: Equatable, Sendable {
        /// In drawing order: the most urgent last, so it sits on top.
        var items: [Item] = []
        /// Hazards with no shape yet (a zone-based product whose zones have
        /// not loaded). Not drawn, but the list says how many.
        var unshaped = 0
    }

    /// A fill light enough to read the terrain and the stations through.
    static let currentFill = 0.18
    static let currentStroke = 0.9
    /// A copy with no newer fetch for a while reads as old.
    static let staleFill = 0.08
    static let staleStroke = 0.5
    static let expiredStroke = 0.35

    static func plan(_ features: [HazardFeature], now: Date, stale: Bool) -> Plan {
        var plan = Plan()
        let ranked = features.sorted {
            NWSHazardStyle.style(for: $0.event).priority > NWSHazardStyle.style(for: $1.event).priority
        }
        for feature in ranked {
            guard case let .polygons(polygons)? = feature.geometry else {
                if feature.geometry == nil { plan.unshaped += 1 }
                continue
            }
            let expired = feature.isExpired(at: now)
            plan.items.append(Item(
                id: feature.id,
                polygons: polygons,
                hex: NWSHazardStyle.style(for: feature.event).hex,
                fillAlpha: expired ? 0 : (stale ? staleFill : currentFill),
                strokeAlpha: expired ? expiredStroke : (stale ? staleStroke : currentStroke),
                dashed: expired))
        }
        return plan
    }
}
