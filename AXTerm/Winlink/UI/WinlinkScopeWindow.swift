import SwiftUI

/// The Winlink station map: every cached RMS gateway plotted around this
/// station, coloured by *measured* link quality rather than by what the
/// directory claims.
///
/// This is the question the winlink.org map cannot answer. That map knows
/// where gateways are; it does not know your ETX, your terrain, or which
/// ones have ever answered you. This one is built from the station's own
/// history, and it needs no network to draw — every gateway's position
/// comes from the grid square already in the cache.
struct WinlinkScopeWindow: View {

    let stations: [WinlinkRMSStationRecord]
    /// Keyed by `WinlinkLinkQuality.linkKey`.
    let linkQuality: [String: WinlinkLinkQuality]
    let observerGrid: String
    /// A live fix beats the configured square when one is available.
    var observerFix: GreatCircle.Point?

    /// Map by default — it is what people mean by "map". The scope is
    /// the mode that still works with no tiles, so it stays one click
    /// away rather than being the only option.
    enum Mode: String, CaseIterable, Identifiable {
        case map = "Map"
        case scope = "Scope"
        var id: String { rawValue }
    }

    @AppStorage("winlink.stationMapMode") private var modeRaw = Mode.map.rawValue
    @AppStorage("winlink.mapBasemap") private var basemapRaw = MapBasemap.standard.rawValue

    private var basemap: MapBasemap { MapBasemap(rawValue: basemapRaw) ?? .standard }
    @State private var selection: String?
    /// Stored tiles, so the gateway map works in the field with no network.
    @StateObject private var offlineTiles = OfflineMapStorage()
    @StateObject private var elevation = ElevationStorage()
    @State private var showingOfflineMaps = false
    @State private var showsUnworked = true

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .map }

    /// Coordinates per site, for the map renderer.
    private var coordinates: [String: GreatCircle.Point] {
        var result = [String: GreatCircle.Point]()
        for station in stations {
            guard let center = Maidenhead.center(of: station.gridSquare) else { continue }
            result[station.callsign.uppercased()] = GreatCircle.Point(center)
        }
        return result
    }

    private var observer: GreatCircle.Point? {
        if let observerFix { return observerFix }
        return Maidenhead.center(of: observerGrid).map(GreatCircle.Point.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if observer == nil {
                noPosition
            } else if scope.isEmpty {
                noStations
            } else if let observer {
                switch mode {
                case .map:
                    StationMapView(
                        scope: scope, observer: observer,
                        coordinates: coordinates,
                        observerCallsign: "", basemap: basemap,
                        legend: .linkQuality,
                        tileStore: offlineTiles.hasStoredTiles ? offlineTiles.store : nil,
                        tileSource: offlineTiles.storedSource,
                        selection: $selection)
                        .frame(minHeight: 340)
                case .scope:
                    StationScopeView(scope: scope, selection: $selection,
                                     legend: .linkQuality)
                        .frame(minHeight: 340)
                }
                Divider()
                detailBar
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .navigationTitle("Winlink Station Map")
        .sheet(isPresented: $showingOfflineMaps) {
            NavigationStack {
                OfflineMapsView(
                    store: offlineTiles,
                    elevation: elevation,
                    observer: observer,
                    suggestedRegion: MapRegionFit.region(
                        covering: [observer].compactMap { $0 } + Array(coordinates.values))?.mkRegion,
                    suggestedRegionName: "this area")
                .navigationTitle("Offline Data")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingOfflineMaps = false }
                    }
                }
            }
            .frame(minWidth: 460, minHeight: 520)
        }
    }

    // MARK: - Scope

    /// One entry per gateway callsign — not per frequency. The same
    /// callsign on three frequencies is one place on the map; the
    /// frequencies belong in its label, not as three overlapping dots.
    private var scope: StationScope {
        guard let observer else {
            return StationScope.build(observerLabel: "", sites: [])
        }
        let byCallsign = Dictionary(grouping: stations, by: { $0.callsign.uppercased() })

        let entries = byCallsign.compactMap { callsign, rows -> (
            id: String, label: String, position: GreatCircle.Point?,
            signal: StationScope.Signal, subtitle: String, detail: String,
            isStale: Bool, isApproximate: Bool
        )? in
            guard let first = rows.first,
                  let center = Maidenhead.center(of: first.gridSquare) else { return nil }
            let quality = bestQuality(for: callsign, rows: rows)
            let signal = signal(for: quality)
            guard showsUnworked || signal != .unknown else { return nil }

            return (
                id: callsign,
                label: callsign,
                position: GreatCircle.Point(center),
                signal: signal,
                subtitle: frequencyList(rows),
                detail: detail(callsign: callsign, rows: rows,
                               grid: first.gridSquare, quality: quality, observer: observer),
                isStale: signal == .unknown,
                isApproximate: false)
        }
        return StationScope.build(
            observerLabel: observerLabel, observer: observer, entries: entries)
    }

    private var observerLabel: String {
        if observerFix != nil, let fix = observerFix,
           let grid = Maidenhead.locator(latitude: fix.latitude, longitude: fix.longitude) {
            return grid
        }
        return observerGrid.uppercased()
    }

    /// The best-evidenced link for a callsign across its frequencies.
    private func bestQuality(for callsign: String,
                             rows: [WinlinkRMSStationRecord]) -> WinlinkLinkQuality? {
        rows.compactMap { row in
            linkQuality[WinlinkLinkQuality.linkKey(
                callsign: callsign, frequencyHz: row.frequencyHz)]
        }
        .filter { $0.attempts > 0 }
        .max { $0.measuredSeconds < $1.measuredSeconds }
    }

    /// Measured behaviour, not advertised capability. A gateway never
    /// worked is `unknown` — which is different from one that answers
    /// badly, and must not be drawn as though it were the same.
    private func signal(for quality: WinlinkLinkQuality?) -> StationScope.Signal {
        guard let quality, quality.attempts > 0 else { return .unknown }
        guard let answerRate = quality.answerRate else { return .unknown }
        if answerRate >= 0.7 { return .good }
        if answerRate >= 0.3 { return .fair }
        return .poor
    }

    private func frequencyList(_ rows: [WinlinkRMSStationRecord]) -> String {
        rows.map { String(format: "%.3f", Double($0.frequencyHz) / 1_000_000) }
            .sorted()
            .joined(separator: ", ")
    }

    private func detail(callsign: String,
                        rows: [WinlinkRMSStationRecord],
                        grid: String,
                        quality: WinlinkLinkQuality?,
                        observer: GreatCircle.Point) -> String {
        guard let center = Maidenhead.center(of: grid) else { return callsign }
        let point = GreatCircle.Point(center)
        let kilometres = GreatCircle.kilometres(from: observer, to: point)
        let bearing = GreatCircle.bearingDegrees(from: observer, to: point)

        var lines = [
            "\(callsign) — \(grid.uppercased())",
            String(format: "%.0f mi at %.0f° (%@)",
                   GreatCircle.miles(fromKilometres: kilometres),
                   bearing, GreatCircle.compassPoint(bearing)),
            "Frequencies: \(frequencyList(rows)) MHz",
        ]
        if let quality, quality.attempts > 0 {
            let answered = quality.answered
            lines.append("Answered \(answered) of \(quality.attempts) attempts")
            if let rate = quality.effectiveBytesPerSecond {
                lines.append(WinlinkAirtimeEstimate.rateText(rate) + " measured")
            }
            if !quality.appliesHere {
                lines.append("Measured from a different location — shown as context, not a prediction.")
            }
        } else {
            lines.append("Never worked from here — position from the directory, quality unknown.")
        }
        lines.append("")
        lines.append("Plotted from the grid square in the station cache. No network needed.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Winlink Station Map").font(.headline)
                Text("\(scope.sites.count) Winlink gateway\(scope.sites.count == 1 ? "" : "s") around \(observerLabel) \u{00B7} RMS directory only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if mode == .map {
                MapBasemapPicker(basemap: Binding(
                    get: { basemap }, set: { basemapRaw = $0.rawValue }),
                    includesOffline: offlineTiles.hasStoredTiles)

                Button {
                    showingOfflineMaps = true
                } label: {
                    Image(systemName: "square.stack.3d.down.right")
                }
                .help("Store map tiles on this device so the gateway map keeps working with no network.")
            }
            Picker("", selection: $modeRaw) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Map draws real geography and needs tiles, which need the network. Scope plots bearing and range from the grid squares already cached, and keeps working with everything else down.")
            Toggle("Show unworked", isOn: $showsUnworked)
                .platformCheckboxToggle()
                .help("Include gateways this station has never worked. They are positioned from the directory, so their place is known but their quality is not — they draw faded and grey.")
        }
        .padding(12)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendDot(.green, "Answers")
            legendDot(.yellow, "Patchy")
            legendDot(.orange, "Rarely")
            legendDot(.secondary, "Unworked")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help("Colour is measured from this station's own session log — how often the gateway actually answered — not what the directory advertises.")
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    @ViewBuilder
    private var detailBar: some View {
        if let site = scope.sites.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(site.label).font(.headline)
                    Text(String(format: "%.0f mi · %.0f° %@",
                                GreatCircle.miles(fromKilometres: site.kilometres),
                                site.bearingDegrees, site.compassPoint))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(site.subtitle + " MHz")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(site.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } else {
            Text("Select a gateway for range, bearing and measured quality.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private var noPosition: some View {
        contentUnavailable(
            symbol: "location.slash",
            title: "No position known",
            message: "The map plots everything by bearing and range from your station, so it needs to know where you are. Use \u{201C}Use My Current Position\u{201D} in Settings \u{2192} Winlink, or set a grid square.")
    }

    private var noStations: some View {
        contentUnavailable(
            symbol: "antenna.radiowaves.left.and.right.slash",
            title: "No gateways cached",
            message: "Refresh the station list on the Stations tab. Gateways are plotted from their grid squares, which the cache already holds \u{2014} but the cache has to be filled once while a path exists.")
    }

    private func contentUnavailable(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
