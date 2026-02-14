import SwiftUI

struct ConnectionSettingsView: View {
    @StateObject private var viewModel: ConnectionTransportViewModel
    
    init(settings: AppSettingsStore, packetEngine: PacketEngine) {
        _viewModel = StateObject(wrappedValue: ConnectionTransportViewModel(settings: settings, packetEngine: packetEngine))
    }
    
    var body: some View {
        let transportBinding = Binding<TransportSelection>(
            get: { viewModel.selectedTransport },
            set: { viewModel.userDidChangeTransport($0) }
        )
        
        Form {
            Section {
                Picker("Transport", selection: transportBinding) {
                    ForEach(TransportSelection.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden() // Hide label for segmented control to save space/clean look
                
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        switch viewModel.selectedTransport {
                        case .network:
                            NetworkSettingsContent(viewModel: viewModel)
                        case .serial:
                            SerialSettingsContent(viewModel: viewModel)
                        case .ble:
                            BLESettingsContent(viewModel: viewModel)
                        }
                    }
                    .padding(4)
                } label: {
                    Text(viewModel.selectedTransport.rawValue)
                }
            } header: {
                Text("Connection")
            }
            
            Section {
                ConnectionStatusView(status: viewModel.connectionStatus)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.onAppear()
            viewModel.suspendAutoReconnect(true)
        }
        .onDisappear {
            viewModel.onDisappear()
            viewModel.suspendAutoReconnect(false)
        }
    }
}

// MARK: - Transports

struct NetworkSettingsContent: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel
    
    var body: some View {
        Grid(alignment: .leading, verticalSpacing: 10) {
            GridRow {
                Text("Host:")
                    .gridColumnAlignment(.trailing)
                TextField("Host", text: $viewModel.host)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            
            GridRow {
                Text("Port:")
                    .gridColumnAlignment(.trailing)
                TextField("Port", value: $viewModel.port, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 80)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SerialSettingsContent: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel
    
    var body: some View {
        let selectionBinding = Binding<String>(
            get: { viewModel.selectedSerialDevicePath },
            set: { viewModel.userDidChangeSerialDevice($0) }
        )
        
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Device:", selection: selectionBinding) {
                    Text("Select a device...").tag("")
                    Divider()
                    ForEach(viewModel.serialDevices) { device in
                        if !device.path.isEmpty {
                            if device.isAvailable {
                                Text(device.displayName).tag(device.path)
                            } else {
                                Text("\(device.displayName)  (Unavailable)").tag(device.path)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .labelsHidden()
                
                Button {
                    viewModel.refreshSerialPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Serial Ports")
            }
            
            // Show full path for selected device
            if !viewModel.selectedSerialDevicePath.isEmpty {
                Text(viewModel.selectedSerialDevicePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if let error = viewModel.userFriendlyError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text(error)
                            .fontWeight(.medium)
                        if let detail = viewModel.errorDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            
            Text("Includes USB serial and Bluetooth classic serial ports that appear as /dev/cu.* (e.g., Mobilinkd).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
            
            Toggle("Enable Mobilinkd TNC4 Mode", isOn: $viewModel.mobilinkdEnabled)
            
            if viewModel.mobilinkdEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Modem Type", selection: $viewModel.mobilinkdModemType) {
                        ForEach(MobilinkdTNC.ModemType.allCases) { type in
                            Text(type.description).tag(type)
                        }
                    }
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Text("TX Volume (Output Gain)")
                            Spacer()
                            Text("\(Int(viewModel.mobilinkdOutputGain))")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $viewModel.mobilinkdOutputGain, in: 0...255, step: 1)
                    }
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Text("RX Volume (Input Gain)")
                            Spacer()
                            Text("\(Int(viewModel.mobilinkdInputGain))")
                                .foregroundStyle(.secondary)
                        }
                        // TNC4 Input Gain is typically 0-4 (attenuation steps?) or raw values?
                        // Firmware limits this. Range 0 (0dB) to 4 (+something dB) or similar.
                        // Safe range 0-15? Let's use 0-4 as previously determined safe default, but expand range slightly if needed.
                        // Actually, KissHardware.cpp shows input_gain is uint16_t, but comments say 0-4.
                        Slider(value: $viewModel.mobilinkdInputGain, in: 0...4, step: 1)
                    }
                    
                    if !viewModel.mobilinkdBatteryLevel.isEmpty {
                        Divider()
                        HStack {
                            Image(systemName: "battery.100")
                                .foregroundStyle(.green)
                            Text("Battery Level:")
                            Spacer()
                            Text(viewModel.mobilinkdBatteryLevel)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading)
            }
        }
    }
}

struct BLESettingsContent: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel
    
    var body: some View {
        let selectionBinding = Binding<String>(
            get: { viewModel.selectedBLEPeripheralID },
            set: { viewModel.userDidChangeBLEPeripheral($0) }
        )
        
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Device:", selection: selectionBinding) {
                    Text("Select a device...").tag("")
                    Divider()
                    ForEach(viewModel.bleDevices) { device in
                        Text("\(device.displayName) (\(device.rssi) dBm)").tag(device.id.uuidString)
                    }
                }
                .labelsHidden()
                
                Button(viewModel.isScanningBLE ? "Scanning..." : "Scan") {
                    viewModel.toggleBLEScan()
                }
                .disabled(viewModel.isScanningBLE)
            }
            
            if viewModel.isScanningBLE {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            }
            
            if let error = viewModel.userFriendlyError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text(error)
                            .fontWeight(.medium)
                        if let detail = viewModel.errorDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            
            Text("Only for BLE-mode TNCs. Many TNCs use Bluetooth Classic (Serial) instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Status

struct ConnectionStatusView: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack {
            Image(systemName: statusIconName)
                .foregroundStyle(statusColor)
            
            VStack(alignment: .leading) {
                Text(statusText)
                    .font(.headline)
                
                if status == .failed {
                    Text("Check your settings and try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    private var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .failed: return "Connection Failed"
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
    
    private var statusIconName: String {
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .disconnected: return "xmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
