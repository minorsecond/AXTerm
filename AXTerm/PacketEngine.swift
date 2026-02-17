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
nonisolated enum ConnectionStatus: String {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case connected = "Connected"
    case failed = "Failed"

    /// Map from KISSLinkState
    init(linkState: KISSLinkState) {
        switch linkState {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .failed: self = .failed
        }
    }
}

/// Transport type for KISS connections
nonisolated enum KISSTransportType: String, CaseIterable, Identifiable, Sendable {
    case network = "Network"
    case serial = "Local USB Serial"
    case ble = "Bluetooth LE"

    var id: String { rawValue }
}

/// Filter settings for packet display
nonisolated struct PacketFilters: Equatable {
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
nonisolated struct RawChunk: Identifiable, Hashable, Sendable {
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

    /// Called when an I-frame (AXDP/user payload) is successfully transmitted.
    /// Parameter: payload byte count. Used for sender progress highlighting.
    var onUserFrameTransmitted: ((Int) -> Void)?

    // MARK: - Debug Logging (Debug Builds Only)
    private func debugTrace(_ message: String, _ data: [String: Any] = [:]) {
        #if DEBUG
        if data.isEmpty {
            print("[KISS TRACE] \(message)")
        } else {
            let details = data.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            print("[KISS TRACE] \(message) | \(details)")
        }
        #endif
    }

    /// AXDP-specific debug logging for capability detection and routing.
    private func debugAXDP(_ message: String, _ data: [String: Any] = [:]) {
        #if DEBUG
        if data.isEmpty {
            print("[AXDP TRACE][Packets] \(message)")
        } else {
            let details = data
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: " ")
            print("[AXDP TRACE][Packets] \(message) | \(details)")
        }
        #endif
    }

    private func hexPrefix(_ data: Data, limit: Int = 32) -> String {
        guard !data.isEmpty else { return "" }
        return data.prefix(limit).map { String(format: "%02X", $0) }.joined()
    }

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

    // MARK: - AXDP Capability Tracking

    /// AXDP capability store for tracking peer capabilities
    /// Used by UI to display capability badges for stations
    let capabilityStore = AXDPCapabilityStore()

    // MARK: - Published State

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var lastError: String?
    private var previousLinkState: KISSLinkState = .disconnected
    @Published private(set) var bytesReceived: Int = 0
    @Published private(set) var connectedHost: String?
    @Published private(set) var connectedPort: UInt16?

    @Published private(set) var packets: [Packet] = []
    @Published private(set) var consoleLines: [ConsoleLine] = []
    @Published private(set) var rawChunks: [RawChunk] = []
    @Published private(set) var stations: [Station] = []
    
    // Mobilinkd Telemetry
    @Published var mobilinkdBatteryLevel: Int?
    @Published var mobilinkdInputLevel: MobilinkdInputLevel?

    @Published var selectedStationCall: String?
    @Published private(set) var pinnedPacketIDs: Set<Packet.ID> = []
    
    // MARK: - Frame Statistics (Diagnostics)
    @Published private(set) var frameStats: FrameStatistics = FrameStatistics()
    
    struct FrameStatistics {
        var totalFramesReceived: Int = 0
        var ax25FramesReceived: Int = 0
        var telemetryFramesReceived: Int = 0
        var unknownFramesReceived: Int = 0
        
        var frameSizeHistogram: [String: Int] = [:]  // "size_range" -> count
        var frameTypeHistogram: [String: Int] = [:]   // "frameType" -> count
        
        mutating func recordFrame(type: String, size: Int) {
            totalFramesReceived += 1
            frameTypeHistogram[type, default: 0] += 1
            
            let sizeRange: String
            if size < 20 {
                sizeRange = "0-19"
            } else if size < 50 {
                sizeRange = "20-49"
            } else if size < 100 {
                sizeRange = "50-99"
            } else {
                sizeRange = "100+"
            }
            frameSizeHistogram[sizeRange, default: 0] += 1
        }
        
        var diagnosticSummary: String {
            let typeStr = frameTypeHistogram.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
            let sizeStr = frameSizeHistogram.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
            return "Total:\(totalFramesReceived) Types:[\(typeStr)] Sizes:[\(sizeStr)]"
        }
    }

    /// Publisher for incoming packets - subscribe to receive all decoded packets
    var packetPublisher: AnyPublisher<Packet, Never> {
        packetInsertSubject.eraseToAnyPublisher()
    }

    // MARK: - Connection Config Snapshot

    /// Captures all connection-relevant settings at a point in time.
    /// Used to detect whether settings actually changed while the settings panel was open.
    ///
    /// NOTE: Mobilinkd-specific settings (modemType, gains) are intentionally EXCLUDED.
    /// Those settings are stored in TNC4 EEPROM and applied via auto-calibration,
    /// NOT via KISS init commands on connect. Changing them in the UI should NOT
    /// trigger a serial port close/reopen cycle, which disrupts the running demodulator.
    struct ConnectionConfigSnapshot: Equatable {
        let transportType: String
        let serialDevicePath: String
        let serialBaudRate: Int
        let blePeripheralUUID: String
        let host: String
        let port: Int

        init(settings: AppSettingsStore) {
            self.transportType = settings.transportType
            self.serialDevicePath = settings.serialDevicePath
            self.serialBaudRate = settings.serialBaudRate
            self.blePeripheralUUID = settings.blePeripheralUUID
            self.host = settings.host
            self.port = settings.port
        }
    }

    /// Snapshot taken when connection logic is suspended (settings panel opens).
    private var suspendedConfigSnapshot: ConnectionConfigSnapshot?

    // MARK: - Private State

    private var connection: NWConnection?
    private var link: KISSLink?
    private var parser = KISSFrameParser()
    private var stationTracker = StationTracker()

    // MARK: - Console Line Duplicate Detection

    /// Tracks recent console line signatures to detect duplicates received via different paths
    private var recentConsoleSignatures: [String: (timestamp: Date, viaPath: [String])] = [:]
    /// Time window for considering console lines as duplicates (5 seconds)
    private let consoleDuplicateWindow: TimeInterval = 5.0

    // MARK: - Initialization

    init(
        maxPackets: Int = 5000,  // We only show this many packets in the UI, but more can be persisted in the DB
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
            #if DEBUG
            if netRomPersistence != nil {
                print("[NETROM:ENGINE] ✅ NetRomPersistence initialized successfully")
            } else {
                print("[NETROM:ENGINE] ❌ NetRomPersistence failed to initialize")
            }
            #endif
        }

        // Initialize NET/ROM integration for passive route inference
        let myCallsign = settings.myCallsign
        if !myCallsign.isEmpty {
            self.netRomIntegration = NetRomIntegration(
                localCallsign: myCallsign,
                mode: .hybrid,  // Use hybrid mode for best passive inference
                persistence: netRomPersistence  // Pass persistence for adaptive stale threshold tracking
            )
            #if DEBUG
            print("[NETROM:ENGINE] ✅ NetRomIntegration initialized with persistence: \(netRomPersistence != nil ? "YES" : "NO")")
            #endif

            // Load persisted NET/ROM state if available
            loadNetRomSnapshot()

            // NOTE: Pruning is deferred to avoid database lock during init.
            // It will run via the scheduled timer below (first run after 60s).
            // See: database_lock_analysis.md for details.
            // pruneOldNetRomEntries()

            // Start periodic snapshot timer (will also handle deferred pruning)
            startNetRomSnapshotTimer()
        }

        configureStationSubscription()
        observeSettings()
        observeCapabilityStore()
        loadPersistedPackets(reason: "startup")
    }

    deinit {
        netRomSnapshotTimer?.invalidate()
    }

    // MARK: - USB Device Path Resolution

    /// Resolve a serial device path, falling back to auto-detection if the configured path doesn't exist.
    /// Scans `/dev/cu.*` for `usbmodem` devices (TNC4 uses CDC-ACM).
    /// Does NOT modify saved settings — returns the resolved path for this connection attempt only.
    func resolveSerialDevicePath(_ configuredPath: String) -> String {
        if !configuredPath.isEmpty && FileManager.default.fileExists(atPath: configuredPath) {
            return configuredPath
        }

        debugTrace("Configured serial path missing or empty, scanning for USB devices", ["path": configuredPath])

        do {
            let devContents = try FileManager.default.contentsOfDirectory(atPath: "/dev")
            let usbDevices = devContents
                .filter { $0.hasPrefix("cu.") && $0.lowercased().contains("usbmodem") }
                .sorted()

            if let first = usbDevices.first {
                let resolved = "/dev/\(first)"
                debugTrace("Auto-detected USB serial device", ["resolved": resolved])
                return resolved
            }
        } catch {
            debugTrace("Failed to scan /dev for USB devices: \(error)")
        }

        // Return original path — KISSLinkSerial will handle the missing device gracefully
        return configuredPath
    }

    // MARK: - Connection Management

    /// Connect using the transport configured in settings.
    /// Falls back to network if transport type is unknown.
    func connectUsingSettings() {
        if settings.isSerialTransport {
            
            // Construct Mobilinkd Config if enabled
            var mobilinkdConfig: MobilinkdConfig?
            if settings.mobilinkdEnabled {
                mobilinkdConfig = MobilinkdConfig(
                    modemType: MobilinkdTNC.ModemType(rawValue: UInt8(settings.mobilinkdModemType)) ?? .afsk1200,
                    outputGain: UInt8(settings.mobilinkdOutputGain),
                    inputGain: UInt8(settings.mobilinkdInputGain),
                    isBatteryMonitoringEnabled: true // Always true for now if enabled
                )
            }
            
            let resolvedPath = resolveSerialDevicePath(settings.serialDevicePath)
            let config = SerialConfig(
                devicePath: resolvedPath,
                baudRate: settings.serialBaudRate,
                autoReconnect: settings.serialAutoReconnect,
                mobilinkdConfig: mobilinkdConfig
            )
            connectSerial(config: config)
        } else if settings.isBLETransport {
            // Construct Mobilinkd config for BLE just like serial
            var bleMobilinkdConfig: MobilinkdConfig?
            if settings.mobilinkdEnabled {
                bleMobilinkdConfig = MobilinkdConfig(
                    modemType: MobilinkdTNC.ModemType(rawValue: UInt8(settings.mobilinkdModemType)) ?? .afsk1200,
                    outputGain: UInt8(settings.mobilinkdOutputGain),
                    inputGain: UInt8(settings.mobilinkdInputGain),
                    isBatteryMonitoringEnabled: true
                )
            }
            let config = BLEConfig(
                peripheralUUID: settings.blePeripheralUUID,
                peripheralName: settings.blePeripheralName,
                autoReconnect: settings.bleAutoReconnect,
                mobilinkdConfig: bleMobilinkdConfig
            )
            connectBLE(config: config)
        } else {
            connect(host: settings.host, port: settings.portValue)
        }
    }

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

        let networkLink = KISSLinkNetwork(host: host, port: port)
        connectViaLink(networkLink)
    }

    /// Connect using a serial device
    func connectSerial(config: SerialConfig) {
        // Orchestration: Check if we are already connected/connecting to this exact device
        if let currentLink = link as? KISSLinkSerial, currentLink.config.devicePath == config.devicePath {
            // It's the same device path. 
            // If settings (baud rate/auto-reconnect) changed, we might need to update.
            // KISSLinkSerial.updateConfig handles this efficiently without full teardown if possible,
            // or handles the teardown/reopen internally.
            debugTrace("Update serial config", ["path": config.devicePath])
            currentLink.updateConfig(config)
            
            // Ensure we are in a mode to connect if we weren't
            if currentLink.state == .disconnected || currentLink.state == .failed {
                currentLink.open()
            }
            return
        }

        disconnect(reason: "switching to new serial device")

        status = .connecting
        lastError = nil
        connectedHost = nil
        connectedPort = nil
        eventLogger?.log(level: .info, category: .connection, message: "Connecting to serial: \(config.devicePath)", metadata: nil)
        loadPersistedPackets(reason: "connect")

        let serialLink = KISSLinkSerial(config: config)
        connectViaLink(serialLink)
    }

    /// Connect using a BLE device
    func connectBLE(config: BLEConfig) {
        // Reuse existing BLE link if it's the same peripheral (mirrors serial pattern)
        if let currentLink = link as? KISSLinkBLE, currentLink.config.peripheralUUID == config.peripheralUUID {
            debugTrace("Update BLE config", ["uuid": config.peripheralUUID])
            currentLink.updateConfig(config)

            if currentLink.state == .disconnected || currentLink.state == .failed {
                currentLink.open()
            }
            return
        }

        disconnect(reason: "switching to BLE transport")

        status = .connecting
        lastError = nil
        connectedHost = nil
        connectedPort = nil
        eventLogger?.log(level: .info, category: .connection, message: "Connecting to BLE: \(config.peripheralName.isEmpty ? config.peripheralUUID : config.peripheralName)", metadata: nil)
        loadPersistedPackets(reason: "connect")

        let bleLink = KISSLinkBLE(config: config)
        connectViaLink(bleLink)
    }

    /// Connect using any KISSLink transport
    private func connectViaLink(_ newLink: KISSLink) {
        link = newLink
        newLink.delegate = self
        newLink.open()
    }

    func disconnect(reason: String = "unknown") {
        let previousStatus = status
        link?.close()
        link = nil
        connection?.cancel()
        connection = nil
        parser.reset()
        status = .disconnected
        connectedHost = nil
        connectedPort = nil
        addSystemLine("Disconnected (reason: \(reason))", category: .connection)
        SentryManager.shared.addBreadcrumb(
            category: "kiss.connection",
            message: "Disconnected",
            level: .info,
            data: ["reason": reason, "previousStatus": previousStatus.rawValue]
        )
        SentryManager.shared.breadcrumbDisconnect()
    }

    // MARK: - Transmission

    /// Send an outbound frame via KISS
    /// - Parameter frame: The frame to send
    /// - Parameter completion: Callback with success or error
    func send(frame: OutboundFrame, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let activeLink = link
        let activeConn = connection
        guard status == .connected, (activeLink != nil || activeConn != nil) else {
            let error = NSError(domain: "PacketEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
            TxLog.error(.transport, "Send failed: not connected", error: error, ["frameId": String(frame.id.uuidString.prefix(8))])
            addErrorLine("Send failed: not connected", category: .transmission)
            completion?(.failure(error))
            return
        }

        // Encode the frame as AX.25
        let ax25Data = frame.encodeAX25()
        debugTrace("TX AX.25", [
            "src": frame.source.display,
            "dest": frame.destination.display,
            "type": frame.frameType,
            "ctl": frame.controlByte.map { String(format: "0x%02X", $0) } ?? "nil",
            "pid": frame.pid.map { String(format: "0x%02X", $0) } ?? "nil",
            "len": ax25Data.count,
            "infoHex": hexPrefix(frame.payload)
        ])
        TxLog.ax25Encode(
            dest: frame.destination.display,
            src: frame.source.display,
            type: frame.frameType,
            size: ax25Data.count
        )
        TxLog.hexDump(.ax25, "AX.25 frame", data: ax25Data)

        // Wrap in KISS frame (port 0, data frame)
        let kissData = KISS.encodeFrame(payload: ax25Data, port: frame.channel)
        debugTrace("TX KISS", [
            "port": frame.channel,
            "len": kissData.count,
            "hex": hexPrefix(kissData)
        ])
        TxLog.kissSend(frameId: frame.id, size: kissData.count)
        TxLog.hexDump(.kiss, "KISS frame", data: kissData)

        LinkDebugLog.shared.recordTxBytes(kissData.count)
        LinkDebugLog.shared.recordFrame(LinkDebugFrameEntry(
            timestamp: Date(), direction: .tx, rawBytes: kissData,
            frameType: frame.frameType, byteCount: kissData.count))

        // Log the transmission: user payload as DATA (purple), protocol as SYS
        let viaSuffix = formatViaPath(frame.path.digis)
        let showAsData: Bool
        if let text = frame.displayInfo, !text.isEmpty {
            showAsData = frame.isUserPayload || (frame.frameType.lowercased() == "i" && !isProtocolDisplayInfo(text))
            if showAsData {
                let line = ConsoleLine.packet(from: frame.source.display, to: frame.destination.display, text: text)
                appendConsoleLine(line, category: .packet, packetID: nil, byteCount: text.utf8.count)
            } else {
                // Build a richer control frame description for TX SYS lines
                let txDesc = txControlFrameDescription(frame) ?? text
                addSystemLine("TX: \(frame.source.display) → \(frame.destination.display)\(viaSuffix): \(txDesc)", category: .transmission)
            }
        } else {
            let txDesc = txControlFrameDescription(frame) ?? frame.displayInfo ?? ""
            addSystemLine("TX: \(frame.source.display) → \(frame.destination.display)\(viaSuffix): \(txDesc)", category: .transmission)
        }
        eventLogger?.log(
            level: .info,
            category: .transmission,
            message: "Sending frame",
            metadata: [
                "frameId": frame.id.uuidString,
                "destination": frame.destination.display,
                "source": frame.source.display,
                "size": "\(ax25Data.count)"
            ]
        )

        // Send via link (preferred) or legacy connection
        let sendCompletion: (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error = error {
                    TxLog.kissSendComplete(frameId: frame.id, success: false, error: error)
                    self.addErrorLine("Send failed: \(error.localizedDescription)", category: .transmission)
                    self.eventLogger?.log(
                        level: .error,
                        category: .transmission,
                        message: "Send failed: \(error.localizedDescription)",
                        metadata: ["frameId": frame.id.uuidString]
                    )
                    completion?(.failure(error))
                } else {
                    TxLog.kissSendComplete(frameId: frame.id, success: true)
                    TxLog.outbound(.frame, "Frame transmitted", [
                        "frameId": String(frame.id.uuidString.prefix(8)),
                        "dest": frame.destination.display,
                        "size": kissData.count
                    ])
                    self.addSystemLine("Frame sent successfully", category: .transmission)
                    // Notify for sender progress highlighting (I-frames with AXDP PID)
                    if frame.frameType.lowercased() == "i", frame.pid == 0xF0 {
                        self.onUserFrameTransmitted?(frame.payload.count)
                    }
                    completion?(.success(()))
                }
            }
        }

        if let activeLink = activeLink {
            activeLink.send(kissData) { error in
                sendCompletion(error)
            }
        } else if let conn = activeConn {
            conn.send(content: kissData, completion: .contentProcessed { error in
                sendCompletion(error)
            })
        }
    }

    // MARK: - Mobilinkd Commands

    /// One-shot poll of audio input levels. Stops the demodulator during measurement,
    /// then sends RESET to restart it. Do NOT call this in a loop.
    func sendPollInputLevel() {
        guard let activeLink = link else { return }
        let pollFrame = Data(MobilinkdTNC.pollInputLevel())
        let resetFrame = Data(MobilinkdTNC.reset())
        activeLink.send(pollFrame) { [weak activeLink] _ in
            // Send RESET after a delay to allow measurement to complete,
            // then restart the demodulator for normal packet reception.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                activeLink?.send(resetFrame) { _ in }
            }
        }
    }

    /// Sends the ADJUST_INPUT_LEVELS command to trigger the TNC4's auto-AGC.
    /// Stops the demodulator during calibration; sends RESET after 5s to restart.
    func sendAdjustInputLevels() {
        guard let activeLink = link else { return }
        let frame = Data(MobilinkdTNC.adjustInputLevels())
        let resetFrame = Data(MobilinkdTNC.reset())
        activeLink.send(frame) { [weak activeLink] _ in
            // Auto-adjust takes several seconds (gain stepping + measurements).
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                activeLink?.send(resetFrame) { _ in }
            }
        }
    }

    /// Sends a SET_INPUT_GAIN command to set manual input gain level (0-4, 6dB steps).
    func sendSetInputGain(_ level: UInt8) {
        guard let activeLink = link else { return }
        let frame = Data(MobilinkdTNC.setInputGain(level))
        activeLink.send(frame) { _ in }
    }

    /// Sends RESET to restart the TNC4 demodulator.
    func sendMobilinkdReset() {
        guard let activeLink = link else { return }
        let frame = Data(MobilinkdTNC.reset())
        activeLink.send(frame) { _ in }
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
            guard let self else { return }
            Task { @MainActor in

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
                    self.disconnect(reason: "legacy NWConnection receive complete")
                    return
                }

                // Continue receiving
                self.startReceiving()
            }
        }
    }

    func handleIncomingData(_ data: Data) {
        bytesReceived += data.count
        LinkDebugLog.shared.recordRxBytes(data.count)

        TxLog.kissReceive(size: data.count)
        debugTrace("RX KISS chunk", [
            "len": data.count,
            "hex": hexPrefix(data)
        ])

        // Always log raw chunk
        appendRawChunk(RawChunk(data: data))

        // Parse KISS frames from the chunk
        let kissFrames = parser.feed(data)

        if !kissFrames.isEmpty {
            TxLog.debug(.kiss, "Parsed KISS frames", ["count": kissFrames.count])
        }

        for frameOutput in kissFrames {
            switch frameOutput {
            case .ax25(let ax25Data):
                debugTrace("KISS AX.25 frame parsed", ["len": ax25Data.count])
                frameStats.recordFrame(type: "AX.25", size: ax25Data.count)
                LinkDebugLog.shared.recordFrame(LinkDebugFrameEntry(
                    timestamp: Date(), direction: .rx, rawBytes: ax25Data,
                    frameType: "AX25", byteCount: ax25Data.count))
                processAX25Frame(ax25Data)

            case .mobilinkdTelemetry(let telemetryData):
                frameStats.recordFrame(type: "Telemetry", size: telemetryData.count)
                if let inputLevel = MobilinkdTNC.parseInputLevel(telemetryData) {
                    DispatchQueue.main.async {
                        self.mobilinkdInputLevel = inputLevel
                    }
                    debugTrace("Mobilinkd InputLevel", [
                        "vpp": inputLevel.vpp, "vavg": inputLevel.vavg,
                        "vmin": inputLevel.vmin, "vmax": inputLevel.vmax
                    ])
                } else if let battery = MobilinkdTNC.parseBatteryLevel(telemetryData) {
                    DispatchQueue.main.async {
                         self.mobilinkdBatteryLevel = battery
                    }
                    debugTrace("Mobilinkd Battery", ["level": battery])
                } else if let gain = MobilinkdTNC.parseInputGain(telemetryData) {
                     DispatchQueue.main.async {
                         if self.settings.mobilinkdInputGain != gain {
                             self.settings.mobilinkdInputGain = gain
                             self.debugTrace("Mobilinkd Auto-Gain Updated", ["newGain": gain])
                         }
                     }
                } else {
                    debugTrace("Mobilinkd Telemetry", ["hex": hexPrefix(telemetryData)])
                }
                LinkDebugLog.shared.recordFrame(LinkDebugFrameEntry(
                    timestamp: Date(), direction: .rx, rawBytes: telemetryData,
                    frameType: "Telemetry", byteCount: telemetryData.count))

            case .unknown(let cmd, let payload):
                frameStats.recordFrame(type: "Unknown(0x\(String(format: "%02X", cmd)))", size: payload.count)
                debugTrace("Unknown KISS Frame", ["cmd": String(format: "0x%02X", cmd), "len": payload.count])
                LinkDebugLog.shared.recordFrame(LinkDebugFrameEntry(
                    timestamp: Date(), direction: .rx, rawBytes: payload,
                    frameType: "Unknown(0x\(String(format: "%02X", cmd)))", byteCount: payload.count))
                LinkDebugLog.shared.recordParseError(
                    message: "Unknown KISS command: 0x\(String(format: "%02X", cmd))",
                    rawBytes: payload)
            }
        }
    }

    private func processAX25Frame(_ ax25Data: Data) {
        debugTrace("processAX25Frame called", ["len": ax25Data.count, "hex": hexPrefix(ax25Data)])
        TxLog.hexDump(.ax25, "Received AX.25 frame", data: ax25Data)
        debugTrace("RX AX.25 raw", [
            "len": ax25Data.count,
            "hex": hexPrefix(ax25Data)
        ])

        guard let decoded = AX25.decodeFrame(ax25: ax25Data) else {
            LinkDebugLog.shared.recordParseError(
                message: "AX.25 decode failed (\(ax25Data.count) bytes)",
                rawBytes: ax25Data)
            TxLog.ax25DecodeError(reason: "Invalid frame structure", size: ax25Data.count)
            eventLogger?.log(
                level: .warning,
                category: .parser,
                message: "Failed to decode AX.25 frame",
                metadata: ["byteCount": "\(ax25Data.count)"]
            )
            SentryManager.shared.captureDecodeFailure(byteCount: ax25Data.count)
            return
        }

        TxLog.ax25Decode(
            dest: decoded.to?.display ?? "?",
            src: decoded.from?.display ?? "?",
            type: decoded.frameType.rawValue,
            size: ax25Data.count
        )
        debugTrace("RX AX.25 decoded", [
            "src": decoded.from?.display ?? "?",
            "dest": decoded.to?.display ?? "?",
            "via": decoded.via.map { $0.display }.joined(separator: ",").isEmpty ? "(direct)" : decoded.via.map { $0.display }.joined(separator: ","),
            "type": decoded.frameType.rawValue,
            "ctl": String(format: "0x%02X", decoded.control),
            "ctl1": decoded.controlByte1.map { String(format: "0x%02X", $0) } ?? "nil",
            "pid": decoded.pid.map { String(format: "0x%02X", $0) } ?? "nil",
            "infoLen": decoded.info.count,
            "infoHex": hexPrefix(decoded.info)
        ])

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
            controlByte1: decoded.controlByte1,
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
        PacketEngine.insertPacketMaintainingCap(packet, into: &packets, maxPackets: maxPackets)
    }

    /// Maintains packet ordering and in-memory cap while preserving newest packets.
    /// Extracted for deterministic unit testing.
    nonisolated static func insertPacketMaintainingCap(
        _ packet: Packet,
        into packets: inout [Packet],
        maxPackets: Int
    ) {
        // Packets are kept in ascending timestamp order (oldest -> newest).
        // When capped, drop oldest entries so newly received packets stay visible
        // and downstream analytics/health calculations keep fresh activity.
        PacketOrdering.insert(packet, into: &packets)
        if packets.count > maxPackets {
            packets.removeFirst(packets.count - maxPackets)
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

    /// Public wrapper for addSystemLine so SessionCoordinator can post adaptive-change notifications.
    func appendSystemNotification(_ text: String) {
        addSystemLine(text, category: .transmission)
    }

    private func addErrorLine(_ text: String, category: ConsoleEntryRecord.Category) {
        appendConsoleLine(ConsoleLine.error(text), category: category)
    }

    // MARK: - Control Frame SYS Logging

    /// Format a via path with H-bit indicators (digi callsigns with `*` suffix = has been repeated).
    private func formatViaPath(_ via: [AX25Address]) -> String {
        guard !via.isEmpty else { return "" }
        let formatted = via.map { addr -> String in
            addr.repeated ? "\(addr.display)*" : addr.display
        }.joined(separator: ",")
        return " via \(formatted)"
    }

    /// Build a human-readable control frame description for SYS logging.
    /// Examples: "SABM P", "UA F", "RR(3)", "I(1,3) P", "REJ(5) F"
    private func describeControlFrame(_ decoded: AX25ControlFieldDecoded) -> String? {
        let pf = (decoded.pf ?? 0) == 1

        switch decoded.frameClass {
        case .U:
            guard let uType = decoded.uType else { return nil }
            switch uType {
            case .UI:
                return nil  // UI frames are data, not control — skip SYS line
            case .SABM, .SABME, .DISC:
                return "\(uType.rawValue)\(pf ? " P" : "")"
            case .UA, .DM, .FRMR:
                return "\(uType.rawValue)\(pf ? " F" : "")"
            case .UNKNOWN:
                return "U?\(pf ? " P/F" : "")"
            }
        case .S:
            guard let sType = decoded.sType else { return nil }
            let nr = decoded.nr ?? 0
            return "\(sType.rawValue)(\(nr))\(pf ? " P/F" : "")"
        case .I:
            let ns = decoded.ns ?? 0
            let nr = decoded.nr ?? 0
            return "I(\(ns),\(nr))\(pf ? " P" : "")"
        case .unknown:
            return nil
        }
    }

    /// Log an RX control frame as a SYS line in the console.
    /// Called from handleIncomingPacket for all decoded frames.
    private func logRxControlFrame(_ packet: Packet, decoded: AX25ControlFieldDecoded) {
        guard let description = describeControlFrame(decoded),
              let from = packet.from, let to = packet.to else { return }
        let via = formatViaPath(packet.via)
        addSystemLine("RX: \(from.display) → \(to.display)\(via): \(description)", category: .transmission)
    }

    /// Build a richer control frame description for outbound frames.
    /// Returns nil if the frame doesn't have enough info for a richer description.
    private func txControlFrameDescription(_ frame: OutboundFrame) -> String? {
        guard let controlByte = frame.controlByte else { return nil }
        let decoded = AX25ControlFieldDecoder.decode(control: controlByte, controlByte1: nil)
        return describeControlFrame(decoded)
    }

    /// Append decoded AXDP/session chat to the console so it appears in the terminal.
    /// Called when AXDP chat is received—the raw I-frame payload is binary so it never
    /// reaches the console via the normal packet path.
    func appendSessionChatLine(from fromDisplay: String, text: String, via: [String] = []) {
        TxLog.debug(.session, "appendSessionChatLine called", [
            "from": fromDisplay,
            "textLength": text.count,
            "preview": String(text.prefix(50)),
            "via": via.joined(separator: ","),
            "currentLineCount": consoleLines.count
        ])
        let toDisplay = settings.myCallsign
        let line = ConsoleLine.packet(from: fromDisplay, to: toDisplay, text: text, via: via)
        appendConsoleLine(line, category: .packet, packetID: nil, byteCount: text.utf8.count)
        TxLog.debug(.session, "appendSessionChatLine complete", [
            "newLineCount": consoleLines.count
        ])
    }

    // MARK: - Console Line Duplicate Detection

    /// Check if a console line with this signature was recently seen (within duplicate window)
    private func isDuplicateConsoleLine(signature: String, timestamp: Date, viaPath: [String]) -> Bool {
        // First, prune old entries
        pruneOldConsoleSignatures(before: timestamp)

        // Check if we've seen this signature recently
        if let existing = recentConsoleSignatures[signature] {
            // Same content seen within the time window
            // Only consider it a duplicate if it came via a different path
            let sameViaPath = existing.viaPath == viaPath
            if !sameViaPath {
                return true  // Different path, same content = duplicate
            }
        }
        return false
    }

    /// Record a console line signature for future duplicate detection
    private func recordConsoleLineSignature(signature: String, timestamp: Date, viaPath: [String]) {
        recentConsoleSignatures[signature] = (timestamp: timestamp, viaPath: viaPath)
    }

    /// Remove signatures older than the duplicate window
    private func pruneOldConsoleSignatures(before timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-consoleDuplicateWindow)
        recentConsoleSignatures = recentConsoleSignatures.filter { _, value in
            value.timestamp > cutoff
        }
    }

    /// Determine if an I-frame should be skipped from console display.
    /// Only skip I-frames (PID 0xF0) that belong to the user's active sessions,
    /// since SessionCoordinator will deliver those via appendSessionChatLine.
    /// Monitored traffic (other stations talking to each other) should appear in console.
    private func shouldSkipIFrame(_ packet: Packet) -> Bool {
        // Only consider I-frames with session data (PID 0xF0)
        guard packet.frameType == .i, packet.pid == 0xF0 else {
            return false
        }
        
        // Check if the user is a participant in this session
        // If source OR destination matches myCallsign, it's a user session - skip it
        // because SessionCoordinator will deliver it via appendSessionChatLine.
        // Use addressMatchesDisplay() to correctly handle SSID (e.g. "K0EPI-7" vs base "K0EPI")
        let myCallDisplay = settings.myCallsign
        guard !myCallDisplay.isEmpty else {
            // If myCallsign is not set, show all I-frames (nothing to match against)
            return false
        }

        let fromMatch = packet.from.map { CallsignNormalizer.addressMatchesDisplay($0, myCallDisplay) } ?? false
        let toMatch = packet.to.map { CallsignNormalizer.addressMatchesDisplay($0, myCallDisplay) } ?? false

        let isUserSession = fromMatch || toMatch
        
        // Skip if it's the user's session, show if it's monitored traffic
        return isUserSession
    }

    /// True if displayInfo is a protocol label (AXDP PING, SABM, etc.), not user chat
    private func isProtocolDisplayInfo(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasPrefix("AXDP ") { return true }
        if t == "SABM" || t == "SABME" || t == "UA" || t == "DM" || t == "DISC" { return true }
        if t.hasPrefix("RR(") || t.hasPrefix("RNR(") || t.hasPrefix("REJ(") { return true }
        if t.hasPrefix("I(") { return true }
        return false
    }

    /// Compute content signature for duplicate detection
    private func computeContentSignature(from: String, to: String, text: String) -> String {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(from.uppercased())|\(to.uppercased())|\(normalizedText)"
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

        // Log RX control frames (SABM, UA, DM, DISC, RR, REJ, I) as SYS lines with digi H-bit status
        let controlDecoded = AX25ControlFieldDecoder.decode(control: packet.control, controlByte1: packet.controlByte1)
        logRxControlFrame(packet, decoded: controlDecoded)

        // Feed packet to NET/ROM integration for route inference
        observePacketForNetRom(packet)

        // Check for AXDP capabilities in UI frames
        detectAXDPCapabilities(from: packet)

        // Skip raw I-frame console lines when payload is AXDP (PID 0xF0) AND the user is
        // part of the session – SessionCoordinator will deliver reassembled chat via
        // appendSessionChatLine. For monitored traffic (other stations' sessions),
        // we DO want to show the I-frame content in the console.
        let skipRawIFrameLine = shouldSkipIFrame(packet)
        if packet.frameType == .i {
            TxLog.debug(.axdp, "I-frame received at wire", [
                "from": packet.fromDisplay,
                "to": packet.toDisplay,
                "pid": packet.pid as Any,
                "infoLen": packet.info.count,
                "hasMagic": AXDP.hasMagic(packet.info),
                "prefixHex": packet.info.prefix(8).map { String(format: "%02X", $0) }.joined()
            ])
        }

        if !skipRawIFrameLine, let text = packet.infoText {
            // Extract via path as array of callsign strings
            let viaPath = Packet.normalizedViaItems(from: packet.via)

            // Check for duplicate (same content via different path)
            var isDuplicate = false
            let signature = computeContentSignature(from: packet.fromDisplay, to: packet.toDisplay, text: text)
            if isDuplicateConsoleLine(signature: signature, timestamp: packet.timestamp, viaPath: viaPath) {
                isDuplicate = true
            }
            // Track this signature for future duplicate detection
            recordConsoleLineSignature(signature: signature, timestamp: packet.timestamp, viaPath: viaPath)

            let line = ConsoleLine.packet(
                from: packet.fromDisplay,
                to: packet.toDisplay,
                text: text,
                timestamp: packet.timestamp,
                via: viaPath,
                isDuplicate: isDuplicate
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
            let viaPath = Packet.normalizedViaItems(from: packet.via).joined(separator: ",")
            print("[NETROM] observe #\(netRomObserveCount): \(fromDisplay) → \(toDisplay) via=[\(viaPath)]")
        }
        #endif
    }

    /// Detect and store AXDP capabilities from packet payload (UI frames).
    /// Capability discovery happens via PING/PONG message exchange.
    private func detectAXDPCapabilities(from packet: Packet) {
        guard let fromAddress = packet.from else { return }

        // Only check UI frames for AXDP - I-frames are handled by SessionCoordinator
        guard packet.frameType == .ui || packet.frameType == .i else { return }

        // Check for AXDP magic header
        guard AXDP.hasMagic(packet.info) else { return }

        // Decode AXDP message
        guard let (message, _) = AXDP.Message.decode(from: packet.info) else { return }

        // PING and PONG messages carry capability information
        if (message.type == .ping || message.type == .pong), let caps = message.capabilities {
            capabilityStore.store(caps, for: fromAddress.call, ssid: fromAddress.ssid)

            let kind = message.type == .ping ? "PING" : "PONG"
            TxLog.debug(.capability, "Detected AXDP capabilities from UI frame", [
                "peer": fromAddress.display,
                "type": kind,
                "protoMax": caps.protoMax,
                "features": caps.features.description
            ])
            debugAXDP("Capability \(kind) via UI/I frame", [
                "peer": fromAddress.display,
                "protoRange": "\(caps.protoMin)-\(caps.protoMax)",
                "features": caps.features.description,
                "infoLen": packet.info.count
            ])
        }
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

    func aggregateAnalytics(
        in timeframe: DateInterval,
        bucket: TimeBucket,
        calendar: Calendar,
        includeViaDigipeaters: Bool,
        histogramBinCount: Int,
        topLimit: Int
    ) async -> AnalyticsAggregationResult? {
        guard settings.persistHistory, let persistenceWorker else { return nil }
        let options = AnalyticsAggregator.Options(
            includeViaDigipeaters: includeViaDigipeaters,
            histogramBinCount: histogramBinCount,
            topLimit: topLimit
        )
        do {
            return try await persistenceWorker.aggregateAnalytics(
                in: timeframe,
                bucket: bucket,
                calendar: calendar,
                options: options
            )
        } catch {
            SentryManager.shared.capturePersistenceFailure("aggregate analytics", error: error)
            return nil
        }
    }

    func loadPackets(in timeframe: DateInterval) async -> [Packet]? {
        guard settings.persistHistory, let persistenceWorker else { return nil }
        do {
            return try await persistenceWorker.loadPackets(in: timeframe)
        } catch {
            SentryManager.shared.capturePersistenceFailure("load packets in timeframe", error: error)
            return nil
        }
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
                SentryManager.shared.capturePersistenceFailure("loadRecent packets", error: error)
                SentryManager.shared.captureMessage(
                    "stations.initial_load.failed",
                    level: .error,
                    extra: ["reason": reason, "error": error.localizedDescription]
                )
            }
        }
    }

    private func applyLoadedPackets(_ loaded: [Packet], pinnedIDs: Set<Packet.ID>) {
        packets = loaded.sorted(by: PacketOrdering.shouldPrecede)
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
                SentryManager.shared.capturePersistenceFailure("loadRecent console", error: error)
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
                SentryManager.shared.capturePersistenceFailure("loadRecent raw", error: error)
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
                SentryManager.shared.capturePersistenceFailure("save/prune packet", error: error)
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
        let metadata = ConsoleEntryMetadata(from: line.from, to: line.to, via: line.via.isEmpty ? nil : line.via)
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
                SentryManager.shared.capturePersistenceFailure("append/prune console", error: error)
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
                SentryManager.shared.capturePersistenceFailure("append/prune raw", error: error)
            }
        }
    }

    private func persistPinned(id: Packet.ID, pinned: Bool) {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.setPinned(packetId: id, pinned: pinned)
            } catch {
                SentryManager.shared.capturePersistenceFailure("setPinned", error: error)
            }
        }
    }

    // MARK: - Connection Logic Suspension
    
    /// If true, automatic connection attempts triggered by settings changes are suspended.
    /// Used by the Settings UI to prevent link thrashing while the user is configuring parameters.
    var isConnectionLogicSuspended: Bool = false {
        didSet {
            if isConnectionLogicSuspended {
                // Capture current settings when panel opens
                suspendedConfigSnapshot = ConnectionConfigSnapshot(settings: settings)
                debugTrace("Connection logic suspended — snapshot captured")
            } else {
                // Compare snapshot to current settings on panel close
                let currentSnapshot = ConnectionConfigSnapshot(settings: settings)
                if currentSnapshot != suspendedConfigSnapshot {
                    debugTrace("Settings changed while suspended — reconnecting")
                    connectUsingSettings()
                } else {
                    debugTrace("Settings unchanged while suspended — skipping reconnect")
                }
                suspendedConfigSnapshot = nil
            }
        }
    }

    private func observeSettings() {
        // Transport changes
        settings.$transportType
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.isConnectionLogicSuspended {
                    self.connectUsingSettings()
                }
            }
            .store(in: &cancellables)

        settings.$serialDevicePath
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settings.isSerialTransport && !self.isConnectionLogicSuspended {
                    self.connectUsingSettings()
                }
            }
            .store(in: &cancellables)
            
        settings.$serialBaudRate
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settings.isSerialTransport && !self.isConnectionLogicSuspended {
                    self.connectUsingSettings()
                }
            }
            .store(in: &cancellables)

        settings.$blePeripheralUUID
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settings.isBLETransport && !self.isConnectionLogicSuspended {
                    self.connectUsingSettings()
                }
            }
            .store(in: &cancellables)

        settings.$host
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.settings.isSerialTransport && !self.settings.isBLETransport && !self.isConnectionLogicSuspended {
                    self.connectUsingSettings()
                }
            }
            .store(in: &cancellables)

        settings.$port
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.settings.isSerialTransport && !self.settings.isBLETransport && !self.isConnectionLogicSuspended {
                    self.connectUsingSettings()
                }
            }

            .store(in: &cancellables)

        // Retention settings
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

    /// Forward capability store changes to trigger view updates
    private func observeCapabilityStore() {
        capabilityStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
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
                SentryManager.shared.capturePersistenceFailure("prune packets", error: error)
            }
        }
    }

    private func prunePersistedConsole(limit: Int) {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.pruneConsole(retentionLimit: limit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("prune console", error: error)
            }
        }
    }

    private func prunePersistedRaw(limit: Int) {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.pruneRaw(retentionLimit: limit)
            } catch {
                SentryManager.shared.capturePersistenceFailure("prune raw", error: error)
            }
        }
    }

    private func clearPersistedConsole() {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.deleteAllConsole()
            } catch {
                SentryManager.shared.capturePersistenceFailure("deleteAll console", error: error)
            }
        }
    }

    private func clearPersistedRaw() {
        guard settings.persistHistory, let persistenceWorker else { return }
        Task {
            do {
                try await persistenceWorker.deleteAllRaw()
            } catch {
                SentryManager.shared.capturePersistenceFailure("deleteAll raw", error: error)
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

            // Always load raw data without per-entry decay.
            // The persistence layer's per-entry TTLs (30 min) are much shorter than
            // the UI's freshness TTLs (6+ hours), causing data to be dropped during load.
            // The UI already handles freshness filtering via the "Hide expired" toggle,
            // so we should load ALL persisted data and let the UI decide what to show.
            let now = Date()

            let neighbors = try persistence.loadNeighbors()
            let routes = try persistence.loadRoutes()
            let linkStats = try persistence.loadLinkStats(now: now)

            #if DEBUG
            print("[NETROM:STARTUP] Loaded raw data (no decay filtering):")
            print("[NETROM:STARTUP]   - Neighbors: \(neighbors.count)")
            print("[NETROM:STARTUP]   - Routes: \(routes.count)")
            print("[NETROM:STARTUP]   - Link stats: \(linkStats.count)")
            #endif

            // If all tables are empty, nothing to import
            if neighbors.isEmpty && routes.isEmpty && linkStats.isEmpty {
                #if DEBUG
                print("[NETROM:STARTUP] No persisted data found, starting fresh")
                #endif
                return
            }

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
            SentryManager.shared.capturePersistenceFailure("load netrom snapshot", error: error)
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

        // Gather state on MainActor before moving to background
        let neighbors = integration.currentNeighbors()
        let routes = integration.currentRoutes()
        let linkStats = integration.exportLinkStats()
        let lastPacketID = Int64(self.packets.count)

        #if DEBUG
        print("[NETROM:SAVE] Saving snapshot:")
        print("[NETROM:SAVE]   - Neighbors: \(neighbors.count)")
        print("[NETROM:SAVE]   - Routes: \(routes.count)")
        print("[NETROM:SAVE]   - LinkStats: \(linkStats.count)")
        print("[NETROM:SAVE]   - lastPacketID: \(lastPacketID)")
        #endif

        Task.detached(priority: .utility) {
            do {
                try persistence.saveSnapshot(
                    neighbors: neighbors,
                    routes: routes,
                    linkStats: linkStats,
                    lastPacketID: lastPacketID,
                    configHash: nil
                )

                #if DEBUG
                print("[NETROM:SAVE] ✓ Snapshot saved successfully")
                #endif
            } catch {
                #if DEBUG
                print("[NETROM:SAVE] ❌ Error saving snapshot: \(error)")
                #endif
                await MainActor.run {
                    SentryManager.shared.capturePersistenceFailure("save netrom snapshot", error: error)
                }
            }
        }
    }

    /// Start the periodic snapshot timer.
    /// Also triggers initial pruning after first interval to avoid init-time database lock.
    private func startNetRomSnapshotTimer() {
        netRomSnapshotTimer?.invalidate()
        netRomSnapshotTimer = Timer.scheduledTimer(
            withTimeInterval: NetRomSnapshotConfig.saveIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.saveNetRomSnapshot()
                // Prune old entries from persistence
                self.pruneOldNetRomEntries()
                // Purge stale routes and neighbors from in-memory integration
                self.netRomIntegration?.purgeStaleData(currentDate: Date())
                #if DEBUG
                print("[NETROM:ENGINE] Purged stale data at \(Date())")
                #endif
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

    // MARK: - NET/ROM Retention Management

    /// Prune old NET/ROM entries based on retention settings.
    /// This deletes entries older than the configured retention days.
    func pruneOldNetRomEntries() {
        guard let persistence = netRomPersistence else { return }

        let retentionDays = settings.routeRetentionDays

        Task.detached(priority: .utility) {
            do {
                let (neighbors, routes, linkStats) = try await MainActor.run {
                    try persistence.pruneOldEntries(retentionDays: retentionDays)
                }

                #if DEBUG
                await MainActor.run {
                    if neighbors > 0 || routes > 0 || linkStats > 0 {
                        print("[NETROM:PRUNE] Pruned old entries (retention: \(retentionDays) days)")
                        print("[NETROM:PRUNE]   - Neighbors deleted: \(neighbors)")
                        print("[NETROM:PRUNE]   - Routes deleted: \(routes)")
                        print("[NETROM:PRUNE]   - Link stats deleted: \(linkStats)")
                    }
                }
                #endif

                if neighbors > 0 || routes > 0 || linkStats > 0 {
                    await MainActor.run {
                        SentryManager.shared.addBreadcrumb(
                            category: "netrom.prune",
                            message: "Pruned old NET/ROM entries",
                            level: .info,
                            data: [
                                "retentionDays": retentionDays,
                                "neighborsDeleted": neighbors,
                                "routesDeleted": routes,
                                "linkStatsDeleted": linkStats
                            ]
                        )
                    }
                }
            } catch {
                #if DEBUG
                await MainActor.run {
                    print("[NETROM:PRUNE] ❌ Error pruning entries: \(error)")
                }
                #endif
                await MainActor.run {
                    SentryManager.shared.capturePersistenceFailure("prune netrom entries", error: error)
                }
            }
        }
    }

    /// Clear all NET/ROM data (neighbors, routes, link stats).
    /// This removes all persisted and in-memory NET/ROM state.
    func clearNetRomData() {
        guard let persistence = netRomPersistence,
              let integration = netRomIntegration else { return }

        // Clear in-memory state
        integration.reset()

        // Clear persisted state
        Task.detached(priority: .utility) {
            do {
                try await MainActor.run {
                    try persistence.clearAll()
                }

                #if DEBUG
                await MainActor.run {
                    print("[NETROM:CLEAR] ✓ All NET/ROM data cleared")
                }
                #endif

                await MainActor.run {
                    SentryManager.shared.addBreadcrumb(
                        category: "netrom.clear",
                        message: "Cleared all NET/ROM data",
                        level: .info,
                        data: nil
                    )
                }
            } catch {
                #if DEBUG
                await MainActor.run {
                    print("[NETROM:CLEAR] ❌ Error clearing data: \(error)")
                }
                #endif
                await MainActor.run {
                    SentryManager.shared.capturePersistenceFailure("clear netrom data", error: error)
                }
            }
        }
    }

    /// Get current counts of NET/ROM entries.
    func getNetRomCounts() -> (neighbors: Int, routes: Int, linkStats: Int)? {
        guard let persistence = netRomPersistence else { return nil }
        return try? persistence.getCounts()
    }

    // MARK: - Debug: Full Rebuild from Packets

    #if DEBUG
    /// Rebuild all NET/ROM routing data from scratch by replaying all packets.
    /// This replays every packet in the database through the NET/ROM integration.
    /// The operation is guarded to avoid destructive wipes when no packets are available.
    ///
    /// - Parameter progress: Optional callback for progress updates (0.0-1.0)
    /// - Returns: A summary of the rebuild results
    func debugRebuildNetRomFromPackets(progress: ((Double) -> Void)? = nil) async -> DebugRebuildResult {
        guard let persistence = netRomPersistence,
              let integration = netRomIntegration,
              let packetStore = packetStore as? SQLitePacketStore else {
            return DebugRebuildResult(
                success: false,
                packetsProcessed: 0,
                neighborsFound: 0,
                routesFound: 0,
                linkStatsFound: 0,
                errorMessage: "Missing persistence, integration, or packet store"
            )
        }

        print("[DEBUG:REBUILD] Starting full NET/ROM rebuild from packets...")

        // Step 1: Build replay set BEFORE mutating in-memory/persisted NET/ROM state.
        // Prefer persisted packets, but include current in-memory packets that may not yet
        // have been flushed to disk (or use in-memory entirely when persistence is empty).
        let packetRecords: [PacketRecord]
        do {
            packetRecords = try packetStore.loadAllChronological()
            print("[DEBUG:REBUILD] ✓ Loaded \(packetRecords.count) packets from database")
        } catch {
            return DebugRebuildResult(
                success: false,
                packetsProcessed: 0,
                neighborsFound: 0,
                routesFound: 0,
                linkStatsFound: 0,
                errorMessage: "Failed to load packets: \(error.localizedDescription)"
            )
        }

        let livePacketsSnapshot = packets
        var replayPackets = packetRecords.map { $0.toPacket() }

        if replayPackets.isEmpty {
            replayPackets = livePacketsSnapshot.sorted(by: PacketOrdering.shouldPrecede)
            print("[DEBUG:REBUILD] Using \(replayPackets.count) in-memory packets for rebuild")
        } else {
            let persistedIDs = Set(replayPackets.map(\.id))
            let unsavedLive = livePacketsSnapshot.filter { !persistedIDs.contains($0.id) }
            if !unsavedLive.isEmpty {
                replayPackets.append(contentsOf: unsavedLive)
                replayPackets.sort(by: PacketOrdering.shouldPrecede)
                print("[DEBUG:REBUILD] Added \(unsavedLive.count) live packets not yet in persistence")
            }
        }

        guard !replayPackets.isEmpty else {
            return DebugRebuildResult(
                success: false,
                packetsProcessed: 0,
                neighborsFound: integration.currentNeighbors().count,
                routesFound: integration.currentRoutes().count,
                linkStatsFound: integration.exportLinkStats().count,
                errorMessage: "No packets available for replay (database and live memory are empty). Existing NET/ROM state was not modified."
            )
        }

        let previousNeighbors = integration.currentNeighbors()
        let previousRoutes = integration.currentRoutes()
        let previousLinkStats = integration.exportLinkStats()

        // Step 2: Clear persistence
        do {
            try persistence.clearAll()
            print("[DEBUG:REBUILD] ✓ Cleared persistence tables")
        } catch {
            return DebugRebuildResult(
                success: false,
                packetsProcessed: 0,
                neighborsFound: previousNeighbors.count,
                routesFound: previousRoutes.count,
                linkStatsFound: previousLinkStats.count,
                errorMessage: "Failed to clear persistence: \(error.localizedDescription)"
            )
        }

        // Step 3: Reset integration state
        integration.reset()
        print("[DEBUG:REBUILD] ✓ Reset integration state")

        // Step 4: Replay all packets through integration
        let total = replayPackets.count
        var processed = 0
        var latestPacketTimestamp = replayPackets[0].timestamp

        for packet in replayPackets {
            integration.observePacket(packet, timestamp: packet.timestamp, isDuplicate: false)
            latestPacketTimestamp = packet.timestamp

            processed += 1
            if processed % 100 == 0 || processed == total {
                let pct = Double(processed) / Double(max(1, total))
                progress?(pct)

                if processed % 500 == 0 {
                    print("[DEBUG:REBUILD] Processed \(processed)/\(total) packets (\(Int(pct * 100))%)")
                }
            }
        }

        print("[DEBUG:REBUILD] ✓ Replayed \(processed) packets")

        // Step 5: Purge stale entries relative to the replay horizon instead of wall-clock now.
        // This preserves snapshot semantics when replaying older captures.
        integration.purgeStaleData(currentDate: latestPacketTimestamp)
        print("[DEBUG:REBUILD] ✓ Purged stale entries (anchor=\(latestPacketTimestamp))")

        // Step 6: Get results
        let neighbors = integration.currentNeighbors()
        let routes = integration.currentRoutes()
        let linkStats = integration.exportLinkStats()

        print("[DEBUG:REBUILD] Results:")
        print("[DEBUG:REBUILD]   - Neighbors: \(neighbors.count)")
        print("[DEBUG:REBUILD]   - Routes: \(routes.count)")
        print("[DEBUG:REBUILD]   - Link Stats: \(linkStats.count)")

        let previousTotal = previousNeighbors.count + previousRoutes.count + previousLinkStats.count
        let rebuiltTotal = neighbors.count + routes.count + linkStats.count
        if previousTotal > 0 && rebuiltTotal == 0 {
            integration.importNeighbors(previousNeighbors)
            integration.importRoutes(previousRoutes)
            integration.importLinkStats(previousLinkStats)
            do {
                try persistence.saveSnapshot(
                    neighbors: previousNeighbors,
                    routes: previousRoutes,
                    linkStats: previousLinkStats,
                    lastPacketID: Int64(total),
                    configHash: nil
                )
            } catch {
                print("[DEBUG:REBUILD] ⚠️ Rollback snapshot save failed: \(error)")
            }
            return DebugRebuildResult(
                success: false,
                packetsProcessed: processed,
                neighborsFound: previousNeighbors.count,
                routesFound: previousRoutes.count,
                linkStatsFound: previousLinkStats.count,
                errorMessage: "Rebuild produced empty routing data; previous state was restored."
            )
        }

        // Step 7: Save to persistence
        do {
            try persistence.saveSnapshot(
                neighbors: neighbors,
                routes: routes,
                linkStats: linkStats,
                lastPacketID: Int64(total),
                configHash: nil
            )
            print("[DEBUG:REBUILD] ✓ Saved rebuilt state to persistence")
        } catch {
            return DebugRebuildResult(
                success: false,
                packetsProcessed: processed,
                neighborsFound: neighbors.count,
                routesFound: routes.count,
                linkStatsFound: linkStats.count,
                errorMessage: "Failed to save persistence: \(error.localizedDescription)"
            )
        }

        print("[DEBUG:REBUILD] ✓ Rebuild complete!")

        return DebugRebuildResult(
            success: true,
            packetsProcessed: processed,
            neighborsFound: neighbors.count,
            routesFound: routes.count,
            linkStatsFound: linkStats.count,
            errorMessage: nil
        )
    }
    #endif
}

#if DEBUG
/// Result of a debug rebuild operation.
struct DebugRebuildResult {
    let success: Bool
    let packetsProcessed: Int
    let neighborsFound: Int
    let routesFound: Int
    let linkStatsFound: Int
    let errorMessage: String?
}
#endif

// MARK: - KISSLinkDelegate

extension PacketEngine: KISSLinkDelegate {
    func linkDidReceive(_ data: Data) {
        handleIncomingData(data)
    }

    func linkDidChangeState(_ state: KISSLinkState) {
        let newStatus = ConnectionStatus(linkState: state)
        let endpoint = link?.endpointDescription ?? "unknown"
        LinkDebugLog.shared.recordStateChange(
            from: previousLinkState.rawValue,
            to: state.rawValue,
            endpoint: endpoint)
        previousLinkState = state
        self.status = newStatus

        switch state {
        case .connected:
            let endpoint = link?.endpointDescription ?? "unknown"
            addSystemLine("Connected to \(endpoint)", category: .connection)
            eventLogger?.log(level: .info, category: .connection, message: "Connected to \(endpoint)", metadata: nil)
            SentryManager.shared.addBreadcrumb(category: "kiss.connection", message: "Connected", level: .info, data: nil)

        case .disconnected:
            addSystemLine("Disconnected", category: .connection)
            eventLogger?.log(level: .info, category: .connection, message: "Disconnected", metadata: nil)
            SentryManager.shared.addBreadcrumb(category: "kiss.connection", message: "Disconnected", level: .info, data: nil)

        case .failed:
            let endpoint = link?.endpointDescription ?? "unknown"
            addErrorLine("Connection to \(endpoint) failed", category: .connection)
            eventLogger?.log(level: .error, category: .connection, message: "Connection failed: \(endpoint)", metadata: nil)

        case .connecting:
            break
        }
    }

    func linkDidError(_ message: String) {
        lastError = message
        LinkDebugLog.shared.recordParseError(message: "Link error: \(message)")
        addErrorLine(message, category: .connection)
        eventLogger?.log(level: .error, category: .connection, message: message, metadata: nil)
    }
}

private struct ConsoleEntryMetadata: Codable {
    let from: String?
    let to: String?
    let via: [String]?

    var hasValues: Bool {
        from != nil || to != nil || (via != nil && !via!.isEmpty)
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
