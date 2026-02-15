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
    /// Mobilinkd TNC4 KISS service
    static let mobilinkd = CBUUID(string: "00000001-BA2A-46C9-AE49-01B0961F68BB")
    /// Nordic UART Service (NUS) - used by many BLE serial devices
    static let nordicUART = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Known TNC service UUIDs to scan for
    static let knownTNCServices: [CBUUID] = [mobilinkd, nordicUART]
}

/// Well-known BLE characteristic UUIDs
enum BLECharacteristicUUIDs {
    // Mobilinkd characteristics (TX/RX from peripheral's perspective)
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

    private let lock = NSLock()
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
    private var txCharacteristic: CBCharacteristic?  // Write to this (peripheral's RX)
    private var rxCharacteristic: CBCharacteristic?  // Subscribe to this (peripheral's TX)
    private let bleQueue = DispatchQueue(label: "com.axterm.kisslink.ble")

    // MARK: - Reconnect State

    private var reconnectTimer: DispatchSourceTimer?
    private var reconnectAttempt = 0
    private static let maxReconnectDelay: TimeInterval = 30
    private static let baseReconnectDelay: TimeInterval = 1

    // MARK: - Battery Polling

    private var batteryPollTimer: DispatchSourceTimer?

    // MARK: - Stats

    private var _totalBytesIn = 0
    private var _totalBytesOut = 0

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

    // MARK: - BLE MTU

    /// Maximum payload per BLE write. Updated after connection from peripheral's negotiated MTU.
    private var bleMTU: Int = 20  // BLE 4.0 default

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
            let txChar = self.txCharacteristic
            let periph = self.peripheral
            let mtu = self.bleMTU
            self.lock.unlock()

            guard currentState == .connected, let txChar, let periph else {
                completion(KISSBLEError.notConnected)
                return
            }

            // BLE has MTU limits; chunk data if needed
            let writeType: CBCharacteristicWriteType = txChar.properties.contains(.writeWithoutResponse)
                ? .withoutResponse
                : .withResponse

            var offset = 0
            while offset < data.count {
                let chunkEnd = min(offset + mtu, data.count)
                let chunk = data[offset..<chunkEnd]
                periph.writeValue(Data(chunk), for: txChar, type: writeType)
                offset = chunkEnd
            }

            self.lock.lock()
            self._totalBytesOut += data.count
            self.lock.unlock()
            KISSLinkLog.bytesOut(self.endpointDescription, count: data.count)
            completion(nil)
        }
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

        lock.lock()
        let periph = peripheral
        let cm = centralManager
        peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        centralManager = nil
        lock.unlock()

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
        var frames: [[UInt8]] = [
            // Duplex = 1 (Full) — ignore DCD, transmit immediately
            [0xC0, 0x05, 0x01, 0xC0],
            // Persistence = 255 (100%) — always transmit
            [0xC0, 0x02, 0xFF, 0xC0],
            // Slot Time = 0 — no delay between checks
            [0xC0, 0x03, 0x00, 0xC0],
            // TX Delay = 30 (300ms) — radio key-up time
            [0xC0, 0x01, 30, 0xC0],
        ]

        if let mobiConfig = config.mobilinkdConfig {
            KISSLinkLog.info(endpointDescription, message: "Applying Mobilinkd BLE Config: \(mobiConfig.modemType.description), Out=\(mobiConfig.outputGain), In=\(mobiConfig.inputGain)")
            frames.append(MobilinkdTNC.setModemType(mobiConfig.modemType))
            frames.append(MobilinkdTNC.setOutputGain(mobiConfig.outputGain))
            frames.append(MobilinkdTNC.setInputGain(mobiConfig.inputGain))
            // REMOVED: Reset demodulator.
            // This command triggers a telemetry flood on TNC4 which jams the connection.
            // frames.append(MobilinkdTNC.reset())
        } else {
            // Default gain config for unspecified Mobilinkd
            frames.append([0xC0, 0x06, 0x01, 0x00, 0x80, 0xC0])
            frames.append([0xC0, 0x06, 0x02, 0x00, 0x00, 0xC0])
            KISSLinkLog.info(endpointDescription, message: "Sending default BLE KISS init (Duplex=1, P=255, Slot=0)")
        }

        for frame in frames {
            let data = Data(frame)
            self.send(data) { error in
                if let error {
                    KISSLinkLog.error("BLE", message: "KISS init frame send failed: \(error.localizedDescription)")
                }
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

    // MARK: - Private: Characteristic Discovery Helpers

    /// Match discovered characteristics to TX/RX roles based on service UUID
    private func mapCharacteristics(for service: CBService) -> (tx: CBCharacteristic?, rx: CBCharacteristic?) {
        guard let characteristics = service.characteristics else { return (nil, nil) }

        var tx: CBCharacteristic?
        var rx: CBCharacteristic?

        for char in characteristics {
            switch char.uuid {
            // Mobilinkd: "TX" (00000002) has Write property — we write TO the TNC here
            case BLECharacteristicUUIDs.mobilinkdTX:
                tx = char
            // Mobilinkd: "RX" (00000003) has Notify property — we receive FROM the TNC here
            case BLECharacteristicUUIDs.mobilinkdRX:
                rx = char

            // Nordic UART: "RX" (6E400002) has Write property — we write TO the peripheral
            case BLECharacteristicUUIDs.nordicUARTRX:
                tx = char
            // Nordic UART: "TX" (6E400003) has Notify property — we receive FROM the peripheral
            case BLECharacteristicUUIDs.nordicUARTTX:
                rx = char

            default:
                // For unknown services, heuristic: writable = TX, notifiable = RX
                if tx == nil && (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)) {
                    tx = char
                }
                if rx == nil && (char.properties.contains(.notify) || char.properties.contains(.indicate)) {
                    rx = char
                }
            }
        }

        return (tx, rx)
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
        // Update MTU from negotiated value
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        lock.lock()
        bleMTU = max(mtu, 20)
        lock.unlock()

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

        let mapped = mapCharacteristics(for: service)

        lock.lock()
        let alreadyHaveTx = txCharacteristic != nil
        let alreadyHaveRx = rxCharacteristic != nil
        if mapped.tx != nil && !alreadyHaveTx {
            txCharacteristic = mapped.tx
        }
        if mapped.rx != nil && !alreadyHaveRx {
            rxCharacteristic = mapped.rx
        }
        let haveTx = txCharacteristic != nil
        let haveRx = rxCharacteristic != nil
        let rxChar = rxCharacteristic
        lock.unlock()

        // Subscribe to RX notifications if we have it
        if let rxChar, !alreadyHaveRx {
            peripheral.setNotifyValue(true, for: rxChar)
        }

        // If we have both characteristics, we're connected
        if haveTx && haveRx {
            setState(.connected)
            reconnectAttempt = 0
            cancelReconnectTimer()
            sendKISSInit()

            // Start battery polling if Mobilinkd config is present
            if let mobiConfig = config.mobilinkdConfig, mobiConfig.isBatteryMonitoringEnabled {
                startBatteryPolling()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            KISSLinkLog.error(endpointDescription, message: "BLE RX error: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value, !data.isEmpty else { return }

        lock.lock()
        _totalBytesIn += data.count
        lock.unlock()
        KISSLinkLog.bytesIn(endpointDescription, count: data.count)

        Task { @MainActor [weak self] in
            self?.delegate?.linkDidReceive(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            KISSLinkLog.error(endpointDescription, message: "BLE TX error: \(error.localizedDescription)")
        }
    }
}
