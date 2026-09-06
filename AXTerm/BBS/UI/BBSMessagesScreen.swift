//
//  BBSMessagesScreen.swift
//  AXTerm
//
//  The mailbox itself, on a handheld: a filtered list and a reader.
//

#if os(iOS)
import SwiftUI

/// The message list.
///
/// A `List` rather than the Mac's `Table`: a table in the narrow content
/// column of a split view renders its first column and nothing else, which
/// here would be a page of blank rows over a mailbox holding mail — the same
/// failure that made the Winlink mailbox look empty for a long time.
struct BBSMessageListScreen: View {

    @ObservedObject var service: BBSService
    let sysop: String
    @Binding var filter: BBSMessageFilter
    /// The row the detail column is showing, by row id — not a message
    /// number: two mailboxes can both hold a "Message 12" and they are
    /// different messages. Unused in `.pushed`, where the stack remembers.
    @Binding var selection: String?
    /// This mailbox first, then one section per other mailbox. Built by
    /// `BBSScreen` so the list and the detail column cannot disagree about
    /// what is in the list.
    let sections: [BBSUnifiedListing.Section<BBSUnifiedListing.MessageRow>]
    @Binding var showsOtherMailboxes: Bool
    /// Whether to offer the chip at all — `BBSRemoteMailbox.showsToggle`.
    let showsChip: Bool
    let onCompose: () -> Void
    let onRefresh: () -> Void
    /// Only used in `.pushed`, where this screen builds the reader itself.
    /// In `.tab` the detail column does, and these are never called.
    var onReply: ((BBSMessage) -> Void)?
    var onOpenProfile: ((String) -> Void)?
    var presentation: BBSScreenPresentation = .tab

    private var rows: [BBSUnifiedListing.MessageRow] { sections.flatMap(\.rows) }

    private var localCount: Int {
        sections.first(where: { !$0.isRemote })?.rows.count ?? 0
    }

    private var remoteCount: Int {
        sections.filter(\.isRemote).reduce(0) { $0 + $1.rows.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(BBSMessageFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if showsChip {
                HStack {
                    BBSOtherMailboxesChip(isOn: $showsOtherMailboxes)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if rows.isEmpty {
                BBSEmptyState(systemImage: filter == .killed ? "trash" : "tray",
                              title: filter.emptyTitle,
                              detail: filter.emptyDetail(sysop: sysop))
            } else if presentation.ownsNavigation {
                List(selection: $selection) {
                    sectionedRows { messageRow in
                        row(messageRow)
                            .tag(messageRow.id)
                            .swipeActions(edge: .trailing) { swipeActions(messageRow) }
                    }
                }
                .listStyle(.plain)
            } else {
                List {
                    sectionedRows { messageRow in
                        NavigationLink {
                            detail(for: messageRow)
                        } label: {
                            row(messageRow)
                        }
                        .swipeActions(edge: .trailing) { swipeActions(messageRow) }
                    }
                }
                .listStyle(.plain)
            }

            if showsChip {
                Text(BBSUnifiedListing.countLine(local: localCount, remote: remoteCount,
                                                 noun: "message"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
        }
        .refreshable { onRefresh() }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onCompose()
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
            }
        }
    }

    /// The sections, however each row is made to navigate.
    @ViewBuilder
    private func sectionedRows<Row: View>(
        @ViewBuilder row: @escaping (BBSUnifiedListing.MessageRow) -> Row) -> some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.rows) { messageRow in
                    row(messageRow)
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

    /// The reader for one row, built here because in `.pushed` there is no
    /// detail column to build it.
    private func detail(for messageRow: BBSUnifiedListing.MessageRow) -> some View {
        BBSMessageDetailScreen(
            service: service,
            sysop: sysop,
            // Looked up live for this mailbox's own mail, so a kill or a read
            // landing while the reader is open changes what is on screen.
            // A remote row is a snapshot: nothing here can change it.
            message: messageRow.origin == .thisMailbox
                ? service.messages.first { $0.id == messageRow.message.id }
                : messageRow.message,
            origin: messageRow.origin,
            onReply: { onReply?($0) },
            onCompose: onCompose,
            onOpenProfile: onOpenProfile)
    }

    /// Killing is not deleting. Mail is append-only, so this sets a flag and
    /// the Killed filter can put it back — and it is offered only for this
    /// mailbox's own history.
    @ViewBuilder
    private func swipeActions(_ messageRow: BBSUnifiedListing.MessageRow) -> some View {
        let actions = BBSMessageActions.forRow(message: messageRow.message,
                                               origin: messageRow.origin, sysop: sysop)
        if actions.canKill {
            Button("Kill", systemImage: "trash", role: .destructive) {
                service.sysopKill(id: messageRow.message.id)
            }
        } else if actions.canRestore {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                service.sysopRestore(id: messageRow.message.id)
            }
            .tint(.blue)
        }
    }

    private func row(_ messageRow: BBSUnifiedListing.MessageRow) -> some View {
        let message = messageRow.message
        // Unread is a fact about this mailbox's own mail — see
        // `BBSMessageActions.showsUnread`.
        let isUnread = BBSMessageActions.forRow(message: message, origin: messageRow.origin,
                                                sysop: sysop).showsUnread
        return HStack(alignment: .top, spacing: 10) {
            // Holds its width whether or not it draws, so every row's text
            // starts on the same vertical line.
            Circle()
                .fill(isUnread ? Color.accentColor : .clear)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                BBSOriginLabel(label: messageRow.origin.label)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.from.uppercased())
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if message.isBulletin {
                        Text("BULLETIN")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 8)
                    Text("#\(message.id)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(BBSMessageList.subjectLabel(message))
                    .font(.callout)
                    .lineLimit(2)
                    .strikethrough(message.killedAt != nil)
                    .foregroundStyle(message.killedAt != nil ? .secondary : .primary)
                Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One message, read.
struct BBSMessageDetailScreen: View {

    @ObservedObject var service: BBSService
    let sysop: String
    let message: BBSMessage?
    /// Which mailbox took it. Everything this screen offers follows from
    /// this: another mailbox's message is readable and nothing else.
    var origin: BBSUnifiedListing.Origin = .thisMailbox
    let onReply: (BBSMessage) -> Void
    let onCompose: () -> Void
    var onOpenProfile: ((String) -> Void)?

    private var actions: BBSMessageActions? {
        message.map { BBSMessageActions.forRow(message: $0, origin: origin, sysop: sysop) }
    }

    var body: some View {
        Group {
            if let message {
                reader(message)
            } else {
                BBSEmptyState(
                    systemImage: "envelope.open",
                    title: "Select a message",
                    detail: "Mail addressed to \(sysop) is yours; a bulletin is addressed "
                        + "to ALL and every caller can read it.")
            }
        }
        .navigationTitle(message.map { "#\($0.id)" } ?? "Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let message, let actions {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            onReply(message)
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }
                        .disabled(!actions.canReply)

                        Button {
                            onCompose()
                        } label: {
                            Label("New Message", systemImage: "square.and.pencil")
                        }

                        if let onOpenProfile, !message.from.isEmpty {
                            Button {
                                onOpenProfile(message.from)
                            } label: {
                                Label("About \(message.from.uppercased())",
                                      systemImage: "person.crop.circle")
                            }
                        }

                        if !actions.isReadOnly { Divider() }

                        if actions.canKill {
                            Button(role: .destructive) {
                                service.sysopKill(id: message.id)
                            } label: {
                                Label("Kill", systemImage: "trash")
                            }
                        } else if actions.canRestore {
                            Button {
                                service.sysopRestore(id: message.id)
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func reader(_ message: BBSMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Said before anything else about the message: the number
                // below, and its read and killed flags, belong to the mailbox
                // that took it rather than to this one.
                if let banner = BBSRemoteMailbox.banner(for: origin) {
                    Label(banner, systemImage: "laptopcomputer.and.iphone")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .explain(BBSRemoteMailbox.attributionExplanation)
                }
                Text(BBSMessageList.subjectLabel(message))
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(message.from.uppercased()) → \(message.to.uppercased())")
                        .font(.system(.caption, design: .monospaced))
                    Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                if message.isBulletin {
                    Label("Addressed to ALL — every caller can read this.",
                          systemImage: "megaphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let killedAt = message.killedAt {
                    Label("Killed \(killedAt.formatted(date: .abbreviated, time: .shortened)) "
                          + "— hidden from callers",
                          systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .explain("Killing sets a flag; the message itself is never deleted, "
                                 + "so restoring it brings it back exactly as it was. Only "
                                 + "Purge removes a row for good.")
                }

                Divider()

                Text(message.body.isEmpty ? "(no text)" : message.body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        // Reading your own mail in the app is the same fact as reading it over
        // the air — see `BBSMessage.readAt`. Re-run on a change of message
        // because on iPad the detail column is reused rather than reappearing.
        .onAppear { markRead(message) }
        .onChange(of: message.id) { markRead(message) }
    }

    private func markRead(_ message: BBSMessage) {
        // Reading another mailbox's mail here says nothing about whether the
        // operator read it there, so it stamps nothing.
        guard BBSMessageActions.forRow(message: message, origin: origin,
                                       sysop: sysop).marksRead else { return }
        service.sysopMarkRead(id: message.id)
    }
}
#endif
