//
//  SettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    let packetStore: PacketStore?
    let consoleStore: ConsoleStore?
    let rawStore: RawStore?
    let eventLogger: EventLogger?
    let notificationManager: NotificationAuthorizationManager
    @ObservedObject var winlinkSettings: WinlinkSettings
    @ObservedObject var stationProfile: StationProfile
    /// Lets the Winlink tab fill the grid square and address from GPS.
    var locationService: StationLocationService?
    /// Nil when the database failed to open — no mailbox, nothing to sync.
    var winlinkSync: WinlinkSyncController?
    
    // Inject the router for navigation
    @StateObject var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.selectedTab) {
            GeneralSettingsView(settings: settings, client: client)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)
            
            NotificationSettingsView(settings: settings, notificationManager: notificationManager)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(SettingsTab.notifications)

            ConnectionSettingsView(settings: settings, packetEngine: client)
                .tabItem { Label("Connection", systemImage: "cable.connector") }
                .tag(SettingsTab.network)
            
            TransmissionSettingsView(settings: settings, client: client)
                .tabItem { Label("Transmission", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(SettingsTab.transmission)

            WinlinkSettingsTab(settings: winlinkSettings, profile: stationProfile,
                               locationService: locationService, sync: winlinkSync)
                .tabItem { Label("Winlink", systemImage: "envelope") }
                .tag(SettingsTab.winlink)
            
            AdvancedSettingsView(
                settings: settings,
                client: client,
                packetStore: packetStore,
                consoleStore: consoleStore,
                rawStore: rawStore,
                eventLogger: eventLogger
            )
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            .tag(SettingsTab.advanced)

            LinkDebugView(packetEngine: client)
                .tabItem { Label("Link Debug", systemImage: "ant") }
                .tag(SettingsTab.linkDebug)
        }
        .environmentObject(router) // Provide router to all tabs
        .frame(width: 550, height: 700)
        .accessibilityIdentifier("settingsView")
    }
}
