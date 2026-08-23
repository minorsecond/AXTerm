import SwiftUI

/// Winlink catalog browser: pick data products (weather, bulletins…),
/// queue a request message, receive the products as mail later.
struct WinlinkCatalogSheet: View {

    @ObservedObject var viewModel: WinlinkCatalogViewModel
    let myCallsign: String
    var onQueued: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var queuedConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Winlink Catalog")
                    .font(.headline)
                    .help(WinlinkCopy.catalogTooltip)
                Spacer()
                if let fetchedAt = viewModel.fetchedAt {
                    Text("Updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                .help(WinlinkCopy.catalogRefreshTooltip)
            }
            .padding(12)
            Divider()

            if let error = viewModel.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if viewModel.groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No catalog cached yet")
                        .font(.headline)
                    Text("The catalog web service needs a personal access key, but every station can request the catalog **over the air**: queue a LIST inquiry, send it with Connect & Exchange, and the index arrives as mail.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        if viewModel.queueCatalogListRequest(myCallsign: myCallsign) != nil {
                            queuedConfirmation = true
                            onQueued()
                        }
                    } label: {
                        Label("Request Catalog by Radio", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .help("Queues a LIST inquiry to INQUIRY in your Outbox — no internet or access key needed.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.groups) { group in
                        Section(group.category) {
                            ForEach(group.items, id: \.inquiryId) { item in
                                row(for: item)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                if !viewModel.selection.isEmpty {
                    Text("\(viewModel.selection.count) selected · ≈\(ByteCountFormatter.string(fromByteCount: Int64(viewModel.selectedSizeEstimate), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(WinlinkCopy.catalogSizeTooltip)
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Request \(viewModel.selection.count) Item\(viewModel.selection.count == 1 ? "" : "s")") {
                    if viewModel.queueRequest(myCallsign: myCallsign) != nil {
                        queuedConfirmation = true
                        onQueued()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.selection.isEmpty)
                .help("Queues a request message to INQUIRY in your Outbox. Send it with Connect & Exchange; the data arrives as mail at a later exchange.")
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 460)
        .alert("Request queued", isPresented: $queuedConfirmation) {
            Button("OK") { dismiss() }
        } message: {
            Text("The catalog request is in your Outbox. Run Connect & Exchange to send it; the response arrives as ordinary mail on a later exchange.")
        }
    }

    private func row(for item: WinlinkCatalogItemRecord) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { viewModel.selection.contains(item.inquiryId) },
                set: { selected in
                    if selected {
                        viewModel.selection.insert(item.inquiryId)
                    } else {
                        viewModel.selection.remove(item.inquiryId)
                    }
                })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.subject.isEmpty ? item.inquiryId : item.subject)
                    Text(item.inquiryId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.sizeEstimate), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(WinlinkCopy.catalogSizeTooltip)
        }
    }
}
