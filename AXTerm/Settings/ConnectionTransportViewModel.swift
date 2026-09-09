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

    /// What the picker offers. The sound modem needs a Mac's sound devices
    /// and serial ports; elsewhere its segment shows only for a profile
    /// that already is one, so the operator can see and change it.
    static func selectable(including current: TransportSelection) -> [TransportSelection] {
        #if os(macOS)
        return allCases
        #else
        return allCases.filter { $0 != .modem || current == .modem }
        #endif
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
    /// This radio's own link state, not the primary's — so a second radio's
    /// form tells the truth about itself.
    @Published private(set) var radioState: KISSLinkState = .disconnected
    /// Why the manager refused this radio's link, recorded the last time it
    /// reconciled. `radioUnavailableReason` prefers this, then falls back to
    /// a live check so an empty field warns before the operator even connects.
    @Published private(set) var managerUnavailableReason: String?

    /// Whether this radio's own link is up (what the tests need).
    var radioConnected: Bool { radioState == .connected }
    var radioConnectionStatus: ConnectionStatus { ConnectionStatus(linkState: radioState) }

    /// Why this radio has no link. Only the sound modem produces these
    /// reasons, so it is scoped to that transport — a Wi-Fi warning must
    /// never linger on the Network tab. The live check catches a missing
    /// field before the manager has even tried; the manager's own reason
    /// covers a genuine failure to open.
    var radioUnavailableReason: String? {
        guard selectedTransport == .modem, !radioConnected,
              let profile = settings.radio(radioID), profile.enabled else { return nil }
        return RadioManager.unsupportedReason(for: profile) ?? managerUnavailableReason
    }
    
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
    private let audioDiscovery = AudioDeviceDiscovery()
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

        if modemMode != profile.modemMode { modemMode = profile.modemMode }
        if audioInputDeviceUID != profile.audioInputDeviceUID { audioInputDeviceUID = profile.audioInputDeviceUID }
        if audioOutputDeviceUID != profile.audioOutputDeviceUID { audioOutputDeviceUID = profile.audioOutputDeviceUID }
        if audioInputChannel != profile.audioInputChannel { audioInputChannel = profile.audioInputChannel }
        if civSerialPath != profile.civSerialPath { civSerialPath = profile.civSerialPath }
        let hex = String(format: "%02X", profile.civAddress)
        if civAddressHex.uppercased() != hex { civAddressHex = hex }
        if pttMethod != profile.pttMethod { pttMethod = profile.pttMethod }
        if txDelayMs != profile.txDelayMs { txDelayMs = profile.txDelayMs }
        if txTailMs != profile.txTailMs { txTailMs = profile.txTailMs }
        if persistence != profile.persistence { persistence = profile.persistence }
        if slotTimeMs != profile.slotTimeMs { slotTimeMs = profile.slotTimeMs }
        if Int(txAudioLevel) != profile.txAudioLevel { txAudioLevel = Double(profile.txAudioLevel) }
        if followsRadioFrequency != profile.followsRadioFrequency { followsRadioFrequency = profile.followsRadioFrequency }
        if setsRadioModeOnConnect != profile.setsRadioModeOnConnect { setsRadioModeOnConnect = profile.setsRadioModeOnConnect }
        if maxTransmitSeconds != profile.maxTransmitSeconds { maxTransmitSeconds = profile.maxTransmitSeconds }
        if rigModel != profile.rigModel { rigModel = profile.rigModel }
        if modemRigLink != profile.modemRigLink { modemRigLink = profile.modemRigLink }
        if lanHost != profile.lanHost { lanHost = profile.lanHost }
        if lanControlPort != profile.lanControlPort { lanControlPort = profile.lanControlPort }
        if lanUsername != profile.lanUsername { lanUsername = profile.lanUsername }
        // Show "stored" only when this build can actually read the password.
        // The profile's flag remembers that one was set; a rebuild can leave
        // it saved but unlockable, and the form must not claim otherwise.
        let passwordReadable = RadioSecrets.hasLANPassword(for: radioID)
        if hasLANPassword != passwordReadable { hasLANPassword = passwordReadable }

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

        // This radio's own link state and why it might have none.
        packetEngine.radioManager.$radioStates
            .receive(on: RunLoop.main)
            .map { [radioID] in $0[radioID] ?? .disconnected }
            .removeDuplicates()
            .assign(to: &$radioState)
        packetEngine.radioManager.$unavailableReasons
            .receive(on: RunLoop.main)
            .map { [radioID] in $0[radioID] }
            .removeDuplicates()
            .assign(to: &$managerUnavailableReason)

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

        audioDiscovery.$devices
            .receive(on: RunLoop.main)
            .assign(to: &$audioDevices)

        // The modem's telemetry and the rig's status, this radio's only.
        packetEngine.radioManager.$modemTelemetry
            .receive(on: RunLoop.main)
            .map { [radioID] in $0[radioID] }
            .assign(to: &$modemTelemetry)
        packetEngine.radioManager.$rigStatus
            .receive(on: RunLoop.main)
            .map { [radioID] in $0[radioID] }
            .assign(to: &$rigStatus)
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
        } else if selectedTransport == .modem {
            Task { serialDiscovery.startScanning() }
            audioDiscovery.startObserving()
        } else if selectedTransport == .ble {
             // Don't auto-start BLE scan every time view appears,
             // only if we don't have a device selected or user requests it.
             // But for now, let's leave it manual via button.
        }
    }
    
    func onDisappear() {
        Task { serialDiscovery.stopScanning() }
        bleScanner.stopScan()
        audioDiscovery.stopObserving()
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

    /// Bring this radio's link up. Reconciles every enabled radio, which
    /// keeps links that are already up and opens the ones that are not — so
    /// a second radio connects without disturbing the first.
    func connectThisRadio() {
        packetEngine.connectUsingSettings()
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
            // The CI-V port is a serial device; the audio pair is the link.
            Task { serialDiscovery.startScanning() }
            bleScanner.stopScan()
            audioDiscovery.startObserving()
        }
        if selectedTransport != .modem { audioDiscovery.stopObserving() }
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

    var isModemTransport: Bool {
        settings.radio(radioID)?.kind == .modem
    }

    // MARK: - Sound modem

    @Published var modemMode: ModemMode = .afsk1200 {
        didSet { update { $0.modemMode = modemMode } }
    }
    @Published private(set) var audioInputDeviceUID: String = ""
    @Published private(set) var audioOutputDeviceUID: String = ""
    @Published var audioInputChannel: ModemInputChannel = .left {
        didSet { update { $0.audioInputChannel = audioInputChannel } }
    }
    @Published var civSerialPath: String = "" {
        didSet { update { $0.civSerialPath = civSerialPath } }
    }
    /// The radio's CI-V address as the operator types it: "A4".
    @Published var civAddressHex: String = "A4" {
        didSet {
            guard let address = UInt8(civAddressHex.trimmingCharacters(in: .whitespaces), radix: 16) else { return }
            update { $0.civAddress = address }
        }
    }
    @Published var pttMethod: ModemPTTMethod = .civ {
        didSet { update { $0.pttMethod = pttMethod } }
    }
    @Published var txDelayMs: Int = 300 {
        didSet { update { $0.txDelayMs = max(0, min(2000, txDelayMs)) } }
    }
    @Published var txTailMs: Int = 100 {
        didSet { update { $0.txTailMs = max(0, min(1000, txTailMs)) } }
    }
    @Published var persistence: Int = 63 {
        didSet { update { $0.persistence = max(0, min(255, persistence)) } }
    }
    @Published var slotTimeMs: Int = 100 {
        didSet { update { $0.slotTimeMs = max(10, min(1000, slotTimeMs)) } }
    }
    /// 0…100; the profile keeps it whole.
    @Published var txAudioLevel: Double = 85 {
        didSet { update { $0.txAudioLevel = Int(txAudioLevel.rounded()) } }
    }
    @Published var followsRadioFrequency: Bool = true {
        didSet { update { $0.followsRadioFrequency = followsRadioFrequency } }
    }
    @Published var setsRadioModeOnConnect: Bool = false {
        didSet { update { $0.setsRadioModeOnConnect = setsRadioModeOnConnect } }
    }
    @Published var maxTransmitSeconds: Int = 30 {
        didSet { update { $0.maxTransmitSeconds = max(3, min(120, maxTransmitSeconds)) } }
    }
    /// What the radio called itself, from the profile.
    @Published private(set) var rigModel: String = ""

    // MARK: Wi-Fi (Icom LAN)
    @Published var modemRigLink: ModemRigLink = .usb {
        didSet { update { $0.modemRigLink = modemRigLink } }
    }
    @Published var lanHost: String = "" {
        didSet { update { $0.lanHost = lanHost.trimmingCharacters(in: .whitespaces) } }
    }
    @Published var lanControlPort: Int = 50001 {
        didSet { update { $0.lanControlPort = lanControlPort } }
    }
    @Published var lanUsername: String = "" {
        didSet { update { $0.lanUsername = lanUsername.trimmingCharacters(in: .whitespaces) } }
    }
    /// Whether a Wi-Fi password is stored for this radio (in the Keychain).
    @Published private(set) var hasLANPassword: Bool = false

    /// Store the Wi-Fi password in the Keychain, or clear it with an empty
    /// string. The value never touches the profile or its JSON.
    func setLANPassword(_ password: String) {
        // Strip stray edge whitespace or a trailing newline — a password
        // pasted from a manager often carries one, and the radio would
        // reject it exactly like a wrong password, with nothing to see.
        let cleaned = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = RadioSecrets.setLANPassword(cleaned, for: radioID)
        hasLANPassword = stored
        update { $0.hasLANPassword = stored }
    }

    /// The Mac's sound devices, live.
    @Published private(set) var audioDevices: [ModemAudioDevice] = []
    /// The modem's levels, carrier and PTT, while it runs.
    @Published private(set) var modemTelemetry: ModemTelemetry?
    /// What the last receive audit found, worst first.
    @Published private(set) var receiveFindings: [RigReceiveAudit.Finding] = []
    /// The audit's own answer, shown beside the audit's own buttons. Sharing
    /// `modemActionMessage` put it in the Transmit section, rows away from the
    /// button that produced it, which reads as nothing having happened.
    @Published private(set) var receiveActionMessage: String?
    @Published private(set) var auditingReceive = false
    /// The radio's frequency and mode, while CI-V is up.
    @Published private(set) var rigStatus: RigStatus?
    /// The last answer to Identify, or the reason there was none.
    @Published private(set) var identifyResult: String?
    @Published private(set) var isIdentifying = false
    @Published private(set) var isSendingTestTone = false
    /// The Wi-Fi reachability test: whether it is running, and its verdict.
    @Published private(set) var isTestingLAN = false
    @Published private(set) var lanTestResult: String?
    /// What the last modem action had to say when it could not be done.
    @Published private(set) var modemActionMessage: String?

    var audioInputs: [ModemAudioDevice] { audioDevices.filter(\.hasInput) }
    var audioOutputs: [ModemAudioDevice] { audioDevices.filter(\.hasOutput) }

    /// The device pair changes the link key, so both halves go in one write.
    func userDidChangeAudioInput(_ uid: String) {
        let name = audioDevices.first { $0.uid == uid }?.name ?? ""
        audioInputDeviceUID = uid
        update { $0.audioInputDeviceUID = uid; $0.audioInputDeviceName = name }
    }

    func userDidChangeAudioOutput(_ uid: String) {
        let name = audioDevices.first { $0.uid == uid }?.name ?? ""
        audioOutputDeviceUID = uid
        update { $0.audioOutputDeviceUID = uid; $0.audioOutputDeviceName = name }
    }

    #if os(macOS)
    /// The modem radio's live link, if the manager has one up.
    private var modemLink: ModemRadioLink? {
        packetEngine.radioManager.session(for: radioID)?.link as? ModemRadioLink
    }
    #endif

    /// Ask the radio what it is. Uses the live link's CI-V port when the
    /// radio is connected; otherwise opens the port just for the question.
    func identifyRig() {
        guard !isIdentifying else { return }
        #if os(macOS)
        guard let config = settings.radio(radioID)?.modemConfig else { return }
        isIdentifying = true
        identifyResult = nil
        Task { [weak self] in
            defer { self?.isIdentifying = false }
            do {
                let answer: String
                if let link = self?.modemLink, link.state == .connected {
                    answer = try await link.identifyRadio()
                } else {
                    answer = try await ModemRadioLink.identifyRadio(config: config)
                }
                self?.identifyResult = answer
            } catch {
                self?.identifyResult = "No answer: \((error as? CIVError)?.message ?? String(describing: error))"
            }
        }
        #else
        identifyResult = "The sound modem needs a Mac."
        #endif
    }

    /// Prove the radio answers over Wi-Fi: log in, wait for it to name
    /// itself, then let go — without starting the modem or its audio. It
    /// reports the radio it reached, or why it could not.
    func testLANConnection() {
        #if os(macOS)
        guard !isTestingLAN else { return }
        if radioConnected {
            lanTestResult = "Already connected\(rigModel.isEmpty ? "." : " to \(rigModel).")"
            return
        }
        guard let config = settings.radio(radioID)?.modemConfig?.lanConfiguration,
              !config.host.isEmpty else {
            lanTestResult = "Enter the radio's address first."
            return
        }
        guard !config.username.isEmpty else {
            lanTestResult = "Enter the radio's username first."
            return
        }
        switch RadioSecrets.readLANPassword(for: radioID) {
        case .found: break
        case .absent:
            lanTestResult = "Enter the radio's password first."
            return
        case .unreadable(let status):
            lanTestResult = KeychainStore.ReadOutcome.unreadable(status).operatorAdvice
                ?? "The saved password could not be read \u{2014} re-enter it once."
            return
        }
        isTestingLAN = true
        lanTestResult = nil
        Task { [weak self] in
            let session = IcomLANSession(configuration: config)
            do {
                try await session.open()
                let name = session.radioName.isEmpty ? "the radio" : session.radioName
                session.close()
                await MainActor.run {
                    self?.lanTestResult = "Reached \(name)."
                    self?.isTestingLAN = false
                }
            } catch {
                session.close()
                let message = (error as? IcomLANError)?.message ?? error.localizedDescription
                await MainActor.run {
                    self?.lanTestResult = "No answer: \(message)"
                    self?.isTestingLAN = false
                }
            }
        }
        #else
        lanTestResult = "The sound modem needs a Mac."
        #endif
    }

    /// Two seconds of steady tone through the modem's PTT path, so the
    /// operator can set drive against the radio's ALC meter.
    func sendTestTone(seconds: Double = 2) {
        modemActionMessage = nil
        #if os(macOS)
        guard let link = modemLink, link.state == .connected else {
            modemActionMessage = "Connect the radio first."
            return
        }
        do {
            try link.sendTestTone(seconds: seconds)
            isSendingTestTone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1) { [weak self] in
                self?.isSendingTestTone = false
            }
        } catch {
            modemActionMessage = "Could not key the radio: \(error)"
        }
        #else
        modemActionMessage = "The sound modem needs a Mac."
        #endif
    }

    /// A UI frame to TEST from this radio's callsign, through the normal
    /// send path, so the other station's decoder can confirm the whole chain.
    @discardableResult
    func sendTestFrame() -> OutboundFrame? {
        modemActionMessage = nil
        guard let profile = settings.radio(radioID) else { return nil }
        let call = profile.resolvedCallsign(station: settings.myCallsign.uppercased())
        guard !call.isEmpty else {
            modemActionMessage = "Set a callsign first."
            return nil
        }
        let parsed = CallsignNormalizer.parse(call)
        let stamp = Date().formatted(date: .omitted, time: .standard)
        let frame = OutboundFrame(
            radio: radioID,
            destination: AX25Address(call: "TEST"),
            source: AX25Address(call: parsed.call, ssid: parsed.ssid),
            payload: Data("AXTerm sound modem test \(stamp)".utf8))
        packetEngine.send(frame: frame) { [weak self] result in
            if case .failure(let error) = result {
                self?.modemActionMessage = "Not sent: \(error.localizedDescription)"
            }
        }
        return frame
    }

    /// Push the modem's mode to the radio: FM-D or USB-D, DATA MOD USB, AF
    /// squelch open, USB SEND off. The view confirms first.
    /// Ask the radio why it might not be hearing anybody, and say what it
    /// answered. Read-only — nothing here changes a setting.
    func auditRadioReceive() {
        receiveActionMessage = nil
        #if os(macOS)
        guard let link = modemLink, link.state == .connected else {
            receiveActionMessage = "Connect the radio first."
            return
        }
        receiveFindings = []
        auditingReceive = true
        Task { [weak self] in
            let result = await link.auditReceive()
            self?.auditingReceive = false
            self?.receiveFindings = result.findings
            self?.receiveActionMessage = result.summary
        }
        #else
        receiveActionMessage = "A radio needs a Mac."
        #endif
    }

    /// Make the corrections the last audit found. Read the list first — this
    /// changes the operator's radio.
    func fixRadioReceive() {
        #if os(macOS)
        guard let link = modemLink, link.state == .connected else {
            receiveActionMessage = "Connect the radio first."
            return
        }
        let findings = receiveFindings
        auditingReceive = true
        Task { [weak self] in
            let done = await link.applyReceiveCorrections(findings)
            let after = await link.auditReceive()
            self?.auditingReceive = false
            self?.receiveFindings = after.findings
            self?.receiveActionMessage = done.isEmpty
                ? "Nothing here is ours to change."
                : "Changed: " + done.joined(separator: ", ") + ". " + after.summary
        }
        #endif
    }

    /// Drive the radio's audio output until the modem sees a usable level.
    func calibrateRadioLevel() {
        #if os(macOS)
        guard let link = modemLink, link.state == .connected else {
            receiveActionMessage = "Connect the radio first."
            return
        }
        auditingReceive = true
        Task { [weak self] in
            let outcome = await link.calibrateReceiveLevel()
            self?.auditingReceive = false
            switch outcome {
            case .alreadyRight(let peak):
                self?.receiveActionMessage = String(format: "Level is fine at %.0f dBFS.", peak)
            case .adjusted(let from, let to, let peak):
                self?.receiveActionMessage = String(
                    format: "Audio output %d \u{2192} %d; the modem now sees %.0f dBFS.", from, to, peak)
            case .controlDoesNothing:
                self?.receiveActionMessage = "That control does not feed the modem on this link \u{2014} "
                    + "the level was moved a long way and the audio did not follow. Set the level on the radio."
            case .nothingHeard:
                self?.receiveActionMessage = "Nothing was received while measuring. Try again when the channel is busy."
            case .unavailable(let why):
                self?.receiveActionMessage = why
            }
        }
        #endif
    }

    func configureRadioForPacket() {
        modemActionMessage = nil
        #if os(macOS)
        guard let link = modemLink, link.state == .connected else {
            modemActionMessage = "Connect the radio first."
            return
        }
        Task { [weak self] in
            do {
                try await link.configureRadioForPacket()
                self?.modemActionMessage = "Radio set for packet."
            } catch {
                self?.modemActionMessage = "The radio refused: \((error as? CIVError)?.message ?? String(describing: error))"
            }
        }
        #else
        modemActionMessage = "The sound modem needs a Mac."
        #endif
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
