import SwiftUI
import AppKit

/// Reading pane: headers, monospaced body, attachment chips, and
/// reply/forward actions.
struct WinlinkMessageDetail: View {

    @ObservedObject var viewModel: WinlinkMailboxViewModel
    var onReply: (_ replyAll: Bool) -> Void
    var onForward: () -> Void
    /// True when the address already has an address-book entry.
    var knownContact: (String) -> Bool = { _ in true }
    /// Opens the contact editor prefilled with the address.
    var onAddContact: ((String) -> Void)?

    var body: some View {
        if let stored = viewModel.selectedMessage {
            content(for: stored)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Select a message")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(for stored: WinlinkStoredMessage) -> some View {
        let message = stored.message
        return VStack(alignment: .leading, spacing: 0) {
            // Header block
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            headerRow("From", message.from)
                            if let onAddContact,
                               message.from.uppercased() != "SERVICE",
                               !knownContact(message.from) {
                                Button {
                                    onAddContact(message.from)
                                } label: {
                                    Image(systemName: "person.badge.plus")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Add \(message.from) to your contacts")
                            }
                        }
                        headerRow("To", message.to.joined(separator: ", "))
                        if !message.cc.isEmpty {
                            headerRow("Cc", message.cc.joined(separator: ", "))
                        }
                        headerRow("Date", message.date.formatted(date: .abbreviated, time: .shortened))
                        HStack(spacing: 6) {
                            Text("MID \(message.mid)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .help("Winlink message ID — unique across the whole network; used for de-duplication.")
                            WinlinkDeliveryBadge(
                                state: stored.state.state ?? .received,
                                error: stored.state.lastError)
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button { onReply(false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                            .help("Reply to the sender")
                        Button { onReply(true) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                            .help("Reply to the sender and all other recipients")
                        Button { onForward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                            .help("Forward this message (attachments included)")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)

            if !message.attachments.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                            attachmentChip(attachment)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            ScrollView {
                Text(bodyText(of: message))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private func headerRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private func attachmentChip(_ attachment: WinlinkB2Message.Attachment) -> some View {
        Button {
            saveAttachment(attachment)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperclip")
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.name).font(.caption)
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(attachment.data.count), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Save \"\(attachment.name)\" to disk")
    }

    private func bodyText(of message: WinlinkB2Message) -> String {
        String(data: message.body, encoding: .isoLatin1) ?? "(body could not be decoded)"
    }

    private func saveAttachment(_ attachment: WinlinkB2Message.Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? attachment.data.write(to: url)
        }
    }
}
