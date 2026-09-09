import Foundation
import MapKit

/// An APRS symbol (table + code) carried to the map so a heard station is
/// drawn as what it *is* — a car, a digipeater, a weather station — over the
/// recency-coloured dot, instead of an anonymous point. The glyph is chosen
/// by `APRSSymbolGlyph`; this type is just the identity that survives being
/// threaded down through the two map paths.
nonisolated struct APRSMapSymbol: Equatable, Sendable {
    var table: Character
    var code: Character
}

/// One station's movement, ready to draw as a trail.
///
/// A single dot says where a station is now; the trail says where it has
/// been, which for a rover *is* the information — a line of fixes shows the
/// road it drove and the direction it is heading. Built from the fixes the
/// station beaconed over the air (`Station.track`), so it is measured, not
/// interpolated.
nonisolated struct MapTrack: Identifiable, Sendable, Equatable {
    /// The station's callsign — the same id its marker carries, so the two
    /// are reconciled together and a trail never outlives its dot.
    var id: String
    var points: [GreatCircle.Point]

    /// A rounded fingerprint of the geometry, so a trail's overlay is rebuilt
    /// only when the path actually changed — not on every map update pass.
    var geometrySignature: String {
        points.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
            .joined(separator: ";")
    }

    var polyline: MKPolyline {
        let coords = points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        return MKPolyline(coordinates: coords, count: coords.count)
    }

    /// Which trails to draw, and how much of each.
    ///
    /// Pure, because three separate rules decide whether a line appears and
    /// all three had to be reasoned about from a screenshot rather than a
    /// test: a trail needs two fixes from a station that *moved*, inside the
    /// window, and belonging to the selection unless every trail is asked for.
    /// Most stations never satisfy the first — a house does not move — which
    /// is why the layer legitimately draws nothing most of the time.
    ///
    /// - Parameters:
    ///   - placedIDs: stations drawn at their own transmitted fix. A trail
    ///     only belongs under a marker that is itself at the beaconed point.
    ///   - windowMinutes: 0 keeps everything the station has.
    static func trails(stations: [Station],
                       placedIDs: Set<String>,
                       selection: String?,
                       showsAll: Bool,
                       windowMinutes: Int,
                       now: Date = Date()) -> [MapTrack] {
        let cutoff = windowMinutes > 0
            ? now.addingTimeInterval(-Double(windowMinutes) * 60)
            : Date.distantPast
        return stations.compactMap { station -> MapTrack? in
            let id = station.call.uppercased()
            guard placedIDs.contains(id) else { return nil }
            if !showsAll, id != selection { return nil }
            let recent = station.track.filter { $0.timestamp >= cutoff }
            guard recent.count >= 2 else { return nil }
            return MapTrack(
                id: id,
                points: recent.map {
                    GreatCircle.Point(latitude: $0.latitude, longitude: $0.longitude)
                })
        }
    }

}
