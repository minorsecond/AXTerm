import SwiftUI

/// Everything this station has connected to, kept.
///
/// The terminal's session strip is a row of live tabs, capped at twenty and
/// gone on relaunch. This is the record: what was said, when, over which
/// path, and how it ended.
struct SessionHistoryView: View {

    let store: TerminalSessionStoring?
    /// Opens a station's page from a callsign in the list.
    var onOpenCallsign: ((String) -> Void)?

    @State private var sessions: [TerminalSession] = []
    @State private var tagCounts: [String: Int] = [:]
    @State private var query = ""
    @State private var activeTag: String?
    @State private var selection: TerminalSession.ID?
    @State private var pendingDeletion: TerminalSession?
    @State private var pendingStationPurge: String?

    var body: some View {
        splitView
            .task { reload() }
            .modifier(SessionDeletionDialogs(
                pendingDeletion: $pendingDeletion,
                pendingStationPurge: $pendingStationPurge,
                onDeleteSession: { id in try? store?.delete(id: id); reload() },
                onDeleteStation: { call in _ = try? store?.deleteAll(forRemote: call); reload() }))
    }

    private var splitView: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            if let session = sessions.first(where: { $0.id == selection }) {
                SessionHistoryDetail(session: session, store: store,
                                     onOpenCallsign: onOpenCallsign,
                                     onChanged: reload)
            } else {
                ContentUnavailableView("Select a session", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            // An inline field, not `.searchable`.
            //
            // This view lives inside the main window, which already owns a
            // `.searchable` for the universal search. A second one is a
            // second `com.apple.SwiftUI.search` toolbar item, and AppKit
            // refuses outright: "NSToolbar already contains an item with the
            // identifier". It is a launch-time assertion failure, not a
            // warning, and it took the app down the first time History was
            // opened.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Callsign, path, tag, or anything said", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if !tagCounts.isEmpty { tagFilter }
            List(selection: $selection) {
                ForEach(visible) { session in
                    SessionHistoryRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Delete Session\u{2026}", role: .destructive) {
                                pendingDeletion = session
                            }
                            Button("Delete All With \(session.remote)\u{2026}",
                                   role: .destructive) {
                                pendingStationPurge = session.remote
                            }
                        }
                }
            }
            .overlay {
                if visible.isEmpty { emptyState }
            }
            Divider()
            HStack {
                Text(countLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }

    /// Tags as filters, with their counts, so the operator can see what they
    /// have actually been labelling.
    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tagCounts.keys.sorted(), id: \.self) { tag in
                    let active = activeTag == tag
                    Button {
                        activeTag = active ? nil : tag
                    } label: {
                        Text("\(tag) \(tagCounts[tag] ?? 0)")
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(active ? Color.accentColor.opacity(0.2)
                                               : Color.primary.opacity(0.06),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if sessions.isEmpty {
            ContentUnavailableView(
                "No sessions yet", systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Connected-mode sessions are kept here once you make one."))
        } else {
            ContentUnavailableView(
                "Nothing matches", systemImage: "magnifyingglass",
                description: Text("\(sessions.count) session"
                                  + "\(sessions.count == 1 ? "" : "s") stored."))
        }
    }

    private var visible: [TerminalSession] {
        sessions.filter { session in
            if let activeTag, !session.tags.contains(activeTag) { return false }
            return session.matches(query)
        }
    }

    /// Says what is being shown against what is stored, so a filter never
    /// quietly hides history.
    private var countLine: String {
        let shown = visible.count, total = sessions.count
        if shown == total {
            return total == 1 ? "1 session" : "\(total) sessions"
        }
        return "\(shown) of \(total) sessions"
    }

    private func reload() {
        sessions = (try? store?.sessions(limit: 500)) ?? []
        tagCounts = (try? store?.tagCounts()) ?? [:]
        if let activeTag, tagCounts[activeTag] == nil { self.activeTag = nil }
    }
}

/// The two destructive confirmations, lifted out of the body.
///
/// Not tidiness: with both dialogs inline the view became one expression the
/// Swift type checker could not solve in reasonable time.
private struct SessionDeletionDialogs: ViewModifier {

    @Binding var pendingDeletion: TerminalSession?
    @Binding var pendingStationPurge: String?
    let onDeleteSession: (UUID) -> Void
    let onDeleteStation: (String) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingDeletion.map { "Delete the session with \($0.correspondent)?" } ?? "",
                isPresented: Binding(get: { pendingDeletion != nil },
                                     set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let doomed = pendingDeletion { onDeleteSession(doomed.id) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("The transcript goes with it. Nothing else about the station changes.")
            }
            .confirmationDialog(
                pendingStationPurge.map { "Delete every session with \($0)?" } ?? "",
                isPresented: Binding(get: { pendingStationPurge != nil },
                                     set: { if !$0 { pendingStationPurge = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    if let call = pendingStationPurge { onDeleteStation(call) }
                    pendingStationPurge = nil
                }
                Button("Cancel", role: .cancel) { pendingStationPurge = nil }
            } message: {
                Text("Every SSID of that callsign, and every transcript. "
                     + "Other stations are untouched.")
            }
    }
}
