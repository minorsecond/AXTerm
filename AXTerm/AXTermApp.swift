//
//  AXTermApp.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

@main
struct AXTermApp: App {
    @StateObject private var settings: AppSettingsStore
    private let packetStore: PacketStore?
    private let consoleStore: ConsoleStore?
    private let rawStore: RawStore?
    private let eventStore: EventLogStore?
    private let eventLogger: EventLogger?
    private let client: KISSTcpClient

    init() {
        let settingsStore = AppSettingsStore()
        _settings = StateObject(wrappedValue: settingsStore)
        let queue = try? DatabaseManager.makeDatabaseQueue()
        let packetStore = queue.map { SQLitePacketStore(dbQueue: $0) }
        let consoleStore = queue.map { SQLiteConsoleStore(dbQueue: $0) }
        let rawStore = queue.map { SQLiteRawStore(dbQueue: $0) }
        let eventStore = queue.map { SQLiteEventLogStore(dbQueue: $0) }
        let eventLogger = eventStore.map { DatabaseEventLogger(store: $0, settings: settingsStore) }
        self.packetStore = packetStore
        self.consoleStore = consoleStore
        self.rawStore = rawStore
        self.eventStore = eventStore
        self.eventLogger = eventLogger
        self.client = KISSTcpClient(
            settings: settingsStore,
            packetStore: packetStore,
            consoleStore: consoleStore,
            rawStore: rawStore,
            eventLogger: eventLogger
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(client: client, settings: settings)
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
                eventLogger: eventLogger
            )
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(settings: settings, eventStore: eventStore)
        }
    }
}
