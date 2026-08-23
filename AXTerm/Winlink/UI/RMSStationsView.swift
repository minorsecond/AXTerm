import SwiftUI

/// Nearby RMS packet gateways from the Winlink CMS, sorted by distance.
struct RMSStationsView: View {

    @ObservedObject var viewModel: RMSStationsViewModel
    var onConnect: (WinlinkRMSStationRecord) -> Void

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

    private var stationsTable: some View {
        Table(viewModel.stations, selection: .constant(Set<String>())) {
            TableColumn("Callsign") { station in
                Text(station.callsign).font(.body.monospaced())
            }
            .width(min: 90, ideal: 100)

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
        .tableStyle(.inset(alternatesRowBackgrounds: true))
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
}
