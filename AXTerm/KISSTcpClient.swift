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

    // MARK: - Published State

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var bytesReceived: Int = 0

    @Published private(set) var packets: [Packet] = []
    @Published private(set) var consoleLines: [ConsoleLine] = []
    @Published private(set) var rawChunks: [RawChunk] = []
    @Published private(set) var stations: [Station] = []

    @Published var selectedStationCall: String?
    @Published var selectedPacket: Packet?

    // MARK: - Private State

    private var connection: NWConnection?
    private var parser = KISSFrameParser()
    private var stationIndex: [String: Int] = [:] // call -> index in stations array

    // MARK: - Initialization

    init(maxPackets: Int = 5000, maxConsoleLines: Int = 5000, maxRawChunks: Int = 1000) {
        self.maxPackets = maxPackets
        self.maxConsoleLines = maxConsoleLines
        self.maxRawChunks = maxRawChunks
    }

    // MARK: - Connection Management

    func connect(host: String = "localhost", port: UInt16 = 8001) {
        disconnect()

        status = .connecting
        lastError = nil

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!

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
            pid: decoded.pid,
            info: decoded.info,
            rawAx25: ax25Data
        )

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
    }

    // MARK: - MHeard (Station Tracking)

    private func updateMHeard(for packet: Packet) {
        guard let from = packet.from else { return }
        let call = from.display

        if let index = stationIndex[call] {
            // Update existing station
            stations[index].lastHeard = packet.timestamp
            stations[index].heardCount += 1
            if !packet.via.isEmpty {
                stations[index].lastVia = packet.via.map { $0.display }
            }
        } else {
            // New station
            let station = Station(
                call: call,
                lastHeard: packet.timestamp,
                heardCount: 1,
                lastVia: packet.via.map { $0.display }
            )
            stations.append(station)
            stationIndex[call] = stations.count - 1
        }

        // Re-sort by lastHeard descending
        sortStations()
    }

    private func sortStations() {
        stations.sort { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
        // Rebuild index
        stationIndex.removeAll()
        for (index, station) in stations.enumerated() {
            stationIndex[station.call] = index
        }
    }

    // MARK: - Capped Array Helpers

    private func appendPacket(_ packet: Packet) {
        packets.append(packet)
        if packets.count > maxPackets {
            packets.removeFirst(packets.count - maxPackets)
        }
    }

    private func appendConsoleLine(_ line: ConsoleLine) {
        consoleLines.append(line)
        if consoleLines.count > maxConsoleLines {
            consoleLines.removeFirst(consoleLines.count - maxConsoleLines)
        }
    }

    private func appendRawChunk(_ chunk: RawChunk) {
        rawChunks.append(chunk)
        if rawChunks.count > maxRawChunks {
            rawChunks.removeFirst(rawChunks.count - maxRawChunks)
        }
    }

    private func addSystemLine(_ text: String) {
        appendConsoleLine(ConsoleLine.system(text))
    }

    private func addErrorLine(_ text: String) {
        appendConsoleLine(ConsoleLine.error(text))
    }

    // MARK: - Filtering

    func filteredPackets(search: String, filters: PacketFilters, stationCall: String?) -> [Packet] {
        packets.filter { packet in
            // Station filter
            if let call = stationCall {
                guard packet.fromDisplay == call else { return false }
            }

            // Frame type filter
            guard filters.allows(frameType: packet.frameType) else { return false }

            // Only with info filter
            if filters.onlyWithInfo && packet.infoText == nil {
                return false
            }

            // Search filter
            if !search.isEmpty {
                let searchLower = search.lowercased()
                let matches = packet.fromDisplay.lowercased().contains(searchLower) ||
                              packet.toDisplay.lowercased().contains(searchLower) ||
                              packet.viaDisplay.lowercased().contains(searchLower) ||
                              (packet.infoText?.lowercased().contains(searchLower) ?? false)
                guard matches else { return false }
            }

            return true
        }
    }

    // MARK: - Clear Actions

    func clearPackets() {
        packets.removeAll()
    }

    func clearConsole() {
        consoleLines.removeAll()
    }

    func clearRaw() {
        rawChunks.removeAll()
    }

    func clearStations() {
        stations.removeAll()
        stationIndex.removeAll()
        selectedStationCall = nil
    }
}
