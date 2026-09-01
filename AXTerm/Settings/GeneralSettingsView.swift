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
    /// Unit and online-lookup choices live on the Winlink store for
    /// historical reasons (same keys, no migration) but they are
    /// app-wide behaviour, so their controls live here. Nil hides them —
    /// the caller that cannot supply the store keeps the old page.
    var winlinkSettings: WinlinkSettings?
    /// Offered so the position section can use a GPS fix when the
    /// operator has asked it to.
    var locationService: StationLocationService?
    @EnvironmentObject var router: SettingsRouter

    @State private var launchAtLoginFeedback: String?
    @AppStorage(AppSettingsStore.runInMenuBarKey) private var runInMenuBar = AppSettingsStore.defaultRunInMenuBar
    @AppStorage(TimeDisplay.formatKey) private var timeFormatRaw = TimeDisplayFormat.system.rawValue

    var body: some View {
        Form {
            PreferencesSection("Identity") {
                CallsignField(title: "My Callsign", text: $settings.myCallsign)
                
                Text("Used to highlight your node in the graph and identify you in sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Beside the callsign, because it is the other half of "who and
            // where this station is". It lived on the Winlink tab as a grid
            // square, which is a strange home for the fact the map, the
            // coverage rings and every terrain profile depend on.
            StationPositionSettings(settings: settings,
                                    winlinkSettings: winlinkSettings,
                                    locationService: locationService)

            PreferencesSection("Display") {
                Picker("Time format", selection: $timeFormatRaw) {
                    ForEach(TimeDisplayFormat.allCases) { format in
                        Text(format.label).tag(format.rawValue)
                    }
                }
                .help("How timestamps are written in the terminal, station "
                      + "lists and logs. System follows this Mac's locale and "
                      + "12/24-hour preference; the other two pin one style "
                      + "regardless. Dates elsewhere always follow the system "
                      + "locale. Protocol content, debug traces and chart axes "
                      + "keep their own conventions.")

                Text("Now: \(TimeDisplay.timeString(Date(), format: TimeDisplayFormat(rawValue: timeFormatRaw)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show day separators in Console", isOn: $settings.showConsoleDaySeparators)
                Toggle("Show day separators in Raw Data", isOn: $settings.showRawDaySeparators)

                if let winlink = winlinkSettings {
                    unitsControls(winlink)
                }

                Stepper(value: $settings.terminalFontSize, in: 9...18, step: 1) {
                    HStack {
                        Text("Terminal text size")
                        Spacer()
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .font(.system(size: settings.terminalFontSize,
                                          design: .monospaced))
                    }
                }
                .help("Console text in the Terminal. The sample shows the "
                      + "size you are choosing.")
            }

            // App-wide network behaviour, surfaced where a non-Winlink
            // operator will actually find it — this one toggle gates the
            // map's position lookups and the node directory's, not just
            // Winlink's (field ask 2026-08-29: "winlink settings contained
            // settings that were more general").
            if let winlink = winlinkSettings {
                PreferencesSection("Online") {
                    OnlineLookupToggle(settings: winlink)
                }
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
    @ViewBuilder
    private func unitsControls(_ winlink: WinlinkSettings) -> some View {
        Picker("Distances", selection: Binding(
            get: { winlink.distanceUnitIsMiles },
            set: { winlink.distanceUnitIsMiles = $0 })) {
            Text("Miles").tag(true)
            Text("Kilometres").tag(false)
        }
        .help("Coverage rings, map cards, profiles and range labels. "
              + "Values are measured in kilometres and converted for "
              + "display, so switching loses nothing.")

        Picker("Heights", selection: Binding(
            get: { winlink.heightUnitIsFeet },
            set: { winlink.heightUnitIsFeet = $0 })) {
            Text("Feet").tag(true)
            Text("Metres").tag(false)
        }
        .help("Antenna heights on station pages and in terrain forecasts. "
              + "Stored in metres; entered and read back in your unit.")
    }

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

/// The one switch that causes background internet traffic, with the
/// disclosure spelled out. Bound to the live Winlink store so the
/// map's auto-lookup reacts immediately.
private struct OnlineLookupToggle: View {
    @ObservedObject var settings: WinlinkSettings

    var body: some View {
        Toggle("Look up callsigns online", isOn: $settings.callsignLookupEnabled)
            .help("Resolves heard and claimed callsigns to a name and "
                  + "location via hamdb.org so they can be placed on the "
                  + "map \u{2014} this gates the map's automatic lookups and "
                  + "the node directory's, not just Winlink. Answers are "
                  + "cached permanently and stay usable offline.\n\nOff by "
                  + "default: a lookup tells a third party which stations "
                  + "you are hearing. Public licence data, but still a "
                  + "disclosure.")
        Text("Gates every automatic position lookup in the app \u{2014} the "
             + "map, the node directory and Winlink alike.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
