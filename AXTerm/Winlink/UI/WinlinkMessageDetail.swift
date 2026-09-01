import SwiftUI

/// Reading pane: headers, monospaced body, attachment chips, and
/// reply/forward actions.
struct WinlinkMessageDetail: View {

    /// The message to show, or nil for the placeholder. Passed in rather
    /// than read off a mailbox view model so the same view serves both
    /// the reading pane and a standalone message window.
    var stored: WinlinkStoredMessage?
    var onReply: (_ replyAll: Bool) -> Void
    var onForward: () -> Void
    /// The station's own town, so a state-wide forecast opens on the city
    /// the operator is actually in.
    var preferredLocality: String?
    /// True when the address already has an address-book entry.
    var knownContact: (String) -> Bool = { _ in true }
    /// Opens the contact editor prefilled with the address.
    var onAddContact: ((String) -> Void)?
    /// Imports a spatial attachment onto the map. Nil hides the action.
    ///
    /// Explicit rather than automatic: a layer appearing because a message
    /// arrived would be a stranger drawing on the operator's situational
    /// picture.
    var onAddToMap: ((WinlinkB2Message.Attachment, String) -> Void)?
    /// Opens this message in its own window. Nil hides the control —
    /// the standalone window itself has no use for it.
    var onOpenInWindow: (() -> Void)?

    /// The exchange that carried this message in, when one was recorded.
    /// Nil for mail that arrived another way, and for everything downloaded
    /// before the link existed — the control hides rather than pointing at a
    /// session picked by proximity in time.
    var carriedBySessionID: Int64?
    /// Opens the session history focused on the exchange that carried this.
    var onShowCarryingSession: ((Int64) -> Void)?

    @State private var saveError: String?
    @State private var pendingExport: ExportableFile?
    /// Derived off the main actor when the message changes — never in
    /// `body`. See `WinlinkRenderedBody`.
    @State private var rendered: WinlinkRenderedBody?
    @State private var wantsFullText = false

    var body: some View {
        if let stored {
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
                            // What this cost to fetch, and what the link
                            // looked like at the time — the question asked
                            // of a message that arrived late or truncated.
                            if let carriedBySessionID, let onShowCarryingSession {
                                Button {
                                    onShowCarryingSession(carriedBySessionID)
                                } label: {
                                    Label("Session", systemImage: "clock.arrow.circlepath")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Show the exchange that carried this message — how long it took, "
                                    + "on what frequency, and what else it brought.")
                            }
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
                        if let onOpenInWindow {
                            Button(action: onOpenInWindow) {
                                Label("Open in Window", systemImage: "macwindow")
                            }
                            .keyboardShortcut("o", modifiers: .command)
                            .help("Open this message in its own window (\u{2318}O). Wide products — tabular forecasts, station lists — need more width than a reading pane has.")
                        }
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
                if let form = receivedForm(in: message) {
                    WinlinkReceivedFormView(form: form)
                        .padding([.horizontal, .top], 12)
                }
                // Fixed-width NWS products get a real table; the view
                // keeps the raw text one disclosure away. Anything that
                // does not parse cleanly falls through unchanged rather
                // than being half-rendered.
                if let rendered {
                    switch rendered.content {
                    case .forecast(let forecast):
                        NWSTabularForecastView(forecast: forecast, rawText: rendered.raw,
                                               preferredLocality: preferredLocality)
                            .padding(12)
                    case .text(let attributed):
                        // Links are an overlay on the exact bytes received,
                        // never an edit — and clickable, never auto-opened.
                        Text(attributed)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .tint(.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        if rendered.isTruncated {
                            truncationFooter(rendered, message: message)
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(24)
                }

                // A product that arrived as an image cost airtime to
                // receive; showing it beats making the operator save it
                // somewhere and find it in the Finder.
                ForEach(imageAttachments(in: message), id: \.name) { attachment in
                    imagePreview(attachment)
                }
            }
        }
        // Keyed on the MID *and* the full-text flag, so switching messages
        // re-derives and "Show Everything" re-renders — and neither costs
        // anything on an unrelated update.
        .task(id: "\(message.mid)|\(wantsFullText)") {
            let body = message.body
            let wantsFull = wantsFullText
            let derived = await Task.detached(priority: .userInitiated) {
                WinlinkRenderedBody.make(body: body, fullText: wantsFull)
            }.value
            guard !Task.isCancelled else { return }
            rendered = derived
        }
        .onChange(of: message.mid) {
            // A new message starts capped again, and must not show the
            // previous one's text while its own is being derived.
            wantsFullText = false
            rendered = nil
        }
        .alert("Save failed", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .exportFile($pendingExport) { saveError = $0 }
    }

    /// Attachments this platform can actually decode as an image.
    /// Says exactly how much is being withheld and why, and offers both
    /// ways out: render the rest here, or save it and read it elsewhere.
    @ViewBuilder
    private func truncationFooter(_ rendered: WinlinkRenderedBody,
                                  message: WinlinkB2Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Showing the first \(byteText(rendered.shownCharacters)) of \(byteText(rendered.totalCharacters)). "
                 + "A message this long takes a noticeable moment to lay out, so the rest is one click away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show Everything") { wantsFullText = true }
                Button("Save as Text\u{2026}") {
                    pendingExport = ExportableFile(
                        name: exportName(for: message),
                        data: Data(rendered.raw.utf8))
                }
                Spacer()
            }
        }
        .padding(12)
    }

    private func byteText(_ characters: Int) -> String {
        ByteCount.string(Int64(characters))
    }

    /// A filename that says which message this came from.
    private func exportName(for message: WinlinkB2Message) -> String {
        let subject = message.subject
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let stem = subject.isEmpty ? message.mid : String(subject.prefix(60))
        return "\(stem).txt"
    }

    private func imageAttachments(in message: WinlinkB2Message) -> [WinlinkB2Message.Attachment] {
        message.attachments.filter { attachment in
            let ext = (attachment.name as NSString).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "gif", "tif", "tiff", "bmp"].contains(ext)
        }
    }

    @ViewBuilder
    private func imagePreview(_ attachment: WinlinkB2Message.Attachment) -> some View {
        if let image = PlatformImage(data: attachment.data) {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text(attachment.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .help("\(attachment.name) — \(ByteCount.string(Int64(attachment.data.count))) as received. Right-click the chip above to save it.")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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
                    Text(ByteCount.string(Int64(attachment.data.count)))
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
        .contextMenu {
            Button("Save…") { saveAttachment(attachment) }
            if let onAddToMap, let kind = MapOverlayAttachment.kind(forAttachmentNamed: attachment.name) {
                Button("Add to Map (\(kind.displayName))") {
                    onAddToMap(attachment, stored?.message.from ?? "")
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // A small map badge on anything the map could take, so the
            // operator can see at a glance that a message carries spatial
            // data rather than discovering it by right-clicking everything.
            if onAddToMap != nil,
               MapOverlayAttachment.kind(forAttachmentNamed: attachment.name) != nil {
                Image(systemName: "map.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.white)
                    .padding(2)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 4, y: -4)
            }
        }
    }

    private func receivedForm(in message: WinlinkB2Message) -> WinlinkReceivedForm? {
        for attachment in message.attachments where WinlinkReceivedForm.isFormAttachment(attachment.name) {
            if let form = WinlinkReceivedForm.parse(attachment.data) {
                return form
            }
        }
        return nil
    }

    /// Hands the attachment to the operator to file wherever they like.
    ///
    /// Failure is surfaced, never swallowed: a silent `try?` here made a
    /// failed save look exactly like a successful one, and the attachment
    /// may be the only copy of something that cost airtime to receive.
    private func saveAttachment(_ attachment: WinlinkB2Message.Attachment) {
        pendingExport = ExportableFile(name: attachment.name, data: attachment.data)
    }
}
