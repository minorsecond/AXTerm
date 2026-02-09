//
//  SettingsView.swift
//  AXTerm
//
//  Refactored by Settings Redesign on 2/8/26.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    let packetStore: PacketStore?
    let consoleStore: ConsoleStore?
    let rawStore: RawStore?
    let eventLogger: EventLogger?
    let notificationManager: NotificationAuthorizationManager
    
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

            NetworkSettingsView(settings: settings)
                .tabItem { Label("Network", systemImage: "network") }
                .tag(SettingsTab.network)
            
            TransmissionSettingsView(settings: settings, client: client)
                .tabItem { Label("Transmission", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(SettingsTab.transmission)
            
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
        }
        .environmentObject(router) // Provide router to all tabs
        .frame(width: 550, height: 600)
        .accessibilityIdentifier("settingsView")
    }
}
