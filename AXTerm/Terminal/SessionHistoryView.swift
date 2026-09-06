import SwiftUI

/// Everything this station has connected to, kept — and, when asked, what
/// the operator's other devices connected to, kept apart and labelled.
///
/// The terminal's session strip is a row of live tabs, capped at twenty and
/// gone on relaunch. This is the record: what was said, when, over which
/// path, and how it ended.
///
/// Three shapes, one set of rules (`SessionHistoryListing`):
/// - Mac: a split view, list beside detail.
/// - iPad: two columns drawn by hand. The terminal tab is already a
///   navigation stack, and a `NavigationSplitView` nested inside one draws
///   its sidebar as a floating card with a collapse button — the mailbox
///   learned that the hard way (see `AXTermiOSRootView.mail`).
/// - iPhone: a list that pushes the detail.
struct SessionHistoryView: View {

    let store: TerminalSessionStoring?
    /// Sessions from the operator's other devices. Nil where sync has no
    /// database; the toggle is then absent rather than inert.
    var remoteStore: TerminalSessionReplicationStore?
    /// Opens a station's page from a callsign in the list.
    var onOpenCallsign: ((String) -> Void)?

    @State private var sessions: [TerminalSession] = []
    @State private var remote: [TerminalSessionPayload] = []
    @State private var tagCounts: [String: Int] = [:]
    @State private var query = ""
    @State private var activeTag: String?
    @State private var selection: SessionHistoryListing.Row.ID?
    @State private var pendingDeletion: TerminalSession?
    @State private var pendingStationPurge: String?
    /// Remembered: an operator who wants both radios' history in one place
    /// wants it every time, and one who does not should never see a remote
    /// row by surprise.
    @AppStorage("history.showsOtherDevices") private var showsOtherDevices = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        layout
            .task { reload() }
            .onChange(of: showsOtherDevices) { _, _ in reload() }
            .modifier(SessionDeletionDialogs(
                pendingDeletion: $pendingDeletion,
                pendingStationPurge: $pendingStationPurge,
                onDeleteSession: { id in try? store?.delete(id: id); reload() },
                onDeleteStation: { call in _ = try? store?.deleteAll(forRemote: call); reload() }))
    }

    // MARK: - Shapes

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
        }
        #else
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                list
                    .frame(width: 340)
                Divider()
                detail
            }
        } else {
            list
                .navigationDestination(for: SessionHistoryRoute.self) { route in
                    detailView(for: route.id)
                        .navigationTitle(rowTitle(for: route.id))
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            detailView(for: selection)
        } else {
            ContentUnavailableView("Select a session", systemImage: "clock.arrow.circlepath")
        }
    }

    @ViewBuilder
    private func detailView(for id: SessionHistoryListing.Row.ID) -> some View {
        if let row = rows.first(where: { $0.id == id }) {
            SessionHistoryDetail(session: row.session, store: store,
                                 onOpenCallsign: onOpenCallsign,
                                 onChanged: reload,
                                 origin: row.origin)
        } else {
            ContentUnavailableView("Select a session", systemImage: "clock.arrow.circlepath")
        }
    }

    private func rowTitle(for id: SessionHistoryListing.Row.ID) -> String {
        rows.first { $0.id == id }?.session.correspondent ?? "Session"
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if !tagCounts.isEmpty || showsToggle {
                filterRow
            }

            List(selection: $selection) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    } header: {
                        if let title = section.title {
                            sectionHeader(title, section: section)
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.plain)
            .refreshable { reload() }
            #endif
            .overlay { if rows.isEmpty { emptyState } }

            Divider()
            HStack {
                Text(countLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// An inline field, not `.searchable`.
    ///
    /// This view lives inside the main window, which already owns a
    /// `.searchable` for the universal search. A second one is a second
    /// `com.apple.SwiftUI.search` toolbar item, and AppKit refuses outright:
    /// "NSToolbar already contains an item with the identifier". It is a
    /// launch-time assertion failure, not a warning, and it took the app
    /// down the first time History was opened. On iOS the same field keeps
    /// the two platforms' History identical to use.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Callsign, path, tag, or anything said", text: $query)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        #if os(iOS)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #else
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        #endif
    }

    /// Tags to filter by, and the switch that brings other devices in.
    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if showsToggle {
                    Toggle(isOn: $showsOtherDevices) {
                        Label("Other devices", systemImage: "laptopcomputer.and.iphone")
                            .font(.caption)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    // Not `.explain`: its container swallows a toggle's taps
                    // on iOS. The explanation sits on each remote section's
                    // attribution line instead, where the rows it explains
                    // are.
                    .accessibilityHint("Also lists sessions your other devices finished in the last week, under each device's name")
                    if !tagCounts.isEmpty {
                        Divider().frame(height: 14)
                    }
                }
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

    private func sectionHeader(_ title: String, section: SessionHistoryListing.Section) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: section.isRemote ? "laptopcomputer.and.iphone" : "iphone.gen3")
                .font(.caption.weight(.semibold))
            if let attribution = section.attribution {
                // The sentence that makes the section honest: whose antenna,
                // where. Not a tooltip, because on a phone nobody hovers.
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .explain("Sessions this device's counterpart finished in the last week, recorded by that radio with its antenna at the grid shown. Every row here says which station and device it came from, and none can be tagged or annotated on this device \u{2014} those stay with the device that made them. Nothing in this section is ever mixed into this device's own history or its link measurements.")
            }
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func rowView(_ row: SessionHistoryListing.Row) -> some View {
        #if os(macOS)
        SessionHistoryRow(session: row.session, originLabel: row.origin.label)
            .tag(row.id)
            .contextMenu { rowMenu(row) }
        #else
        if horizontalSizeClass == .regular {
            Button {
                selection = row.id
            } label: {
                SessionHistoryRow(session: row.session, originLabel: row.origin.label)
            }
            .buttonStyle(.plain)
            .listRowBackground(selection == row.id ? Color.accentColor.opacity(0.15) : nil)
            .contextMenu { rowMenu(row) }
        } else {
            NavigationLink(value: SessionHistoryRoute(id: row.id)) {
                SessionHistoryRow(session: row.session, originLabel: row.origin.label)
            }
            .contextMenu { rowMenu(row) }
        }
        #endif
    }

    /// Deletion is for this device's rows only. A remote row is another
    /// device's record; forgetting it here would come back on the next pull.
    @ViewBuilder
    private func rowMenu(_ row: SessionHistoryListing.Row) -> some View {
        if case .thisDevice = row.origin {
            Button("Delete Session\u{2026}", role: .destructive) {
                pendingDeletion = row.session
            }
            Button("Delete All With \(row.session.remote)\u{2026}", role: .destructive) {
                pendingStationPurge = row.session.remote
            }
        } else if let onOpenCallsign {
            Button("Open \(row.session.correspondent)") {
                onOpenCallsign(row.session.correspondent)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if sessions.isEmpty, !showsOtherDevices || remote.isEmpty {
            ContentUnavailableView(
                "No sessions yet", systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Connected-mode sessions are kept here once you make one."))
        } else {
            ContentUnavailableView(
                "Nothing matches", systemImage: "magnifyingglass",
                description: Text(SessionHistoryListing.countLine(
                    shown: sessions.count, total: sessions.count,
                    remoteShown: showsOtherDevices ? remote.count : 0) + " stored."))
        }
    }

    // MARK: - Derived

    /// The switch earns its place only when there is something behind it, or
    /// it was already on — a control for data that has never arrived would
    /// be a promise the screen cannot keep.
    private var showsToggle: Bool {
        remoteStore != nil && (!remote.isEmpty || showsOtherDevices)
    }

    private var sections: [SessionHistoryListing.Section] {
        SessionHistoryListing.sections(local: sessions, remote: remote,
                                       showsOtherDevices: showsOtherDevices,
                                       query: query, tag: activeTag)
    }

    private var rows: [SessionHistoryListing.Row] { sections.flatMap(\.rows) }

    private var countLine: String {
        let shownLocal = rows.filter { $0.origin == .thisDevice }.count
        return SessionHistoryListing.countLine(
            shown: shownLocal, total: sessions.count,
            remoteShown: rows.count - shownLocal)
    }

    private func reload() {
        sessions = (try? store?.sessions(limit: 500)) ?? []
        tagCounts = (try? store?.tagCounts()) ?? [:]
        remote = showsOtherDevices || remoteStore != nil
            ? ((try? remoteStore?.remoteSessions(limit: 500)) ?? [])
            : []
        if let activeTag, tagCounts[activeTag] == nil { self.activeTag = nil }
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }
}

/// A pushed detail on iPhone, keyed by row so a remote and a local copy of
/// the same session are two destinations.
nonisolated struct SessionHistoryRoute: Hashable, Sendable {
    let id: SessionHistoryListing.Row.ID
}

/// The two destructive confirmations, lifted out of the body.
///
/// Inline, the pair of dialogs pushed the body past what the type checker
/// will solve; as a modifier they are one expression each.
private struct SessionDeletionDialogs: ViewModifier {
    @Binding var pendingDeletion: TerminalSession?
    @Binding var pendingStationPurge: String?
    let onDeleteSession: (UUID) -> Void
    let onDeleteStation: (String) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete the session with \(pendingDeletion?.correspondent ?? "")?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = pendingDeletion?.id { onDeleteSession(id) }
                    pendingDeletion = nil
                }
            } message: {
                Text("The transcript goes with it. Nothing else about the station changes.")
            }
            .confirmationDialog(
                "Delete every session with \(pendingStationPurge ?? "")?",
                isPresented: Binding(
                    get: { pendingStationPurge != nil },
                    set: { if !$0 { pendingStationPurge = nil } }),
                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    if let call = pendingStationPurge { onDeleteStation(call) }
                    pendingStationPurge = nil
                }
            } message: {
                Text("Every SSID of that callsign, and every transcript. Other stations are untouched.")
            }
    }
}
