//
//  AXTermApp.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

@main
struct AXTermApp: App {
    @NSApplicationDelegateAdaptor(AXTermAppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettingsStore
    @StateObject private var inspectionRouter: PacketInspectionRouter
    private let packetStore: PacketStore?
    private let consoleStore: ConsoleStore?
    private let rawStore: RawStore?
    private let eventStore: EventLogStore?
    private let eventLogger: EventLogger?
    private let notificationManager: NotificationAuthorizationManager
    private let client: PacketEngine

    init() {
        let settingsStore = AppSettingsStore()
        _settings = StateObject(wrappedValue: settingsStore)
        let router = PacketInspectionRouter()
        _inspectionRouter = StateObject(wrappedValue: router)
        let queue = try? DatabaseManager.makeDatabaseQueue()
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
            notificationScheduler: notificationScheduler
        )
        if settingsStore.autoConnectOnLaunch {
            self.client.connect(host: settingsStore.host, port: settingsStore.portValue)
        }
        appDelegate.settings = settingsStore
        appDelegate.notificationDelegate = notificationHandler
    }

    var body: some Scene {
        WindowGroup("AXTerm", id: "main") {
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

        MenuBarExtra("AXTerm", systemImage: "antenna.radiowaves.left.and.right", isInserted: $settings.runInMenuBar) {
            MenuBarView(
                client: client,
                settings: settings,
                inspectionRouter: inspectionRouter
            )
        }
    }
}
