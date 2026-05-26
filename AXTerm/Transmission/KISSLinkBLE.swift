//
//  KISSLinkBLE.swift
//  AXTerm
//
//  KISS transport over Bluetooth Low Energy.
//  Supports Mobilinkd TNC4 and other BLE KISS TNCs.
//

import Combine
import CoreBluetooth
import Foundation

// MARK: - BLE Configuration

/// Configuration for a BLE KISS TNC connection
struct BLEConfig: Equatable, Sendable {
    var peripheralUUID: String
    var peripheralName: String
    var autoReconnect: Bool
    var mobilinkdConfig: MobilinkdConfig?

    static let defaultAutoReconnect = true

    init(
        peripheralUUID: String,
        peripheralName: String = "",
        autoReconnect: Bool = Self.defaultAutoReconnect,
        mobilinkdConfig: MobilinkdConfig? = nil
    ) {
        self.peripheralUUID = peripheralUUID
        self.peripheralName = peripheralName
        self.autoReconnect = autoReconnect
        self.mobilinkdConfig = mobilinkdConfig
    }
}

// MARK: - BLE Service UUIDs

/// Well-known BLE serial service UUIDs used by KISS TNCs
enum BLEServiceUUIDs {
    /// Mobilinkd TNC4 Bluetooth LE service
    static let mobilinkd = CBUUID(string: "00000001-BA2A-46C9-AE49-01B0961F68BB")
    /// Nordic UART Service (NUS) - used by many BLE serial devices
    static let nordicUART = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Known TNC service UUIDs to scan for
    static let knownTNCServices: [CBUUID] = [mobilinkd, nordicUART]
}

/// Well-known BLE characteristic UUIDs
enum BLECharacteristicUUIDs {
    // Mobilinkd characteristics (TX/RX from peripheral's perspective) - legacy
    static let mobilinkdTX = CBUUID(string: "00000002-BA2A-46C9-AE49-01B0961F68BB")
    static let mobilinkdRX = CBUUID(string: "00000003-BA2A-46C9-AE49-01B0961F68BB")

    // Nordic UART characteristics (TX/RX from peripheral's perspective)
    static let nordicUARTTX = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nordicUARTRX = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    
}

// MARK: - BLE Discovered Device

/// A BLE peripheral discovered during scanning
struct BLEDiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let serviceUUIDs: [CBUUID]

    var displayName: String {
        name.isEmpty ? "Unknown (\(id.uuidString.prefix(8)))" : name
    }

    /// Whether this device advertises a known TNC service
    var isKnownTNC: Bool {
        !serviceUUIDs.isEmpty && serviceUUIDs.contains(where: { BLEServiceUUIDs.knownTNCServices.contains($0) })
    }

    static func == (lhs: BLEDiscoveredDevice, rhs: BLEDiscoveredDevice) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.rssi == rhs.rssi
    }
}

// MARK: - BLE Errors

nonisolated enum KISSBLEError: Error, LocalizedError {
    case bluetoothUnavailable(String)
    case peripheralNotFound(String)
    case serviceNotFound(String)
    case characteristicNotFound(String)
    case writeFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let reason):
            return "Bluetooth unavailable: \(reason)"
        case .peripheralNotFound(let uuid):
            return "BLE peripheral not found: \(uuid)"
        case .serviceNotFound(let uuid):
            return "BLE service not found: \(uuid)"
        case .characteristicNotFound(let uuid):
            return "BLE characteristic not found: \(uuid)"
        case .writeFailed(let reason):
            return "BLE write failed: \(reason)"
        case .notConnected:
            return "BLE not connected"
        }
    }
}

// MARK: - BLE Device Scanner

/// Scans for BLE peripherals advertising KISS TNC services.
/// Results are published via the `devices` property.
final class BLEDeviceScanner: NSObject, ObservableObject {
    @Published private(set) var devices: [BLEDiscoveredDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var bluetoothState: CBManagerState = .unknown

    /// When true, scan discovers all BLE peripherals (not just known TNC services)
    var showAllDevices = false

    private var centralManager: CBCentralManager?
    private var scanTimer: Timer?

    override init() {
        super.init()
    }

    func startScan(duration: TimeInterval = 10) {
        // Debounce scan requests if already running
        if isScanning { return }

        devices.removeAll()

        if centralManager == nil {
            centralManager = CBCentralManager(delegate: nil, queue: nil)
        }

        // Set delegate via helper
        let delegateHelper = ScannerDelegate(scanner: self)
        self._delegateHelper = delegateHelper
        centralManager?.delegate = delegateHelper

        // Mark scanning intent BEFORE checking state — if BT isn't ready yet,
        // handleStateUpdate will see isScanning==true and start scanning when poweredOn fires.
        isScanning = true

        // Start the scan timeout regardless of BT state so we don't hang forever
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopScan()
            }
        }

        guard centralManager?.state == .poweredOn else {
            bluetoothState = centralManager?.state ?? .unknown
            return
        }

        // Pass nil for services to discover ALL BLE peripherals,
        // or pass known TNC services to filter
        let serviceFilter: [CBUUID]? = showAllDevices ? nil : BLEServiceUUIDs.knownTNCServices
        centralManager?.scanForPeripherals(
            withServices: serviceFilter,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        guard isScanning else { return }
        centralManager?.stopScan()
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
    }

    fileprivate func handleStateUpdate(_ state: CBManagerState) {
        bluetoothState = state
        if state == .poweredOn, isScanning {
            let serviceFilter: [CBUUID]? = showAllDevices ? nil : BLEServiceUUIDs.knownTNCServices
            centralManager?.scanForPeripherals(
                withServices: serviceFilter,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        } else if state != .poweredOn {
            isScanning = false
        }
    }

    fileprivate func handleDiscoveredPeripheral(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let device = BLEDiscoveredDevice(
            id: peripheral.identifier,
            name: peripheral.name ?? "",
            rssi: rssi.intValue,
            serviceUUIDs: advertisedServices
        )

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            // Update RSSI for already-seen device
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    // Strong reference to delegate helper to prevent deallocation
    private var _delegateHelper: ScannerDelegate?

    /// NSObject delegate helper to bridge CBCentralManagerDelegate back to scanner
    private class ScannerDelegate: NSObject, CBCentralManagerDelegate {
        weak var scanner: BLEDeviceScanner?

        init(scanner: BLEDeviceScanner) {
            self.scanner = scanner
        }

        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            Task { @MainActor [weak self] in
                self?.scanner?.handleStateUpdate(central.state)
            }
        }

        func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
            Task { @MainActor [weak self] in
                self?.scanner?.handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
            }
        }
    }
}

// MARK: - KISSLinkBLE

/// KISS transport over Bluetooth Low Energy.
///
/// Connects to a BLE peripheral advertising a serial service (Mobilinkd, Nordic UART),
/// discovers TX/RX characteristics, and bridges data to/from the KISSLink delegate.
///
/// Thread-safety: NSLock + dedicated DispatchQueue, same pattern as KISSLinkSerial.
final class KISSLinkBLE: NSObject, KISSLink, @unchecked Sendable {

    // MARK: - Configuration

    private(set) var config: BLEConfig

    // MARK: - KISSLink State

    let lock = NSLock()
    private var _state: KISSLinkState = .disconnected

    var state: KISSLinkState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var endpointDescription: String {
        config.peripheralName.isEmpty
            ? "BLE \(config.peripheralUUID.prefix(8))"
            : "BLE \(config.peripheralName)"
    }

    weak var delegate: KISSLinkDelegate?

    // MARK: - CoreBluetooth State

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    var txCharacteristic: CBCharacteristic?  // Write to this (peripheral's RX)
    var rxCharacteristic: CBCharacteristic?  // Subscribe to this (peripheral's TX)
    private let bleQueue = DispatchQueue(label: "com.axterm.kisslink.ble")

    // MARK: - Reconnect State

    private var reconnectTimer: DispatchSourceTimer?
    private var reconnectAttempt = 0
    private static let maxReconnectDelay: TimeInterval = 30
    private static let baseReconnectDelay: TimeInterval = 1

    // MARK: - Battery Polling

    private var batteryPollTimer: DispatchSourceTimer?

    // MARK: - Watchdog State

    private var startupNoKISSRecoveryTimer: DispatchSourceTimer?
    private var startupNoAX25RecoveryTimer: DispatchSourceTimer?
    private var ongoingNoAX25RecoveryTimer: DispatchSourceTimer?
    private let startupReceptionGuard = MobilinkdStartupReceptionGuard()
    private var connectionOpenedAt: Date?
    private var ongoingNoAX25RecoveryAttempts = 0
    private static let startupNoKISSRecoveryDelay: TimeInterval = 30.0
    private static let startupNoAX25RecoveryDelay: TimeInterval = 90.0
    private static let ongoingNoAX25RecoveryDelay: TimeInterval = 180.0
    private static let ongoingNoAX25RecoveryInterval: TimeInterval = 180.0
    private static let maxOngoingNoAX25RecoveryAttempts = 3

    // MARK: - Stats

    var _totalBytesIn = 0
    var _totalBytesOut = 0

    var totalBytesIn: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalBytesIn
    }

    var totalBytesOut: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalBytesOut
    }

    // MARK: - Pending Write Queue (flow control for withoutResponse writes)

    /// Queued data waiting to send when canSendWriteWithoutResponse becomes true.
    private var pendingWriteData: Data?
    private var pendingWriteCompletion: ((Error?) -> Void)?

    // MARK: - KISS Init Guard

    /// Prevents calling sendKISSInit more than once per connection (service discovery fires per service).
    private var _kissInitDone = false

    /// True once a known TNC service (Mobilinkd, Nordic) has been assigned to txCharacteristic.
    /// Prevents later known-service discoveries from overriding, while still allowing the first
    /// known-service discovery to override a heuristic assignment from an unknown service.
    private var _txFromKnownService = false
    
    // MARK: - Service Discovery State
    
    /// Services pending characteristic discovery
    private var pendingServices: Set<CBUUID> = []
    
    /// All discovered services with their characteristics
    var discoveredServiceCharacteristics: [CBUUID: [CBCharacteristic]] = [:]
    
    /// Whether we're waiting for all service discoveries to complete
    private var waitingForAllServices = false

    // MARK: - Init

    init(config: BLEConfig) {
        self.config = config
        super.init()
    }

    deinit {
        // Tear down without delegate notifications or queue dispatches.
        // During deinit, `self` is partially deallocated — avoid any async
        // work or weak-self captures that could race.
        lock.lock()
        let timer = reconnectTimer
        reconnectTimer = nil
        let batTimer = batteryPollTimer
        batteryPollTimer = nil
        let periph = peripheral
        let cm = centralManager
        peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        centralManager = nil
        _state = .disconnected
        pendingWriteData = nil
        pendingWriteCompletion = nil
        _kissInitDone = false
        _txFromKnownService = false
        pendingServices.removeAll()
        discoveredServiceCharacteristics.removeAll()
        waitingForAllServices = false
        lock.unlock()

        timer?.cancel()
        batTimer?.cancel()

        // Cancel the BLE connection synchronously if possible.
        // CBCentralManager tolerates cancelPeripheralConnection from any thread.
        if let periph, let cm {
            cm.delegate = nil
            cm.cancelPeripheralConnection(periph)
        }
    }

    // MARK: - KISSLink Conformance

    func open() {
        bleQueue.async { [weak self] in
            self?.openInternal()
        }
    }

    func close() {
        bleQueue.async { [weak self] in
            self?.closeInternal(reason: "User initiated")
        }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        bleQueue.async { [weak self] in
            guard let self else {
                completion(KISSBLEError.notConnected)
                return
            }

            self.lock.lock()
            let currentState = self._state
            self.lock.unlock()

            guard currentState == .connected else {
                completion(KISSBLEError.notConnected)
                return
            }

            self.writeBLE(data, completion: completion)
        }
    }

    /// Write raw bytes to BLE, bypassing the .connected state check.
    /// Used only during KISS init (before .connected is set) to send config frames and RESET.
    /// MUST be called on bleQueue.
    private func writeBLE(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock()
        let txChar = txCharacteristic
        let periph = peripheral
        lock.unlock()

        guard let txChar, let periph else {
            completion(KISSBLEError.notConnected)
            return
        }

        // Prefer .withoutResponse for Mobilinkd TNC4 to avoid macOS BLE stack buffering delays.
        // On macOS, .withResponse writes can be delayed/buffered, preventing timely PTT activation.
        // Fall back to .withResponse only if .withoutResponse is not supported.
        let supportsWithResponse = txChar.properties.contains(.write)
        let supportsWithoutResponse = txChar.properties.contains(.writeWithoutResponse)
        
        let writeType: CBCharacteristicWriteType
        if supportsWithoutResponse {
            writeType = .withoutResponse
        } else if supportsWithResponse {
            writeType = .withResponse
        } else {
            // Default fallback if neither is explicitly flagged, though highly unusual.
            writeType = .withResponse
        }

        // Use write-type-specific MTU queried directly from the peripheral (not a cached value).
        // For .withResponse, CoreBluetooth returns up to 512 bytes (GATT Long Write support),
        // allowing a full KISS DATA frame (typically 25 bytes) in a single writeValue() call.
        // Splitting a KISS frame across multiple GATT Write Requests can cause the TNC4 firmware
        // to discard the partial frame since each write may be processed independently.
        // For .withoutResponse, bounded by ATT MTU - 3 (minimum 20 bytes).
        let effectiveMTU = periph.maximumWriteValueLength(for: writeType)

        let chunkCount = (data.count + effectiveMTU - 1) / effectiveMTU
        KISSLinkLog.info(
            endpointDescription,
            message: "BLE TX: \(data.count)B, MTU=\(effectiveMTU), type=\(writeType == .withResponse ? "withResp" : "noResp"), chunks=\(chunkCount), hasWrite=\(supportsWithResponse), hasWriteNR=\(supportsWithoutResponse), canSend=\(periph.canSendWriteWithoutResponse)"
        )

        var offset = 0
        while offset < data.count {
            let chunkEnd = min(offset + effectiveMTU, data.count)
            let chunk = data[offset..<chunkEnd]

            // For withoutResponse, check flow control. A false canSendWriteWithoutResponse means
            // the BLE TX buffer is full — the write will be silently dropped by CoreBluetooth.
            if writeType == .withoutResponse && !periph.canSendWriteWithoutResponse {
                // Store the remaining data; peripheral(_:isReadyToSendWriteWithoutResponse:) will
                // resume when the buffer has space.
                KISSLinkLog.error(
                    endpointDescription,
                    message: "BLE TX: buffer full at offset \(offset)/\(data.count) — queuing \(data.count - offset) remaining bytes"
                )
                lock.lock()
                pendingWriteData = data.subdata(in: offset..<data.count)
                pendingWriteCompletion = completion
                lock.unlock()
                // Bytes already written are counted below; pending bytes will be counted on resume.
                lock.lock()
                _totalBytesOut += offset
                lock.unlock()
                KISSLinkLog.bytesOut(endpointDescription, count: offset)
                return
            }

            periph.writeValue(Data(chunk), for: txChar, type: writeType)
            offset = chunkEnd
        }

        lock.lock()
        _totalBytesOut += data.count
        lock.unlock()
        KISSLinkLog.bytesOut(endpointDescription, count: data.count)
        completion(nil)
    }

    /// Resume a pending write that was deferred due to a full BLE TX buffer.
    /// MUST be called on bleQueue.
    private func resumePendingWrite() {
        lock.lock()
        let data = pendingWriteData
        let completion = pendingWriteCompletion
        pendingWriteData = nil
        pendingWriteCompletion = nil
        lock.unlock()

        guard let data, let completion else { return }
        KISSLinkLog.info(endpointDescription, message: "BLE TX: resuming deferred write (\(data.count) bytes)")
        writeBLE(data, completion: completion)
    }

    /// Update configuration. If connected, reconnects with new config.
    func updateConfig(_ newConfig: BLEConfig) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let wasConnected: Bool
            self.lock.lock()
            wasConnected = self._state == .connected
            self.lock.unlock()

            self.config = newConfig

            if wasConnected {
                self.closeInternal(reason: "Config changed")
                self.openInternal()
            }
        }
    }

    // MARK: - Private: Open

    private func openInternal() {
        lock.lock()
        let current = _state
        lock.unlock()

        guard current != .connecting && current != .connected else { return }

        setState(.connecting)
        KISSLinkLog.opened(endpointDescription)

        lock.lock()
        _totalBytesIn = 0
        _totalBytesOut = 0
        lock.unlock()

        // Create central manager on the BLE queue
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
        // Connection continues in centralManagerDidUpdateState
    }

    // MARK: - Private: Close

    private func closeInternal(reason: String) {
        cancelReconnectTimer()
        cancelBatteryPolling()
        cancelStartupRecoveryWatchdog()
        connectionOpenedAt = nil
        ongoingNoAX25RecoveryAttempts = 0

        lock.lock()
        let periph = peripheral
        let cm = centralManager
        peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        centralManager = nil
        let pendingCompletion = pendingWriteCompletion
        pendingWriteData = nil
        pendingWriteCompletion = nil
        _kissInitDone = false
        _txFromKnownService = false
        pendingServices.removeAll()
        discoveredServiceCharacteristics.removeAll()
        waitingForAllServices = false
        lock.unlock()

        // Fail any deferred write that was waiting for buffer space
        pendingCompletion?(KISSBLEError.notConnected)

        if let periph, let cm {
            cm.delegate = nil
            cm.cancelPeripheralConnection(periph)
        }

        setState(.disconnected)
        KISSLinkLog.closed(endpointDescription, reason: reason)
    }

    // MARK: - Private: Reconnect

    private func scheduleReconnectIfEnabled() {
        guard config.autoReconnect else { return }

        reconnectAttempt += 1
        let delay = min(
            Self.baseReconnectDelay * pow(2, Double(reconnectAttempt - 1)),
            Self.maxReconnectDelay
        )

        KISSLinkLog.reconnect(endpointDescription, attempt: reconnectAttempt)

        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.openInternal()
        }

        lock.lock()
        reconnectTimer?.cancel()
        reconnectTimer = timer
        lock.unlock()

        timer.resume()
    }

    private func cancelReconnectTimer() {
        lock.lock()
        let timer = reconnectTimer
        reconnectTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    // MARK: - Private: KISS Init

    /// Send KISS parameter frames and Mobilinkd-specific config after BLE connection.
    /// Same init sequence as the serial transport.
    private func sendKISSInit() {
        // TNC4 KISS Init Strategy — MINIMAL DISRUPTION:
        //
        // The TNC4 auto-starts its demodulator on BLE connect. The EEPROM holds
        // calibrated gain/twist/DC-offset from ADJUST_INPUT_LEVELS.
        //
        // We send ONLY the transmit timing parameters (TXDELAY, PERSISTENCE, SLOTTIME, TXTAIL)
        // to ensure proper TX operation. We do NOT send RESET or demodulator config commands
        // that would disrupt the already-running receiver.

        KISSLinkLog.info(endpointDescription, message: "Sending KISS transmit timing parameters")

        // Standard KISS parameters for reliable transmission
        // TXDELAY: 30 (300ms) - time to key PTT before data
        // PERSISTENCE: 63 (p=0.25) - CSMA persistence parameter
        // SLOTTIME: 10 (100ms) - CSMA slot time
        // TXTAIL: 5 (50ms) - time to hold PTT after last byte
        // FULLDUPLEX: 0 (half-duplex)
        
        let txDelay: UInt8 = 30      // 300ms
        let persistence: UInt8 = 63  // p=0.25
        let slotTime: UInt8 = 10     // 100ms
        let txTail: UInt8 = 5        // 50ms
        let fullDuplex: UInt8 = 0    // half-duplex
        
        var initFrames: [Data] = []
        
        // Build KISS parameter frames manually
        // KISS frame format: FEND | CMD | DATA | FEND
        // CMD byte: (port << 4) | command_type
        let fend: UInt8 = 0xC0
        let port: UInt8 = 0
        
        // TXDELAY (command 1)
        initFrames.append(Data([fend, (port << 4) | 1, txDelay, fend]))
        
        // PERSISTENCE (command 2)
        initFrames.append(Data([fend, (port << 4) | 2, persistence, fend]))
        
        // SLOTTIME (command 3)
        initFrames.append(Data([fend, (port << 4) | 3, slotTime, fend]))
        
        // TXTAIL (command 4)
        initFrames.append(Data([fend, (port << 4) | 4, txTail, fend]))
        
        // FULLDUPLEX (command 5)
        initFrames.append(Data([fend, (port << 4) | 5, fullDuplex, fend]))
        
        // Send all init frames sequentially
        sendInitFrames(initFrames, index: 0) { [weak self] error in
            guard let self else { return }
            
            if let error {
                KISSLinkLog.error(self.endpointDescription, message: "KISS init failed: \(error.localizedDescription)")
                self.setState(.failed)
                return
            }
            
            setState(.connected)
            KISSLinkLog.info(endpointDescription, message: "KISS init complete — link ready")

            startupReceptionGuard.resetForNewConnection()
            connectionOpenedAt = Date()
            ongoingNoAX25RecoveryAttempts = 0
            
            // Start battery polling if Mobilinkd config is present
            if let mobiConfig = self.config.mobilinkdConfig, mobiConfig.isBatteryMonitoringEnabled {
                self.startBatteryPolling()
            }
            
            self.scheduleStartupRecoveryWatchdogIfNeeded()
        }
    }
    
    /// Recursively send init frames with a small delay between each
    private func sendInitFrames(_ frames: [Data], index: Int, completion: @escaping (Error?) -> Void) {
        guard index < frames.count else {
            completion(nil)
            return
        }
        
        writeBLE(frames[index]) { [weak self] error in
            guard let self else {
                completion(KISSBLEError.notConnected)
                return
            }
            
            if let error {
                completion(error)
                return
            }
            
            // Small delay before next frame (50ms)
            self.bleQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.sendInitFrames(frames, index: index + 1, completion: completion)
            }
        }
    }

    private func startBatteryPolling() {
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + 5.0, repeating: 60.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let frame = MobilinkdTNC.pollBatteryLevel()
            self.send(Data(frame)) { _ in }
        }
        timer.resume()

        lock.lock()
        batteryPollTimer?.cancel()
        batteryPollTimer = timer
        lock.unlock()
    }

    private func cancelBatteryPolling() {
        lock.lock()
        let timer = batteryPollTimer
        batteryPollTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func scheduleStartupRecoveryWatchdogIfNeeded() {
        cancelStartupRecoveryWatchdog()

        guard config.mobilinkdConfig != nil else { return }

        let noKISSTimer = DispatchSource.makeTimerSource(queue: bleQueue)
        noKISSTimer.schedule(deadline: .now() + Self.startupNoKISSRecoveryDelay)
        noKISSTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.startupNoKISSRecoveryTimer = nil
            self.lock.unlock()
            self.handleStartupRecovery(
                trigger: .noInboundKISS,
                watchdogLabel: "Startup RX watchdog (no inbound KISS)"
            )
        }

        let noAX25Timer = DispatchSource.makeTimerSource(queue: bleQueue)
        noAX25Timer.schedule(deadline: .now() + Self.startupNoAX25RecoveryDelay)
        noAX25Timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.startupNoAX25RecoveryTimer = nil
            self.lock.unlock()
            self.handleStartupRecovery(
                trigger: .noInboundAX25,
                watchdogLabel: "Startup RX watchdog (no inbound AX.25)"
            )
        }

        let ongoingNoAX25Timer = DispatchSource.makeTimerSource(queue: bleQueue)
        ongoingNoAX25Timer.schedule(
            deadline: .now() + Self.ongoingNoAX25RecoveryDelay,
            repeating: Self.ongoingNoAX25RecoveryInterval
        )
        ongoingNoAX25Timer.setEventHandler { [weak self] in
            self?.handleOngoingNoAX25Recovery()
        }

        lock.lock()
        startupNoKISSRecoveryTimer = noKISSTimer
        startupNoAX25RecoveryTimer = noAX25Timer
        ongoingNoAX25RecoveryTimer = ongoingNoAX25Timer
        lock.unlock()

        noKISSTimer.resume()
        noAX25Timer.resume()
        ongoingNoAX25Timer.resume()
    }

    private func handleStartupRecovery(
        trigger: MobilinkdStartupReceptionGuard.RecoveryTrigger,
        watchdogLabel: String
    ) {
        lock.lock()
        let connected = _state == .connected
        lock.unlock()

        let shouldSendReset = startupReceptionGuard.shouldIssueRecoveryReset(
            isConnected: connected,
            isMobilinkd: config.mobilinkdConfig != nil,
            trigger: trigger
        )

        guard shouldSendReset else {
            KISSLinkLog.info(
                endpointDescription,
                message: "\(watchdogLabel) skipped (inboundKISS=\(startupReceptionGuard.hasSeenInboundKISSFrame), inboundAX25=\(startupReceptionGuard.hasSeenInboundAX25), resetSent=\(startupReceptionGuard.didIssueRecoveryReset))"
            )
            return
        }

        KISSLinkLog.info(
            endpointDescription,
            message: "\(watchdogLabel): sending one-shot demodulator RESET"
        )

        let resetFrame = Data(MobilinkdTNC.reset())
        send(resetFrame) { [weak self] error in
            guard let self, let error else { return }
            KISSLinkLog.error(
                self.endpointDescription,
                message: "\(watchdogLabel) RESET failed: \(error.localizedDescription)"
            )
        }
    }

    private func handleOngoingNoAX25Recovery() {
        lock.lock()
        let connected = _state == .connected
        lock.unlock()

        guard connected, config.mobilinkdConfig != nil else { return }

        if startupReceptionGuard.hasSeenInboundAX25 {
            cancelOngoingNoAX25Recovery()
            return
        }

        guard ongoingNoAX25RecoveryAttempts < Self.maxOngoingNoAX25RecoveryAttempts else {
            KISSLinkLog.info(
                endpointDescription,
                message: "Ongoing no-AX.25 recovery stopped after \(Self.maxOngoingNoAX25RecoveryAttempts) attempts"
            )
            cancelOngoingNoAX25Recovery()
            return
        }

        ongoingNoAX25RecoveryAttempts += 1
        let elapsedSeconds = Int(Date().timeIntervalSince(connectionOpenedAt ?? Date()))
        KISSLinkLog.info(
            endpointDescription,
            message: "No inbound AX.25 after \(elapsedSeconds)s — sending demodulator RESET attempt \(ongoingNoAX25RecoveryAttempts)/\(Self.maxOngoingNoAX25RecoveryAttempts)"
        )

        send(Data(MobilinkdTNC.reset())) { [weak self] error in
            guard let self, let error else { return }
            KISSLinkLog.error(
                self.endpointDescription,
                message: "Ongoing no-AX.25 RESET failed: \(error.localizedDescription)"
            )
        }
    }

    private func cancelOngoingNoAX25Recovery() {
        lock.lock()
        let timer = ongoingNoAX25RecoveryTimer
        ongoingNoAX25RecoveryTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func cancelStartupRecoveryWatchdog() {
        lock.lock()
        let noKISSTimer = startupNoKISSRecoveryTimer
        let noAX25Timer = startupNoAX25RecoveryTimer
        let ongoingNoAX25Timer = ongoingNoAX25RecoveryTimer
        startupNoKISSRecoveryTimer = nil
        startupNoAX25RecoveryTimer = nil
        ongoingNoAX25RecoveryTimer = nil
        lock.unlock()
        noKISSTimer?.cancel()
        noAX25Timer?.cancel()
        ongoingNoAX25Timer?.cancel()
    }

    // MARK: - Private: State Helpers

    private func setState(_ newState: KISSLinkState) {
        let old: KISSLinkState
        lock.lock()
        old = _state
        _state = newState
        lock.unlock()

        if old != newState {
            KISSLinkLog.stateChange(endpointDescription, from: old, to: newState)
            Task { @MainActor [weak self] in
                self?.delegate?.linkDidChangeState(newState)
            }
        }
    }

    private func notifyError(_ message: String) {
        KISSLinkLog.error(endpointDescription, message: message)
        Task { @MainActor [weak self] in
            self?.delegate?.linkDidError(message)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension KISSLinkBLE: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Try to connect to the configured peripheral
            if let uuid = UUID(uuidString: config.peripheralUUID) {
                let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
                if let target = peripherals.first {
                    lock.lock()
                    peripheral = target
                    lock.unlock()
                    target.delegate = self
                    central.connect(target, options: nil)
                } else {
                    // Peripheral not cached; scan for it (nil = all services)
                    central.scanForPeripherals(
                        withServices: nil,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                    )
                }
            } else {
                setState(.failed)
                notifyError("Invalid peripheral UUID: \(config.peripheralUUID)")
            }

        case .poweredOff:
            setState(.failed)
            notifyError("Bluetooth is powered off")
            scheduleReconnectIfEnabled()

        case .unauthorized:
            setState(.failed)
            notifyError("Bluetooth access not authorized. Check System Settings > Privacy & Security > Bluetooth.")

        case .unsupported:
            setState(.failed)
            notifyError("Bluetooth LE is not supported on this device")

        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Check if this is the peripheral we want
        if peripheral.identifier.uuidString == config.peripheralUUID {
            central.stopScan()
            lock.lock()
            self.peripheral = peripheral
            lock.unlock()
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Log both write-type MTUs for diagnostics.
        // NOTE: MTU exchange may not have completed yet at this point; writeBLE() queries
        // maximumWriteValueLength() at write time to always get the current negotiated value.
        let mtuNR = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let mtuWR = peripheral.maximumWriteValueLength(for: .withResponse)
        KISSLinkLog.info(endpointDescription, message: "BLE connected: MTU(withResp)=\(mtuWR) MTU(noResp)=\(mtuNR)")

        // Discover ALL services — the peripheral may use non-standard UUIDs
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "Unknown error"
        setState(.failed)
        notifyError("Failed to connect to BLE peripheral: \(message)")
        scheduleReconnectIfEnabled()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        txCharacteristic = nil
        rxCharacteristic = nil
        self.peripheral = nil
        lock.unlock()

        if error != nil {
            setState(.failed)
            notifyError("BLE peripheral disconnected unexpectedly")
            scheduleReconnectIfEnabled()
        } else {
            setState(.disconnected)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension KISSLinkBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            setState(.failed)
            notifyError("BLE service discovery failed: \(error.localizedDescription)")
            scheduleReconnectIfEnabled()
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            setState(.failed)
            notifyError("No BLE services found on peripheral")
            scheduleReconnectIfEnabled()
            return
        }

        // NEW STRATEGY: Wait for ALL service characteristic discoveries to complete
        // before selecting TX/RX characteristics. This prevents the race where
        // an unknown service (Microchip) is discovered first and triggers init
        // before the known service (Mobilinkd) is found.
        
        lock.lock()
        waitingForAllServices = true
        pendingServices.removeAll()
        discoveredServiceCharacteristics.removeAll()
        for service in services {
            pendingServices.insert(service.uuid)
        }
        lock.unlock()
        
        KISSLinkLog.info(endpointDescription, message: "BLE discovered \(services.count) services: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")

        // Discover characteristics for ALL services
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            setState(.failed)
            notifyError("BLE characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        // Store discovered characteristics for this service
        lock.lock()
        if let characteristics = service.characteristics {
            discoveredServiceCharacteristics[service.uuid] = characteristics
        }
        pendingServices.remove(service.uuid)
        let allServicesDiscovered = pendingServices.isEmpty && waitingForAllServices
        lock.unlock()

        var debugStr = "Svc \(service.uuid): "
        for c in service.characteristics ?? [] {
            debugStr += "[\(c.uuid) \(c.properties.rawValue)] "
        }
        KISSLinkLog.info(endpointDescription, message: "\n====== CHAR DUMP ======\n" + debugStr + "\n=======================\n")

        // Wait for all services to complete characteristic discovery
        guard allServicesDiscovered else {
            KISSLinkLog.info(endpointDescription, message: "Waiting for more service discoveries (pending: \(pendingServices.count))")
            return
        }
        
        KISSLinkLog.info(endpointDescription, message: "All services discovered, selecting best characteristics")
        
        // Now select the best TX/RX characteristics from all available services
        selectBestCharacteristics(peripheral: peripheral)
    }
    
    /// Select the best TX/RX characteristics from all discovered services.
    /// Prioritizes known TNC services (Mobilinkd, Nordic UART) over heuristic matches.
    private func selectBestCharacteristics(peripheral: CBPeripheral) {
        lock.lock()
        let allCharacteristics = discoveredServiceCharacteristics
        waitingForAllServices = false
        lock.unlock()
        
        var bestTX: (char: CBCharacteristic, priority: Int)?
        var bestRX: (char: CBCharacteristic, priority: Int)?
        
        // Priority levels:
        // 3 = Known service with explicit UUID match
        // 2 = Known service with heuristic match
        // 1 = Unknown service with heuristic match
        
        for (serviceUUID, characteristics) in allCharacteristics {
            let isKnownService = BLEServiceUUIDs.knownTNCServices.contains(serviceUUID)
            
            for char in characteristics {
                // Check for explicit UUID matches in known services
                switch char.uuid {
                case BLECharacteristicUUIDs.mobilinkdTX,
                     BLECharacteristicUUIDs.nordicUARTRX:
                    // These are TX (writable) from our perspective
                    if bestTX == nil || bestTX!.priority < 3 {
                        bestTX = (char, 3)
                        KISSLinkLog.info(endpointDescription, message: "Selected TX (priority 3): \(char.uuid) from service \(serviceUUID)")
                    }
                    
                case BLECharacteristicUUIDs.mobilinkdRX,
                     BLECharacteristicUUIDs.nordicUARTTX:
                    // These are RX (notifiable) from our perspective
                    if bestRX == nil || bestRX!.priority < 3 {
                        bestRX = (char, 3)
                        KISSLinkLog.info(endpointDescription, message: "Selected RX (priority 3): \(char.uuid) from service \(serviceUUID)")
                    }
                    
                default:
                    // Heuristic: writable = TX, notifiable = RX
                    let isWritable = char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)
                    let isNotifiable = char.properties.contains(.notify) || char.properties.contains(.indicate)
                    
                    let heuristicPriority = isKnownService ? 2 : 1
                    
                    if isWritable && (bestTX == nil || bestTX!.priority < heuristicPriority) {
                        bestTX = (char, heuristicPriority)
                        KISSLinkLog.info(endpointDescription, message: "Selected TX (priority \(heuristicPriority)): \(char.uuid) from service \(serviceUUID)")
                    }
                    
                    if isNotifiable && (bestRX == nil || bestRX!.priority < heuristicPriority) {
                        bestRX = (char, heuristicPriority)
                        KISSLinkLog.info(endpointDescription, message: "Selected RX (priority \(heuristicPriority)): \(char.uuid) from service \(serviceUUID)")
                    }
                }
            }
        }
        
        guard let tx = bestTX?.char, let rx = bestRX?.char else {
            setState(.failed)
            notifyError("No suitable TX/RX characteristics found")
            scheduleReconnectIfEnabled()
            return
        }
        
        lock.lock()
        txCharacteristic = tx
        rxCharacteristic = rx
        _txFromKnownService = bestTX!.priority == 3
        lock.unlock()
        
        KISSLinkLog.info(endpointDescription, message: "Final characteristic selection: TX=\(tx.uuid), RX=\(rx.uuid)")
        
        // Subscribe to RX notifications
        peripheral.setNotifyValue(true, for: rx)
        
        // Wait for notification subscription to complete before sending KISS init
        // (didUpdateNotificationStateFor will trigger init)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            KISSLinkLog.error(endpointDescription, message: "BLE RX error: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value, !data.isEmpty else { return }

        // Only process data from the active RX characteristic.
        lock.lock()
        let currentRx = rxCharacteristic
        lock.unlock()
        
        if let currentRx, characteristic.uuid != currentRx.uuid {
            // CRITICAL FIX: Log when we're filtering out data from a different characteristic
            // This makes reception stoppage immediately visible in logs
            KISSLinkLog.error(
                endpointDescription,
                message: "BLE RX: IGNORING \(data.count) bytes from unexpected characteristic \(characteristic.uuid) (expected: \(currentRx.uuid))"
            )
            return
        }

        lock.lock()
        _totalBytesIn += data.count
        lock.unlock()
        KISSLinkLog.bytesIn(endpointDescription, count: data.count)

        startupReceptionGuard.observeInboundChunk(data)
        if startupReceptionGuard.hasSeenInboundAX25 {
            cancelOngoingNoAX25Recovery()
        }

        Task { @MainActor [weak self] in
            self?.delegate?.linkDidReceive(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            KISSLinkLog.error(endpointDescription, message: "BLE TX error: \(error.localizedDescription)")
        } else {
            KISSLinkLog.info(endpointDescription, message: "BLE TX acknowledged (withResponse)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            KISSLinkLog.error(endpointDescription, message: "BLE RX subscription failed for \(characteristic.uuid): \(error.localizedDescription)")
            // Don't fail the connection here; the characteristic might still work
        } else {
            let state = characteristic.isNotifying ? "enabled" : "disabled"
            KISSLinkLog.info(endpointDescription, message: "BLE RX notifications \(state) for \(characteristic.uuid)")
        }
        
        // Check if this is our selected RX characteristic and notifications are enabled
        lock.lock()
        let rxChar = rxCharacteristic
        let txChar = txCharacteristic
        let shouldInit = !_kissInitDone && characteristic.uuid == rxChar?.uuid && characteristic.isNotifying
        if shouldInit { _kissInitDone = true }
        lock.unlock()
        
        guard shouldInit, txChar != nil, rxChar != nil else { return }
        
        // Both TX and RX are ready and RX subscription is confirmed — send KISS init
        reconnectAttempt = 0
        cancelReconnectTimer()
        sendKISSInit()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Buffer has space again — resume any write that was deferred due to flow control.
        bleQueue.async { [weak self] in
            self?.resumePendingWrite()
        }
    }
}
