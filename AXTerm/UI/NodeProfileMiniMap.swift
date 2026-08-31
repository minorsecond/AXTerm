import MapKit
import SwiftUI

/// A small map in a station profile: where this station is, at a glance.
///
/// Deliberately not the full `StationMapView`. That one needs a whole
/// `StationScope` — every heard station, their paths, coverage rings — to
/// answer "what does the network look like". This answers one much smaller
/// question, and building a scope to ask it would be a lot of machinery for
/// a thumbnail.
///
/// It is honest about what the pin means. Most station coordinates in this
/// app come from a grid square, and the centre of a six-character locator is
/// about 8 km across — the pin describes the square, not the antenna. The
/// caption says which, because a map is exactly the place someone would
/// otherwise assume precision it does not have.
struct NodeProfileMiniMap: View {

    let callsign: String
    let position: GreatCircle.Point
    /// How much the coordinate is worth. Drives the caption and the size of
    /// the uncertainty circle.
    let confidence: HeardStationMap.PositionConfidence

    @State private var camera: MapCameraPosition = .automatic

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                // The circle is the claim; the pin is only where its centre
                // happens to fall. Drawn first so the marker sits above it.
                if let radius = uncertaintyRadiusMetres {
                    MapCircle(center: coordinate, radius: radius)
                        .foregroundStyle(.blue.opacity(0.12))
                        .stroke(.blue.opacity(0.35), lineWidth: 1)
                }
                Marker(callsign, systemImage: "antenna.radiowaves.left.and.right",
                       coordinate: coordinate)
                    .tint(.blue)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onAppear {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: span, longitudinalMeters: span))
            }
            .accessibilityLabel("Map showing \(callsign)")

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Roughly how wrong the pin can be. Nil for a coordinate the station
    /// actually reported, where drawing a circle would invent doubt.
    private var uncertaintyRadiusMetres: CLLocationDistance? {
        switch confidence {
        case .exact: return nil
        // Half the diagonal of a six-character locator at mid latitudes:
        // the square is about 5 km by 9 km, so nothing inside ~5 km of the
        // centre is excluded.
        case .gridSquare: return 5_000
        // A node placed at its operator's licence address is a lead about a
        // different entity — nodes live on hilltops, not at the house — so
        // the circle is wide enough to say "somewhere around here".
        case .inferredFromOperator: return 15_000
        }
    }

    private var span: CLLocationDistance {
        uncertaintyRadiusMetres.map { $0 * 6 } ?? 12_000
    }

    private var caption: String {
        switch confidence {
        case .exact:
            return "A position this station reported."
        case .gridSquare:
            return "The centre of a grid square, about 8 km across — the shaded area "
                + "is where the antenna could be, not a margin of error on the pin."
        case .inferredFromOperator:
            return "The operator's licence address, not the node. Nodes usually sit on "
                + "a hilltop or a repeater site, so treat this as a lead."
        }
    }
}
