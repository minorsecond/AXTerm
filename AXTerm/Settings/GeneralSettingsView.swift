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
    /// app-wide behavior, so their controls live here. Nil hides them —
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
        SettingsForm(landing: [.stationIdentity, .stationPosition, .display, .online, .system]) {
            PreferencesSection("Identity", id: .stationIdentity) {
                StationCallsignField(settings: settings)

                Text("Your callsign without an SSID, such as K0EPI. Each radio adds its own "
                     + "SSID, set under Identity on the radio's page under Radios.")
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

            PreferencesSection("Display", id: .display) {
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

            // App-wide network behavior, surfaced where a non-Winlink
            // operator will actually find it — this one toggle gates the
            // map's position lookups and the node directory's, not just
            // Winlink's (field ask 2026-08-29: "winlink settings contained
            // settings that were more general").
            if let winlink = winlinkSettings {
                PreferencesSection("Online", id: .online) {
                    OnlineLookupToggle(settings: winlink)
                }
            }
            
            PreferencesSection("System", id: .system) {
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

                // Sleep, not App Nap. Staying scheduled is unconditional and
                // is not offered here; see KeepAwake.swift for why one is a
                // choice and the other is not.
                Picker("Keep this Mac awake", selection: $settings.keepAwakePolicy) {
                    ForEach(KeepAwakePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Text(settings.keepAwakePolicy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
        }
        .settingsPagePadding()
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
            Text("Kilometers").tag(false)
        }
        .help("Coverage rings, map cards, profiles and range labels. "
              + "Values are measured in kilometers and converted for "
              + "display, so switching loses nothing.")

        Picker("Heights", selection: Binding(
            get: { winlink.heightUnitIsFeet },
            set: { winlink.heightUnitIsFeet = $0 })) {
            Text("Feet").tag(true)
            Text("Meters").tag(false)
        }
        .help("Antenna heights on station pages and in terrain forecasts. "
              + "Stored in meters; entered and read back in your unit.")
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

/// The station callsign: the base call alone.
///
/// Typed into like any callsign field, but an SSID never reaches the store.
/// `AppSettingsStore.myCallsign` keeps the base, and the line under the field
/// says where the SSID is set instead. What was typed stays in the field
/// while it has focus, so the operator can see what they typed and why part
/// of it was not kept; it settles to the stored value once focus leaves.
struct StationCallsignField: View {
    @ObservedObject var settings: AppSettingsStore
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Trimmed here, upper-cased by callsignInput; see there for why
            // the setter leaves the case alone.
            TextField("My Callsign", text: Binding(
                get: { draft },
                set: { typed in
                    draft = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                    settings.myCallsign = draft
                }
            ))
            .textFieldStyle(.roundedBorder)
            .callsignInput($draft)
            .focused($focused)
            .onAppear { draft = settings.myCallsign }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { draft = settings.myCallsign }
            }
            .onChange(of: settings.myCallsign) { _, stored in
                if !focused { draft = stored }
            }

            if let guidance = StationCallsignRules.ssidGuidance(
                for: draft, hasMultipleRadios: settings.hasMultipleRadios) {
                Label(guidance, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !draft.isEmpty && !CallsignValidator.isValidCallsign(draft) {
                Label("Invalid format (e.g. K0EPI)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
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
                  + "map. This gates the map's automatic lookups and "
                  + "the node directory's, not just Winlink. Answers are "
                  + "cached permanently and stay usable offline.\n\nOff by "
                  + "default: a lookup tells a third party which stations "
                  + "you are hearing. Public license data, but still a "
                  + "disclosure.")
        Text("Gates every automatic position lookup in the app: the "
             + "map, the node directory and Winlink alike.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
