//
//  PacketTableNSTableView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import AppKit
import SwiftUI

struct PacketTableNSTableView: NSViewRepresentable {
    let packets: [Packet]
    @Binding var selection: Set<Packet.ID>
    let onInspectSelection: () -> Void
    let onCopyInfo: (Packet) -> Void
    let onCopyRawHex: (Packet) -> Void

    func makeCoordinator() -> PacketTableCoordinator {
        PacketTableCoordinator(
            selection: $selection,
            onInspectSelection: onInspectSelection,
            onCopyInfo: onCopyInfo,
            onCopyRawHex: onCopyRawHex
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = PacketTableNativeTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(PacketTableCoordinator.handleDoubleClick(_:))
        tableView.menu = contextMenu(for: context.coordinator)
        tableView.onRightClickRow = { row in
            context.coordinator.handleRightClick(row: row)
        }

        context.coordinator.attach(tableView: tableView)
        configureColumns(for: tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }
        let rowViewModels = packets.map { PacketRowViewModel.fromPacket($0) }
        context.coordinator.update(rows: rowViewModels, packets: packets, selection: selection)
        tableView.sizeLastColumnToFit()
    }

    private func configureColumns(for tableView: NSTableView) {
        if !tableView.tableColumns.isEmpty { return }

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(PacketTableColumnIdentifier.time.rawValue))
        timeColumn.title = "Time"
        timeColumn.minWidth = 70
        timeColumn.width = 80
        timeColumn.resizingMask = [.autoresizingMask]
        timeColumn.headerToolTip = "Received time"

        let fromColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(PacketTableColumnIdentifier.from.rawValue))
        fromColumn.title = "From"
        fromColumn.minWidth = 80
        fromColumn.width = 100
        fromColumn.resizingMask = [.autoresizingMask]
        fromColumn.headerToolTip = "Source callsign"

        let toColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(PacketTableColumnIdentifier.to.rawValue))
        toColumn.title = "To"
        toColumn.minWidth = 80
        toColumn.width = 100
        toColumn.resizingMask = [.autoresizingMask]
        toColumn.headerToolTip = "Destination callsign"

        let viaColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(PacketTableColumnIdentifier.via.rawValue))
        viaColumn.title = "Via"
        viaColumn.minWidth = 60
        viaColumn.width = 120
        viaColumn.resizingMask = [.autoresizingMask]
        viaColumn.headerToolTip = "Digipeater path"

        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(PacketTableColumnIdentifier.type.rawValue))
        typeColumn.title = "Frame Type"
        typeColumn.minWidth = 60
        typeColumn.width = 70
        typeColumn.resizingMask = [.autoresizingMask]
        typeColumn.headerToolTip = "Classified frame type"

        let infoColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(PacketTableColumnIdentifier.info.rawValue))
        infoColumn.title = "Info"
        infoColumn.minWidth = 200
        infoColumn.width = 400
        infoColumn.resizingMask = [.autoresizingMask]
        infoColumn.headerToolTip = "Decoded payload preview"

        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(fromColumn)
        tableView.addTableColumn(toColumn)
        tableView.addTableColumn(viaColumn)
        tableView.addTableColumn(typeColumn)
        tableView.addTableColumn(infoColumn)
    }

    private func contextMenu(for coordinator: PacketTableCoordinator) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let inspectItem = NSMenuItem(title: "Inspect Packet", action: #selector(PacketTableCoordinator.inspectFromMenu(_:)), keyEquivalent: "")
        inspectItem.target = coordinator
        menu.addItem(inspectItem)

        menu.addItem(.separator())

        let copyInfoItem = NSMenuItem(title: "Copy Info", action: #selector(PacketTableCoordinator.copyInfoFromMenu(_:)), keyEquivalent: "")
        copyInfoItem.target = coordinator
        menu.addItem(copyInfoItem)

        let copyRawItem = NSMenuItem(title: "Copy Raw Hex", action: #selector(PacketTableCoordinator.copyRawHexFromMenu(_:)), keyEquivalent: "")
        copyRawItem.target = coordinator
        menu.addItem(copyRawItem)

        return menu
    }
}
