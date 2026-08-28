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

    enum Filter: String, CaseIterable, Identifiable {
        case mine = "Mine"
        case bulletins = "Bulletins"
        case all = "All"
        case killed = "Killed"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .mine
    @State private var selection: Int64?
    @State private var composing = false
    @State private var replyTo: BBSMessage?

    var body: some View {
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

    private var visible: [BBSMessage] {
        let all = service.messages
        let filtered: [BBSMessage] = switch filter {
        case .mine: all.filter { $0.killedAt == nil && $0.isAddressed(to: sysop) }
        case .bulletins: all.filter { $0.killedAt == nil && $0.isBulletin }
        case .all: all.filter { $0.killedAt == nil }
        case .killed: all.filter { $0.killedAt != nil }
        }
        return filtered.sorted { $0.receivedAt > $1.receivedAt }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            if visible.isEmpty {
                emptyList
            } else {
                List(visible, selection: $selection) { message in
                    row(message).tag(message.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ message: BBSMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isUnread(message) ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.from.uppercased())
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(isUnread(message) ? .semibold : .regular)
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

    private func isUnread(_ message: BBSMessage) -> Bool {
        message.readAt == nil && message.isAddressed(to: sysop)
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

    private var emptyTitle: String {
        switch filter {
        case .mine: "No mail for you"
        case .bulletins: "No bulletins"
        case .all: "Mailbox empty"
        case .killed: "Nothing killed"
        }
    }

    private var emptyDetail: String {
        switch filter {
        case .mine: "Callers leave mail with S \(sysop) at the prompt."
        case .bulletins: "Post one with New Message addressed to ALL — every caller can read it."
        case .all: "Nothing has been left here yet."
        case .killed: "Killed messages stay here so a mistaken K can be undone."
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected = visible.first(where: { $0.id == selection }) {
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

    private func messageView(_ message: BBSMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
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
        .toolbar { toolbar(for: message) }
        .onAppear { markReadIfMine(message) }
        .onChange(of: selection) { markReadIfMine(message) }
    }

    @ToolbarContentBuilder
    private func toolbar(for message: BBSMessage) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                replyTo = message
                composing = true
            } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .disabled(message.isBulletin && message.from.isEmpty)

            Button { replyTo = nil; composing = true } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }

            if message.killedAt == nil {
                Button(role: .destructive) { service.sysopKill(id: message.id) } label: {
                    Label("Kill", systemImage: "trash")
                }
            } else {
                Button { service.sysopRestore(id: message.id) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private func markReadIfMine(_ message: BBSMessage) {
        // Reading your own mail in the app is the same fact as reading it over
        // the air — see `BBSMessage.readAt`.
        guard message.readAt == nil, message.isAddressed(to: sysop) else { return }
        service.sysopMarkRead(id: message.id)
    }
}
#endif
