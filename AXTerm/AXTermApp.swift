//
//  AXTermApp.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import GRDB
import SwiftUI

@main
struct AXTermApp: App {
    @NSApplicationDelegateAdaptor(AXTermAppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettingsStore
    @StateObject private var inspectionRouter: PacketInspectionRouter
    /// Controls MenuBarExtra visibility via @AppStorage to avoid feedback loops.
    /// @Published bindings to MenuBarExtra(isInserted:) cause SwiftUI scene updates
    /// to trigger Combine publishes, creating an infinite invalidation loop.
    @AppStorage(AppSettingsStore.runInMenuBarKey) private var runInMenuBar = AppSettingsStore.defaultRunInMenuBar
    private let packetStore: PacketStore?
    private let consoleStore: ConsoleStore?
    private let rawStore: RawStore?
    private let eventStore: EventLogStore?
    private let eventLogger: EventLogger?
    private let notificationManager: NotificationAuthorizationManager
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
        let router = PacketInspectionRouter()
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

        // Start main thread watchdog
        MainThreadWatchdog.shared.start()

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
        let notificationHandler = NotificationActionHandler(router: router)
        self.packetStore = packetStore
        self.consoleStore = consoleStore
        self.rawStore = rawStore
        self.eventStore = eventStore
        self.eventLogger = eventLogger
        self.notificationManager = notificationManager
        self.client = PacketEngine(
            settings: settingsStore,
            packetStore: packetStore,
            consoleStore: consoleStore,
            rawStore: rawStore,
            eventLogger: eventLogger,
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
            self.client.connect(host: effectiveHost, port: effectivePort)
        }
        appDelegate.settings = settingsStore
        appDelegate.notificationDelegate = notificationHandler
    }

    var body: some Scene {
        let windowTitle = "AXTerm" + TestModeConfiguration.shared.windowTitleSuffix
        WindowGroup(windowTitle, id: "main") {
            ContentView(client: client, settings: settings, inspectionRouter: inspectionRouter)
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
                notificationManager: notificationManager
            )
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(settings: settings, eventStore: eventStore)
        }

        MenuBarExtra("AXTerm", systemImage: "antenna.radiowaves.left.and.right", isInserted: $runInMenuBar) {
            MenuBarView(
                client: client,
                settings: settings,
                inspectionRouter: inspectionRouter
            )

            #if DEBUG
            Divider()
            Button("Send Test Event to Sentry") {
                SentryManager.shared.sendTestEvent()
            }
            #endif
        }
    }
}
