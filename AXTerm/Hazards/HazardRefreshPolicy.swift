import Foundation

/// When a hazard layer fetches (Docs/HazardLayers.md §4): only while it is
/// on and, for a scope tied to the station, the station has a position; at
/// once when first turned on or when the area changes, then
/// every two minutes, and early after a move of more than 5 km so a moving
/// station does not show the last town's warnings.
nonisolated enum HazardRefreshPolicy {
    static let interval: TimeInterval = 120
    static let movedFarKm = 5.0

    static func shouldRefresh(enabled: Bool, position: GreatCircle.Point?, lastAttempt: Date?,
                              lastPoint: GreatCircle.Point?, now: Date,
                              needsPosition: Bool = true, scopeChanged: Bool = false) -> Bool {
        guard enabled, position != nil || !needsPosition else { return false }
        guard let lastAttempt else { return true }
        // A different area chosen: the alerts shown are for the old one.
        if scopeChanged { return true }
        if let lastPoint, let position,
           GreatCircle.kilometres(from: lastPoint, to: position) > movedFarKm { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }
}
