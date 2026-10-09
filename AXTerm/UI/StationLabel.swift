import Foundation

/// The grid square the map labels this station with.
nonisolated enum StationLabel {

    /// The grid of the position in use: an exact coordinate or this device's
    /// fix, not only the grid typed in Settings. The map labeled Station C
    /// DM79PO while its exact coordinate was in Alabama (2026-10-09). With no
    /// position at all, the Settings grid stands.
    static func grid(at point: GreatCircle.Point?, settingsGrid: String) -> String {
        guard let point,
              let grid = Maidenhead.locator(latitude: point.latitude, longitude: point.longitude)
        else { return settingsGrid.uppercased() }
        return grid.uppercased()
    }
}
