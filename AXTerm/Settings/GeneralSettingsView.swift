//
//  GeneralSettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import CoreBluetooth
import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

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

                // Menu bar and login items are macOS concepts. Shown on a
                // handheld they are switches that cannot do anything, which
                // reads as a broken setting rather than an absent one.
                #if os(macOS)
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
                #endif
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onTapGesture {
            // Clear focus when clicking background. A touch platform
            // dismisses the keyboard through the focus system instead.
            #if os(macOS)
            NSApp.keyWindow?.makeFirstResponder(nil)
            #endif
        }
    }

    /// Registers the app as a login item.
    ///
    /// macOS-only by nature: iOS has no login items, and an app there is
    /// launched by the operator or by a notification, never at boot. The
    /// control that calls this is hidden on iOS rather than being shown and
    /// doing nothing.
    private func updateLaunchAtLogin(enabled: Bool) {
        #if os(macOS)
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
        #endif
    }
}
