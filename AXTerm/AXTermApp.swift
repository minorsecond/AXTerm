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
        let testConfig = TestModeConfiguration.shared
        let settingsStore = AppSettingsStore()
        _settings = StateObject(wrappedValue: settingsStore)
        let router = PacketInspectionRouter()
        _inspectionRouter = StateObject(wrappedValue: router)

        // Apply test mode overrides
        if testConfig.isTestMode {
            if let callsign = testConfig.callsign {
                settingsStore.myCallsign = callsign
            }
        }

        SentryManager.shared.startIfEnabled(settings: settingsStore)
        SentryManager.shared.addBreadcrumb(category: "app.lifecycle", message: "App init", level: .info, data: nil)

        // Use ephemeral database in test mode to avoid polluting the real database
        let queue: DatabaseQueue?
        if testConfig.isTestMode {
            queue = try? DatabaseManager.makeEphemeralDatabaseQueue(instanceID: testConfig.instanceID)
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
        if settingsStore.autoConnectOnLaunch || testConfig.autoConnect {
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
