#if os(iOS)
import SwiftUI

/// Downloads gateways for somewhere the operator is going.
///
/// The CMS has no geographic query — `gateway/status.json` returns every
/// public gateway in the world and AXTerm applies the radius on this device.
/// So this is not a heavier request than an ordinary refresh; it is the same
/// request, keeping more of the answer.
///
/// Regions are two-character Maidenhead **fields** rather than states or
/// countries, because a grid square is the only geography the CMS record
/// carries. Offering "Colorado" would mean inventing a boundary the data
/// cannot support and then quietly getting it wrong at the edges.
struct WinlinkTripDownloadSheet: View {

    @ObservedObject var viewModel: RMSStationsViewModel
    /// Where the operator is now, so their own field can be marked.
    let homeGrid: String

    @Environment(\.dismiss) private var dismiss
    @State private var available: [(field: String, count: Int)] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var result: String?

    private var homeField: String {
        String(homeGrid.uppercased().prefix(2))
    }

    var body: some View {
        List {
            Section {
                Text("Gateways for a region you are travelling to, kept separately from the ones near home. An ordinary refresh will not delete them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Do this while you still have a path to the internet — there is no way to fetch it from the field.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !viewModel.downloadedFields.isEmpty {
                Section("Already downloaded") {
                    ForEach(viewModel.downloadedFields, id: \.field) { entry in
                        HStack {
                            Text(entry.field).font(.body.monospaced())
                            Spacer()
                            Text("\(entry.count) gateways")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Remove downloaded regions", role: .destructive) {
                        viewModel.clearDownloaded()
                    }
                }
            }

            Section {
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Asking the CMS which regions have gateways\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if available.isEmpty {
                    Text("No regions came back. That usually means no network path or no API key.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(available, id: \.field) { entry in
                        Button {
                            if selected.contains(entry.field) {
                                selected.remove(entry.field)
                            } else {
                                selected.insert(entry.field)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(entry.field)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(entry.field)
                                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                Text(entry.field).font(.body.monospaced())
                                if entry.field == homeField {
                                    Text("your field")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                                Spacer()
                                Text("\(entry.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Regions")
            } footer: {
                Text("A Maidenhead field is roughly 10\u{00B0} of latitude by 20\u{00B0} of longitude — a few hundred miles across. It is the only geography the gateway list carries, so it is what regions are made of here.")
            }

            if let result {
                Section { Text(result).font(.callout) }
            }
        }
        .navigationTitle("Download for a Trip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Download") {
                    Task {
                        let count = await viewModel.downloadForTrip(gridFields: selected)
                        result = count == 0
                            ? "Nothing was downloaded."
                            : "Kept \(count) gateways across \(selected.count) region(s)."
                    }
                }
                .disabled(selected.isEmpty || viewModel.isRefreshing)
            }
        }
        .task {
            available = await viewModel.availableGridFields()
            loading = false
        }
    }
}
#endif
