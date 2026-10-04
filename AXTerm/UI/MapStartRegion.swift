import Foundation

/// Where the map opens.
///
/// It used to open framed around the observer *and* every station heard — so
/// on a channel reaching Dodge City, Raton and Fort Collins it opened at
/// continental zoom, showing three states and none of them usefully. That is
/// also slow: a 700 km view asks the tile store for 700 km of tiles before
/// anything is legible.
///
/// So: the region the operator last looked at, then their own position at a
/// span that suits VHF packet, and only then the fit-everything framing.
///
/// The value is persisted through `UserDefaults` directly rather than
/// `@AppStorage` on purpose. Panning writes it on every region change, and an
/// `@AppStorage` write republishes the view — which on this map means
/// recomputing the scope, the coordinates, the symbols and the trails, on a
/// gesture that fires continuously. That is the shape of the console beachball.
nonisolated struct MapStartRegion: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double

    /// About 100 km across — far enough to hold the digis a VHF station
    /// actually works, close enough to read a callsign.
    static let defaultLatitudeDelta: Double = 0.9

    static let storageKey = "map.lastRegion"

    /// The widest view worth reopening: a few states across. Past this the
    /// station's own network is a dot, and MapKit reports a fully zoomed-out
    /// view with its longitude span clamped at 180 and the center shifted half
    /// a turn, which reopened Station A over Asia (smoke run 2026-10-03-1,
    /// issue 23).
    static let widestLatitudeDelta: Double = 30
    static let widestLongitudeDelta: Double = 120

    /// Rejects a stored region that would open the map somewhere useless: off
    /// the globe, inside-out, zoomed so far in that nothing renders, or so far
    /// out that the station is lost in it.
    var isSane: Bool {
        latitude >= -90 && latitude <= 90
            && longitude >= -180 && longitude <= 180
            && latitudeDelta > 0.0004 && longitudeDelta > 0.0004
            && latitudeDelta <= Self.widestLatitudeDelta
            && longitudeDelta <= Self.widestLongitudeDelta
    }

    var encoded: String {
        String(format: "%.6f,%.6f,%.6f,%.6f",
               latitude, longitude, latitudeDelta, longitudeDelta)
    }

    static func decode(_ text: String?) -> MapStartRegion? {
        guard let parts = text?.split(separator: ","), parts.count == 4 else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        let region = MapStartRegion(latitude: values[0], longitude: values[1],
                                    latitudeDelta: values[2], longitudeDelta: values[3])
        return region.isSane ? region : nil
    }

    /// A square-looking box around a point. Longitude degrees shrink towards
    /// the poles, so an equal delta in both would draw a letterbox.
    static func around(latitude: Double, longitude: Double,
                       latitudeDelta: Double = defaultLatitudeDelta) -> MapStartRegion {
        let shrink = max(0.2, cos(latitude * .pi / 180))
        return MapStartRegion(latitude: latitude, longitude: longitude,
                              latitudeDelta: latitudeDelta,
                              longitudeDelta: latitudeDelta / shrink)
    }

    /// The region to open at, in order of what the operator most likely wants.
    static func opening(saved: MapStartRegion?,
                        observerLatitude: Double?, observerLongitude: Double?,
                        fitEverything: MapStartRegion?) -> MapStartRegion? {
        if let saved, saved.isSane { return saved }
        if let lat = observerLatitude, let lon = observerLongitude {
            return around(latitude: lat, longitude: lon)
        }
        return fitEverything
    }

    // MARK: - Persistence

    /// In the app's own suite, which a test-mode instance clears at launch.
    /// In `.standard` it outlived every test launch and was shared by every
    /// instance, so each opened where the last one had looked.
    static func load(_ defaults: UserDefaults = AppEnvironment.defaults) -> MapStartRegion? {
        decode(defaults.string(forKey: storageKey))
    }

    /// Throttled by the caller; this just writes.
    static func save(_ region: MapStartRegion, to defaults: UserDefaults = AppEnvironment.defaults) {
        guard region.isSane else { return }
        defaults.set(region.encoded, forKey: storageKey)
    }
}
