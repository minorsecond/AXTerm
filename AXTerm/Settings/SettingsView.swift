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

    /// The sidebar's selection, kept apart from the router's.
    ///
    /// The List writes its selection binding from inside a view update, both
    /// when a row is clicked and when it re-asserts the current row. Bound
    /// straight to `router.selectedTab` that write was a publish during the
    /// update: SwiftUI logged "Publishing changes from within view updates"
    /// three to seven times per click on 2026-09-29. Local state takes the
    /// write, and the router follows in `onChange`, which runs afterwards.
    @State private var sidebarSelection: SettingsTab? = SettingsRouter.shared.selectedTab

    var body: some View {
        // A sidebar, not a tab strip. Grouped the way the app thinks: who
        // and where the station is, its radios, the services running on
        // them, and the machinery underneath. Each setting has one home, and
        // the homes do not move when a second radio is added.
        NavigationSplitView {
            // Optional selection: the non-optional List selection
            // initializer is macOS-only, and this file compiles into the
            // iOS target even though the iOS shell composes pages directly.
            List(selection: $sidebarSelection) {
                Section("Station") {
                    sidebarRow(.general)
                    sidebarRow(.notifications)
                }
                Section("Radios") {
                    sidebarRow(.radios)
                }
                Section("Services") {
                    sidebarRow(.aprs)
                    sidebarRow(.packetNode)
                    #if os(macOS)
                    sidebarRow(.bbs)
                    #endif
                    sidebarRow(.winlink)
                }
                Section("Maintenance") {
                    sidebarRow(.advanced)
                    sidebarRow(.linkDebug)
                }
            }
            .listStyle(.sidebar)
            // No sidebar toggle in a Settings window.
            //
            // System Settings has none, and for a good reason: the sidebar
            // is the only way to reach the other pages, so collapsing it
            // strands the operator on whichever page happens to be open.
            // The modifier goes on the sidebar's own content, which is
            // where the item comes from — on the split view it does nothing.
            #if os(macOS)
            .toolbar(removing: .sidebarToggle)
            #endif
            .navigationSplitViewColumnWidth(min: 185, ideal: 200, max: 240)
        } detail: {
            detail
                .navigationTitle(router.selectedTab.settingsTitle)
        }
        .onAppear {
            if sidebarSelection != router.selectedTab { sidebarSelection = router.selectedTab }
        }
        .onChange(of: sidebarSelection) { _, tab in
            // A click in empty sidebar space deselects; keep the page and
            // put its row back.
            guard let tab else {
                sidebarSelection = router.selectedTab
                return
            }
            if tab != router.selectedTab { router.selectedTab = tab }
        }
        .onChange(of: router.selectedTab) { _, tab in
            // Deep links move the router; the sidebar follows.
            if sidebarSelection != tab { sidebarSelection = tab }
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
        case .radios:
            RadiosSettingsView(settings: settings, client: client)
        case .packetNode:
            PacketNodeSettingsView(settings: settings, client: client)
        case .winlink:
            WinlinkSettingsTab(settings: winlinkSettings, profile: stationProfile,
                               stationCallsign: settings.primaryCallsign,
                               answeringRadios: ServiceRadios.winlinkPeerToPeer(settings.activeRadios),
                               locationService: locationService, sync: winlinkSync)
        case .bbs:
            // The mailbox UI is macOS-only; see AXTerm/BBS/UI.
            #if os(macOS)
            BBSSettingsTab(settings: bbsSettings,
                           stationCallsign: settings.primaryCallsign,
                           isWinlinkP2PArmed: winlinkSettings.p2pListenEnabled,
                           runsOn: ServiceRadios.mailbox(settings.activeRadios))
            #else
            EmptyView()
            #endif
        case .aprs:
            APRSSettingsView(settings: settings, client: client)
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
    /// eye can navigate by color before it reads a word.
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
        case .radios: return "Radios"
        case .aprs: return "APRS"
        case .packetNode: return "Packet Node"
        case .bbs: return "BBS"
        case .winlink: return "Winlink"
        case .advanced: return "Advanced"
        case .linkDebug: return "Link Debug"
        }
    }

    var settingsIcon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .notifications: return "bell.badge.fill"
        case .radios: return "radio"
        case .aprs: return "mappin.and.ellipse"
        case .packetNode: return "point.3.connected.trianglepath.dotted"
        case .bbs: return "tray.full.fill"
        case .winlink: return "envelope.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .linkDebug: return "ant.fill"
        }
    }

    var settingsTint: Color {
        switch self {
        case .general: return .gray
        case .notifications: return .red
        case .radios: return .blue
        case .aprs: return .green
        case .packetNode: return .orange
        case .bbs: return .indigo
        case .winlink: return .teal
        case .advanced: return .brown
        case .linkDebug: return .purple
        }
    }

    /// The pages in the order the sidebar lists them. The BBS page is the
    /// Mac's; the mailbox settings on iOS have their own screen.
    static var sidebarOrder: [SettingsTab] {
        #if os(macOS)
        return [.general, .notifications, .radios, .aprs, .packetNode, .bbs, .winlink, .advanced, .linkDebug]
        #else
        return [.general, .notifications, .radios, .aprs, .packetNode, .winlink, .advanced, .linkDebug]
        #endif
    }
}
