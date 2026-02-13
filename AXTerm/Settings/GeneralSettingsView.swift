//
//  GeneralSettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @EnvironmentObject var router: SettingsRouter

    @State private var launchAtLoginFeedback: String?
    @State private var showAllSerialDevices = false
    @AppStorage(AppSettingsStore.runInMenuBarKey) private var runInMenuBar = AppSettingsStore.defaultRunInMenuBar

    var body: some View {
        Form {
            PreferencesSection("Connection") {
                Picker("Transport", selection: $settings.transportType) {
                    Text("Network (TCP)").tag("network")
                    Text("Local USB Serial").tag("serial")
                }
                .pickerStyle(.segmented)

                if settings.transportType == "network" {
                    networkSettingsContent
                } else {
                    serialSettingsContent
                }

                Toggle("Connect automatically on launch", isOn: $settings.autoConnectOnLaunch)

                if shouldSuggestReconnect {
                    Text("Reconnect to apply changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            PreferencesSection("Identity") {
                CallsignField(title: "My Callsign", text: $settings.myCallsign)

                Text("Used to highlight your node in the graph and identify you in sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PreferencesSection("Display") {
                Toggle("Show day separators in Console", isOn: $settings.showConsoleDaySeparators)
                Toggle("Show day separators in Raw Data", isOn: $settings.showRawDaySeparators)
            }

            PreferencesSection("System") {
                Toggle("Show icon in Menu Bar", isOn: $runInMenuBar)

                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }

                if let feedback = launchAtLoginFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onTapGesture {
            // Clear focus when clicking background
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: - Network Settings

    @ViewBuilder
    private var networkSettingsContent: some View {
        TextField("Host", text: $settings.host)
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)

        NumericInput("Port", value: $settings.port, range: 1...65535)
    }

    // MARK: - Serial Settings

    @ViewBuilder
    private var serialSettingsContent: some View {
        Picker("Device", selection: $settings.serialDevicePath) {
            Text("Select a device…").tag("")

            ForEach(availableSerialDevices, id: \.self) { device in
                Text(serialDeviceLabel(device))
                    .tag(device)
            }
        }

        HStack {
            Toggle("Show all serial devices", isOn: $showAllSerialDevices)
                .controlSize(.small)

            Button("Refresh") {
                // Force SwiftUI to re-evaluate availableSerialDevices
                showAllSerialDevices.toggle()
                showAllSerialDevices.toggle()
            }
            .controlSize(.small)
        }

        Picker("Baud Rate", selection: $settings.serialBaudRate) {
            ForEach(AppSettingsStore.commonBaudRates, id: \.self) { rate in
                Text(formatBaudRate(rate)).tag(rate)
            }
        }

        Toggle("Auto-reconnect on disconnect", isOn: $settings.serialAutoReconnect)

        if !settings.serialDevicePath.isEmpty && !FileManager.default.fileExists(atPath: settings.serialDevicePath) {
            Label("Device not found. Connect the TNC and select it again.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Helpers

    private var availableSerialDevices: [String] {
        showAllSerialDevices
            ? SerialDeviceEnumerator.allCUDevices()
            : SerialDeviceEnumerator.likelyTNCDevices()
    }

    private func serialDeviceLabel(_ path: String) -> String {
        // Show just the device name, not the full /dev/ path
        let name = (path as NSString).lastPathComponent
        return name
    }

    private func formatBaudRate(_ rate: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: rate)) ?? "\(rate)"
    }

    private var shouldSuggestReconnect: Bool {
        guard client.status == .connected else { return false }
        if settings.transportType == "network" {
            if let connectedHost = client.connectedHost, connectedHost != settings.host {
                return true
            }
            if let connectedPort = client.connectedPort, connectedPort != settings.portValue {
                return true
            }
        }
        return false
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        launchAtLoginFeedback = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginFeedback = "Launch at login failed"
            DispatchQueue.main.async {
                settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
