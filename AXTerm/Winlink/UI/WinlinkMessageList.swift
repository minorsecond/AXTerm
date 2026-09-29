import SwiftUI

/// Message table for the selected folder (NetRomRoutesView table idiom).
struct WinlinkMessageList: View {

    @ObservedObject var viewModel: WinlinkMailboxViewModel
    /// Set while a permanent deletion is waiting to be confirmed. Nothing
    /// in this view destroys mail without passing through here.
    @State private var pendingDeletion: Set<String>?
    /// Set while a *bulk* move to the Trash waits to be confirmed. A single
    /// message never gets here — see `onDeleteCommand`.
    @State private var pendingTrash: Set<String>?
    /// The window's undo stack, so ⌘Z and Edit ▸ Undo both work and the
    /// menu item names the action.
    @Environment(\.undoManager) private var undoManager
    /// Double-click and the context menu both open a message in its own
    /// window — the habitual mail-client gesture.
    var onOpenInWindow: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                TextField("Search subject, from, to…", text: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.searchText = $0 }))
                    .textFieldStyle(.plain)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, searchFieldPadding)
            #if os(iOS)
            // A field with a visible well reads as somewhere to type; the
            // bare row above the list read as a header.
            .background(Color(platform: .platformCardBackground),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            #else
            .padding(.horizontal, 1)
            #endif
            Divider()

            if viewModel.filteredMessages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: viewModel.searchText.isEmpty
                          ? "tray" : "magnifyingglass")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text(viewModel.searchText.isEmpty ? "No messages" : "No matches")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(viewModel.searchText.isEmpty
                         ? "Start an exchange with a gateway to collect mail."
                         : "No message in this folder matches \u{201C}\(viewModel.searchText)\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                #if os(iOS)
                touchList
                #else
                // Bound straight to the set. Routing it through a single
                // optional is what made Select All and shift-click land on
                // one row.
                Table(viewModel.filteredMessages, selection: $viewModel.selectedMIDs) {

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

                    // Only in the Trash, where "when did this go?" is the
                    // question. Everywhere else it would be an empty column
                    // with a header promising something.
                    if viewModel.isViewingTrash {
                    TableColumn("Deleted") { summary in
                        if let trashedAt = summary.trashedAt {
                            Text(trashedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                                .help("Moved to the Trash on "
                                      + trashedAt.formatted(date: .long, time: .standard))
                        } else if viewModel.isViewingTrash {
                            // Trashed before the date was recorded. Saying
                            // so beats an invented one.
                            Text("—")
                                .foregroundStyle(.tertiary)
                                .help("Deleted before AXTerm recorded deletion dates.")
                        }
                    }
                    .width(min: 100, ideal: 130)
                    }

                    TableColumn("State") { summary in
                        WinlinkDeliveryBadge(state: summary.deliveryState, error: summary.lastError)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Size") { summary in
                        Text(ByteCount.string(Int64(summary.bodySize)))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 70)
                }
                .platformInsetTable()
                // Every item acts on the whole selection. Right-clicking
                // one of six selected messages and having "Move to Trash"
                // take one of them is worse than not offering it.
                .contextMenu(forSelectionType: String.self) { mids in
                    if !mids.isEmpty {
                        if let onOpenInWindow, mids.count == 1, let mid = mids.first {
                            Button("Open in Window") { onOpenInWindow(mid) }
                            Divider()
                        }
                        if viewModel.isViewingTrash {
                            // Finder's word for it, and now that the origin
                            // is recorded it means the same thing: back to
                            // the folder it actually came from.
                            Button(label("Put Back", mids)) { viewModel.putBack(mids: mids) }
                            Divider()
                        }
                        Button(label("Mark as Unread", mids)) { viewModel.markUnread(mids: mids) }
                        Menu(label("Move", mids) + " to") {
                            ForEach(viewModel.folders, id: \.id) { folder in
                                Button(folder.name) {
                                    if let id = folder.id {
                                        viewModel.move(mids: mids, toFolder: id)
                                    }
                                }
                            }
                        }
                        Divider()
                        // Inside the Trash there is nowhere further to file
                        // mail, so Delete means what it says there and only
                        // there.
                        if viewModel.isViewingTrash {
                            Button(label("Delete", mids) + " Permanently", role: .destructive) {
                                pendingDeletion = mids
                            }
                        } else {
                            Button(label("Move", mids) + " to Trash", role: .destructive) {
                                viewModel.trash(mids: mids)
                            }
                        }
                    }
                } primaryAction: { mids in
                    // Table's primaryAction is the double-click.
                    if mids.count == 1, let mid = mids.first { onOpenInWindow?(mid) }
                }
                // Delete moves the selection to the trash, which is what
                // the key does in every other mail client.
                // ⌫ moves the selection to the Trash, as it does in
                // Mail. No dialog for a single message: it is reversible,
                // and a prompt on every keystroke is how operators learn to
                // dismiss prompts — which is exactly the habit the
                // permanent-delete dialog cannot afford.
                //
                // A whole selection is different. Twenty messages vanishing
                // at once is disorienting even when it can be taken back,
                // so that one asks.
                .onDeleteCommand {
                    let selection = viewModel.selectedMIDs
                    guard !selection.isEmpty else { return }
                    if viewModel.isViewingTrash {
                        pendingDeletion = selection
                    } else if selection.count > 1 {
                        pendingTrash = selection
                    } else {
                        trash(selection)
                    }
                }
                #endif
            }
        }
        // The only path to a permanent delete in this view, and it always
        // says how many and that it cannot be undone. Mail that cost
        // airtime to receive deserves the extra keystroke.
        .confirmationDialog(
            deletionPrompt,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let mids = pendingDeletion { viewModel.deleteForever(mids: mids) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This cannot be undone, here or on your other devices.")
        }
        .confirmationDialog(
            "Move \(pendingTrash?.count ?? 0) messages to the Trash?",
            isPresented: Binding(
                get: { pendingTrash != nil },
                set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash") {
                if let mids = pendingTrash { trash(mids) }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("You can put them back with Undo.")
        }
    }

    /// Moves to the Trash and arms the window's undo, so ⌘Z reads
    /// "Undo Move to Trash" and puts each message back where it came from.
    private func trash(_ mids: Set<String>) {
        viewModel.trash(mids: mids)
        guard let undoManager, viewModel.canUndoTrash else { return }
        undoManager.registerUndo(withTarget: viewModel) { model in
            // The undo manager calls back on the main thread; the model is
            // main-actor isolated and this is where that is asserted.
            MainActor.assumeIsolated { model.undoLastTrash() }
        }
        undoManager.setActionName(mids.count == 1
                                  ? "Move to Trash"
                                  : "Move \(mids.count) Messages to Trash")
    }

    private var deletionPrompt: String {
        let count = pendingDeletion?.count ?? 0
        return count == 1
            ? "Delete this message permanently?"
            : "Delete \(count) messages permanently?"
    }

#if os(macOS)
    /// "Move to Trash" for one, "Move 6 to Trash" for a selection — so a
    /// destructive item always says how much it is about to affect.
    private func label(_ verb: String, _ mids: Set<String>) -> String {
        mids.count > 1 ? "\(verb) \(mids.count)" : verb
    }
#endif

#if os(iOS)
    /// The same messages as a touch list.
    ///
    /// `Table` is not usable here: iOS renders only its **first** column, and
    /// this table's first column is a 30pt indicator holding an unread dot and
    /// a paperclip. A read message with no attachment therefore drew a row
    /// with nothing in it — the mailbox looked empty while holding mail, which
    /// reads as sync being broken rather than as a layout bug.
    private var touchList: some View {
        List(viewModel.filteredMessages, selection: Binding(
            get: { viewModel.selectedMID },
            set: { viewModel.selectedMID = $0 })) { summary in
            row(for: summary)
                .swipeActions(edge: .trailing) {
                    // Swiping in the Trash used to file a message into the
                    // folder it was already in, which looked like the swipe
                    // had failed.
                    if viewModel.isViewingTrash {
                        Button("Delete", systemImage: "trash.slash", role: .destructive) {
                            pendingDeletion = [summary.id]
                        }
                    } else {
                        Button("Trash", systemImage: "trash", role: .destructive) {
                            viewModel.trash(mid: summary.id)
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    if summary.isRead {
                        Button("Unread", systemImage: "envelope.badge") {
                            viewModel.markUnread(mid: summary.id)
                        }
                        .tint(.blue)
                    }
                }
        }
        .listStyle(.plain)
    }

    /// A traditional mail-client row: who, when, what — then the packet
    /// details that a Winlink operator needs and an email user never sees.
    ///
    /// Airtime is the scarce resource on a packet link, so size stays on the
    /// row; it just stops competing with the subject for the eye.
    @ViewBuilder
    private func row(for summary: WinlinkMessageSummary) -> some View {
        let model = WinlinkMessageRowModel.make(summary)
        HStack(alignment: .top, spacing: 10) {
            // Holds its width whether or not it draws, so every row's text
            // starts on the same vertical line.
            Circle()
                .fill(model.isUnread ? Color.accentColor : .clear)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.correspondent)
                        .font(.body.weight(model.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(model.dateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Text(model.subject)
                    .font(.subheadline)
                    .foregroundStyle(model.subjectIsPlaceholder ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if model.showsAttachmentIndicator {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(model.sizeLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    // Only when it says something the folder does not.
                    if let badge = model.badge {
                        WinlinkDeliveryBadge(state: badge, error: summary.lastError)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

#endif

    private var searchFieldPadding: CGFloat {
        #if os(iOS)
        return 9
        #else
        return 6
        #endif
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
