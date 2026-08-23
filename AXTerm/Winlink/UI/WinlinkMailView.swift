import SwiftUI

/// Root of the Winlink feature area: Mail / Stations segmented control,
/// exchange toolbar, and the three-pane mailbox.
struct WinlinkMailView: View {

    enum Tab: String, CaseIterable {
        case mail = "Mail"
        case stations = "Stations"
    }

    @ObservedObject private var context: WinlinkContext
    @ObservedObject private var appSettings: AppSettingsStore
    @ObservedObject private var winlinkSettings: WinlinkSettings
    private let sessionCoordinator: SessionCoordinator
    private let client: PacketEngine

    @StateObject private var mailboxVM: WinlinkMailboxViewModel
    @StateObject private var stationsVM: RMSStationsViewModel
    @StateObject private var catalogVM: WinlinkCatalogViewModel

    @State private var tab: Tab = .mail
    @State private var showingCatalog = false
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
            client: WinlinkCMSClient(accessKey: settingsStore.effectiveAPIKey),
            settings: settingsStore))
        _catalogVM = StateObject(wrappedValue: WinlinkCatalogViewModel(
            store: store,
            client: WinlinkCMSClient(accessKey: settingsStore.effectiveAPIKey)))
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
                switch tab {
                case .mail:
                    mailPanes
                case .stations:
                    RMSStationsView(
                        viewModel: stationsVM,
                        onConnect: { station in startExchange(gatewayOverride: station.callsign) })
                }
            }
        }
        .sheet(isPresented: $showingCatalog) {
            WinlinkCatalogSheet(
                viewModel: catalogVM,
                myCallsign: appSettings.myCallsign,
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
                showingCatalog = true
            } label: {
                Label("Catalog", systemImage: "books.vertical")
            }
            .help(WinlinkCopy.catalogTooltip)

            Spacer()

            runnerStatus

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
                Label(runner.statusText, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if case .failed(let reason) = runner.phase {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(reason)
            }
        }
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
                    let gateway = winlinkSettings.gatewayCallsign
                    Text(gateway.isEmpty
                         ? "Packet — choose a gateway in Stations first"
                         : "Packet via \(gateway)")
                }
                .disabled(winlinkSettings.gatewayCallsign.isEmpty)

                Button("Telnet (Internet)") {
                    startExchange(useTelnet: true)
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
                onForward: { composeForward() })
                .frame(minWidth: 300, idealWidth: 480)
        }
    }

    // MARK: - Compose flows

    private func composeNew() {
        openCompose(prefill: nil)
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
        let transport: WinlinkTransport
        let gatewayName: String
        let transportName: String

        if useTelnet {
            transport = WinlinkTelnetTransport(callsign: myCall)
            gatewayName = "Winlink CMS"
            transportName = "telnet"
        } else {
            let gateway = gatewayOverride ?? winlinkSettings.gatewayCallsign
            guard !gateway.isEmpty else {
                exchangeAlert = "Choose an RMS gateway in the Stations tab first."
                return
            }
            guard client.status == .connected else {
                exchangeAlert = "Connect to your TNC before starting a packet exchange."
                return
            }
            let parsed = CallsignNormalizer.parse(gateway)
            let destination = AX25Address(call: parsed.call, ssid: parsed.ssid)
            let pathText = winlinkSettings.gatewayPath
            let path = pathText.isEmpty
                ? DigiPath()
                : DigiPath.from(pathText.split(separator: ",").map(String.init))
            transport = WinlinkAX25Transport(
                sessionManager: sessionCoordinator.sessionManager,
                sendFrames: { [weak client] frames in
                    for frame in frames { client?.send(frame: frame) }
                },
                destination: destination,
                path: path)
            gatewayName = gateway
            transportName = "ax25"
        }

        Task {
            let summary = await runner.runExchange(
                transport: transport,
                myCallsign: myCall,
                password: password.isEmpty ? nil : password,
                gatewayName: gatewayName,
                transportName: transportName)
            mailboxVM.refresh()
            context.refreshUnread()
            if let failure = summary.failureReason {
                exchangeAlert = failure
            }
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
