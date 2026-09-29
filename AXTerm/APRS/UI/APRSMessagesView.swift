import SwiftUI

/// The APRS Messages page. A conversation UI — thread list, bubbles, a compose
/// bar — but honest about RF: APRS is a best-effort, unencrypted, low-rate
/// broadcast, so delivery is shown as what it actually is (queued → sent →
/// acked / no ack), and the APRS facts iMessage has no slot for (direct vs via
/// a digipeater, the message number, the path) are surfaced, not hidden to
/// keep up an appearance. Bulletins are read-only broadcasts; queries are
/// machine Q&A shown as system rows, not chat.
///
/// Two shells share every piece: `.standalone` uses a `NavigationSplitView`
/// (the macOS sidebar item and the iPad tab); `.pushed` is a plain list that
/// drills into the conversation on the navigation stack it's already inside
/// (the iPhone More list), so it never draws a second back button.
struct APRSMessagesView: View {
    @ObservedObject var messaging: APRSMessagingService
    @ObservedObject var probe: APRSReachabilityProbe
    /// Our callsign, stamped on outgoing messages.
    var myCallsign: String
    /// How this view is embedded. Defaults to the split-view shell.
    var presentation: Presentation = .standalone

    enum Presentation { case standalone, pushed }

    /// The pseudo-peer that gathers bulletins so they don't scatter the list.
    private static let bulletinsPeer = "· Bulletins"

    @State private var selectedPeer: String?
    @State private var showNewMessage = false
    @State private var showNewBulletin = false
    @State private var showProbe = false
    @State private var draft = ""

    /// One conversation: a peer and the messages exchanged with it.
    private struct Thread: Identifiable {
        var peer: String
        var messages: [APRSMessageRecord]
        var id: String { peer }
        var last: APRSMessageRecord? { messages.max(by: { $0.createdAt < $1.createdAt }) }
        var unread: Int { messages.filter { $0.direction == .incoming && !$0.isRead }.count }
        var isBulletins: Bool { peer == APRSMessagesView.bulletinsPeer }
    }

    private var threads: [Thread] {
        let grouped = Dictionary(grouping: messaging.messages) { rec -> String in
            rec.kind == .bulletin ? APRSMessagesView.bulletinsPeer : rec.peer.uppercased()
        }
        return grouped.map { Thread(peer: $0.key, messages: $0.value) }
            .sorted { ($0.last?.createdAt ?? .distantPast) > ($1.last?.createdAt ?? .distantPast) }
    }

    var body: some View {
        Group {
            switch presentation {
            case .standalone: splitBody
            case .pushed: pushedBody
            }
        }
        .sheet(isPresented: $showNewMessage) {
            APRSComposeSheet(myCallsign: myCallsign) { to, text in
                messaging.sendMessage(to: to, text: text, from: myCallsign,
                                      path: outgoingPath(), radioID: nil)
                selectedPeer = to.uppercased()
            }
        }
        .sheet(isPresented: $showNewBulletin) {
            APRSBulletinComposeSheet(myCallsign: myCallsign) { identifier, group, text in
                messaging.sendBulletin(identifier: identifier, group: group, text: text,
                                       from: myCallsign, path: outgoingPath(), radioID: nil)
            }
        }
        .sheet(isPresented: $showProbe) {
            APRSWhoCanHearMeView(probe: probe)
        }
    }

    // MARK: - Standalone shell (macOS sidebar, iPad tab)

    private var splitBody: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                pageHeader
                Divider()
                List(selection: $selectedPeer) {
                    actionsSection
                    Section("Conversations") {
                        if threads.isEmpty {
                            emptyConversations
                        }
                        ForEach(threads) { thread in
                            threadRow(thread).tag(thread.peer)
                        }
                    }
                }
            }
            // Deliberately not `.navigationTitle`. This split view is nested
            // inside the app's own, and the inner sidebar then renders the
            // *detail's* title — so the conversation list was headed with
            // whichever station was selected (2026-09-17).
            .navigationTitle("")
        } detail: {
            if let peer = selectedPeer, let thread = threads.first(where: { $0.peer == peer }) {
                conversation(thread)
            } else {
                ContentUnavailableViewCompat(
                    "APRS Messages",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: "Short messages sent over the air to a station's callsign. "
                        + "Pick a conversation, or start one from the left.")
            }
        }
    }

    // MARK: - Pushed shell (iPhone More list)

    private var pushedBody: some View {
        List {
            actionsSection
            Section("Conversations") {
                if threads.isEmpty {
                    Text("No APRS messages yet.").foregroundStyle(.secondary)
                }
                ForEach(threads) { thread in
                    NavigationLink {
                        conversation(thread)
                    } label: {
                        threadRow(thread)
                    }
                }
            }
        }
        .navigationTitle("Messages")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Shared list pieces

    /// Says what this page is, since "Messages" alone does not distinguish it
    /// from mail, the BBS, or a terminal session — all of which this app also
    /// has, and all of which carry text between stations.
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("APRS Messages", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
            Text("Sent over the air to a station's callsign. 67 characters, "
                 + "acknowledged or retried.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var emptyConversations: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No messages yet").font(.callout.weight(.medium))
            Text("Anything addressed to \(myCallsign.isEmpty ? "this station" : myCallsign.uppercased()) "
                 + "appears here, and so does anything you send.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            // Three different jobs, and the difference between the last two
            // matters on the air: one is addressed and acknowledged, the
            // other is shouted at everybody and nobody answers. Said on the
            // button rather than learned afterwards.
            action("New message", "square.and.pencil",
                   detail: "To one station, acknowledged",
                   tint: .accentColor) { showNewMessage = true }
            action("New bulletin", "megaphone",
                   detail: "To everyone, no reply expected",
                   tint: .orange) { showNewBulletin = true }
            action("Who can hear me?", "antenna.radiowaves.left.and.right",
                   detail: "Ask the channel and see who answers",
                   tint: .teal) { showProbe = true }
        }
    }

    @ViewBuilder
    private func action(_ title: String, _ symbol: String, detail: String,
                        tint: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func threadRow(_ thread: Thread) -> some View {
        HStack {
            Image(systemName: thread.isBulletins ? "megaphone" : "person.crop.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.peer).font(.body.weight(.medium))
                if let last = thread.last {
                    Text(preview(of: last))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if thread.unread > 0 {
                Text("\(thread.unread)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    /// The one-line preview for a thread row, tagged so a query or a sent
    /// direction reads at a glance.
    private func preview(of msg: APRSMessageRecord) -> String {
        switch msg.kind {
        case .query: return "query: \(msg.text)"
        case .bulletin: return "\(msg.peer): \(msg.text)"
        case .message: return (msg.direction == .outgoing ? "You: " : "") + msg.text
        }
    }

    // MARK: - Conversation

    @ViewBuilder
    private func conversation(_ thread: Thread) -> some View {
        VStack(spacing: 0) {
            conversationHeader(thread)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(thread.messages.sorted { $0.createdAt < $1.createdAt }) { msg in
                        messageRow(msg)
                    }
                }
                .padding()
            }
            if !thread.isBulletins {
                Divider()
                composeBar(to: thread.peer)
            } else {
                Divider()
                Text("Bulletins are broadcast to everyone and can't be replied to. "
                     + "Use New bulletin to send one.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(8)
            }
        }
        #if os(iOS)
        .navigationTitle(thread.peer)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { messaging.markThreadRead(thread.peer) }
    }

    /// Who this conversation is with, stated in the pane itself.
    ///
    /// On macOS the title is drawn here rather than with `navigationTitle`:
    /// nested inside the app's own split view, that title was landing on the
    /// conversation list instead, so the list of every conversation was headed
    /// with one station's callsign.
    @ViewBuilder
    private func conversationHeader(_ thread: Thread) -> some View {
        HStack(spacing: 10) {
            Image(systemName: thread.isBulletins ? "megaphone.fill" : "person.crop.circle.fill")
                .font(.title3)
                .foregroundStyle(thread.isBulletins ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.isBulletins ? "Bulletins" : thread.peer)
                    .font(.headline)
                Text(thread.isBulletins
                     ? "Broadcast to everyone, by anyone. Nothing here is addressed to you."
                     : "APRS messages with \(thread.peer)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Route each record to the rendering its kind deserves: a chat bubble for
    /// a person-to-person message, a full-width card for a bulletin, a system
    /// row for a machine query.
    @ViewBuilder
    private func messageRow(_ msg: APRSMessageRecord) -> some View {
        switch msg.kind {
        case .message: messageBubble(msg)
        case .bulletin: bulletinCard(msg)
        case .query: queryRow(msg)
        }
    }

    // MARK: Message bubble

    @ViewBuilder
    private func messageBubble(_ msg: APRSMessageRecord) -> some View {
        let outgoing = msg.direction == .outgoing
        HStack {
            if outgoing { Spacer(minLength: 40) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
                Text(msg.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(outgoing ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 10))
                captionRow(msg, outgoing: outgoing)
            }
            if !outgoing { Spacer(minLength: 40) }
        }
    }

    /// The quiet line under a bubble: time, then either the honest delivery
    /// state (outgoing) or how it was heard (incoming), then path/number.
    @ViewBuilder
    private func captionRow(_ msg: APRSMessageRecord, outgoing: Bool) -> some View {
        HStack(spacing: 5) {
            Text(msg.createdAt, style: .time)
            if outgoing {
                deliveryCaption(msg)
            } else {
                heardCaption(msg)
            }
            if let meta = pathAndNumber(msg) { Text(meta) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// Outgoing delivery, told straight — no checkmark that implies a
    /// guaranteed private delivery APRS never offers.
    @ViewBuilder
    private func deliveryCaption(_ msg: APRSMessageRecord) -> some View {
        switch msg.state {
        case .queued:
            Label("Queued", systemImage: "clock").labelStyle(.titleAndIcon)
        case .sent:
            if msg.number != nil {
                Label("Sent · awaiting ack", systemImage: "arrow.up.circle")
                    .labelStyle(.titleAndIcon)
            } else {
                // Unnumbered messages solicit no ack — say so, don't imply one.
                Label("Sent · no ack", systemImage: "arrow.up.circle")
                    .labelStyle(.titleAndIcon)
            }
        case .acked:
            Label("Acked", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).foregroundStyle(.green)
        case .failed:
            Label("No ack · \(max(msg.attempts, 1)) tries", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon).foregroundStyle(.orange)
        case .received:
            EmptyView()
        }
    }

    /// Incoming: direct copy vs relayed by a digipeater — the reachability
    /// fact that matters on RF.
    @ViewBuilder
    private func heardCaption(_ msg: APRSMessageRecord) -> some View {
        if msg.viaDirect {
            Label("direct", systemImage: "dot.radiowaves.left.and.right")
                .labelStyle(.titleAndIcon).foregroundStyle(.green)
        } else {
            Label("via digi", systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon).foregroundStyle(.orange)
        }
    }

    /// "#042" and/or "via WIDE2-2, KE0NCQ" when present — the number an ack
    /// matches on and the route the frame took.
    private func pathAndNumber(_ msg: APRSMessageRecord) -> String? {
        var parts: [String] = []
        if let number = msg.number, !number.isEmpty { parts.append("#\(number)") }
        if !msg.path.isEmpty { parts.append("via \(msg.path.joined(separator: ", "))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Bulletin card

    @ViewBuilder
    private func bulletinCard(_ msg: APRSMessageRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("BLN").font(.caption2.weight(.bold).monospaced())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                Text(msg.peer).font(.caption.weight(.medium))
                Spacer()
                Text(msg.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            Text(msg.text).font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Query row

    @ViewBuilder
    private func queryRow(_ msg: APRSMessageRecord) -> some View {
        let outgoing = msg.direction == .outgoing
        HStack(spacing: 6) {
            Image(systemName: outgoing ? "arrow.up.right" : "arrow.down.left")
            Text(msg.text).monospaced()
            Spacer()
            Text(msg.createdAt, style: .time)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Compose bar

    @ViewBuilder
    private func composeBar(to peer: String) -> some View {
        let count = draft.count
        VStack(spacing: 2) {
            HStack {
                TextField("Message to \(peer)", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit { send(to: peer) }
                Button { send(to: peer) } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if count > 0 {
                Text("\(count)/\(APRSMessage.maxTextLength) · unencrypted RF")
                    .font(.caption2)
                    .foregroundStyle(count > APRSMessage.maxTextLength ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(8)
    }

    /// The radio's APRS path. A message with none is heard only by stations in
    /// direct earshot; a reply keeps the path its message arrived by instead.
    private func outgoingPath() -> [String] {
        SessionCoordinator.shared?.aprsPath(forRadio: nil) ?? []
    }

    private func send(to peer: String) {
        let text = String(draft.trimmingCharacters(in: .whitespaces).prefix(APRSMessage.maxTextLength))
        guard !text.isEmpty else { return }
        messaging.sendMessage(to: peer, text: text, from: myCallsign,
                              path: outgoingPath(), radioID: nil)
        draft = ""
    }
}

/// A back-compatible stand-in for `ContentUnavailableView` (which is newer),
/// so the page reads the same on any deployment target the app supports.
private struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String
    init(_ title: String, systemImage: String, description: String) {
        self.title = title; self.systemImage = systemImage; self.description = description
    }
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
