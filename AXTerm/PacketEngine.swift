//
//  PacketEngine.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Combine
import CoreGraphics
import Foundation
import GRDB
import Network

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
    private let packetInsertSubject = PassthroughSubject<Packet, Never>()

    // MARK: - NET/ROM Integration

    /// NET/ROM routing integration for passive route inference and link quality estimation.
    /// Observes all incoming packets to build routing tables.
    private(set) var netRomIntegration: NetRomIntegration?

    /// NET/ROM persistence for saving/loading routing state.
    private var netRomPersistence: NetRomPersistence?

    /// Timer for periodic NET/ROM snapshot saving.
    private var netRomSnapshotTimer: Timer?

    /// Counter for packets since last snapshot (for packet-count-based saves).
    private var netRomPacketsSinceSnapshot: Int = 0

    /// Configuration for NET/ROM snapshot saving.
    private enum NetRomSnapshotConfig {
        static let saveIntervalSeconds: TimeInterval = 60  // Save every 60 seconds
        static let saveAfterPacketCount: Int = 500         // Or after 500 packets
    }

    #if DEBUG
    /// Debug packet counter for throttled logging
    private var netRomObserveCount: Int = 0
    #endif

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
        notificationScheduler: NotificationScheduling? = nil,
        databaseWriter: (any GRDB.DatabaseWriter)? = nil
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

        // Initialize NET/ROM persistence
        if let writer = databaseWriter {
            self.netRomPersistence = try? NetRomPersistence(database: writer)
        }

        // Initialize NET/ROM integration for passive route inference
        let myCallsign = settings.myCallsign
        if !myCallsign.isEmpty {
            self.netRomIntegration = NetRomIntegration(
                localCallsign: myCallsign,
                mode: .hybrid  // Use hybrid mode for best passive inference
            )

            // Load persisted NET/ROM state if available
            loadNetRomSnapshot()

            // Start periodic snapshot timer
            startNetRomSnapshotTimer()
        }

        configureStationSubscription()
        observeSettings()
        loadPersistedPackets(reason: "startup")
    }

    deinit {
        netRomSnapshotTimer?.invalidate()
    }

    // MARK: - Connection Management

    func connect(host: String = "localhost", port: UInt16 = 8001) {
        disconnect()

        guard port > 0 else {
            status = .failed
            lastError = "Invalid port \(port)"
            addErrorLine("Connection failed: invalid port \(port)", category: .connection)
            eventLogger?.log(level: .error, category: .connection, message: "Connection failed: invalid port \(port)", metadata: nil)
            SentryManager.shared.captureConnectionFailure("Connection failed: invalid port \(port)")
            return
        }

        status = .connecting
        lastError = nil
        connectedHost = host
        connectedPort = port
        SentryManager.shared.breadcrumbConnectAttempt(host: host, port: port)
        SentryManager.shared.setConnectionTags(host: host, port: port)
        eventLogger?.log(level: .info, category: .connection, message: "Connecting to \(host):\(port)", metadata: nil)
        loadPersistedPackets(reason: "connect")

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
        guard let stationCall = packet.from?.display else { return }
        stationTracker.update(with: packet)
        stations = stationTracker.stations
        if let heardCount = stationTracker.heardCount(for: stationCall) {
            SentryManager.shared.addBreadcrumb(
                category: "stations.update.on_packet_insert",
                message: "Stations updated from packet insert",
                level: .info,
                data: ["stationKey": stationCall, "heardCount": heardCount]
            )
        }
    }

    // MARK: - Capped Array Helpers

    private func insertPacketSorted(_ packet: Packet) {
        // NOTE: Persisted packets load newest-first; appending new packets at the end
        // caused "All Packets" to appear stale because fresh rows landed off-screen.
        let insertionIndex = PacketEngine.insertionIndex(for: packet, in: packets)
        packets.insert(packet, at: insertionIndex)
        if packets.count > maxPackets {
            packets.removeLast(packets.count - maxPackets)
        }
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
        SentryManager.shared.addBreadcrumb(
            category: "packets.insert",
            message: "Packet insert received",
            level: .info,
            data: ["packetID": packet.id.uuidString, "currentCount": packets.count]
        )
        insertPacketSorted(packet)
        packetInsertSubject.send(packet)

        // Feed packet to NET/ROM integration for route inference
        observePacketForNetRom(packet)

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

    /// Feed a packet to NET/ROM integration for passive route inference.
    /// Called from handleIncomingPacket for live packets.
    private func observePacketForNetRom(_ packet: Packet) {
        guard let integration = netRomIntegration else { return }

        integration.observePacket(packet, timestamp: packet.timestamp, isDuplicate: false)

        // Check if we should save based on packet count
        checkNetRomPacketCountSave()

        #if DEBUG
        netRomObserveCount += 1
        // Throttle debug logging to first 5 packets then every 100
        if netRomObserveCount <= 5 || netRomObserveCount % 100 == 0 {
            let fromDisplay = packet.from?.display ?? "?"
            let toDisplay = packet.to?.display ?? "?"
            let viaPath = packet.via.map { $0.display }.joined(separator: ",")
            print("[NETROM] observe #\(netRomObserveCount): \(fromDisplay) → \(toDisplay) via=[\(viaPath)]")
        }
        #endif
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
        loadPersistedPackets(reason: "manual")
    }

    private func loadPersistedPackets(reason: String) {
        guard settings.persistHistory, let persistenceWorker else { return }
        if !packets.isEmpty {
            if stations.isEmpty {
                rebuildStations(from: packets)
                SentryManager.shared.addBreadcrumb(
                    category: "stations.initial_load.end",
                    message: "Stations seeded from in-memory packets",
                    level: .info,
                    data: ["packetCount": packets.count, "stationCount": stations.count, "reason": reason]
                )
            }
            return
        }
        let limit = min(settings.retentionLimit, maxPackets)
        SentryManager.shared.addBreadcrumb(
            category: "stations.initial_load.start",
            message: "Stations initial load started",
            level: .info,
            data: ["retentionLimit": limit, "reason": reason]
        )
        Task {
            do {
                let result = try await persistenceWorker.loadPackets(limit: limit)
                applyLoadedPackets(result.packets, pinnedIDs: result.pinnedIDs)
                SentryManager.shared.addBreadcrumb(
                    category: "stations.initial_load.end",
                    message: "Stations initial load completed",
                    level: .info,
                    data: ["packetCount": result.packets.count, "stationCount": stations.count, "reason": reason]
                )
            } catch {
                SentryManager.shared.capturePersistenceFailure("loadRecent packets", errorDescription: error.localizedDescription)
                SentryManager.shared.captureMessage(
                    "stations.initial_load.failed",
                    level: .error,
                    extra: ["reason": reason, "error": error.localizedDescription]
                )
            }
        }
    }

    private func applyLoadedPackets(_ loaded: [Packet], pinnedIDs: Set<Packet.ID>) {
        packets = loaded.sorted(by: PacketEngine.shouldPrecede)
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
        stationTracker.rebuild(from: packets)
        stations = stationTracker.stations
    }

    private func persistPacket(_ packet: Packet) {
        guard settings.persistHistory, let persistenceWorker else { return }
        let retentionLimit = settings.retentionLimit
        Task {
            do {
                try await persistenceWorker.savePacket(packet, retentionLimit: retentionLimit)
                await MainActor.run {
                    SentryManager.shared.addBreadcrumb(
                        category: "packets.insert",
                        message: "Packet insert committed",
                        level: .info,
                        data: ["packetID": packet.id.uuidString, "retentionLimit": retentionLimit]
                    )
                }
            } catch {
                SentryManager.shared.capturePersistenceFailure("save/prune packet", errorDescription: error.localizedDescription)
            }
        }
    }

    private static func shouldPrecede(_ lhs: Packet, _ rhs: Packet) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private static func insertionIndex(for packet: Packet, in packets: [Packet]) -> Int {
        var lowerBound = 0
        var upperBound = packets.count
        while lowerBound < upperBound {
            let mid = (lowerBound + upperBound) / 2
            if shouldPrecede(packet, packets[mid]) {
                upperBound = mid
            } else {
                lowerBound = mid + 1
            }
        }
        return lowerBound
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

    private func configureStationSubscription() {
        SentryManager.shared.addBreadcrumb(
            category: "stations.subscription",
            message: "Stations subscription configured",
            level: .info,
            data: nil
        )
        packetInsertSubject
            .sink { [weak self] packet in
                self?.updateMHeard(for: packet)
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

    // MARK: - NET/ROM Persistence

    /// Load NET/ROM snapshot on startup if valid.
    private func loadNetRomSnapshot() {
        #if DEBUG
        print("[NETROM:STARTUP] ========== Loading NET/ROM Snapshot ==========")
        #endif

        guard let persistence = netRomPersistence else {
            #if DEBUG
            print("[NETROM:STARTUP] ❌ netRomPersistence is nil - persistence not initialized")
            #endif
            return
        }

        guard let integration = netRomIntegration else {
            #if DEBUG
            print("[NETROM:STARTUP] ❌ netRomIntegration is nil - integration not initialized")
            #endif
            return
        }

        #if DEBUG
        print("[NETROM:STARTUP] ✓ Persistence and Integration initialized")
        print("[NETROM:STARTUP] Local callsign: '\(settings.myCallsign)'")
        #endif

        do {
            // Check snapshot metadata first
            let meta = try persistence.loadSnapshotMeta()
            #if DEBUG
            if let meta = meta {
                print("[NETROM:STARTUP] Snapshot metadata found:")
                print("[NETROM:STARTUP]   - lastPacketID: \(meta.lastPacketID)")
                print("[NETROM:STARTUP]   - configHash: \(meta.configHash ?? "nil")")
                print("[NETROM:STARTUP]   - snapshotTimestamp: \(meta.snapshotTimestamp)")
                let age = Date().timeIntervalSince(meta.snapshotTimestamp)
                print("[NETROM:STARTUP]   - age: \(Int(age)) seconds (\(Int(age / 3600)) hours)")
            } else {
                print("[NETROM:STARTUP] ⚠️ No snapshot metadata found in database")
            }
            #endif

            // Check if snapshot is valid (within TTL)
            let isValid = try persistence.isSnapshotValid(currentDate: Date(), expectedConfigHash: nil)
            #if DEBUG
            print("[NETROM:STARTUP] Snapshot valid check: \(isValid)")
            #endif

            guard isValid else {
                #if DEBUG
                print("[NETROM:STARTUP] ❌ Snapshot expired or invalid, starting fresh")
                print("[NETROM:STARTUP] (maxSnapshotAgeSeconds = 3600 by default)")
                #endif
                return
            }

            // Load persisted state
            let neighbors = try persistence.loadNeighbors()
            let routes = try persistence.loadRoutes()
            let linkStats = try persistence.loadLinkStats()

            #if DEBUG
            print("[NETROM:STARTUP] Raw data loaded from SQLite:")
            print("[NETROM:STARTUP]   - Neighbors: \(neighbors.count)")
            for (i, n) in neighbors.prefix(5).enumerated() {
                print("[NETROM:STARTUP]     [\(i)] \(n.call) quality=\(n.quality) lastSeen=\(n.lastSeen) source=\(n.sourceType)")
            }
            if neighbors.count > 5 { print("[NETROM:STARTUP]     ... and \(neighbors.count - 5) more") }

            print("[NETROM:STARTUP]   - Routes: \(routes.count)")
            for (i, r) in routes.prefix(5).enumerated() {
                print("[NETROM:STARTUP]     [\(i)] \(r.destination) via \(r.origin) quality=\(r.quality)")
            }
            if routes.count > 5 { print("[NETROM:STARTUP]     ... and \(routes.count - 5) more") }

            print("[NETROM:STARTUP]   - LinkStats: \(linkStats.count)")
            for (i, s) in linkStats.prefix(5).enumerated() {
                print("[NETROM:STARTUP]     [\(i)] \(s.fromCall)→\(s.toCall) quality=\(s.quality) lastUpdated=\(s.lastUpdated)")
            }
            if linkStats.count > 5 { print("[NETROM:STARTUP]     ... and \(linkStats.count - 5) more") }
            #endif

            // Import all data into the integration
            integration.importNeighbors(neighbors)
            integration.importRoutes(routes)
            integration.importLinkStats(linkStats)

            #if DEBUG
            print("[NETROM:STARTUP] ✓ All data imported into integration")

            // Verify what's actually in the integration now
            let integrationNeighbors = integration.currentNeighbors()
            let integrationRoutes = integration.currentRoutes()
            let integrationLinkStats = integration.exportLinkStats()

            print("[NETROM:STARTUP] Integration state AFTER import:")
            print("[NETROM:STARTUP]   - Neighbors in integration: \(integrationNeighbors.count)")
            print("[NETROM:STARTUP]   - Routes in integration: \(integrationRoutes.count)")
            print("[NETROM:STARTUP]   - LinkStats in integration: \(integrationLinkStats.count)")

            print("[NETROM:STARTUP] ========== Snapshot Load Complete ==========")
            #endif

            SentryManager.shared.addBreadcrumb(
                category: "netrom.persistence",
                message: "Loaded NET/ROM snapshot",
                level: .info,
                data: [
                    "neighbors": neighbors.count,
                    "routes": routes.count,
                    "linkStats": linkStats.count
                ]
            )
        } catch {
            #if DEBUG
            print("[NETROM:STARTUP] ❌ Error loading snapshot: \(error)")
            #endif
            SentryManager.shared.capturePersistenceFailure("load netrom snapshot", errorDescription: error.localizedDescription)
        }
    }

    /// Save NET/ROM snapshot to persistence.
    private func saveNetRomSnapshot() {
        guard let persistence = netRomPersistence,
              let integration = netRomIntegration else {
            #if DEBUG
            print("[NETROM:SAVE] ❌ Cannot save - persistence or integration is nil")
            #endif
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            do {
                // Get current state from integration (on main actor)
                let neighbors = await MainActor.run { integration.currentNeighbors() }
                let routes = await MainActor.run { integration.currentRoutes() }
                let linkStats = await MainActor.run { integration.exportLinkStats() }

                // Generate a stable packet ID for high-water mark
                let lastPacketID = await MainActor.run { Int64(self.packets.count) }

                #if DEBUG
                await MainActor.run {
                    print("[NETROM:SAVE] Saving snapshot:")
                    print("[NETROM:SAVE]   - Neighbors: \(neighbors.count)")
                    print("[NETROM:SAVE]   - Routes: \(routes.count)")
                    print("[NETROM:SAVE]   - LinkStats: \(linkStats.count)")
                    print("[NETROM:SAVE]   - lastPacketID: \(lastPacketID)")
                }
                #endif

                // Save atomically
                try persistence.saveSnapshot(
                    neighbors: neighbors,
                    routes: routes,
                    linkStats: linkStats,
                    lastPacketID: lastPacketID,
                    configHash: nil
                )

                #if DEBUG
                await MainActor.run {
                    print("[NETROM:SAVE] ✓ Snapshot saved successfully")
                }
                #endif
            } catch {
                await MainActor.run {
                    #if DEBUG
                    print("[NETROM:SAVE] ❌ Error saving snapshot: \(error)")
                    #endif
                    SentryManager.shared.capturePersistenceFailure("save netrom snapshot", errorDescription: error.localizedDescription)
                }
            }
        }
    }

    /// Start the periodic snapshot timer.
    private func startNetRomSnapshotTimer() {
        netRomSnapshotTimer?.invalidate()
        netRomSnapshotTimer = Timer.scheduledTimer(
            withTimeInterval: NetRomSnapshotConfig.saveIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveNetRomSnapshot()
            }
        }
    }

    /// Check if we should save based on packet count.
    private func checkNetRomPacketCountSave() {
        netRomPacketsSinceSnapshot += 1
        if netRomPacketsSinceSnapshot >= NetRomSnapshotConfig.saveAfterPacketCount {
            netRomPacketsSinceSnapshot = 0
            saveNetRomSnapshot()
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

@MainActor
final class AnalyticsViewModel: ObservableObject {
    @Published private(set) var summary: AnalyticsSummary?
    @Published private(set) var series: AnalyticsSeries = .empty
    @Published private(set) var activeBucket: TimeBucket
    @Published private(set) var graphEdges: [GraphEdge] = []
    @Published private(set) var graphLayout: GraphLayoutResult = .empty
    @Published private(set) var includeViaDigipeaters: Bool
    @Published private(set) var graphMinCount: Int

    private let calendar: Calendar
    private var graphLayoutSize: CGSize = .zero
    private var graphLayoutSeed: Int = 0

    init(
        calendar: Calendar = .current,
        bucket: TimeBucket = .fiveMinutes,
        includeViaDigipeaters: Bool = false,
        graphMinCount: Int = 1
    ) {
        self.calendar = calendar
        self.activeBucket = bucket
        self.includeViaDigipeaters = includeViaDigipeaters
        self.graphMinCount = graphMinCount
    }

    func setBucket(_ bucket: TimeBucket, packets: [Packet]) {
        guard bucket != activeBucket else { return }
        activeBucket = bucket
        Telemetry.breadcrumb(
            category: "analytics.bucket.changed",
            message: "Analytics bucket changed",
            data: ["bucket": bucket.displayName]
        )
        recompute(packets: packets)
    }

    func setGraphIncludeViaDigipeaters(_ includeViaDigipeaters: Bool, packets: [Packet]) {
        guard includeViaDigipeaters != self.includeViaDigipeaters else { return }
        self.includeViaDigipeaters = includeViaDigipeaters
        Telemetry.breadcrumb(
            category: "analytics.graph.includeVia.changed",
            message: "Analytics graph include via changed",
            data: ["includeVia": includeViaDigipeaters]
        )
        recomputeEdges(packets: packets, layoutReason: "filtersChanged")
    }

    func setGraphMinCount(_ minCount: Int, packets: [Packet]) {
        guard minCount != graphMinCount else { return }
        graphMinCount = minCount
        recomputeEdges(packets: packets, layoutReason: "filtersChanged")
    }

    func updateGraphLayout(size: CGSize, seed: Int, reason: String = "layoutRequested") {
        graphLayoutSize = size
        graphLayoutSeed = seed
        recomputeGraphLayout(reason: reason)
    }

    func recompute(packets: [Packet]) {
        Telemetry.breadcrumb(
            category: "analytics.recompute.start",
            message: "Recomputing analytics summary",
            data: [TelemetryContext.packetCount: packets.count]
        )
        let uniqueStations = AnalyticsEngine.uniqueStationsCount(packets: packets)
        let summary = Telemetry.measure(
            name: "analytics.computeSummary",
            data: [
                TelemetryContext.packetCount: packets.count,
                TelemetryContext.uniqueStations: uniqueStations
            ]
        ) {
            AnalyticsEngine.computeSummary(packets: packets)
        }
        self.summary = summary

        let series = Telemetry.measure(
            name: "analytics.computeSeries",
            data: [
                TelemetryContext.packetCount: packets.count,
                "bucket": activeBucket.displayName
            ]
        ) {
            AnalyticsEngine.computeSeries(
                packets: packets,
                bucket: activeBucket,
                calendar: calendar
            )
        }
        self.series = series

        let seriesIssues = validateSeries(series)
        if !seriesIssues.isEmpty {
            Telemetry.capture(
                message: "analytics.series.invalid",
                data: [
                    "issues": seriesIssues,
                    "bucket": activeBucket.displayName
                ]
            )
        }

        if summary.infoTextRatio.isNaN || summary.totalPayloadBytes < 0 {
            Telemetry.capture(
                message: "analytics.summary.invalid",
                data: [
                    "infoTextRatio": summary.infoTextRatio,
                    "totalPayloadBytes": summary.totalPayloadBytes
                ]
            )
        }

        recomputeEdges(packets: packets, layoutReason: "dataChanged")
    }

    private func validateSeries(_ series: AnalyticsSeries) -> [String] {
        var issues: [String] = []
        issues.append(contentsOf: validate(points: series.packetsPerBucket, label: "packetsPerBucket"))
        issues.append(contentsOf: validate(points: series.bytesPerBucket, label: "bytesPerBucket"))
        issues.append(contentsOf: validate(points: series.uniqueStationsPerBucket, label: "uniqueStationsPerBucket"))
        return issues
    }

    private func validate(points: [AnalyticsSeriesPoint], label: String) -> [String] {
        var issues: [String] = []
        var seen: Set<Date> = []
        var lastBucket: Date?

        for point in points {
            if let lastBucket, point.bucket < lastBucket {
                issues.append("\(label).unsorted")
            }
            if !seen.insert(point.bucket).inserted {
                issues.append("\(label).duplicateBucket")
            }
            lastBucket = point.bucket
        }

        return issues
    }

    private func recomputeEdges(packets: [Packet], layoutReason: String) {
        let edges = Telemetry.measureWithResult(
            name: "analytics.computeEdges",
            data: [
                TelemetryContext.packetCount: packets.count,
                "includeVia": includeViaDigipeaters,
                "minCount": graphMinCount
            ],
            updateData: { result in
                ["edgeCount": result.count]
            }
        ) {
            AnalyticsEngine.computeEdges(
                packets: packets,
                includeViaDigipeaters: includeViaDigipeaters,
                minCount: graphMinCount
            )
        }
        graphEdges = edges

        if edges.contains(where: { $0.source.isEmpty || $0.target.isEmpty || $0.count <= 0 }) {
            Telemetry.capture(
                message: "analytics.edges.invalid",
                data: [
                    "includeVia": includeViaDigipeaters,
                    "minCount": graphMinCount,
                    "edgeCount": edges.count
                ]
            )
        }

        recomputeGraphLayout(reason: layoutReason)
    }

    private func recomputeGraphLayout(reason: String) {
        let nodes = buildGraphNodes(from: graphEdges)
        Telemetry.breadcrumb(
            category: "analytics.graph.layout.recompute",
            message: "Analytics graph layout recomputed",
            data: [
                "reason": reason,
                "nodeCount": nodes.count,
                "edgeCount": graphEdges.count
            ]
        )

        let positions = Telemetry.measure(
            name: "analytics.graph.layout",
            data: [
                "nodeCount": nodes.count,
                "edgeCount": graphEdges.count,
                "algorithm": GraphLayoutEngine.algorithmName,
                "iterations": GraphLayoutEngine.iterations
            ]
        ) {
            GraphLayoutEngine.layout(
                nodes: nodes,
                edges: graphEdges,
                size: graphLayoutSize,
                seed: graphLayoutSeed
            )
        }
        graphLayout = GraphLayoutResult(nodes: positions, edges: graphEdges)

        let layoutIssues = validateLayout(positions: positions, size: graphLayoutSize)
        if layoutIssues.invalidCount > 0 {
            Telemetry.capture(
                message: "analytics.graph.layout.invalid",
                data: [
                    "nodeCount": nodes.count,
                    "edgeCount": graphEdges.count,
                    "invalidCount": layoutIssues.invalidCount,
                    "nonFiniteCount": layoutIssues.nonFiniteCount,
                    "outOfBoundsCount": layoutIssues.outOfBoundsCount,
                    "width": layoutIssues.width,
                    "height": layoutIssues.height
                ]
            )
        }
    }

    private func buildGraphNodes(from edges: [GraphEdge]) -> [GraphNode] {
        struct NodeMetrics {
            var degree: Int = 0
            var count: Int = 0
            var bytes: Int = 0
            var hasBytes: Bool = false
        }

        var metricsById: [String: NodeMetrics] = [:]
        for edge in edges {
            let edgeBytes = edge.bytes

            var sourceMetrics = metricsById[edge.source, default: NodeMetrics()]
            sourceMetrics.degree += 1
            sourceMetrics.count += edge.count
            if let edgeBytes {
                sourceMetrics.bytes += edgeBytes
                sourceMetrics.hasBytes = true
            }
            metricsById[edge.source] = sourceMetrics

            var targetMetrics = metricsById[edge.target, default: NodeMetrics()]
            targetMetrics.degree += 1
            targetMetrics.count += edge.count
            if let edgeBytes {
                targetMetrics.bytes += edgeBytes
                targetMetrics.hasBytes = true
            }
            metricsById[edge.target] = targetMetrics
        }

        return metricsById.map { key, metrics in
            GraphNode(
                id: key,
                degree: metrics.degree,
                count: metrics.count,
                bytes: metrics.hasBytes ? metrics.bytes : nil
            )
        }
    }

    private func validateLayout(positions: [NodePosition], size: CGSize) -> (invalidCount: Int, nonFiniteCount: Int, outOfBoundsCount: Int, width: Double, height: Double) {
        let safeWidth = size.width.isFinite ? Double(size.width) : 0
        let safeHeight = size.height.isFinite ? Double(size.height) : 0
        var invalidCount = 0
        var nonFiniteCount = 0
        var outOfBoundsCount = 0

        for position in positions {
            if !position.x.isFinite || !position.y.isFinite {
                nonFiniteCount += 1
                invalidCount += 1
                continue
            }
            if position.x < 0 || position.x > safeWidth || position.y < 0 || position.y > safeHeight {
                outOfBoundsCount += 1
                invalidCount += 1
            }
        }

        return (
            invalidCount: invalidCount,
            nonFiniteCount: nonFiniteCount,
            outOfBoundsCount: outOfBoundsCount,
            width: safeWidth,
            height: safeHeight
        )
    }
}
