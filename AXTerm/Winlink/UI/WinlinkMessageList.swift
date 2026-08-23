import SwiftUI

/// Message table for the selected folder (NetRomRoutesView table idiom).
struct WinlinkMessageList: View {

    @ObservedObject var viewModel: WinlinkMailboxViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search subject, from, to…", text: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.searchText = $0 }))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if viewModel.filteredMessages.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(viewModel.searchText.isEmpty ? "No messages" : "No matches")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(viewModel.filteredMessages, selection: Binding(
                    get: { viewModel.selectedMID.map { Set([$0]) } ?? [] },
                    set: { viewModel.selectedMID = $0.first })) {

                    TableColumn("") { summary in
                        HStack(spacing: 2) {
                            if !summary.isRead {
                                Circle().fill(.blue).frame(width: 7, height: 7)
                            }
                            if summary.attachmentCount > 0 {
                                Image(systemName: "paperclip")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 26)
                        .help(summary.isRead ? "" : "Unread")
                    }
                    .width(30)

                    TableColumn("Correspondent") { summary in
                        Text(correspondent(of: summary))
                            .fontWeight(summary.isRead ? .regular : .semibold)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Subject") { summary in
                        Text(summary.subject.isEmpty ? "(no subject)" : summary.subject)
                            .fontWeight(summary.isRead ? .regular : .semibold)
                            .foregroundStyle(summary.subject.isEmpty ? .secondary : .primary)
                    }
                    .width(min: 140, ideal: 240)

                    TableColumn("Date") { summary in
                        Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 130)

                    TableColumn("State") { summary in
                        WinlinkDeliveryBadge(state: summary.deliveryState, error: summary.lastError)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Size") { summary in
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(summary.bodySize), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 70)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { mids in
                    if let mid = mids.first {
                        Button("Mark as Unread") { viewModel.markUnread(mid: mid) }
                        Menu("Move to") {
                            ForEach(viewModel.folders, id: \.id) { folder in
                                Button(folder.name) {
                                    if let id = folder.id { viewModel.move(mid: mid, toFolder: id) }
                                }
                            }
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) { viewModel.trash(mid: mid) }
                    }
                }
            }
        }
    }

    private func correspondent(of summary: WinlinkMessageSummary) -> String {
        switch summary.direction {
        case .inbound: return summary.fromAddr
        case .outbound: return summary.toAddrs.first ?? "—"
        }
    }
}

/// Small colored badge for a message's delivery state, with the
/// mandatory explanatory tooltip.
struct WinlinkDeliveryBadge: View {
    let state: WinlinkMessageStateRecord.DeliveryState
    var error: String?

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .help(error.map { "\(WinlinkCopy.deliveryStateTooltip)\n\nError: \($0)" }
                  ?? WinlinkCopy.deliveryStateTooltip)
    }

    private var label: String {
        switch state {
        case .draft: return "Draft"
        case .queued: return "Queued"
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .failed: return "Failed"
        case .received: return "Received"
        }
    }

    private var color: Color {
        switch state {
        case .draft: return .secondary
        case .queued: return .orange
        case .sending: return .blue
        case .sent: return .green
        case .failed: return .red
        case .received: return .teal
        }
    }
}
