//
//  PacketNSTableView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import AppKit
import SwiftUI

struct PacketNSTableView: NSViewRepresentable {
    struct Constants {
        static let autosaveName = "PacketTable"
        static let autoresizingColumnIdentifier: ColumnIdentifier = .info
    }

    enum ColumnIdentifier: String, CaseIterable {
        case time
        case from
        case to
        case via
        case type
        case info
    }

    let packets: [Packet]
    @Binding var selection: Set<Packet.ID>
    let onInspectSelection: () -> Void
    let onCopyInfo: (Packet) -> Void
    let onCopyRawHex: (Packet) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: $selection,
            onInspectSelection: onInspectSelection,
            onCopyInfo: onCopyInfo,
            onCopyRawHex: onCopyRawHex
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.autoresizesAllColumnsToFit = false
        tableView.allowsColumnResizing = true
        tableView.autosaveName = Constants.autosaveName
        tableView.autosaveTableColumns = true
        tableView.menu = contextMenu(for: context.coordinator)
        tableView.autoresizingMask = [.width, .height]
        tableView.translatesAutoresizingMaskIntoConstraints = true

        #if DEBUG
        resetAutosavedColumnsIfNeeded(for: tableView)
        #endif

        context.coordinator.attach(tableView: tableView)
        configureColumns(for: tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }
        let rowViewModels = packets.map { PacketRowViewModel.fromPacket($0) }
        context.coordinator.update(rows: rowViewModels, packets: packets, selection: selection)
    }

    private func configureColumns(for tableView: NSTableView) {
        if !tableView.tableColumns.isEmpty { return }

        let timeColumn = makeColumn(id: .time, title: "Time", minWidth: 70, width: 80)
        let fromColumn = makeColumn(id: .from, title: "From", minWidth: 80, width: 100)
        let toColumn = makeColumn(id: .to, title: "To", minWidth: 80, width: 100)
        let viaColumn = makeColumn(id: .via, title: "Via", minWidth: 60, width: 120)
        let typeColumn = makeColumn(id: .type, title: "Type", minWidth: 40, width: 50)
        let infoColumn = makeColumn(id: .info, title: "Info", minWidth: 200, width: 400)
        infoColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(fromColumn)
        tableView.addTableColumn(toColumn)
        tableView.addTableColumn(viaColumn)
        tableView.addTableColumn(typeColumn)
        tableView.addTableColumn(infoColumn)
        // The autoresizingColumn is required for Finder-style fill behavior so Info expands
        // to consume remaining width when the window grows.
        tableView.autoresizingColumn = infoColumn
    }

    private func makeColumn(id: ColumnIdentifier, title: String, minWidth: CGFloat, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
        column.title = title
        column.minWidth = minWidth
        column.width = width
        column.resizingMask = .userResizingMask
        return column
    }

    private func contextMenu(for coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let inspectItem = NSMenuItem(title: "Inspect Packet", action: #selector(Coordinator.inspectFromMenu(_:)), keyEquivalent: "")
        inspectItem.target = coordinator
        menu.addItem(inspectItem)

        menu.addItem(.separator())

        let copyInfoItem = NSMenuItem(title: "Copy Info", action: #selector(Coordinator.copyInfoFromMenu(_:)), keyEquivalent: "")
        copyInfoItem.target = coordinator
        menu.addItem(copyInfoItem)

        let copyRawItem = NSMenuItem(title: "Copy Raw Hex", action: #selector(Coordinator.copyRawHexFromMenu(_:)), keyEquivalent: "")
        copyRawItem.target = coordinator
        menu.addItem(copyRawItem)

        return menu
    }

    #if DEBUG
    private func resetAutosavedColumnsIfNeeded(for tableView: NSTableView) {
        // Autosaved column widths can mask changes to autoresizingColumn. Use this
        // debug-only toggle to clear saved widths if the Info column stays narrow.
        let shouldResetAutosave = false
        guard shouldResetAutosave, let autosaveName = tableView.autosaveName else { return }
        let defaultsKey = "NSTableView Columns \(autosaveName)"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
    #endif
}

extension PacketNSTableView {
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let selection: Binding<Set<Packet.ID>>
        private let onInspectSelection: () -> Void
        private let onCopyInfo: (Packet) -> Void
        private let onCopyRawHex: (Packet) -> Void

        private(set) var rows: [PacketRowViewModel] = []
        private(set) var packets: [Packet] = []
        private var isApplyingSelection = false
        private var lastContextRow: Int?

        weak var tableView: NSTableView?

        init(
            selection: Binding<Set<Packet.ID>>,
            onInspectSelection: @escaping () -> Void,
            onCopyInfo: @escaping (Packet) -> Void,
            onCopyRawHex: @escaping (Packet) -> Void
        ) {
            self.selection = selection
            self.onInspectSelection = onInspectSelection
            self.onCopyInfo = onCopyInfo
            self.onCopyRawHex = onCopyRawHex
        }

        func update(rows: [PacketRowViewModel], packets: [Packet], selection: Set<Packet.ID>) {
            self.rows = rows
            self.packets = packets
            tableView?.reloadData()
            applySelection(selection)
        }

        func attach(tableView: NSTableView) {
            self.tableView = tableView
        }

        func applySelection(_ selection: Set<Packet.ID>) {
            guard let tableView else { return }
            let mapper = PacketTableSelectionMapper(rows: rows)
            let desired = mapper.indexes(for: selection)
            guard desired != tableView.selectedRowIndexes else { return }
            isApplyingSelection = true
            tableView.selectRowIndexes(desired, byExtendingSelection: false)
            isApplyingSelection = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let mapper = PacketTableSelectionMapper(rows: rows)
            let newSelection = mapper.selection(for: tableView.selectedRowIndexes)
            DispatchQueue.main.async { [weak self] in
                self?.selection.wrappedValue = newSelection
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, rows.indices.contains(row) else { return nil }
            let rowModel = rows[row]
            let identifier = tableColumn.identifier
            let textField = makeTextField(for: identifier, row: rowModel)
            let cell = NSTableCellView()
            cell.identifier = identifier
            cell.textField = textField
            cell.addSubview(textField)
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 1),
                textField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -1)
            ])
            return cell
        }

        func tableView(_ tableView: NSTableView, menuFor event: NSEvent) -> NSMenu? {
            let clickedRow = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
            lastContextRow = clickedRow >= 0 ? clickedRow : nil
            if clickedRow >= 0, !tableView.selectedRowIndexes.contains(clickedRow) {
                tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.selection.wrappedValue = [self.rows[clickedRow].id]
                }
            }
            return tableView.menu
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            activateRow(row)
        }

        @objc func inspectFromMenu(_ sender: Any?) {
            activateRow(lastContextRow)
        }

        @objc func copyInfoFromMenu(_ sender: Any?) {
            guard let packet = packetForContextAction() else { return }
            onCopyInfo(packet)
        }

        @objc func copyRawHexFromMenu(_ sender: Any?) {
            guard let packet = packetForContextAction() else { return }
            onCopyRawHex(packet)
        }

        private func packetForContextAction() -> Packet? {
            if let contextRow = lastContextRow, packets.indices.contains(contextRow) {
                return packets[contextRow]
            }
            guard let tableView else { return nil }
            let row = tableView.selectedRowIndexes.first ?? -1
            guard packets.indices.contains(row) else { return nil }
            return packets[row]
        }

        private func activateRow(_ row: Int?) {
            guard let tableView else { return }
            let resolvedRow = row ?? tableView.selectedRowIndexes.first
            guard let resolvedRow, rows.indices.contains(resolvedRow) else { return }
            let packetID = rows[resolvedRow].id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selection.wrappedValue = [packetID]
                self.onInspectSelection()
            }
        }

        private func makeTextField(for identifier: NSUserInterfaceItemIdentifier, row: PacketRowViewModel) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.backgroundColor = .clear
            field.drawsBackground = false

            switch identifier.rawValue {
            case ColumnIdentifier.time.rawValue:
                field.stringValue = row.timeText
                field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                field.textColor = .secondaryLabelColor
                field.alignment = .left
            case ColumnIdentifier.from.rawValue:
                field.stringValue = row.fromText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
                field.alignment = .left
            case ColumnIdentifier.to.rawValue:
                field.stringValue = row.toText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
                field.alignment = .left
            case ColumnIdentifier.via.rawValue:
                field.stringValue = row.viaText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = .secondaryLabelColor
                field.alignment = .left
            case ColumnIdentifier.type.rawValue:
                field.stringValue = row.typeIcon
                field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
                field.alignment = .center
                field.toolTip = row.typeTooltip
            case ColumnIdentifier.info.rawValue:
                field.stringValue = row.infoText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
                field.alignment = .left
                field.toolTip = row.infoTooltip
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            default:
                field.stringValue = ""
            }

            return field
        }
    }
}
