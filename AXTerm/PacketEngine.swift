//
//  PacketEngine.swift
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
    var payloadOnly: Bool = false
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
struct RawChunk: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let data: Data

    init(id: UUID = UUID(), timestamp: Date = Date(), data: Data) {
        self.id = id
        self.timestamp = timestamp
        self.data = data
    }

    var hex: String {
        RawEntryEncoding.encodeHex(data)
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
final class PacketEngine: ObservableObject {
    // MARK: - Configuration

    private let maxPackets: Int
    private let maxConsoleLines: Int
    private let maxRawChunks: Int
    private let settings: AppSettingsStore
    private let packetStore: PacketStore?
    private let consoleStore: ConsoleStore?
    private let rawStore: RawStore?
    private let persistenceWorker: PersistenceWorker?
    private let eventLogger: EventLogger?
    private let watchMatcher: WatchMatching
    private let watchRecorder: WatchEventRecording?
    private let notificationScheduler: NotificationScheduling?
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
        maxConsoleLines: Int = 10_000,
        maxRawChunks: Int = 10_000,
        settings: AppSettingsStore,
        packetStore: PacketStore? = nil,
        consoleStore: ConsoleStore? = nil,
        rawStore: RawStore? = nil,
        eventLogger: EventLogger? = nil,
        watchMatcher: WatchMatching? = nil,
        watchRecorder: WatchEventRecording? = nil,
        notificationScheduler: NotificationScheduling? = nil
    ) {
        self.maxPackets = maxPackets
        self.maxConsoleLines = maxConsoleLines
        self.maxRawChunks = maxRawChunks
        self.settings = settings
        self.packetStore = packetStore
        self.consoleStore = consoleStore
        self.rawStore = rawStore
        self.persistenceWorker = PersistenceWorker(packetStore: packetStore, consoleStore: consoleStore, rawStore: rawStore)
        self.eventLogger = eventLogger
        self.watchMatcher = watchMatcher ?? WatchRuleMatcher(settings: settings)
        self.watchRecorder = watchRecorder
        self.notificationScheduler = notificationScheduler
        observeSettings()
    }

    // MARK: - Connection Management

    func connect(host: String = "localhost", port: UInt16 = 8001) {
        disconnect()

        status = .connecting
        lastError = nil
        connectedHost = host
        connectedPort = port
        SentryManager.shared.breadcrumbConnectAttempt(host: host, port: port)
        SentryManager.shared.setConnectionTags(host: host, port: port)
        eventLogger?.log(level: .info, category: .connection, message: "Connecting to \(host):\(port)", metadata: nil)

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .failed
            lastError = "Invalid port \(port)"
            addErrorLine("Connection failed: invalid port \(port)", category: .connection)
            eventLogger?.log(level: .error, category: .connection, message: "Connection failed: invalid port \(port)", metadata: nil)
            SentryManager.shared.captureConnectionFailure("Connection failed: invalid port \(port)")
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
        SentryManager.shared.breadcrumbDisconnect()
    }

    private func handleConnectionState(_ state: NWConnection.State, host: String, port: UInt16) {
        switch state {
        case .ready:
            status = .connected
            addSystemLine("Connected to \(host):\(port)", category: .connection)
            eventLogger?.log(level: .info, category: .connection, message: "Connected to \(host):\(port)", metadata: nil)
            SentryManager.shared.addBreadcrumb(category: "kiss.connection", message: "Connected", level: .info, data: nil)
            startReceiving()

        case .failed(let error):
            status = .failed
            lastError = error.localizedDescription
            addErrorLine("Connection failed: \(error.localizedDescription)", category: .connection)
            eventLogger?.log(level: .error, category: .connection, message: "Connection failed: \(error.localizedDescription)", metadata: nil)
            SentryManager.shared.captureConnectionFailure("Connection failed: \(error.localizedDescription)", error: error)

        case .cancelled:
            status = .disconnected
            addSystemLine("Disconnected", category: .connection)
            eventLogger?.log(level: .info, category: .connection, message: "Disconnected", metadata: nil)
            SentryManager.shared.addBreadcrumb(category: "kiss.connection", message: "Cancelled", level: .info, data: nil)

        case .waiting(let error):
            lastError = error.localizedDescription
            eventLogger?.log(level: .warning, category: .connection, message: "Waiting: \(error.localizedDescription)", metadata: nil)
            SentryManager.shared.captureConnectionFailure("Connection waiting: \(error.localizedDescription)", error: error)

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
                    self.handleIncomingData(data)
                }

                if let error = error {
                    self.lastError = error.localizedDescription
                    self.addErrorLine("Receive error: \(error.localizedDescription)", category: .connection)
                    self.eventLogger?.log(level: .error, category: .connection, message: "Receive error: \(error.localizedDescription)", metadata: nil)
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

    func handleIncomingData(_ data: Data) {
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
            eventLogger?.log(
                level: .warning,
                category: .parser,
                message: "Failed to decode AX.25 frame",
                metadata: ["byteCount": "\(ax25Data.count)"]
            )
            SentryManager.shared.captureDecodeFailure(byteCount: ax25Data.count)
            return
        }

        let host = connectedHost ?? settings.host
        let port = connectedPort ?? settings.portValue
        let endpoint = KISSEndpoint(host: host, port: port)

        let packet = Packet(
            timestamp: Date(),
            from: decoded.from,
            to: decoded.to,
            via: decoded.via,
            frameType: decoded.frameType,
            control: decoded.control,
            pid: decoded.pid,
            info: decoded.info,
            rawAx25: ax25Data,
            kissEndpoint: endpoint
        )

        SentryManager.shared.breadcrumbDecodeSuccessSampled(packet: packet)
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

    private func appendConsoleLine(
        _ line: ConsoleLine,
        category: ConsoleEntryRecord.Category,
        packetID: UUID? = nil,
        byteCount: Int? = nil
    ) {
        CappedArray.append(line, to: &consoleLines, max: maxConsoleLines)
        persistConsoleLine(line, category: category, packetID: packetID, byteCount: byteCount)
    }

    private func appendRawChunk(_ chunk: RawChunk) {
        CappedArray.append(chunk, to: &rawChunks, max: maxRawChunks)
        persistRawChunk(chunk)
    }

    private func addSystemLine(_ text: String, category: ConsoleEntryRecord.Category) {
        appendConsoleLine(ConsoleLine.system(text), category: category)
    }

    private func addErrorLine(_ text: String, category: ConsoleEntryRecord.Category) {
        appendConsoleLine(ConsoleLine.error(text), category: category)
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
        let action = shouldPin ? "Pinned packet" : "Unpinned packet"
        eventLogger?.log(
            level: .info,
            category: .ui,
            message: action,
            metadata: ["packetID": id.uuidString]
        )
        persistPinned(id: id, pinned: shouldPin)
    }

    // MARK: - Clear Actions

    func clearPackets() {
        packets.removeAll()
        pinnedPacketIDs.removeAll()
    }

    func clearConsole(clearPersisted: Bool = true) {
        consoleLines.removeAll()
        if clearPersisted {
            clearPersistedConsole()
        }
    }

    func clearRaw(clearPersisted: Bool = true) {
        rawChunks.removeAll()
        if clearPersisted {
            clearPersistedRaw()
        }
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
            appendConsoleLine(line, category: .packet, packetID: packet.id, byteCount: packet.info.count)
        }

        persistPacket(packet)
        handleWatchMatch(for: packet)
    }

    private func handleWatchMatch(for packet: Packet) {
        let match = watchMatcher.match(packet: packet)
        guard match.hasMatches else { return }
        let matchCount = match.matchedCallsigns.count + match.matchedKeywords.count
        SentryManager.shared.breadcrumbWatchHit(packet: packet, matchCount: matchCount)
        watchRecorder?.recordWatchHit(packet: packet, match: match)
        notificationScheduler?.scheduleWatchNotification(packet: packet, match: match)
    }

    func loadPersistedHistory() {
        loadPersistedPackets()
        loadPersistedConsole()
        loadPersistedRaw()
    }

    func loadPersistedPackets() {
        guard settings.persistHistory, let persistenceWorker else { return }
        let limit = min(settings.retentionLimit, maxPackets)
        Task {
            do {
                let result = try await persistenceWorker.loadPackets(limit: limit)
                applyLoadedPackets(result.packets, pinnedIDs: result.pinnedIDs)
            } catch {
                SentryManager.shared.capturePersistenceFailure("loadRecent packets", errorDescription: error.localizedDescription)
            }
        }
    }

    private func applyLoadedPackets(_ loaded: [Packet], pinnedIDs: Set<Packet.ID>) {
        packets = loaded
        pinnedPacketIDs = pinnedIDs
        rebuildStations(from: loaded)
    }

    func loadPersistedConsole() {
        guard settings.persistHistory, let persistenceWorker else { return }
        let limit = min(settings.consoleRetentionLimit, maxConsoleLines)
        Task {
            do {
                consoleLines = try await persistenceWorker.loadConsole(limit: limit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("loadRecent console", errorDescription: error.localizedDescription)
            }
        }
    }

    func loadPersistedRaw() {
        guard settings.persistHistory, let persistenceWorker else { return }
        let limit = min(settings.rawRetentionLimit, maxRawChunks)
        Task {
            do {
                rawChunks = try await persistenceWorker.loadRaw(limit: limit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("loadRecent raw", errorDescription: error.localizedDescription)
            }
        }
    }

    private func rebuildStations(from packets: [Packet]) {
        stationTracker.reset()
        for packet in packets {
            stationTracker.update(with: packet)
        }
        stations = stationTracker.stations
    }

    private func persistPacket(_ packet: Packet) {
        guard settings.persistHistory, let persistenceWorker else { return }
        let retentionLimit = settings.retentionLimit
        Task {
            do {
                try await persistenceWorker.savePacket(packet, retentionLimit: retentionLimit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("save/prune packet", errorDescription: error.localizedDescription)
            }
        }
    }

    private func persistConsoleLine(
        _ line: ConsoleLine,
        category: ConsoleEntryRecord.Category,
        packetID: UUID? = nil,
        byteCount: Int? = nil
    ) {
        guard settings.persistHistory, let persistenceWorker else { return }
        let metadata = ConsoleEntryMetadata(from: line.from, to: line.to)
        let metadataJSON = metadata.hasValues ? DeterministicJSON.encode(metadata) : nil
        let entry = ConsoleEntryRecord(
            id: line.id,
            createdAt: line.timestamp,
            level: ConsoleEntryRecord.Level(from: line.kind),
            category: category,
            message: line.text,
            packetID: packetID,
            metadataJSON: metadataJSON,
            byteCount: byteCount
        )
        let retentionLimit = settings.consoleRetentionLimit
        Task {
            do {
                try await persistenceWorker.appendConsole(entry, retentionLimit: retentionLimit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("append/prune console", errorDescription: error.localizedDescription)
            }
        }
    }

    private func persistRawChunk(_ chunk: RawChunk) {
        guard settings.persistHistory, let persistenceWorker else { return }
        let entry = RawEntryRecord(
            id: chunk.id,
            createdAt: chunk.timestamp,
            source: "kiss",
            direction: "rx",
            kind: .bytes,
            rawHex: RawEntryEncoding.encodeHex(chunk.data),
            byteCount: chunk.data.count,
            packetID: nil,
            metadataJSON: nil
        )
        let retentionLimit = settings.rawRetentionLimit
        Task {
            do {
                try await persistenceWorker.appendRaw(entry, retentionLimit: retentionLimit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("append/prune raw", errorDescription: error.localizedDescription)
            }
        }
    }

    private func persistPinned(id: Packet.ID, pinned: Bool) {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.setPinned(packetId: id, pinned: pinned)
            } catch {
                SentryManager.shared.capturePersistenceFailure("setPinned", errorDescription: error.localizedDescription)
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

        settings.$consoleRetentionLimit
            .dropFirst()
            .sink { [weak self] newLimit in
                self?.prunePersistedConsole(limit: newLimit)
            }
            .store(in: &cancellables)

        settings.$rawRetentionLimit
            .dropFirst()
            .sink { [weak self] newLimit in
                self?.prunePersistedRaw(limit: newLimit)
            }
            .store(in: &cancellables)

        settings.$persistHistory
            .dropFirst()
            .sink { [weak self] enabled in
                guard enabled else { return }
                self?.loadPersistedHistory()
            }
            .store(in: &cancellables)
    }

    private func prunePersistedHistory(limit: Int) {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.prunePackets(retentionLimit: limit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("prune packets", errorDescription: error.localizedDescription)
            }
        }
    }

    private func prunePersistedConsole(limit: Int) {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.pruneConsole(retentionLimit: limit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("prune console", errorDescription: error.localizedDescription)
            }
        }
    }

    private func prunePersistedRaw(limit: Int) {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.pruneRaw(retentionLimit: limit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("prune raw", errorDescription: error.localizedDescription)
            }
        }
    }

    private func clearPersistedConsole() {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.deleteAllConsole()
            } catch {
                SentryManager.shared.capturePersistenceFailure("deleteAll console", errorDescription: error.localizedDescription)
            }
        }
    }

    private func clearPersistedRaw() {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.deleteAllRaw()
            } catch {
                SentryManager.shared.capturePersistenceFailure("deleteAll raw", errorDescription: error.localizedDescription)
            }
        }
    }
}

private struct ConsoleEntryMetadata: Codable {
    let from: String?
    let to: String?

    var hasValues: Bool {
        from != nil || to != nil
    }
}

private extension ConsoleEntryRecord.Level {
    init(from kind: ConsoleLine.Kind) {
        switch kind {
        case .system:
            self = .system
        case .error:
            self = .error
        case .packet:
            self = .info
        }
    }
}
