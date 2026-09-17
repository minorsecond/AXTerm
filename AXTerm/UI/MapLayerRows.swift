import SwiftUI

/// What the map draws, as rows of the main sidebar.
///
/// These lived in a toolbar menu, so changing what the page drew cost
/// opening a menu and the current state was invisible until you did. They
/// are the map's navigation, so they belong where the other pages keep
/// theirs — and there is exactly one of each, here, rather than a toggle in
/// the sidebar and a second copy in the toolbar.
///
/// **Scoping.** Most of these layers only mean anything for one kind of
/// network. "Transmitted Positions" is an APRS idea; the node directory is a
/// packet-network one. With two radios on two different networks, showing all
/// of them in one flat list invites exactly the mistake it caused: an APRS
/// layer, left on, emptied the map of a packet channel's stations because none
/// of them beacons a position. So each layer declares the family it belongs
/// to, and the sidebar puts it under the radio that carries that family.
///
/// The captions are not decoration. Both the node directory and the terrain
/// forecast collect "enabled but invisible" reports, because for both of
/// them drawing nothing is a common and honest outcome — most of a harvested
/// directory has no position, and in rolling ground most untried paths really
/// are blocked. A layer that can legitimately draw nothing has to say so, or
/// it is indistinguishable from a broken one.
struct MapLayerRows: View {

    @ObservedObject var status: MapLayerStatus
    /// "Showing stations heard on IC-705 only" while the sidebar's radio
    /// switches hide some radio; nil otherwise. The switches themselves live
    /// in the Radios section — this only says that they are in effect here.
    var radioScope: String? = nil
    /// Which layers this instance draws. The default shows everything, which
    /// is right for a single-radio station: there is no second network to
    /// separate it from.
    var scope: MapLayerScope = .everything

    var body: some View {
        Section("Layers") {
            MapLayerToggles(status: status, scope: scope)

            if let radioScope {
                Text(radioScope)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("The Radios section's switches hide a radio's stations here too. "
                          + "A station heard on a visible radio stays on the map.")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

/// Which subset of the map layers to draw.
nonisolated enum MapLayerScope: Equatable, Sendable {
    /// Every layer, ungrouped — one radio, or no traffic classified yet.
    case everything
    /// Only the layers belonging to these traffic families.
    case families(Set<RadioTrafficFamily>)
    /// Only the layers that belong to no single family, plus any family whose
    /// layers could not be filed under one radio because several carry it.
    case shared(Set<RadioTrafficFamily>)

    /// Whether a layer belonging to `family` (nil = belongs to none) is drawn.
    func includes(_ family: RadioTrafficFamily?) -> Bool {
        switch self {
        case .everything:
            return true
        case .families(let set):
            guard let family else { return false }
            return set.contains(family)
        case .shared(let orphans):
            guard let family else { return true }
            return orphans.contains(family)
        }
    }
}

/// A radio's layers behind one line.
///
/// With two radios the sidebar ran to about twenty-five rows and the radios
/// themselves, which are what the section is for, were pushed off the top.
/// Collapsed by default, remembered per radio, and the closed line says how
/// many of the layers are on: the state stays visible, which is the whole
/// reason these are not in a menu.
struct CollapsibleMapLayerToggles: View {

    @ObservedObject var status: MapLayerStatus
    var scope: MapLayerScope
    /// Remembered per radio, so opening one radio's layers does not open the
    /// other's and the choice survives a relaunch.
    var expansionKey: String

    @AppStorage private var isExpanded: Bool

    init(status: MapLayerStatus, scope: MapLayerScope, expansionKey: String) {
        self.status = status
        self.scope = scope
        self.expansionKey = expansionKey
        _isExpanded = AppStorage(wrappedValue: false, expansionKey)
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text("Map layers")
                    .font(.caption)
                Spacer(minLength: 4)
                if !isExpanded {
                    Text(MapLayerCatalog.summaryText(in: scope))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What the map draws for this radio. Collapsed, the count is how many of "
              + "its layers are switched on.")

        if isExpanded {
            MapLayerToggles(status: status, scope: scope)
                .padding(.leading, 12)
        }
    }
}

/// The layer switches themselves, with no Section around them so they can sit
/// under a radio's row as easily as in a section of their own.
struct MapLayerToggles: View {

    @ObservedObject var status: MapLayerStatus
    var scope: MapLayerScope = .everything

    @AppStorage("stations.showsPaths") private var showsPaths = false
    @AppStorage("stations.showsPredictedPaths") private var showsPredictedPaths = false
    @AppStorage("stations.showsDirectoryNodes") private var showsDirectoryNodes = false
    @AppStorage("stations.showsCoverageRing") private var showsCoverageRing = true
    @AppStorage("stations.showsAPRSCoverageRing") private var showsAPRSCoverageRing = true
    @AppStorage("stations.hidesDistantStations") private var hidesDistantStations = false
    @AppStorage("stations.preferTransmittedPosition") private var prefersTransmittedPosition = true
    @AppStorage("stations.showsObjects") private var showsObjects = true
    @AppStorage("stations.clustersStations") private var clustersStations = true
    @AppStorage("stations.falloffMinutes") private var falloffMinutes = 0
    /// Which layers have their options expanded. Collapsed by default: the
    /// sidebar is a list of what the map draws, and the tuning underneath it
    /// had grown into a dozen rows that pushed the layers themselves off the
    /// screen.
    @AppStorage("stations.expandedTypeOptions") private var expandedTypes = false
    @AppStorage("stations.expandedTrackOptions") private var expandedTracks = false
    @AppStorage("stations.expandedFieldOptions") private var expandedField = false
    @AppStorage("stations.showsTracks") private var showsTracks = true
    @AppStorage("stations.showsAllTracks") private var showsAllTracks = false
    @AppStorage("stations.trackWindowMinutes") private var trackWindowMinutes = 60
    @AppStorage("stations.showsWeatherField") private var showsWeatherField = false
    @AppStorage("stations.weatherFieldParameter") private var weatherFieldParameter =
        APRSWeatherField.Parameter.temperature.rawValue

    // Per-type visibility, only meaningful (and only shown) in APRS mode.
    // Same keys the map reads in StationsMapView.
    @AppStorage("stations.showsTypeDigipeater") private var showsTypeDigipeater = true
    @AppStorage("stations.showsTypeWeather") private var showsTypeWeather = true
    @AppStorage("stations.showsTypeVehicle") private var showsTypeVehicle = true
    @AppStorage("stations.showsTypeFixed") private var showsTypeFixed = true

    var body: some View {
        if scope.includes(.aprs) {
            layer("Transmitted Positions", "dot.radiowaves.up.forward",
                  isOn: $prefersTransmittedPosition,
                  caption: prefersTransmittedPosition
                      ? "APRS fix where a station beacons one"
                      : "Licence / registry address",
                  help: "On: place a station at the position it beaconed over the air, and draw "
                      + "its APRS symbol on the marker. Off: place it at its licence or registry "
                      + "address instead, as a plain dot. Only stations heard on a radio that "
                      + "carries APRS are affected \u{2014} a packet channel's stations never "
                      + "beacon a position and are always drawn at whatever point they have.")

            // APRS mode: choose which classes of transmitted station to draw.
            // Colour already keys the class on the map; these say whether to
            // show it at all. Indented under the mode that turns symbols on.
            if prefersTransmittedPosition {
                optionsChevron("Station types", isExpanded: $expandedTypes,
                               summary: typeSummary)
            }
            if prefersTransmittedPosition, expandedTypes {
                typeToggle("Digipeaters", "antenna.radiowaves.left.and.right",
                           isOn: $showsTypeDigipeater,
                           help: "Show fixed relay infrastructure \u{2014} digipeaters, i-gates, gateways, repeaters (indigo).")
                typeToggle("Weather", "cloud.sun.fill", isOn: $showsTypeWeather,
                           help: "Show weather stations (teal).")
                typeToggle("Vehicles", "car.fill", isOn: $showsTypeVehicle,
                           help: "Show movers \u{2014} anything wearing a vehicle symbol or reporting course and speed (orange).")
                typeToggle("Fixed / home", "house.fill", isOn: $showsTypeFixed,
                           help: "Show fixed stations that are not infrastructure \u{2014} typically home stations (gray).")
            }

            layer("Movement Trails", "point.topleft.down.to.point.bottomright.curvepath",
                  isOn: $showsTracks,
                  caption: status.trackCaption,
                  help: "The line of fixes a station beaconed as it moved. Drawn for the "
                      + "selected station by default: one trail belongs unmistakably to the "
                      + "station whose card is open, where a map full of unlabelled trails "
                      + "cannot be matched to anything and buries the terrain under it.")

            if showsTracks {
                optionsChevron("Trail options", isExpanded: $expandedTracks,
                               summary: showsAllTracks ? "Every rover" : "Selected only")
            }
            if showsTracks, expandedTracks {
                Toggle(isOn: $showsAllTracks) {
                    Label("All stations' trails", systemImage: "scribble")
                }
                .padding(.leading, 18)
                .help("Draw every rover's trail at once. The whole picture, at the cost of a "
                      + "much busier map \u{2014} useful when you are watching a group move, "
                      + "noisy the rest of the time.")

                Picker("", selection: $trackWindowMinutes) {
                    Text("Last 15 minutes").tag(15)
                    Text("Last hour").tag(60)
                    Text("Last 6 hours").tag(360)
                    Text("Everything kept").tag(0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .padding(.leading, 22)
                .help("How far back a trail is drawn. Where something was this morning is not "
                      + "where it is now, and an unbounded trail says both with the same line. "
                      + "About thirty fixes per station are kept whatever this is set to.")
            }

            // A statement, not a layer: there is nothing to switch on, and it
            // reads as a line of weather rather than a control. Shown only
            // when a barometer has actually reported, because "steady" and
            // "nobody is reporting" are different and must not look alike.
            if let pressure = status.pressure {
                VStack(alignment: .leading, spacing: 1) {
                    Label(pressure.headline, systemImage: pressure.outlook.symbol)
                        .font(.callout)
                        .foregroundStyle(pressure.outlook.isNotable && pressure.isAreaWide
                                         ? Color.orange : Color.primary)
                    if let caveat = pressure.caveat {
                        Text(caveat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let steepest = pressure.steepest {
                        Text("Steepest at \(steepest.call), "
                             + String(format: "%+.1f mb/3h", steepest.perThreeHours))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Barometric tendency over the last three hours, from the weather "
                      + "stations this radio has heard. The change is used rather than the "
                      + "pressure itself because a station's altitude and its sea-level "
                      + "reduction cancel out of a difference \u{2014} absolute readings "
                      + "across this much terrain would mostly map who has configured their "
                      + "station correctly. Falling pressure means unsettled weather "
                      + "approaching; a fall past about 3.5 mb in three hours usually brings "
                      + "wind with it. It is a handful of amateur barometers, not a forecast.")

                Divider()
            }

            layer("Weather Field", "thermometer.medium",
                  isOn: $showsWeatherField,
                  caption: status.weatherFieldCaption ?? status.weatherFieldUnavailableReason,
                  enabled: status.weatherFieldCaption != nil,
                  help: (status.weatherFieldUnavailableReason.map {
                      "Unavailable: \($0.lowercased()). A field is built only from readings "
                          + "under an hour old, and needs two of them \u{2014} one station is "
                          + "a reading, not a field, and colouring a map from it would paint "
                          + "one thermometer across a county. Stations whose readings have "
                          + "aged out are still drawn; it is the interpolation that stops. "
                  } ?? "")
                      + "A wash inferred from the weather stations you have heard. For "
                      + "temperature their heights are removed first, the differences that are "
                      + "left are blended by distance, and the local ground height is added "
                      + "back \u{2014} so a mountain reads colder than the plain beside it. It "
                      + "fades out where no station is near enough to say, and it is an "
                      + "inference from a handful of points, never an observation.")

            // Which reading the wash is drawn from. Only the parameters
            // enough stations are actually reporting are offered; the rest
            // would draw an empty map and look broken.
            if showsWeatherField, !status.availableWeatherParameters.isEmpty {
                Picker("", selection: $weatherFieldParameter) {
                    ForEach(APRSWeatherField.Parameter.allCases, id: \.rawValue) { parameter in
                        if status.availableWeatherParameters.contains(parameter) {
                            Text(parameter.label).tag(parameter.rawValue)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .padding(.leading, 22)
                .help("Pressure is the one that interpolates honestly over a sparse network "
                      + "\u{2014} it varies smoothly over hundreds of kilometres, which is why "
                      + "hand-drawn isobars worked for a century, and a falling barometer is a "
                      + "forecast you can act on with nothing else working. Rainfall is "
                      + "deliberately not offered: rain cells are kilometres across and gauges "
                      + "are tens of kilometres apart, so a smooth surface through a few of them "
                      + "invents storms between the gauges. Rain stays on the stations that "
                      + "measured it.")
            }

            layer("Coverage Rings", "circle.dashed",
                  isOn: $showsAPRSCoverageRing,
                  help: "Both directions of this radio's reach. Purple is how far you are "
                      + "heard: the digipeaters that put your own beacons back on the air, "
                      + "which proves they decoded you. Teal is how far you hear: the "
                      + "stations you decoded with no digipeater in the path. They are "
                      + "rarely the same distance, and the purple one fills in on its own "
                      + "with every beacon. Measurements, not a propagation model.")

            layer("Objects & Hazards", "exclamationmark.triangle.fill",
                  isOn: $showsObjects,
                  caption: status.objectCaption,
                  help: "Points other operators have placed about somewhere other than "
                      + "themselves \u{2014} fires, road closures, shelters, aid stations, "
                      + "landing zones. This is how incident information moves when nothing "
                      + "upstream is working, so each one names who reported it and when it "
                      + "was last heard. An object nobody has repeated for six hours stops "
                      + "being drawn; one heard only once is marked unconfirmed.")
        }

        if scope.includes(.ax25) {
            layer("Coverage Rings", "circle.dashed",
                  isOn: $showsCoverageRing,
                  help: "Both directions of this radio's reach. Blue is how far you are "
                      + "heard: the stations that answered you directly, since a UA, DM or "
                      + "FRMR to your frames proves they decoded you. It only grows where "
                      + "you went looking for someone to talk to. Teal is how far you hear: "
                      + "the stations you decoded with no digipeater in the path. "
                      + "Measurements, not a propagation model.")

            layer("Observed Paths", "point.topleft.down.to.point.bottomright.curvepath",
                  isOn: $showsPaths,
                  help: "Paths observed between stations. Colour is evidence: green completed a "
                      + "connect end to end, blue arrived through a digipeater, teal was heard "
                      + "direct, grey dashed is inferred from a shared digipeater, and red means "
                      + "connect attempts went unanswered.")

            layer("Predicted Paths", "point.topleft.down.to.point.bottomright.curvepath.fill",
                  isOn: $showsPredictedPaths,
                  caption: status.hasTerrain ? status.forecastSummary : "Needs terrain data",
                  enabled: status.hasTerrain,
                  help: status.hasTerrain
                      ? "Where the stored terrain says a signal would cross between stations "
                        + "never heard talking. A forecast from ground elevation and Fresnel "
                        + "geometry \u{2014} not a measurement, which is why it is drawn differently."
                      : "Needs terrain data. Download the elevation tiles for this area from "
                        + "the map's Terrain menu first.")

            layer("Node Directory", "list.bullet.indent",
                  isOn: $showsDirectoryNodes,
                  caption: status.directoryCaption,
                  help: "Every station the network has claimed reachable that can be placed from "
                      + "cached positions. Dashed when the position is the operator's address "
                      + "rather than the node's own. Nothing is looked up online for this layer.")
        }

        if scope.includes(nil) {
            // How long a station stays on the map after it goes quiet.
            //
            // Distinct from the recency fade, which never removes anything. On
            // a busy channel a day of accumulated stations buries the handful
            // actually on the air, and "who is up right now" is the question
            // this map exists to answer.
            HStack(spacing: 4) {
                Label("Drop after", systemImage: "clock.arrow.circlepath")
                Spacer(minLength: 4)
                Picker("", selection: $falloffMinutes) {
                    Text("Never").tag(0)
                    Text("15 min").tag(15)
                    Text("1 hour").tag(60)
                    Text("6 hours").tag(360)
                    Text("24 hours").tag(1440)
                    Text("7 days").tag(10080)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
            }
            .help("Removes a station from the map once it has not been heard for this long. "
                  + "Different from the recency fade, which only dims: on a busy channel a "
                  + "day of accumulated stations buries the few that are actually on the air. "
                  + "Stations placed from a directory rather than heard are governed by their "
                  + "own layer, not by this.")

            if falloffMinutes > 0, status.falloffHiddenCount > 0 {
                Text("\(status.falloffHiddenCount) dropped for going quiet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }

            layer("Cluster Markers", "circle.grid.3x3.fill",
                  isOn: $clustersStations,
                  caption: clustersStations ? "Zoomed out, never hazards" : nil,
                  help: "Folds ordinary stations into a count when they are too close together "
                      + "to tell apart at this zoom, and breaks them back out as you zoom in. "
                      + "Your own station, and anything a person placed as an object or a "
                      + "hazard, are never folded in \u{2014} those are the reasons the page is "
                      + "open. Switch it off to draw every station at its own position at every "
                      + "zoom: denser, but it hides nothing.")

            layer("Hide Distant Stations", "arrow.down.right.and.arrow.up.left",
                  isOn: $hidesDistantStations,
                  caption: distantCaption,
                  enabled: status.distantCount > 0,
                  help: "Sets aside stations too far away to have arrived by radio. One "
                      + "internet-bridged station on the far coast stretches the zoom until every "
                      + "local station is a single cluster.")
        }
    }

    /// Named even when the filter is off, so the operator meets the feature
    /// here rather than discovering it by accident.
    private var distantCaption: String? {
        switch status.distantCount {
        case 0: return nil
        case 1: return hidesDistantStations ? "1 hidden" : "1 too far to have been heard"
        default:
            return hidesDistantStations
                ? "\(status.distantCount) hidden"
                : "\(status.distantCount) too far to have been heard"
        }
    }

    /// A disclosure row for a layer's options, so a layer is one line until
    /// the operator asks for more. The summary keeps the current setting
    /// visible while collapsed — hiding a control is fine, hiding what it is
    /// set to is not.
    @ViewBuilder
    private func optionsChevron(_ title: String, isExpanded: Binding<Bool>,
                                summary: String?) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .font(.caption2)
                if let summary, !isExpanded.wrappedValue {
                    Text("\u{b7} \(summary)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
    }

    /// Which station classes are currently drawn, for the collapsed summary.
    private var typeSummary: String {
        let hidden = [
            !showsTypeDigipeater ? "digis" : nil,
            !showsTypeWeather ? "weather" : nil,
            !showsTypeVehicle ? "vehicles" : nil,
            !showsTypeFixed ? "fixed" : nil,
        ].compactMap { $0 }
        return hidden.isEmpty ? "all shown" : "hiding " + hidden.joined(separator: ", ")
    }

    /// A per-type visibility switch, indented under Transmitted Positions so
    /// it reads as a refinement of it rather than a peer layer. Mini and tight
    /// because there are four in a row.
    @ViewBuilder
    private func typeToggle(_ title: String, _ symbol: String,
                            isOn: Binding<Bool>, help: String) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: symbol)
        }
        .padding(.leading, 18)
        .help(help)
    }

    @ViewBuilder
    private func layer(_ title: String, _ symbol: String,
                       isOn: Binding<Bool>,
                       caption: String? = nil,
                       enabled: Bool = true,
                       help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: isOn) {
                Label(title, systemImage: symbol)
            }
            .disabled(!enabled)
            // A caption earns its line when the layer is on and might be
            // drawing nothing, or when it is unavailable and has to say why.
            // Under a layer that is simply switched off it restates the
            // switch, and a second line per layer is most of what made this
            // list too long to read.
            if let caption, isOn.wrappedValue || !enabled {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Clear of the switch, and lined up under the label
                    // rather than under the icon.
                    .padding(.leading, 22)
            }
        }
        .help(help)
    }
}
