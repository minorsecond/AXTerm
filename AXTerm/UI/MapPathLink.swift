import Foundation
import MapKit

/// One observed path, ready to draw.
///
/// The map is the natural home for this: a list of paths is a table of
/// callsign pairs, while the same information drawn between pins shows the
/// shape of the network — which digipeater everything funnels through, which
/// stations are isolated, and where a path crosses terrain that explains a
/// poor link.
nonisolated struct MapPathLink: Identifiable, Sendable {

    var id: String
    var from: GreatCircle.Point
    var to: GreatCircle.Point
    var evidence: NetworkPath.Evidence
    /// Drawn differently: a path that looks plausible and never answers is
    /// the one most worth noticing.
    var isSuspect: Bool
    /// Set for a path nobody has used, judged only by the ground between the
    /// two ends. Drawn faintly, because a forecast that looks like a
    /// measurement is worse than no forecast.
    var isPrediction: Bool = false
    var label: String

    /// A great-circle line rather than a straight one on the projection.
    ///
    /// Over a few hundred miles the difference is small but real, and the
    /// terrain profile already samples the same curve — a link drawn one way
    /// and analysed another would disagree about which ridge is in the way.
    var polyline: MKPolyline {
        let points = GreatCircle.samplePath(from: from, to: to, count: 24)
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return MKPolyline(coordinates: points, count: points.count)
    }

    /// Terrain forecasts, drawn alongside the observed network.
    static func links(fromPredictions predictions: [PredictedPath],
                      positions: [String: GreatCircle.Point]) -> [MapPathLink] {
        predictions.filter(\.isWorthDrawing).compactMap { prediction in
            guard let from = positions[prediction.from.uppercased()],
                  let to = positions[prediction.to.uppercased()] else { return nil }
            return MapPathLink(
                id: prediction.id, from: from, to: to,
                // Weakest evidence on purpose: nothing has travelled it.
                evidence: .transitive,
                isSuspect: false,
                isPrediction: true,
                label: "\(prediction.from) \u{2194} \(prediction.to) \u{00B7} "
                    + String(format: "%.0f km \u{00B7} ", prediction.distanceKilometres)
                    + prediction.outlook.label
                    // A forecast resting on a guessed antenna height must not
                    // read like one resting on a measured one.
                    + (prediction.assumedHeights ? " \u{00B7} assumed height" : ""))
        }
    }

    /// Builds drawable links from observed paths and known positions.
    ///
    /// Paths whose ends are not both placed are dropped rather than guessed
    /// at: a line to a station whose position is unknown would be a drawing of
    /// an assumption.
    static func links(from paths: [NetworkPath],
                      positions: [String: GreatCircle.Point]) -> [MapPathLink] {
        paths.compactMap { path in
            guard let from = positions[path.from.uppercased()],
                  let to = positions[path.to.uppercased()] else { return nil }
            // A path between two stations at the same coordinate — different
            // SSIDs of one licence — would draw a dot, not a line.
            guard from != to else { return nil }

            let hops = path.via.isEmpty ? "direct" : "via \(path.via.joined(separator: ", "))"
            return MapPathLink(
                id: path.id,
                from: from,
                to: to,
                evidence: path.evidence,
                isSuspect: path.isSuspect,
                label: "\(path.from) \u{2194} \(path.to) \u{00B7} \(hops) \u{00B7} \(path.evidence.label)")
        }
    }
}
