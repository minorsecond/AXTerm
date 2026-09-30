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
        // A sidebar, not a tab strip: eight tabs crammed into a 550-point
        // toolbar read as clutter and hid what the pages had in common.
        // Grouped the way the app thinks — who you are, the radio, the
        // services running on it, and the machinery underneath — in a
        // window the operator can finally resize.
        NavigationSplitView {
            // Optional selection: the non-optional List selection
            // initialiser is macOS-only, and this file compiles into the
            // iOS target even though the iOS shell composes pages directly.
            List(selection: $sidebarSelection) {
                Section("Station") {
                    sidebarRow(.general)
                    sidebarRow(.notifications)
                }
                Section("Radio") {
                    sidebarRow(.radios)
                    sidebarRow(.transmission)
                }
                Section("Services") {
                    sidebarRow(.aprs)
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
                .navigationTitle(router.selectedTab.settingsTitle(hasMultipleRadios: settings.hasMultipleRadios))
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
        case .aprs:
            APRSSettingsView(settings: settings)
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
            Image(systemName: tab.settingsIcon(hasMultipleRadios: settings.hasMultipleRadios))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tab.settingsTint.gradient))
            Text(tab.settingsTitle(hasMultipleRadios: settings.hasMultipleRadios))
        }
        .tag(tab)
    }
}

extension SettingsTab {
    /// The pane's name. One radio and it is the Connection pane it always
    /// was — the word "radios" appears nowhere until there are several.
    func settingsTitle(hasMultipleRadios: Bool) -> String {
        if self == .radios, !hasMultipleRadios { return "Connection" }
        return settingsTitle
    }

    func settingsIcon(hasMultipleRadios: Bool) -> String {
        if self == .radios, !hasMultipleRadios { return "cable.connector" }
        return settingsIcon
    }

    var settingsTitle: String {
        switch self {
        case .general: return "General"
        case .notifications: return "Notifications"
        case .radios: return "Radios"
        case .transmission: return "Transmission"
        case .winlink: return "Winlink"
        case .bbs: return "BBS"
        case .aprs: return "APRS"
        case .advanced: return "Advanced"
        case .linkDebug: return "Link Debug"
        }
    }

    var settingsIcon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .notifications: return "bell.badge.fill"
        case .radios: return "radio"
        case .transmission: return "antenna.radiowaves.left.and.right"
        case .winlink: return "envelope.fill"
        case .bbs: return "tray.full.fill"
        case .aprs: return "mappin.and.ellipse"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .linkDebug: return "ant.fill"
        }
    }

    var settingsTint: Color {
        switch self {
        case .general: return .gray
        case .notifications: return .red
        case .radios: return .blue
        case .transmission: return .orange
        case .winlink: return .teal
        case .bbs: return .indigo
        case .aprs: return .green
        case .advanced: return .brown
        case .linkDebug: return .purple
        }
    }
}
