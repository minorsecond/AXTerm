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

    @StateObject private var mailboxVM: WinlinkMailboxViewModel
    @StateObject private var stationsVM: RMSStationsViewModel
    @StateObject private var catalogVM: WinlinkCatalogViewModel
    @StateObject private var contactsVM: WinlinkContactsViewModel

    @State private var tab: Tab = .mail
    @State private var showingCatalog = false
    @State private var showingForms = false
    @State private var showConsole = false
    @State private var exchangeAlert: String?

    @Environment(\.openWindow) private var openWindow

    init(context: WinlinkContext,
         appSettings: AppSettingsStore,
         sessionCoordinator: SessionCoordinator,
         client: PacketEngine) {
        self.context = context
        self.appSettings = appSettings
        self.winlinkSettings = context.settings
        self.sessionCoordinator = sessionCoordinator
        self.client = client

        let store = context.store ?? FallbackWinlinkStore()
        let settingsStore = context.settings
        let callsignProvider = { [weak appSettings] in appSettings?.myCallsign ?? "" }
        _mailboxVM = StateObject(wrappedValue: WinlinkMailboxViewModel(
            store: store, myCallsign: callsignProvider))
        _stationsVM = StateObject(wrappedValue: RMSStationsViewModel(
            store: store,
            makeClient: { WinlinkCMSClient(accessKey: settingsStore.effectiveAPIKey) },
            settings: settingsStore))
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
                    WinlinkExchangeConsoleView(runner: runner)
                    Divider()
                }
                switch tab {
                case .mail:
                    mailPanes
                case .stations:
                    RMSStationsView(
                        viewModel: stationsVM,
                        onConnect: { station in startExchange(gatewayOverride: station.callsign) })
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
        .sheet(isPresented: $showingCatalog) {
            WinlinkCatalogSheet(
                viewModel: catalogVM,
                myCallsign: appSettings.myCallsign,
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
            mailboxVM.refresh()
            context.refreshUnread()
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

    private var mailPanes: some View {
        HSplitView {
            WinlinkFolderSidebar(viewModel: mailboxVM)
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 260)

            WinlinkMessageList(viewModel: mailboxVM)
                .frame(minWidth: 320, idealWidth: 460)

            WinlinkMessageDetail(
                viewModel: mailboxVM,
                onReply: { replyAll in composeReply(replyAll: replyAll) },
                onForward: { composeForward() },
                knownContact: { address in contactsVM.contact(forAddress: address) != nil },
                onAddContact: { address in addContact(address: address) })
                .frame(minWidth: 300, idealWidth: 480)
        }
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

    private func startExchange(gatewayOverride: String? = nil, useTelnet: Bool = false) {
        guard let runner = context.runner else { return }
        guard !runner.isRunning else { return }

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
                context.refreshUnread()
                if let failure = summary.failureReason {
                    exchangeAlert = failure
                }
            }
            return
        }

        // RF: a single station (row button) or the whole ladder.
        let rungs: [WinlinkSettings.GatewayLadderEntry]
        if let gatewayOverride {
            rungs = [.init(callsign: gatewayOverride, path: winlinkSettings.gatewayPath)]
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

            let summary = await runner.runExchange(
                transport: transport,
                myCallsign: myCallsign,
                password: password.isEmpty ? nil : password,
                gatewayName: rung.callsign,
                transportName: "ax25",
                sid: sid,
                preserveTranscript: index > 0)

            mailboxVM.refresh()
            context.refreshUnread()

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
    func revertSendingToQueued() throws {}
    func recordSentOffset(mid: String, offset: Int) throws {}
    func saveInbound(_ message: WinlinkB2Message) throws -> Bool { false }
    func messages(inFolder folderId: Int64) throws -> [WinlinkMessageSummary] { [] }
    func message(mid: String) throws -> WinlinkStoredMessage? { nil }
    func setRead(mid: String, _ read: Bool) throws {}
    func move(mid: String, toFolder folderId: Int64) throws {}
    func moveToTrash(mid: String) throws {}
    func unreadInboxCount() throws -> Int { 0 }
    func replaceStationCache(_ stations: [WinlinkRMSStationRecord]) throws {}
    func stations() throws -> [WinlinkRMSStationRecord] { [] }
    func replaceCatalogCache(_ items: [WinlinkCatalogItemRecord]) throws {}
    func catalogItems() throws -> [WinlinkCatalogItemRecord] { [] }
    func appendSessionLog(_ log: WinlinkSessionLogRecord) throws {}
    func sessionLogs(limit: Int) throws -> [WinlinkSessionLogRecord] { [] }
}
