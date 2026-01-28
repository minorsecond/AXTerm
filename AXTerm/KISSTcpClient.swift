//
//  KISSTcpClient.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation
import Network
import Combine

/// Connection status for the KISS TCP client
enum ConnectionStatus: String {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case connected = "Connected"
    case failed = "Failed"
}

/// Filter settings for packet display
struct PacketFilters: Equatable {
    var showUI: Bool = true
    var showI: Bool = true
    var showS: Bool = true
    var showU: Bool = true
    var onlyWithInfo: Bool = false
    var onlyPinned: Bool = false

    func allows(frameType: FrameType) -> Bool {
        switch frameType {
        case .ui: return showUI
        case .i: return showI
        case .s: return showS
        case .u: return showU
        case .unknown: return true
        }
    }
}

/// Raw data chunk for the Raw view
struct RawChunk: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let data: Data

    init(id: UUID = UUID(), timestamp: Date = Date(), data: Data) {
        self.id = id
        self.timestamp = timestamp
        self.data = data
    }

    var hex: String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var timestampString: String {
        Self.timeFormatter.string(from: timestamp)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// KISS TCP client that connects to a TNC (e.g., Direwolf)
@MainActor
final class KISSTcpClient: ObservableObject {
    // MARK: - Configuration

    private let maxPackets: Int
    private let maxConsoleLines: Int
    private let maxRawChunks: Int
    private let settings: AppSettingsStore
    private let packetStore: PacketStore?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Published State

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var bytesReceived: Int = 0
    @Published private(set) var connectedHost: String?
    @Published private(set) var connectedPort: UInt16?

    @Published private(set) var packets: [Packet] = []
    @Published private(set) var consoleLines: [ConsoleLine] = []
    @Published private(set) var rawChunks: [RawChunk] = []
    @Published private(set) var stations: [Station] = []

    @Published var selectedStationCall: String?
    @Published private(set) var pinnedPacketIDs: Set<Packet.ID> = []

    // MARK: - Private State

    private var connection: NWConnection?
    private var parser = KISSFrameParser()
    private var stationTracker = StationTracker()

    // MARK: - Initialization

    init(
        maxPackets: Int = 5000,
        maxConsoleLines: Int = 5000,
        maxRawChunks: Int = 1000,
        settings: AppSettingsStore,
        packetStore: PacketStore? = nil
    ) {
        self.maxPackets = maxPackets
        self.maxConsoleLines = maxConsoleLines
        self.maxRawChunks = maxRawChunks
        self.settings = settings
        self.packetStore = packetStore
        observeSettings()
    }

    // MARK: - Connection Management

    func connect(host: String = "localhost", port: UInt16 = 8001) {
        disconnect()

        status = .connecting
        lastError = nil
        connectedHost = host
        connectedPort = port

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .failed
            lastError = "Invalid port \(port)"
            addErrorLine("Connection failed: invalid port \(port)")
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        connection = NWConnection(host: nwHost, port: nwPort, using: params)

        let hostCopy = host
        let portCopy = port
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state, host: hostCopy, port: portCopy)
            }
        }

        connection?.start(queue: .main)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        parser.reset()
        status = .disconnected
        connectedHost = nil
        connectedPort = nil
    }

    private func handleConnectionState(_ state: NWConnection.State, host: String, port: UInt16) {
        switch state {
        case .ready:
            status = .connected
            addSystemLine("Connected to \(host):\(port)")
            startReceiving()

        case .failed(let error):
            status = .failed
            lastError = error.localizedDescription
            addErrorLine("Connection failed: \(error.localizedDescription)")

        case .cancelled:
            status = .disconnected
            addSystemLine("Disconnected")

        case .waiting(let error):
            lastError = error.localizedDescription

        default:
            break
        }
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if let data = content, !data.isEmpty {
                    self.handleReceivedData(data)
                }

                if let error = error {
                    self.lastError = error.localizedDescription
                    self.addErrorLine("Receive error: \(error.localizedDescription)")
                    return
                }

                if isComplete {
                    self.disconnect()
                    return
                }

                // Continue receiving
                self.startReceiving()
            }
        }
    }

    private func handleReceivedData(_ data: Data) {
        bytesReceived += data.count

        // Always log raw chunk
        appendRawChunk(RawChunk(data: data))

        // Parse KISS frames from the chunk
        let ax25Frames = parser.feed(data)

        for ax25Data in ax25Frames {
            processAX25Frame(ax25Data)
        }
    }

    private func processAX25Frame(_ ax25Data: Data) {
        guard let decoded = AX25.decodeFrame(ax25: ax25Data) else {
            return
        }

        let packet = Packet(
            timestamp: Date(),
            from: decoded.from,
            to: decoded.to,
            via: decoded.via,
            frameType: decoded.frameType,
            control: decoded.control,
            pid: decoded.pid,
            info: decoded.info,
            rawAx25: ax25Data
        )

        handleIncomingPacket(packet)
    }

    // MARK: - MHeard (Station Tracking)

    private func updateMHeard(for packet: Packet) {
        stationTracker.update(with: packet)
        stations = stationTracker.stations
    }

    // MARK: - Capped Array Helpers

    private func appendPacket(_ packet: Packet) {
        CappedArray.append(packet, to: &packets, max: maxPackets)
    }

    private func appendConsoleLine(_ line: ConsoleLine) {
        CappedArray.append(line, to: &consoleLines, max: maxConsoleLines)
    }

    private func appendRawChunk(_ chunk: RawChunk) {
        CappedArray.append(chunk, to: &rawChunks, max: maxRawChunks)
    }

    private func addSystemLine(_ text: String) {
        appendConsoleLine(ConsoleLine.system(text))
    }

    private func addErrorLine(_ text: String) {
        appendConsoleLine(ConsoleLine.error(text))
    }

    // MARK: - Filtering

    func filteredPackets(search: String, filters: PacketFilters, stationCall: String?) -> [Packet] {
        PacketFilter.filter(
            packets: packets,
            search: search,
            filters: filters,
            stationCall: stationCall,
            pinnedIDs: pinnedPacketIDs
        )
    }

    func packet(with id: Packet.ID) -> Packet? {
        packets.first { $0.id == id }
    }

    func isPinned(_ id: Packet.ID) -> Bool {
        pinnedPacketIDs.contains(id)
    }

    func togglePin(for id: Packet.ID) {
        let shouldPin = !pinnedPacketIDs.contains(id)
        if pinnedPacketIDs.contains(id) {
            pinnedPacketIDs.remove(id)
        } else {
            pinnedPacketIDs.insert(id)
        }
        persistPinned(id: id, pinned: shouldPin)
    }

    // MARK: - Clear Actions

    func clearPackets() {
        packets.removeAll()
        pinnedPacketIDs.removeAll()
    }

    func clearConsole() {
        consoleLines.removeAll()
    }

    func clearRaw() {
        rawChunks.removeAll()
    }

    func clearStations() {
        stations.removeAll()
        stationTracker.reset()
        selectedStationCall = nil
    }

    // MARK: - Persistence Integration

    func handleIncomingPacket(_ packet: Packet) {
        appendPacket(packet)
        updateMHeard(for: packet)

        if let text = packet.infoText {
            let line = ConsoleLine.packet(
                from: packet.fromDisplay,
                to: packet.toDisplay,
                text: text,
                timestamp: packet.timestamp
            )
            appendConsoleLine(line)
        }

        persistPacket(packet)
    }

    func loadPersistedPackets() {
        guard settings.persistHistory, let packetStore else { return }
        let limit = min(settings.retentionLimit, maxPackets)
        DispatchQueue.global(qos: .utility).async { [weak self, packetStore] in
            do {
                let records = try packetStore.loadRecent(limit: limit)
                let packets = records.map { $0.toPacket() }
                let pinnedIDs = Set(records.filter { $0.pinned }.map(\.id))
                Task { @MainActor in
                    self?.applyLoadedPackets(packets, pinnedIDs: pinnedIDs)
                }
            } catch {
                return
            }
        }
    }

    private func applyLoadedPackets(_ loaded: [Packet], pinnedIDs: Set<Packet.ID>) {
        packets = loaded
        pinnedPacketIDs = pinnedIDs
        rebuildStations(from: loaded)
    }

    private func rebuildStations(from packets: [Packet]) {
        stationTracker.reset()
        for packet in packets {
            stationTracker.update(with: packet)
        }
        stations = stationTracker.stations
    }

    private func persistPacket(_ packet: Packet) {
        guard settings.persistHistory, let packetStore else { return }
        let retentionLimit = settings.retentionLimit
        DispatchQueue.global(qos: .utility).async {
            do {
                try packetStore.save(packet)
                try packetStore.pruneIfNeeded(retentionLimit: retentionLimit)
            } catch {
                return
            }
        }
    }

    private func persistPinned(id: Packet.ID, pinned: Bool) {
        guard settings.persistHistory, let packetStore else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try packetStore.setPinned(packetId: id, pinned: pinned)
            } catch {
                return
            }
        }
    }

    private func observeSettings() {
        settings.$retentionLimit
            .dropFirst()
            .sink { [weak self] newLimit in
                self?.prunePersistedHistory(limit: newLimit)
            }
            .store(in: &cancellables)

        settings.$persistHistory
            .dropFirst()
            .sink { [weak self] enabled in
                guard enabled else { return }
                self?.loadPersistedPackets()
            }
            .store(in: &cancellables)
    }

    private func prunePersistedHistory(limit: Int) {
        guard settings.persistHistory, let packetStore else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try packetStore.pruneIfNeeded(retentionLimit: limit)
            } catch {
                return
            }
        }
    }
}
