//
//  TerminalView.swift
//  AXTerm
//
//  Main terminal view combining session output, compose, and transfer management.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Observable View Model Wrapper

/// Observable wrapper around TerminalTxViewModel for SwiftUI binding
@MainActor
final class ObservableTerminalTxViewModel: ObservableObject {
    @Published private(set) var viewModel: TerminalTxViewModel

    init(sourceCall: String = "") {
        var vm = TerminalTxViewModel()
        vm.sourceCall = sourceCall
        self.viewModel = vm
    }

    // MARK: - Compose Bindings

    var composeText: Binding<String> {
        Binding(
            get: { self.viewModel.composeText },
            set: { self.viewModel.composeText = $0 }
        )
    }

    var destinationCall: Binding<String> {
        Binding(
            get: { self.viewModel.destinationCall },
            set: { self.viewModel.destinationCall = $0 }
        )
    }

    var digiPath: Binding<String> {
        Binding(
            get: { self.viewModel.digiPath },
            set: { self.viewModel.digiPath = $0 }
        )
    }

    // MARK: - Read-only Properties

    var sourceCall: String {
        viewModel.sourceCall
    }

    var canSend: Bool {
        viewModel.canSend
    }

    var characterCount: Int {
        viewModel.characterCount
    }

    var queueEntries: [TxQueueEntry] {
        viewModel.queueEntries
    }

    var queueDepth: Int {
        viewModel.queueEntries.filter { entry in
            switch entry.state.status {
            case .queued, .sending, .awaitingAck:
                return true
            default:
                return false
            }
        }.count
    }

    // MARK: - Actions

    func updateSourceCall(_ call: String) {
        viewModel.sourceCall = call
    }

    func enqueueCurrentMessage() {
        viewModel.enqueueCurrentMessage()
    }

    func clearCompose() {
        viewModel.composeText = ""
    }

    func cancelFrame(_ frameId: UUID) {
        viewModel.cancelFrame(frameId)
    }

    func clearCompleted() {
        viewModel.clearCompleted()
    }
}

// MARK: - Terminal Tab Enum

enum TerminalTab: String, CaseIterable {
    case session = "Session"
    case transfers = "Transfers"
}

// MARK: - Terminal View

/// Main terminal view with session output and transmission controls
struct TerminalView: View {
    @ObservedObject var client: PacketEngine
    @ObservedObject var settings: AppSettingsStore
    @StateObject private var txViewModel: ObservableTerminalTxViewModel

    @State private var selectedTab: TerminalTab = .session
    @State private var showingTransferSheet = false
    @State private var selectedFileURL: URL?

    // Bulk transfer state (simplified for now)
    @State private var transfers: [BulkTransfer] = []

    init(client: PacketEngine, settings: AppSettingsStore) {
        self.client = client
        _settings = ObservedObject(wrappedValue: settings)
        _txViewModel = StateObject(wrappedValue: ObservableTerminalTxViewModel(sourceCall: settings.myCallsign))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(TerminalTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Divider()
                .padding(.top, 8)

            // Content based on tab
            switch selectedTab {
            case .session:
                sessionView
            case .transfers:
                transfersView
            }
        }
        .onChange(of: settings.myCallsign) { _, newValue in
            txViewModel.updateSourceCall(newValue)
        }
        .sheet(isPresented: $showingTransferSheet) {
            SendFileSheet(
                isPresented: $showingTransferSheet,
                selectedFileURL: selectedFileURL,
                onSend: { destination, path in
                    startTransfer(destination: destination, path: path)
                }
            )
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
    }

    // MARK: - Session View

    @ViewBuilder
    private var sessionView: some View {
        VStack(spacing: 0) {
            // Connection status banner
            if client.status != .connected {
                connectionBanner
            }

            // Session output (reuse console view for now, filtered by session)
            sessionOutputView

            // TX Queue (collapsible)
            if !txViewModel.queueEntries.isEmpty {
                TxQueueView(
                    entries: txViewModel.queueEntries,
                    onCancel: { frameId in
                        txViewModel.cancelFrame(frameId)
                    },
                    onClearCompleted: {
                        txViewModel.clearCompleted()
                    }
                )
            }

            // Compose area
            TerminalComposeView(
                destinationCall: txViewModel.destinationCall,
                digiPath: txViewModel.digiPath,
                composeText: txViewModel.composeText,
                sourceCall: txViewModel.sourceCall,
                canSend: txViewModel.canSend,
                characterCount: txViewModel.characterCount,
                queueDepth: txViewModel.queueDepth,
                isConnected: client.status == .connected,
                onSend: {
                    txViewModel.enqueueCurrentMessage()
                },
                onClear: {
                    txViewModel.clearCompose()
                }
            )
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        HStack {
            Image(systemName: connectionIcon)
                .foregroundStyle(connectionColor)

            Text(connectionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if client.status == .disconnected || client.status == .failed {
                Button("Connect") {
                    client.connect(host: settings.host, port: settings.portValue)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(connectionColor.opacity(0.1))
    }

    private var connectionIcon: String {
        switch client.status {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch client.status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var connectionMessage: String {
        switch client.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Not connected. Connect to send messages."
        case .failed: return "Connection failed."
        }
    }

    @ViewBuilder
    private var sessionOutputView: some View {
        // Use ConsoleView with session filtering (for now, show all console lines)
        ConsoleView(
            lines: client.consoleLines,
            showDaySeparators: settings.showConsoleDaySeparators,
            onClear: {}
        )
        .overlay(alignment: .center) {
            if client.consoleLines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)

                    Text("No messages yet")
                        .foregroundStyle(.secondary)

                    Text("Connect to a TNC to start receiving packets")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Transfers View

    @ViewBuilder
    private var transfersView: some View {
        BulkTransferListView(
            transfers: transfers,
            onPause: { id in
                pauseTransfer(id)
            },
            onResume: { id in
                resumeTransfer(id)
            },
            onCancel: { id in
                cancelTransfer(id)
            },
            onClearCompleted: {
                clearCompletedTransfers()
            },
            onAddFile: {
                selectFileForTransfer()
            }
        )
    }

    // MARK: - Transfer Management

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            Task { @MainActor in
                selectedFileURL = url
                showingTransferSheet = true
            }
        }

        return true
    }

    private func selectFileForTransfer() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            selectedFileURL = url
            showingTransferSheet = true
        }
    }

    private func startTransfer(destination: String, path: String) {
        guard let url = selectedFileURL else { return }

        let transfer = BulkTransfer(
            id: UUID(),
            fileName: url.lastPathComponent,
            fileSize: fileSize(url) ?? 0,
            destination: destination
        )

        transfers.append(transfer)
        selectedFileURL = nil

        // TODO: Actually start transfer via TxScheduler
    }

    private func fileSize(_ url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    }

    private func pauseTransfer(_ id: UUID) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].status = .paused
        }
    }

    private func resumeTransfer(_ id: UUID) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].status = .sending
        }
    }

    private func cancelTransfer(_ id: UUID) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].status = .cancelled
        }
    }

    private func clearCompletedTransfers() {
        transfers.removeAll { transfer in
            switch transfer.status {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Preview

#Preview("Terminal View") {
    TerminalView(
        client: PacketEngine(settings: AppSettingsStore()),
        settings: AppSettingsStore()
    )
    .frame(width: 800, height: 600)
}
