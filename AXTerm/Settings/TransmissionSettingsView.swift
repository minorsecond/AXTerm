//
//  TransmissionSettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import SwiftUI

struct TransmissionSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @EnvironmentObject var router: SettingsRouter
    
    @State private var txAdaptiveSettings = TxAdaptiveSettings()
    
    // File transfer list logic
    @State private var newAllowCallsign = ""
    @State private var newDenyCallsign = ""

    var body: some View {
        Form {
            // Adaptive Transmission Section (Deep Link Target)
            PreferencesSection("Adaptive Transmission", id: .adaptiveTransmission) {
                Toggle("Enable Adaptive Transmission", isOn: Binding(
                    get: { settings.adaptiveTransmissionEnabled },
                    set: { newValue in
                        settings.adaptiveTransmissionEnabled = newValue
                        if let coordinator = SessionCoordinator.shared {
                            coordinator.adaptiveTransmissionEnabled = newValue
                            coordinator.syncSessionManagerConfigFromAdaptive()
                            if newValue { TxLog.adaptiveEnabled() } else { TxLog.adaptiveDisabled() }
                        }
                    }
                ))
                
                if settings.adaptiveTransmissionEnabled {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundStyle(.green)
                            Text("Learning from session and network")
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Text("Parameters update automatically based on link quality.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    
                    // Default Values Grid
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Default Values")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        adaptiveSettingRow(
                            title: "Packet Length",
                            setting: txAdaptiveSettings.paclen,
                            onToggle: {
                                txAdaptiveSettings.paclen.mode = txAdaptiveSettings.paclen.mode == .auto ? .manual : .auto
                            },
                            onValueChange: { txAdaptiveSettings.paclen.manualValue = $0 }
                        )

                        adaptiveSettingRow(
                            title: "Window Size (K)",
                            setting: txAdaptiveSettings.windowSize,
                            onToggle: {
                                txAdaptiveSettings.windowSize.mode = txAdaptiveSettings.windowSize.mode == .auto ? .manual : .auto
                                syncAdaptiveSettingsToSessionCoordinator()
                            },
                            onValueChange: {
                                txAdaptiveSettings.windowSize.manualValue = $0
                                syncAdaptiveSettingsToSessionCoordinator()
                            }
                        )

                        adaptiveSettingRow(
                            title: "Max Retries (N2)",
                            setting: txAdaptiveSettings.maxRetries,
                            onToggle: {
                                txAdaptiveSettings.maxRetries.mode = txAdaptiveSettings.maxRetries.mode == .auto ? .manual : .auto
                                syncAdaptiveSettingsToSessionCoordinator()
                            },
                            onValueChange: {
                                txAdaptiveSettings.maxRetries.manualValue = $0
                                syncAdaptiveSettingsToSessionCoordinator()
                            }
                        )
                    }
                    .padding(.vertical, 4)
                    
                    Divider()
                    
                    LabeledContent("Overrides") {
                        HStack {
                            Button("Reset Specific Station…") {
                                resetStationAlert()
                            }
                            
                            Button("Clear All Learned Data") {
                                if let coordinator = SessionCoordinator.shared {
                                    coordinator.clearAllLearned()
                                    txAdaptiveSettings = TxAdaptiveSettings()
                                    syncAdaptiveSettingsToSessionCoordinator()
                                }
                            }
                        }
                    }
                    .disabled(!settings.adaptiveTransmissionEnabled)
                }
            }

            PreferencesSection("AXDP Protocol", id: .axdpProtocol) {
                Toggle("Enable AXDP Extensions", isOn: $txAdaptiveSettings.axdpExtensionsEnabled)
                    .onChange(of: txAdaptiveSettings.axdpExtensionsEnabled) { _, _ in
                        syncAdaptiveSettingsToSessionCoordinator()
                    }

                if txAdaptiveSettings.axdpExtensionsEnabled {
                    Toggle("Auto-negotiate Capabilities", isOn: $txAdaptiveSettings.autoNegotiateCapabilities)
                        .onChange(of: txAdaptiveSettings.autoNegotiateCapabilities) { _, _ in
                            syncAdaptiveSettingsToSessionCoordinator()
                        }

                    Toggle("Enable Compression", isOn: $txAdaptiveSettings.compressionEnabled)
                        .onChange(of: txAdaptiveSettings.compressionEnabled) { _, _ in
                            syncAdaptiveSettingsToSessionCoordinator()
                        }

                    if txAdaptiveSettings.compressionEnabled {
                        Picker("Compression Algorithm", selection: $txAdaptiveSettings.compressionAlgorithm) {
                            Text("LZ4 (fast)").tag(AXDPCompression.Algorithm.lz4)
                            Text("Deflate (better ratio)").tag(AXDPCompression.Algorithm.deflate)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: txAdaptiveSettings.compressionAlgorithm) { _, _ in
                            syncAdaptiveSettingsToSessionCoordinator()
                        }
                    }
                    
                    Toggle("Show AXDP decode details in console", isOn: $txAdaptiveSettings.showAXDPDecodeDetails)
                         .onChange(of: txAdaptiveSettings.showAXDPDecodeDetails) { _, _ in
                             syncAdaptiveSettingsToSessionCoordinator()
                         }
                }

                Text("AXDP extensions provide compression, capability negotiation, and reliable transfers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PreferencesSection("File Transfers", id: .fileTransfer) {
                Text("Control which stations can send you files without prompting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                
                // Keep the existing custom list components for now, but wrapped natively
                // Or standardized?
                // Let's use the fileTransferList helper function, but styling might need tweak.
                // We'll reimplement it inline for cleaner code or use helper.
                
                VStack(alignment: .leading, spacing: 16) {
                    fileTransferList(
                        title: "Auto-Accept",
                        items: settings.allowedFileTransferCallsigns,
                        icon: "checkmark.circle.fill",
                        color: .green,
                        onAdd: addToAllowList,
                        onRemove: { settings.removeCallsignFromFileTransferAllowlist($0) }
                    )
                    
                    fileTransferList(
                        title: "Auto-Deny",
                        items: settings.deniedFileTransferCallsigns,
                        icon: "xmark.circle.fill",
                        color: .red,
                        onAdd: addToDenyList,
                        onRemove: { settings.removeCallsignFromFileTransferDenylist($0) }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            seedAdaptiveSettings()
        }
    }
    
    // MARK: - Helpers
    
    // ... Copying existing helpers (seedAdaptiveSettings, syncAdaptiveSettingsToSessionCoordinator) ...
    // Since we are overwriting the file structure, we need to ensure we include these.
    
    private func seedAdaptiveSettings() {
        txAdaptiveSettings.axdpExtensionsEnabled = settings.axdpExtensionsEnabled
        txAdaptiveSettings.autoNegotiateCapabilities = settings.axdpAutoNegotiateCapabilities
        txAdaptiveSettings.compressionEnabled = settings.axdpCompressionEnabled
        if let algo = AXDPCompression.Algorithm(rawValue: settings.axdpCompressionAlgorithmRaw) {
            txAdaptiveSettings.compressionAlgorithm = algo
        }
        txAdaptiveSettings.maxDecompressedPayload = UInt32(settings.axdpMaxDecompressedPayload)
        txAdaptiveSettings.showAXDPDecodeDetails = settings.axdpShowDecodeDetails

        syncAdaptiveSettingsToSessionCoordinator()
        if let coordinator = SessionCoordinator.shared {
            coordinator.adaptiveTransmissionEnabled = settings.adaptiveTransmissionEnabled
            coordinator.syncSessionManagerConfigFromAdaptive()
        }
    }
    
    private func syncAdaptiveSettingsToSessionCoordinator() {
        guard let coordinator = SessionCoordinator.shared else { return }
        
        settings.axdpExtensionsEnabled = txAdaptiveSettings.axdpExtensionsEnabled
        settings.axdpAutoNegotiateCapabilities = txAdaptiveSettings.autoNegotiateCapabilities
        settings.axdpCompressionEnabled = txAdaptiveSettings.compressionEnabled
        settings.axdpCompressionAlgorithmRaw = txAdaptiveSettings.compressionAlgorithm.rawValue
        settings.axdpMaxDecompressedPayload = Int(txAdaptiveSettings.maxDecompressedPayload)
        settings.axdpShowDecodeDetails = txAdaptiveSettings.showAXDPDecodeDetails

        var updatedSettings = coordinator.globalAdaptiveSettings
        updatedSettings.axdpExtensionsEnabled = txAdaptiveSettings.axdpExtensionsEnabled
        updatedSettings.autoNegotiateCapabilities = txAdaptiveSettings.autoNegotiateCapabilities
        updatedSettings.compressionEnabled = txAdaptiveSettings.compressionEnabled
        updatedSettings.compressionAlgorithm = txAdaptiveSettings.compressionAlgorithm
        updatedSettings.maxDecompressedPayload = txAdaptiveSettings.maxDecompressedPayload
        updatedSettings.showAXDPDecodeDetails = txAdaptiveSettings.showAXDPDecodeDetails
        updatedSettings.windowSize = txAdaptiveSettings.windowSize
        updatedSettings.maxRetries = txAdaptiveSettings.maxRetries
        updatedSettings.rtoMin = txAdaptiveSettings.rtoMin
        updatedSettings.rtoMax = txAdaptiveSettings.rtoMax
        coordinator.globalAdaptiveSettings = updatedSettings
        coordinator.syncSessionManagerConfigFromAdaptive()

        if txAdaptiveSettings.axdpExtensionsEnabled && txAdaptiveSettings.autoNegotiateCapabilities {
            coordinator.triggerCapabilityDiscoveryForAllConnected()
        }
    }
    
    private func resetStationAlert() {
        let alert = NSAlert()
        alert.messageText = "Reset Station Parameters"
        alert.informativeText = "Enter the callsign of the station to reset learned parameters for."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "N0CALL-1"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        
        if alert.runModal() == .alertFirstButtonReturn {
            let call = input.stringValue.trimmingCharacters(in: .whitespaces)
            if !call.isEmpty {
                SessionCoordinator.shared?.resetStationToDefault(callsign: call)
            }
        }
    }

    @ViewBuilder
    private func adaptiveSettingRow(
        title: String,
        setting: AdaptiveSetting<Int>,
        onToggle: @escaping () -> Void,
        onValueChange: @escaping (Int) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Picker("Mode", selection: Binding(
                    get: { setting.mode },
                    set: { _ in onToggle() }
                )) {
                    Text("Auto").tag(AdaptiveMode.auto)
                    Text("Manual").tag(AdaptiveMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .labelsHidden()
                
                if setting.mode == .auto {
                     Text("\(setting.currentAdaptive)")
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .frame(width: 50, alignment: .trailing)
                } else {
                     TextField("Value", value: Binding(
                         get: { setting.manualValue },
                         set: { onValueChange($0) }
                     ), format: .number)
                     .textFieldStyle(.roundedBorder)
                     .frame(width: 50)
                }
            }
        }
    }
    
    @ViewBuilder
    private func fileTransferList(
        title: String,
        items: [String],
        icon: String,
        color: Color,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 4)
            
            List {
                ForEach(items, id: \.self) { callsign in
                    HStack {
                        Image(systemName: icon)
                            .foregroundStyle(color)
                            .font(.caption)
                        Text(callsign).monospaced()
                        Spacer()
                        Button { onRemove(callsign) } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                
                if items.isEmpty {
                    Text("No stations")
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .frame(height: 100)
            .border(Color.gray.opacity(0.2))
        }
    }
    
    // Actions for add
    private func addToAllowList() {
        let alert = NSAlert()
        alert.messageText = "Add to Auto-Accept"
        alert.informativeText = "Enter callsign to always accept files from."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "N0CALL-7"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn {
            let call = input.stringValue
            if !call.isEmpty { settings.allowCallsignForFileTransfer(call) }
        }
    }
    private func addToDenyList() {
        let alert = NSAlert()
        alert.messageText = "Add to Auto-Deny"
        alert.informativeText = "Enter callsign to always deny files from."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "N0CALL-7"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn {
            let call = input.stringValue
            if !call.isEmpty { settings.denyCallsignForFileTransfer(call) }
        }
    }
}
