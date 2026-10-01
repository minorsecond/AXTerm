import CoreBluetooth
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
            #if os(iOS)
            // Nothing that speaks KISS runs on this device, so localhost is
            // never the answer here, though it is the Mac's default.
            if NetworkSettingsContent.isLoopback(viewModel.host) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Direwolf can't run on this device. Enter the address of the computer that runs it, such as 192.168.1.20.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            #endif
        }
        .padding(.vertical, 4)
    }

    nonisolated static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
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

            if !viewModel.isScanningBLE, let notice = viewModel.bleScanNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

/// What the form says when a Bluetooth scan ends with nothing to show.
///
/// A scan that found nothing used to end in silence. On 2026-09-30 the
/// TNC4 did not show up because the Mobilinkd configuration app still held
/// its Bluetooth connection (a TNC stops advertising while connected), and
/// for a while after it was switched over from USB.
nonisolated enum BLEScanNotice {
    static let nothingFound = "No TNC found. If the Mobilinkd configuration app or another app is connected to the TNC, close it and scan again. A TNC that was just switched from USB may need a moment, or a power cycle."
    static let bluetoothOff = "Bluetooth is off. Turn it on and scan again."
    #if os(macOS)
    static let notAllowed = "AXTerm isn't allowed to use Bluetooth. Allow it in System Settings under Privacy & Security, then scan again."
    #else
    static let notAllowed = "AXTerm isn't allowed to use Bluetooth. Allow it in Settings under Privacy & Security, then scan again."
    #endif

    /// Nil when the scan found something, or when the radio's own TNC is
    /// connected: it has stopped advertising, and the picker already lists
    /// it as connected.
    static func afterScan(found: Int, bluetoothState: CBManagerState, thisRadioConnected: Bool) -> String? {
        switch bluetoothState {
        case .poweredOff: return bluetoothOff
        case .unauthorized: return notAllowed
        default: break
        }
        guard found == 0, !thisRadioConnected else { return nil }
        return nothingFound
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
