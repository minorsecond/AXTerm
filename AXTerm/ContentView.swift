//
//  ContentView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

enum NavigationItem: String, Hashable, CaseIterable {
    case packets = "Packets"
    case console = "Console"
    case raw = "Raw"
    case analytics = "Analytics"
    case routes = "Routes"
}

struct ContentView: View {
    @StateObject private var client: PacketEngine
    @ObservedObject private var settings: AppSettingsStore
    @ObservedObject private var inspectionRouter: PacketInspectionRouter
    private let inspectionCoordinator = PacketInspectionCoordinator()

    @State private var selectedNav: NavigationItem = .packets
    @State private var searchText: String = ""
    @State private var filters = PacketFilters()

    @State private var selection = Set<Packet.ID>()
    @State private var inspectorSelection: PacketInspectorSelection?
    @FocusState private var isSearchFocused: Bool
    @State private var didLoadHistory = false
    @State private var didLoadConsoleHistory = false
    @State private var didLoadRawHistory = false
    @State private var selectionMutationScheduler = SelectionMutationScheduler()
    @StateObject private var analyticsViewModel: AnalyticsDashboardViewModel

    init(client: PacketEngine, settings: AppSettingsStore, inspectionRouter: PacketInspectionRouter) {
        _client = StateObject(wrappedValue: client)
        _settings = ObservedObject(wrappedValue: settings)
        _inspectionRouter = ObservedObject(wrappedValue: inspectionRouter)
        // Initialize analytics view model with settings store for persistence
        _analyticsViewModel = StateObject(wrappedValue: AnalyticsDashboardViewModel(settingsStore: settings))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .searchable(text: $searchText, prompt: "Search packets...")
        .searchFocused($isSearchFocused)
        .toolbar {
            toolbarContent
        }
        .sheet(item: $inspectorSelection) { selection in
            if let packet = client.packet(with: selection.id) {
                PacketInspectorView(
                    packet: packet,
                    isPinned: client.isPinned(packet.id),
                    onTogglePin: { client.togglePin(for: packet.id) },
                    onFilterStation: { call in
                        client.selectedStationCall = call
                    },
                    onClose: {
                        SentryManager.shared.addBreadcrumb(category: "ui.inspector", message: "Inspector closed", level: .info, data: ["packetID": selection.id.uuidString])
                        inspectorSelection = nil
                    }
                )
            } else {
                Text("Packet unavailable")
                    .padding()
            }
        }
        .task {
            guard !didLoadHistory else { return }
            didLoadHistory = true
            SentryManager.shared.addBreadcrumb(category: "app.lifecycle", message: "Main UI ready", level: .info, data: nil)
            // Keep startup responsive: load the main (Packets) view history first.
            client.loadPersistedPackets()
        }
        .task(id: selectedNav) {
            switch selectedNav {
            case .packets:
                return
            case .console:
                guard !didLoadConsoleHistory else { return }
                didLoadConsoleHistory = true
                await Task.yield()
                client.loadPersistedConsole()
            case .raw:
                guard !didLoadRawHistory else { return }
                didLoadRawHistory = true
                await Task.yield()
                client.loadPersistedRaw()
            case .analytics:
                return
            case .routes:
                // Routes view handles its own data loading
                return
            }
        }
        .task(id: inspectionRouter.requestedPacketID) {
            guard let packetID = inspectionRouter.requestedPacketID else { return }
            await openInspectorFromRouterRequest(packetID: packetID)
        }
        .focusedValue(\.searchFocus, SearchFocusAction { isSearchFocused = true })
        .focusedValue(\.toggleConnection, ToggleConnectionAction { toggleConnection() })
        .focusedValue(\.inspectPacket, InspectPacketAction { inspectSelectedPacket() })
        .focusedValue(\.selectNavigation, SelectNavigationAction { item in
            selectedNav = item
        })
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedNav) {
            Section("Views") {
                ForEach(NavigationItem.allCases, id: \.self) { item in
                    Label(item.rawValue, systemImage: iconFor(item))
                        .tag(item)
                }
            }

            Section("Stations (\(client.stations.count))") {
                // "All" option
                HStack {
                    Text("All Packets")
                    Spacer()
                    if client.selectedStationCall == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    client.selectedStationCall = nil
                }

                if client.stations.isEmpty {
                    Text("No stations heard")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(client.stations) { station in
                        StationRowView(
                            station: station,
                            isSelected: client.selectedStationCall == station.call
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if client.selectedStationCall == station.call {
                                client.selectedStationCall = nil
                            } else {
                                client.selectedStationCall = station.call
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    private func iconFor(_ item: NavigationItem) -> String {
        switch item {
        case .packets: return "list.bullet.rectangle"
        case .console: return "terminal"
        case .raw: return "doc.text"
        case .analytics: return "chart.bar"
        case .routes: return "arrow.triangle.branch"
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if let err = client.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(err)
                    Spacer()
                }
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.1))
            }

            switch selectedNav {
            case .packets:
                packetsView
            case .console:
                ConsoleView(
                    lines: client.consoleLines,
                    showDaySeparators: settings.showConsoleDaySeparators,
                    onClear: { client.clearConsole() }
                )
            case .raw:
                RawView(
                    chunks: client.rawChunks,
                    showDaySeparators: settings.showRawDaySeparators,
                    onClear: { client.clearRaw() }
                )
            case .analytics:
                AnalyticsDashboardView(packetEngine: client, settings: settings, viewModel: analyticsViewModel)
            case .routes:
                NetRomRoutesView(integration: client.netRomIntegration)
            }
        }
    }

    private var packetsView: some View {
        let rows = filteredPackets

        return PacketTableView(
            packets: rows,
            selection: $selection,
            onInspectSelection: {
                inspectSelectedPacket()
            },
            onCopyInfo: { packet in
                ClipboardWriter.copy(packet.infoText ?? "")
            },
            onCopyRawHex: { packet in
                ClipboardWriter.copy(PayloadFormatter.hexString(packet.rawAx25))
            }
        )
        .onChange(of: selection) { _, newSelection in
            guard newSelection.isEmpty else { return }
            deferSelectionMutation {
                SentryManager.shared.addBreadcrumb(category: "ui.selection", message: "Selection cleared", level: .info, data: nil)
                inspectorSelection = nil
            }
        }
        .onChange(of: searchText) { _, _ in scheduleSelectionSync(with: rows) }
        .onChange(of: filters) { _, _ in scheduleSelectionSync(with: rows) }
        .onChange(of: client.selectedStationCall) { _, _ in scheduleSelectionSync(with: rows) }
        .onChange(of: client.packets) { _, _ in scheduleSelectionSync(with: rows) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            connectionControls
        }

        ToolbarItemGroup(placement: .automatic) {
            filterControls
        }

        ToolbarItem(placement: .status) {
            statusPill
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        if client.status == .disconnected || client.status == .failed {
            HStack(spacing: 4) {
                TextField("Host", text: $settings.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .help("Hostname or IP of the KISS TNC")

                TextField("Port", text: $settings.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .help("TCP port for the KISS TNC")

                Button("Connect") {
                    client.connect(host: settings.host, port: settings.portValue)
                }
                .buttonStyle(.borderedProminent)
                .help("Connect to the TNC")
            }
        } else {
            Button("Disconnect") {
                client.disconnect()
            }
            .buttonStyle(.bordered)
            .help("Disconnect from the TNC")
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        Toggle("UI", isOn: $filters.showUI)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)
            .help("Show UI frames")

        Toggle("I", isOn: $filters.showI)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)
            .help("Show I frames")

        Toggle("S", isOn: $filters.showS)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)
            .help("Show S frames")

        Toggle("U", isOn: $filters.showU)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)
            .help("Show U control frames")

        Divider()

        Toggle("Payload Only", isOn: $filters.payloadOnly)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)
            .help("Show I frames and UI frames with payload")

        Toggle("Pinned", isOn: $filters.onlyPinned)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.pinnedPacketIDs.isEmpty)
            .help("Show pinned packets only")

        if client.selectedStationCall != nil {
            Button {
                client.selectedStationCall = nil
            } label: {
                Label("Clear Filter", systemImage: "xmark.circle")
            }
            .help("Clear station filter")
        }
    }

    private var statusPill: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: client.status)
    }

    private var statusTitle: String {
        switch client.status {
        case .connected:
            return "\(statusEmoji) Connected @ \(connectionHostPort)"
        case .connecting:
            return "\(statusEmoji) Connecting..."
        case .disconnected:
            return "\(statusEmoji) Disconnected"
        case .failed:
            return "\(statusEmoji) Connection Failed"
        }
    }

    private var statusDetail: String {
        "\(formatBytes(client.bytesReceived)) • \(client.packets.count) packets"
    }

    private var statusEmoji: String {
        switch client.status {
        case .connected: return "🟢"
        case .connecting: return "🟠"
        case .disconnected: return "⚪️"
        case .failed: return "🔴"
        }
    }

    private var connectionHostPort: String {
        let hostValue = client.connectedHost ?? settings.host
        let portValue = client.connectedPort.map(String.init) ?? settings.port
        return "\(hostValue):\(portValue)"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func toggleConnection() {
        switch client.status {
        case .connected, .connecting:
            client.disconnect()
        case .disconnected, .failed:
            client.connect(host: settings.host, port: settings.portValue)
        }
    }

    private func inspectSelectedPacket() {
        guard let selection = inspectionCoordinator.inspectSelectedPacket(
            selection: selection,
            packets: filteredPackets
        ) else {
            return
        }
        deferSelectionMutation {
            SentryManager.shared.addBreadcrumb(category: "ui.inspector", message: "Inspector opened", level: .info, data: ["packetID": selection.id.uuidString])
            inspectorSelection = selection
        }
    }

    private var filteredPackets: [Packet] {
        client.filteredPackets(
            search: searchText,
            filters: filters,
            stationCall: client.selectedStationCall
        )
    }

    private func syncSelection(with packets: [Packet]) {
        let nextSelection = PacketSelectionResolver.filteredSelection(selection, for: packets)
        if nextSelection != selection {
            selection = nextSelection
        }

        if selection.isEmpty {
            inspectorSelection = nil
        }
    }

    @MainActor
    private func openInspectorFromRouterRequest(packetID: Packet.ID) async {
        // Ensure this happens outside of SwiftUI's view-update transaction.
        await Task.yield()

        SentryManager.shared.addBreadcrumb(
            category: "ui.routing",
            message: "Apply inspector route",
            level: .info,
            data: ["packetID": packetID.uuidString]
        )

        if inspectorSelection?.id != packetID {
            inspectorSelection = PacketInspectorSelection(id: packetID)
        }
        if selection != [packetID] {
            selection = [packetID]
        }
        inspectionRouter.consumePacketRequest()
    }

    private func scheduleSelectionSync(with packets: [Packet]) {
        selectionMutationScheduler.schedule {
            syncSelection(with: packets)
        }
    }

    private func deferSelectionMutation(_ mutation: @MainActor @escaping () -> Void) {
        selectionMutationScheduler.schedule {
            mutation()
        }
    }
}

#Preview {
    ContentView(
        client: PacketEngine(settings: AppSettingsStore()),
        settings: AppSettingsStore(),
        inspectionRouter: PacketInspectionRouter()
    )
}
