#if os(iOS)
import SwiftUI
import Combine

/// The mailbox on a handheld.
///
/// Same view model, same list and same reading pane as the Mac — only the
/// navigation differs. A Mac shows folders, list and message side by side
/// because it has the width; a phone pushes through them, and an iPad gets
/// the columns back automatically because `NavigationSplitView` collapses on
/// its own rather than being told which device it is on.
struct WinlinkMailboxScreen: View {

    @ObservedObject var context: WinlinkContext
    /// The radio. An exchange is a packet session, so the mailbox needs the
    /// engine that owns the link and the session manager that runs it.
    @ObservedObject var client: PacketEngine
    @ObservedObject var appSettings: AppSettingsStore
    let sessionCoordinator: SessionCoordinator
    let myCallsign: String
    /// Imports a spatial attachment onto the map. Nil hides the action.
    var onAddToMap: ((WinlinkB2Message.Attachment, String) -> Void)?

    @StateObject private var viewModel: ViewModelBox
    @StateObject private var catalogVM: WinlinkCatalogViewModel
    @StateObject private var contactsVM: WinlinkContactsViewModel
    @StateObject private var stationsVM: RMSStationsViewModel

    @State private var composingDraft: ComposeTarget?

    /// The draft being edited. A wrapper because `sheet(item:)` needs an
    /// Identifiable and a bare MID string is not one.
    private struct ComposeTarget: Identifiable, Hashable {
        let id: String
    }
    @State private var showingForms = false
    @State private var showingConsole = false
    @State private var activeExchangeGateway = ""
    @State private var exchangeAlert: String?
    /// The download picker's request, mirrored from the runner.
    @State private var inboundSelection: WinlinkSessionRunner.InboundSelectionRequest?

    /// No runner means the store failed to open, so there are no exchanges
    /// to be asked about either.
    private var selectionPublisher: AnyPublisher<WinlinkSessionRunner.InboundSelectionRequest?, Never> {
        context.runner?.$pendingSelection.eraseToAnyPublisher()
            ?? Just(nil).eraseToAnyPublisher()
    }
    @State private var showingFieldStatus = false
    @State private var showingCommsLog = false
    @State private var showingPositionReport = false
    @State private var showingStationMap = false
    @State private var positionComment = ""
    @State private var positionLocation: StationLocation?
    @State private var positionQueued: String?
    @State private var showingCatalog = false
    @State private var composeError: String?

    /// Boxed so the view model can be built from a store that is only known
    /// at init, while `@StateObject` still owns its lifetime.
    ///
    /// The box **forwards** the mailbox's change notifications. Without that,
    /// SwiftUI observes the box — which never changes — and any part of this
    /// screen that reads the mailbox directly renders once and then stops
    /// updating. That is what left the detail column stuck on "Select a
    /// message": the list kept working because it takes the mailbox as its
    /// own `@ObservedObject`, so only the half that had no observer of its
    /// own went stale, which is a hard failure to see.
    final class ViewModelBox: ObservableObject {
        let mailbox: WinlinkMailboxViewModel
        private var forwarding: AnyCancellable?

        init(mailbox: WinlinkMailboxViewModel) {
            self.mailbox = mailbox
            forwarding = mailbox.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    init(context: WinlinkContext,
         client: PacketEngine,
         appSettings: AppSettingsStore,
         sessionCoordinator: SessionCoordinator,
         myCallsign: String,
         onAddToMap: ((WinlinkB2Message.Attachment, String) -> Void)? = nil) {
        self.context = context
        self.client = client
        self.appSettings = appSettings
        self.sessionCoordinator = sessionCoordinator
        self.myCallsign = myCallsign
        self.onAddToMap = onAddToMap
        let call = myCallsign
        let store = context.store!
        _viewModel = StateObject(wrappedValue: ViewModelBox(
            mailbox: WinlinkMailboxViewModel(store: store, myCallsign: { call })))
        let settings = context.settings
        _catalogVM = StateObject(wrappedValue: WinlinkCatalogViewModel(
            store: store,
            makeClient: { WinlinkCMSClient(accessKey: settings.effectiveAPIKey) }))
        _contactsVM = StateObject(wrappedValue: WinlinkContactsViewModel(
            store: context.contactStore ?? NullContactStore()))
        let location = context.locationService
        _stationsVM = StateObject(wrappedValue: RMSStationsViewModel(
            store: store,
            makeClient: { WinlinkCMSClient(accessKey: settings.effectiveAPIKey) },
            settings: settings,
            observer: { [weak location] in
                location?.lastLocation ?? location?.manualLocation()
            }))
    }

    private var mailbox: WinlinkMailboxViewModel { viewModel.mailbox }

    var body: some View {
        NavigationSplitView {
            folderList
        } content: {
            messageList
        } detail: {
            WinlinkMessageDetail(
                stored: mailbox.selectedMessage,
                // These buttons existed and did nothing: the detail view drew
                // Reply, Reply All and Forward, and iOS handed it empty
                // closures.
                onReply: { replyAll in
                    guard let stored = mailbox.selectedMessage else { return }
                    composeNew(prefill: mailbox.replyDraft(to: stored, replyAll: replyAll))
                },
                onForward: {
                    guard let stored = mailbox.selectedMessage else { return }
                    composeNew(prefill: mailbox.forwardDraft(of: stored))
                },
                preferredLocality: context.profile.city,
                onAddToMap: onAddToMap)
        }
        .navigationSplitViewStyle(.balanced)
        .task { mailbox.refresh() }
    }

    // MARK: - Columns

    private var folderList: some View {
        List(selection: Binding(
            get: { mailbox.selectedFolderID },
            set: { mailbox.selectedFolderID = $0 })) {
            Section {
                ForEach(mailbox.folders, id: \.id) { folder in
                    Label(folder.name, systemImage: icon(for: folder))
                        .tag(folder.id ?? 0)
                }
            }

            // The Mac carries these as tabs beside Mail. Both existed on iOS
            // — `WinlinkStationsScreen` was written and then referenced
            // nowhere — so the gateway list was unreachable and the station
            // map's empty state pointed at a "Stations tab" that did not
            // exist on this platform.
            Section("Directory") {
                NavigationLink {
                    WinlinkStationsScreen(
                        viewModel: stationsVM,
                        observerGrid: context.settings.gridSquare)
                } label: {
                    Label("Stations", systemImage: "antenna.radiowaves.left.and.right")
                }


                NavigationLink {
                    WinlinkContactsView(viewModel: contactsVM,
                                        onCompose: { address in composeTo(address) })
                        .navigationTitle("Contacts")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Contacts", systemImage: "person.crop.circle")
                }
            }
        }
        .navigationTitle("Mailbox")
        .refreshable { refresh() }
    }

    /// What the operator's other stations heard.
    ///
    /// Read fresh rather than cached: these arrive on a sync pass, not on a
    /// user action, so a snapshot taken when the screen was built would show
    /// yesterday's answer to a question about today.
    private var remoteObservations: [StationActivityPayload] {
        (try? context.activityStore?.remoteStationActivity()) as? [StationActivityPayload] ?? []
    }

    /// Opens a draft addressed to someone chosen from Contacts.
    private func composeTo(_ address: String) {
        let me = myCallsign.isEmpty ? "NOCALL" : myCallsign
        composeNew(prefill: WinlinkB2Message(
            mid: WinlinkB2Message.generateMID(callsign: me),
            date: Date(),
            type: .privateMessage,
            from: me,
            to: [address],
            cc: [],
            subject: "",
            mbo: me,
            body: Data(),
            attachments: []))
    }

    private var messageList: some View {
        WinlinkMessageList(viewModel: mailbox)
            .navigationTitle(currentFolderName)
            .navigationBarTitleDisplayMode(.inline)
            // Opening a message marks it read inside the view model, which
            // the tab badge does not observe. Without this the badge stayed
            // lit until some unrelated action happened to call refresh().
            .task { mailbox.onUnreadCountChanged = { context.refreshUnread() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let sync = context.sync {
                        // The indicator is the control: it reports when the
                        // mailbox last synced and syncing again is a tap on it.
                        //
                        // Glyph only here. The relative-time label is sized
                        // for a Mac toolbar; in a split-view column it
                        // truncated to "ju..." and ate the space the compose
                        // and exchange buttons needed. The full account is
                        // still one tap away in the explanation.
                        SyncStatusIndicator(sync: sync, showsLabel: false)
                    }
                }
                // Forms and the catalog are the two ways of composing that
                // are not free typing, so they sit beside the pencil rather
                // than inside it.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingForms = true
                        } label: {
                            Label("Forms", systemImage: "doc.text")
                        }
                        Button {
                            showingCatalog = true
                        } label: {
                            Label("Catalog", systemImage: "books.vertical")
                        }
                        Divider()
                        // The transcript outlives its exchange on purpose, so
                        // the last session can be read back. Until now the
                        // only way in was to start another one, which is a
                        // strange price for looking at what already happened.
                        Button {
                            showingConsole = true
                        } label: {
                            Label("Exchange Console", systemImage: "terminal")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composeNew()
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                }
                // The reason the mailbox exists: queued mail leaves here.
                ToolbarItem(placement: .topBarTrailing) {
                    exchangeControl
                }
            }
            // Compose is a window on the Mac and a sheet here: iOS has no
            // second window to put it in, and a draft is a modal task
            // anyway — it ends in send, save or discard.
            .sheet(item: $composingDraft) { target in
                composeSheet(draftMID: target.id)
            }
            .sheet(isPresented: $showingForms) {
                if let store = context.store {
                    NavigationStack {
                        WinlinkFormsSheet(
                            store: store,
                            makeContext: { await makeFormContext() },
                            onQueued: { refresh() })
                    }
                }
            }
            .sheet(isPresented: $showingCatalog) {
                NavigationStack {
                    WinlinkCatalogSheet(
                        viewModel: catalogVM,
                        myCallsign: myCallsign,
                        operatorState: context.profile.state,
                        airtime: catalogAirtime,
                        locationService: context.locationService,
                        onQueued: { refresh() })
                }
            }
            .sheet(isPresented: $showingConsole) { consoleSheet }
            .sheet(isPresented: $showingFieldStatus) {
                NavigationStack {
                    WinlinkFieldStatusSheet(
                        readiness: currentReadiness(),
                        gatewayHours: currentGatewayHours(),
                        location: context.locationService.lastLocation
                            ?? context.locationService.manualLocation())
                }
            }
            // Distinct from the Map tab, which plots stations *heard*. This
            // one plots the RMS gateways that can carry mail, with the link
            // quality actually measured against each — the question is "which
            // gateway should I work", not "who is on the air".
            .sheet(isPresented: $showingStationMap) {
                NavigationStack {
                    WinlinkScopeWindow(
                        stations: (try? context.store?.stations()) ?? [],
                        linkQuality: context.mapLinkQuality,
                        observerGrid: context.settings.gridSquare,
                        observerFix: context.locationService.lastLocation.map {
                            GreatCircle.Point(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .navigationTitle("Station Map")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingStationMap = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingPositionReport) {
                NavigationStack { positionReportSheet }
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingCommsLog) {
                NavigationStack {
                    WinlinkICS309Sheet(
                        messages: loggableMessages(),
                        defaultOperatorName: context.profile.realName,
                        defaultStationId: appSettings.myCallsign)
                }
            }
            .alert("Mail Exchange", isPresented: Binding(
                get: { exchangeAlert != nil },
                set: { if !$0 { exchangeAlert = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exchangeAlert ?? "")
            }
            .onReceive(selectionPublisher) { request in
                // The publisher republishes on resubscribe and `body`
                // rebuilds it; assign only on a real change.
                if inboundSelection != request { inboundSelection = request }
            }
            .sheet(item: $inboundSelection) { request in
                WinlinkInboundSelectionSheet(request: request) { mids in
                    inboundSelection = nil
                    context.runner?.resolveInboundSelection(accepting: mids)
                }
            }
            .alert("Compose", isPresented: Binding(
                get: { composeError != nil },
                set: { if !$0 { composeError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(composeError ?? "")
            }
    }

    // MARK: - Exchange UI

    /// One control that reports as well as acts.
    ///
    /// While a session runs it becomes the way to watch it and the way to stop
    /// it — a separate "abort" hidden elsewhere would be the wrong thing to
    /// hunt for with a transmitter keyed.
    @ViewBuilder
    private var exchangeControl: some View {
        if let runner = context.runner, runner.isRunning {
            Menu {
                Button {
                    showingConsole = true
                } label: {
                    Label("Show Progress", systemImage: "waveform")
                }
                Button(role: .destructive) {
                    runner.abort()
                } label: {
                    Label("Abort Exchange", systemImage: "stop.circle")
                }
            } label: {
                ProgressView().controlSize(.small)
            }
            .accessibilityLabel("Exchange running")
        } else {
            Menu {
                Button {
                    startExchange()
                } label: {
                    Label("Connect & Exchange", systemImage: "antenna.radiowaves.left.and.right")
                }
                if !context.settings.gatewayLadder.isEmpty {
                    Menu("Specific Gateway") {
                        ForEach(context.settings.gatewayLadder, id: \.callsign) { rung in
                            Button(rung.callsign) { startExchange(gatewayOverride: rung) }
                        }
                    }
                }
                Divider()
                Button {
                    startExchange(useTelnet: true)
                } label: {
                    Label("Telnet (Internet)", systemImage: "network")
                }
                Divider()
                Button {
                    showingFieldStatus = true
                } label: {
                    Label("Field Status…", systemImage: "checklist")
                }
                Button {
                    showingCommsLog = true
                } label: {
                    Label("Communications Log (ICS-309)…", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    showingStationMap = true
                } label: {
                    Label("Station Map…", systemImage: "map")
                }
                Button {
                    showingPositionReport = true
                } label: {
                    Label("Report Position…", systemImage: "location.circle")
                }
                Button {
                    if catalogVM.queueTestMessage(myCallsign: appSettings.myCallsign) != nil {
                        refresh()
                    }
                } label: {
                    Label("Queue Loopback Test Message", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Label("Exchange", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }

    /// The live transcript of the running exchange.
    @ViewBuilder
    private var consoleSheet: some View {
        if let runner = context.runner {
            let gateway = activeExchangeGateway.isEmpty
                ? context.settings.gatewayCallsign.uppercased()
                : activeExchangeGateway
            NavigationStack {
                WinlinkExchangeConsoleView(
                    runner: runner,
                    viz: gateway.isEmpty
                        ? sessionCoordinator.linkVizMonitor.mostRecentlyActive
                        : sessionCoordinator.linkVizMonitor.sessions[gateway],
                    gatewayName: gateway.isEmpty ? "Gateway" : gateway,
                    adaptive: sessionCoordinator.adaptiveStatusStore.effectiveAdaptive)
                    .navigationTitle(gateway.isEmpty ? "Exchange" : gateway)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            // Dismisses the view, never the session: an
                            // exchange keeps running while the operator looks
                            // at something else, and stopping it is an
                            // explicit Abort.
                            Button("Done") { showingConsole = false }
                        }
                        if runner.isRunning {
                            ToolbarItem(placement: .destructiveAction) {
                                Button("Abort", role: .destructive) { runner.abort() }
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Composing

    @ViewBuilder
    private func composeSheet(draftMID: String) -> some View {
        if let store = context.store {
            NavigationStack {
                WinlinkComposeWindow(
                    store: store,
                    myCallsign: myCallsign,
                    draftMID: draftMID,
                    locationService: context.locationService,
                    contactStore: context.contactStore,
                    onChanged: { refresh() })
                    .navigationTitle("New Message")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // The compose view carries Save Draft and Queue; this
                        // is the third outcome, and without it a sheet opened
                        // by mistake has no way out.
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { composingDraft = nil }
                        }
                    }
            }
        }
    }

    /// Creates a draft and opens it.
    ///
    /// The draft is saved *before* the editor opens, exactly as on macOS, so
    /// a compose interrupted by a crash or a task switch is still in Drafts
    /// rather than lost with the sheet.
    private func composeNew(prefill: WinlinkB2Message? = nil) {
        guard let store = context.store else { return }
        let me = myCallsign.isEmpty ? "NOCALL" : myCallsign
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
            refresh()
            composingDraft = ComposeTarget(id: draft.mid)
        } catch {
            composeError = "Could not create the draft: \(error.localizedDescription)"
        }
    }

    // MARK: - Position report

    /// Posts a position to the Winlink map (a message to `QTH`).
    ///
    /// This is the self-spotting path when there is no cell coverage — the
    /// POTA/SOTA case, and the one where a handheld is the *only* radio
    /// present, so it belongs on iOS more than it does on the Mac.
    private var positionReportSheet: some View {
        Form {
            Section {
                if let location = positionLocation {
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
                        Text("Getting a position…").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Posts your position to the Winlink map as a message to QTH. With no cell coverage this is how a portable station spots itself.")
            }

            Section {
                TextField("Comment", text: $positionComment,
                          prompt: Text("e.g. POTA K-1234, portable"))
            } footer: {
                Text("Sent with the report and remembered between reports — an activation reference stays the same all day.")
            }
        }
        .navigationTitle("Report Position")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { showingPositionReport = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Queue") { Task { await queuePositionReport() } }
                    // Refused without a fix rather than sent with a guess: a
                    // position report whose position is invented is worse
                    // than none, because it will be believed.
                    .disabled(positionLocation == nil)
            }
        }
        .task {
            positionLocation = await context.locationService.currentLocation()
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
        refresh()
    }

    // MARK: - Station tools

    /// Whether this station is ready to work mail, from what it actually has
    /// rather than from what it was configured with.
    private func currentReadiness() -> WinlinkReadiness {
        let catalogItems = catalogVM.groups.flatMap(\.items)
        let kit = WinlinkOutageKit.build(items: catalogItems, state: context.profile.state)
        let logs = (try? context.store?.sessionLogs(limit: 2000)) ?? []
        let location = context.locationService.lastLocation
            ?? context.locationService.manualLocation()
        return WinlinkReadiness.evaluate(.init(
            callsign: appSettings.myCallsign,
            hasPassword: !context.settings.password.isEmpty,
            passwordVerifiedAt: context.settings.passwordVerifiedAt,
            gatewayCount: context.settings.gatewayLadder.count,
            gridSquare: context.settings.gridSquare,
            hasPositionFix: location?.source == .gps,
            catalogItemCount: catalogItems.count,
            catalogFetchedAt: catalogVM.fetchedAt,
            outageKitCount: kit.count,
            outageKitBytes: WinlinkOutageKit.totalBytes(kit),
            p2pArmed: context.settings.p2pListenEnabled,
            lastSuccessfulSessionAt: logs
                .filter { $0.result == "success" && $0.errorText == nil }
                .map(\.startedAt).max(),
            queuedOutboundCount: (try? context.store?.queuedOutboundMessages().count) ?? 0,
            now: Date()))
    }

    /// When the ladder's first gateway has historically been reachable — the
    /// one worth planning an activation against.
    private func currentGatewayHours() -> WinlinkGatewayHours {
        let logs = (try? context.store?.sessionLogs(limit: 2000)) ?? []
        return WinlinkGatewayHours.profile(
            logs: logs, callsign: context.settings.gatewayLadder.first?.callsign ?? "")
    }

    /// Everything that actually crossed the air, for the ICS-309.
    ///
    /// Drafts are excluded: a message that was never sent has no place in a
    /// communications log, which is a record of traffic and not of intent.
    private func loggableMessages() -> [WinlinkMessageSummary] {
        guard let store = context.store else { return [] }
        var byMID = [String: WinlinkMessageSummary]()
        for folder in mailbox.folders {
            guard let id = folder.id else { continue }
            for summary in (try? store.messages(inFolder: id)) ?? []
            where summary.deliveryState != .draft {
                byMID[summary.mid] = summary
            }
        }
        return Array(byMID.values)
    }

    // MARK: - Exchange
    //
    // Ported from `WinlinkMailView` rather than shared, because the two
    // shells differ only in presentation — but the *rules* below are the
    // protocol's, not the UI's, and must match on both: the pre-flight
    // refusals, and which failures are worth trying the next gateway for.

    /// Runs an exchange, over the ladder or over the internet.
    private func startExchange(gatewayOverride: WinlinkSettings.GatewayLadderEntry? = nil,
                               useTelnet: Bool = false) {
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
            exchangeAlert = "Set your callsign in Settings → Identity before exchanging mail."
            return
        }

        // Refused before keying rather than discovered mid-session: the CMS
        // requires a secure login, and a session that gets as far as the
        // password prompt has already spent airtime for nothing.
        let password = context.settings.password
            guard !password.isEmpty else {
                // "Nothing saved" and "saved but this build cannot open it"
                // need opposite things from the operator, and the second is
                // what actually happens after a rebuild.
                exchangeAlert = context.settings.passwordReadOutcome.operatorAdvice
                    ?? "No Winlink password found — the CMS requires secure login, so "
                    + "the exchange was not started. Enter your password in Settings → Winlink."
                return
            }

        let product = context.settings.clientProduct.trimmingCharacters(in: .whitespaces)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let sid = WinlinkSID(product: product.isEmpty ? "AXTerm" : product,
                             version: version,
                             features: "B2FHM$")

        if useTelnet {
            showingConsole = true
            activeExchangeGateway = "WINLINK CMS"
            let transport = WinlinkTelnetTransport(callsign: myCall)
            Task {
                let summary = await runner.runExchange(
                    transport: transport,
                    myCallsign: myCall,
                    password: password,
                    gatewayName: "Winlink CMS",
                    transportName: "telnet",
                    sid: sid,
                    inboundSelection: context.settings.inboundSelectionPolicy,
                    airtime: catalogAirtime)
                refresh()
                context.exchangeFinished()
                if let failure = summary.failureReason { exchangeAlert = failure }
            }
            return
        }

        let rungs = gatewayOverride.map { [$0] } ?? context.settings.gatewayLadder
        guard !rungs.isEmpty else {
            exchangeAlert = "Add an RMS gateway to your ladder in Settings → Winlink first."
            return
        }
        guard client.status == .connected else {
            exchangeAlert = "Connect to your TNC before starting a packet exchange."
            return
        }

        showingConsole = true
        Task { await runLadder(rungs, runner: runner, myCallsign: myCall,
                               password: password, sid: sid) }
    }

    /// Walks the gateway ladder: tries each rung until a session completes.
    ///
    /// Gateway-specific failures (no answer, busy, link lost) fall through to
    /// the next rung; CMS-level failures stop the ladder, because they would
    /// repeat identically everywhere and trying again is just airtime.
    private func runLadder(_ rungs: [WinlinkSettings.GatewayLadderEntry],
                           runner: WinlinkSessionRunner,
                           myCallsign: String,
                           password: String,
                           sid: WinlinkSID) async {
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

            sessionCoordinator.selectAdaptiveSession(
                destination: rung.callsign, path: rung.path.isEmpty ? nil : rung.path)
            activeExchangeGateway = rung.callsign.uppercased()
            sessionCoordinator.linkVizMonitor.viz(for: rung.callsign).resetTransferCounters()

            let summary = await runner.runExchange(
                transport: transport,
                myCallsign: myCallsign,
                password: password,
                gatewayName: rung.callsign,
                transportName: "ax25",
                frequencyHz: rung.frequencyHz,
                sid: sid,
                preserveTranscript: index > 0,
                inboundSelection: context.settings.inboundSelectionPolicy,
                airtime: WinlinkAirtimeEstimate.forGateway(
                    callsign: rung.callsign, frequencyHz: rung.frequencyHz, quality: [:]))

            refresh()
            context.exchangeFinished()

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

    private func makeFormContext() async -> WinlinkFormContext {
        let location = await context.locationService.currentLocation()
        let profile = context.profile
        return WinlinkFormContext(
            callsign: myCallsign,
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

    /// What a catalog request will cost on the air, from the gateway the
    /// ladder would actually use.
    private var catalogAirtime: WinlinkAirtimeEstimate {
        let rung = context.settings.gatewayLadder.first
        return WinlinkAirtimeEstimate.forGateway(
            callsign: rung?.callsign ?? context.settings.gatewayCallsign,
            frequencyHz: rung?.frequencyHz,
            quality: [:])
    }

    // MARK: - Support

    private var currentFolderName: String {
        mailbox.folders.first { $0.id == mailbox.selectedFolderID }?.name ?? "Mailbox"
    }

    private func refresh() {
        mailbox.refresh()
        context.refreshUnread()
    }

    private func icon(for folder: WinlinkFolderRecord) -> String {
        switch folder.role {
        case .inbox: "tray"
        case .outbox: "tray.and.arrow.up"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .trash: "trash"
        case nil: "folder"
        }
    }
}
#endif
