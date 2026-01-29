//
//  PacketTableCoordinator.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import AppKit
import SwiftUI

final class PacketTableCoordinator: NSObject {
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

    func handleRightClick(row: Int) {
        lastContextRow = row
        guard let tableView, row >= 0 else { return }
        guard !tableView.selectedRowIndexes.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selection.wrappedValue = [self.rows[row].id]
        }
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
}

extension PacketTableCoordinator: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

extension PacketTableCoordinator: NSTableViewDelegate {
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

    private func makeTextField(for identifier: NSUserInterfaceItemIdentifier, row: PacketRowViewModel) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.backgroundColor = .clear
        field.drawsBackground = false

        switch identifier.rawValue {
        case PacketTableColumnIdentifier.time.rawValue:
            field.stringValue = row.timeText
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.alignment = .left
            field.toolTip = row.timeText
        case PacketTableColumnIdentifier.from.rawValue:
            field.stringValue = row.fromText
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
            field.alignment = .left
            field.toolTip = row.fromText
        case PacketTableColumnIdentifier.to.rawValue:
            field.stringValue = row.toText
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
            field.alignment = .left
            field.toolTip = row.toText
        case PacketTableColumnIdentifier.via.rawValue:
            field.stringValue = row.viaText
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.alignment = .left
            field.toolTip = row.viaText
        case PacketTableColumnIdentifier.type.rawValue:
            field.stringValue = row.typeLabel
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
            field.alignment = .center
            field.toolTip = row.typeTooltip
        case PacketTableColumnIdentifier.info.rawValue:
            field.stringValue = row.infoText
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
            field.alignment = .left
            field.toolTip = row.infoTooltip
        default:
            field.stringValue = ""
        }

        return field
    }
}

enum PacketTableColumnIdentifier: String {
    case time
    case from
    case to
    case via
    case type
    case info
}

final class PacketTableNativeTableView: NSTableView {
    var onRightClickRow: ((Int) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let row = row(at: location)
        onRightClickRow?(row)
        super.rightMouseDown(with: event)
    }
}
