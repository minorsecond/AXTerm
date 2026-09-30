import SwiftUI

// The per-transport halves of a radio's form. `RadioDetailView` composes
// them under a segmented picker; each binds to the same per-radio
// `ConnectionTransportViewModel`.

// MARK: - Transports

struct NetworkSettingsContent: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel
    
    var body: some View {
        Grid(alignment: .leading, verticalSpacing: 10) {
            GridRow {
                Text("Host")
                    .gridColumnAlignment(.trailing)
                TextField("Host", text: $viewModel.host)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    // Without a border these read as static labels and the
                    // operator cannot tell the host is editable. That is true
                    // on both platforms — inside this Grid the Mac does not
                    // supply one either. The keyboard hints are iOS-only, but
                    // they matter as much: autocapitalizing the first letter
                    // of a hostname, or offering letters for an IP, turns a
                    // working address into a failed connection.
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
            }
            
            GridRow {
                Text("Port")
                    .gridColumnAlignment(.trailing)
                TextField("Port", value: $viewModel.port, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
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
                Picker("Device", selection: selectionBinding) {
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
            
            Toggle("This is a Mobilinkd TNC", isOn: $viewModel.mobilinkdEnabled)
            Text("A serial port can't say what's on the other end, so a Mobilinkd connected this way needs this switch. Its settings then appear in the TNC4 section.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Picker("Device", selection: selectionBinding) {
                    Text("Select a device...").tag("")
                    Divider()
                    ForEach(BLEDevicePicker.rows(scanned: viewModel.bleDevices,
                                                 selectedID: viewModel.selectedBLEPeripheralID,
                                                 savedName: viewModel.savedBLEPeripheralName,
                                                 connected: viewModel.radioConnected)) { row in
                        Text(row.label).tag(row.id)
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

/// The rows of the Bluetooth device picker.
///
/// The scan only lists what has advertised since it started, and a TNC that
/// is already connected stops advertising, so the radio's own device was
/// often missing and the picker showed nothing selected. The saved device
/// always has a row, named as it was when chosen.
enum BLEDevicePicker {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
    }

    static func rows(scanned: [BLEDiscoveredDevice], selectedID: String,
                     savedName: String, connected: Bool) -> [Row] {
        var rows = scanned.map { Row(id: $0.id.uuidString, label: "\($0.displayName) (\($0.rssi) dBm)") }
        if !selectedID.isEmpty, !rows.contains(where: { $0.id == selectedID }) {
            let name = savedName.isEmpty ? selectedID : savedName
            rows.insert(Row(id: selectedID, label: connected ? "\(name) (connected)" : name), at: 0)
        }
        return rows
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
