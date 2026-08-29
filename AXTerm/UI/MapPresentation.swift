import SwiftUI
import MapKit

/// Which basemap a station map draws on.
///
/// Shared by the live map, the offline snapshotter and every consumer,
/// so what gets captured for offline use is what was on screen.
nonisolated enum MapBasemap: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case hybrid = "Hybrid"
    case satellite = "Satellite"
    /// Stored tiles only. The mode that works with everything else down —
    /// see MapTileStore and Docs/OfflineMaps.md.
    case offline = "Offline"
    /// No basemap at all — bearing and range only. The mode that needs
    /// no tiles and therefore no network.
    case none = "None"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .hybrid: "globe.americas"
        case .satellite: "photo"
        case .offline: "square.stack.3d.down.right"
        case .none: "circle.dashed"
        }
    }

    /// Terrain is what matters for RF, so elevation is kept flat but
    /// points of interest are dropped — a coffee shop is noise here.
    /// Emphasis is muted: Apple's palette pulled back to greys is the
    /// difference between a street map with dots on it and a purpose-built
    /// RF map whose colour all belongs to the data.
    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard(elevation: .flat, emphasis: .muted,
                                  pointsOfInterest: .excludingAll)
        case .hybrid: .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        case .satellite: .imagery(elevation: .flat)
        // Never rendered by SwiftUI's Map: the offline mode is drawn by
        // OfflineBasemapMapView, which is the only thing that can host a
        // tile overlay. Kept exhaustive so a new case cannot silently fall
        // through to Apple's basemap.
        case .offline: .standard(elevation: .flat, emphasis: .muted,
                                 pointsOfInterest: .excludingAll)
        case .none: .standard(elevation: .flat, emphasis: .muted,
                              pointsOfInterest: .excludingAll)
        }
    }

    var mkMapType: MKMapType {
        switch self {
        case .standard, .none, .offline: .standard
        case .hybrid: .hybridFlyover
        case .satellite: .satellite
        }
    }

    /// The same choices for the MKMapView path, which is the one the
    /// stations screen actually renders through.
    var mkConfiguration: MKMapConfiguration {
        switch self {
        case .standard, .none, .offline:
            let configuration = MKStandardMapConfiguration(
                elevationStyle: .flat, emphasisStyle: .muted)
            configuration.pointOfInterestFilter = .excludingAll
            configuration.showsTraffic = false
            return configuration
        case .hybrid:
            let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: .flat)
        }
    }

    /// True where marker labels sit on dark imagery and need more
    /// contrast than a light basemap requires.
    var isDark: Bool { self == .satellite || self == .hybrid }

    /// True for the mode that draws from stored tiles and needs no network.
    var isOffline: Bool { self == .offline }

    /// Why an operator would pick this mode. Shown in the picker, because
    /// "Offline" alone does not say that it is the one that keeps working.
    var summary: String {
        switch self {
        case .standard: "Apple's map. Needs a network."
        case .hybrid: "Apple's imagery with labels. Needs a network."
        case .satellite: "Apple's imagery. Needs a network."
        case .offline: "Tiles stored on this device. Works with the network down — the only mode that does."
        case .none: "Bearing and range only, on no basemap at all. Needs nothing."
        }
    }
}

/// What the colours on a station map mean.
///
/// Every map carries one. A coloured dot with no key is decoration; the
/// colour here encodes measured behaviour, and the reader has no way to
/// know that without being told.
struct MapLegend: View {

    /// Legends differ by what the colour actually measures.
    enum Kind {
        /// Winlink gateways: how often the gateway answered *us*.
        case linkQuality
        /// Heard stations: how recently we heard them.
        case recency

        var title: String {
            switch self {
            case .linkQuality: "Measured link quality"
            case .recency: "Last heard"
            }
        }

        var entries: [(color: Color, label: String, detail: String)] {
            switch self {
            case .linkQuality:
                [(.green, "Answers", "Answered 70% or more of attempts from here."),
                 (.yellow, "Patchy", "Answered between 30% and 70% of attempts."),
                 (.orange, "Rarely", "Answered fewer than 30% of attempts."),
                 (.secondary, "Unworked", "Never worked from here. Position is from the directory; quality is unknown, which is not the same as bad.")]
            case .recency:
                [(.green, "Within the hour", "Heard in the last hour."),
                 (.yellow, "Today", "Heard in the last 24 hours."),
                 (.orange, "Older", "Heard, but more than a day ago."),
                 (.secondary, "Never", "In the station list with no recorded time.")]
            }
        }

        var footnote: String {
            switch self {
            case .linkQuality:
                "Colour is measured from this station's own session log, not from what the directory advertises."
            case .recency:
                "Recency is the only thing the receiver actually measured about a heard station."
            }
        }
    }

    let kind: Kind
    /// Drawn over imagery needs a stronger backing than over a light map.
    var overDarkBasemap = false
    /// True when coverage rings are on the map, so the legend explains
    /// what each ring means without the operator having to find the chip.
    var showsCoverage = false
    /// True when the node directory layer is drawn, so the diamond shape
    /// is explained where the colours are.
    var showsNodes = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(kind.title)
                        .font(.caption2.weight(.semibold))
                }
            }
            .buttonStyle(.plain)

            ForEach(kind.entries, id: \.label) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.color)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    Text(entry.label)
                        .font(.caption2)
                    Spacer(minLength: 0)
                }
                .help(entry.detail)
            }

            Divider().padding(.vertical, 1)
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.5]))
                    .frame(width: 8, height: 8)
                Text("Approximate")
                    .font(.caption2)
                Spacer(minLength: 0)
            }
            .help("A hollow marker is a lead, not a fix: the position comes from a different entity than the thing shown \u{2014} typically a NET/ROM node placed at its operator's licence address. Nodes usually sit on a hilltop or a repeater site, not at the operator's house.")

            if showsNodes {
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(Color.purple)
                        .frame(width: 7, height: 7)
                        .rotationEffect(.degrees(45))
                    Text("Node / directory")
                        .font(.caption2)
                    Spacer(minLength: 0)
                }
                .help("A diamond is NET/ROM infrastructure — a node or a station harvested from a node's directory — rather than a station heard on the air.")
            }

            if showsCoverage {
                Divider().padding(.vertical, 1)
                HStack(spacing: 5) {
                    Circle()
                        .strokeBorder(.blue.opacity(0.8), lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                    Text("Typical coverage")
                        .font(.caption2)
                    Spacer(minLength: 0)
                }
                .help("The inner ring: half the stations that answered you directly are inside it. An answer \u{2014} a UA, DM or FRMR to your frames \u{2014} proves that station decoded your transmitter, so it is a measured point in your footprint. Where your signal reliably works.")
                HStack(spacing: 5) {
                    Circle()
                        .strokeBorder(.blue.opacity(0.6),
                                      style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
                        .frame(width: 8, height: 8)
                    Text("Farthest answer")
                        .font(.caption2)
                    Spacer(minLength: 0)
                }
                .help("The dashed outer ring: the most distant station that has demonstrably decoded you in the last two weeks. Your best proven reach \u{2014} not a promise, and not a propagation model. Terrain will bend both rings.")
            }

            if isExpanded {
                Text(kind.footnote)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180, alignment: .leading)
            }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.primary.opacity(overDarkBasemap ? 0.25 : 0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .fixedSize()
    }
}

/// Basemap picker, shared by every map surface.
struct MapBasemapPicker: View {
    @Binding var basemap: MapBasemap
    /// Omit `.none` where a scope mode already exists separately.
    var includesNone = false
    /// Offer the offline basemap only when tiles are actually stored —
    /// otherwise it draws an empty map that reads as a bug rather than as an
    /// empty cupboard.
    var includesOffline = false

    var body: some View {
        Menu {
            ForEach(MapBasemap.allCases.filter {
                if $0 == .none { return includesNone }
                if $0 == .offline { return includesOffline }
                return true
            }) { option in
                Button {
                    basemap = option
                } label: {
                    Label(option.rawValue, systemImage: option.systemImage)
                }
                .help(option.summary)
            }
        } label: {
            Label(basemap.rawValue, systemImage: basemap.systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Basemap for this map. Satellite and hybrid show terrain, which is what actually decides whether a path works. Any of them can be captured for offline use.")
    }
}
