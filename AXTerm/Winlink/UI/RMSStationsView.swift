import SwiftUI

/// Nearby RMS packet gateways from the Winlink CMS, sorted by distance.
struct RMSStationsView: View {

    @ObservedObject var viewModel: RMSStationsViewModel
    @ObservedObject var settings: WinlinkSettings
    var onConnect: (WinlinkRMSStationRecord) -> Void

    @State private var showingHidden = false
    @State private var editingPathFor: String?
    @State private var isHoveringPath: String?
    @FocusState private var pathFieldFocused: Bool
    @State private var pathDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let blocker = viewModel.refreshBlocker, viewModel.stations.isEmpty {
                notice(blocker, systemImage: "mappin.slash")
            } else if viewModel.stations.isEmpty {
                notice("No cached stations — refresh to query the Winlink CMS.",
                       systemImage: "antenna.radiowaves.left.and.right.slash")
            } else {
                stationsTable
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let fetchedAt = viewModel.fetchedAt {
                Text("Updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("When the station list was last fetched from the Winlink CMS. Stale lists may include gateways that have since gone off the air.")
            }
            if let error = viewModel.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            frequencyFilterMenu
            if hiddenCount > 0 {
                // Silent truncation reads as "that is everything".
                Text("\(visibleStations.count) of \(viewModel.stations.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("\(hiddenCount) link\(hiddenCount == 1 ? " is" : "s are") filtered out. Nothing is deleted \u{2014} hidden links stay cached and keep accumulating link quality.")
            }
            Spacer()
            if !viewModel.ladderSummary.isEmpty {
                Label(viewModel.ladderSummary.joined(separator: " → "), systemImage: "list.number")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("Your gateway ladder. Connect & Exchange tries these stations top-down until one completes a session. Manage the order here or in Settings → Winlink.")
            }
            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(viewModel.isRefreshing)
            .help(WinlinkCopy.stationRefreshTooltip)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Measured link quality from our own sessions, as distinct from the
    /// CMS's advertised distance and baud. Greyed out when the samples
    /// were taken somewhere else — see `placementExplanation`.
    @ViewBuilder
    private func linkCell(for station: WinlinkRMSStationRecord) -> some View {
        let presentation = viewModel.quality(for: station)?.presentation()
            ?? WinlinkLinkQuality.unobservedPresentation(
                callsign: station.callsign, frequencyHz: station.frequencyHz)
        Label {
            Text(presentation.text)
                .font(.body.monospacedDigit())
                .lineLimit(1)
        } icon: {
            Image(systemName: presentation.systemImage)
        }
        .foregroundStyle(presentation.tint.color)
        .help(presentation.tooltip)
    }

    private var visibleStations: [WinlinkRMSStationRecord] {
        settings.stationPreferences.visible(viewModel.stations, showingHidden: showingHidden)
    }

    private var stationsTable: some View {
        Table(visibleStations, selection: .constant(Set<String>())) {
            TableColumn("Callsign") { station in
                HStack(spacing: 4) {
                    if settings.stationPreferences.isHidden(station) {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Hidden from this table. Still cached, still accumulating link quality.")
                    }
                    Text(station.callsign).font(.body.monospaced())
                }
                .contextMenu { hideMenuItems(station) }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Distance") { station in
                Text(String(format: "%.0f mi", station.distanceMiles))
                    .help(WinlinkCopy.stationDistanceTooltip)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Heading") { station in
                Text(String(format: "%.0f°", station.headingDegrees))
                    .foregroundStyle(.secondary)
                    .help("Initial great-circle bearing from your grid square toward the gateway.")
            }
            .width(min: 55, ideal: 60)

            TableColumn("Frequency") { station in
                Text(formatFrequency(station.frequencyHz))
                    .font(.body.monospaced())
                    .help(WinlinkCopy.stationFrequencyTooltip)
            }
            .width(min: 90, ideal: 100)

            TableColumn("Baud") { station in
                Text(station.baud).foregroundStyle(.secondary)
            }
            .width(min: 45, ideal: 55)

            TableColumn("Link") { station in
                linkCell(for: station)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Path") { station in
                pathCell(station)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Grid") { station in
                Text(station.gridSquare).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Service") { station in
                Text(station.serviceCode).foregroundStyle(.secondary)
            }
            .width(min: 55, ideal: 65)

            TableColumn("") { station in
                HStack(spacing: 6) {
                    if let rank = viewModel.ladderRank(of: station) {
                        Menu {
                            Button("Make Primary") { viewModel.promoteToTop(station) }
                            Button("Remove from Ladder", role: .destructive) {
                                viewModel.removeFromLadder(station)
                            }
                        } label: {
                            Label("#\(rank)", systemImage: rank == 1 ? "star.fill" : "star")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(rank == 1
                              ? "Your primary gateway — first rung of the ladder."
                              : "Rung #\(rank) of your gateway ladder — tried after \(rank - 1) other gateway\(rank == 2 ? "" : "s").")
                    } else {
                        Button {
                            viewModel.addToLadder(station)
                        } label: {
                            Label("Add", systemImage: "star")
                        }
                        .help("Add \(station.callsign) to your gateway ladder. Connect & Exchange tries ladder stations in order until one answers.")
                    }
                    Button("Exchange") { onConnect(station) }
                        .help(WinlinkCopy.connectExchangeTooltip)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .width(min: 160, ideal: 185)
        }
        .platformInsetTable()
    }

    private func formatFrequency(_ hz: Int) -> String {
        String(format: "%.3f MHz", Double(hz) / 1_000_000)
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filtering

    private var hiddenCount: Int {
        settings.stationPreferences.hiddenCount(in: viewModel.stations)
    }

    private var availableFrequencies: [Int] {
        WinlinkStationPreferences.frequencies(in: viewModel.stations)
    }

    /// A radio tuned to one frequency has no use for the others in the
    /// table; this is a view filter, so nothing is lost by using it.
    private var frequencyFilterMenu: some View {
        Menu {
            Button("All Frequencies") {
                settings.stationPreferences.visibleFrequencies = []
            }
            Divider()
            ForEach(availableFrequencies, id: \.self) { frequency in
                Toggle(formatFrequency(frequency), isOn: Binding(
                    get: { settings.stationPreferences.showsFrequency(frequency) },
                    set: { _ in
                        settings.stationPreferences.toggleFrequency(
                            frequency, in: availableFrequencies)
                    }))
            }
            Divider()
            Toggle("Show Hidden Links", isOn: $showingHidden)
        } label: {
            Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show only the frequencies your radio is actually on. Hidden links are filtered from this table only \u{2014} they stay cached and keep accumulating link quality.")
    }

    private var filterLabel: String {
        let selected = settings.stationPreferences.visibleFrequencies
        if selected.isEmpty { return "All Frequencies" }
        if selected.count == 1, let only = selected.first { return formatFrequency(only) }
        return "\(selected.count) Frequencies"
    }

    // MARK: - Path

    /// The digipeater path used for this link, every time. Without one
    /// the connection is direct, which is what a blank cell means.
    @ViewBuilder
    private func pathCell(_ station: WinlinkRMSStationRecord) -> some View {
        let key = WinlinkStationPreferences.linkKey(station)
        let path = settings.stationPreferences.path(for: station)

        if editingPathFor == key {
            HStack(spacing: 4) {
                TextField("direct", text: $pathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .focused($pathFieldFocused)
                    .onAppear { pathFieldFocused = true }
                    .onSubmit { commitPath(for: station) }
                    // Escape cancels the edit where there is an Escape key.
                    // On a touch keyboard the operator taps away instead,
                    // which the focus binding already handles.
                    #if os(macOS)
                    .platformEscape { editingPathFor = nil; pathDraft = "" }
                    #endif
                Button {
                    commitPath(for: station)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                pathDraft = path
                editingPathFor = key
            } label: {
                HStack(spacing: 4) {
                    if path.isEmpty {
                        Text("direct")
                            .foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.purple)
                        Text(path.replacingOccurrences(of: ",", with: " \u{2192} "))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .opacity(isHoveringPath == key ? 1 : 0)
                }
                .font(.caption.monospaced())
                // The label is a few characters wide; the *cell* is not.
                // Without this the operator has to hit the text itself,
                // which is a tiny target in a dense table.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringPath = $0 ? key : nil }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHoveringPath == key ? Color.primary.opacity(0.06) : .clear))
            .help(path.isEmpty
                  ? "Direct \u{2014} no digipeaters. Click to set a path for \(station.callsign) on \(formatFrequency(station.frequencyHz)); it is remembered and used every time you exchange with this link."
                  : "Digipeated via \(path.replacingOccurrences(of: ",", with: " then ")). Stored for this callsign *and frequency*, so the same gateway on another band keeps its own path. Click to change; clear it for direct.")
        }
    }

    private func commitPath(for station: WinlinkRMSStationRecord) {
        settings.stationPreferences.setPath(pathDraft, for: station)
        editingPathFor = nil
        pathDraft = ""
    }

    // MARK: - Row menu

    /// Hiding lives in the context menu rather than a column: it is a
    /// rare action, and a permanent button for it would cost width every
    /// row forever.
    private func hideMenuItems(_ station: WinlinkRMSStationRecord) -> some View {
        Group {
            if settings.stationPreferences.isHidden(station) {
                Button("Show This Link") {
                    settings.stationPreferences.setHidden(false, for: station)
                }
            } else {
                Button("Hide This Link") {
                    settings.stationPreferences.setHidden(true, for: station)
                }
            }
        }
    }
}
