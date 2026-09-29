//
//  BBSMessagesPane.swift
//  AXTerm
//

import SwiftUI

// The mailbox UI is macOS-only, like the window layout it lives in. The shell,
// the store and the service are platform-neutral, so an iOS view can be added
// later without touching anything below this layer.
#if os(macOS)

/// The mailbox itself: list on the left, the message on the right.
struct BBSMessagesPane: View {
    @ObservedObject var service: BBSService
    let sysop: String
    /// Other instances' mailboxes. Nil where mailbox sharing is off, and then
    /// this pane behaves exactly as it did before there was such a thing.
    var remoteMailbox: BBSMailboxReplicationStore?

    /// Shared with the iOS mailbox, along with the empty-state wording — see
    /// `BBSMailboxModels`. Two platforms deciding separately what counts as
    /// the sysop's mail is two chances to get the access model wrong.
    typealias Filter = BBSMessageFilter

    @State private var filter: Filter = .mine
    /// A row id, not a message number: two mailboxes can both hold a
    /// "Message 12" and they are different messages.
    @State private var selection: String?
    @State private var composing = false
    @State private var replyTo: BBSMessage?

    /// Off, and remembered — see `BBSCallersPane`. Nothing from another
    /// station appears in this list until the operator asks for it.
    @AppStorage("bbs.showsOtherMailboxes") private var showsOtherMailboxes = false
    @State private var remoteMessages: [BBSMessagePayload] = []

    var body: some View {
        splitView
            .task { reloadRemote() }
            .onChange(of: showsOtherMailboxes) { _, _ in reloadRemote() }
    }

    private var splitView: some View {
        HSplitView {
            list
                .frame(minWidth: 280, idealWidth: 340)
            detail
                .frame(minWidth: 320)
        }
        .sheet(isPresented: $composing) {
            BBSComposeSheet(sysop: sysop, replyingTo: replyTo) { to, subject, body in
                service.sysopPost(to: to, subject: subject, body: body)
            }
        }
    }

    // MARK: - List

    /// This mailbox first, then one section per other mailbox — never
    /// interleaved, so a message number is always read against the mailbox
    /// that issued it.
    private var sections: [BBSUnifiedListing.Section<BBSUnifiedListing.MessageRow>] {
        BBSUnifiedListing.messageSections(local: service.messages,
                                          remote: remoteMessages,
                                          showsOtherInstances: showsOtherMailboxes,
                                          filter: filter, sysop: sysop)
    }

    private var rows: [BBSUnifiedListing.MessageRow] { sections.flatMap(\.rows) }

    private var selectedRow: BBSUnifiedListing.MessageRow? {
        rows.first { $0.id == selection }
    }

    private var showsChip: Bool {
        BBSRemoteMailbox.showsToggle(hasStore: remoteMailbox != nil,
                                     remoteCount: remoteMessages.count,
                                     isOn: showsOtherMailboxes)
    }

    private func reloadRemote() {
        guard BBSRemoteMailbox.shouldLoadRemote(hasStore: remoteMailbox != nil) else {
            remoteMessages = []
            return
        }
        remoteMessages = (try? remoteMailbox?.remoteMessages(limit: 500)) ?? []
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            if showsChip {
                HStack {
                    BBSOtherMailboxesChip(isOn: $showsOtherMailboxes)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            if rows.isEmpty {
                emptyList
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows) { messageRow in
                                row(messageRow).tag(messageRow.id)
                            }
                        } header: {
                            if let title = section.title {
                                BBSMailboxSectionHeader(title: title,
                                                        attribution: section.attribution,
                                                        isRemote: section.isRemote)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            if showsChip {
                Text(BBSUnifiedListing.countLine(
                    local: sections.first(where: { !$0.isRemote })?.rows.count ?? 0,
                    remote: sections.filter(\.isRemote).reduce(0) { $0 + $1.rows.count },
                    noun: "message"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
    }

    private func row(_ messageRow: BBSUnifiedListing.MessageRow) -> some View {
        let message = messageRow.message
        let isUnread = BBSMessageActions.forRow(message: message, origin: messageRow.origin,
                                                sysop: sysop).showsUnread
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isUnread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                BBSOriginLabel(label: messageRow.origin.label)
                HStack(spacing: 6) {
                    Text(message.from.uppercased())
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(isUnread ? .semibold : .regular)
                    if message.isBulletin {
                        Text("BULLETIN")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    Text("#\(message.id)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(message.subject)
                    .font(.callout)
                    .lineLimit(1)
                    .strikethrough(message.killedAt != nil)
                    .foregroundStyle(message.killedAt != nil ? .secondary : .primary)
                Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(emptyTitle).font(.callout).foregroundStyle(.secondary)
            Text(emptyDetail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String { filter.emptyTitle }

    private var emptyDetail: String { filter.emptyDetail(sysop: sysop) }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected = selectedRow {
            messageView(selected)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("Select a message").foregroundStyle(.secondary)
                Button("New Message…") { replyTo = nil; composing = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func messageView(_ row: BBSUnifiedListing.MessageRow) -> some View {
        let message = row.message
        let actions = BBSMessageActions.forRow(message: message, origin: row.origin,
                                               sysop: sysop)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                // Which station actually took this, said before anything else
                // about it: the number and the read flag below belong to that
                // mailbox, not to this one.
                if let banner = BBSRemoteMailbox.banner(for: row.origin) {
                    Label(banner, systemImage: "laptopcomputer.and.iphone")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .explain(BBSRemoteMailbox.attributionExplanation)
                }
                Text(message.subject)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("#\(message.id)").monospacedDigit()
                    Text("·")
                    Text("\(message.from.uppercased()) → \(message.to.uppercased())")
                        .font(.system(.caption, design: .monospaced))
                    Text("·")
                    Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let killedAt = message.killedAt {
                    Label("Killed \(killedAt.formatted(date: .abbreviated, time: .shortened)) — hidden from callers",
                          systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                Text(message.body.isEmpty ? "(no text)" : message.body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .toolbar { toolbar(for: message, actions: actions) }
        .onAppear { markRead(message, actions: actions) }
        .onChange(of: selection) { markRead(message, actions: actions) }
    }

    /// What the toolbar offers is decided in `BBSMessageActions`, so a
    /// surface cannot quietly grow a Kill button over another mailbox's
    /// history by forgetting a condition.
    @ToolbarContentBuilder
    private func toolbar(for message: BBSMessage,
                         actions: BBSMessageActions) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                replyTo = message
                composing = true
            } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .disabled(!actions.canReply)

            Button { replyTo = nil; composing = true } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }

            if actions.canKill {
                Button(role: .destructive) { service.sysopKill(id: message.id) } label: {
                    Label("Kill", systemImage: "trash")
                }
            } else if actions.canRestore {
                Button { service.sysopRestore(id: message.id) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private func markRead(_ message: BBSMessage, actions: BBSMessageActions) {
        // Reading your own mail in the app is the same fact as reading it over
        // the air — see `BBSMessage.readAt`. Reading somebody else's mailbox's
        // mail here is not that fact at all, so it stamps nothing.
        guard actions.marksRead else { return }
        service.sysopMarkRead(id: message.id)
    }
}
#endif
