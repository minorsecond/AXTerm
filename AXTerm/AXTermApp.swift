//
//  AXTermApp.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import GRDB
import SwiftUI
import UserNotifications

@main
struct AXTermApp: App {
    @NSApplicationDelegateAdaptor(AXTermAppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettingsStore
    @StateObject private var inspectionRouter: PacketInspectionRouter
    /// Personal mailbox settings. Owned here rather than in ContentView so the
    /// Settings scene and the BBS view observe the same object — two instances
    /// would each read the same defaults and neither would see the other's
    /// changes until relaunch.
    @StateObject private var bbsSettings = BBSSettings()
    // The menu bar item's visibility is read straight from UserDefaults
    // by StatusItemController; no scene state is involved any more.
    private let packetStore: PacketStore?
    private let consoleStore: ConsoleStore?
    private let rawStore: RawStore?
    private let eventStore: EventLogStore?
    private let eventLogger: EventLogger?
    private let notificationManager: NotificationAuthorizationManager
    private let winlinkContext: WinlinkContext
    private let client: PacketEngine

    init() {
        let isUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let testConfig = TestModeConfiguration.shared
        let isTestModeRun = isUnitTests || testConfig.isTestMode
        let defaults: UserDefaults
        if isTestModeRun {
            let suiteName = "com.rosswardrup.AXTerm.test.\(testConfig.instanceID)"
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            defaults = .standard
        }
        let settingsStore = AppSettingsStore(defaults: defaults)
        _settings = StateObject(wrappedValue: settingsStore)
        let router = PacketInspectionRouter.shared
        _inspectionRouter = StateObject(wrappedValue: router)

        TxLog.configure(wireDebugEnabled: WireDebugSettings.isEnabled)

        // Apply test mode overrides
        if testConfig.isTestMode {
            if let callsign = testConfig.callsign {
                settingsStore.myCallsign = callsign
            }
            settingsStore.runInMenuBar = false

            // In UI test mode we want AXDP capability negotiation and related
            // features to be completely frictionless so the harness "just
            // works" without touching Settings in each instance.
            //
            // This ONLY affects the ephemeral per-test UserDefaults suite
            // created above, so it does not change behaviour for normal
            // installs.
            settingsStore.axdpExtensionsEnabled = true
            settingsStore.axdpAutoNegotiateCapabilities = true
            settingsStore.axdpCompressionEnabled = true
        }

        SentryManager.shared.startIfEnabled(settings: settingsStore)
        SentryManager.shared.addBreadcrumb(category: "app.lifecycle", message: "App init", level: .info, data: nil)

        // Use ephemeral database in test mode to avoid polluting the real database
        let queue: DatabaseQueue?
        let useEphemeralDatabase = (testConfig.isTestMode && testConfig.ephemeralDatabase) || isUnitTests || testConfig.isTestMode
        if useEphemeralDatabase {
            let instanceID = isUnitTests
                ? "unit-\(ProcessInfo.processInfo.processIdentifier)"
                : testConfig.instanceID
            queue = try? DatabaseManager.makeEphemeralDatabaseQueue(instanceID: instanceID)
        } else {
            queue = try? DatabaseManager.makeDatabaseQueue()
        }
        let packetStore = queue.map { SQLitePacketStore(dbQueue: $0) }
        let consoleStore = queue.map { SQLiteConsoleStore(dbQueue: $0) }
        let rawStore = queue.map { SQLiteRawStore(dbQueue: $0) }
        let eventStore = queue.map { SQLiteEventLogStore(dbQueue: $0) }
        let eventLogger = eventStore.map { DatabaseEventLogger(store: $0, settings: settingsStore) }
        let watchRecorder = eventStore.map { EventLogWatchRecorder(store: $0, settings: settingsStore) }
        let appState = DefaultAppStateProvider()
        let notificationScheduler = UserNotificationScheduler(settings: settingsStore, appState: appState)
        let notificationManager = NotificationAuthorizationManager()
        self.packetStore = packetStore
        self.consoleStore = consoleStore
        self.rawStore = rawStore
        self.eventStore = eventStore
        self.eventLogger = eventLogger
        self.notificationManager = notificationManager
        self.winlinkContext = WinlinkContext(
            store: queue.map { SQLiteWinlinkStore(dbQueue: $0) },
            settings: WinlinkSettings(defaults: defaults),
            profile: StationProfile(defaults: defaults),
            contactStore: queue.map { SQLiteContactStore(dbQueue: $0) },
            appSettings: settingsStore,
            activityStore: queue.map { SQLiteStationActivityStore(dbQueue: $0) })
        self.client = PacketEngine(
            settings: settingsStore,
            packetStore: packetStore,
            consoleStore: consoleStore,
            rawStore: rawStore,
            eventLogger: eventLogger,
            eventLogStore: eventStore,
            watchRecorder: watchRecorder,
            notificationScheduler: notificationScheduler,
            databaseWriter: queue
        )

        // Determine connection settings (test mode overrides take precedence)
        let effectiveHost = testConfig.effectiveHost(default: settingsStore.host)
        let effectivePort = testConfig.effectivePort(default: settingsStore.portValue)

        SentryManager.shared.setConnectionTags(host: effectiveHost, port: effectivePort)

        // Auto-connect if settings say so OR if test mode requests it
        if !isUnitTests && (settingsStore.autoConnectOnLaunch || testConfig.autoConnect) {
            if testConfig.isTestMode {
                // Test mode always uses network with explicit host/port
                self.client.connect(host: effectiveHost, port: effectivePort)
            } else {
                self.client.connectUsingSettings()
            }
        }
        appDelegate.settings = settingsStore

        // The menu bar item lives in AppKit — see StatusItemController's
        // header for why SwiftUI's MenuBarExtra had to go. Skipped in
        // unit tests: the test host has no business inserting status
        // items, and tests construct their own controllers.
        if !isUnitTests, StatusItemController.shared == nil {
            StatusItemController.shared = StatusItemController(
                client: client,
                settings: settingsStore,
                inspectionRouter: router,
                defaults: defaults)
        }
    }

    var body: some Scene {
        let windowTitle = "AXTerm" + TestModeConfiguration.shared.windowTitleSuffix
        WindowGroup(windowTitle, id: "main") {
            // The unit-test host mounts no UI at all: the full
            // ContentView spins up the map pre-warm, sync passes and
            // lookup tasks underneath five thousand tests that
            // construct their own worlds — churn, sockets and (until
            // 2026-08-29) a visible window over the operator's editor.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                Text("AXTerm unit-test host")
                    .frame(width: 200, height: 40)
            } else if ProcessInfo.processInfo.arguments.contains("--console-hang-repro") {
                // Isolated reproduction of the ConsoleView layout-loop hang.
                // Hosts the real ConsoleView and self-terminates; see
                // ConsoleHangReproHarness.
                ConsoleHangReproHarness()
            } else {
                ContentView(client: client, settings: settings, inspectionRouter: inspectionRouter, winlinkContext: winlinkContext, bbsSettings: bbsSettings)
                    // @AppStorage follows the isolated suite under test
                    // mode; in production this is .standard, so it is a
                    // no-op. Belt-and-suspenders with AppEnvironment.defaults.
                    .defaultAppStorage(AppEnvironment.defaults)
                    // Launch and every return to the foreground: pull whatever
                    // the operator's other devices did while this one was away.
                    .task { winlinkContext.appBecameActive() }
                    .onReceive(NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification)) { _ in
                        winlinkContext.appBecameActive()
                    }
            }
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Close") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
            AXTermCommands()
        }

        Settings {
            SettingsView(
                settings: settings,
                client: client,
                packetStore: packetStore,
                consoleStore: consoleStore,
                rawStore: rawStore,
                eventLogger: eventLogger,
                notificationManager: notificationManager,
                winlinkSettings: winlinkContext.settings,
                stationProfile: winlinkContext.profile,
                locationService: winlinkContext.locationService,
                winlinkSync: winlinkContext.sync,
                bbsSettings: bbsSettings
            )
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(settings: settings, eventStore: eventStore)
        }

        WindowGroup("New Winlink Message", id: "winlinkCompose", for: String.self) { $draftMID in
            if let draftMID, let store = winlinkContext.store {
                WinlinkComposeWindow(
                    store: store,
                    myCallsign: settings.myCallsign,
                    draftMID: draftMID,
                    locationService: winlinkContext.locationService,
                    contactStore: winlinkContext.contactStore,
                    onChanged: { winlinkContext.refreshUnread() }
                )
            }
        }

        WindowGroup("Winlink Message", id: "winlinkMessage", for: String.self) { $mid in
            if let mid, let store = winlinkContext.store {
                WinlinkMessageWindow(
                    store: store,
                    mid: mid,
                    myCallsign: settings.myCallsign,
                    onDraftSaved: { winlinkContext.refreshUnread() })
            }
        }

        // A window rather than a sheet: a map wants to be resized,
        // zoomed and put full-screen, and a sheet can do none of those.
        Window("Winlink Station Map", id: "winlinkMap") {
            WinlinkScopeWindow(
                stations: (try? winlinkContext.store?.stations()) ?? [],
                linkQuality: winlinkContext.mapLinkQuality,
                observerGrid: winlinkContext.settings.gridSquare)
        }
        .defaultSize(width: 820, height: 700)

        // No MenuBarExtra scene: the menu bar item is an AppKit
        // NSStatusItem owned by StatusItemController (created in init).
        // SwiftUI's MenuBarExtraController re-set the status button
        // image during every window's render flush, and a packet flood
        // tripped AppKit's constraint-loop guard on the status window —
        // thrown as an NSException that froze the app (2026-08-29).
    }
}
