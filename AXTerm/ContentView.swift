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

    @State private var selectedNav: NavigationItem = .packets
    @State private var searchText: String = ""
    @State private var filters = PacketFilters()

    @State private var host: String = "localhost"
    @State private var port: String = "8001"

    @State private var selection = Set<Packet.ID>()

    @AppStorage("lastHost") private var savedHost: String = "localhost"
    @AppStorage("lastPort") private var savedPort: String = "8001"

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .searchable(text: $searchText, prompt: "Search packets...")
        .toolbar {
            toolbarContent
        }
        .sheet(item: $client.selectedPacket) { packet in
            PacketInspectorView(packet: packet) {
                client.selectedPacket = nil
            }
        }
        .onAppear {
            host = savedHost
            port = savedPort
        }
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
                        StationRow(
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
        let rows = client.filteredPackets(
            search: searchText,
            filters: filters,
            stationCall: client.selectedStationCall
        )

        return Table(rows, selection: $selection) {
            TableColumn("Time") { pkt in
                Text(pkt.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)

            TableColumn("From") { pkt in
                Text(pkt.fromDisplay)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 80, ideal: 100)

            TableColumn("To") { pkt in
                Text(pkt.toDisplay)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Via") { pkt in
                Text(pkt.viaDisplay.isEmpty ? "" : pkt.viaDisplay)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 120)

            TableColumn("Type") { pkt in
                Text(pkt.typeDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(typeColor(pkt.frameType).opacity(0.2))
                    .cornerRadius(4)
            }
            .width(min: 40, ideal: 50)

            TableColumn("Info") { pkt in
                Text(pkt.infoPreview)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let id = newValue.first else { return }
            if let pkt = client.packets.first(where: { $0.id == id }) {
                client.selectedPacket = pkt
                selection.removeAll()
            }
        }
    }

    private func typeColor(_ type: FrameType) -> Color {
        switch type {
        case .ui: return .blue
        case .i: return .green
        case .s: return .orange
        case .u: return .purple
        case .unknown: return .gray
        }
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

        Toggle("I", isOn: $filters.showI)
            .toggleStyle(.button)
            .buttonStyle(.bordered)

        Toggle("S", isOn: $filters.showS)
            .toggleStyle(.button)
            .buttonStyle(.bordered)

        Toggle("U", isOn: $filters.showU)
            .toggleStyle(.button)
            .buttonStyle(.bordered)

        Divider()

        Toggle("Info Only", isOn: $filters.onlyWithInfo)
            .toggleStyle(.button)
            .buttonStyle(.bordered)

        if client.selectedStationCall != nil {
            Button {
                client.selectedStationCall = nil
            } label: {
                Label("Clear Filter", systemImage: "xmark.circle")
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var statusColor: Color {
        switch client.status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch client.status {
        case .connected:
            return "Connected | \(formatBytes(client.bytesReceived)) | \(client.packets.count) pkts"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Failed"
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Station Row

struct StationRow: View {
    let station: Station
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.call)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(isSelected ? .semibold : .regular)

                Text(station.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}

// MARK: - Console View

struct ConsoleView: View {
    let lines: [ConsoleLine]
    let onClear: () -> Void

    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Spacer()

                Text("\(lines.count) lines")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Button("Clear") {
                    onClear()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            ConsoleLineView(line: line)
                                .id(line.id)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) { _, _ in
                    if autoScroll, let lastLine = lines.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(lastLine.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(.background)
        }
    }
}

struct ConsoleLineView: View {
    let line: ConsoleLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.timestampString)
                .foregroundStyle(.secondary)

            if let from = line.from {
                Text(from)
                    .foregroundStyle(kindColor)

                if let to = line.to {
                    Text(">")
                        .foregroundStyle(.secondary)
                    Text(to)
                        .foregroundStyle(.secondary)
                }

                Text(":")
                    .foregroundStyle(.secondary)
            }

            Text(line.text)
                .textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(kindColor)
    }

    private var kindColor: Color {
        switch line.kind {
        case .system: return .blue
        case .error: return .red
        case .packet: return .primary
        }
    }
}

// MARK: - Raw View

struct RawView: View {
    let chunks: [RawChunk]
    let onClear: () -> Void

    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Spacer()

                Text("\(chunks.count) chunks")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Button("Clear") {
                    onClear()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(chunks) { chunk in
                            RawChunkView(chunk: chunk)
                                .id(chunk.id)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chunks.count) { _, _ in
                    if autoScroll, let lastChunk = chunks.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(lastChunk.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(.background)
        }
    }
}

struct RawChunkView: View {
    let chunk: RawChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chunk.timestampString)
                    .foregroundStyle(.secondary)

                Text("[\(chunk.data.count) bytes]")
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    copyToPasteboard(chunk.hex)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Text(chunk.hex)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
        }
        .padding(8)
        .background(.background.secondary)
        .cornerRadius(6)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview {
    ContentView()
}
