#if os(iOS)
import SwiftUI

/// RMS gateways this station knows about, on a handheld.
///
/// Deliberately not the Mac's table transplanted onto a phone. The Mac shows
/// every column at once because it has the width; here each gateway is a row
/// that leads with the two things that decide whether to call it — how far
/// away it is and whether it has ever answered *from here* — and puts the
/// rest behind a tap.
///
/// The honesty rule from `WinlinkLinkQuality` carries over intact: a
/// measurement taken somewhere else is shown as history, never as a
/// prediction. A handheld is the device most likely to be somewhere other
/// than where the samples were taken, so this matters more here, not less.
struct WinlinkStationsScreen: View {

    /// The live list. iOS previously read the cache straight from the store,
    /// which meant the screen could show "no gateways cached — fetch it while
    /// you have a path" and offer no way to fetch anything. The Mac has had a
    /// Refresh button since this view model was written; this platform simply
    /// never got one.
    @ObservedObject var viewModel: RMSStationsViewModel
    let observerGrid: String
    /// Tapping a gateway opens the same identity page a terminal callsign
    /// opens. A row used to answer "who is this?" with a popover that
    /// covered the list it came from.
    @EnvironmentObject private var profiles: NodeProfileCoordinator

    @State private var search = ""
    @State private var scope: WinlinkRMSStationRecord.Scope?
    @State private var showingTripDownload = false

    /// Nil scope means both sets. The picker only appears once a trip set
    /// exists — before that there is nothing to choose between.
    private var stations: [WinlinkRMSStationRecord] {
        guard let scope else { return viewModel.stations }
        return viewModel.stations.filter { $0.scope == scope }
    }

    private var hasDownloaded: Bool {
        viewModel.stations.contains { $0.scope == .global }
    }
    private var linkQuality: [String: WinlinkLinkQuality] { viewModel.linkQuality }

    var body: some View {
        List(filtered, id: \.id) { station in
            Button {
                profiles.openPage(station.callsign)
            } label: {
                row(for: station)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .leading) {
                // A downloaded gateway is a legitimate rung — carrying one is
                // the reason for downloading it. The row shows its distance,
                // so a rung added for a trip is recognisable as such later.
                if viewModel.isInLadder(station) {
                    Button {
                        viewModel.removeFromLadder(station)
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                    .tint(.orange)
                } else {
                    Button {
                        viewModel.addToLadder(station)
                    } label: {
                        Label("Ladder", systemImage: "plus.circle")
                    }
                    .tint(.accentColor)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Callsign or grid")
        .safeAreaInset(edge: .top) {
            if hasDownloaded {
                Picker("Set", selection: $scope) {
                    Text("All").tag(WinlinkRMSStationRecord.Scope?.none)
                    Text("Near home").tag(WinlinkRMSStationRecord.Scope?.some(.local))
                    Text("Downloaded").tag(WinlinkRMSStationRecord.Scope?.some(.global))
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showingTripDownload) {
            NavigationStack {
                WinlinkTripDownloadSheet(viewModel: viewModel, homeGrid: observerGrid)
            }
        }
        .refreshable { await viewModel.refresh() }
        .navigationTitle("Stations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingTripDownload = true
                } label: {
                    Label("Download for a Trip", systemImage: "arrow.down.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRefreshing)
            }
        }
        .overlay {
            if stations.isEmpty && !viewModel.isRefreshing {
                ContentUnavailableView {
                    Label("No gateways cached",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("The gateway list comes from the Winlink web service and is cached for offline use. Fetch it while you have a path, and it stays usable when you do not.")
                } actions: {
                    // The empty state used to name an action the screen did
                    // not have.
                    Button("Fetch Gateway List") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let error = viewModel.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            } else if let fetchedAt = viewModel.fetchedAt {
                Text("Updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private var filtered: [WinlinkRMSStationRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).uppercased()
        guard !query.isEmpty else { return stations }
        return stations.filter {
            $0.callsign.uppercased().contains(query) || $0.gridSquare.uppercased().contains(query)
        }
    }

    @ViewBuilder
    private func row(for station: WinlinkRMSStationRecord) -> some View {
        let quality = linkQuality["\(station.callsign)@\(station.frequencyHz)"]
            ?? linkQuality[station.callsign]

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if viewModel.isInLadder(station) {
                    Image(systemName: "list.number")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                Text(station.callsign)
                    .font(.headline.monospaced())
                if station.scope == .global {
                    Text(station.gridField)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(frequency(station.frequencyHz))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(colour(for: quality))
                    .frame(width: 8, height: 8)
                Text(qualityLabel(quality))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(station.gridSquare)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Presentation

    private func frequency(_ hz: Int) -> String {
        String(format: "%.3f MHz", Double(hz) / 1_000_000)
    }

    /// Grey means unknown, and unknown is not bad. A gateway never worked
    /// from here has no measurement, which says nothing about whether it
    /// would answer.
    private func colour(for quality: WinlinkLinkQuality?) -> Color {
        guard let quality, quality.appliesHere, let rate = quality.answerRate else {
            return .secondary
        }
        if rate >= 0.7 { return .green }
        if rate >= 0.3 { return .yellow }
        return .orange
    }

    private func qualityLabel(_ quality: WinlinkLinkQuality?) -> String {
        guard let quality else { return "Never worked from here" }
        guard let rate = quality.answerRate else { return "No attempts recorded" }
        let percent = Int((rate * 100).rounded())
        if quality.appliesHere {
            return "Answered \(percent)% of \(quality.attempts) from here"
        }
        return "Answered \(percent)% elsewhere — not a prediction here"
    }

    /// Says why the row reads the way it does, per CLAUDE.md §11.
    private func explanation(for station: WinlinkRMSStationRecord,
                             quality: WinlinkLinkQuality?) -> String {
        var lines = ["\(station.callsign) on \(frequency(station.frequencyHz)), grid \(station.gridSquare)."]

        guard let quality else {
            lines.append("This station has never worked this gateway, so there is no measurement. Grey means unknown, which is not the same as bad — an unworked gateway may answer perfectly.")
            return lines.joined(separator: "\n\n")
        }

        lines.append("\(quality.answered) of \(quality.attempts) attempts were answered; \(quality.completed) finished the exchange. Answering and completing are different problems: a gateway that never answers is out of reach, while one that answers and fails is a marginal path.")

        switch quality.placement {
        case .here:
            lines.append("Measured from essentially where you are now, so it applies.")
        case .nearby(let km):
            lines.append(String(format: "Measured %.1f km from here. Probably the same path, but terrain can change it completely across a ridge.", km))
        case .elsewhere(let grid, let km):
            lines.append(String(format: "Measured in %@, %.0f km away. Shown as history, not as a prediction — that was a different link.", grid, km))
        case .unknown:
            lines.append("These samples carry no position, so whether they describe the path from here is unknown.")
        }
        return lines.joined(separator: "\n\n")
    }
}
#endif
