//
//  AXTermCommands.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

struct SearchFocusAction {
    let action: () -> Void
}

struct ToggleConnectionAction {
    let action: () -> Void
}

struct InspectPacketAction {
    let action: () -> Void
}

struct SelectNavigationAction {
    let action: (NavigationItem) -> Void
}

extension FocusedValues {
    var searchFocus: SearchFocusAction? {
        get { self[SearchFocusActionKey.self] ?? nil }
        set { self[SearchFocusActionKey.self] = newValue }
    }

    var toggleConnection: ToggleConnectionAction? {
        get { self[ToggleConnectionActionKey.self] ?? nil }
        set { self[ToggleConnectionActionKey.self] = newValue }
    }

    var inspectPacket: InspectPacketAction? {
        get { self[InspectPacketActionKey.self] ?? nil }
        set { self[InspectPacketActionKey.self] = newValue }
    }

    var selectNavigation: SelectNavigationAction? {
        get { self[SelectNavigationActionKey.self] ?? nil }
        set { self[SelectNavigationActionKey.self] = newValue }
    }
}

private struct SearchFocusActionKey: FocusedValueKey {
    typealias Value = SearchFocusAction?
    static let defaultValue: SearchFocusAction? = nil
}

private struct ToggleConnectionActionKey: FocusedValueKey {
    typealias Value = ToggleConnectionAction?
    static let defaultValue: ToggleConnectionAction? = nil
}

private struct InspectPacketActionKey: FocusedValueKey {
    typealias Value = InspectPacketAction?
    static let defaultValue: InspectPacketAction? = nil
}

private struct SelectNavigationActionKey: FocusedValueKey {
    typealias Value = SelectNavigationAction?
    static let defaultValue: SelectNavigationAction? = nil
}

struct AXTermCommands: Commands {
    @FocusedValue(\.searchFocus) private var searchFocus
    @FocusedValue(\.toggleConnection) private var toggleConnection
    @FocusedValue(\.inspectPacket) private var inspectPacket
    @FocusedValue(\.selectNavigation) private var selectNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Focus Search") {
                searchFocus?.action()
            }
            .keyboardShortcut("f", modifiers: [.command])
            
            Button("Inspect Packet") {
                inspectPacket?.action()
            }
            .keyboardShortcut("i", modifiers: [.command])
        }

        CommandMenu("Connection") {
            Button("Connect/Disconnect") {
                toggleConnection?.action()
            }
            .keyboardShortcut("k", modifiers: [.command])
        }

        CommandMenu("View") {
            Button("Terminal") {
                selectNavigation?.action(.terminal)
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("Packets") {
                selectNavigation?.action(.packets)
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("Routes") {
                selectNavigation?.action(.routes)
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button("Analytics") {
                selectNavigation?.action(.analytics)
            }
            .keyboardShortcut("4", modifiers: [.command])

            //Button("Raw") {
            //    selectNavigation?.action(.raw)
            //}
            //.keyboardShortcut("5", modifiers: [.command])
        }

        CommandGroup(after: .help) {
            Button("Diagnostics…") {
                openWindow(id: "diagnostics")
            }

            #if DEBUG
            Divider()

            Button("Send Test Event to Sentry") {
                Task { @MainActor in
                    SentryManager.shared.sendTestEvent()
                }
            }
            .disabled(!SentryManager.shared.isRunning)
            #endif
        }

    }
}
