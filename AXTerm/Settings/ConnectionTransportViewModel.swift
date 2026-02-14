//
//  ConnectionTransportViewModel.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/14/26.
//

import Combine
import Foundation
import SwiftUI

/// Transport selection enum for UI
enum TransportSelection: String, CaseIterable, Identifiable {
    case network = "Network"
    case serial = "Serial"
    case ble = "Bluetooth LE"
    
    var id: String { rawValue }
}

@MainActor
final class ConnectionTransportViewModel: ObservableObject {
    private let settings: AppSettingsStore
    private let packetEngine: PacketEngine
    
    // MARK: - State
    
    @Published var selectedTransport: TransportSelection {
        didSet {
            updateSettingsForTransport()
            handleTransportChange()
        }
    }
    
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    @Published var serialDevices: [SerialDevice] = []
    @Published var selectedSerialDevicePath: String = "" {
        didSet {
            if selectedTransport == .serial {
                settings.serialDevicePath = selectedSerialDevicePath
            }
        }
    }
    
    private var missingSerialDeviceDate: Date?
    
    // BLE Discovery
    @Published var bleDevices: [BLEDiscoveredDevice] = []
    @Published var isScanningBLE = false
    @Published var selectedBLEPeripheralID: String = "" {
        didSet {
            if selectedTransport == .ble {
                // Only persist valid UUIDs or empty string
                if selectedBLEPeripheralID.isEmpty || UUID(uuidString: selectedBLEPeripheralID) != nil {
                    settings.blePeripheralUUID = selectedBLEPeripheralID
                }
                
                // Also update name if found
                if let device = bleDevices.first(where: { $0.id.uuidString == selectedBLEPeripheralID }) {
                    settings.blePeripheralName = device.name
                }
            }
        }
    }
    
    @Published var host: String = "" {
        didSet { settings.host = host }
    }
    
    @Published var port: Int = 8001 {
        didSet { settings.port = port }
    }
    
    // MARK: - Error State
    @Published var userFriendlyError: String?
    @Published var errorDetail: String?
    
    // MARK: - Dependencies
    
    private let serialDiscovery = SerialPortDiscovery()
    private let bleScanner = BLEDeviceScanner()
    private var cancellables: Set<AnyCancellable> = []
    private var serialGraceTimer: Timer?
    
    init(settings: AppSettingsStore, packetEngine: PacketEngine) {
        self.settings = settings
        self.packetEngine = packetEngine
        
        // Initialize state from settings
        if settings.isSerialTransport {
            self.selectedTransport = .serial
        } else if settings.isBLETransport {
            self.selectedTransport = .ble
        } else {
            self.selectedTransport = .network
        }
        
        self.selectedSerialDevicePath = settings.serialDevicePath
        
        // Validate persisted BLE UUID
        let persistedUUID = settings.blePeripheralUUID
        if !persistedUUID.isEmpty, UUID(uuidString: persistedUUID) != nil {
            self.selectedBLEPeripheralID = persistedUUID
        } else {
            self.selectedBLEPeripheralID = ""
        }
        
        self.host = settings.host
        self.port = settings.port
        
        self.mobilinkdEnabled = settings.mobilinkdEnabled
        self.mobilinkdModemType = MobilinkdTNC.ModemType(rawValue: UInt8(settings.mobilinkdModemType)) ?? .afsk1200
        self.mobilinkdInputGain = Double(settings.mobilinkdInputGain)
        self.mobilinkdOutputGain = Double(settings.mobilinkdOutputGain)
        
        setupSubscriptions()
    }
    
    private func setupSubscriptions() {
        // Bind PacketEngine status & map errors
        packetEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.connectionStatus = status
                self?.updateErrorMessage(for: status)
            }
            .store(in: &cancellables)
        
        // Bind Mobilinkd Battery Level
        packetEngine.$mobilinkdBatteryLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                if let mv = level {
                    let volts = Double(mv) / 1000.0
                    self?.mobilinkdBatteryLevel = String(format: "%.2f V", volts)
                } else {
                    self?.mobilinkdBatteryLevel = ""
                }
            }
            .store(in: &cancellables)

        // Bind Serial Discovery with Grace Period Logic
        serialDiscovery.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] discovered in
                self?.handleSerialDevicesUpdate(discovered)
            }
            .store(in: &cancellables)
        
        // Bind BLE Scanner (deduplication happens in scanner or here)
        bleScanner.$devices
            .receive(on: RunLoop.main)
            .assign(to: &$bleDevices)
            
        bleScanner.$isScanning
            .receive(on: RunLoop.main)
            .assign(to: &$isScanningBLE)
    }
    
    private func handleSerialDevicesUpdate(_ discovered: [SerialDevice]) {
        // 1. If currently selected device is missing, keep it but mark unavailable
        // 2. If it reappears, mark available and clear grace timer
        
        var mergedList = discovered
        
        if !selectedSerialDevicePath.isEmpty {
            let isPresent = discovered.contains { $0.path == selectedSerialDevicePath }
            
            if !isPresent {
                // Device went missing
                if missingSerialDeviceDate == nil {
                    missingSerialDeviceDate = Date()
                    startSerialGraceTimer()
                }
                
                // Keep it in the list but marked unavailable
                let name = (selectedSerialDevicePath as NSString).lastPathComponent.replacingOccurrences(of: "cu.", with: "")
                var missingDevice = SerialDevice(id: selectedSerialDevicePath, path: selectedSerialDevicePath, name: name)
                missingDevice.isAvailable = false
                mergedList.append(missingDevice)
                
            } else {
                // Device is present
                missingSerialDeviceDate = nil
                stopSerialGraceTimer()
            }
        } else {
            missingSerialDeviceDate = nil
            stopSerialGraceTimer()
        }
        
        // Sort: Available first, then by name
        self.serialDevices = mergedList.sorted {
            if $0.isAvailable != $1.isAvailable {
                return $0.isAvailable // Available (true) first
            }
            return $0.name < $1.name
        }
    }
    
    private func startSerialGraceTimer() {
        guard serialGraceTimer == nil else { return }
        serialGraceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let missingSince = self.missingSerialDeviceDate else { return }
            
            if Date().timeIntervalSince(missingSince) > 10 {
                // Grace period expired
                self.selectedSerialDevicePath = ""
                self.stopSerialGraceTimer()
                self.missingSerialDeviceDate = nil
                // Refresh list to remove the unavailable item
                 Task { @MainActor in
                     self.handleSerialDevicesUpdate(self.serialDiscovery.devices)
                 }
            }
        }
    }
    
    private func stopSerialGraceTimer() {
        serialGraceTimer?.invalidate()
        serialGraceTimer = nil
    }
    
    private func updateErrorMessage(for status: ConnectionStatus) {
        if status == .failed {
            // Check PacketEngine.lastError if exposed, or infer from context
            // For now, we provide generic messages or user-friendly mappings
            // Note: PacketEngine doesn't strictly expose the raw error object in a public property easily,
            // assuming we might need to add that or just rely on status.
            // Let's assume generic failure for now unless we sniff the logs/sentry.
            // Ideally PacketEngine would publish the error.
            if selectedTransport == .serial {
                 if missingSerialDeviceDate != nil {
                     userFriendlyError = "Device disconnected."
                     errorDetail = "The selected serial device is no longer available."
                 } else {
                     userFriendlyError = "Connection failed."
                     errorDetail = "Check that the device is connected and not in use by another application."
                 }
            } else {
                userFriendlyError = "Connection failed."
                errorDetail = "Could not establish a connection to the host."
            }
        } else {
            userFriendlyError = nil
            errorDetail = nil
        }
    }
    
    func onAppear() {
        if selectedTransport == .serial {
            Task { await serialDiscovery.startScanning() }
        } else if selectedTransport == .ble {
             // Don't auto-start BLE scan every time view appears,
             // only if we don't have a device selected or user requests it.
             // But for now, let's leave it manual via button.
        }
    }
    
    func onDisappear() {
        Task { await serialDiscovery.stopScanning() }
        bleScanner.stopScan()
        stopSerialGraceTimer()
    }
    
    // MARK: - Actions
    
    func toggleBLEScan() {
        if isScanningBLE {
            bleScanner.stopScan()
        } else {
            bleScanner.startScan()
        }
    }
    
    func refreshSerialPorts() {
        Task { await serialDiscovery.startScanning() }
    }
    
    // MARK: - Auto-Reconnect Suspension
    
    private var isAutoReconnectSuspended = false
    
    func suspendAutoReconnect(_ suspend: Bool) {
        isAutoReconnectSuspended = suspend
        
        // Also suspend the PacketEngine's reaction to settings changes
        // This prevents the connection from restarting while the user is actively editing settings
        packetEngine.isConnectionLogicSuspended = suspend
    }
    
    // MARK: - Safe Selection Handling
    
    /// Called by UI when user changes transport selection.
    /// Ensures changes are dispatched asynchronously to avoid SwiftUI view update faults.
    func userDidChangeTransport(_ newValue: TransportSelection) {
        guard newValue != selectedTransport else { return }
        
        // Dispatch to next run loop to avoid "Publishing changes from within view updates"
        Task { @MainActor in
            self.selectedTransport = newValue
        }
    }
    
    func userDidChangeSerialDevice(_ newPath: String) {
        guard newPath != selectedSerialDevicePath else { return }
        
        Task { @MainActor in
            self.selectedSerialDevicePath = newPath
        }
    }
    
    func userDidChangeBLEPeripheral(_ newID: String) {
        guard newID != selectedBLEPeripheralID else { return }
        
        Task { @MainActor in
            self.selectedBLEPeripheralID = newID
        }
    }

    // MARK: - Logic
    
    private func handleTransportChange() {
        userFriendlyError = nil
        errorDetail = nil
        
        switch selectedTransport {
        case .network:
            Task { await serialDiscovery.stopScanning() }
            bleScanner.stopScan()
            stopSerialGraceTimer()
            
        case .serial:
            Task { await serialDiscovery.startScanning() }
            bleScanner.stopScan()
            
        case .ble:
            Task { await serialDiscovery.stopScanning() }
            stopSerialGraceTimer()
            // BLE scan is manual or on-demand
        }
    }
    
    private func updateSettingsForTransport() {
        // If suspended, don't update settings yet (optional, if we want to defer write)
        // But usually we want immediate write, just not immediate reconnect chrun.
        // The packet engine observes these.
        
        // If we want to prevent churn, we can ask PacketEngine to pause monitoring?
        // Or we rely on the single-flight logic we added to KISSLinkSerial to mitigate thrashing.
        
        switch selectedTransport {
        case .network:
            settings.transportType = "network"
        case .serial:
            settings.transportType = "serial"
        case .ble:
            settings.transportType = "ble"
        }
    }

    var isSerialTransport: Bool {
        settings.transportType == "serial"
    }

    // MARK: - Mobilinkd Settings

    @Published var mobilinkdEnabled: Bool = false {
        didSet { settings.mobilinkdEnabled = mobilinkdEnabled }
    }

    @Published var mobilinkdModemType: MobilinkdTNC.ModemType = .afsk1200 {
        didSet { settings.mobilinkdModemType = Int(mobilinkdModemType.rawValue) }
    }

    @Published var mobilinkdInputGain: Double = 4.0 {
        didSet { settings.mobilinkdInputGain = Int(mobilinkdInputGain) }
    }

    @Published var mobilinkdOutputGain: Double = 128.0 {
        didSet { settings.mobilinkdOutputGain = Int(mobilinkdOutputGain) }
    }
    
    @Published var mobilinkdBatteryLevel: String = ""
    
    // MARK: - Subscriptions
    
}
