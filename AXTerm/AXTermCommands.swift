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
        get { self[SearchFocusActionKey.self] }
        set { self[SearchFocusActionKey.self] = newValue }
    }

    var toggleConnection: ToggleConnectionAction? {
        get { self[ToggleConnectionActionKey.self] }
        set { self[ToggleConnectionActionKey.self] = newValue }
    }

    var inspectPacket: InspectPacketAction? {
        get { self[InspectPacketActionKey.self] }
        set { self[InspectPacketActionKey.self] = newValue }
    }

    var selectNavigation: SelectNavigationAction? {
        get { self[SelectNavigationActionKey.self] }
        set { self[SelectNavigationActionKey.self] = newValue }
    }
}

private struct SearchFocusActionKey: FocusedValueKey {
    static let defaultValue: SearchFocusAction? = nil
}

private struct ToggleConnectionActionKey: FocusedValueKey {
    static let defaultValue: ToggleConnectionAction? = nil
}

private struct InspectPacketActionKey: FocusedValueKey {
    static let defaultValue: InspectPacketAction? = nil
}

private struct SelectNavigationActionKey: FocusedValueKey {
    static let defaultValue: SelectNavigationAction? = nil
}

struct AXTermCommands: Commands {
    @FocusedValue(\.searchFocus) private var searchFocus
    @FocusedValue(\.toggleConnection) private var toggleConnection
    @FocusedValue(\.inspectPacket) private var inspectPacket
    @FocusedValue(\.selectNavigation) private var selectNavigation

    var body: some Commands {
        CommandGroup(after: .find) {
            Button("Focus Search") {
                searchFocus?.action()
            }
            .keyboardShortcut("f", modifiers: [.command])
        }

        CommandMenu("Connection") {
            Button("Connect/Disconnect") {
                toggleConnection?.action()
            }
            .keyboardShortcut("k", modifiers: [.command])
        }

        CommandMenu("View") {
            Button("Packets") {
                selectNavigation?.action(.packets)
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("Console") {
                selectNavigation?.action(.console)
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("Raw") {
                selectNavigation?.action(.raw)
            }
            .keyboardShortcut("3", modifiers: [.command])
        }

        CommandGroup(after: .textEditing) {
            Button("Inspect Packet") {
                inspectPacket?.action()
            }
            .keyboardShortcut("i", modifiers: [.command])
        }
    }
}
