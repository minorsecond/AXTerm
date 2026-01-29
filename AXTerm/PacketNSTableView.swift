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
        static let autosaveName = "PacketTable.v3"
        static let defaultColumnOrder: [ColumnIdentifier] = [.time, .from, .to, .via, .type, .info]
        static let infoColumnIdentifier: ColumnIdentifier = .info
    }

    private static let style = PacketTableStyle.current

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
        tableView.rowHeight = Self.style.rowHeight
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true
        tableView.autosaveName = Constants.autosaveName
        tableView.autosaveTableColumns = true
        tableView.menu = contextMenu(for: context.coordinator)
        tableView.autoresizingMask = [.width, .height]
        tableView.translatesAutoresizingMaskIntoConstraints = true

        #if DEBUG
        let didResetAutosave = resetAutosavedColumnsIfNeeded(for: tableView)
        #else
        let didResetAutosave = false
        #endif
        let hasAutosavedColumns = UserDefaults.standard.object(forKey: "NSTableView Columns \(Constants.autosaveName)") != nil

        context.coordinator.attach(tableView: tableView)
        context.coordinator.shouldApplyMeasuredSizing = (!hasAutosavedColumns && !context.coordinator.hasAppliedMeasuredSizing) || didResetAutosave
        if didResetAutosave {
            context.coordinator.clearBaselineWidths()
        }
        context.coordinator.configureDoubleClick()
        configureColumns(for: tableView)
        context.coordinator.captureBaselineWidths(from: tableView)
        sizeColumnsToFitContent(in: tableView, coordinator: context.coordinator)
        ensureInfoColumnLast(in: tableView)
        expandInfoColumnToFill(in: tableView)

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
        ensureInfoColumnLast(in: tableView)
        expandInfoColumnToFill(in: tableView)
    }

    private func configureColumns(for tableView: NSTableView) {
        if !tableView.tableColumns.isEmpty { return }

        let timeColumn = makeColumn(id: .time, title: "Time", minWidth: 70, width: 80, toolTip: "Received time")
        let fromColumn = makeColumn(id: .from, title: "From", minWidth: 80, width: 100, toolTip: "Source callsign")
        let toColumn = makeColumn(id: .to, title: "To", minWidth: 80, width: 100, toolTip: "Destination callsign")
        let viaColumn = makeColumn(id: .via, title: "Via", minWidth: 60, width: 120, toolTip: "Digipeater path")
        let typeColumn = makeColumn(id: .type, title: "Type", minWidth: 40, width: 50, toolTip: "AX.25 frame type")
        let infoColumn = makeColumn(id: .info, title: "Info", minWidth: 200, width: 400, toolTip: "Decoded payload preview")
        infoColumn.resizingMask = [.autoresizingMask, .userResizingMask]

        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(fromColumn)
        tableView.addTableColumn(toColumn)
        tableView.addTableColumn(viaColumn)
        tableView.addTableColumn(typeColumn)
        tableView.addTableColumn(infoColumn)
        // With .lastColumnOnlyAutoresizingStyle, the trailing column expands to fill
        // remaining width like Finder. Keep Info last to make it the expanding column.
    }

    private func makeColumn(id: ColumnIdentifier, title: String, minWidth: CGFloat, width: CGFloat, toolTip: String) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
        column.title = title
        column.minWidth = minWidth
        column.width = width
        column.resizingMask = .userResizingMask
        column.headerToolTip = toolTip
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
    @discardableResult
    private func resetAutosavedColumnsIfNeeded(for tableView: NSTableView) -> Bool {
        // Autosaved column widths can mask changes to autoresizingColumn. Use this
        // debug-only toggle to clear saved widths if the Info column stays narrow.
        let shouldResetAutosave = UserDefaults.standard.bool(forKey: "AXTermResetAutosavedPacketTableColumns")
        guard shouldResetAutosave, let autosaveName = tableView.autosaveName else { return false }
        let columnDefaultsKey = "NSTableView Columns \(autosaveName)"
        let sortDefaultsKey = "NSTableView Sort Ordering \(autosaveName)"
        UserDefaults.standard.removeObject(forKey: columnDefaultsKey)
        UserDefaults.standard.removeObject(forKey: sortDefaultsKey)
        return true
    }
    #endif

    private func sizeColumnsToFitContent(in tableView: NSTableView, coordinator: Coordinator) {
        guard coordinator.shouldApplyMeasuredSizing else { return }
        guard !tableView.tableColumns.isEmpty else { return }
        let rows = packets.map { PacketRowViewModel.fromPacket($0) }
        let measurements = PacketTableColumnSizer(rows: rows)
        for column in tableView.tableColumns {
            guard let identifier = ColumnIdentifier(rawValue: column.identifier.rawValue) else { continue }
            guard identifier != .info else { continue }
            guard coordinator.shouldResizeColumn(column) else { continue }
            let targetWidth = max(column.minWidth, measurements.width(for: identifier))
            guard targetWidth > column.width else { continue }
            column.width = targetWidth
        }
        coordinator.captureColumnWidths(from: tableView)
        coordinator.shouldApplyMeasuredSizing = false
    }

    private func expandInfoColumnToFill(in tableView: NSTableView) {
        guard let infoColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == ColumnIdentifier.info.rawValue }) else {
            return
        }
        let totalSpacing = tableView.intercellSpacing.width * CGFloat(max(0, tableView.tableColumns.count - 1))
        let otherColumnsWidth = tableView.tableColumns
            .filter { $0 != infoColumn }
            .reduce(CGFloat.zero) { $0 + $1.width }
        let availableWidth = max(infoColumn.minWidth, tableView.bounds.width - otherColumnsWidth - totalSpacing)
        // Only expand; never shrink user-resized widths.
        if availableWidth > infoColumn.width {
            infoColumn.width = availableWidth
        }
    }

    private func ensureInfoColumnLast(in tableView: NSTableView) {
        guard let infoIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == ColumnIdentifier.info.rawValue }) else {
            return
        }
        let lastIndex = tableView.tableColumns.count - 1
        guard infoIndex != lastIndex else { return }
        tableView.moveColumn(infoIndex, toColumn: lastIndex)
    }
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
        private var lastKnownColumnWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
        private var baselineColumnWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
        private var doubleClickRecognizer: NSClickGestureRecognizer?
        private let columnWidthEpsilon: CGFloat = 0.5

        var hasAppliedMeasuredSizing = false
        var shouldApplyMeasuredSizing = true

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

        func configureDoubleClick() {
            guard let tableView else { return }
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleClick(_:))
            if doubleClickRecognizer == nil {
                let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClickGesture(_:)))
                recognizer.numberOfClicksRequired = 2
                tableView.addGestureRecognizer(recognizer)
                doubleClickRecognizer = recognizer
            }
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

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView else { return }
            captureColumnWidths(from: tableView)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, rows.indices.contains(row) else { return nil }
            let rowModel = rows[row]
            let identifier = tableColumn.identifier
            if identifier.rawValue == ColumnIdentifier.type.rawValue {
                return makeTypePillCell(for: identifier, row: rowModel)
            }

            let textField = makeTextField(for: identifier, row: rowModel)
            let cell = NSTableCellView()
            cell.identifier = identifier
            cell.textField = textField
            cell.addSubview(textField)
            textField.translatesAutoresizingMaskIntoConstraints = false
            let style = PacketNSTableView.style
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: style.cellHorizontalPadding),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -style.cellHorizontalPadding),
                textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: style.cellVerticalPadding),
                textField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -style.cellVerticalPadding)
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

        @objc func handleDoubleClickGesture(_ sender: NSClickGestureRecognizer) {
            guard let tableView else { return }
            let location = sender.location(in: tableView)
            let row = tableView.row(at: location)
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
            tableView.selectRowIndexes(IndexSet(integer: resolvedRow), byExtendingSelection: false)
            let packetID = rows[resolvedRow].id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selection.wrappedValue = [packetID]
                self.onInspectSelection()
            }
        }

        func captureColumnWidths(from tableView: NSTableView) {
            let widths = tableView.tableColumns.reduce(into: [NSUserInterfaceItemIdentifier: CGFloat]()) { result, column in
                result[column.identifier] = column.width
            }
            lastKnownColumnWidths = widths
            hasAppliedMeasuredSizing = true
        }

        func captureBaselineWidths(from tableView: NSTableView) {
            guard baselineColumnWidths.isEmpty else { return }
            baselineColumnWidths = tableView.tableColumns.reduce(into: [NSUserInterfaceItemIdentifier: CGFloat]()) { result, column in
                result[column.identifier] = column.width
            }
        }

        func clearBaselineWidths() {
            baselineColumnWidths.removeAll()
        }

        func shouldResizeColumn(_ column: NSTableColumn) -> Bool {
            guard let baselineWidth = baselineColumnWidths[column.identifier] else { return true }
            return abs(column.width - baselineWidth) <= columnWidthEpsilon
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
                field.toolTip = row.timeText
            case ColumnIdentifier.from.rawValue:
                field.stringValue = row.fromText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
                field.alignment = .left
                field.toolTip = row.fromText
            case ColumnIdentifier.to.rawValue:
                field.stringValue = row.toText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .secondaryLabelColor : .labelColor
                field.alignment = .left
                field.toolTip = row.toText
            case ColumnIdentifier.via.rawValue:
                field.stringValue = row.viaText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = .secondaryLabelColor
                field.alignment = .left
                field.toolTip = row.viaText
            case ColumnIdentifier.type.rawValue:
                field.stringValue = row.typeLabel
                field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                field.textColor = .secondaryLabelColor
                field.alignment = .center
                field.toolTip = row.typeTooltip
            case ColumnIdentifier.info.rawValue:
                field.stringValue = row.infoText
                field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                field.textColor = row.isLowSignal ? .tertiaryLabelColor : .secondaryLabelColor
                field.alignment = .left
                field.toolTip = row.infoTooltip
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            default:
                field.stringValue = ""
            }

            return field
        }

        private func makeTypePillCell(for identifier: NSUserInterfaceItemIdentifier, row: PacketRowViewModel) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let pillView = TypePillView(text: row.typeLabel, isLowSignal: row.isLowSignal)
            pillView.toolTip = row.typeTooltip
            cell.addSubview(pillView)
            pillView.translatesAutoresizingMaskIntoConstraints = false
            let style = PacketNSTableView.style
            NSLayoutConstraint.activate([
                pillView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                pillView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                pillView.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor, constant: style.cellVerticalPadding),
                pillView.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -style.cellVerticalPadding)
            ])
            return cell
        }
    }
}

private final class TypePillView: NSView {
    private let textField = NSTextField(labelWithString: "")
    private let backgroundView = NSView()

    init(text: String, isLowSignal: Bool) {
        super.init(frame: .zero)
        let style = PacketTableStyle.current
        wantsLayer = true
        backgroundView.wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(backgroundView)
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        textField.stringValue = text
        textField.font = .monospacedSystemFont(ofSize: style.pillFontSize, weight: .semibold)
        textField.alignment = .center
        textField.textColor = isLowSignal ? .secondaryLabelColor : .labelColor
        textField.setContentHuggingPriority(.required, for: .horizontal)
        textField.setContentCompressionResistancePriority(.required, for: .horizontal)
        backgroundView.addSubview(textField)
        textField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: style.pillMinWidth),
            textField.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: style.pillHPadding),
            textField.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -style.pillHPadding),
            textField.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: style.pillVPadding),
            textField.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -style.pillVPadding)
        ])
        backgroundView.layer?.cornerRadius = style.pillCornerRadius
        backgroundView.layer?.borderWidth = style.pillBorderWidth
        backgroundView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(style.pillBorderAlpha).cgColor
        backgroundView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(style.pillBackgroundAlpha).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct PacketTableStyle {
    static let current = PacketTableStyle()

    let rowHeight: CGFloat = 20
    let cellVerticalPadding: CGFloat = 1
    let cellHorizontalPadding: CGFloat = 4
    let pillCornerRadius: CGFloat = 8
    let pillHPadding: CGFloat = 6
    let pillVPadding: CGFloat = 2
    let pillBackgroundAlpha: CGFloat = 0.35
    let pillBorderAlpha: CGFloat = 0.6
    let pillMinWidth: CGFloat = 28
    let pillFontSize: CGFloat = 11
    let pillBorderWidth: CGFloat = 1
}

private struct PacketTableColumnSizer {
    let rows: [PacketRowViewModel]

    func width(for column: PacketNSTableView.ColumnIdentifier) -> CGFloat {
        let headerWidth = columnHeaderWidth(for: column)
        let contentWidth = columnContentWidth(for: column)
        let maxWidth = columnMaxWidth(for: column)
        return min(max(headerWidth, contentWidth) + 12, maxWidth)
    }

    private func columnHeaderWidth(for column: PacketNSTableView.ColumnIdentifier) -> CGFloat {
        let title: String
        switch column {
        case .time: title = "Time"
        case .from: title = "From"
        case .to: title = "To"
        case .via: title = "Via"
        case .type: title = "Type"
        case .info: title = "Info"
        }
        return title.size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
    }

    private func columnContentWidth(for column: PacketNSTableView.ColumnIdentifier) -> CGFloat {
        let font: NSFont
        let values: [String]
        switch column {
        case .time:
            font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            values = rows.map { $0.timeText }
        case .from:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values = rows.map { $0.fromText }
        case .to:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values = rows.map { $0.toText }
        case .via:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values = rows.map { $0.viaText }
        case .type:
            font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            values = rows.map { $0.typeLabel }
        case .info:
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            values = rows.map { $0.infoText }
        }
        let measured = values.reduce(CGFloat.zero) { current, value in
            let width = value.size(withAttributes: [.font: font]).width
            return max(current, width)
        }
        return measured
    }

    private func columnMaxWidth(for column: PacketNSTableView.ColumnIdentifier) -> CGFloat {
        switch column {
        case .time: return 140
        case .from, .to: return 200
        case .via: return 180
        case .type: return 80
        case .info: return 1200
        }
    }
}
