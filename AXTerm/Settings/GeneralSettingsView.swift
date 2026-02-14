//
//  GeneralSettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import CoreBluetooth
import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @EnvironmentObject var router: SettingsRouter

    @State private var launchAtLoginFeedback: String?
    @AppStorage(AppSettingsStore.runInMenuBarKey) private var runInMenuBar = AppSettingsStore.defaultRunInMenuBar

    var body: some View {
        Form {
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
                Toggle("Connect automatically on launch", isOn: $settings.autoConnectOnLaunch)
                
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
