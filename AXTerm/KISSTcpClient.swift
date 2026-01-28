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
    @Published private(set) var connectedHost: String?
    @Published private(set) var connectedPort: UInt16?

    @Published private(set) var packets: [Packet] = []
    @Published private(set) var consoleLines: [ConsoleLine] = []
    @Published private(set) var rawChunks: [RawChunk] = []
    @Published private(set) var stations: [Station] = []

    @Published var selectedStationCall: String?
    @Published var selectedPacket: Packet?

    // MARK: - Private State

    private var connection: NWConnection?
    private var parser = KISSFrameParser()
    private var stationTracker = StationTracker()

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
        connectedHost = host
        connectedPort = port

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
        PacketFilter.filter(packets: packets, search: search, filters: filters, stationCall: stationCall)
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
        stationTracker.reset()
        selectedStationCall = nil
    }
}
