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
}

struct ContentView: View {
    @StateObject private var client = KISSTcpClient()
    private let inspectionCoordinator = PacketInspectionCoordinator()

    @State private var selectedNav: NavigationItem = .packets
    @State private var searchText: String = ""
    @State private var filters = PacketFilters()

    @State private var host: String = "localhost"
    @State private var port: String = "8001"

    @State private var selection = Set<Packet.ID>()
    @State private var inspectorSelection: PacketInspectorSelection?
    @FocusState private var isSearchFocused: Bool

    @AppStorage("lastHost") private var savedHost: String = "localhost"
    @AppStorage("lastPort") private var savedPort: String = "8001"

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
                        inspectorSelection = nil
                    }
                )
            } else {
                Text("Packet unavailable")
                    .padding()
            }
        }
        .onAppear {
            host = savedHost
            port = savedPort
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
                ConsoleView(lines: client.consoleLines, onClear: { client.clearConsole() })
            case .raw:
                RawView(chunks: client.rawChunks, onClear: { client.clearRaw() })
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
            if newSelection.isEmpty {
                inspectorSelection = nil
            }
        }
        .onChange(of: searchText) { _, _ in syncSelection(with: rows) }
        .onChange(of: filters) { _, _ in syncSelection(with: rows) }
        .onChange(of: client.selectedStationCall) { _, _ in syncSelection(with: rows) }
        .onChange(of: client.packets) { _, _ in syncSelection(with: rows) }
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
                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)

                Button("Connect") {
                    savedHost = host
                    savedPort = port
                    if let portNum = UInt16(port) {
                        client.connect(host: host, port: portNum)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            Button("Disconnect") {
                client.disconnect()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        Toggle("UI", isOn: $filters.showUI)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)

        Toggle("I", isOn: $filters.showI)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)

        Toggle("S", isOn: $filters.showS)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)

        Toggle("U", isOn: $filters.showU)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)

        Divider()

        Toggle("Info Only", isOn: $filters.onlyWithInfo)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.packets.isEmpty)

        Toggle("Pinned", isOn: $filters.onlyPinned)
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .disabled(client.pinnedPacketIDs.isEmpty)

        if client.selectedStationCall != nil {
            Button {
                client.selectedStationCall = nil
            } label: {
                Label("Clear Filter", systemImage: "xmark.circle")
            }
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
            return "\(statusEmoji) Dire Wolf @ \(connectionHostPort)"
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
        let hostValue = client.connectedHost ?? savedHost
        let portValue = client.connectedPort.map(String.init) ?? savedPort
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
            savedHost = host
            savedPort = port
            if let portNum = UInt16(port) {
                client.connect(host: host, port: portNum)
            }
        }
    }

    private func inspectSelectedPacket() {
        guard let selection = inspectionCoordinator.inspectSelectedPacket(
            selection: selection,
            packets: filteredPackets
        ) else {
            return
        }
        inspectorSelection = selection
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

}

#Preview {
    ContentView()
}
