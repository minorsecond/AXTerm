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
    enum Kind: Equatable {
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

    /// APRS mode: symbols are on the map, so colour keys the station *type*
    /// (see the marker renderer) and recency has moved to opacity. The
    /// legend follows — type swatches instead of recency swatches, and a
    /// fade row for recency.
    private var aprsMode: Bool { showsPositionSource && kind == .recency }
    /// What the dot colour means right now, for the header and the a11y label.
    private var keyedDimension: String { aprsMode ? "Station type" : kind.title }
    private var effectiveFootnote: String {
        aprsMode
        ? "In APRS mode colour is the station type; recency is opacity \u{2014} fresh is solid, older fades, nothing is hidden."
        : kind.footnote
    }
    /// Drawn over imagery needs a stronger backing than over a light map.
    var overDarkBasemap = false
    /// Nine points is legible beside a pointer and not on a phone held at
    /// arm's length; caption2 is the smallest text style the platform ships.
    private var legendFootnoteFont: Font {
        #if os(macOS)
        .system(size: 9)
        #else
        .caption2
        #endif
    }
    /// True when coverage rings are on the map, so the legend explains
    /// what each ring means without the operator having to find the chip.
    var showsCoverage = false
    /// True when the node directory layer is drawn, so the diamond shape
    /// is explained where the colours are.
    var showsNodes = false
    /// True when at least one station is placed at its own transmitted APRS
    /// fix, so the key explains that a symbol marks a beaconed position and a
    /// plain dot marks a looked-up address.
    var showsPositionSource = false
    /// Collapses the whole key, not one line of it.
    ///
    /// The disclosure used to hide only the footnote — every swatch stayed
    /// put — so the chevron promised more than it delivered and read as
    /// broken. The legend is a permanent box over the map, and an operator
    /// who knows the colours has a real reason to want it gone; that is what
    /// a disclosure is for.
    ///
    /// Stored, so it stays how it was left. Open by default: a coloured dot
    /// with no key is decoration.
    @AppStorage("map.legendExpanded") private var isExpanded = true

    /// The station-type key shown in APRS mode. Colour keys the class exactly
    /// as the map paints it (digi blue, weather teal, vehicle orange, home
    /// gray); the white SF Symbol inside reads as the class at legend size —
    /// not the exact APRS glyph, the same meaning. Recency is no longer a
    /// colour here: it is opacity, keyed by the fade row below.
    /// The same four hues the map paints, pulled toward the paper. See
    /// `OfflineBasemapMapView.Coordinator.typeColour`.
    static let digipeaterTint = Color(red: 0.36, green: 0.36, blue: 0.62)
    static let weatherTint = Color(red: 0.20, green: 0.50, blue: 0.56)
    static let vehicleTint = Color(red: 0.72, green: 0.45, blue: 0.22)
    static let fixedTint = Color(red: 0.42, green: 0.45, blue: 0.48)

    private static let typeSwatches: [(color: Color, symbol: String, label: String, help: String)] = [
        (digipeaterTint, "antenna.radiowaves.left.and.right", "Digipeater / relay",
         "Fixed relay infrastructure — a digipeater, i-gate, gateway or repeater. It forwards other stations rather than being a destination."),
        (weatherTint, "cloud.sun.fill", "Weather station",
         "A station beaconing weather data. Its position is fixed; the payload is temperature, wind and rain. "
         + "Its current temperature is drawn beside its callsign, and the rest of the reading \u{2014} wind, gust, "
         + "humidity, pressure, rainfall \u{2014} is on the station's card. A reading over an hour old loses the "
         + "temperature beside the callsign, because a stale number on a map reads as the current one."),
        (vehicleTint, "car.fill", "Vehicle",
         "Something on the move, or wearing a vehicle symbol — a car, truck, boat, aircraft or glider — placed where it last beaconed."),
        (fixedTint, "house.fill", "Fixed / home station",
         "A station at a fixed location that is not infrastructure — typically an operator's home station."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    // Says what the box *is* before what it keys. On its own,
                    // "Last heard" beside a chevron reads as a filter or a
                    // sort order — something that picks stations by when they
                    // were last heard — rather than as the key to the dot
                    // colours. Naming the dimension still earns its place:
                    // the Winlink scope keys the same dots by measured link
                    // quality instead, and which is in force cannot be
                    // guessed from the colours.
                    Text("Legend")
                        .font(.caption2.weight(.semibold))
                    Text("\u{b7} \(keyedDimension)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(isExpanded
                  ? "Hide the key and give the map back the space. Dot colour means \(keyedDimension.lowercased())."
                  : "Show what the dot colours mean.")
            .accessibilityLabel(isExpanded
                                ? "Legend, \(keyedDimension), expanded"
                                : "Legend, \(keyedDimension), collapsed")

            if isExpanded {
            if aprsMode {
                // Colour = type. Each swatch is the exact disc the map paints
                // — the class colour with the white class glyph inside.
                ForEach(Self.typeSwatches, id: \.label) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Image(systemName: item.symbol)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white))
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        Text(item.label)
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .help(item.help)
                }
                // Recency, now that colour is spoken for: opacity.
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Circle().fill(.secondary).frame(width: 11, height: 11)
                        Circle().fill(.secondary).opacity(0.35).frame(width: 11, height: 11)
                    }
                    Text("Fresh \u{2192} long silent")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .help("With colour keying type, recency is shown by opacity instead: a station heard within the hour is solid and fades as it ages, down to long-silent. Faded, never hidden.")
            } else {
                ForEach(kind.entries, id: \.label) { entry in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.color)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        Text(entry.label)
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .help(entry.detail)
                }
            }

            Divider().padding(.vertical, 1)
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.5]))
                    .frame(width: 14, height: 14)
                Text("Approximate")
                    .font(.caption2)
                Spacer(minLength: 0)
            }
            .help("A hollow marker is a lead, not a fix: the position comes from a different entity than the thing shown \u{2014} typically a NET/ROM node placed at its operator's licence address. Nodes usually sit on a hilltop or a repeater site, not at the operator's house.")

            if showsPositionSource {
                HStack(spacing: 6) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.green))
                    Text("Beaconed position \u{b7} plain dot = looked-up address")
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .help("A station drawn with its APRS symbol is at the position it beaconed over the air \u{2014} a live fix. A plain coloured dot is placed from a lookup about the callsign (licence address, registry grid), not from a transmitted position. Toggle which one is shown under Layers \u{2192} Transmitted Positions.")
            }

            if showsNodes {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.purple)
                        .frame(width: 11, height: 11)
                        .rotationEffect(.degrees(45))
                    Text("Node / directory")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .help("A diamond is NET/ROM infrastructure — a node or a station harvested from a node's directory — rather than a station heard on the air.")
            }

            if showsCoverage {
                Divider().padding(.vertical, 1)
                HStack(spacing: 6) {
                    Circle()
                        .strokeBorder(.blue.opacity(0.8), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    Text("Typical coverage")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .help("The inner ring: half the stations that answered you directly are inside it. An answer \u{2014} a UA, DM or FRMR to your frames \u{2014} proves that station decoded your transmitter, so it is a measured point in your footprint. Where your signal reliably works.")
                HStack(spacing: 6) {
                    Circle()
                        .strokeBorder(.blue.opacity(0.6),
                                      style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
                        .frame(width: 14, height: 14)
                    Text("Farthest answer")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .help("The dashed outer ring: the most distant station that has demonstrably decoded you in the last two weeks. Your best proven reach \u{2014} not a promise, and not a propagation model. Terrain will bend both rings.")
            }

            // A fixed width, not a maximum. Under the legend's `fixedSize()`
            // a `maxWidth` frame measures the sentence on one line, clamps
            // the width, and reports one line of height — the text then
            // wraps to three and the last line hangs out of the box, off the
            // bottom of the map. A fixed width proposes the width first, so
            // the height reported is the height drawn.
            Text(effectiveFootnote)
                .font(legendFootnoteFont)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)
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
