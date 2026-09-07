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
    case modem = "Sound Modem"
    
    var id: String { rawValue }

    /// What the picker offers. The sound modem appears once its form
    /// exists; a profile that already is one always shows its segment.
    static func selectable(including current: TransportSelection) -> [TransportSelection] {
        allCases.filter { $0 != .modem || current == .modem }
    }
}

/// The form behind one radio: every field of its profile as a published
/// value, the transport discovery it needs, and the link as the engine
/// reports it.
///
/// Writes go to the radio's `RadioProfile` in settings; the settings store
/// mirrors the primary radio's profile into the single-connection scalars the
/// engine still reads, so editing here still reconnects the TNC the way the
/// Connection pane always did.
@MainActor
final class ConnectionTransportViewModel: ObservableObject {
    private let settings: AppSettingsStore
    private let packetEngine: PacketEngine
    /// The radio this form edits.
    let radioID: RadioID

    /// Set while the profile is being copied into the published fields, so
    /// their didSets do not write the same values straight back.
    private var isApplyingProfile = false

    @Published var name: String = "" {
        didSet { update { $0.name = name } }
    }
    @Published var enabled: Bool = true {
        didSet { update { $0.enabled = enabled } }
    }
    /// The callsign this radio operates as; empty means the station callsign.
    @Published var callsign: String = "" {
        didSet { update { $0.callsign = callsign } }
    }
    /// Whether this is the radio the engine connects to.
    @Published private(set) var isPrimary: Bool = true
    /// What the TNC said it is — see PacketEngine.tncIdentity.
    @Published var tncIdentity: String?
    
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
                update { $0.serialDevicePath = selectedSerialDevicePath }
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
                    update { $0.blePeripheralUUID = selectedBLEPeripheralID }
                }
                
                // Also update name if found
                if let device = bleDevices.first(where: { $0.id.uuidString == selectedBLEPeripheralID }) {
                    update { $0.blePeripheralName = device.name }
                }
            }
        }
    }
    
    @Published var host: String = "" {
        didSet { update { $0.host = AppSettingsStore.sanitizeHost(host) } }
    }
    
    @Published var port: Int = 8001 {
        didSet { update { $0.port = AppSettingsStore.sanitizePort(port) } }
    }
    
    // MARK: - Error State
    @Published var userFriendlyError: String?
    @Published var errorDetail: String?
    
    // MARK: - Dependencies
    
    private let serialDiscovery = SerialPortDiscovery()
    private let bleScanner = BLEDeviceScanner()
    private var cancellables: Set<AnyCancellable> = []
    private var serialGraceTimer: Timer?
    
    func identifyTNC() { packetEngine.identifyTNC() }

    init(radioID: RadioID, settings: AppSettingsStore, packetEngine: PacketEngine) {
        self.settings = settings
        self.packetEngine = packetEngine
        self.radioID = radioID

        // A placeholder until the profile is applied below; the property
        // wrappers need a value before `self` can be used.
        self.selectedTransport = .network

        applyProfile(settings.radio(radioID) ?? RadioProfile(id: radioID, name: ""))
        setupSubscriptions()
    }

    /// The profile's transport kind as the picker names it.
    private static func selection(for kind: RadioTransportKind) -> TransportSelection {
        switch kind {
        case .tcp: .network
        case .serial: .serial
        case .ble: .ble
        case .modem: .modem
        }
    }

    /// Copies the profile into the published fields, touching only the ones
    /// that differ so SwiftUI is not told about changes that are not.
    private func applyProfile(_ profile: RadioProfile) {
        isApplyingProfile = true
        defer { isApplyingProfile = false }

        let transport = Self.selection(for: profile.kind)
        if selectedTransport != transport { selectedTransport = transport }
        if name != profile.name { name = profile.name }
        if enabled != profile.enabled { enabled = profile.enabled }
        if callsign != profile.callsign { callsign = profile.callsign }
        if selectedSerialDevicePath != profile.serialDevicePath { selectedSerialDevicePath = profile.serialDevicePath }

        // Only a valid UUID is worth showing as a selection.
        let persistedUUID = profile.blePeripheralUUID
        let bleID = (!persistedUUID.isEmpty && UUID(uuidString: persistedUUID) != nil) ? persistedUUID : ""
        if selectedBLEPeripheralID != bleID { selectedBLEPeripheralID = bleID }

        if host != profile.host { host = profile.host }
        if port != profile.port { port = profile.port }

        if mobilinkdEnabled != profile.mobilinkdEnabled { mobilinkdEnabled = profile.mobilinkdEnabled }
        let modem = MobilinkdTNC.ModemType(rawValue: UInt8(clamping: profile.mobilinkdModemType)) ?? .afsk1200
        if mobilinkdModemType != modem { mobilinkdModemType = modem }
        if mobilinkdInputGain != Double(profile.mobilinkdInputGain) { mobilinkdInputGain = Double(profile.mobilinkdInputGain) }
        if mobilinkdOutputGain != Double(profile.mobilinkdOutputGain) { mobilinkdOutputGain = Double(profile.mobilinkdOutputGain) }

        let primary = settings.primaryRadio?.id == radioID
        if isPrimary != primary { isPrimary = primary }
    }

    /// One write to the profile. Skipped while the profile is being read
    /// into the fields, which is the other direction.
    private func update(_ change: (inout RadioProfile) -> Void) {
        guard !isApplyingProfile else { return }
        settings.updateRadio(radioID, change)
    }
    
    private func setupSubscriptions() {
        // Follow the profile: the legacy scalars still have writers (the
        // engine's auto-gain, for one), and their changes arrive here through
        // the store's mirror.
        settings.$radios
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] radios in
                guard let self, let profile = radios.first(where: { $0.id == self.radioID }) else { return }
                self.applyProfile(profile)
            }
            .store(in: &cancellables)

        // Bind PacketEngine status & map errors
        packetEngine.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.connectionStatus = status
                self?.updateErrorMessage(for: status)
            }
            .store(in: &cancellables)
        
        // Bind Mobilinkd Battery Level
        packetEngine.$tncIdentity
            .receive(on: DispatchQueue.main)
            .assign(to: &$tncIdentity)

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

        // Bind Mobilinkd Input Level (to avoid direct access in View)
        packetEngine.$mobilinkdInputLevel
            .receive(on: RunLoop.main)
            .assign(to: &$mobilinkdInputLevelState)

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
            // Every property this closure touches is @MainActor-isolated, so hop onto the
            // main actor explicitly rather than relying on the timer's run loop happening
            // to be the main one. Reading and mutating them from the nonisolated Sendable
            // closure is a data race (and an error under the Swift 6 language mode).
            // The weak reference is read once, here, into a local: reading it
            // inside the Task means the concurrently-executing closure touches
            // the captured variable, which Swift 6 rejects. Capturing strongly
            // would be worse — the timer owns this closure and this object owns
            // the timer, so it would be a retain cycle rather than a fix.
            let model = self
            Task { @MainActor in
                guard let model, let missingSince = model.missingSerialDeviceDate else { return }
                guard Date().timeIntervalSince(missingSince) > 10 else { return }

                // Grace period expired
                model.selectedSerialDevicePath = ""
                model.stopSerialGraceTimer()
                model.missingSerialDeviceDate = nil
                // Refresh list to remove the unavailable item
                model.handleSerialDevicesUpdate(model.serialDiscovery.devices)
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
            Task { serialDiscovery.startScanning() }
        } else if selectedTransport == .ble {
             // Don't auto-start BLE scan every time view appears,
             // only if we don't have a device selected or user requests it.
             // But for now, let's leave it manual via button.
        }
    }
    
    func onDisappear() {
        Task { serialDiscovery.stopScanning() }
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
        Task { serialDiscovery.startScanning() }
    }

    func triggerAutoGain() {
        isAdjustingInputLevels = true
        lastInputLevelMeasurement = Date()
        packetEngine.sendAdjustInputLevels()
        
        // Reset the measuring state after 5 seconds (matching the RESET timing in PacketEngine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.isAdjustingInputLevels = false
        }
    }
    
    // MARK: - Auto-Reconnect Suspension
    
    private var isAutoReconnectSuspended = false
    
    func suspendAutoReconnect(_ suspend: Bool) {
        isAutoReconnectSuspended = suspend
        
        // Also suspend the PacketEngine's reaction to settings changes
        // This prevents the connection from restarting while the user is actively editing settings
        packetEngine.isConnectionLogicSuspended = suspend
    }
    
    // MARK: - Connecting

    /// Whether a connection attempt would do anything right now.
    var canConnect: Bool { Self.canConnect(from: connectionStatus) }

    /// Pure, so the button's states can be tested without standing up a
    /// `PacketEngine` and a real socket.
    ///
    /// `.failed` counts as connectable: a failed attempt is the case where
    /// the operator most wants to retry, and leaving the button saying
    /// "Disconnect" there would strand them.
    nonisolated static func canConnect(from status: ConnectionStatus) -> Bool {
        switch status {
        case .disconnected, .failed: true
        case .connecting, .connected: false
        }
    }

    /// Opens the link using whatever transport is currently configured.
    ///
    /// The suspension in place while this screen is on-screen only gates
    /// *settings-change-triggered* reconnects, so an explicit connect works
    /// straight through it. Lifting the suspension here would be actively
    /// wrong: doing so compares the settings snapshot taken on appear, and
    /// since editing the host or port is exactly what the operator just did,
    /// it fires a second connect that closes the link this one opened.
    func connect() {
        packetEngine.connectUsingSettings()
    }

    func disconnect() {
        packetEngine.disconnect(reason: "operator disconnected from Connection settings")
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
            Task { serialDiscovery.stopScanning() }
            bleScanner.stopScan()
            stopSerialGraceTimer()
            
        case .serial:
            Task { serialDiscovery.startScanning() }
            bleScanner.stopScan()
            
        case .ble:
            Task { serialDiscovery.stopScanning() }
            stopSerialGraceTimer()
            // BLE scan is manual or on-demand

        case .modem:
            // The CI-V port is a serial device; the audio devices come later.
            Task { serialDiscovery.startScanning() }
            bleScanner.stopScan()
        }
    }
    
    private func updateSettingsForTransport() {
        // If suspended, don't update settings yet (optional, if we want to defer write)
        // But usually we want immediate write, just not immediate reconnect chrun.
        // The packet engine observes these.
        
        // If we want to prevent churn, we can ask PacketEngine to pause monitoring?
        // Or we rely on the single-flight logic we added to KISSLinkSerial to mitigate thrashing.
        
        let kind: RadioTransportKind
        switch selectedTransport {
        case .network: kind = .tcp
        case .serial: kind = .serial
        case .ble: kind = .ble
        case .modem: kind = .modem
        }
        update {
            $0.kind = kind
            // Our own modem tunes both the link and itself.
            if kind == .modem {
                $0.capabilities = TNCCapabilities(mode: .kiss, supportsLinkTuning: true,
                                                  supportsModemTuning: true, supportsCustomCommands: false)
            }
        }
    }

    var isSerialTransport: Bool {
        settings.radio(radioID)?.kind == .serial
    }

    // MARK: - Mobilinkd Settings

    @Published var mobilinkdEnabled: Bool = false {
        didSet { update { $0.mobilinkdEnabled = mobilinkdEnabled } }
    }

    @Published var mobilinkdModemType: MobilinkdTNC.ModemType = .afsk1200 {
        didSet { update { $0.mobilinkdModemType = Int(mobilinkdModemType.rawValue) } }
    }

    @Published var mobilinkdInputGain: Double = 4.0 {
        didSet { update { $0.mobilinkdInputGain = Int(mobilinkdInputGain) } }
    }

    @Published var mobilinkdOutputGain: Double = 128.0 {
        didSet { update { $0.mobilinkdOutputGain = Int(mobilinkdOutputGain) } }
    }
    
    @Published var mobilinkdBatteryLevel: String = ""
    
    @Published var mobilinkdInputLevelState: MobilinkdInputLevel?
    
    /// Tracks whether an auto-adjust measurement is currently in progress
    @Published var isAdjustingInputLevels: Bool = false
    
    /// Timestamp of the last input level measurement
    @Published var lastInputLevelMeasurement: Date?

}
