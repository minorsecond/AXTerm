import Foundation

/// Chooses a map region that frames a set of positions.
///
/// Kept apart from MapKit and from any view so the framing can be tested
/// without a map — the arithmetic is where the mistakes live (a span of
/// zero when every station shares a grid square, or a region that clips
/// the furthest gateway off the edge).
nonisolated enum MapRegionFit {

    struct Region: Equatable, Sendable {
        var centerLatitude: Double
        var centerLongitude: Double
        /// Total height and width of the region, in degrees.
        var latitudeDelta: Double
        var longitudeDelta: Double
    }

    /// Never zoom closer than this. Two gateways in the same grid square
    /// would otherwise produce a zero span and a map zoomed to the
    /// molecule.
    static let minimumDelta = 0.08
    /// Slack around the outermost point so markers are not clipped by
    /// the frame they sit on.
    static let padding = 1.35

    /// Frames every point, or nil if there are none.
    ///
    /// Does not handle regions straddling the antimeridian — a station
    /// list spanning ±180° would frame the long way round. No RMS list
    /// this is used with comes close, and pretending to solve it would
    /// be untested code.
    static func region(covering points: [GreatCircle.Point]) -> Region? {
        guard !points.isEmpty else { return nil }

        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max()
        else { return nil }

        return Region(
            centerLatitude: (minLat + maxLat) / 2,
            centerLongitude: (minLon + maxLon) / 2,
            latitudeDelta: max(minimumDelta, (maxLat - minLat) * padding),
            longitudeDelta: max(minimumDelta, (maxLon - minLon) * padding))
    }

    /// True when the region contains the point — the property that
    /// matters, since a framing that clips a station is the bug.
    static func contains(_ region: Region, _ point: GreatCircle.Point) -> Bool {
        abs(point.latitude - region.centerLatitude) <= region.latitudeDelta / 2 + 1e-9
            && abs(point.longitude - region.centerLongitude) <= region.longitudeDelta / 2 + 1e-9
    }
}

import MapKit

extension MapRegionFit.Region {
    /// The MapKit form. Kept out of the model above so the framing
    /// arithmetic stays testable without a map.
    var mkRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    }
}
