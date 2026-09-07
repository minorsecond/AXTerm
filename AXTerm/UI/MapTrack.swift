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
}
