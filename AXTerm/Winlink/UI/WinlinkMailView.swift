import SwiftUI

/// Root of the Winlink feature area: Mail / Stations segmented control,
/// exchange toolbar, and the three-pane mailbox.
struct WinlinkMailView: View {

    enum Tab: String, CaseIterable {
        case mail = "Mail"
        case stations = "Stations"
        case contacts = "Contacts"
    }

    @ObservedObject private var context: WinlinkContext
    @ObservedObject private var appSettings: AppSettingsStore
    @ObservedObject private var winlinkSettings: WinlinkSettings
    private let sessionCoordinator: SessionCoordinator
    private let client: PacketEngine
    /// Imports a spatial attachment onto the map and switches to it. Nil
    /// hides the action.
    var onAddToMap: ((WinlinkB2Message.Attachment, String) -> Void)?

    /// Passed to the reading pane only when the app wired a map up.
    private var onAddSpatialAttachment: ((WinlinkB2Message.Attachment, String) -> Void)? {
        onAddToMap
    }

    @StateObject private var mailboxVM: WinlinkMailboxViewModel
    @StateObject private var stationsVM: RMSStationsViewModel
    @StateObject private var catalogVM: WinlinkCatalogViewModel
    @StateObject private var contactsVM: WinlinkContactsViewModel

    @State private var tab: Tab = .mail
    @State private var showingCatalog = false
    @State private var showingForms = false
    @State private var showingCommsLog = false
    @State private var showingFieldStatus = false
    @State private var showingPositionReport = false
    @State private var fieldStatusLocation: StationLocation?
    /// The activation reference sent with a position report — a park or
    /// summit ID that stays the same all day, so it is remembered.
    @AppStorage("winlink.positionComment") private var positionComment = ""
    @State private var positionQueued: String?
    @State private var showConsole = false
    @State private var exchangeAlert: String?
    /// The gateway the running (or last) exchange actually talks to — the
    /// active ladder rung, which can differ from the configured gateway.
    @State private var activeExchangeGateway: String = ""

    /// Reading-pane placement, remembered across launches. Stored as the
    /// raw string so `@AppStorage` needs no custom conformance.
    @AppStorage("winlink.readingPaneLayout")
    private var readingPaneLayoutRaw = ReadingPaneLayout.right.rawValue

    private var readingPaneLayout: ReadingPaneLayout {
        ReadingPaneLayout(rawValue: readingPaneLayoutRaw) ?? .right
    }

    @Environment(\.openWindow) private var openWindow

    init(context: WinlinkContext,
         appSettings: AppSettingsStore,
         sessionCoordinator: SessionCoordinator,
         client: PacketEngine,
         onAddToMap: ((WinlinkB2Message.Attachment, String) -> Void)? = nil) {
        self.context = context
        self.appSettings = appSettings
        self.winlinkSettings = context.settings
        self.sessionCoordinator = sessionCoordinator
        self.client = client
        self.onAddToMap = onAddToMap

        let store = context.store ?? FallbackWinlinkStore()
        let settingsStore = context.settings
        let callsignProvider = { [weak appSettings] in appSettings?.myCallsign ?? "" }
        _mailboxVM = StateObject(wrappedValue: WinlinkMailboxViewModel(
            store: store, myCallsign: callsignProvider))
        // The last known position judges whether a stored measurement
        // still describes the link from here; the grid-square fallback
        // keeps the column meaningful when GPS is unavailable.
        let locationService = context.locationService
        _stationsVM = StateObject(wrappedValue: RMSStationsViewModel(
            store: store,
            makeClient: { WinlinkCMSClient(accessKey: settingsStore.effectiveAPIKey) },
            settings: settingsStore,
            observer: { [weak locationService] in
                locationService?.lastLocation ?? locationService?.manualLocation()
            }))
        _catalogVM = StateObject(wrappedValue: WinlinkCatalogViewModel(
            store: store,
            makeClient: { WinlinkCMSClient(accessKey: settingsStore.effectiveAPIKey) }))
        _contactsVM = StateObject(wrappedValue: WinlinkContactsViewModel(
            store: context.contactStore ?? NullContactStore()))
    }

    var body: some View {
        VStack(spacing: 0) {
            if context.store == nil {
                emptyState(
                    title: "Mail unavailable",
                    message: "The AXTerm database could not be opened, so Winlink mail is disabled.")
            } else {
                toolbar
                Divider()
                if showConsole, let runner = context.runner {
                    let gateway = activeExchangeGateway.isEmpty
                        ? winlinkSettings.gatewayCallsign.uppercased()
                        : activeExchangeGateway
                    WinlinkExchangeConsoleView(
                        runner: runner,
                        viz: gateway.isEmpty
                            ? sessionCoordinator.linkVizMonitor.mostRecentlyActive
                            : sessionCoordinator.linkVizMonitor.sessions[gateway],
                        gatewayName: gateway.isEmpty ? "Gateway" : gateway,
                        adaptive: sessionCoordinator.adaptiveStatusStore.effectiveAdaptive,
                        observedCapSeconds: observedCap(for: gateway))
                    Divider()
                }
                switch tab {
                case .mail:
                    mailPanes
                case .stations:
                    RMSStationsView(
                        viewModel: stationsVM,
                        settings: winlinkSettings,
                        onConnect: { station in
                            // Carry the row's frequency through: the same
                            // callsign on 145.050 and 441.075 is two links.
                            // The path is the one stored for *this* link,
                            // falling back to the global default — a digi
                            // route is a property of the link, not of the
                            // station generally.
                            let stored = winlinkSettings.stationPreferences.path(for: station)
                            startExchange(gatewayOverride: .init(
                                callsign: station.callsign,
                                path: stored.isEmpty ? winlinkSettings.gatewayPath : stored,
                                frequencyHz: station.frequencyHz))
                        })
                case .contacts:
                    WinlinkContactsView(
                        viewModel: contactsVM,
                        onCompose: { address in composeTo(address) })
                }
            }
        }
        .sheet(isPresented: $showingForms) {
            if let store = context.store {
                WinlinkFormsSheet(
                    store: store,
                    makeContext: { await makeFormContext() },
                    onQueued: {
                        mailboxVM.refresh()
                        context.refreshUnread()
                    })
            }
        }
        // Arming P2P is a station-wide capability, so the hook is
        // attached whenever the mail area is present and re-evaluated
        // when the setting changes. The listener itself re-checks
        // `isArmed` on every call, so a stale hook can never answer.
        .onAppear { attachP2PListener() }
        // Same reason as the iOS shell: reading a message updates the view
        // model's count, and the sidebar badge reads the context's.
        .onAppear { mailboxVM.onUnreadCountChanged = { context.refreshUnread() } }
        .sheet(isPresented: $showingFieldStatus) {
            WinlinkFieldStatusSheet(
                readiness: currentReadiness(),
                gatewayHours: currentGatewayHours(),
                location: fieldStatusLocation)
        }
        .sheet(isPresented: $showingPositionReport) {
            positionReportSheet
        }
        .sheet(isPresented: $showingCommsLog) {
            WinlinkICS309Sheet(
                messages: loggableMessages(),
                defaultOperatorName: context.profile.realName,
                defaultStationId: appSettings.myCallsign)
        }
        .sheet(isPresented: $showingCatalog) {
            WinlinkCatalogSheet(
                viewModel: catalogVM,
                myCallsign: appSettings.myCallsign,
                operatorState: context.profile.state,
                airtime: catalogAirtime,
                locationService: context.locationService,
                onQueued: {
                    mailboxVM.refresh()
                    context.refreshUnread()
                })
        }
        .alert("Mail Exchange", isPresented: Binding(
            get: { exchangeAlert != nil },
            set: { if !$0 { exchangeAlert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exchangeAlert ?? "")
        }
        .onAppear {
            // Defer one tick: onAppear runs inside SwiftUI's update
            // transaction on macOS, and refresh()/refreshUnread() mutate
            // @Published state ("Publishing changes from within view
            // updates is not allowed").
            Task { @MainActor in
                mailboxVM.refresh()
                context.refreshUnread()
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .labelsHidden()

            Button {
                composeNew()
            } label: {
                Label("Compose", systemImage: "square.and.pencil")
            }
            .help(WinlinkCopy.composeTooltip)

            Button {
                showingForms = true
            } label: {
                Label("Forms", systemImage: "doc.text")
            }
            .help("Winlink forms: check-ins, ICS-213, situation and weather reports, position reports. Auto-filled from your profile and position; recipients see the official form.")

            Button {
                showingCatalog = true
            } label: {
                Label("Catalog", systemImage: "books.vertical")
            }
            .help(WinlinkCopy.catalogTooltip)

            if tab == .mail {
                stationToolsMenu
            }

            Spacer()

            runnerStatus

            if context.runner != nil {
                Button {
                    showConsole.toggle()
                } label: {
                    Image(systemName: showConsole ? "chevron.up.square" : "terminal")
                }
                .help("Show the exchange console — the live conversation with the gateway (what is being sent and received).")
                .accessibilityIdentifier("winlinkConsoleToggle")
            }

            exchangeControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var runnerStatus: some View {
        if let runner = context.runner {
            if runner.isRunning {
                WinlinkExchangeProgressView(runner: runner)
            } else if case .done = runner.phase {
                resultBanner(
                    icon: "checkmark.circle.fill",
                    tint: .green,
                    text: runner.statusText,
                    runner: runner)
            } else if case .failed(let reason) = runner.phase {
                resultBanner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    text: reason,
                    runner: runner)
            }
        }
    }

    /// Result of the last exchange — persists until dismissed, so it is
    /// still there after stepping away. Clicking it opens the console.
    private func resultBanner(icon: String, tint: Color, text: String, runner: WinlinkSessionRunner) -> some View {
        HStack(spacing: 6) {
            Button {
                showConsole.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            .help("\(text)\n\nClick to review the full exchange transcript.")

            Button {
                runner.clearResult()
                showConsole = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this result")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.1), in: Capsule())
    }

    @ViewBuilder
    private var exchangeControls: some View {
        if let runner = context.runner, runner.isRunning {
            Button(role: .destructive) {
                runner.abort()
            } label: {
                Label("Abort", systemImage: "xmark.octagon")
            }
            .help(WinlinkCopy.abortExchangeTooltip)
        } else {
            Menu {
                Button {
                    startExchange(gatewayOverride: nil)
                } label: {
                    let ladder = winlinkSettings.gatewayLadder
                    if ladder.isEmpty {
                        Text("Packet — add gateways in Stations first")
                    } else if ladder.count == 1 {
                        Text("Packet via \(ladder[0].callsign)")
                    } else {
                        Text("Packet ladder: \(ladder.prefix(3).map(\.callsign).joined(separator: " → "))\(ladder.count > 3 ? " …" : "")")
                    }
                }
                .disabled(winlinkSettings.gatewayLadder.isEmpty)

                Button("Telnet (Internet)") {
                    startExchange(useTelnet: true)
                }

                Divider()

                Button("Queue Loopback Test Message") {
                    if catalogVM.queueTestMessage(myCallsign: appSettings.myCallsign) != nil {
                        mailboxVM.refresh()
                        exchangeAlert = "Test message queued. Exchange once to send it — the Winlink TEST bot echoes it back on your next exchange."
                    }
                }
            } label: {
                Label("Connect & Exchange", systemImage: "envelope.arrow.triangle.branch")
            }
            .help(WinlinkCopy.connectExchangeTooltip)
        }
    }

    // MARK: - Mail panes

    /// Where the reading pane sits, or whether it appears at all.
    ///
    /// Right is the classic three-column mail layout and suits ordinary
    /// correspondence. Bottom gives the reading pane the window's full
    /// width, which is what the natively-rendered products need — a
    /// seven-day tabular forecast is eight columns wide and unreadable
    /// in a side pane.
    enum ReadingPaneLayout: String, CaseIterable, Identifiable {
        case right, bottom, hidden
        var id: String { rawValue }

        var title: String {
            switch self {
            case .right: "Reading Pane on Right"
            case .bottom: "Reading Pane at Bottom"
            case .hidden: "Hide Reading Pane"
            }
        }

        var systemImage: String {
            switch self {
            case .right: "sidebar.right"
            case .bottom: "rectangle.bottomthird.inset.filled"
            case .hidden: "rectangle"
            }
        }
    }

    private var mailPanes: some View {
        HSplitView {
            WinlinkFolderSidebar(viewModel: mailboxVM)
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 260)

            switch readingPaneLayout {
            case .right:
                messageList
                    .frame(minWidth: 320, idealWidth: 460)
                messageDetail
                    .frame(minWidth: 300, idealWidth: 480)
            case .bottom:
                VSplitView {
                    messageList
                        .frame(minHeight: 140, idealHeight: 240)
                    messageDetail
                        .frame(minHeight: 200, idealHeight: 420)
                }
                .frame(minWidth: 420)
            case .hidden:
                messageList
                    .frame(minWidth: 320)
            }
        }
    }

    private var messageList: some View {
        WinlinkMessageList(
            viewModel: mailboxVM,
            onOpenInWindow: { mid in openWindow(id: "winlinkMessage", value: mid) })
    }

    private var messageDetail: some View {
        WinlinkMessageDetail(
            stored: mailboxVM.selectedMessage,
            onReply: { replyAll in composeReply(replyAll: replyAll) },
            onForward: { composeForward() },
            preferredLocality: context.profile.city,
            knownContact: { address in contactsVM.contact(forAddress: address) != nil },
            onAddContact: { address in addContact(address: address) },
            onAddToMap: onAddSpatialAttachment,
            onOpenInWindow: { openSelectedMessageInWindow() })
    }

    /// Lifts the selected message into its own window, sized for its
    /// content rather than for the split.
    private func openSelectedMessageInWindow() {
        guard let mid = mailboxVM.selectedMessage?.message.mid else { return }
        openWindow(id: "winlinkMessage", value: mid)
    }

    /// Occasional actions live behind one control rather than each
    /// taking permanent toolbar space. The toolbar should carry what an
    /// operator reaches for every session; everything else is a menu.
    private var stationToolsMenu: some View {
        Menu {
            Picker("Reading Pane", selection: $readingPaneLayoutRaw) {
                ForEach(ReadingPaneLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.systemImage).tag(layout.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()
            Button("Open Message in Window") { openSelectedMessageInWindow() }
                .disabled(mailboxVM.selectedMessage == nil)

            Divider()
            Button("Station Map\u{2026}") { openScope() }
            Button("Field Status\u{2026}") { openFieldStatus() }
            Button("Report Position\u{2026}") { showingPositionReport = true }

            Divider()
            Button("Communications Log (ICS-309)\u{2026}") { showingCommsLog = true }
        } label: {
            Label("Station Tools", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Reading-pane placement, opening a message in its own window, and the ICS-309 communications log.")
    }

    // MARK: - Winlink P2P

    /// Answers inbound calls as a P2P mail peer when the operator has
    /// armed it. Every decision is logged to the exchange console —
    /// a station that silently ignores callers is indistinguishable
    /// from a broken one.
    private func attachP2PListener() {
        sessionCoordinator.onInboundSessionConnected = { session in
            Task { @MainActor in
                let listener = WinlinkP2PListener(
                    isArmed: winlinkSettings.p2pListenEnabled,
                    myCallsign: winlinkSettings.effectiveP2PCallsign(
                        stationCallsign: appSettings.myCallsign),
                    isExchangeRunning: context.runner?.isRunning ?? true,
                    // Refuses to answer when another of the operator's devices
                    // already holds this callsign on this TNC — otherwise both
                    // reply to the same caller with nobody watching.
                    contestedBy: context.contestedIdentityHolder)
                let called = session.localAddress.display
                let decision = listener.decide(
                    called: called, isInitiator: session.isInitiator)
                guard decision == .answer else {
                    if case .weInitiated = decision { return }
                    context.runner?.note(
                        "Inbound call from \(session.remoteAddress.display) \(decision.explanation)")
                    return
                }
                await answerP2PCall(session)
            }
        }
    }

    private func answerP2PCall(_ session: AX25Session) async {
        guard let runner = context.runner else { return }
        let peer = session.remoteAddress.display.uppercased()
        // The transport reuses the already-connected session rather than
        // placing a call: `open()` finds it and returns immediately.
        let transport = WinlinkAX25Transport(
            sessionManager: sessionCoordinator.sessionManager,
            sendFrames: { [weak client] frames in
                for frame in frames { client?.send(frame: frame) }
            },
            destination: session.remoteAddress,
            channel: session.channel)
        _ = await runner.runExchange(
            transport: transport,
            myCallsign: appSettings.myCallsign,
            password: nil,          // P2P carries no CMS account
            gatewayName: peer,
            transportName: "P2P",
            role: .answering)
        mailboxVM.refresh()
        context.exchangeFinished()
        stationsVM.reloadLinkQuality()
    }

    // MARK: - Field status

    /// A GPS fix takes seconds; the sheet should not wait on it before
    /// opening, so the position fills in when it arrives.
    private func openFieldStatus() {
        showingFieldStatus = true
        Task { @MainActor in
            fieldStatusLocation = await context.locationService.currentLocation()
        }
    }

    /// Opens the map as its own window so it can be resized, zoomed and
    /// put full-screen — none of which a sheet allows.
    private func openScope() {
        openWindow(id: "winlinkMap")
    }

    private func currentReadiness() -> WinlinkReadiness {
        let catalogItems = catalogVM.groups.flatMap(\.items)
        let kit = WinlinkOutageKit.build(items: catalogItems, state: context.profile.state)
        let logs = (try? context.store?.sessionLogs(limit: 2000)) ?? []
        return WinlinkReadiness.evaluate(.init(
            callsign: appSettings.myCallsign,
            hasPassword: !winlinkSettings.password.isEmpty,
            gatewayCount: winlinkSettings.gatewayLadder.count,
            gridSquare: winlinkSettings.gridSquare,
            hasPositionFix: fieldStatusLocation?.source == .gps,
            catalogItemCount: catalogItems.count,
            catalogFetchedAt: catalogVM.fetchedAt,
            outageKitCount: kit.count,
            outageKitBytes: WinlinkOutageKit.totalBytes(kit),
            p2pArmed: winlinkSettings.p2pListenEnabled,
            lastSuccessfulSessionAt: logs
                .filter { $0.result == "success" && $0.errorText == nil }
                .map(\.startedAt).max(),
            queuedOutboundCount: (try? context.store?.queuedOutboundMessages().count) ?? 0,
            now: Date()))
    }

    private func currentGatewayHours() -> WinlinkGatewayHours {
        let logs = (try? context.store?.sessionLogs(limit: 2000)) ?? []
        // The first ladder rung is the gateway this station actually
        // works, so its hours are the ones worth planning against.
        return WinlinkGatewayHours.profile(
            logs: logs, callsign: winlinkSettings.gatewayLadder.first?.callsign ?? "")
    }

    // MARK: - Position report

    /// Posts a position to the Winlink map (a message to `QTH`), which
    /// is the self-spotting path when there is no cell coverage — the
    /// POTA/SOTA case. Reuses the existing Position Report form so the
    /// wire format stays the one Winlink expects.
    private var positionReportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Report Position", systemImage: "location.circle")
                .font(.headline)
            Text("Posts your position to the Winlink map as a message to QTH. With no cell coverage this is how a portable station spots itself.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let location = fieldStatusLocation {
                LabeledContent("Position") {
                    Text("\(StationLocationFormat.signedDecimal(location))  \(location.gridSquare)")
                        .font(.callout.monospaced())
                }
                LabeledContent("Source") {
                    Text(location.source.rawValue).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Getting a position\u{2026}").foregroundStyle(.secondary)
                }
            }

            TextField("Comment", text: $positionComment,
                      prompt: Text("e.g. POTA K-1234, portable"))
                .textFieldStyle(.roundedBorder)
                .help("Sent with the report and remembered between reports \u{2014} an activation reference stays the same all day.")

            HStack {
                Spacer()
                Button("Cancel") { showingPositionReport = false }
                Button("Queue Report") {
                    Task { await queuePositionReport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fieldStatusLocation == nil)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            Task { @MainActor in
                fieldStatusLocation = await context.locationService.currentLocation()
            }
        }
        .alert("Position report queued", isPresented: Binding(
            get: { positionQueued != nil },
            set: { if !$0 { positionQueued = nil } })) {
            Button("OK") { showingPositionReport = false }
        } message: {
            Text("It is in your Outbox. Send it with Connect & Exchange, or it will ride along with the next one.")
        }
    }

    private func queuePositionReport() async {
        guard let store = context.store,
              let template = WinlinkFormTemplates.all.first(where: { $0.id == "gps-position-report" })
        else { return }
        let formContext = await makeFormContext()
        let composer = WinlinkFormComposeViewModel(
            template: template, context: formContext, store: store)
        if !positionComment.trimmingCharacters(in: .whitespaces).isEmpty {
            composer.values["Message"] = positionComment
        }
        guard let mid = composer.queue() else { return }
        positionQueued = mid
        mailboxVM.refresh()
        context.refreshUnread()
    }

    /// Every message that actually crossed the air, across all folders.
    ///
    /// Drafts are excluded: a message that was composed but never sent is
    /// not traffic, and logging it would overstate what the station did.
    private func loggableMessages() -> [WinlinkMessageSummary] {
        guard let store = context.store else { return [] }
        var byMID = [String: WinlinkMessageSummary]()
        for folder in mailboxVM.folders {
            guard let id = folder.id else { continue }
            for summary in (try? store.messages(inFolder: id)) ?? []
            where summary.deliveryState != .draft {
                byMID[summary.mid] = summary
            }
        }
        return Array(byMID.values)
    }

    /// Context for form auto-fill: callsign, position (GPS fix when
    /// available), and the operator profile.
    private func makeFormContext() async -> WinlinkFormContext {
        let location = await context.locationService.currentLocation()
        let profile = context.profile
        return WinlinkFormContext(
            callsign: appSettings.myCallsign,
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
            now: Date(),
            location: location,
            operatorName: profile.realName,
            operatorNameWithTitle: profile.nameWithTitle,
            operatorPhone: profile.phone,
            operatorEmail: profile.email,
            organization: profile.organization,
            city: profile.city,
            state: profile.state,
            county: profile.county)
    }

    // MARK: - Compose flows

    private func composeNew() {
        openCompose(prefill: nil)
    }

    /// Compose to a specific address (contact row, add-sender flows).
    private func composeTo(_ address: String) {
        let me = appSettings.myCallsign.isEmpty ? "NOCALL" : appSettings.myCallsign
        let draft = WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: me),
            date: Date(),
            type: .privateMessage,
            from: me,
            to: [address],
            cc: [],
            subject: "",
            mbo: me,
            body: Data(),
            attachments: [])
        openCompose(prefill: draft)
    }

    /// Jumps to the Contacts tab with the editor prefilled.
    private func addContact(address: String) {
        tab = .contacts
        contactsVM.beginNewContact(prefillAddress: address)
    }

    private func composeReply(replyAll: Bool) {
        guard let stored = mailboxVM.selectedMessage else { return }
        openCompose(prefill: mailboxVM.replyDraft(to: stored, replyAll: replyAll))
    }

    private func composeForward() {
        guard let stored = mailboxVM.selectedMessage else { return }
        openCompose(prefill: mailboxVM.forwardDraft(of: stored))
    }

    /// Compose always edits a persisted draft row, so the window can be
    /// reopened and drafts survive restarts.
    private func openCompose(prefill: WinlinkB2Message?) {
        guard let store = context.store else { return }
        let me = appSettings.myCallsign.isEmpty ? "NOCALL" : appSettings.myCallsign
        let draft = prefill ?? WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: me),
            date: Date(),
            type: .privateMessage,
            from: me,
            to: [],
            cc: [],
            subject: "",
            mbo: me,
            body: Data(),
            attachments: [])
        do {
            try store.saveDraft(draft)
            mailboxVM.refresh()
            openWindow(id: "winlinkCompose", value: draft.mid)
        } catch {
            exchangeAlert = "Could not create the draft: \(error)"
        }
    }

    // MARK: - Exchange

    /// The longest session this gateway has previously allowed, across any
    /// of its frequencies. A cap is a property of the gateway's software,
    /// not of the channel, so it carries between bands.
    private func observedCap(for gateway: String) -> Double? {
        WinlinkAirtimeEstimate.forGateway(
            callsign: gateway, frequencyHz: nil, quality: stationsVM.linkQuality)
            .sessionCapSeconds
    }

    /// What a catalog request will actually cost on the air, measured
    /// from this station's own sessions with the gateway it will use.
    /// The first ladder rung is the one `startExchange` tries first, and
    /// it carries the frequency — which decides the rate, since the same
    /// gateway behaves nothing alike at 1200 and 9600 baud.
    private var catalogAirtime: WinlinkAirtimeEstimate {
        let rung = winlinkSettings.gatewayLadder.first
        return WinlinkAirtimeEstimate.forGateway(
            callsign: rung?.callsign ?? winlinkSettings.gatewayCallsign,
            frequencyHz: rung?.frequencyHz,
            quality: stationsVM.linkQuality)
    }

    private func startExchange(
        gatewayOverride: WinlinkSettings.GatewayLadderEntry? = nil,
        useTelnet: Bool = false
    ) {
        // Every other guard here tells the operator why nothing happened;
        // these two used to return in silence, so a tap on Start Exchange
        // was indistinguishable from a dead button. Whatever the cause, the
        // operator needs to see that the app declined rather than failed.
        guard let runner = context.runner else {
            exchangeAlert = "The mailbox is not ready yet \u{2014} the Winlink store failed to open on this device. Reopening the app usually clears it."
            return
        }
        guard !runner.isRunning else {
            exchangeAlert = "An exchange is already running. Open the exchange console to watch it, or wait for it to finish."
            return
        }

        let myCall = appSettings.myCallsign
        guard !myCall.isEmpty, myCall != "NOCALL" else {
            exchangeAlert = "Set your callsign in Settings → General before exchanging mail."
            return
        }

        let password = winlinkSettings.password
        guard !password.isEmpty else {
            exchangeAlert = "No Winlink password found — the CMS requires secure login, so the exchange was not started. Enter your password in Settings → Winlink. (After rebuilding or reinstalling the app, macOS can revoke Keychain access; re-entering the password once fixes it.)"
            return
        }
        let product = winlinkSettings.clientProduct.trimmingCharacters(in: .whitespaces)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let sid = WinlinkSID(
            product: product.isEmpty ? "AXTerm" : product,
            version: version,
            features: "B2FHM$")

        if useTelnet {
            showConsole = true
            activeExchangeGateway = "WINLINK CMS"
            let transport = WinlinkTelnetTransport(callsign: myCall)
            Task {
                let summary = await runner.runExchange(
                    transport: transport,
                    myCallsign: myCall,
                    password: password.isEmpty ? nil : password,
                    gatewayName: "Winlink CMS",
                    transportName: "telnet",
                    sid: sid)
                mailboxVM.refresh()
                context.exchangeFinished()
                if let failure = summary.failureReason {
                    exchangeAlert = failure
                }
            }
            return
        }

        // RF: a single station (row button) or the whole ladder.
        let rungs: [WinlinkSettings.GatewayLadderEntry]
        if let gatewayOverride {
            rungs = [gatewayOverride]
        } else {
            rungs = winlinkSettings.gatewayLadder
        }
        guard !rungs.isEmpty else {
            exchangeAlert = "Add an RMS gateway to your ladder in the Stations tab first."
            return
        }
        guard client.status == .connected else {
            exchangeAlert = "Connect to your TNC before starting a packet exchange."
            return
        }

        showConsole = true
        Task {
            await runLadder(rungs, runner: runner, myCallsign: myCall,
                            password: password, sid: sid)
        }
    }

    /// Walks the gateway ladder: tries each rung until a session
    /// completes. Gateway-specific failures (no answer, busy, link lost)
    /// fall through to the next rung; CMS-level failures stop the ladder
    /// because they would repeat everywhere.
    private func runLadder(
        _ rungs: [WinlinkSettings.GatewayLadderEntry],
        runner: WinlinkSessionRunner,
        myCallsign: String,
        password: String,
        sid: WinlinkSID
    ) async {
        var lastFailure: String?
        var lastFailedCallsign = rungs[0].callsign

        for (index, rung) in rungs.enumerated() {
            let parsed = CallsignNormalizer.parse(rung.callsign)
            let destination = AX25Address(call: parsed.call, ssid: parsed.ssid)
            let path = rung.path.isEmpty
                ? DigiPath()
                : DigiPath.from(rung.path.split(separator: ",").map(String.init))
            let transport = WinlinkAX25Transport(
                sessionManager: sessionCoordinator.sessionManager,
                sendFrames: { [weak client] frames in
                    for frame in frames { client?.send(frame: frame) }
                },
                destination: destination,
                path: path)

            // Point the adaptive toolbar at this exchange's route so the
            // popover shows the session scope instead of "Global Network".
            sessionCoordinator.selectAdaptiveSession(
                destination: rung.callsign, path: rung.path.isEmpty ? nil : rung.path)

            // Fresh per-transfer stats for the console's Activity pane —
            // link-level RTT/window history stays for continuity.
            activeExchangeGateway = rung.callsign.uppercased()
            sessionCoordinator.linkVizMonitor.viz(for: rung.callsign).resetTransferCounters()

            let summary = await runner.runExchange(
                transport: transport,
                myCallsign: myCallsign,
                password: password.isEmpty ? nil : password,
                gatewayName: rung.callsign,
                transportName: "ax25",
                frequencyHz: rung.frequencyHz,
                sid: sid,
                preserveTranscript: index > 0)

            mailboxVM.refresh()
            context.exchangeFinished()
            // This session just became evidence — including a no-answer,
            // which is exactly the outcome the Link column should show.
            stationsVM.reloadLinkQuality()

            guard let failure = summary.failureReason else {
                sessionCoordinator.selectAdaptiveSession(destination: nil, path: nil)
                return  // success — the ladder is done
            }
            lastFailure = failure
            lastFailedCallsign = rung.callsign

            let hasNextRung = index + 1 < rungs.count
            if hasNextRung, WinlinkExchangeFailureClass.isWorthTryingNextGateway(failure) {
                continue
            }
            break
        }

        sessionCoordinator.selectAdaptiveSession(destination: nil, path: nil)

        if let lastFailure {
            exchangeAlert = rungs.count > 1
                ? "No gateway completed a session. Last error (\(lastFailedCallsign)): \(lastFailure)"
                : lastFailure
        }
    }

    // MARK: - Helpers

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inert store used only when the database failed to open, so view
/// models still construct (the UI shows a disabled notice instead).
private nonisolated final class FallbackWinlinkStore: WinlinkStore, @unchecked Sendable {
    func folders() throws -> [WinlinkFolderRecord] { [] }
    func folderID(for role: WinlinkFolderRecord.SystemRole) throws -> Int64 {
        throw WinlinkStoreError.missingSystemFolder(role.rawValue)
    }
    func createFolder(name: String) throws -> WinlinkFolderRecord {
        throw WinlinkStoreError.missingSystemFolder("unavailable")
    }
    func renameFolder(id: Int64, name: String) throws { throw WinlinkStoreError.folderNotFound(id) }
    func deleteFolder(id: Int64) throws { throw WinlinkStoreError.folderNotFound(id) }
    func saveDraft(_ message: WinlinkB2Message) throws { throw WinlinkStoreError.missingSystemFolder("unavailable") }
    func updateDraft(_ message: WinlinkB2Message) throws { throw WinlinkStoreError.messageNotFound(message.mid) }
    func queueDraft(mid: String) throws { throw WinlinkStoreError.messageNotFound(mid) }
    func queuedOutboundMessages() throws -> [WinlinkB2Message] { [] }
    func markSending(mid: String) throws {}
    func markSent(mid: String) throws {}
    func markFailed(mid: String, error: String) throws {}
    func markDeferred(mid: String) throws {}
    func savePartialBody(mid: String, compressedSize: Int, data: Data) throws {}
    func partialBodies() throws -> [WinlinkPartialBodyRecord] { [] }
    func deletePartialBody(mid: String) throws {}
    func revertSendingToQueued() throws {}
    func recordSentOffset(mid: String, offset: Int) throws {}
    func saveInbound(_ message: WinlinkB2Message) throws -> Bool { false }
    func messages(inFolder folderId: Int64) throws -> [WinlinkMessageSummary] { [] }
    func message(mid: String) throws -> WinlinkStoredMessage? { nil }
    func inboundMessages(fromAddr: String, limit: Int) throws -> [WinlinkStoredMessage] { [] }
    func catalogFavorites() throws -> Set<String> { [] }
    func setCatalogFavorite(inquiryId: String, isFavorite: Bool) throws {}
    func callsignRecord(callsign: String) throws -> CallsignDirectoryRecord? { nil }
    func saveCallsignRecord(_ record: CallsignDirectoryRecord) throws {}
    func setRead(mid: String, _ read: Bool) throws {}
    func move(mid: String, toFolder folderId: Int64) throws {}
    func moveToTrash(mid: String) throws {}
    func unreadInboxCount() throws -> Int { 0 }
    func replaceStationCache(_ stations: [WinlinkRMSStationRecord],
                             scope: WinlinkRMSStationRecord.Scope) throws {}
    func stations() throws -> [WinlinkRMSStationRecord] { [] }
    func stations(scope: WinlinkRMSStationRecord.Scope) throws -> [WinlinkRMSStationRecord] { [] }
    func downloadedGridFields() throws -> [(field: String, count: Int)] { [] }
    func clearDownloadedStations() throws {}
    func replaceCatalogCache(_ items: [WinlinkCatalogItemRecord]) throws {}
    func catalogItems() throws -> [WinlinkCatalogItemRecord] { [] }
    func appendSessionLog(_ log: WinlinkSessionLogRecord) throws {}
    func sessionLogs(limit: Int) throws -> [WinlinkSessionLogRecord] { [] }
}
