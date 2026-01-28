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
    private let client: KISSTcpClient

    init() {
        let settingsStore = AppSettingsStore()
        _settings = StateObject(wrappedValue: settingsStore)
        let store = try? SQLitePacketStore()
        self.packetStore = store
        self.client = KISSTcpClient(settings: settingsStore, packetStore: store)
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
            SettingsView(settings: settings, client: client, packetStore: packetStore)
        }
    }
}
