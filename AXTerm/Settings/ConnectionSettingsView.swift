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
    
    // State variables to prevent "Publishing changes during view updates" warnings
    @State private var inputLevelText: String = "Waiting for data..."
    @State private var inputLevelProgress: Double = 0.0
    @State private var inputLevelColor: Color = .gray
    @State private var batteryLevel: String = ""
    @State private var isAdjusting: Bool = false
    @State private var lastMeasurement: Date? = nil
    @State private var mobilinkdEnabled: Bool = false
    @State private var mobilinkdOutputGain: Double = 128.0
    @State private var mobilinkdInputGain: Double = 4.0
    
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
                    
                    // Always show the currently selected device first if it's not empty
                    if !viewModel.selectedSerialDevicePath.isEmpty {
                        let isInList = viewModel.serialDevices.contains { $0.path == viewModel.selectedSerialDevicePath }
                        if !isInList {
                            Text("\(viewModel.selectedSerialDevicePath.split(separator: "/").last ?? "") (Current Connection)")
                                .tag(viewModel.selectedSerialDevicePath)
                        }
                    }
                    
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
            
            if mobilinkdEnabled {
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
                            Text("\(Int(mobilinkdOutputGain))")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $viewModel.mobilinkdOutputGain, in: 0...255, step: 1)
                    }
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Text("RX Volume (Input Gain)")
                            Spacer()
                            Text("\(Int(mobilinkdInputGain))")
                                .foregroundStyle(.secondary)
                        }
                        // TNC4 Input Gain is typically 0-4 (attenuation steps?) or raw values?
                        // Firmware limits this. Range 0 (0dB) to 4 (+something dB) or similar.
                        // Safe range 0-15? Let's use 0-4 as previously determined safe default, but expand range slightly if needed.
                        // Actually, KissHardware.cpp shows input_gain is uint16_t, but comments say 0-4.
                        Slider(value: $viewModel.mobilinkdInputGain, in: 0...4, step: 1)
                        
                        Button {
                            viewModel.triggerAutoGain()
                        } label: {
                            if isAdjusting {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 12, height: 12)
                                    Text("Measuring...")
                                }
                            } else {
                                Text("Measure & Auto-Adjust Input Levels")
                            }
                        }
                        .disabled(isAdjusting)
                        .font(.caption)
                        .padding(.top, 4)
                        .help("Temporarily stops packet reception for ~5 seconds to measure and optimize input levels")
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Last Measured Input Level")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if isAdjusting {
                                    Text("Measuring...")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.orange)
                                } else {
                                    Text(inputLevelText)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(inputLevelColor)
                                }
                            }
                            
                            if let timestamp = lastMeasurement {
                                Text("Measured \(timestamp.formatted(.relative(presentation: .named)))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            
                            ProgressView(value: inputLevelProgress)
                                .tint(inputLevelColor)
                        }
                        .padding(.top, 4)
                    }
                    
                    if !batteryLevel.isEmpty {
                        Divider()
                        HStack {
                            Image(systemName: "battery.100")
                                .foregroundStyle(.green)
                            Text("Battery Level:")
                            Spacer()
                            Text(batteryLevel)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading)
            }
        }
        .onAppear {
            // Initialize @State variables from ViewModel on first render
            mobilinkdEnabled = viewModel.mobilinkdEnabled
            mobilinkdOutputGain = viewModel.mobilinkdOutputGain
            mobilinkdInputGain = viewModel.mobilinkdInputGain
            batteryLevel = viewModel.mobilinkdBatteryLevel
            isAdjusting = viewModel.isAdjustingInputLevels
            lastMeasurement = viewModel.lastInputLevelMeasurement
            
            if let level = viewModel.mobilinkdInputLevelState {
                let percentage = (Double(level.vpp) / 65535.0) * 100.0
                inputLevelText = String(format: "Vpp: %d (%.0f%%)", level.vpp, percentage)
                inputLevelProgress = Double(level.vpp) / 65535.0
                
                let per = Double(level.vpp) / 65535.0
                if per > 0.9 {
                    inputLevelColor = .red
                } else if per < 0.1 {
                    inputLevelColor = .yellow
                } else {
                    inputLevelColor = .green
                }
            }
        }
        .onChange(of: viewModel.mobilinkdInputLevelState) { oldValue, newLevel in
            // Update state asynchronously to prevent "Publishing changes during view updates"
            if let level = newLevel {
                let percentage = (Double(level.vpp) / 65535.0) * 100.0
                inputLevelText = String(format: "Vpp: %d (%.0f%%)", level.vpp, percentage)
                inputLevelProgress = Double(level.vpp) / 65535.0
                
                let per = Double(level.vpp) / 65535.0
                if per > 0.9 {
                    inputLevelColor = .red      // Clipping
                } else if per < 0.1 {
                    inputLevelColor = .yellow   // Too low
                } else {
                    inputLevelColor = .green    // Good
                }
            } else {
                inputLevelText = "Waiting for data..."
                inputLevelProgress = 0.0
                inputLevelColor = .gray
            }
        }
        .onChange(of: viewModel.mobilinkdBatteryLevel) { _, newValue in
            batteryLevel = newValue
        }
        .onChange(of: viewModel.isAdjustingInputLevels) { _, newValue in
            isAdjusting = newValue
        }
        .onChange(of: viewModel.lastInputLevelMeasurement) { _, newValue in
            lastMeasurement = newValue
        }
        .onChange(of: viewModel.mobilinkdEnabled) { _, newValue in
            mobilinkdEnabled = newValue
        }
        .onChange(of: viewModel.mobilinkdOutputGain) { _, newValue in
            mobilinkdOutputGain = newValue
        }
        .onChange(of: viewModel.mobilinkdInputGain) { _, newValue in
            mobilinkdInputGain = newValue
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
