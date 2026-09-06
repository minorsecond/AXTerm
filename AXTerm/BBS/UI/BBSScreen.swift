//
//  BBSScreen.swift
//  AXTerm
//
//  The personal mailbox on a handheld.
//

#if os(iOS)
import SwiftUI

/// The mailbox tab.
///
/// Same service, same store, same four panes as the Mac window — only the
/// navigation differs. A Mac shows the sidebar, a list and a detail side by
/// side because it has the width; a phone pushes through them, and an iPad
/// gets the columns back on its own because `NavigationSplitView` collapses
/// itself rather than being told which device it is on.
///
/// It owns that navigation. The shell places this as a tab's content and must
/// not wrap it in a `NavigationStack`: a split view inside a stack renders as
/// a single squeezed column with two navigation bars.
struct BBSScreen: View {

    @ObservedObject var service: BBSService
    @ObservedObject var settings: BBSSettings
    @ObservedObject var library: BBSFileLibrary
    let stationCallsign: String
    let isWinlinkP2PArmed: Bool
    /// Opens a station's identity page for a callsign — a caller, a message
    /// author, a directory entry. Nil where the shell has nowhere to go.
    var onOpenProfile: ((String) -> Void)?
    /// Other instances' mailboxes, read-only. Nil where the operator has not
    /// switched mailbox sharing on, and then every surface here behaves
    /// exactly as it did before there was such a thing.
    var remoteMailbox: BBSMailboxReplicationStore?
    /// Whether this brings its own navigation. `.tab` by default, so every
    /// existing caller keeps the split view it already had.
    var presentation: BBSScreenPresentation = .tab

    /// Optional because that is the only shape iOS offers: a `List` selection
    /// binding to a non-optional is a macOS-only initialiser. Nil is also the
    /// honest state on an iPad whose sidebar has nothing chosen yet.
    /// All three columns from the first frame.
    ///
    /// Left to itself a `NavigationSplitView` hides the sidebar at iPad
    /// widths, which put the on-air switch — the one control that decides
    /// whether the station answers at all — behind a toolbar button the
    /// operator has to go looking for. The mailbox is a thing you check, so
    /// the state it reports has to be on screen when it opens.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pane: BBSPane? = .messages
    @State private var filter: BBSMessageFilter = .mine
    /// A row id, so a remote row is selectable and a local "Message 12" and
    /// a remote "Message 12" are two different selections.
    @State private var messageSelection: String?
    /// Off, and remembered. The same key the Mac and the callers pane use, so
    /// "show me everything" is one decision rather than one per surface.
    @AppStorage("bbs.showsOtherMailboxes") private var showsOtherMailboxes = false
    @State private var remoteMessages: [BBSMessagePayload] = []
    @State private var directorySelection: String?
    @State private var areaSelection: String?
    /// One compose sheet for the whole screen.
    ///
    /// Reply is offered in the detail column and New Message in the list, and
    /// two `.sheet` modifiers on one view silently leave only the last one
    /// working. Held here, presented once.
    @State private var compose: ComposeRequest?

    /// `sheet(item:)` needs an Identifiable, and "a reply to nothing" — a new
    /// message — is a legitimate request rather than the absence of one.
    private struct ComposeRequest: Identifiable {
        let id = UUID()
        let replyingTo: BBSMessage?
    }

    /// The pane the columns are drawn for. A sidebar with nothing selected
    /// still has to put something in the other two columns, and Messages is
    /// what a mailbox opens on.
    private var currentPane: BBSPane { pane ?? .messages }

    private var sysop: String {
        settings.effectiveCallsign(stationCallsign: stationCallsign)
    }

    /// Built once, here, so the list and the detail column cannot disagree
    /// about what is in the list.
    private var messageSections: [BBSUnifiedListing.Section<BBSUnifiedListing.MessageRow>] {
        BBSUnifiedListing.messageSections(local: service.messages,
                                          remote: remoteMessages,
                                          showsOtherInstances: showsOtherMailboxes,
                                          filter: filter, sysop: sysop)
    }

    private var selectedMessageRow: BBSUnifiedListing.MessageRow? {
        messageSections.flatMap(\.rows).first { $0.id == messageSelection }
    }

    private var showsMailboxChip: Bool {
        BBSRemoteMailbox.showsToggle(hasStore: remoteMailbox != nil,
                                     remoteCount: remoteMessages.count,
                                     isOn: showsOtherMailboxes)
    }

    /// Read whenever there is a store, not only while the chip is on: the
    /// chip appears once something has arrived, so loading only when switched
    /// on could never discover there was anything to show.
    private func reloadRemote() {
        guard BBSRemoteMailbox.shouldLoadRemote(hasStore: remoteMailbox != nil) else {
            remoteMessages = []
            return
        }
        remoteMessages = (try? remoteMailbox?.remoteMessages(limit: 500)) ?? []
        if selectedMessageRow == nil { messageSelection = nil }
    }

    var body: some View {
        Group {
            if !service.isAvailable {
                // The same statement either way; only the navigation around
                // it differs.
                if presentation.ownsNavigation {
                    NavigationStack { unavailable }
                } else {
                    unavailable
                }
            } else if presentation.ownsNavigation {
                splitView
            } else {
                pushedRoot
            }
        }
        // The Mac window reloads when the page appears; the tab does the same
        // when it is first shown. A rescan comes with it because the shared
        // folders are the operator's and may have changed while the app was
        // suspended — iOS suspends aggressively, so "since launch" is a much
        // longer time here than on a Mac.
        .task {
            service.reload()
            library.rescan()
            reloadRemote()
        }
        .onChange(of: showsOtherMailboxes) { _, _ in reloadRemote() }
    }

    /// Status and the live call above the columns, not inside one.
    ///
    /// `columnVisibility = .all` asks for three columns and iPadOS declines in
    /// portrait — at 834pt there is no room, so the sidebar goes behind the
    /// toolbar button whatever the binding says. That took the on-air switch,
    /// the one control deciding whether the station answers at all, off the
    /// screen the operator opens. So it does not live in a column: the header
    /// spans the whole page, which is also where the Mac window puts it.
    private var splitView: some View {
        columns
            .safeAreaInset(edge: .bottom, spacing: 0) { storeErrorBanner }
            .animation(.easeInOut(duration: 0.2), value: service.live)
        .sheet(item: $compose) { request in
            BBSComposeSheet(sysop: sysop, replyingTo: request.replyingTo) { to, subject, body in
                service.sysopPost(to: to, subject: subject, body: body)
            }
        }
    }

    /// Reachability, and the call happening right now.
    private var statusBanner: some View {
        VStack(spacing: 0) {
            BBSStatusHeader(service: service, settings: settings)

            if service.live != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BBSLiveCallPanel(service: service, now: context.date)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var columns: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                // Narrower than the default so three columns actually fit an
                // iPad in portrait. `columnVisibility = .all` is a request,
                // not an instruction: at 834pt the default sidebar and
                // content widths leave nothing for the detail, and iPadOS
                // answers by hiding the sidebar behind its toolbar button —
                // which is where the on-air switch had gone.
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } content: {
            paneList
                // Reachability rides the *content* column, which is the one
                // column iPadOS always shows. Above the split view it would
                // be drawn under the floating tab bar, unreadable behind the
                // tabs; in the sidebar it would be behind a toolbar button in
                // portrait, which is what put the on-air switch out of reach.
                // Here it is below this column's own navigation bar, which is
                // the only place on this page that is reliably on screen.
                .safeAreaInset(edge: .top, spacing: 0) { statusBanner }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            paneDetail
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sidebar

    /// The four panes. Everything above them — reachability, the live call —
    /// is outside the split view, because a column iPadOS may hide is not a
    /// place to keep the state the operator opened the mailbox to check.
    private var sidebar: some View {
        List(selection: $pane) {
            Section("Mailbox") {
                ForEach(paneRows) { row in
                    paneLabel(row).tag(row.pane)
                }
            }
        }
        .navigationTitle("Mailbox")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The four panes and their badges. Which counts are worth showing is
    /// decided in `BBSPaneList`, where it can be tested and where the Mac
    /// sidebar reads the same rule.
    private var paneRows: [BBSPaneRow] {
        BBSPaneList.rows(
            messageBadge: BBSMessageList.unreadCount(service.messages, sysop: sysop),
            liveCallers: service.live == nil ? 0 : 1)
    }

    private func paneLabel(_ row: BBSPaneRow) -> some View {
        HStack {
            Label(row.pane.rawValue, systemImage: row.pane.systemImage)
            Spacer()
            if let badge = row.badge {
                Text("\(badge)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var storeErrorBanner: some View {
        if let storeError = service.storeError {
            Label(storeError, systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    // MARK: - Pushed

    /// The same sidebar, as one list inside somebody else's navigation stack.
    ///
    /// The compact "More" list wraps its content in a navigation controller of
    /// its own, so a split view here would collapse into one squeezed column
    /// under two navigation bars. Everything the sidebar shows is shown — the
    /// status header and its switch, the live call, the four panes — but the
    /// panes are links rather than a selection, because a selection drives a
    /// column that does not exist in this placement.
    private var pushedRoot: some View {
        List {
            Section {
                BBSStatusHeader(service: service, settings: settings)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if service.live != nil {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        BBSLiveCallPanel(service: service, now: context.date)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section("Mailbox") {
                ForEach(paneRows) { row in
                    // A destination link, not `NavigationLink(value:)`.
                    //
                    // The shell's stack is `NavigationStack(path:)` over its
                    // own settings route, and a typed path accepts only that
                    // type: a value link carrying a `BBSPane` compiles, draws,
                    // highlights when pressed — and appends nothing. The row
                    // simply does not push, with no error anywhere. A
                    // destination link works in any stack, whatever it is
                    // pathed on.
                    NavigationLink {
                        pushedList(for: row.pane)
                    } label: {
                        paneLabel(row)
                    }
                }
            }

            if service.storeError != nil {
                Section { storeErrorBanner }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.easeInOut(duration: 0.2), value: service.live)
        .navigationTitle("BBS")
        .navigationBarTitleDisplayMode(.inline)
        // One sheet, on the root. Reply is offered two pushes deep and New
        // Message one, and two `.sheet` modifiers on one view leave only the
        // last one working — silently.
        .sheet(item: $compose) { request in
            BBSComposeSheet(sysop: sysop, replyingTo: request.replyingTo) { to, subject, body in
                service.sysopPost(to: to, subject: subject, body: body)
            }
        }
    }

    @ViewBuilder
    private func pushedList(for pane: BBSPane) -> some View {
        switch pane {
        case .messages:
            BBSMessageListScreen(service: service,
                                 sysop: sysop,
                                 filter: $filter,
                                 selection: $messageSelection,
                                 sections: messageSections,
                                 showsOtherMailboxes: $showsOtherMailboxes,
                                 showsChip: showsMailboxChip,
                                 onCompose: { compose = ComposeRequest(replyingTo: nil) },
                                 onRefresh: {
                                     service.reload()
                                     reloadRemote()
                                 },
                                 onReply: { compose = ComposeRequest(replyingTo: $0) },
                                 onOpenProfile: onOpenProfile,
                                 presentation: .pushed)
        case .callers:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                BBSCallersPane(service: service, now: context.date,
                               onOpenProfile: onOpenProfile,
                               remoteMailbox: remoteMailbox)
            }
            .navigationTitle("Callers")
            .navigationBarTitleDisplayMode(.inline)
        case .directory:
            BBSDirectoryListScreen(service: service,
                                   selection: $directorySelection,
                                   onOpenProfile: onOpenProfile,
                                   presentation: .pushed)
        case .files:
            BBSAreaListScreen(library: library,
                              settings: settings,
                              bytesPerSecond: service.linkThroughput,
                              selection: $areaSelection,
                              presentation: .pushed)
        }
    }

    // MARK: - Columns

    /// The middle column: whichever list this pane is.
    @ViewBuilder
    private var paneList: some View {
        switch currentPane {
        case .messages:
            BBSMessageListScreen(service: service,
                                 sysop: sysop,
                                 filter: $filter,
                                 selection: $messageSelection,
                                 sections: messageSections,
                                 showsOtherMailboxes: $showsOtherMailboxes,
                                 showsChip: showsMailboxChip,
                                 onCompose: { compose = ComposeRequest(replyingTo: nil) },
                                 onRefresh: {
                                     service.reload()
                                     reloadRemote()
                                 })
        case .callers:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                BBSCallersPane(service: service, now: context.date,
                               onOpenProfile: onOpenProfile,
                               remoteMailbox: remoteMailbox)
            }
            .navigationTitle("Callers")
            .navigationBarTitleDisplayMode(.inline)
        case .directory:
            BBSDirectoryListScreen(service: service, selection: $directorySelection)
        case .files:
            BBSAreaListScreen(library: library,
                              settings: settings,
                              bytesPerSecond: service.linkThroughput,
                              selection: $areaSelection)
        }
    }

    /// The third column. Looked up from the service by id rather than held as
    /// a copy, so a message killed or a licence lookup landing while the
    /// detail is open changes what is on screen.
    @ViewBuilder
    private var paneDetail: some View {
        switch currentPane {
        case .messages:
            let row = selectedMessageRow
            BBSMessageDetailScreen(
                service: service,
                sysop: sysop,
                // Looked up live for this mailbox's own mail, so a kill or a
                // read landing while the reader is open changes what is on
                // screen. A remote row is a snapshot; nothing here can change
                // it anyway.
                message: row.map { messageRow in
                    messageRow.origin == .thisMailbox
                        ? (service.messages.first { $0.id == messageRow.message.id }
                           ?? messageRow.message)
                        : messageRow.message
                },
                origin: row?.origin ?? .thisMailbox,
                onReply: { compose = ComposeRequest(replyingTo: $0) },
                onCompose: { compose = ComposeRequest(replyingTo: nil) },
                onOpenProfile: onOpenProfile)
        case .callers:
            callersDetail
        case .directory:
            BBSDirectoryDetailScreen(
                service: service,
                entry: service.directory.first { $0.callsign == directorySelection },
                onRemoved: { directorySelection = nil },
                onOpenProfile: onOpenProfile)
        case .files:
            BBSFileListScreen(library: library,
                              area: areaSelection,
                              bytesPerSecond: service.linkThroughput)
        }
    }

    /// The callers log has no per-row detail — a call is one line, and the row
    /// says all of it. The column is given to the session actually happening,
    /// which is the one thing here that changes while you watch.
    @ViewBuilder
    private var callersDetail: some View {
        if service.live != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack {
                    BBSLiveCallPanel(service: service, now: context.date)
                    Spacer()
                }
            }
            .navigationTitle("Live Call")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            BBSEmptyState(
                systemImage: "phone.badge.waveform",
                title: "Nobody is connected",
                detail: "A call in progress shows here as the caller types, both "
                    + "directions — the fastest way to find out that a banner reads "
                    + "badly or a command confuses people.")
            .navigationTitle("Live Call")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Unavailable

    /// Mirrors `BBSView.unavailable`: the mailbox cannot keep what callers
    /// leave, so it will not answer, and saying that is the whole screen.
    private var unavailable: some View {
        BBSEmptyState(
            systemImage: "externaldrive.badge.exclamationmark",
            title: "Mailbox unavailable",
            detail: "The AXTerm database could not be opened, so the mailbox cannot "
                + "keep what callers leave and will not answer.")
        .navigationTitle("Mailbox")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The empty states, said the same way everywhere.
///
/// An empty pane has to explain itself: on a handheld there is no second
/// window to look at for the reason, and "nothing here" with no cause reads as
/// a fault in the app rather than as a mailbox nobody has called yet.
struct BBSEmptyState: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
