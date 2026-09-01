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
    @ObservedObject var bbsSettings: BBSSettings
    
    // Inject the router for navigation
    @StateObject var router = SettingsRouter.shared

    var body: some View {
        // A sidebar, not a tab strip: eight tabs crammed into a 550-point
        // toolbar read as clutter and hid what the pages had in common.
        // Grouped the way the app thinks — who you are, the radio, the
        // services running on it, and the machinery underneath — in a
        // window the operator can finally resize.
        NavigationSplitView {
            // Optional-selection binding: the non-optional List selection
            // initialiser is macOS-only, and this file compiles into the
            // iOS target even though the iOS shell composes pages directly.
            List(selection: Binding<SettingsTab?>(
                get: { router.selectedTab },
                set: { if let tab = $0 { router.selectedTab = tab } })) {
                Section("Station") {
                    sidebarRow(.general)
                    sidebarRow(.notifications)
                }
                Section("Radio") {
                    sidebarRow(.network)
                    sidebarRow(.transmission)
                }
                Section("Services") {
                    sidebarRow(.winlink)
                    #if os(macOS)
                    sidebarRow(.bbs)
                    #endif
                }
                Section("Maintenance") {
                    sidebarRow(.advanced)
                    sidebarRow(.linkDebug)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 185, ideal: 200, max: 240)
        } detail: {
            detail
                .navigationTitle(router.selectedTab.settingsTitle)
        }
        .environmentObject(router) // Provide router to all tabs
        .frame(minWidth: 760, idealWidth: 800, minHeight: 560, idealHeight: 660)
        .accessibilityIdentifier("settingsView")
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selectedTab {
        case .general:
            GeneralSettingsView(settings: settings, client: client,
                                winlinkSettings: winlinkSettings,
                                locationService: locationService)
        case .notifications:
            NotificationSettingsView(settings: settings, notificationManager: notificationManager)
        case .network:
            ConnectionSettingsView(settings: settings, packetEngine: client)
        case .transmission:
            TransmissionSettingsView(settings: settings, client: client)
        case .winlink:
            WinlinkSettingsTab(settings: winlinkSettings, profile: stationProfile,
                               stationCallsign: settings.myCallsign,
                               locationService: locationService, sync: winlinkSync)
        case .bbs:
            // The mailbox UI is macOS-only; see AXTerm/BBS/UI.
            #if os(macOS)
            BBSSettingsTab(settings: bbsSettings,
                           stationCallsign: settings.myCallsign,
                           isWinlinkP2PArmed: winlinkSettings.p2pListenEnabled)
            #else
            EmptyView()
            #endif
        case .advanced:
            AdvancedSettingsView(
                settings: settings,
                client: client,
                packetStore: packetStore,
                consoleStore: consoleStore,
                rawStore: rawStore,
                eventLogger: eventLogger
            )
        case .linkDebug:
            LinkDebugView(packetEngine: client)
        }
    }

    /// One sidebar row, System Settings style: a tinted icon tile so the
    /// eye can navigate by colour before it reads a word.
    private func sidebarRow(_ tab: SettingsTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tab.settingsIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tab.settingsTint.gradient))
            Text(tab.settingsTitle)
        }
        .tag(tab)
    }
}

extension SettingsTab {
    var settingsTitle: String {
        switch self {
        case .general: return "General"
        case .notifications: return "Notifications"
        case .network: return "Connection"
        case .transmission: return "Transmission"
        case .winlink: return "Winlink"
        case .bbs: return "BBS"
        case .advanced: return "Advanced"
        case .linkDebug: return "Link Debug"
        }
    }

    var settingsIcon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .notifications: return "bell.badge.fill"
        case .network: return "cable.connector"
        case .transmission: return "antenna.radiowaves.left.and.right"
        case .winlink: return "envelope.fill"
        case .bbs: return "tray.full.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .linkDebug: return "ant.fill"
        }
    }

    var settingsTint: Color {
        switch self {
        case .general: return .gray
        case .notifications: return .red
        case .network: return .blue
        case .transmission: return .orange
        case .winlink: return .teal
        case .bbs: return .indigo
        case .advanced: return .brown
        case .linkDebug: return .purple
        }
    }
}
